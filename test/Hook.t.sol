// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

abstract contract HookScenarios is LaunchFixture {
    using StateLibrary for IPoolManager;

    function test_DecayAndBothFeesThroughAllFourSwapModes() public {
        uint256 opening = hook.openingBlock();
        for (uint256 elapsed; elapsed <= 11; ++elapsed) {
            vm.roll(opening + elapsed);
            assertEq(hook.antiSnipeBps(), elapsed < 10 ? 3000 - 300 * elapsed : 0);
            for (uint256 mode; mode < 4; ++mode) {
                _checkSwap(mode < 2, mode % 2 == 0, 100 ether);
            }
        }
    }

    function test_SweepAnyCallerBothDestinationsRepeatedAndUnlocked() public {
        _stake(alice, 100 ether);
        _swap(true, true, 1000 ether);
        uint256 anti = hook.antiSnipeFees();
        uint256 staking = hook.stakingFees();
        uint256 hackBefore = imd.balanceOf(hook.HACKATHON_VAULT());
        uint256 vaultBefore = imd.balanceOf(address(vault));
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(vault.earned(alice), staking);
        vm.prank(bob);
        hook.sweep();
        assertEq(imd.balanceOf(hook.HACKATHON_VAULT()) - hackBefore, anti);
        assertEq(imd.balanceOf(address(vault)) - vaultBefore, staking);
        assertEq(vault.totalNotified(), staking);
        hook.sweep();
        assertEq(vault.totalNotified(), staking);
        _swap(false, true, 10 ether);
        router.sweepUnlocked(key);
        _assertSettled();
        assertEq(hook.antiSnipeFees() + hook.stakingFees(), 0);
    }

    function test_TransfersAndLiquidityUntaxed() public {
        uint256 before = token.balanceOf(address(manager));
        token.transfer(address(manager), 1 ether);
        assertEq(token.balanceOf(address(manager)) - before, 1 ether);
        assertEq(hook.stakingFees(), 0);
        router.liquidity(key, 100 ether);
        router.liquidity(key, -100 ether);
        assertEq(hook.stakingFees(), 0);
        _checkSwap(true, false, 10 ether);
        _assertSettled();
    }

    function test_PartialFillChargesOnlyExecutedIMDInAllModes() public {
        for (uint256 mode; mode < 4; ++mode) {
            bool buy = mode < 2;
            bool exactInput = mode % 2 == 0;
            bool zeroForOne = buy == hook.pairIsCurrency0();
            (uint160 price,,,) = manager.getSlot0(key.toId());
            uint160 limit = zeroForOne ? price - price / 100_000 : price + price / 100_000;
            uint256 antiBefore = hook.antiSnipeFees();
            uint256 stakeBefore = hook.stakingFees();
            BalanceDelta delta =
                router.swap(key, SwapParams(zeroForOne, exactInput ? -int256(1e24) : int256(1e24), limit));
            _checkFee(delta, buy, antiBefore, stakeBefore);
            assertLt(uint256(buy ? -_pairDelta(delta) : _pairDelta(delta)), 1e22);
            _assertSettled();
        }
    }

    function test_HugeRequestsWithFinitePriceLimitDoNotNarrowOrOverflow() public {
        uint256[4] memory requests =
            [uint256(type(uint128).max), uint256(1) << 200, uint256(type(int256).max) / 2, uint256(1) << 255];
        for (uint256 i; i < requests.length; ++i) {
            for (uint256 mode; mode < 4; ++mode) {
                bool buy = mode < 2;
                bool exactInput = mode % 2 == 0;
                if (!exactInput && i == 3) continue;
                bool zeroForOne = buy == hook.pairIsCurrency0();
                (uint160 price,,,) = manager.getSlot0(key.toId());
                uint160 limit = zeroForOne ? price - price / 1000 : price + price / 1000;
                int256 specified;
                if (exactInput && i == 3) specified = type(int256).min;
                else specified = exactInput ? -int256(requests[i]) : int256(requests[i]);
                uint256 anti = hook.antiSnipeFees();
                uint256 staking = hook.stakingFees();
                BalanceDelta delta = router.swap(key, SwapParams(zeroForOne, specified, limit));
                _checkFee(delta, buy, anti, staking);
                _assertSettled();
            }
        }
    }

    function test_UnrepresentableGrossOutputRejected() public {
        bool zeroForOne = !hook.pairIsCurrency0();
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(SIMDTESTHook.UnrepresentableFee.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap(
            key,
            SwapParams(
                zeroForOne, type(int256).max, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        _assertSettled();
        assertEq(hook.stakingFees(), 0);
    }

    function test_EmptyPoolDoesNotChargeUnfilledRequests() public {
        router.liquidity(key, -int256(1_000_000 ether));
        bool zeroForOne = hook.pairIsCurrency0();
        BalanceDelta d = router.swap(
            key, SwapParams(zeroForOne, -100 ether, zeroForOne ? PRICE - PRICE / 100 : PRICE + PRICE / 100)
        );
        assertEq(_pairDelta(d), 0);
        assertEq(_tokenDelta(d), 0);
        assertEq(hook.stakingFees(), 0);
        _assertSettled();
    }

    function _checkSwap(bool buy, bool exactInput, uint256 amount) internal {
        uint256 anti = hook.antiSnipeFees();
        uint256 staking = hook.stakingFees();
        uint256 pairBefore = imd.balanceOf(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));
        BalanceDelta delta = _swap(buy, exactInput, amount);
        if (buy) {
            assertEq(pairBefore - imd.balanceOf(address(this)), uint256(-_pairDelta(delta)));
            assertEq(token.balanceOf(address(this)) - tokenBefore, uint256(_tokenDelta(delta)));
        } else {
            assertEq(imd.balanceOf(address(this)) - pairBefore, uint256(_pairDelta(delta)));
            assertEq(tokenBefore - token.balanceOf(address(this)), uint256(-_tokenDelta(delta)));
        }
        if (buy && exactInput) assertEq(uint256(-_pairDelta(delta)), amount);
        if (buy && !exactInput) assertEq(uint256(_tokenDelta(delta)), amount);
        if (!buy && exactInput) assertEq(uint256(-_tokenDelta(delta)), amount);
        if (!buy && !exactInput) assertEq(uint256(_pairDelta(delta)), amount);
        _checkFee(delta, buy, anti, staking);
        _assertSettled();
        (,, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        protocolFee;
        assertEq(lpFee, 12500);
    }

    function _checkFee(BalanceDelta delta, bool buy, uint256 antiBefore, uint256 stakeBefore) internal view {
        uint256 anti = hook.antiSnipeFees() - antiBefore;
        uint256 staking = hook.stakingFees() - stakeBefore;
        uint256 gross = buy ? uint256(-_pairDelta(delta)) : uint256(_pairDelta(delta)) + anti + staking;
        assertEq(anti, gross * hook.antiSnipeBps() / 10000, "anti fee on gross IMD");
        assertEq(staking, gross / 100, "staking fee on gross IMD");
    }
}

contract HookTest is HookScenarios {
    function setUp() public {
        _setup(false);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_Swaps(bool buy, bool exactInput, uint256 amount, uint8 elapsed) public {
        amount = bound(amount, 100, 1000 ether);
        vm.roll(hook.openingBlock() + uint256(elapsed));
        _checkSwap(buy, exactInput, amount);
    }
}

/// @notice Uses real mainnet IMD and PoolManager when invoked with --fork-url. Skips offline.
contract MainnetForkTest is HookScenarios {
    function setUp() public {
        _setup(true);
    }
}

/// @dev Force both possible currency orderings, independent of Foundry's fixture deployment address.
abstract contract OrderedCurrencyScenarios is HookScenarios {
    function _pairFirst() internal pure virtual returns (bool);

    function setUp() public {
        _setup(false);
        assertEq(hook.pairIsCurrency0(), _pairFirst());
    }

    function _deployToken() internal override returns (SIMDTEST) {
        bytes32 codeHash = keccak256(type(SIMDTEST).creationCode);
        for (uint256 i; i < 1000; ++i) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), codeHash))))
            );
            if ((IMD < predicted) == _pairFirst()) return new SIMDTEST{salt: bytes32(i)}();
        }
        revert("token salt not found");
    }
}

contract IMDCurrency0Test is OrderedCurrencyScenarios {
    function _pairFirst() internal pure override returns (bool) {
        return true;
    }
}

contract IMDCurrency1Test is OrderedCurrencyScenarios {
    function _pairFirst() internal pure override returns (bool) {
        return false;
    }
}
