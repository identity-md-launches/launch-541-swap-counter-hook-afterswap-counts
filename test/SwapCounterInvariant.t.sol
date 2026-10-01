// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {SwapCounterHook} from "../src/SwapCounterHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";

/// @dev Models callbacks from the trusted manager separately from real-pool integration tests.
contract CounterHandler is Test {
    SwapCounterHook internal immutable hook;
    IPoolManager internal immutable manager;
    PoolKey internal key;
    uint256 public expectedTotal;
    uint256[8] public expectedBySender;

    constructor(SwapCounterHook hook_, IPoolManager manager_, PoolKey memory key_) {
        hook = hook_;
        manager = manager_;
        key = key_;
    }

    function recordSwap(uint8 actor, bool secondPool, bytes32 data) external {
        uint256 index = uint256(actor) % 8;
        key.fee = secondPool ? 500 : 3000;
        vm.prank(address(manager));
        (bytes4 selector, int128 delta) = hook.afterSwap(
            address(uint160(index)), key, SwapParams(true, -1, 1), BalanceDelta.wrap(0), abi.encode(data)
        );
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(delta, 0);
        ++expectedTotal;
        ++expectedBySender[index];
    }

    function unauthorizedAttempt(uint8 actor) external {
        (bool ok, bytes memory reason) = address(hook)
            .call(
                abi.encodeCall(
                    IHooks.afterSwap,
                    (
                        address(uint160(uint256(actor) % 8)),
                        key,
                        SwapParams(true, -1, 1),
                        BalanceDelta.wrap(0),
                        ""
                    )
                )
            );
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(ImmutableState.NotPoolManager.selector));
    }
}

contract SwapCounterInvariantTest is HookFixture {
    CounterHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new CounterHandler(hook, manager, key);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = CounterHandler.recordSwap.selector;
        selectors[1] = CounterHandler.unauthorizedAttempt.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_totalEqualsSumAndSuccessfulCallbacks() public view {
        uint256 sum;
        for (uint256 i; i < 8; ++i) {
            uint256 actual = hook.swapCount(address(uint160(i)));
            assertEq(actual, handler.expectedBySender(i));
            sum += actual;
        }
        assertEq(hook.totalSwaps(), sum);
        assertEq(hook.totalSwaps(), handler.expectedTotal());
        assertEq(hook.swapCount(address(manager)), 0);
    }
}
