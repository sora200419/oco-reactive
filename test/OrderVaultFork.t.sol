// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Vm} from "forge-std/Test.sol";

import {OrderVault} from "../src/OrderVault.sol";
import {V4Swapper} from "../src/v4/V4Swapper.sol";
import {V4ForkBase} from "./utils/V4ForkBase.sol";
import {WeirdToken} from "./mocks/WeirdToken.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";
import {MockSystem} from "./mocks/MockSystem.sol";

contract OrderVaultForkTest is V4ForkBase {
    OrderVault internal vault;
    address internal proxy = makeAddr("callbackProxy");
    address internal reactive = makeAddr("reactive");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    uint64 internal constant EXPIRY = uint64(T0 + 1 days);

    /// Non-indexed fields of OrderCreated, in declaration order.
    struct CreatedData {
        bool zeroForOne;
        uint128 amountIn;
        bool useStop;
        int24 nStop;
        bool useTakeProfit;
        int24 nTakeProfit;
        uint24 trailingDistance;
        uint64 expiry;
        int24 nAtCreation;
    }

    event OrderExecuted(uint256 indexed id, uint8 side, uint256 amountOut, int24 nTick, uint256 executedAt);
    event OrderExecutionFailed(uint256 indexed id, uint8 side, bytes reason);
    event OrderCancelled(uint256 indexed id);
    event OrderExpired(uint256 indexed id);

    function setUp() public {
        _setUpPool();
        vault = new OrderVault(IPayable(payable(proxy)), reactive, swapper, key);
        address[4] memory users = [alice, bob, carol, dave];
        for (uint256 i = 0; i < users.length; i++) {
            token0.mint(users[i], 1_000e18);
            token1.mint(users[i], 1_000e18);
            vm.startPrank(users[i]);
            token0.approve(address(vault), type(uint256).max);
            token1.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ---------------------------------------------------------------- helpers

    /// Sell 100 token0 with stop at -120, take-profit at +120, 5% slippage bound.
    function _params() internal pure returns (OrderVault.OrderParams memory p) {
        p = OrderVault.OrderParams({
            zeroForOne: true,
            amountIn: 100e18,
            useStop: true,
            stopTick: -120,
            useTakeProfit: true,
            takeProfitTick: 120,
            trailingDistance: 0,
            minAmountOut: 0,
            maxSlippageBps: 500,
            expiry: EXPIRY
        });
    }

    function _create(OrderVault.OrderParams memory p_) internal returns (uint256 id) {
        vm.prank(alice);
        id = vault.createOrder(p_);
    }

    function _execute(uint256 id_, uint8 side_, int24 threshold_) internal {
        vm.prank(proxy);
        vault.execute(reactive, id_, side_, threshold_);
    }

    function _status(uint256 id_) internal view returns (OrderVault.Status status) {
        status = vault.getOrder(id_).status;
    }

    // ----------------------------------------------------------------- create

    function test_createOrder_escrowsTokensAndStoresNormalizedLevels() public {
        vm.recordLogs();
        uint256 id = _create(_params());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(id, 0);
        assertEq(token0.balanceOf(address(vault)), 100e18);
        assertEq(token0.balanceOf(alice), 900e18);
        assertEq(vault.activeOrderCount(), 1);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));

        // Last log is OrderCreated: 3 topics, 9 data words.
        Vm.Log memory log = logs[logs.length - 1];
        assertEq(log.emitter, address(vault));
        assertEq(log.topics.length, 3);
        assertEq(uint256(log.topics[1]), id);
        assertEq(address(uint160(uint256(log.topics[2]))), alice);
        assertEq(log.data.length, 9 * 32);
        CreatedData memory d = abi.decode(log.data, (CreatedData));
        assertTrue(d.zeroForOne);
        assertEq(d.amountIn, 100e18);
        assertTrue(d.useStop);
        assertEq(d.nStop, -120);
        assertTrue(d.useTakeProfit);
        assertEq(d.nTakeProfit, 120);
        assertEq(d.trailingDistance, 0);
        assertEq(d.expiry, EXPIRY);
        assertEq(d.nAtCreation, 0);
    }

    function test_createOrder_sellingToken1NegatesTicks() public {
        OrderVault.OrderParams memory p = _params();
        p.zeroForOne = false;
        p.stopTick = 120; // token1 loses value as the tick rises
        p.takeProfitTick = -120;
        uint256 id = _create(p);

        OrderVault.Order memory o = vault.getOrder(id);
        assertEq(o.nStop, -120);
        assertEq(o.nTakeProfit, 120);
        assertEq(token1.balanceOf(address(vault)), 100e18);
    }

    function test_createOrder_validations() public {
        OrderVault.OrderParams memory p = _params();
        p.amountIn = 0;
        vm.expectRevert(OrderVault.ZeroAmount.selector);
        _create(p);

        p = _params();
        p.expiry = uint64(T0);
        vm.expectRevert(OrderVault.ExpiryInPast.selector);
        _create(p);

        p = _params();
        p.useStop = false;
        p.useTakeProfit = false;
        vm.expectRevert(OrderVault.NoTrigger.selector);
        _create(p);

        p = _params();
        p.maxSlippageBps = 10_001;
        vm.expectRevert(OrderVault.SlippageTooHigh.selector);
        _create(p);

        p = _params();
        p.stopTick = 0; // equal to the current tick: not below it
        vm.expectRevert(abi.encodeWithSelector(OrderVault.StopNotBelowPrice.selector, int24(0), int24(0)));
        _create(p);

        p = _params();
        p.takeProfitTick = 0;
        vm.expectRevert(
            abi.encodeWithSelector(OrderVault.TakeProfitNotAbovePrice.selector, int24(0), int24(0))
        );
        _create(p);

        p = _params();
        p.stopTick = -887_273;
        vm.expectRevert(OrderVault.TickOutOfRange.selector);
        _create(p);

        p = _params();
        p.trailingDistance = 2 * 887_272 + 1;
        vm.expectRevert(OrderVault.TrailingDistanceTooLarge.selector);
        _create(p);

        assertEq(vault.activeOrderCount(), 0);
        assertEq(token0.balanceOf(alice), 1_000e18);
    }

    function test_createOrder_capsActiveOrdersAcrossOwners() public {
        OrderVault.OrderParams memory p = _params();
        p.amountIn = 1e18;
        address[4] memory users = [alice, bob, carol, dave];
        // 3 + 3 + 3 + 1 fills the ten slots.
        for (uint256 i = 0; i < vault.MAX_ACTIVE_ORDERS(); i++) {
            vm.prank(users[i / 3]);
            vault.createOrder(p);
        }
        vm.expectRevert(OrderVault.TooManyActiveOrders.selector);
        vm.prank(dave);
        vault.createOrder(p);

        // Closing one frees a slot.
        vm.prank(alice);
        vault.cancelOrder(0);
        vm.prank(dave);
        vault.createOrder(p);
        assertEq(vault.activeOrderCount(), vault.MAX_ACTIVE_ORDERS());
    }

    function test_createOrder_capsOrdersPerOwner() public {
        OrderVault.OrderParams memory p = _params();
        p.amountIn = 1e18;
        uint256 perOwner = vault.MAX_ORDERS_PER_OWNER();
        for (uint256 i = 0; i < perOwner; i++) {
            _create(p);
        }
        assertEq(vault.activeOrdersOf(alice), perOwner);

        vm.expectRevert(OrderVault.TooManyOrdersForOwner.selector);
        _create(p);

        // Someone else is not affected, and closing one of alice's frees her quota.
        vm.prank(bob);
        vault.createOrder(p);
        vm.prank(alice);
        vault.cancelOrder(0);
        assertEq(vault.activeOrdersOf(alice), perOwner - 1);
        _create(p);
    }

    function test_ownerQuota_isReleasedOnExecutionAndExpiry() public {
        uint256 a = _create(_params());
        uint256 b = _create(_params());
        assertEq(vault.activeOrdersOf(alice), 2);

        _pushDown(2_000e18);
        _execute(a, 1, 0);
        assertEq(vault.activeOrdersOf(alice), 1, "released on execution");

        vm.warp(EXPIRY + 1);
        vault.reclaimExpired(b);
        assertEq(vault.activeOrdersOf(alice), 0, "released on expiry");
        assertEq(vault.activeOrderCount(), 0);
    }

    function test_ownerQuota_isKeptWhenTheSwapFails() public {
        OrderVault.OrderParams memory p = _params();
        p.maxSlippageBps = 0;
        uint256 id = _create(p);
        _pushDown(2_000e18);
        _execute(id, 1, 0);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));
        assertEq(vault.activeOrdersOf(alice), 1);
        assertEq(vault.activeOrderCount(), 1);
    }

    function test_createOrder_rejectsExpiryBeyondMaxDuration() public {
        OrderVault.OrderParams memory p = _params();
        p.expiry = uint64(T0 + vault.MAX_ORDER_DURATION() + 1);
        vm.expectRevert(OrderVault.ExpiryTooFar.selector);
        _create(p);

        p.expiry = uint64(T0 + vault.MAX_ORDER_DURATION());
        _create(p);
    }

    function test_constructor_rejectsUninitialisedPool() public {
        PoolKey memory other = key;
        other.fee = 500;
        other.tickSpacing = 10; // same tokens, a fee tier nobody initialised
        vm.expectRevert(OrderVault.PoolNotInitialized.selector);
        new OrderVault(IPayable(payable(proxy)), reactive, swapper, other);
    }

    // ------------------------------------------------------------- bad tokens

    function _vaultFor(address token_) internal returns (OrderVault v, bool tokenIsZero) {
        PoolKey memory k;
        (k, tokenIsZero) = _initPoolWith(token_);
        v = new OrderVault(IPayable(payable(proxy)), reactive, swapper, k);
    }

    function _paramsSelling(bool zeroForOne_) internal pure returns (OrderVault.OrderParams memory p) {
        p = _params();
        p.zeroForOne = zeroForOne_;
        p.useTakeProfit = false;
        p.stopTick = zeroForOne_ ? int24(-120) : int24(120);
    }

    function test_createOrder_refusesFeeOnTransferToken() public {
        WeirdToken weird = new WeirdToken();
        (OrderVault v, bool weirdIsZero) = _vaultFor(address(weird));
        weird.mint(alice, 1_000e18);
        vm.prank(alice);
        weird.approve(address(v), type(uint256).max);
        weird.setMode(WeirdToken.Mode.FeeOnTransfer);

        vm.expectRevert(abi.encodeWithSelector(OrderVault.IncompleteDeposit.selector, 99e18, 100e18));
        vm.prank(alice);
        v.createOrder(_paramsSelling(weirdIsZero));

        assertEq(weird.balanceOf(alice), 1_000e18);
        assertEq(v.activeOrderCount(), 0);
    }

    function test_createOrder_refusesTokenThatReturnsFalse() public {
        WeirdToken weird = new WeirdToken();
        (OrderVault v, bool weirdIsZero) = _vaultFor(address(weird));
        weird.mint(alice, 1_000e18);
        vm.prank(alice);
        weird.approve(address(v), type(uint256).max);
        weird.setMode(WeirdToken.Mode.ReturnFalse);

        vm.expectRevert(OrderVault.TokenTransferFailed.selector);
        vm.prank(alice);
        v.createOrder(_paramsSelling(weirdIsZero));
        assertEq(v.activeOrderCount(), 0);
    }

    function test_cancelOrder_revertsWhenRefundTransferFails() public {
        WeirdToken weird = new WeirdToken();
        (OrderVault v, bool weirdIsZero) = _vaultFor(address(weird));
        weird.mint(alice, 1_000e18);
        vm.startPrank(alice);
        weird.approve(address(v), type(uint256).max);
        uint256 id = v.createOrder(_paramsSelling(weirdIsZero));
        vm.stopPrank();

        weird.setMode(WeirdToken.Mode.ReturnFalse);
        vm.expectRevert(OrderVault.TokenTransferFailed.selector);
        vm.prank(alice);
        v.cancelOrder(id);

        // Nothing was lost: the order is still active and refundable once the token works.
        assertEq(uint8(v.getOrder(id).status), uint8(OrderVault.Status.Active));
        weird.setMode(WeirdToken.Mode.Normal);
        vm.prank(alice);
        v.cancelOrder(id);
        assertEq(weird.balanceOf(alice), 1_000e18);
    }

    function test_reentrancy_tokenCannotReenterDuringDeposit() public {
        ReentrantToken evil = new ReentrantToken();
        (OrderVault v, bool evilIsZero) = _vaultFor(address(evil));
        evil.mint(alice, 1_000e18);
        vm.prank(alice);
        evil.approve(address(v), type(uint256).max);

        // While the vault pulls the deposit, the token tries each guarded entry point.
        bytes[3] memory attacks = [
            abi.encodeCall(OrderVault.cancelOrder, (0)),
            abi.encodeCall(OrderVault.reclaimExpired, (0)),
            abi.encodeCall(OrderVault.createOrder, (_paramsSelling(evilIsZero)))
        ];
        for (uint256 i = 0; i < attacks.length; i++) {
            evil.arm(address(v), attacks[i]);
            vm.expectRevert(OrderVault.Reentrancy.selector);
            vm.prank(alice);
            v.createOrder(_paramsSelling(evilIsZero));
        }
        assertEq(v.activeOrderCount(), 0);
        assertEq(evil.balanceOf(alice), 1_000e18);
    }

    // ------------------------------------------------------------------ funds

    function test_coverDebt_paysTheProxyFromNativeBalance() public {
        MockSystem debtProxy = new MockSystem();
        OrderVault v =
            new OrderVault{value: 1 ether}(IPayable(payable(address(debtProxy))), reactive, swapper, key);
        debtProxy.setDebt(address(v), 0.3 ether);

        vm.prank(bob);
        v.coverDebt();
        assertEq(address(debtProxy).balance, 0.3 ether);
        assertEq(address(v).balance, 0.7 ether);
    }

    /// The recovery the README describes: with too little balance the debt cannot be paid; a plain
    /// transfer tops the vault up, then anyone can settle it.
    function test_coverDebt_underfundedRevertsThenTopUpSettlesIt() public {
        MockSystem debtProxy = new MockSystem();
        OrderVault v =
            new OrderVault{value: 0.1 ether}(IPayable(payable(address(debtProxy))), reactive, swapper, key);
        debtProxy.setDebt(address(v), 0.3 ether);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.InsufficientFunds.selector, 0.3 ether, 0.1 ether)
        );
        v.coverDebt();

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        (bool ok,) = address(v).call{value: 0.2 ether}("");
        assertTrue(ok, "plain transfer accepted");

        vm.prank(bob);
        v.coverDebt();
        assertEq(address(debtProxy).balance, 0.3 ether, "debt paid");
        assertEq(address(v).balance, 0);
    }

    function test_withdraw_ownerOnlyAndNativeOnly() public {
        vm.deal(address(vault), 1 ether);
        uint256 id = _create(_params());

        vm.expectRevert(OrderVault.NotOwner.selector);
        vm.prank(alice);
        vault.withdraw(1 ether);

        // The test contract deployed the vault, so it is the owner.
        uint256 before = address(this).balance;
        vault.withdraw(1 ether);
        assertEq(address(this).balance - before, 1 ether);
        assertEq(token0.balanceOf(address(vault)), 100e18, "escrow untouched");
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));
    }

    receive() external payable {}

    // --------------------------------------------------------------- slippage

    function test_execute_slippageBoundAllowsForThePoolFee() public {
        // 0.20% is below the 0.30% pool fee. The bound is measured after the fee, so it only has
        // to cover price impact (about 0.1% for this size) and the order sells.
        OrderVault.OrderParams memory p = _params();
        p.maxSlippageBps = 20;
        uint256 id = _create(p);
        _pushDown(2_000e18);
        _execute(id, 1, 0);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Executed));
    }

    function test_views_poolKeyAndNormalizedTick() public {
        PoolKey memory k = vault.poolKey();
        assertEq(Currency.unwrap(k.currency0), address(token0));
        assertEq(Currency.unwrap(k.currency1), address(token1));
        assertEq(k.fee, key.fee);
        assertEq(k.tickSpacing, key.tickSpacing);
        assertEq(address(k.hooks), address(0));

        _pushDown(2_000e18);
        int24 tick = _tick();
        assertLt(tick, 0);
        assertEq(vault.normalizedTick(true), tick);
        assertEq(vault.normalizedTick(false), -tick);
    }

    function test_constructor_rejectsHookedPool() public {
        PoolKey memory hooked = key;
        hooked.hooks = IHooks(address(0x4444));
        vm.expectRevert(OrderVault.HooksNotSupported.selector);
        new OrderVault(IPayable(payable(proxy)), reactive, swapper, hooked);
    }

    // ----------------------------------------------------------------- cancel

    function test_cancelOrder_refundsOwnerOnly() public {
        uint256 id = _create(_params());

        vm.expectRevert(OrderVault.NotOrderOwner.selector);
        vm.prank(bob);
        vault.cancelOrder(id);

        vm.expectEmit(true, false, false, false, address(vault));
        emit OrderCancelled(id);
        vm.prank(alice);
        vault.cancelOrder(id);

        assertEq(token0.balanceOf(alice), 1_000e18);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(vault.activeOrderCount(), 0);

        vm.expectRevert(OrderVault.OrderNotActive.selector);
        vm.prank(alice);
        vault.cancelOrder(id);
    }

    function test_execute_afterCancelIsSilentNoOp() public {
        uint256 id = _create(_params());
        vm.prank(alice);
        vault.cancelOrder(id);
        _pushDown(2_000e18);
        assertLt(_tick(), -120);

        vm.recordLogs();
        _execute(id, vault.SIDE_STOP(), 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(token1.balanceOf(alice), 1_000e18, "nothing sold");
    }

    // ------------------------------------------------------------------- auth

    function test_execute_rejectsNonProxyCaller() public {
        uint256 id = _create(_params());
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, bob, proxy));
        vm.prank(bob);
        vault.execute(reactive, id, 1, 0);
    }

    function test_execute_rejectsOtherReactiveContract() public {
        uint256 id = _create(_params());
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, bob, reactive)
        );
        vm.prank(proxy);
        vault.execute(bob, id, 1, 0);
    }

    // -------------------------------------------------------------- stop-loss

    function test_execute_stop_failsWhilePriceAboveStop() public {
        uint256 id = _create(_params());

        vm.expectEmit(true, false, false, true, address(vault));
        emit OrderExecutionFailed(
            id, 1, abi.encodeWithSelector(OrderVault.PriceNotAtTrigger.selector, int24(0))
        );
        _execute(id, 1, 0);

        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));
        assertEq(token0.balanceOf(address(vault)), 100e18);
        assertEq(vault.activeOrderCount(), 1);
    }

    function test_execute_stop_sellsOnceWhenPriceAtOrBelowStop() public {
        uint256 id = _create(_params());
        _pushDown(2_000e18);
        int24 tick = _tick();
        assertLt(tick, -120);

        vm.recordLogs();
        _execute(id, 1, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 proceeds = token1.balanceOf(alice) - 1_000e18;
        assertGt(proceeds, 90e18, "sold near the stop price");
        assertLt(proceeds, 100e18);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token0.allowance(address(vault), address(swapper)), 0, "no allowance left behind");
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Executed));
        assertEq(vault.activeOrderCount(), 0);

        Vm.Log memory last = logs[logs.length - 1];
        assertEq(last.topics[0], OrderExecuted.selector);
        (uint8 side, uint256 amountOut, int24 nTick, uint256 executedAt) =
            abi.decode(last.data, (uint8, uint256, int24, uint256));
        assertEq(side, 1);
        assertEq(amountOut, proceeds);
        assertEq(nTick, tick);
        assertEq(executedAt, T0);

        // A duplicate delivery must not sell again or emit anything.
        vm.recordLogs();
        _execute(id, 1, 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(token1.balanceOf(alice) - 1_000e18, proceeds);
    }

    // ------------------------------------------------------------ take-profit

    function test_execute_takeProfit_sellsWhenPriceAtOrAboveLevel() public {
        uint256 id = _create(_params());

        // Not there yet.
        _execute(id, 2, 0);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));

        _pushUp(2_000e18);
        assertGt(_tick(), 120);
        _execute(id, 2, 0);

        uint256 proceeds = token1.balanceOf(alice) - 1_000e18;
        assertGt(proceeds, 100e18, "sold above the entry price");
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Executed));
    }

    function test_oco_otherSideIsDeadAfterExecution() public {
        uint256 id = _create(_params());
        _pushUp(2_000e18);
        _execute(id, 2, 0);
        uint256 proceeds = token1.balanceOf(alice);

        // Price collapses through the stop afterwards.
        _pushDown(6_000e18);
        assertLt(_tick(), -120);
        vm.recordLogs();
        _execute(id, 1, 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(token1.balanceOf(alice), proceeds, "second side did not sell");
    }

    function test_execute_wrongSideForPriceFails() public {
        uint256 id = _create(_params());
        _pushDown(2_000e18);
        // Price is at the stop, but the callback claims take-profit.
        _execute(id, 2, 0);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));
        assertEq(token0.balanceOf(address(vault)), 100e18);
    }

    function test_execute_sideNotEnabledFails() public {
        OrderVault.OrderParams memory p = _params();
        p.useStop = false;
        uint256 id = _create(p);
        _pushDown(2_000e18);
        _execute(id, 1, 0);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));
    }

    function test_execute_unknownSideFails() public {
        uint256 id = _create(_params());
        vm.expectEmit(true, false, false, true, address(vault));
        emit OrderExecutionFailed(id, 9, abi.encodeWithSelector(OrderVault.UnknownSide.selector, uint8(9)));
        _execute(id, 9, 0);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));
    }

    function test_execute_unknownSideNeverSellsEvenWithAValidTrailingLevel() public {
        // Without the early return an unknown side would fall through to the trailing check.
        uint256 id = _create(_trailingParams());
        _pushDown(4_000e18);
        vm.recordLogs();
        _execute(id, 9, -100);
        assertEq(vm.getRecordedLogs().length, 1, "exactly one failure event");
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));
        assertEq(token0.balanceOf(address(vault)), 100e18);
    }

    // ----------------------------------------------------------------- token1

    function test_execute_sellingToken1_stopFiresWhenTickRises() public {
        OrderVault.OrderParams memory p = _params();
        p.zeroForOne = false;
        p.stopTick = 120;
        p.takeProfitTick = -120;
        uint256 id = _create(p);

        _pushDown(2_000e18); // token1 gets more valuable: not a stop
        _execute(id, 1, 0);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));

        _pushUp(6_000e18);
        assertGt(_tick(), 120);
        _execute(id, 1, 0);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Executed));
        assertGt(token0.balanceOf(alice) - 1_000e18, 90e18);
        assertEq(token1.balanceOf(address(vault)), 0);
    }

    // --------------------------------------------------------------- trailing

    function _trailingParams() internal pure returns (OrderVault.OrderParams memory p) {
        p = _params();
        p.useStop = false;
        p.trailingDistance = 100;
    }

    function test_execute_trailing_sellsWhenPriceAtOrBelowReportedLevel() public {
        uint256 id = _create(_trailingParams());
        _pushUp(400e18); // peak would be here, about 80 ticks up
        int24 peak = _tick();
        assertGt(peak, 0);
        assertLt(peak, 120, "stay below take-profit");
        _pushDown(4_000e18);
        int24 level = peak - 100;
        assertLe(_tick(), level);

        _execute(id, 3, level);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Executed));
    }

    function test_execute_trailing_rejectsLevelThePriceHasNotReached() public {
        uint256 id = _create(_trailingParams());
        // Tick is 0; a level of -50 has not been reached.
        _execute(id, 3, -50);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));
    }

    function test_execute_trailing_rejectsLevelBelowWhereTrailingStarted() public {
        uint256 id = _create(_trailingParams());
        _pushDown(4_000e18);
        // Created at tick 0 with distance 100: the level can never be below -100.
        _execute(id, 3, -101);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));
        _execute(id, 3, -100);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Executed));
    }

    function test_execute_trailing_rejectsLevelAtOrAboveTakeProfit() public {
        uint256 id = _create(_trailingParams());
        // A bogus level at the take-profit would sell immediately at any price below it.
        _execute(id, 3, 120);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));
    }

    function test_execute_trailing_rejectedWhenOrderHasNoTrailing() public {
        uint256 id = _create(_params());
        _pushDown(2_000e18);
        _execute(id, 3, 0);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));
    }

    // ----------------------------------------------------------------- expiry

    function test_execute_afterExpiryRefundsInsteadOfSelling() public {
        uint256 id = _create(_params());
        _pushDown(2_000e18);
        vm.warp(EXPIRY + 1);

        vm.expectEmit(true, false, false, false, address(vault));
        emit OrderExpired(id);
        _execute(id, 1, 0);

        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Expired));
        assertEq(token0.balanceOf(alice), 1_000e18, "refunded");
        assertEq(token1.balanceOf(alice), 1_000e18, "not sold");
        assertEq(vault.activeOrderCount(), 0);
    }

    function test_execute_atExpiryTimestampStillSells() public {
        uint256 id = _create(_params());
        _pushDown(2_000e18);
        vm.warp(EXPIRY);
        _execute(id, 1, 0);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Executed));
    }

    function test_execute_expireSideBeforeExpiryDoesNothing() public {
        uint256 id = _create(_params());
        vm.recordLogs();
        _execute(id, 4, 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));
    }

    function test_reclaimExpired_anyoneCanCloseAfterExpiry() public {
        uint256 id = _create(_params());

        vm.expectRevert(OrderVault.NotExpired.selector);
        vault.reclaimExpired(id);

        vm.warp(EXPIRY + 1);
        vm.prank(bob);
        vault.reclaimExpired(id);
        assertEq(token0.balanceOf(alice), 1_000e18);
        assertEq(token0.balanceOf(bob), 1_000e18, "caller gets nothing");

        vm.expectRevert(OrderVault.OrderNotActive.selector);
        vault.reclaimExpired(id);
    }

    // --------------------------------------------------------------- slippage

    function test_execute_swapFailureKeepsOrderActiveAndClearsAllowance() public {
        OrderVault.OrderParams memory p = _params();
        p.maxSlippageBps = 1; // tighter than the 0.3% pool fee: the swap must fail
        uint256 id = _create(p);
        _pushDown(2_000e18);

        vm.recordLogs();
        _execute(id, 1, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Vm.Log memory last = logs[logs.length - 1];
        assertEq(last.topics[0], OrderExecutionFailed.selector);
        (, bytes memory reason) = abi.decode(last.data, (uint8, bytes));
        assertEq(bytes4(reason), V4Swapper.InsufficientOutput.selector);

        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));
        assertEq(vault.activeOrderCount(), 1);
        assertEq(token0.balanceOf(address(vault)), 100e18, "tokens still escrowed");
        assertEq(token0.allowance(address(vault), address(swapper)), 0);
        assertEq(token1.balanceOf(alice), 1_000e18);

        // Still cancellable afterwards.
        vm.prank(alice);
        vault.cancelOrder(id);
        assertEq(token0.balanceOf(alice), 1_000e18);
    }

    function test_execute_absoluteFloorIsEnforced() public {
        OrderVault.OrderParams memory p = _params();
        p.maxSlippageBps = 10_000; // relative check off
        p.minAmountOut = 99e18; // unreachable once the price is below the stop
        uint256 id = _create(p);
        _pushDown(2_000e18);
        _execute(id, 1, 0);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));
    }

    // -------------------------------------------------------------------- gas

    function test_execute_gasFitsCallbackBudget() public {
        uint256 id = _create(_params());
        _pushDown(2_000e18);
        vm.prank(proxy);
        uint256 before = gasleft();
        vault.execute(reactive, id, 1, 0);
        uint256 used = before - gasleft();
        emit log_named_uint("vault.execute gas (stop, no tick crossed)", used);
        assertLt(used, 870_000);
    }
}
