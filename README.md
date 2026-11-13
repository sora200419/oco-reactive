# oco-reactive

On-chain OCO (one-cancels-the-other) stop-loss / take-profit orders for Uniswap v4, executed by a
Reactive Omni contract. Entry for the Reactive Omni Buildathon, track "Every Second Counts".

**Status: work in progress.** What exists today is the minimal loop and the Uniswap v4 swap spike
described below. The order vault and the OCO reactive contract are not written yet; see
`docs/IMPLEMENTATION-PLAN.md`.

## What is in the repo now

### Uniswap v4 swap spike

`src/v4/V4Swapper.sol` executes an exact-input ERC-20 swap directly against the v4 PoolManager, with
no router. It is the execution path the order vault will use. `test/V4SwapperFork.t.sol` runs it
against the real PoolManager on a pinned-block fork of Unichain Sepolia and pins down what a
subscriber sees in the `Swap` event. It has not been broadcast to a testnet yet.

### Minimal loop

A minimal origin event → reactive transaction → callback loop, used to prove the pipeline end to end
before the real contracts are layered on top.

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

The reactive contract records the position of the newest swap it has processed. If this stays 0
after a swap, swap events are not reaching it or are being ignored:

```bash
cast call $OCO_REACTIVE_ADDR "lastSwapPos()(uint128)" --rpc-url $REACTIVE_RPC
```

If you opened a new terminal and lost the exported addresses, copy them from
`broadcast/Oco.s.sol/1301/run-latest.json` (steps 2 and 4) and
`broadcast/Oco.s.sol/5318007/run-latest.json` (step 3).

## Measure latency

`tools/latency/latency.mjs` runs the full loop many times and times it. It needs Node 22 and
Foundry's `cast`; it has no npm dependencies. It reads the same exported variables as the
deployment steps above.

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
less lREACT than the run needs (about 0.08 per round), owes fees, or the vault, the wallet's
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
  (`maxPollCycleMs`). Rounds where an RPC call had to be retried are marked and left out of the
  observed statistics, because the backoff would be counted as latency.

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
