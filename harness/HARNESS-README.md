# bench/ — HyperStack vs Supabase Benchmark Harness

> **Package note.** The authoritative setup + reproduce steps for this published
> package are in [`../README.md`](../README.md): a **prebuilt x86_64 binary** (no
> source), a **Supabase CLI** stack (project `sb-bench`), on **x86_64 macOS +
> OrbStack**. Some container names below (`*_SDTool`) and host ports describe the
> harness's *original in-repo dev environment* — adjust them to your stack (the
> published runs used `*_sb-bench`). This file documents the harness internals.

Reproduce-yourself runbook. The harness measures REST, Auth, Realtime, Storage,
and Footprint across two framings (Kong-bypassed vs full stack).

For the full results and methodology, see [`bench/RESULTS.md`](./RESULTS.md).
For all known fairness gaps, see [`bench/FAIRNESS.md`](./FAIRNESS.md).

---

## Prerequisites

### 1. Supabase local dev stack (SDTool)

The harness expects the Supabase SDTool local stack running with the `SDTool`
project name (container suffix `_SDTool`).

```bash
# Install Supabase CLI if not present
npm install -g supabase

# Start the local stack (project name = SDTool)
npx supabase start --project-id SDTool
# OR use the Supabase Desktop app with project named "SDTool"
```

Required containers (check with `docker ps`):
- `supabase_kong_SDTool` — API gateway (port 54321)
- `supabase_rest_SDTool` — PostgREST (port 3000 inside network)
- `supabase_auth_SDTool` — GoTrue (port 9999 inside network)
- `supabase_realtime_SDTool` — Elixir realtime
- `supabase_storage_SDTool` — Storage API
- `supabase_db_SDTool` — Postgres (port 54322 on host)

### 2. HyperStack binary

This package ships a **prebuilt** binary — no source or `cargo` needed:

```bash
# The binary is bundled at the package root; config.sh points HS_BINARY at it.
../hyperstack --version
# HyperStack v1.2.1   (x86_64-apple-darwin)
```

Verify integrity against `../hyperstack.sha256` before running (see `../README.md`).

### 3. Docker + grafana/k6

```bash
docker pull grafana/k6
```

### 4. Node.js 18+

Required for the realtime driver, seed scripts, and selfcheck:
```bash
node --version   # should be v18 or later
```

Required npm packages (install from repo root):
```bash
cd bench && npm install   # installs @supabase/supabase-js and ws
```

---

## Directory Layout

```
bench/
  run.sh                    — Main orchestration script
  config.sh                 — Shared env vars and defaults
  selfcheck.mjs             — Pre-run sanity check (REST, Auth, Realtime)
  FAIRNESS.md               — All known confounds (read before citing numbers)
  RESULTS.md                — Generated report (DO NOT edit manually)
  fixtures/
    seed.mjs                — Seeds bench_items + users in both targets
  scenarios/
    rest-select.js          — k6: RLS-filtered GET
    rest-insert.js          — k6: authed POST with RLS WITH CHECK
    auth-signin.js          — k6: POST /auth/v1/token (password grant)
    auth-signup.js          — k6: POST /auth/v1/signup (new user)
    storage-updownload.js   — k6: upload + download 64KB + 1MB objects
    realtime-driver.mjs     — Node: delivery latency + fanout ramp
  targets/
    framing-a.sh            — Start HyperStack on a fresh pg container (framing A)
    framing-b.sh            — Start HyperStack on framing B pg container
  footprint/
    measure.sh              — Measure RAM, disk, cold-start
  results/
    raw/                    — All raw JSON output (committed)
  report/
    aggregate.mjs           — Reads raw/ → generates RESULTS.md
```

---

## Quick Start

```bash
# 1. Ensure Supabase SDTool stack is up
docker ps | grep supabase_kong_SDTool

# 2. Build HyperStack (no-op if up to date)
cargo build --release -p hyperstack

# 3. Run the selfcheck (both targets must pass)
node bench/selfcheck.mjs

# 4. Run all scenarios (takes ~30–40 minutes total)
bash bench/run.sh --framing both --scenario rest     --runs 5
bash bench/run.sh --framing both --scenario auth     --runs 5
bash bench/run.sh --framing both --scenario realtime --runs 5
bash bench/run.sh --framing both --scenario storage  --runs 5
bash bench/run.sh --scenario footprint

# 5. Regenerate RESULTS.md
node bench/report/aggregate.mjs
```

---

## Detailed Commands

### Selfcheck

```bash
node bench/selfcheck.mjs
# Expected output: all checks pass (REST 200, Auth token, Realtime delivery)
# If any check fails, fix the underlying issue before bench runs.
```

### REST Scenarios (N=5 runs, both framings, ~12 minutes)

```bash
bash bench/run.sh --framing both --scenario rest --runs 5
```

Produces:
- `bench/results/raw/k6-{a,b}-rest-{select,insert}-{hyperstack,supabase}-{runid}-run{1..5}.json`

### Auth Scenarios (N=5 runs, both framings, ~18 minutes)

```bash
bash bench/run.sh --framing both --scenario auth --runs 5
```

Note: Auth uses 5 VUs with 500ms think time (not 20 VUs like REST). This is
intentional — auth is hash-algorithm-bound (Argon2id vs bcrypt), and higher VU
counts would just queue without measuring additional throughput.

Produces:
- `bench/results/raw/k6-{a,b}-auth-{signin,signup}-{hyperstack,supabase}-{runid}-run{1..5}.json`

### Realtime Scenarios (~5 minutes)

```bash
bash bench/run.sh --framing both --scenario realtime --runs 5
```

Runs the Node.js realtime driver (not k6) at N=10 subscribers, M=5 inserts/s,
D=20s per run. Followed by a fanout ramp (N=5,10,25,50).

Both targets use the supabase-js Phoenix WebSocket path (`/realtime/v1/websocket`).

Produces:
- `bench/results/raw/rt-{a,b}-{hyperstack,supabase}-{runid}-run{1..5}.json`
- `bench/results/raw/rt-{a,b}-{hyperstack,supabase}-{runid}-fanout.json`

### Storage Scenarios (N=5 runs, both framings, ~15 minutes)

```bash
bash bench/run.sh --framing both --scenario storage --runs 5
```

Uploads and downloads 64 KB and 1 MB objects. Service-role JWTs (no per-object
RLS policies in the bench fixture). Object keys are unique per VU per iteration.

**Warning:** Supabase's local storage backend may degrade across sequential runs
as the bench bucket accumulates objects. This is a local dev-stack limitation
documented in FAIRNESS.md and RESULTS.md §2f.

Produces:
- `bench/results/raw/k6-{a,b}-storage-{hyperstack,supabase}-{runid}-run{1..5}.json`

### Footprint Measurement (~2 minutes)

```bash
# Ensure framing-A stack is up first
bash bench/run.sh --scenario footprint
```

Measures:
- Idle RSS (HyperStack: `ps -o rss=`; Supabase: `docker stats`)
- Under-load RSS (with 20-VU k6 REST load running)
- On-disk binary/image sizes
- Cold-start latency (HyperStack binary → /ready; Supabase Kong restart → /rest/v1/)

Produces:
- `bench/results/raw/footprint-a-footprint-{runid}.json`

### Regenerate RESULTS.md

```bash
node bench/report/aggregate.mjs
```

Reads all `bench/results/raw/*.json`, picks the latest canonical run per scenario,
computes medians across N runs, and writes `bench/RESULTS.md`.

---

## Run Manifest

Every bench run produces a `manifest-{runid}.json` capturing:
- Exact pg versions for both targets
- HyperStack version
- Supabase container images and IDs
- k6 image used
- Fixture parameters (K users, R rows, S storage objects)
- `pg_settings` snapshot (max_connections, shared_buffers, etc.)
- Fairness metadata (confound IDs from FAIRNESS.md)

---

## Individual Scenario Files

### k6 output format

Each `k6-*-run{N}.json` is a k6 summary export (`--summary-export`). Key fields:
```json
{
  "metrics": {
    "http_reqs": { "count": ..., "rate": ... },
    "http_req_duration": { "med": ..., "p(95)": ..., "avg": ... },
    "http_req_failed": { "value": ... },
    "storage_upload_latency_small_ms": { "p(95)": ... },
    "storage_upload_success_rate": { "value": ... }
  }
}
```

### Realtime output format

```json
{
  "target": "hyperstack",
  "protocol": "phoenix-supabase-js",
  "mode": "bench",
  "params": { "n": 10, "m": 5, "d": 20, "runs": 5 },
  "runs": [
    { "run": 1, "p50": 27, "p95": 37, "p99": 44, "drop_rate": 0.0, "total_received": 990 }
  ],
  "summary": { "p50_median": 27, "p95_median": 37, "p99_median": 44 }
}
```

### Footprint output format

```json
{
  "hyperstack": {
    "api_layer": { "idle_rss_mb": 10.2, "load_rss_mb": "12.4", "binary_size_mb": 3.9, "coldstart_ms": "595" },
    "postgres": { "idle_rss_mb": 34.7 }
  },
  "supabase": {
    "api_layer": {
      "idle_rss_total_mb": 2204.4,
      "per_container_idle_rss_mb": { "supabase_kong_SDTool": 100.4, ... },
      "coldstart_ms": "10693",
      "coldstart_method": "docker_restart_kong_to_http200"
    },
    "postgres": { "idle_rss_mb": 240.8 }
  }
}
```

---

## Fairness Notes

Read `bench/FAIRNESS.md` before citing any number. Key confounds:

- **C1:** Different Postgres instances and builds (17.10 vanilla vs 17.6.1 fork).
  Framing A controls gateway overhead, NOT engine identity.
- **C2:** Argon2id (HS) vs bcrypt-10 (SB). Auth numbers are NOT comparable.
  HyperStack signup is slower BY DESIGN (stronger hash = correct security default).
- **I1:** k6 → HyperStack traverses an extra Docker network hop vs container-to-container
  for Supabase. HyperStack numbers are a conservative lower bound.
- **F2:** Cold-start: HyperStack = full binary cold-start; Supabase = Kong-only restart
  (9 containers warm). NOT symmetric.
- **F3:** RSS measurement methods differ (ps vs cgroup). Ratios may overstate by 10–30%.
- **F4:** 216× ratio = full dev stack including Studio/Analytics. Honest production
  comparison = 73× (5 API containers only).
