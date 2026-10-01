// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapCounterHook} from "../../src/SwapCounterHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";

abstract contract HookFixture is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    PoolManager internal manager;
    SwapCounterHook internal hook;
    PoolKey internal key;

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        (address predicted, bytes32 salt) = HookMiner.find(
            address(this), HookFlags.COUNTER_FLAGS, type(SwapCounterHook).creationCode, abi.encode(manager)
        );
        hook = new SwapCounterHook{salt: salt}(manager);
        assertEq(address(hook), predicted);
        key = PoolKey(Currency.wrap(address(0x1000)), Currency.wrap(address(0x2000)), 3000, 60, hook);
    }
}
