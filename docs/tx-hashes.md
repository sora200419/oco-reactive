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
