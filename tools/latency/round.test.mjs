// Failure-path tests for one measurement round, with the network replaced by a scripted stub.
// The point: whatever goes wrong after the order is placed, the order is cancelled and the record
// keeps the identifiers. Run: node --test tools/latency/round.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { measureRound } from './round.mjs';
import { TOPICS, STATUS, encodeWord } from './lib.mjs';

const VAULT = '0x6a8932797f1fb9d164f6e075cb4f525feb824184';
const cfg = {
  vault: VAULT,
  reactive: '0xc358ffaa2bcc6be005ab4063fb7dfcc2ef4f56fe',
  swapper: '0x715666dc26bb46dbada0112e0c9e6f7db945edaa',
  token0: '0x0a75150631c8e1ad3fcb48d8b0478b1dc685cd2b',
  token1: '0x354fc758ac107d77ff53d3e0b0b2bae1c55d58ec',
  orderAmount: 10n,
  pushAmount: 600n,
  offset: 60,
  roundTimeoutMs: 1_000,
  pollMs: 1,
};
const OWNER = '0x9ca5ff17496ba8101438a4c5fa3851f3b2879635';
const ORDER_ID = 42n;

const receipt = (hash, logs = [], status = '0x1', block = 100) => ({
  transactionHash: hash,
  status,
  blockNumber: '0x' + block.toString(16),
  logs,
});
const createdLog = {
  address: VAULT,
  topics: [TOPICS.orderCreated, '0x' + encodeWord(ORDER_ID), '0x' + encodeWord(OWNER)],
  data: '0x',
};
// Swap log whose tick (word 4) is -120: below a stop at -60.
const swapLog = {
  address: '0x00b036b58a818b1bc34d502d3fe730db729e62ac',
  topics: [TOPICS.swap],
  data: '0x' + [0n, 0n, 0n, 0n].map(encodeWord).join('') + 'f'.repeat(58) + 'ff88' + encodeWord(3000n),
};

/**
 * A stub of the round's I/O. `failAt` names the step that throws. Records every transaction sent
 * so a test can check that a cancel went out.
 */
function stubIo({ failAt, status = STATUS.Active, tracked = true } = {}) {
  let clock = 1_000_000;
  const sent = [];
  let orderStatus = status;
  const io = {
    sent,
    now: () => clock,
    sleep: async (ms) => {
      clock += ms;
    },
    stopRequested: () => false,
    rpcRetries: () => 0,
    nonce: 5,
    pendingNonce: async () => {
      if (failAt === 'nonceAfter' && sent.length) throw new Error('rpc down');
      return io.nonce;
    },
    normalizedTick: async () => 0, // round 0 at tick 0 is a stop at -60
    orderStatus: async () => {
      if (failAt === 'orderStatus') throw new Error('rpc down');
      return orderStatus;
    },
    isTracked: async () => {
      if (failAt === 'isTracked') throw new Error('lasna rpc failed after retries');
      return tracked;
    },
    blockNumber: async () => 100,
    blockTimestamp: async () => 1_800_000_000,
    getLogs: async () => {
      if (failAt === 'getLogs') throw new Error('getLogs failed');
      return [];
    },
    send: async (to, sig) => {
      sent.push(sig);
      if (sig.startsWith('createOrder')) {
        if (failAt === 'createSentThenKilled') {
          io.nonce++; // broadcast went out, then cast died before printing the hash
          throw new Error('cast send createOrder failed: killed');
        }
        if (failAt === 'createNotSent' || failAt === 'nonceAfter') throw new Error('cast send createOrder failed: killed');
        return '0xcreate';
      }
      if (sig.startsWith('swapExactIn')) {
        if (failAt === 'swapSend') throw new Error('cast send swapExactIn failed: nonce too low');
        return '0xswap';
      }
      if (sig.startsWith('cancelOrder')) {
        if (failAt === 'cancelSend') throw new Error('cancel failed');
        orderStatus = STATUS.Cancelled;
        return '0xcancel';
      }
      throw new Error('unexpected send ' + sig);
    },
    waitForReceipt: async (hash) => {
      if (hash === '0xcreate') {
        if (failAt === 'createReceipt') {
          failAt = 'createReceiptOnce'; // the first wait fails, the retry finds it
          throw new Error('no receipt for 0xcreate within 90 s');
        }
        return { receipt: receipt(hash, [createdLog]), seenAt: clock };
      }
      if (hash === '0xswap') {
        if (failAt === 'swapReceipt') throw new Error('no receipt for 0xswap within 90 s');
        return { receipt: receipt(hash, [swapLog]), seenAt: clock };
      }
      if (hash === '0xcancel') return { receipt: receipt(hash), seenAt: clock };
      throw new Error('unexpected receipt ' + hash);
    },
  };
  return io;
}

const cancels = (io) => io.sent.filter((s) => s.startsWith('cancelOrder')).length;

test('reactive RPC failing after the order exists: order cancelled, id kept', async () => {
  const io = stubIo({ failAt: 'isTracked' });
  const rec = await measureRound(io, cfg, OWNER, 0, 0);
  assert.equal(rec.outcome, 'error');
  assert.equal(rec.orderId, '42');
  assert.equal(rec.createTx, '0xcreate');
  assert.equal(cancels(io), 1);
  assert.match(rec.note, /lasna rpc failed/);
  assert.match(rec.note, /order cancelled/);
});

test('swap send failing: order cancelled', async () => {
  const io = stubIo({ failAt: 'swapSend' });
  const rec = await measureRound(io, cfg, OWNER, 0, 0);
  assert.equal(rec.outcome, 'error');
  assert.equal(rec.orderId, '42');
  assert.equal(cancels(io), 1);
});

test('swap receipt never seen: order cancelled and the swap hash kept', async () => {
  const io = stubIo({ failAt: 'swapReceipt' });
  const rec = await measureRound(io, cfg, OWNER, 0, 0);
  assert.equal(rec.outcome, 'error');
  assert.equal(rec.swapTx, '0xswap');
  assert.equal(cancels(io), 1);
});

test('log polling failing during the loop: order cancelled', async () => {
  const io = stubIo({ failAt: 'getLogs' });
  const rec = await measureRound(io, cfg, OWNER, 0, 0);
  assert.equal(rec.outcome, 'error');
  assert.equal(rec.swapTx, '0xswap');
  assert.equal(cancels(io), 1);
});

test('order receipt slow the first time: the id is recovered and the order cancelled', async () => {
  const io = stubIo({ failAt: 'createReceipt' });
  const rec = await measureRound(io, cfg, OWNER, 0, 0);
  assert.equal(rec.outcome, 'error');
  assert.equal(rec.orderId, '42');
  assert.equal(cancels(io), 1);
});

test('never tracked: order cancelled', async () => {
  const io = stubIo({ tracked: false });
  const rec = await measureRound(io, cfg, OWNER, 0, 0);
  assert.equal(rec.outcome, 'not-tracked');
  assert.equal(cancels(io), 1);
});

test('loop times out: order cancelled, outcome timeout', async () => {
  const io = stubIo();
  const rec = await measureRound(io, cfg, OWNER, 0, 0);
  assert.equal(rec.outcome, 'timeout');
  assert.equal(cancels(io), 1);
});

test('order already sold when the cancel is attempted: reported as executed-late, not as a failure', async () => {
  const io = stubIo({ failAt: 'cancelSend' });
  // The cancel throws; the re-read then finds the order executed.
  const original = io.orderStatus;
  let reads = 0;
  io.orderStatus = async (id) => (++reads === 1 ? STATUS.Active : STATUS.Executed);
  const rec = await measureRound(io, cfg, OWNER, 0, 0);
  assert.equal(rec.outcome, 'executed-late');
  assert.equal(rec.leftActive, undefined);
  io.orderStatus = original;
});

test('cancel failing while the order is still active: flagged so the run stops', async () => {
  const io = stubIo({ failAt: 'cancelSend' });
  const rec = await measureRound(io, cfg, OWNER, 0, 0);
  assert.equal(rec.leftActive, true);
  assert.match(rec.note, /cancel failed/);
});

test('cancel failing and the re-read failing too: unknown state is flagged so the run stops', async () => {
  const io = stubIo({ failAt: 'cancelSend' });
  let reads = 0;
  io.orderStatus = async () => {
    if (++reads === 1) return STATUS.Active;
    throw new Error('rpc down');
  };
  const rec = await measureRound(io, cfg, OWNER, 0, 0);
  assert.equal(rec.leftActive, true);
  assert.match(rec.note, /state unknown/);
});

test('every order-status read failing: unknown state is flagged so the run stops', async () => {
  const io = stubIo();
  io.orderStatus = async () => {
    throw new Error('rpc down');
  };
  const rec = await measureRound(io, cfg, OWNER, 0, 0);
  assert.equal(rec.leftActive, true);
  assert.equal(cancels(io), 0);
});

test('order send killed after broadcasting: flagged so the run stops', async () => {
  const io = stubIo({ failAt: 'createSentThenKilled' });
  const rec = await measureRound(io, cfg, OWNER, 0, 0);
  assert.equal(rec.outcome, 'error');
  assert.equal(rec.createTx, undefined);
  assert.equal(rec.leftActive, true);
  assert.match(rec.note, /may have been placed/);
});

test('order send failing before broadcasting: nothing left behind, run continues', async () => {
  const io = stubIo({ failAt: 'createNotSent' });
  const rec = await measureRound(io, cfg, OWNER, 0, 0);
  assert.equal(rec.outcome, 'error');
  assert.equal(rec.leftActive, undefined);
});

test('order send failing and the nonce unreadable: flagged so the run stops', async () => {
  const io = stubIo({ failAt: 'nonceAfter' });
  const rec = await measureRound(io, cfg, OWNER, 0, 0);
  assert.equal(rec.leftActive, true);
});

test('interrupt during the loop: order cancelled, outcome interrupted', async () => {
  const io = stubIo();
  let checks = 0;
  io.stopRequested = () => ++checks > 4; // let the order be placed and tracked first
  const rec = await measureRound(io, cfg, OWNER, 0, 0);
  assert.equal(rec.outcome, 'interrupted');
  assert.equal(rec.orderId, '42');
  assert.equal(cancels(io), 1);
});

test('a password in an error message is redacted in the record', async () => {
  const io = stubIo({ failAt: 'swapSend' });
  io.send = async (to, sig) => {
    io.sent.push(sig);
    if (sig.startsWith('createOrder')) return '0xcreate';
    if (sig.startsWith('cancelOrder')) return '0xcancel';
    throw new Error('cast failed with --password hunter2');
  };
  const rec = await measureRound(io, cfg, OWNER, 0, 0, (s) => s.split('hunter2').join('[redacted]'));
  assert.doesNotMatch(rec.note, /hunter2/);
});
