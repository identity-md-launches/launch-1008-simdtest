// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice Regressions from the swap-accounting specialist review.
contract SwapRoundingTest is LaunchFixture {
    function setUp() public {
        _setup(false);
    }

    function testExactInputPartialFillRounding() public {
        vm.roll(hook.openingBlock() + 9);
        bool zeroForOne = hook.pairIsCurrency0();
        // 94 input plus the LP fee requires 96 IMD. A 99-wei request would ordinarily
        // leave 97 after hook fees, so the price limit makes this a partial fill.
        uint160 limit = SqrtPriceMath.getNextSqrtPriceFromInput(PRICE, 1_000_000 ether, 94, zeroForOne);
        BalanceDelta delta = router.swap(key, SwapParams(zeroForOne, -99, limit));
        uint256 spent = uint256(-_pairDelta(delta));
        assertEq(spent, 98);
        assertEq(hook.antiSnipeFees(), spent * 300 / 10_000, "anti fee inconsistent with actual gross");
        assertEq(hook.stakingFees(), spent / 100, "staking fee inconsistent with actual gross");
        _assertSettled();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzSmallExactInputPartialFill(uint16 amountSeed, uint8 blockSeed, uint16 limitSeed) public {
        uint256 amount = bound(uint256(amountSeed), 1, 10_000);
        uint256 age = bound(uint256(blockSeed), 0, 10);
        vm.roll(hook.openingBlock() + age);
        bool zeroForOne = hook.pairIsCurrency0();
        uint256 limitedInput = bound(uint256(limitSeed), 1, amount);
        uint160 limit = SqrtPriceMath.getNextSqrtPriceFromInput(PRICE, 1_000_000 ether, limitedInput, zeroForOne);
        BalanceDelta delta = router.swap(key, SwapParams(zeroForOne, -int256(amount), limit));
        uint256 spent = uint256(-_pairDelta(delta));
        assertLe(spent, amount);
        assertEq(hook.antiSnipeFees(), spent * hook.antiSnipeBps() / 10_000);
        assertEq(hook.stakingFees(), spent / 100);
        _assertSettled();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzSmallExactOutputPartialFill(uint16 amountSeed, uint8 blockSeed, uint16 limitSeed) public {
        uint256 amount = bound(uint256(amountSeed), 1, 10_000);
        uint256 age = bound(uint256(blockSeed), 0, 10);
        vm.roll(hook.openingBlock() + age);
        bool zeroForOne = !hook.pairIsCurrency0();
        uint256 limitedOutput = bound(uint256(limitSeed), 1, amount);
        uint160 limit = SqrtPriceMath.getNextSqrtPriceFromOutput(PRICE, 1_000_000 ether, limitedOutput, zeroForOne);
        BalanceDelta delta = router.swap(key, SwapParams(zeroForOne, int256(amount), limit));
        uint256 received = uint256(_pairDelta(delta));
        uint256 gross = received + hook.antiSnipeFees() + hook.stakingFees();
        assertLe(received, amount);
        assertEq(hook.antiSnipeFees(), gross * hook.antiSnipeBps() / 10_000);
        assertEq(hook.stakingFees(), gross / 100);
        _assertSettled();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzSmallUnspecifiedPairPartialFill(uint16 amountSeed, uint8 blockSeed, uint16 limitSeed, bool buy)
        public
    {
        uint256 amount = bound(uint256(amountSeed), 1, 10_000);
        vm.roll(hook.openingBlock() + bound(uint256(blockSeed), 0, 10));
        bool zeroForOne = buy == hook.pairIsCurrency0();
        uint256 limited = bound(uint256(limitSeed), 1, amount);
        uint160 limit = buy
            ? SqrtPriceMath.getNextSqrtPriceFromOutput(PRICE, 1_000_000 ether, limited, zeroForOne)
            : SqrtPriceMath.getNextSqrtPriceFromInput(PRICE, 1_000_000 ether, limited, zeroForOne);
        BalanceDelta delta = router.swap(key, SwapParams(zeroForOne, buy ? int256(amount) : -int256(amount), limit));
        uint256 gross =
            buy ? uint256(-_pairDelta(delta)) : uint256(_pairDelta(delta)) + hook.antiSnipeFees() + hook.stakingFees();
        assertEq(hook.antiSnipeFees(), gross * hook.antiSnipeBps() / 10_000);
        assertEq(hook.stakingFees(), gross / 100);
        _assertSettled();
    }
}
