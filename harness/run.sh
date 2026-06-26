#!/usr/bin/env bash
# bench/run.sh — Main orchestration script for HyperStack vs Supabase benchmarks.
#
# Usage:
#   bash bench/run.sh --framing <a|b|both> --scenario <smoke|rest|auth|storage|footprint> [--runs N]
#                     [--fixture-k K] [--fixture-r R] [--fixture-s S]
#                     [--skip-seed] [--skip-selfcheck]
#
# Examples:
#   bash bench/run.sh --framing a --scenario smoke
#   bash bench/run.sh --framing both --scenario smoke --runs 3
#   bash bench/run.sh --framing both --scenario rest --runs 5
#   bash bench/run.sh --framing both --scenario auth --runs 5
#   bash bench/run.sh --framing both --scenario storage --runs 5
#   bash bench/run.sh --scenario footprint
#   bash bench/run.sh --framing a --scenario smoke --fixture-k 20 --fixture-r 500
#
# NOTE on --scenario auth:
#   Runs auth-signin.js + auth-signup.js against both targets.
#   FAIRNESS.md §C2 applies: HyperStack uses Argon2id (memory-hard, ~19 MB/hash);
#   Supabase GoTrue uses bcrypt cost=10. Auth throughput numbers are NOT a direct
#   speed comparison — they reflect different default security postures.
#   A lower HyperStack req/s is expected and correct (stronger hash).
#
# NOTE on --scenario storage:
#   Runs storage-updownload.js (k6) against both targets.
#   Tests upload (PUT) + download (GET) of 64 KB and 1 MB objects.
#   Validity-asserted: upload 2xx, download 200 with correct content-length.
#
# NOTE on --scenario footprint:
#   Runs bench/footprint/measure.sh — does NOT iterate over framings or run k6.
#   Measures idle RSS, under-load RSS/CPU, container count, on-disk size, cold-start.
#   Uses the currently running framing (framing-a.sh must be up before running).
#   Footprint is run ONCE per invocation, not per-framing (--framing is ignored).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# ── Argument parsing ──────────────────────────────────────────────────────────

FRAMING=""
SCENARIO="smoke"
RUNS=1
FIXTURE_K="${DEFAULT_FIXTURE_K}"
FIXTURE_R="${DEFAULT_FIXTURE_R}"
FIXTURE_S="${DEFAULT_FIXTURE_S}"
SKIP_SEED=0
SKIP_SELFCHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --framing)       FRAMING="$2";        shift 2 ;;
    --scenario)      SCENARIO="$2";       shift 2 ;;
    --runs)          RUNS="$2";           shift 2 ;;
    --fixture-k)     FIXTURE_K="$2";      shift 2 ;;
    --fixture-r)     FIXTURE_R="$2";      shift 2 ;;
    --fixture-s)     FIXTURE_S="$2";      shift 2 ;;
    --skip-seed)     SKIP_SEED=1;         shift ;;
    --skip-selfcheck) SKIP_SELFCHECK=1;   shift ;;
    *)
      echo "Unknown arg: $1" >&2
      echo "Usage: bash bench/run.sh --framing <a|b|both> --scenario <smoke|rest|auth|storage|footprint> [--runs N]" >&2
      exit 1
      ;;
  esac
done

# Footprint scenario does not iterate over framings — it measures the currently-up stack.
# Allow running without --framing when --scenario footprint is given.
if [[ "${SCENARIO}" == "footprint" && -z "${FRAMING}" ]]; then
  FRAMING="a"  # default framing for env file lookup
fi

if [[ -z "${FRAMING}" ]]; then
  echo "ERROR: --framing is required." >&2
  exit 1
fi

if [[ "${FRAMING}" != "a" && "${FRAMING}" != "b" && "${FRAMING}" != "both" ]]; then
  echo "ERROR: --framing must be a, b, or both." >&2
  exit 1
fi

# ── Scenario validation ───────────────────────────────────────────────────────
# "rest" is a multi-file scenario (rest-select.js + rest-insert.js).
# "auth" is a multi-file scenario (auth-signin.js + auth-signup.js).
# "realtime" is a Node-driver scenario (realtime-driver.mjs) — NOT k6.
# Other scenarios are single-file (smoke.js, etc.).

SCENARIO_IS_MULTI=0
SCENARIO_IS_AUTH=0
SCENARIO_IS_REALTIME=0
SCENARIO_IS_STORAGE=0
SCENARIO_IS_FOOTPRINT=0

# Realtime bench parameters (can be overridden via env)
RT_N="${RT_N:-10}"
RT_M="${RT_M:-5}"
RT_D="${RT_D:-20}"
RT_FANOUT_LEVELS="${RT_FANOUT_LEVELS:-5,10,25,50}"

if [[ "${SCENARIO}" == "rest" ]]; then
  SCENARIO_IS_MULTI=1
  # Verify both sub-scenario files exist
  if [[ ! -f "${SCRIPT_DIR}/scenarios/rest-select.js" ]]; then
    echo "ERROR: Scenario file not found: ${SCRIPT_DIR}/scenarios/rest-select.js" >&2
    exit 1
  fi
  if [[ ! -f "${SCRIPT_DIR}/scenarios/rest-insert.js" ]]; then
    echo "ERROR: Scenario file not found: ${SCRIPT_DIR}/scenarios/rest-insert.js" >&2
    exit 1
  fi
elif [[ "${SCENARIO}" == "auth" ]]; then
  SCENARIO_IS_MULTI=1
  SCENARIO_IS_AUTH=1
  # Verify both auth sub-scenario files exist
  if [[ ! -f "${SCRIPT_DIR}/scenarios/auth-signin.js" ]]; then
    echo "ERROR: Scenario file not found: ${SCRIPT_DIR}/scenarios/auth-signin.js" >&2
    exit 1
  fi
  if [[ ! -f "${SCRIPT_DIR}/scenarios/auth-signup.js" ]]; then
    echo "ERROR: Scenario file not found: ${SCRIPT_DIR}/scenarios/auth-signup.js" >&2
    exit 1
  fi
elif [[ "${SCENARIO}" == "realtime" ]]; then
  SCENARIO_IS_REALTIME=1
  if [[ ! -f "${SCRIPT_DIR}/scenarios/realtime-driver.mjs" ]]; then
    echo "ERROR: Realtime driver not found: ${SCRIPT_DIR}/scenarios/realtime-driver.mjs" >&2
    exit 1
  fi
elif [[ "${SCENARIO}" == "storage" ]]; then
  SCENARIO_IS_STORAGE=1
  if [[ ! -f "${SCRIPT_DIR}/scenarios/storage-updownload.js" ]]; then
    echo "ERROR: Scenario file not found: ${SCRIPT_DIR}/scenarios/storage-updownload.js" >&2
    exit 1
  fi
elif [[ "${SCENARIO}" == "footprint" ]]; then
  SCENARIO_IS_FOOTPRINT=1
  if [[ ! -f "${SCRIPT_DIR}/footprint/measure.sh" ]]; then
    echo "ERROR: Footprint script not found: ${SCRIPT_DIR}/footprint/measure.sh" >&2
    exit 1
  fi
else
  SCENARIO_FILE="${SCRIPT_DIR}/scenarios/${SCENARIO}.js"
  if [[ ! -f "${SCENARIO_FILE}" ]]; then
    echo "ERROR: Scenario file not found: ${SCENARIO_FILE}" >&2
    exit 1
  fi
fi

# ── Run ID ────────────────────────────────────────────────────────────────────

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUNID="$(date +%Y%m%d_%H%M%S)_$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6 || true)"
echo "[run] Run ID: ${RUNID}"
echo "[run] Timestamp: ${TIMESTAMP}"
echo "[run] Framing: ${FRAMING}"
echo "[run] Scenario: ${SCENARIO}"
echo "[run] Runs: ${RUNS}"
echo "[run] Fixture: K=${FIXTURE_K} R=${FIXTURE_R} S=${FIXTURE_S}"
echo ""

mkdir -p "${BENCH_RESULTS_DIR}" "${BENCH_RAW_DIR}"

# ── k6 docker runner (single invocation) ─────────────────────────────────────
# Runs k6 for ONE target on ONE sub-scenario and writes JSON to bench/results/raw/.
# File name: k6-{framing}-{scenario}-{target}-{runid}-run{N}.json
#
# I4 COMPLIANCE: Each target is a SEPARATE k6 invocation → no ordering/warmup
# bias, no shared VU state, no cold/warm asymmetry between targets.
#
# Args: framing scenario_file target out_file hs_rest_url hs_jwt hs_user_id
#       sb_rest_url sb_jwt sb_user_id sb_anon_key

run_k6_single_target() {
  local framing="$1"
  local scenario_js="$2"    # path inside /scenarios/ (e.g. rest-select.js)
  local target="$3"         # "hyperstack" or "supabase"
  local out_file="$4"       # full path under /results/ for summary JSON output
  local hs_rest_url="$5"
  local hs_jwt="$6"
  local hs_user_id="$7"
  local sb_rest_url="$8"
  local sb_jwt="$9"
  local sb_user_id="${10}"
  local sb_anon_key="${11}"

  echo "[run] k6 → target=${target} scenario=${scenario_js} ..."

  local out_basename
  out_basename="$(basename "${out_file}")"

  # k6 exits 99 when thresholds are crossed — that is informative (FAILED tag),
  # not a hard abort. We capture the exit code and tag the result accordingly.
  # Use --summary-export (compact aggregate JSON) not --out json (per-event, huge).
  local k6_exit=0
  docker run --rm \
    --add-host "host.docker.internal:host-gateway" \
    --network "${DOCKER_NETWORK}" \
    -e "TARGET=${target}" \
    -e "HS_REST_URL=${hs_rest_url}" \
    -e "HS_JWT=${hs_jwt}" \
    -e "HS_USER_ID=${hs_user_id}" \
    -e "SB_REST_URL=${sb_rest_url}" \
    -e "SB_JWT=${sb_jwt}" \
    -e "SB_USER_ID=${sb_user_id}" \
    -e "SB_ANON_KEY=${sb_anon_key}" \
    -v "${SCRIPT_DIR}/scenarios:/scenarios:ro" \
    -v "${BENCH_RAW_DIR}:/results" \
    "${K6_IMAGE}" run \
      --summary-export "/results/${out_basename}" \
      "/scenarios/${scenario_js}" || k6_exit=$?

  # k6 exit 0 = all thresholds passed; 99 = threshold(s) crossed; other = script/runtime error.
  if [[ "${k6_exit}" -eq 0 ]]; then
    echo "[run] k6 PASSED (all thresholds) → ${out_file}"
  elif [[ "${k6_exit}" -eq 99 ]]; then
    echo "[run] k6 FAILED (threshold crossed) → ${out_file} [marked FAILED in results]"
    # Annotate the summary JSON with a failed flag so analysis can identify bad runs.
    if [[ -f "${out_file}" ]]; then
      local tmp_file
      tmp_file=$(mktemp)
      node -e "
const fs=require('fs');
const d=JSON.parse(fs.readFileSync('${out_file}','utf8'));
d.__bench_threshold_failed=true;
d.__bench_target='${target}';
fs.writeFileSync('${out_file}',JSON.stringify(d));
" && rm -f "${tmp_file}" || rm -f "${tmp_file}"
    fi
    return 1
  else
    echo "[run] k6 ERROR (exit ${k6_exit}) → ${out_file}" >&2
    return 1
  fi
}

# ── Auth k6 runner (single target) ───────────────────────────────────────────
# Like run_k6_single_target but passes auth-specific env vars instead of REST ones.
# Auth scenarios require HS_AUTH_URL, SB_AUTH_URL, fixture user JSON, BENCH_RUN_ID.
#
# C2 NOTE: Auth throughput is hash-algorithm-bound (Argon2id vs bcrypt).
# Numbers from this runner MUST be interpreted with the C2 caveat from FAIRNESS.md.
#
# Args: framing scenario_js target out_file
#       hs_auth_url hs_fixture_users_json
#       sb_auth_url sb_fixture_users_json sb_anon_key bench_run_id

run_k6_auth_target() {
  local framing="$1"
  local scenario_js="$2"    # e.g. auth-signin.js
  local target="$3"         # "hyperstack" or "supabase"
  local out_file="$4"       # full path under results/raw/
  local hs_auth_url="$5"
  local hs_fixture_users_json="$6"
  local sb_auth_url="$7"
  local sb_fixture_users_json="$8"
  local sb_anon_key="$9"
  local bench_run_id="${10}"

  echo "[run] k6-auth → target=${target} scenario=${scenario_js} ..."

  local out_basename
  out_basename="$(basename "${out_file}")"

  local k6_exit=0
  docker run --rm \
    --add-host "host.docker.internal:host-gateway" \
    --network "${DOCKER_NETWORK}" \
    -e "TARGET=${target}" \
    -e "HS_AUTH_URL=${hs_auth_url}" \
    -e "HS_FIXTURE_USERS_JSON=${hs_fixture_users_json}" \
    -e "SB_AUTH_URL=${sb_auth_url}" \
    -e "SB_FIXTURE_USERS_JSON=${sb_fixture_users_json}" \
    -e "SB_ANON_KEY=${sb_anon_key}" \
    -e "BENCH_RUN_ID=${bench_run_id}" \
    -v "${SCRIPT_DIR}/scenarios:/scenarios:ro" \
    -v "${BENCH_RAW_DIR}:/results" \
    "${K6_IMAGE}" run \
      --summary-export "/results/${out_basename}" \
      "/scenarios/${scenario_js}" || k6_exit=$?

  if [[ "${k6_exit}" -eq 0 ]]; then
    echo "[run] k6-auth PASSED (all thresholds) → ${out_file}"
  elif [[ "${k6_exit}" -eq 99 ]]; then
    echo "[run] k6-auth FAILED (threshold crossed) → ${out_file} [marked FAILED in results]"
    if [[ -f "${out_file}" ]]; then
      local tmp_file
      tmp_file=$(mktemp)
      node -e "
const fs=require('fs');
const d=JSON.parse(fs.readFileSync('${out_file}','utf8'));
d.__bench_threshold_failed=true;
d.__bench_target='${target}';
fs.writeFileSync('${out_file}',JSON.stringify(d));
" && rm -f "${tmp_file}" || rm -f "${tmp_file}"
    fi
    return 1
  else
    echo "[run] k6-auth ERROR (exit ${k6_exit}) → ${out_file}" >&2
    return 1
  fi
}

# ── REST scenario runner ──────────────────────────────────────────────────────
# Runs rest-select + rest-insert, N times each, with SEPARATE k6 invocations
# per target. Order within a run: HS-select, SB-select, HS-insert, SB-insert
# (interleaved so neither target gets consistent "first" or "last" position).
# Tagged output files: k6-{framing}-rest-select-{target}-{runid}-run{N}.json

run_rest_scenarios() {
  local framing="$1"
  local hs_rest_url="$2"
  local hs_jwt="$3"
  local hs_user_id="$4"
  local sb_rest_url="$5"
  local sb_jwt="$6"
  local sb_user_id="$7"
  local sb_anon_key="$8"

  local RUN_ERRORS=0

  for run_n in $(seq 1 "${RUNS}"); do
    echo ""
    echo "[run] REST run ${run_n}/${RUNS} (framing ${framing}) ..."

    # ── rest-select: HyperStack then Supabase (separate k6 invocations) ──────
    local hs_select_out="${BENCH_RAW_DIR}/k6-${framing}-rest-select-hyperstack-${RUNID}-run${run_n}.json"
    local sb_select_out="${BENCH_RAW_DIR}/k6-${framing}-rest-select-supabase-${RUNID}-run${run_n}.json"

    echo "[run] REST-SELECT HyperStack (run ${run_n}) ..."
    if ! run_k6_single_target \
        "${framing}" "rest-select.js" "hyperstack" "${hs_select_out}" \
        "${hs_rest_url}" "${hs_jwt}" "${hs_user_id}" \
        "${sb_rest_url}" "${sb_jwt}" "${sb_user_id}" "${sb_anon_key}"; then
      echo "[run] ERROR: rest-select hyperstack run ${run_n} FAILED" >&2
      (( RUN_ERRORS++ )) || true
    fi

    echo "[run] REST-SELECT Supabase (run ${run_n}) ..."
    if ! run_k6_single_target \
        "${framing}" "rest-select.js" "supabase" "${sb_select_out}" \
        "${hs_rest_url}" "${hs_jwt}" "${hs_user_id}" \
        "${sb_rest_url}" "${sb_jwt}" "${sb_user_id}" "${sb_anon_key}"; then
      echo "[run] ERROR: rest-select supabase run ${run_n} FAILED" >&2
      (( RUN_ERRORS++ )) || true
    fi

    # ── rest-insert: HyperStack then Supabase (separate k6 invocations) ──────
    local hs_insert_out="${BENCH_RAW_DIR}/k6-${framing}-rest-insert-hyperstack-${RUNID}-run${run_n}.json"
    local sb_insert_out="${BENCH_RAW_DIR}/k6-${framing}-rest-insert-supabase-${RUNID}-run${run_n}.json"

    echo "[run] REST-INSERT HyperStack (run ${run_n}) ..."
    if ! run_k6_single_target \
        "${framing}" "rest-insert.js" "hyperstack" "${hs_insert_out}" \
        "${hs_rest_url}" "${hs_jwt}" "${hs_user_id}" \
        "${sb_rest_url}" "${sb_jwt}" "${sb_user_id}" "${sb_anon_key}"; then
      echo "[run] ERROR: rest-insert hyperstack run ${run_n} FAILED" >&2
      (( RUN_ERRORS++ )) || true
    fi

    echo "[run] REST-INSERT Supabase (run ${run_n}) ..."
    if ! run_k6_single_target \
        "${framing}" "rest-insert.js" "supabase" "${sb_insert_out}" \
        "${hs_rest_url}" "${hs_jwt}" "${hs_user_id}" \
        "${sb_rest_url}" "${sb_jwt}" "${sb_user_id}" "${sb_anon_key}"; then
      echo "[run] ERROR: rest-insert supabase run ${run_n} FAILED" >&2
      (( RUN_ERRORS++ )) || true
    fi

    echo "[run] REST run ${run_n} complete."
  done

  return "${RUN_ERRORS}"
}

# ── Auth scenario runner ──────────────────────────────────────────────────────
# Runs auth-signin + auth-signup, N times each, with SEPARATE k6 invocations
# per target (I4 compliance).
# Order within a run: HS-signin, SB-signin, HS-signup, SB-signup
# (interleaved so neither target gets consistent "first" or "last" position).
#
# C2 CAVEAT (printed per run): HyperStack uses Argon2id (memory-hard, ~19 MB/hash);
# Supabase GoTrue uses bcrypt cost=10 (CPU-only). Auth throughput numbers reflect
# DIFFERENT default security postures — NOT a raw apples-to-apples speed comparison.
#
# Args: framing hs_auth_url hs_fixture_users_json
#               sb_auth_url sb_fixture_users_json sb_anon_key

run_auth_scenarios() {
  local framing="$1"
  local hs_auth_url="$2"
  local hs_fixture_users_json="$3"
  local sb_auth_url="$4"
  local sb_fixture_users_json="$5"
  local sb_anon_key="$6"

  echo ""
  echo "[run] ┌─ C2 CAVEAT ─────────────────────────────────────────────────────"
  echo "[run] │  HyperStack  → Argon2id (m=19456 KiB, t=2) — memory-hard KDF"
  echo "[run] │  Supabase    → bcrypt cost=10              — CPU-only hash"
  echo "[run] │  Auth throughput measures TWO things: API overhead + hash cost."
  echo "[run] │  Hash algorithms differ — numbers are NOT directly comparable."
  echo "[run] │  A slower HyperStack auth req/s is expected and correct behavior."
  echo "[run] └────────────────────────────────────────────────────────────────"
  echo ""

  local RUN_ERRORS=0

  for run_n in $(seq 1 "${RUNS}"); do
    echo ""
    echo "[run] AUTH run ${run_n}/${RUNS} (framing ${framing}) ..."

    # ── auth-signin ───────────────────────────────────────────────────────────
    local hs_signin_out="${BENCH_RAW_DIR}/k6-${framing}-auth-signin-hyperstack-${RUNID}-run${run_n}.json"
    local sb_signin_out="${BENCH_RAW_DIR}/k6-${framing}-auth-signin-supabase-${RUNID}-run${run_n}.json"

    echo "[run] AUTH-SIGNIN HyperStack (run ${run_n}) ..."
    if ! run_k6_auth_target \
        "${framing}" "auth-signin.js" "hyperstack" "${hs_signin_out}" \
        "${hs_auth_url}" "${hs_fixture_users_json}" \
        "${sb_auth_url}" "${sb_fixture_users_json}" \
        "${sb_anon_key}" "${RUNID}"; then
      echo "[run] ERROR: auth-signin hyperstack run ${run_n} FAILED" >&2
      (( RUN_ERRORS++ )) || true
    fi

    echo "[run] AUTH-SIGNIN Supabase (run ${run_n}) ..."
    if ! run_k6_auth_target \
        "${framing}" "auth-signin.js" "supabase" "${sb_signin_out}" \
        "${hs_auth_url}" "${hs_fixture_users_json}" \
        "${sb_auth_url}" "${sb_fixture_users_json}" \
        "${sb_anon_key}" "${RUNID}"; then
      echo "[run] ERROR: auth-signin supabase run ${run_n} FAILED" >&2
      (( RUN_ERRORS++ )) || true
    fi

    # ── auth-signup ───────────────────────────────────────────────────────────
    local hs_signup_out="${BENCH_RAW_DIR}/k6-${framing}-auth-signup-hyperstack-${RUNID}-run${run_n}.json"
    local sb_signup_out="${BENCH_RAW_DIR}/k6-${framing}-auth-signup-supabase-${RUNID}-run${run_n}.json"

    # Signup run ID: embed framing + run_n so each run+framing registers fresh unique emails.
    # Without framing: both framings share the Supabase GoTrue backend, so framing B's
    # run 1 would collide with framing A's run 1 emails.
    # Without run_n: k6 restarts __VU/__ITER from 0 each invocation, causing
    # duplicate-email errors on runs 2-5 (409 HS, 422 Supabase).
    local signup_run_id="${RUNID}${framing}r${run_n}"

    echo "[run] AUTH-SIGNUP HyperStack (run ${run_n}) ..."
    if ! run_k6_auth_target \
        "${framing}" "auth-signup.js" "hyperstack" "${hs_signup_out}" \
        "${hs_auth_url}" "${hs_fixture_users_json}" \
        "${sb_auth_url}" "${sb_fixture_users_json}" \
        "${sb_anon_key}" "${signup_run_id}"; then
      echo "[run] ERROR: auth-signup hyperstack run ${run_n} FAILED" >&2
      (( RUN_ERRORS++ )) || true
    fi

    echo "[run] AUTH-SIGNUP Supabase (run ${run_n}) ..."
    if ! run_k6_auth_target \
        "${framing}" "auth-signup.js" "supabase" "${sb_signup_out}" \
        "${hs_auth_url}" "${hs_fixture_users_json}" \
        "${sb_auth_url}" "${sb_fixture_users_json}" \
        "${sb_anon_key}" "${signup_run_id}"; then
      echo "[run] ERROR: auth-signup supabase run ${run_n} FAILED" >&2
      (( RUN_ERRORS++ )) || true
    fi

    echo "[run] AUTH run ${run_n} complete."
  done

  return "${RUN_ERRORS}"
}

# ── Realtime scenario runner ──────────────────────────────────────────────────
# Runs realtime-driver.mjs for both targets, then a fanout ramp.
# Outputs JSON files to bench/results/raw/rt-{framing}-{target}-{runid}-run{N}.json
#
# C3 NOTE: Driver runs on HOST (not Docker) — path is symmetric:
#   Host Node → HyperStack: http://127.0.0.1:<HS_PORT> (localhost)
#   Host Node → Supabase:   http://localhost:54321 via Kong (localhost)
# Unlike k6 REST/auth scenarios, realtime has NO network-hop asymmetry (I1 does
# NOT apply). The measured latency reflects only the realtime delivery path.

run_realtime_scenarios() {
  local framing="$1"
  local hs_base_url="$2"
  local hs_jwt="$3"
  local hs_user_id="$4"
  local hs_service_key="$5"
  local hs_pg_port="$6"
  local hs_pg_pass="$7"
  local hs_db="$8"
  local sb_jwt="$9"
  local sb_user_id="${10}"
  local sb_service_jwt="${11}"
  local sb_anon_key="${12}"

  local SB_BASE_URL="http://localhost:55421"
  local RUN_ERRORS=0

  echo ""
  echo "[run] ┌─ C3 NOTE ────────────────────────────────────────────────────────"
  echo "[run] │  Realtime driver runs on HOST (not Docker): symmetric network path."
  echo "[run] │  Host Node → HS: http://127.0.0.1:<PORT> (no extra hop)"
  echo "[run] │  Host Node → SB: http://localhost:54321 via Kong (no extra hop)"
  echo "[run] │  I1 (k6 hop asymmetry) does NOT apply to this scenario."
  echo "[run] │  HS RLS re-fetch per delivery: O(N) per insert — see FAIRNESS.md §C3"
  echo "[run] └──────────────────────────────────────────────────────────────────"
  echo ""

  # Fixed-N bench runs (per target)
  for run_n in $(seq 1 "${RUNS}"); do
    echo ""
    echo "[run] REALTIME bench run ${run_n}/${RUNS} (framing ${framing}) ..."

    for rt_target in "hyperstack" "supabase"; do
      local out_json="${BENCH_RAW_DIR}/rt-${framing}-${rt_target}-${RUNID}-run${run_n}.json"
      echo "[run] REALTIME ${rt_target} run ${run_n} → ${out_json}"

      node "${SCRIPT_DIR}/scenarios/realtime-driver.mjs" \
        --target "${rt_target}" \
        --hs-url "${hs_base_url}" \
        --hs-jwt "${hs_jwt}" \
        --hs-service-key "${hs_service_key}" \
        --hs-user-id "${hs_user_id}" \
        --hs-pg-port "${hs_pg_port}" \
        --hs-pg-pass "${hs_pg_pass}" \
        --hs-db "${hs_db}" \
        --sb-url "${SB_BASE_URL}" \
        --sb-jwt "${sb_jwt}" \
        --sb-service-jwt "${sb_service_jwt}" \
        --sb-anon-key "${sb_anon_key}" \
        --sb-user-id "${sb_user_id}" \
        --n "${RT_N}" --m "${RT_M}" --d "${RT_D}" \
        --runs 1 \
        --mode bench \
        > "${out_json}" 2>/dev/null || {
          echo "[run] WARNING: realtime ${rt_target} run ${run_n} returned non-zero" >&2
          (( RUN_ERRORS++ )) || true
        }

      echo "[run] REALTIME ${rt_target} run ${run_n} complete."
    done
  done

  # Fanout ramp (single pass, covers both targets separately)
  for rt_target in "hyperstack" "supabase"; do
    local fanout_json="${BENCH_RAW_DIR}/rt-${framing}-${rt_target}-${RUNID}-fanout.json"
    echo ""
    echo "[run] REALTIME fanout ramp: ${rt_target} levels=${RT_FANOUT_LEVELS} → ${fanout_json}"

    node "${SCRIPT_DIR}/scenarios/realtime-driver.mjs" \
      --target "${rt_target}" \
      --hs-url "${hs_base_url}" \
      --hs-jwt "${hs_jwt}" \
      --hs-service-key "${hs_service_key}" \
      --hs-user-id "${hs_user_id}" \
      --hs-pg-port "${hs_pg_port}" \
      --hs-pg-pass "${hs_pg_pass}" \
      --hs-db "${hs_db}" \
      --sb-url "${SB_BASE_URL}" \
      --sb-jwt "${sb_jwt}" \
      --sb-service-jwt "${sb_service_jwt}" \
      --sb-anon-key "${sb_anon_key}" \
      --sb-user-id "${sb_user_id}" \
      --m "${RT_M}" --d "${RT_D}" \
      --mode fanout \
      --fanout-levels "${RT_FANOUT_LEVELS}" \
      > "${fanout_json}" 2>/dev/null || {
        echo "[run] WARNING: realtime fanout ${rt_target} returned non-zero" >&2
        (( RUN_ERRORS++ )) || true
      }

    echo "[run] REALTIME fanout ${rt_target} complete."
  done

  return "${RUN_ERRORS}"
}

# ── Storage scenario runner ───────────────────────────────────────────────────
# Runs storage-updownload.js, N times each, with SEPARATE k6 invocations
# per target (I4 compliance).
# Order within a run: HS, SB (interleaved so neither target gets consistent position).
# Uploads 64 KB + 1 MB objects (authed PUT), downloads them (authed GET).
# Validity: upload 2xx, download 200 + correct content-length.
#
# Storage URL mapping:
#   HyperStack:  <HS_BASE_URL>/storage/v1  (same binary handles storage)
#   Supabase:    http://supabase_storage_SDTool:5000  (direct container, bypass Kong, framing A)
#               or http://supabase_kong_SDTool:8000/storage/v1  (framing B, through Kong)
#
# Args: framing hs_storage_url hs_jwt sb_storage_url sb_jwt sb_anon_key

run_storage_scenarios() {
  local framing="$1"
  local hs_storage_url="$2"
  local hs_service_key="$3"
  local sb_storage_url="$4"
  local sb_service_jwt="$5"
  local sb_anon_key="$6"

  local RUN_ERRORS=0

  for run_n in $(seq 1 "${RUNS}"); do
    echo ""
    echo "[run] STORAGE run ${run_n}/${RUNS} (framing ${framing}) ..."

    # ── HyperStack storage ────────────────────────────────────────────────────
    local hs_storage_out="${BENCH_RAW_DIR}/k6-${framing}-storage-hyperstack-${RUNID}-run${run_n}.json"
    echo "[run] STORAGE HyperStack (run ${run_n}) ..."
    if ! run_k6_storage_target \
        "${framing}" "storage-updownload.js" "hyperstack" "${hs_storage_out}" \
        "${hs_storage_url}" "${hs_service_key}" \
        "${sb_storage_url}" "${sb_service_jwt}" "${sb_anon_key}"; then
      echo "[run] ERROR: storage hyperstack run ${run_n} FAILED" >&2
      (( RUN_ERRORS++ )) || true
    fi

    # ── Supabase storage ──────────────────────────────────────────────────────
    local sb_storage_out="${BENCH_RAW_DIR}/k6-${framing}-storage-supabase-${RUNID}-run${run_n}.json"
    echo "[run] STORAGE Supabase (run ${run_n}) ..."
    if ! run_k6_storage_target \
        "${framing}" "storage-updownload.js" "supabase" "${sb_storage_out}" \
        "${hs_storage_url}" "${hs_service_key}" \
        "${sb_storage_url}" "${sb_service_jwt}" "${sb_anon_key}"; then
      echo "[run] ERROR: storage supabase run ${run_n} FAILED" >&2
      (( RUN_ERRORS++ )) || true
    fi

    echo "[run] STORAGE run ${run_n} complete."
  done

  return "${RUN_ERRORS}"
}

# ── Storage k6 runner (single target) ────────────────────────────────────────
# Like run_k6_single_target but passes storage-specific env vars.
#
# Args: framing scenario_js target out_file
#       hs_storage_url hs_jwt
#       sb_storage_url sb_jwt sb_anon_key

run_k6_storage_target() {
  local framing="$1"
  local scenario_js="$2"
  local target="$3"
  local out_file="$4"
  local hs_storage_url="$5"
  local hs_service_key="$6"
  local sb_storage_url="$7"
  local sb_service_jwt="$8"
  local sb_anon_key="$9"

  echo "[run] k6-storage → target=${target} scenario=${scenario_js} ..."

  local out_basename
  out_basename="$(basename "${out_file}")"

  local k6_exit=0
  docker run --rm \
    --add-host "host.docker.internal:host-gateway" \
    --network "${DOCKER_NETWORK}" \
    -e "TARGET=${target}" \
    -e "HS_STORAGE_URL=${hs_storage_url}" \
    -e "HS_SERVICE_KEY=${hs_service_key}" \
    -e "SB_STORAGE_URL=${sb_storage_url}" \
    -e "SB_SERVICE_JWT=${sb_service_jwt}" \
    -e "SB_ANON_KEY=${sb_anon_key}" \
    -v "${SCRIPT_DIR}/scenarios:/scenarios:ro" \
    -v "${BENCH_RAW_DIR}:/results" \
    "${K6_IMAGE}" run \
      --summary-export "/results/${out_basename}" \
      "/scenarios/${scenario_js}" || k6_exit=$?

  if [[ "${k6_exit}" -eq 0 ]]; then
    echo "[run] k6-storage PASSED (all thresholds) → ${out_file}"
  elif [[ "${k6_exit}" -eq 99 ]]; then
    echo "[run] k6-storage FAILED (threshold crossed) → ${out_file} [marked FAILED in results]"
    if [[ -f "${out_file}" ]]; then
      local tmp_file
      tmp_file=$(mktemp)
      node -e "
const fs=require('fs');
const d=JSON.parse(fs.readFileSync('${out_file}','utf8'));
d.__bench_threshold_failed=true;
d.__bench_target='${target}';
fs.writeFileSync('${out_file}',JSON.stringify(d));
" && rm -f "${tmp_file}" || rm -f "${tmp_file}"
    fi
    return 1
  else
    echo "[run] k6-storage ERROR (exit ${k6_exit}) → ${out_file}" >&2
    return 1
  fi
}

# ── Stale-binary guard ────────────────────────────────────────────────────────
# Ensure target/release/hyperstack is built from current source before any
# framing boots. `cargo build --release -p hyperstack` is a no-op when the
# binary is already up-to-date (cargo checks mtimes). This prevents a stale
# binary (e.g. predating a feature mount like /realtime/v1/websocket) from
# producing incorrect results.

ensure_fresh_binary() {
  # PACKAGE MODE: no source tree. Use the BUNDLED prebuilt binary (no cargo build).
  # HS_BINARY is set by config.sh to the bundled ./hyperstack (see config.sh override).
  if [[ ! -x "${HS_BINARY}" ]]; then
    echo "[run] ERROR: bundled binary not found/executable at ${HS_BINARY}" >&2
    return 1
  fi
  echo "[run] Using bundled binary (package mode): ${HS_BINARY}"
}

# ── Per-framing runner ────────────────────────────────────────────────────────

run_framing() {
  local framing="$1"
  echo "════════════════════════════════════════════════════"
  echo "[run] Framing ${framing} start"
  echo "════════════════════════════════════════════════════"

  # a. Boot target
  bash "${SCRIPT_DIR}/targets/framing-${framing}.sh" up

  # b. Source the env file
  local env_file="${BENCH_RESULTS_DIR}/framing-${framing}.env"
  if [[ ! -f "${env_file}" ]]; then
    echo "[run] ERROR: env file not found after up: ${env_file}" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "${env_file}"

  # c. Seed (unless skipped)
  if [[ "${SKIP_SEED}" -eq 0 ]]; then
    echo "[run] Seeding fixtures ..."
    node "${SCRIPT_DIR}/fixtures/seed.mjs" \
      --framing "${framing}" \
      --users "${FIXTURE_K}" \
      --rows "${FIXTURE_R}" \
      --storage-objects "${FIXTURE_S}"
  else
    echo "[run] Skipping seed (--skip-seed)."
    local seed_file="${BENCH_RESULTS_DIR}/framing-${framing}-seed.json"
    if [[ ! -f "${seed_file}" ]]; then
      echo "[run] ERROR: seed file not found and --skip-seed given: ${seed_file}" >&2
      return 1
    fi
  fi

  # d. Selfcheck
  if [[ "${SKIP_SELFCHECK}" -eq 0 ]]; then
    echo "[run] Running selfcheck ..."
    if ! node "${SCRIPT_DIR}/selfcheck.mjs" --framing "${framing}"; then
      echo "[run] ERROR: selfcheck failed for framing ${framing}" >&2
      bash "${SCRIPT_DIR}/targets/framing-${framing}.sh" down
      return 1
    fi
  else
    echo "[run] Skipping selfcheck (--skip-selfcheck)."
  fi

  # e. Read JWTs + user IDs from seed file
  local seed_file="${BENCH_RESULTS_DIR}/framing-${framing}-seed.json"

  local hs_jwt
  hs_jwt=$(node -e "const s=JSON.parse(require('fs').readFileSync('${seed_file}','utf8')); console.log(s.hyperstack.users[0].jwt || '')")
  local sb_jwt
  sb_jwt=$(node -e "const s=JSON.parse(require('fs').readFileSync('${seed_file}','utf8')); console.log(s.supabase.users[0].jwt || '')")

  # User IDs needed for REST INSERT (owner field)
  local hs_user_id
  hs_user_id=$(node -e "const s=JSON.parse(require('fs').readFileSync('${seed_file}','utf8')); console.log(s.hyperstack.users[0].userId || s.hyperstack.users[0].id || '')")
  local sb_user_id
  sb_user_id=$(node -e "const s=JSON.parse(require('fs').readFileSync('${seed_file}','utf8')); console.log(s.supabase.users[0].userId || s.supabase.users[0].id || '')")

  if [[ -z "${hs_jwt}" ]]; then
    echo "[run] WARNING: HyperStack JWT is empty — REST checks in k6 may fail." >&2
  fi
  if [[ -z "${sb_jwt}" ]]; then
    echo "[run] WARNING: Supabase JWT is empty — REST checks in k6 may fail." >&2
  fi

  # f. Build k6 URLs (docker-network-internal)
  local hs_rest_url_k6="${HS_BASE_URL_K6}/rest/v1"
  local sb_rest_url_k6="${SB_REST_URL_K6}"

  # Auth URLs for k6 (docker-network-internal)
  # HS auth is on the same base URL as REST; SB auth hits GoTrue container directly.
  local hs_auth_url_k6="${HS_BASE_URL_K6}/auth/v1"
  local sb_auth_url_k6="${SB_AUTH_URL_K6}"   # e.g. http://supabase_auth_SDTool:9999

  # Build fixture user JSON arrays for auth scenarios (email + password pairs).
  # Cycling through all K fixture users gives more realistic load distribution.
  local hs_fixture_users_json
  hs_fixture_users_json=$(node -e "
const s=JSON.parse(require('fs').readFileSync('${seed_file}','utf8'));
const users=s.hyperstack.users.map(u=>({email:u.email,password:'bench_password_123'}));
console.log(JSON.stringify(users));
")
  local sb_fixture_users_json
  sb_fixture_users_json=$(node -e "
const s=JSON.parse(require('fs').readFileSync('${seed_file}','utf8'));
const users=s.supabase.users.map(u=>({email:u.email,password:'bench_password_123'}));
console.log(JSON.stringify(users));
")

  # g. Run scenario(s)
  if [[ "${SCENARIO_IS_STORAGE}" -eq 1 ]]; then
    # STORAGE: separate k6 invocations per target (I4 compliance).
    # HS storage: same base URL as REST (single binary handles all endpoints).
    # SB storage: direct container in framing A (bypass Kong), Kong path in framing B.
    # Both targets use /storage/v1/object/<bucket>/<path> — same URL shape.
    local hs_storage_url_k6="${HS_BASE_URL_K6}/storage/v1"
    # Framing A: direct to storage container; Framing B: through Kong
    local sb_storage_url_k6
    if [[ "${framing}" == "a" ]]; then
      sb_storage_url_k6="http://${SB_STORAGE_CONTAINER}:5000"
    else
      sb_storage_url_k6="http://${SB_KONG_CONTAINER}:8000/storage/v1"
    fi

    echo "[run] Storage URL: HS=${hs_storage_url_k6} SB=${sb_storage_url_k6}"

    # Storage uses service-role JWTs (see comment in storage-updownload.js):
    # Both targets use service-role to bypass storage-level RLS policy evaluation.
    # This measures raw storage throughput symmetrically on both sides.
    local storage_errors=0
    if ! run_storage_scenarios "${framing}" \
        "${hs_storage_url_k6}" "${HS_SERVICE_KEY}" \
        "${sb_storage_url_k6}" "${SB_SERVICE_JWT}" \
        "${SB_ANON_JWT}"; then
      storage_errors=$?
    fi
    if [[ "${storage_errors}" -gt 0 ]]; then
      echo "[run] WARNING: ${storage_errors} STORAGE k6 run(s) failed in framing ${framing}" >&2
    fi
  elif [[ "${SCENARIO_IS_REALTIME}" -eq 1 ]]; then
    # REALTIME: Node driver (not k6) — symmetric host-to-host path for both targets.
    # C3 caveat: printed inside run_realtime_scenarios.
    local rt_errors=0
    if ! run_realtime_scenarios "${framing}" \
        "${HS_BASE_URL}" "${hs_jwt}" "${hs_user_id}" \
        "${HS_SERVICE_KEY}" "${HS_PG_PORT}" "${HS_PG_PASS}" "${HS_DB}" \
        "${sb_jwt}" "${sb_user_id}" \
        "${SB_SERVICE_JWT}" "${SB_ANON_JWT}"; then
      rt_errors=$?
    fi
    if [[ "${rt_errors}" -gt 0 ]]; then
      echo "[run] WARNING: ${rt_errors} REALTIME run(s) had errors in framing ${framing}" >&2
    fi
  elif [[ "${SCENARIO_IS_AUTH}" -eq 1 ]]; then
    # AUTH: separate k6 invocations per target per sub-scenario (I4 compliance)
    # C2: prints caveat banner per run; numbers reflect algorithm choice, not just speed.
    local auth_errors=0
    if ! run_auth_scenarios "${framing}" \
        "${hs_auth_url_k6}" "${hs_fixture_users_json}" \
        "${sb_auth_url_k6}" "${sb_fixture_users_json}" \
        "${SB_ANON_JWT}"; then
      auth_errors=$?
    fi
    if [[ "${auth_errors}" -gt 0 ]]; then
      echo "[run] WARNING: ${auth_errors} AUTH k6 run(s) failed in framing ${framing}" >&2
    fi
  elif [[ "${SCENARIO_IS_MULTI}" -eq 1 ]]; then
    # REST: separate k6 invocations per target per sub-scenario (I4 compliance)
    local rest_errors=0
    if ! run_rest_scenarios "${framing}" \
        "${hs_rest_url_k6}" "${hs_jwt}" "${hs_user_id}" \
        "${sb_rest_url_k6}" "${sb_jwt}" "${sb_user_id}" \
        "${SB_ANON_JWT}"; then
      rest_errors=$?
    fi
    if [[ "${rest_errors}" -gt 0 ]]; then
      echo "[run] WARNING: ${rest_errors} REST k6 run(s) failed in framing ${framing}" >&2
    fi
  else
    # Single-file scenario (smoke, etc.)
    for run_n in $(seq 1 "${RUNS}"); do
      echo ""
      echo "[run] k6 run ${run_n}/${RUNS} (framing ${framing}) ..."

      local out_json="${BENCH_RAW_DIR}/k6-${framing}-${RUNID}-run${run_n}.json"

      docker run --rm \
        --add-host "host.docker.internal:host-gateway" \
        --network "${DOCKER_NETWORK}" \
        -e "HS_REST_URL=${hs_rest_url_k6}" \
        -e "HS_JWT=${hs_jwt}" \
        -e "SB_REST_URL=${sb_rest_url_k6}" \
        -e "SB_JWT=${sb_jwt}" \
        -e "SB_ANON_KEY=${SB_ANON_JWT}" \
        -v "${SCRIPT_DIR}/scenarios:/scenarios:ro" \
        -v "${BENCH_RAW_DIR}:/results" \
        "${K6_IMAGE}" run \
          --out "json=/results/k6-${framing}-${RUNID}-run${run_n}.json" \
          "/scenarios/${SCENARIO}.js"

      echo "[run] k6 output written to ${out_json}"
    done
  fi

  # h. Manifest
  echo "[run] Writing manifest ..."
  node "${SCRIPT_DIR}/targets/manifest.mjs" \
    --runid "${RUNID}" \
    --timestamp "${TIMESTAMP}" \
    --framing "${framing}" \
    --fixture-k "${FIXTURE_K}" \
    --fixture-r "${FIXTURE_R}" \
    --fixture-s "${FIXTURE_S}"

  # i. Teardown
  echo "[run] Tearing down framing ${framing} ..."
  bash "${SCRIPT_DIR}/targets/framing-${framing}.sh" down

  echo ""
  echo "[run] Framing ${framing} complete."
}

# ── Main ──────────────────────────────────────────────────────────────────────

FRAMINGS=()
if [[ "${FRAMING}" == "both" ]]; then
  FRAMINGS=("a" "b")
else
  FRAMINGS=("${FRAMING}")
fi

# ── Footprint scenario: special path — does NOT boot/teardown framings ────────
# Footprint measures the currently-running stack. It reads the existing env file
# for the specified framing (default: a) but does NOT call framing-a.sh up/down.
# The framing must already be up (HyperStack running, Supabase running).
if [[ "${SCENARIO_IS_FOOTPRINT}" -eq 1 ]]; then
  echo ""
  echo "════════════════════════════════════════════════════"
  echo "[run] FOOTPRINT measurement (framing ${FRAMING})"
  echo "════════════════════════════════════════════════════"
  echo ""

  # Stale-binary guard still applies (cold-start test will restart the binary)
  if ! ensure_fresh_binary; then
    echo "[run] FATAL: stale-binary guard failed — aborting." >&2
    exit 1
  fi

  # Ensure framing is up (env file must exist + HS must be running)
  ENV_FILE="${BENCH_RESULTS_DIR}/framing-${FRAMING}.env"
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "[run] ERROR: framing-${FRAMING}.env not found. Run: bash bench/targets/framing-${FRAMING}.sh up" >&2
    exit 1
  fi

  FOOTPRINT_EXIT=0
  bash "${SCRIPT_DIR}/footprint/measure.sh" --framing "${FRAMING}" || FOOTPRINT_EXIT=$?

  echo ""
  echo "════════════════════════════════════════════════════"
  if [[ "${FOOTPRINT_EXIT}" -eq 0 ]]; then
    echo "[run] FOOTPRINT DONE. Run ID: ${RUNID}"
    echo "[run] Results in: ${BENCH_RAW_DIR}/"
    ls -lh "${BENCH_RAW_DIR}/" 2>/dev/null | grep "footprint" | tail -5 || true
  else
    echo "[run] FOOTPRINT FAILED (exit ${FOOTPRINT_EXIT}). Run ID: ${RUNID}"
    exit 1
  fi
  echo "════════════════════════════════════════════════════"
  exit 0
fi

# Stale-binary guard: rebuild before ANY framing boots so no run can use a
# binary that predates source changes (e.g. a feature endpoint mount).
if ! ensure_fresh_binary; then
  echo "[run] FATAL: stale-binary guard failed — aborting." >&2
  exit 1
fi

RUN_ERRORS=0
for f in "${FRAMINGS[@]}"; do
  if ! run_framing "${f}"; then
    echo "[run] ERROR: framing ${f} failed." >&2
    (( RUN_ERRORS++ )) || true
  fi
done

echo ""
echo "════════════════════════════════════════════════════"
if [[ "${RUN_ERRORS}" -eq 0 ]]; then
  echo "[run] ALL DONE. Run ID: ${RUNID}"
  echo "[run] Results in: ${BENCH_RAW_DIR}/"
  ls -lh "${BENCH_RAW_DIR}/" 2>/dev/null | grep "${RUNID}" || true
else
  echo "[run] DONE WITH ${RUN_ERRORS} ERROR(S). Run ID: ${RUNID}"
  exit 1
fi
echo "════════════════════════════════════════════════════"
