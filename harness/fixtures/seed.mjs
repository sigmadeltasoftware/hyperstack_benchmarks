#!/usr/bin/env node
// bench/fixtures/seed.mjs — Seed bench data into HyperStack and Supabase.
//
// Usage:
//   node bench/fixtures/seed.mjs --framing <a|b> [--users K] [--rows R] [--storage-objects S]
//
// Reads bench/results/framing-<framing>.env for URLs.
// Writes bench/results/framing-<framing>-seed.json on success.

import { execSync, execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, unlinkSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '../..');
const BENCH_DIR = path.join(REPO_ROOT, 'bench');

// ── Constants ─────────────────────────────────────────────────────────────────

const PSQL_PATH = process.env.HOME + '/bin/psql-bench';

// Supabase shared pg (for seeding Supabase's postgres DB)
const SB_PG_HOST = 'localhost';
const SB_PG_PORT = '55422';
const SB_PG_USER = 'postgres';
const SB_PG_PASS = 'postgres';

const BENCH_USER_PASSWORD = 'bench_password_123';

// ── Arg parsing ───────────────────────────────────────────────────────────────

function parseArgs() {
  const args = process.argv.slice(2);
  const result = { framing: null, k: 10, r: 100, s: 5 };
  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--framing':         result.framing = args[++i]; break;
      case '--users':           result.k       = parseInt(args[++i], 10); break;
      case '--rows':            result.r       = parseInt(args[++i], 10); break;
      case '--storage-objects': result.s       = parseInt(args[++i], 10); break;
      default:
        console.error(`Unknown arg: ${args[i]}`);
        process.exit(1);
    }
  }
  if (!result.framing) {
    console.error('Missing required arg: --framing <a|b>');
    process.exit(1);
  }
  return result;
}

// ── Env file reader ───────────────────────────────────────────────────────────

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
    console.error(`[seed] Cannot read env file ${p}: ${e.message}`);
    process.exit(1);
  }
}

// ── psql helpers ──────────────────────────────────────────────────────────────

function makePgEnv(pgPass) {
  return {
    ...process.env,
    PATH: `${process.env.HOME}/bin:/usr/local/bin:${process.env.PATH ?? '/usr/bin:/bin'}`,
    PGPASSWORD: pgPass,
  };
}

function psqlDb(connStr, sql, pgPass) {
  const tmpFile = path.join(os.tmpdir(), `bench-seed-${Date.now()}-${process.pid}.sql`);
  try {
    writeFileSync(tmpFile, sql, 'utf8');
    return execFileSync(PSQL_PATH, [
      connStr,
      '-v', 'ON_ERROR_STOP=1',
      '-f', tmpFile,
    ], { encoding: 'utf8', env: makePgEnv(pgPass) });
  } finally {
    try { unlinkSync(tmpFile); } catch (_) { /* ignore */ }
  }
}

function psqlDbQuery(connStr, sql, pgPass) {
  return execFileSync(PSQL_PATH, [
    connStr,
    '-tAc', sql,
  ], { encoding: 'utf8', env: makePgEnv(pgPass) }).trim();
}

// ── HTTP helpers ──────────────────────────────────────────────────────────────

async function httpPost(url, body, headers = {}) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...headers },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let json;
  try { json = JSON.parse(text); } catch { json = { _raw: text }; }
  return { status: res.status, ok: res.ok, json };
}

async function httpGet(url, headers = {}) {
  const res = await fetch(url, { headers });
  const text = await res.text();
  let json;
  try { json = JSON.parse(text); } catch { json = { _raw: text }; }
  return { status: res.status, ok: res.ok, json };
}

// ── Schema setup ──────────────────────────────────────────────────────────────

function applyBenchSchema(connStr, pgPass, label, isSupabase) {
  console.log(`[seed] Applying bench schema to ${label} ...`);
  const sql = `
CREATE TABLE IF NOT EXISTS public.bench_items (
  id         serial PRIMARY KEY,
  owner      uuid NOT NULL,
  body       text,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE public.bench_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bench_items_owner ON public.bench_items;
CREATE POLICY bench_items_owner ON public.bench_items
  USING  (owner = auth.uid())
  WITH CHECK (owner = auth.uid());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.bench_items TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.bench_items_id_seq TO authenticated;
${isSupabase ? 'GRANT SELECT, INSERT ON public.bench_items TO anon;' : ''}
GRANT SELECT, INSERT, UPDATE, DELETE ON public.bench_items TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.bench_items_id_seq TO service_role;

-- REPLICA IDENTITY FULL is required for Supabase realtime postgres_changes with RLS.
-- Without it, the WAL record only carries PK columns; the realtime server cannot
-- evaluate owner-based RLS policies (which reference non-PK columns) and drops
-- the change silently. HyperStack's realtime re-fetches the full row so it does
-- not need FULL, but we apply it on both sides for consistent WAL format.
${isSupabase ? 'ALTER TABLE public.bench_items REPLICA IDENTITY FULL;' : '-- HyperStack: REPLICA IDENTITY DEFAULT is sufficient (re-fetch architecture).'}

-- Truncate to ensure idempotent seeding (framing A and B share the Supabase DB)
TRUNCATE public.bench_items RESTART IDENTITY;
`;
  psqlDb(connStr, sql, pgPass);
  console.log(`[seed] Schema applied to ${label}.`);
}

// ── User seeding ──────────────────────────────────────────────────────────────

async function signupUser(authUrl, email, password) {
  const res = await httpPost(`${authUrl}/signup`, { email, password });
  if (!res.ok) {
    throw new Error(`Signup failed for ${email}: HTTP ${res.status} — ${JSON.stringify(res.json)}`);
  }
  const { access_token, user } = res.json;
  if (!user?.id) {
    throw new Error(`Signup response missing user.id for ${email}: ${JSON.stringify(res.json)}`);
  }
  // access_token may be null if email confirmation is required; handle gracefully
  const jwt = access_token ?? null;
  return { email, userId: user.id, jwt };
}

async function seedUsers(label, authUrl, emailPrefix, k) {
  console.log(`[seed] Creating ${k} users for ${label} at ${authUrl} ...`);
  const users = [];
  for (let i = 0; i < k; i++) {
    const email = `${emailPrefix}_${i}@bench.test`;
    try {
      const u = await signupUser(authUrl, email, BENCH_USER_PASSWORD);
      users.push(u);
      process.stdout.write(`\r[seed] ${label}: ${i + 1}/${k} users created`);
    } catch (e) {
      // User may already exist from a previous seed run — try signing in
      const signinRes = await httpPost(`${authUrl}/token?grant_type=password`, {
        email,
        password: BENCH_USER_PASSWORD,
      });
      if (signinRes.ok && signinRes.json?.access_token) {
        users.push({
          email,
          userId: signinRes.json.user?.id,
          jwt: signinRes.json.access_token,
        });
        process.stdout.write(`\r[seed] ${label}: ${i + 1}/${k} users (pre-existing)`);
      } else {
        console.error(`\n[seed] ERROR: Cannot create or sign in user ${email}: ${e.message}`);
        throw e;
      }
    }
  }
  console.log(`\n[seed] ${k} users ready for ${label}.`);
  return users;
}

// ── Row seeding ───────────────────────────────────────────────────────────────

function seedRows(connStr, pgPass, label, users, totalRows) {
  console.log(`[seed] Inserting ${totalRows} rows into ${label}.bench_items ...`);
  const k = users.length;
  const rowsPerUser = Math.floor(totalRows / k);
  const extra = totalRows % k;

  // Build bulk INSERT values
  const values = [];
  for (let i = 0; i < k; i++) {
    const count = rowsPerUser + (i < extra ? 1 : 0);
    for (let j = 0; j < count; j++) {
      values.push(`('${users[i].userId}', 'bench body ${i}-${j}')`);
    }
  }

  if (values.length === 0) return;

  // Split into chunks to avoid overly large SQL statements
  const CHUNK = 500;
  for (let start = 0; start < values.length; start += CHUNK) {
    const chunk = values.slice(start, start + CHUNK);
    const sql = `INSERT INTO public.bench_items (owner, body) VALUES\n${chunk.join(',\n')};`;
    psqlDb(connStr, sql, pgPass);
  }
  console.log(`[seed] ${values.length} rows inserted into ${label}.`);
}

// ── Storage bucket + objects ──────────────────────────────────────────────────

async function ensureStorageBucket(storageUrl, authHeader) {
  console.log(`[seed] Ensuring storage bucket 'bench' at ${storageUrl} ...`);
  const res = await httpPost(
    `${storageUrl}/bucket`,
    { id: 'bench', name: 'bench', public: false },
    { Authorization: authHeader }
  );
  if (res.ok || (res.status === 400 && JSON.stringify(res.json).includes('already exists'))) {
    console.log('[seed] Storage bucket ready.');
  } else if (res.status === 409) {
    console.log('[seed] Storage bucket already exists.');
  } else {
    console.warn(`[seed] Warning: bucket creation returned HTTP ${res.status}: ${JSON.stringify(res.json)}`);
  }
}

async function seedStorageObjects(storageUrl, authHeader, count) {
  console.log(`[seed] Uploading ${count} storage objects ...`);
  for (let i = 0; i < count; i++) {
    const key = `bench-object-${i}.txt`;
    const body = `bench content ${i} ${'x'.repeat(256)}`;
    const res = await fetch(`${storageUrl}/object/bench/${key}`, {
      method: 'POST',
      headers: {
        Authorization: authHeader,
        'Content-Type': 'text/plain',
      },
      body,
    });
    if (!res.ok && res.status !== 409) {
      const txt = await res.text();
      console.warn(`[seed] Warning: object upload ${key} returned HTTP ${res.status}: ${txt}`);
    }
    process.stdout.write(`\r[seed] Storage: ${i + 1}/${count}`);
  }
  console.log('\n[seed] Storage objects done.');
}

// ── Verification ──────────────────────────────────────────────────────────────

function countRows(connStr, pgPass) {
  const n = psqlDbQuery(connStr, 'SELECT COUNT(*) FROM public.bench_items', pgPass);
  return parseInt(n, 10);
}

// ── Main ──────────────────────────────────────────────────────────────────────

const args = parseArgs();
const { framing, k, r, s } = args;

const envVars = readEnvFile(framing);

const HS_BASE_URL    = envVars['HS_BASE_URL'];
const HS_SERVICE_KEY = envVars['HS_SERVICE_KEY'];
const HS_DB          = envVars['HS_DB'];
const HS_PG_PORT     = envVars['HS_PG_PORT'];   // HyperStack's own pg17 container port
const HS_PG_PASS     = envVars['HS_PG_PASS'];   // HyperStack pg superuser password

const SB_AUTH_URL    = envVars['SB_AUTH_URL_HOST'];
const SB_REST_URL    = envVars['SB_REST_URL_HOST'];
const SB_SERVICE_JWT = envVars['SB_SERVICE_JWT'];
const SB_DB          = envVars['SB_DB'] ?? 'postgres';

if (!HS_BASE_URL || !HS_DB) {
  console.error('[seed] Missing HS_BASE_URL or HS_DB in env file. Run framing up first.');
  process.exit(1);
}

// Connection strings for psql admin operations
const HS_CONN = `host=localhost port=${HS_PG_PORT} user=postgres dbname=${HS_DB}`;
const SB_CONN = `host=${SB_PG_HOST} port=${SB_PG_PORT} user=${SB_PG_USER} dbname=${SB_DB}`;

console.log(`[seed] Framing ${framing}: HS_DB=${HS_DB} (pg:${HS_PG_PORT}), SB_DB=${SB_DB} (pg:${SB_PG_PORT})`);
console.log(`[seed] Fixture params: K=${k} users, R=${r} rows, S=${s} storage objects`);

// 1. Apply schema
applyBenchSchema(HS_CONN, HS_PG_PASS, `HyperStack DB=${HS_DB}`, false);
applyBenchSchema(SB_CONN, SB_PG_PASS, `Supabase DB=${SB_DB}`, true);

// 1b. Trigger HyperStack schema reload so bench_items becomes visible via REST API
{
  const HS_ADMIN_TOKEN = envVars['HS_ADMIN_TOKEN'];
  console.log('[seed] Triggering HyperStack schema reload ...');
  try {
    const reloadRes = await fetch(`${HS_BASE_URL}/admin/v1/reload-schema`, {
      method: 'POST',
      headers: {
        'x-admin-token': HS_ADMIN_TOKEN,
        'content-type': 'application/json',
      },
      signal: AbortSignal.timeout(10_000),
    });
    if (reloadRes.ok) {
      console.log('[seed] HyperStack schema reloaded — bench_items now visible.');
    } else {
      console.warn(`[seed] Schema reload returned HTTP ${reloadRes.status}`);
    }
  } catch (e) {
    console.warn(`[seed] Schema reload request failed: ${e.message}`);
  }
}

// 2. Seed users via real signup endpoints
const HS_AUTH_URL = `${HS_BASE_URL}/auth/v1`;
const hsUsers = await seedUsers('hyperstack', HS_AUTH_URL, 'hs_bench_user', k);
const sbUsers = await seedUsers('supabase',   SB_AUTH_URL,  'sb_bench_user', k);

// 3. Seed rows (via psql admin — fast bulk INSERT)
seedRows(HS_CONN, HS_PG_PASS, `HyperStack(${HS_DB})`, hsUsers, r);
seedRows(SB_CONN, SB_PG_PASS, `Supabase(${SB_DB})`, sbUsers, r);

// 4. Ensure storage buckets
const HS_STORAGE_URL = `${HS_BASE_URL}/storage/v1`;
const SB_STORAGE_URL = `http://localhost:55421/storage/v1`;

await ensureStorageBucket(HS_STORAGE_URL, `Bearer ${HS_SERVICE_KEY}`);
await ensureStorageBucket(SB_STORAGE_URL, `Bearer ${SB_SERVICE_JWT}`);

// 5. Seed storage objects
await seedStorageObjects(HS_STORAGE_URL, `Bearer ${HS_SERVICE_KEY}`, s);
await seedStorageObjects(SB_STORAGE_URL, `Bearer ${SB_SERVICE_JWT}`, s);

// 5b. Realtime setup (idempotent)
// HyperStack: enable realtime on bench_items via realtime.enable()
// Supabase:   add bench_items to the supabase_realtime publication
console.log('[seed] Setting up realtime for bench_items ...');

try {
  psqlDb(HS_CONN, "SELECT realtime.enable('public.bench_items');", HS_PG_PASS);
  console.log('[seed] HyperStack realtime enabled for bench_items.');
} catch (e) {
  const msg = e.message ?? String(e);
  if (msg.includes('already') || msg.includes('ERROR:  0')) {
    console.log('[seed] HyperStack realtime already enabled for bench_items (OK).');
  } else {
    console.warn(`[seed] Warning: HyperStack realtime enable: ${msg.split('\n')[0]}`);
  }
}

try {
  psqlDb(SB_CONN, 'ALTER PUBLICATION supabase_realtime ADD TABLE public.bench_items;', SB_PG_PASS);
  console.log('[seed] Supabase bench_items added to supabase_realtime publication.');
} catch (e) {
  const msg = e.message ?? String(e);
  if (msg.includes('already') || msg.includes('relation') || msg.includes('ERROR')) {
    console.log('[seed] Supabase bench_items already in publication or not applicable (OK).');
  } else {
    console.warn(`[seed] Warning: Supabase realtime publication: ${msg.split('\n')[0]}`);
  }
}

// 6. Verify row counts (fairness assertion)
const hsCount = countRows(HS_CONN, HS_PG_PASS);
const sbCount = countRows(SB_CONN, SB_PG_PASS);
console.log(`[seed] Row counts: HyperStack=${hsCount}, Supabase=${sbCount}`);

if (hsCount !== sbCount) {
  console.error(`[seed] ABORT: Row count mismatch! HyperStack=${hsCount} != Supabase=${sbCount}`);
  console.error('[seed] Both targets must have identical fixture data. Fix seeding before benchmarking.');
  process.exit(1);
}
console.log('[seed] Row count assertion passed — fixtures are identical.');

// 7. Write seed output
const seedData = {
  framing,
  created_at: new Date().toISOString(),
  fixture: { k, r, s },
  hyperstack: {
    db: HS_DB,
    pg_port: HS_PG_PORT,
    auth_url: HS_AUTH_URL,
    row_count: hsCount,
    users: hsUsers,
  },
  supabase: {
    db: SB_DB,
    pg_port: SB_PG_PORT,
    auth_url: SB_AUTH_URL,
    row_count: sbCount,
    users: sbUsers,
  },
};

const outDir = path.join(BENCH_DIR, 'results');
mkdirSync(outDir, { recursive: true });
const outPath = path.join(outDir, `framing-${framing}-seed.json`);
writeFileSync(outPath, JSON.stringify(seedData, null, 2), 'utf8');
console.log(`[seed] Seed data written to ${outPath}`);
console.log('[seed] Done.');
