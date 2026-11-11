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
