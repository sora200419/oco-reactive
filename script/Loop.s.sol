// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";

import {PingOrigin} from "../src/loop/PingOrigin.sol";
import {PingReactive} from "../src/loop/PingReactive.sol";
import {PongCallback} from "../src/loop/PongCallback.sol";

// Deployment scripts for the minimal loop. Run them in this order:
//   1. DeployPingOrigin   on the origin chain
//   2. DeployPingReactive on Lasna
//   3. DeployPongCallback on the destination chain
//   4. `setRecipient` on PingReactive (see README)
//
// The signer is supplied on the command line (`--account <keystore>`); no private key is read from
// the environment. Every script refuses to run on a chain other than the one named in the env file.

/// @dev Shared guard against broadcasting to the wrong network.
abstract contract ChainGuard is Script {
    error WrongChain(uint256 expected, uint256 actual);

    function _requireChain(uint256 expected_) internal view {
        if (block.chainid != expected_) revert WrongChain(expected_, block.chainid);
    }
}

/// @notice Step 1: deploys `PingOrigin` on the origin chain.
contract DeployPingOrigin is ChainGuard {
    /// @notice Reads `ORIGIN_CHAIN_ID`, then broadcasts the deployment.
    /// @return origin The deployed contract.
    function run() external returns (PingOrigin origin) {
        _requireChain(vm.envUint("ORIGIN_CHAIN_ID"));

        vm.startBroadcast();
        origin = new PingOrigin();
        vm.stopBroadcast();

        console.log("PingOrigin:", address(origin));
    }
}

/// @notice Step 2: deploys `PingReactive` on Reactive Network and funds it.
contract DeployPingReactive is ChainGuard {
    /// @notice Reads `REACTIVE_CHAIN_ID`, `ORIGIN_CHAIN_ID`, `PING_ORIGIN_ADDR`, `DESTINATION_CHAIN_ID`
    ///         and `REACTIVE_FUNDING_WEI`, then broadcasts the deployment.
    /// @return reactive The deployed contract.
    function run() external returns (PingReactive reactive) {
        _requireChain(vm.envUint("REACTIVE_CHAIN_ID"));
        uint256 originChainId = vm.envUint("ORIGIN_CHAIN_ID");
        address originContract = vm.envAddress("PING_ORIGIN_ADDR");
        uint256 destinationChainId = vm.envUint("DESTINATION_CHAIN_ID");
        uint256 funding = vm.envUint("REACTIVE_FUNDING_WEI");

        vm.startBroadcast();
        reactive = new PingReactive{value: funding}(originChainId, originContract, destinationChainId);
        vm.stopBroadcast();

        console.log("PingReactive:", address(reactive));
    }
}

/// @notice Step 3: deploys `PongCallback` on the destination chain and funds it.
contract DeployPongCallback is ChainGuard {
    /// @notice Reads `DESTINATION_CHAIN_ID`, `DESTINATION_CALLBACK_PROXY_ADDR`, `PING_REACTIVE_ADDR` and
    ///         `CALLBACK_FUNDING_WEI`, then broadcasts the deployment.
    /// @return callback The deployed contract.
    function run() external returns (PongCallback callback) {
        _requireChain(vm.envUint("DESTINATION_CHAIN_ID"));
        address proxy = vm.envAddress("DESTINATION_CALLBACK_PROXY_ADDR");
        address reactive = vm.envAddress("PING_REACTIVE_ADDR");
        uint256 funding = vm.envUint("CALLBACK_FUNDING_WEI");

        vm.startBroadcast();
        callback = new PongCallback{value: funding}(IPayable(payable(proxy)), reactive);
        vm.stopBroadcast();

        console.log("PongCallback:", address(callback));
    }
}
