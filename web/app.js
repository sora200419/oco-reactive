// Order page: connects a browser wallet, places and cancels orders on the vault, moves the pool
// price for demos and follows the loop (swap -> reactive transaction -> sale) across both chains.
import {
  createPublicClient,
  createWalletClient,
  custom,
  http,
  defineChain,
  parseEventLogs,
  BaseError,
  ContractFunctionRevertedError,
} from 'https://cdn.jsdelivr.net/npm/viem@2.57.11/+esm';

import { ORIGIN, REACTIVE, ADDR, POOL_KEY, ORDER_SCAN, WATCH_MS, POLL_MS, VAULT_ABI, REACTIVE_ABI, SWAPPER_ABI, ERC20_ABI } from './config.js';
import {
  STATUS,
  STATUS_LABEL,
  MAX_ORDERS_PER_OWNER,
  parseAmount,
  formatAmount,
  buildOrder,
  describeLevels,
  timelineRows,
  trackingLabel,
  txUrl,
  isUserRejection,
  recentIds,
} from './lib.js';

// ------------------------------------------------------------------ chains

const chainOf = (c) =>
  defineChain({
    id: c.id,
    name: c.name,
    nativeCurrency: c.id === REACTIVE.id ? { name: 'lREACT', symbol: 'lREACT', decimals: 18 } : { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [c.rpc] } },
    blockExplorers: { default: { name: 'Explorer', url: c.explorer } },
  });
const originChain = chainOf(ORIGIN);
const reactiveChain = chainOf(REACTIVE);
// viem polls receipts every 4 s by default; once a second keeps the "seen" times closer.
const origin = createPublicClient({ chain: originChain, pollingInterval: POLL_MS, transport: http(ORIGIN.rpc, { timeout: 15_000, retryCount: 3 }) });
const lasna = createPublicClient({ chain: reactiveChain, pollingInterval: POLL_MS, transport: http(REACTIVE.rpc, { timeout: 15_000, retryCount: 3 }) });

// ------------------------------------------------------------------- state

const $ = (id) => document.getElementById(id);
const state = {
  providers: new Map(), // rdns -> { info, provider }
  provider: null,
  account: null,
  wallet: null,
  tick: undefined,
  symbols: ['token0', 'token1'],
  activeIds: [],
  placedAt: new Map(), // order id -> when this page placed it (ms)
  busy: false,
};

/** Buttons that send transactions; disabled while one is in flight or no wallet is connected. */
function setActionButtons() {
  const off = state.busy || !state.account;
  for (const id of ['place', 'push-down', 'push-up']) $(id).disabled = off;
  for (const b of document.querySelectorAll('button.cancel')) b.disabled = off;
}

// --------------------------------------------------------------- messages

function say(text, kind = '') {
  const m = $('message');
  m.textContent = text;
  m.className = kind;
}

/** Message and optional link, built with text nodes only. */
function sayWithLink(text, linkText, href, kind = '') {
  const m = $('message');
  m.textContent = text + ' ';
  m.className = kind;
  if (href) {
    const a = document.createElement('a');
    a.href = href;
    a.target = '_blank';
    a.rel = 'noopener';
    a.textContent = linkText;
    m.append(a);
  }
}

/** A short, human explanation of an error: the contract's own error name when there is one. */
function explain(error) {
  if (isUserRejection(error)) return 'Cancelled in the wallet.';
  if (error instanceof BaseError) {
    const revert = error.walk((e) => e instanceof ContractFunctionRevertedError);
    if (revert?.data?.errorName) {
      const args = (revert.data.args ?? []).map(String).join(', ');
      return `The contract refused: ${revert.data.errorName}${args ? ` (${args})` : ''}.`;
    }
    return error.shortMessage || error.message;
  }
  return error?.message ?? String(error);
}

/** Retries a read that a lagging node behind the public RPC may not answer yet. */
async function retry(fn, tries = 10, delayMs = 400) {
  let last;
  for (let i = 0; i < tries; i++) {
    try {
      const v = await fn();
      if (v !== null && v !== undefined) return v;
    } catch (e) {
      last = e;
    }
    await new Promise((r) => setTimeout(r, delayMs));
  }
  throw last ?? new Error('no answer from the RPC node');
}

// ------------------------------------------------------------------ wallet

function renderWallets() {
  const box = $('wallets');
  box.replaceChildren();
  const list = [...state.providers.values()];
  if (!list.length && window.ethereum) list.push({ info: { name: 'Browser wallet', rdns: 'injected' }, provider: window.ethereum });
  if (!list.length) {
    const p = document.createElement('span');
    p.className = 'muted';
    p.textContent = 'No browser wallet found. Install a wallet extension such as Rainbow, then reload.';
    box.append(p);
    return;
  }
  for (const { info, provider } of list) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = state.provider === provider ? '' : 'secondary';
    if (typeof info.icon === 'string' && info.icon.startsWith('data:image/')) {
      const img = document.createElement('img');
      img.src = info.icon;
      img.alt = '';
      b.append(img);
    }
    b.append(document.createTextNode(state.provider === provider ? `${info.name} connected` : `Connect ${info.name}`));
    b.addEventListener('click', () => connect(provider));
    box.append(b);
  }
}

window.addEventListener('eip6963:announceProvider', (event) => {
  const { info, provider } = event.detail ?? {};
  if (!info || !provider) return;
  state.providers.set(info.rdns || info.uuid, { info, provider });
  renderWallets();
});

async function ensureChain(provider) {
  const want = '0x' + ORIGIN.id.toString(16);
  const have = await provider.request({ method: 'eth_chainId' });
  if (have === want) return;
  try {
    await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: want }] });
  } catch (e) {
    if (e?.code !== 4902) throw e;
    await provider.request({
      method: 'wallet_addEthereumChain',
      params: [{
        chainId: want,
        chainName: ORIGIN.name,
        nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
        rpcUrls: [ORIGIN.rpc],
        blockExplorerUrls: [ORIGIN.explorer],
      }],
    });
  }
}

async function connect(provider) {
  try {
    say('Waiting for the wallet…');
    const accounts = await provider.request({ method: 'eth_requestAccounts' });
    if (!accounts?.length) throw new Error('The wallet returned no account.');
    await ensureChain(provider);
    if (state.provider) detach(state.provider); // also for the same wallet, so listeners never pile up
    state.provider = provider;
    setAccount(accounts[0]);
    provider.on?.('accountsChanged', onAccounts);
    provider.on?.('chainChanged', onChain);
    renderWallets();
    say('Connected.', 'ok');
  } catch (e) {
    say(explain(e), isUserRejection(e) ? 'warn' : 'bad');
  }
}

function detach(provider) {
  provider.removeListener?.('accountsChanged', onAccounts);
  provider.removeListener?.('chainChanged', onChain);
}

function onAccounts(accounts) {
  setAccount(accounts?.[0] ?? null);
}

function onChain(chainId) {
  if (Number(chainId) !== ORIGIN.id) say(`The wallet switched to another network; it will be asked to return to ${ORIGIN.name} before the next transaction.`, 'warn');
}

function setAccount(account) {
  state.account = account;
  state.wallet = account
    ? createWalletClient({ account, chain: originChain, transport: custom(state.provider) })
    : null;
  $('account').textContent = account ? `Connected: ${account}` : 'Not connected.';
  setActionButtons();
  $('refresh-orders').disabled = !account;
  $('place').textContent = account ? 'Place order' : 'Connect a wallet first';
  refreshAll();
}

// ------------------------------------------------------------------- reads

async function loadSymbols() {
  try {
    state.symbols = await Promise.all(
      [ADDR.token0, ADDR.token1].map((address) => origin.readContract({ address, abi: ERC20_ABI, functionName: 'symbol' }))
    );
  } catch {
    // Keep the generic names; the rest of the page does not depend on them.
  }
  $('bal0-label').textContent = `${state.symbols[0]} balance`;
  $('bal1-label').textContent = `${state.symbols[1]} balance`;
}

async function refreshMarket() {
  try {
    state.tick = Number(await origin.readContract({ address: ADDR.vault, abi: VAULT_ABI, functionName: 'normalizedTick', args: [true] }));
    $('tick').textContent = String(state.tick);
    previewLevels();
  } catch (e) {
    say('Could not read the pool price: ' + explain(e), 'bad');
  }
  if (!state.account) return;
  try {
    const [b0, b1, active] = await Promise.all([
      origin.readContract({ address: ADDR.token0, abi: ERC20_ABI, functionName: 'balanceOf', args: [state.account] }),
      origin.readContract({ address: ADDR.token1, abi: ERC20_ABI, functionName: 'balanceOf', args: [state.account] }),
      origin.readContract({ address: ADDR.vault, abi: VAULT_ABI, functionName: 'activeOrdersOf', args: [state.account] }),
    ]);
    $('bal0').textContent = formatAmount(b0, 18, 2);
    $('bal1').textContent = formatAmount(b1, 18, 2);
    $('active-count').textContent = `${active} of ${MAX_ORDERS_PER_OWNER}`;
  } catch (e) {
    say('Could not read balances: ' + explain(e), 'bad');
  }
}

async function readOrders() {
  const next = await origin.readContract({ address: ADDR.vault, abi: VAULT_ABI, functionName: 'nextOrderId' });
  const ids = recentIds(next, ORDER_SCAN);
  const mine = [];
  for (let i = 0; i < ids.length; i += 10) {
    const batch = ids.slice(i, i + 10);
    const orders = await Promise.all(
      batch.map((id) => origin.readContract({ address: ADDR.vault, abi: VAULT_ABI, functionName: 'getOrder', args: [BigInt(id)] }))
    );
    orders.forEach((o, j) => {
      if (o.owner.toLowerCase() === state.account.toLowerCase()) mine.push({ id: batch[j], ...o });
    });
  }
  return { mine, scanned: ids.length, total: Number(next) };
}

/**
 * Whether the reactive contract tracks an order. "Not tracked" is only believed after three reads
 * a second apart agree, since a lagging node behind the public RPC can briefly answer it for an
 * order that is tracked. Returns null when no read succeeded.
 */
async function readTracked(id) {
  let answer = null;
  for (let i = 0; i < 3; i++) {
    if (i > 0) await new Promise((r) => setTimeout(r, 1000));
    try {
      const t = await lasna.readContract({ address: ADDR.reactive, abi: REACTIVE_ABI, functionName: 'getTracked', args: [BigInt(id)] });
      if (t.active) return true;
      answer = false;
    } catch {
      // Counted as no answer; the next read may succeed.
    }
  }
  return answer;
}

async function refreshOrders() {
  if (!state.account) return;
  const tbody = $('orders');
  try {
    const { mine, scanned, total } = await readOrders();
    const active = mine.filter((o) => Number(o.status) === STATUS.Active);
    state.activeIds = active.map((o) => o.id);
    const tracked = new Map();
    await Promise.all(
      active.map(async (o) => {
        tracked.set(o.id, trackingLabel(await readTracked(o.id), state.placedAt.get(o.id), Date.now()));
      })
    );
    tbody.replaceChildren();
    if (!mine.length) {
      const tr = document.createElement('tr');
      const td = document.createElement('td');
      td.colSpan = 6;
      td.className = 'muted';
      td.textContent = 'No orders yet.';
      tr.append(td);
      tbody.append(tr);
    }
    for (const o of mine) {
      const status = STATUS_LABEL[Number(o.status)] ?? String(o.status);
      const tr = document.createElement('tr');
      const cells = [
        String(o.id),
        `${formatAmount(o.amountIn, 18, 2)} ${state.symbols[o.zeroForOne ? 0 : 1]}`,
        describeLevels(o),
        status,
        Number(o.status) === STATUS.Active ? tracked.get(o.id) : '',
      ];
      cells.forEach((text, k) => {
        const td = document.createElement('td');
        td.textContent = text;
        if (k === 3) td.className = `status-${status}`;
        tr.append(td);
      });
      const td = document.createElement('td');
      if (Number(o.status) === STATUS.Active) {
        const b = document.createElement('button');
        b.type = 'button';
        b.className = 'secondary cancel';
        b.textContent = 'Cancel';
        b.addEventListener('click', () => cancelOrder(o.id));
        td.append(b);
      }
      tr.append(td);
      tbody.append(tr);
    }
    setActionButtons();
    $('orders-note').textContent =
      total > scanned ? `Showing your orders among the newest ${scanned} of ${total} orders in the vault.` : '';
  } catch (e) {
    say('Could not read orders: ' + explain(e), 'bad');
  }
}

function refreshAll() {
  refreshMarket();
  refreshOrders();
}

// ------------------------------------------------------------------ writes

/** Simulates first (so a refusal costs nothing and names the contract's error), then sends. */
async function write(label, request) {
  await ensureChain(state.provider);
  const { request: simulated } = await origin.simulateContract({ account: state.account, ...request });
  say(`${label}: confirm in the wallet…`);
  const hash = await state.wallet.writeContract(simulated);
  sayWithLink(`${label}: sent, waiting for it to be mined…`, 'view', txUrl(ORIGIN.name, hash));
  let receipt;
  try {
    receipt = await origin.waitForTransactionReceipt({ hash, timeout: 120_000 });
  } catch (e) {
    // It may still be mined later; keep the link so the person can check.
    e.hash = hash;
    throw e;
  }
  if (receipt.status !== 'success') {
    const err = new Error(`${label} failed on chain.`);
    err.hash = hash;
    throw err;
  }
  return { hash, receipt, seenMs: Date.now() };
}

/** Stops before any transaction when the wallet holds too little of the token. */
async function ensureBalance(token, amount, symbol) {
  const balance = await origin.readContract({ address: token, abi: ERC20_ABI, functionName: 'balanceOf', args: [state.account] });
  if (balance < amount) throw new Error(`You hold ${formatAmount(balance, 18, 4)} ${symbol}, less than ${formatAmount(amount, 18, 4)}.`);
}

async function ensureAllowance(token, spender, amount, symbol) {
  const allowance = await origin.readContract({ address: token, abi: ERC20_ABI, functionName: 'allowance', args: [state.account, spender] });
  if (allowance >= amount) return;
  await write(`Approve ${symbol}`, { address: token, abi: ERC20_ABI, functionName: 'approve', args: [spender, amount] });
}

async function guarded(fn) {
  if (state.busy) {
    say('Another action is still running; wait for it to finish.', 'warn');
    return;
  }
  state.busy = true;
  setActionButtons();
  try {
    await fn();
  } catch (e) {
    const text = explain(e);
    if (e?.hash) sayWithLink(text, 'transaction', txUrl(ORIGIN.name, e.hash), 'bad');
    else say(text, isUserRejection(e) ? 'warn' : 'bad');
  } finally {
    state.busy = false;
    setActionButtons();
  }
}

function readForm() {
  return {
    amount: $('f-amount').value,
    stopBelow: $('f-stop').value,
    tpAbove: $('f-tp').value,
    trailing: $('f-trail').value,
    lifetimeHours: $('f-life').value,
  };
}

function previewLevels() {
  const out = $('levels-preview');
  try {
    const p = buildOrder(readForm(), state.tick, 0);
    const parts = [];
    if (p.useStop) parts.push(`stop-loss at tick ${p.stopTick}`);
    if (p.useTakeProfit) parts.push(`take-profit at tick ${p.takeProfitTick}`);
    if (p.trailingDistance) parts.push(`trailing stop ${p.trailingDistance} ticks below the highest tick seen`);
    out.textContent = `Sells when the price reaches: ${parts.join(', or ')}. Whichever comes first cancels the rest.`;
  } catch (e) {
    out.textContent = state.tick === undefined ? '' : e.message;
  }
}

async function placeOrder(event) {
  event.preventDefault();
  let placed = false;
  await guarded(async () => {
    await refreshMarket();
    const block = await origin.getBlock();
    const params = buildOrder(readForm(), state.tick, Number(block.timestamp));
    const active = await origin.readContract({ address: ADDR.vault, abi: VAULT_ABI, functionName: 'activeOrdersOf', args: [state.account] });
    if (active >= BigInt(MAX_ORDERS_PER_OWNER)) throw new Error(`You already have ${MAX_ORDERS_PER_OWNER} active orders, the most one wallet may hold. Cancel one first.`);
    await ensureBalance(ADDR.token0, params.amountIn, state.symbols[0]);
    await ensureAllowance(ADDR.token0, ADDR.vault, params.amountIn, state.symbols[0]);
    const { hash, receipt } = await write('Place order', { address: ADDR.vault, abi: VAULT_ABI, functionName: 'createOrder', args: [params] });
    const created = parseEventLogs({ abi: VAULT_ABI, eventName: 'OrderCreated', logs: receipt.logs })[0];
    if (created) state.placedAt.set(Number(created.args.id), Date.now());
    sayWithLink(
      `Order${created ? ` #${created.args.id}` : ''} placed. The reactive contract usually picks it up within a few seconds.`,
      'view',
      txUrl(ORIGIN.name, hash),
      'ok'
    );
    placed = true;
  });
  if (!placed) return;
  refreshMarket();
  // Follow the "Reactive" column for a while, without holding the other buttons.
  for (let i = 0; i < 10; i++) {
    await refreshOrders();
    await new Promise((r) => setTimeout(r, 2000));
  }
}

async function cancelOrder(id) {
  await guarded(async () => {
    const { hash } = await write(`Cancel order ${id}`, { address: ADDR.vault, abi: VAULT_ABI, functionName: 'cancelOrder', args: [BigInt(id)] });
    sayWithLink(`Order ${id} cancelled and its tokens returned.`, 'view', txUrl(ORIGIN.name, hash), 'ok');
    refreshAll();
  });
}

// ---------------------------------------------------------------- timeline

function renderTimeline(loop, waitingFor) {
  const ol = $('timeline');
  ol.replaceChildren();
  for (const row of timelineRows(loop)) {
    const li = document.createElement('li');
    const strong = document.createElement('strong');
    strong.textContent = row.step;
    const a = document.createElement('a');
    a.href = txUrl(row.chain, row.tx);
    a.target = '_blank';
    a.rel = 'noopener';
    a.textContent = `${row.tx.slice(0, 10)}…${row.tx.slice(-6)}`;
    li.append(strong, document.createElement('br'), document.createTextNode(`${row.chain} · `), a, document.createTextNode(` · ${row.detail}`));
    ol.append(li);
  }
  if (waitingFor) {
    const li = document.createElement('li');
    li.className = 'waiting';
    li.textContent = waitingFor;
    ol.append(li);
  }
}

async function push(zeroForOne) {
  await guarded(async () => {
    const amount = parseAmount($('f-push').value);
    const token = zeroForOne ? ADDR.token0 : ADDR.token1;
    const symbol = state.symbols[zeroForOne ? 0 : 1];
    await refreshOrders();
    const ids = [...state.activeIds];
    await ensureBalance(token, amount, symbol);
    await ensureAllowance(token, ADDR.swapper, amount, symbol);
    const lasnaFrom = await lasna.getBlockNumber();
    const swap = await write(`Swap ${symbol}`, {
      address: ADDR.swapper,
      abi: SWAPPER_ABI,
      functionName: 'swapExactIn',
      args: [POOL_KEY, zeroForOne, amount, 0n, state.account],
    });
    const swapBlock = swap.receipt.blockNumber;
    const block = await retry(() => origin.getBlock({ blockNumber: swapBlock }));
    const loop = { swap: { tx: swap.hash, block: Number(swapBlock), timestamp: Number(block.timestamp), seenMs: swap.seenMs } };
    refreshMarket();
    if (!ids.length) {
      renderTimeline(loop, 'You have no active order, so this swap cannot trigger anything of yours.');
      say('Swap done.', 'ok');
      return;
    }
    say('Swap done. Following the loop…', 'ok');
    await watch(loop, ids, swapBlock, lasnaFrom);
    refreshAll();
  });
}

async function watch(loop, ids, swapBlock, lasnaFrom) {
  const idArgs = ids.map((id) => BigInt(id));
  const deadline = Date.now() + WATCH_MS;
  const triggered = REACTIVE_ABI.find((x) => x.name === 'Triggered');
  const executed = VAULT_ABI.find((x) => x.name === 'OrderExecuted');
  const failed = VAULT_ABI.find((x) => x.name === 'OrderExecutionFailed');
  // The first trigger of one of the person's orders seen after this swap fixes which order the
  // timeline follows; the sale is then looked up for that order only. An expiry request closes
  // the order without a sale, so it ends the timeline there.
  while (Date.now() < deadline && !(loop.reactive && (loop.sale || loop.reactive.side === 4))) {
    renderTimeline(
      loop,
      loop.reactive ? `Waiting for the vault to sell order #${loop.reactive.id}…` : 'Waiting for the reactive contract on Lasna…'
    );
    try {
      if (!loop.reactive) {
        const logs = await lasna.getLogs({ address: ADDR.reactive, event: triggered, args: { id: idArgs }, fromBlock: lasnaFrom, toBlock: 'latest' });
        if (logs.length) {
          const first = logs[0];
          loop.reactive = { tx: first.transactionHash, seenMs: Date.now(), id: Number(first.args.id), side: Number(first.args.side) };
        }
      }
      if (loop.reactive && loop.reactive.side !== 4 && !loop.sale) {
        const id = BigInt(loop.reactive.id);
        for (const [event, isFailure] of [[executed, false], [failed, true]]) {
          const logs = await origin.getLogs({ address: ADDR.vault, event, args: { id }, fromBlock: swapBlock, toBlock: 'latest' });
          if (logs.length) {
            const b = await retry(() => origin.getBlock({ blockNumber: logs[0].blockNumber }));
            loop.sale = {
              tx: logs[0].transactionHash,
              block: Number(logs[0].blockNumber),
              timestamp: Number(b.timestamp),
              failed: isFailure,
              id: loop.reactive.id,
            };
            break;
          }
        }
      }
    } catch (e) {
      // A failed poll is retried on the next cycle; say so without clearing the timeline.
      say('A read failed while following the loop; retrying: ' + explain(e), 'warn');
    }
    if (!(loop.reactive && (loop.sale || loop.reactive.side === 4))) await new Promise((r) => setTimeout(r, POLL_MS));
  }
  if (loop.reactive?.side === 4) {
    renderTimeline(loop);
    say(`Order #${loop.reactive.id} had expired; the reactive contract asked the vault to close it and refund you.`, 'warn');
  } else if (loop.reactive && loop.sale) {
    renderTimeline(loop);
    say(
      loop.sale.failed ? `The vault declined to sell order #${loop.sale.id}; it stays active.` : `Order #${loop.sale.id} sold.`,
      loop.sale.failed ? 'warn' : 'ok'
    );
  } else {
    renderTimeline(loop, `Nothing more seen within ${WATCH_MS / 1000} s. If the price did not reach your level, push it further.`);
  }
}

// ------------------------------------------------------------------- start

$('order-form').addEventListener('submit', placeOrder);
$('order-form').addEventListener('input', previewLevels);
$('refresh-orders').addEventListener('click', () => refreshAll());
$('push-down').addEventListener('click', () => push(true));
$('push-up').addEventListener('click', () => push(false));

window.dispatchEvent(new Event('eip6963:requestProvider'));
setTimeout(renderWallets, 500); // fall back to window.ethereum if no wallet announced itself
loadSymbols();
refreshMarket();
setInterval(refreshMarket, 15_000);
