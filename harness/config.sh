#!/usr/bin/env bash
# bench/config.sh — Shared configuration for all bench scripts.
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# ── Postgres (shared pg17 instance) ───────────────────────────────────────────
export BENCH_PG_HOST="localhost"
export BENCH_PG_PORT="55422"
export BENCH_PG_USER="postgres"
export BENCH_PG_PASSWORD="postgres"
export PSQL_PATH="$HOME/bin/psql-bench"
export PATH="$HOME/bin:/usr/local/bin:$PATH"

# ── HyperStack binary ─────────────────────────────────────────────────────────
BENCH_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BENCH_REPO_ROOT
# PACKAGE MODE: use the bundled prebuilt binary shipped at the package root.
export HS_BINARY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hyperstack"

# HyperStack bench secrets
export HS_JWT_SECRET="bench-jwt-secret-0123456789abcdef-long"
export HS_SERVICE_KEY="bench-service-key-0123456789abcdef-long"
export HS_ADMIN_TOKEN="bench-admin-token-1234"
export HS_AUTHENTICATOR_PASSWORD="benchauthpass"
export HS_STORAGE_ROOT="${BENCH_REPO_ROOT}/target/bench-storage"

# ── Supabase (sb-bench local stack) ──────────────────────────────────────────
export SB_DB="postgres"

# JWT tokens (standard Supabase demo tokens — same for all local stacks)
export SB_ANON_JWT="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
export SB_SERVICE_JWT="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU"
export SB_ANON_KEY="sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"
export SB_SECRET_KEY="REDACTED_REGENERATE_FROM_supabase_start_OUTPUT"  # local sb-bench secret key — regenerate from your own `supabase start`

# Supabase URLs — host-accessible (via Kong at 55421)
export SB_KONG_HOST="localhost:55421"
export SB_REST_URL_HOST="http://localhost:55421/rest/v1"
export SB_AUTH_URL_HOST="http://localhost:55421/auth/v1"
export SB_STORAGE_URL_HOST="http://localhost:55421/storage/v1"

# Supabase container names (reachable inside supabase_network_sb-bench)
export SB_KONG_CONTAINER="supabase_kong_sb-bench"
export SB_REST_CONTAINER="supabase_rest_sb-bench"
export SB_AUTH_CONTAINER="supabase_auth_sb-bench"
export SB_REALTIME_CONTAINER="supabase_realtime_sb-bench"
export SB_STORAGE_CONTAINER="supabase_storage_sb-bench"
export SB_DB_CONTAINER="supabase_db_sb-bench"

# ── Docker / k6 ───────────────────────────────────────────────────────────────
export DOCKER_NETWORK="supabase_network_sb-bench"
export K6_IMAGE="grafana/k6"

# ── Results directory ─────────────────────────────────────────────────────────
export BENCH_RESULTS_DIR="${BENCH_REPO_ROOT}/bench/results"
export BENCH_RAW_DIR="${BENCH_RESULTS_DIR}/raw"

# ── Fixture defaults ──────────────────────────────────────────────────────────
export DEFAULT_FIXTURE_K=10     # users
export DEFAULT_FIXTURE_R=100    # rows
export DEFAULT_FIXTURE_S=5      # storage objects
