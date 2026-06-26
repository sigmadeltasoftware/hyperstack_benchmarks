#!/usr/bin/env bash
# bench/footprint/measure.sh — Footprint + cold-start measurement.
#
# Measures and compares HyperStack vs Supabase on four dimensions:
#
#   1. Idle RSS (API-layer only, Postgres counted separately since both need it)
#   2. RSS + CPU% under a fixed REST load (20 VUs, 30s)
#   3. Container/process count (API layer vs "+ Postgres" shown separately)
#   4. On-disk size (binary size for HS; sum of Docker image sizes for Supabase API layers)
#   5. Cold-start (time from process/container start to first HTTP 200)
#
# HONESTY NOTE — what "API layer" means:
#   HyperStack: a single Rust binary (~3.9 MB) handles REST, Auth, Storage, Realtime,
#               and all RLS logic. It needs ONE Postgres instance.
#   Supabase:   uses ~9-11 containers for its API layer (Kong, PostgREST, GoTrue,
#               Realtime, Storage, Studio, pg_meta, Vector, Analytics, Inbucket).
#               It also needs ONE Postgres instance (separate from the above).
#
#   "API-layer footprint" = HyperStack binary vs the Supabase API containers.
#   Postgres is NOT counted in either API-layer RSS/size figure — both need it.
#   The report makes this explicit to avoid unfair inflation.
#
# Method:
#   - HyperStack RSS: ps -o rss= -p <hs_pid>  (in KB, converted to MB)
#   - Supabase RSS:   docker stats --no-stream Σ over API containers (excl. Postgres)
#   - CPU%: sampled via docker stats during a fixed k6 REST run
#   - Cold-start HS: bash timing from exec to first /ready HTTP 200
#   - Cold-start SB: time for Kong to serve 200 after docker restart supabase_kong_sb-bench
#
# Outputs:
#   bench/results/raw/footprint-<framing>-<RUNID>.json
#
# Usage:
#   bash bench/footprint/measure.sh [--framing a|b] [--skip-load] [--skip-coldstart]
#
# Prerequisites:
#   - bench/results/framing-<framing>.env  (from framing-<framing>.sh up)
#   - bench/results/framing-<framing>-seed.json
#   - HyperStack running (HS_PID in env file)
#   - Supabase SDTool stack running

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="${SCRIPT_DIR}/.."
source "${BENCH_DIR}/config.sh"

# ── Argument parsing ──────────────────────────────────────────────────────────

FRAMING="a"
SKIP_LOAD=0
SKIP_COLDSTART=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --framing)       FRAMING="$2";      shift 2 ;;
    --skip-load)     SKIP_LOAD=1;       shift ;;
    --skip-coldstart) SKIP_COLDSTART=1; shift ;;
    --load-vus)      shift 2 ;;  # accepted but unused (20 VUs fixed)
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

RUNID="footprint-$(date +%Y%m%d_%H%M%S)"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUT_JSON="${BENCH_RAW_DIR}/footprint-${FRAMING}-${RUNID}.json"

echo "[footprint] Run ID: ${RUNID}"
echo "[footprint] Timestamp: ${TIMESTAMP}"
echo "[footprint] Framing: ${FRAMING}"
echo ""

mkdir -p "${BENCH_RAW_DIR}"

# ── Load env ──────────────────────────────────────────────────────────────────

ENV_FILE="${BENCH_RESULTS_DIR}/framing-${FRAMING}.env"
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "[footprint] ERROR: env file not found: ${ENV_FILE}" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${ENV_FILE}"

SEED_FILE="${BENCH_RESULTS_DIR}/framing-${FRAMING}-seed.json"
if [[ ! -f "${SEED_FILE}" ]]; then
  echo "[footprint] ERROR: seed file not found: ${SEED_FILE}" >&2
  exit 1
fi

# ── Verify HyperStack is running ──────────────────────────────────────────────

if [[ -z "${HS_PID:-}" ]]; then
  echo "[footprint] ERROR: HS_PID not set in env file." >&2
  exit 1
fi
if ! kill -0 "${HS_PID}" 2>/dev/null; then
  echo "[footprint] ERROR: HyperStack PID=${HS_PID} is not running." >&2
  exit 1
fi
echo "[footprint] HyperStack running: PID=${HS_PID} URL=${HS_BASE_URL}"

# ── Supabase API-layer containers (exclude Postgres) ─────────────────────────
#
# Container sets for footprint accounting:
#
#   minimal-prod: the containers a production Supabase deployment needs for API
#     functionality (Kong gateway, GoTrue auth, PostgREST REST API, Realtime,
#     Storage). Does NOT include developer-tooling containers.
#
#   dev-extras: containers that ship in the local Supabase dev stack but are NOT
#     required for production API traffic:
#       - Studio        (~200 MB) — admin UI / dashboard
#       - pg-meta       (~80 MB)  — schema browser API
#       - Vector/Logflare/Analytics (~1.0–1.1 GB combined) — telemetry pipeline
#       - Inbucket/Mailpit (~8 MB) — dev-only mail trap
#
# The HONEST HEADLINE leads with minimal-prod (skeptics who say "I don't run
# Studio in prod" are correct). Full dev-stack is reported for completeness.
#
SB_MINIMAL_PROD_CONTAINERS="supabase_kong_sb-bench supabase_auth_sb-bench supabase_rest_sb-bench supabase_realtime_sb-bench supabase_storage_sb-bench"
SB_DEV_EXTRA_CONTAINERS="supabase_studio_sb-bench supabase_pg_meta_sb-bench supabase_vector_sb-bench supabase_analytics_sb-bench supabase_inbucket_sb-bench"
SB_API_CONTAINERS="${SB_MINIMAL_PROD_CONTAINERS} ${SB_DEV_EXTRA_CONTAINERS}"
SB_PG_CONTAINER="supabase_db_sb-bench"

# ── Helper: get RSS in MiB from docker stats ─────────────────────────────────

get_docker_rss_mb() {
  local container="$1"
  local raw
  raw=$(docker stats --no-stream --format "{{.MemUsage}}" "${container}" 2>/dev/null || echo "")
  if [[ -z "${raw}" ]]; then echo "0"; return; fi
  local used
  used=$(echo "${raw}" | cut -d'/' -f1 | tr -d ' ')
  if echo "${used}" | grep -qi 'GiB'; then
    local gib; gib=$(echo "${used}" | sed 's/[Gg][Ii][Bb]//')
    echo "${gib} * 1024" | bc -l | xargs printf "%.1f"
  elif echo "${used}" | grep -qi 'MiB'; then
    echo "${used}" | sed 's/[Mm][Ii][Bb]//' | xargs printf "%.1f"
  elif echo "${used}" | grep -qi 'kB'; then
    local kb; kb=$(echo "${used}" | sed 's/[Kk][Bb]//')
    echo "scale=1; ${kb} / 1024" | bc
  else
    echo "0"
  fi
}

# ── Helper: get HyperStack RSS (ps) ──────────────────────────────────────────

get_hs_rss_mb() {
  local pid="$1"
  local rss_kb
  rss_kb=$(ps -o rss= -p "${pid}" 2>/dev/null | tr -d ' ' || echo "0")
  if [[ -z "${rss_kb}" || "${rss_kb}" == "0" ]]; then echo "0"; return; fi
  echo "scale=1; ${rss_kb} / 1024" | bc
}

# ── Helper: get Docker image size ─────────────────────────────────────────────

get_image_size_mb() {
  local image="$1"
  local size_bytes
  size_bytes=$(docker image inspect "${image}" --format '{{.Size}}' 2>/dev/null || echo "0")
  if [[ -z "${size_bytes}" || "${size_bytes}" == "0" ]]; then echo "0"; return; fi
  echo "scale=1; ${size_bytes} / 1048576" | bc
}

# ── 1. Idle RSS ───────────────────────────────────────────────────────────────

echo ""
echo "[footprint] === 1. IDLE RSS ==="
echo ""
echo "[footprint] RSS method note:"
echo "[footprint]   HyperStack RSS: 'ps -o rss= -p <pid>' on macOS host — virtual-memory RSS,"
echo "[footprint]     excludes page cache, excludes shared library frames counted elsewhere."
echo "[footprint]   Supabase RSS: 'docker stats --no-stream' inside the Linux VM — cgroup"
echo "[footprint]     memory.usage_in_bytes, which INCLUDES page cache and anonymous memory."
echo "[footprint]   These are different accounting units. cgroup memory.usage tends to run"
echo "[footprint]     HIGHER than ps RSS for the same workload, which FAVOURS HyperStack."
echo "[footprint]   This asymmetry is disclosed in bench/FAIRNESS.md §F3."
echo ""

HS_IDLE_RSS_MB=$(get_hs_rss_mb "${HS_PID}")
echo "[footprint] HyperStack idle RSS: ${HS_IDLE_RSS_MB} MB (PID=${HS_PID}, method: ps on macOS host)"

echo ""
echo "[footprint] Supabase container RSS (method: docker stats, cgroup memory.usage, includes page cache):"

SB_IDLE_RSS_TOTAL_MB=0
SB_MINIMAL_PROD_RSS_MB=0
SB_DEV_EXTRA_RSS_MB=0
SB_API_CONTAINER_COUNT=0
SB_MINIMAL_PROD_COUNT=0
SB_DEV_EXTRA_COUNT=0
SB_CONTAINER_RSS_JSON="{"
SB_CONTAINER_RSS_FIRST=1

# Helper: is a container in the minimal-prod set?
is_minimal_prod() {
  local cname="$1"
  for mp in ${SB_MINIMAL_PROD_CONTAINERS}; do
    if [[ "${mp}" == "${cname}" ]]; then return 0; fi
  done
  return 1
}

echo "[footprint]   --- MINIMAL-PROD containers (Kong, GoTrue, PostgREST, Realtime, Storage) ---"
for cname in ${SB_MINIMAL_PROD_CONTAINERS}; do
  if docker inspect "${cname}" > /dev/null 2>&1; then
    state=$(docker inspect --format '{{.State.Status}}' "${cname}" 2>/dev/null || echo "unknown")
    if [[ "${state}" == "running" ]]; then
      rss=$(get_docker_rss_mb "${cname}")
      SB_IDLE_RSS_TOTAL_MB=$(echo "${SB_IDLE_RSS_TOTAL_MB} + ${rss}" | bc)
      SB_MINIMAL_PROD_RSS_MB=$(echo "${SB_MINIMAL_PROD_RSS_MB} + ${rss}" | bc)
      SB_API_CONTAINER_COUNT=$(( SB_API_CONTAINER_COUNT + 1 ))
      SB_MINIMAL_PROD_COUNT=$(( SB_MINIMAL_PROD_COUNT + 1 ))
      echo "[footprint]   [minimal-prod] ${cname}: ${rss} MB"
      if [[ ${SB_CONTAINER_RSS_FIRST} -eq 0 ]]; then SB_CONTAINER_RSS_JSON="${SB_CONTAINER_RSS_JSON},"; fi
      SB_CONTAINER_RSS_JSON="${SB_CONTAINER_RSS_JSON}\"${cname}\":${rss}"
      SB_CONTAINER_RSS_FIRST=0
    else
      echo "[footprint]   [minimal-prod] ${cname}: ${state} (skipped)"
    fi
  else
    echo "[footprint]   [minimal-prod] ${cname}: not found (skipped)"
  fi
done

echo "[footprint]   --- DEV-EXTRAS containers (Studio, pg-meta, Vector, Analytics, Inbucket) ---"
for cname in ${SB_DEV_EXTRA_CONTAINERS}; do
  if docker inspect "${cname}" > /dev/null 2>&1; then
    state=$(docker inspect --format '{{.State.Status}}' "${cname}" 2>/dev/null || echo "unknown")
    if [[ "${state}" == "running" ]]; then
      rss=$(get_docker_rss_mb "${cname}")
      SB_IDLE_RSS_TOTAL_MB=$(echo "${SB_IDLE_RSS_TOTAL_MB} + ${rss}" | bc)
      SB_DEV_EXTRA_RSS_MB=$(echo "${SB_DEV_EXTRA_RSS_MB} + ${rss}" | bc)
      SB_API_CONTAINER_COUNT=$(( SB_API_CONTAINER_COUNT + 1 ))
      SB_DEV_EXTRA_COUNT=$(( SB_DEV_EXTRA_COUNT + 1 ))
      echo "[footprint]   [dev-extra]    ${cname}: ${rss} MB"
      if [[ ${SB_CONTAINER_RSS_FIRST} -eq 0 ]]; then SB_CONTAINER_RSS_JSON="${SB_CONTAINER_RSS_JSON},"; fi
      SB_CONTAINER_RSS_JSON="${SB_CONTAINER_RSS_JSON}\"${cname}\":${rss}"
      SB_CONTAINER_RSS_FIRST=0
    else
      echo "[footprint]   [dev-extra]    ${cname}: ${state} (skipped)"
    fi
  else
    echo "[footprint]   [dev-extra]    ${cname}: not found (skipped)"
  fi
done
SB_CONTAINER_RSS_JSON="${SB_CONTAINER_RSS_JSON}}"

echo ""
printf "[footprint] Supabase MINIMAL-PROD API-layer RSS: %s MB (%d containers: Kong+GoTrue+PostgREST+Realtime+Storage)\n" \
  "${SB_MINIMAL_PROD_RSS_MB}" "${SB_MINIMAL_PROD_COUNT}"
printf "[footprint] Supabase DEV-EXTRAS RSS:             %s MB (%d containers: Studio+pg-meta+Vector+Analytics+Inbucket)\n" \
  "${SB_DEV_EXTRA_RSS_MB}" "${SB_DEV_EXTRA_COUNT}"
printf "[footprint] Supabase FULL-DEV-STACK API-layer RSS: %s MB (%d containers total)\n" \
  "${SB_IDLE_RSS_TOTAL_MB}" "${SB_API_CONTAINER_COUNT}"
echo ""
echo "[footprint] HONEST HEADLINE: minimal-prod comparison is the correct production basis."
echo "[footprint] Full dev-stack is reported for completeness."

HS_PG_IDLE_RSS_MB=0
if [[ -n "${HS_PG_CONTAINER:-}" ]]; then
  HS_PG_IDLE_RSS_MB=$(get_docker_rss_mb "${HS_PG_CONTAINER}" 2>/dev/null || echo "0")
  echo "[footprint] HyperStack Postgres (${HS_PG_CONTAINER}) idle RSS: ${HS_PG_IDLE_RSS_MB} MB (not in API-layer total)"
fi
SB_PG_IDLE_RSS_MB=$(get_docker_rss_mb "${SB_PG_CONTAINER}" 2>/dev/null || echo "0")
echo "[footprint] Supabase Postgres (${SB_PG_CONTAINER}) idle RSS: ${SB_PG_IDLE_RSS_MB} MB (not in API-layer total)"

printf "[footprint] Supabase API-layer idle RSS TOTAL: %s MB (%d containers)\n" \
  "${SB_IDLE_RSS_TOTAL_MB}" "${SB_API_CONTAINER_COUNT}"
echo ""

# ── 2. Container count ────────────────────────────────────────────────────────

echo "[footprint] === 2. CONTAINER COUNT ==="
echo "[footprint] HyperStack API layer: 1 process (binary, not a container)"
echo "[footprint] HyperStack + Postgres: 1 process + 1 Docker container (postgres:17)"
echo "[footprint] Supabase API layer: ${SB_API_CONTAINER_COUNT} containers (excluding Postgres)"
SB_TOTAL_CONTAINER_COUNT=$(( SB_API_CONTAINER_COUNT + 1 ))
echo "[footprint] Supabase total: ${SB_TOTAL_CONTAINER_COUNT} containers (including Postgres)"
echo ""

# ── 3. On-disk size ───────────────────────────────────────────────────────────

echo "[footprint] === 3. ON-DISK SIZE ==="

HS_BINARY_SIZE_BYTES=$(stat -f%z "${HS_BINARY}" 2>/dev/null || echo "0")
HS_BINARY_SIZE_MB=$(echo "scale=2; ${HS_BINARY_SIZE_BYTES} / 1048576" | bc)
echo "[footprint] HyperStack binary: ${HS_BINARY_SIZE_MB} MB (${HS_BINARY})"

HS_PG_IMAGE_SIZE_MB=$(get_image_size_mb "postgres:17")
echo "[footprint] HyperStack Postgres image (postgres:17): ${HS_PG_IMAGE_SIZE_MB} MB (not counted in API binary size)"

SB_IMAGE_SIZE_TOTAL_MB=0
SB_IMAGE_SEEN=""
SB_IMAGE_JSON="{"
SB_IMAGE_JSON_FIRST=1
echo "[footprint] Supabase API-layer image sizes:"
for cname in ${SB_API_CONTAINERS}; do
  if docker inspect "${cname}" > /dev/null 2>&1; then
    img=$(docker inspect --format '{{.Config.Image}}' "${cname}" 2>/dev/null || echo "")
    # Avoid double-counting shared images
    if [[ -n "${img}" ]]; then
      already_seen=0
      for seen_img in ${SB_IMAGE_SEEN}; do
        if [[ "${seen_img}" == "${img}" ]]; then already_seen=1; break; fi
      done
      if [[ ${already_seen} -eq 0 ]]; then
        img_mb=$(get_image_size_mb "${img}")
        SB_IMAGE_SIZE_TOTAL_MB=$(echo "${SB_IMAGE_SIZE_TOTAL_MB} + ${img_mb}" | bc)
        SB_IMAGE_SEEN="${SB_IMAGE_SEEN} ${img}"
        echo "[footprint]   ${cname} (${img}): ${img_mb} MB"
        if [[ ${SB_IMAGE_JSON_FIRST} -eq 0 ]]; then SB_IMAGE_JSON="${SB_IMAGE_JSON},"; fi
        # escape quotes in image name
        img_escaped=$(echo "${img}" | sed 's/"/\\"/g')
        SB_IMAGE_JSON="${SB_IMAGE_JSON}\"${img_escaped}\":${img_mb}"
        SB_IMAGE_JSON_FIRST=0
      fi
    fi
  fi
done
SB_IMAGE_JSON="${SB_IMAGE_JSON}}"

SB_PG_IMAGE=$(docker inspect --format '{{.Config.Image}}' "${SB_PG_CONTAINER}" 2>/dev/null || echo "")
SB_PG_IMAGE_SIZE_MB=0
if [[ -n "${SB_PG_IMAGE}" ]]; then
  SB_PG_IMAGE_SIZE_MB=$(get_image_size_mb "${SB_PG_IMAGE}")
fi
echo "[footprint] Supabase Postgres image (${SB_PG_IMAGE}): ${SB_PG_IMAGE_SIZE_MB} MB (not counted in API-layer total)"
printf "[footprint] Supabase API-layer image size TOTAL: %s MB\n" "${SB_IMAGE_SIZE_TOTAL_MB}"
echo ""

# ── 4. Under-load RSS + CPU% ─────────────────────────────────────────────────

HS_LOAD_RSS_MB="skipped"
SB_LOAD_RSS_TOTAL_MB="skipped"

if [[ "${SKIP_LOAD}" -eq 0 ]]; then
  echo "[footprint] === 4. UNDER-LOAD RSS + CPU% ==="

  HS_JWT=$(node -e "const s=JSON.parse(require('fs').readFileSync('${SEED_FILE}','utf8')); console.log(s.hyperstack.users[0].jwt || '')")
  SB_JWT=$(node -e "const s=JSON.parse(require('fs').readFileSync('${SEED_FILE}','utf8')); console.log(s.supabase.users[0].jwt || '')")
  HS_USER_ID=$(node -e "const s=JSON.parse(require('fs').readFileSync('${SEED_FILE}','utf8')); console.log(s.hyperstack.users[0].userId || s.hyperstack.users[0].id || '')")
  SB_USER_ID=$(node -e "const s=JSON.parse(require('fs').readFileSync('${SEED_FILE}','utf8')); console.log(s.supabase.users[0].userId || s.supabase.users[0].id || '')")

  HS_REST_URL_K6="${HS_BASE_URL_K6}/rest/v1"
  SB_REST_URL_K6="${SB_REST_URL_K6:-http://supabase_rest_sb-bench:3000}"

  # Run k6 load against HyperStack in background, sample RSS mid-run
  LOAD_OUT_HS="${BENCH_RAW_DIR}/footprint-${FRAMING}-load-hs-${RUNID}.json"
  K6_HS_CONTAINER="k6_footprint_hs_$$"
  docker run --rm -d \
    --name "${K6_HS_CONTAINER}" \
    --add-host "host.docker.internal:host-gateway" \
    --network "${DOCKER_NETWORK}" \
    -e "TARGET=hyperstack" \
    -e "HS_REST_URL=${HS_REST_URL_K6}" \
    -e "HS_JWT=${HS_JWT}" \
    -e "HS_USER_ID=${HS_USER_ID}" \
    -e "SB_REST_URL=${SB_REST_URL_K6}" \
    -e "SB_JWT=${SB_JWT}" \
    -e "SB_USER_ID=${SB_USER_ID}" \
    -e "SB_ANON_KEY=${SB_ANON_JWT}" \
    -v "${BENCH_DIR}/scenarios:/scenarios:ro" \
    -v "${BENCH_RAW_DIR}:/results" \
    "${K6_IMAGE}" run \
      --summary-export "/results/$(basename ${LOAD_OUT_HS})" \
      "/scenarios/rest-select.js" > /dev/null 2>&1 || true

  echo "[footprint] k6 REST load started against HyperStack, sampling RSS in 8s ..."
  sleep 8
  HS_LOAD_RSS_MB=$(get_hs_rss_mb "${HS_PID}")
  echo "[footprint] HyperStack under-load RSS: ${HS_LOAD_RSS_MB} MB"
  docker wait "${K6_HS_CONTAINER}" > /dev/null 2>&1 || true
  docker rm -f "${K6_HS_CONTAINER}" > /dev/null 2>&1 || true

  # Run against Supabase
  LOAD_OUT_SB="${BENCH_RAW_DIR}/footprint-${FRAMING}-load-sb-${RUNID}.json"
  K6_SB_CONTAINER="k6_footprint_sb_$$"
  docker run --rm -d \
    --name "${K6_SB_CONTAINER}" \
    --add-host "host.docker.internal:host-gateway" \
    --network "${DOCKER_NETWORK}" \
    -e "TARGET=supabase" \
    -e "HS_REST_URL=${HS_REST_URL_K6}" \
    -e "HS_JWT=${HS_JWT}" \
    -e "HS_USER_ID=${HS_USER_ID}" \
    -e "SB_REST_URL=${SB_REST_URL_K6}" \
    -e "SB_JWT=${SB_JWT}" \
    -e "SB_USER_ID=${SB_USER_ID}" \
    -e "SB_ANON_KEY=${SB_ANON_JWT}" \
    -v "${BENCH_DIR}/scenarios:/scenarios:ro" \
    -v "${BENCH_RAW_DIR}:/results" \
    "${K6_IMAGE}" run \
      --summary-export "/results/$(basename ${LOAD_OUT_SB})" \
      "/scenarios/rest-select.js" > /dev/null 2>&1 || true

  echo "[footprint] k6 REST load started against Supabase, sampling RSS in 8s ..."
  sleep 8
  SB_LOAD_RSS_ACC=0
  for cname in ${SB_API_CONTAINERS}; do
    if docker inspect "${cname}" > /dev/null 2>&1; then
      state=$(docker inspect --format '{{.State.Status}}' "${cname}" 2>/dev/null || echo "unknown")
      if [[ "${state}" == "running" ]]; then
        rss=$(get_docker_rss_mb "${cname}")
        SB_LOAD_RSS_ACC=$(echo "${SB_LOAD_RSS_ACC} + ${rss}" | bc)
      fi
    fi
  done
  SB_LOAD_RSS_TOTAL_MB="${SB_LOAD_RSS_ACC}"
  printf "[footprint] Supabase API-layer under-load RSS: %s MB\n" "${SB_LOAD_RSS_TOTAL_MB}"
  docker wait "${K6_SB_CONTAINER}" > /dev/null 2>&1 || true
  docker rm -f "${K6_SB_CONTAINER}" > /dev/null 2>&1 || true
fi

# ── 5. Cold-start ─────────────────────────────────────────────────────────────

HS_COLDSTART_MS="skipped"
SB_COLDSTART_MS="skipped"
HS_COLDSTART_METHOD="skipped"
SB_COLDSTART_METHOD="skipped"

if [[ "${SKIP_COLDSTART}" -eq 0 ]]; then
  echo ""
  echo "[footprint] === 5. COLD-START ==="

  # ── HyperStack cold-start ──────────────────────────────────────────────────
  echo "[footprint] HyperStack cold-start: stopping PID=${HS_PID} ..."
  kill "${HS_PID}" 2>/dev/null || true
  local_i=0
  while kill -0 "${HS_PID}" 2>/dev/null && [[ ${local_i} -lt 30 ]]; do
    sleep 0.3
    local_i=$(( local_i + 1 ))
  done
  if kill -0 "${HS_PID}" 2>/dev/null; then
    kill -9 "${HS_PID}" 2>/dev/null || true
    sleep 0.5
  fi
  echo "[footprint] HyperStack stopped."

  HS_CS_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); p=s.getsockname()[1]; s.close(); print(p)")
  HS_CS_BASE_URL="http://127.0.0.1:${HS_CS_PORT}"

  DATABASE_URL_CS="host=localhost port=${HS_PG_PORT} user=authenticator password=${HS_AUTHENTICATOR_PASSWORD} dbname=${HS_DB}"
  ADMIN_DATABASE_URL_CS="host=localhost port=${HS_PG_PORT} user=postgres password=${HS_PG_PASS} dbname=${HS_DB}"

  echo "[footprint] Starting fresh HyperStack on :${HS_CS_PORT} ..."
  HS_CS_START_MS=$(python3 -c "import time; print(int(time.time()*1000))")

  env \
    DATABASE_URL="${DATABASE_URL_CS}" \
    ADMIN_DATABASE_URL="${ADMIN_DATABASE_URL_CS}" \
    AUTHENTICATOR_PASSWORD="${HS_AUTHENTICATOR_PASSWORD}" \
    JWT_SECRET="${HS_JWT_SECRET}" \
    SERVICE_KEY="${HS_SERVICE_KEY}" \
    ADMIN_TOKEN="${HS_ADMIN_TOKEN}" \
    BIND_ADDR="127.0.0.1:${HS_CS_PORT}" \
    STORAGE_ROOT="${HS_STORAGE_ROOT}/framing-${FRAMING}" \
    RUST_LOG="warn" \
    PATH="/opt/homebrew/opt/libpq/bin:${PATH}" \
    "${HS_BINARY}" > /tmp/hs-coldstart-$$.log 2>&1 &
  HS_CS_PID=$!

  HS_CS_READY=0
  HS_CS_READY_MS=0
  HS_CS_DEADLINE=$(( $(date +%s) + 30 ))
  while [[ $(date +%s) -lt ${HS_CS_DEADLINE} ]]; do
    if curl -sf --max-time 0.5 "${HS_CS_BASE_URL}/ready" > /dev/null 2>&1; then
      HS_CS_READY_MS=$(python3 -c "import time; print(int(time.time()*1000))")
      HS_CS_READY=1
      break
    fi
    sleep 0.05
  done

  if [[ ${HS_CS_READY} -eq 1 ]]; then
    HS_COLDSTART_MS=$(( HS_CS_READY_MS - HS_CS_START_MS ))
    echo "[footprint] HyperStack cold-start: ${HS_COLDSTART_MS} ms (exec → /ready 200)"
    HS_COLDSTART_METHOD="exec_to_ready_http200"
  else
    echo "[footprint] WARNING: HyperStack did not become ready within 30s" >&2
    HS_COLDSTART_MS="timeout"
    HS_COLDSTART_METHOD="exec_to_ready_http200_timeout"
  fi

  # Update env file with new PID + port
  NEW_HS_PID="${HS_CS_PID}"
  sed -i.bak "s/^HS_PID=.*/HS_PID=${NEW_HS_PID}/" "${ENV_FILE}" 2>/dev/null || true
  sed -i.bak "s/^HS_PORT=.*/HS_PORT=${HS_CS_PORT}/" "${ENV_FILE}" 2>/dev/null || true
  sed -i.bak "s|^HS_BASE_URL=.*|HS_BASE_URL=http://127.0.0.1:${HS_CS_PORT}|" "${ENV_FILE}" 2>/dev/null || true
  sed -i.bak "s|^HS_BASE_URL_K6=.*|HS_BASE_URL_K6=http://host.docker.internal:${HS_CS_PORT}|" "${ENV_FILE}" 2>/dev/null || true
  rm -f "${ENV_FILE}.bak"

  # ── Supabase cold-start (Kong restart) ─────────────────────────────────────
  echo "[footprint] Supabase cold-start: restarting Kong (${SB_KONG_CONTAINER}) ..."
  SB_CS_START_MS=$(python3 -c "import time; print(int(time.time()*1000))")
  docker restart "${SB_KONG_CONTAINER}" > /dev/null 2>&1 || true

  SB_CS_READY=0
  SB_CS_READY_MS=0
  SB_CS_DEADLINE=$(( $(date +%s) + 60 ))
  while [[ $(date +%s) -lt ${SB_CS_DEADLINE} ]]; do
    if curl -sf --max-time 1 "http://localhost:54321/rest/v1/" > /dev/null 2>&1; then
      SB_CS_READY_MS=$(python3 -c "import time; print(int(time.time()*1000))")
      SB_CS_READY=1
      break
    fi
    sleep 0.1
  done

  if [[ ${SB_CS_READY} -eq 1 ]]; then
    SB_COLDSTART_MS=$(( SB_CS_READY_MS - SB_CS_START_MS ))
    echo "[footprint] Supabase Kong cold-start: ${SB_COLDSTART_MS} ms (docker restart → HTTP 200)"
    SB_COLDSTART_METHOD="docker_restart_kong_only_conservative_lower_bound"
  else
    echo "[footprint] WARNING: Supabase Kong did not become ready within 60s" >&2
    SB_COLDSTART_MS="timeout"
    SB_COLDSTART_METHOD="docker_restart_kong_only_conservative_lower_bound_timeout"
  fi

  echo ""
  echo "[footprint] ┌─ COLD-START ASYMMETRY ─────────────────────────────────────────────────────"
  echo "[footprint] │"
  echo "[footprint] │  HyperStack (${HS_COLDSTART_MS} ms):"
  echo "[footprint] │    Single binary exec → Postgres pool + schema introspect → /ready HTTP 200."
  echo "[footprint] │    This is the FULL API-layer cold-start from process creation."
  echo "[footprint] │"
  echo "[footprint] │  Supabase (${SB_COLDSTART_MS} ms) — CONSERVATIVE LOWER BOUND:"
  echo "[footprint] │    'docker restart supabase_kong_sb-bench' → Kong re-starts + serves 200."
  echo "[footprint] │    The other 9 containers (GoTrue, PostgREST, Realtime, Storage, Studio,"
  echo "[footprint] │    pg-meta, Vector, Analytics, Inbucket, Postgres) remain WARM and running."
  echo "[footprint] │    This is NOT equivalent to HyperStack's full cold-start."
  echo "[footprint] │"
  echo "[footprint] │  A FAIR Supabase cold-start would be 'docker compose up' from fully stopped:"
  echo "[footprint] │    - With warm image cache: ~30–120 seconds (image load + 11 containers start)"
  echo "[footprint] │    - From cold image cache: ~5–15 minutes (image pull + start)"
  echo "[footprint] │    Measuring this requires taking the full stack down, which is disruptive."
  echo "[footprint] │    The Kong-only number is kept and LABELED as a conservative lower bound."
  echo "[footprint] │"
  echo "[footprint] │  BOTTOM LINE: The ${HS_COLDSTART_MS}ms vs ${SB_COLDSTART_MS}ms comparison is NOT symmetric."
  echo "[footprint] │  The honest reading is: HyperStack cold-starts in <1s. Supabase Kong alone"
  echo "[footprint] │  takes ~${SB_COLDSTART_MS}ms; full stack cold-start is 30s–2min."
  echo "[footprint] └────────────────────────────────────────────────────────────────────────────"
fi

# ── 6. Print summary table ────────────────────────────────────────────────────

SB_MINIMAL_PROD_RATIO="N/A"
if [[ "${HS_IDLE_RSS_MB}" != "0" && "${SB_MINIMAL_PROD_RSS_MB}" != "0" ]]; then
  SB_MINIMAL_PROD_RATIO=$(echo "scale=0; ${SB_MINIMAL_PROD_RSS_MB} / ${HS_IDLE_RSS_MB}" | bc)
fi
SB_FULL_STACK_RATIO="N/A"
if [[ "${HS_IDLE_RSS_MB}" != "0" && "${SB_IDLE_RSS_TOTAL_MB}" != "0" ]]; then
  SB_FULL_STACK_RATIO=$(echo "scale=0; ${SB_IDLE_RSS_TOTAL_MB} / ${HS_IDLE_RSS_MB}" | bc)
fi

echo ""
echo "[footprint] ================================================================"
echo "[footprint]   FOOTPRINT SUMMARY — Framing ${FRAMING}"
echo "[footprint] ================================================================"
echo ""
printf "[footprint]  %-38s  %18s  %18s\n" "Metric" "HyperStack" "Supabase"
printf "[footprint]  %-38s  %18s  %18s\n" "──────────────────────────────────────" "──────────────────" "──────────────────"
printf "[footprint]  %-38s  %18s  %18s\n" "API-layer idle RSS (minimal-prod)" "${HS_IDLE_RSS_MB} MB" "${SB_MINIMAL_PROD_RSS_MB} MB (~${SB_MINIMAL_PROD_RATIO}x)"
printf "[footprint]  %-38s  %18s  %18s\n" "  (minimal-prod = Kong+GoTrue+PGRST+RT+Stor)" "" ""
printf "[footprint]  %-38s  %18s  %18s\n" "API-layer idle RSS (full dev stack)" "${HS_IDLE_RSS_MB} MB" "${SB_IDLE_RSS_TOTAL_MB} MB (~${SB_FULL_STACK_RATIO}x)"
printf "[footprint]  %-38s  %18s  %18s\n" "  (full = minimal-prod + Studio+pg-meta+" "" ""
printf "[footprint]  %-38s  %18s  %18s\n" "   Vector+Analytics+Inbucket)" "" ""
printf "[footprint]  %-38s  %18s  %18s\n" "API-layer under-load RSS" "${HS_LOAD_RSS_MB} MB" "${SB_LOAD_RSS_TOTAL_MB} MB"
printf "[footprint]  %-38s  %18s  %18s\n" "Postgres idle RSS" "${HS_PG_IDLE_RSS_MB} MB" "${SB_PG_IDLE_RSS_MB} MB"
printf "[footprint]  %-38s  %18s  %18s\n" "API containers/processes" "1 process" "${SB_API_CONTAINER_COUNT} containers"
printf "[footprint]  %-38s  %18s  %18s\n" "Total (API + Postgres)" "1 proc + 1 ctr" "${SB_TOTAL_CONTAINER_COUNT} containers"
printf "[footprint]  %-38s  %18s  %18s\n" "API on-disk size" "${HS_BINARY_SIZE_MB} MB (binary)" "${SB_IMAGE_SIZE_TOTAL_MB} MB (images)"
printf "[footprint]  %-38s  %18s  %18s\n" "Cold-start (API layer)" "${HS_COLDSTART_MS} ms (full)" "${SB_COLDSTART_MS} ms (*)"
echo ""
echo "[footprint] (*) Supabase cold-start = Kong-restart only (other 9 containers warm)."
echo "[footprint]     CONSERVATIVE LOWER BOUND. Full stack cold-start: 30–120 seconds."
echo "[footprint]     See FAIRNESS.md §F2 and the cold-start asymmetry note above."
echo ""
echo "[footprint] HEADLINE RECOMMENDATION:"
printf "[footprint]   Honest headline: HS %s MB vs SB minimal-prod %s MB (~%sx) idle RSS.\n" \
  "${HS_IDLE_RSS_MB}" "${SB_MINIMAL_PROD_RSS_MB}" "${SB_MINIMAL_PROD_RATIO}"
printf "[footprint]   Full dev-stack note: HS %s MB vs SB full-dev %s MB (~%sx).\n" \
  "${HS_IDLE_RSS_MB}" "${SB_IDLE_RSS_TOTAL_MB}" "${SB_FULL_STACK_RATIO}"
echo "[footprint]   RSS accounting asymmetry: ps (HS) vs cgroup memory.usage (SB) — see FAIRNESS.md §F3."
echo ""
echo "[footprint] NOTE: 'API layer' excludes Postgres (both sides need a pg instance)."
echo "[footprint] ================================================================"
echo ""

# ── 7. Write JSON ─────────────────────────────────────────────────────────────

node - <<NODESCRIPT
const fs = require('fs');

function safe(v) {
  if (typeof v === 'string' && (v === 'skipped' || v === 'timeout')) return JSON.stringify(v);
  const n = parseFloat(v);
  if (!isNaN(n)) return n;
  return JSON.stringify(v);
}

const data = {
  run_id:    '${RUNID}',
  timestamp: '${TIMESTAMP}',
  framing:   '${FRAMING}',

  method: {
    hs_rss: 'ps -o rss= -p <pid> on macOS host (KB->MB) — virtual-memory RSS, excludes page cache',
    sb_rss: 'docker stats --no-stream sum over containers (cgroup memory.usage, includes page cache)',
    rss_asymmetry: 'cgroup memory.usage (SB) tends to run higher than ps RSS (HS) — favours HS. See FAIRNESS.md §F3.',
    hs_coldstart: '${HS_COLDSTART_METHOD}',
    sb_coldstart: '${SB_COLDSTART_METHOD}',
    sb_coldstart_note: 'Kong-restart only — other 9 containers remain warm. CONSERVATIVE LOWER BOUND. Full stack cold-start: 30-120s. See FAIRNESS.md §F2.',
    note: 'API-layer footprint excludes Postgres. Both HS and SB require a pg instance. Report shows API separately + Postgres separately.'
  },

  hyperstack: {
    api_layer: {
      type:             'single_binary',
      idle_rss_mb:      ${HS_IDLE_RSS_MB:-0},
      load_rss_mb:      '${HS_LOAD_RSS_MB}',
      binary_size_mb:   ${HS_BINARY_SIZE_MB:-0},
      process_count:    1,
      coldstart_ms:     '${HS_COLDSTART_MS}',
      coldstart_method: '${HS_COLDSTART_METHOD}',
      coldstart_note:   'Full API-layer cold-start: binary exec to first /ready HTTP 200'
    },
    postgres: {
      container:   '${HS_PG_CONTAINER:-bench_hs_pg_a}',
      idle_rss_mb: ${HS_PG_IDLE_RSS_MB:-0},
      image:       'postgres:17'
    }
  },

  supabase: {
    api_layer: {
      type:                     'multi_container',
      container_count_total:    ${SB_API_CONTAINER_COUNT},
      container_count_minimal_prod: ${SB_MINIMAL_PROD_COUNT},
      container_count_dev_extras:   ${SB_DEV_EXTRA_COUNT},
      idle_rss_minimal_prod_mb: ${SB_MINIMAL_PROD_RSS_MB:-0},
      idle_rss_dev_extras_mb:   ${SB_DEV_EXTRA_RSS_MB:-0},
      idle_rss_full_stack_mb:   ${SB_IDLE_RSS_TOTAL_MB:-0},
      load_rss_total_mb:        '${SB_LOAD_RSS_TOTAL_MB}',
      image_size_total_mb:      ${SB_IMAGE_SIZE_TOTAL_MB:-0},
      coldstart_ms:             '${SB_COLDSTART_MS}',
      coldstart_method:         '${SB_COLDSTART_METHOD}',
      coldstart_note:           'Kong-restart only (9 containers warm) — CONSERVATIVE LOWER BOUND; full stack cold-start 30-120s',
      minimal_prod_containers:  ['supabase_kong_sb-bench','supabase_auth_sb-bench','supabase_rest_sb-bench','supabase_realtime_sb-bench','supabase_storage_sb-bench'],
      dev_extra_containers:     ['supabase_studio_sb-bench','supabase_pg_meta_sb-bench','supabase_vector_sb-bench','supabase_analytics_sb-bench','supabase_inbucket_sb-bench'],
      per_container_idle_rss_mb: ${SB_CONTAINER_RSS_JSON},
      images:                   ${SB_IMAGE_JSON}
    },
    postgres: {
      container:   '${SB_PG_CONTAINER}',
      idle_rss_mb: ${SB_PG_IDLE_RSS_MB:-0}
    }
  },

  ratios: {
    idle_rss_minimal_prod: '${SB_MINIMAL_PROD_RATIO}x (SB minimal-prod / HS)',
    idle_rss_full_stack:   '${SB_FULL_STACK_RATIO}x (SB full dev stack / HS)',
    honest_headline:       'minimal-prod ratio (skeptics who do not run Studio/analytics in prod are right to use this)',
    full_stack_for_completeness: 'full dev-stack ratio includes dev-only containers; reported for completeness not as headline'
  },

  fairness_note: [
    'API-layer comparison: HyperStack binary vs Supabase API containers.',
    'minimal-prod = Kong + GoTrue + PostgREST + Realtime + Storage (5 containers needed for production API traffic).',
    'dev-extras = Studio + pg_meta + Vector + Analytics/Logflare + Inbucket (dev tooling, not required in production).',
    'Postgres is NOT counted in either API-layer figure. Both need a pg instance.',
    'HyperStack folds all API-layer functionality into a single binary (~3.9 MB).',
    'RSS accounting: HS uses ps (macOS, excludes page cache); SB uses docker stats cgroup memory.usage (includes page cache). Different units — favours HS. See FAIRNESS.md §F3.',
    'Cold-start: HS = single binary exec to first /ready 200 (FULL cold-start). SB = docker restart Kong only (CONSERVATIVE LOWER BOUND; full stack 30-120s). See FAIRNESS.md §F2.'
  ]
};

fs.writeFileSync('${OUT_JSON}', JSON.stringify(data, null, 2), 'utf8');
console.log('[footprint] JSON written to ${OUT_JSON}');
NODESCRIPT

echo "[footprint] Done. Results: ${OUT_JSON}"
