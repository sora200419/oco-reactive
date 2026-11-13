#!/usr/bin/env node
// Latency tool for the OCO system on Unichain Sepolia + Reactive Lasna.
//
//   node tools/latency/latency.mjs run [rounds]          place an order, push the price through it,
//                                                       time the loop; repeat. Sends real transactions.
//   node tools/latency/latency.mjs replay <swapTx>...    measure loops that already happened from
//                                                       their swap transactions. Read-only.
//
// Settings come from the environment (the same names as the deployment runbook): ORIGIN_RPC,
// REACTIVE_RPC, ORDER_VAULT_ADDR, OCO_REACTIVE_ADDR, SWAPPER_ADDR, TOKEN0_ADDR, TOKEN1_ADDR.
// `run` also needs OCO_KEYSTORE_PASSWORD (read it with `read -rs` in your own shell; it is passed to
// `cast` and never written anywhere) and optionally OCO_KEYSTORE (default
// ~/.foundry/keystores/deployer). Tuning: LATENCY_ORDER_AMOUNT_WEI, LATENCY_PUSH_AMOUNT_WEI,
// LATENCY_LEVEL_OFFSET, LATENCY_ROUND_TIMEOUT_S, LATENCY_POLL_MS.
//
// Two measurements per round:
//   on chain:  swap block -> callback block on Unichain Sepolia, as block count and block-timestamp
//              seconds. Both ends are on the same chain, so the same clock.
//   observed:  milliseconds between this tool seeing the swap mined and seeing the reactive
//              transaction on Lasna / the callback on Unichain Sepolia. Each "seen" time comes from
//              polling, so each end is late by up to one poll cycle (the sleep plus the RPC round
//              trips; the largest cycle is recorded per round as maxPollCycleMs). The difference can
//              be off by about that much in either direction. Rounds with RPC retries are marked.
// Block timestamps are never subtracted across the two chains: their clocks are not aligned.

import { execFile } from 'node:child_process';
import { mkdirSync, writeFileSync, appendFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  SELECTORS,
  TOPICS,
  STATUS,
  encodeWord,
  word,
  int24,
  summarize,
  CSV_COLUMNS,
  csvLine,
  redact,
  isRateLimitError,
  isAfter,
  positiveInt,
  positiveBigInt,
  sweepPlan,
} from './lib.mjs';
import { measureRound } from './round.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const RESULTS_DIR = join(HERE, 'results');
const RPC_TIMEOUT_MS = 15_000;
const RPC_RETRIES = 4;
const CAST_TIMEOUT_MS = 120_000;
const BLOCK_LOOKUPS = 15;
const BLOCK_LOOKUP_MS = 400;
const SYSTEM_CONTRACT = '0x8888888888888888888888888888888888888888';
const CALLBACK_PROXY = '0x775c9b990ade401060b78d0e98684eef8d2466c1';
/** Estimated lREACT spent by the reactive contract per round (four reactive transactions). */
const LREACT_PER_ROUND = 80_000_000_000_000_000n; // 0.08

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const now = () => Date.now();
const hex = (n) => '0x' + BigInt(n).toString(16);
const fmtEther = (wei) => (Number(wei) / 1e18).toFixed(4);

// ------------------------------------------------------------------- config

function env(name, fallback) {
  const v = process.env[name];
  if (v === undefined || v === '') {
    if (fallback !== undefined) return fallback;
    throw new Error(`missing environment variable ${name} (see the README's deployment section)`);
  }
  return v;
}

function loadConfig({ needSigner }) {
  const cfg = {
    originRpc: env('ORIGIN_RPC'),
    reactiveRpc: env('REACTIVE_RPC'),
    vault: env('ORDER_VAULT_ADDR').toLowerCase(),
    reactive: env('OCO_REACTIVE_ADDR').toLowerCase(),
    swapper: env('SWAPPER_ADDR').toLowerCase(),
    token0: env('TOKEN0_ADDR').toLowerCase(),
    token1: env('TOKEN1_ADDR').toLowerCase(),
    // 10 token0 plus 7 wei. The odd amount marks the tool's own orders, so the clean-up before a run
    // cancels only those and never an order placed by hand.
    orderAmount: positiveBigInt('LATENCY_ORDER_AMOUNT_WEI', env('LATENCY_ORDER_AMOUNT_WEI', '10000000000000000007')),
    pushAmount: positiveBigInt('LATENCY_PUSH_AMOUNT_WEI', env('LATENCY_PUSH_AMOUNT_WEI', '600000000000000000000')), // 600 tokens
    offset: positiveInt('LATENCY_LEVEL_OFFSET', env('LATENCY_LEVEL_OFFSET', '60'), 1000),
    roundTimeoutMs: positiveInt('LATENCY_ROUND_TIMEOUT_S', env('LATENCY_ROUND_TIMEOUT_S', '90'), 600) * 1000,
    pollMs: positiveInt('LATENCY_POLL_MS', env('LATENCY_POLL_MS', '200'), 5000),
  };
  if (needSigner) {
    cfg.keystore = env('OCO_KEYSTORE', join(homedir(), '.foundry', 'keystores', 'deployer'));
    cfg.password = env('OCO_KEYSTORE_PASSWORD');
  }
  return cfg;
}

// --------------------------------------------------------------------- RPC

class RpcError extends Error {}
let rpcRetryCount = 0;

/**
 * JSON-RPC call with a timeout. Network errors, HTTP 429/5xx and JSON-RPC rate-limit errors are
 * retried with exponential backoff; other JSON-RPC errors are final.
 */
async function rpc(url, method, params) {
  const host = new URL(url).host;
  let lastError;
  for (let attempt = 0; attempt <= RPC_RETRIES; attempt++) {
    if (attempt > 0) {
      rpcRetryCount++;
      await sleep(500 * 2 ** (attempt - 1));
    }
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        signal: AbortSignal.timeout(RPC_TIMEOUT_MS),
      });
      if (res.status === 429 || res.status >= 500) throw new Error(`HTTP ${res.status}`);
      const body = await res.json();
      if (body.error) {
        if (isRateLimitError(body.error)) throw new Error(`rate limited: ${body.error.message}`);
        throw new RpcError(`${method} on ${host}: ${body.error.message ?? JSON.stringify(body.error)}`);
      }
      return body.result;
    } catch (e) {
      if (e instanceof RpcError) throw e;
      lastError = e;
    }
  }
  throw new Error(`${method} on ${host} failed after ${RPC_RETRIES + 1} attempts: ${lastError?.message}`);
}

function makeChainIo(cfg) {
  const url = (chain) => (chain === 'reactive' ? cfg.reactiveRpc : cfg.originRpc);
  const call = (chain, to, data) => rpc(url(chain), 'eth_call', [{ to, data }, 'latest']);
  return {
    url,
    call,
    blockNumber: async (chain) => Number(BigInt(await rpc(url(chain), 'eth_blockNumber', []))),
    // A block number just reported by one node can be missing on the next node behind the same
    // load-balanced URL for a moment, so "not found" is retried briefly (and counted as a retry).
    blockTimestamp: async (chain, n) => {
      for (let attempt = 0; attempt < BLOCK_LOOKUPS; attempt++) {
        if (attempt > 0) {
          rpcRetryCount++;
          await sleep(BLOCK_LOOKUP_MS);
        }
        const b = await rpc(url(chain), 'eth_getBlockByNumber', [hex(n), false]);
        if (b) return Number(BigInt(b.timestamp));
      }
      throw new Error(`block ${n} not found on ${chain} after ${BLOCK_LOOKUPS} lookups`);
    },
    /** Block timestamp, or null when the node does not serve that block (pruned history). */
    blockTimestampOrNull: async (chain, n) => {
      const b = await rpc(url(chain), 'eth_getBlockByNumber', [hex(n), false]).catch((e) => {
        if (e instanceof RpcError && /not found/i.test(e.message)) return null;
        throw e;
      });
      return b ? Number(BigInt(b.timestamp)) : null;
    },
    getLogs: (chain, filter) => rpc(url(chain), 'eth_getLogs', [filter]),
    balance: async (chain, addr) => BigInt(await rpc(url(chain), 'eth_getBalance', [addr, 'latest'])),
    normalizedTick: async () => int24(word(await call('origin', cfg.vault, SELECTORS.normalizedTick + encodeWord(true)), 0)),
    getOrderWords: async (id) => call('origin', cfg.vault, SELECTORS.getOrder + encodeWord(id)),
    orderStatus: async (id) => Number(word(await call('origin', cfg.vault, SELECTORS.getOrder + encodeWord(id)), 2)),
    isTracked: async (id) => word(await call('reactive', cfg.reactive, SELECTORS.getTracked + encodeWord(id)), 0) === 1n,
  };
}

// -------------------------------------------------------------------- cast

/** Runs cast with the keystore password; errors never contain the password. */
function castWithKeystore(cfg, args, what) {
  const argv = [...args, '--keystore', cfg.keystore, '--password', cfg.password];
  return new Promise((resolve, reject) => {
    execFile('cast', argv, { timeout: CAST_TIMEOUT_MS, maxBuffer: 10 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) {
        const detail = String(stderr || err.message).trim().split('\n').slice(0, 3).join(' | ');
        return reject(new Error(`${what} failed: ${redact(detail, cfg.password)}`));
      }
      resolve(stdout.trim());
    });
  });
}

/** Broadcasts a transaction and returns its hash without waiting for the receipt. */
async function sendAsync(cfg, to, sig, args) {
  const out = await castWithKeystore(cfg, ['send', to, sig, ...args, '--rpc-url', cfg.originRpc, '--async'], `cast send ${sig}`);
  const m = out.match(/0x[0-9a-fA-F]{64}/);
  if (!m) throw new Error(`cast send ${sig}: no transaction hash in output`);
  return m[0];
}

async function signerAddress(cfg) {
  const out = await castWithKeystore(cfg, ['wallet', 'address'], 'opening the keystore');
  const m = out.match(/0x[0-9a-fA-F]{40}/);
  if (!m) throw new Error('could not read the signer address from the keystore');
  return m[0].toLowerCase();
}

function makeRoundIo(cfg, chain, stopFlag) {
  return {
    now,
    sleep,
    stopRequested: () => stopFlag.stop,
    rpcRetries: () => rpcRetryCount,
    pendingNonce: async (owner) => Number(BigInt(await rpc(cfg.originRpc, 'eth_getTransactionCount', [owner, 'pending']))),
    normalizedTick: chain.normalizedTick,
    orderStatus: chain.orderStatus,
    isTracked: chain.isTracked,
    blockNumber: chain.blockNumber,
    blockTimestamp: chain.blockTimestamp,
    getLogs: chain.getLogs,
    send: (to, sig, args) => sendAsync(cfg, to, sig, args),
    waitForReceipt: async (txHash, timeoutMs) => {
      const deadline = now() + timeoutMs;
      while (now() < deadline) {
        const r = await rpc(cfg.originRpc, 'eth_getTransactionReceipt', [txHash]);
        if (r) return { receipt: r, seenAt: now() };
        await sleep(cfg.pollMs);
      }
      throw new Error(`no receipt for ${txHash} within ${timeoutMs / 1000} s`);
    },
  };
}

// -------------------------------------------------------- pre-flight checks

async function erc20(chain, token, selector, ...addrs) {
  return word(await chain.call('origin', token, selector + addrs.map(encodeWord).join('')), 0);
}

/** Refuses to start a run that would run out of funds part way through. */
async function preflight(cfg, chain, owner, rounds) {
  const problems = [];
  const reactiveBal = await chain.balance('reactive', cfg.reactive);
  const reactiveDebt = word(await chain.call('reactive', SYSTEM_CONTRACT, SELECTORS.debt + encodeWord(cfg.reactive)), 0);
  const needLReact = LREACT_PER_ROUND * BigInt(rounds);
  if (reactiveDebt > 0n) problems.push(`the reactive contract owes ${fmtEther(reactiveDebt)} lREACT and receives nothing until it is paid`);
  if (reactiveBal < needLReact) {
    problems.push(
      `the reactive contract holds ${fmtEther(reactiveBal)} lREACT; ${rounds} rounds need about ${fmtEther(needLReact)}. ` +
        `Top it up with: cast send $OCO_REACTIVE_ADDR --value ${fmtEther(needLReact - reactiveBal + 10n ** 17n)}ether --rpc-url $REACTIVE_RPC --chain 5318007 --account deployer`
    );
  }
  const vaultBal = await chain.balance('origin', cfg.vault);
  const vaultDebt = word(await chain.call('origin', CALLBACK_PROXY, SELECTORS.debt + encodeWord(cfg.vault)), 0);
  if (vaultDebt > 0n) problems.push(`the vault owes the callback proxy ${fmtEther(vaultDebt)} ETH`);
  if (vaultBal < 10n ** 15n) problems.push(`the vault holds ${fmtEther(vaultBal)} ETH for callback fees; add some`);
  const ownerEth = await chain.balance('origin', owner);
  if (ownerEth < 5n * 10n ** 14n) problems.push(`the signer holds ${fmtEther(ownerEth)} ETH on Unichain Sepolia; it needs a little for gas`);
  const t0 = await erc20(chain, cfg.token0, SELECTORS.balanceOf, owner);
  const t1 = await erc20(chain, cfg.token1, SELECTORS.balanceOf, owner);
  const n = BigInt(rounds);
  if (t0 < n * (cfg.orderAmount + cfg.pushAmount)) problems.push('the signer does not hold enough token0 for every round');
  if (t1 < n * cfg.pushAmount) problems.push('the signer does not hold enough token1 for every round');
  console.log(
    `funds: reactive ${fmtEther(reactiveBal)} lREACT, vault ${fmtEther(vaultBal)} ETH, signer ${fmtEther(ownerEth)} ETH, ` +
      `token0 ${fmtEther(t0)}, token1 ${fmtEther(t1)}`
  );
  if (problems.length) throw new Error('not starting:\n  - ' + problems.join('\n  - '));
}

/**
 * Cancels active orders an earlier run of this tool left behind (recognised by the marker order
 * amount; orders placed by hand are kept), and refuses to start if the kept ones leave no room for
 * the round's own order.
 */
async function sweepOldOrders(cfg, chain, io, owner) {
  const active = word(await chain.call('origin', cfg.vault, SELECTORS.activeOrdersOf + encodeWord(owner)), 0);
  if (active === 0n) return;
  const next = Number(word(await chain.call('origin', cfg.vault, SELECTORS.nextOrderId), 0));
  const orders = [];
  let found = 0;
  for (let id = next - 1; id >= Math.max(0, next - 200) && found < Number(active); id--) {
    const w = await chain.getOrderWords(id);
    const o = {
      id,
      owner: '0x' + word(w, 0).toString(16).padStart(40, '0'),
      status: Number(word(w, 2)),
      amountIn: word(w, 11),
    };
    if (o.owner === owner && o.status === STATUS.Active) found++;
    orders.push(o);
  }
  const { cancel, kept } = sweepPlan(orders, owner, cfg.orderAmount, active);
  console.log(`the signer has ${active} active order(s): ${cancel.length} left by this tool, ${kept} kept`);
  for (const id of cancel) {
    const tx = await io.send(cfg.vault, 'cancelOrder(uint256)', [String(id)]);
    const { receipt } = await io.waitForReceipt(tx, cfg.roundTimeoutMs);
    if (receipt.status !== '0x1') throw new Error(`cancelling old order ${id} reverted (${tx})`);
    console.log(`  cancelled order ${id}`);
  }
}

async function ensureApprovals(cfg, chain, io, owner) {
  const MAX = (1n << 256n) - 1n;
  for (const [token, spender] of [
    [cfg.token0, cfg.vault],
    [cfg.token0, cfg.swapper],
    [cfg.token1, cfg.swapper],
  ]) {
    if ((await erc20(chain, token, SELECTORS.allowance, owner, spender)) >= MAX / 2n) continue;
    console.log(`approving ${spender} to spend ${token}`);
    const tx = await io.send(token, 'approve(address,uint256)', [spender, MAX.toString()]);
    const { receipt } = await io.waitForReceipt(tx, cfg.roundTimeoutMs);
    if (receipt.status !== '0x1') throw new Error(`approve reverted (${tx})`);
  }
}

// ------------------------------------------------------------------ output

function stamp() {
  return new Date().toISOString().replace(/[:.]/g, '-');
}

function summaryMarkdown(records, title) {
  const ok = records.filter((r) => r.outcome === 'executed');
  const clean = ok.filter((r) => !r.rpcRetries);
  const others = records
    .filter((r) => r.outcome !== 'executed')
    .reduce((m, r) => ((m[r.outcome] = (m[r.outcome] || 0) + 1), m), {});
  const fmt = (s, unit) =>
    s.count ? `${s.count} | ${s.min}${unit} | ${s.p50}${unit} | ${s.p95}${unit} | ${s.max}${unit} | ${s.mean}${unit}` : '0 | | | | |';
  return [
    `# ${title}`,
    '',
    `Rounds: ${records.length}, executed: ${ok.length}` +
      (Object.keys(others).length ? `, other outcomes: ${Object.entries(others).map(([k, v]) => `${k} ${v}`).join(', ')}` : '') +
      (records.some((r) => r.leftActive) ? '. **Some orders may still be active; see the CSV notes.**' : ''),
    '',
    'Percentiles are nearest-rank over executed rounds. Observed times exclude rounds with RPC retries.',
    '',
    '| Measure | n | min | p50 | p95 | max | mean |',
    '|---|---|---|---|---|---|---|',
    `| Swap block to callback block, blocks (Unichain Sepolia) | ${fmt(summarize(ok.map((r) => r.chainBlocks)), '')} |`,
    `| Swap block to callback block, seconds (same chain's clock) | ${fmt(summarize(ok.map((r) => r.chainSeconds)), ' s')} |`,
    `| Observed: swap mined to reactive tx seen on Lasna, ms | ${fmt(summarize(clean.map((r) => r.obsMsSwapToReactive)), ' ms')} |`,
    `| Observed: swap mined to callback seen, ms | ${fmt(summarize(clean.map((r) => r.obsMsSwapToCallback)), ' ms')} |`,
    `| Observed: order mined to tracked on Lasna, ms | ${fmt(summarize(clean.map((r) => r.obsMsOrderToTracked)), ' ms')} |`,
    `| Largest poll cycle in the round (resolution of observed times), ms | ${fmt(summarize(clean.map((r) => r.maxPollCycleMs)), ' ms')} |`,
    '',
  ].join('\n');
}

// --------------------------------------------------------------------- run

async function cmdRun(rounds) {
  const cfg = loadConfig({ needSigner: true });
  const chain = makeChainIo(cfg);
  const stopFlag = { stop: false };
  const io = makeRoundIo(cfg, chain, stopFlag);

  const owner = await signerAddress(cfg);
  console.log(`signer ${owner}, ${rounds} rounds, poll every ${cfg.pollMs} ms`);
  await preflight(cfg, chain, owner, rounds);
  await sweepOldOrders(cfg, chain, io, owner);
  await ensureApprovals(cfg, chain, io, owner);

  // First Ctrl-C: finish cleaning up the current round, then stop. Second Ctrl-C: quit now.
  process.on('SIGINT', () => {
    if (stopFlag.stop) {
      console.error('\nquitting without cleanup; an order may still be active (the next run cancels it)');
      process.exit(130);
    }
    stopFlag.stop = true;
    console.error('\nstopping after cleaning up the current round (Ctrl-C again to quit now)');
  });

  const center = await chain.normalizedTick();
  mkdirSync(RESULTS_DIR, { recursive: true });
  const base = join(RESULTS_DIR, `run-${stamp()}`);
  writeFileSync(base + '.csv', CSV_COLUMNS.join(',') + '\n');
  console.log(`starting tick ${center}; writing ${base}.csv`);

  const records = [];
  for (let i = 0; i < rounds && !stopFlag.stop; i++) {
    const rec = await measureRound(io, cfg, owner, i, center, (s) => redact(s, cfg.password));
    records.push(rec);
    appendFileSync(base + '.csv', csvLine(rec) + '\n');
    console.log(
      `round ${rec.round} (${rec.kind ?? '?'}): ${rec.outcome}` +
        (rec.outcome === 'executed' ? `, ${rec.chainBlocks} blocks / ${rec.chainSeconds} s on chain, ${rec.obsMsSwapToCallback} ms observed` : '') +
        (rec.note ? ` (${rec.note})` : '')
    );
    if (rec.leftActive) {
      console.error('an order could not be cleaned up; stopping so it does not block later rounds');
      break;
    }
    if (!stopFlag.stop) await sleep(3000);
  }
  writeFileSync(base + '.md', summaryMarkdown(records, `Latency run, ${new Date().toISOString()}`));
  console.log(`\nwrote ${base}.csv and ${base}.md\n`);
  console.log(summaryMarkdown(records, 'Summary'));
}

// ------------------------------------------------------------------ replay

/** Finds the first block at or after timestamp `ts`; blocks the node no longer serves count as earlier. */
async function blockAtOrAfter(chain, name, ts) {
  let lo = 0;
  let hi = await chain.blockNumber(name);
  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2);
    const t = await chain.blockTimestampOrNull(name, mid);
    if (t === null || t < ts) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

/**
 * Each argument is a swap transaction, optionally `tx:orderId`. Without an order id the first
 * callback (any order) after the swap's own log is used.
 */
async function cmdReplay(args) {
  const cfg = loadConfig({ needSigner: false });
  const chain = makeChainIo(cfg);
  const records = [];
  for (const [i, arg] of args.entries()) {
    const [tx, wantId] = arg.split(':');
    const rec = { round: i + 1, swapTx: tx, note: 'replay' };
    try {
      const r = await rpc(cfg.originRpc, 'eth_getTransactionReceipt', [tx]);
      if (!r) throw new Error('swap transaction not found');
      rec.swapBlock = Number(BigInt(r.blockNumber));
      rec.swapBlockTs = await chain.blockTimestamp('origin', rec.swapBlock);
      const swapLog = r.logs.find((l) => l.topics[0] === TOPICS.swap);
      if (!swapLog) throw new Error('no Swap event in that transaction');
      rec.tickAfterSwap = int24(word(swapLog.data, 4));
      const swapLogIndex = Number(BigInt(swapLog.logIndex));

      const topics = [[TOPICS.orderExecuted, TOPICS.orderExecutionFailed]];
      if (wantId !== undefined) topics.push('0x' + encodeWord(wantId));
      const exec = (
        await chain.getLogs('origin', { address: cfg.vault, fromBlock: hex(rec.swapBlock), toBlock: hex(rec.swapBlock + 60), topics })
      ).filter((l) => isAfter(l, rec.swapBlock, swapLogIndex));
      if (!exec.length) throw new Error('no vault execution within 60 blocks after the swap');
      const cb = exec[0];
      rec.orderId = BigInt(cb.topics[1]).toString();
      rec.callbackTx = cb.transactionHash;
      rec.callbackBlock = Number(BigInt(cb.blockNumber));
      rec.callbackBlockTs = await chain.blockTimestamp('origin', rec.callbackBlock);
      rec.chainBlocks = rec.callbackBlock - rec.swapBlock;
      rec.chainSeconds = rec.callbackBlockTs - rec.swapBlockTs;
      rec.outcome = cb.topics[0] === TOPICS.orderExecuted ? 'executed' : 'execution-failed';

      const lasnaStart = await blockAtOrAfter(chain, 'reactive', rec.swapBlockTs - 30);
      const trig = await chain.getLogs('reactive', {
        address: cfg.reactive, fromBlock: hex(lasnaStart), toBlock: hex(lasnaStart + 120), topics: [TOPICS.triggered, '0x' + encodeWord(rec.orderId)],
      });
      if (trig.length) {
        rec.reactiveTx = trig[0].transactionHash;
        rec.reactiveBlock = Number(BigInt(trig[0].blockNumber));
        rec.reactiveBlockTs = await chain.blockTimestamp('reactive', rec.reactiveBlock);
      }
    } catch (e) {
      rec.outcome = 'error';
      rec.note = e.message;
    }
    records.push(rec);
  }
  console.log(CSV_COLUMNS.join(','));
  for (const r of records) console.log(csvLine(r));
  console.log('\n' + summaryMarkdown(records, 'Replay summary (no observed times in replay)'));
}

// -------------------------------------------------------------------- main

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  if (cmd === 'run') return cmdRun(positiveInt('rounds', rest[0] ?? '30', 200));
  if (cmd === 'replay' && rest.length) return cmdReplay(rest);
  console.error('usage: node tools/latency/latency.mjs run [rounds] | replay <swapTx[:orderId]>...');
  process.exit(2);
}

main().catch((e) => {
  console.error('ERROR ' + redact(e.message, process.env.OCO_KEYSTORE_PASSWORD));
  process.exit(1);
});
