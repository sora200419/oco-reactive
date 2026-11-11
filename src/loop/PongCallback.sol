// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";

/// @title PongCallback
/// @notice Destination-chain contract for the minimal loop. Receives the `pong` callback and records
///         when it arrived.
contract PongCallback is AbstractCallback {
    /// @notice Emitted when a pong is delivered for the first time.
    /// @param nonce Id of the ping this answers.
    /// @param sentAt Origin-chain timestamp carried by the ping.
    /// @param receivedAt Destination-chain `block.timestamp` of delivery.
    event Pong(uint256 indexed nonce, uint256 sentAt, uint256 receivedAt);

    /// @notice Destination-chain timestamp at which each ping was answered. Zero if not yet answered.
    mapping(uint256 nonce => uint256 receivedAt) public receivedAt;

    /// @notice Number of distinct pings answered.
    uint256 public pongCount;

    /// @param callbackProxy_ Reactive callback proxy on this chain.
    /// @param callbackSender_ Address of `PingReactive` on Reactive Network. Immutable.
    /// @dev Payable so the contract can be funded at deployment; callbacks are billed to this
    ///      contract in the chain's native token.
    constructor(IPayable callbackProxy_, address callbackSender_)
        payable
        AbstractCallback(callbackProxy_, callbackSender_)
    {}

    /// @notice Callback entry point.
    /// @param reactive_ Address of the reactive contract that requested the callback, injected by the
    ///        network.
    /// @param nonce_ Id of the ping.
    /// @param sentAt_ Origin-chain timestamp of the ping.
    /// @dev A repeated delivery for the same nonce is ignored rather than reverted, because a failed
    ///      callback is still billed.
    function pong(address reactive_, uint256 nonce_, uint256 sentAt_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        if (receivedAt[nonce_] != 0) return;
        receivedAt[nonce_] = block.timestamp;
        pongCount++;
        emit Pong(nonce_, sentAt_, block.timestamp);
    }

    /// @notice Settles outstanding debt to the callback proxy from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }
}
