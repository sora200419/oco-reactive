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
价格一律用"归一化 tick"表示：卖 currency0 的订单用池子的 tick，卖 currency1 的订单用它的相反数。这样数值越大对卖方越有利，止损、止盈、移动止损的判断在两个方向上是同一套逻辑。

`OrderVault`（`src/OrderVault.sol`，Unichain Sepolia，一个金库只服务一个已初始化、不带 hooks 的池子）：
| 函数 | 输入 | 谁能调用 |
|---|---|---|
| `createOrder(OrderParams)` | 方向、卖出数量、是否设止损及其 tick、是否设止盈及其 tick、移动止损距离、绝对最低成交量、相对现价的最大滑点（基点）、过期时间戳 | 任何人（为自己下单，需先授权代币） |
| `cancelOrder(id)` | 订单 id | 订单所有者 |
| `reclaimExpired(id)` | 订单 id | 任何人，但只能在订单过期之后；代币退给所有者 |
| `execute(reactive, id, side, nThreshold)` | reactive 地址（由网络填入）、订单 id、触发方向（1 止损、2 止盈、3 移动止损、4 过期）、移动止损的触发位 | 只有 callback proxy，且来源必须是指定的 reactive 合约 |
| `getOrder(id)`、`poolKey()`、`normalizedTick(方向)`、`activeOrdersOf(地址)` | 只读 | 任何人 |
| `coverDebt()` | 无 | 任何人 |
| `withdraw(amount)` | 取回合约里用于付 callback 费的原生币；碰不到托管的代币 | 部署者 |

事件：`OrderCreated`、`OrderCancelled`、`OrderExpired`、`OrderExecuted`（含成交时间戳）、`OrderExecutionFailed`（含失败原因）。

下单时的限制：
- 每个地址最多 3 张活跃订单（`MAX_ORDERS_PER_OWNER`），全库最多 10 张（`MAX_ACTIVE_ORDERS`）。
- 过期时间必须在将来，且不超过 30 天（`MAX_ORDER_DURATION`）。
- 止损位必须低于现价、止盈位必须高于现价（按归一化 tick）。
- 代币必须足额到账，不支持转账扣费的代币。

`execute` 的行为约定：
- 订单已成交、已取消或已过期关闭时直接返回，不 revert，不产生事件。
- 订单已过期时不卖出，改为关闭订单并把代币退给所有者。
- 价格已不在触发位、或 swap 失败（滑点超限、流动性不足）时，订单保持活跃，发出 `OrderExecutionFailed`。
- 成交是整笔的，不做部分成交。
- 滑点保护取两者中较大的一个：所有者设的绝对最低成交量；按成交前的现价、先扣掉池子手续费、再留出 `maxSlippageBps` 算出的数量。
- 移动止损的最高价只存在于 reactive 合约里，所以触发位由 callback 带过来。金库对它做三项限制：不低于"下单时的价格减去距离"、低于止盈位、当前价格确实不高于它。这三项限制防的是错误的触发位，**防不住价格被人为拉高再砸回**：那种情况下触发位是真实的，订单会按当时的价格卖出。

`OcoReactive`（`src/OcoReactive.sol`，Lasna）：
| 函数 | 输入 | 谁能调用 |
|---|---|---|
| `react(LogRecord)` | 池子的 `Swap` 或金库的五种事件 | 只有系统合约 |
| `setVault(vault)` | 金库地址；同时订阅金库的五种事件 | owner，只能设一次 |
| `activeIds()`、`getTracked(id)`、`closed(id)`、`lastSwapPos()` | 只读 | 任何人 |
| `coverDebt()` | 无 | 任何人 |
| `withdraw(amount)` | 取回合约里的原生币 | owner |

订阅：构造时订阅 PoolManager 的 `Swap`（topic1 固定为 poolId）；`setVault` 时订阅金库的 `OrderCreated`、`OrderCancelled`、`OrderExpired`、`OrderExecuted`、`OrderExecutionFailed`。

对事件迟到和乱序的处理（"位置"指事件在源链上的区块号加日志序号）：
- 位置不晚于"已处理过的最新一笔 swap"的 swap 一律忽略：迟到的旧 swap 不代表现在的价格，重复投递的同一笔 swap 也只算一次。
- 每张订单记下创建事件的位置，位置更早的 swap 对这张订单不起作用，不会移动它的最高价，也不会触发它。
- 反过来，如果创建事件比之后的 swap 晚到，那些已经被处理掉的 swap 不会再补算给这张订单，移动止损的最高价可能低于真实值。
- 每张订单还记下最近一次失败事件的位置，同一个失败事件重复投递或迟到时只处理一次。
- 金库报告过关闭（成交、取消、过期）的订单 id 被记入 `closed`，之后再收到它的创建事件也不会重新跟踪。订单 id 不会重复使用。
- 跟踪上限是金库上限的两倍，这样"新订单的创建事件先到、旧订单的关闭事件后到"时新订单仍有位置。真的满了会发出 `OrderDropped`。

限额和计时（都是合约里的常量）：
| 常量 | 值 | 作用 |
|---|---|---|
| 金库 `MAX_ACTIVE_ORDERS` | 10 | 全库活跃订单上限 |
| 金库 `MAX_ORDERS_PER_OWNER` | 3 | 单个地址的活跃订单上限 |
| 金库 `MAX_ORDER_DURATION` | 30 天 | 订单最长有效期 |
| reactive `MAX_TRACKED_ORDERS` | 20 | 跟踪上限，金库上限的两倍 |
| `MAX_TRIGGERS_PER_REACT` | 4 | 一笔 reactive 交易最多请求的 callback 数，防止超过 900,000 gas 上限；剩下的订单由池子里的下一次 swap 触发，而金库每卖出一笔本身就是一次 swap |
| `PENDING_TIMEOUT` | 120 秒 | 触发后等金库回音的时间，期间不重复触发 |
| `RETRY_COOLDOWN` | 30 秒 | 金库报告失败后多久可以再试 |
| `MAX_ATTEMPTS` / `ATTEMPT_WINDOW` | 5 次 / 1 小时 | 一张订单在一个窗口内最多被触发的次数。金库回报"价格已不在触发位"的那次不计数；swap 失败和没有回音的计数。窗口过后重新计数，所以没有订单会被永久停用。过期关闭的请求不受这个限制 |
| `EXPIRY_GRACE` | 60 秒 | 过期多久后请求关闭订单，用来吸收两条链时钟的差异。请求发出后 reactive 合约就不再跟踪这张订单 |
| `CALLBACK_GAS_LIMIT` | 1,000,000 | 每个 callback 请求的 gas 上限 |

`V4Swapper`（`src/v4/V4Swapper.sol`）：金库通过它换币。
| 函数 | 输入 | 谁能调用 |
|---|---|---|
| `swapExactIn` | 池子、方向、卖出数量、最小成交量、收款人 | 任何人（卖自己授权的代币） |
| `unlockCallback` | PoolManager 传回的数据 | 只有 PoolManager |

v4 的事件格式、正负号和 gas 数据见 `docs/IMPLEMENTATION-PLAN.md` 的"v4 试验结论"。

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
