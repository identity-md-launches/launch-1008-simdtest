// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ShavingERC20} from "./mocks/ShavingERC20.sol";

contract StakingIntegrationTest is LaunchFixture {
    function setUp() public {
        _setup(false);
    }

    function test_JoinLeaveClaimBeforeAndAfterSweep() public {
        _stake(alice, 100 ether);
        vm.roll(block.number + 1); // A stake earns from the block after it is made.
        _swap(true, true, 1000 ether); // 10 IMD for Alice, still held as claims.
        _stake(bob, 300 ether);
        assertEq(vault.earned(alice), 10 ether);
        assertEq(vault.earned(bob), 0);
        vm.roll(block.number + 1);
        _swap(true, true, 2000 ether); // 5 Alice, 15 Bob.
        vm.prank(alice);
        vault.unstake(100 ether);
        _swap(true, true, 1000 ether); // 10 Bob.
        assertEq(vault.earned(alice), 15 ether);
        assertApproxEqAbs(vault.earned(bob), 25 ether, 1);
        assertEq(vault.pending(), 40 ether);
        assertEq(imd.balanceOf(address(vault)), 0);
        vm.prank(alice);
        assertEq(vault.claim(), 15 ether);
        assertEq(imd.balanceOf(alice), 15 ether);
        uint256 bobReward = vault.earned(bob);
        vm.prank(bob);
        assertEq(vault.claim(), bobReward);
        assertApproxEqAbs(imd.balanceOf(bob), 25 ether, 1);
        vm.prank(bob);
        assertEq(vault.claim(), 0);
        vm.prank(bob);
        vault.unstake(300 ether);
        assertEq(vault.totalStaked(), 0);
        assertLe(vault.pending(), 1); // Sub-wei accumulator residue is retained, never overpaid.
        assertEq(token.balanceOf(alice), 10_000 ether);
        assertEq(token.balanceOf(bob), 10_000 ether);
        _assertSettled();
    }

    function test_RewardTransferFailureRollsBackSweepButCannotLockPrincipal() public {
        _stake(alice, 100 ether);
        vm.roll(block.number + 1);
        _swap(true, true, 1000 ether);
        uint256 anti = hook.antiSnipeFees();
        uint256 staking = hook.stakingFees();
        uint256 claims = manager.balanceOf(address(hook), Currency.wrap(IMD).toId());
        vm.mockCall(IMD, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(false));
        vm.expectRevert();
        hook.sweep();
        assertEq(hook.antiSnipeFees(), anti);
        assertEq(hook.stakingFees(), staking);
        assertEq(manager.balanceOf(address(hook), Currency.wrap(IMD).toId()), claims);
        vm.prank(alice);
        vault.unstake(100 ether);
        assertEq(token.balanceOf(alice), 10_000 ether);
        assertEq(vault.earned(alice), staking);
        vm.clearMockedCalls();
        vm.prank(alice);
        assertEq(vault.claim(), staking);
        _assertSettled();
    }

    /// A paired token that delivers less than requested must not strand the hackathon payout.
    function test_ShortDeliveryByIMDStillSweepsBothStreams() public {
        _stake(alice, 100 ether);
        vm.roll(block.number + 1);
        _swap(true, true, 1000 ether);
        uint256 anti = hook.antiSnipeFees();
        uint256 staking = hook.stakingFees();
        assertGt(anti, 0);
        assertEq(staking, 10 ether);
        vm.etch(IMD, address(new ShavingERC20()).code);
        hook.sweep();
        assertEq(imd.balanceOf(hook.HACKATHON_VAULT()), anti - 1);
        assertEq(imd.balanceOf(address(vault)), staking - 1);
        assertEq(vault.totalNotified(), staking - 1);
        assertEq(hook.antiSnipeFees() + hook.stakingFees(), 0);
        // Rewards are still credited on accrued fees, so the shortfall lands on the last claim.
        assertEq(vault.earned(alice), staking);
        vm.prank(alice);
        vm.expectRevert();
        vault.claim();
        vm.prank(alice);
        vault.unstake(100 ether); // Principal is never affected.
        assertEq(token.balanceOf(alice), 10_000 ether);
        _assertSettled();
    }

    function test_AccruedFeesBeforeFirstStakeAreQueued() public {
        _swap(true, true, 1000 ether);
        hook.sweep();
        assertEq(vault.queuedRewards(), 10 ether);
        _stake(alice, 1 ether);
        assertEq(vault.earned(alice), 0); // Nothing until her stake matures in the next block.
        vm.roll(block.number + 1);
        assertEq(vault.earned(alice), 10 ether); // The queue goes to the first matured stake.
        _stake(bob, 1 ether);
        assertEq(vault.earned(alice), 10 ether);
        assertEq(vault.earned(bob), 0);
        vm.prank(alice);
        vault.claim();
        assertEq(imd.balanceOf(alice), 10 ether);
    }

    function test_SameBlockStakersShareTheQueueProRata() public {
        _swap(true, true, 1000 ether);
        _stake(alice, 1 ether);
        _stake(bob, 3 ether);
        vm.roll(block.number + 1);
        assertEq(vault.earned(alice), 2.5 ether);
        assertEq(vault.earned(bob), 7.5 ether);
    }
}
