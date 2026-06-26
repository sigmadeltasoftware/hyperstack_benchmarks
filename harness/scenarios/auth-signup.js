// bench/scenarios/auth-signup.js — k6 Auth SIGN-UP scenario.
//
// Runs inside Docker (grafana/k6 image). No Node.js APIs.
// Exercises POST /auth/v1/signup with a unique disposable email per iteration
// so each iteration hashes a real new password (no existing-user fast-path).
//
// ══════════════════════════════════════════════════════════════════════════════
// C2 CAVEAT — MANDATORY READING (FAIRNESS.md §C2)
// ══════════════════════════════════════════════════════════════════════════════
// Auth signup throughput is DOMINATED by the password hash algorithm, NOT by
// the API layer's speed.  The two sides use DIFFERENT algorithms:
//
//   HyperStack   → Argon2id  (m=19456 KiB ~19 MB, t=2, p=1)
//                  Memory-hard KDF; each hash occupies ~19 MB RAM + 2 passes.
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
// Do not present a gap in signup req/s as a raw performance regression.
// ══════════════════════════════════════════════════════════════════════════════
//
// Design: ONE target per k6 invocation (I4 — no ordering/warmup bias).
// The orchestrator (run.sh) runs separate k6 invocations for each target.
//
// EMAIL NAMESPACE ISOLATION:
//   Signup users use the prefix "bench_signup_hs_" or "bench_signup_sb_" plus
//   VU + iteration + timestamp suffix.  This prefix is DISTINCT from the fixture
//   user prefix ("hs_bench_user_" / "sb_bench_user_") so signup runs do NOT
//   pollute the fixture user set used by rest/auth-signin scenarios.
//   The rows created during signup runs are accepted and left in the DB (disposable
//   pattern).  They are removed on the next "framing up" → seed cycle which
//   truncates bench_items and re-seeds from scratch.
//
// Env vars (passed via -e):
//   TARGET         — "hyperstack" | "supabase"
//   HS_AUTH_URL    — e.g. http://host.docker.internal:PORT/auth/v1
//   SB_AUTH_URL    — e.g. http://supabase_auth_SDTool:9999
//   SB_ANON_KEY    — Supabase anon/apikey header value
//   BENCH_RUN_ID   — run ID string embedded in emails (avoids cross-run collisions)
//
// Results via --summary-export capturing http_req_duration percentiles + http_reqs.
//
// VU DESIGN NOTE:
//   Signup is at least as expensive as signin (hash + DB write + JWT mint).
//   5 VUs with 500 ms think time is appropriate — same reasoning as auth-signin.

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';

// ── Custom metrics ────────────────────────────────────────────────────────────

const signupLatency = new Trend('auth_signup_latency_ms', true);
const signupSuccess = new Rate('auth_signup_success_rate');
const signupErrors  = new Counter('auth_signup_errors');

// ── Options ───────────────────────────────────────────────────────────────────
// Low VU count: signup is hash-bound + DB write, even heavier than signin.
// 5 VUs × 500 ms think time keeps in-flight hashes bounded.

export const options = {
  scenarios: {
    auth_signup: {
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
    auth_signup_success_rate: ['rate>0.99'],
    // p95 threshold is intentionally generous: signup includes hash + DB write.
    // Argon2id cost means ~200-600ms per hash under load is expected.
    auth_signup_latency_ms:   ['p(95)<15000'],
  },
};

// ── Default function ──────────────────────────────────────────────────────────

export default function () {
  const target   = __ENV.TARGET || 'hyperstack';
  const runId    = __ENV.BENCH_RUN_ID || 'x';

  let authUrl, emailPrefix, extraHeaders;

  if (target === 'supabase') {
    authUrl      = __ENV.SB_AUTH_URL;
    emailPrefix  = `bench_signup_sb_${runId}`;
    const anonKey = __ENV.SB_ANON_KEY || '';
    extraHeaders = anonKey ? { 'apikey': anonKey } : {};
  } else {
    authUrl      = __ENV.HS_AUTH_URL;
    emailPrefix  = `bench_signup_hs_${runId}`;
    extraHeaders = {};
  }

  // Unique email per VU+iteration — each signup is a real new user with a fresh hash.
  // The "bench_signup_" prefix is distinct from fixture users ("hs_bench_user_")
  // so these rows never interfere with auth-signin or REST scenarios.
  const email    = `${emailPrefix}_vu${__VU}_i${__ITER}@bench.test`;
  const password = 'bench_signup_pw_123!';

  const url  = `${authUrl}/signup`;
  const body = JSON.stringify({ email, password });

  const params = {
    headers: {
      'Content-Type': 'application/json',
      'Accept':       'application/json',
      ...extraHeaders,
    },
    timeout: '30s',   // Argon2id signup can take >1s under load
    tags: { target, scenario: 'auth-signup' },
  };

  const res = http.post(url, body, params);

  // Both sides return 200 with user object on success.
  // Supabase may return 200 with confirmation_sent_at if email confirm required
  // (autoconfirm is on in SDTool dev stack, so access_token is present).
  const ok = check(res, {
    'status 200': (r) => r.status === 200,
    'user.id present': (r) => {
      try {
        const j = JSON.parse(r.body);
        // Accept either a direct user.id (HyperStack) or nested user.id (some GoTrue versions)
        const uid = j.user?.id || j.id;
        return typeof uid === 'string' && uid.length > 0;
      } catch { return false; }
    },
  });

  signupLatency.add(res.timings.duration, { target });
  signupSuccess.add(ok ? 1 : 0, { target });
  if (!ok) signupErrors.add(1, { target });

  // Think time: gives the hash time to complete and avoids infinite queue buildup.
  sleep(0.5);
}
