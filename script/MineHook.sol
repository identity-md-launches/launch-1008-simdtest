// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Simulation-only helper: use the actual factory, manager and launch token when mining.
contract MineHook {
    error SaltNotFound();

    function find(address factory, IPoolManager manager, IERC20 token, uint256 start, uint256 count)
        external
        pure
        returns (bytes32 salt, address predicted)
    {
        bytes32 initHash = keccak256(abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, token)));
        for (uint256 i; i < count; ++i) {
            salt = bytes32(start + i);
            predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initHash)))));
            if (HookFlags.matches(predicted, HookFlags.REQUIRED)) return (salt, predicted);
        }
        revert SaltNotFound();
    }
}
