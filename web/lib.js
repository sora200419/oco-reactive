// Pure helpers for the order page: no DOM, no network, so they run under `node --test`.
// Run: node --test web/lib.test.mjs

/** Order status values as stored by OrderVault. */
export const STATUS = { None: 0, Active: 1, Executed: 2, Cancelled: 3, Expired: 4 };
export const STATUS_LABEL = ['none', 'active', 'sold', 'cancelled', 'expired'];
/** Trigger sides as reported by OrderExecuted / Triggered. */
export const SIDE_LABEL = ['', 'stop-loss', 'take-profit', 'trailing stop', 'expiry'];

/** OrderVault limits mirrored for checks before a transaction is sent. */
export const MAX_TICK = 887_272;
export const MAX_ORDERS_PER_OWNER = 3;
export const MAX_LIFETIME_HOURS = 30 * 24;

/**
 * Parses a token amount typed by a person into base units (18 decimals by default).
 * Accepts digits with at most one dot as the decimal separator. Anything else, including commas
 * in either role ("1,5" or "1,000"), is rejected rather than guessed.
 */
export function parseAmount(text, decimals = 18) {
  const s = String(text ?? '').trim();
  if (!/^\d+(\.\d+)?$/.test(s)) {
    throw new Error('Amount must be a number like 10 or 2.5 (dot for decimals, no commas).');
  }
  const [whole, frac = ''] = s.split('.');
  if (frac.length > decimals) throw new Error(`At most ${decimals} decimal places.`);
  const value = BigInt(whole) * 10n ** BigInt(decimals) + BigInt(frac.padEnd(decimals, '0') || '0');
  if (value === 0n) throw new Error('Amount must be more than zero.');
  return value;
}

/** Formats base units as a decimal string with at most `shown` decimals, rounded down. */
export function formatAmount(value, decimals = 18, shown = 4) {
  const v = BigInt(value);
  const neg = v < 0n;
  const abs = neg ? -v : v;
  const base = 10n ** BigInt(decimals);
  const whole = abs / base;
  let frac = (abs % base).toString().padStart(decimals, '0').slice(0, shown).replace(/0+$/, '');
  return (neg ? '-' : '') + whole.toString() + (frac ? '.' + frac : '');
}

/** Parses an optional whole number of ticks; empty means "not used" (null). */
function optionalTicks(name, text) {
  const s = String(text ?? '').trim();
  if (s === '') return null;
  if (!/^\d+$/.test(s)) throw new Error(`${name} must be a whole number of ticks.`);
  const n = Number(s);
  if (n === 0) throw new Error(`${name} must be at least 1 tick, or left empty.`);
  return n;
}

/**
 * Turns the form into OrderParams for selling token0. Distances are ticks away from the current
 * pool tick: the stop below it, the take-profit above it. Throws with a message for the person
 * when the order would be rejected by the vault, so no gas is wasted.
 */
export function buildOrder(form, currentTick, nowSeconds) {
  if (!Number.isInteger(currentTick)) throw new Error('Current price not loaded yet.');
  const amountIn = parseAmount(form.amount);
  const stopBelow = optionalTicks('Stop-loss distance', form.stopBelow);
  const tpAbove = optionalTicks('Take-profit distance', form.tpAbove);
  const trailing = optionalTicks('Trailing distance', form.trailing) ?? 0;
  if (stopBelow === null && tpAbove === null && trailing === 0) {
    throw new Error('Set at least one of stop-loss, take-profit or trailing stop.');
  }
  const stopTick = stopBelow === null ? 0 : currentTick - stopBelow;
  const takeProfitTick = tpAbove === null ? 0 : currentTick + tpAbove;
  for (const [label, t, used] of [
    ['Stop-loss', stopTick, stopBelow !== null],
    ['Take-profit', takeProfitTick, tpAbove !== null],
  ]) {
    if (used && (t < -MAX_TICK || t > MAX_TICK)) throw new Error(`${label} is outside the pool's tick range.`);
  }
  if (trailing > 2 * MAX_TICK) throw new Error('Trailing distance is too large.');
  const hoursText = String(form.lifetimeHours ?? '').trim();
  if (!/^\d+$/.test(hoursText) || Number(hoursText) < 1 || Number(hoursText) > MAX_LIFETIME_HOURS) {
    throw new Error(`Lifetime must be 1 to ${MAX_LIFETIME_HOURS} hours.`);
  }
  return {
    zeroForOne: true,
    amountIn,
    useStop: stopBelow !== null,
    stopTick,
    useTakeProfit: tpAbove !== null,
    takeProfitTick,
    trailingDistance: trailing,
    minAmountOut: 0n,
    maxSlippageBps: 500,
    expiry: BigInt(nowSeconds + Number(hoursText) * 3600),
  };
}

/**
 * Plain-language summary of an order's levels as pool ticks. The vault stores "normalized" ticks:
 * the pool tick for an order selling token0, the negated pool tick for one selling token1. Levels
 * are converted back so both kinds read in the pool's own terms.
 */
export function describeLevels(order) {
  const pool = (n) => (order.zeroForOne ? Number(n) : -Number(n));
  const parts = [];
  if (order.useStop) parts.push(`stop ${pool(order.nStop)}`);
  if (order.useTakeProfit) parts.push(`take-profit ${pool(order.nTakeProfit)}`);
  if (Number(order.trailingDistance)) parts.push(`trailing ${Number(order.trailingDistance)}`);
  return parts.join(' · ');
}

/**
 * Builds the timeline rows for one loop. `swap` and `sale` carry block timestamps of the same
 * chain, so their difference is exact to the second. The reactive transaction is on another
 * chain whose clock is not aligned, so only the time this page saw it is given; the page polls,
 * so that figure is approximate, by a few seconds either way. `reactive` names the order it
 * triggered and the side; the sale row is only ever looked up for that same order.
 */
export function timelineRows({ swap, reactive, sale }) {
  const rows = [];
  if (!swap) return rows;
  rows.push({ step: 'Swap', chain: 'Unichain Sepolia', tx: swap.tx, detail: `block ${swap.block}` });
  if (reactive) {
    const seen = reactive.seenMs - swap.seenMs;
    const expiry = reactive.side === 4;
    rows.push({
      step: expiry
        ? `Reactive contract asks the vault to close expired order #${reactive.id}`
        : `Reactive contract triggers order #${reactive.id} (${SIDE_LABEL[reactive.side] ?? `side ${reactive.side}`})`,
      chain: 'Reactive Lasna',
      tx: reactive.tx,
      detail: `seen by this page about ${(seen / 1000).toFixed(0)} s after it saw the swap (approximate, polled)`,
    });
  }
  if (sale) {
    rows.push({
      step: sale.failed ? `Vault declined to sell order #${sale.id}` : `Vault sells order #${sale.id}`,
      chain: 'Unichain Sepolia',
      tx: sale.tx,
      detail: `${sale.block - swap.block} blocks, ${sale.timestamp - swap.timestamp} s after the swap (same chain's clock)`,
    });
  }
  return rows;
}

/**
 * What the "Reactive" column says for an active order. `tracked` must come from several reads
 * that agree (a lagging node can briefly answer "not tracked"). `placedMs` is when this page
 * placed it, undefined for orders placed elsewhere or before a reload. Only an order this page
 * placed more than two minutes ago gets the advice to cancel: by then it will not be tracked
 * (dropped at the tracking cap, or its creation was missed). For an order of unknown age the
 * label stays neutral, because it may simply be new.
 */
export function trackingLabel(tracked, placedMs, nowMs) {
  if (tracked === true) return 'tracked';
  if (tracked !== false) return 'could not read';
  if (placedMs === undefined) return 'not tracked (if just placed, wait a minute; if it stays, see README)';
  if (nowMs - placedMs < 120_000) return 'not tracked yet';
  return 'not tracked after 2 minutes: cancel and place again (see README)';
}

/** Explorer link for a transaction on one of the two chains. */
export function txUrl(chain, hash) {
  const base = chain === 'Reactive Lasna' ? 'https://lasna.reactscan.net' : 'https://sepolia.uniscan.xyz';
  return `${base}/tx/${hash}`;
}

/** True when an error is the wallet saying the person declined. */
export function isUserRejection(error) {
  for (let e = error; e; e = e.cause) {
    if (e.code === 4001 || e.name === 'UserRejectedRequestError') return true;
  }
  return false;
}

/**
 * Puts an EIP-1193 wallet on `chain` ({ id, name, rpc, explorer }). The standard answer to
 * switching to an unknown network is error 4902, but some wallets (Rainbow) answer "unsupported
 * network" with another code, so any failure other than the person declining leads to asking the
 * wallet to add the network. Some wallets add without switching, so the chain is checked at the end.
 */
export async function switchToChain(provider, chain) {
  const want = '0x' + chain.id.toString(16);
  if ((await provider.request({ method: 'eth_chainId' })) === want) return;
  try {
    await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: want }] });
    return;
  } catch (e) {
    if (isUserRejection(e)) throw e;
  }
  await provider.request({
    method: 'wallet_addEthereumChain',
    params: [{
      chainId: want,
      chainName: chain.name,
      nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
      rpcUrls: [chain.rpc],
      blockExplorerUrls: [chain.explorer],
    }],
  });
  if ((await provider.request({ method: 'eth_chainId' })) !== want) {
    await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: want }] });
  }
  if ((await provider.request({ method: 'eth_chainId' })) !== want) {
    throw new Error(`The wallet is still not on ${chain.name} (chain ${chain.id}). Switch it there by hand and try again.`);
  }
}

/** The ids to read for "my orders": the newest `limit` ids, newest first. */
export function recentIds(nextOrderId, limit = 50) {
  const next = Number(nextOrderId);
  const ids = [];
  for (let id = next - 1; id >= 0 && id >= next - limit; id--) ids.push(id);
  return ids;
}
