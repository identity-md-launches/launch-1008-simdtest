// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SIMDTEST} from "src/SIMDTEST.sol";
import {SIMDTESTVault} from "src/SIMDTESTVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {VaultRewardSource} from "./helpers/VaultRewardSource.sol";

contract VaultModelHandler is Test {
    SIMDTEST public immutable token;
    MockERC20 public immutable reward;
    VaultRewardSource public immutable source;
    SIMDTESTVault public immutable vault;
    address[3] public actors;
    uint256[3] public principal;
    uint256[3] public credits;
    uint256[3] public rewardIntervals;
    uint256[3] public claimed;
    uint256 public totalPrincipal;
    uint256 public accrued;
    uint256 public idleRewards;
    uint256 public principalDonations;
    uint256 public rewardDonations;

    constructor(SIMDTEST token_, MockERC20 reward_, VaultRewardSource source_) {
        token = token_;
        reward = reward_;
        source = source_;
        vault = source_.vault();
        for (uint256 i; i < 3; ++i) {
            actors[i] = makeAddr(string(abi.encode("model staker", i)));
            vm.prank(actors[i]);
            token.approve(address(vault), type(uint256).max);
        }
    }

    function stake(uint256 actorSeed, uint256 amountSeed) external {
        uint256 i = actorSeed % 3;
        uint256 available = token.balanceOf(actors[i]);
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 1, available);
        vm.prank(actors[i]);
        vault.stake(amount);
        principal[i] += amount;
        totalPrincipal += amount;
        if (idleRewards != 0) {
            credits[i] += idleRewards;
            idleRewards = 0;
        }
    }

    function unstake(uint256 actorSeed, uint256 amountSeed) external {
        uint256 i = actorSeed % 3;
        if (principal[i] == 0) return;
        uint256 amount = bound(amountSeed, 1, principal[i]);
        vm.prank(actors[i]);
        vault.unstake(amount);
        principal[i] -= amount;
        totalPrincipal -= amount;
    }

    function accrue(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 1e24);
        source.accrue(amount);
        accrued += amount;
        if (totalPrincipal == 0) {
            idleRewards += amount;
        } else {
            // Independent oracle: apportion each fee at arrival using only handler-owned stakes.
            // No rewardPerToken, checkpoint, or remainder values from the vault are consulted.
            for (uint256 i; i < 3; ++i) {
                credits[i] += amount * principal[i] / totalPrincipal;
                if (principal[i] != 0) ++rewardIntervals[i];
            }
        }
    }

    function claim(uint256 actorSeed) external {
        uint256 i = actorSeed % 3;
        uint256 beforeBalance = reward.balanceOf(actors[i]);
        vm.prank(actors[i]);
        uint256 paid = vault.claim();
        claimed[i] += paid;
        assertEq(reward.balanceOf(actors[i]) - beforeBalance, paid);
    }

    function sweep() external {
        source.sweep();
    }

    function donate(uint256 amountSeed, bool donateReward) external {
        uint256 amount = bound(amountSeed, 1, 1 ether);
        if (donateReward) {
            rewardDonations += amount;
            reward.mint(address(vault), amount);
        } else {
            principalDonations += amount;
            require(token.transfer(address(vault), amount));
        }
    }

    function invalidWithdrawal(uint256 actorSeed) external {
        uint256 i = actorSeed % 3;
        vm.prank(actors[i]);
        vm.expectRevert(SIMDTESTVault.InsufficientStake.selector);
        vault.unstake(principal[i] + 1);
    }

    function exitAll() external {
        for (uint256 i; i < 3; ++i) {
            if (principal[i] != 0) {
                vm.prank(actors[i]);
                vault.unstake(principal[i]);
                principal[i] = 0;
            }
            vm.prank(actors[i]);
            claimed[i] += vault.claim();
        }
        totalPrincipal = 0;
    }
}

contract VaultModelInvariantTest is Test {
    SIMDTEST token;
    MockERC20 reward;
    VaultRewardSource source;
    SIMDTESTVault vault;
    VaultModelHandler handler;
    uint256 constant INITIAL_PRINCIPAL = 1000 ether;

    function setUp() public {
        token = new SIMDTEST();
        reward = new MockERC20("Reward", "RWD", 0);
        source = new VaultRewardSource(token, reward);
        vault = source.vault();
        handler = new VaultModelHandler(token, reward, source);
        token.transfer(address(handler), 1e24);
        for (uint256 i; i < 3; ++i) {
            token.transfer(handler.actors(i), INITIAL_PRINCIPAL);
        }
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.stake.selector;
        selectors[1] = handler.unstake.selector;
        selectors[2] = handler.accrue.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.sweep.selector;
        selectors[5] = handler.donate.selector;
        selectors[6] = handler.invalidWithdrawal.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_PrincipalAndRewardsMatchIndependentModel() public view {
        uint256 totalClaims;
        uint256 owed;
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            uint256 principal = handler.principal(i);
            uint256 paid = handler.claimed(i);
            uint256 earned = vault.earned(actor);
            assertEq(vault.balanceOf(actor), principal);
            assertEq(token.balanceOf(actor) + principal, INITIAL_PRINCIPAL);
            assertEq(reward.balanceOf(actor), paid);
            uint256 expectedFloor = handler.credits(i);
            // Each per-arrival floor loses <1 wei. With <=64 steps and <=3000 ether
            // stake, the vault's 1e36 global precision contributes <1 further wei.
            assertGe(paid + earned + 1, expectedFloor, "staker lost historical rewards");
            assertLe(paid + earned, expectedFloor + handler.rewardIntervals(i) + 1, "staker captured others' rewards");
            totalClaims += paid;
            owed += earned;
        }
        assertEq(vault.totalStaked(), handler.totalPrincipal());
        assertEq(token.balanceOf(address(vault)), handler.totalPrincipal() + handler.principalDonations());
        assertEq(vault.totalClaimed(), totalClaims);
        assertEq(vault.totalNotified(), source.swept());
        assertEq(source.totalStakingFees(), handler.accrued());
        assertEq(vault.pending(), handler.accrued() - totalClaims);
        assertLe(totalClaims + owed, handler.accrued(), "rewards must remain solvent");
        assertEq(reward.balanceOf(address(vault)) + totalClaims, source.swept() + handler.rewardDonations());
        assertEq(reward.balanceOf(address(source)) + source.swept(), handler.accrued());
        assertEq(token.totalSupply(), 1e27);
    }

    function afterInvariant() public {
        handler.exitAll();
        assertEq(vault.totalStaked(), 0);
        assertEq(token.balanceOf(address(vault)), handler.principalDonations());
        for (uint256 i; i < 3; ++i) {
            assertEq(token.balanceOf(handler.actors(i)), INITIAL_PRINCIPAL);
            assertEq(vault.earned(handler.actors(i)), 0);
        }
        invariant_PrincipalAndRewardsMatchIndependentModel();
    }
}
