#!/usr/bin/env bash
# Corrected RUN 2: realtime-enabled insert into bench_items (write-tax), both framings, N=5.
set -uo pipefail
cd ~/HyperStack
source bench/config.sh

D=/usr/local/bin/docker
RUNID="$(date +%Y%m%d_%H%M%S)_rtins"
RAW="${BENCH_RAW_DIR}"
NET="${DOCKER_NETWORK}"
SB_ANON="sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"
echo "RUNID=${RUNID}"

run_one() {
  local framing="$1" target="$2" out="$3"
  local hs_url="$4" hs_jwt="$5" hs_uid="$6" sb_url="$7" sb_jwt="$8" sb_uid="$9"
  echo "[plain] framing=${framing} target=${target} -> $(basename "$out")"
  local ec=0
  $D run --rm \
    --add-host "host.docker.internal:host-gateway" \
    --network "${NET}" \
    -e "TARGET=${target}" \
    -e "HS_REST_URL=${hs_url}" \
    -e "HS_JWT=${hs_jwt}" \
    -e "HS_USER_ID=${hs_uid}" \
    -e "SB_REST_URL=${sb_url}" \
    -e "SB_JWT=${sb_jwt}" \
    -e "SB_USER_ID=${sb_uid}" \
    -e "SB_ANON_KEY=${SB_ANON}" \
    -v "${PWD}/bench/scenarios:/scenarios:ro" \
    -v "${RAW}:/results" \
    "${K6_IMAGE}" run --quiet \
      --summary-export "/results/$(basename "$out")" \
      "/scenarios/rest-insert.js" >/dev/null 2>&1 || ec=$?
  if [[ "$ec" -eq 99 ]]; then
    node -e "const fs=require('fs');const d=JSON.parse(fs.readFileSync('$out','utf8'));d.__bench_threshold_failed=true;d.__bench_target='$target';fs.writeFileSync('$out',JSON.stringify(d));"
    echo "  -> threshold FAILED (marked)"
  elif [[ "$ec" -ne 0 ]]; then
    echo "  -> ERROR exit $ec"
  else
    echo "  -> OK"
  fi
}

for framing in a b; do
  seed="bench/results/framing-${framing}-seed.json"
  hs_jwt=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$seed')).hyperstack.users[0].jwt)")
  hs_uid=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$seed')).hyperstack.users[0].userId)")
  sb_jwt=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$seed')).supabase.users[0].jwt)")
  sb_uid=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$seed')).supabase.users[0].userId)")
  # URLs per framing
  envf="bench/results/framing-${framing}.env"
  hs_url=$(grep '^HS_BASE_URL_K6=' "$envf" | cut -d= -f2-)/rest/v1
  sb_url=$(grep '^SB_REST_URL_K6=' "$envf" | cut -d= -f2-)
  echo "=== Framing ${framing}: HS=${hs_url} SB=${sb_url} ==="
  for run_n in 1 2 3 4 5; do
    run_one "$framing" "hyperstack" "${RAW}/k6-${framing}-rest-insert-rt-hyperstack-${RUNID}-run${run_n}.json" \
      "$hs_url" "$hs_jwt" "$hs_uid" "$sb_url" "$sb_jwt" "$sb_uid"
    run_one "$framing" "supabase" "${RAW}/k6-${framing}-rest-insert-rt-supabase-${RUNID}-run${run_n}.json" \
      "$hs_url" "$hs_jwt" "$hs_uid" "$sb_url" "$sb_jwt" "$sb_uid"
  done
done
echo "DONE RUNID=${RUNID}"
