# IMPLEMENTATION PLAN — 实施计划

规则：一次做一步，做完跑测试再勾选。每一步要小到一次对话能做完并验证。

## Phase 1：环境与最小闭环（11/10–11/16），过 Execution 门槛
- [x] 安装 Foundry。验证：`forge --version` 输出 1.9.0。
- [x] 新建仓库文件夹，放入文档模板，`git init`。验证：`git status` 正常。
- [x] 填好 4 份核心文档。验证：本地文档检查脚本通过（11/10；脚本属于本地工具，不在公开仓库里）。
- [x] 核实 Omni 库：是 `Reactive-Network/reactive-lib-omni`（tag v0.1.0，提交 3ade0dc），含 `src/base/AbstractReactive.sol`、`onlySystem`、`requestCallbackV_1_0`。旧的 `reactive-lib` 和官方 demo 仓库都还是旧版写法，不能用。
- [x] 【负责人】确认 PRD 内容（11/10 已确认）。
- [x] Foundry 工程骨架、`.gitignore`、`.env.example`、MIT 许可，安装 `reactive-lib-omni`（remapping `@reactive/=lib/reactive-lib-omni/`）。验证：`forge build` 成功。
- [x] 最小闭环合约：源链 `Ping` 事件 → `PingReactive` → `PongCallback`，带测试。验证：`forge test` 通过。
- [x] 部署脚本（Lasna、Unichain Sepolia）。验证：`test/LoopScripts.t.sol` 在进程内跑脚本并检查接线和错链保护。没有在 anvil 或测试网上真实广播过（anvil 上没有系统合约，脚本跑不了），第一次真实运行就是上测试网那一步。
- [x] 【负责人】领测试 ETH，换 lREACT，导入 Foundry keystore（11/11 完成；没有建 `.env`，直接加载 `.env.example`）。
- [ ] 【负责人】建公开 GitHub 仓库并推送。
- [x] 测试网跑通最小闭环，三笔交易哈希记入 `docs/tx-hashes.md`（11/11）。验证：三笔交易都从链上读回，`pongCount()` 为 1，源事件到 callback 用时 2 秒。`getCallbacks` 返回空数组，原因未明，改用合约事件对应三笔交易。
- [x] v4 试验，fork 部分（11/11）：从 v4-core v4.0.0 源码确认 `Swap` 事件；`src/v4/V4Swapper.sol` 不经路由直接对 PoolManager 换币；`test/V4SwapperFork.t.sol` 在 Unichain Sepolia 的 fork（固定区块 67,550,000）上对真实 PoolManager 建池、加流动性、双向 swap 并解码事件，15 个 fork 测试通过；`test/V4SwapperUnit.t.sol` 用假的 PoolManager 覆盖真实池子不会出现的"正负号错误"分支，3 个测试通过。`V4Swapper` 的 9 个守卫都做过"删掉守卫、对应测试变红"的检查。其中 `TransferFailed` 和 `SettleMismatch` 两个守卫删掉后调用仍会被 PoolManager 自己拦下，它们的作用是给出更清楚的报错，不是唯一的保护。
- [ ] v4 试验，真实广播部分：测试网上发一笔真实的 swap 交易并把哈希记入 `docs/tx-hashes.md`。原计划的验收标准是这一条；fork 测试没有产生真实交易，所以这一项不勾。打算并入 Phase 2 的测试网部署一起做，**这个调整待负责人确认**。
- [x] 11/16 决策（提前于 11/11 做出）：**走 v4**，不启用 V2 退路。依据是 fork 测试，不是真实交易；测量条件和余量见下面"gas"一条。

### v4 试验结论（写 Phase 2 时要用）
以下结论只在**不带 hooks 的池子**上验证过。带 hooks 的池子里 hook 可以改变成交数量，事件里的数量也可能和调用方实际收付的不同，所以金库只接受 `hooks == address(0)` 的池子。

- `Swap(PoolId indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)`，topic0 = `0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f`。
- 订阅条件：合约 = PoolManager，topic0 = 上值，topic1 = poolId。日志有 3 个 topic，data 是 6 个 32 字节字。
- `opCode`：Reactive 文档说它等于原日志的 topic 数。实测依据是最小闭环：`PingReactive.react()` 要求 `opCode == 3`，而 3 个 topic 的 `Ping` 事件在 Lasna 上通过了这个判断并发出了 callback（`docs/tx-hashes.md` 第 2 段交易）。v4 的 `Swap` 也是 3 个 topic，所以预期 `opCode == 3`，但**还没有用真实的 Swap 日志在 Lasna 上验证过**，Phase 2 第一次上测试网时确认。
- 事件里的 `tick` 和 `sqrtPriceX96` 是 swap **之后**的价格，和 `StateLibrary.getSlot0` 读到的一致，所以 reactive 合约只靠事件就能判断触线，金库复核时用 `getSlot0`。
- 数量的正负号：事件里卖出的一边是**负数**，买入的一边是正数（卖 100 个 currency0 时 `amount0 == -100e18`）。这和 v4-core 注释的字面意思、以及 v3 的习惯相反，以测试为准。
- 卖 currency0 让 tick 下降，卖 currency1 让 tick 上升。订单要记录卖的是哪一边，止损和止盈的方向据此决定。
- 付款流程：`sync(currency)` → 把代币转给 PoolManager → `settle()`；收款用 `take(currency, recipient, amount)`。
- gas（Foundry 测量，不含 21,000 的交易基础费，也不含金库自己的逻辑）：
  - 最好情况 159,321：卖 1e18，单个流动性区间，不跨 tick。
  - 压力情况 499,493：十个窄区间叠在一起，一笔卖穿，跨 11 个已初始化 tick。这是一个压力样本，不是上限；而且这些区间是在同一个测试交易里刚建的，存储槽是热的，真实 callback 面对冷槽时数字会不同，偏大还是偏小没有确定。
  - 可用额度（估算）：callback gas 上限我们设的是 1,000,000；Unichain Sepolia 的 callback proxy 上读到 `_extraGas` = 80,000、`_maxChargeGas` = 50,000（11/10 用 `cast call` 读取）。文档说 proxy 会为这两项预留 gas，据此估算留给金库的约 870,000。"两项相加后全部扣留"是按文档的理解，没有从真实 callback 的 gas 用量上验证过。
  - 结论：普通情况余量很大；跨很多 tick 时可能吃掉一半以上。Phase 2 要给金库的 `execute` 做同样的压测，必要时调高 callback gas 上限。
- `V4Swapper` 的有意限制：只支持返回 bool 且足额到账的 ERC-20（不支持转账扣费的代币和不返回值的代币）；整笔成交，池子太薄吃不下就整笔失败。后一条对止损有影响：池子流动性不够时止损单会一直失败，而失败的 callback 照样收费。金库设计时要决定是否允许部分成交或设重试上限。
- 公共节点 `https://sepolia.unichain.org` 的 `eth_getLogs` 一次最多查 1000 个区块，延迟工具要分段查。11/11 实测该节点能返回 500 万个区块之前的合约代码，fork 测试因此固定在区块 67,550,000；节点以后是否一直保留这段历史不确定。

## Phase 2：核心合约（11/17–11/23）
- [ ] `OrderVault`：下单、取消、过期取回。验证：单元测试。
- [ ] `OrderVault.execute`：鉴权、复核价格、swap、结算。验证：单元测试，含伪造调用被拒。
- [ ] `OcoReactive`：订阅、订单簿、止损和止盈判断、防重复触发。验证：单元测试。
- [ ] 移动止损。验证：先涨后跌的测试。
- [ ] 顺序测试：取消后触发、成交后触发、过期后触发、重复触发、两边同时触线。
- [ ] 部署测试网，跑通第一条真实止损链路并记录哈希。

## Phase 3：延迟、加固、界面（11/24–11/30）
- [ ] `tools/latency` 脚本，跑 30 轮以上。验证：产出 CSV 和 p50 / p95。
- [ ] 欠款处理和 gas 上限压测（满额订单）。验证：满额时 `react` gas 低于 900,000。
- [ ] 最小网页（落后就砍）。
- [ ] 交 `harness-reviewer` 审查，问题逐条修或给证据。
- [ ] 11/30 功能冻结。

## Phase 4：部署、视频、文档（12/1–12/5）
- [ ] 最终部署，Sourcify 验证，三组完整链路哈希。
- [ ] README：是什么、为什么需要 Omni、架构图、延迟表、地址、哈希、复现步骤。
- [ ] 【负责人】录 3 分钟内的 demo 视频。
- [ ] 【负责人】12/4 在活动页提交。12/5 缓冲。

## 已知风险 / 待决定
- 截止时间 12/6 04:00 的时区未确认。
- `reactive-lib-omni` 的源码标注 `UNLICENSED` 且仓库没有 LICENSE 文件；只以 git submodule 方式引用，不把它的源码拷进本仓库。
- 官方没有 Omni 写法的示例合约可参考，只能照文档和库源码写，第一次上测试网要预留调试时间。
- Lasna 和 Unichain Sepolia 的区块时间戳没有对齐（实测 Lasna 的 reactive 交易时间戳比触发它的源事件还早 1 秒），延迟工具不能跨链相减时间戳，要同时记录本机观测时间。
- `SYSTEM.getCallbacks` 实测返回空数组，延迟工具不能依赖它找 callback 交易，改用目标合约的事件。
- Foundry 装在 `~/.foundry/bin`，还没加进 PATH，命令要写全路径或由负责人自己加 PATH。
- v4 的事件布局和合约内 swap 已在 fork 上验证，但还没有真实交易佐证；`opCode` 对 Swap 日志的取值待上测试网确认。
- fork 测试依赖公共节点 `https://sepolia.unichain.org`，节点不可用时 `forge test` 里的 fork 套件会失败（其余两个套件不受影响）。
- Lasna 到 Unichain Sepolia 的真实延迟未知；若远高于预期，README 如实写并分析各段耗时。
- 官方 demo 已有 V2 止损/止盈，本项目必须靠 v4、OCO、移动止损和延迟数据体现差异。
- 仓库路径含空格并在 OneDrive 下，可能让工具出问题；出问题就把仓库移到无空格的本地路径。
