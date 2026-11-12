// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";

/// @title OcoReactive
/// @notice Reactive Network half of the OCO order system. Mirrors the vault's active orders from
///         its events, watches every swap in the pool, and asks for a callback to the vault the
///         moment an order's stop, take-profit or trailing-stop level is reached.
/// @dev All price logic uses "normalized ticks": the pool tick when the order sells currency0 and
///      its negation when it sells currency1, so higher is always better for the seller. The
///      trailing-stop peak exists only here. Timers use `block.timestamp` of Reactive Network.
contract OcoReactive is AbstractReactive {
    // ----------------------------------------------------------------- errors

    /// @notice The caller is not the owner.
    error NotOwner();
    /// @notice The vault has already been set and cannot be changed.
    error VaultAlreadySet();
    /// @notice A required address is zero.
    error ZeroAddress();

    // ----------------------------------------------------------------- events

    /// @notice Emitted once, when the vault is set and its events are subscribed to.
    event VaultSet(address indexed vault);
    /// @notice Emitted when an order starts being tracked.
    event OrderTracked(uint256 indexed id);
    /// @notice Emitted when an order stops being tracked.
    event OrderUntracked(uint256 indexed id);
    /// @notice Emitted when a callback is requested for an order.
    /// @param id Order id.
    /// @param side 1 stop, 2 take-profit, 3 trailing stop, 4 expiry.
    /// @param nTick Normalized tick of the swap that caused the trigger.
    /// @param nThreshold Normalized level that was crossed.
    event Triggered(uint256 indexed id, uint8 side, int24 nTick, int24 nThreshold);
    /// @notice Emitted when an order has used its trigger attempts for the current window. It is
    ///         triggered again once the window has passed.
    event TriggerAttemptsExhausted(uint256 indexed id);
    /// @notice Emitted when an order could not be tracked because the book is full.
    event OrderDropped(uint256 indexed id);
    /// @notice Emitted when the owner withdraws native funds.
    event Withdrawn(address indexed to, uint256 amount);

    // -------------------------------------------------------------- constants

    /// @notice topic0 of the v4 PoolManager `Swap` event.
    uint256 public constant SWAP_TOPIC_0 =
        uint256(keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"));
    /// @notice topic0 of the vault's `OrderCreated` event.
    uint256 public constant ORDER_CREATED_TOPIC_0 = uint256(
        keccak256("OrderCreated(uint256,address,bool,uint128,bool,int24,bool,int24,uint24,uint64,int24)")
    );
    /// @notice topic0 of the vault's `OrderCancelled` event.
    uint256 public constant ORDER_CANCELLED_TOPIC_0 = uint256(keccak256("OrderCancelled(uint256)"));
    /// @notice topic0 of the vault's `OrderExpired` event.
    uint256 public constant ORDER_EXPIRED_TOPIC_0 = uint256(keccak256("OrderExpired(uint256)"));
    /// @notice topic0 of the vault's `OrderExecuted` event.
    uint256 public constant ORDER_EXECUTED_TOPIC_0 =
        uint256(keccak256("OrderExecuted(uint256,uint8,uint256,int24,uint256)"));
    /// @notice topic0 of the vault's `OrderExecutionFailed` event.
    uint256 public constant ORDER_FAILED_TOPIC_0 =
        uint256(keccak256("OrderExecutionFailed(uint256,uint8,bytes)"));

    /// @notice Trigger side: fixed stop-loss.
    uint8 public constant SIDE_STOP = 1;
    /// @notice Trigger side: take-profit.
    uint8 public constant SIDE_TAKE_PROFIT = 2;
    /// @notice Trigger side: trailing stop.
    uint8 public constant SIDE_TRAILING = 3;
    /// @notice Trigger side: order past its expiry.
    uint8 public constant SIDE_EXPIRE = 4;
    /// @notice Selector of the vault's `PriceNotAtTrigger(int24)` failure reason.
    bytes4 public constant PRICE_NOT_AT_TRIGGER = bytes4(keccak256("PriceNotAtTrigger(int24)"));

    /// @notice Gas limit requested for each callback.
    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;
    /// @notice Most orders tracked at once. Twice the vault's `MAX_ACTIVE_ORDERS`, so that a
    ///         creation delivered before the closing event of an older order still finds a slot.
    uint256 public constant MAX_TRACKED_ORDERS = 20;
    /// @notice Seconds to wait for the vault's answer before an order may be triggered again.
    uint64 public constant PENDING_TIMEOUT = 120;
    /// @notice Seconds to wait before retrying after the vault reports a failed execution.
    uint64 public constant RETRY_COOLDOWN = 30;
    /// @notice Triggers an order may receive within one `ATTEMPT_WINDOW`, to bound callback
    ///         spending. Expiry requests do not count.
    uint8 public constant MAX_ATTEMPTS = 5;
    /// @notice Length in seconds of the window over which `MAX_ATTEMPTS` is counted. When it has
    ///         passed the count starts again, so no order is ever disabled for good.
    uint64 public constant ATTEMPT_WINDOW = 1 hours;
    /// @notice Most callbacks requested from a single reactive transaction.
    uint256 public constant MAX_TRIGGERS_PER_REACT = 4;
    /// @notice Seconds past expiry before an expiry callback is requested, covering clock
    ///         differences between Reactive Network and the destination chain.
    uint64 public constant EXPIRY_GRACE = 60;

    // ------------------------------------------------------------------ state

    /// @notice Tracked copy of a vault order. `n*` fields are normalized ticks.
    struct Tracked {
        bool active;
        bool zeroForOne;
        bool useStop;
        bool useTakeProfit;
        int24 nStop;
        int24 nTakeProfit;
        int24 nPeak;
        uint24 trailingDistance;
        uint64 expiry;
        uint64 notBefore;
        uint64 windowStart;
        uint8 attempts;
        uint128 createdPos;
        uint128 lastFailedPos;
    }

    /// @notice Account allowed to set the vault.
    address public immutable OWNER;
    /// @notice Chain the pool and the vault live on.
    uint256 public immutable ORIGIN_CHAIN_ID;
    /// @notice Uniswap v4 PoolManager on the origin chain.
    address public immutable POOL_MANAGER;
    /// @notice Id of the watched pool.
    uint256 public immutable POOL_ID;

    /// @notice The order vault on the origin chain. Zero until set.
    address public vault;

    /// @notice Tracked orders by id.
    mapping(uint256 id => Tracked) public tracked;
    uint256[] internal _activeIds;
    mapping(uint256 id => uint256) internal _indexPlusOne;
    /// @notice Ids the vault has reported closed. Ids are never reused, so these are never tracked
    ///         again, whatever order their events arrive in.
    mapping(uint256 id => bool) public closed;
    /// @notice Position (block number and log index) of the newest swap processed. Older swaps
    ///         arriving late are ignored.
    uint128 public lastSwapPos;

    /// @param originChainId_ Chain id of the chain with the pool and the vault.
    /// @param poolManager_ Uniswap v4 PoolManager on that chain.
    /// @param poolId_ Id of the pool to watch.
    /// @dev Payable so the contract can be funded at deployment. Subscribes to the pool's swaps
    ///      here; the vault's events are subscribed to in `setVault`.
    constructor(uint256 originChainId_, address poolManager_, bytes32 poolId_) payable {
        if (poolManager_ == address(0)) revert ZeroAddress();
        OWNER = msg.sender;
        ORIGIN_CHAIN_ID = originChainId_;
        POOL_MANAGER = poolManager_;
        POOL_ID = uint256(poolId_);

        SYSTEM.subscribe(
            originChainId_, poolManager_, SWAP_TOPIC_0, uint256(poolId_), REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    /// @notice Sets the vault and subscribes to its order events. Once, by the owner.
    /// @dev A wrong address cannot be corrected: redeploy both contracts.
    /// @param vault_ Address of `OrderVault` on the origin chain.
    function setVault(address vault_) external {
        if (msg.sender != OWNER) revert NotOwner();
        if (vault != address(0)) revert VaultAlreadySet();
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
        emit VaultSet(vault_);

        _subscribeVault(vault_, ORDER_CREATED_TOPIC_0);
        _subscribeVault(vault_, ORDER_CANCELLED_TOPIC_0);
        _subscribeVault(vault_, ORDER_EXPIRED_TOPIC_0);
        _subscribeVault(vault_, ORDER_EXECUTED_TOPIC_0);
        _subscribeVault(vault_, ORDER_FAILED_TOPIC_0);
    }

    /// @inheritdoc IReactive
    /// @dev Logs that do not match fall through without reverting: a revert is still billed.
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.chainId != ORIGIN_CHAIN_ID) return;

        if (log_.contractAddress == POOL_MANAGER) {
            // Swap has two indexed parameters (pool id, sender) and six data words.
            if (log_.topic0 != SWAP_TOPIC_0 || log_.opCode != 3) return;
            if (log_.topic1 != POOL_ID || log_.data.length != 192) return;
            (,,,, int24 tick,) = abi.decode(log_.data, (int128, int128, uint160, uint128, int24, uint24));
            _onSwap(tick, _position(log_));
            return;
        }

        address vault_ = vault;
        if (vault_ == address(0) || log_.contractAddress != vault_) return;

        uint256 topic0 = log_.topic0;
        if (topic0 == ORDER_CREATED_TOPIC_0) {
            // Two indexed parameters: id and owner.
            if (log_.opCode != 3 || log_.data.length != 288) return;
            _track(log_.topic1, log_.data, _position(log_));
        } else if (
            topic0 == ORDER_CANCELLED_TOPIC_0 || topic0 == ORDER_EXPIRED_TOPIC_0
                || topic0 == ORDER_EXECUTED_TOPIC_0
        ) {
            if (log_.opCode != 2) return;
            closed[log_.topic1] = true;
            _untrack(log_.topic1);
        } else if (topic0 == ORDER_FAILED_TOPIC_0) {
            if (log_.opCode != 2) return;
            _onFailed(log_.topic1, log_.data, _position(log_));
        }
    }

    /// @dev The vault could not sell. Wait before retrying. If the reason is only that the price
    ///      had already moved back, the attempt is not counted: otherwise anyone could disable an
    ///      order by pushing the price through its level and back a few times.
    ///      Each failure event is applied once: a copy delivered again, or an older one delivered
    ///      late, is ignored, so it cannot hand back attempts it did not use.
    function _onFailed(uint256 id_, bytes calldata data_, uint128 pos_) internal {
        Tracked storage t = tracked[id_];
        if (!t.active) return;
        if (pos_ <= t.lastFailedPos) return;
        t.lastFailedPos = pos_;
        t.notBefore = uint64(block.timestamp) + RETRY_COOLDOWN;

        // data = abi.encode(uint8 side, bytes reason): two head words, a length word, the bytes.
        if (data_.length < 128 || t.attempts == 0) return;
        (, bytes memory reason) = abi.decode(data_, (uint8, bytes));
        if (reason.length >= 4 && bytes4(reason) == PRICE_NOT_AT_TRIGGER) t.attempts--;
    }

    /// @notice Settles outstanding debt to the system contract from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Withdraws native funds held by this contract. Owner only.
    /// @param amount_ Amount to send to the owner.
    function withdraw(uint256 amount_) external {
        if (msg.sender != OWNER) revert NotOwner();
        emit Withdrawn(msg.sender, amount_);
        _pay(payable(msg.sender), amount_);
    }

    /// @notice Tracked state of an order.
    /// @param id_ Order id.
    /// @return The tracked record; `active` is false for an id that is not tracked.
    function getTracked(uint256 id_) external view returns (Tracked memory) {
        return tracked[id_];
    }

    /// @notice Ids of the orders currently tracked.
    /// @return The ids, in no particular order.
    function activeIds() external view returns (uint256[] memory) {
        return _activeIds;
    }

    // --------------------------------------------------------------- internal

    function _subscribeVault(address vault_, uint256 topic0_) internal {
        SYSTEM.subscribe(ORIGIN_CHAIN_ID, vault_, topic0_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @dev Position of a log on the origin chain: block number in the high half, log index in
    ///      the low half, so positions compare in emission order.
    function _position(LogRecord calldata log_) internal pure returns (uint128) {
        return (uint128(uint64(log_.blockNumber)) << 64) | uint128(uint64(log_.logIndex));
    }

    function _track(uint256 id_, bytes calldata data_, uint128 pos_) internal {
        if (tracked[id_].active || closed[id_]) return;
        if (_activeIds.length >= MAX_TRACKED_ORDERS) {
            emit OrderDropped(id_);
            return;
        }
        (
            bool zeroForOne,,
            bool useStop,
            int24 nStop,
            bool useTakeProfit,
            int24 nTakeProfit,
            uint24 trailingDistance,
            uint64 expiry,
            int24 nAtCreation
        ) = abi.decode(data_, (bool, uint128, bool, int24, bool, int24, uint24, uint64, int24));

        tracked[id_] = Tracked({
            active: true,
            zeroForOne: zeroForOne,
            useStop: useStop,
            useTakeProfit: useTakeProfit,
            nStop: nStop,
            nTakeProfit: nTakeProfit,
            nPeak: nAtCreation,
            trailingDistance: trailingDistance,
            expiry: expiry,
            notBefore: 0,
            windowStart: 0,
            attempts: 0,
            createdPos: pos_,
            lastFailedPos: 0
        });
        _activeIds.push(id_);
        _indexPlusOne[id_] = _activeIds.length;
        emit OrderTracked(id_);
    }

    function _untrack(uint256 id_) internal {
        uint256 indexPlusOne = _indexPlusOne[id_];
        if (indexPlusOne == 0) return;
        uint256 lastId = _activeIds[_activeIds.length - 1];
        if (lastId != id_) {
            _activeIds[indexPlusOne - 1] = lastId;
            _indexPlusOne[lastId] = indexPlusOne;
        }
        _activeIds.pop();
        delete _indexPlusOne[id_];
        delete tracked[id_];
        emit OrderUntracked(id_);
    }

    /// @dev Checks every tracked order against the post-swap tick. At most
    ///      `MAX_TRIGGERS_PER_REACT` callbacks are requested per call so the transaction stays
    ///      under the reactive gas cap; orders left over fire on the next swap in the pool, and
    ///      each sale the vault makes is itself such a swap.
    /// @param tick_ Pool tick after the swap.
    /// @param pos_ Position of the swap log on the origin chain.
    function _onSwap(int24 tick_, uint128 pos_) internal {
        // Swaps can be delivered late. One older than a swap already processed says nothing about
        // the current price, and a repeat of the same swap must not count twice.
        if (pos_ <= lastSwapPos) return;
        lastSwapPos = pos_;

        uint256 triggers;
        uint256 i;
        while (i < _activeIds.length) {
            uint256 id = _activeIds[i];
            Tracked storage t = tracked[id];
            // A swap from before the order existed must not move its peak or trigger it.
            if (pos_ < t.createdPos) {
                i++;
                continue;
            }
            int24 n = t.zeroForOne ? tick_ : -tick_;

            // The peak keeps moving even while a callback is pending.
            if (t.trailingDistance != 0 && n > t.nPeak) t.nPeak = n;

            if (triggers == MAX_TRIGGERS_PER_REACT || block.timestamp < t.notBefore) {
                i++;
                continue;
            }
            (uint8 side, int24 threshold) = _evaluate(t, n);
            if (side == 0) {
                i++;
                continue;
            }

            if (side == SIDE_EXPIRE) {
                // Ask the vault to refund, then stop tracking: an expired order can never sell,
                // and anyone can call `reclaimExpired` on the vault if this callback is lost.
                // Not subject to the attempt limit. `i` is not advanced because untracking moves
                // the last id into this slot.
                triggers++;
                emit Triggered(id, side, n, threshold);
                _requestExecute(id, side, threshold);
                closed[id] = true;
                _untrack(id);
                continue;
            }

            bool newWindow = block.timestamp >= uint256(t.windowStart) + ATTEMPT_WINDOW;
            if (!newWindow && t.attempts >= MAX_ATTEMPTS) {
                i++;
                continue;
            }
            if (newWindow) {
                t.windowStart = uint64(block.timestamp);
                t.attempts = 1;
            } else {
                t.attempts++;
            }
            if (t.attempts == MAX_ATTEMPTS) emit TriggerAttemptsExhausted(id);

            triggers++;
            t.notBefore = uint64(block.timestamp) + PENDING_TIMEOUT;
            emit Triggered(id, side, n, threshold);
            _requestExecute(id, side, threshold);
            i++;
        }
    }

    /// @dev Returns the side that fired and the level crossed, or side 0 for none.
    function _evaluate(Tracked storage t_, int24 n_) internal view returns (uint8 side, int24 threshold) {
        if (block.timestamp > uint256(t_.expiry) + EXPIRY_GRACE) return (SIDE_EXPIRE, 0);

        if (t_.useTakeProfit && n_ >= t_.nTakeProfit) return (SIDE_TAKE_PROFIT, t_.nTakeProfit);

        bool hasLevel = t_.useStop;
        int256 level = t_.nStop;
        side = SIDE_STOP;
        if (t_.trailingDistance != 0) {
            int256 trailing = int256(t_.nPeak) - int256(uint256(t_.trailingDistance));
            // Never at or above the take-profit: the vault rejects such a level, and a price that
            // has been past the take-profit and is falling back should still sell.
            if (t_.useTakeProfit && trailing >= t_.nTakeProfit) trailing = int256(t_.nTakeProfit) - 1;
            if (!hasLevel || trailing > level) {
                level = trailing;
                side = SIDE_TRAILING;
            }
            hasLevel = true;
        }
        if (!hasLevel || int256(n_) > level) return (0, 0);
        // Safe: here n_ <= level, and level never exceeds a stored int24, so it fits int24.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (side, int24(level));
    }

    function _requestExecute(uint256 id_, uint8 side_, int24 threshold_) internal {
        // The first argument is a placeholder the network replaces with this contract's address.
        bytes memory payload = abi.encodeWithSignature(
            "execute(address,uint256,uint8,int24)", address(0), id_, side_, threshold_
        );
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: ORIGIN_CHAIN_ID, recipient: vault, gasLimit: CALLBACK_GAS_LIMIT, payload: payload
            })
        );
    }
}
