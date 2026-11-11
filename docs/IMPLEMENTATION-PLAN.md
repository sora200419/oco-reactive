# IMPLEMENTATION PLAN — 实施计划

规则：一次做一步，做完跑测试再勾选。每一步要小到一次对话能做完并验证。

## Phase 1：环境与最小闭环（11/10–11/16），过 Execution 门槛
- [x] 安装 Foundry。验证：`forge --version` 输出 1.9.0。
- [x] 新建仓库文件夹，放入文档模板，`git init`。验证：`git status` 正常。
- [x] 填好 4 份核心文档。验证：`node .claude/hooks/doc-gate.js --check` 通过（11/10 已通过）。
- [x] 核实 Omni 库：是 `Reactive-Network/reactive-lib-omni`（tag v0.1.0，提交 3ade0dc），含 `src/base/AbstractReactive.sol`、`onlySystem`、`requestCallbackV_1_0`。旧的 `reactive-lib` 和官方 demo 仓库都还是旧版写法，不能用。
- [x] 【负责人】确认 PRD 内容（11/10 已确认）。
- [x] Foundry 工程骨架、`.gitignore`、`.env.example`、MIT 许可，安装 `reactive-lib-omni`（remapping `@reactive/=lib/reactive-lib-omni/`）。验证：`forge build` 成功。
- [x] 最小闭环合约：源链 `Ping` 事件 → `PingReactive` → `PongCallback`，带测试。验证：`forge test` 通过。
- [x] 部署脚本（Lasna、Unichain Sepolia）。验证：`test/LoopScripts.t.sol` 在进程内跑脚本并检查接线和错链保护。没有在 anvil 或测试网上真实广播过（anvil 上没有系统合约，脚本跑不了），第一次真实运行就是上测试网那一步。
- [x] 【负责人】领测试 ETH，换 lREACT，导入 Foundry keystore（11/11 完成；没有建 `.env`，直接加载 `.env.example`）。
- [ ] 【负责人】建公开 GitHub 仓库并推送。
- [x] 测试网跑通最小闭环，三笔交易哈希记入 `docs/tx-hashes.md`（11/11）。验证：三笔交易都从链上读回，`pongCount()` 为 1，源事件到 callback 用时 2 秒。`getCallbacks` 返回空数组，原因未明，改用合约事件对应三笔交易。
- [ ] v4 试验：从 v4-core 源码确认 `Swap` 事件签名；建测试代币和池子；从合约里完成一次 swap。验证：测试网上有成功的 swap 交易。
- [ ] 11/16 决策：v4 合约内 swap 可行则继续，否则改为自部署 V2 式池子，并更新 TRD。

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
- v4 `Swap` 事件布局和合约内 swap 的做法尚未核实；有 V2 式池子作退路。
- Lasna 到 Unichain Sepolia 的真实延迟未知；若远高于预期，README 如实写并分析各段耗时。
- 官方 demo 已有 V2 止损/止盈，本项目必须靠 v4、OCO、移动止损和延迟数据体现差异。
- 仓库路径含空格并在 OneDrive 下，可能让工具出问题；出问题就把仓库移到无空格的本地路径。
