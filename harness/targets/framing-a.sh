#!/usr/bin/env bash
# bench/targets/framing-a.sh — Framing A: gateway-overhead isolation.
#
# WHAT THIS FRAMING CONTROLS:
#   Framing A removes Kong/gateway overhead from the Supabase measurement path so
#   that k6 hits PostgREST direct (supabase_rest_SDTool:3000) and GoTrue direct
#   (supabase_auth_SDTool:9999), matching HyperStack's single-process model.
#   It does NOT establish "identical Postgres engine" equivalence — see below.
#
# HONEST ENGINE DESCRIPTION:
#   HyperStack: vanilla postgres:17.10 (Docker Hub postgres:17, Debian build).
#   Supabase:   public.ecr.aws/supabase/postgres:17.6.1.106 — Supabase's fork.
#               The fork carries additional shared_preload_libraries
#               (pg_stat_statements, pgaudit, plpgsql, plpgsql_check, pg_cron,
#               pg_net, pgsodium, auto_explain, pg_tle, plan_filter, supabase_vault)
#               and session_preload_libraries (supautils).
#   The two pg instances are SEPARATE — they do not share storage, WAL, or config.
#   WEAKER CLAIM: Framing A controls for gateway overhead only, NOT pg-engine identity.
#   Any latency difference includes contributions from pg version (17.10 vs 17.6.1),
#   extension overhead in Supabase's fork, and different default pg_settings.
#
# WHY A SHARED INSTANCE IS STRUCTURALLY IMPOSSIBLE:
#   The Supabase pg cluster carries reserved cluster-wide role names
#   (authenticator, anon, authenticated, service_role) managed by supautils.
#   HyperStack's bootstrap must ALTER ROLE authenticator PASSWORD '...' to set its
#   own credential; this conflicts with PostgREST's existing authenticator identity.
#   Even supabase_admin CAN issue the ALTER — but doing so would break PostgREST's
#   live connection pool, which relies on authenticator's password for reconnect.
#   The blocker is cluster-wide role-namespace collision, not merely a permission
#   restriction on ALTER ROLE. A truly shared instance is therefore not achievable
#   without destroying the running Supabase stack.
#
# NETWORK PATH (confound — see bench/FAIRNESS.md §I1):
#   k6 (container) -> HyperStack (host binary) via host.docker.internal extra hop.
#   k6 (container) -> Supabase (container)      container-to-container, direct.
#   This asymmetry PENALIZES HyperStack. Its latency numbers are a conservative
#   lower bound: even with the extra hop, observed throughput reflects real behavior.
#   Cross-compiling HyperStack to linux/aarch64 for containerization was attempted
#   but `cross` is not available in this environment; a multi-stage Dockerfile build
#   was considered but deferred (see FAIRNESS.md §I1 for rationale).
#
# Usage:
#   bash bench/targets/framing-a.sh up
#   bash bench/targets/framing-a.sh down
#   bash bench/targets/framing-a.sh status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.sh"

FRAMING="a"
HS_DB="bench_hs"
HS_PG_CONTAINER="bench_hs_pg_a"
HS_PG_PORT="54330"                  # host-mapped port for HyperStack's pg17
HS_PG_PASS="bench_hs_pgpass"        # postgres superuser password in HS container

ENV_FILE="${BENCH_RESULTS_DIR}/framing-a.env"
PID_FILE="${BENCH_RESULTS_DIR}/framing-a.pid"
LOG_FILE="${BENCH_RESULTS_DIR}/framing-a.log"

# ── Helpers ────────────────────────────────────────────────────────────────────

psql_hs_admin() {
  PGPASSWORD="${HS_PG_PASS}" "${PSQL_PATH}" \
    -h "${BENCH_PG_HOST}" -p "${HS_PG_PORT}" \
    -U postgres -d postgres \
    -v ON_ERROR_STOP=1 "$@"
}

find_free_port() {
  python3 -c "
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
port = s.getsockname()[1]
s.close()
print(port)
"
}

wait_pg() {
  local port="$1"
  local pass="$2"
  local label="$3"
  local deadline=$(( $(date +%s) + 30 ))
  echo "[framing-a] Waiting for ${label} on port ${port} ..."
  while [[ $(date +%s) -lt $deadline ]]; do
    if PGPASSWORD="${pass}" "${PSQL_PATH}" -h localhost -p "${port}" -U postgres \
         -d postgres -tAc "SELECT 1" > /dev/null 2>&1; then
      echo "[framing-a] ${label} is ready."
      return 0
    fi
    sleep 0.5
  done
  echo "[framing-a] ERROR: ${label} on port ${port} not ready within 30s" >&2
  return 1
}

wait_ready() {
  local url="$1"
  local timeout_s="${2:-60}"
  local deadline=$(( $(date +%s) + timeout_s ))
  local ready_url="${url}/ready"
  echo "[framing-a] Waiting for HyperStack at ${ready_url} ..."
  while [[ $(date +%s) -lt $deadline ]]; do
    if curl -sf --max-time 1 "${ready_url}" > /dev/null 2>&1; then
      echo "[framing-a] HyperStack is ready."
      return 0
    fi
    sleep 0.5
  done
  echo "[framing-a] ERROR: HyperStack did not become ready within ${timeout_s}s" >&2
  return 1
}

# ── UP ─────────────────────────────────────────────────────────────────────────

cmd_up() {
  echo "[framing-a] Bringing up Framing A ..."
  mkdir -p "${BENCH_RESULTS_DIR}" "${BENCH_RAW_DIR}" "${HS_STORAGE_ROOT}/framing-a"

  # 1. Start HyperStack's dedicated postgres:17 container (if not already running)
  if docker inspect "${HS_PG_CONTAINER}" > /dev/null 2>&1; then
    local state
    state=$(docker inspect --format '{{.State.Status}}' "${HS_PG_CONTAINER}")
    if [[ "${state}" != "running" ]]; then
      echo "[framing-a] Container ${HS_PG_CONTAINER} exists but is ${state}; starting ..."
      docker start "${HS_PG_CONTAINER}"
    else
      echo "[framing-a] Container ${HS_PG_CONTAINER} already running."
    fi
  else
    echo "[framing-a] Starting postgres:17 container ${HS_PG_CONTAINER} on port ${HS_PG_PORT} ..."
    docker run -d \
      --name "${HS_PG_CONTAINER}" \
      -e POSTGRES_PASSWORD="${HS_PG_PASS}" \
      -p "${HS_PG_PORT}:5432" \
      postgres:17
  fi

  wait_pg "${HS_PG_PORT}" "${HS_PG_PASS}" "HyperStack pg17"

  # 2. Create bench DB if not exists
  local db_exists
  db_exists=$(PGPASSWORD="${HS_PG_PASS}" "${PSQL_PATH}" \
    -h localhost -p "${HS_PG_PORT}" -U postgres -d postgres \
    -tAc "SELECT 1 FROM pg_database WHERE datname='${HS_DB}'" 2>/dev/null || echo "")
  if [[ -z "${db_exists}" ]]; then
    echo "[framing-a] Creating database ${HS_DB} ..."
    psql_hs_admin -c "CREATE DATABASE ${HS_DB};"
  else
    echo "[framing-a] Database ${HS_DB} already exists."
  fi

  # 3. Kill any previously running HyperStack for this framing
  if [[ -f "${PID_FILE}" ]]; then
    local old_pid
    old_pid=$(cat "${PID_FILE}" 2>/dev/null || true)
    if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
      echo "[framing-a] Stopping previous HyperStack PID=${old_pid} ..."
      kill "${old_pid}" 2>/dev/null || true
      sleep 1
    fi
    rm -f "${PID_FILE}"
  fi

  # 4. Pick a free port for HyperStack API
  local HS_PORT
  HS_PORT=$(find_free_port)
  local HS_BIND="127.0.0.1:${HS_PORT}"
  local HS_BASE_URL="http://127.0.0.1:${HS_PORT}"
  local HS_BASE_URL_K6="http://host.docker.internal:${HS_PORT}"

  echo "[framing-a] Starting HyperStack on ${HS_BIND} (pg port ${HS_PG_PORT}) ..."

  local DATABASE_URL="host=localhost port=${HS_PG_PORT} user=authenticator password=${HS_AUTHENTICATOR_PASSWORD} dbname=${HS_DB}"
  local ADMIN_DATABASE_URL="host=localhost port=${HS_PG_PORT} user=postgres password=${HS_PG_PASS} dbname=${HS_DB}"

  # 5. Spawn HyperStack (its bootstrap will create roles + schema in the clean pg17)
  env \
    DATABASE_URL="${DATABASE_URL}" \
    ADMIN_DATABASE_URL="${ADMIN_DATABASE_URL}" \
    AUTHENTICATOR_PASSWORD="${HS_AUTHENTICATOR_PASSWORD}" \
    JWT_SECRET="${HS_JWT_SECRET}" \
    SERVICE_KEY="${HS_SERVICE_KEY}" \
    ADMIN_TOKEN="${HS_ADMIN_TOKEN}" \
    BIND_ADDR="${HS_BIND}" \
    STORAGE_ROOT="${HS_STORAGE_ROOT}/framing-a" \
    RUST_LOG="warn" \
    PATH="$HOME/bin:/usr/local/bin:${PATH}" \
    "${HS_BINARY}" > "${LOG_FILE}" 2>&1 &
  local HS_PID=$!
  echo "${HS_PID}" > "${PID_FILE}"
  echo "[framing-a] HyperStack PID=${HS_PID}"

  # 6. Wait for ready (bootstrap migrations run inside HyperStack on first start)
  if ! wait_ready "${HS_BASE_URL}" 60; then
    echo "[framing-a] HyperStack log tail:" >&2
    tail -30 "${LOG_FILE}" >&2
    kill "${HS_PID}" 2>/dev/null || true
    rm -f "${PID_FILE}"
    exit 1
  fi

  # 7. Trigger schema reload
  echo "[framing-a] Triggering schema reload ..."
  local reload_status
  reload_status=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" \
    -X POST "${HS_BASE_URL}/admin/v1/reload-schema" \
    -H "x-admin-token: ${HS_ADMIN_TOKEN}" \
    -H "content-type: application/json" || echo "000")
  if [[ "${reload_status}" != "200" ]]; then
    echo "[framing-a] Warning: schema reload returned HTTP ${reload_status}"
  else
    echo "[framing-a] Schema reloaded."
  fi

  # 8. Write env file
  cat > "${ENV_FILE}" <<EOF
# Framing A environment — generated by framing-a.sh up
# Do not edit manually.
FRAMING=a
HS_DB=${HS_DB}
HS_PG_PORT=${HS_PG_PORT}
HS_PG_PASS=${HS_PG_PASS}
HS_PG_CONTAINER=${HS_PG_CONTAINER}
SB_DB=${SB_DB}
HS_PORT=${HS_PORT}
HS_PID=${HS_PID}
HS_BASE_URL=${HS_BASE_URL}
HS_BASE_URL_K6=${HS_BASE_URL_K6}
SB_REST_URL_K6=http://${SB_REST_CONTAINER}:3000
SB_AUTH_URL_K6=http://${SB_AUTH_CONTAINER}:9999
SB_REST_URL_HOST=${SB_REST_URL_HOST}
SB_AUTH_URL_HOST=${SB_AUTH_URL_HOST}
SB_SERVICE_JWT=${SB_SERVICE_JWT}
SB_ANON_JWT=${SB_ANON_JWT}
HS_SERVICE_KEY=${HS_SERVICE_KEY}
HS_ADMIN_TOKEN=${HS_ADMIN_TOKEN}
EOF

  echo "[framing-a] Env written to ${ENV_FILE}"
  echo "[framing-a] Framing A is UP."
  echo "[framing-a]   HyperStack: ${HS_BASE_URL} (pg17 on port ${HS_PG_PORT})"
  echo "[framing-a]   Supabase:   PostgREST direct = http://supabase_rest_SDTool:3000 (bypass Kong)"
}

# ── DOWN ───────────────────────────────────────────────────────────────────────

cmd_down() {
  echo "[framing-a] Tearing down Framing A ..."

  local hs_pid=""
  if [[ -f "${ENV_FILE}" ]]; then
    hs_pid=$(grep '^HS_PID=' "${ENV_FILE}" | cut -d= -f2 || true)
  fi
  if [[ -z "${hs_pid}" ]] && [[ -f "${PID_FILE}" ]]; then
    hs_pid=$(cat "${PID_FILE}" 2>/dev/null || true)
  fi

  if [[ -n "${hs_pid}" ]] && kill -0 "${hs_pid}" 2>/dev/null; then
    echo "[framing-a] Stopping HyperStack PID=${hs_pid} ..."
    kill "${hs_pid}" 2>/dev/null || true
    local i=0
    while kill -0 "${hs_pid}" 2>/dev/null && [[ $i -lt 20 ]]; do
      sleep 0.5
      (( i++ )) || true
    done
    if kill -0 "${hs_pid}" 2>/dev/null; then
      echo "[framing-a] Force-killing PID=${hs_pid} ..."
      kill -9 "${hs_pid}" 2>/dev/null || true
    fi
  else
    echo "[framing-a] No running HyperStack found."
  fi

  rm -f "${PID_FILE}"

  # Stop (but do NOT remove) the pg container so data persists for inspection.
  # Use 'docker rm -f bench_hs_pg_a' manually to remove.
  if docker inspect "${HS_PG_CONTAINER}" > /dev/null 2>&1; then
    echo "[framing-a] Stopping pg container ${HS_PG_CONTAINER} ..."
    docker stop "${HS_PG_CONTAINER}" > /dev/null || true
  fi

  echo "[framing-a] Framing A is DOWN."
}

# ── STATUS ─────────────────────────────────────────────────────────────────────

cmd_status() {
  if [[ -f "${ENV_FILE}" ]]; then
    local hs_pid
    hs_pid=$(grep '^HS_PID=' "${ENV_FILE}" | cut -d= -f2 || true)
    if [[ -n "${hs_pid}" ]] && kill -0 "${hs_pid}" 2>/dev/null; then
      echo "[framing-a] HyperStack running (PID=${hs_pid})"
    else
      echo "[framing-a] HyperStack NOT running"
    fi
    cat "${ENV_FILE}"
  else
    echo "[framing-a] No env file found — not up."
  fi
}

# ── Dispatch ───────────────────────────────────────────────────────────────────

CMD="${1:-up}"
case "${CMD}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  *)
    echo "Usage: $0 <up|down|status>" >&2
    exit 1
    ;;
esac
