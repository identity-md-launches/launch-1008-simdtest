// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";

/// @notice The hook's per-block fee boundary record is what lets the vault settle a stake's own block
/// to the stake that existed before it without anyone checkpointing. These tests drive random swap
/// and block sequences through the real local PoolManager and check the record against an independent
/// end-of-block ledger, then check that an untouched vault settles exactly along those boundaries.
contract FeeBoundariesTest is LaunchFixture {
    uint256 constant STEPS = 16;

    function setUp() public {
        _setup(false);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_HookRecordsExactEndOfBlockFeeTotals(uint256 seed) public {
        uint256 start = hook.openingBlock();
        assertEq(hook.lastAccrualBlock(), start);
        uint256[64] memory endTotal;
        bool[64] memory accruedIn;
        uint256 offset;
        uint256 lastAccrualOffset;
        bool anyAccrual;
        for (uint256 step; step < STEPS; ++step) {
            uint256 word = uint256(keccak256(abi.encode(seed, step)));
            if (word % 3 == 2) {
                offset += 1 + (word >> 8) % 3;
                vm.roll(start + offset);
                continue;
            }
            uint256 before = hook.totalStakingFees();
            _swap(word % 3 == 0, (word >> 16) % 2 == 0, bound(word >> 32, 1 ether, 50 ether));
            if (hook.totalStakingFees() != before) {
                accruedIn[offset] = true;
                lastAccrualOffset = offset;
                anyAccrual = true;
            }
            endTotal[offset] = hook.totalStakingFees();
        }
        _assertSettled();
        assertEq(hook.lastAccrualBlock(), start + (anyAccrual ? lastAccrualOffset : 0));
        for (uint256 o; o <= offset; ++o) {
            uint256 recorded = hook.stakingFeesAtEndOf(start + o);
            if (o == lastAccrualOffset && anyAccrual) {
                // The current last accrual block has no boundary yet; the vault reads the live total.
                assertEq(recorded, 0, "open block must not be closed early");
            } else if (accruedIn[o]) {
                assertEq(recorded, endTotal[o], "closed block total");
            } else if (o == 0) {
                // Deployment block: the clock starts there, so its boundary is written as zero.
                assertEq(recorded, 0);
            } else {
                assertEq(recorded, 0, "a block without fees leaves no record");
            }
        }
    }

    /// Alice is eligible throughout; Bob stakes at a random step. Fees of Bob's stake block belong to
    /// Alice alone, fees of later blocks split 1:3, and nobody touches the vault until the end.
    /// Buys of multiples of 400 IMD make every split exact, so equality is asserted, not closeness.
    /// forge-config: default.fuzz.runs = 300
    function testFuzz_UntouchedVaultSettlesEachBlockToTheStakeEligibleInIt(uint256 seed, uint8 stakeStepSeed) public {
        _stake(alice, 100 ether);
        vm.roll(block.number + 1);
        uint256 bobStep = bound(uint256(stakeStepSeed), 0, STEPS - 1);
        uint256 bobBlock;
        bool bobStaked;
        uint256 expectedAlice;
        uint256 expectedBob;
        for (uint256 step; step < STEPS; ++step) {
            uint256 word = uint256(keccak256(abi.encode(seed, step)));
            if (step == bobStep) {
                _stake(bob, 300 ether);
                bobStaked = true;
                bobBlock = block.number;
            }
            if (word % 3 == 2) {
                vm.roll(block.number + 1 + (word >> 8) % 3);
                continue;
            }
            uint256 before = hook.totalStakingFees();
            _swap(true, true, (1 + (word >> 16) % 5) * 400 ether);
            uint256 fee = hook.totalStakingFees() - before;
            assertEq(fee % 4, 0);
            if (bobStaked && block.number > bobBlock) {
                expectedAlice += fee / 4;
                expectedBob += fee * 3 / 4;
            } else {
                expectedAlice += fee;
            }
        }
        assertTrue(bobStaked);
        assertEq(vault.earned(alice), expectedAlice, "alice before maturity check");
        assertEq(vault.earned(bob), expectedBob, "bob before maturity check");
        vm.roll(block.number + 1);
        assertEq(vault.earned(alice), expectedAlice, "alice");
        assertEq(vault.earned(bob), expectedBob, "bob");
        vm.prank(bob);
        assertEq(vault.claim(), expectedBob);
        vm.prank(alice);
        assertEq(vault.claim(), expectedAlice);
        assertEq(vault.activeStake(), 400 ether);
        assertEq(vault.pendingStake(), 0);
        assertEq(vault.pending(), 0);
        _assertSettled();
    }
}
