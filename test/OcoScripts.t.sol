// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

import {OrderVault} from "../src/OrderVault.sol";
import {OcoReactive} from "../src/OcoReactive.sol";
import {TestToken} from "../src/v4/TestToken.sol";
import {V4Swapper} from "../src/v4/V4Swapper.sol";
import {ChainGuard} from "../script/Loop.s.sol";
import {
    DeployPool,
    DeployOcoReactive,
    DeployOrderVault,
    PlaceOrder,
    Swap,
    OcoScript
} from "../script/Oco.s.sol";
import {MockSystem} from "./mocks/MockSystem.sol";

/// Runs the real deployment and demo scripts in order on a pinned fork of Unichain Sepolia, then
/// relays the resulting events through the reactive contract the way the network would. This is
/// the dress rehearsal for the testnet deployment; nothing is broadcast.
///
/// The scripts read their settings with `vm.env*`, and `vm.setEnv` changes the environment of the
/// whole test process. Forge runs the tests of a suite in parallel, so separate tests here would
/// overwrite each other's settings mid-run. Everything is therefore one test that runs each
/// scenario in turn, restoring a state snapshot between them. test/LoopScripts.t.sol also sets
/// ORIGIN_CHAIN_ID, REACTIVE_CHAIN_ID and DESTINATION_CALLBACK_PROXY_ADDR; that is safe only because
/// both suites set the same values, so keep them identical.
contract OcoScriptsTest is Test {
    using StateLibrary for IPoolManager;

    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address internal constant MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address internal constant PROXY = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;
    uint256 internal constant FORK_BLOCK = 67_550_000;
    uint256 internal constant ORIGIN = 1301;
    uint256 internal constant LASNA = 5318007;
    /// Foundry's default broadcaster when no account is given.
    address internal constant DEPLOYER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    MockSystem internal system = MockSystem(payable(SYSTEM_ADDR));
    uint256 internal logIndex;
    uint256 internal delivered;

    struct Deployed {
        TestToken token0;
        TestToken token1;
        V4Swapper swapper;
        bytes32 poolId;
        OcoReactive reactive;
        OrderVault vault;
    }

    function setUp() public {
        vm.createSelectFork(vm.envOr("ORIGIN_RPC", string("https://sepolia.unichain.org")), FORK_BLOCK);
        vm.etch(SYSTEM_ADDR, address(new MockSystem()).code);
        vm.deal(DEPLOYER, 10 ether);
    }

    /// The only test in this file; see the contract comment for why.
    function test_scripts_allScenarios() public {
        uint256 clean = vm.snapshotState();

        _scenarioDeployWiresEverythingTogether();
        _reset(clean);
        _scenarioStopLoss();
        _reset(clean);
        _scenarioTakeProfitAndTrailing();
        _reset(clean);
        _scenarioRefuseWrongChain();
        _reset(clean);
        _scenarioRejectBadSettings();
    }

    // -------------------------------------------------------------- scenarios

    function _scenarioDeployWiresEverythingTogether() internal {
        Deployed memory d = _deployAll();

        (uint160 sqrtPriceX96, int24 tick,,) = IPoolManager(MANAGER).getSlot0(PoolId.wrap(d.poolId));
        assertEq(sqrtPriceX96, 79228162514264337593543950336, "starts at 1:1");
        assertEq(tick, 0);
        assertEq(IPoolManager(MANAGER).getLiquidity(PoolId.wrap(d.poolId)), 100_000e18, "liquidity");
        assertGt(d.token0.balanceOf(DEPLOYER), 900_000e18, "deployer keeps the rest");
        assertLt(uint160(address(d.token0)), uint160(address(d.token1)), "tokens sorted");

        assertEq(d.reactive.POOL_ID(), uint256(d.poolId), "reactive watches the pool");
        assertEq(d.reactive.POOL_MANAGER(), MANAGER);
        assertEq(d.reactive.ORIGIN_CHAIN_ID(), ORIGIN);
        assertEq(d.reactive.OWNER(), DEPLOYER);
        assertEq(d.reactive.vault(), address(d.vault));
        assertEq(address(d.reactive).balance, 1 ether, "reactive funded");
        assertEq(system.subscriptionCount(), 6);
        assertEq(system.subscriptionAt(0).topic1, uint256(d.poolId));

        assertEq(d.vault._CALLBACK_SENDER(), address(d.reactive), "vault paired");
        assertEq(address(d.vault._SERVICE_PROVIDER()), PROXY);
        assertEq(PoolId.unwrap(d.vault.POOL_ID()), d.poolId);
        assertEq(address(d.vault.SWAPPER()), address(d.swapper));
        assertEq(d.vault.OWNER(), DEPLOYER);
        assertEq(address(d.vault).balance, 0.002 ether, "vault funded");
    }

    function _scenarioStopLoss() internal {
        Deployed memory d = _deployAll();
        vm.recordLogs();

        _setOrder("-120", "120", "0");
        uint256 id = new PlaceOrder().run();
        assertEq(_relayAll(d), 0);
        assertEq(d.reactive.activeIds().length, 1, "order tracked");
        assertEq(d.token0.balanceOf(address(d.vault)), 100e18);
        assertEq(d.token0.allowance(DEPLOYER, address(d.vault)), 0, "approval used exactly");

        uint256 before1 = d.token1.balanceOf(DEPLOYER);
        _swap(true, "2000000000000000000000");
        assertEq(_relayAll(d), 1, "one callback");

        assertEq(uint8(d.vault.getOrder(id).status), uint8(OrderVault.Status.Executed), "stop executed");
        assertGt(d.token1.balanceOf(DEPLOYER) - before1, 2_000e18, "swap plus order proceeds");
        assertEq(d.token0.balanceOf(address(d.vault)), 0);
        assertEq(d.reactive.activeIds().length, 0);
    }

    function _scenarioTakeProfitAndTrailing() internal {
        Deployed memory d = _deployAll();
        vm.recordLogs();

        _setOrder("0", "120", "0");
        uint256 tp = new PlaceOrder().run();
        _setOrder("0", "0", "100");
        uint256 trailing = new PlaceOrder().run();
        _relayAll(d);
        assertEq(d.reactive.activeIds().length, 2, "both tracked");

        _swap(false, "2000000000000000000000");
        _relayAll(d);
        assertEq(uint8(d.vault.getOrder(tp).status), uint8(OrderVault.Status.Executed), "take-profit");
        assertEq(uint8(d.vault.getOrder(trailing).status), uint8(OrderVault.Status.Active), "trailing waits");

        _swap(true, "2000000000000000000000");
        _relayAll(d);
        assertEq(uint8(d.vault.getOrder(trailing).status), uint8(OrderVault.Status.Executed), "trailing");
    }

    function _scenarioRefuseWrongChain() internal {
        _setCommon();
        vm.setEnv("TOKEN0_ADDR", vm.toString(address(1)));
        vm.setEnv("TOKEN1_ADDR", vm.toString(address(2)));
        vm.setEnv("POOL_ID", vm.toString(bytes32(0)));
        vm.setEnv("SWAPPER_ADDR", vm.toString(address(3)));
        vm.setEnv("OCO_REACTIVE_ADDR", vm.toString(address(4)));
        vm.setEnv("ORDER_VAULT_ADDR", vm.toString(address(5)));
        _setOrder("-120", "120", "0");
        vm.setEnv("SWAP_ZERO_FOR_ONE", "true");
        vm.setEnv("SWAP_AMOUNT_WEI", "1");

        DeployPool pool = new DeployPool();
        DeployOcoReactive reactive = new DeployOcoReactive();
        DeployOrderVault vault = new DeployOrderVault();
        PlaceOrder place = new PlaceOrder();
        Swap swap = new Swap();

        vm.chainId(1); // Ethereum mainnet: everything refuses
        vm.expectRevert(abi.encodeWithSelector(ChainGuard.WrongChain.selector, ORIGIN, 1));
        pool.run();
        vm.expectRevert(abi.encodeWithSelector(ChainGuard.WrongChain.selector, LASNA, 1));
        reactive.run();
        vm.expectRevert(abi.encodeWithSelector(ChainGuard.WrongChain.selector, ORIGIN, 1));
        vault.run();
        vm.expectRevert(abi.encodeWithSelector(ChainGuard.WrongChain.selector, ORIGIN, 1));
        place.run();
        vm.expectRevert(abi.encodeWithSelector(ChainGuard.WrongChain.selector, ORIGIN, 1));
        swap.run();

        vm.chainId(ORIGIN); // the reactive script also refuses the origin chain
        vm.expectRevert(abi.encodeWithSelector(ChainGuard.WrongChain.selector, LASNA, ORIGIN));
        reactive.run();
    }

    function _scenarioRejectBadSettings() internal {
        _setCommon();
        DeployOcoReactive reactive = new DeployOcoReactive();
        vm.chainId(LASNA);

        // Unsorted token addresses.
        vm.setEnv("TOKEN0_ADDR", vm.toString(address(2)));
        vm.setEnv("TOKEN1_ADDR", vm.toString(address(1)));
        vm.setEnv("POOL_ID", vm.toString(bytes32(0)));
        vm.expectRevert(OcoScript.TokensNotSorted.selector);
        reactive.run();

        // A POOL_ID from step 1 that does not match the tokens.
        vm.setEnv("TOKEN0_ADDR", vm.toString(address(1)));
        vm.setEnv("TOKEN1_ADDR", vm.toString(address(2)));
        vm.setEnv("POOL_ID", vm.toString(keccak256("some other pool")));
        vm.expectPartialRevert(OcoScript.PoolIdMismatch.selector);
        reactive.run();

        // Order settings that do not fit their field are refused, not truncated.
        _deployAll();
        PlaceOrder place = new PlaceOrder();
        _setOrder("8388608", "120", "0"); // int24.max + 1
        vm.expectRevert(abi.encodeWithSelector(OcoScript.ValueOutOfRange.selector, "ORDER_STOP_TICK"));
        place.run();
        _setOrder("-120", "-8388609", "0"); // int24.min - 1
        vm.expectRevert(abi.encodeWithSelector(OcoScript.ValueOutOfRange.selector, "ORDER_TP_TICK"));
        place.run();
        _setOrder("-120", "120", "16777216"); // uint24.max + 1
        vm.expectRevert(abi.encodeWithSelector(OcoScript.ValueOutOfRange.selector, "ORDER_TRAILING"));
        place.run();
        _setOrder("-120", "120", "0");
        vm.setEnv("ORDER_AMOUNT_WEI", "340282366920938463463374607431768211456"); // 2**128
        vm.expectRevert(abi.encodeWithSelector(OcoScript.ValueOutOfRange.selector, "ORDER_AMOUNT_WEI"));
        place.run();
        _setOrder("-120", "120", "0");
        vm.setEnv("ORDER_MIN_OUT_WEI", "340282366920938463463374607431768211456");
        vm.expectRevert(abi.encodeWithSelector(OcoScript.ValueOutOfRange.selector, "ORDER_MIN_OUT_WEI"));
        place.run();
        _setOrder("-120", "120", "0");
        vm.setEnv("ORDER_LIFETIME_SECONDS", vm.toString(uint256(365 days) + 1));
        vm.expectRevert(abi.encodeWithSelector(OcoScript.ValueOutOfRange.selector, "ORDER_LIFETIME_SECONDS"));
        place.run();
    }

    // ---------------------------------------------------------------- helpers

    function _reset(uint256 snapshot_) internal {
        vm.revertToState(snapshot_);
        vm.chainId(ORIGIN);
        logIndex = 0;
        delivered = 0;
        vm.getRecordedLogs();
    }

    function _setCommon() internal {
        vm.setEnv("ORIGIN_CHAIN_ID", vm.toString(ORIGIN));
        vm.setEnv("REACTIVE_CHAIN_ID", vm.toString(LASNA));
        vm.setEnv("POOL_MANAGER_ADDR", vm.toString(MANAGER));
        vm.setEnv("DESTINATION_CALLBACK_PROXY_ADDR", vm.toString(PROXY));
        vm.setEnv("OCO_REACTIVE_FUNDING_WEI", "1000000000000000000");
        vm.setEnv("VAULT_FUNDING_WEI", "2000000000000000");
    }

    function _deployAll() internal returns (Deployed memory d) {
        _setCommon();
        vm.chainId(ORIGIN);
        (d.token0, d.token1, d.swapper, d.poolId) = new DeployPool().run();
        vm.setEnv("TOKEN0_ADDR", vm.toString(address(d.token0)));
        vm.setEnv("TOKEN1_ADDR", vm.toString(address(d.token1)));
        vm.setEnv("SWAPPER_ADDR", vm.toString(address(d.swapper)));
        vm.setEnv("POOL_ID", vm.toString(d.poolId));

        vm.chainId(LASNA);
        d.reactive = new DeployOcoReactive().run();
        vm.setEnv("OCO_REACTIVE_ADDR", vm.toString(address(d.reactive)));

        vm.chainId(ORIGIN);
        d.vault = new DeployOrderVault().run();
        vm.setEnv("ORDER_VAULT_ADDR", vm.toString(address(d.vault)));

        // Step 5 is a cast send from the deployer.
        vm.prank(DEPLOYER);
        d.reactive.setVault(address(d.vault));
    }

    function _setOrder(string memory stop_, string memory tp_, string memory trailing_) internal {
        vm.setEnv("ORDER_AMOUNT_WEI", "100000000000000000000");
        vm.setEnv("ORDER_STOP_TICK", stop_);
        vm.setEnv("ORDER_TP_TICK", tp_);
        vm.setEnv("ORDER_TRAILING", trailing_);
        vm.setEnv("ORDER_MIN_OUT_WEI", "0");
        vm.setEnv("ORDER_LIFETIME_SECONDS", "86400");
    }

    function _swap(bool zeroForOne_, string memory amount_) internal {
        vm.setEnv("SWAP_ZERO_FOR_ONE", zeroForOne_ ? "true" : "false");
        vm.setEnv("SWAP_AMOUNT_WEI", amount_);
        new Swap().run();
    }

    function _relayAll(Deployed memory d_) internal returns (uint256 callbacksNow) {
        for (uint256 round = 0; round < 20; round++) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool busy;
            for (uint256 i = 0; i < logs.length; i++) {
                if (logs[i].emitter != MANAGER && logs[i].emitter != address(d_.vault)) continue;
                IReactive.LogRecord memory r;
                r.chainId = ORIGIN;
                r.contractAddress = logs[i].emitter;
                r.opCode = logs[i].topics.length;
                r.data = logs[i].data;
                r.blockNumber = block.number;
                r.logIndex = logIndex++;
                if (logs[i].topics.length > 0) r.topic0 = uint256(logs[i].topics[0]);
                if (logs[i].topics.length > 1) r.topic1 = uint256(logs[i].topics[1]);
                if (logs[i].topics.length > 2) r.topic2 = uint256(logs[i].topics[2]);
                vm.prank(SYSTEM_ADDR);
                d_.reactive.react(r);
                busy = true;
            }
            while (delivered < system.callbackCount()) {
                MockSystem.CallbackRequest memory c = system.callbackAt(delivered);
                bytes memory payload = c.payload;
                bytes32 word = bytes32(uint256(uint160(c.sender)));
                assembly {
                    mstore(add(payload, 36), word)
                }
                vm.prank(PROXY);
                (bool ok,) = c.recipient.call{gas: 870_000}(payload);
                assertTrue(ok, "callback reverted");
                delivered++;
                callbacksNow++;
                busy = true;
            }
            if (!busy) return callbacksNow;
        }
        revert("did not settle");
    }
}
