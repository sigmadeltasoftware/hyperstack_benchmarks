// bench/scenarios/rest-insert.js — k6 REST INSERT scenario.
//
// Runs inside Docker (grafana/k6 image). No Node.js APIs.
// Exercises authed POST /rest/v1/bench_items with owner = authenticated user.
//
// Design: ONE target per k6 invocation (I4 — no ordering/warmup bias).
// The orchestrator (run.sh) runs separate k6 invocations for each target.
//
// Env vars (passed via -e or --env):
//   TARGET          — "hyperstack" | "supabase"  (selects URL + JWT to use)
//   HS_REST_URL     — e.g. http://host.docker.internal:PORT/rest/v1
//   HS_JWT          — HyperStack user JWT
//   HS_USER_ID      — HyperStack fixture user UUID (for owner field)
//   SB_REST_URL     — e.g. http://supabase_rest_SDTool:3000
//   SB_JWT          — Supabase user JWT
//   SB_USER_ID      — Supabase fixture user UUID (for owner field)
//   SB_ANON_KEY     — Supabase anon/apikey header value
//
// Results via --summary-export capturing http_req_duration percentiles + http_reqs.
// Table columns: id (serial), owner (uuid NOT NULL), body (text), created_at.
// Prefer: return=minimal → HyperStack: 204, Supabase: 201.

import http from 'k6/http';
import { check } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';

// ── Custom metrics ────────────────────────────────────────────────────────────

const insertLatency = new Trend('rest_insert_latency_ms', true);
const insertSuccess = new Rate('rest_insert_success_rate');
const insertErrors  = new Counter('rest_insert_errors');

// ── Options ───────────────────────────────────────────────────────────────────
// Ramping-VU model: ramp up to 20 VUs, hold 30s, ramp down.
// Lower peak than select because writes are heavier (WAL, fsync, RLS check).

export const options = {
  scenarios: {
    rest_insert: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration:  '5s', target: 20 },  // ramp to 20 VUs
        { duration: '30s', target: 20 },  // hold steady — measurement window
        { duration:  '5s', target:  0 },  // ramp down
      ],
      gracefulRampDown: '5s',
    },
  },
  thresholds: {
    http_req_failed:          ['rate<0.01'],   // <1% error rate
    rest_insert_success_rate: ['rate>0.99'],
    rest_insert_latency_ms:   ['p(95)<8000'],
  },
};

// ── Default function ──────────────────────────────────────────────────────────

// Deterministic unique payload per VU+iteration to avoid duplicate-key conflicts
// while keeping payloads realistic.
function makePayload(vuId, iter) {
  return `bench-insert-vu${vuId}-iter${iter}`;
}

export default function () {
  const target = __ENV.TARGET || 'hyperstack';

  let baseUrl, jwt, userId, extraHeaders;

  if (target === 'supabase') {
    baseUrl  = __ENV.SB_REST_URL;
    jwt      = __ENV.SB_JWT;
    userId   = __ENV.SB_USER_ID || '';
    const anonKey = __ENV.SB_ANON_KEY || jwt;
    extraHeaders = { 'apikey': anonKey };
  } else {
    // Default: hyperstack
    baseUrl  = __ENV.HS_REST_URL;
    jwt      = __ENV.HS_JWT;
    userId   = __ENV.HS_USER_ID || '';
    extraHeaders = {};
  }

  const url = `${baseUrl}/bench_items`;

  // Table columns: id (serial), owner (uuid NOT NULL), body (text), created_at.
  // Must set owner = authenticated user's UUID — RLS WITH CHECK enforces this.
  const requestBody = JSON.stringify({
    owner: userId,
    body:  makePayload(__VU, __ITER),
  });

  const params = {
    headers: {
      'Authorization': `Bearer ${jwt}`,
      'Content-Type':  'application/json',
      'Accept':        'application/json',
      'Prefer':        'return=minimal',
      ...extraHeaders,
    },
    timeout: '15s',
    tags: { target, scenario: 'rest-insert' },
  };

  const res = http.post(url, requestBody, params);

  // HyperStack returns 204 (return=minimal); Supabase returns 201.
  const ok = check(res, {
    'status 2xx': (r) => r.status >= 200 && r.status < 300,
  });

  insertLatency.add(res.timings.duration, { target });
  insertSuccess.add(ok ? 1 : 0, { target });
  if (!ok) insertErrors.add(1, { target });
}
