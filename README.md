# oco-reactive

On-chain OCO (one-cancels-the-other) stop-loss / take-profit orders for Uniswap v4, executed by a
Reactive Omni contract. Entry for the Reactive Omni Buildathon, track "Every Second Counts".

**Status:** deployed and running on the testnets, Unichain Sepolia and Reactive Lasna. Try it on the
order page: <https://sora200419.github.io/oco-reactive/> (a browser wallet with test tokens; see
[Order page](#order-page)). Test networks and test tokens only.

## How it works

```
Unichain Sepolia                         Reactive Lasna                       Unichain Sepolia
Uniswap v4 pool  --Swap(tick)----------> OcoReactive.react()  --callback-->  OrderVault.execute()
OrderVault       --OrderCreated/          checks every tracked order          re-checks the price,
                   Cancelled/Expired/     against the new tick, keeps         sells on the pool,
                   Executed/Failed------> trailing peaks, requests a sale     pays the owner
```

- **`OrderVault`** (`src/OrderVault.sol`, Unichain Sepolia) holds the tokens of each order. An order
  can carry a stop-loss, a take-profit and a trailing stop at once. When the reactive contract asks
  it to sell, the vault checks the pool price again and sells the whole order on the Uniswap v4
  pool through `V4Swapper`, then pays the owner. A sold order is closed, so its other levels can
  never fire: one cancels the other.
- **`OcoReactive`** (`src/OcoReactive.sol`, Reactive Lasna) subscribes to the pool's `Swap` event and
  to the vault's order events. On each swap it compares the new tick with every tracked order's
  levels, moves trailing peaks up, and requests a callback to the vault for each order whose level
  was crossed (up to four per swap; an order just triggered waits before it can be triggered
  again). There is no off-chain bot: without this contract nothing would sell.
- Written for Reactive Omni with
  [`reactive-lib-omni`](https://github.com/Reactive-Network/reactive-lib-omni) v0.1.0: `react()` is
  guarded by `onlySystem`, callbacks are requested with `SYSTEM.requestCallbackV_1_0`, and the
  vault's `execute` accepts only the callback proxy acting for this reactive contract.

## Deployed contracts

| Contract | Chain | Address |
|---|---|---|
| OrderVault | Unichain Sepolia (1301) | [`0x6a8932797F1FB9D164F6e075Cb4F525FEb824184`](https://sepolia.uniscan.xyz/address/0x6a8932797F1FB9D164F6e075Cb4F525FEb824184) |
| OcoReactive | Reactive Lasna (5318007) | [`0xc358fFaA2bCc6bE005Ab4063Fb7dfcc2Ef4f56fe`](https://lasna.reactscan.net/address/0xc358fFaA2bCc6bE005Ab4063Fb7dfcc2Ef4f56fe) |
| V4Swapper | Unichain Sepolia (1301) | [`0x715666dc26bB46dBADA0112E0c9E6f7Db945EDAa`](https://sepolia.uniscan.xyz/address/0x715666dc26bB46dBADA0112E0c9E6f7Db945EDAa) |
| Test token 0 (OCOA) | Unichain Sepolia (1301) | [`0x0A75150631C8E1ad3FcB48D8B0478B1DC685CD2b`](https://sepolia.uniscan.xyz/address/0x0A75150631C8E1ad3FcB48D8B0478B1DC685CD2b) |
| Test token 1 (OCOB) | Unichain Sepolia (1301) | [`0x354Fc758Ac107D77FF53d3e0b0B2BAE1C55d58EC`](https://sepolia.uniscan.xyz/address/0x354Fc758Ac107D77FF53d3e0b0B2BAE1C55d58EC) |

The pool is on the Uniswap v4 PoolManager `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` (fee 0.3%,
tick spacing 60, no hooks). Deployment transactions and every hash below:
[`docs/tx-hashes.md`](docs/tx-hashes.md).

## Recorded loops

Each loop: the swap that crosses the level on Unichain Sepolia → the reactive transaction on Lasna →
the vault's sale (the callback) on Unichain Sepolia.

| Order | Swap | Reactive transaction | Sale | Swap to sale |
|---|---|---|---|---|
| Stop-loss (order 0) | [`0x3ca44c…9160`](https://sepolia.uniscan.xyz/tx/0x3ca44cc7f75b2097acc48eb8cf702c6abe2da96d4bb50bedb8cb5f7d28199160) | [`0x1d5b75…28d4`](https://lasna.reactscan.net/tx/0x1d5b755512e49157d5af6e069d00853622647f46edc7ac993ec1faf1bb0928d4) | [`0x47346e…a4c6`](https://sepolia.uniscan.xyz/tx/0x47346e451d0f34896f4c5c43230bd4d4a57297a42d5906953a37ebd6a457a4c6) | 2 blocks, 2 s |
| Take-profit (order 1) | [`0x85fa6c…af2b`](https://sepolia.uniscan.xyz/tx/0x85fa6cbb6217c4f407964d9a18cb5f70dbff6901f4877afe17c73cfa52c3af2b) | [`0xc5226d…bcbc`](https://lasna.reactscan.net/tx/0xc5226df2431bb28c6218a00e96d27037f37f469713c709cc4a8a4f3a63ffbcbc) | [`0xc676b4…1a0e`](https://sepolia.uniscan.xyz/tx/0xc676b454087ff03bf086b6c2dd862b4ab9cdfc88a32f33da1b7ecb756be91a0e) | 2 blocks, 2 s |
| Trailing stop (order 2) | [`0x2c98df…8f4e`](https://sepolia.uniscan.xyz/tx/0x2c98dfeb07448eed2407d2c5763ce6ae2749e6531d0a36b99b4d2fdade6c8f4e) | [`0x6c58c2…df75`](https://lasna.reactscan.net/tx/0x6c58c2a402ea86993396d120078edc1a3682889b3066c42d32ea0922eda8df75) | [`0x255c6a…f7f2`](https://sepolia.uniscan.xyz/tx/0x255c6af5f7132a4b683a72f385ad6a98017ab20c4cd241dc3441f3bc3c26f7f2) | 3 blocks, 3 s |

Also recorded there: a cancellation, an expiry closed through the network, and one reactive
transaction triggering three orders at once.

**Latency:** over 30 measured rounds every order sold, 2 blocks (2 s) after the crossing swap at
the median and 3 blocks (3 s) at p95. Details in [Measure latency](#measure-latency).

## Known limitations

- **Orders fill at the market price, not at the level.** When a level is crossed, the vault sells
  the whole order at the pool price at that moment. Its slippage bound (5% from the order page and
  the scripts) is measured against the pool's own price at execution, so it guards against a thin
  pool, not against a price that jumped past the level. Order 0's stop was at tick -120; a single
  2,000-token sale pushed the price to -395 before the callback ran, and the order filled there.
- **The reactive contract pays for every swap in the pool.** Each swap by anyone and each vault
  event is a reactive transaction paid in lREACT by the reactive contract: about 0.013 to 0.017
  lREACT each, about 0.068 per demo round. On 2026-11-13 it held 0.848 lREACT. When the balance
  runs out it goes into debt and the whole system stops until it is topped up (see
  [If nothing happens](#if-nothing-happens)). Because the test tokens can be minted by anyone, anyone
  could also drain it with many small swaps. The owner tops it up before judging.
- **The order book can be filled by one party.** The vault allows 10 active orders in total and 3
  per address, with no minimum amount and lifetimes up to 30 days. Someone using 4 addresses could
  fill all 10 places with tiny orders, and new orders would then fail with `TooManyActiveOrders`
  until those expire; only their owners can cancel them. The final deployment is planned to add a
  minimum order amount and a shorter maximum lifetime.
- **An expiry request can arrive too early for the vault.** The reactive contract asks the vault to
  close an expired order 60 seconds after its expiry by Lasna's clock, and stops tracking it at that
  moment. If Unichain Sepolia's clock were more than 60 seconds behind, the vault would ignore the
  request and the order would stay active but untracked. The two clocks measured about a second
  apart. Such an order can always be closed and refunded by anyone with `reclaimExpired(id)`.
- **A sale has a gas budget.** Each callback asks for 1,000,000 gas, of which the Unichain Sepolia
  callback proxy keeps about 130,000. A sale that crosses ten stacked narrow liquidity ranges used
  499,493 gas in the tests (`test_swapExactIn_gasWhenCrossingManyTicks`). If someone added many
  more narrow ranges in the sale's path, the sale could run out of gas and the order would not be
  sold (it stays active with its tokens in the vault); this has not been tested.

## Earlier milestones

### Uniswap v4 swap path

`src/v4/V4Swapper.sol` executes an exact-input ERC-20 swap directly against the v4 PoolManager, with
no router; the vault sells through it. `test/V4SwapperFork.t.sol` runs it against the real
PoolManager on a pinned-block fork of Unichain Sepolia and pins down what a subscriber sees in the
`Swap` event. It is deployed (address above) and used by every sale and every demo swap.

### Minimal loop

A minimal origin event → reactive transaction → callback loop, used to prove the pipeline end to end
before the real contracts were layered on top.

| Contract | Chain | Role |
|---|---|---|
| `src/loop/PingOrigin.sol` | Unichain Sepolia | Emits `Ping(sender, nonce, sentAt)` |
| `src/loop/PingReactive.sol` | Reactive Lasna | Subscribes to `Ping`, requests a `pong` callback |
| `src/loop/PongCallback.sol` | Unichain Sepolia | Receives `pong`, records the delivery timestamp |

Written against Reactive Omni using
[`reactive-lib-omni`](https://github.com/Reactive-Network/reactive-lib-omni) v0.1.0: `react()` is
guarded by `onlySystem` and callbacks are requested through `SYSTEM.requestCallbackV_1_0`.

The loop is deployed and has run end to end on Unichain Sepolia and Reactive Lasna: origin event to
callback took 2 seconds. Addresses and the three transaction hashes are in
[`docs/tx-hashes.md`](docs/tx-hashes.md).

## Build and test

Requires [Foundry](https://getfoundry.sh/).

```bash
git clone https://github.com/sora200419/oco-reactive.git
cd oco-reactive
git submodule update --init
forge build
forge test -vv
```

Initialise the submodules without `--recursive`: only the three top-level dependencies are needed,
and the nested ones inside them are large and not used by this project.

The fork tests read chain state from the public Unichain Sepolia RPC (`https://sepolia.unichain.org`)
and fail if it is unreachable. Set `ORIGIN_RPC` to use another endpoint.

## Deploy the OCO system (testnets only)

The commands below are for a bash shell (on Windows use Git Bash, not PowerShell), run from the
repo root, all in **one** terminal window. Every script refuses to run if the connected chain id
is not the expected one.

### What you need

- A Foundry keystore for a testnet-only wallet (`cast wallet import deployer --interactive`).
- Unichain Sepolia ETH: deployment and callbacks cost very little there; 0.005 ETH is plenty.
- Lasna lREACT, **at least 1.7 lREACT in the wallet before step 3** with the default settings.
  Step 3 sends `OCO_REACTIVE_FUNDING_WEI` (1 lREACT) into the contract to pay for its reactive
  transactions, and the network also checks that the wallet can cover the gas limit at the
  maximum fee (about 0.6 lREACT more), although only about 0.25 lREACT of that is spent (measured:
  the deployment cost about 0.22 lREACT). Step 6
  (`setVault`) needs up to about 0.05 lREACT more (measured: about 0.008). Get lREACT by sending Sepolia ETH to the faucet contract listed
  in the [Reactive docs](https://dev.reactive.network/reactive-mainnet) (1 ETH gives 100 lREACT).
- After deployment, every swap in the pool and every vault event costs the reactive contract
  lREACT at a 100 gwei gas price. Measured: one stop-loss demo (order, swap, the vault's own
  sale, confirmation) used about 0.067 lREACT, so about 0.017 per reactive transaction on average.

Check the balances first:

```bash
cast balance <your address> --ether --rpc-url https://lasna-rpc.rnk.dev/
```

### Steps

1. Load the public settings, **once**. `.env.example` has empty placeholders for the addresses
   you are about to deploy, so loading it again later would erase them.

   ```bash
   set -a; source ./.env.example; set +a
   ```

2. Pool, tokens, liquidity and swapper on Unichain Sepolia. `--slow` sends the transactions one
   at a time. The script ends by printing five `export ...` lines: run them in the same window,
   and keep a copy somewhere (they are also recorded in
   `broadcast/Oco.s.sol/1301/run-latest.json`). If the output does not end with
   `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`, do not use the printed lines; run this step again
   from the start, which costs almost nothing.

   ```bash
   forge script script/Oco.s.sol:DeployPool --rpc-url $ORIGIN_RPC --account deployer --broadcast --slow
   ```

3. Reactive contract on Lasna, funded with `OCO_REACTIVE_FUNDING_WEI`. It refuses to run if the
   exported `POOL_ID` does not match the token addresses. Run the `export OCO_REACTIVE_ADDR=...`
   line it prints.

   ```bash
   forge script script/Oco.s.sol:DeployOcoReactive --rpc-url $REACTIVE_RPC --account deployer --broadcast
   ```

4. Order vault on Unichain Sepolia, funded with `VAULT_FUNDING_WEI`. Run the
   `export ORDER_VAULT_ADDR=...` line it prints.

   ```bash
   forge script script/Oco.s.sol:DeployOrderVault --rpc-url $ORIGIN_RPC --account deployer --broadcast
   ```

5. Before wiring, check the vault really belongs to this reactive contract and this pool. The
   first command must print the same address as `echo $OCO_REACTIVE_ADDR`, the second the same
   value as `echo $POOL_ID`. Do not continue if either differs.

   ```bash
   cast call $ORDER_VAULT_ADDR "_CALLBACK_SENDER()(address)" --rpc-url $ORIGIN_RPC
   ```

   ```bash
   cast call $ORDER_VAULT_ADDR "POOL_ID()(bytes32)" --rpc-url $ORIGIN_RPC
   ```

6. Wire the reactive contract to the vault. This can be done once and cannot be undone.

   ```bash
   cast send $OCO_REACTIVE_ADDR "setVault(address)" $ORDER_VAULT_ADDR --rpc-url $REACTIVE_RPC --chain 5318007 --account deployer
   ```

### Run a stop-loss

The stop must be below the current tick and the take-profit above it. The pool starts at tick 0;
every demo moves it, so read it before each order:

```bash
cast call $ORDER_VAULT_ADDR "normalizedTick(bool)(int24)" true --rpc-url $ORIGIN_RPC
```

Place an order selling 100 token0 with a stop 120 ticks below and a take-profit 120 ticks above
a current tick of 0. A tick of 0 leaves that level unset, so a level at exactly tick 0 cannot be
set this way. The script always sells token0, uses a 5% slippage bound, and refuses values that
do not fit their field.

```bash
ORDER_AMOUNT_WEI=100000000000000000000 ORDER_STOP_TICK=-120 ORDER_TP_TICK=120 ORDER_TRAILING=0 ORDER_MIN_OUT_WEI=0 ORDER_LIFETIME_SECONDS=86400 forge script script/Oco.s.sol:PlaceOrder --rpc-url $ORIGIN_RPC --account deployer --broadcast
```

Push the price down through the stop by selling 2,000 token0:

```bash
SWAP_ZERO_FOR_ONE=true SWAP_AMOUNT_WEI=2000000000000000000000 forge script script/Oco.s.sol:Swap --rpc-url $ORIGIN_RPC --account deployer --broadcast
```

A few seconds later the order should be sold. Check it, replacing `0` with the order id PlaceOrder
printed (ids count up from 0 on each new vault); the third field is the status, where 1 is active
and 2 is executed:

```bash
cast call $ORDER_VAULT_ADDR "getOrder(uint256)((address,uint64,uint8,bool,bool,bool,int24,int24,int24,uint24,uint16,uint128,uint128))" 0 --rpc-url $ORIGIN_RPC
```

### If nothing happens

Debt on either side stops delivery:

```bash
cast call $SYSTEM_CONTRACT_ADDR "debt(address)(uint256)" $OCO_REACTIVE_ADDR --rpc-url $REACTIVE_RPC
```

```bash
cast call $DESTINATION_CALLBACK_PROXY_ADDR "debt(address)(uint256)" $ORDER_VAULT_ADDR --rpc-url $ORIGIN_RPC
```

Neither contract can pay its debt from inside `react` or `execute`, because those are exactly what
debt stops. To pay it, send the contract funds with a plain transfer, then call `coverDebt()`,
which anyone may call; it reverts with `InsufficientFunds` and pays nothing if the balance is still
short. For the reactive contract (lREACT on Lasna):

```bash
cast send $OCO_REACTIVE_ADDR --value 1ether --rpc-url $REACTIVE_RPC --chain 5318007 --account deployer
```

```bash
cast send $OCO_REACTIVE_ADDR "coverDebt()" --rpc-url $REACTIVE_RPC --chain 5318007 --account deployer
```

For the vault (ETH on Unichain Sepolia):

```bash
cast send $ORDER_VAULT_ADDR --value 0.001ether --rpc-url $ORIGIN_RPC --account deployer
```

```bash
cast send $ORDER_VAULT_ADDR "coverDebt()" --rpc-url $ORIGIN_RPC --account deployer
```

Both steps are covered by tests (`test_coverDebt_underfundedRevertsThenTopUpSettlesIt` in the
reactive contract's and the vault's suites) but have not been run on the testnets, since neither
contract has had debt. Once delivery resumes, the next swap in the pool re-checks every tracked
order; at most four fire per swap, and an order triggered or failed in the last 30 to 120 seconds,
or one that used up its five attempts in the hour, waits for a later swap.

Events missed while the reactive contract owed fees can leave its view of an order wrong in two
ways. Compare the first word this returns (1 tracked, 0 not) with the order's status in the vault
(the third field of `getOrder`; 1 active, 2 executed, 3 cancelled, 4 expired):

```bash
cast call $OCO_REACTIVE_ADDR "getTracked(uint256)" <orderId> --rpc-url $REACTIVE_RPC
```

- Vault 1, reactive 0: right after placing an order this is normal for a few seconds, so check
  again. If it stays, the creation was missed (or the order was dropped because 20 were already
  tracked) and the order will never trigger. Cancel it and place it again.
- Vault 2, 3 or 4, reactive 1: the closing event was missed. The vault ignores callbacks for a
  closed order without telling the reactive contract, so while the price stays past the order's
  level it keeps requesting callbacks (up to five an hour, each paid for) and holds one of the 20
  tracking slots until the first swap more than 60 seconds after the order's expiry, which costs
  one last callback.

The reactive contract records the position of the newest swap it has processed. If this stays 0
after a swap, swap events are not reaching it or are being ignored:

```bash
cast call $OCO_REACTIVE_ADDR "lastSwapPos()(uint128)" --rpc-url $REACTIVE_RPC
```

If you opened a new terminal and lost the exported addresses, copy them from
`broadcast/Oco.s.sol/1301/run-latest.json` (steps 2 and 4) and
`broadcast/Oco.s.sol/5318007/run-latest.json` (step 3).

## Order page

Live at <https://sora200419.github.io/oco-reactive/> (testnets only).

`web/` is a single static page for the deployed contracts: connect a browser wallet extension,
place an order (sells token0; stop-loss, take-profit and trailing distances are ticks from the
current price), see your orders and whether Reactive Network tracks them, cancel them, and, in a
section marked as a testnet demo, swap your own test tokens to push the price through a level and
watch the loop arrive: the swap, the reactive transaction on Lasna and the sale, with links. It has
no backend and no build step; viem is loaded from jsDelivr at a fixed version. The page trusts that
CDN: there is no subresource integrity or content security policy, so a compromised CDN could
offer the wallet a harmful transaction to sign. It is meant for testnet tokens only, and the wallet
shows every transaction before signing.

It needs a little Unichain Sepolia ETH for gas and the two test tokens. The tokens are free: the
page's "Get test tokens" button mints 2,000 of each to the connected wallet. Without the page:

```bash
cast send 0x0A75150631C8E1ad3FcB48D8B0478B1DC685CD2b "mint(address,uint256)" <your address> 2000000000000000000000 --rpc-url https://sepolia.unichain.org --account <your keystore>
```

```bash
cast send 0x354Fc758Ac107D77FF53d3e0b0B2BAE1C55d58EC "mint(address,uint256)" <your address> 2000000000000000000000 --rpc-url https://sepolia.unichain.org --account <your keystore>
```

Run it locally (the page uses JavaScript modules, so open it over http, not as a file):

```bash
python -m http.server 8765 --directory web
```

Then open `http://localhost:8765`. Pushes on `main` that touch `web/` publish it to GitHub Pages
through `.github/workflows/pages.yml`, once the repository's Pages source is set to
"GitHub Actions". Tests for its helpers and configuration (the second needs `cast`):

```bash
node --test web/lib.test.mjs web/config.test.mjs
```

## Measure latency

`tools/latency/latency.mjs` runs the full loop many times and times it. It needs Node 22 and
Foundry's `cast`; it has no npm dependencies. It reads the same exported variables as the
deployment steps above.

### Results

30 rounds on 2026-11-13 (UTC), 15 stop-loss and 15 take-profit, all 30 sold. Raw data with every
transaction hash: [`tools/latency/results/run-2026-11-13T05-32-12-039Z.csv`](tools/latency/results/run-2026-11-13T05-32-12-039Z.csv).

| From the swap that crosses the level to the sale (Unichain Sepolia) | p50 | p95 | max |
|---|---|---|---|
| Blocks | 2 | 3 | 3 |
| Seconds (block timestamps, same chain) | 2 s | 3 s | 3 s |

Percentiles are nearest-rank. In 21 of the 30 rounds the sale landed 2 blocks after the swap, in
the other 9 it took 3 (mean 2.3). Round 1, for example: swap
[`0xe4ab…a629`](https://sepolia.uniscan.xyz/tx/0xe4aba16786faecd128d234f8dd109c65541e19b1403992746f82fdf34c9ba629)
in block 67695515, reactive transaction on Lasna
[`0x19e2…3ce2`](https://lasna.reactscan.net/tx/0x19e22f2db98e4c3f4cf1b597b021f9575b41c7ad4ac7aff422a64bc845923ce2),
sale
[`0x965b…e1be`](https://sepolia.uniscan.xyz/tx/0x965b3e5beaa6cf6f461fafc07bff26d39f9f33b6e003d3019c293dfcd4c0e1be)
in block 67695517.

The times the tool observed from its own polling are skewed upward and should not be read as the
latency. In this run the swap block's timestamp was looked up between seeing the swap and the first
poll, which added at least one RPC round trip to every round, and each round's RPC calls needed 1
to 3 retries of 400 ms, very likely that same lookup waiting for a lagging node. Since this run the
tool reads timestamps after the timing ends and re-reads order states before concluding anything;
that newer version is covered by unit tests but has not yet been run against the testnets. The
run's own summary file leaves these figures out because of the retries; computed from the CSV
anyway:

| Observed, from seeing the swap mined (ms) | p50 | p95 |
|---|---|---|
| to seeing the reactive transaction on Lasna | 2897 | 3461 |
| to seeing the sale on Unichain Sepolia | 3946 | 5010 |

With one RPC call taking about 0.6 s here, that delay comes to very roughly 1 to 3 s per round, with
a polling resolution of about 1.2 s (median; up to 2.1 s, `maxPollCycleMs`). The on-chain figures
above are the ones to rely on.

Cost: the reactive contract's balance fell from 2.9446 to 0.9161 lREACT, about 0.068 per round.

### How it works

Each round places a small order (10 token0 plus 7 wei; the odd amount marks the tool's own
orders) 60 ticks from the current price, waits until the
reactive contract tracks it, pushes the price through the level with one swap (600 tokens), and
records when the reactive transaction and the callback appear. Rounds alternate between stop-loss
(price pushed down) and take-profit (pushed up) and keep the price within 300 ticks of where the
run started.

A round that does not end in a sale, for any reason (timeout, RPC failure, a failed transaction,
Ctrl-C), cancels its order before the next round starts, and the CSV keeps that order's id and
transaction hashes. If a cancel fails while the order may still be active (including when its
state cannot be read), or if sending the order fails but the wallet's nonce shows something was
broadcast, the run stops so the order cannot block later rounds (one wallet may hold at most three
active orders). Before it starts, the next run cancels active orders of the wallet that carry the
tool's marker amount; orders placed by hand are left alone, and the run refuses to start if they
leave no room for its own order. This only works while `LATENCY_ORDER_AMOUNT_WEI` stays the same
between runs, and it must never be an amount you also use for orders by hand. Ctrl-C once stops after cleaning up the current round; twice
quits at once. Ctrl-C can also reach a `cast` command that is running; the nonce check above
covers that case, but how Ctrl-C behaves in Git Bash's terminal has not been tried on a real run.

Settings are bounded: at most 200 rounds, `LATENCY_LEVEL_OFFSET` up to 1000 ticks,
`LATENCY_ROUND_TIMEOUT_S` up to 600, `LATENCY_POLL_MS` up to 5000.

Before the first round it checks the funds and refuses to start if the reactive contract holds
less lREACT than the run needs (0.08 per round, a margin over the 0.068 measured), owes fees, or the vault, the wallet's
Unichain Sepolia ETH or its test tokens run short. It prints the top-up command when lREACT is
short.

Two measurements per round:

- **On chain**: swap block to callback block on Unichain Sepolia, as a block count and as
  block-timestamp seconds. Both ends are on the same chain and the same clock. This is the main
  number.
- **Observed**: milliseconds between the tool seeing the swap mined and seeing the reactive
  transaction on Lasna, and seeing the callback. Every "seen" time comes from polling, so each end
  is late by up to one poll cycle (a 200 ms sleep plus the RPC round trips), and the difference can
  be off by about that much in either direction. The largest poll cycle of each round is in the CSV
  (`maxPollCycleMs`). Rounds where an RPC call had to be retried while a time was being taken
  (order mined to tracked, swap mined to the end of the loop) are marked and left out of the
  observed statistics, because the backoff would be counted as latency. Lookups outside those
  windows, such as block timestamps, may retry without marking the round. Retries while waiting
  for the order's or the swap's receipt are not counted either: they make the tool see the receipt
  late, which can only shorten the time that follows it.

Block timestamps are never subtracted across the two chains: their clocks differ by about a second.

Measure loops that already happened (read-only). Each argument is a swap transaction, optionally
followed by `:orderId`; without an order id the first callback after the swap is used:

```bash
node tools/latency/latency.mjs replay <swapTx> <swapTx>:<orderId> ...
```

Run new rounds (sends real transactions). The tool signs with `cast` from your keystore, so it
needs the keystore password. Read it into the current shell without echoing it; it is passed to
`cast` on its command line and not written anywhere. While a `cast` command runs, other programs on
your computer can see that command line. Writing the password to a file for `--password-file`
would avoid that but would put it on disk instead; for a testnet-only wallet the command line was
chosen. Clear it afterwards.

```bash
read -rs OCO_KEYSTORE_PASSWORD && export OCO_KEYSTORE_PASSWORD
```

```bash
node tools/latency/latency.mjs run 30
```

```bash
unset OCO_KEYSTORE_PASSWORD
```

Results go to `tools/latency/results/run-<time>.csv` (one row per round, with every transaction
hash) and a summary `.md` next to it. Tests for the tool:

```bash
node --test tools/latency/lib.test.mjs tools/latency/round.test.mjs
```

## Deploy the minimal loop (testnets only)

The commands below are for a bash shell (on Windows use Git Bash, not PowerShell).

1. Copy `.env.example` to `.env`. The public RPC URLs are already filled in. Do not put a private
   key in it.
2. Import a testnet-only deployer key into a Foundry keystore, once:

   ```bash
   cast wallet import deployer --interactive
   ```

3. Get lREACT: send Sepolia or Base Sepolia ETH to the faucet contract listed in the
   [Reactive docs](https://dev.reactive.network/reactive-mainnet) (1 ETH gives 100 lREACT, at most
   5 ETH per transaction).
4. From the repo root, load the env file (`set -a; source .env; set +a`) and deploy in this order, copying each printed address into
   `.env` and reloading it before the next step:

   ```bash
   forge script script/Loop.s.sol:DeployPingOrigin --rpc-url $ORIGIN_RPC --account deployer --broadcast
   ```

   ```bash
   forge script script/Loop.s.sol:DeployPingReactive --rpc-url $REACTIVE_RPC --account deployer --broadcast
   ```

   ```bash
   forge script script/Loop.s.sol:DeployPongCallback --rpc-url $DESTINATION_RPC --account deployer --broadcast
   ```

5. Point the reactive contract at the callback contract. This can be done only once and neither
   contract can be drained, so check the address first; a wrong one means redeploying both:

   ```bash
   cast send $PING_REACTIVE_ADDR "setRecipient(address)" $PONG_CALLBACK_ADDR --rpc-url $REACTIVE_RPC --account deployer
   ```

6. Fire a ping and check that the pong arrived:

   ```bash
   cast send $PING_ORIGIN_ADDR "ping()" --rpc-url $ORIGIN_RPC --account deployer
   ```

   ```bash
   cast call $PONG_CALLBACK_ADDR "pongCount()(uint256)" --rpc-url $DESTINATION_RPC
   ```

Each script refuses to run if the connected chain id does not match the one in `.env`.

If nothing arrives, check for debt, which stops delivery:

```bash
cast call $SYSTEM_CONTRACT_ADDR "debt(address)(uint256)" $PING_REACTIVE_ADDR --rpc-url $REACTIVE_RPC
```

```bash
cast call $DESTINATION_CALLBACK_PROXY_ADDR "debt(address)(uint256)" $PONG_CALLBACK_ADDR --rpc-url $DESTINATION_RPC
```

## License

MIT. Dependencies under `lib/` keep their own licenses.
