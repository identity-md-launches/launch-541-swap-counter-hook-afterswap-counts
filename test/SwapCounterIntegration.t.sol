// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapCounterHook} from "../src/SwapCounterHook.sol";
import {SwapCounterToken} from "../src/SwapCounterToken.sol";

contract SwapCounterIntegrationTest is HookFixture {
    using StateLibrary for IPoolManager;

    ERC20 internal token0;
    ERC20 internal token1;
    PoolRouter internal router;
    PoolRouter internal secondRouter;
    PoolKey internal plainKey;
    uint256 internal constant LIQUIDITY = 1e24;

    function setUp() public override {
        super.setUp();
        ERC20 a = new SwapCounterToken();
        ERC20 b = new MockERC20("Quote", "Q", 1e27);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        router = new PoolRouter(manager);
        secondRouter = new PoolRouter(manager);
        token0.approve(address(router), 1e26);
        token1.approve(address(router), 1e26);
        token0.approve(address(secondRouter), 1e26);
        token1.approve(address(secondRouter), 1e26);
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, hook);
        plainKey = PoolKey(key.currency0, key.currency1, key.fee, key.tickSpacing, IHooks(address(0)));
        assertEq(manager.initialize(key, SQRT_PRICE_1_1), 0);
        manager.initialize(plainKey, SQRT_PRICE_1_1);
        router.modifyLiquidity(key, int256(LIQUIDITY));
        router.modifyLiquidity(plainKey, int256(LIQUIDITY));
    }

    function test_initializeSeedTradeBothWaysAndUnwind() public {
        assertEq(hook.totalSwaps(), 0);
        vm.expectEmit(true, true, false, true, address(hook));
        emit SwapCounterHook.SwapCounted(address(router), key.toId(), 1, 1);
        router.swap(key, _params(true, -1 ether), "", true);
        vm.expectEmit(true, true, false, true, address(hook));
        emit SwapCounterHook.SwapCounted(address(router), key.toId(), 2, 2);
        router.swap(key, _params(false, -1 ether), "", true);
        secondRouter.swap(key, _params(true, 1 ether), "", true);
        assertEq(hook.totalSwaps(), 3);
        assertEq(hook.swapCount(address(router)), 2);
        assertEq(hook.swapCount(address(secondRouter)), 1);
        assertEq(hook.swapCount(address(this)), 0);
        BalanceDelta removed = router.modifyLiquidity(key, -int256(LIQUIDITY));
        assertGt(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), 0);
        assertEq(hook.totalSwaps(), 3);
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 0);
    }

    function testFuzz_matchesUnhookedPoolAmountsPricesAndFees(
        bool direction,
        bool exactOutput,
        uint96 rawAmount
    ) public {
        int256 amount = int256(bound(uint256(rawAmount), 1e6, 10 ether));
        SwapParams memory params = _params(direction, exactOutput ? amount : -amount);
        uint256 before0 = token0.balanceOf(address(this));
        uint256 before1 = token1.balanceOf(address(this));
        BalanceDelta hookedDelta = router.swap(key, params, hex"ff00", true);
        uint256 after0 = token0.balanceOf(address(this));
        uint256 after1 = token1.balanceOf(address(this));
        assertEq(int256(after0) - int256(before0), hookedDelta.amount0());
        assertEq(int256(after1) - int256(before1), hookedDelta.amount1());
        BalanceDelta plainDelta = router.swap(plainKey, params, "", true);
        assertEq(BalanceDelta.unwrap(hookedDelta), BalanceDelta.unwrap(plainDelta));
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) =
            IPoolManager(address(manager)).getSlot0(key.toId());
        (uint160 plainPrice, int24 plainTick, uint24 plainProtocolFee, uint24 plainLpFee) =
            IPoolManager(address(manager)).getSlot0(plainKey.toId());
        assertEq(price, plainPrice);
        assertEq(tick, plainTick);
        assertEq(protocolFee, plainProtocolFee);
        assertEq(lpFee, plainLpFee);
        assertEq(lpFee, 3000);
        (uint256 fee0, uint256 fee1) = IPoolManager(address(manager)).getFeeGrowthGlobals(key.toId());
        (uint256 plainFee0, uint256 plainFee1) =
            IPoolManager(address(manager)).getFeeGrowthGlobals(plainKey.toId());
        assertEq(fee0, plainFee0);
        assertEq(fee1, plainFee1);
        assertEq(hook.totalSwaps(), 1);
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 0);
    }

    function test_countsAcrossPoolsAndIgnoresForgedUserInHookData() public {
        PoolKey memory otherKey = PoolKey(key.currency0, key.currency1, 500, 10, hook);
        manager.initialize(otherKey, SQRT_PRICE_1_1);
        router.modifyLiquidity(otherKey, int256(LIQUIDITY));
        router.swap(key, _params(true, -1 ether), abi.encode(address(0xBAD)), true);
        router.swap(otherKey, _params(false, -1 ether), abi.encode(address(0xBAD)), true);
        assertEq(hook.totalSwaps(), 2);
        assertEq(hook.swapCount(address(router)), 2);
        assertEq(hook.swapCount(address(0xBAD)), 0);
    }

    function test_unsettledSwapRollsBackCountersAndPoolState() public {
        router.swap(key, _params(true, -1 ether), "", true);
        (uint160 beforePrice,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        secondRouter.swap(key, _params(false, -1 ether), "", false);
        (uint160 afterPrice,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(afterPrice, beforePrice);
        assertEq(hook.totalSwaps(), 1);
        assertEq(hook.swapCount(address(router)), 1);
        assertEq(hook.swapCount(address(secondRouter)), 0);
        secondRouter.swap(key, _params(false, -1 ether), "", true);
        assertEq(hook.totalSwaps(), 2);
    }

    function test_zeroSwapRevertsWithoutCounting() public {
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        router.swap(key, _params(true, 0), "", true);
        assertEq(hook.totalSwaps(), 0);
    }

    function test_predictedAddressCannotInitializeBeforeHookExists() public {
        address undeployed = address(uint160(address(hook)) + (1 << 14));
        assertEq(undeployed.code.length, 0);
        PoolKey memory absentKey = PoolKey(key.currency0, key.currency1, 3000, 60, IHooks(undeployed));
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        manager.initialize(absentKey, SQRT_PRICE_1_1);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(absentKey.toId());
        assertEq(price, 0);
    }

    function _params(bool direction, int256 amount) private pure returns (SwapParams memory) {
        return
            SwapParams(
                direction, amount, direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            );
    }
}
