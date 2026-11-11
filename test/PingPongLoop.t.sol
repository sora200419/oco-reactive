// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";

import {PingOrigin} from "../src/loop/PingOrigin.sol";
import {PingReactive} from "../src/loop/PingReactive.sol";
import {PongCallback} from "../src/loop/PongCallback.sol";
import {MockSystem} from "./mocks/MockSystem.sol";

contract PingPongLoopTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant REACTIVE_IGNORE =
        0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    uint256 internal constant PING_TOPIC_0 = uint256(keccak256("Ping(address,uint256,uint256)"));
    uint256 internal constant ORIGIN_CHAIN = 1301;
    uint256 internal constant DEST_CHAIN = 1301;
    // Fixed start time so no assertion depends on the wall clock.
    uint256 internal constant T0 = 1_800_000_000;

    MockSystem internal system = MockSystem(payable(SYSTEM_ADDR));
    address internal proxy = makeAddr("callbackProxy");
    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    PingOrigin internal origin;
    PingReactive internal reactive;
    PongCallback internal callback;

    event Pong(uint256 indexed nonce, uint256 sentAt, uint256 receivedAt);

    function setUp() public {
        vm.warp(T0);
        vm.etch(SYSTEM_ADDR, address(new MockSystem()).code);

        origin = new PingOrigin();
        vm.prank(owner);
        reactive = new PingReactive(ORIGIN_CHAIN, address(origin), DEST_CHAIN);
        callback = new PongCallback(IPayable(payable(proxy)), address(reactive));
    }

    // ---------------------------------------------------------------- helpers

    function _pingLog(uint256 nonce_, uint256 sentAt_) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: address(origin),
            // Computed locally: an external read here would consume a pending vm.prank.
            topic0: PING_TOPIC_0,
            topic1: uint256(uint160(stranger)),
            topic2: nonce_,
            topic3: 0,
            data: abi.encode(sentAt_),
            blockNumber: 1,
            opCode: 3,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _setRecipient() internal {
        vm.prank(owner);
        reactive.setRecipient(address(callback));
    }

    /// Mimics the network: overwrite the first argument with the requesting reactive contract.
    function _injectSender(bytes memory payload_, address sender_) internal pure returns (bytes memory) {
        bytes32 word = bytes32(uint256(uint160(sender_)));
        assembly {
            mstore(add(payload_, 36), word)
        }
        return payload_;
    }

    // ----------------------------------------------------------- PingOrigin

    function test_ping_emitsSequentialNonces() public {
        vm.recordLogs();
        vm.prank(stranger);
        assertEq(origin.ping(), 0);
        vm.prank(stranger);
        assertEq(origin.ping(), 1);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(uint256(logs[0].topics[0]), reactive.PING_TOPIC_0());
        assertEq(logs[0].topics.length, 3);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), stranger);
        assertEq(uint256(logs[1].topics[2]), 1);
        assertEq(abi.decode(logs[0].data, (uint256)), T0);
    }

    // --------------------------------------------------------- PingReactive

    function test_constructor_subscribesToPing() public view {
        assertEq(system.subscriptionCount(), 1);
        MockSystem.Subscription memory s = system.subscriptionAt(0);
        assertEq(s.subscriber, address(reactive));
        assertEq(s.chainId, ORIGIN_CHAIN);
        assertEq(s.contractAddr, address(origin));
        assertEq(s.topic0, uint256(keccak256("Ping(address,uint256,uint256)")));
        assertEq(s.topic1, REACTIVE_IGNORE);
        assertEq(s.topic2, REACTIVE_IGNORE);
        assertEq(s.topic3, REACTIVE_IGNORE);
    }

    function test_constructor_rejectsZeroOrigin() public {
        vm.expectRevert(PingReactive.ZeroOrigin.selector);
        new PingReactive(ORIGIN_CHAIN, address(0), DEST_CHAIN);
    }

    function test_react_revertsForNonSystemCaller() public {
        _setRecipient();
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, SYSTEM_ADDR));
        vm.prank(stranger);
        reactive.react(_pingLog(0, T0));
    }

    function test_react_requestsCallbackWithPlaceholderSender() public {
        _setRecipient();
        vm.prank(SYSTEM_ADDR);
        reactive.react(_pingLog(7, T0));

        assertEq(system.callbackCount(), 1);
        MockSystem.CallbackRequest memory c = system.callbackAt(0);
        assertEq(c.sender, address(reactive));
        assertEq(c.chainId, DEST_CHAIN);
        assertEq(c.recipient, address(callback));
        assertEq(c.gasLimit, reactive.CALLBACK_GAS_LIMIT());
        assertEq(
            c.payload, abi.encodeWithSelector(PongCallback.pong.selector, address(0), uint256(7), uint256(T0))
        );
    }

    function test_react_ignoresWhenRecipientUnset() public {
        vm.prank(SYSTEM_ADDR);
        reactive.react(_pingLog(0, T0));
        assertEq(system.callbackCount(), 0);
    }

    function test_react_ignoresNonMatchingLogs() public {
        _setRecipient();

        IReactive.LogRecord memory log = _pingLog(0, T0);
        log.chainId = 84532;
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);

        log = _pingLog(0, T0);
        log.contractAddress = stranger;
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);

        log = _pingLog(0, T0);
        log.topic0 = uint256(keccak256("Other(uint256)"));
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);

        log = _pingLog(0, T0);
        log.opCode = 1;
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);

        log = _pingLog(0, T0);
        log.data = "";
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);

        assertEq(system.callbackCount(), 0);
    }

    function test_setRecipient_onlyOwner() public {
        vm.expectRevert(PingReactive.NotOwner.selector);
        vm.prank(stranger);
        reactive.setRecipient(address(callback));
    }

    function test_setRecipient_rejectsZero() public {
        vm.expectRevert(PingReactive.ZeroRecipient.selector);
        vm.prank(owner);
        reactive.setRecipient(address(0));
    }

    function test_setRecipient_onlyOnce() public {
        _setRecipient();
        vm.expectRevert(PingReactive.RecipientAlreadySet.selector);
        vm.prank(owner);
        reactive.setRecipient(stranger);
        assertEq(reactive.recipient(), address(callback));
    }

    function test_coverDebt_paysSystemFromBalance() public {
        vm.deal(address(reactive), 1 ether);
        system.setDebt(address(reactive), 0.25 ether);
        uint256 before = SYSTEM_ADDR.balance;

        vm.prank(stranger);
        reactive.coverDebt();

        assertEq(SYSTEM_ADDR.balance - before, 0.25 ether);
        assertEq(address(reactive).balance, 0.75 ether);
    }

    function test_coverDebt_revertsWhenUnderfunded() public {
        system.setDebt(address(reactive), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.InsufficientFunds.selector, 1 ether, 0));
        reactive.coverDebt();
    }

    // --------------------------------------------------------- PongCallback

    function test_pong_revertsWhenCallerIsNotProxy() public {
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, proxy));
        vm.prank(stranger);
        callback.pong(address(reactive), 0, T0);
    }

    function test_pong_revertsWhenSenderIsNotOurReactive() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                AbstractCallback.CallbackNotAuthorized.selector, stranger, address(reactive)
            )
        );
        vm.prank(proxy);
        callback.pong(stranger, 0, T0);
    }

    function test_pong_recordsDeliveryTimestamp() public {
        vm.warp(T0 + 3);
        vm.expectEmit(true, false, false, true, address(callback));
        emit Pong(5, T0, T0 + 3);
        vm.prank(proxy);
        callback.pong(address(reactive), 5, T0);

        assertEq(callback.receivedAt(5), T0 + 3);
        assertEq(callback.pongCount(), 1);
    }

    function test_pong_duplicateIsIgnoredWithoutRevert() public {
        vm.prank(proxy);
        callback.pong(address(reactive), 5, T0);

        vm.warp(T0 + 10);
        vm.recordLogs();
        vm.prank(proxy);
        callback.pong(address(reactive), 5, T0);

        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(callback.receivedAt(5), T0);
        assertEq(callback.pongCount(), 1);
    }

    // ------------------------------------------------------------ full loop

    /// Origin event -> react() -> recorded callback request -> proxy delivery, all from real logs.
    function test_fullLoop_fromOriginEventToCallback() public {
        _setRecipient();

        vm.recordLogs();
        vm.prank(stranger);
        uint256 nonce = origin.ping();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);

        IReactive.LogRecord memory rec = IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: logs[0].emitter,
            topic0: uint256(logs[0].topics[0]),
            topic1: uint256(logs[0].topics[1]),
            topic2: uint256(logs[0].topics[2]),
            topic3: 0,
            data: logs[0].data,
            blockNumber: block.number,
            opCode: logs[0].topics.length,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });

        vm.warp(T0 + 1);
        vm.prank(SYSTEM_ADDR);
        reactive.react(rec);
        assertEq(system.callbackCount(), 1);
        MockSystem.CallbackRequest memory c = system.callbackAt(0);

        vm.warp(T0 + 2);
        bytes memory delivered = _injectSender(c.payload, c.sender);
        vm.prank(proxy);
        (bool ok,) = c.recipient.call{gas: c.gasLimit}(delivered);
        assertTrue(ok);

        assertEq(callback.receivedAt(nonce), T0 + 2);
        assertEq(callback.pongCount(), 1);
    }

    /// A payload delivered without the sender injection (first argument still zero) must be rejected.
    function test_fullLoop_uninjectedPayloadIsRejected() public {
        _setRecipient();
        vm.prank(SYSTEM_ADDR);
        reactive.react(_pingLog(0, T0));
        MockSystem.CallbackRequest memory c = system.callbackAt(0);

        vm.prank(proxy);
        (bool ok,) = c.recipient.call(c.payload);
        assertFalse(ok);
        assertEq(callback.pongCount(), 0);
    }
}
