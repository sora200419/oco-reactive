// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title PingOrigin
/// @notice Origin-chain contract for the minimal loop: anyone can emit a `Ping`, which the reactive
///         contract on Reactive Network picks up.
contract PingOrigin {
    /// @notice Emitted on every ping.
    /// @param sender Caller of `ping()`.
    /// @param nonce Sequential id of this ping, unique per deployment.
    /// @param sentAt Origin-chain `block.timestamp` of the ping, used to measure loop latency.
    event Ping(address indexed sender, uint256 indexed nonce, uint256 sentAt);

    /// @notice Id the next ping will get.
    uint256 public nextNonce;

    /// @notice Emits a `Ping` event.
    /// @return nonce Id assigned to this ping.
    function ping() external returns (uint256 nonce) {
        nonce = nextNonce++;
        emit Ping(msg.sender, nonce, block.timestamp);
    }
}
