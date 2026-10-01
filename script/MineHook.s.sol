// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapCounterHook} from "../src/SwapCounterHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @notice Read-only CREATE2 preparation. This script never broadcasts or reads environment variables.
contract MineHook {
    error InvalidDeployer();

    /// @param deployer The actual contract that will execute CREATE2 (e.g. the launch factory).
    /// @param manager The existing PoolManager on the target chain.
    /// @return predicted Address whose low 14 bits are 0x2040.
    /// @return salt Salt for that exact deployer and initCode.
    /// @return initCode Complete hook creation code including its constructor argument.
    function run(address deployer, IPoolManager manager)
        external
        view
        returns (address predicted, bytes32 salt, bytes memory initCode)
    {
        if (deployer == address(0)) revert InvalidDeployer();
        if (address(manager).code.length == 0) revert SwapCounterHook.InvalidPoolManager();
        bytes memory args = abi.encode(manager);
        (predicted, salt) =
            HookMiner.find(deployer, HookFlags.COUNTER_FLAGS, type(SwapCounterHook).creationCode, args);
        initCode = abi.encodePacked(type(SwapCounterHook).creationCode, args);
    }
}
