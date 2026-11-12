// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {DemoLiquidity} from "../src/v4/DemoLiquidity.sol";
import {V4ForkBase} from "./utils/V4ForkBase.sol";
import {WeirdToken} from "./mocks/WeirdToken.sol";

/// Calls `unlockCallback` from inside the attacker's own PoolManager unlock, trying to make the
/// helper add liquidity paid for by a victim who approved it.
contract CallbackThief is IUnlockCallback {
    IPoolManager internal immutable manager;
    DemoLiquidity internal immutable helper;
    bytes internal payload;

    constructor(IPoolManager manager_, DemoLiquidity helper_) {
        manager = manager_;
        helper = helper_;
    }

    function steal(bytes calldata payload_) external {
        payload = payload_;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        return helper.unlockCallback(payload);
    }
}

contract DemoLiquidityForkTest is V4ForkBase {
    using StateLibrary for IPoolManager;

    DemoLiquidity internal helper;
    address internal provider = makeAddr("provider");

    function setUp() public {
        _setUpPool();
        helper = new DemoLiquidity(MANAGER);
        token0.mint(provider, 100_000e18);
        token1.mint(provider, 100_000e18);
        vm.startPrank(provider);
        token0.approve(address(helper), type(uint256).max);
        token1.approve(address(helper), type(uint256).max);
        vm.stopPrank();
    }

    function test_addLiquidity_paysFromTheCaller() public {
        uint128 before = MANAGER.getLiquidity(poolId);
        vm.prank(provider);
        (uint256 a0, uint256 a1) = helper.addLiquidity(key, -600, 600, 1_000e18);

        assertEq(MANAGER.getLiquidity(poolId) - before, 1_000e18);
        assertGt(a0, 0);
        assertGt(a1, 0);
        assertEq(token0.balanceOf(provider), 100_000e18 - a0);
        assertEq(token1.balanceOf(provider), 100_000e18 - a1);
        assertEq(token0.balanceOf(address(helper)), 0, "helper keeps nothing");
    }

    function test_addLiquidity_rejectsZeroAndOversized() public {
        vm.startPrank(provider);
        vm.expectRevert(DemoLiquidity.BadLiquidity.selector);
        helper.addLiquidity(key, -600, 600, 0);
        vm.expectRevert(DemoLiquidity.BadLiquidity.selector);
        helper.addLiquidity(key, -600, 600, uint128(type(int128).max) + 1);
        vm.stopPrank();
    }

    function test_unlockCallback_rejectsDirectCaller() public {
        vm.expectRevert(DemoLiquidity.NotPoolManager.selector);
        helper.unlockCallback("");
    }

    function test_unlockCallback_cannotBeDrivenFromSomeoneElsesUnlock() public {
        // The provider has approved the helper. An attacker inside their own unlock tries to make
        // the helper add liquidity paid for by the provider.
        CallbackThief thief = new CallbackThief(MANAGER, helper);
        bytes memory payload = abi.encode(DemoLiquidity.Request(key, -600, 600, 1_000e18, provider));
        vm.expectRevert(DemoLiquidity.NotPoolManager.selector);
        thief.steal(payload);
        assertEq(token0.balanceOf(provider), 100_000e18, "nothing taken");
    }

    function _weirdKey(WeirdToken weird_) internal returns (PoolKey memory k) {
        (k,) = _initPoolWith(address(weird_));
        weird_.mint(provider, 100_000e18);
        vm.prank(provider);
        weird_.approve(address(helper), type(uint256).max);
    }

    function test_addLiquidity_refusesTokenThatReturnsFalse() public {
        WeirdToken weird = new WeirdToken();
        PoolKey memory k = _weirdKey(weird);
        weird.setMode(WeirdToken.Mode.ReturnFalse);
        vm.expectRevert(DemoLiquidity.TransferFailed.selector);
        vm.prank(provider);
        helper.addLiquidity(k, -600, 600, 1_000e18);
    }

    function test_addLiquidity_refusesFeeOnTransferToken() public {
        WeirdToken weird = new WeirdToken();
        PoolKey memory k = _weirdKey(weird);
        weird.setMode(WeirdToken.Mode.FeeOnTransfer);
        vm.expectPartialRevert(DemoLiquidity.SettleMismatch.selector);
        vm.prank(provider);
        helper.addLiquidity(k, -600, 600, 1_000e18);
    }

    function test_addLiquidity_secondAddAfterFeesSettlesTheCredit() public {
        vm.prank(provider);
        helper.addLiquidity(key, -600, 600, 1_000e18);

        // Heavy trading in the range accrues fees to the helper's position.
        for (uint256 i = 0; i < 6; i++) {
            _pushDown(5_000e18);
            _pushUp(5_000e18);
        }

        // Adding a tiny amount to the same position: fees exceed the cost, so the caller is owed.
        uint256 b0 = token0.balanceOf(provider);
        uint256 b1 = token1.balanceOf(provider);
        vm.prank(provider);
        helper.addLiquidity(key, -600, 600, 1);
        assertTrue(token0.balanceOf(provider) > b0 || token1.balanceOf(provider) > b1, "credit paid out");
        assertEq(token0.balanceOf(address(helper)), 0);
        assertEq(token1.balanceOf(address(helper)), 0);
    }
}
