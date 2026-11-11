# TRD — 技术设计

## 技术栈和理由
- **合约**：Solidity ^0.8.29 + Foundry。Reactive 官方文档和 demo 都用这套，`forge` / `cast` 可直接用于 Lasna。
- **Reactive 侧**：Reactive Omni（Lasna 测试网，Chain ID 5318007）。赛道要求；约 1 秒出块、即时最终性。基类来自 `Reactive-Network/reactive-lib-omni` v0.1.0（不是旧的 `reactive-lib`）。
- **源链和目标链**：Unichain Sepolia（Chain ID 1301）。赛道指定链，1 秒出块，有官方 Uniswap v4 部署。
- **DEX**：Uniswap v4。官方 demo 已做过 V2 止损，v4 是差异点；`Swap` 事件按 poolId 索引，适合精确订阅。
- **延迟工具**：TypeScript + viem（Node 22）。
- **网页**（可砍）：单页静态页面 + viem，不需要后端。
- **数据库**：无。状态全在链上。
- **部署**：Foundry 脚本；合约在 Sourcify 验证。

## 架构
```
Unichain Sepolia                    Lasna                         Unichain Sepolia
PoolManager  --Swap(poolId)-->   OcoReactive.react()  --callback-->  OrderVault.execute()
OrderVault   --OrderCreated/
               Cancelled/Executed-->
```
- `OrderVault`（目标链，继承 `AbstractCallback`）：托管代币，记录订单，收到 callback 后复核价格并在 v4 上卖出，结算给用户。
- `OcoReactive`（Lasna，继承 `AbstractReactive`）：订阅金库的生命周期事件和池子的 `Swap` 事件；保存活跃订单；每次 Swap 判断是否触线，更新移动止损的最高价；触线时请求 callback，并标记订单为待确认以防重复触发。
- 部署顺序：先 `OcoReactive`，再 `OrderVault`（构造时传 callback proxy 和 reactive 地址，不可改），最后在 `OcoReactive` 上回填金库地址。

## API / 对外接口
`OrderVault`：
| 函数 | 输入 | 谁能调用 |
|---|---|---|
| `createOrder` | 池子、卖出数量、止损 tick、止盈 tick、移动止损距离、过期时间戳 | 任何人（为自己下单） |
| `cancelOrder` | 订单 id | 订单所有者 |
| `reclaimExpired` | 订单 id | 订单所有者 |
| `execute` | reactive 地址（由网络填入）、订单 id、触发方向 | 只有 callback proxy，且来源必须是指定的 reactive 合约 |
| `coverDebt` | 无 | 任何人 |

`OcoReactive`：
| 函数 | 输入 | 谁能调用 |
|---|---|---|
| `react` | `LogRecord` | 只有系统合约 |
| `setVault` | 金库地址 | owner，只能设一次 |
| `coverDebt` | 无 | 任何人 |

事件：`OrderCreated`、`OrderCancelled`、`OrderExecuted`（含成交时间戳）。

具体签名在第 1 周核实 v4 接口后定稿并更新本节。

## 第三方服务和密钥
- RPC：Lasna `https://lasna-rpc.rnk.dev/`；Unichain Sepolia 公共 RPC。地址放 `.env`。
- 部署私钥：只放本地 `.env`（已在 `.gitignore`），仓库里只有 `.env.example` 占位。使用只装测试币的专用钱包。
- 链上地址（公开，不是密钥）：系统合约 `0x8888888888888888888888888888888888888888`；Unichain Sepolia callback proxy `0x775c9B990ADe401060B78D0e98684eEf8d2466C1`；v4 PoolManager `0x00b036b58a818b1bc34d502d3fe730db729e62ac`；StateView `0xc199f1072a74d4e905aba1a84d9a45e2546b6222`。

## 约束
- **期限**：2026-12-06 04:00 截止（时区待确认），按 12 月 4 日提交排期；11 月 30 日功能冻结。
- **Execution 门槛**：链上必须有 reactive 交易和它触发的 callback，否则不计分。
- **计时**：一律用 `block.timestamp`，不用区块数；测试用 `vm.warp`。
- **Reactive 限制**：订阅只能精确匹配；reactive 交易 gas 上限 900,000，所以活跃订单数设上限；callback gas 最低 100,000；payload 第一个参数必须是 `address(0)` 占位；合约有任何欠款就收不到事件；失败的 react 和 callback 照样收费，所以不匹配的日志直接返回，不 revert。
- **安全**：`execute` 必须同时有 `onlyServiceProvider` 和 `onlyCallbackSender`；成交前在链上复核价格并设最小成交量；外部调用前先改状态。
- **规则**：所有代码在活动期内新写；`reactive-lib`、`v4-core`、`v4-periphery`、`forge-std`、OpenZeppelin 只作依赖；不复制官方 demo 代码。
- **预算**：只用测试币。
