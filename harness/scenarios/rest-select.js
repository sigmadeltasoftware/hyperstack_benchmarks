// bench/scenarios/rest-select.js — k6 REST SELECT (RLS-filtered) scenario.
//
// Runs inside Docker (grafana/k6 image). No Node.js APIs.
// Exercises authed GET /rest/v1/bench_items with RLS filtering.
//
// Design: ONE target per k6 invocation (I4 — no ordering/warmup bias).
// The orchestrator (run.sh) runs separate k6 invocations for each target.
//
// Env vars (passed via -e or --env):
//   TARGET          — "hyperstack" | "supabase"  (selects URL + JWT to use)
//   HS_REST_URL     — e.g. http://host.docker.internal:PORT/rest/v1
//   HS_JWT          — HyperStack user JWT
//   SB_REST_URL     — e.g. http://supabase_rest_SDTool:3000
//   SB_JWT          — Supabase user JWT
//   SB_ANON_KEY     — Supabase anon/apikey header value
//
// Results via --summary-export capturing http_req_duration percentiles + http_reqs.
// Table column: "body" (text). Schema: id, owner (uuid), body (text), created_at.

import http from 'k6/http';
import { check } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';

// ── Custom metrics ────────────────────────────────────────────────────────────

const selectLatency = new Trend('rest_select_latency_ms', true);
const selectSuccess = new Rate('rest_select_success_rate');
const selectErrors  = new Counter('rest_select_errors');

// ── Options ───────────────────────────────────────────────────────────────────
// Ramping-VU model: ramp up to 20 VUs, hold 30s, ramp down.
// 20 VUs is enough to saturate both targets without giant output files.

export const options = {
  scenarios: {
    rest_select: {
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
    rest_select_success_rate: ['rate>0.99'],
    rest_select_latency_ms:   ['p(95)<5000'],
  },
};

// ── Default function ──────────────────────────────────────────────────────────

export default function () {
  const target = __ENV.TARGET || 'hyperstack';

  let baseUrl, jwt, extraHeaders;

  if (target === 'supabase') {
    baseUrl = __ENV.SB_REST_URL;
    jwt     = __ENV.SB_JWT;
    const anonKey = __ENV.SB_ANON_KEY || jwt;
    extraHeaders = { 'apikey': anonKey };
  } else {
    // Default: hyperstack
    baseUrl = __ENV.HS_REST_URL;
    jwt     = __ENV.HS_JWT;
    extraHeaders = {};
  }

  // Table columns: id, owner (uuid), body (text), created_at
  const url = `${baseUrl}/bench_items?select=id,owner,body&limit=20&order=id.asc`;

  const params = {
    headers: {
      'Authorization': `Bearer ${jwt}`,
      'Content-Type':  'application/json',
      'Accept':        'application/json',
      ...extraHeaders,
    },
    timeout: '15s',
    tags: { target, scenario: 'rest-select' },
  };

  const res = http.get(url, params);

  const ok = check(res, {
    'status 200': (r) => r.status === 200,
    // Non-empty guard: a 200-with-empty-array (e.g. RLS silently breaking, or a
    // wrong/expired JWT) must NOT count as a successful measured request — that
    // would inflate the target's req/s. The Task-1 self-check gates this at
    // startup; this is the per-request continuous guard during the load run.
    'body is non-empty array': (r) => {
      try { const a = JSON.parse(r.body); return Array.isArray(a) && a.length > 0; } catch { return false; }
    },
  });

  selectLatency.add(res.timings.duration, { target });
  selectSuccess.add(ok ? 1 : 0, { target });
  if (!ok) selectErrors.add(1, { target });
}
