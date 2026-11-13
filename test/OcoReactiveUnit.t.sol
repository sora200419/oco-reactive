// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";

import {OcoReactive} from "../src/OcoReactive.sol";
import {MockSystem} from "./mocks/MockSystem.sol";
import {EventSystem} from "./mocks/EventSystem.sol";

/// Unit tests for the reactive contract in isolation: logs are fed in by hand and the callback
/// requests it makes are read back from a mock system contract.
contract OcoReactiveUnitTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant REACTIVE_IGNORE =
        0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    uint256 internal constant CHAIN = 1301;
    uint256 internal constant T0 = 1_800_000_000;
    uint64 internal constant EXPIRY = uint64(T0 + 1 days);
    bytes32 internal constant POOL_ID = keccak256("pool");

    uint256 internal constant SWAP_T0 =
        uint256(keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"));
    uint256 internal constant CREATED_T0 = uint256(
        keccak256("OrderCreated(uint256,address,bool,uint128,bool,int24,bool,int24,uint24,uint64,int24)")
    );
    uint256 internal constant CANCELLED_T0 = uint256(keccak256("OrderCancelled(uint256)"));
    uint256 internal constant EXPIRED_T0 = uint256(keccak256("OrderExpired(uint256)"));
    uint256 internal constant EXECUTED_T0 =
        uint256(keccak256("OrderExecuted(uint256,uint8,uint256,int24,uint256)"));
    uint256 internal constant FAILED_T0 = uint256(keccak256("OrderExecutionFailed(uint256,uint8,bytes)"));

    MockSystem internal system = MockSystem(payable(SYSTEM_ADDR));
    address internal manager = makeAddr("poolManager");
    address internal vault = makeAddr("vault");
    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    OcoReactive internal reactive;
    uint256 internal nextLogIndex;
    /// The vault's cap on active orders, used for the full-book tests.
    uint256 internal constant BOOK = 10;

    event OrderDropped(uint256 indexed id);

    /// Shape of an order as it appears in OrderCreated.
    struct Spec {
        bool zeroForOne;
        bool useStop;
        int24 nStop;
        bool useTakeProfit;
        int24 nTakeProfit;
        uint24 trailing;
        uint64 expiry;
        int24 nAtCreation;
    }

    function setUp() public {
        vm.warp(T0);
        vm.etch(SYSTEM_ADDR, address(new MockSystem()).code);
        vm.startPrank(owner);
        reactive = new OcoReactive(CHAIN, manager, POOL_ID);
        reactive.setVault(vault);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- helpers

    /// A log positioned after every log made so far, as if emitted in call order.
    function _log(address emitter_, uint256 topic0_, uint256 topic1_, uint256 topicCount_, bytes memory data_)
        internal
        returns (IReactive.LogRecord memory)
    {
        return _logAt(emitter_, topic0_, topic1_, topicCount_, data_, 1_000_000, nextLogIndex++);
    }

    /// A log at an explicit position on the origin chain, for out-of-order delivery tests.
    function _logAt(
        address emitter_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topicCount_,
        bytes memory data_,
        uint256 blockNumber_,
        uint256 logIndex_
    ) internal pure returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: CHAIN,
            contractAddress: emitter_,
            topic0: topic0_,
            topic1: topic1_,
            topic2: 0,
            topic3: 0,
            data: data_,
            blockNumber: blockNumber_,
            opCode: topicCount_,
            blockHash: 0,
            txHash: 0,
            logIndex: logIndex_
        });
    }

    function _failed(uint8 side_, bytes memory reason_) internal pure returns (bytes memory) {
        return abi.encode(side_, reason_);
    }

    function _priceNotAtTrigger(int24 nNow_) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("PriceNotAtTrigger(int24)", nNow_);
    }

    function _react(IReactive.LogRecord memory log_) internal {
        vm.prank(SYSTEM_ADDR);
        reactive.react(log_);
    }

    function _swapData(int24 tick_) internal pure returns (bytes memory) {
        return abi.encode(int128(-1), int128(1), uint160(1), uint128(1), tick_, uint24(3000));
    }

    function _swap(int24 tick_) internal {
        _react(_log(manager, SWAP_T0, uint256(POOL_ID), 3, _swapData(tick_)));
    }

    function _stopAndTp() internal pure returns (Spec memory) {
        return Spec({
            zeroForOne: true,
            useStop: true,
            nStop: -120,
            useTakeProfit: true,
            nTakeProfit: 120,
            trailing: 0,
            expiry: EXPIRY,
            nAtCreation: 0
        });
    }

    function _createdData(Spec memory s_) internal pure returns (bytes memory) {
        return abi.encode(
            s_.zeroForOne,
            uint128(100e18),
            s_.useStop,
            s_.nStop,
            s_.useTakeProfit,
            s_.nTakeProfit,
            s_.trailing,
            s_.expiry,
            s_.nAtCreation
        );
    }

    function _create(uint256 id_, Spec memory s_) internal {
        _react(_log(vault, CREATED_T0, id_, 3, _createdData(s_)));
    }

    function _vaultEvent(uint256 topic0_, uint256 id_) internal {
        _react(_log(vault, topic0_, id_, 2, ""));
    }

    function _assertCallback(uint256 index_, uint256 id_, uint8 side_, int24 threshold_) internal view {
        MockSystem.CallbackRequest memory c = system.callbackAt(index_);
        assertEq(c.sender, address(reactive));
        assertEq(c.chainId, CHAIN);
        assertEq(c.recipient, vault);
        assertEq(c.gasLimit, reactive.CALLBACK_GAS_LIMIT());
        assertEq(
            c.payload,
            abi.encodeWithSignature(
                "execute(address,uint256,uint8,int24)", address(0), id_, side_, threshold_
            )
        );
    }

    // ----------------------------------------------------------- subscriptions

    function test_subscriptions_swapByPoolIdThenFiveVaultEvents() public view {
        assertEq(system.subscriptionCount(), 6);

        MockSystem.Subscription memory s = system.subscriptionAt(0);
        assertEq(s.subscriber, address(reactive));
        assertEq(s.chainId, CHAIN);
        assertEq(s.contractAddr, manager);
        assertEq(s.topic0, SWAP_T0);
        assertEq(s.topic1, uint256(POOL_ID), "swap subscription is pinned to the pool id");
        assertEq(s.topic2, REACTIVE_IGNORE);

        uint256[5] memory expected = [CREATED_T0, CANCELLED_T0, EXPIRED_T0, EXECUTED_T0, FAILED_T0];
        for (uint256 i = 0; i < 5; i++) {
            s = system.subscriptionAt(i + 1);
            assertEq(s.contractAddr, vault);
            assertEq(s.topic0, expected[i]);
            assertEq(s.topic1, REACTIVE_IGNORE);
        }
    }

    function test_setVault_onlyOwnerOnceNonZero() public {
        vm.prank(owner);
        OcoReactive fresh = new OcoReactive(CHAIN, manager, POOL_ID);

        vm.expectRevert(OcoReactive.NotOwner.selector);
        vm.prank(stranger);
        fresh.setVault(vault);

        vm.expectRevert(OcoReactive.ZeroAddress.selector);
        vm.prank(owner);
        fresh.setVault(address(0));

        vm.prank(owner);
        fresh.setVault(vault);
        vm.expectRevert(OcoReactive.VaultAlreadySet.selector);
        vm.prank(owner);
        fresh.setVault(stranger);
    }

    function test_constructor_rejectsZeroPoolManager() public {
        vm.expectRevert(OcoReactive.ZeroAddress.selector);
        new OcoReactive(CHAIN, address(0), POOL_ID);
    }

    function test_react_onlySystem() public {
        IReactive.LogRecord memory log = _log(manager, SWAP_T0, uint256(POOL_ID), 3, _swapData(0));
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, SYSTEM_ADDR));
        vm.prank(stranger);
        reactive.react(log);
    }

    // --------------------------------------------------------------- tracking

    function test_track_fromOrderCreated() public {
        _create(7, _stopAndTp());
        uint256[] memory ids = reactive.activeIds();
        assertEq(ids.length, 1);
        assertEq(ids[0], 7);
    }

    function test_track_ignoresForeignOrMalformedLogs() public {
        bytes memory data = _createdData(_stopAndTp());

        _react(_log(stranger, CREATED_T0, 1, 3, data)); // not the vault
        IReactive.LogRecord memory log = _log(vault, CREATED_T0, 1, 3, data);
        log.chainId = 84532; // wrong chain
        _react(log);
        _react(_log(vault, CREATED_T0, 1, 2, data)); // wrong topic count
        _react(_log(vault, CREATED_T0, 1, 3, hex"1234")); // wrong data length
        _react(_log(vault, uint256(keccak256("Other()")), 1, 3, data)); // unknown event

        assertEq(reactive.activeIds().length, 0);
    }

    function test_track_duplicateCreatedIsIgnored() public {
        _create(1, _stopAndTp());
        _create(1, _stopAndTp());
        assertEq(reactive.activeIds().length, 1);
    }

    function test_track_capsAtMaxTrackedOrders() public {
        uint256 max = reactive.MAX_TRACKED_ORDERS();
        for (uint256 i = 0; i <= max; i++) {
            _create(i, _stopAndTp());
        }
        assertEq(reactive.activeIds().length, max);
    }

    function test_untrack_onCancelledExpiredExecuted_keepsOthersWorking() public {
        _create(1, _stopAndTp());
        _create(2, _stopAndTp());
        _create(3, _stopAndTp());
        _create(4, _stopAndTp());

        _vaultEvent(CANCELLED_T0, 1);
        _vaultEvent(EXPIRED_T0, 3);
        _react(_log(vault, EXECUTED_T0, 2, 2, abi.encode(uint8(1), uint256(1), int24(0), uint256(T0))));

        uint256[] memory ids = reactive.activeIds();
        assertEq(ids.length, 1);
        assertEq(ids[0], 4);

        // Unknown id: nothing happens.
        _vaultEvent(CANCELLED_T0, 99);
        assertEq(reactive.activeIds().length, 1);

        // The survivor still triggers; the removed ones do not.
        _swap(-200);
        assertEq(system.callbackCount(), 1);
        _assertCallback(0, 4, 1, -120);
    }

    // ---------------------------------------------------------- stop / profit

    function test_swap_stopFiresAtOrBelowLevelOnly() public {
        _create(1, _stopAndTp());

        _swap(-119);
        assertEq(system.callbackCount(), 0, "one tick above the stop");

        _swap(-120);
        assertEq(system.callbackCount(), 1, "exactly at the stop");
        _assertCallback(0, 1, 1, -120);
    }

    function test_swap_takeProfitFiresAtOrAboveLevelOnly() public {
        _create(1, _stopAndTp());

        _swap(119);
        assertEq(system.callbackCount(), 0);

        _swap(120);
        assertEq(system.callbackCount(), 1);
        _assertCallback(0, 1, 2, 120);
    }

    function test_swap_sellingToken1UsesNegatedTick() public {
        Spec memory s = _stopAndTp();
        s.zeroForOne = false;
        _create(1, s);

        _swap(-200); // token1 worth more: normalized +200 is a take-profit
        _assertCallback(0, 1, 2, 120);
    }

    function test_swap_sellingToken1StopFiresWhenTickRises() public {
        Spec memory s = _stopAndTp();
        s.zeroForOne = false;
        _create(1, s);

        _swap(200);
        _assertCallback(0, 1, 1, -120);
    }

    function test_swap_ignoresOtherPoolsAndMalformedSwaps() public {
        _create(1, _stopAndTp());

        _react(_log(manager, SWAP_T0, uint256(keccak256("other pool")), 3, _swapData(-500)));
        _react(_log(manager, SWAP_T0, uint256(POOL_ID), 2, _swapData(-500)));
        _react(_log(manager, SWAP_T0, uint256(POOL_ID), 3, hex"00"));
        _react(_log(stranger, SWAP_T0, uint256(POOL_ID), 3, _swapData(-500)));
        _react(_log(manager, uint256(keccak256("Donate()")), uint256(POOL_ID), 3, _swapData(-500)));

        assertEq(system.callbackCount(), 0);
    }

    function test_swap_withNoOrdersDoesNothing() public {
        _swap(-500);
        assertEq(system.callbackCount(), 0);
    }

    // ----------------------------------------------------- pending and retries

    function test_pending_suppressesDuplicateTriggersUntilTimeout() public {
        _create(1, _stopAndTp());
        _swap(-200);
        _swap(-300);
        _swap(-400);
        assertEq(system.callbackCount(), 1, "one callback while the first is pending");

        vm.warp(T0 + reactive.PENDING_TIMEOUT() - 1);
        _swap(-400);
        assertEq(system.callbackCount(), 1);

        vm.warp(T0 + reactive.PENDING_TIMEOUT());
        _swap(-400);
        assertEq(system.callbackCount(), 2, "retried after the timeout");
    }

    function test_failedExecution_allowsRetryAfterCooldown() public {
        _create(1, _stopAndTp());
        _swap(-200);

        vm.warp(T0 + 5);
        _react(
            _log(
                vault,
                FAILED_T0,
                1,
                2,
                _failed(1, abi.encodeWithSignature("InsufficientOutput(uint256,uint256)", 1, 2))
            )
        );

        vm.warp(T0 + 5 + reactive.RETRY_COOLDOWN() - 1);
        _swap(-200);
        assertEq(system.callbackCount(), 1, "still cooling down");

        vm.warp(T0 + 5 + reactive.RETRY_COOLDOWN());
        _swap(-200);
        assertEq(system.callbackCount(), 2, "retried well before the pending timeout");
    }

    // --------------------------------------------------------------- trailing

    function _trailingOnly() internal pure returns (Spec memory s) {
        s = _stopAndTp();
        s.useStop = false;
        s.useTakeProfit = false;
        s.trailing = 100;
    }

    function test_trailing_followsPeakAndFiresOnPullback() public {
        _create(1, _trailingOnly());

        _swap(50);
        _swap(300); // peak
        _swap(250);
        _swap(201); // one tick above peak - distance
        assertEq(system.callbackCount(), 0);

        _swap(200);
        assertEq(system.callbackCount(), 1);
        _assertCallback(0, 1, 3, 200);
    }

    function test_trailing_startsFromCreationPriceWhenPriceOnlyFalls() public {
        _create(1, _trailingOnly());
        _swap(-99);
        assertEq(system.callbackCount(), 0);
        _swap(-100);
        _assertCallback(0, 1, 3, -100);
    }

    function test_trailing_fixedStopWinsWhileItIsHigher() public {
        Spec memory s = _trailingOnly();
        s.useStop = true;
        s.nStop = -50; // above the initial trailing level of -100
        _create(1, s);

        _swap(-50);
        _assertCallback(0, 1, 1, -50);
    }

    function test_trailing_overtakesFixedStopAfterPriceRises() public {
        Spec memory s = _trailingOnly();
        s.useStop = true;
        s.nStop = -50;
        _create(1, s);

        _swap(400); // trailing level is now 300, far above the fixed stop
        _swap(300);
        _assertCallback(0, 1, 3, 300);
    }

    function test_trailing_peakKeepsRisingWhileCallbackPending() public {
        Spec memory s = _trailingOnly();
        s.useTakeProfit = true;
        s.nTakeProfit = 1000;
        _create(1, s);

        _swap(-100); // fires at the initial level; now pending
        assertEq(system.callbackCount(), 1);
        _swap(500); // new peak recorded although pending

        vm.warp(T0 + reactive.PENDING_TIMEOUT());
        _swap(401);
        assertEq(system.callbackCount(), 1, "above the new trailing level of 400");
        _swap(400);
        _assertCallback(1, 1, 3, 400);
    }

    function test_trailing_sellingToken1TracksLowestTick() public {
        Spec memory s = _trailingOnly();
        s.zeroForOne = false;
        _create(1, s);

        _swap(-300); // best price for a token1 seller: normalized +300
        _swap(-201);
        assertEq(system.callbackCount(), 0);
        _swap(-200);
        _assertCallback(0, 1, 3, 200);
    }

    // ----------------------------------------------------------------- expiry

    function test_expiry_requestsCloseAfterGrace() public {
        _create(1, _stopAndTp());

        vm.warp(uint256(EXPIRY) + reactive.EXPIRY_GRACE());
        _swap(0);
        assertEq(system.callbackCount(), 0, "grace not over yet");

        vm.warp(uint256(EXPIRY) + reactive.EXPIRY_GRACE() + 1);
        _swap(0);
        _assertCallback(0, 1, 4, 0);

        // Asked once, then no longer tracked; a replayed creation cannot bring it back.
        assertEq(reactive.activeIds().length, 0);
        _swap(0);
        assertEq(system.callbackCount(), 1);
        _create(1, _stopAndTp());
        assertEq(reactive.activeIds().length, 0);
    }

    // ------------------------------------------- review regressions (R1 - R5)

    /// R1: with take-profit and trailing together, the trailing level is held just below the
    /// take-profit, so a price that overshot the take-profit and fell back still sells.
    function test_trailing_levelIsHeldBelowTakeProfit() public {
        Spec memory s = _stopAndTp();
        s.trailing = 60;
        _create(1, s);

        _swap(589); // far above the take-profit: fires take-profit, now pending
        _assertCallback(0, 1, 2, 120);

        // The take-profit callback missed (price fell back first). After the vault reports it:
        _react(_log(vault, FAILED_T0, 1, 2, _failed(2, _priceNotAtTrigger(82))));
        vm.warp(T0 + reactive.RETRY_COOLDOWN());

        // Peak 589 minus 60 would be 529, at or above the take-profit; the level used is 119.
        _swap(82);
        assertEq(system.callbackCount(), 2);
        _assertCallback(1, 1, 3, 119);
    }

    function test_trailing_fixedStopStillFiresAfterOvershoot() public {
        Spec memory s = _stopAndTp();
        s.trailing = 60;
        _create(1, s);
        _swap(589);
        _react(_log(vault, FAILED_T0, 1, 2, _failed(2, _priceNotAtTrigger(130))));
        vm.warp(T0 + reactive.RETRY_COOLDOWN());

        // Straight down through everything: the clamped trailing level (119) is what fires, and
        // it is a level the vault accepts.
        _swap(-500);
        _assertCallback(1, 1, 3, 119);
    }

    /// R2: failures caused by the price moving back do not use up attempts.
    function test_attempts_priceRecoveredFailuresAreNotCounted() public {
        _create(1, _stopAndTp());
        uint256 rounds = uint256(reactive.MAX_ATTEMPTS()) * 3;
        for (uint256 i = 0; i < rounds; i++) {
            vm.warp(T0 + i * reactive.RETRY_COOLDOWN());
            _swap(-200); // through the stop
            _swap(20); // and back before the callback lands
            _react(_log(vault, FAILED_T0, 1, 2, _failed(1, _priceNotAtTrigger(20))));
        }
        assertEq(system.callbackCount(), rounds, "every round trip was still answered");

        // A real drop afterwards is still acted on.
        vm.warp(T0 + rounds * reactive.RETRY_COOLDOWN());
        _swap(-300);
        assertEq(system.callbackCount(), rounds + 1);
        _assertCallback(rounds, 1, 1, -120);
    }

    function test_attempts_swapFailuresAreCountedAndWindowResets() public {
        _create(1, _stopAndTp());
        uint256 max = reactive.MAX_ATTEMPTS();
        for (uint256 i = 0; i < max + 3; i++) {
            vm.warp(T0 + i * reactive.RETRY_COOLDOWN());
            _swap(-200);
            _react(
                _log(
                    vault,
                    FAILED_T0,
                    1,
                    2,
                    _failed(1, abi.encodeWithSignature("InsufficientOutput(uint256,uint256)", 1, 2))
                )
            );
        }
        assertEq(system.callbackCount(), max, "bounded within one window");

        // Once the window has passed the order is live again.
        vm.warp(T0 + reactive.ATTEMPT_WINDOW());
        _swap(-200);
        assertEq(system.callbackCount(), max + 1, "not disabled for good");
    }

    function test_expiry_isRequestedEvenWhenAttemptsAreExhausted() public {
        _create(1, _stopAndTp());
        uint256 max = reactive.MAX_ATTEMPTS();
        for (uint256 i = 0; i < max; i++) {
            vm.warp(uint256(EXPIRY) - 600 + i * reactive.PENDING_TIMEOUT());
            _swap(-200);
        }
        assertEq(system.callbackCount(), max);

        vm.warp(uint256(EXPIRY) + reactive.EXPIRY_GRACE() + 1);
        _swap(0);
        _assertCallback(max, 1, 4, 0);
        assertEq(reactive.activeIds().length, 0);
    }

    function test_expiry_closesSeveralOrdersInOneSwap() public {
        _create(1, _stopAndTp());
        _create(2, _stopAndTp());
        _create(3, _stopAndTp());
        vm.warp(uint256(EXPIRY) + reactive.EXPIRY_GRACE() + 1);
        _swap(0);
        assertEq(system.callbackCount(), 3, "untracking inside the loop skips nobody");
        assertEq(reactive.activeIds().length, 0);
    }

    /// R3: a swap that happened before the order existed, delivered afterwards, is ignored for it.
    function test_staleSwap_fromBeforeCreationDoesNotMovePeakOrTrigger() public {
        // Emitted first on the origin chain, but held back by the network.
        IReactive.LogRecord memory oldHigh =
            _logAt(manager, SWAP_T0, uint256(POOL_ID), 3, _swapData(500), 100, 1);
        IReactive.LogRecord memory oldLow =
            _logAt(manager, SWAP_T0, uint256(POOL_ID), 3, _swapData(0), 100, 2);

        Spec memory s = _stopAndTp();
        s.useStop = false;
        s.useTakeProfit = false;
        s.trailing = 100;
        _react(_logAt(vault, CREATED_T0, 1, 3, _createdData(s), 100, 3));

        _react(oldHigh);
        _react(oldLow);

        assertEq(system.callbackCount(), 0, "the order never saw those prices");
        int24 nPeak = reactive.getTracked(1).nPeak;
        assertEq(nPeak, 0);

        // A swap after creation works normally.
        _react(_logAt(manager, SWAP_T0, uint256(POOL_ID), 3, _swapData(-100), 100, 4));
        _assertCallback(0, 1, 3, -100);
    }

    function test_staleSwap_olderThanLastProcessedIsIgnored() public {
        _react(_logAt(vault, CREATED_T0, 1, 3, _createdData(_stopAndTp()), 100, 0));
        _react(_logAt(manager, SWAP_T0, uint256(POOL_ID), 3, _swapData(10), 200, 5));

        // An older swap that says the price is below the stop arrives late: not the current price.
        _react(_logAt(manager, SWAP_T0, uint256(POOL_ID), 3, _swapData(-500), 200, 4));
        _react(_logAt(manager, SWAP_T0, uint256(POOL_ID), 3, _swapData(-500), 199, 9));
        assertEq(system.callbackCount(), 0);

        // The same swap delivered twice counts once.
        _react(_logAt(manager, SWAP_T0, uint256(POOL_ID), 3, _swapData(-500), 200, 6));
        _react(_logAt(manager, SWAP_T0, uint256(POOL_ID), 3, _swapData(-500), 200, 6));
        assertEq(system.callbackCount(), 1);
    }

    function test_position_blockNumberOutranksLogIndex() public {
        _react(_logAt(vault, CREATED_T0, 1, 3, _createdData(_stopAndTp()), 100, 0));
        _react(_logAt(manager, SWAP_T0, uint256(POOL_ID), 3, _swapData(10), 200, 900));
        // Later block, smaller log index: still newer.
        _react(_logAt(manager, SWAP_T0, uint256(POOL_ID), 3, _swapData(-500), 201, 0));
        assertEq(system.callbackCount(), 1);
    }

    /// R5: a creation event arriving after the order's closing event must not leave a ghost.
    function test_track_createdAfterClosingEventIsIgnored() public {
        _vaultEvent(CANCELLED_T0, 1);
        _create(1, _stopAndTp());
        assertEq(reactive.activeIds().length, 0);
        assertTrue(reactive.closed(1));

        _swap(-500);
        assertEq(system.callbackCount(), 0);
    }

    function test_track_replayedCreatedAfterExecutionIsIgnored() public {
        _create(1, _stopAndTp());
        _react(_log(vault, EXECUTED_T0, 1, 2, abi.encode(uint8(1), uint256(1), int24(0), uint256(T0))));
        _create(1, _stopAndTp());
        assertEq(reactive.activeIds().length, 0);
    }

    function test_track_bookHasRoomForCreationBeforeAnOlderClose() public {
        // The vault allows 10 active orders. Created(new) can overtake Cancelled(old), so for a
        // moment the reactive side sees 11.
        for (uint256 i = 0; i < 10; i++) {
            _create(i, _stopAndTp());
        }
        _create(10, _stopAndTp());
        _vaultEvent(CANCELLED_T0, 0);

        bool active = reactive.getTracked(10).active;
        assertTrue(active, "the new order is watched");
        assertEq(reactive.activeIds().length, 10);
    }

    function test_track_emitsOrderDroppedWhenFull() public {
        uint256 max = reactive.MAX_TRACKED_ORDERS();
        for (uint256 i = 0; i < max; i++) {
            _create(i, _stopAndTp());
        }
        vm.expectEmit(true, false, false, false, address(reactive));
        emit OrderDropped(max);
        _create(max, _stopAndTp());
    }

    // ------------------------------------------------------------- odd inputs

    function test_trailing_unreachableLevelNeverTriggersOrReverts() public {
        // A distance no real order can have (the vault rejects it) puts the level below int24.
        Spec memory s = _trailingOnly();
        s.trailing = type(uint24).max;
        _create(1, s);
        _swap(-887_272);
        assertEq(system.callbackCount(), 0);
    }

    function test_vaultEvents_withWrongTopicCountAreIgnored() public {
        _create(1, _stopAndTp());

        // Closing events carry exactly two topics; anything else is not one of ours.
        _react(_log(vault, CANCELLED_T0, 1, 3, ""));
        _react(_log(vault, EXPIRED_T0, 1, 1, ""));
        _react(_log(vault, EXECUTED_T0, 1, 3, abi.encode(uint8(1), uint256(1), int24(0), uint256(T0))));
        assertEq(reactive.activeIds().length, 1, "still tracked");
        assertFalse(reactive.closed(1));

        // Same for the failure event: no cooldown is applied.
        _react(_log(vault, FAILED_T0, 1, 3, _failed(1, _priceNotAtTrigger(0))));
        assertEq(reactive.getTracked(1).notBefore, 0);
    }

    function test_failed_forUntrackedIdWritesNothing() public {
        _react(_log(vault, FAILED_T0, 99, 2, _failed(1, _priceNotAtTrigger(0))));
        assertEq(reactive.getTracked(99).notBefore, 0);
        assertFalse(reactive.getTracked(99).active);
    }

    /// N1. Expiry requests also count toward the per-transaction cap, so a crowd of expired
    /// orders cannot push one reactive transaction over the gas limit.
    function test_expiry_requestsAreBatchedLikeOtherTriggers() public {
        uint256 batch = reactive.MAX_TRIGGERS_PER_REACT();
        uint256 orders = batch + 2;
        for (uint256 i = 0; i < orders; i++) {
            _create(i, _stopAndTp());
        }
        vm.warp(uint256(EXPIRY) + reactive.EXPIRY_GRACE() + 1);

        _swap(0);
        assertEq(system.callbackCount(), batch, "one batch per reactive transaction");
        assertEq(reactive.activeIds().length, orders - batch);

        _swap(0);
        assertEq(system.callbackCount(), orders, "the rest on the next swap");
        assertEq(reactive.activeIds().length, 0);
        for (uint256 i = 0; i < orders; i++) {
            assertEq(
                uint8(uint256(_payloadWord(system.callbackAt(i).payload, 2))), 4, "every request is an expiry"
            );
        }
    }

    /// N2. The same failure event delivered twice refunds the attempt only once.
    function test_failed_duplicateDeliveryRefundsOnce() public {
        _create(1, _stopAndTp());
        _swap(-200);
        _swap(-200); // pending: no second trigger
        assertEq(reactive.getTracked(1).attempts, 1);

        IReactive.LogRecord memory failure = _log(vault, FAILED_T0, 1, 2, _failed(1, _priceNotAtTrigger(20)));
        _react(failure);
        assertEq(reactive.getTracked(1).attempts, 0, "refunded");

        // Exhaust the window with counted failures, then replay the old refund.
        uint256 max = reactive.MAX_ATTEMPTS();
        for (uint256 i = 0; i < max; i++) {
            vm.warp(T0 + (i + 1) * reactive.RETRY_COOLDOWN());
            _swap(-200);
            _react(
                _log(
                    vault,
                    FAILED_T0,
                    1,
                    2,
                    _failed(1, abi.encodeWithSignature("InsufficientOutput(uint256,uint256)", 1, 2))
                )
            );
        }
        assertEq(reactive.getTracked(1).attempts, max);
        _react(failure);
        _react(failure);
        assertEq(reactive.getTracked(1).attempts, max, "an old failure cannot hand attempts back");
    }

    /// Reads the n-th 32-byte argument of a call payload (0 = first argument after the selector).
    function _payloadWord(bytes memory payload_, uint256 n_) internal pure returns (bytes32 word) {
        assembly {
            word := mload(add(add(payload_, 36), mul(n_, 32)))
        }
    }

    function test_failed_malformedOrUnknownReasonOnlySetsCooldown() public {
        _create(1, _stopAndTp());
        _swap(-200);
        _react(_log(vault, FAILED_T0, 1, 2, hex"")); // no reason at all
        _react(_log(vault, FAILED_T0, 99, 2, _failed(1, _priceNotAtTrigger(0)))); // unknown id
        uint8 attempts = reactive.getTracked(1).attempts;
        assertEq(attempts, 1, "attempt still counted");
    }

    // ------------------------------------------------------------------ funds

    function test_coverDebt_paysSystemFromBalance() public {
        vm.deal(address(reactive), 1 ether);
        system.setDebt(address(reactive), 0.25 ether);
        uint256 before = SYSTEM_ADDR.balance;
        vm.prank(stranger);
        reactive.coverDebt();
        assertEq(SYSTEM_ADDR.balance - before, 0.25 ether);
    }

    /// The recovery the README describes: with too little balance the debt cannot be paid and
    /// stays; a plain transfer tops the contract up, then anyone can settle it.
    function test_coverDebt_underfundedRevertsThenTopUpSettlesIt() public {
        vm.deal(address(reactive), 0.4 ether);
        system.setDebt(address(reactive), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.InsufficientFunds.selector, 1 ether, 0.4 ether));
        reactive.coverDebt();
        assertEq(SYSTEM_ADDR.balance, 0, "nothing paid");

        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(reactive).call{value: 0.6 ether}("");
        assertTrue(ok, "plain transfer accepted");

        vm.prank(stranger);
        reactive.coverDebt();
        assertEq(SYSTEM_ADDR.balance, 1 ether, "debt paid");
        assertEq(address(reactive).balance, 0);
    }

    function test_withdraw_ownerOnly() public {
        vm.deal(address(reactive), 1 ether);
        vm.expectRevert(OcoReactive.NotOwner.selector);
        vm.prank(stranger);
        reactive.withdraw(1 ether);

        vm.prank(owner);
        reactive.withdraw(0.4 ether);
        assertEq(owner.balance, 0.4 ether);
        assertEq(address(reactive).balance, 0.6 ether);
    }

    // -------------------------------------------------------------------- many

    function test_manyOrders_eachEvaluatedIndependently() public {
        Spec memory s = _stopAndTp();
        s.nStop = -100;
        _create(1, s);
        s.nStop = -200;
        _create(2, s);
        s.nStop = -300;
        _create(3, s);

        _swap(-250);
        assertEq(system.callbackCount(), 2);
        _assertCallback(0, 1, 1, -100);
        _assertCallback(1, 2, 1, -200);

        _swap(-300);
        assertEq(system.callbackCount(), 3);
        _assertCallback(2, 3, 1, -300);
    }

    function test_batching_fullBookTriggersInBatchesAcrossSwaps() public {
        uint256 max = BOOK;
        uint256 batch = reactive.MAX_TRIGGERS_PER_REACT();
        for (uint256 i = 0; i < max; i++) {
            _create(i, _stopAndTp());
        }

        // Every order is at its stop, but one reactive transaction only requests one batch.
        _swap(-500);
        assertEq(system.callbackCount(), batch);
        // The next swaps pick up the rest; orders already pending are not repeated.
        _swap(-500);
        assertEq(system.callbackCount(), 2 * batch);
        _swap(-500);
        assertEq(system.callbackCount(), max);
        _swap(-500);
        assertEq(system.callbackCount(), max, "nothing left to trigger");

        // Each order was requested exactly once.
        bool[] memory seen = new bool[](max);
        for (uint256 i = 0; i < max; i++) {
            bytes memory payload = system.callbackAt(i).payload;
            uint256 id;
            assembly {
                id := mload(add(payload, 68)) // 4-byte selector + address word, then the id
            }
            assertFalse(seen[id], "order triggered twice");
            seen[id] = true;
        }
    }

    function test_batching_trailingPeakStillUpdatesForOrdersBeyondTheBatch() public {
        uint256 max = BOOK;
        for (uint256 i = 0; i < max; i++) {
            Spec memory s = _trailingOnly();
            s.useTakeProfit = true;
            s.nTakeProfit = 50; // all hit take-profit on the first swap
            _create(i, s);
        }
        _swap(300);
        assertEq(system.callbackCount(), reactive.MAX_TRIGGERS_PER_REACT());

        // The last order was beyond the batch, yet its peak moved to 300.
        int24 nPeak = reactive.getTracked(max - 1).nPeak;
        assertEq(nPeak, 300);
    }

    function test_gas_fullBookWithAFullBatchTriggering() public {
        uint256 max = BOOK;
        Spec memory s = _trailingOnly();
        s.useStop = true;
        s.nStop = -120;
        for (uint256 i = 0; i < max; i++) {
            _create(i, s);
        }
        IReactive.LogRecord memory log = _log(manager, SWAP_T0, uint256(POOL_ID), 3, _swapData(-500));

        // Swap in a system stand-in that emits an event per request, as the real one does,
        // instead of the bookkeeping mock whose storage writes would dominate the measurement.
        vm.etch(SYSTEM_ADDR, address(new EventSystem()).code);
        uint256 countBefore = EventSystem(payable(SYSTEM_ADDR)).callbackCount();

        vm.prank(SYSTEM_ADDR);
        uint256 before = gasleft();
        reactive.react(log);
        uint256 used = before - gasleft();

        assertEq(
            EventSystem(payable(SYSTEM_ADDR)).callbackCount() - countBefore, reactive.MAX_TRIGGERS_PER_REACT()
        );
        emit log_named_uint("react gas, 10 orders tracked, 4 triggering (event-emitting system)", used);
        // Reactive transactions are capped at 900,000 gas. Keep half of it as margin, because the
        // real system contract's cost per request is not known exactly.
        assertLt(used, 450_000);
    }

    function test_gas_fullBookNoneTriggering() public {
        uint256 max = BOOK;
        for (uint256 i = 0; i < max; i++) {
            _create(i, _stopAndTp());
        }
        IReactive.LogRecord memory log = _log(manager, SWAP_T0, uint256(POOL_ID), 3, _swapData(5));

        vm.prank(SYSTEM_ADDR);
        uint256 before = gasleft();
        reactive.react(log);
        uint256 used = before - gasleft();

        assertEq(system.callbackCount(), 0);
        emit log_named_uint("react gas, 10 orders none triggering", used);
        assertLt(used, 200_000);
    }

    // ------------------------------------------------- gas at the tracking cap

    /// Real reactive transactions on Lasna, read with `cast receipt <tx> gasUsed`:
    /// one order tracked and triggered (latency run round 1, 0x19e22f2d…3ce2) and three orders
    /// tracked and triggered in one transaction (0xb0f59b42…0c4d, see docs/tx-hashes.md).
    uint256 internal constant REAL_ONE_TRIGGER = 112_444;
    uint256 internal constant REAL_THREE_TRIGGERS = 171_802;
    /// Hard cap on a reactive transaction's gas.
    uint256 internal constant REACTIVE_GAS_CAP = 900_000;

    /// Gas of one `react`, with a system stand-in that emits an event per callback request as the
    /// real one does. Forge 1.9.0 runs tests with `isolate = true` by default (`forge config`), so
    /// each external call made by a test is its own transaction: a probe measured 21,543 gas for
    /// an empty call and 26,784 for a nonzero-to-nonzero write after earlier writes in the same
    /// test, the price of a cold, clean slot. The figure therefore includes the 21,000 base cost
    /// and fresh-transaction storage prices; `vm.cool` also makes the contract's address cold, as
    /// it is when the system calls it. Without isolation the measured figure would drop by about
    /// the base cost and the calibration's fixed part would absorb it.
    /// Also returns how many callback requests the call made.
    function _coldReactGas(IReactive.LogRecord memory log_)
        internal
        returns (uint256 used, uint256 requests)
    {
        vm.etch(SYSTEM_ADDR, address(new EventSystem()).code);
        // The stand-in's counter slot holds whatever the bookkeeping mock left there.
        uint256 countBefore = EventSystem(payable(SYSTEM_ADDR)).callbackCount();
        vm.cool(address(reactive));
        vm.cool(SYSTEM_ADDR);
        vm.prank(SYSTEM_ADDR);
        uint256 before = gasleft();
        reactive.react(log_);
        used = before - gasleft();
        requests = EventSystem(payable(SYSTEM_ADDR)).callbackCount() - countBefore;
    }

    /// `count_` stop orders at -120, a first swap that triggers nothing (so the newest-swap marker
    /// is already set, as on the live contract), then a measured swap that triggers them all.
    function _measureStops(uint256 count_) internal returns (uint256) {
        for (uint256 i = 0; i < count_; i++) {
            _create(i, _stopAndTp());
        }
        _swap(0);
        (uint256 used, uint256 requests) =
            _coldReactGas(_log(manager, SWAP_T0, uint256(POOL_ID), 3, _swapData(-200)));
        assertEq(requests, count_, "calibration: every order triggers");
        return used;
    }

    /// What the real network adds to this test's measurement: a fixed part (transaction, system
    /// contract dispatch, cold contract access) and a part per callback request, solved from the
    /// two real transactions above.
    function _calibration() internal returns (uint256 fixedPart, uint256 perRequest) {
        uint256 snap = vm.snapshotState();
        uint256 one = _measureStops(1);
        vm.revertToState(snap);
        uint256 three = _measureStops(3);
        vm.revertToState(snap);
        uint256 extraOne = REAL_ONE_TRIGGER - one;
        uint256 extraThree = REAL_THREE_TRIGGERS - three;
        perRequest = extraThree > extraOne ? (extraThree - extraOne) / 2 : 0;
        fixedPart = extraOne - perRequest;
        emit log_named_uint("test-measured react, 1 order triggering", one);
        emit log_named_uint("test-measured react, 3 orders triggering", three);
        emit log_named_uint("real network adds, fixed", fixedPart);
        emit log_named_uint("real network adds, per callback request", perRequest);
    }

    /// Fills the tracking cap with orders built by `spec_`, then sends the measured swap and
    /// checks the predicted real cost against the cap.
    function _assertCapFits(
        string memory label_,
        Spec memory spec_,
        int24 swapTick_,
        uint256 warpTo_,
        uint256 expectedRequests_
    ) internal {
        (uint256 fixedPart, uint256 perRequest) = _calibration();
        uint256 cap = reactive.MAX_TRACKED_ORDERS();
        for (uint256 i = 0; i < cap; i++) {
            _create(i, spec_);
        }
        assertEq(reactive.activeIds().length, cap, "tracking cap reached");
        _swap(0);
        if (warpTo_ != 0) vm.warp(warpTo_);

        (uint256 used, uint256 requests) =
            _coldReactGas(_log(manager, SWAP_T0, uint256(POOL_ID), 3, _swapData(swapTick_)));
        assertEq(requests, expectedRequests_, "callback requests");

        uint256 predicted = used + fixedPart + perRequest * expectedRequests_;
        emit log_named_string("scenario", label_);
        emit log_named_uint("test-measured react", used);
        emit log_named_uint("predicted on the real network", predicted);
        assertLt(predicted, REACTIVE_GAS_CAP, "a full book must fit one reactive transaction");
    }

    /// Out-of-sample check of the calibration against a real expiry transaction that was not used
    /// to calibrate: one order tracked, past expiry, one expiry request (Lasna 0x08d4c3a2…7af9777,
    /// 134,783 gas; docs/tx-hashes.md). What matters for the cap is that the model does not
    /// under-predict, so that side is held to 10%. It over-predicted this one by 9.8% (148,038);
    /// the upper bound of 20% only guards against the model drifting far from reality.
    function test_gasModel_predictsARealExpiryTransaction() public {
        (uint256 fixedPart, uint256 perRequest) = _calibration();
        _create(1, _stopAndTp());
        _swap(0);
        vm.warp(uint256(EXPIRY) + reactive.EXPIRY_GRACE() + 1);
        (uint256 used, uint256 requests) =
            _coldReactGas(_log(manager, SWAP_T0, uint256(POOL_ID), 3, _swapData(0)));
        assertEq(requests, 1);
        uint256 predicted = used + fixedPart + perRequest;
        uint256 real = 134_783;
        emit log_named_uint("predicted real expiry transaction", predicted);
        assertGe(predicted, real * 9 / 10, "the model under-predicts a real transaction");
        assertLe(predicted, real * 12 / 10, "the model is far from a real transaction");
    }

    /// 20 orders, every trailing peak moves, nothing triggers.
    function test_gasCap_twentyPeaksMoveNoneTrigger() public {
        Spec memory s = _trailingOnly();
        _assertCapFits("20 tracked, all peaks move, none trigger", s, 60, 0, 0);
    }

    /// 20 orders, every peak moves and a full batch of take-profits triggers.
    function test_gasCap_twentyPeaksMoveFullBatchTriggers() public {
        Spec memory s = _trailingOnly();
        s.useTakeProfit = true;
        s.nTakeProfit = 50;
        _assertCapFits("20 tracked, all peaks move, 4 trigger", s, 300, 0, reactive.MAX_TRIGGERS_PER_REACT());
    }

    /// 20 orders past expiry: a full batch of expiry requests, each untracking its order (the
    /// costliest path, it rewrites the id list and clears the order), while the rest's peaks move.
    function test_gasCap_twentyExpiredFullBatch() public {
        Spec memory s = _trailingOnly();
        _assertCapFits(
            "20 tracked, all expired, 4 expiry requests",
            s,
            60,
            uint256(EXPIRY) + reactive.EXPIRY_GRACE() + 1,
            reactive.MAX_TRIGGERS_PER_REACT()
        );
    }
}
