// Pure helpers for the latency tool: ABI constants, decoding, round planning and statistics.
// Nothing in this file does I/O, so all of it is unit-tested in lib.test.mjs.

/** Function selectors (first 4 bytes of keccak256 of the signature). Checked against `cast sig` in tests. */
export const SELECTORS = {
  normalizedTick: '0xa493a3f0', // normalizedTick(bool)
  getOrder: '0xd09ef241', // getOrder(uint256)
  getTracked: '0xbe8b4d00', // getTracked(uint256)
  debt: '0x9b6c56ec', // debt(address)
  activeOrdersOf: '0x36604b97', // activeOrdersOf(address)
  nextOrderId: '0x2a58b330', // nextOrderId()
  allowance: '0xdd62ed3e', // allowance(address,address)
  balanceOf: '0x70a08231', // balanceOf(address)
};

/** Event topic0 values. Checked against `cast keccak` in tests. */
export const TOPICS = {
  orderCreated: '0x70473f9729fa53ff7f51a8cf988f25c79042c134fd862fdd84c96bddc656fd57',
  orderExecuted: '0x5efd1a00a8e985c60ebdda2c21ab1604cd12e42fb4c918db684375807e100a28',
  orderExecutionFailed: '0x8c0c74b57619e19270c008985d282a8061ece5924f5b018373773288ae41481b',
  triggered: '0x7b80e77f96b7f1bf0286968c5d7ad771e72f072f0806d6a1c61c0aabe808d80f',
  swap: '0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f',
};

/** Order status values of OrderVault.Status. */
export const STATUS = { None: 0, Active: 1, Executed: 2, Cancelled: 3, Expired: 4 };

const MASK_24 = (1n << 24n) - 1n;

/** Encodes a uint256 (or bool) as one 32-byte ABI word, without 0x. */
export function encodeWord(value) {
  const v = typeof value === 'boolean' ? (value ? 1n : 0n) : BigInt(value);
  if (v < 0n) throw new Error('encodeWord: negative value');
  return v.toString(16).padStart(64, '0');
}

/** Returns the n-th 32-byte word of hex data (with or without 0x) as a BigInt. */
export function word(data, n) {
  const hex = data.startsWith('0x') ? data.slice(2) : data;
  const chunk = hex.slice(n * 64, (n + 1) * 64);
  if (chunk.length !== 64) throw new Error(`word: data too short for word ${n}`);
  return BigInt('0x' + chunk);
}

/** Interprets the low 24 bits of an ABI word as a signed int24. */
export function int24(w) {
  const x = BigInt(w) & MASK_24;
  return Number(x >= 0x800000n ? x - 0x1000000n : x);
}

/**
 * Chooses the next round so the pool price stays near `center` (the tick when the run started):
 * more than `band` below it the round is a take-profit (the push raises the price), more than
 * `band` above it a stop-loss (the push lowers it), and in between the kinds alternate. Both
 * kinds sell token0.
 * @returns {{kind: 'stop'|'takeProfit', stopTick: number, takeProfitTick: number, pushZeroForOne: boolean}}
 */
export function planRound(tick, roundIndex, offset, center = 0, band = 300) {
  if (!Number.isInteger(tick) || !Number.isInteger(offset) || offset <= 0 || !Number.isInteger(center)) {
    throw new Error('planRound: tick and center must be integers and offset a positive integer');
  }
  let kind;
  if (tick < center - band) kind = 'takeProfit';
  else if (tick > center + band) kind = 'stop';
  else kind = roundIndex % 2 === 0 ? 'stop' : 'takeProfit';
  // A level of exactly 0 means "unset" to the vault, so move it one tick further from the price.
  if (kind === 'stop') {
    const level = tick - offset;
    return { kind, stopTick: level === 0 ? -1 : level, takeProfitTick: 0, pushZeroForOne: true };
  }
  const level = tick + offset;
  return { kind, stopTick: 0, takeProfitTick: level === 0 ? 1 : level, pushZeroForOne: false };
}

/** True when the post-swap tick has reached the order's level. */
export function crossed(plan, tickAfter) {
  return plan.kind === 'stop' ? tickAfter <= plan.stopTick : tickAfter >= plan.takeProfitTick;
}

/** Nearest-rank percentile (p in 0..100) of a list of numbers. Returns null for an empty list. */
export function percentile(values, p) {
  if (!values.length) return null;
  if (p <= 0 || p > 100) throw new Error('percentile: p must be in (0, 100]');
  const sorted = [...values].sort((a, b) => a - b);
  const rank = Math.ceil((p / 100) * sorted.length);
  return sorted[rank - 1];
}

/** Count, min, p50, p95, max and mean of a list, or null fields when it is empty. */
export function summarize(values) {
  const v = values.filter((x) => typeof x === 'number' && Number.isFinite(x));
  if (!v.length) return { count: 0, min: null, p50: null, p95: null, max: null, mean: null };
  const sum = v.reduce((a, b) => a + b, 0);
  return {
    count: v.length,
    min: Math.min(...v),
    p50: percentile(v, 50),
    p95: percentile(v, 95),
    max: Math.max(...v),
    mean: Math.round((sum / v.length) * 100) / 100,
  };
}

/**
 * True for JSON-RPC errors that public endpoints use for rate limiting, which are worth retrying.
 * A query that is too large ("block range greater than 1000 max") is not one of them.
 */
export function isRateLimitError(error) {
  if (!error) return false;
  // -32005 is left out on purpose: some nodes also use it for "query returned more than 10000
  // results", which retrying cannot fix. A -32005 rate limit still matches on its message below.
  if ([-32016, -32090, 429].includes(Number(error.code))) return true;
  return /rate.?limit|too many requests|limit exceeded|capacity exceeded/i.test(String(error.message ?? ''));
}

/** True when log `l` comes after the position (block, logIndex) on the same chain. */
export function isAfter(l, block, logIndex) {
  const b = Number(BigInt(l.blockNumber));
  return b > block || (b === block && Number(BigInt(l.logIndex)) > logIndex);
}

/** Parses a positive integer setting no larger than `max`, or throws naming the setting. */
export function positiveInt(name, value, max = Number.MAX_SAFE_INTEGER) {
  const n = Number(value);
  if (!Number.isInteger(n) || n <= 0) throw new Error(`${name} must be a positive integer, got "${value}"`);
  if (n > max) throw new Error(`${name} must be at most ${max}, got ${n}`);
  return n;
}

/** Most active orders one wallet may hold in the vault (OrderVault.MAX_ORDERS_PER_OWNER). */
export const MAX_ORDERS_PER_OWNER = 3;

/**
 * Decides which of the signer's active orders the tool may cancel before a run. Only orders whose
 * amount is the tool's own marker amount count as left over by the tool; orders placed by hand are
 * left alone. `orders` are {id, owner, status, amountIn} for the ids scanned; `activeCount` is the
 * vault's activeOrdersOf(owner), which also counts orders older than the scan. Throws when the
 * orders the tool must keep would leave no room for the round's own order.
 */
export function sweepPlan(orders, owner, toolAmount, activeCount) {
  const own = orders.filter((o) => o.owner === owner && o.status === STATUS.Active);
  const cancel = own.filter((o) => o.amountIn === toolAmount).map((o) => o.id);
  const kept = Number(activeCount) - cancel.length;
  if (kept + 1 > MAX_ORDERS_PER_OWNER) {
    throw new Error(
      `the signer has ${kept} active order(s) not placed by this tool; with the round's own order that ` +
        `exceeds the vault's limit of ${MAX_ORDERS_PER_OWNER} per wallet. Cancel some by hand first.`
    );
  }
  return { cancel, kept };
}

/** Parses a positive whole-number amount (wei) as a BigInt, or throws naming the setting. */
export function positiveBigInt(name, value) {
  if (!/^[0-9]+$/.test(String(value))) throw new Error(`${name} must be a whole number of wei, got "${value}"`);
  const n = BigInt(value);
  if (n <= 0n) throw new Error(`${name} must be positive`);
  return n;
}

/** Columns written to the CSV, in order. */
export const CSV_COLUMNS = [
  'round',
  'kind',
  'outcome',
  'orderId',
  'createTx',
  'level',
  'tickAfterSwap',
  'swapTx',
  'swapBlock',
  'swapBlockTs',
  'reactiveTx',
  'reactiveBlock',
  'reactiveBlockTs',
  'callbackTx',
  'callbackBlock',
  'callbackBlockTs',
  'chainBlocks',
  'chainSeconds',
  'obsMsSwapToReactive',
  'obsMsSwapToCallback',
  'obsMsOrderToTracked',
  'maxPollCycleMs',
  'rpcRetries',
  'note',
];

/** One CSV line for a round record; missing fields are empty, text is quoted when needed. */
export function csvLine(record) {
  return CSV_COLUMNS.map((c) => {
    const v = record[c];
    if (v === undefined || v === null) return '';
    const s = String(v);
    return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  }).join(',');
}

/**
 * Removes every occurrence of `secret` from a message, so errors from child processes can be
 * shown without leaking the keystore password.
 */
export function redact(message, secret) {
  const text = String(message ?? '');
  if (!secret) return text;
  return text.split(secret).join('[redacted]');
}
