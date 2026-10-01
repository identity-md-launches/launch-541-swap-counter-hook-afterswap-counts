// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MineHook} from "../script/MineHook.s.sol";
import {SwapCounterHook} from "../src/SwapCounterHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

contract MineHookTest is Test {
    function test_minedInitCodeDeploysAtPredictedAddress() public {
        PoolManager manager = new PoolManager(address(this));
        MineHook miner = new MineHook();
        (address predicted, bytes32 salt, bytes memory code) = miner.run(address(this), manager);
        assertEq(HookFlags.flagsOf(predicted), 0x2040);
        assertEq(code, abi.encodePacked(type(SwapCounterHook).creationCode, abi.encode(manager)));
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        assertEq(deployed, predicted);
        assertGt(deployed.code.length, 0);
        assertEq(address(SwapCounterHook(deployed).poolManager()), address(manager));
        (address next,,) = miner.run(address(this), manager);
        assertNotEq(next, deployed);
    }

    function test_invalidDeploymentParametersRejected() public {
        MineHook miner = new MineHook();
        vm.expectRevert(MineHook.InvalidDeployer.selector);
        miner.run(address(0), IPoolManager(address(0)));
        vm.expectRevert(SwapCounterHook.InvalidPoolManager.selector);
        miner.run(address(this), IPoolManager(address(0)));
    }
}
