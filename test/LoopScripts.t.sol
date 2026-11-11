// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";

import {PingOrigin} from "../src/loop/PingOrigin.sol";
import {PingReactive} from "../src/loop/PingReactive.sol";
import {PongCallback} from "../src/loop/PongCallback.sol";
import {ChainGuard, DeployPingOrigin, DeployPingReactive, DeployPongCallback} from "../script/Loop.s.sol";
import {MockSystem} from "./mocks/MockSystem.sol";

/// Runs the deployment scripts in-process to check their wiring and the wrong-chain guard.
contract LoopScriptsTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address internal constant PROXY = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;

    function setUp() public {
        vm.etch(SYSTEM_ADDR, address(new MockSystem()).code);
        vm.setEnv("REACTIVE_CHAIN_ID", "5318007");
        vm.setEnv("ORIGIN_CHAIN_ID", "1301");
        vm.setEnv("DESTINATION_CHAIN_ID", "1301");
        vm.setEnv("DESTINATION_CALLBACK_PROXY_ADDR", vm.toString(PROXY));
        vm.setEnv("REACTIVE_FUNDING_WEI", "1000000000000000000");
        vm.setEnv("CALLBACK_FUNDING_WEI", "10000000000000000");
    }

    function test_scripts_deployAndWireTheLoop() public {
        vm.chainId(1301);
        PingOrigin origin = new DeployPingOrigin().run();
        vm.setEnv("PING_ORIGIN_ADDR", vm.toString(address(origin)));

        vm.chainId(5318007);
        PingReactive reactive = new DeployPingReactive().run();
        vm.setEnv("PING_REACTIVE_ADDR", vm.toString(address(reactive)));

        assertEq(reactive.ORIGIN_CHAIN_ID(), 1301);
        assertEq(reactive.ORIGIN_CONTRACT(), address(origin));
        assertEq(reactive.DESTINATION_CHAIN_ID(), 1301);
        assertEq(address(reactive).balance, 1 ether);
        assertEq(MockSystem(payable(SYSTEM_ADDR)).subscriptionCount(), 1);

        vm.chainId(1301);
        PongCallback callback = new DeployPongCallback().run();
        assertEq(address(callback._SERVICE_PROVIDER()), PROXY);
        assertEq(callback._CALLBACK_SENDER(), address(reactive));
        assertEq(address(callback).balance, 0.01 ether);
    }

    function test_scripts_refuseWrongChain() public {
        // The chain guard runs before any address variable is read, so this test sets none of
        // them and shares no mutable environment with the wiring test.
        DeployPingOrigin deployOrigin = new DeployPingOrigin();
        DeployPingReactive deployReactive = new DeployPingReactive();
        DeployPongCallback deployCallback = new DeployPongCallback();

        // Ethereum mainnet: every script must refuse.
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(ChainGuard.WrongChain.selector, 1301, 1));
        deployOrigin.run();
        vm.expectRevert(abi.encodeWithSelector(ChainGuard.WrongChain.selector, 5318007, 1));
        deployReactive.run();
        vm.expectRevert(abi.encodeWithSelector(ChainGuard.WrongChain.selector, 1301, 1));
        deployCallback.run();

        // The reactive script must also refuse the destination chain.
        vm.chainId(1301);
        vm.expectRevert(abi.encodeWithSelector(ChainGuard.WrongChain.selector, 5318007, 1301));
        deployReactive.run();
    }
}
