#!/usr/bin/env node
// bench/selfcheck.mjs — Verify that both targets are responding correctly.
//
// Usage:
//   node bench/selfcheck.mjs --framing <a|b>
//
// Reads bench/results/framing-<framing>.env and bench/results/framing-<framing>-seed.json.
// Exits 1 on any failure.

import { readFileSync } from 'node:fs';
import { createClient } from '../clients/hyperstack-js/node_modules/@supabase/supabase-js/dist/index.mjs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..');
const BENCH_DIR = path.join(REPO_ROOT, 'bench');

// ── Arg parsing ───────────────────────────────────────────────────────────────

function parseArgs() {
  const args = process.argv.slice(2);
  let framing = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--framing') framing = args[++i];
  }
  if (!framing) {
    console.error('Missing required arg: --framing <a|b>');
    process.exit(1);
  }
  return { framing };
}

// ── File readers ──────────────────────────────────────────────────────────────

function readEnvFile(framing) {
  const p = path.join(BENCH_DIR, 'results', `framing-${framing}.env`);
  try {
    const raw = readFileSync(p, 'utf8');
    const env = {};
    for (const line of raw.split('\n')) {
      const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
      if (m) env[m[1]] = m[2];
    }
    return env;
  } catch (e) {
    console.error(`[selfcheck] Cannot read env file ${p}: ${e.message}`);
    process.exit(1);
  }
}

function readSeedFile(framing) {
  const p = path.join(BENCH_DIR, 'results', `framing-${framing}-seed.json`);
  try {
    return JSON.parse(readFileSync(p, 'utf8'));
  } catch (e) {
    console.error(`[selfcheck] Cannot read seed file ${p}: ${e.message}`);
    console.error('[selfcheck] Run seed.mjs first.');
    process.exit(1);
  }
}

// ── HTTP helpers ──────────────────────────────────────────────────────────────

async function httpGet(url, headers = {}) {
  try {
    const res = await fetch(url, { headers, signal: AbortSignal.timeout(10_000) });
    const text = await res.text();
    let json;
    try { json = JSON.parse(text); } catch { json = { _raw: text }; }
    return { status: res.status, ok: res.ok, json };
  } catch (e) {
    return { status: 0, ok: false, json: null, error: e.message };
  }
}

async function httpPost(url, body, headers = {}) {
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...headers },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(10_000),
    });
    const text = await res.text();
    let json;
    try { json = JSON.parse(text); } catch { json = { _raw: text }; }
    return { status: res.status, ok: res.ok, json };
  } catch (e) {
    return { status: 0, ok: false, json: null, error: e.message };
  }
}

// ── Checks ────────────────────────────────────────────────────────────────────

const BENCH_USER_PASSWORD = 'bench_password_123';

let allPassed = true;
const failures = [];

function pass(label) {
  console.log(`  ✓ ${label}`);
}

function fail(label, detail) {
  console.error(`  ✗ ${label}: ${detail}`);
  allPassed = false;
  failures.push({ label, detail });
}

async function checkTarget(label, restUrl, authUrl, firstUser, anonKey) {
  console.log(`\n[selfcheck] Checking ${label} ...`);
  console.log(`  REST URL : ${restUrl}`);
  console.log(`  Auth URL : ${authUrl}`);

  const { email, jwt, userId } = firstUser;

  // Check 1: REST select with JWT — must return non-empty JSON array owned by user (RLS)
  if (!jwt) {
    fail(`${label} REST select`, 'No JWT available (email confirmation required?)');
  } else {
    // Kong requires apikey header; use anonKey if provided (for Supabase via Kong),
    // otherwise fall back to the user JWT (for HyperStack direct).
    const apikeyHeader = anonKey || jwt;
    const restRes = await httpGet(
      `${restUrl}/bench_items?select=id,owner&limit=10`,
      {
        'Authorization': `Bearer ${jwt}`,
        'apikey': apikeyHeader,
      }
    );
    if (restRes.status !== 200) {
      fail(`${label} REST select`, `Expected 200, got ${restRes.status}: ${JSON.stringify(restRes.json)}`);
    } else {
      // I3: assert body is a non-empty JSON array — "200 but empty" must fail
      const rows = restRes.json;
      if (!Array.isArray(rows)) {
        fail(`${label} REST select body`, `Expected JSON array, got: ${JSON.stringify(rows)}`);
      } else if (rows.length === 0) {
        fail(`${label} REST select body`, 'Got HTTP 200 but response is an empty array — RLS may be mis-configured or fixture rows are missing');
      } else {
        pass(`${label} REST select (HTTP 200, non-empty array, ${rows.length} row(s))`);
        // I3: assert RLS is actually filtering — all returned rows should be owned by this user
        if (userId) {
          const wrongOwner = rows.filter(row => row.owner && row.owner !== userId);
          if (wrongOwner.length > 0) {
            fail(
              `${label} REST RLS check`,
              `${wrongOwner.length} row(s) returned with owner != ${userId} — RLS may not be enforced`
            );
          } else if (rows.some(row => row.owner === userId)) {
            pass(`${label} REST RLS (all returned rows owned by requesting user)`);
          } else {
            // rows present but none have owner set — skip ownership check (schema variation)
            pass(`${label} REST RLS (rows returned; owner field not populated — skipping ownership assertion)`);
          }
        }
      }
    }
  }

  // Check 2: Auth signin
  const signinRes = await httpPost(
    `${authUrl}/token?grant_type=password`,
    { email, password: BENCH_USER_PASSWORD }
  );
  if (signinRes.ok && signinRes.json?.access_token) {
    pass(`${label} auth signin (200 + access_token present)`);
  } else {
    fail(`${label} auth signin`, `HTTP ${signinRes.status}: ${JSON.stringify(signinRes.json)}`);
  }
}

// ── Realtime sanity check ─────────────────────────────────────────────────────
//
// Both HyperStack and Supabase use the supabase-js Phoenix path
// (/realtime/v1/websocket) for this self-check — same protocol as the headline
// benchmark driver.  This ensures selfcheck results are consistent with the
// benchmark numbers (apples-to-apples).
//
//   HyperStack: supabase-js Phoenix at /realtime/v1/websocket (Phoenix endpoint
//               on the HyperStack binary — confirmed working on 2026-06-25 rebuild)
//   Supabase:   supabase-js Phoenix at /realtime/v1/websocket (via Kong)
//
// Publisher: service-role REST INSERT with owner=subscriberUserId so the RLS
// USING clause (owner = auth.uid()) passes for the subscriber — REPLICA IDENTITY
// FULL ensures the WAL record carries the owner column for the realtime server.

// checkRealtimeSanityHs — uses the same supabase-js Phoenix path as Supabase.
// The HyperStack release binary (rebuilt 2026-06-25) has the /realtime/v1/websocket
// endpoint mounted; using it here makes selfcheck consistent with the benchmark driver.
// anonKey for HyperStack: the service key is accepted as the apikey param (HS does not
// enforce a distinct anon key — any valid key is accepted for the Phoenix handshake).
async function checkRealtimeSanityHs(label, baseUrl, anonKey, subscriberJwt, serviceJwt, userId) {
  console.log(`\n[selfcheck] Checking realtime delivery for ${label} (supabase-js Phoenix) ...`);
  // Delegate to the same Phoenix check used for Supabase.
  return checkRealtimeSanitySb(label, baseUrl, anonKey, subscriberJwt, serviceJwt, userId);
}

async function checkRealtimeSanitySb(label, baseUrl, anonKey, subscriberJwt, serviceJwt, userId) {
  console.log(`\n[selfcheck] Checking realtime delivery for ${label} (supabase-js Phoenix) ...`);

  let subscriberClient = null;
  let publisherClient = null;
  const received = [];

  try {
    subscriberClient = createClient(baseUrl, anonKey, {
      global: { headers: { Authorization: `Bearer ${subscriberJwt}` } },
      realtime: { params: { apikey: anonKey } },
    });
    await subscriberClient.realtime.setAuth(subscriberJwt);

    // Publisher uses service role
    publisherClient = createClient(baseUrl, serviceJwt, {
      global: { headers: { Authorization: `Bearer ${serviceJwt}`, apikey: serviceJwt } },
    });
  } catch (e) {
    fail(`${label} realtime client`, `createClient threw: ${e.message}`);
    return;
  }

  // Subscribe
  try {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('SUBSCRIBED timeout after 15s')), 15_000);
      subscriberClient.channel(`selfcheck-rt-${Date.now()}`)
        .on('postgres_changes',
          { event: 'INSERT', schema: 'public', table: 'bench_items' },
          payload => received.push(payload)
        )
        .subscribe((status, err) => {
          if (status === 'SUBSCRIBED') { clearTimeout(timer); resolve(); }
          else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT' || status === 'CLOSED') {
            clearTimeout(timer);
            reject(new Error(`Channel: ${status} ${err?.message ?? ''}`));
          }
        });
    });
  } catch (e) {
    fail(`${label} realtime subscribe`, e.message);
    try { subscriberClient.realtime.disconnect(); } catch (_) {}
    return;
  }

  pass(`${label} realtime subscribe (SUBSCRIBED)`);

  // Insert via service client
  const countBefore = received.length;
  try {
    const { error } = await publisherClient
      .from('bench_items')
      .insert({ owner: userId, body: JSON.stringify({ inserted_at: Date.now(), seq: 0 }) });
    if (error) {
      fail(`${label} realtime insert`, `INSERT error: ${JSON.stringify(error)}`);
    }
  } catch (e) {
    fail(`${label} realtime insert`, e.message);
  }

  // Wait for delivery
  try {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('no event within 10s')), 10_000);
      const poll = setInterval(() => {
        if (received.length > countBefore) { clearTimeout(timer); clearInterval(poll); resolve(); }
      }, 100);
    });
    pass(`${label} realtime delivery (event received within 10s)`);
  } catch (e) {
    fail(`${label} realtime delivery`, e.message);
  }

  try { await subscriberClient.removeAllChannels(); } catch (_) {}
  try { subscriberClient.realtime.disconnect(); } catch (_) {}
}

// ── Main ──────────────────────────────────────────────────────────────────────

const { framing } = parseArgs();
const envVars  = readEnvFile(framing);
const seedData = readSeedFile(framing);

console.log(`[selfcheck] Framing ${framing.toUpperCase()} self-check`);

// HyperStack
const HS_BASE_URL = envVars['HS_BASE_URL'];
const HS_REST_URL = `${HS_BASE_URL}/rest/v1`;
const HS_AUTH_URL = `${HS_BASE_URL}/auth/v1`;
const hsFirstUser = seedData.hyperstack.users[0];

// Supabase (host-accessible URLs for selfcheck)
// SB_REST_URL_HOST already includes /rest/v1 path (e.g. http://localhost:54321/rest/v1)
// SB_AUTH_URL_HOST already includes /auth/v1 path (e.g. http://localhost:54321/auth/v1)
const SB_REST_URL_HOST = envVars['SB_REST_URL_HOST'];
const SB_AUTH_URL_HOST = envVars['SB_AUTH_URL_HOST'];
const SB_ANON_JWT = envVars['SB_ANON_JWT'];
const sbFirstUser = seedData.supabase.users[0];

await checkTarget('HyperStack', HS_REST_URL, HS_AUTH_URL, hsFirstUser, null);
await checkTarget('Supabase',   SB_REST_URL_HOST, SB_AUTH_URL_HOST, sbFirstUser, SB_ANON_JWT);

// Realtime sanity checks
// HS_SERVICE_KEY used as anonKey for HyperStack WS (HyperStack uses it as the apikey param)
// User JWTs used for subscribers so RLS re-fetch works correctly
// Service JWTs used for publishers to bypass INSERT RLS
const HS_SERVICE_KEY = envVars['HS_SERVICE_KEY'];
const SB_SERVICE_JWT = envVars['SB_SERVICE_JWT'];
const hsUserId  = hsFirstUser?.userId ?? hsFirstUser?.id ?? '';
const sbUserId  = sbFirstUser?.userId ?? sbFirstUser?.id ?? '';
const hsUserJwt = hsFirstUser?.jwt ?? '';
const sbUserJwt = sbFirstUser?.jwt ?? '';

if (hsUserJwt) {
  await checkRealtimeSanityHs(
    'HyperStack', HS_BASE_URL,
    HS_SERVICE_KEY,   // anonKey: HS accepts service key as Phoenix apikey param
    hsUserJwt,        // subscriber JWT (authenticated user — owner RLS must pass)
    HS_SERVICE_KEY,   // service key for REST INSERT (bypasses INSERT RLS)
    hsUserId
  );
} else {
  console.log('\n[selfcheck] Skipping HyperStack realtime (no user JWT available)');
}

if (sbUserJwt && SB_SERVICE_JWT) {
  await checkRealtimeSanitySb(
    'Supabase', 'http://localhost:55421',
    SB_ANON_JWT,    // anonKey (Kong apikey param)
    sbUserJwt,      // subscriber JWT
    SB_SERVICE_JWT, // service JWT for insert
    sbUserId
  );
} else {
  console.log('\n[selfcheck] Skipping Supabase realtime (no user JWT or service JWT available)');
}

console.log('');
if (allPassed) {
  console.log('[selfcheck] All checks passed.');
  process.exit(0);
} else {
  console.error(`[selfcheck] ${failures.length} check(s) FAILED:`);
  for (const f of failures) {
    console.error(`  - ${f.label}: ${f.detail}`);
  }
  process.exit(1);
}
