// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SIMDTEST} from "src/SIMDTEST.sol";
import {SIMDTESTVault, ISIMDTESTFeeSource} from "src/SIMDTESTVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {VaultRewardSource} from "./helpers/VaultRewardSource.sol";

contract VaultFailurePathsTest is Test {
    SIMDTEST token;
    MockERC20 reward;
    VaultRewardSource source;
    SIMDTESTVault vault;
    address alice;
    address bob;

    function setUp() public {
        token = new SIMDTEST();
        reward = new MockERC20("Reward", "RWD", 0);
        source = new VaultRewardSource(token, reward);
        vault = source.vault();
        alice = makeAddr("failure alice");
        bob = makeAddr("failure bob");
        token.transfer(alice, 100 ether);
        token.transfer(bob, 100 ether);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
    }

    function test_InvalidDependenciesRejected() public {
        vm.expectRevert(SIMDTESTVault.InvalidAddress.selector);
        new SIMDTESTVault(IERC20(address(0)), reward, source);
        vm.expectRevert(SIMDTESTVault.InvalidAddress.selector);
        new SIMDTESTVault(token, IERC20(address(0)), source);
        vm.expectRevert(SIMDTESTVault.InvalidAddress.selector);
        new SIMDTESTVault(token, reward, ISIMDTESTFeeSource(address(0)));
        vm.expectRevert(SIMDTESTVault.InvalidAddress.selector);
        new SIMDTESTVault(token, token, source);
    }

    function test_ZeroStakeAndUnstakeDoNotConsumePendingRewards() public {
        _stake(alice, 50 ether);
        source.accrue(20 ether);
        bytes32 state = _state(alice);
        vm.prank(alice);
        vm.expectRevert(SIMDTESTVault.ZeroAmount.selector);
        vault.stake(0);
        vm.prank(alice);
        vm.expectRevert(SIMDTESTVault.ZeroAmount.selector);
        vault.unstake(0);
        assertEq(_state(alice), state);
        assertEq(vault.earned(alice), 20 ether);
    }

    function test_InsufficientAllowanceAndBalanceRollBackAccounting() public {
        _stake(alice, 50 ether);
        source.accrue(20 ether);
        vm.prank(bob);
        token.approve(address(vault), 0);
        bytes32 beforeState = _state(bob);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, 1 ether)
        );
        vault.stake(1 ether);
        assertEq(_state(bob), beforeState);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 100 ether, 100 ether + 1)
        );
        vault.stake(100 ether + 1);
        assertEq(_state(bob), beforeState);
        assertEq(vault.earned(alice), 20 ether);
    }

    function test_OverWithdrawalAndStrangerCannotCheckpointOrTakeRewards() public {
        _stake(alice, 50 ether);
        source.accrue(20 ether);
        bytes32 state = _state(alice);
        vm.prank(alice);
        vm.expectRevert(SIMDTESTVault.InsufficientStake.selector);
        vault.unstake(50 ether + 1);
        vm.prank(bob);
        vm.expectRevert(SIMDTESTVault.InsufficientStake.selector);
        vault.unstake(1);
        assertEq(_state(alice), state);
        vm.prank(bob);
        assertEq(vault.claim(), 0);
        assertEq(vault.earned(alice), 20 ether);
        vm.prank(alice);
        assertEq(vault.claim(), 20 ether);
    }

    function test_NotificationsRequireBothAccrualAndFundingAndCannotReplay() public {
        _stake(alice, 50 ether);
        source.accrue(10 ether);
        vm.expectRevert(SIMDTESTVault.OnlyHook.selector);
        vault.notifyReward(0);
        vm.expectRevert(SIMDTESTVault.UnfundedReward.selector);
        source.notifyOnly(10 ether); // Accrued but funds still at source.
        assertEq(vault.totalNotified(), 0);
        source.sweep();
        reward.mint(address(vault), 20 ether); // Funding alone cannot authorize another notification.
        vm.expectRevert(SIMDTESTVault.UnfundedReward.selector);
        source.notifyOnly(1);
        assertEq(vault.totalNotified(), 10 ether);
        vm.prank(alice);
        assertEq(vault.claim(), 10 ether);
        vm.expectRevert(SIMDTESTVault.UnfundedReward.selector);
        source.notifyOnly(10 ether);
        source.notifyOnly(0);
        assertEq(vault.earned(alice), 0);
        assertEq(vault.pending(), 0);
        assertEq(reward.balanceOf(address(vault)), 20 ether);
    }

    function test_DonationsDoNotCreateStakeOrDistributableRewards() public {
        _stake(alice, 20 ether);
        _stake(bob, 60 ether);
        source.accrue(40 ether);
        token.transfer(address(vault), 7 ether);
        reward.mint(address(vault), 11 ether);
        assertEq(vault.totalStaked(), 80 ether);
        assertEq(vault.earned(alice), 10 ether);
        assertEq(vault.earned(bob), 30 ether);
        assertEq(vault.pending(), 40 ether);
        vm.prank(alice);
        vault.unstake(20 ether);
        vm.prank(bob);
        vault.unstake(60 ether);
        vm.prank(alice);
        assertEq(vault.claim(), 10 ether);
        vm.prank(bob);
        assertEq(vault.claim(), 30 ether);
        assertEq(token.balanceOf(address(vault)), 7 ether);
        assertEq(reward.balanceOf(address(vault)), 11 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_PartialExitPreservesProRataHistoricalRewards(uint80 aSeed, uint80 bSeed, uint80 rewardSeed)
        public
    {
        uint256 a = bound(uint256(aSeed), 2, 100 ether);
        uint256 b = bound(uint256(bSeed), 1, 100 ether);
        uint256 fee = bound(uint256(rewardSeed), 1, 1e24);
        _stake(alice, a);
        _stake(bob, b);
        source.accrue(fee);
        uint256 firstAlice = fee * a / (a + b);
        uint256 firstBob = fee * b / (a + b);
        uint256 exit = a / 2;
        vm.prank(alice);
        vault.unstake(exit);
        assertApproxEqAbs(vault.earned(alice), firstAlice, 1);
        assertApproxEqAbs(vault.earned(bob), firstBob, 1);
        source.accrue(fee);
        uint256 secondAlice = fee * (a - exit) / (a - exit + b);
        uint256 secondBob = fee * b / (a - exit + b);
        vm.prank(alice);
        uint256 paidAlice = vault.claim();
        vm.prank(bob);
        uint256 paidBob = vault.claim();
        assertApproxEqAbs(paidAlice, firstAlice + secondAlice, 2);
        assertApproxEqAbs(paidBob, firstBob + secondBob, 2);
        assertLe(paidAlice + paidBob, fee * 2);
        assertEq(reward.balanceOf(address(vault)) + paidAlice + paidBob, fee * 2);
        vm.prank(alice);
        vault.unstake(a - exit);
        vm.prank(bob);
        vault.unstake(b);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
    }

    function _stake(address actor, uint256 amount) internal {
        vm.prank(actor);
        vault.stake(amount);
    }

    function _state(address actor) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                vault.totalStaked(),
                vault.balanceOf(actor),
                vault.rewardPerTokenStored(),
                vault.accountedFees(),
                vault.rewards(actor),
                vault.userRewardPerTokenPaid(actor),
                vault.scaledRemainder(),
                vault.userRemainder(actor),
                vault.queuedRewards(),
                token.balanceOf(actor),
                token.balanceOf(address(vault))
            )
        );
    }
}
