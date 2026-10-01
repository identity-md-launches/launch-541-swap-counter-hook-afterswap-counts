// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Test-only ERC20 router. It settles real PoolManager deltas; not suitable for production routing.
contract PoolRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData, bool settle)
        external
        returns (BalanceDelta)
    {
        return BalanceDelta.wrap(
            abi.decode(
                manager.unlock(abi.encode(msg.sender, key, true, abi.encode(params, hookData), settle)),
                (int256)
            )
        );
    }

    function modifyLiquidity(PoolKey memory key, int256 amount) external returns (BalanceDelta) {
        return BalanceDelta.wrap(
            abi.decode(
                manager.unlock(
                    abi.encode(
                        msg.sender,
                        key,
                        false,
                        abi.encode(ModifyLiquidityParams(-600, 600, amount, bytes32(0))),
                        true
                    )
                ),
                (int256)
            )
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (address payer, PoolKey memory key, bool isSwap, bytes memory operation, bool settle) =
            abi.decode(data, (address, PoolKey, bool, bytes, bool));
        BalanceDelta delta;
        if (isSwap) {
            (SwapParams memory params, bytes memory hookData) = abi.decode(operation, (SwapParams, bytes));
            delta = manager.swap(key, params, hookData);
        } else {
            (delta,) = manager.modifyLiquidity(key, abi.decode(operation, (ModifyLiquidityParams)), "");
        }
        if (settle) {
            _settle(key.currency0, payer, delta.amount0());
            _settle(key.currency1, payer, delta.amount1());
        }
        return abi.encode(BalanceDelta.unwrap(delta));
    }

    function _settle(Currency currency, address payer, int128 delta) private {
        if (delta < 0) {
            manager.sync(currency);
            require(
                IERC20(Currency.unwrap(currency))
                    .transferFrom(payer, address(manager), uint256(-int256(delta)))
            );
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, payer, uint256(int256(delta)));
        }
    }
}
