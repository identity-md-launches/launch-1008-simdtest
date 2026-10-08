// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {Test} from "forge-std/Test.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {SIMDTESTVault} from "../src/SIMDTESTVault.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract LaunchHandler is Test {
    SIMDTESTHook public hook;
    SIMDTESTVault public vault;
    PoolRouter public router;
    IERC20 public token;
    IERC20 public imd;
    PoolKey private key;
    address[3] public actors;

    constructor(SIMDTESTHook hook_, PoolRouter router_, PoolKey memory key_) {
        hook = hook_;
        vault = hook_.vault();
        router = router_;
        key = key_;
        token = hook_.token();
        imd = IERC20(hook_.PAIRED_CURRENCY());
        token.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            actors[i] = makeAddr(string(abi.encodePacked("invariant staker", bytes1(uint8(i)))));
            vm.prank(actors[i]);
            token.approve(address(vault), type(uint256).max);
        }
    }

    function act(uint256 seed) external {
        uint256 mode = seed % 8;
        address actor = actors[(seed >> 8) % 3];
        uint256 amount = (seed >> 16) % (100 ether) + 100;
        if (mode < 4) {
            bool buy = mode < 2;
            bool exactInput = mode % 2 == 0;
            bool zeroForOne = buy == hook.pairIsCurrency0();
            router.swap(
                key,
                SwapParams(
                    zeroForOne,
                    exactInput ? -int256(amount) : int256(amount),
                    zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                )
            );
        } else if (mode == 4) {
            amount = bound(amount, 1, token.balanceOf(actor));
            vm.prank(actor);
            vault.stake(amount);
        } else if (mode == 5) {
            uint256 balance = vault.balanceOf(actor);
            if (balance != 0) {
                vm.prank(actor);
                vault.unstake(bound(amount, 1, balance));
            }
        } else if (mode == 6) {
            vm.prank(actor);
            vault.claim();
        } else {
            vm.roll(block.number + 1);
            hook.sweep();
        }
    }
}

contract LaunchInvariantTest is LaunchFixture {
    LaunchHandler handler;

    function setUp() public {
        _setup(false);
        handler = new LaunchHandler(hook, router, key);
        token.transfer(address(handler), 1_000_000 ether);
        imd.transfer(address(handler), 1_000_000 ether);
        for (uint256 i; i < 3; ++i) {
            token.transfer(handler.actors(i), 10_000 ether);
        }
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = LaunchHandler.act.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_SettlementPrincipalAndRewardConservation() public view {
        _assertSettled();
        uint256 obligations = vault.totalClaimed();
        uint256 principal;
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            obligations += vault.earned(actor);
            principal += vault.balanceOf(actor);
            assertEq(token.balanceOf(actor) + vault.balanceOf(actor), 10_000 ether);
        }
        assertEq(principal, vault.totalStaked());
        assertEq(principal, token.balanceOf(address(vault)));
        assertLe(obligations, hook.totalStakingFees());
        assertEq(imd.balanceOf(address(vault)) + vault.totalClaimed() + hook.stakingFees(), hook.totalStakingFees());
        assertEq(token.totalSupply(), 1e27);
    }
}
