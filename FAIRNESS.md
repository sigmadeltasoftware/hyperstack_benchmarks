# bench/FAIRNESS.md — Known Confounds and Honest Caveats

This document is the authoritative record of every known fairness gap in the
benchmark harness. It exists so that RESULTS.md can state honest, scoped claims
rather than overclaiming equivalence that does not exist.

---

## C1 — Engine Non-Identity (Critical)

**What the header used to say:** "same pg major version (17) — API-layer parity."

**What is actually true:** Framing A and Framing B both use *separate* Postgres
instances. They are NOT the same engine build, NOT the same configuration, and NOT
sharing any storage or WAL.

| Side        | Image                                             | pg version |
|-------------|---------------------------------------------------|------------|
| HyperStack  | `postgres:17` (Docker Hub, vanilla Debian build)  | 17.10      |
| Supabase    | `public.ecr.aws/supabase/postgres:17.6.1.106`    | 17.6.1     |

**Differences that affect latency:**

- Supabase's fork carries more `shared_preload_libraries`:
  `pg_stat_statements, pgaudit, plpgsql, plpgsql_check, pg_cron, pg_net,
  pgsodium, auto_explain, pg_tle, plan_filter, supabase_vault`
  plus `session_preload_libraries=supautils`.
  Vanilla postgres:17 loads none of these.
- Default `pg_settings` differ between the two builds (see manifest
  `pg_settings.*` keys for the exact values captured at run time).

**Why a shared instance is structurally impossible:**

The Supabase pg cluster reserves the role names `authenticator`, `anon`,
`authenticated`, and `service_role` cluster-wide. HyperStack's bootstrap migration
must execute `ALTER ROLE authenticator PASSWORD '...'` to install its own
credential. Even though `supabase_admin` has the privilege to issue this ALTER,
doing so would immediately break PostgREST's live connection pool (which uses
`authenticator` + its current password for every reconnect). The blocker is
a *cluster-wide role-namespace collision*, not merely a supautils permission guard.
A truly shared instance is not achievable without destroying the running Supabase
stack.

**Honest claim Framing A supports:**

> Framing A controls for **gateway overhead only**. Any observed latency difference
> also includes contributions from pg-version delta (17.10 vs 17.6.1), the
> extension load in Supabase's fork, and different default pg configuration.

---

## C2 — Password Hash Algorithm Mismatch (Critical)

Auth signin and signup latency is **NOT directly comparable** between the two sides.

| Side                    | Algorithm  | Parameters                                   |
|-------------------------|------------|----------------------------------------------|
| HyperStack              | Argon2id   | `m=19456 KiB (~19 MB), t=2, p=1` (argon2 crate 0.5 defaults) |
| Supabase GoTrue v2.188.1| bcrypt     | cost=10 (GoTrue default, not overridden)     |

Argon2id is a memory-hard KDF: each hash verification occupies ~19 MB of RAM and
performs two passes. Bcrypt is CPU-only (no large memory requirement). The
algorithms have fundamentally different CPU and memory profiles; wall-clock latency
for a hash operation is not exchangeable.

**Impact:** Task 3 (auth scenario) latency numbers reflect algorithm choice as much
as implementation quality. Interpreting a latency advantage as "the implementation
is faster" conflates algorithm and implementation.

**What a fair comparison would require:** calibrate both sides to equal wall-clock
hash time at the chosen concurrency level (e.g. measure the time per hash for each
and match Argon2 `t_cost` / bcrypt `cost` accordingly). This harness does NOT do
that. The Task 3 numbers carry this caveat prominently.

**HyperStack's Argon2 cost is not changed** — it is the correct, recommended
production setting (OWASP minimum). The caveat is documented, not papered over.

---

## I1 — Network Path Asymmetry (Important)

k6 runs inside a Docker container on `supabase_network_SDTool`.

| Route                    | Path                                                        |
|--------------------------|-------------------------------------------------------------|
| k6 → HyperStack          | container → `host.docker.internal` → host binary (extra hop)|
| k6 → Supabase            | container → container (direct, same Docker network)         |

This asymmetry **penalizes HyperStack**. Every HyperStack request traverses an
additional network boundary (container → host kernel bridge) that Supabase requests
do not. The measured HyperStack latency is therefore a **conservative lower bound**:
even with the extra hop, the reported numbers reflect real behavior.

**QUANTIFIED (update):** a re-measurement routing k6 to BOTH targets via the host's
published ports (equal hop on each side) showed this confound accounted for **~80% of the
original −16% REST-read gap** — HyperStack's read req/s rose from 2,812 → ~3,369 once the
path was symmetric, while Supabase's barely moved. With the network equalized, small reads
are a tie (HS wins p95/p99) and large reads are a clear HS win (see RESULTS.md §2a). So the
original framing-A/B read figures overstated Supabase's lead by the size of this hop.

**Fix attempted:** Cross-compile HyperStack to `linux/aarch64` and run it as a
container on `supabase_network_SDTool` to achieve symmetric container-to-container
routing from k6.

**Outcome:** `cross` is not installed in this environment
(`cross not found` on PATH). A multi-stage Dockerfile build
(`FROM rust:slim` + copy binary to `debian:stable-slim`) was considered but deferred
because the build would take ~10–20 min in CI and the resulting linux/aarch64 binary
has not been validated. The document-the-hop path was taken instead.

**How to read the results:** Any HyperStack latency advantage persists *despite* the
extra hop. A HyperStack disadvantage in latency may partly or fully reflect the
extra network boundary rather than the implementation.

**Future fix:** Build a `bench/Dockerfile.hyperstack` multi-stage image and wire
`framing-a.sh` / `framing-b.sh` to run the container on `supabase_network_SDTool`.

---

## I2 — Connection Pool Sizes Uncontrolled (Important)

| Component              | Pool size                                                  |
|------------------------|------------------------------------------------------------|
| HyperStack authn pool  | 16 (`Db::connect(…, 16)` in `bin/hyperstack/src/lib.rs:86`) |
| HyperStack admin pool  | 8  (`Db::connect(…, 8)`  in `bin/hyperstack/src/lib.rs:67`) |
| PostgREST              | 10 (default; `PGRST_DB_POOL` not set in container env)     |
| GoTrue                 | uncapped (Go `database/sql` defaults; no env override seen) |

Pool sizes are **not equalized** in this harness. Under high concurrency the
difference between pool=10 (PostgREST) and pool=16 (HyperStack authn) will affect
queuing latency and throughput — in HyperStack's favour for REST-heavy scenarios.

**Why not equalized:** Setting `PGRST_DB_POOL=16` on the running Supabase PostgREST
container would require a container restart and is intrusive to the shared SDTool
stack. The harness records the actual values so readers can assess the impact.

**How to neutralize:** Set `PGRST_DB_POOL=16` in the PostgREST container before
bench runs and restart it. Document in the run manifest.

---

## C3 — Realtime Scenario: Network Topology, Protocol, and RLS Re-Fetch Cost

### Protocol (headline: Phoenix/supabase-js on both sides)

The realtime headline numbers use the **same `@supabase/supabase-js` client and
Phoenix WebSocket path (`/realtime/v1/websocket`) for both HyperStack and Supabase**.
This is the path a real supabase-js user connects with.

An earlier run (2026-06-24) mistakenly benchmarked HyperStack via its custom native
WS protocol (`/realtime/v1?token=<jwt>`) because the release binary at that time
predated the Phoenix endpoint mount and returned 404 on `/realtime/v1/websocket`.
That run's numbers OVERSTATED HyperStack's supabase-compatible realtime performance:
the native protocol has less framing overhead than the Phoenix protocol (no
phx_join/phx_reply round-trips, no Erlang-style topic multiplexing).

The binary was rebuilt on 2026-06-25; the Phoenix endpoint (`/realtime/v1/websocket`
→ `crate::phoenix::phoenix_ws_handler`) is confirmed working. All headline realtime
numbers from 2026-06-25 onward use the Phoenix/supabase-js path on both sides.

The native protocol numbers (if recorded, under key `hyperstack_native` in the JSON)
are clearly labeled as a secondary datapoint: *"HyperStack native protocol (not the
supabase-js path)"*. They are not used in the headline comparison.

**Stale-binary guard:** `bench/run.sh` now runs `cargo build --release -p hyperstack`
before every bench run (cheap no-op when up-to-date), ensuring the binary cannot
lag behind source.

### Network topology (symmetric — I1 does NOT apply)

The realtime benchmark driver (`bench/scenarios/realtime-driver.mjs`) runs as a
**Node.js process on the host**, not inside Docker. Both targets are accessed via
`localhost`:

| Route                          | Path                                               |
|--------------------------------|----------------------------------------------------|
| Host Node → HyperStack         | `http://127.0.0.1:<HS_PORT>` — direct localhost   |
| Host Node → Supabase           | `http://localhost:54321` via Kong — localhost      |

This is **symmetric**: unlike the k6 REST/auth scenarios (§I1), there is no extra
Docker network hop penalizing either target. The measured latency reflects only
the realtime delivery path, not network topology differences.

### HyperStack's per-subscriber RLS re-fetch cost

HyperStack's realtime implementation re-fetches each changed row **once per
subscriber**, executing `SELECT ... WHERE owner = auth.uid()` as that subscriber's
identity (i.e. via `SET LOCAL ROLE authenticated; SET LOCAL "request.jwt.claims" = ...`).

For N subscribers and M inserts/second, this is **O(N × M) Postgres queries/second**
in addition to the original writes. This is the correct behaviour for an
RLS-enforced realtime system (it ensures subscribers only receive rows they are
authorized to see), but it means that HyperStack's realtime throughput scales
differently from Supabase's.

Supabase Realtime uses a different architecture (Elixir-based, reads WAL via
logical replication, then re-evaluates RLS per subscriber) with its own scaling
profile.

**How to read the fanout results:** The `max_sustainable_n` figure (highest N where
`drop_rate < 1%` AND `p99 < 2000ms`) is the per-machine ceiling at the chosen M.
These numbers are an honest measurement of each system's throughput under the test
conditions; they are **not** a universal claim about architectural superiority.

### Publisher fairness

The publisher uses a **service-role JWT** to insert rows with `owner = <bench_user_id>`.
This bypasses the INSERT RLS policy (avoiding throttle from repeated auth checks on
inserts) while ensuring the `owner` column is set correctly so all N subscribers
(authenticated as that user) can see each row via the SELECT-based RLS re-fetch.

### REPLICA IDENTITY FULL (required for Supabase realtime + RLS)

Supabase Realtime uses Postgres logical replication (WAL). With the default
`REPLICA IDENTITY DEFAULT`, the WAL record for an UPDATE or INSERT only carries the
PRIMARY KEY column(s). Supabase Realtime evaluates the RLS policy
(`owner = auth.uid()`) against the WAL record to decide whether to deliver it to a
subscriber — but with DEFAULT identity, the `owner` column is absent from the WAL,
so the RLS check fails and the event is **dropped silently**.

Root-cause fix applied in `bench/fixtures/seed.mjs`: `ALTER TABLE public.bench_items
REPLICA IDENTITY FULL` is now part of the Supabase schema setup (idempotent). This
ensures the WAL record carries every column so the realtime server can evaluate
owner-based RLS correctly.

Diagnosis: confirmed on 2026-06-25. Before fix: selfcheck showed
`✗ Supabase realtime delivery: no event within 10s`. After setting REPLICA IDENTITY
FULL, delivery succeeded.

HyperStack's realtime re-fetches the row from Postgres for each subscriber, so it
does not use the WAL column set at all — DEFAULT identity works for HyperStack.
FULL is applied there too for consistent WAL format documentation.

### Selfcheck Phoenix consistency

The selfcheck (`bench/selfcheck.mjs`) previously used HyperStack's native WS
protocol (`/realtime/v1?token=<jwt>`) for the HyperStack realtime probe. This was
inconsistent with the benchmark driver (which uses the supabase-js Phoenix path on
both sides). Fixed on 2026-06-25: the selfcheck now uses `checkRealtimeSanitySb`
(supabase-js Phoenix) for HyperStack as well, confirming that the Phoenix endpoint
works end-to-end before every bench run.

---

## F2 — Cold-Start Asymmetry: Kong-Only vs Full Stack (Critical)

**What the numbers say:** HyperStack 595 ms vs Supabase ~10,693 ms. Ratio: ~18×.

**The asymmetry:**
- HyperStack cold-start = single binary exec → Postgres pool + schema introspect → `/ready` HTTP 200. This is the **full API-layer cold-start from a completely stopped state**.
- Supabase cold-start = `docker restart supabase_kong_SDTool` → Kong re-initialises → `/rest/v1/` HTTP 200. The other 9 containers (GoTrue, PostgREST, Realtime, Storage, Studio, pg-meta, Vector, Analytics, Inbucket, Postgres) **remain warm and running throughout**. This is NOT equivalent to HyperStack's cold-start.

**Fair Supabase measurement** = `docker compose up` from fully stopped state:
  - With warm image cache (images already pulled): ~30–120 seconds
  - With cold image cache (fresh pull required): ~5–15 minutes

**Why the fair measurement was not taken:** Stopping the full Supabase dev stack during a live bench run would terminate all 11 containers and disrupt other scenarios. The Kong-only number is **kept but labeled as a CONSERVATIVE LOWER BOUND**.

**Bottom line:** The 18× headline comparison is NOT symmetric. HyperStack cold-starts in <1 second. The honest description is: "Supabase Kong alone takes ~11 seconds to restart; the full stack cold-start is 30 seconds to 2 minutes." The `bench/footprint/measure.sh` output now makes this asymmetry unmissable.

---

## F3 — RSS Measurement Method Asymmetry (Important)

**What is measured:**
- HyperStack RSS: `ps -o rss= -p <pid>` on the macOS host. This is the **virtual-memory RSS** as reported by the macOS kernel. It excludes page cache contributions from other processes, and does not include memory-mapped files that are not currently resident.
- Supabase RSS: `docker stats --no-stream` inside the Docker Linux VM. This reports `cgroup memory.usage_in_bytes`, which **includes page cache** (file-backed anonymous memory) and all cgroup-charged memory.

**Direction:** cgroup `memory.usage_in_bytes` tends to run **higher** than `ps` RSS for the same workload because page cache is included. This **favours HyperStack** in the comparison — the Supabase numbers may be inflated relative to what `ps` would show for the same containers.

**Why not fixed:** Making the two measurements identical would require running `ps`-equivalent inside the Docker Linux VM for each container (e.g., `docker exec <ctr> cat /proc/<pid>/status | grep VmRSS`), which is fragile across images (some lack `/proc`). The asymmetry is **disclosed, not corrected**.

**How to read the results:** Any HyperStack RSS advantage is conservative — if we measured Supabase with the same method as HS (`ps`-equivalent), the Supabase numbers would be lower. The reported ratios may overstate the true RSS difference by an unknown factor (likely 10–30% for typical server workloads).

---

## F4 — Footprint Container Set: Minimal-Prod vs Full Dev Stack (Critical)

**What Supabase ships in its local dev stack:**
- **Minimal-prod containers** — required for production API traffic:
  - Kong (API gateway, ~100–170 MB)
  - GoTrue/auth (~19 MB)
  - PostgREST/rest (~130–200 MB)
  - Realtime (~190 MB)
  - Storage (~230–450 MB)
  - **Total: ~747 MB** (varies with workload)
- **Dev-extras containers** — developer tooling, NOT needed for production API traffic:
  - Studio (admin UI, ~200 MB)
  - pg-meta (schema browser, ~80 MB)
  - Vector + Logflare/Analytics (~120 MB + ~1050 MB ≈ **1170 MB combined**)
  - Inbucket/Mailpit (dev mail trap, ~8 MB)
  - **Total extras: ~1460 MB**

**Why this matters:** The original headline (216×) counted all 10 containers including dev-extras. A skeptic who does not run Studio, analytics, or a mail trap in production is correct to exclude them.

**Corrected framing:**
- **Minimal-prod headline: HS ~10 MB vs SB ~747 MB ≈ 73× ratio** — this is the honest production comparison.
- **Full dev-stack: HS ~10 MB vs SB ~2204 MB ≈ 216× ratio** — correct for the full local dev stack, reported for completeness.

Both are real measurements from a single consistent run. The `bench/footprint/measure.sh` script now computes and emits both sums with the container lists that constitute each. The HONEST HEADLINE is the minimal-prod ratio.

---

## W1 — Realtime Write-Tax (Critical) [added 2026-06-26]

**The original INSERT headline was wrong.** It benchmarked `POST /rest/v1/bench_items`
against a table that had HyperStack realtime **enabled**. `realtime.enable('public.bench_items')`
installs an `AFTER INSERT OR UPDATE OR DELETE FOR EACH ROW EXECUTE FUNCTION realtime.notify('id')`
trigger, which issues a `pg_notify` per row. Under concurrency the NOTIFY queue serialises
commits, so that benchmark measured HyperStack's **realtime write-tax**, not raw insert speed.

**Correction:** the INSERT headline now uses a **plain, non-realtime table**
(`bench_items_plain`) with identical schema, RLS policy, grants, and fixture rows, but
**no** `realtime.enable` on HyperStack and **not** added to the `supabase_realtime`
publication. Verified: 0 triggers on the HyperStack plain tables; absent from the Supabase
publication.

**Measured (req/s, 20 VUs, N=5):**

| Framing | Target | Plain table | Realtime-enabled | Write-tax |
|---------|--------|------------:|-----------------:|----------:|
| A | HyperStack | 2,185 | 585 | **3.7×** |
| A | Supabase | 1,876 | 1,873 | 1.00× |
| B | HyperStack | 2,184 | 567 | **3.85×** |
| B | Supabase | 1,766 | 1,750 | 1.01× |

Independently confirmed at the DB layer with `pgbench` (8 clients, 10s) inside the
HyperStack Postgres container: plain table **2,702 TPS** vs realtime-enabled **641 TPS**
(= 4.2× at c=8; the multiplier grows with concurrency/commit profile).

**Direction / honest claim:**
- HyperStack pays ~3.7–3.85× to write to a realtime-enabled table (architectural:
  per-row `pg_notify`). **This penalises HyperStack** and must be reported as its own row.
- Supabase pays ~nothing (1.00–1.01×): its Realtime reads the WAL out of band, so enabling
  realtime on a table does not tax writes to it.
- **Trade-off:** HyperStack's NOTIFY-and-refetch design is exactly what buys its ~24×
  lower realtime *delivery* latency and zero-drop fanout to N≥50 (see C3 / RESULTS §2d).
  The write-tax is the cost side of that same design. It applies only to tables with
  realtime explicitly enabled.

---

## S1 — Storage Upload Saturation (Important) [added 2026-06-26]

**The original storage failure was attributed (with a caveat) to load ordering.** An
isolated re-run shows that attribution was too generous to Supabase.

The storage scenario was re-run **isolated**: Supabase storage container restarted to
`healthy`, the `bench` bucket emptied (17,663 leftover objects deleted), and **no other
load** on the box. Storage uses service-role keys (unaffected by user-JWT expiry).

**Finding:** even from a fresh start, **Supabase storage uploads saturate under sustained
20-VU concurrency.** Framing A run 1 passes cleanly (100% upload success, 0% errors), then
collapses run-over-run (upload success 100% → 64.7% → 46.2% → 34.1% → 26.0%; error rate
0% → 59%). Framing B (via Kong) is already failing on run 1 (18% upload success) down to
8.7%. HyperStack passes 5/5 in both framings (100% upload + download, 0% errors).

- The bottleneck is **uploads only** — download success stays 100% on Supabase throughout.
- **Misleading metric caveat:** Supabase's iterations/s *rises* across runs (38→153
  framing A) even as it fails, because failed uploads return faster and spin the loop
  faster while doing less real work. Report `http_reqs/s` and upload-success, not iter/s.

**Direction:** penalises Supabase. This is a real, reproducible reliability property under
sustained concurrent upload load — a single-shot upload burst (run 1, framing A) is fine.

---

## ENV — Environment Correction (Note) [added 2026-06-26]

An earlier draft described the benchmark host as "Apple M-series (aarch64), 14 CPU cores,
48 GB RAM." **That was wrong.** The actual benchmark server is:

- **CPU/OS:** x86_64 Intel Mac, macOS Darwin 25.4.0 (kernel `RELEASE_X86_64`).
- **HyperStack binary:** native `x86_64-apple-darwin` Mach-O executable, run on the host.
- **Docker provider:** **OrbStack** (Docker Engine — Community), **not** colima, **not**
  Docker Desktop. `/usr/local/bin/docker` → `/Applications/OrbStack.app/.../docker`.
- **Supabase stack:** brought up via the Supabase CLI under OrbStack.

Direction: neutral for the comparison (both targets run on the same host), but the platform
note matters for anyone reproducing — the bundled binary is x86_64-apple-darwin and will
not run on Apple Silicon or Linux without a rebuild.

---

## JWT — Fixture JWT Re-Seed (Note) [added 2026-06-26]

Fixture user-JWTs have a ~1-hour TTL. The corrected INSERT runs were performed in a fresh
session after the originals had expired, so both framings were **re-seeded** first: fresh
JWTs, identical 100-row fixtures, with the harness's row-count assertion (100 = 100 on both
targets) passing before any measurement. The plain table was seeded by copying rows from
`bench_items`, so the owner distribution is identical. Storage and footprint use
service-role / admin credentials with long-lived tokens and were unaffected.

---

## FRAMING — Framing B Is the More Symmetric Comparison (Note) [added 2026-06-26]

For latency comparisons, **weight framing B**. In framing A, Supabase is reached
container-to-container (`supabase_rest_sb-bench:3000` etc.) while HyperStack is always
reached across the Docker bridge via `host.docker.internal` (confound I1). Framing A thus
carries a structural network advantage for Supabase. Framing B routes Supabase through Kong
(the as-shipped path), narrowing the asymmetry. Where the framings disagree (e.g. REST
reads), framing B is the fairer number — and notably HyperStack's raw-insert lead is
*larger* in framing B (+24%) than framing A (+16%), so the asymmetry is not flattering
HyperStack on that dimension.


---

## Summary Table

| ID | Severity | Confound                                 | Direction   | Status      |
|----|----------|------------------------------------------|-------------|-------------|
| C1 | Critical | Separate pg instances, different builds  | Neutral/mixed| Documented  |
| C2 | Critical | Argon2id vs bcrypt — different algorithms| Mixed       | Documented  |
| I1 | Important| k6→HS extra network hop vs container-direct| Penalizes HS| Document-hop path taken |
| I2 | Important| Pool sizes differ (16 vs 10 vs uncapped) | Favours HS  | Documented  |
| C3 | Important| Realtime: RLS re-fetch is O(N) per insert in HS; headline uses Phoenix/supabase-js on both sides | Mixed | Documented |
| C4 | Critical | Supabase realtime requires REPLICA IDENTITY FULL for RLS-filtered postgres_changes | Fixed in seed.mjs | Applied 2026-06-25 |
| F2 | Critical | Cold-start asymmetry: HS full binary cold-start vs SB Kong-only restart (9 containers warm) | Favours HS | Labeled conservative lower bound in output |
| F3 | Important| RSS method: ps/macOS (HS) vs cgroup memory.usage/Linux-VM (SB, includes page cache) | Favours HS | Disclosed in output + FAIRNESS.md |
| F4 | Critical | Footprint container set: minimal-prod (5 containers) vs full dev-stack (10 containers) | Mixed (full inflated by dev-extras) | Both sums emitted, minimal-prod is honest headline |
| W1 | Critical | Realtime write-tax: HS pg_notify-per-row on realtime-enabled tables (3.7-3.85x); SB ~1.0x (WAL) | Penalizes HS | Documented; INSERT headline now uses plain table |
| S1 | Important| Storage: SB upload saturates under sustained 20-VU load (fresh+isolated, not just contamination); uploads only | Penalizes SB | Documented; isolated re-run |
| ENV| Note     | Server is x86_64 Intel + OrbStack (corrected from earlier 'Apple Silicon' / colima error) | Neutral | Corrected |
| JWT| Note     | Fixture user-JWTs ~1h TTL; both framings re-seeded (100=100 assertion) before corrected runs | Neutral | Documented |

All confounds are recorded in the run manifest under `fairness.*`.
