// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {stdError} from "forge-std/StdError.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

contract SwapCounterHookEdgesTest is HookFixture {
    using stdStorage for StdStorage;

    function test_allDisabledCallbacksRejectManagerWithoutChangingExistingCounts() public {
        _observe(address(0xA11CE), SwapParams(true, -1, 1), BalanceDelta.wrap(0), "");
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1, bytes32(0));
        BalanceDelta zero = BalanceDelta.wrap(0);
        bytes[] memory calls = new bytes[](8);
        calls[0] = abi.encodeCall(IHooks.afterInitialize, (address(this), key, SQRT_PRICE_1_1, 0));
        calls[1] = abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), key, lp, ""));
        calls[2] = abi.encodeCall(IHooks.afterAddLiquidity, (address(this), key, lp, zero, zero, ""));
        calls[3] = abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), key, lp, ""));
        calls[4] = abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), key, lp, zero, zero, ""));
        calls[5] = abi.encodeCall(IHooks.beforeSwap, (address(this), key, SwapParams(false, 1, 1), ""));
        calls[6] = abi.encodeCall(IHooks.beforeDonate, (address(this), key, 1, 1, ""));
        calls[7] = abi.encodeCall(IHooks.afterDonate, (address(this), key, 1, 1, ""));
        vm.recordLogs();
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(address(manager));
            (bool ok, bytes memory reason) = address(hook).call(calls[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(BaseHook.HookNotImplemented.selector));
            assertEq(hook.totalSwaps(), 1);
            assertEq(hook.swapCount(address(0xA11CE)), 1);
        }
        assertEq(vm.getRecordedLogs().length, 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_initializationCannotBeSpoofed(address caller, address origin, uint160 price) public {
        if (caller == address(manager)) caller = address(0);
        _observe(address(0xA11CE), SwapParams(true, -1, 1), BalanceDelta.wrap(0), "");
        vm.recordLogs();
        // Neither a forged sender argument nor transaction origin confers manager authority.
        vm.prank(caller, origin);
        (bool ok, bytes memory reason) =
            address(hook).call(abi.encodeCall(IHooks.beforeInitialize, (address(manager), key, price)));
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(ImmutableState.NotPoolManager.selector));
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(hook.totalSwaps(), 1);
        assertEq(hook.swapCount(address(0xA11CE)), 1);
    }

    function test_edgeCallbackInputsStayObservationalAndAttributeSender() public {
        address[4] memory senders = [address(0), address(manager), address(hook), address(type(uint160).max)];
        int256[4] memory amounts = [int256(0), int256(1), type(int256).min, type(int256).max];
        int256[4] memory deltas = [type(int256).min, type(int256).max, int256(-1), int256(0)];
        // This is the callback domain. Real swaps additionally obey PoolManager's validation.
        for (uint256 i; i < senders.length; ++i) {
            _observe(
                senders[i],
                SwapParams(i % 2 == 0, amounts[i], i == 0 ? 0 : type(uint160).max),
                BalanceDelta.wrap(deltas[i]),
                hex"ff"
            );
            assertEq(hook.swapCount(senders[i]), 1);
            assertEq(hook.totalSwaps(), i + 1);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_eventsIdentifyPoolAndPostIncrementCounts(uint8 rawLength, uint256 actorChoices) public {
        uint256 length = bound(rawLength, 2, 32);
        address[2] memory actors = [address(0xA11CE), address(0xB0B)];
        uint256[2] memory expected;
        for (uint256 i; i < length; ++i) {
            uint256 index = (actorChoices >> i) & 1;
            ++expected[index];
            key.fee = i % 2 == 0 ? 500 : 3000;
            key.tickSpacing = i % 2 == 0 ? int24(10) : int24(60);
            vm.recordLogs();
            _observe(
                actors[index],
                SwapParams(i % 2 == 0, -1, 1),
                BalanceDelta.wrap(0),
                abi.encode(actors[1 - index])
            );
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, 1);
            assertEq(logs[0].emitter, address(hook));
            assertEq(logs[0].topics.length, 3);
            assertEq(logs[0].topics[0], keccak256("SwapCounted(address,bytes32,uint256,uint256)"));
            assertEq(logs[0].topics[1], bytes32(uint256(uint160(actors[index]))));
            assertEq(logs[0].topics[2], keccak256(abi.encode(key)));
            assertEq(logs[0].data, abi.encode(expected[index], i + 1));
            assertEq(hook.swapCount(actors[0]), expected[0]);
            assertEq(hook.swapCount(actors[1]), expected[1]);
            assertEq(hook.totalSwaps(), i + 1);
        }
        assertEq(hook.swapCount(address(manager)), 0);
    }

    function test_lastRepresentableTotalSucceedsThenOverflowIsAtomic() public {
        address sender = address(0xA11CE);
        stdstore.target(address(hook)).sig("totalSwaps()").checked_write(type(uint256).max - 1);
        stdstore.target(address(hook))
            .sig("swapCount(address)")
            .with_key(sender)
            .checked_write(type(uint256).max - 1);
        _observe(sender, SwapParams(true, -1, 1), BalanceDelta.wrap(0), "");
        assertEq(hook.totalSwaps(), type(uint256).max);
        assertEq(hook.swapCount(sender), type(uint256).max);
        // A fresh sender reaches the total increment, so its earlier increment must be rolled back.
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(address(manager));
        hook.afterSwap(address(0xB0B), key, SwapParams(true, -1, 1), BalanceDelta.wrap(0), "");
        assertEq(hook.swapCount(address(0xB0B)), 0);
        assertEq(hook.swapCount(sender), type(uint256).max);
        assertEq(hook.totalSwaps(), type(uint256).max);
    }

    function test_countViewsWorkThroughStaticCallAfterWrites() public {
        _observe(address(0xA11CE), SwapParams(true, -1, 1), BalanceDelta.wrap(0), "");
        (bool totalOk, bytes memory total) = address(hook).staticcall(abi.encodeWithSignature("totalSwaps()"));
        (bool senderOk, bytes memory count) =
            address(hook).staticcall(abi.encodeWithSignature("swapCount(address)", address(0xA11CE)));
        (bool freshOk, bytes memory fresh) =
            address(hook).staticcall(abi.encodeWithSignature("swapCount(address)", address(0xB0B)));
        assertTrue(totalOk && senderOk && freshOk);
        assertEq(abi.decode(total, (uint256)), 1);
        assertEq(abi.decode(count, (uint256)), 1);
        assertEq(abi.decode(fresh, (uint256)), 0);
    }

    function _observe(address sender, SwapParams memory params, BalanceDelta delta, bytes memory data)
        private
    {
        vm.prank(address(manager));
        (bytes4 selector, int128 adjustment) = hook.afterSwap(sender, key, params, delta, data);
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(adjustment, 0);
    }
}
