// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {console} from "forge-std/Script.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {OrderVault} from "../src/OrderVault.sol";
import {OcoReactive} from "../src/OcoReactive.sol";
import {TestToken} from "../src/v4/TestToken.sol";
import {V4Swapper} from "../src/v4/V4Swapper.sol";
import {DemoLiquidity} from "../src/v4/DemoLiquidity.sol";
import {ChainGuard} from "./Loop.s.sol";

// Deployment and demo scripts for the OCO system. Run them in this order (see README):
//   1. DeployPool       on Unichain Sepolia: two test tokens, a pool, liquidity, the swapper
//   2. DeployOcoReactive on Lasna, watching that pool
//   3. DeployOrderVault  on Unichain Sepolia, paired with the reactive contract
//   4. `setVault` on OcoReactive (cast send)
//   5. PlaceOrder / Swap on Unichain Sepolia to run the loop
//
// The signer is supplied on the command line (`--account <keystore>`); no private key is read
// from the environment. Every script refuses to run on a chain other than the expected one.

/// @dev Pool parameters shared by every script. The pool key is rebuilt from the two token
///      addresses, so later scripts only need TOKEN0_ADDR and TOKEN1_ADDR.
abstract contract OcoScript is ChainGuard {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    /// Price 1:1.
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function _poolKey() internal view returns (PoolKey memory key) {
        address token0 = vm.envAddress("TOKEN0_ADDR");
        address token1 = vm.envAddress("TOKEN1_ADDR");
        if (token0 >= token1) revert TokensNotSorted();
        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    function _poolId() internal view returns (bytes32) {
        return PoolId.unwrap(_poolKey().toId());
    }

    /// @dev The account the current broadcast sends from. Read from Foundry rather than assumed:
    ///      inside a script, `msg.sender` is not necessarily the signing account.
    function _broadcaster() internal view returns (address caller) {
        (, caller,) = vm.readCallers();
    }

    error TokensNotSorted();
    error PoolIdMismatch(bytes32 expected, bytes32 actual);
    error ValueOutOfRange(string name);

    /// @dev Reads a signed env value and refuses it unless it fits int24, instead of wrapping.
    function _envInt24(string memory name_) internal view returns (int24) {
        int256 v = vm.envInt(name_);
        if (v < type(int24).min || v > type(int24).max) revert ValueOutOfRange(name_);
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(v);
    }

    /// @dev Reads an unsigned env value and refuses it unless it is at most `max_`.
    function _envUintMax(string memory name_, uint256 max_) internal view returns (uint256 v) {
        v = vm.envUint(name_);
        if (v > max_) revert ValueOutOfRange(name_);
    }
}

/// @notice Step 1 (Unichain Sepolia): deploys two test tokens, opens a hookless 0.3% pool at 1:1,
///         adds liquidity from the sender, and deploys the swapper the vault will use.
contract DeployPool is OcoScript {
    /// Liquidity added around the starting price; needs about 45,000 of each token.
    uint128 internal constant LIQUIDITY = 100_000e18;
    int24 internal constant RANGE = 12_000;
    uint256 internal constant MINT = 1_000_000e18;

    /// @notice Reads `ORIGIN_CHAIN_ID` and `POOL_MANAGER_ADDR`, then broadcasts the deployment.
    /// @return token0 Lower-addressed test token.
    /// @return token1 Higher-addressed test token.
    /// @return swapper The deployed swapper.
    /// @return poolId Id of the new pool.
    function run() external returns (TestToken token0, TestToken token1, V4Swapper swapper, bytes32 poolId) {
        _requireChain(vm.envUint("ORIGIN_CHAIN_ID"));
        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER_ADDR"));

        vm.startBroadcast();
        address sender = _broadcaster();
        TestToken a = new TestToken("OCO Demo A", "OCOA");
        TestToken b = new TestToken("OCO Demo B", "OCOB");
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        token0.mint(sender, MINT);
        token1.mint(sender, MINT);
        DemoLiquidity liquidity = new DemoLiquidity(manager);
        token0.approve(address(liquidity), type(uint256).max);
        token1.approve(address(liquidity), type(uint256).max);
        liquidity.addLiquidity(key, -RANGE, RANGE, LIQUIDITY);

        swapper = new V4Swapper(manager);
        vm.stopBroadcast();

        poolId = PoolId.unwrap(PoolIdLibrary.toId(key));
        console.log("export TOKEN0_ADDR=%s", address(token0));
        console.log("export TOKEN1_ADDR=%s", address(token1));
        console.log("export SWAPPER_ADDR=%s", address(swapper));
        console.log("export LIQUIDITY_HELPER_ADDR=%s", address(liquidity));
        console.log("export POOL_ID=%s", vm.toString(poolId));
    }
}

/// @notice Step 2 (Lasna): deploys the reactive contract watching the pool, funded for fees.
contract DeployOcoReactive is OcoScript {
    /// @notice Reads `REACTIVE_CHAIN_ID`, `ORIGIN_CHAIN_ID`, `POOL_MANAGER_ADDR`, `TOKEN0_ADDR`,
    ///         `TOKEN1_ADDR` and `OCO_REACTIVE_FUNDING_WEI`, then broadcasts the deployment.
    /// @return reactive The deployed contract.
    function run() external returns (OcoReactive reactive) {
        _requireChain(vm.envUint("REACTIVE_CHAIN_ID"));
        uint256 originChainId = vm.envUint("ORIGIN_CHAIN_ID");
        address manager = vm.envAddress("POOL_MANAGER_ADDR");
        bytes32 poolId = _poolId();
        // When step 1's POOL_ID is exported, it must match the pool rebuilt from the token addresses.
        bytes32 expected = vm.envOr("POOL_ID", bytes32(0));
        if (expected != bytes32(0) && expected != poolId) revert PoolIdMismatch(expected, poolId);
        uint256 funding = vm.envUint("OCO_REACTIVE_FUNDING_WEI");

        vm.startBroadcast();
        reactive = new OcoReactive{value: funding}(originChainId, manager, poolId);
        vm.stopBroadcast();

        console.log("export OCO_REACTIVE_ADDR=%s", address(reactive));
        console.log("watching pool %s", vm.toString(poolId));
    }
}

/// @notice Step 3 (Unichain Sepolia): deploys the order vault paired with the reactive contract.
contract DeployOrderVault is OcoScript {
    /// @notice Reads `ORIGIN_CHAIN_ID`, `DESTINATION_CALLBACK_PROXY_ADDR`, `OCO_REACTIVE_ADDR`,
    ///         `SWAPPER_ADDR`, `TOKEN0_ADDR`, `TOKEN1_ADDR` and `VAULT_FUNDING_WEI`, then
    ///         broadcasts the deployment.
    /// @return vault The deployed contract.
    function run() external returns (OrderVault vault) {
        _requireChain(vm.envUint("ORIGIN_CHAIN_ID"));
        IPayable proxy = IPayable(payable(vm.envAddress("DESTINATION_CALLBACK_PROXY_ADDR")));
        address reactive = vm.envAddress("OCO_REACTIVE_ADDR");
        V4Swapper swapper = V4Swapper(vm.envAddress("SWAPPER_ADDR"));
        PoolKey memory key = _poolKey();
        uint256 funding = vm.envUint("VAULT_FUNDING_WEI");

        vm.startBroadcast();
        vault = new OrderVault{value: funding}(proxy, reactive, swapper, key);
        vm.stopBroadcast();

        console.log("export ORDER_VAULT_ADDR=%s", address(vault));
    }
}

/// @notice Demo (Unichain Sepolia): the sender places an OCO order selling token0.
contract PlaceOrder is OcoScript {
    /// Slippage bound passed with every demo order: 5% of the price at execution, after the fee.
    uint16 internal constant MAX_SLIPPAGE_BPS = 500;

    /// @notice Reads `ORIGIN_CHAIN_ID`, `ORDER_VAULT_ADDR`, `TOKEN0_ADDR`, `TOKEN1_ADDR` and the
    ///         order settings `ORDER_AMOUNT_WEI`, `ORDER_STOP_TICK`, `ORDER_TP_TICK`,
    ///         `ORDER_TRAILING`, `ORDER_MIN_OUT_WEI`, `ORDER_LIFETIME_SECONDS`. A tick of 0
    ///         leaves that level unset, so a level at exactly tick 0 cannot be set from here.
    ///         Values that do not fit their field are refused, not truncated. The order always
    ///         sells token0 and uses a 5% slippage bound.
    /// @return id Id of the new order.
    function run() external returns (uint256 id) {
        _requireChain(vm.envUint("ORIGIN_CHAIN_ID"));
        OrderVault vault = OrderVault(payable(vm.envAddress("ORDER_VAULT_ADDR")));
        PoolKey memory key = _poolKey();
        int24 stopTick = _envInt24("ORDER_STOP_TICK");
        int24 tpTick = _envInt24("ORDER_TP_TICK");

        OrderVault.OrderParams memory p = OrderVault.OrderParams({
            zeroForOne: true,
            amountIn: uint128(_envUintMax("ORDER_AMOUNT_WEI", type(uint128).max)),
            useStop: stopTick != 0,
            stopTick: stopTick,
            useTakeProfit: tpTick != 0,
            takeProfitTick: tpTick,
            trailingDistance: uint24(_envUintMax("ORDER_TRAILING", type(uint24).max)),
            minAmountOut: uint128(_envUintMax("ORDER_MIN_OUT_WEI", type(uint128).max)),
            maxSlippageBps: MAX_SLIPPAGE_BPS,
            expiry: uint64(block.timestamp + _envUintMax("ORDER_LIFETIME_SECONDS", 365 days))
        });

        vm.startBroadcast();
        TestToken(Currency.unwrap(key.currency0)).approve(address(vault), p.amountIn);
        id = vault.createOrder(p);
        vm.stopBroadcast();

        console.log("order id %s, current tick %s", id, vm.toString(vault.normalizedTick(true)));
        console.log(
            "stop %s, take-profit %s, trailing %s",
            vm.toString(stopTick),
            vm.toString(tpTick),
            p.trailingDistance
        );
    }
}

/// @notice Demo (Unichain Sepolia): the sender swaps in the pool to move the price.
contract Swap is OcoScript {
    /// @notice Reads `ORIGIN_CHAIN_ID`, `SWAPPER_ADDR`, `TOKEN0_ADDR`, `TOKEN1_ADDR`,
    ///         `SWAP_ZERO_FOR_ONE` (true sells token0 and lowers the tick) and `SWAP_AMOUNT_WEI`.
    /// @return amountOut Amount received.
    function run() external returns (uint256 amountOut) {
        _requireChain(vm.envUint("ORIGIN_CHAIN_ID"));
        V4Swapper swapper = V4Swapper(vm.envAddress("SWAPPER_ADDR"));
        PoolKey memory key = _poolKey();
        bool zeroForOne = vm.envBool("SWAP_ZERO_FOR_ONE");
        uint256 amount = vm.envUint("SWAP_AMOUNT_WEI");
        Currency input = zeroForOne ? key.currency0 : key.currency1;

        vm.startBroadcast();
        TestToken(Currency.unwrap(input)).approve(address(swapper), amount);
        amountOut = swapper.swapExactIn(key, zeroForOne, amount, 0, _broadcaster());
        vm.stopBroadcast();

        console.log("swapped, received %s", amountOut);
    }
}
