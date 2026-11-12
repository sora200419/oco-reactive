// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice System-contract stand-in for gas measurements. Like the real one (per the Reactive
///         docs) it answers a callback request by emitting `CallbackRequest` instead of storing
///         it, so the measured cost is not inflated by test bookkeeping. It is still only an
///         approximation of the real contract.
contract EventSystem {
    event CallbackRequest(
        uint256 indexed chainId,
        address indexed sender,
        address indexed recipient,
        ISystemContract.CallbackVersion version,
        bytes configuration
    );

    uint256 public callbackCount;

    receive() external payable {}

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        callbackCount++;
        emit CallbackRequest(
            config_.chainId,
            msg.sender,
            config_.recipient,
            ISystemContract.CallbackVersion.V_1_0,
            abi.encode(config_)
        );
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }
}
