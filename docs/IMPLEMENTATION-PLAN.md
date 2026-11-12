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
- [x] 建公开 GitHub 仓库并推送（11/11）：`https://github.com/sora200419/oco-reactive`。验证：匿名克隆后 `git submodule update --init`、`forge build`、`forge test` 全部通过（38 个测试）。
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

## Phase 2：核心合约（原定 11/17–11/23，11/11 提前开始）
- [x] `OrderVault`：下单、取消、过期取回。验证：`test/OrderVaultFork.t.sol`（fork，固定区块）。
- [x] `OrderVault.execute`：鉴权、复核价格、swap、结算。验证：同上，含非 proxy 调用被拒、其他 reactive 合约被拒。
- [x] `OcoReactive`：订阅、订单簿、止损和止盈判断、防重复触发。验证：`test/OcoReactiveUnit.t.sol`（手工喂日志，假的系统合约）。
- [x] 移动止损。验证：reactive 单元测试里的先涨后跌用例；全链路测试 `test_loop_trailingStop`。
- [x] 顺序测试：取消后触发、成交后触发（重复投递）、过期后触发、止盈成交后止损再触线、失败后重试。验证：`test/OrderVaultFork.t.sol` 和 `test/OcoFullLoopFork.t.sol`。"两边同时触线"不会发生：下单时要求止损位低于现价、止盈位高于现价，同一个价格不可能同时满足两边。
- [x] 全链路测试 `test/OcoFullLoopFork.t.sol`：真实的池子和金库事件转给 reactive 合约，它请求的 callback 再投递给金库；中间的 Reactive 网络是模拟的。测试可以控制事件的投递顺序，用来验证迟到和乱序的情况。
- [x] 交 `harness-reviewer` 审查：金库和 reactive 合约经三轮审查通过；部署脚本经多角度审查加一轮复审通过。
- [x] 部署测试网，跑通第一条真实止损链路并记录哈希（11/12）：地址和哈希见 `docs/tx-hashes.md`。真实的 Swap 日志触发了 reactive 合约，callback 让金库卖出了订单，从 swap 到 callback 用时 2 秒。v4 试验留下的"真实 swap 交易"也有了：`0x3ca44cc7…9160`。
- [x] 测试网上止盈和移动止损各跑一遍（11/12）：比赛要求的三组完整链路（止损、止盈、移动止损）都有了，从 swap 到 callback 分别是 2、2、3 秒，哈希见 `docs/tx-hashes.md`。移动止损那组的触发位 -171 正好是高点 -71 减 100，说明 reactive 合约确实跟住了高点；价格上涨那一笔没有触发。
- [ ] 还没测的：一笔 `react()` 同时触发多张订单时真实系统合约上的 gas；订单被取消、过期时的真实链路。
- 录视频前要注意：三组链路都是"一笔大 swap 把价格推过触发位"，成交价都比触发位差（止损成交在 -395、移动止损成交在 -269，比下单价还低）。这是止损按市价成交的正常结果，但视频里最好用更小的推价量，让成交价贴近触发位，并在解说里讲清楚。

### Phase 2 的设计决定（实现时定的，负责人可以推翻）
- 一个金库只服务一个池子，池子必须已初始化且不带 hooks；只做卖出方向（两种代币都可以卖）。
- 全库活跃订单上限 10 张，单个地址上限 3 张，订单最长有效期 30 天。
- 一笔 reactive 交易最多触发 4 张订单，其余由后续 swap 触发。测试 `test_loop_fullBookDrainsThroughItsOwnSwaps` 验证了 10 张同价位的订单靠金库自己卖出产生的 swap 就能全部成交。**如果某一批的 4 笔全部失败且池子里再没有别的 swap，剩下的订单会等到下一次有人交易才触发。**
- 整笔成交，不做部分成交。
- 触发次数的限制：一张订单在 1 小时的窗口内最多被触发 5 次，窗口过后重新计数，所以不会被永久停用。金库回报"价格已不在触发位"的那次不计数（否则有人把价格砸穿止损位再拉回几次就能让止损失效）；swap 失败（滑点超限、流动性不足）和没有回音的触发计数。同一个失败事件重复投递或迟到时只按一次处理，不能借此多退还次数。
- 滑点保护有两道：相对现价的最大滑点（先扣掉池子手续费再算，只用来限制价格冲击）和一个绝对最低成交量。
- 过期的订单不卖出。reactive 合约在过期 60 秒后遇到的下一次 swap 时请求金库关闭并退款，然后不再跟踪它；这个请求不受触发次数限制，但如果同一笔 reactive 交易里已经触发了 4 张订单，会顺延到再下一次 swap。订单过期后任何人都可以调用金库的 `reclaimExpired` 直接退款，不依赖 callback。
- 移动止损的最高价只存在 reactive 合约里。金库信任经过鉴权的 reactive 合约给出的触发位，并限制它不低于"下单价减距离"、低于止盈位、且当前价确实不高于它。同时设了止盈和移动止损时，移动止损位最高只到止盈位下面一格，所以价格冲过止盈位又回落、而止盈 callback 没赶上时，订单仍会在回落途中卖出。
- 事件迟到和乱序的处理见 TRD 的"对事件迟到和乱序的处理"。
- 两边的时钟不同：金库用 Unichain Sepolia 的时间判断过期，reactive 合约用 Lasna 的时间计冷却、超时和窗口。

### 已知的限制（这一版接受，没有修）
- **单笔 swap 的价格就能触发订单。** 触发判断和成交前的复核看的都是池子当时的现价，没有时间加权。所以：
  - 有人把价格拉高再砸回原处（付两次手续费），就能让一张移动止损单卖出。测试 `test_documented_roundTripCanForceATrailingSale` 记录了这个行为。
  - 有人把价格砸到止损位以下再触发，止损单会按被砸低的价格卖出。相对滑点保护是对着同一个被操纵的现价算的，挡不住这种情况。
  - 所有者唯一的防线是下单时设一个绝对最低成交量（`minAmountOut`），测试 `test_documented_minAmountOutBlocksAForcedSaleBelowTheFloor` 验证了它有效。它默认是 0，也就是不设防。
- **callback 的费用可以被人消耗。** 订单的触发次数限制是按订单算的，取消后重新下单就是一张新订单。另外"价格已不在触发位"的失败不计数，只受 30 秒冷却限制。所以愿意反复付 swap 手续费或 gas 的人可以持续消耗两个合约里预存的费用。这一版没有收下单费来抵这笔开销。合约余额耗尽后订单不再被触发，托管的代币不受影响，所有者始终可以取消取回。
- **订单簿可以被多个地址占满。** 单地址上限 3 张、有效期上限 30 天，但 4 个地址就能占满 10 个位置，没有最小下单金额，也没有管理员清理的途径。
- **止损不是保证成交价的。** 它是"价格到了就按市价卖"。
- 池子流动性太薄、吃不下整笔卖单时，订单会一直失败，直到所有者取消。
- reactive 合约里的订单状态完全依赖事件投递。事件永久丢失时订单会失去监控（代币仍然安全，可以取消或过期取回），这一版没有对账或重新同步的途径。
- **过期关闭的 callback 丢失，或 Lasna 的时钟比 Unichain Sepolia 快出 60 秒以上时，订单会留在金库里却没人监控。** reactive 合约发出过期请求后立刻停止跟踪这张订单；如果这个 callback 没送到，或者送到时金库那边还没过期（金库会忽略它），订单在金库里仍是活跃的：止损不再触发，代币不会自动退回，它占用的订单位置也不会释放，直到有人调用 `reclaimExpired`。这一版没有自动补救。
- **创建事件比之后的 swap 晚到时，这些 swap 设下的最高价会丢失。** reactive 合约只用位置在创建之后、且晚于已处理过的最新一笔的 swap。如果创建事件晚到，期间已经被处理掉的 swap 不会再对这张订单起作用，移动止损的最高价从下单价开始算，可能比真实的最高价低，于是该卖的时候没卖。

### Phase 2 的实测数字（Foundry，fork 或模拟环境，不是真实链上交易）
- `vault.execute` 一次止损成交：191,224 gas（不跨 tick）。
- 全链路测试里最大的一次 callback：190,854 gas（金库卖出时附近叠了十个窄区间，但 100 个代币的卖单没有穿过它们）。
- `react`，10 张订单都不触发：134,894 gas。
- `react`，10 张订单、其中 4 张触发：212,661 gas。这个数字用的是一个"每次请求发一个事件"的假系统合约，真实系统合约的开销未知，上测试网后要重新量。
- reactive 合约最多可以同时跟踪 20 张订单。审查方用同一个假系统合约量过 20 张时的 `react`：20 张的最高价都移动、都不触发 288,192 gas；4 张触发 264,144 gas；4 张过期 416,599 gas。都低于 900,000，但这几个数字不在本仓库的测试里，真实系统合约的开销同样未知。

### 守卫的变异检查（11/12，逐行删除后跑全部测试）
要检查的行是用正则从源码里搜出来的，不是手工挑的：所有 `revert`、所有提前 `return`、以及几处关键的赋值。
- `src/OrderVault.sol`：32 处。31 处删除后有测试失败；1 处（未知触发类型后的 `return`）最初没有测试覆盖，删掉它会让未知类型被当成移动止损卖出，已补测试 `test_execute_unknownSideNeverSellsEvenWithAValidTrailingLevel`，现在 32 处都有测试失败。
- `src/OcoReactive.sol`：35 处。30 处删除后有测试失败；3 处（事件 topic 数量检查两处、失败事件对未跟踪订单的检查一处）最初没有覆盖，已补测试，现在有测试失败；1 处是到不了的死代码，已删除；1 处（处理完 swap 后的 `return`）删掉后行为不变，因为后面的金库地址检查同样会返回，所以没有测试能区分，保留。
- 第二轮审查（独立审查方自己跑了一遍，范围更大：reactive 42 处、金库 54 处）又找到 3 处没有测试覆盖：过期请求计入每笔交易的触发上限（删掉后 20 张过期订单会在一笔交易里发出 20 个 callback）、金库的两个只读函数。已补测试，三处删除后都有测试失败。同时修了审查方发现的"同一个失败事件重复投递会多次退还触发次数"，改为按事件位置去重，删除去重代码的两行后都有测试失败。

### 上测试网时要确认的事（11/12 第一条真实止损链路的结果）
已确认（证据见 `docs/tx-hashes.md`）：
- 真实 Swap 日志送到 `react()` 时 `opCode` 等于 3，数据长度也对：reactive 合约据此发出了 callback。
- `LogRecord.blockNumber` 和 `logIndex` 是源链上的区块号和区块内日志序号（订单创建位置解码为区块 67637067、序号 2，正是 `OrderCreated` 发出的位置）。严格递增这一点，目前只有"一笔订单创建、一笔 swap"的样本，没有发现反例。
- Lasna 上的 `block.timestamp` 跟随真实时间，与 Unichain Sepolia 的区块时间相差约 1 秒以内。
- 一次触发的真实 `react()` 用 129,712 gas；真实 callback 交易总共用 205,055 gas（含 proxy 自己的开销，是 `execute` 的上限）。

还没确认的：
- `react()` 同时触发多张订单时在真实系统合约上的 gas。
- proxy 实际为自己扣留多少 gas：这次 callback 远低于限额，没有触及，所以没有测出。

以下是上线前的原始清单，保留作记录：
- 真实 Swap 日志送到 `react()` 时 `opCode` 是否等于 3。
- `LogRecord.blockNumber` 和 `logIndex` 是否是源链上的区块号和区块内的日志序号，并且严格递增。合约用它们判断事件先后。如果不是，后果比"迟到处理失效"严重：区块号和序号都是 0 时所有 swap 都会被忽略，订单永远不触发；序号恒为 0 时同一区块里的第二笔 swap 会被忽略。第一次上测试网时要把前几笔真实 swap 送到 `react()` 时的这两个原始值记录下来。
- Lasna 上 `block.timestamp` 是否跟随真实时间。冷却、超时、窗口和过期宽限都依赖它。
- 真实 callback 的 gas 用量，以及 proxy 实际扣留多少。
- 真实系统合约上一笔触发 4 张订单的 `react` 用多少 gas。
- 补上 v4 试验留下的"真实 swap 交易"哈希。

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
