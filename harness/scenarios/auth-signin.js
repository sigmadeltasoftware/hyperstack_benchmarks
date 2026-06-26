// bench/scenarios/auth-signin.js — k6 Auth SIGN-IN scenario.
//
// Runs inside Docker (grafana/k6 image). No Node.js APIs.
// Exercises POST /auth/v1/token?grant_type=password with fixture users.
//
// ══════════════════════════════════════════════════════════════════════════════
// C2 CAVEAT — MANDATORY READING (FAIRNESS.md §C2)
// ══════════════════════════════════════════════════════════════════════════════
// Auth signin throughput is DOMINATED by the password hash algorithm, NOT by
// the API layer's speed.  The two sides use DIFFERENT algorithms:
//
//   HyperStack   → Argon2id  (m=19456 KiB ~19 MB, t=2, p=1)
//                  Memory-hard KDF; each verify occupies ~19 MB RAM + 2 passes.
//                  OWASP-recommended minimum — the CORRECT production default.
//
//   Supabase     → bcrypt    (cost=10, GoTrue default)
//                  CPU-only hash; no large memory requirement.
//
// These are DIFFERENT security postures, not equivalent work units. A lower
// HyperStack req/s DOES NOT mean HyperStack auth is "worse" — it means
// Argon2id is deliberately more expensive per-hash to resist offline cracking.
// To compare on equal terms you would need to calibrate hash time per
// algorithm (e.g. match wall-clock time per hash at the target concurrency).
// This harness does NOT do that; it intentionally runs each side's production
// default and documents the confound.
//
// INTERPRETATION RULE: auth throughput numbers measure TWO THINGS simultaneously:
//   (1) API-layer + connection overhead (the comparable part)
//   (2) Hash algorithm cost             (NOT comparable — by design)
// Do not present a gap in signin req/s as a raw performance regression.
// ══════════════════════════════════════════════════════════════════════════════
//
// Design: ONE target per k6 invocation (I4 — no ordering/warmup bias).
// The orchestrator (run.sh) runs separate k6 invocations for each target.
//
// Env vars (passed via -e):
//   TARGET         — "hyperstack" | "supabase"
//   HS_AUTH_URL    — e.g. http://host.docker.internal:PORT/auth/v1
//   HS_FIXTURE_USERS_JSON — JSON array of {email,password} for HS fixture users
//   SB_AUTH_URL    — e.g. http://supabase_auth_SDTool:9999
//   SB_FIXTURE_USERS_JSON — JSON array of {email,password} for SB fixture users
//   SB_ANON_KEY    — Supabase anon/apikey header value (required by Kong; not
//                    needed for direct GoTrue but included for symmetry)
//
// Results via --summary-export capturing http_req_duration percentiles + http_reqs.
//
// VU DESIGN NOTE:
//   Auth is memory-hard on HyperStack (Argon2id ~19 MB/hash) and CPU-heavy on
//   Supabase (bcrypt). High VU counts only build queue depth, not throughput.
//   5 VUs with 500 ms think time keeps in-flight hashes bounded and avoids
//   pure queuing artifacts.  The 30s hold window gives a stable measurement.

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';

// ── Custom metrics ────────────────────────────────────────────────────────────

const signinLatency = new Trend('auth_signin_latency_ms', true);
const signinSuccess = new Rate('auth_signin_success_rate');
const signinErrors  = new Counter('auth_signin_errors');

// ── Options ───────────────────────────────────────────────────────────────────
// Low VU count: auth is hash-bound, not connection-bound.
// 5 VUs × 500 ms think time → ~10 concurrent hashes max, sustainable.
// Ramp matches rest-select shape but shorter and with think time.

export const options = {
  scenarios: {
    auth_signin: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration:  '5s', target: 5 },  // ramp to 5 VUs
        { duration: '30s', target: 5 },  // hold steady — measurement window
        { duration:  '5s', target: 0 },  // ramp down
      ],
      gracefulRampDown: '5s',
    },
  },
  thresholds: {
    http_req_failed:          ['rate<0.01'],   // <1% error rate
    auth_signin_success_rate: ['rate>0.99'],
    // p95 threshold is intentionally generous: Argon2id at m=19MB is ~200-400ms
    // per hash; bcrypt cost=10 is ~80-150ms.  Both are expected to be slower
    // than REST data scenarios — that is correct behavior, not a bug.
    auth_signin_latency_ms:   ['p(95)<10000'],
  },
};

// ── User cycling ──────────────────────────────────────────────────────────────
// Parsed from JSON env var so we can cycle without Node.js fs access.

let fixtureUsers = [];

function getUsers() {
  if (fixtureUsers.length > 0) return fixtureUsers;
  const target = __ENV.TARGET || 'hyperstack';
  const raw = (target === 'supabase')
    ? __ENV.SB_FIXTURE_USERS_JSON
    : __ENV.HS_FIXTURE_USERS_JSON;
  if (!raw) {
    // Fallback: single user from legacy env vars (graceful degradation)
    fixtureUsers = [{ email: 'hs_bench_user_0@bench.test', password: 'bench_password_123' }];
    return fixtureUsers;
  }
  try {
    fixtureUsers = JSON.parse(raw);
  } catch (_) {
    fixtureUsers = [{ email: 'hs_bench_user_0@bench.test', password: 'bench_password_123' }];
  }
  return fixtureUsers;
}

// ── Default function ──────────────────────────────────────────────────────────

export default function () {
  const target = __ENV.TARGET || 'hyperstack';

  let authUrl, extraHeaders;

  if (target === 'supabase') {
    authUrl      = __ENV.SB_AUTH_URL;
    const anonKey = __ENV.SB_ANON_KEY || '';
    extraHeaders = anonKey ? { 'apikey': anonKey } : {};
  } else {
    authUrl      = __ENV.HS_AUTH_URL;
    extraHeaders = {};
  }

  // Cycle through fixture users deterministically (VU + iteration mod len)
  const users = getUsers();
  const user  = users[(__VU - 1 + __ITER) % users.length];

  const url  = `${authUrl}/token?grant_type=password`;
  const body = JSON.stringify({ email: user.email, password: user.password });

  const params = {
    headers: {
      'Content-Type': 'application/json',
      'Accept':       'application/json',
      ...extraHeaders,
    },
    timeout: '30s',   // Argon2id can take >1s under load
    tags: { target, scenario: 'auth-signin' },
  };

  const res = http.post(url, body, params);

  const ok = check(res, {
    'status 200': (r) => r.status === 200,
    'access_token present': (r) => {
      try {
        const j = JSON.parse(r.body);
        return typeof j.access_token === 'string' && j.access_token.length > 0;
      } catch { return false; }
    },
  });

  signinLatency.add(res.timings.duration, { target });
  signinSuccess.add(ok ? 1 : 0, { target });
  if (!ok) signinErrors.add(1, { target });

  // Think time: gives hashes time to complete and avoids pure queue-depth measurement.
  // 500 ms is intentional — auth is not a high-frequency endpoint in real workloads.
  sleep(0.5);
}
