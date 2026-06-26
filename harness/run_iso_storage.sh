#!/usr/bin/env bash
# Corrected RUN 3: ISOLATED storage (fresh SB storage state), both framings, N=5.
set -uo pipefail
cd ~/HyperStack
source bench/config.sh

D=/usr/local/bin/docker
RUNID="$(date +%Y%m%d_%H%M%S)_isostor"
RAW="${BENCH_RAW_DIR}"
NET="${DOCKER_NETWORK}"
echo "RUNID=${RUNID}"

run_one() {
  local framing="$1" target="$2" out="$3" hs_url="$4" sb_url="$5"
  echo "[stor] framing=${framing} target=${target} -> $(basename "$out")"
  local ec=0
  $D run --rm \
    --add-host "host.docker.internal:host-gateway" \
    --network "${NET}" \
    -e "TARGET=${target}" \
    -e "HS_STORAGE_URL=${hs_url}" \
    -e "HS_SERVICE_KEY=${HS_SERVICE_KEY}" \
    -e "SB_STORAGE_URL=${sb_url}" \
    -e "SB_SERVICE_JWT=${SB_SERVICE_JWT}" \
    -e "SB_ANON_KEY=${SB_ANON_JWT}" \
    -v "${PWD}/bench/scenarios:/scenarios:ro" \
    -v "${RAW}:/results" \
    "${K6_IMAGE}" run --quiet \
      --summary-export "/results/$(basename "$out")" \
      "/scenarios/storage-updownload.js" >/dev/null 2>&1 || ec=$?
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
  envf="bench/results/framing-${framing}.env"
  hs_base=$(grep '^HS_BASE_URL_K6=' "$envf" | cut -d= -f2-)
  hs_url="${hs_base}/storage/v1"
  if [[ "$framing" == "a" ]]; then
    sb_url="http://supabase_storage_sb-bench:5000"
  else
    sb_url="http://supabase_kong_sb-bench:8000/storage/v1"
  fi
  echo "=== Framing ${framing}: HS=${hs_url} SB=${sb_url} ==="
  for run_n in 1 2 3 4 5; do
    run_one "$framing" "hyperstack" "${RAW}/k6-${framing}-storage-iso-hyperstack-${RUNID}-run${run_n}.json" "$hs_url" "$sb_url"
    run_one "$framing" "supabase" "${RAW}/k6-${framing}-storage-iso-supabase-${RUNID}-run${run_n}.json" "$hs_url" "$sb_url"
  done
done
echo "DONE RUNID=${RUNID}"
