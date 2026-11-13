// Unit tests for the latency tool's pure helpers. Run: node --test tools/latency/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';

import {
  SELECTORS,
  TOPICS,
  encodeWord,
  word,
  int24,
  planRound,
  crossed,
  percentile,
  summarize,
  CSV_COLUMNS,
  csvLine,
  redact,
  isRateLimitError,
  isAfter,
  positiveInt,
  positiveBigInt,
  sweepPlan,
  STATUS,
} from './lib.mjs';

function cast(args) {
  return execFileSync('cast', args, { encoding: 'utf8' }).trim();
}

test('selectors match cast sig', () => {
  assert.equal(SELECTORS.normalizedTick, cast(['sig', 'normalizedTick(bool)']));
  assert.equal(SELECTORS.getOrder, cast(['sig', 'getOrder(uint256)']));
  assert.equal(SELECTORS.getTracked, cast(['sig', 'getTracked(uint256)']));
  assert.equal(SELECTORS.debt, cast(['sig', 'debt(address)']));
  assert.equal(SELECTORS.activeOrdersOf, cast(['sig', 'activeOrdersOf(address)']));
  assert.equal(SELECTORS.nextOrderId, cast(['sig', 'nextOrderId()']));
  assert.equal(SELECTORS.allowance, cast(['sig', 'allowance(address,address)']));
  assert.equal(SELECTORS.balanceOf, cast(['sig', 'balanceOf(address)']));
});

test('event topics match cast keccak', () => {
  assert.equal(TOPICS.orderCreated, cast(['keccak', 'OrderCreated(uint256,address,bool,uint128,bool,int24,bool,int24,uint24,uint64,int24)']));
  assert.equal(TOPICS.orderExecuted, cast(['keccak', 'OrderExecuted(uint256,uint8,uint256,int24,uint256)']));
  assert.equal(TOPICS.orderExecutionFailed, cast(['keccak', 'OrderExecutionFailed(uint256,uint8,bytes)']));
  assert.equal(TOPICS.triggered, cast(['keccak', 'Triggered(uint256,uint8,int24,int24)']));
  assert.equal(TOPICS.swap, cast(['keccak', 'Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)']));
});

test('encodeWord and word round-trip, bools and addresses', () => {
  assert.equal(encodeWord(true), '0'.repeat(63) + '1');
  assert.equal(encodeWord(false), '0'.repeat(64));
  assert.equal(encodeWord('0x9CA5FF17496Ba8101438A4C5fA3851F3B2879635').slice(24), '9ca5ff17496ba8101438a4c5fa3851f3b2879635');
  assert.equal(word('0x' + encodeWord(7n) + encodeWord(9n), 1), 9n);
  assert.throws(() => encodeWord(-1n));
  assert.throws(() => word('0x1234', 0));
});

test('int24 decodes negative ticks from sign-extended words', () => {
  // A real Swap log word for tick -395 (sign-extended to 256 bits).
  assert.equal(int24(BigInt('0x' + 'f'.repeat(58) + 'fe75')), -395);
  assert.equal(int24(120n), 120);
  assert.equal(int24(0n), 0);
  assert.equal(int24(0x800000n), -8388608);
  assert.equal(int24(0x7fffffn), 8388607);
});

test('planRound alternates near the start and pulls the price back outside the band', () => {
  assert.deepEqual(planRound(0, 0, 60), { kind: 'stop', stopTick: -60, takeProfitTick: 0, pushZeroForOne: true });
  assert.deepEqual(planRound(0, 1, 60), { kind: 'takeProfit', stopTick: 0, takeProfitTick: 60, pushZeroForOne: false });
  // Far below: always take-profit (push up), whatever the round number.
  assert.equal(planRound(-611, 0, 60).kind, 'takeProfit');
  assert.equal(planRound(-611, 0, 60).takeProfitTick, -551);
  // Far above: always stop (push down).
  assert.equal(planRound(400, 1, 60).kind, 'stop');
  assert.equal(planRound(400, 1, 60).stopTick, 340);
  assert.throws(() => planRound(0.5, 0, 60));
  assert.throws(() => planRound(0, 0, 0));
});

test('planRound keeps the price near the starting tick, not near tick 0', () => {
  // A run that starts at -610 alternates around -610 instead of pushing up toward 0 every round.
  assert.equal(planRound(-610, 0, 60, -610).kind, 'stop');
  assert.equal(planRound(-610, 1, 60, -610).kind, 'takeProfit');
  assert.equal(planRound(-950, 0, 60, -610).kind, 'takeProfit');
  assert.equal(planRound(-250, 1, 60, -610).kind, 'stop');
  assert.throws(() => planRound(0, 0, 60, 0.5));
});

test('isRateLimitError recognises rate limits but not oversized queries', () => {
  assert.equal(isRateLimitError({ code: -32005, message: 'limit exceeded' }), true);
  // Same code, but a query that is too large: retrying cannot help.
  assert.equal(isRateLimitError({ code: -32005, message: 'query returned more than 10000 results' }), false);
  assert.equal(isRateLimitError({ code: -32000, message: 'Too Many Requests' }), true);
  assert.equal(isRateLimitError({ code: -32602, message: 'block range greater than 1000 max' }), false);
  assert.equal(isRateLimitError({ code: 3, message: 'execution reverted' }), false);
  assert.equal(isRateLimitError(undefined), false);
});

test('isAfter orders logs by block, then log index', () => {
  const l = (b, i) => ({ blockNumber: '0x' + b.toString(16), logIndex: '0x' + i.toString(16) });
  assert.equal(isAfter(l(10, 3), 10, 2), true);
  assert.equal(isAfter(l(10, 2), 10, 2), false);
  assert.equal(isAfter(l(10, 1), 10, 2), false);
  assert.equal(isAfter(l(11, 0), 10, 9), true);
  assert.equal(isAfter(l(9, 9), 10, 0), false);
});

test('settings are validated instead of turning into NaN', () => {
  assert.equal(positiveInt('rounds', '30'), 30);
  assert.throws(() => positiveInt('rounds', 'abc'), /rounds must be a positive integer/);
  assert.throws(() => positiveInt('rounds', '0'));
  assert.throws(() => positiveInt('LATENCY_ROUND_TIMEOUT_S', 'x'), /LATENCY_ROUND_TIMEOUT_S/);
  assert.equal(positiveInt('rounds', '200', 200), 200);
  assert.throws(() => positiveInt('rounds', '3000', 200), /rounds must be at most 200/);
  assert.equal(positiveBigInt('amount', '600000000000000000000'), 600000000000000000000n);
  assert.throws(() => positiveBigInt('amount', '1e18'), /whole number/);
  assert.throws(() => positiveBigInt('amount', '0'), /positive/);
});

test('planRound never asks for a level of exactly zero, which means "unset" to the vault', () => {
  for (const tick of [-60, 60]) {
    for (const i of [0, 1]) {
      const p = planRound(tick, i, 60);
      const level = p.kind === 'stop' ? p.stopTick : p.takeProfitTick;
      if (level === 0) assert.fail(`tick ${tick}, round ${i}: level 0 would leave the order with no trigger`);
    }
  }
});

test('sweepPlan cancels only the tool\'s own orders and keeps hand-placed ones', () => {
  const me = '0x9ca5ff17496ba8101438a4c5fa3851f3b2879635';
  const other = '0x00000000000000000000000000000000000000aa';
  const TOOL = 10000000000000000007n;
  const orders = [
    { id: 9, owner: me, status: STATUS.Active, amountIn: TOOL }, // tool leftover
    { id: 8, owner: me, status: STATUS.Active, amountIn: 50n * 10n ** 18n }, // placed by hand
    { id: 7, owner: other, status: STATUS.Active, amountIn: TOOL }, // someone else's
    { id: 6, owner: me, status: STATUS.Executed, amountIn: TOOL }, // already closed
  ];
  assert.deepEqual(sweepPlan(orders, me, TOOL, 2n), { cancel: [9], kept: 1 });
});

test('sweepPlan refuses when kept orders leave no room for the round\'s order', () => {
  const me = '0x9ca5ff17496ba8101438a4c5fa3851f3b2879635';
  const hand = (id) => ({ id, owner: me, status: STATUS.Active, amountIn: 1n });
  assert.throws(() => sweepPlan([hand(1), hand(2), hand(3)], me, 7n, 3n), /not placed by this tool/);
  // Active orders older than the scan count as kept.
  assert.throws(() => sweepPlan([hand(5)], me, 7n, 3n), /limit of 3/);
  assert.deepEqual(sweepPlan([hand(1), hand(2)], me, 7n, 2n), { cancel: [], kept: 2 });
});

test('crossed follows the vault rules (<= for stop, >= for take-profit)', () => {
  const stop = planRound(0, 0, 60);
  assert.equal(crossed(stop, -60), true);
  assert.equal(crossed(stop, -59), false);
  const tp = planRound(0, 1, 60);
  assert.equal(crossed(tp, 60), true);
  assert.equal(crossed(tp, 59), false);
});

test('percentile is nearest-rank', () => {
  const v = [5, 1, 4, 2, 3];
  assert.equal(percentile(v, 50), 3);
  assert.equal(percentile(v, 95), 5);
  assert.equal(percentile([2, 2, 3], 50), 2);
  assert.equal(percentile(Array.from({ length: 30 }, (_, i) => i + 1), 95), 29);
  assert.equal(percentile([], 50), null);
  assert.throws(() => percentile([1], 0));
});

test('summarize ignores missing values and reports an empty list as nulls', () => {
  assert.deepEqual(summarize([2, 3, null, undefined, 3]), { count: 3, min: 2, p50: 3, p95: 3, max: 3, mean: 2.67 });
  assert.deepEqual(summarize([]), { count: 0, min: null, p50: null, p95: null, max: null, mean: null });
});

test('csvLine keeps column order, leaves gaps empty and quotes text', () => {
  const line = csvLine({ round: 1, outcome: 'executed', note: 'a, "b"' });
  const cells = line.split(',');
  assert.equal(cells[0], '1');
  assert.equal(cells[CSV_COLUMNS.indexOf('outcome')], 'executed');
  assert.ok(line.endsWith('"a, ""b"""'));
});

test('redact removes every copy of the secret', () => {
  assert.equal(redact('bad pw hunter2 at --password hunter2', 'hunter2'), 'bad pw [redacted] at --password [redacted]');
  assert.equal(redact('nothing here', ''), 'nothing here');
  assert.equal(redact(undefined, 'x'), '');
});
