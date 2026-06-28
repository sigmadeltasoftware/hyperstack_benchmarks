# HyperStack vs Supabase — Benchmark Package

A self-contained, reproducible benchmark comparing **HyperStack v1.2.1** (a single-binary,
Rust-based Supabase-compatible backend over Postgres) against a full local **Supabase**
stack, across REST, Auth, Realtime, Storage, and Footprint.

This package contains the prebuilt HyperStack binary, the benchmark harness, the corrected
raw result data, and the two authoritative write-ups (`RESULTS.md` + `FAIRNESS.md`).

---

## Headline results

(Framing B = both targets behind a gateway — the more symmetric comparison. Full detail,
both framings, and every confound: `RESULTS.md` / `FAIRNESS.md`.)

| Dimension | HyperStack | Supabase | Result |
|-----------|-----------:|---------:|--------|
| REST read — small (20-row, symmetric) | 3,369 | 3,394 | tie (SB +0.7%); **HS wins p95/p99** |
| **REST read — large (1000-row, symmetric)** | **838** | 727 | **HS +15.3%**, lower at every percentile |
| **REST insert — RAW (req/s, plain table)** | **2,176** | 1,773 | **HS +23%** |
| **Realtime write-tax (architectural)** | **3.7–3.85×** | **~1.00×** | HS pays for pg_notify-per-row; SB ~free (WAL) |
| Auth sign-in (req/s) | 7.5 | 7.2 | parity (KDF-bounded) |
| Auth sign-up (req/s) | 2.6 | 7.1 | SB wins (HS serialises hashing) |
| Realtime delivery p50 | 10–11 ms | 258–261 ms | **HS ~24×** lower latency |
| Realtime fanout | ≥50 subs, 0 drop | 25 subs (31% drop @ N=50) | **HS** |
| Storage throughput (successful req/s) | 401–422 | 55–124 | **HS ~3.4–7.3×** (SB total incl. failed uploads: 196–239) |
| Storage reliability (isolated) | 5/5 pass | 0–1/5 pass | **HS** (SB upload saturates) |
| Idle RSS (minimal-prod) | 6.4 MB | 1,020 MB | **HS ~159×** smaller |
| Under-load RSS | 12.4 MB | 2,812 MB (full stack) | **HS ~227×** smaller |
| On-disk | 4.94 MB binary | 3,532 MB images | **HS ~715×** smaller |

**Two corrections vs earlier drafts** (see the correction notice in `RESULTS.md`):
1. The INSERT headline now uses a **plain, non-realtime table** — the old "Supabase ~3×
   faster" number was actually HyperStack's realtime *write-tax* (reported separately).
2. Storage was **re-run isolated** from a fresh Supabase storage container.

---

## What's in this package

```
hyperstack             # prebuilt HyperStack v1.2.1 binary (x86_64-apple-darwin)
hyperstack.sha256      # checksum of the binary
binary-info.txt        # version, target triple, size, sha256, platform notes
RESULTS.md             # full benchmark write-up (all scenarios, both framings)
FAIRNESS.md            # every known confound + the corrections, authoritative
README.md              # this file
results/raw/           # corrected raw k6 / realtime / footprint JSON (196 files)
harness/               # the benchmark harness, adapted to use the bundled binary
  run.sh               #   orchestrator (cargo build replaced by bundled-binary check)
  config.sh            #   config (HS_BINARY -> bundled binary; sb secret redacted)
  targets/             #   framing-a.sh / framing-b.sh (bring up HS + point harness)
  scenarios/           #   k6 + node drivers incl. rest-insert-plain.js (fair insert)
  fixtures/            #   seed.mjs (creates tables, users, rows, storage objects)
  footprint/           #   measure.sh (RSS / disk / cold-start)
  report/              #   aggregate.mjs (re-derive k6 medians from results/raw)
  run_plain_insert.sh  #   driver: fair raw insert (bench_items_plain)
  run_rt_insert.sh     #   driver: realtime write-tax (bench_items)
  run_iso_storage.sh   #   driver: isolated storage
  stats_k6.py          #   small stats helper for the raw JSON
```

---

## Platform note (important)

- The bundled binary is **`x86_64-apple-darwin` (Intel Mac)**. It will **not** run on
  Apple Silicon (arm64) or Linux without a rebuild from HyperStack source.
- The benchmark server is an **Intel Mac running macOS**, with **OrbStack** providing
  Docker (`docker` resolves to OrbStack's CLI). It is **not** colima and **not** Docker
  Desktop, though any Docker-compatible engine should work for reproduction.

---

## Prerequisites

1. **Docker** — OrbStack (used here), Docker Desktop, or colima. The harness runs k6 and
   the Postgres/Supabase containers under it.
2. **Supabase CLI** — `supabase start` brings up the local Supabase stack
   (`https://supabase.com/docs/guides/local-development`). This benchmark used a project
   named `sb-bench`; container names in the harness are `supabase_*_sb-bench`. Adjust the
   `SB_*_CONTAINER` names in `harness/config.sh` to match your local project name.
3. **`grafana/k6`** Docker image — pulled automatically on first run (`docker pull grafana/k6`).
4. **The bundled binary** (`./hyperstack`) — no `cargo`/source needed; the harness uses it
   directly (the stale-binary guard was replaced with a bundled-binary check).
5. **Node.js** (for `harness/fixtures/seed.mjs`, `harness/report/aggregate.mjs`, and the
   realtime driver) and **psql** (the harness expects a psql at `~/bin/psql-bench`; see
   `config.sh`).

---

## Reproduce

From the package root:

```bash
# 0. Verify the binary
shasum -a 256 -c hyperstack.sha256

# 1. Start the local Supabase stack (project "sb-bench"), and confirm containers are up
supabase start            # in your sb-bench project dir
docker ps --format '{{.Names}}' | grep sb-bench

# 2. Point config at the bundled binary + your stack (edit harness/config.sh if your
#    Supabase project name / container names / ports differ from sb-bench)

# 3. Bring up HyperStack for a framing (writes harness/../results/framing-<a|b>.env)
bash harness/targets/framing-a.sh up      # framing A (Kong bypassed)
#   or
bash harness/targets/framing-b.sh up      # framing B (via Kong)

# 4. Seed fixtures (fresh JWTs + identical 100-row fixtures on both targets)
node harness/fixtures/seed.mjs --framing a --users 10 --rows 100 --storage-objects 5

# 5. Run scenarios (N=5), e.g. the full REST + Auth + Storage sweep:
bash harness/run.sh --framing both --scenario rest    --runs 5
bash harness/run.sh --framing both --scenario auth    --runs 5
bash harness/run.sh --framing both --scenario storage --runs 5
bash harness/run.sh                 --scenario footprint

# 6. The CORRECTED runs specifically:
#    - fair raw insert (plain table):   bash harness/run_plain_insert.sh
#    - realtime write-tax (bench_items):bash harness/run_rt_insert.sh
#    - isolated storage (reset SB first; see RESULTS.md §2f / FAIRNESS S1):
#                                        bash harness/run_iso_storage.sh

# 7. Summaries from the raw JSON:
python3 harness/stats_k6.py <run_id> rest-insert-plain rps
node harness/report/aggregate.mjs       # re-derive k6 medians (reference)
```

> The `run_*_insert.sh` / `run_iso_storage.sh` drivers and `stats_k6.py` reference
> absolute `~/HyperStack/...` paths from the original server layout; adjust the `cd` /
> `RAW` paths to your checkout if you re-run them. `results/raw/` already contains the
> exact JSON these produced.

---

## Secrets disclosure (no real secrets in this package)

All credentials in `harness/config.sh` are **throwaway local-dev values only**:

- `SB_ANON_JWT` / `SB_SERVICE_JWT` — the **public Supabase demo tokens** (issuer
  `supabase-demo`). These are the well-known anon + service_role keys shipped in every
  local Supabase stack and published in Supabase's own documentation. Not secret.
- `HS_JWT_SECRET`, `HS_SERVICE_KEY`, `HS_ADMIN_TOKEN`, `HS_AUTHENTICATOR_PASSWORD` —
  literal placeholder strings (`bench-*`, `benchauthpass`) for the throwaway local HS
  instance.
- `BENCH_PG_PASSWORD=postgres` — the local Postgres default.
- `SB_SECRET_KEY` — **redacted** in this package (`REDACTED_REGENERATE_FROM_supabase_start_OUTPUT`).
  It was a local `sb-bench` dev key; regenerate your own from `supabase start` output.

No production secrets, no private keys, and **no per-user fixture JWTs** (the live
`results/framing-*.env` and `framing-*-seed.json` files were deliberately excluded). No
HyperStack **source code** is included — only the prebuilt binary. The `results/raw/` JSON
were scanned and contain no JWTs or keys.

---

## Read next

- **`RESULTS.md`** — the full results, both framings, with the correction notice and the
  hostile-skeptic "Where HyperStack loses / ties" section.
- **`FAIRNESS.md`** — every confound (C1, C2, I1, I2, C3, **W1** write-tax, **S1** storage
  saturation, F2/F3/F4 footprint, ENV/JWT/FRAMING notes), with direction-of-bias for each.
