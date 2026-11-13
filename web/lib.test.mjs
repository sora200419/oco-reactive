// Tests for the order page's pure helpers. Run: node --test web/lib.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  parseAmount,
  formatAmount,
  buildOrder,
  describeLevels,
  timelineRows,
  trackingLabel,
  txUrl,
  isUserRejection,
  recentIds,
  MAX_TICK,
} from './lib.js';

const E18 = 10n ** 18n;

test('parseAmount reads dot decimals and rejects commas instead of guessing', () => {
  assert.equal(parseAmount('10'), 10n * E18);
  assert.equal(parseAmount('2.5'), 25n * E18 / 10n);
  assert.equal(parseAmount(' 0.000000000000000001 '), 1n);
  for (const bad of ['1,5', '1,000', '4,500', '1.2.3', '-1', '1e18', '', '.5', '5.']) {
    assert.throws(() => parseAmount(bad), undefined, `accepted ${JSON.stringify(bad)}`);
  }
  assert.throws(() => parseAmount('0'), /more than zero/);
  assert.throws(() => parseAmount('0.0000000000000000001'), /decimal places/);
});

test('formatAmount rounds down to the shown decimals', () => {
  assert.equal(formatAmount(1234567n * E18 / 1000n), '1234.567');
  assert.equal(formatAmount(19999n * E18 / 10000n, 18, 2), '1.99');
  assert.equal(formatAmount(5n * E18), '5');
  assert.equal(formatAmount(0n), '0');
});

const form = { amount: '10', stopBelow: '60', tpAbove: '60', trailing: '', lifetimeHours: '24' };

test('buildOrder places the stop below and the take-profit above the current tick', () => {
  const p = buildOrder(form, -610, 1_800_000_000);
  assert.equal(p.zeroForOne, true);
  assert.equal(p.amountIn, 10n * E18);
  assert.deepEqual([p.useStop, p.stopTick, p.useTakeProfit, p.takeProfitTick], [true, -670, true, -550]);
  assert.equal(p.trailingDistance, 0);
  assert.equal(p.maxSlippageBps, 500);
  assert.equal(p.minAmountOut, 0n);
  assert.equal(p.expiry, 1_800_000_000n + 24n * 3600n);
});

test('buildOrder leaves an empty side unused, and needs at least one trigger', () => {
  const p = buildOrder({ ...form, tpAbove: '' }, 0, 0);
  assert.equal(p.useTakeProfit, false);
  assert.equal(p.takeProfitTick, 0);
  const t = buildOrder({ ...form, stopBelow: '', tpAbove: '', trailing: '100' }, 0, 0);
  assert.deepEqual([t.useStop, t.useTakeProfit, t.trailingDistance], [false, false, 100]);
  assert.throws(() => buildOrder({ ...form, stopBelow: '', tpAbove: '' }, 0, 0), /at least one/);
});

test('buildOrder rejects what the vault would reject', () => {
  assert.throws(() => buildOrder({ ...form, stopBelow: '0' }, 0, 0), /at least 1 tick/);
  assert.throws(() => buildOrder({ ...form, stopBelow: '1.5' }, 0, 0), /whole number/);
  assert.throws(() => buildOrder({ ...form, stopBelow: '-5' }, 0, 0), /whole number/);
  assert.throws(() => buildOrder({ ...form, tpAbove: '10' }, MAX_TICK - 5, 0), /tick range/);
  assert.throws(() => buildOrder({ ...form, lifetimeHours: '0' }, 0, 0), /Lifetime/);
  assert.throws(() => buildOrder({ ...form, lifetimeHours: '721' }, 0, 0), /Lifetime/);
  assert.throws(() => buildOrder({ ...form, lifetimeHours: '1.5' }, 0, 0), /Lifetime/);
  assert.throws(() => buildOrder(form, undefined, 0), /not loaded/);
});

test('describeLevels names only the triggers in use, in pool ticks', () => {
  assert.equal(
    describeLevels({ zeroForOne: true, useStop: true, nStop: -670, useTakeProfit: false, nTakeProfit: 0, trailingDistance: 100 }),
    'stop -670 · trailing 100'
  );
  // An order selling token1 stores negated ticks; they are shown as pool ticks again.
  assert.equal(
    describeLevels({ zeroForOne: false, useStop: true, nStop: 550, useTakeProfit: true, nTakeProfit: 700, trailingDistance: 0n }),
    'stop -550 · take-profit -700'
  );
});

const swap = { tx: '0xs', block: 100, timestamp: 1000, seenMs: 50_000 };

test('timelineRows names the order, and subtracts timestamps only within one chain', () => {
  const rows = timelineRows({
    swap,
    reactive: { tx: '0xr', seenMs: 52_400, id: 7, side: 1 },
    sale: { tx: '0xc', block: 102, timestamp: 1002, id: 7 },
  });
  assert.equal(rows.length, 3);
  assert.equal(rows[0].step, 'Swap', 'the swap row claims nothing about levels');
  assert.match(rows[1].step, /triggers order #7 \(stop-loss\)/);
  assert.match(rows[1].detail, /about 2 s after it saw the swap \(approximate, polled\)/);
  assert.equal(rows[1].chain, 'Reactive Lasna');
  assert.match(rows[2].step, /sells order #7/);
  assert.match(rows[2].detail, /2 blocks, 2 s after the swap \(same chain's clock\)/);
  assert.equal(timelineRows({}).length, 0);
  assert.equal(timelineRows({ swap }).length, 1);
  assert.match(timelineRows({ swap, reactive: { tx: '0xr', seenMs: 0, id: 3, side: 2 }, sale: { tx: '0xc', block: 101, timestamp: 1001, failed: true, id: 3 } })[2].step, /declined to sell order #3/);
});

test('timelineRows says an expiry request is a close, not a sale', () => {
  const rows = timelineRows({ swap, reactive: { tx: '0xr', seenMs: 51_000, id: 4, side: 4 } });
  assert.match(rows[1].step, /close expired order #4/);
  assert.doesNotMatch(rows[1].step, /trigger/);
});

test('trackingLabel turns "not tracked" into advice once it cannot be a delay', () => {
  assert.equal(trackingLabel(true, undefined, 0), 'tracked');
  assert.equal(trackingLabel(false, 1_000, 60_000), 'not tracked yet');
  assert.match(trackingLabel(false, 1_000, 200_000), /after 2 minutes: cancel and place again/);
  // Placed elsewhere or before a reload: its age is unknown, so never advise cancelling it.
  const unknownAge = trackingLabel(false, undefined, 999_999_999);
  assert.doesNotMatch(unknownAge, /cancel/);
  assert.match(unknownAge, /wait a minute/);
  assert.equal(trackingLabel(null), 'could not read');
});

test('txUrl picks the explorer by chain', () => {
  assert.equal(txUrl('Reactive Lasna', '0xab'), 'https://lasna.reactscan.net/tx/0xab');
  assert.equal(txUrl('Unichain Sepolia', '0xab'), 'https://sepolia.uniscan.xyz/tx/0xab');
});

test('isUserRejection finds a 4001 anywhere in the cause chain', () => {
  assert.equal(isUserRejection({ code: 4001 }), true);
  assert.equal(isUserRejection({ name: 'X', cause: { name: 'UserRejectedRequestError' } }), true);
  assert.equal(isUserRejection(new Error('execution reverted')), false);
  assert.equal(isUserRejection(undefined), false);
});

test('recentIds lists the newest ids first, bounded', () => {
  assert.deepEqual(recentIds(3n, 50), [2, 1, 0]);
  assert.deepEqual(recentIds(100, 3), [99, 98, 97]);
  assert.deepEqual(recentIds(0, 50), []);
});
