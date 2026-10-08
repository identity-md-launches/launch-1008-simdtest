// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {SIMDTESTHook} from "src/SIMDTESTHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract DeploymentBoundaryTest is LaunchFixture {
    function setUp() public {
        _setup(false);
    }

    function test_AllFourteenPermissionsMatchDeployedAddressIndependently() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        bool[14] memory flags = [
            p.beforeInitialize,
            p.afterInitialize,
            p.beforeAddLiquidity,
            p.afterAddLiquidity,
            p.beforeRemoveLiquidity,
            p.afterRemoveLiquidity,
            p.beforeSwap,
            p.afterSwap,
            p.beforeDonate,
            p.afterDonate,
            p.beforeSwapReturnDelta,
            p.afterSwapReturnDelta,
            p.afterAddLiquidityReturnDelta,
            p.afterRemoveLiquidityReturnDelta
        ];
        uint160 declared;
        for (uint256 i; i < flags.length; ++i) {
            if (flags[i]) declared |= uint160(1 << (13 - i));
        }
        assertEq(declared, 0x20cc);
        assertEq(uint160(address(hook)) & 0x3fff, declared);
        assertLe(abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, token)).length, 49_152);
        assertEq(address(hook.vault()), address(vault));
    }

    function test_WrongPermissionBitsRejectDirectDeployment() public {
        bytes32 initHash = keccak256(abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, token)));
        for (uint256 i; i < 10; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = vm.computeCreate2Address(salt, initHash, address(this));
            if (uint160(predicted) & 0x3fff == 0x20cc) continue;
            vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
            new SIMDTESTHook{salt: salt}(manager, token);
            assertEq(predicted.code.length, 0);
            return;
        }
        assertTrue(false, "could not select mismatched permissions");
    }

    function test_InvalidHookDependenciesRejectBeforePermissionValidation() public {
        vm.expectRevert(SIMDTESTHook.InvalidAddress.selector);
        new SIMDTESTHook(IPoolManager(address(0)), token);
        vm.expectRevert(SIMDTESTHook.InvalidAddress.selector);
        new SIMDTESTHook(manager, IERC20(address(0)));
        address noCode = makeAddr("noncontract token");
        vm.expectRevert(SIMDTESTHook.InvalidAddress.selector);
        new SIMDTESTHook(manager, IERC20(noCode));
        vm.expectRevert(SIMDTESTHook.InvalidAddress.selector);
        new SIMDTESTHook(manager, IERC20(IMD));
    }

    function test_StaticFeeAndTickSpacingCannotBeChangedByAnotherPool() public {
        PoolKey memory changed = key;
        changed.fee = 0x800000; // Uniswap dynamic fee flag.
        _expectInvalidPool();
        manager.initialize(changed, PRICE);
        changed.fee = 3000;
        _expectInvalidPool();
        manager.initialize(changed, PRICE);
        changed = key;
        changed.tickSpacing = 120;
        _expectInvalidPool();
        manager.initialize(changed, PRICE);
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        manager.initialize(key, PRICE);
        assertEq(hook.openingBlock(), block.number);
        assertEq(hook.antiSnipeBps(), 3000);
        _assertSettled();
    }

    function _expectInvalidPool() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(SIMDTESTHook.InvalidPool.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }
}
