// One measurement round, written against an injected `io` object so its failure paths can be
// tested without a network (see round.test.mjs). latency.mjs supplies the real implementation.
//
// io must provide:
//   now(), sleep(ms), stopRequested() -> bool
//   normalizedTick() -> int, orderStatus(id) -> int, isTracked(id) -> bool
//   blockNumber(chain), blockTimestamp(chain, n), getLogs(chain, filter)        chain: 'origin'|'reactive'
//   send(to, sig, args) -> txHash (returns as soon as the transaction is broadcast)
//   waitForReceipt(txHash, timeoutMs) -> { receipt, seenAt }   (throws on timeout)
//   rpcRetries() -> number of RPC retries so far (for marking disturbed samples)
//   pendingNonce(owner) -> number (transaction count including pending ones)

import { TOPICS, STATUS, encodeWord, word, int24, planRound, crossed } from './lib.mjs';

const hex = (n) => '0x' + BigInt(n).toString(16);
/** How long to wait after a failed order send before checking whether it went out anyway. */
const CREATE_SETTLE_MS = 5_000;

export class Interrupted extends Error {
  constructor() {
    super('interrupted');
  }
}

function checkStop(io) {
  if (io.stopRequested()) throw new Interrupted();
}

function orderIdFromReceipt(cfg, receipt) {
  const log = receipt.logs.find((l) => l.address.toLowerCase() === cfg.vault && l.topics[0] === TOPICS.orderCreated);
  if (!log) throw new Error(`no OrderCreated in ${receipt.transactionHash}`);
  return BigInt(log.topics[1]);
}

function addNote(rec, text) {
  rec.note = [rec.note, text].filter(Boolean).join('; ');
}

/**
 * Cancels the round's order if it is still active. If the cancel fails because the order was
 * sold in the meantime, says so instead of reporting a failure.
 */
export async function cancelIfActive(io, cfg, rec) {
  if (rec.orderId === undefined) return;
  const id = BigInt(rec.orderId);
  try {
    if ((await io.orderStatus(id)) !== STATUS.Active) return;
    const tx = await io.send(cfg.vault, 'cancelOrder(uint256)', [id.toString()]);
    const { receipt } = await io.waitForReceipt(tx, cfg.roundTimeoutMs);
    if (receipt.status === '0x1') {
      addNote(rec, 'order cancelled');
      return;
    }
    throw new Error(`cancel ${tx} reverted`);
  } catch (e) {
    let status = null;
    try {
      status = await io.orderStatus(id);
    } catch (e2) {
      addNote(rec, 'could not re-read the order: ' + e2.message);
    }
    if (status === STATUS.Executed) {
      rec.outcome = 'executed-late';
      addNote(rec, 'sold after the round timed out');
    } else if (status === null) {
      // Unknown state: it may still be active, so treat it like one and stop the run.
      addNote(rec, 'order state unknown after a failed cancel: ' + e.message);
      rec.leftActive = true;
    } else if (status !== STATUS.Active) {
      addNote(rec, `order closed meanwhile (status ${status})`);
    } else {
      addNote(rec, 'cancel failed: ' + e.message);
      rec.leftActive = true;
    }
  }
}

/** Polls both chains until this order's trigger and callback are seen, or the deadline. */
async function watchLoop(io, cfg, id, unichainFrom, lasnaFrom, deadline, rec) {
  const idTopic = '0x' + encodeWord(id);
  const out = {};
  rec.maxPollCycleMs = 0;
  while (io.now() < deadline && !(out.reactive && out.callback)) {
    checkStop(io);
    const cycleStart = io.now();
    if (!out.reactive) {
      const logs = await io.getLogs('reactive', {
        address: cfg.reactive, fromBlock: hex(lasnaFrom), toBlock: 'latest', topics: [TOPICS.triggered, idTopic],
      });
      if (logs.length) out.reactive = { log: logs[0], seenAt: io.now() };
    }
    if (!out.callback) {
      const logs = await io.getLogs('origin', {
        address: cfg.vault, fromBlock: hex(unichainFrom), toBlock: 'latest',
        topics: [[TOPICS.orderExecuted, TOPICS.orderExecutionFailed], idTopic],
      });
      if (logs.length) out.callback = { log: logs[0], seenAt: io.now() };
    }
    rec.maxPollCycleMs = Math.max(rec.maxPollCycleMs, io.now() - cycleStart);
    if (!(out.reactive && out.callback)) await io.sleep(cfg.pollMs);
  }
  return out;
}

/**
 * The round's steps. Fills `rec` as it goes so that whatever happens, the caller still knows
 * the order id and transaction hashes. Throws on unexpected errors; `measureRound` handles them.
 */
async function roundSteps(io, cfg, owner, index, center, rec) {
  const retriesAtStart = io.rpcRetries();
  const tick = await io.normalizedTick();
  const plan = planRound(tick, index, cfg.offset, center);
  rec.kind = plan.kind;
  rec.level = plan.kind === 'stop' ? plan.stopTick : plan.takeProfitTick;

  // 1. Place the order, from our own receipt poll, and wait until the reactive contract tracks it.
  const unichainNow = await io.blockNumber('origin');
  const expiry = (await io.blockTimestamp('origin', unichainNow)) + 3600;
  const params = `(true,${cfg.orderAmount},${plan.stopTick !== 0},${plan.stopTick},${plan.takeProfitTick !== 0},${plan.takeProfitTick},0,0,500,${expiry})`;
  checkStop(io);
  const nonceBefore = await io.pendingNonce(owner);
  try {
    rec.createTx = await io.send(cfg.vault, 'createOrder((bool,uint128,bool,int24,bool,int24,uint24,uint128,uint16,uint64))', [params]);
  } catch (e) {
    // The send can fail after the transaction went out (for example Ctrl-C killing `cast`), leaving
    // an order whose hash we never got. A higher pending nonce means something was broadcast.
    await io.sleep(CREATE_SETTLE_MS);
    let nonceAfter = null;
    try {
      nonceAfter = await io.pendingNonce(owner);
    } catch (e2) {
      addNote(rec, 'could not re-read the nonce: ' + e2.message);
    }
    if (nonceAfter === null || nonceAfter > nonceBefore) {
      addNote(rec, 'the order may have been placed without a known hash; the next run cancels it');
      rec.leftActive = true;
    }
    throw e;
  }
  const { receipt: created, seenAt: orderSeenAt } = await io.waitForReceipt(rec.createTx, cfg.roundTimeoutMs);
  if (created.status !== '0x1') {
    rec.outcome = 'create-reverted';
    return;
  }
  rec.orderId = orderIdFromReceipt(cfg, created).toString();
  const id = BigInt(rec.orderId);

  const trackDeadline = io.now() + cfg.roundTimeoutMs;
  while (!(await io.isTracked(id))) {
    checkStop(io);
    if (io.now() > trackDeadline) {
      rec.outcome = 'not-tracked';
      addNote(rec, 'the reactive contract did not pick up the order in time');
      return;
    }
    await io.sleep(cfg.pollMs);
  }
  rec.obsMsOrderToTracked = io.now() - orderSeenAt;

  // 2. Push the price through the level and time the loop.
  checkStop(io);
  const lasnaFrom = await io.blockNumber('reactive');
  rec.swapTx = await io.send(
    cfg.swapper,
    'swapExactIn((address,address,uint24,int24,address),bool,uint256,uint256,address)',
    [`(${cfg.token0},${cfg.token1},3000,60,0x0000000000000000000000000000000000000000)`, String(plan.pushZeroForOne), cfg.pushAmount.toString(), '0', owner]
  );
  const { receipt: swapReceipt, seenAt: swapSeenAt } = await io.waitForReceipt(rec.swapTx, cfg.roundTimeoutMs);
  if (swapReceipt.status !== '0x1') {
    rec.outcome = 'swap-reverted';
    return;
  }
  rec.swapBlock = Number(BigInt(swapReceipt.blockNumber));
  rec.swapBlockTs = await io.blockTimestamp('origin', rec.swapBlock);
  const swapLog = swapReceipt.logs.find((l) => l.topics[0] === TOPICS.swap);
  rec.tickAfterSwap = swapLog ? int24(word(swapLog.data, 4)) : null;
  if (rec.tickAfterSwap !== null && !crossed(plan, rec.tickAfterSwap)) {
    rec.outcome = 'level-not-crossed';
    addNote(rec, 'push too small for the level; raise LATENCY_PUSH_AMOUNT_WEI');
    return;
  }

  const seen = await watchLoop(io, cfg, id, rec.swapBlock, lasnaFrom, io.now() + cfg.roundTimeoutMs, rec);
  if (seen.reactive) {
    rec.reactiveTx = seen.reactive.log.transactionHash;
    rec.reactiveBlock = Number(BigInt(seen.reactive.log.blockNumber));
    rec.reactiveBlockTs = await io.blockTimestamp('reactive', rec.reactiveBlock);
    rec.obsMsSwapToReactive = seen.reactive.seenAt - swapSeenAt;
  }
  if (seen.callback) {
    rec.callbackTx = seen.callback.log.transactionHash;
    rec.callbackBlock = Number(BigInt(seen.callback.log.blockNumber));
    rec.callbackBlockTs = await io.blockTimestamp('origin', rec.callbackBlock);
    rec.chainBlocks = rec.callbackBlock - rec.swapBlock;
    rec.chainSeconds = rec.callbackBlockTs - rec.swapBlockTs;
    rec.obsMsSwapToCallback = seen.callback.seenAt - swapSeenAt;
    rec.outcome = seen.callback.log.topics[0] === TOPICS.orderExecuted ? 'executed' : 'execution-failed';
  } else {
    rec.outcome = 'timeout';
  }
  rec.rpcRetries = io.rpcRetries() - retriesAtStart;
  if (rec.rpcRetries > 0) addNote(rec, 'RPC retries during the round; observed times include backoff');
}

/**
 * Runs one round and never leaves its order behind: whatever happens after the order is placed,
 * including an error or an interrupt, an order that is still active is cancelled. The record
 * keeps every identifier it got to.
 */
export async function measureRound(io, cfg, owner, index, center, redact = (s) => s) {
  const rec = { round: index + 1 };
  try {
    await roundSteps(io, cfg, owner, index, center, rec);
  } catch (e) {
    rec.outcome = e instanceof Interrupted ? 'interrupted' : 'error';
    addNote(rec, redact(e.message));
    // The order may exist even though the receipt was never seen: look for it once more.
    if (rec.orderId === undefined && rec.createTx) {
      try {
        const { receipt } = await io.waitForReceipt(rec.createTx, cfg.roundTimeoutMs);
        if (receipt.status === '0x1') rec.orderId = orderIdFromReceipt(cfg, receipt).toString();
      } catch (e2) {
        addNote(rec, 'order creation unresolved: ' + redact(e2.message));
        rec.leftActive = true;
      }
    }
  } finally {
    if (rec.outcome !== 'executed') await cancelIfActive(io, cfg, rec);
  }
  return rec;
}
