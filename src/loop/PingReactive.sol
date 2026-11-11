// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";

/// @title PingReactive
/// @notice Reactive contract for the minimal loop. Subscribes to `Ping` on the origin chain and, for
///         each one, asks the system contract to deliver a `pong` callback on the destination chain.
/// @dev Written against Reactive Omni: `react()` is called by the system contract and callbacks are
///      requested through `SYSTEM.requestCallbackV_1_0`.
contract PingReactive is AbstractReactive {
    /// @notice The caller is not the owner.
    error NotOwner();
    /// @notice The recipient has already been set and cannot be changed.
    error RecipientAlreadySet();
    /// @notice The zero address is not a valid recipient.
    error ZeroRecipient();
    /// @notice The zero address is not a valid origin contract.
    error ZeroOrigin();

    /// @notice Emitted once, when the callback recipient is set.
    event RecipientSet(address indexed recipient);
    /// @notice Emitted when a callback is requested for a ping.
    event PongRequested(uint256 indexed nonce, uint256 sentAt);

    /// @notice topic0 of `Ping(address,uint256,uint256)`.
    uint256 public constant PING_TOPIC_0 = uint256(keccak256("Ping(address,uint256,uint256)"));

    /// @notice Gas limit requested for the destination call. The callback proxy withholds part of it
    ///         for its own accounting, so this is well above what `pong` itself needs.
    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;

    /// @notice Account allowed to set the recipient.
    address public immutable OWNER;
    /// @notice Chain the `Ping` events come from.
    uint256 public immutable ORIGIN_CHAIN_ID;
    /// @notice Contract emitting the `Ping` events.
    address public immutable ORIGIN_CONTRACT;
    /// @notice Chain the callback is delivered to.
    uint256 public immutable DESTINATION_CHAIN_ID;

    /// @notice Callback contract on the destination chain. Zero until set.
    address public recipient;

    /// @param originChainId_ Chain id of the origin chain.
    /// @param originContract_ Address of `PingOrigin` on the origin chain.
    /// @param destinationChainId_ Chain id of the destination chain.
    /// @dev Payable so the contract can be funded at deployment; reactive transactions are paid for
    ///      from this balance.
    constructor(uint256 originChainId_, address originContract_, uint256 destinationChainId_) payable {
        // address(0) is the subscription wildcard: it would match every contract on the chain.
        if (originContract_ == address(0)) revert ZeroOrigin();
        OWNER = msg.sender;
        ORIGIN_CHAIN_ID = originChainId_;
        ORIGIN_CONTRACT = originContract_;
        DESTINATION_CHAIN_ID = destinationChainId_;

        SYSTEM.subscribe(
            originChainId_, originContract_, PING_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    /// @notice Sets the destination callback contract. Can be called once, by the owner.
    /// @dev The callback contract needs this contract's address at construction, so it is deployed
    ///      second and wired in here. A wrong address cannot be corrected: redeploy both contracts.
    /// @param recipient_ Address of `PongCallback` on the destination chain.
    function setRecipient(address recipient_) external {
        if (msg.sender != OWNER) revert NotOwner();
        if (recipient != address(0)) revert RecipientAlreadySet();
        if (recipient_ == address(0)) revert ZeroRecipient();
        recipient = recipient_;
        emit RecipientSet(recipient_);
    }

    /// @inheritdoc IReactive
    /// @dev Logs that do not match fall through without reverting: a revert is still billed.
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.chainId != ORIGIN_CHAIN_ID || log_.contractAddress != ORIGIN_CONTRACT) return;
        // Ping has two indexed parameters, so the log carries three topics.
        if (log_.topic0 != PING_TOPIC_0 || log_.opCode != 3) return;
        if (log_.data.length != 32) return;

        address recipient_ = recipient;
        if (recipient_ == address(0)) return;

        uint256 nonce = log_.topic2;
        uint256 sentAt = abi.decode(log_.data, (uint256));

        // The first argument is a placeholder: the network overwrites it with this contract's
        // address so the destination can authenticate the sender.
        bytes memory payload =
            abi.encodeWithSignature("pong(address,uint256,uint256)", address(0), nonce, sentAt);

        emit PongRequested(nonce, sentAt);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: DESTINATION_CHAIN_ID,
                recipient: recipient_,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            })
        );
    }

    /// @notice Settles outstanding debt to the system contract from this contract's balance.
    /// @dev Open to anyone so the contract can be revived by whoever funds it.
    function coverDebt() external {
        _coverDebt();
    }
}
