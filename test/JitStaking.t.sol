// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SIMDTESTVault} from "../src/SIMDTESTVault.sol";

/// @dev Borrows pool-held SIMDTEST inside its own unlock, stakes it around its swap and repays it.
contract FlashStaker is IUnlockCallback {
    IPoolManager immutable manager;
    SIMDTESTVault immutable vault;

    constructor(IPoolManager manager_, SIMDTESTVault vault_) {
        manager = manager_;
        vault = vault_;
    }

    function run(PoolKey memory key, SwapParams memory params, uint256 borrow) external {
        manager.unlock(abi.encode(key, params, borrow));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, SwapParams memory params, uint256 borrow) =
            abi.decode(data, (PoolKey, SwapParams, uint256));
        Currency staking = Currency.wrap(address(vault.stakingToken()));
        manager.take(staking, address(this), borrow);
        IERC20(Currency.unwrap(staking)).approve(address(vault), borrow);
        vault.stake(borrow);
        BalanceDelta delta = manager.swap(key, params, "");
        vault.unstake(borrow);
        _pay(staking, borrow);
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function claim() external returns (uint256) {
        return vault.claim();
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) _pay(currency, uint256(-int256(amount)));
        else if (amount > 0) manager.take(currency, address(this), uint128(amount));
    }

    function _pay(Currency currency, uint256 amount) private {
        manager.sync(currency);
        IERC20(Currency.unwrap(currency)).transfer(address(manager), amount);
        manager.settle();
    }
}

contract JitStakingTest is LaunchFixture {
    function setUp() public {
        _setup(false);
        vm.roll(hook.openingBlock() + 20); // Anti-snipe window over: only the 1% staking fee applies.
    }

    /// A stake that lives only inside one PoolManager unlock, funded with pool tokens, earns nothing.
    function test_InUnlockFlashStakeWithBorrowedPoolTokensEarnsNothing() public {
        _stake(alice, 10_000 ether);
        vm.roll(block.number + 1);
        FlashStaker whale = new FlashStaker(manager, vault);
        imd.transfer(address(whale), 200_000 ether);
        bool zeroForOne = hook.pairIsCurrency0();
        uint256 before = hook.totalStakingFees();
        whale.run(
            key,
            SwapParams(
                zeroForOne,
                -int256(100_000 ether),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            500_000 ether
        );
        uint256 fee = hook.totalStakingFees() - before;
        assertEq(fee, 1000 ether);
        assertEq(vault.totalStaked(), 10_000 ether);
        assertEq(vault.earned(alice), fee);
        assertEq(whale.claim(), 0);
        assertEq(vault.earned(alice), fee);
        _assertSettled();
    }

    /// Staking in the block of someone else's swap, then leaving, captures none of that swap's fee.
    function test_SameBlockSandwichStakeEarnsNothing() public {
        _stake(alice, 1_000 ether);
        vm.roll(block.number + 1);
        _stake(bob, 9_000 ether); // Front-runs a buy visible in the mempool.
        _swap(true, true, 1000 ether); // 10 IMD staking fee.
        vm.prank(bob);
        assertEq(vault.claim(), 0);
        vm.prank(bob);
        vault.unstake(9_000 ether);
        assertEq(token.balanceOf(bob), 10_000 ether);
        assertEq(vault.earned(alice), 10 ether);
        vm.prank(alice);
        assertEq(vault.claim(), 10 ether);
        _assertSettled();
    }

    /// Fees accrued in the stake's block settle to the earlier stake; later blocks are shared,
    /// even when nobody checkpoints the vault between the stake and the check.
    function test_BlockBoundaryIsExactWithoutIntermediateCheckpoints() public {
        _stake(alice, 100 ether);
        vm.roll(block.number + 1);
        _swap(true, true, 1000 ether); // 10 to alice.
        _stake(bob, 300 ether);
        _swap(true, true, 2000 ether); // 20 to alice: bob's stake block.
        vm.roll(block.number + 1);
        _swap(true, true, 4000 ether); // 40 shared 1:3.
        vm.roll(block.number + 1);
        _swap(true, true, 4000 ether); // 40 shared 1:3.
        vm.roll(block.number + 1);
        assertEq(vault.earned(alice), 50 ether);
        assertEq(vault.earned(bob), 60 ether);
        vm.prank(bob);
        assertEq(vault.claim(), 60 ether);
        vm.prank(alice);
        assertEq(vault.claim(), 50 ether);
        assertEq(vault.activeStake(), 400 ether);
        assertEq(vault.pendingStake(), 0);
        _assertSettled();
    }

    /// Stake block with no swap at all (fallback snapshot path), and stake block that is the last
    /// accrual block so far.
    function test_BlockBoundaryWhenStakeBlockHasNoLaterOrNoOwnAccrual() public {
        _stake(alice, 100 ether);
        vm.roll(block.number + 1);
        _stake(bob, 100 ether); // No swap in this block.
        vm.roll(block.number + 1);
        _swap(true, true, 1000 ether); // 10 shared 1:1.
        vm.roll(block.number + 1);
        assertEq(vault.earned(alice), 5 ether);
        assertEq(vault.earned(bob), 5 ether);
        address carol = makeAddr("carol");
        token.transfer(carol, 200 ether);
        vm.startPrank(carol);
        token.approve(address(vault), type(uint256).max);
        vault.stake(200 ether);
        vm.stopPrank();
        _swap(true, true, 1000 ether); // 10 shared between alice and bob only; last accrual block.
        vm.roll(block.number + 1);
        assertEq(vault.earned(alice), 10 ether);
        assertEq(vault.earned(bob), 10 ether);
        assertEq(vault.earned(carol), 0);
        _swap(true, true, 4000 ether); // 40 shared 1:1:2.
        assertEq(vault.earned(alice), 20 ether);
        assertEq(vault.earned(bob), 20 ether);
        assertEq(vault.earned(carol), 20 ether);
        _assertSettled();
    }

    /// Principal can leave at any time; a same-block stake is simply cancelled.
    function test_PendingStakeCanBeCancelledAndMaturesNextBlock() public {
        _stake(alice, 100 ether);
        assertEq(vault.pendingOf(alice), 100 ether);
        assertEq(vault.balanceOf(alice), 100 ether);
        assertEq(vault.totalStaked(), 100 ether);
        vm.prank(alice);
        vault.unstake(60 ether);
        assertEq(vault.pendingOf(alice), 40 ether);
        assertEq(vault.pendingStake(), 40 ether);
        assertEq(token.balanceOf(alice), 9_960 ether);
        vm.roll(block.number + 1);
        vm.prank(alice);
        vm.expectRevert(SIMDTESTVault.InsufficientStake.selector);
        vault.unstake(41 ether);
        vm.prank(alice);
        vault.unstake(40 ether);
        assertEq(token.balanceOf(alice), 10_000 ether);
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.activeStake(), 0);
    }
}
