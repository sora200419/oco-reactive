// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Vm} from "forge-std/Test.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

import {OrderVault} from "../src/OrderVault.sol";
import {OcoReactive} from "../src/OcoReactive.sol";
import {MockSystem} from "./mocks/MockSystem.sol";
import {V4ForkBase} from "./utils/V4ForkBase.sol";

/// End-to-end tests of the whole loop in one EVM: real pool and vault events are relayed to the
/// reactive contract the way Reactive Network would, and the callbacks it requests are delivered
/// to the vault the way the callback proxy would. Only the network in between is simulated, and
/// the tests control it: logs can be relayed in emission order, late, or not at all.
contract OcoFullLoopForkTest is V4ForkBase {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    /// Gas the Unichain Sepolia proxy is expected to withhold from each callback.
    uint256 internal constant PROXY_WITHHELD_GAS = 130_000;

    MockSystem internal system = MockSystem(payable(SYSTEM_ADDR));
    OrderVault internal vault;
    OcoReactive internal reactive;
    address internal proxy = makeAddr("callbackProxy");
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    uint64 internal constant EXPIRY = uint64(T0 + 1 days);
    uint256 internal delivered;
    uint256 internal maxCallbackGas;
    /// Emission-order counter used as the log index of relayed logs.
    uint256 internal emitted;

    function setUp() public {
        _setUpPool();
        vm.etch(SYSTEM_ADDR, address(new MockSystem()).code);

        // Same order as a real deployment: reactive first, then the vault, then wire them.
        vm.prank(deployer);
        reactive = new OcoReactive(block.chainid, address(MANAGER), PoolId.unwrap(poolId));
        vault = new OrderVault(IPayable(payable(proxy)), address(reactive), swapper, key);
        vm.prank(deployer);
        reactive.setVault(address(vault));

        address[4] memory users = [alice, bob, carol, dave];
        for (uint256 i = 0; i < users.length; i++) {
            token0.mint(users[i], 1_000e18);
            token1.mint(users[i], 1_000e18);
            vm.startPrank(users[i]);
            token0.approve(address(vault), type(uint256).max);
            token1.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
        vm.recordLogs();
    }

    // ------------------------------------------------------- network stand-in

    /// Takes every pool or vault log emitted since the last call and stamps each with its position
    /// in emission order. Holding the result back and relaying it later models late delivery.
    function _collect() internal returns (IReactive.LogRecord[] memory records) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(MANAGER) || logs[i].emitter == address(vault)) n++;
        }
        records = new IReactive.LogRecord[](n);
        uint256 j;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(MANAGER) && logs[i].emitter != address(vault)) continue;
            IReactive.LogRecord memory r;
            r.chainId = block.chainid;
            r.contractAddress = logs[i].emitter;
            r.opCode = logs[i].topics.length;
            r.data = logs[i].data;
            r.blockNumber = block.number;
            r.logIndex = emitted++;
            if (logs[i].topics.length > 0) r.topic0 = uint256(logs[i].topics[0]);
            if (logs[i].topics.length > 1) r.topic1 = uint256(logs[i].topics[1]);
            if (logs[i].topics.length > 2) r.topic2 = uint256(logs[i].topics[2]);
            if (logs[i].topics.length > 3) r.topic3 = uint256(logs[i].topics[3]);
            records[j++] = r;
        }
    }

    function _relay(IReactive.LogRecord[] memory records_) internal {
        for (uint256 i = 0; i < records_.length; i++) {
            vm.prank(SYSTEM_ADDR);
            reactive.react(records_[i]);
        }
    }

    function _relayFrom(IReactive.LogRecord[] memory records_, address emitter_) internal {
        for (uint256 i = 0; i < records_.length; i++) {
            if (records_[i].contractAddress != emitter_) continue;
            vm.prank(SYSTEM_ADDR);
            reactive.react(records_[i]);
        }
    }

    /// Relays every new log in emission order and delivers every callback requested, repeating
    /// until the system is quiet. Returns how many callbacks were delivered.
    function _pump() internal returns (uint256 deliveredNow) {
        for (uint256 round = 0; round < 40; round++) {
            IReactive.LogRecord[] memory records = _collect();
            _relay(records);
            bool busy = records.length > 0;
            while (delivered < system.callbackCount()) {
                _deliver(system.callbackAt(delivered));
                delivered++;
                deliveredNow++;
                busy = true;
            }
            if (!busy) return deliveredNow;
        }
        revert("loop did not settle");
    }

    /// Mimics the callback proxy: injects the requesting contract as the first argument and calls
    /// the recipient with the requested gas minus what the proxy keeps for itself.
    function _deliver(MockSystem.CallbackRequest memory c_) internal {
        bytes memory payload = c_.payload;
        bytes32 word = bytes32(uint256(uint160(c_.sender)));
        assembly {
            mstore(add(payload, 36), word)
        }
        uint256 gasForTarget = uint256(c_.gasLimit) - PROXY_WITHHELD_GAS;
        vm.prank(proxy);
        uint256 before = gasleft();
        (bool ok,) = c_.recipient.call{gas: gasForTarget}(payload);
        uint256 used = before - gasleft();
        if (used > maxCallbackGas) maxCallbackGas = used;
        assertTrue(ok, "a callback reverted; callbacks must never revert");
    }

    // ---------------------------------------------------------------- helpers

    function _order() internal pure returns (OrderVault.OrderParams memory p) {
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

    function _trailing(uint24 distance_) internal pure returns (OrderVault.OrderParams memory p) {
        p = _order();
        p.useStop = false;
        p.useTakeProfit = false;
        p.trailingDistance = distance_;
    }

    function _place(address user_, OrderVault.OrderParams memory p_) internal returns (uint256 id) {
        vm.prank(user_);
        id = vault.createOrder(p_);
        _pump();
    }

    function _status(uint256 id_) internal view returns (OrderVault.Status) {
        return vault.getOrder(id_).status;
    }

    // ------------------------------------------------------------- happy paths

    function test_loop_orderIsTrackedAfterCreation() public {
        uint256 id = _place(alice, _order());
        uint256[] memory ids = reactive.activeIds();
        assertEq(ids.length, 1);
        assertEq(ids[0], id);
        assertEq(system.callbackCount(), 0);
    }

    function test_loop_stopLoss() public {
        uint256 id = _place(alice, _order());

        _pushDown(300e18); // not far enough
        assertGt(_tick(), -120);
        assertEq(_pump(), 0);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));

        _pushDown(2_000e18);
        assertLt(_tick(), -120);
        assertEq(_pump(), 1, "exactly one callback");

        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Executed));
        assertGt(token1.balanceOf(alice) - 1_000e18, 90e18);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(reactive.activeIds().length, 0, "untracked after the vault confirmed");
    }

    function test_loop_takeProfit() public {
        uint256 id = _place(alice, _order());
        _pushUp(2_000e18);
        assertEq(_pump(), 1);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Executed));
        assertGt(token1.balanceOf(alice) - 1_000e18, 100e18, "sold above entry");
        assertEq(reactive.activeIds().length, 0);
    }

    function test_loop_trailingStop() public {
        uint256 id = _place(alice, _trailing(100));

        _pushUp(1_500e18);
        int24 peak = _tick();
        assertGt(peak, 200);
        assertEq(_pump(), 0, "rising price never triggers a trailing stop");

        _pushDown(200e18); // small pullback, inside the distance
        assertGt(_tick(), peak - 100);
        assertEq(_pump(), 0);

        _pushDown(800e18);
        assertLe(_tick(), peak - 100);
        assertEq(_pump(), 1);

        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Executed));
        // Sold well above the entry price of 1.0 even though the price was falling.
        assertGt(token1.balanceOf(alice) - 1_000e18, 100e18);
    }

    function test_loop_cancelledOrderIsNeverTriggered() public {
        uint256 id = _place(alice, _order());
        vm.prank(alice);
        vault.cancelOrder(id);
        _pump();
        assertEq(reactive.activeIds().length, 0);

        _pushDown(2_000e18);
        assertEq(_pump(), 0);
        assertEq(token0.balanceOf(alice), 1_000e18);
    }

    function test_loop_twoUsersBothStoppedOnceEach() public {
        uint256 a = _place(alice, _order());
        OrderVault.OrderParams memory p = _order();
        p.stopTick = -60;
        uint256 b = _place(bob, p);

        _pushDown(2_000e18);
        assertEq(_pump(), 2, "one callback per order, none repeated by the vault's own swaps");

        assertEq(uint8(_status(a)), uint8(OrderVault.Status.Executed));
        assertEq(uint8(_status(b)), uint8(OrderVault.Status.Executed));
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(reactive.activeIds().length, 0);
    }

    function test_loop_fullBookDrainsThroughItsOwnSwaps() public {
        // Ten orders at the same stop. One reactive transaction may only request four callbacks;
        // the swaps made by those four sales are what trigger the remaining orders.
        uint256 max = vault.MAX_ACTIVE_ORDERS();
        address[4] memory users = [alice, bob, carol, dave];
        OrderVault.OrderParams memory p = _order();
        p.amountIn = 10e18;
        p.maxSlippageBps = 10_000;
        uint256[] memory ids = new uint256[](max);
        for (uint256 i = 0; i < max; i++) {
            ids[i] = _place(users[i / 3], p);
        }
        assertEq(reactive.activeIds().length, max);

        _pushDown(2_000e18); // a single external swap
        assertEq(_pump(), max, "every order executed with exactly one callback");

        for (uint256 i = 0; i < max; i++) {
            assertEq(uint8(_status(ids[i])), uint8(OrderVault.Status.Executed));
        }
        assertEq(vault.activeOrderCount(), 0);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(reactive.activeIds().length, 0);
    }

    // ---------------------------------------------------------------- failures

    function test_loop_swapFailuresAreRetriedAfterCooldownAndBounded() public {
        OrderVault.OrderParams memory p = _order();
        p.maxSlippageBps = 0; // no price impact allowed: every attempt fails in the swap
        uint256 id = _place(alice, p);

        _pushDown(2_000e18);
        assertEq(_pump(), 1);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active), "failed, still active");

        // Another swap right away: still cooling down.
        _pushDown(1e18);
        assertEq(_pump(), 0);

        uint256 total = 1;
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + reactive.RETRY_COOLDOWN());
            _pushDown(1e18);
            total += _pump();
        }
        assertEq(total, reactive.MAX_ATTEMPTS(), "callback spending is bounded within the window");

        // The owner can still get the tokens back.
        vm.prank(alice);
        vault.cancelOrder(id);
        assertEq(token0.balanceOf(alice), 1_000e18);
        _pump();
        assertEq(reactive.activeIds().length, 0);
    }

    function test_loop_expiredOrderIsClosedAndRefunded() public {
        uint256 id = _place(alice, _order());

        vm.warp(uint256(EXPIRY) + reactive.EXPIRY_GRACE() + 1);
        _pushUp(1e18); // any swap in the pool
        assertEq(_pump(), 1);

        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Expired));
        assertEq(token0.balanceOf(alice), 1_000e18, "refunded in full");
        assertEq(reactive.activeIds().length, 0);
    }

    function test_loop_ownerReclaimsBeforeTheExpiryCallback() public {
        uint256 id = _place(alice, _order());
        vm.warp(uint256(EXPIRY) + 1);
        vault.reclaimExpired(id);
        _pump();
        assertEq(reactive.activeIds().length, 0);

        vm.warp(uint256(EXPIRY) + reactive.EXPIRY_GRACE() + 1);
        _pushUp(1e18);
        assertEq(_pump(), 0, "nothing left to expire");
    }

    function test_loop_callbackGasStaysInsideTheForwardedBudget() public {
        _place(alice, _order());
        // Stack narrow positions so the vault's sale crosses several initialised ticks.
        for (int24 i = 0; i < 10; i++) {
            _addLiquidity(-60 * (i + 4), -60 * (i + 3), 1_000e18);
        }
        vm.getRecordedLogs(); // liquidity events are not relayed in production either
        _pushDown(2_000e18);
        assertEq(_pump(), 1);
        emit log_named_uint("largest callback gas in this test", maxCallbackGas);
        assertLt(maxCallbackGas, 1_000_000 - PROXY_WITHHELD_GAS);
    }

    // ------------------------------------------- review regressions (R1 - R6)

    /// R1. A wick far above the take-profit comes back before the take-profit callback lands.
    /// The order must not be left with a trailing level the vault will never accept.
    function test_review_wickAboveTakeProfitStillSellsOnTheWayDown() public {
        OrderVault.OrderParams memory p = _order(); // stop -120, take-profit 120
        p.trailingDistance = 60;
        uint256 id = _place(alice, p);

        _pushUp(3_000e18);
        assertGt(_tick(), 120 + 60, "wick is past take-profit plus distance");
        _pushDown(2_500e18);
        assertLt(_tick(), 120, "back under the take-profit before anything was relayed");
        assertGt(_tick(), -120);

        assertEq(_pump(), 1, "the take-profit callback arrives too late");
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));

        // Next swap after the cooldown: the price is under the held trailing level, so it sells.
        vm.warp(block.timestamp + reactive.RETRY_COOLDOWN());
        _pushDown(1e18);
        assertEq(_pump(), 1);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Executed));
        assertGt(token1.balanceOf(alice) - 1_000e18, 100e18, "sold above the entry price");
    }

    /// R2. Pushing the price through the stop and back, repeatedly, must not disable the stop.
    function test_review_roundTripsDoNotDisableTheStop() public {
        uint256 id = _place(alice, _order());
        uint256 rounds = uint256(reactive.MAX_ATTEMPTS()) + 3;
        for (uint256 i = 0; i < rounds; i++) {
            _pushDown(2_000e18);
            _pushUp(2_000e18);
            assertGt(_tick(), -120, "price recovered before the callback");
            assertEq(_pump(), 1, "each round trip costs one failed callback");
            assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));
            vm.warp(block.timestamp + reactive.RETRY_COOLDOWN());
        }

        _pushDown(4_000e18); // the real drop
        assertLt(_tick(), -120);
        assertEq(_pump(), 1);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Executed), "the stop still works");
    }

    function test_review_expiryIsHonouredAfterManyFailedTriggers() public {
        OrderVault.OrderParams memory p = _order();
        p.maxSlippageBps = 0;
        uint256 id = _place(alice, p);
        for (uint256 i = 0; i < 8; i++) {
            _pushDown(600e18);
            _pump();
            vm.warp(block.timestamp + reactive.RETRY_COOLDOWN());
        }
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));

        vm.warp(uint256(EXPIRY) + reactive.EXPIRY_GRACE() + 1);
        _pushDown(1e18);
        assertEq(_pump(), 1);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Expired));
        assertEq(token0.balanceOf(alice), 1_000e18);
        assertEq(reactive.activeIds().length, 0);
    }

    /// R3. Swaps from before the order existed, delivered after its creation event, must not
    /// move its trailing peak.
    function test_review_staleSwapsCannotSellAFreshTrailingOrder() public {
        _pushUp(1_500e18);
        _pushDown(1_500e18);
        IReactive.LogRecord[] memory heldBack = _collect();

        vm.prank(alice);
        uint256 id = vault.createOrder(_trailing(100));
        _pump(); // the creation event overtakes the two swaps
        _relayFrom(heldBack, address(MANAGER));

        assertEq(_pump(), 0, "the order never saw those prices");
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active));
        assertEq(reactive.getTracked(id).nPeak, vault.getOrder(id).nAtCreation);
    }

    /// R5a. A creation event replayed after the order has closed must not leave a ghost.
    function test_review_replayedCreationAfterExecutionLeavesNoGhost() public {
        vm.prank(alice);
        uint256 id = vault.createOrder(_order());
        IReactive.LogRecord[] memory created = _collect();
        _relay(created);

        _pushDown(2_000e18);
        assertEq(_pump(), 1);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Executed));

        _relay(created);
        assertEq(reactive.activeIds().length, 0, "not tracked again");

        vm.warp(block.timestamp + reactive.PENDING_TIMEOUT() + 1);
        _pushDown(1e18);
        assertEq(_pump(), 0, "no callbacks wasted on a closed order");
    }

    /// R5b. With the vault's book full, a new order's creation event can arrive before the
    /// closing event that made room for it. The new order must still be watched.
    function test_review_creationOvertakingACloseIsStillTracked() public {
        address[4] memory users = [alice, bob, carol, dave];
        OrderVault.OrderParams memory p = _order();
        p.amountIn = 1e18;
        for (uint256 i = 0; i < vault.MAX_ACTIVE_ORDERS(); i++) {
            _place(users[i / 3], p);
        }

        vm.prank(alice);
        vault.cancelOrder(0);
        IReactive.LogRecord[] memory cancelLogs = _collect();
        vm.prank(alice);
        uint256 id = vault.createOrder(_order());
        _pump(); // Created(new) first
        _relay(cancelLogs); // Cancelled(old) late

        assertTrue(reactive.getTracked(id).active, "the new order is watched");
        assertEq(reactive.activeIds().length, vault.MAX_ACTIVE_ORDERS());

        _pushDown(2_000e18);
        _pump();
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Executed));
    }

    /// R6. One address cannot fill the book with dust orders that never expire.
    function test_review_oneAddressCannotLockTheBook() public {
        OrderVault.OrderParams memory dust = _order();
        dust.amountIn = 1;
        dust.stopTick = -887_272;
        dust.useTakeProfit = false;

        dust.expiry = type(uint64).max;
        vm.expectRevert(OrderVault.ExpiryTooFar.selector);
        vm.prank(bob);
        vault.createOrder(dust);

        dust.expiry = uint64(T0 + vault.MAX_ORDER_DURATION());
        for (uint256 i = 0; i < vault.MAX_ORDERS_PER_OWNER(); i++) {
            vm.prank(bob);
            vault.createOrder(dust);
        }
        vm.expectRevert(OrderVault.TooManyOrdersForOwner.selector);
        vm.prank(bob);
        vault.createOrder(dust);

        // Everyone else can still trade.
        _place(alice, _order());
    }

    /// R4, documented limit rather than a fix: triggers read the price of a single swap, so a
    /// round trip can force a trailing order to sell. This test pins the behaviour the docs
    /// describe; `minAmountOut` is the owner's defence.
    function test_documented_roundTripCanForceATrailingSale() public {
        uint256 id = _place(alice, _trailing(100));
        _pushUp(1_500e18);
        _pushDown(1_500e18);
        assertEq(_pump(), 1);
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Executed));
    }

    function test_documented_minAmountOutBlocksAForcedSaleBelowTheFloor() public {
        OrderVault.OrderParams memory p = _trailing(100);
        p.minAmountOut = 100e18; // will not sell 100 token0 for less than 100 token1
        uint256 id = _place(alice, p);
        _pushUp(1_500e18);
        _pushDown(1_500e18); // back to about the entry price, minus fees: under the floor
        _pump();
        assertEq(uint8(_status(id)), uint8(OrderVault.Status.Active), "the floor held");
        assertEq(token0.balanceOf(address(vault)), 100e18);
    }
}
