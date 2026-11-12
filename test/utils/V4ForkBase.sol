// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {TestToken} from "../../src/v4/TestToken.sol";
import {V4Swapper} from "../../src/v4/V4Swapper.sol";

/// Shared setup for tests that need a real Uniswap v4 pool: a pinned-block fork of Unichain Sepolia,
/// two test tokens, a hookless 0.3% pool at price 1:1 with liquidity, and a swapper. Nothing is
/// broadcast.
abstract contract V4ForkBase is Test, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal constant MANAGER = IPoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant FORK_BLOCK = 67_550_000;
    /// Fixed clock so no assertion depends on the fork block's real timestamp.
    uint256 internal constant T0 = 1_800_000_000;

    TestToken internal token0;
    TestToken internal token1;
    PoolKey internal key;
    PoolId internal poolId;
    V4Swapper internal swapper;
    address internal whale = makeAddr("whale");

    function _setUpPool() internal {
        vm.createSelectFork(vm.envOr("ORIGIN_RPC", string("https://sepolia.unichain.org")), FORK_BLOCK);
        vm.warp(T0);
        assertEq(block.chainid, 1301, "not Unichain Sepolia");

        TestToken a = new TestToken("Test A", "TSTA");
        TestToken b = new TestToken("Test B", "TSTB");
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolId = key.toId();
        MANAGER.initialize(key, SQRT_PRICE_1_1);

        token0.mint(address(this), 10_000_000e18);
        token1.mint(address(this), 10_000_000e18);
        _addLiquidity(-12000, 12000, 100_000e18);

        swapper = new V4Swapper(MANAGER);
        token0.mint(whale, 1_000_000e18);
        token1.mint(whale, 1_000_000e18);
        vm.startPrank(whale);
        token0.approve(address(swapper), type(uint256).max);
        token1.approve(address(swapper), type(uint256).max);
        vm.stopPrank();
    }

    function _addLiquidity(int24 lower_, int24 upper_, int256 liquidity_) internal {
        MANAGER.unlock(abi.encode(lower_, upper_, liquidity_));
    }

    function unlockCallback(bytes calldata data_) external returns (bytes memory) {
        require(msg.sender == address(MANAGER), "not manager");
        (int24 lower, int24 upper, int256 liquidity) = abi.decode(data_, (int24, int24, int256));
        (BalanceDelta delta,) = MANAGER.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: liquidity, salt: bytes32(0)
            }),
            ""
        );
        if (delta.amount0() < 0) _pay(key.currency0, uint256(uint128(-delta.amount0())));
        if (delta.amount1() < 0) _pay(key.currency1, uint256(uint128(-delta.amount1())));
        return "";
    }

    function _pay(Currency currency_, uint256 amount_) internal {
        MANAGER.sync(currency_);
        TestToken(Currency.unwrap(currency_)).transfer(address(MANAGER), amount_);
        MANAGER.settle();
    }

    /// Initialises a hookless 0.3% pool at price 1:1 pairing `token_` with token1. No liquidity.
    function _initPoolWith(address token_) internal returns (PoolKey memory k, bool tokenIsZero) {
        tokenIsZero = token_ < address(token1);
        k = PoolKey({
            currency0: Currency.wrap(tokenIsZero ? token_ : address(token1)),
            currency1: Currency.wrap(tokenIsZero ? address(token1) : token_),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        MANAGER.initialize(k, SQRT_PRICE_1_1);
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = MANAGER.getSlot0(poolId);
    }

    /// Whale sells token0, pushing the tick down.
    function _pushDown(uint256 amount0_) internal {
        vm.prank(whale);
        swapper.swapExactIn(key, true, amount0_, 0, whale);
    }

    /// Whale sells token1, pushing the tick up.
    function _pushUp(uint256 amount1_) internal {
        vm.prank(whale);
        swapper.swapExactIn(key, false, amount1_, 0, whale);
    }
}
