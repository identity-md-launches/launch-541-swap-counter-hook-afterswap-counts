// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {stdError} from "forge-std/StdError.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {SwapCounterHook} from "../src/SwapCounterHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

contract SwapCounterHookTest is HookFixture {
    using stdStorage for StdStorage;

    function test_permissionsAndInitialState() public view {
        Hooks.Permissions memory expected;
        expected.beforeInitialize = true;
        expected.afterSwap = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
        assertEq(HookFlags.flagsOf(address(hook)), 0x2040);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.totalSwaps(), 0);
        assertEq(hook.swapCount(address(this)), 0);
    }

    function test_initializationReturnsSelectorAndDoesNotCount() public {
        vm.prank(address(manager));
        assertEq(hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1), IHooks.beforeInitialize.selector);
        assertEq(hook.totalSwaps(), 0);
    }

    function test_countsRepeatedSendersAndMultiplePools() public {
        _swap(address(11));
        _swap(address(22));
        key.fee = 500;
        _swap(address(11));
        assertEq(hook.totalSwaps(), 3);
        assertEq(hook.swapCount(address(11)), 2);
        assertEq(hook.swapCount(address(22)), 1);
        assertEq(hook.swapCount(address(manager)), 0);
    }

    function testFuzz_afterSwapEmitsExactlyOnceAndReturnsZero(
        address sender,
        bool direction,
        int256 amount,
        int256 delta,
        bytes memory hookData
    ) public {
        vm.recordLogs();
        vm.prank(address(manager));
        (bytes4 selector, int128 adjustment) = hook.afterSwap(
            sender, key, SwapParams(direction, amount, SQRT_PRICE_1_1), BalanceDelta.wrap(delta), hookData
        );
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(adjustment, 0);
        assertEq(hook.swapCount(sender), 1);
        assertEq(hook.totalSwaps(), 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(hook));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("SwapCounted(address,bytes32,uint256,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(sender))));
        assertEq(logs[0].topics[2], PoolId.unwrap(key.toId()));
        assertEq(logs[0].data, abi.encode(uint256(1), uint256(1)));
    }

    function test_everyCallbackRefusesUnauthorizedCaller() public {
        bytes[] memory calls = new bytes[](10);
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        SwapParams memory sp = SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2);
        BalanceDelta zero = BalanceDelta.wrap(0);
        calls[0] = abi.encodeCall(IHooks.beforeInitialize, (address(this), key, SQRT_PRICE_1_1));
        calls[1] = abi.encodeCall(IHooks.afterInitialize, (address(this), key, SQRT_PRICE_1_1, 0));
        calls[2] = abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), key, lp, ""));
        calls[3] = abi.encodeCall(IHooks.afterAddLiquidity, (address(this), key, lp, zero, zero, ""));
        calls[4] = abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), key, lp, ""));
        calls[5] = abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), key, lp, zero, zero, ""));
        calls[6] = abi.encodeCall(IHooks.beforeSwap, (address(this), key, sp, ""));
        calls[7] = abi.encodeCall(IHooks.afterSwap, (address(this), key, sp, zero, ""));
        calls[8] = abi.encodeCall(IHooks.beforeDonate, (address(this), key, 1, 1, ""));
        calls[9] = abi.encodeCall(IHooks.afterDonate, (address(this), key, 1, 1, ""));
        for (uint256 i; i < calls.length; ++i) {
            (bool success, bytes memory reason) = address(hook).call(calls[i]);
            assertFalse(success);
            assertEq(reason, abi.encodeWithSelector(ImmutableState.NotPoolManager.selector));
        }
        assertEq(hook.totalSwaps(), 0);
    }

    function testFuzz_spoofedAfterSwapCannotCount(address caller, address sender) public {
        vm.assume(caller != address(manager));
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        vm.prank(caller);
        hook.afterSwap(sender, key, SwapParams(true, -1, 1), BalanceDelta.wrap(0), abi.encode(sender));
        assertEq(hook.totalSwaps(), 0);
        assertEq(hook.swapCount(sender), 0);
    }

    function test_disabledCallbackRevertsEvenForManager() public {
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, SwapParams(true, -1, 1), "");
    }

    function test_wrongAddressBitsPreventDeployment() public {
        bytes memory code = abi.encodePacked(type(SwapCounterHook).creationCode, abi.encode(manager));
        uint256 salt;
        address predicted = HookMiner.computeAddress(address(this), salt, code);
        while (HookFlags.matches(predicted, HookFlags.COUNTER_FLAGS)) {
            predicted = HookMiner.computeAddress(address(this), ++salt, code);
        }
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new SwapCounterHook{salt: bytes32(salt)}(manager);
    }

    function test_noCodePoolManagerRejected() public {
        _expectInvalidManager(address(0));
        _expectInvalidManager(address(0xBAD));
    }

    function test_totalOverflowRevertsBothIncrements() public {
        stdstore.target(address(hook)).sig("totalSwaps()").checked_write(type(uint256).max);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(address(manager));
        hook.afterSwap(address(11), key, SwapParams(true, -1, 1), BalanceDelta.wrap(0), "");
        assertEq(hook.totalSwaps(), type(uint256).max);
        assertEq(hook.swapCount(address(11)), 0);
    }

    function test_senderOverflowDoesNotWrap() public {
        stdstore.target(address(hook))
            .sig("swapCount(address)")
            .with_key(address(11))
            .checked_write(type(uint256).max);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(address(manager));
        hook.afterSwap(address(11), key, SwapParams(true, -1, 1), BalanceDelta.wrap(0), "");
        assertEq(hook.swapCount(address(11)), type(uint256).max);
        assertEq(hook.totalSwaps(), 0);
    }

    function _expectInvalidManager(address candidate) private {
        (, bytes32 salt) = HookMiner.find(
            address(this), HookFlags.COUNTER_FLAGS, type(SwapCounterHook).creationCode, abi.encode(candidate)
        );
        vm.expectRevert(SwapCounterHook.InvalidPoolManager.selector);
        new SwapCounterHook{salt: salt}(IPoolManager(candidate));
    }

    function _swap(address sender) private {
        vm.prank(address(manager));
        hook.afterSwap(sender, key, SwapParams(true, -1, 1), BalanceDelta.wrap(0), "");
    }
}
