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
    uint256 public swept;
    VaultAuditToken public reward;
    SIMDTESTVault public vault;

    constructor(VaultAuditToken stake, VaultAuditToken reward_) {
        reward = reward_;
        vault = new SIMDTESTVault(stake, reward_, this);
    }

    function accrue(uint256 value) external {
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
        source.accrue(2000);
        vm.prank(actors[1]);
        vault.stake(1000);
        assertEq(vault.earned(actors[0]), 2000);
        assertEq(vault.earned(actors[1]), 0);
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
        assertEq(vault.earned(actors[0]), 99);
        vm.prank(actors[0]);
        vault.unstake(1);
        source.accrue(11);
        vm.prank(actors[1]);
        vault.stake(100);
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
            uint256 action = (seed >> 8) % 6;
            uint256 amount = (seed >> 32) % 1e24 + 1;
            if (action == 0) {
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
