// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SIMDTESTHook} from "../../src/SIMDTESTHook.sol";

/// @dev Test settlement router; deliberately not a production slippage/deadline router.
contract PoolRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(0), msg.sender, key, abi.encode(params))), (BalanceDelta));
    }

    function liquidity(PoolKey memory key, int256 amount) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(1), msg.sender, key, abi.encode(amount))), (BalanceDelta));
    }

    function sweepUnlocked(PoolKey memory key) external {
        manager.unlock(abi.encode(uint8(2), msg.sender, key, bytes("")));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (uint8 action, address payer, PoolKey memory key, bytes memory params) =
            abi.decode(data, (uint8, address, PoolKey, bytes));
        BalanceDelta delta;
        if (action == 0) {
            delta = manager.swap(key, abi.decode(params, (SwapParams)), "");
        } else if (action == 1) {
            (delta,) = manager.modifyLiquidity(
                key, ModifyLiquidityParams(-887220, 887220, abi.decode(params, (int256)), 0), ""
            );
        } else {
            SIMDTESTHook(address(key.hooks)).sweep();
        }
        _settle(key.currency0, payer, delta.amount0());
        _settle(key.currency1, payer, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, address payer, int128 amount) private {
        if (amount < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), uint256(-int256(amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, payer, uint128(amount));
        }
    }
}
