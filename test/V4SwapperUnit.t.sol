// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

import {V4Swapper} from "../src/v4/V4Swapper.sol";

/// Pool manager stand-in that returns whatever swap delta the test sets. Used for the one branch a
/// real PoolManager never produces: deltas with the wrong sign.
contract StubManager {
    int128 public delta0;
    int128 public delta1;

    function setDelta(int128 delta0_, int128 delta1_) external {
        delta0 = delta0_;
        delta1 = delta1_;
    }

    function unlock(bytes calldata data_) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data_);
    }

    function swap(PoolKey memory, IPoolManager.SwapParams memory, bytes calldata)
        external
        view
        returns (BalanceDelta)
    {
        return toBalanceDelta(delta0, delta1);
    }
}

contract V4SwapperUnitTest is Test {
    StubManager internal manager;
    V4Swapper internal swapper;
    PoolKey internal key;

    function setUp() public {
        manager = new StubManager();
        swapper = new V4Swapper(IPoolManager(address(manager)));
        key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function test_unexpectedDelta_positiveInputSide() public {
        // Selling currency0, but the pool claims it owes us currency0.
        manager.setDelta(5, 7);
        vm.expectRevert(abi.encodeWithSelector(V4Swapper.UnexpectedDelta.selector, int128(5), int128(7)));
        swapper.swapExactIn(key, true, 100, 0, address(this));
    }

    function test_unexpectedDelta_negativeOutputSide() public {
        // Selling currency0, but the pool claims we also owe currency1.
        manager.setDelta(-100, -1);
        vm.expectRevert(abi.encodeWithSelector(V4Swapper.UnexpectedDelta.selector, int128(-100), int128(-1)));
        swapper.swapExactIn(key, true, 100, 0, address(this));
    }

    function test_unexpectedDelta_mirroredForOneForZero() public {
        // Selling currency1: the input side is amount1.
        manager.setDelta(-1, -100);
        vm.expectRevert(abi.encodeWithSelector(V4Swapper.UnexpectedDelta.selector, int128(-100), int128(-1)));
        swapper.swapExactIn(key, false, 100, 0, address(this));
    }
}
