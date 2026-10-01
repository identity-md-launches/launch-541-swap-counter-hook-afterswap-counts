// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice Observes swaps across all pools using this hook without modifying amounts or fees.
/// @dev `sender` is PoolManager's immediate swap caller (usually a router), not necessarily an EOA.
contract SwapCounterHook is BaseHook {
    error InvalidPoolManager();

    /// @notice Number of successful afterSwap callbacks attributed to each sender.
    mapping(address sender => uint256 count) public swapCount;

    /// @notice Number of successful afterSwap callbacks across all senders and pools.
    uint256 public totalSwaps;

    /// @notice Emitted once per afterSwap callback, with counts after incrementing.
    event SwapCounted(address indexed sender, PoolId indexed poolId, uint256 senderCount, uint256 totalCount);

    /// @param manager The trusted Uniswap v4 PoolManager for the target chain.
    /// @dev BaseHook rejects an address whose low 14 bits disagree with getHookPermissions().
    constructor(IPoolManager manager) BaseHook(manager) {
        if (address(manager).code.length == 0) revert InvalidPoolManager();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.afterSwap = true;
    }

    /// @dev The inherited external callback enforces onlyPoolManager. Pool parameters remain unrestricted.
    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    /// @dev No external calls, hookData decoding, fee updates, or custom accounting. Reverts roll back counts.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        uint256 senderCount = ++swapCount[sender];
        uint256 totalCount = ++totalSwaps;
        emit SwapCounted(sender, key.toId(), senderCount, totalCount);
        return (IHooks.afterSwap.selector, 0);
    }
}
