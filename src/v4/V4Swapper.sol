// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @title V4Swapper
/// @notice Executes an exact-input swap of ERC-20 tokens directly against the Uniswap v4
///         PoolManager, without a router. This is the execution path the order vault will use.
/// @dev Spike contract: ERC-20 pairs only (no native ETH), single pool, no hooks data.
contract V4Swapper is IUnlockCallback {
    /// @notice `unlockCallback` was called by something other than the PoolManager.
    error NotPoolManager();
    /// @notice The swap produced less output than the caller's minimum.
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    /// @notice The swap did not consume the full input amount (price limit or no liquidity).
    error PartialFill(uint256 amountInUsed, uint256 amountIn);
    /// @notice The pool reported deltas with the wrong sign for an exact-input swap.
    error UnexpectedDelta(int128 inDelta, int128 outDelta);
    /// @notice The amount settled with the pool differs from the amount owed.
    error SettleMismatch(uint256 paid, uint256 owed);
    /// @notice A token transfer returned false or reverted.
    error TransferFailed();
    /// @notice The input amount does not fit the PoolManager's signed amount type.
    error AmountTooLarge();
    /// @notice The input amount is zero.
    error ZeroAmount();
    /// @notice The recipient is the zero address.
    error ZeroRecipient();

    /// @notice Emitted after a successful swap.
    /// @param payer Account the input tokens were pulled from.
    /// @param recipient Account that received the output tokens.
    /// @param zeroForOne True when selling currency0 for currency1.
    /// @param amountIn Input amount.
    /// @param amountOut Output amount.
    event Swapped(
        address indexed payer, address indexed recipient, bool zeroForOne, uint256 amountIn, uint256 amountOut
    );

    /// @notice The Uniswap v4 PoolManager this contract trades against.
    IPoolManager public immutable POOL_MANAGER;

    struct SwapRequest {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint256 minAmountOut;
        address payer;
        address recipient;
    }

    /// @param poolManager_ Address of the v4 PoolManager on this chain.
    constructor(IPoolManager poolManager_) {
        POOL_MANAGER = poolManager_;
    }

    /// @notice Sells exactly `amountIn_` of one pool currency for the other.
    /// @dev The caller must have approved this contract for `amountIn_` of the input token.
    ///      Limits, all deliberate for this version: tokens must return a bool from `transferFrom`
    ///      and deliver the full amount (no fee-on-transfer); the swap is all-or-nothing, so a pool
    ///      too thin to absorb `amountIn_` makes the call revert; verified on pools without hooks
    ///      only, since a hook can change the amounts swapped.
    /// @param key_ Pool to trade in.
    /// @param zeroForOne_ True to sell currency0 for currency1, false for the reverse.
    /// @param amountIn_ Exact amount of the input token to sell.
    /// @param minAmountOut_ Minimum acceptable output; the call reverts below it.
    /// @param recipient_ Account that receives the output tokens.
    /// @return amountOut Amount of the output token sent to `recipient_`.
    function swapExactIn(
        PoolKey calldata key_,
        bool zeroForOne_,
        uint256 amountIn_,
        uint256 minAmountOut_,
        address recipient_
    ) external returns (uint256 amountOut) {
        if (amountIn_ == 0) revert ZeroAmount();
        // Safe: int256.max is positive, so the cast to uint256 is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (amountIn_ > uint256(type(int256).max)) revert AmountTooLarge();
        if (recipient_ == address(0)) revert ZeroRecipient();
        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(
                SwapRequest({
                    key: key_,
                    zeroForOne: zeroForOne_,
                    amountIn: amountIn_,
                    minAmountOut: minAmountOut_,
                    payer: msg.sender,
                    recipient: recipient_
                })
            )
        );
        amountOut = abi.decode(result, (uint256));
        // Emitted after the external call because the output amount is only known then. The
        // PoolManager's own lock makes a nested unlock revert, so the log cannot be reordered.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Swapped(msg.sender, recipient_, zeroForOne_, amountIn_, amountOut);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Runs inside `PoolManager.unlock`. Swaps, pays the input owed, and takes the output.
    function unlockCallback(bytes calldata data_) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        SwapRequest memory req = abi.decode(data_, (SwapRequest));

        // Negative amountSpecified means exact input. The price limit is set to the extreme so the
        // only slippage control is minAmountOut.
        BalanceDelta delta = POOL_MANAGER.swap(
            req.key,
            IPoolManager.SwapParams({
                zeroForOne: req.zeroForOne,
                // Safe: swapExactIn rejects amounts above int256.max.
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(req.amountIn),
                sqrtPriceLimitX96: req.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // From this contract's point of view: negative = owed to the pool, positive = owed to us.
        (int128 inDelta, int128 outDelta) =
            req.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        if (inDelta > 0 || outDelta < 0) revert UnexpectedDelta(inDelta, outDelta);
        // Both casts are safe: the signs were just checked, and -inDelta cannot overflow because
        // inDelta is at most zero and int128.min would mean an input larger than any token supply.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountInUsed = uint256(uint128(-inDelta));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountOut = uint256(uint128(outDelta));

        if (amountInUsed != req.amountIn) revert PartialFill(amountInUsed, req.amountIn);
        if (amountOut < req.minAmountOut) revert InsufficientOutput(amountOut, req.minAmountOut);

        (Currency currencyIn, Currency currencyOut) =
            req.zeroForOne ? (req.key.currency0, req.key.currency1) : (req.key.currency1, req.key.currency0);

        // Pay the input: sync, transfer straight from the payer to the manager, then settle.
        POOL_MANAGER.sync(currencyIn);
        // `payer` is always the caller of swapExactIn: this function is manager-only, and the
        // manager calls back whoever called unlock, which for this contract is swapExactIn alone.
        IERC20Minimal tokenIn = IERC20Minimal(Currency.unwrap(currencyIn));
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        bool sent = tokenIn.transferFrom(req.payer, address(POOL_MANAGER), amountInUsed);
        if (!sent) revert TransferFailed();
        // A fee-on-transfer token would arrive short; refuse instead of leaving a debt.
        uint256 paid = POOL_MANAGER.settle();
        if (paid != amountInUsed) revert SettleMismatch(paid, amountInUsed);

        // Collect the output directly to the recipient.
        POOL_MANAGER.take(currencyOut, req.recipient, amountOut);

        return abi.encode(amountOut);
    }
}
