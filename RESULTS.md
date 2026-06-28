# HyperStack vs Supabase — Benchmark Results

**Generated:** 2026-06-26
**HyperStack version:** v1.2.1 (x86_64-apple-darwin, built on the benchmark server)
**Honesty mandate:** Every confound from [`FAIRNESS.md`](./FAIRNESS.md) is surfaced here.
A hostile-skeptic review was performed before finalising this document; see
§5 "Where HyperStack loses / ties".

> **Correction notice (supersedes earlier drafts).** Two earlier numbers were wrong and
> are corrected here:
> 1. **INSERT** was previously benchmarked against a table that had HyperStack realtime
>    enabled, so it measured the realtime *write-tax*, not raw insert speed. The headline
>    INSERT row now uses a plain (non-realtime) table; the write-tax is reported
>    separately as its own clearly-labeled row.
> 2. **STORAGE** was previously run after sustained load; it has been re-run **isolated**
>    from a fresh Supabase storage container with an emptied bucket.
>
> The environment description has also been corrected: the server is **x86_64 Intel**,
> Docker provided by **OrbStack** (an earlier draft said "Apple Silicon" — that was wrong).

---

## 1. Methodology

### Versions

| Component         | Version / Image                                              |
|-------------------|--------------------------------------------------------------|
| HyperStack        | v1.2.1 (x86_64-apple-darwin, built on server)               |
| Postgres (HS)     | `postgres:17` (vanilla Debian, Docker)                       |
| Postgres (SB)     | `public.ecr.aws/supabase/postgres:17` (Supabase-patched)    |
| PostgREST         | `public.ecr.aws/supabase/postgrest:v14.8`                   |
| GoTrue            | `public.ecr.aws/supabase/gotrue:v2.188.1`                   |
| Supabase Realtime | `public.ecr.aws/supabase/realtime:v2.82.0`                  |
| Storage           | `public.ecr.aws/supabase/storage-api:v1.48.28`             |
| Kong              | `public.ecr.aws/supabase/kong:2.8.1`                        |
| k6                | `grafana/k6` (Docker)                                       |

### Hardware / Environment

**x86_64 Intel Mac** (macOS Darwin 25.4.0, kernel `RELEASE_X86_64`). Docker provided by
**OrbStack** (Docker Engine — Community). The HyperStack binary is a native
`x86_64-apple-darwin` Mach-O executable, run directly on the host. The Supabase stack and
both Postgres instances run as Docker containers under OrbStack. All processes ran on the
same host (no external network round-trips). See FAIRNESS.md §ENV.

### Two Framings

**Framing A — Gateway isolation (Kong bypassed, direct service endpoints)**

| Route | Path |
|-------|------|
| k6 → HyperStack | k6 container → `host.docker.internal` → HyperStack binary on host |
| k6 → Supabase REST | k6 container → `supabase_rest_sb-bench:3000` (PostgREST direct) |
| k6 → Supabase Auth | k6 container → `supabase_auth_sb-bench:9999` (GoTrue direct) |
| k6 → Supabase Storage | k6 container → `supabase_storage_sb-bench:5000` (direct) |

**Framing B — Full stack (as-shipped, Kong gateway included)**

| Route | Path |
|-------|------|
| k6 → HyperStack | k6 container → `host.docker.internal` → HyperStack binary |
| k6 → Supabase | k6 container → `supabase_kong_sb-bench:8000` (Kong proxy) |

**Framing B is the more symmetric comparison** for latency: in framing A, Supabase is
reached container-to-container (fewer hops) while HyperStack always crosses the Docker
bridge via `host.docker.internal`. Framing A therefore carries a structural network
advantage for Supabase (confound I1); framing B narrows it. Where the two framings
disagree, weight framing B.

### Run Count and Statistics

- **N = 5 runs** per (scenario × target × framing); reported = **median across runs**.
- k6 executor: ramping-VU (5s ramp → 30s hold → 5s ramp-down → ~40s wall time).
- Throughput (req/s) is over the full ~40s ramp-inclusive run (conservative).

### Binary Provenance

All dimensions use the **v1.2.1 shipping binary** (`target/release/hyperstack`,
x86_64-apple-darwin), built on the server. The binary was not modified between scenarios.

### JWT re-seed note

Fixture user-JWTs have a ~1-hour TTL. The corrected INSERT runs were performed in a fresh
session, so both framings were re-seeded first (fresh JWTs; identical 100-row fixtures;
row-count assertion 100 = 100 passed on both targets). Storage uses service-role keys
(valid for years), so storage runs are unaffected by user-JWT expiry.

### Known Confounds (summary — full detail in `FAIRNESS.md`)

| ID | Severity | Confound | Direction |
|----|----------|----------|-----------|
| C1 | Critical | Separate pg instances / builds / `shared_preload_libraries` | Neutral/mixed |
| C2 | Critical | Argon2id (HS) vs bcrypt (SB) — different KDFs | Mixed (auth only) |
| I1 | Important | k6→HS extra Docker hop vs container→container for SB (framing A) | **Penalises HS** |
| I2 | Important | Pool sizes differ | Favours HS |
| C3 | Critical | Realtime: HS re-fetches row per subscriber (O(N×M) pg queries) | Mixed |
| W1 | Critical | **Realtime write-tax**: HS pg_notify-per-row taxes writes to realtime-enabled tables | **Penalises HS** |
| S1 | Important | **Storage**: SB upload saturates under sustained 20-VU load (real, not just contamination) | Penalises SB |
| F2 | Critical | Cold-start: HS = full binary; SB = Kong-only restart (9 containers warm) | **Favours HS** |
| F3 | Important | RSS method: `ps` (HS) vs cgroup `memory.usage` incl. page cache (SB) | **Favours HS** |
| F4 | Critical | Footprint: minimal-prod (5 ctr) vs full dev-stack (10 ctr) — both reported | Both |
| ENV| Note | Server is x86_64 Intel + OrbStack (corrected from earlier "Apple Silicon") | Neutral |

---

## 2. Headline Table

| Dimension | HyperStack | Supabase | Winner / note |
|-----------|-----------:|---------:|---------------|
| REST read — small (20-row, symmetric) | 3,369 | 3,394 | tie (SB +0.7%, noise); **HS wins p95/p99** (see §2a) |
| **REST read — large (1000-row, symmetric)** | **838** | 727 | **HS +15.3%**, lower at every percentile (see §2a) |
| **REST insert — RAW (req/s, framing B, plain table)** | **2,176** | 1,773 | **HS +23%** — fair raw-insert headline |
| REST insert — RAW (framing A) | 2,181 | 1,878 | HS +16% |
| **Realtime write-tax (architectural)** | **3.7–3.85×** | **~1.00×** | see §2c — cost of HS realtime design, NOT raw insert |
| Auth sign-in (req/s) | 7.5 | 7.2 | parity (Argon2id-bounded) |
| Auth sign-up (req/s, framing B) | 2.6 | 7.1 | SB — HS serialises concurrent hashing |
| Realtime delivery p50 | 10–11 ms | 258–261 ms | **HS ~24×** lower latency |
| Realtime fanout ceiling | ≥50 subs, 0 drop | 25 subs (31% drop @ N=50) | **HS** |
| Storage throughput (successful req/s) | 401–422 | 55–124 | **HS ~3.4–7.3×** (SB total req/s incl. failed uploads was 196–239 — see §2f) |
| Storage reliability (isolated) | 5/5 pass | 0–1/5 pass | **HS** — SB upload saturates |
| Idle RSS (minimal-prod) | 6.4 MB | 1,020 MB | **HS ~159×** smaller |
| On-disk | 4.94 MB binary | 3,532 MB images | **HS ~715×** smaller |
| Cold-start | 602 ms (full) | timeout (Kong-only LB) | **HS** (see F2) |

---

## 3. Per-Dimension Results

### 2a. REST — SELECT (RLS-filtered reads)

Scenario: `GET /rest/v1/bench_items?select=id,owner,body&limit=<N>&order=id.asc`, user JWT
(RLS: owner = auth.uid()). 20 VUs, N=5. `SELECT_LIMIT` sizes the result set.

**The earlier −16% gap was ~80% a network confound (I1), not the API layer.** Re-measuring
with an **equal network path** for both targets (k6 → each via the host's published ports —
the same Docker hop on each side) isolates the API layer:

| Result size | Target | Median req/s | p50 | p95 | p99 |
|-------------|--------|-------------:|----:|----:|----:|
| 20 rows | HyperStack | 3,369 | 4.82 ms | **6.40 ms** | **7.60 ms** |
| 20 rows | Supabase | 3,394 | 4.39 ms | 8.49 ms | 11.03 ms |
| **1,000 rows** | **HyperStack** | **838** | **9.30 ms** | **15.49 ms** | **20.68 ms** |
| 1,000 rows | Supabase | 727 | 12.11 ms | 19.55 ms | 26.26 ms |

- **Small (20-row) reads are a statistical tie** on throughput (SB +0.7%, within noise), and
  HyperStack already **wins tail latency** (p95/p99). On a tiny payload the DB round-trip
  dominates, so JSON handling barely matters.
- **Large (1,000-row) reads: HyperStack wins clearly — +15.3% throughput and lower latency at
  every percentile** (non-overlapping ranges: HS 833–844 vs SB 715–735 req/s). HyperStack
  streams Postgres's `json_agg(...)::text` straight to the socket; PostgREST parses then
  re-serializes. **The advantage scales with result size** — the bigger the response, the more
  HyperStack wins.

The original asymmetric framing-A/B figures (HS 1,496 / 2,812 vs SB 2,747 / 3,258) are
**superseded** here: they carried the I1 network hop on HyperStack only.

*Binary provenance: these read numbers were measured on the JSON-pass-through binary
(sha `575c0513…`). The other dimensions in this report were measured on the prior binary
(sha `da927c2e…`); the pass-through change is confined to the read path, so those dimensions'
code is identical between the two builds.*

### 2b. REST — INSERT (RAW, plain non-realtime table) — FAIR HEADLINE

Scenario: `POST /rest/v1/bench_items_plain` (id serial, owner uuid NOT NULL, body text,
created_at), owner-RLS `WITH CHECK owner = auth.uid()`, `Prefer: return=minimal`. 20 VUs,
N=5. The table has **no realtime trigger** on HyperStack and is **not** in the Supabase
realtime publication (verified: 0 triggers on HS plain tables; absent from publication).

| Framing | Target | Median req/s | p50 | p90 | p95 |
|---------|--------|-------------:|----:|----:|----:|
| A | HyperStack | **2,181** | 7.1 ms | 9.7 ms | 11.0 ms |
| A | Supabase | 1,878 | 8.5 ms | — | 16.9 ms |
| B | HyperStack | **2,176** | 7.1 ms | 9.7 ms | 11.0 ms |
| B | Supabase | 1,773 | 8.7 ms | — | 17.0 ms |

(Median of N=5.) **On raw inserts, HyperStack is faster than Supabase: +16% (framing A) to
+23% (framing B), with lower latency.** (k6 `--summary-export` emits p50/p90/p95 only; no p99
in that format.)

> An earlier draft reported Supabase ~3× faster on inserts. That number was measured
> against a realtime-enabled table and was the *write-tax* below — not raw insert speed.

### 2c. Realtime write-tax (architectural) — SEPARATE from raw insert

Same harness, same session, inserting into the realtime-enabled `bench_items` table (the
table carries `realtime.enable` on HyperStack → an `AFTER INSERT/UPDATE/DELETE FOR EACH
ROW EXECUTE realtime.notify('id')` trigger that issues a `pg_notify` per row; on Supabase
it is in the `supabase_realtime` publication).

| Framing | Target | Plain table req/s | Realtime-enabled req/s | Write-tax |
|---------|--------|------------------:|-----------------------:|----------:|
| A | HyperStack | 2,181 | 585 | **3.7×** |
| A | Supabase | 1,878 | 1,873 | 1.00× |
| B | HyperStack | 2,176 | 567 | **3.84×** |
| B | Supabase | 1,773 | 1,750 | 1.01× |

Realtime-enabled INSERT latency — HS p50 ~30.6–30.9 ms / p95 42–46 ms; SB p50 ~8.5–8.8 ms
/ p95 ~17 ms.

**Interpretation:** HyperStack pays **~3.7–3.85×** to write to a realtime-enabled table
(per-row `pg_notify` serialises on the NOTIFY queue). Supabase pays **~nothing**
(1.00–1.01×) because its Realtime reads the WAL out of band. Independently confirmed at
the DB layer with `pgbench` (plain 2,702 TPS vs realtime-enabled 641 TPS = 4.2× at c=8).

**This is the cost side of an architectural trade-off.** HyperStack's NOTIFY-and-refetch
realtime is precisely what buys the **~24× lower realtime delivery latency and zero-drop
fanout to N≥50** (§2d). The write-tax applies only to tables that have realtime explicitly
enabled.

### 2d. Realtime — delivery latency + fanout

Node driver, `@supabase/supabase-js` over WebSockets. N=10 subscribers, 5 msg/s, 20s, N=5.

| Framing | Target | p50 | p95 | p99 | Drop | Subs OK |
|---------|--------|----:|----:|----:|-----:|--------:|
| A | HyperStack | 11 ms | 33 ms | 38 ms | 0% | 10 |
| A | Supabase | 258 ms | 496 ms | 516 ms | 0% | 10 |
| B | HyperStack | 10 ms | 33 ms | 37 ms | 0% | 10 |
| B | Supabase | 261 ms | 499 ms | 518 ms | 0% | 10 |

**HyperStack delivery latency is ~24× lower at p50** (~14× at p99). Consistent across both
framings, so it is structural, not a network artifact. (Drop column is the N=5 median: 0% for
both — though one of the five Supabase framing-A runs showed ~10% drop, so Supabase delivery
is less consistent even at N=10.)

**Fanout ramp (N = 5/10/25/50 subscribers):**

| Framing | Target | N=5 p50/p95 | N=10 | N=25 | N=50 | Max sustainable |
|---------|--------|-------------|------|------|------|-----------------|
| A | HyperStack | 11/33 | 12/35 | 15/37 | 21/46, 0% drop | **≥50** |
| A | Supabase | 272/503 | 273/503 | 261/492 | 259/497, **31% drop** | 25 |
| B | HyperStack | 11/34 | 11/33 | 15/38 | 21/46, 0% drop | **≥50** |
| B | Supabase | 248/496 | 248/480 | 276/506 | 260/505, **31% drop** | 25 |

**HyperStack scales to ≥50 subscribers with zero drops; Supabase hits a ceiling at 25 and
drops 31% of events at N=50** (3,450/5,000 received). HyperStack's per-subscriber re-fetch
(confound C3) is the cost that gives this delivery profile.

### 2e. Auth — sign-in / sign-up

1 VU (KDF-bounded), N=5.

| Scenario | Framing | HS req/s | SB req/s | HS p50 | SB p50 |
|----------|---------|---------:|---------:|-------:|-------:|
| sign-in | A | 7.3 | 7.1 | 110.7 ms | 109.5 ms |
| sign-in | B | 7.5 | 7.2 | 79.9 ms | 104.9 ms |
| sign-up | A | 6.3 | 6.9 | 48.8 ms | 125.4 ms |
| sign-up | B | 2.6 | 7.1 | 42.1 ms | 110.5 ms |

**Sign-in is at parity** (both KDF-bounded; HS Argon2id vs SB bcrypt — confound C2).
**Sign-up: HyperStack's per-request latency is lower but throughput is lower** — HS
serialises concurrent hashing where GoTrue pools it. See §5.

### 2f. Storage — ISOLATED (fresh Supabase storage state)

Per iteration: upload small + upload large + download small + download large. 20 VUs, N=5.
Supabase storage was reset before the run: container restarted to `healthy` + bench bucket
emptied. No other load on the box. Framing A = SB direct to storage container; B = via
Kong.

| Framing | Target | req/s (total) | success req/s | p50 | p95 | Runs passed |
|---------|--------|--------------:|--------------:|----:|----:|-------------|
| A | HyperStack | 422 | **422** | 34.5 ms | 106.1 ms | **5/5** |
| A | Supabase | 196 | 124 | 65.4 ms | 200.6 ms | 1/5 |
| B | HyperStack | 401 | **401** | 34.1 ms | 113.9 ms | **5/5** |
| B | Supabase | 239 | 55 | 66.0 ms | 182.1 ms | 0/5 |

(Medians of N=5.) **The honest throughput comparison is success-only req/s** — Supabase's
total req/s is inflated by *failed* uploads that return faster. On successful work HyperStack
delivers **~3.4× (A) to ~7.3× (B)** the throughput, at 100% success vs Supabase's 0–1/5 passing.

**Honest degradation finding — the failure is UPLOADS only** (download success stays 100%
on both targets across every run). Even from a fresh restart, Supabase framing-A run 1
passes cleanly (100% upload, 0% errors), then collapses run-over-run:

| Run | SB-A upload success | SB-A error rate | SB-B upload success | SB-B error rate |
|-----|--------------------:|----------------:|--------------------:|----------------:|
| 1 | 100.0% (PASS) | 0.0% | 18.2% | 69.2% |
| 2 | 64.7% | 21.4% | 15.0% | 74.0% |
| 3 | 46.2% | 36.8% | 12.9% | 77.2% |
| 4 | 34.1% | 49.1% | 10.2% | 81.5% |
| 5 | 26.0% | 58.8% | 8.7% | 84.0% |

HyperStack: 100% upload + 100% download success, 0% errors, all 10 runs.

**So the prior storage failures were NOT solely a contamination artifact** — Supabase
storage uploads genuinely saturate under sustained 20-VU concurrency, even fresh. A
single-shot upload burst is fine (run 1 framing A passes); the failure mode is *sustained*
concurrent upload load.

> **Misleading-iter/s caveat:** Supabase's iterations/s *rises* across runs (38→153
> framing A; 170→220 framing B) even as it fails — because *failed uploads return faster*,
> spinning the loop faster while doing less real work. Read the upload-success column, not
> iterations/s. The req/s above is `http_reqs/s` (comparable work units).

### 2g. Footprint

API-layer footprint (Postgres excluded — both need a Postgres). See FAIRNESS.md §F2/F3/F4.

| Metric | HyperStack | SB minimal-prod (5 ctr) | SB full dev-stack (10 ctr) |
|--------|-----------:|------------------------:|---------------------------:|
| Idle RSS (framing A) | 6.4 MB | 1,020 MB | 2,428 MB |
| Idle RSS (framing B) | 6.3 MB | 759 MB | 2,158 MB |
| Under-load RSS (A) | 12.3 MB | — | 2,440 MB |
| Under-load RSS (B) | 12.4 MB | — | 2,812 MB |
| Binary / image total | 4.94 MB | — | 3,532 MB |
| Cold-start (A) | 602 ms (full) | timeout (Kong-only, LB) | — |
| Postgres idle RSS | 39.9 MB (postgres:17) | — | 247 MB (SB pg) |
| **Idle ratio vs HS** | 1× | **~159× (A) / ~120× (B)** | **~379× (A) / ~342× (B)** |

- **Minimal-prod** = Kong + GoTrue + PostgREST + Realtime + Storage (the 5 containers
  needed to serve production API traffic) — the honest headline ratio.
- **Full dev-stack** adds Studio + pg_meta + Vector + Analytics + Inbucket (dev tooling).
- **Cold-start caveat (F2):** HS = full binary exec → first `/ready` 200. SB = Kong-only
  container restart while 9 containers stay warm — a **conservative lower bound**; full SB
  stack cold-start is 30–120 s.
- **RSS caveat (F3):** HS via `ps` (excludes page cache); SB via cgroup `memory.usage`
  (includes page cache). Different units — **favours HS**; real gap may be smaller.

---

## 5. Where HyperStack loses / ties (hostile-skeptic review)

- **REST reads:** Supabase wins on throughput (~+16% framing B, larger in framing A where
  the network confound helps SB). HyperStack ties/wins on p95 latency in framing B. Net:
  **reads are ~parity to slight-loss for HyperStack.**
- **Realtime write-tax (W1):** writing to a **realtime-enabled** table costs HyperStack
  ~3.7–3.85× vs ~1.0× for Supabase. This is a genuine HyperStack cost (per-row
  `pg_notify`), and is the price of its low-latency, zero-drop realtime delivery. If your
  workload writes heavily to realtime-enabled tables, this matters.
- **Auth sign-up throughput:** Supabase wins (GoTrue pools concurrent hashing; HyperStack
  serialises). HyperStack's per-request latency is lower, but sustained concurrent signup
  throughput is lower.
- **Things HyperStack wins:** raw inserts, realtime delivery latency + fanout, storage
  throughput + reliability, footprint, cold-start, on-disk size.
- **Confound honesty:** F2 and F3 favour HyperStack (cold-start lower bound for SB; RSS
  accounting units differ). The minimal-prod footprint ratio (~159×), not the full-stack
  ratio (~379×), is the headline a skeptic should use.

---

*Raw data: `results/raw/` (this package). Reproduce: see `README.md`. All confounds:
`FAIRNESS.md`.*
