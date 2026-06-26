#!/usr/bin/env node
// bench/targets/manifest.mjs — Capture run metadata to a JSON manifest.
//
// Usage:
//   node bench/targets/manifest.mjs \
//     --runid <ID> \
//     --timestamp <ISO> \
//     --framing <a|b> \
//     --fixture-k <K> \
//     --fixture-r <R> \
//     --fixture-s <S>

import { execSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '../..');
const BENCH_DIR = path.join(REPO_ROOT, 'bench');

// ── Arg parsing ───────────────────────────────────────────────────────────────

function parseArgs() {
  const args = process.argv.slice(2);
  const result = {};
  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--runid':        result.runid     = args[++i]; break;
      case '--timestamp':    result.timestamp = args[++i]; break;
      case '--framing':      result.framing   = args[++i]; break;
      case '--fixture-k':    result.k         = parseInt(args[++i], 10); break;
      case '--fixture-r':    result.r         = parseInt(args[++i], 10); break;
      case '--fixture-s':    result.s         = parseInt(args[++i], 10); break;
      default:
        console.error(`Unknown arg: ${args[i]}`);
        process.exit(1);
    }
  }
  for (const req of ['runid', 'timestamp', 'framing', 'k', 'r', 's']) {
    if (result[req] === undefined) {
      console.error(`Missing required arg: --${req}`);
      process.exit(1);
    }
  }
  return result;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const PSQL_PATH = '/opt/homebrew/opt/libpq/bin/psql';
const PG_ENV = {
  ...process.env,
  PATH: `/opt/homebrew/opt/libpq/bin:${process.env.PATH ?? '/usr/bin:/bin'}`,
  PGPASSWORD: 'postgres',
};

const PG_SETTINGS_QUERY =
  "SELECT json_agg(row_to_json(t)) FROM " +
  "(SELECT name,setting FROM pg_settings WHERE name IN " +
  "('shared_buffers','work_mem','max_connections','shared_preload_libraries','session_preload_libraries')" +
  " ORDER BY name) t";

function run(cmd, opts = {}) {
  try {
    return execSync(cmd, { encoding: 'utf8', env: PG_ENV, ...opts }).trim();
  } catch (e) {
    return `ERROR: ${e.message.split('\n')[0]}`;
  }
}

function runJSON(cmd, opts = {}) {
  try {
    return JSON.parse(run(cmd, opts));
  } catch {
    return null;
  }
}

/** Determine which bench DB/port to query based on framing env vars. */
function benchDb(framing) {
  return framing === 'a' ? 'bench_hs' : 'bench_hs_b';
}
function benchPgPort(envVars) {
  return envVars['HS_PG_PORT'] ?? '54330';
}
function benchPgPass(envVars) {
  return envVars['HS_PG_PASS'] ?? 'bench_hs_pgpass';
}

/** Read a value from the framing env file. */
function readEnvFile(framing) {
  const envPath = path.join(BENCH_DIR, 'results', `framing-${framing}.env`);
  try {
    const raw = readFileSync(envPath, 'utf8');
    const env = {};
    for (const line of raw.split('\n')) {
      const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
      if (m) env[m[1]] = m[2];
    }
    return env;
  } catch {
    return {};
  }
}

/** Get HyperStack version from Cargo.toml workspace.package.version */
function hsVersion() {
  try {
    const toml = readFileSync(path.join(REPO_ROOT, 'Cargo.toml'), 'utf8');
    const m = toml.match(/^\[workspace\.package\][^\[]*version\s*=\s*"([^"]+)"/ms);
    return m ? m[1] : 'unknown';
  } catch {
    // Fallback: try binary --version output indirectly via binary path stat
    return 'unknown';
  }
}

/** Inspect a docker container and return image+id. */
function inspectContainer(name) {
  const out = run(`docker inspect --format '{{.Config.Image}} {{.Id}}' "${name}" 2>/dev/null`);
  if (out.startsWith('ERROR') || out === '') {
    return { image: 'not-found', id: 'not-found' };
  }
  const parts = out.split(' ');
  return { image: parts[0] ?? 'unknown', id: parts[1] ?? 'unknown' };
}

// ── Main ──────────────────────────────────────────────────────────────────────

const args = parseArgs();
const { runid, timestamp, framing, k, r, s } = args;

const db = benchDb(framing);
const envVars = readEnvFile(framing);
const hsPgPort = benchPgPort(envVars);
const hsPgPass = benchPgPass(envVars);

// Host info
const cpuCount = parseInt(run('sysctl -n hw.ncpu'), 10) || 0;
const ramBytesStr = run('sysctl -n hw.memsize');
const ramBytes = parseInt(ramBytesStr, 10) || 0;

// Postgres versions
const hsPgEnv = { ...PG_ENV, PGPASSWORD: hsPgPass };
const hsPgVersion = run(
  `${PSQL_PATH} "host=localhost port=${hsPgPort} user=postgres dbname=${db}" -tAc "SELECT version()"`,
  { env: hsPgEnv }
);
const sbPgVersion = run(
  `${PSQL_PATH} "host=localhost port=54322 user=postgres dbname=postgres" -tAc "SELECT version()"`,
  { env: PG_ENV }
);
const pgVersion = `HS: ${hsPgVersion} | SB: ${sbPgVersion}`;

// HyperStack version
const hyperStackVersion = hsVersion();

// Container metadata
const CONTAINERS = [
  'supabase_kong_SDTool',
  'supabase_auth_SDTool',
  'supabase_rest_SDTool',
  'supabase_realtime_SDTool',
  'supabase_storage_SDTool',
  'supabase_db_SDTool',
];

const containers = {};
for (const name of CONTAINERS) {
  containers[name] = inspectContainer(name);
}

// pg_settings for both instances (M1)
function parsePgSettings(raw) {
  if (!raw || raw.startsWith('ERROR')) return `ERROR: ${raw}`;
  try { return JSON.parse(raw); } catch { return `PARSE_ERROR: ${raw}`; }
}

const hsPgSettingsRaw = run(
  `${PSQL_PATH} "host=localhost port=${hsPgPort} user=postgres dbname=${db}" -tAc "${PG_SETTINGS_QUERY}"`,
  { env: hsPgEnv }
);
const sbPgSettingsRaw = run(
  `${PSQL_PATH} "host=localhost port=54322 user=postgres dbname=postgres" -tAc "${PG_SETTINGS_QUERY}"`,
  { env: PG_ENV }
);
const hsPgSettings = parsePgSettings(hsPgSettingsRaw);
const sbPgSettings = parsePgSettings(sbPgSettingsRaw);

// ── Fairness metadata (C2, I1, I2) ───────────────────────────────────────────
//
// C2 — Password hash algorithm mismatch:
//   HyperStack uses Argon2id (argon2 crate v0.5 defaults: m=19456 KiB ~19 MB,
//   t=2 iterations, p=1 parallelism). This is a memory-hard, CPU+RAM intensive KDF.
//   GoTrue (Supabase auth v2.188.1) uses bcrypt with cost=10 by default.
//   Bcrypt is CPU-only (no large memory requirement). The two algorithms have
//   fundamentally different CPU and memory profiles; auth signin/signup latency
//   numbers are NOT directly comparable between the two sides.
//
// I1 — Network path:
//   k6 -> HyperStack: host.docker.internal (container-to-host extra hop).
//   k6 -> Supabase:   container-to-container on supabase_network_SDTool (direct).
//   This asymmetry penalizes HyperStack. cross was not available; containerization
//   deferred (see FAIRNESS.md §I1). HyperStack latency = conservative lower bound.
//
// I2 — Connection pool sizes:
//   HyperStack authn pool: 16 connections (Db::connect max_size=16, lib.rs:86).
//   HyperStack admin pool:  8 connections (Db::connect max_size=8,  lib.rs:67).
//   PostgREST (Supabase):  default pool size = 10 (PGRST_DB_POOL not set).
//   GoTrue (Supabase):     no explicit pool cap (uses Go database/sql defaults).
//   Pools are NOT equalized — see FAIRNESS.md §I2 for caveats.

const fairness = {
  engine_identity: {
    framing_a_controls: 'gateway_overhead_only',
    note: 'NOT identical pg engine — separate instances, different builds and shared_preload_libraries',
    hyperstack_pg: 'vanilla postgres:17.10 (Docker Hub postgres:17, Debian)',
    supabase_pg: 'public.ecr.aws/supabase/postgres:17.6.1.106 (Supabase fork)',
    shared_instance_impossible_reason:
      'Cluster-wide role-namespace collision: authenticator/anon/authenticated/service_role ' +
      'are reserved by supautils; ALTER ROLE authenticator PASSWORD would break PostgREST live pool.',
  },
  password_hash_algorithms: {
    hyperstack: {
      algorithm: 'argon2id',
      crate: 'argon2@0.5',
      m_cost_kib: 19456,
      m_cost_mb_approx: 19,
      t_cost_iterations: 2,
      parallelism: 1,
      note: 'memory-hard KDF; CPU + RAM intensive',
    },
    supabase_gotrue: {
      algorithm: 'bcrypt',
      version: 'v2.188.1',
      cost: 10,
      note: 'CPU-only KDF; no large memory requirement; default GoTrue cost',
    },
    comparability: 'NOT_COMPARABLE — different algorithms with different CPU+memory profiles',
    caveat: 'Auth scenario (Task 3) latency difference reflects algorithm choice, not solely implementation quality',
  },
  network_topology: {
    k6_to_hyperstack: 'container -> host.docker.internal -> host binary (extra hop)',
    k6_to_supabase: 'container -> container on supabase_network_SDTool (direct)',
    asymmetry_penalizes: 'HyperStack',
    hyperstack_latency_interpretation: 'conservative lower bound (extra hop included)',
    containerization_status: 'not_attempted — cross not available; Dockerfile build deferred',
  },
  connection_pools: {
    hyperstack_authn_pool: 16,
    hyperstack_admin_pool: 8,
    postgrest_pool: 'default=10 (PGRST_DB_POOL not set)',
    gotrue_pool: 'uncapped (Go database/sql defaults)',
    equalized: false,
    note: 'Pool sizes not equalized; see FAIRNESS.md §I2',
  },
};

const manifest = {
  runid,
  timestamp,
  created_at: new Date().toISOString(),
  framing,
  fixture: { k, r, s },
  host: {
    cpu_count: cpuCount,
    ram_bytes: ramBytes,
  },
  postgres_version: pgVersion,
  hyperstack_version: hyperStackVersion,
  supabase_containers: containers,
  k6_image: 'grafana/k6',
  env: {
    hs_base_url: envVars['HS_BASE_URL'] ?? '',
    hs_pg_port: hsPgPort,
    sb_rest_url_k6: envVars['SB_REST_URL_K6'] ?? '',
    sb_auth_url_k6: envVars['SB_AUTH_URL_K6'] ?? '',
    hs_db: envVars['HS_DB'] ?? '',
    sb_db: envVars['SB_DB'] ?? '',
  },
  pg_settings: {
    hyperstack: hsPgSettings,
    supabase: sbPgSettings,
  },
  fairness,
};

const outDir = path.join(BENCH_DIR, 'results', 'raw');
mkdirSync(outDir, { recursive: true });
const outPath = path.join(outDir, `manifest-${runid}.json`);
writeFileSync(outPath, JSON.stringify(manifest, null, 2), 'utf8');

console.log(`[manifest] Written to ${outPath}`);
console.log(JSON.stringify(manifest, null, 2));
