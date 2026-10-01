// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {SwapCounterHook} from "src/SwapCounterHook.sol";
import {SwapCounterToken} from "src/SwapCounterToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";

/// @dev Each successful action is replayed against an identically funded pool without a hook.
/// Bounds keep both pools within the seeded range at the configured sequence depth.
contract CounterPoolHandler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    SwapCounterHook public immutable hook;
    ERC20 public immutable token0;
    ERC20 public immutable token1;
    PoolRouter[2] public routers;
    PoolKey internal key;
    PoolKey internal plainKey;
    uint256[2] public swapsByRouter;
    uint256 public successfulSwaps;
    uint256 public extraLiquidity;

    constructor(IPoolManager manager_, SwapCounterHook hook_, PoolKey memory key_) {
        manager = manager_;
        hook = hook_;
        key = key_;
        plainKey = PoolKey(key.currency0, key.currency1, key.fee, key.tickSpacing, IHooks(address(0)));
        token0 = ERC20(Currency.unwrap(key.currency0));
        token1 = ERC20(Currency.unwrap(key.currency1));
        for (uint256 i; i < 2; ++i) {
            routers[i] = new PoolRouter(manager_);
            token0.approve(address(routers[i]), type(uint256).max);
            token1.approve(address(routers[i]), type(uint256).max);
        }
    }

    function swap(uint8 routerSeed, bool direction, bool exactOutput, uint256 rawAmount, bytes32 data)
        public
    {
        uint256 index = routerSeed % 2;
        int256 amount = int256(bound(rawAmount, 1, 10 ether));
        SwapParams memory params = _params(direction, exactOutput ? amount : -amount);
        uint256 feesBefore = manager.protocolFeesAccrued(direction ? key.currency0 : key.currency1);
        uint256 before0 = token0.balanceOf(address(this));
        uint256 before1 = token1.balanceOf(address(this));
        vm.recordLogs();
        BalanceDelta actual = routers[index].swap(key, params, abi.encode(data), true);
        _checkEvent(vm.getRecordedLogs(), index);
        assertEq(int256(token0.balanceOf(address(this))) - int256(before0), actual.amount0());
        assertEq(int256(token1.balanceOf(address(this))) - int256(before1), actual.amount1());
        uint256 feesAfterHook = manager.protocolFeesAccrued(direction ? key.currency0 : key.currency1);
        BalanceDelta referenceDelta = routers[index].swap(plainKey, params, "", true);
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(referenceDelta), "swap amounts changed");
        uint256 feesAfterPlain = manager.protocolFeesAccrued(direction ? key.currency0 : key.currency1);
        assertEq(feesAfterHook - feesBefore, feesAfterPlain - feesAfterHook, "protocol fee changed");
        ++successfulSwaps;
        ++swapsByRouter[index];
    }

    function changeLiquidity(bool remove, uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, remove ? extraLiquidity : 1e22);
        int256 change = remove ? -int256(amount) : int256(amount);
        BalanceDelta actual = routers[0].modifyLiquidity(key, change);
        BalanceDelta referenceDelta = routers[0].modifyLiquidity(plainKey, change);
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(referenceDelta), "LP amounts changed");
        if (remove) extraLiquidity -= amount;
        else extraLiquidity += amount;
    }

    function unsettledSwap(uint8 routerSeed, bool direction, uint256 rawAmount) public {
        bytes32 beforeState = stateDigest();
        int256 amount = int256(bound(rawAmount, 1, 10 ether));
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        routers[routerSeed % 2].swap(key, _params(direction, -amount), "", false);
        assertEq(stateDigest(), beforeState, "unsettled swap retained state");
    }

    function revokedApprovalSwap(uint8 routerSeed, bool direction) public {
        PoolRouter router = routers[routerSeed % 2];
        ERC20 input = direction ? token0 : token1;
        input.approve(address(router), 0);
        bytes32 beforeState = stateDigest();
        // Exact input is fully consumed within the funded range, including the fees.
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 0, 1 ether
            )
        );
        router.swap(key, _params(direction, -1 ether), "", true);
        assertEq(stateDigest(), beforeState, "failed token settlement retained state");
        assertEq(input.allowance(address(this), address(router)), 0);
        input.approve(address(router), type(uint256).max);
    }

    function invalidPriceLimit(uint8 routerSeed, bool direction) public {
        (uint160 price,,,) = manager.getSlot0(key.toId());
        bytes32 beforeState = stateDigest();
        vm.expectRevert(abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, price, price));
        routers[routerSeed % 2].swap(key, SwapParams(direction, -1 ether, price), "", true);
        assertEq(stateDigest(), beforeState, "invalid swap retained state");
    }

    function poolDigest(PoolKey memory poolKey) public view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(poolKey.toId());
        (uint256 fee0, uint256 fee1) = manager.getFeeGrowthGlobals(poolKey.toId());
        return keccak256(
            abi.encode(price, tick, protocolFee, lpFee, fee0, fee1, manager.getLiquidity(poolKey.toId()))
        );
    }

    function stateDigest() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                poolDigest(key),
                hook.totalSwaps(),
                hook.swapCount(address(routers[0])),
                hook.swapCount(address(routers[1])),
                token0.balanceOf(address(this)),
                token1.balanceOf(address(this)),
                token0.balanceOf(address(manager)),
                token1.balanceOf(address(manager)),
                manager.protocolFeesAccrued(key.currency0),
                manager.protocolFeesAccrued(key.currency1)
            )
        );
    }

    function _checkEvent(Vm.Log[] memory logs, uint256 routerIndex) private view {
        uint256 events;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            ++events;
            assertEq(logs[i].topics.length, 3);
            assertEq(logs[i].topics[0], keccak256("SwapCounted(address,bytes32,uint256,uint256)"));
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(routers[routerIndex])))));
            assertEq(logs[i].topics[2], PoolId.unwrap(key.toId()));
            assertEq(logs[i].data, abi.encode(swapsByRouter[routerIndex] + 1, successfulSwaps + 1));
        }
        assertEq(events, 1, "one event per successful swap");
    }

    function _params(bool direction, int256 amount) private pure returns (SwapParams memory) {
        return
            SwapParams(
                direction, amount, direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            );
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SwapCounterPoolInvariantTest is HookFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    CounterPoolHandler internal handler;
    ERC20 internal token0;
    ERC20 internal token1;
    PoolKey internal plainKey;

    function setUp() public override {
        super.setUp();
        ERC20 a = new SwapCounterToken();
        ERC20 b = new MockERC20("Quote", "Q", 1e27);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, hook);
        plainKey = PoolKey(key.currency0, key.currency1, key.fee, key.tickSpacing, IHooks(address(0)));
        manager.initialize(key, SQRT_PRICE_1_1);
        manager.initialize(plainKey, SQRT_PRICE_1_1);
        manager.setProtocolFeeController(address(this));
        // Unequal directional protocol fees exercise both fee paths in the differential oracle.
        manager.setProtocolFee(key, (500 << 12) | 1000);
        manager.setProtocolFee(plainKey, (500 << 12) | 1000);
        handler = new CounterPoolHandler(manager, hook, key);
        token0.transfer(address(handler), token0.balanceOf(address(this)));
        token1.transfer(address(handler), token1.balanceOf(address(this)));
        PoolRouter lpRouter = handler.routers(0);
        vm.startPrank(address(handler));
        lpRouter.modifyLiquidity(key, 1e24);
        lpRouter.modifyLiquidity(plainKey, 1e24);
        vm.stopPrank();

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = CounterPoolHandler.swap.selector;
        selectors[1] = CounterPoolHandler.changeLiquidity.selector;
        selectors[2] = CounterPoolHandler.unsettledSwap.selector;
        selectors[3] = CounterPoolHandler.revokedApprovalSwap.selector;
        selectors[4] = CounterPoolHandler.invalidPriceLimit.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_onlySuccessfulSwapsCountForTheirRouter() public view {
        uint256 total;
        for (uint256 i; i < 2; ++i) {
            uint256 count = hook.swapCount(address(handler.routers(i)));
            assertEq(count, handler.swapsByRouter(i));
            total += count;
        }
        assertEq(hook.totalSwaps(), total);
        assertEq(total, handler.successfulSwaps());
        assertEq(hook.swapCount(address(handler)), 0, "payer was counted instead of router");
        assertEq(hook.swapCount(address(manager)), 0);
    }

    function invariant_poolStateAndFeesMatchUnhookedPool() public view {
        assertEq(handler.poolDigest(key), handler.poolDigest(plainKey));
    }

    function invariant_valueIsConservedAndAllDeltasSettled() public view {
        IPoolManager poolManager = manager;
        assertEq(token0.totalSupply(), 1e27);
        assertEq(token1.totalSupply(), 1e27);
        assertEq(token0.balanceOf(address(handler)) + token0.balanceOf(address(manager)), 1e27);
        assertEq(token1.balanceOf(address(handler)) + token1.balanceOf(address(manager)), 1e27);
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 0);
        assertEq(poolManager.getNonzeroDeltaCount(), 0);
        assertFalse(poolManager.isUnlocked());
        assertEq(poolManager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency1), 0);
        for (uint256 i; i < 2; ++i) {
            address router = address(handler.routers(i));
            assertEq(token0.balanceOf(router), 0);
            assertEq(token1.balanceOf(router), 0);
            assertEq(poolManager.currencyDelta(router, key.currency0), 0);
            assertEq(poolManager.currencyDelta(router, key.currency1), 0);
        }
    }

    function test_repeatedSwapsFailuresFeeCollectionAndRecovery() public {
        handler.swap(0, true, false, 1, bytes32(0));
        handler.swap(1, false, true, 1, bytes32(type(uint256).max));
        handler.swap(0, false, false, 10 ether, bytes32(0));
        handler.unsettledSwap(1, true, 1 ether);
        handler.revokedApprovalSwap(0, false);
        handler.invalidPriceLimit(1, true);
        handler.changeLiquidity(false, 1e22);
        handler.swap(1, true, true, 1 ether, bytes32(0));
        handler.changeLiquidity(true, 1e22);
        handler.changeLiquidity(false, 0);
        invariant_onlySuccessfulSwapsCountForTheirRouter();
        invariant_poolStateAndFeesMatchUnhookedPool();
        invariant_valueIsConservedAndAllDeltasSettled();
        assertEq(hook.totalSwaps(), 4);
    }
}
