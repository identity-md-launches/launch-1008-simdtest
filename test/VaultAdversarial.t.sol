// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SIMDTESTVault, ISIMDTESTFeeSource} from "../src/SIMDTESTVault.sol";

contract VaultAuditToken is ERC20 {
    constructor() ERC20("Audit", "AUD") {}

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }
}

contract VaultAuditSource is ISIMDTESTFeeSource {
    uint256 public totalStakingFees;
    uint256 public lastAccrualBlock;
    mapping(uint256 => uint256) public stakingFeesAtEndOf;
    uint256 public swept;
    VaultAuditToken public reward;
    SIMDTESTVault public vault;

    constructor(VaultAuditToken stake, VaultAuditToken reward_) {
        reward = reward_;
        lastAccrualBlock = block.number;
        vault = new SIMDTESTVault(stake, reward_, this);
    }

    /// @dev Mirrors SIMDTESTHook._accrue, including the per-block boundary record.
    function accrue(uint256 value) external {
        if (block.number != lastAccrualBlock) {
            stakingFeesAtEndOf[lastAccrualBlock] = totalStakingFees;
            lastAccrualBlock = block.number;
        }
        totalStakingFees += value;
        reward.mint(address(this), value);
    }

    function sweep() external {
        uint256 amount = totalStakingFees - swept;
        swept = totalStakingFees;
        reward.transfer(address(vault), amount);
        vault.notifyReward(amount);
    }

    function notifyWithoutFunding(uint256 value) external {
        vault.notifyReward(value);
    }
}

contract VaultAdversarialTest is Test {
    VaultAuditToken stake;
    VaultAuditToken reward;
    VaultAuditSource source;
    SIMDTESTVault vault;
    address[4] actors;

    function setUp() public {
        stake = new VaultAuditToken();
        reward = new VaultAuditToken();
        source = new VaultAuditSource(stake, reward);
        vault = source.vault();
        for (uint256 i; i < 4; i++) {
            actors[i] = makeAddr(string(abi.encodePacked("actor", bytes1(uint8(i)))));
            stake.mint(actors[i], 1e25);
            vm.prank(actors[i]);
            stake.approve(address(vault), type(uint256).max);
        }
    }

    function test_UnfundedRewardCannotBeNotified() public {
        source.accrue(100);
        vm.expectRevert(SIMDTESTVault.UnfundedReward.selector);
        source.notifyWithoutFunding(100);
        vm.expectRevert(SIMDTESTVault.OnlyHook.selector);
        vault.notifyReward(0);
    }

    function test_UnsweptRewardsBelongToPriorStakers() public {
        vm.prank(actors[0]);
        vault.stake(1000);
        vm.roll(block.number + 1);
        source.accrue(2000);
        vm.prank(actors[1]);
        vault.stake(1000);
        assertEq(vault.earned(actors[0]), 2000);
        assertEq(vault.earned(actors[1]), 0);
        vm.roll(block.number + 1);
        source.accrue(1000);
        vm.prank(actors[0]);
        vault.unstake(1000);
        assertEq(vault.earned(actors[0]), 2500);
        assertEq(vault.earned(actors[1]), 500);
        source.accrue(1000);
        source.sweep();
        vm.prank(actors[0]);
        vault.claim();
        vm.prank(actors[1]);
        vault.claim();
        assertEq(reward.balanceOf(actors[0]), 2500);
        assertEq(reward.balanceOf(actors[1]), 1500);
        assertEq(vault.pending(), 0);
    }

    function test_ZeroStakerQueueGoesToFirstStake() public {
        source.accrue(99);
        source.sweep();
        assertEq(vault.pending(), 99);
        vm.prank(actors[0]);
        vault.stake(1);
        assertEq(vault.earned(actors[0]), 0);
        vm.roll(block.number + 1);
        assertEq(vault.earned(actors[0]), 99);
        vm.prank(actors[0]);
        vault.unstake(1);
        source.accrue(11);
        vm.prank(actors[1]);
        vault.stake(100);
        vm.roll(block.number + 1);
        assertEq(vault.earned(actors[1]), 11);
        vm.prank(actors[0]);
        vault.claim();
        vm.prank(actors[1]);
        vault.claim();
        assertEq(vault.pending(), 0);
    }

    function test_FractionalRewardsSurviveRepeatedClaims() public {
        vm.prank(actors[0]);
        vault.stake(1);
        vm.prank(actors[1]);
        vault.stake(2);
        vm.roll(block.number + 1);
        for (uint256 i; i < 3; i++) {
            source.accrue(1);
            vm.prank(actors[0]);
            vault.claim();
            vm.prank(actors[1]);
            vault.claim();
        }
        assertEq(reward.balanceOf(actors[0]), 1);
        assertEq(reward.balanceOf(actors[1]), 2);
        assertEq(vault.pending(), 0);
    }

    function test_StakeEarnsOnlyFromTheNextBlock() public {
        vm.prank(actors[0]);
        vault.stake(100);
        vm.roll(block.number + 1);
        vm.prank(actors[1]);
        vault.stake(300); // Same block as the next accrual: not eligible for it.
        source.accrue(1000);
        assertEq(vault.earned(actors[0]), 1000);
        assertEq(vault.earned(actors[1]), 0);
        vm.prank(actors[1]);
        vault.claim();
        assertEq(reward.balanceOf(actors[1]), 0);
        vm.roll(block.number + 1);
        source.accrue(400); // Shared 1:3.
        assertEq(vault.earned(actors[0]), 1100);
        assertEq(vault.earned(actors[1]), 300);
        vm.prank(actors[1]);
        vault.unstake(300);
        assertEq(vault.earned(actors[1]), 300);
        vm.prank(actors[1]);
        vault.claim();
        assertEq(reward.balanceOf(actors[1]), 300);
    }

    function test_LazyFlushDoesNotRobPassiveStakers() public {
        vm.prank(actors[0]);
        vault.stake(100);
        vm.roll(block.number + 1);
        vm.prank(actors[1]);
        vault.stake(100);
        source.accrue(1000); // Stake block: all to actor 0.
        vm.roll(block.number + 5);
        source.accrue(500); // Shared.
        vm.roll(block.number + 5);
        source.accrue(500); // Shared.
        vm.roll(block.number + 5);
        assertEq(vault.earned(actors[0]), 1500);
        assertEq(vault.earned(actors[1]), 500);
        uint256 preview = vault.earned(actors[1]);
        vm.prank(actors[1]);
        vault.claim();
        assertEq(reward.balanceOf(actors[1]), preview);
        assertEq(vault.activeStake(), 200);
        assertEq(vault.activationRewardPerToken(block.number - 15), 1000 * vault.SCALE() / 100);
    }

    function test_PrincipalCanOnlyBeWithdrawnByItsStaker() public {
        vm.prank(actors[0]);
        vault.stake(123);
        vm.prank(actors[1]);
        vm.expectRevert(SIMDTESTVault.InsufficientStake.selector);
        vault.unstake(123);
        vm.prank(actors[0]);
        vault.unstake(123);
        assertEq(stake.balanceOf(actors[0]), 1e25);
        assertEq(vault.totalStaked(), 0);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_ConservationAndPrincipal(uint256 seed) public {
        for (uint256 step; step < 150; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            address actor = actors[seed % 4];
            uint256 action = (seed >> 8) % 7;
            uint256 amount = (seed >> 32) % 1e24 + 1;
            if (action == 6) {
                vm.roll(block.number + 1 + (seed >> 200) % 3);
            } else if (action == 0) {
                source.accrue(amount);
            } else if (action == 1) {
                source.sweep();
            } else if (action == 2) {
                uint256 available = stake.balanceOf(actor);
                if (available != 0) {
                    amount = bound(amount, 1, available);
                    vm.prank(actor);
                    vault.stake(amount);
                }
            } else if (action == 3) {
                amount = vault.balanceOf(actor);
                if (amount > 0) {
                    vm.prank(actor);
                    vault.unstake(amount);
                }
            } else if (action == 4) {
                vm.prank(actor);
                vault.claim();
            } else if (action == 5) {
                amount = vault.balanceOf(actor) / 2;
                if (amount > 0) {
                    vm.prank(actor);
                    vault.unstake(amount);
                }
            }
            uint256 accounted = vault.totalClaimed();
            uint256 principal;
            for (uint256 i; i < 4; i++) {
                accounted += vault.earned(actors[i]);
                principal += vault.balanceOf(actors[i]);
                assertEq(stake.balanceOf(actors[i]) + vault.balanceOf(actors[i]), 1e25);
            }
            assertLe(accounted, source.totalStakingFees());
            assertEq(vault.pending(), source.totalStakingFees() - vault.totalClaimed());
            assertEq(principal, vault.totalStaked());
            assertEq(principal, stake.balanceOf(address(vault)));
        }
        for (uint256 i; i < 4; i++) {
            uint256 principal = vault.balanceOf(actors[i]);
            if (principal != 0) {
                vm.prank(actors[i]);
                vault.unstake(principal);
            }
            vm.prank(actors[i]);
            vault.claim();
            assertEq(stake.balanceOf(actors[i]), 1e25);
        }
        assertEq(vault.totalStaked(), 0);
        assertEq(reward.balanceOf(address(vault)) + vault.totalClaimed(), source.totalStakingFees());
    }
}
