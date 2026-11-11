// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {TestToken} from "../src/v4/TestToken.sol";
import {V4Swapper} from "../src/v4/V4Swapper.sol";
import {WeirdToken} from "./mocks/WeirdToken.sol";

/// Fork test against the real Uniswap v4 PoolManager on Unichain Sepolia. Nothing is broadcast.
/// It answers the spike questions: can a contract swap on v4 without a router, and what exactly
/// does the `Swap` event look like to a subscriber.
contract V4SwapperForkTest is Test, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal constant MANAGER = IPoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);
    /// topic0 of Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)
    bytes32 internal constant SWAP_TOPIC_0 =
        0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant FORK_BLOCK = 67_550_000;

    TestToken internal token0;
    TestToken internal token1;
    PoolKey internal key;
    PoolId internal poolId;
    V4Swapper internal swapper;

    address internal trader = makeAddr("trader");
    address internal recipient = makeAddr("recipient");

    struct SwapLog {
        bytes32 id;
        address sender;
        int128 amount0;
        int128 amount1;
        uint160 sqrtPriceX96;
        uint128 liquidity;
        int24 tick;
        uint24 fee;
        uint256 topicCount;
        uint256 dataLength;
    }

    function setUp() public {
        // Pinned block: results are reproducible and nobody can front-run the pool this test creates.
        vm.createSelectFork(vm.envOr("ORIGIN_RPC", string("https://sepolia.unichain.org")), FORK_BLOCK);
        assertEq(block.chainid, 1301, "not Unichain Sepolia");
        assertGt(address(MANAGER).code.length, 0, "no PoolManager at the documented address");

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

        // Liquidity provided by this test contract through its own unlock callback.
        token0.mint(address(this), 1_000_000e18);
        token1.mint(address(this), 1_000_000e18);
        _addLiquidity(key, -6000, 6000, 100_000e18);

        swapper = new V4Swapper(MANAGER);
        token0.mint(trader, 1_000e18);
        token1.mint(trader, 1_000e18);
        vm.startPrank(trader);
        token0.approve(address(swapper), type(uint256).max);
        token1.approve(address(swapper), type(uint256).max);
        vm.stopPrank();
    }

    function _addLiquidity(PoolKey memory key_, int24 lower_, int24 upper_, int256 liquidity_) internal {
        MANAGER.unlock(abi.encode(key_, lower_, upper_, liquidity_));
    }

    /// Liquidity helper: add a position and pay both currencies.
    function unlockCallback(bytes calldata data_) external returns (bytes memory) {
        require(msg.sender == address(MANAGER), "not manager");
        (PoolKey memory k, int24 lower, int24 upper, int256 liquidity) =
            abi.decode(data_, (PoolKey, int24, int24, int256));
        (BalanceDelta delta,) = MANAGER.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: liquidity, salt: bytes32(0)
            }),
            ""
        );
        if (delta.amount0() < 0) _pay(k.currency0, uint256(uint128(-delta.amount0())));
        if (delta.amount1() < 0) _pay(k.currency1, uint256(uint128(-delta.amount1())));
        return "";
    }

    /// Builds a second pool whose currencies are a WeirdToken and token1, with liquidity added
    /// while the weird token still behaves normally.
    function _weirdPool() internal returns (WeirdToken weird, PoolKey memory k, bool weirdIsZero) {
        weird = new WeirdToken();
        weirdIsZero = address(weird) < address(token1);
        k = PoolKey({
            currency0: Currency.wrap(weirdIsZero ? address(weird) : address(token1)),
            currency1: Currency.wrap(weirdIsZero ? address(token1) : address(weird)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        MANAGER.initialize(k, SQRT_PRICE_1_1);
        weird.mint(address(this), 1_000_000e18);
        _addLiquidity(k, -6000, 6000, 100_000e18);
        weird.mint(trader, 1_000e18);
        vm.prank(trader);
        weird.approve(address(swapper), type(uint256).max);
    }

    function _pay(Currency currency_, uint256 amount_) internal {
        MANAGER.sync(currency_);
        TestToken(Currency.unwrap(currency_)).transfer(address(MANAGER), amount_);
        MANAGER.settle();
    }

    function _findSwapLog(Vm.Log[] memory logs_) internal pure returns (SwapLog memory out, uint256 count) {
        for (uint256 i = 0; i < logs_.length; i++) {
            if (logs_[i].emitter != address(MANAGER) || logs_[i].topics[0] != SWAP_TOPIC_0) continue;
            count++;
            out.topicCount = logs_[i].topics.length;
            out.dataLength = logs_[i].data.length;
            out.id = logs_[i].topics[1];
            out.sender = address(uint160(uint256(logs_[i].topics[2])));
            (out.amount0, out.amount1, out.sqrtPriceX96, out.liquidity, out.tick, out.fee) =
                abi.decode(logs_[i].data, (int128, int128, uint160, uint128, int24, uint24));
        }
    }

    // ------------------------------------------------------------------ tests

    function test_poolStartsAtParity() public view {
        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = MANAGER.getSlot0(poolId);
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(tick, 0);
        assertEq(lpFee, 3000);
        assertEq(MANAGER.getLiquidity(poolId), 100_000e18);
    }

    function test_swapExactIn_sellToken0_movesPriceDownAndPaysRecipient() public {
        vm.recordLogs();
        vm.prank(trader);
        uint256 out = swapper.swapExactIn(key, true, 100e18, 0, recipient);
        (SwapLog memory log, uint256 count) = _findSwapLog(vm.getRecordedLogs());

        assertEq(token0.balanceOf(trader), 900e18, "input not taken in full");
        assertEq(token1.balanceOf(recipient), out, "output not delivered");
        assertGt(out, 99e18);
        assertLt(out, 100e18);
        assertEq(token0.balanceOf(address(swapper)), 0);
        assertEq(token1.balanceOf(address(swapper)), 0);

        // What a subscriber sees.
        assertEq(count, 1, "exactly one Swap log");
        assertEq(log.topicCount, 3, "LOG3: topic0 + id + sender");
        assertEq(log.dataLength, 6 * 32, "six non-indexed words");
        assertEq(log.id, PoolId.unwrap(poolId));
        assertEq(log.sender, address(swapper));
        assertEq(log.amount0, -100e18, "pool event deltas are from the swapper's side");
        assertEq(uint256(uint128(log.amount1)), out);
        assertEq(log.fee, 3000);
        assertEq(log.liquidity, 100_000e18);

        // The event carries the post-swap price, identical to what the pool now reports.
        (uint160 sqrtPriceX96, int24 tick,,) = MANAGER.getSlot0(poolId);
        assertEq(log.sqrtPriceX96, sqrtPriceX96);
        assertEq(log.tick, tick);
        assertLt(tick, 0, "selling token0 lowers the tick");
        assertLt(sqrtPriceX96, SQRT_PRICE_1_1);
    }

    function test_swapExactIn_sellToken1_movesPriceUp() public {
        vm.recordLogs();
        vm.prank(trader);
        uint256 out = swapper.swapExactIn(key, false, 100e18, 0, recipient);
        (SwapLog memory log, uint256 count) = _findSwapLog(vm.getRecordedLogs());

        assertEq(count, 1);
        assertEq(token1.balanceOf(trader), 900e18);
        assertEq(token0.balanceOf(recipient), out);
        assertEq(log.amount1, -100e18);
        assertGt(log.tick, 0, "selling token1 raises the tick");
        (, int24 tick,,) = MANAGER.getSlot0(poolId);
        assertEq(log.tick, tick);
    }

    function test_swapExactIn_revertsBelowMinOut() public {
        vm.expectPartialRevert(V4Swapper.InsufficientOutput.selector);
        vm.prank(trader);
        swapper.swapExactIn(key, true, 100e18, 100e18, recipient);

        // Nothing moved.
        assertEq(token0.balanceOf(trader), 1_000e18);
        assertEq(token1.balanceOf(recipient), 0);
        (uint160 sqrtPriceX96,,,) = MANAGER.getSlot0(poolId);
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
    }

    function test_swapExactIn_revertsWhenLiquidityRunsOut() public {
        // Far more than the position can absorb: the swap stops at the price limit, unfilled.
        token0.mint(trader, 10_000_000e18);
        vm.expectPartialRevert(V4Swapper.PartialFill.selector);
        vm.prank(trader);
        swapper.swapExactIn(key, true, 10_000_000e18, 0, recipient);
        assertEq(token1.balanceOf(recipient), 0);
    }

    function test_unlockCallback_rejectsDirectCalls() public {
        vm.expectRevert(V4Swapper.NotPoolManager.selector);
        vm.prank(trader);
        swapper.unlockCallback("");
    }

    // ------------------------------------------------- guards and bad tokens

    function test_swapExactIn_rejectsZeroAmount() public {
        vm.expectRevert(V4Swapper.ZeroAmount.selector);
        vm.prank(trader);
        swapper.swapExactIn(key, true, 0, 0, recipient);
    }

    function test_swapExactIn_rejectsAmountAboveInt256Max() public {
        vm.expectRevert(V4Swapper.AmountTooLarge.selector);
        vm.prank(trader);
        swapper.swapExactIn(key, true, uint256(type(int256).max) + 1, 0, recipient);
    }

    function test_swapExactIn_rejectsZeroRecipient() public {
        vm.expectRevert(V4Swapper.ZeroRecipient.selector);
        vm.prank(trader);
        swapper.swapExactIn(key, true, 1e18, 0, address(0));
    }

    function test_swapExactIn_revertsWithoutAllowance() public {
        address stranger = makeAddr("noAllowance");
        token0.mint(stranger, 10e18);
        vm.expectPartialRevert(TestToken.InsufficientAllowance.selector);
        vm.prank(stranger);
        swapper.swapExactIn(key, true, 1e18, 0, recipient);
        assertEq(token0.balanceOf(stranger), 10e18);
        assertEq(token1.balanceOf(recipient), 0);
    }

    function test_swapExactIn_feeOnTransferTokenIsRefused() public {
        (WeirdToken weird, PoolKey memory k, bool weirdIsZero) = _weirdPool();
        weird.setMode(WeirdToken.Mode.FeeOnTransfer);

        // The manager receives 1% less than owed: settle reports the shortfall and we revert.
        vm.expectRevert(abi.encodeWithSelector(V4Swapper.SettleMismatch.selector, 99e18, 100e18));
        vm.prank(trader);
        swapper.swapExactIn(k, weirdIsZero, 100e18, 0, recipient);

        assertEq(weird.balanceOf(trader), 1_000e18, "trader keeps the input");
        assertEq(token1.balanceOf(recipient), 0, "no output leaked");
    }

    function test_swapExactIn_falseReturningTokenIsRefused() public {
        (WeirdToken weird, PoolKey memory k, bool weirdIsZero) = _weirdPool();
        weird.setMode(WeirdToken.Mode.ReturnFalse);

        vm.expectRevert(V4Swapper.TransferFailed.selector);
        vm.prank(trader);
        swapper.swapExactIn(k, weirdIsZero, 100e18, 0, recipient);

        assertEq(weird.balanceOf(trader), 1_000e18);
        assertEq(token1.balanceOf(recipient), 0);
    }

    function test_swapExactIn_normalWeirdTokenStillSwaps() public {
        // Control for the two tests above: the same pool works while the token behaves.
        (WeirdToken weird, PoolKey memory k, bool weirdIsZero) = _weirdPool();
        vm.prank(trader);
        uint256 out = swapper.swapExactIn(k, weirdIsZero, 100e18, 0, recipient);
        assertEq(weird.balanceOf(trader), 900e18);
        assertEq(token1.balanceOf(recipient), out);
        assertGt(out, 99e18);
    }

    // -------------------------------------------------------------------- gas

    /// Worst case measured here: a swap that crosses several initialised ticks.
    function test_swapExactIn_gasWhenCrossingManyTicks() public {
        // Ten narrow positions stacked below the current price: selling token0 walks through them.
        for (int24 i = 0; i < 10; i++) {
            _addLiquidity(key, -60 * (i + 2), -60 * (i + 1), 1_000e18);
        }
        token0.mint(trader, 5_000e18);
        (, int24 tickBefore,,) = MANAGER.getSlot0(poolId);

        vm.prank(trader);
        uint256 before = gasleft();
        swapper.swapExactIn(key, true, 5_000e18, 0, recipient);
        uint256 used = before - gasleft();

        (, int24 tickAfter,,) = MANAGER.getSlot0(poolId);
        emit log_named_uint("swapExactIn gas, many ticks crossed", used);
        emit log_named_int("ticks moved", int256(tickBefore) - int256(tickAfter));
        assertLt(tickAfter, -660, "swap did not pass the stacked positions");
        // Callback gas limit 1,000,000 minus the 130,000 the Unichain Sepolia proxy withholds
        // (_extraGas 80,000 + _maxChargeGas 50,000, read from the proxy on 2026-11-10).
        assertLt(used, 870_000);
    }

    function test_swapExactIn_gasFitsCallbackBudget() public {
        vm.prank(trader);
        uint256 before = gasleft();
        swapper.swapExactIn(key, true, 1e18, 0, recipient);
        uint256 used = before - gasleft();
        emit log_named_uint("swapExactIn gas", used);
        // Callback limit is 1,000,000 and the proxy withholds 130,000 on Unichain Sepolia.
        assertLt(used, 400_000);
    }
}
