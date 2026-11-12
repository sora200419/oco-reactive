// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @title DemoLiquidity
/// @notice Adds liquidity to a Uniswap v4 pool for the testnet demo. An account cannot call the
///         PoolManager's `unlock` itself, so this contract does it and pays the tokens owed from
///         the caller's balance.
/// @dev Demo infrastructure only: ERC-20 pairs, no hooks data, no way to remove the liquidity.
///      Every position belongs to this contract, so whoever adds to a range shares it and its fees.
contract DemoLiquidity is IUnlockCallback {
    /// @notice `unlockCallback` was called by something other than the PoolManager.
    error NotPoolManager();
    /// @notice The liquidity amount is zero or does not fit the PoolManager's signed type.
    error BadLiquidity();
    /// @notice A token transfer returned false.
    error TransferFailed();
    /// @notice The PoolManager received a different amount than owed (fee-on-transfer token).
    error SettleMismatch(uint256 paid, uint256 owed);

    /// @notice Emitted after liquidity is added.
    /// @param provider Account the tokens were taken from.
    /// @param amount0 Amount of currency0 paid.
    /// @param amount1 Amount of currency1 paid.
    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1);

    /// @notice The Uniswap v4 PoolManager.
    IPoolManager public immutable POOL_MANAGER;

    struct Request {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        address payer;
    }

    /// @param poolManager_ Address of the v4 PoolManager on this chain.
    constructor(IPoolManager poolManager_) {
        POOL_MANAGER = poolManager_;
    }

    /// @notice Adds a liquidity position owned by this contract, paid for by the caller.
    /// @dev The caller must have approved this contract for enough of both tokens.
    /// @param key_ Pool to add to.
    /// @param tickLower_ Lower tick of the range.
    /// @param tickUpper_ Upper tick of the range.
    /// @param liquidity_ Liquidity to add.
    /// @return amount0 Amount of currency0 paid.
    /// @return amount1 Amount of currency1 paid.
    function addLiquidity(PoolKey calldata key_, int24 tickLower_, int24 tickUpper_, uint128 liquidity_)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        // Safe: int128.max is positive, so the cast is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (liquidity_ == 0 || liquidity_ > uint128(type(int128).max)) revert BadLiquidity();
        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(
                Request({
                    key: key_,
                    tickLower: tickLower_,
                    tickUpper: tickUpper_,
                    liquidity: liquidity_,
                    payer: msg.sender
                })
            )
        );
        (amount0, amount1) = abi.decode(result, (uint256, uint256));
        // Emitted after the call because the amounts are only known then; the PoolManager lock
        // stops any nested unlock, so the log cannot be reordered.
        // forge-lint: disable-next-line(reentrancy-events)
        emit LiquidityAdded(msg.sender, amount0, amount1);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data_) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        Request memory req = abi.decode(data_, (Request));
        // The fee delta is already folded into the caller delta, so it is not needed separately.
        BalanceDelta delta;
        // forge-lint: disable-next-line(unused-return)
        (delta,) = POOL_MANAGER.modifyLiquidity(
            req.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: req.tickLower,
                tickUpper: req.tickUpper,
                // Safe: addLiquidity rejects values above int128.max.
                // forge-lint: disable-next-line(unsafe-typecast)
                liquidityDelta: int256(uint256(req.liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        uint256 amount0 = _settle(req.key.currency0, delta.amount0(), req.payer);
        uint256 amount1 = _settle(req.key.currency1, delta.amount1(), req.payer);
        return abi.encode(amount0, amount1);
    }

    /// @dev Settles one currency. A negative delta is owed and paid from `payer_`. A positive one
    ///      happens when the position already exists and its accrued fees exceed what the new
    ///      liquidity costs; that credit is sent to `payer_`. Returns the amount paid.
    function _settle(Currency currency_, int128 delta_, address payer_) internal returns (uint256 amount) {
        if (delta_ == 0) return 0;
        if (delta_ > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            POOL_MANAGER.take(currency_, payer_, uint256(uint128(delta_)));
            return 0;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        amount = uint256(uint128(-delta_));
        POOL_MANAGER.sync(currency_);
        IERC20Minimal token = IERC20Minimal(Currency.unwrap(currency_));
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        bool sent = token.transferFrom(payer_, address(POOL_MANAGER), amount);
        if (!sent) revert TransferFailed();
        uint256 paid = POOL_MANAGER.settle();
        if (paid != amount) revert SettleMismatch(paid, amount);
    }
}
