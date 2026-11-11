// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Test double for the Reactive system contract. Its code is etched at the real system
///         address so contracts under test talk to it unchanged. It records subscriptions and
///         callback requests instead of acting on them.
contract MockSystem {
    struct Subscription {
        address subscriber;
        uint256 chainId;
        address contractAddr;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    struct CallbackRequest {
        address sender;
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    Subscription[] internal _subscriptions;
    CallbackRequest[] internal _callbacks;
    mapping(address => uint256) public debt;

    receive() external payable {}

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 t0_,
        uint256 t1_,
        uint256 t2_,
        uint256 t3_
    ) external {
        _subscriptions.push(Subscription(msg.sender, chainId_, contract_, t0_, t1_, t2_, t3_));
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        _callbacks.push(
            CallbackRequest(msg.sender, config_.chainId, config_.recipient, config_.gasLimit, config_.payload)
        );
    }

    function setDebt(address contract_, uint256 amount_) external {
        debt[contract_] = amount_;
    }

    function subscriptionCount() external view returns (uint256) {
        return _subscriptions.length;
    }

    function subscriptionAt(uint256 i_) external view returns (Subscription memory) {
        return _subscriptions[i_];
    }

    function callbackCount() external view returns (uint256) {
        return _callbacks.length;
    }

    function callbackAt(uint256 i_) external view returns (CallbackRequest memory) {
        return _callbacks[i_];
    }
}
