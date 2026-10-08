// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SIMDTEST} from "src/SIMDTEST.sol";
import {SIMDTESTVault} from "src/SIMDTESTVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {VaultRewardSource} from "./helpers/VaultRewardSource.sol";

/// @dev Independent oracle for the vault's economics. It never reads the vault's accumulator, boundary
/// records or remainders: it apportions every fee at arrival among the stakes it knows were eligible,
/// where a stake is eligible from the block after it was made, a stake cancelled in its own block was
/// never eligible, and fees that arrive while nothing is eligible wait for the first stakes to mature.
contract VaultModelHandler is Test {
    SIMDTEST public immutable token;
    MockERC20 public immutable reward;
    VaultRewardSource public immutable source;
    SIMDTESTVault public immutable vault;
    address[3] public actors;
    uint256[3] public active;
    uint256[3] public pendingAmount;
    uint256[3] public pendingBlock;
    uint256[3] public credits;
    uint256[3] public rewardIntervals;
    uint256[3] public claimed;
    uint256 public totalActive;
    uint256 public accrued;
    uint256 public idleRewards;
    uint256 public principalDonations;
    uint256 public rewardDonations;
    uint256 public maturations;
    uint256 public cancellations;

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

    function principal(uint256 i) public view returns (uint256) {
        return active[i] + pendingAmount[i];
    }

    function totalPrincipal() public view returns (uint256) {
        return totalActive + pendingAmount[0] + pendingAmount[1] + pendingAmount[2];
    }

    function stake(uint256 actorSeed, uint256 amountSeed) external {
        _mature();
        uint256 i = actorSeed % 3;
        uint256 available = token.balanceOf(actors[i]);
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 1, available);
        vm.prank(actors[i]);
        vault.stake(amount);
        pendingAmount[i] += amount;
        pendingBlock[i] = block.number;
    }

    function unstake(uint256 actorSeed, uint256 amountSeed) external {
        _mature();
        uint256 i = actorSeed % 3;
        uint256 held = principal(i);
        if (held == 0) return;
        uint256 amount = bound(amountSeed, 1, held);
        vm.prank(actors[i]);
        vault.unstake(amount);
        // A same-block stake is cancelled first and never counted as eligible.
        uint256 cancelled = amount < pendingAmount[i] ? amount : pendingAmount[i];
        if (cancelled != 0) ++cancellations;
        pendingAmount[i] -= cancelled;
        active[i] -= amount - cancelled;
        totalActive -= amount - cancelled;
    }

    function accrue(uint256 amountSeed) external {
        _mature();
        uint256 amount = bound(amountSeed, 1, 1e24);
        source.accrue(amount);
        accrued += amount;
        if (totalActive == 0) {
            idleRewards += amount;
        } else {
            for (uint256 i; i < 3; ++i) {
                if (active[i] == 0) continue;
                credits[i] += amount * active[i] / totalActive;
                ++rewardIntervals[i];
            }
        }
    }

    function claim(uint256 actorSeed) external {
        _mature();
        uint256 i = actorSeed % 3;
        uint256 beforeBalance = reward.balanceOf(actors[i]);
        vm.prank(actors[i]);
        uint256 paid = vault.claim();
        claimed[i] += paid;
        assertEq(reward.balanceOf(actors[i]) - beforeBalance, paid);
    }

    function sweep() external {
        _mature();
        source.sweep();
    }

    function roll(uint256 blocksSeed) external {
        vm.roll(block.number + bound(blocksSeed, 1, 3));
        _mature();
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
        _mature();
        uint256 i = actorSeed % 3;
        vm.prank(actors[i]);
        vm.expectRevert(SIMDTESTVault.InsufficientStake.selector);
        vault.unstake(principal(i) + 1);
    }

    function exitAll() external {
        _mature();
        for (uint256 i; i < 3; ++i) {
            uint256 held = principal(i);
            if (held != 0) {
                vm.prank(actors[i]);
                vault.unstake(held);
                if (pendingAmount[i] != 0) ++cancellations;
                pendingAmount[i] = 0;
                totalActive -= active[i];
                active[i] = 0;
            }
            vm.prank(actors[i]);
            claimed[i] += vault.claim();
        }
    }

    /// @dev Eager maturation: stakes from earlier blocks become eligible, and whatever queued while
    /// nothing was eligible goes to them pro rata. The vault does this lazily, so the two must agree
    /// however long the vault goes untouched.
    function _mature() internal {
        uint256 matured;
        for (uint256 i; i < 3; ++i) {
            if (pendingAmount[i] != 0 && pendingBlock[i] < block.number) matured += pendingAmount[i];
        }
        if (matured == 0) return;
        ++maturations;
        if (idleRewards != 0) {
            assertEq(totalActive, 0, "model: rewards can only queue while nothing is eligible");
            for (uint256 i; i < 3; ++i) {
                if (pendingAmount[i] == 0 || pendingBlock[i] >= block.number) continue;
                credits[i] += idleRewards * pendingAmount[i] / matured;
                ++rewardIntervals[i];
            }
            idleRewards = 0;
        }
        for (uint256 i; i < 3; ++i) {
            if (pendingAmount[i] == 0 || pendingBlock[i] >= block.number) continue;
            active[i] += pendingAmount[i];
            totalActive += pendingAmount[i];
            pendingAmount[i] = 0;
        }
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
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.stake.selector;
        selectors[1] = handler.unstake.selector;
        selectors[2] = handler.accrue.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.sweep.selector;
        selectors[5] = handler.donate.selector;
        selectors[6] = handler.invalidWithdrawal.selector;
        selectors[7] = handler.roll.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_PrincipalAndRewardsMatchIndependentModel() public view {
        uint256 totalClaims;
        uint256 owed;
        uint256 pendingTotal;
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            uint256 principal = handler.principal(i);
            uint256 paid = handler.claimed(i);
            uint256 earned = vault.earned(actor);
            assertEq(vault.balanceOf(actor), principal);
            assertEq(token.balanceOf(actor) + principal, INITIAL_PRINCIPAL);
            assertEq(reward.balanceOf(actor), paid);
            // A stake made in the current block is pending; the vault must agree on how much.
            if (handler.pendingBlock(i) == block.number) {
                assertEq(vault.pendingOf(actor) + vault.activeOf(actor), principal);
                assertEq(vault.pendingOf(actor), handler.pendingAmount(i), "pending bucket disagrees");
            }
            pendingTotal += handler.pendingAmount(i);
            uint256 expectedFloor = handler.credits(i);
            // Each per-arrival floor loses <1 wei. With <=64 steps and <=3000 ether
            // stake, the vault's 1e36 global precision contributes <1 further wei.
            assertGe(paid + earned + 1, expectedFloor, "staker lost historical rewards");
            assertLe(paid + earned, expectedFloor + handler.rewardIntervals(i) + 1, "staker captured others' rewards");
            totalClaims += paid;
            owed += earned;
        }
        assertEq(vault.totalStaked(), handler.totalPrincipal());
        assertEq(vault.activeStake() + vault.pendingStake(), handler.totalPrincipal());
        // The vault flushes lazily, so its pending bucket may still hold stakes the model matured;
        // it can never hold more than the model's pending total plus those.
        assertGe(vault.pendingStake(), pendingTotal);
        assertEq(token.balanceOf(address(vault)), handler.totalPrincipal() + handler.principalDonations());
        assertEq(vault.totalClaimed(), totalClaims);
        assertEq(vault.totalNotified(), source.swept());
        assertEq(source.totalStakingFees(), handler.accrued());
        assertEq(vault.pending(), handler.accrued() - totalClaims);
        assertLe(totalClaims + owed, handler.accrued(), "rewards must remain solvent");
        // Everything accrued is either paid, owed to a current or former staker, or still queued/dust.
        assertGe(totalClaims + owed + handler.idleRewards() + 3 * 64 + 3, handler.accrued(), "rewards leaked");
        assertEq(reward.balanceOf(address(vault)) + totalClaims, source.swept() + handler.rewardDonations());
        assertEq(reward.balanceOf(address(source)) + source.swept(), handler.accrued());
        assertEq(token.totalSupply(), 1e27);
    }

    function afterInvariant() public {
        handler.exitAll();
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.activeStake(), 0);
        assertEq(vault.pendingStake(), 0);
        assertEq(token.balanceOf(address(vault)), handler.principalDonations());
        for (uint256 i; i < 3; ++i) {
            assertEq(token.balanceOf(handler.actors(i)), INITIAL_PRINCIPAL);
            assertEq(vault.earned(handler.actors(i)), 0);
        }
        invariant_PrincipalAndRewardsMatchIndependentModel();
    }
}
