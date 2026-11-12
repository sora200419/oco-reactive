// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {V4Swapper} from "./v4/V4Swapper.sol";

/// @title OrderVault
/// @notice Holds tokens for OCO sell orders on one Uniswap v4 pool and sells them when the paired
///         reactive contract reports that a stop, take-profit or trailing-stop level was reached.
/// @dev Destination-chain half of the system. Prices are handled as "normalized ticks": the pool
///      tick when the order sells currency0 and its negation when it sells currency1, so a higher
///      normalized tick is always a better price for the seller. All deadlines use
///      `block.timestamp`.
contract OrderVault is AbstractCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ------------------------------------------------------------------ types

    /// @notice Lifecycle of an order.
    enum Status {
        None,
        Active,
        Executed,
        Cancelled,
        Expired
    }

    /// @notice Arguments of `createOrder`. Ticks are raw pool ticks.
    /// @param zeroForOne True to sell currency0 for currency1, false for the reverse.
    /// @param amountIn Amount of the sold token to escrow.
    /// @param useStop Whether a fixed stop-loss level is set.
    /// @param stopTick Pool tick of the stop-loss; must be on the losing side of the current tick.
    /// @param useTakeProfit Whether a take-profit level is set.
    /// @param takeProfitTick Pool tick of the take-profit; must be on the winning side.
    /// @param trailingDistance Trailing-stop distance in ticks, zero to disable.
    /// @param minAmountOut Absolute floor on the output, zero for none.
    /// @param maxSlippageBps Largest accepted shortfall against the pool's spot price at execution,
    ///        in basis points. 10000 disables the check.
    /// @param expiry Timestamp after which the order no longer executes.
    struct OrderParams {
        bool zeroForOne;
        uint128 amountIn;
        bool useStop;
        int24 stopTick;
        bool useTakeProfit;
        int24 takeProfitTick;
        uint24 trailingDistance;
        uint128 minAmountOut;
        uint16 maxSlippageBps;
        uint64 expiry;
    }

    /// @notice Stored order. `n*` fields are normalized ticks.
    struct Order {
        address owner;
        uint64 expiry;
        Status status;
        bool zeroForOne;
        bool useStop;
        bool useTakeProfit;
        int24 nStop;
        int24 nTakeProfit;
        int24 nAtCreation;
        uint24 trailingDistance;
        uint16 maxSlippageBps;
        uint128 amountIn;
        uint128 minAmountOut;
    }

    // ----------------------------------------------------------------- errors

    /// @notice The pool uses hooks; only hookless pools are supported.
    error HooksNotSupported();
    /// @notice The pool has not been initialised.
    error PoolNotInitialized();
    /// @notice The caller is not the owner.
    error NotOwner();
    /// @notice The expiry is further away than `MAX_ORDER_DURATION`.
    error ExpiryTooFar();
    /// @notice The caller already has `MAX_ORDERS_PER_OWNER` active orders.
    error TooManyOrdersForOwner();
    /// @notice The order amount is zero.
    error ZeroAmount();
    /// @notice The expiry is not in the future.
    error ExpiryInPast();
    /// @notice The order sets no stop, take-profit or trailing stop.
    error NoTrigger();
    /// @notice The slippage bound is above 100%.
    error SlippageTooHigh();
    /// @notice The trailing distance is larger than the whole tick range.
    error TrailingDistanceTooLarge();
    /// @notice The stop level is not below the current price (in the seller's terms).
    error StopNotBelowPrice(int24 nStop, int24 nNow);
    /// @notice The take-profit level is not above the current price (in the seller's terms).
    error TakeProfitNotAbovePrice(int24 nTakeProfit, int24 nNow);
    /// @notice A tick is outside the range the pool supports.
    error TickOutOfRange();
    /// @notice The vault already holds the maximum number of active orders.
    error TooManyActiveOrders();
    /// @notice The token did not deliver the full amount (fee-on-transfer tokens are unsupported).
    error IncompleteDeposit(uint256 received, uint256 expected);
    /// @notice A token transfer returned false.
    error TokenTransferFailed();
    /// @notice The caller does not own the order.
    error NotOrderOwner();
    /// @notice The order is not active.
    error OrderNotActive();
    /// @notice The order has not expired yet.
    error NotExpired();
    /// @notice A guarded function was re-entered.
    error Reentrancy();
    /// @notice Recorded as the failure reason when the price is no longer at the trigger level.
    error PriceNotAtTrigger(int24 nNow);
    /// @notice Recorded as the failure reason when the callback names an unknown trigger side.
    error UnknownSide(uint8 side);

    // ----------------------------------------------------------------- events

    /// @notice Emitted when an order is created and its tokens are escrowed.
    event OrderCreated(
        uint256 indexed id,
        address indexed owner,
        bool zeroForOne,
        uint128 amountIn,
        bool useStop,
        int24 nStop,
        bool useTakeProfit,
        int24 nTakeProfit,
        uint24 trailingDistance,
        uint64 expiry,
        int24 nAtCreation
    );
    /// @notice Emitted when the owner cancels an order and is refunded.
    event OrderCancelled(uint256 indexed id);
    /// @notice Emitted when an expired order is closed and its owner refunded.
    event OrderExpired(uint256 indexed id);
    /// @notice Emitted when an order is sold.
    /// @param id Order id.
    /// @param side Which trigger fired: 1 stop, 2 take-profit, 3 trailing stop.
    /// @param amountOut Proceeds sent to the owner.
    /// @param nTick Normalized tick observed just before the swap.
    /// @param executedAt `block.timestamp` of the execution.
    event OrderExecuted(uint256 indexed id, uint8 side, uint256 amountOut, int24 nTick, uint256 executedAt);
    /// @notice Emitted when a trigger arrived but the order could not be sold. The order stays
    ///         active and can be triggered again.
    /// @param id Order id.
    /// @param side Trigger side the callback named.
    /// @param reason ABI-encoded error describing why.
    event OrderExecutionFailed(uint256 indexed id, uint8 side, bytes reason);
    /// @notice Emitted when the owner withdraws native funds.
    event Withdrawn(address indexed to, uint256 amount);

    // -------------------------------------------------------------- constants

    /// @notice Trigger side: fixed stop-loss.
    uint8 public constant SIDE_STOP = 1;
    /// @notice Trigger side: take-profit.
    uint8 public constant SIDE_TAKE_PROFIT = 2;
    /// @notice Trigger side: trailing stop.
    uint8 public constant SIDE_TRAILING = 3;
    /// @notice Trigger side: the order is past its expiry and should be closed.
    uint8 public constant SIDE_EXPIRE = 4;

    /// @notice Most orders that can be active at once. Bounded so the reactive contract can scan
    ///         all of them inside one reactive transaction.
    uint256 public constant MAX_ACTIVE_ORDERS = 10;
    /// @notice Most orders one address can have active at once, so a single address cannot fill
    ///         the whole book.
    uint256 public constant MAX_ORDERS_PER_OWNER = 3;
    /// @notice Longest time an order may stay open, so a slot cannot be held forever.
    uint256 public constant MAX_ORDER_DURATION = 30 days;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant FEE_UNITS = 1_000_000;
    int24 internal constant MAX_TICK = 887_272;

    // ------------------------------------------------------------------ state

    /// @notice Uniswap v4 PoolManager.
    IPoolManager public immutable POOL_MANAGER;
    /// @notice Contract that performs the swap against the PoolManager.
    V4Swapper public immutable SWAPPER;
    /// @notice Id of the pool this vault serves.
    PoolId public immutable POOL_ID;

    PoolKey internal _poolKey;

    /// @notice Id the next order will get.
    uint256 public nextOrderId;
    /// @notice Number of orders currently active.
    uint256 public activeOrderCount;
    /// @notice Number of active orders per owner.
    mapping(address owner => uint256) public activeOrdersOf;
    /// @notice Account that deployed the vault and may withdraw its native funds.
    address public immutable OWNER;
    /// @notice Orders by id.
    mapping(uint256 id => Order) public orders;

    bool private _locked;

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    /// @param callbackProxy_ Reactive callback proxy on this chain.
    /// @param reactive_ Address of the paired `OcoReactive` on Reactive Network. Immutable.
    /// @param swapper_ Deployed `V4Swapper`; its PoolManager is the one this vault uses.
    /// @param poolKey_ Pool this vault serves. Must have no hooks.
    /// @dev Payable so the vault can be funded for callback fees at deployment.
    constructor(IPayable callbackProxy_, address reactive_, V4Swapper swapper_, PoolKey memory poolKey_)
        payable
        AbstractCallback(callbackProxy_, reactive_)
    {
        if (address(poolKey_.hooks) != address(0)) revert HooksNotSupported();
        SWAPPER = swapper_;
        POOL_MANAGER = swapper_.POOL_MANAGER();
        OWNER = msg.sender;
        _poolKey = poolKey_;
        POOL_ID = poolKey_.toId();
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(POOL_ID);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
    }

    // ------------------------------------------------------------ user actions

    /// @notice Creates an order and escrows the tokens to sell.
    /// @dev The caller must have approved this vault for `amountIn` of the sold token.
    /// @param p_ Order parameters, see `OrderParams`.
    /// @return id Id of the new order.
    function createOrder(OrderParams calldata p_) external nonReentrant returns (uint256 id) {
        if (p_.amountIn == 0) revert ZeroAmount();
        if (p_.expiry <= block.timestamp) revert ExpiryInPast();
        if (p_.expiry > block.timestamp + MAX_ORDER_DURATION) revert ExpiryTooFar();
        if (!p_.useStop && !p_.useTakeProfit && p_.trailingDistance == 0) revert NoTrigger();
        if (p_.maxSlippageBps > BPS) revert SlippageTooHigh();
        if (p_.trailingDistance > uint24(2 * MAX_TICK)) revert TrailingDistanceTooLarge();
        if (activeOrderCount >= MAX_ACTIVE_ORDERS) revert TooManyActiveOrders();
        if (activeOrdersOf[msg.sender] >= MAX_ORDERS_PER_OWNER) revert TooManyOrdersForOwner();

        int24 nNow = _normalizedTickNow(p_.zeroForOne);
        int24 nStop;
        int24 nTakeProfit;
        if (p_.useStop) {
            nStop = _normalize(p_.zeroForOne, p_.stopTick);
            if (nStop >= nNow) revert StopNotBelowPrice(nStop, nNow);
        }
        if (p_.useTakeProfit) {
            nTakeProfit = _normalize(p_.zeroForOne, p_.takeProfitTick);
            if (nTakeProfit <= nNow) revert TakeProfitNotAbovePrice(nTakeProfit, nNow);
        }

        id = nextOrderId++;
        orders[id] = Order({
            owner: msg.sender,
            expiry: p_.expiry,
            status: Status.Active,
            zeroForOne: p_.zeroForOne,
            useStop: p_.useStop,
            useTakeProfit: p_.useTakeProfit,
            nStop: nStop,
            nTakeProfit: nTakeProfit,
            nAtCreation: nNow,
            trailingDistance: p_.trailingDistance,
            maxSlippageBps: p_.maxSlippageBps,
            amountIn: p_.amountIn,
            minAmountOut: p_.minAmountOut
        });
        _occupy(msg.sender);

        _pullDeposit(p_.zeroForOne, p_.amountIn);
        _emitCreated(id);
    }

    function _pullDeposit(bool zeroForOne_, uint256 amount_) internal {
        IERC20Minimal token = _sellToken(zeroForOne_);
        uint256 balanceBefore = token.balanceOf(address(this));
        if (!token.transferFrom(msg.sender, address(this), amount_)) revert TokenTransferFailed();
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        if (received != amount_) revert IncompleteDeposit(received, amount_);
    }

    function _emitCreated(uint256 id_) internal {
        Order storage o = orders[id_];
        emit OrderCreated(
            id_,
            o.owner,
            o.zeroForOne,
            o.amountIn,
            o.useStop,
            o.nStop,
            o.useTakeProfit,
            o.nTakeProfit,
            o.trailingDistance,
            o.expiry,
            o.nAtCreation
        );
    }

    /// @notice Cancels an active order and returns its tokens. Owner only.
    /// @param id_ Order id.
    function cancelOrder(uint256 id_) external nonReentrant {
        Order storage o = orders[id_];
        if (o.owner != msg.sender) revert NotOrderOwner();
        if (o.status != Status.Active) revert OrderNotActive();
        o.status = Status.Cancelled;
        _release(o.owner);
        emit OrderCancelled(id_);
        _refund(o);
    }

    /// @notice Closes an order whose expiry has passed and refunds its owner. Anyone may call.
    /// @param id_ Order id.
    function reclaimExpired(uint256 id_) external nonReentrant {
        Order storage o = orders[id_];
        if (o.status != Status.Active) revert OrderNotActive();
        if (block.timestamp <= o.expiry) revert NotExpired();
        _expire(id_, o);
    }

    // --------------------------------------------------------------- callback

    /// @notice Callback entry point: the reactive contract reports that an order's trigger fired.
    /// @dev Never reverts for order-level reasons, because a reverted callback is still billed and
    ///      would leave the reactive contract waiting. Late or duplicate deliveries are ignored;
    ///      a trigger that can no longer be honoured emits `OrderExecutionFailed` and leaves the
    ///      order active.
    /// @param reactive_ Address of the requesting reactive contract, injected by the network.
    /// @param id_ Order id.
    /// @param side_ Which trigger fired, one of the `SIDE_*` constants.
    /// @param nThreshold_ For a trailing stop, the normalized trailing level the reactive contract
    ///        computed. Ignored for the other sides, which use the levels stored here.
    function execute(address reactive_, uint256 id_, uint8 side_, int24 nThreshold_)
        external
        nonReentrant
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        Order storage o = orders[id_];
        if (o.status != Status.Active) return;

        if (block.timestamp > o.expiry) {
            _expire(id_, o);
            return;
        }
        if (side_ == SIDE_EXPIRE) return;

        int24 nNow = _normalizedTickNow(o.zeroForOne);
        if (side_ != SIDE_STOP && side_ != SIDE_TAKE_PROFIT && side_ != SIDE_TRAILING) {
            emit OrderExecutionFailed(id_, side_, abi.encodeWithSelector(UnknownSide.selector, side_));
            return;
        }
        if (!_triggerHolds(o, side_, nThreshold_, nNow)) {
            emit OrderExecutionFailed(id_, side_, abi.encodeWithSelector(PriceNotAtTrigger.selector, nNow));
            return;
        }

        uint256 minOut = _minAmountOut(o);
        IERC20Minimal token = _sellToken(o.zeroForOne);

        // State first, then the external calls; restored by hand if the swap fails.
        o.status = Status.Executed;
        _release(o.owner);
        if (!token.approve(address(SWAPPER), o.amountIn)) revert TokenTransferFailed();

        try SWAPPER.swapExactIn(_poolKey, o.zeroForOne, o.amountIn, minOut, o.owner) returns (
            uint256 amountOut
        ) {
            emit OrderExecuted(id_, side_, amountOut, nNow, block.timestamp);
        } catch (bytes memory reason) {
            o.status = Status.Active;
            _occupy(o.owner);
            if (!token.approve(address(SWAPPER), 0)) revert TokenTransferFailed();
            emit OrderExecutionFailed(id_, side_, reason);
        }
    }

    /// @notice Settles outstanding debt to the callback proxy from this contract's native balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Withdraws native funds held for callback fees. Owner only. Escrowed tokens are
    ///         ERC-20 and cannot be touched by this.
    /// @param amount_ Amount to send to the owner.
    function withdraw(uint256 amount_) external {
        if (msg.sender != OWNER) revert NotOwner();
        emit Withdrawn(msg.sender, amount_);
        _pay(payable(msg.sender), amount_);
    }

    // ------------------------------------------------------------------ views

    /// @notice The pool this vault serves.
    /// @return The pool key.
    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @notice Full record of an order.
    /// @param id_ Order id.
    /// @return The stored order; `status` is `None` for an id that was never used.
    function getOrder(uint256 id_) external view returns (Order memory) {
        return orders[id_];
    }

    /// @notice Current normalized tick for a given sell direction.
    /// @param zeroForOne_ Sell direction.
    /// @return The pool tick, negated when selling currency1.
    function normalizedTick(bool zeroForOne_) external view returns (int24) {
        return _normalizedTickNow(zeroForOne_);
    }

    // --------------------------------------------------------------- internal

    function _triggerHolds(Order storage o_, uint8 side_, int24 nThreshold_, int24 nNow_)
        internal
        view
        returns (bool)
    {
        if (side_ == SIDE_TAKE_PROFIT) return o_.useTakeProfit && nNow_ >= o_.nTakeProfit;
        if (side_ == SIDE_STOP) return o_.useStop && nNow_ <= o_.nStop;
        // Trailing stop. The peak lives in the reactive contract, so the level is taken from the
        // callback, but it is bounded: never below where a trailing stop started, never at or
        // above the take-profit, and the price must actually be at or below it now.
        if (o_.trailingDistance == 0) return false;
        int256 lowest = int256(o_.nAtCreation) - int256(uint256(o_.trailingDistance));
        if (int256(nThreshold_) < lowest) return false;
        if (o_.useTakeProfit && nThreshold_ >= o_.nTakeProfit) return false;
        return nNow_ <= nThreshold_;
    }

    /// @dev Larger of the owner's absolute floor and the slippage bound against the spot price.
    function _minAmountOut(Order storage o_) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(POOL_ID);
        uint256 quote = o_.zeroForOne
            ? FullMath.mulDiv(FullMath.mulDiv(o_.amountIn, sqrtPriceX96, Q96), sqrtPriceX96, Q96)
            : FullMath.mulDiv(FullMath.mulDiv(o_.amountIn, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
        // The pool takes its fee from the input, so an honest swap never reaches the raw spot
        // quote. Allow for the fee first; the slippage bound then covers price impact only.
        quote = quote * (FEE_UNITS - _poolKey.fee) / FEE_UNITS;
        uint256 bySlippage = quote * (BPS - o_.maxSlippageBps) / BPS;
        return bySlippage > o_.minAmountOut ? bySlippage : o_.minAmountOut;
    }

    function _expire(uint256 id_, Order storage o_) internal {
        o_.status = Status.Expired;
        _release(o_.owner);
        emit OrderExpired(id_);
        _refund(o_);
    }

    function _occupy(address owner_) internal {
        activeOrderCount++;
        activeOrdersOf[owner_]++;
    }

    function _release(address owner_) internal {
        activeOrderCount--;
        activeOrdersOf[owner_]--;
    }

    function _refund(Order storage o_) internal {
        if (!_sellToken(o_.zeroForOne).transfer(o_.owner, o_.amountIn)) revert TokenTransferFailed();
    }

    function _sellToken(bool zeroForOne_) internal view returns (IERC20Minimal) {
        return IERC20Minimal(Currency.unwrap(zeroForOne_ ? _poolKey.currency0 : _poolKey.currency1));
    }

    function _normalizedTickNow(bool zeroForOne_) internal view returns (int24) {
        (, int24 tick,,) = POOL_MANAGER.getSlot0(POOL_ID);
        return zeroForOne_ ? tick : -tick;
    }

    function _normalize(bool zeroForOne_, int24 tick_) internal pure returns (int24) {
        if (tick_ < -MAX_TICK || tick_ > MAX_TICK) revert TickOutOfRange();
        return zeroForOne_ ? tick_ : -tick_;
    }
}
