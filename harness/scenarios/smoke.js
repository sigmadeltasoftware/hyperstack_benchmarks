// bench/scenarios/smoke.js — k6 smoke scenario comparing HyperStack vs Supabase.
//
// Runs inside Docker (grafana/k6 image). No Node.js APIs.
// Receives config via k6 --env flags:
//   HS_REST_URL   — HyperStack REST base URL (e.g. http://host.docker.internal:PORT/rest/v1)
//   HS_JWT        — HyperStack user JWT
//   SB_REST_URL   — Supabase REST base URL (e.g. http://supabase_rest_SDTool:3000 or via Kong)
//   SB_JWT        — Supabase user JWT
//   SB_ANON_KEY   — Supabase anon API key (used as apikey header)
//
// k6 docs: https://grafana.com/docs/k6/latest/

import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// ── Custom metrics ────────────────────────────────────────────────────────────

const hsLatency  = new Trend('hs_latency_ms',  true);
const sbLatency  = new Trend('sb_latency_ms',  true);
const hsErrors   = new Counter('hs_errors');
const sbErrors   = new Counter('sb_errors');
const hsSuccRate = new Rate('hs_success_rate');
const sbSuccRate = new Rate('sb_success_rate');

// ── k6 options ────────────────────────────────────────────────────────────────

export const options = {
  vus: 2,
  duration: '5s',
  thresholds: {
    'http_req_failed':   ['rate<0.01'],
    'hs_success_rate':   ['rate>0.99'],
    'sb_success_rate':   ['rate>0.99'],
    'hs_latency_ms':     ['p(95)<2000'],
    'sb_latency_ms':     ['p(95)<2000'],
  },
};

// ── Default function ──────────────────────────────────────────────────────────

export default function () {
  const hsRestUrl = __ENV.HS_REST_URL;
  const hsJwt     = __ENV.HS_JWT;
  const sbRestUrl = __ENV.SB_REST_URL;
  const sbJwt     = __ENV.SB_JWT;
  const sbAnonKey = __ENV.SB_ANON_KEY || sbJwt;

  // ── HyperStack group ───────────────────────────────────────────────────────
  group('hyperstack', function () {
    const url = `${hsRestUrl}/bench_items?select=id&limit=1`;
    const params = {
      headers: {
        'Authorization': `Bearer ${hsJwt}`,
        'Content-Type':  'application/json',
      },
      timeout: '10s',
      tags: { target: 'hyperstack' },
    };

    const res = http.get(url, params);
    const ok = check(res, {
      'hs: status 200': (r) => r.status === 200,
    });

    hsLatency.add(res.timings.duration);
    hsSuccRate.add(ok ? 1 : 0);
    if (!ok) hsErrors.add(1);
  });

  // ── Supabase group ─────────────────────────────────────────────────────────
  group('supabase', function () {
    const url = `${sbRestUrl}/bench_items?select=id&limit=1`;
    const params = {
      headers: {
        'Authorization': `Bearer ${sbJwt}`,
        'apikey':        sbAnonKey,
        'Content-Type':  'application/json',
      },
      timeout: '10s',
      tags: { target: 'supabase' },
    };

    const res = http.get(url, params);
    const ok = check(res, {
      'sb: status 200': (r) => r.status === 200,
    });

    sbLatency.add(res.timings.duration);
    sbSuccRate.add(ok ? 1 : 0);
    if (!ok) sbErrors.add(1);
  });

  // Small inter-iteration pause to avoid thundering-herd on a smoke run
  sleep(0.1);
}
