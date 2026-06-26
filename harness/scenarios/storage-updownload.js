// bench/scenarios/storage-updownload.js — k6 Storage upload/download throughput + latency.
//
// Runs inside Docker (grafana/k6 image). No Node.js APIs.
// Exercises authed PUT /storage/v1/object/<bucket>/<path> (upload)
// and GET /storage/v1/object/<bucket>/<path> (download) for each target.
//
// Design: ONE target per k6 invocation (I4 — no ordering/warmup bias).
// The orchestrator (run.sh) runs separate k6 invocations per target.
//
// Object-key strategy: unique per VU per iteration (VU_ID + ITER_ID) to avoid
// overwrite contention and ensure every upload/download pair is independent.
// Overwriting is NOT tested explicitly; the uniqueness strategy measures upload
// throughput in a clean-write path, which is the realistic case.
//
// Two object sizes are tested within each invocation via separate custom metrics:
//   - 64 KB (SMALL): measures low-latency upload/download path (65536 bytes)
//   - 1 MB (LARGE): measures throughput under realistic file sizes (1048576 bytes)
//
// Both are uploaded, then downloaded, in the same VU iteration. Each size gets
// separate Trend/Rate metrics so p50/p95/p99 are disaggregated.
//
// HTTP method choice:
//   - Upload: POST /storage/v1/object/:bucket/*path (new object — both HS and SB)
//     The Supabase-compatible API uses POST for new uploads (supabase-js .upload()).
//     PUT is for updating existing objects (supabase-js .update()).
//     Since keys are unique per VU/iter, we always POST new objects.
//   - Download: GET /storage/v1/object/:bucket/*path (authed, private bucket)
//
// Auth design: use service-role JWTs for storage operations.
// Storage RLS in Supabase requires explicit per-bucket policies on storage.objects,
// which are not seeded in the bench fixture (RLS is set on bench_items only).
// Both targets bypass storage-level RLS with service-role credentials.
// This is honest: we measure raw storage throughput, not the overhead of storage RLS
// policy evaluation. The test is symmetric: both use service-role for upload/download.
//
// Env vars (passed via -e / --env):
//   TARGET             — "hyperstack" | "supabase"  (selects URL + JWT)
//   HS_STORAGE_URL     — e.g. http://host.docker.internal:PORT/storage/v1
//   HS_SERVICE_KEY     — HyperStack service-role key (bypasses storage RLS)
//   SB_STORAGE_URL     — e.g. http://supabase_storage_SDTool:5000
//   SB_SERVICE_JWT     — Supabase service-role JWT (bypasses storage RLS)
//   SB_ANON_KEY        — Supabase apikey header value
//
// Validity guards (I4 compliant):
//   - Upload must return 2xx (200 or 204)
//   - Download must return 200
//   - Download Content-Length must equal the uploaded byte count exactly (65536 or 1048576).
//     If Content-Length is absent, falls back to body.length check.
//     This rejects truncated or wrong-size responses that a non-empty guard would pass.
//
// Thresholds:
//   http_req_failed < 0.01 (< 1% error rate across all requests)
//   storage_upload_success_rate > 0.99
//   storage_download_success_rate > 0.99

import http from 'k6/http';
import { check } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';

// ── Sizes ─────────────────────────────────────────────────────────────────────

const SMALL_BYTES = 64 * 1024;       // 64 KB
const LARGE_BYTES = 1024 * 1024;     // 1 MB

// Pre-generate payloads as ArrayBuffer (k6 binary body)
// k6 does not support Buffer/Node APIs — use a simple string of fixed char repeated.
// Note: a repeated ASCII char gives exactly N bytes in UTF-8 / binary body.
function makePayload(size) {
  // k6 supports ArrayBuffer natively for binary HTTP bodies.
  // We generate a Uint8Array filled with a fixed byte value (0x61 = 'a').
  const buf = new Uint8Array(size);
  for (let i = 0; i < size; i++) {
    buf[i] = 0x61; // 'a'
  }
  return buf.buffer;
}

const SMALL_PAYLOAD = makePayload(SMALL_BYTES);
const LARGE_PAYLOAD = makePayload(LARGE_BYTES);

// ── Custom metrics ────────────────────────────────────────────────────────────

// Upload latency (ms), disaggregated by size
const uploadLatencySmall   = new Trend('storage_upload_latency_small_ms',  true);
const uploadLatencyLarge   = new Trend('storage_upload_latency_large_ms',  true);

// Download latency (ms), disaggregated by size
const downloadLatencySmall = new Trend('storage_download_latency_small_ms', true);
const downloadLatencyLarge = new Trend('storage_download_latency_large_ms', true);

// Success rates
const uploadSuccess   = new Rate('storage_upload_success_rate');
const downloadSuccess = new Rate('storage_download_success_rate');

// Error counters (for quick scan of summary output)
const uploadErrors   = new Counter('storage_upload_errors');
const downloadErrors = new Counter('storage_download_errors');

// ── Options ───────────────────────────────────────────────────────────────────
// Ramping-VU model matching rest-select.js: ramp to 20 VUs, hold 30s, ramp down.
// 20 VUs is enough to saturate both storage backends without excessively large files.

export const options = {
  scenarios: {
    storage_updownload: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration:  '5s', target: 20 },  // ramp to 20 VUs
        { duration: '30s', target: 20 },  // hold steady — measurement window
        { duration:  '5s', target:  0 },  // ramp down
      ],
      gracefulRampDown: '5s',
    },
  },
  thresholds: {
    http_req_failed:               ['rate<0.01'],   // <1% HTTP errors total
    storage_upload_success_rate:   ['rate>0.99'],
    storage_download_success_rate: ['rate>0.99'],
    // Relaxed latency bounds for storage (larger payloads than REST)
    storage_upload_latency_small_ms:   ['p(95)<10000'],
    storage_upload_latency_large_ms:   ['p(95)<30000'],
    storage_download_latency_small_ms: ['p(95)<10000'],
    storage_download_latency_large_ms: ['p(95)<30000'],
  },
};

// ── Default function ──────────────────────────────────────────────────────────

export default function () {
  const target = __ENV.TARGET || 'hyperstack';

  let storageBaseUrl, jwt, extraHeaders;

  if (target === 'supabase') {
    storageBaseUrl = __ENV.SB_STORAGE_URL;
    jwt            = __ENV.SB_SERVICE_JWT;  // service-role bypasses storage RLS
    const anonKey  = __ENV.SB_ANON_KEY || jwt;
    extraHeaders   = { 'apikey': anonKey };
  } else {
    // Default: hyperstack
    storageBaseUrl = __ENV.HS_STORAGE_URL;
    jwt            = __ENV.HS_SERVICE_KEY;  // service-role bypasses storage RLS
    extraHeaders   = {};
  }

  // Unique keys per VU per iteration — avoids overwrite contention,
  // ensures each upload/download pair is clean and independent.
  const keySmall = `bench-vu${__VU}-iter${__ITER}-small.bin`;
  const keyLarge = `bench-vu${__VU}-iter${__ITER}-large.bin`;

  const authHeaders = {
    'Authorization': `Bearer ${jwt}`,
    ...extraHeaders,
  };

  // ── Upload small (64 KB) ────────────────────────────────────────────────────
  // Use POST for new objects (supabase-js .upload() uses POST).
  // PUT is for updating existing objects (.update()), and would 404 on a fresh key.

  const uploadSmallUrl = `${storageBaseUrl}/object/bench/${keySmall}`;
  const uploadSmallRes = http.post(uploadSmallUrl, SMALL_PAYLOAD, {
    headers: {
      ...authHeaders,
      'Content-Type':   'application/octet-stream',
      'Content-Length': String(SMALL_BYTES),
    },
    timeout: '30s',
    tags: { target, scenario: 'storage-upload', size: 'small' },
  });

  const uploadSmallOk = check(uploadSmallRes, {
    'upload small: 2xx': (r) => r.status >= 200 && r.status < 300,
  });
  uploadLatencySmall.add(uploadSmallRes.timings.duration, { target });
  uploadSuccess.add(uploadSmallOk ? 1 : 0, { target });
  if (!uploadSmallOk) {
    uploadErrors.add(1, { target });
    // Do NOT attempt download if upload failed (no object to fetch)
    return;
  }

  // ── Upload large (1 MB) ─────────────────────────────────────────────────────

  const uploadLargeUrl = `${storageBaseUrl}/object/bench/${keyLarge}`;
  const uploadLargeRes = http.post(uploadLargeUrl, LARGE_PAYLOAD, {
    headers: {
      ...authHeaders,
      'Content-Type':   'application/octet-stream',
      'Content-Length': String(LARGE_BYTES),
    },
    timeout: '30s',
    tags: { target, scenario: 'storage-upload', size: 'large' },
  });

  const uploadLargeOk = check(uploadLargeRes, {
    'upload large: 2xx': (r) => r.status >= 200 && r.status < 300,
  });
  uploadLatencyLarge.add(uploadLargeRes.timings.duration, { target });
  uploadSuccess.add(uploadLargeOk ? 1 : 0, { target });
  if (!uploadLargeOk) {
    uploadErrors.add(1, { target });
  }

  // ── Download small (64 KB) ──────────────────────────────────────────────────

  const downloadSmallUrl = `${storageBaseUrl}/object/bench/${keySmall}`;
  const downloadSmallRes = http.get(downloadSmallUrl, {
    headers: {
      ...authHeaders,
    },
    timeout: '30s',
    tags: { target, scenario: 'storage-download', size: 'small' },
  });

  // Validity guards:
  // 1. Must be HTTP 200
  // 2. Content-Length must equal SMALL_BYTES exactly (65536) when the header is present.
  //    This rejects truncated downloads and wrong-size responses that a "> 0" guard passes.
  //    Falls back to body.length === SMALL_BYTES when Content-Length is absent.
  const downloadSmallOk = check(downloadSmallRes, {
    'download small: 200':           (r) => r.status === 200,
    'download small: exact size':    (r) => {
      const cl = r.headers['Content-Length'];
      if (cl !== undefined && cl !== null) return parseInt(cl, 10) === SMALL_BYTES;
      return r.body !== null && r.body.length === SMALL_BYTES;
    },
  });
  downloadLatencySmall.add(downloadSmallRes.timings.duration, { target });
  downloadSuccess.add(downloadSmallOk ? 1 : 0, { target });
  if (!downloadSmallOk) {
    downloadErrors.add(1, { target });
  }

  // ── Download large (1 MB) ───────────────────────────────────────────────────

  if (!uploadLargeOk) {
    // Large upload failed — skip large download
    return;
  }

  const downloadLargeUrl = `${storageBaseUrl}/object/bench/${keyLarge}`;
  const downloadLargeRes = http.get(downloadLargeUrl, {
    headers: {
      ...authHeaders,
    },
    timeout: '30s',
    tags: { target, scenario: 'storage-download', size: 'large' },
  });

  const downloadLargeOk = check(downloadLargeRes, {
    'download large: 200':        (r) => r.status === 200,
    'download large: exact size': (r) => {
      const cl = r.headers['Content-Length'];
      if (cl !== undefined && cl !== null) return parseInt(cl, 10) === LARGE_BYTES;
      return r.body !== null && r.body.length === LARGE_BYTES;
    },
  });
  downloadLatencyLarge.add(downloadLargeRes.timings.duration, { target });
  downloadSuccess.add(downloadLargeOk ? 1 : 0, { target });
  if (!downloadLargeOk) {
    downloadErrors.add(1, { target });
  }
}
