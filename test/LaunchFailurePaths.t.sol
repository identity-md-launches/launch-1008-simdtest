// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

abstract contract LaunchFailureScenarios is LaunchFixture {
    using StateLibrary for IPoolManager;

    function test_SecondSweepTransferFailureRevertsFirstPaymentAndNotification() public {
        _stake(alice, 100 ether);
        _swap(true, true, 1000 ether);
        bytes32 beforeState = _financialState();
        uint256 anti = hook.antiSnipeFees();
        uint256 staking = hook.stakingFees();
        uint256 hackBefore = imd.balanceOf(hook.HACKATHON_VAULT());
        vm.mockCall(IMD, abi.encodeCall(IERC20.transfer, (address(vault), staking)), abi.encode(false));
        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        hook.sweep();
        assertEq(_financialState(), beforeState, "second transfer failure must roll back the whole sweep");
        _assertSettled();
        vm.clearMockedCalls();
        vm.prank(bob);
        hook.sweep();
        assertEq(imd.balanceOf(hook.HACKATHON_VAULT()) - hackBefore, anti);
        assertEq(vault.totalNotified(), staking);
        assertEq(imd.balanceOf(address(vault)), staking);
        _assertSettled();
    }

    function test_FailedClaimPaymentRollsBackItsNestedSweepAndCanRetry() public {
        _stake(alice, 100 ether);
        _swap(true, true, 1000 ether);
        bytes32 beforeState = _financialState();
        uint256 reward = vault.earned(alice);
        vm.mockCall(IMD, abi.encodeCall(IERC20.transfer, (alice, reward)), abi.encode(false));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        vault.claim();
        assertEq(_financialState(), beforeState);
        assertEq(vault.earned(alice), reward);
        assertEq(vault.totalClaimed(), 0);
        _assertSettled();
        vm.clearMockedCalls();
        vm.prank(alice);
        assertEq(vault.claim(), reward);
        vm.prank(alice);
        assertEq(vault.claim(), 0);
        assertEq(vault.totalClaimed(), reward);
        _assertSettled();
    }

    function test_FailedPrincipalTransfersPreserveStakeAndRewardCheckpoints() public {
        _stake(alice, 100 ether);
        _swap(true, true, 1000 ether);
        bytes32 beforeState = _financialState();
        uint256 earned = vault.earned(alice);
        uint256 paid = vault.userRewardPerTokenPaid(alice);
        uint256 checkpoint = vault.rewardPerTokenStored();
        vm.mockCall(
            address(token), abi.encodeCall(IERC20.transferFrom, (alice, address(vault), 1 ether)), abi.encode(false)
        );
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vault.stake(1 ether);
        vm.clearMockedCalls();
        vm.mockCall(address(token), abi.encodeCall(IERC20.transfer, (alice, 1 ether)), abi.encode(false));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vault.unstake(1 ether);
        vm.clearMockedCalls();
        assertEq(_financialState(), beforeState);
        assertEq(vault.balanceOf(alice), 100 ether);
        assertEq(vault.totalStaked(), 100 ether);
        assertEq(vault.earned(alice), earned);
        assertEq(vault.userRewardPerTokenPaid(alice), paid);
        assertEq(vault.rewardPerTokenStored(), checkpoint);
        vm.prank(alice);
        vault.unstake(100 ether);
        assertEq(token.balanceOf(alice), 10_000 ether);
        assertEq(vault.earned(alice), earned);
    }

    function test_ZeroAndInvalidPriceSwapsPreserveAllAccounting() public {
        _stake(alice, 100 ether);
        _swap(true, true, 100 ether);
        bytes32 beforeState = _financialState();
        (uint160 price, int24 tick, uint24 protocol, uint24 lpFee) = manager.getSlot0(key.toId());
        for (uint256 mode; mode < 4; ++mode) {
            bool zeroForOne = (mode < 2) == hook.pairIsCurrency0();
            uint160 validLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
            router.swap(key, SwapParams(zeroForOne, 0, validLimit));
            // Paired specified swaps reject in the hook quote; the others reject in the actual swap.
            bytes memory reason = abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, price, price);
            if (mode == 0 || mode == 3) {
                reason = abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(hook),
                    IHooks.beforeSwap.selector,
                    reason,
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                );
            }
            vm.expectRevert(reason);
            router.swap(key, SwapParams(zeroForOne, mode % 2 == 0 ? -int256(1 ether) : int256(1 ether), price));
            assertEq(_financialState(), beforeState);
            _assertSettled();
        }
        (uint160 priceAfter, int24 tickAfter, uint24 protocolAfter, uint24 lpFeeAfter) = manager.getSlot0(key.toId());
        assertEq(priceAfter, price);
        assertEq(tickAfter, tick);
        assertEq(protocolAfter, protocol);
        assertEq(lpFeeAfter, lpFee);
        assertEq(lpFeeAfter, 12500);
    }

    function test_EmptyPoolAllModesLeaveNoClaimsOrFees() public {
        router.liquidity(key, -int256(1_000_000 ether));
        bytes32 beforeState = _financialState();
        for (uint256 mode; mode < 4; ++mode) {
            uint256 snapshot = vm.snapshotState();
            BalanceDelta delta = _swap(mode < 2, mode % 2 == 0, 100 ether);
            assertEq(_pairDelta(delta), 0);
            assertEq(_tokenDelta(delta), 0);
            assertEq(_financialState(), beforeState);
            _assertSettled();
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_CommonAdminCallsCannotChangeHookOrVault() public {
        _stake(alice, 100 ether);
        _swap(true, true, 1000 ether);
        bytes32 beforeState = _financialState();
        bytes[9] memory calls = [
            abi.encodeWithSignature("transferOwnership(address)", bob),
            abi.encodeWithSignature("setOwner(address)", bob),
            abi.encodeWithSignature("upgradeTo(address)", bob),
            abi.encodeWithSignature("setFee(uint256)", uint256(0)),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("unpause()"),
            abi.encodeWithSignature("setVault(address)", bob),
            abi.encodeWithSignature("withdraw(address,uint256)", bob, uint256(1 ether)),
            abi.encodeWithSignature("rescueTokens(address,address,uint256)", IMD, bob, uint256(1 ether))
        ];
        for (uint256 i; i < calls.length; ++i) {
            for (uint256 caller; caller < 2; ++caller) {
                address who = caller == 0 ? address(this) : bob;
                vm.prank(who);
                (bool hookAccepted,) = address(hook).call(calls[i]);
                vm.prank(who);
                (bool vaultAccepted,) = address(vault).call(calls[i]);
                assertFalse(hookAccepted);
                assertFalse(vaultAccepted);
            }
        }
        assertEq(_financialState(), beforeState);
        assertEq(vault.balanceOf(alice), 100 ether);
    }

    function _financialState() internal view returns (bytes32) {
        uint256[14] memory state = [
            hook.antiSnipeFees(),
            hook.stakingFees(),
            hook.totalStakingFees(),
            manager.balanceOf(address(hook), Currency.wrap(IMD).toId()),
            imd.balanceOf(hook.HACKATHON_VAULT()),
            imd.balanceOf(address(vault)),
            imd.balanceOf(address(manager)),
            imd.balanceOf(address(this)),
            imd.balanceOf(alice),
            token.balanceOf(address(manager)),
            token.balanceOf(alice),
            token.balanceOf(address(vault)),
            vault.totalNotified(),
            vault.totalClaimed()
        ];
        return keccak256(abi.encode(state));
    }
}

contract LaunchFailurePathsTest is LaunchFailureScenarios {
    function setUp() public {
        _setup(false);
    }
}

/// @notice Real mainnet PoolManager and IMD; explicitly skipped unless running on a fork.
contract LaunchFailurePathsForkTest is LaunchFailureScenarios {
    function setUp() public {
        _setup(true);
    }
}
