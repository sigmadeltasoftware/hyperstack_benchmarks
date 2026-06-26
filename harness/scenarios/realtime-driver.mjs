#!/usr/bin/env node
// bench/scenarios/realtime-driver.mjs — Realtime fan-out benchmark driver.
//
// Measures WebSocket postgres_changes delivery latency and drop rate for
// both HyperStack and Supabase realtime.
//
// HEADLINE protocol (both sides — apples-to-apples):
//   HyperStack: supabase-js Phoenix at /realtime/v1/websocket
//               Uses @supabase/supabase-js channel.on('postgres_changes',...)
//               Same client path a supabase-js user experiences.
//   Supabase:   supabase-js Phoenix at /realtime/v1/websocket (via Kong)
//               Uses @supabase/supabase-js channel.on('postgres_changes',...)
//
// SECONDARY (opt-in, --hs-native-protocol flag, clearly labeled):
//   HyperStack native WS: /realtime/v1?token=<jwt>
//   subscribe msg: {"subscribe":"bench_items"}
//   receive msg:   {"table":"bench_items","op":"INSERT","record":{...}}
//   Lower framing overhead than Phoenix — NOT the supabase-js path. Recorded
//   separately as "HyperStack native protocol (not the supabase-js path)".
//
// HISTORY NOTE: An earlier run (2026-06-24) used the native protocol for
// HyperStack because the release binary predated the Phoenix endpoint mount
// (/realtime/v1/websocket returned 404). The binary has since been rebuilt
// (2026-06-25); the Phoenix path is confirmed working. See FAIRNESS.md §C3.
//
// Usage (env vars or CLI args):
//   node bench/scenarios/realtime-driver.mjs --target both --hs-url URL ...
//   node bench/scenarios/realtime-driver.mjs --target hyperstack --hs-native-protocol ...
//
// Prints JSON to stdout on completion. Progress/errors go to stderr.

import { createClient } from '../../clients/hyperstack-js/node_modules/@supabase/supabase-js/dist/index.mjs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PSQL_PATH = process.env.PSQL_PATH || process.env.HOME + '/bin/psql-bench';

// ── CLI / Env arg parsing ─────────────────────────────────────────────────────

function parseArgs() {
  const argv = process.argv.slice(2);
  const env = process.env;
  const get = (flag, envKey, def) => {
    const idx = argv.indexOf(flag);
    if (idx !== -1 && argv[idx + 1] !== undefined) return argv[idx + 1];
    if (env[envKey] !== undefined) return env[envKey];
    return def;
  };

  const hasFlag = (flag) => argv.includes(flag);

  return {
    target:             get('--target',            'TARGET',               'both'),
    hsBaseUrl:          get('--hs-url',            'HS_BASE_URL',          ''),
    hsJwt:              get('--hs-jwt',            'HS_JWT',               ''),
    hsAnonKey:          get('--hs-anon-key',       'HS_ANON_KEY',          ''),
    hsServiceKey:       get('--hs-service-key',    'HS_SERVICE_KEY',       ''),
    hsUserId:           get('--hs-user-id',        'HS_USER_ID',           ''),
    hsPgPort:           get('--hs-pg-port',        'HS_PG_PORT',           '54330'),
    hsPgPass:           get('--hs-pg-pass',        'HS_PG_PASS',           'bench_hs_pgpass'),
    hsDb:               get('--hs-db',             'HS_DB',                'bench_hs'),
    // --hs-native-protocol: record a SECONDARY labeled run using the native WS
    // protocol (not the supabase-js Phoenix path). NOT used for headline numbers.
    hsNativeProtocol:   hasFlag('--hs-native-protocol') || (process.env.HS_NATIVE_PROTOCOL === '1'),
    sbBaseUrl:          get('--sb-url',            'SB_BASE_URL',          'http://localhost:54321'),
    sbJwt:              get('--sb-jwt',            'SB_JWT',               ''),
    sbServiceJwt:       get('--sb-service-jwt',    'SB_SERVICE_JWT',       ''),
    sbAnonKey:          get('--sb-anon-key',       'SB_ANON_KEY',          ''),
    sbUserId:           get('--sb-user-id',        'SB_USER_ID',           ''),
    n:          parseInt(get('--n',              'RT_N',               '10'),  10),
    m:          parseInt(get('--m',              'RT_M',               '5'),   10),
    d:          parseInt(get('--d',              'RT_D',               '20'),  10),
    mode:           get('--mode',            'RT_MODE',            'bench'),
    fanoutLevels:   get('--fanout-levels',   'RT_FANOUT_LEVELS',   '5,10,25,50'),
    dropThreshold: parseFloat(get('--drop-threshold', 'RT_DROP_THRESHOLD', '0.01')),
    p99ThresholdMs:parseInt(get('--p99-threshold', 'RT_P99_THRESHOLD_MS', '2000'), 10),
    runs:       parseInt(get('--runs',           'RT_RUNS',            '5'),   10),
  };
}

// ── Percentile helper ─────────────────────────────────────────────────────────

function percentile(sorted, p) {
  if (sorted.length === 0) return 0;
  const idx = Math.ceil((p / 100) * sorted.length) - 1;
  return sorted[Math.max(0, idx)];
}

// ── Realtime setup helpers ────────────────────────────────────────────────────

function psqlExec(connStr, sql, pgPass) {
  try {
    execFileSync(PSQL_PATH, [connStr, '-c', sql], {
      encoding: 'utf8',
      env: { ...process.env, PGPASSWORD: pgPass },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (e) {
    const msg = (e.stderr || e.stdout || e.message || '').toString();
    // Ignore "already a member" or similar idempotent messages
    if (!msg.includes('already') && !msg.includes('does not exist')) {
      console.error(`[rt-driver] psql: ${msg.split('\n')[0].trim()}`);
    }
  }
}

function setupHsRealtime(pgPort, pgPass, hsDb) {
  console.error('[rt-driver] Enabling realtime on HyperStack bench_items ...');
  const connStr = `host=localhost port=${pgPort} user=postgres dbname=${hsDb}`;
  psqlExec(connStr, "SELECT realtime.enable('public.bench_items');", pgPass);
}

function setupSbRealtime() {
  console.error('[rt-driver] Ensuring bench_items in supabase_realtime publication ...');
  const sbPgPort = process.env.BENCH_PG_PORT || '54322';
  const connStr = `host=localhost port=${sbPgPort} user=postgres dbname=postgres`;
  psqlExec(connStr, 'ALTER PUBLICATION supabase_realtime ADD TABLE public.bench_items;', 'postgres');
}

// ── HyperStack native WS subscriber ──────────────────────────────────────────
// Uses Node 25's built-in WebSocket (no library needed).
// Protocol: connect with ?token=<jwt>, send {"subscribe":"bench_items"},
// receive {"table":"bench_items","op":"INSERT","record":{body:...}}.

function makeHsSubscriber(wsUrl) {
  const latencies = [];
  let received = 0;
  let ws = null;
  let closed = false;

  const readyPromise = new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error('HyperStack WS connect timeout after 30s'));
    }, 30_000);

    ws = new WebSocket(wsUrl);

    ws.onopen = () => {
      clearTimeout(timer);
      // Send subscription request
      ws.send(JSON.stringify({ subscribe: 'bench_items' }));
      resolve();
    };

    ws.onerror = (e) => {
      clearTimeout(timer);
      if (!closed) reject(new Error(`WS error: ${e.message ?? 'unknown'}`));
    };

    ws.onmessage = (e) => {
      try {
        const msg = JSON.parse(e.data);
        if (msg.op === 'INSERT' && msg.table === 'bench_items') {
          try {
            const body = JSON.parse(msg.record?.body ?? '{}');
            if (body.inserted_at) {
              latencies.push(Date.now() - body.inserted_at);
            }
          } catch (_) { /* ignore malformed body */ }
          received++;
        }
      } catch (_) { /* ignore malformed frame */ }
    };
  });

  return {
    readyPromise,
    getStats: () => ({ latencies, received }),
    close: () => {
      closed = true;
      try { if (ws) ws.close(); } catch (_) {}
    },
  };
}

// ── Supabase supabase-js subscriber ──────────────────────────────────────────
// Uses Phoenix protocol via supabase-js.

function makeSbSubscriber(baseUrl, anonKey, jwt) {
  const latencies = [];
  let received = 0;
  let client = null;

  const readyPromise = new Promise(async (resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error('Supabase realtime SUBSCRIBED timeout after 30s'));
    }, 30_000);

    try {
      client = createClient(baseUrl, anonKey, {
        global: { headers: { Authorization: `Bearer ${jwt}` } },
        realtime: { params: { apikey: anonKey } },
      });
      await client.realtime.setAuth(jwt);

      client.channel(`bench-rt-sb-${Date.now()}`)
        .on('postgres_changes',
          { event: 'INSERT', schema: 'public', table: 'bench_items' },
          (payload) => {
            try {
              const body = JSON.parse(payload.new?.body ?? '{}');
              if (body.inserted_at) {
                latencies.push(Date.now() - body.inserted_at);
              }
            } catch (_) { /* ignore */ }
            received++;
          }
        )
        .subscribe((status, err) => {
          if (status === 'SUBSCRIBED') {
            clearTimeout(timer);
            resolve();
          } else if (
            status === 'CHANNEL_ERROR' ||
            status === 'TIMED_OUT' ||
            status === 'CLOSED'
          ) {
            clearTimeout(timer);
            reject(new Error(`Channel status: ${status} ${err?.message ?? ''}`));
          }
        });
    } catch (e) {
      clearTimeout(timer);
      reject(e);
    }
  });

  return {
    readyPromise,
    getStats: () => ({ latencies, received }),
    close: async () => {
      try { if (client) await client.removeAllChannels(); } catch (_) {}
      try { if (client) client.realtime.disconnect(); } catch (_) {}
    },
  };
}

// ── Publisher (REST API) ──────────────────────────────────────────────────────
// Fires M inserts per second for D seconds using fire-and-forget.
// Uses service role for HyperStack (plain Authorization header).
// Uses service role for Supabase (Authorization + apikey headers).

async function runPublisher(cfg, firedCallback) {
  const { baseUrl, serviceKey, userId, m, d, isHyperStack, sbAnonKey } = cfg;
  const restUrl = `${baseUrl}/rest/v1/bench_items`;
  const intervalMs = Math.floor(1000 / m);
  let seqCounter = 0;
  let firedCount = 0;
  const errors = [];

  const headers = {
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${serviceKey}`,
    'Prefer': 'return=minimal',
  };
  if (!isHyperStack && sbAnonKey) {
    headers['apikey'] = sbAnonKey;
  }

  return new Promise((resolve) => {
    const startTime = Date.now();

    const doInsert = () => {
      if (Date.now() - startTime >= d * 1000) {
        resolve({ fired: firedCount, errors: errors.slice(0, 5) });
        return;
      }

      const seq = seqCounter++;
      const insertedAt = Date.now();
      const body = JSON.stringify({ inserted_at: insertedAt, seq });
      firedCount++;
      firedCallback?.(firedCount);

      // Fire-and-forget
      fetch(restUrl, {
        method: 'POST',
        headers,
        body: JSON.stringify({ owner: userId, body }),
      })
        .then(r => { if (!r.ok) errors.push(`HTTP ${r.status}`); })
        .catch(e => errors.push(e.message ?? String(e)));

      setTimeout(doInsert, intervalMs);
    };

    setTimeout(doInsert, 0);
  });
}

// ── Core bench measurement ────────────────────────────────────────────────────

async function runRealtimeOnTarget(cfg) {
  const {
    label, baseUrl, anonKey, jwt, userId, serviceKey,
    n, m, d, isHyperStack, useNativeProtocol, sbAnonKey, sbServiceJwt,
  } = cfg;

  console.error(`[rt-driver] ${label}: connecting ${n} subscribers (N=${n}, M=${m}/s, D=${d}s) ...`);

  // Build N subscribers.
  // HEADLINE: both HyperStack and Supabase use supabase-js Phoenix path.
  // SECONDARY: HyperStack-only native protocol (useNativeProtocol=true).
  const subscribers = [];
  const subscriberResults = [];

  for (let i = 0; i < n; i++) {
    let sub;
    if (isHyperStack && useNativeProtocol) {
      // Secondary labeled path: HyperStack native WS protocol (not supabase-js).
      // Not used for headline comparison numbers.
      const wsUrl = `${baseUrl.replace('http://', 'ws://').replace('https://', 'wss://')}/realtime/v1?token=${encodeURIComponent(jwt)}`;
      sub = makeHsSubscriber(wsUrl);
    } else {
      // HEADLINE path: supabase-js Phoenix /realtime/v1/websocket — same client
      // a supabase-js user connects with. Used for HyperStack AND Supabase.
      sub = makeSbSubscriber(baseUrl, anonKey, jwt);
    }
    subscribers.push(sub);
  }

  // Wait for all subscribers (with individual timeout handling)
  const subSettled = await Promise.allSettled(
    subscribers.map(s => s.readyPromise)
  );

  let okCount = 0;
  for (let i = 0; i < subSettled.length; i++) {
    if (subSettled[i].status === 'fulfilled') {
      okCount++;
    } else {
      console.error(`[rt-driver] ${label}: subscriber ${i} failed: ${subSettled[i].reason?.message}`);
    }
  }

  console.error(`[rt-driver] ${label}: ${okCount}/${n} subscribers ready`);

  if (okCount === 0) {
    for (const sub of subscribers) {
      try { await sub.close(); } catch (_) {}
    }
    return {
      ok: false, p50: 0, p95: 0, p99: 0,
      total_expected: m * d * n,
      total_received: 0, drop_rate: 1.0,
      per_subscriber_stats: [],
    };
  }

  // Publisher service key
  const pubServiceKey = isHyperStack ? serviceKey : sbServiceJwt;

  console.error(`[rt-driver] ${label}: starting publisher (${m} rows/s for ${d}s) ...`);
  const pubResult = await runPublisher({
    baseUrl, serviceKey: pubServiceKey, userId, m, d, isHyperStack, sbAnonKey,
  });

  const totalFired = pubResult.fired;
  if (pubResult.errors.length > 0) {
    console.error(`[rt-driver] ${label}: ${pubResult.errors.length} insert errors: ${pubResult.errors.slice(0,3).join(', ')}`);
  }

  console.error(`[rt-driver] ${label}: publisher done (${totalFired} fired). Waiting buffer (3s) ...`);
  await new Promise(r => setTimeout(r, 3000));

  // Collect stats
  const allLatencies = [];
  let totalReceived = 0;
  for (let i = 0; i < subscribers.length; i++) {
    if (subSettled[i].status === 'rejected') continue;
    const stats = subscribers[i].getStats();
    allLatencies.push(...stats.latencies);
    totalReceived += stats.received;
    subscriberResults.push({ sub: i, received: stats.received, expected: totalFired });
  }

  // Cleanup
  for (const sub of subscribers) {
    try { await sub.close(); } catch (_) {}
  }

  // Wait for WS connections to close
  await new Promise(r => setTimeout(r, 500));

  allLatencies.sort((a, b) => a - b);
  const totalExpected = totalFired * okCount;
  const p50 = percentile(allLatencies, 50);
  const p95 = percentile(allLatencies, 95);
  const p99 = percentile(allLatencies, 99);
  const dropRate = totalExpected > 0
    ? Math.max(0, (totalExpected - totalReceived) / totalExpected)
    : 0;

  console.error(`[rt-driver] ${label}: p50=${p50}ms p95=${p95}ms p99=${p99}ms drop=${(dropRate * 100).toFixed(1)}% recv=${totalReceived}/${totalExpected}`);

  return {
    ok: true, p50, p95, p99,
    total_expected: totalExpected,
    total_received: totalReceived,
    drop_rate: dropRate,
    insert_errors: pubResult.errors.length,
    subscribers_ok: okCount,
    per_subscriber_stats: subscriberResults,
  };
}

// ── Bench mode ────────────────────────────────────────────────────────────────

async function runBenchMode(targetCfg, runs) {
  const results = [];
  for (let r = 1; r <= runs; r++) {
    console.error(`[rt-driver] Run ${r}/${runs} for ${targetCfg.label} ...`);
    const res = await runRealtimeOnTarget(targetCfg);
    results.push({
      run: r,
      p50: res.p50, p95: res.p95, p99: res.p99,
      total_expected: res.total_expected,
      total_received: res.total_received,
      drop_rate: res.drop_rate,
      subscribers_ok: res.subscribers_ok ?? 0,
    });
    if (r < runs) await new Promise(r => setTimeout(r, 3000));
  }

  const sortedP50 = results.map(r => r.p50).sort((a,b) => a-b);
  const sortedP95 = results.map(r => r.p95).sort((a,b) => a-b);
  const sortedP99 = results.map(r => r.p99).sort((a,b) => a-b);
  const avgDropRate = results.reduce((s, r) => s + r.drop_rate, 0) / results.length;

  return {
    runs: results,
    summary: {
      p50_median: percentile(sortedP50, 50),
      p95_median: percentile(sortedP95, 50),
      p99_median: percentile(sortedP99, 50),
      avg_drop_rate: avgDropRate,
    },
  };
}

// ── Fanout ramp mode ──────────────────────────────────────────────────────────

async function runFanoutMode(targetCfg, levels, dropThreshold, p99Threshold) {
  const results = [];
  let maxSustainableN = 0;

  for (const n of levels) {
    console.error(`[rt-driver] Fanout: ${targetCfg.label} N=${n} ...`);
    const res = await runRealtimeOnTarget({ ...targetCfg, n });
    const ceiling = res.drop_rate >= dropThreshold || res.p99 >= p99Threshold;
    results.push({
      n, p50: res.p50, p95: res.p95, p99: res.p99,
      total_expected: res.total_expected,
      total_received: res.total_received,
      drop_rate: res.drop_rate,
      ceiling,
    });

    if (!ceiling) {
      maxSustainableN = n;
    } else {
      console.error(`[rt-driver] Ceiling at N=${n}: drop=${(res.drop_rate*100).toFixed(1)}% p99=${res.p99}ms`);
      break;
    }
    await new Promise(r => setTimeout(r, 3000));
  }

  return { results, max_sustainable_n: maxSustainableN };
}

// ── Main ──────────────────────────────────────────────────────────────────────

const args = parseArgs();

const targets = args.target === 'both'
  ? ['hyperstack', 'supabase']
  : [args.target];

// Realtime setup (idempotent)
if (targets.includes('hyperstack') && args.hsBaseUrl) {
  try { setupHsRealtime(args.hsPgPort, args.hsPgPass, args.hsDb); }
  catch (e) { console.error(`[rt-driver] HS realtime setup error: ${e.message}`); }
}
if (targets.includes('supabase')) {
  try { setupSbRealtime(); }
  catch (e) { console.error(`[rt-driver] SB realtime setup error: ${e.message}`); }
}

await new Promise(r => setTimeout(r, 1000));

const fanoutLevels = args.fanoutLevels.split(',')
  .map(s => parseInt(s.trim(), 10))
  .filter(n => n > 0);

const outputAll = {};

// HEADLINE: HyperStack is benchmarked via supabase-js Phoenix path (/realtime/v1/websocket),
// the same client path a supabase-js user connects with. This is the apples-to-apples
// comparison. Pass --hs-native-protocol to also record the native WS protocol as a
// separate labeled secondary datapoint.
if (args.hsNativeProtocol && targets.includes('hyperstack')) {
  console.error('[rt-driver] NOTE: --hs-native-protocol set — HyperStack native WS protocol');
  console.error('[rt-driver] will be recorded as a SECONDARY datapoint (labeled). Headline');
  console.error('[rt-driver] numbers use the Phoenix/supabase-js path for both targets.');
}

for (const target of targets) {
  const isHyperStack = target === 'hyperstack';
  const baseUrl    = isHyperStack ? args.hsBaseUrl    : args.sbBaseUrl;
  const jwt        = isHyperStack ? args.hsJwt        : args.sbJwt;
  const userId     = isHyperStack ? args.hsUserId     : args.sbUserId;
  const serviceKey = isHyperStack ? args.hsServiceKey : args.sbServiceJwt;
  // HEADLINE anonKey: for HyperStack Phoenix path, use --hs-anon-key if provided,
  // otherwise fall back to --hs-service-key (service key works as anon key for HS).
  const anonKey    = isHyperStack
    ? (args.hsAnonKey || args.hsServiceKey)
    : args.sbAnonKey;
  const label      = isHyperStack ? 'HyperStack (Phoenix/supabase-js)' : 'Supabase';

  if (!baseUrl) {
    console.error(`[rt-driver] Skipping ${target} — no base URL`);
    continue;
  }
  if (!jwt) {
    console.error(`[rt-driver] Skipping ${target} — no JWT`);
    continue;
  }

  // HEADLINE: supabase-js Phoenix path (both targets)
  const targetCfg = {
    label, baseUrl, anonKey, jwt, userId,
    serviceKey, sbServiceJwt: args.sbServiceJwt, sbAnonKey: args.sbAnonKey,
    n: args.n, m: args.m, d: args.d,
    isHyperStack,
    useNativeProtocol: false,  // Phoenix/supabase-js path (headline)
  };

  if (args.mode === 'bench') {
    console.error(`[rt-driver] Bench (HEADLINE): ${label} (${args.runs} run(s), N=${args.n}, M=${args.m}/s, D=${args.d}s)`);
    const result = await runBenchMode(targetCfg, args.runs);
    outputAll[target] = {
      target, mode: 'bench', protocol: 'phoenix-supabase-js',
      params: { n: args.n, m: args.m, d: args.d, runs: args.runs },
      ...result,
    };
  } else {
    console.error(`[rt-driver] Fanout (HEADLINE): ${label} levels=${fanoutLevels.join(',')}`);
    const result = await runFanoutMode(targetCfg, fanoutLevels, args.dropThreshold, args.p99ThresholdMs);
    outputAll[target] = {
      target, mode: 'fanout', protocol: 'phoenix-supabase-js',
      params: { m: args.m, d: args.d, levels: fanoutLevels },
      ...result,
    };
  }

  // SECONDARY (opt-in): HyperStack native protocol — clearly labeled, not headline.
  if (isHyperStack && args.hsNativeProtocol) {
    const nativeLabel = 'HyperStack native protocol (not the supabase-js path)';
    const nativeCfg = {
      ...targetCfg,
      label: nativeLabel,
      useNativeProtocol: true,
    };
    console.error(`[rt-driver] SECONDARY: ${nativeLabel} ...`);
    if (args.mode === 'bench') {
      const nativeResult = await runBenchMode(nativeCfg, args.runs);
      outputAll['hyperstack_native'] = {
        target: 'hyperstack_native',
        mode: 'bench', protocol: 'native-ws',
        label: nativeLabel,
        note: 'Secondary labeled datapoint only. NOT used for headline comparison. Lower framing overhead than Phoenix.',
        params: { n: args.n, m: args.m, d: args.d, runs: args.runs },
        ...nativeResult,
      };
    } else {
      const nativeResult = await runFanoutMode(nativeCfg, fanoutLevels, args.dropThreshold, args.p99ThresholdMs);
      outputAll['hyperstack_native'] = {
        target: 'hyperstack_native',
        mode: 'fanout', protocol: 'native-ws',
        label: nativeLabel,
        note: 'Secondary labeled datapoint only. NOT used for headline comparison. Lower framing overhead than Phoenix.',
        params: { m: args.m, d: args.d, levels: fanoutLevels },
        ...nativeResult,
      };
    }
  }
}

// Print final JSON to stdout
if (targets.length === 1) {
  console.log(JSON.stringify(outputAll[targets[0]], null, 2));
} else {
  console.log(JSON.stringify(outputAll, null, 2));
}
