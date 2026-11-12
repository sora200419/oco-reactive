# Transaction hashes

Every value here was read back from the chain, not copied from terminal output.

Explorers: Unichain Sepolia `https://sepolia.uniscan.xyz`, Reactive Lasna `https://lasna.reactscan.net`.

## Minimal loop (ping → react → pong), 2026-11-11

### Deployed contracts

| Contract | Chain | Address | Deployment tx |
|---|---|---|---|
| PingOrigin | Unichain Sepolia (1301) | `0x64299Ef53b1775791fe79429cc57E42ea2267AaF` | `0x99322336d783913967a7d71d801d421c8bd3397c2533ae4fc4b78543d7dc2ad2` |
| PingReactive | Reactive Lasna (5318007) | `0x64299Ef53b1775791fe79429cc57E42ea2267AaF` | `0x04e3f44c4411584d57cf54d5d3d5f2398853b321efb5f2fe6dad891f9c3704b3` |
| PongCallback | Unichain Sepolia (1301) | `0xAF4cc461F2496961e318cA39CA7c6095ceDE3178` | `0x86ccb18ea57293d709cbdf5918ffb97526bef8e32226b8ebda3ce3b6c1840a88` |

PingOrigin and PingReactive share an address because the same deployer made its first deployment on
each chain. They are different contracts on different chains.

Wiring: `setRecipient` on Lasna, tx `0x147cc83e726b0bc267ecea57b3df032e3dfbec45d42bf1a630150b400b2ff7f4`.

### Full loop #1 (nonce 0)

| Leg | Chain | Block | Block timestamp | Tx |
|---|---|---|---|---|
| 1. Origin event `Ping` | Unichain Sepolia | 67531197 | 1794383625 | `0xb16b1635a7f7b60360d363e09ed4dc10f1c84881d5baaf1135c958fb8ef70a81` |
| 2. Reactive transaction (`react()`, emits `CallbackRequest`) | Reactive Lasna | 8067636 | 1794383624 | `0x82e3d998625286569f0c0a55069d7d669d1476ff8bcd7604526dc688d1cfb51c` |
| 3. Callback `pong` | Unichain Sepolia | 67531199 | 1794383627 | `0xd325eddd51e68204ab2af119820ad5e1c5c36046c62ce4920089051c4d50dce6` |

Result: `pongCount() == 1`, `receivedAt(0) == 1794383627`.

**Origin event to callback: 2 seconds, 2 Unichain Sepolia blocks** (both ends measured on the same
chain's clock).

Notes:
- The Lasna block timestamp of leg 2 is one second *earlier* than the origin event that caused it.
  The two chains' clocks are not aligned, so per-leg timings must not be derived by subtracting
  block timestamps across chains. The latency tool will need wall-clock observation times as well.
- `react()` used 86,476 gas. The reactive contract paid about 0.0127 lREACT for it; the callback
  cost the callback contract about 0.0000002 ETH. Neither contract has debt.
- `SYSTEM.getCallbacks(reactiveTxHash)` returned an empty array when queried a few minutes after
  delivery. Not yet understood; the legs above were matched through contract events instead.

## OCO order system: stop-loss on Uniswap v4, 2026-11-12

Every value below was read back from the chain (receipts, contract getters, event logs).
Explorers: Unichain Sepolia `https://sepolia.uniscan.xyz`, Reactive Lasna `https://lasna.reactscan.net`.

### Deployed contracts

| Contract | Chain | Address | Deployment tx |
|---|---|---|---|
| Test token 0 (OCOA) | Unichain Sepolia (1301) | `0x0A75150631C8E1ad3FcB48D8B0478B1DC685CD2b` | `0x06a3242e8650452c5421a0b1f27e99ae968dbfe99663a08bf9460cc1368ff6ae` |
| Test token 1 (OCOB) | Unichain Sepolia (1301) | `0x354Fc758Ac107D77FF53d3e0b0B2BAE1C55d58EC` | `0xf398bf1414baa2fa7e878465452c0be8010961115b53056e31a376d9b777224b` |
| DemoLiquidity | Unichain Sepolia (1301) | `0x9798835636Ac2037af234776a1C7791Fdde23406` | `0x85df3d350abb1b9465f85683d53675efa709f5e3bae42ac9c227cfae39470c24` |
| V4Swapper | Unichain Sepolia (1301) | `0x715666dc26bB46dBADA0112E0c9E6f7Db945EDAa` | `0xf09027a9f7f1513bfd896ff320b568729df00099f5b576ffaf582b59be5930d2` |
| OcoReactive | Reactive Lasna (5318007) | `0xc358fFaA2bCc6bE005Ab4063Fb7dfcc2Ef4f56fe` | `0xe3834fb0fb6cf47f425dc606d61eadace08ff680b43f473065888f1e9f10c37e` |
| OrderVault | Unichain Sepolia (1301) | `0x6a8932797F1FB9D164F6e075Cb4F525FEb824184` | `0xef85c6a24da11f34f4d1a8a2fad0e35128ce636700fb9ccb6bf57ab7add593da` |

Pool: Uniswap v4 PoolManager `0x00B036B58a818B1BC34d502D3fE730Db729e62AC`, no hooks, fee 0.3%,
tick spacing 60, started at price 1:1 with liquidity 100,000e18 over ticks -12000 to 12000.
Pool id `0xcbbd24e7d8b2783d256bef331fb752ced5658e431d833b154c243ba4726be209`.

Wiring: `OcoReactive.setVault`, tx `0x37886a02489b7e438ebad80c963e37056bee989e4f65539b213a605188cd1357`
(Lasna block 8163646). Before it, the vault's `_CALLBACK_SENDER()` and `POOL_ID()` were read and
matched the reactive contract and the pool. After it, the network's subscription list holds six
active subscriptions for the reactive contract: the pool's `Swap` event (pinned to the pool id)
and the vault's five order events.

An earlier run of the pool script (Unichain Sepolia blocks 67625465 to 67625490, tokens
`0x3C80...d77c` and `0x738c...4c54`, swapper `0xa818...28cd`) was also broadcast from the same
wallet. Nothing refers to it and it costs nothing; it is not part of this deployment.

### Full stop-loss loop #1

Order 0: sell 100 token0, stop at tick -120, take-profit at +120, 5% slippage bound, created at
tick 0. Then 2,000 token0 were sold into the pool to push the price through the stop.

| Leg | Chain | Block | Block timestamp | Tx |
|---|---|---|---|---|
| 0. Order created (`createOrder`) | Unichain Sepolia | 67637067 | n/a | `0xd9fe7e1572950a8735cb8d0245a7a0570ec2a8ee044113e297e6180f5f22782c` |
| 1. Price pushed through the stop (`Swap` event) | Unichain Sepolia | 67639461 | 1794491889 | `0x3ca44cc7f75b2097acc48eb8cf702c6abe2da96d4bb50bedb8cb5f7d28199160` |
| 2. Reactive transaction (`react()`, requests the callback) | Reactive Lasna | 8169453 | 1794491888 | `0x1d5b755512e49157d5af6e069d00853622647f46edc7ac993ec1faf1bb0928d4` |
| 3. Callback: vault sells the order (`OrderExecuted`) | Unichain Sepolia | 67639463 | 1794491891 | `0x47346e451d0f34896f4c5c43230bd4d4a57297a42d5906953a37ebd6a457a4c6` |

Result: order status Executed, the vault holds 0 token0, the reactive contract no longer tracks
the order (`activeIds()` empty, `closed(0)` true). The order sold 100 token0 for 95.746 token1 at
tick -395. That is below the stop price: the stop is a market order, and the 2,000-token push
moved the price well past the stop level before the callback arrived.

**Swap to callback: 2 seconds, 2 Unichain Sepolia blocks** (both ends on the same chain's clock).

### Measurements from this run

- `react()` for the triggering swap: 129,712 gas on Lasna, status success.
- The callback transaction on Unichain Sepolia used 205,055 gas in total (it includes the callback
  proxy's own work, so it is an upper bound for `OrderVault.execute`).
- The swap transaction: 126,984 gas.
- The reactive contract's balance went from 1.000 to 0.9329 lREACT over the whole demo (order
  creation, the swap that triggered, the vault's own sale, the confirmation): about 0.067 lREACT.
  Neither contract has debt.
- Deploying the reactive contract cost the wallet about 0.22 lREACT on top of the 1 lREACT sent into
  it, and `setVault` about 0.008 lREACT. The three Unichain Sepolia deployments and the demo
  transactions cost under 0.00002 ETH in total.
- The Lasna block timestamp of the reactive transaction (1794491888) is one second before the
  Unichain Sepolia block of the swap that caused it (1794491889), as in the first loop, so the two
  clocks agree to within about a second.

### What this run settled

- The `Swap` log reaches `react()` with `opCode` 3 and the 192-byte data the contract expects:
  the reactive contract acted on it.
- `LogRecord.blockNumber` and `logIndex` are the origin chain's block number and the log's index in
  that block: the stored creation position decodes to block 67637067, log index 2, which is where
  `OrderCreated` was emitted. The newest processed swap position decodes to block 67639463.
- `block.timestamp` on Lasna tracks real time.
- Not measured: a `react()` that triggers several orders at once on the real system contract.

### Full take-profit loop #2

Order 1: sell 100 token0, take-profit at tick -250, stop at -800, created at tick -415. Then 1,000
token1 were sold into the pool to push the price up through the take-profit.

| Leg | Chain | Block | Block timestamp | Tx |
|---|---|---|---|---|
| 0. Order created (`createOrder`) | Unichain Sepolia | 67641589 | n/a | `0xe17321882f0025f56e11d3f5e0b267c5860ff9d764cce9283b2bbf1258abdba0` |
| 1. Price pushed through the take-profit (`Swap` event, tick -212) | Unichain Sepolia | 67641616 | 1794494044 | `0x85fa6cbb6217c4f407964d9a18cb5f70dbff6901f4877afe17c73cfa52c3af2b` |
| 2. Reactive transaction (take-profit, level -250) | Reactive Lasna | 8171393 | 1794494043 | `0xc5226df2431bb28c6218a00e96d27037f37f469713c709cc4a8a4f3a63ffbcbc` |
| 3. Callback: vault sells the order (`OrderExecuted`, side 2) | Unichain Sepolia | 67641618 | 1794494046 | `0xc676b454087ff03bf086b6c2dd862b4ab9cdfc88a32f33da1b7ecb756be91a0e` |

Result: the order sold 100 token0 for 97.514 token1 at tick -212, above its creation price of tick
-415. Order closed, nothing left in the vault, the reactive contract stopped tracking it.

**Swap to callback: 2 seconds, 2 Unichain Sepolia blocks.** `react()` used 112,501 gas.

### Full trailing-stop loop #3

Order 2: sell 100 token0 with only a trailing stop, distance 100 ticks, created at tick -232. Then
800 token1 were sold to push the price up to tick -71 (a new peak, no sale), and 1,000 token0 were
sold to push it down to tick -269.

| Leg | Chain | Block | Block timestamp | Tx |
|---|---|---|---|---|
| 0. Order created (`createOrder`) | Unichain Sepolia | 67641792 | n/a | `0x93abce97970052182b0f87ae2ecd7fb213f9855f3dfe6a646aa75c904d00fc97` |
| 1a. Price rises to a new peak (`Swap` event, tick -71); no trigger | Unichain Sepolia | 67641820 | 1794494248 | `0xb20c634accd87887aa8f08c6401307d634845bacf3ff3f07ee06ffba0d98d87e` |
| 1b. Price falls through peak minus 100 (`Swap` event, tick -269) | Unichain Sepolia | 67641851 | 1794494279 | `0x2c98dfeb07448eed2407d2c5763ce6ae2749e6531d0a36b99b4d2fdade6c8f4e` |
| 2. Reactive transaction (trailing stop, level -171) | Reactive Lasna | 8171611 | 1794494279 | `0x6c58c2a402ea86993396d120078edc1a3682889b3066c42d32ea0922eda8df75` |
| 3. Callback: vault sells the order (`OrderExecuted`, side 3) | Unichain Sepolia | 67641854 | 1794494282 | `0x255c6af5f7132a4b683a72f385ad6a98017ab20c4cd241dc3441f3bc3c26f7f2` |

The reactive contract's `Triggered` event reports the level it used: -171, exactly the peak of -71
minus the distance of 100, so the peak was tracked on Reactive Network from the rising swap. That
rising swap produced no `Triggered` event (the only two in the window are loops #2 and #3).

Result: the order sold 100 token0 for 96.963 token1 at tick -269. That is below its creation price
of -232: the single 1,000-token sale pushed the price far past the trailing level (-171) before the
callback ran, and the vault sells at the market price at that moment. A smaller push would have
sold closer to the level.

**Swap to callback: 3 seconds, 3 Unichain Sepolia blocks.** `react()` used 113,108 gas.

### Cost of the three demos

The reactive contract's balance went from 1.000 lREACT to 0.9329 after loop #1, 0.8653 after loop
#2 and 0.7846 after loop #3 (loop #3 has one extra swap): about 0.067 to 0.081 lREACT per demo.
The vault paid about 0.0000012 ETH in callback fees for all three. Neither contract has debt.
