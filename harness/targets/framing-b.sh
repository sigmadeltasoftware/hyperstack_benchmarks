#!/usr/bin/env bash
# bench/targets/framing-b.sh — Framing B: Full stacks as-shipped.
#
# HyperStack: dedicated postgres:17 container (bench_hs_pg_b) + HS binary on host.
# Supabase:   via Kong gateway (supabase_kong_SDTool:8000 inside Docker /
#             localhost:54321 from host) — the full production stack path.
#
# Framing B measures the end-to-end latency including any gateway overhead,
# making it the most comparable to a real-world deployment.
#
# Usage:
#   bash bench/targets/framing-b.sh up
#   bash bench/targets/framing-b.sh down
#   bash bench/targets/framing-b.sh status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.sh"

FRAMING="b"
HS_DB="bench_hs_b"
HS_PG_CONTAINER="bench_hs_pg_b"
HS_PG_PORT="54332"                  # host-mapped port for HyperStack's pg17
HS_PG_PASS="bench_hs_pgpass"        # postgres superuser password in HS container

ENV_FILE="${BENCH_RESULTS_DIR}/framing-b.env"
PID_FILE="${BENCH_RESULTS_DIR}/framing-b.pid"
LOG_FILE="${BENCH_RESULTS_DIR}/framing-b.log"

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
  echo "[framing-b] Waiting for ${label} on port ${port} ..."
  while [[ $(date +%s) -lt $deadline ]]; do
    if PGPASSWORD="${pass}" "${PSQL_PATH}" -h localhost -p "${port}" -U postgres \
         -d postgres -tAc "SELECT 1" > /dev/null 2>&1; then
      echo "[framing-b] ${label} is ready."
      return 0
    fi
    sleep 0.5
  done
  echo "[framing-b] ERROR: ${label} on port ${port} not ready within 30s" >&2
  return 1
}

wait_ready() {
  local url="$1"
  local timeout_s="${2:-60}"
  local deadline=$(( $(date +%s) + timeout_s ))
  local ready_url="${url}/ready"
  echo "[framing-b] Waiting for HyperStack at ${ready_url} ..."
  while [[ $(date +%s) -lt $deadline ]]; do
    if curl -sf --max-time 1 "${ready_url}" > /dev/null 2>&1; then
      echo "[framing-b] HyperStack is ready."
      return 0
    fi
    sleep 0.5
  done
  echo "[framing-b] ERROR: HyperStack did not become ready within ${timeout_s}s" >&2
  return 1
}

# ── UP ─────────────────────────────────────────────────────────────────────────

cmd_up() {
  echo "[framing-b] Bringing up Framing B ..."
  mkdir -p "${BENCH_RESULTS_DIR}" "${BENCH_RAW_DIR}" "${HS_STORAGE_ROOT}/framing-b"

  # 1. Start HyperStack's dedicated postgres:17 container (if not already running)
  if docker inspect "${HS_PG_CONTAINER}" > /dev/null 2>&1; then
    local state
    state=$(docker inspect --format '{{.State.Status}}' "${HS_PG_CONTAINER}")
    if [[ "${state}" != "running" ]]; then
      echo "[framing-b] Container ${HS_PG_CONTAINER} exists but is ${state}; starting ..."
      docker start "${HS_PG_CONTAINER}"
    else
      echo "[framing-b] Container ${HS_PG_CONTAINER} already running."
    fi
  else
    echo "[framing-b] Starting postgres:17 container ${HS_PG_CONTAINER} on port ${HS_PG_PORT} ..."
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
    echo "[framing-b] Creating database ${HS_DB} ..."
    psql_hs_admin -c "CREATE DATABASE ${HS_DB};"
  else
    echo "[framing-b] Database ${HS_DB} already exists."
  fi

  # 3. Kill any previously running HyperStack for this framing
  if [[ -f "${PID_FILE}" ]]; then
    local old_pid
    old_pid=$(cat "${PID_FILE}" 2>/dev/null || true)
    if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
      echo "[framing-b] Stopping previous HyperStack PID=${old_pid} ..."
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

  echo "[framing-b] Starting HyperStack on ${HS_BIND} (pg port ${HS_PG_PORT}) ..."

  local DATABASE_URL="host=localhost port=${HS_PG_PORT} user=authenticator password=${HS_AUTHENTICATOR_PASSWORD} dbname=${HS_DB}"
  local ADMIN_DATABASE_URL="host=localhost port=${HS_PG_PORT} user=postgres password=${HS_PG_PASS} dbname=${HS_DB}"

  # 5. Spawn HyperStack
  env \
    DATABASE_URL="${DATABASE_URL}" \
    ADMIN_DATABASE_URL="${ADMIN_DATABASE_URL}" \
    AUTHENTICATOR_PASSWORD="${HS_AUTHENTICATOR_PASSWORD}" \
    JWT_SECRET="${HS_JWT_SECRET}" \
    SERVICE_KEY="${HS_SERVICE_KEY}" \
    ADMIN_TOKEN="${HS_ADMIN_TOKEN}" \
    BIND_ADDR="${HS_BIND}" \
    STORAGE_ROOT="${HS_STORAGE_ROOT}/framing-b" \
    RUST_LOG="warn" \
    PATH="$HOME/bin:/usr/local/bin:${PATH}" \
    "${HS_BINARY}" > "${LOG_FILE}" 2>&1 &
  local HS_PID=$!
  echo "${HS_PID}" > "${PID_FILE}"
  echo "[framing-b] HyperStack PID=${HS_PID}"

  # 6. Wait for ready
  if ! wait_ready "${HS_BASE_URL}" 60; then
    echo "[framing-b] HyperStack log tail:" >&2
    tail -30 "${LOG_FILE}" >&2
    kill "${HS_PID}" 2>/dev/null || true
    rm -f "${PID_FILE}"
    exit 1
  fi

  # 7. Trigger schema reload
  echo "[framing-b] Triggering schema reload ..."
  local reload_status
  reload_status=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" \
    -X POST "${HS_BASE_URL}/admin/v1/reload-schema" \
    -H "x-admin-token: ${HS_ADMIN_TOKEN}" \
    -H "content-type: application/json" || echo "000")
  if [[ "${reload_status}" != "200" ]]; then
    echo "[framing-b] Warning: schema reload returned HTTP ${reload_status}"
  else
    echo "[framing-b] Schema reloaded."
  fi

  # 8. Write env file — Supabase URLs go through Kong for Framing B
  cat > "${ENV_FILE}" <<EOF
# Framing B environment — generated by framing-b.sh up
# Do not edit manually.
FRAMING=b
HS_DB=${HS_DB}
HS_PG_PORT=${HS_PG_PORT}
HS_PG_PASS=${HS_PG_PASS}
HS_PG_CONTAINER=${HS_PG_CONTAINER}
SB_DB=${SB_DB}
HS_PORT=${HS_PORT}
HS_PID=${HS_PID}
HS_BASE_URL=${HS_BASE_URL}
HS_BASE_URL_K6=${HS_BASE_URL_K6}
SB_REST_URL_K6=http://${SB_KONG_CONTAINER}:8000/rest/v1
SB_AUTH_URL_K6=http://${SB_KONG_CONTAINER}:8000/auth/v1
SB_REST_URL_HOST=${SB_REST_URL_HOST}
SB_AUTH_URL_HOST=${SB_AUTH_URL_HOST}
SB_SERVICE_JWT=${SB_SERVICE_JWT}
SB_ANON_JWT=${SB_ANON_JWT}
HS_SERVICE_KEY=${HS_SERVICE_KEY}
HS_ADMIN_TOKEN=${HS_ADMIN_TOKEN}
EOF

  echo "[framing-b] Env written to ${ENV_FILE}"
  echo "[framing-b] Framing B is UP."
  echo "[framing-b]   HyperStack: ${HS_BASE_URL} (pg17 on port ${HS_PG_PORT})"
  echo "[framing-b]   Supabase:   Kong = http://localhost:54321 (full gateway stack)"
}

# ── DOWN ───────────────────────────────────────────────────────────────────────

cmd_down() {
  echo "[framing-b] Tearing down Framing B ..."

  local hs_pid=""
  if [[ -f "${ENV_FILE}" ]]; then
    hs_pid=$(grep '^HS_PID=' "${ENV_FILE}" | cut -d= -f2 || true)
  fi
  if [[ -z "${hs_pid}" ]] && [[ -f "${PID_FILE}" ]]; then
    hs_pid=$(cat "${PID_FILE}" 2>/dev/null || true)
  fi

  if [[ -n "${hs_pid}" ]] && kill -0 "${hs_pid}" 2>/dev/null; then
    echo "[framing-b] Stopping HyperStack PID=${hs_pid} ..."
    kill "${hs_pid}" 2>/dev/null || true
    local i=0
    while kill -0 "${hs_pid}" 2>/dev/null && [[ $i -lt 20 ]]; do
      sleep 0.5
      (( i++ )) || true
    done
    if kill -0 "${hs_pid}" 2>/dev/null; then
      echo "[framing-b] Force-killing PID=${hs_pid} ..."
      kill -9 "${hs_pid}" 2>/dev/null || true
    fi
  else
    echo "[framing-b] No running HyperStack found."
  fi

  rm -f "${PID_FILE}"

  if docker inspect "${HS_PG_CONTAINER}" > /dev/null 2>&1; then
    echo "[framing-b] Stopping pg container ${HS_PG_CONTAINER} ..."
    docker stop "${HS_PG_CONTAINER}" > /dev/null || true
  fi

  echo "[framing-b] Framing B is DOWN."
}

# ── STATUS ─────────────────────────────────────────────────────────────────────

cmd_status() {
  if [[ -f "${ENV_FILE}" ]]; then
    local hs_pid
    hs_pid=$(grep '^HS_PID=' "${ENV_FILE}" | cut -d= -f2 || true)
    if [[ -n "${hs_pid}" ]] && kill -0 "${hs_pid}" 2>/dev/null; then
      echo "[framing-b] HyperStack running (PID=${hs_pid})"
    else
      echo "[framing-b] HyperStack NOT running"
    fi
    cat "${ENV_FILE}"
  else
    echo "[framing-b] No env file found — not up."
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
