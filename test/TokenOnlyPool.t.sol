// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {SIMDTEST} from "src/SIMDTEST.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Seeds a range with exactly one currency at tick zero. Uses real manager settlement.
contract TokenOnlySeeder is IUnlockCallback {
    IPoolManager immutable manager;
    IERC20 immutable token;

    constructor(IPoolManager manager_, IERC20 token_) {
        manager = manager_;
        token = token_;
    }

    function seed(PoolKey memory key, bool pair0) external {
        manager.unlock(abi.encode(key, pair0, msg.sender));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, bool pair0, address payer) = abi.decode(data, (PoolKey, bool, address));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            ModifyLiquidityParams(pair0 ? int24(-600) : int24(0), pair0 ? int24(0) : int24(600), 1_000_000 ether, 0),
            ""
        );
        int128 paired = pair0 ? delta.amount0() : delta.amount1();
        int128 principal = pair0 ? delta.amount1() : delta.amount0();
        require(paired == 0 && principal < 0, "seed must contain only launch tokens");
        manager.sync(Currency.wrap(address(token)));
        require(token.transferFrom(payer, address(manager), uint256(-int256(principal))));
        manager.settle();
        return "";
    }
}

abstract contract TokenOnlyPoolScenarios is LaunchFixture {
    function _pairFirst() internal pure virtual returns (bool);

    function setUp() public {
        _setup(false);
        assertEq(hook.pairIsCurrency0(), _pairFirst());
        assertEq(imd.balanceOf(address(manager)), 0, "fresh manager must have no paired reserves");
        assertGt(token.balanceOf(address(manager)), 0);
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

    function _seedLiquidity() internal override {
        TokenOnlySeeder seeder = new TokenOnlySeeder(manager, token);
        token.approve(address(seeder), type(uint256).max);
        seeder.seed(key, hook.pairIsCurrency0());
    }

    function _firstBuy(bool exactInput, uint96 amountSeed, uint8 elapsedSeed) internal {
        uint256 amount = bound(uint256(amountSeed), 100, 1000 ether);
        uint256 elapsed = bound(uint256(elapsedSeed), 0, 12);
        vm.roll(hook.openingBlock() + elapsed);
        _stake(alice, 100 ether);
        uint256 pairBefore = imd.balanceOf(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));
        BalanceDelta delta = _swap(true, exactInput, amount);
        uint256 spent = uint256(-_pairDelta(delta));
        uint256 received = uint256(_tokenDelta(delta));
        assertGt(received, 0);
        assertEq(pairBefore - imd.balanceOf(address(this)), spent);
        assertEq(token.balanceOf(address(this)) - tokenBefore, received);
        assertEq(exactInput ? spent : received, amount);
        uint256 rate = elapsed < 10 ? 3000 - elapsed * 300 : 0;
        uint256 anti = spent * rate / 10_000;
        uint256 staking = spent / 100;
        assertEq(hook.antiSnipeFees(), anti);
        assertEq(hook.stakingFees(), staking);
        assertEq(imd.balanceOf(address(manager)), spent);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(vault.earned(alice), staking);
        _assertSettled();

        uint256 hackBefore = imd.balanceOf(hook.HACKATHON_VAULT());
        vm.prank(bob);
        hook.sweep();
        assertEq(imd.balanceOf(hook.HACKATHON_VAULT()) - hackBefore, anti);
        assertEq(imd.balanceOf(address(vault)), staking);
        assertEq(imd.balanceOf(bob), 0);
        assertEq(imd.balanceOf(address(manager)), spent - anti - staking);
        assertEq(vault.totalNotified(), staking);
        _assertSettled();
    }
}

contract TokenOnlyIMD0Test is TokenOnlyPoolScenarios {
    function _pairFirst() internal pure override returns (bool) {
        return true;
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FirstBuyNeedsNoExistingIMD(bool exactInput, uint96 amountSeed, uint8 elapsedSeed) public {
        _firstBuy(exactInput, amountSeed, elapsedSeed);
    }
}

contract TokenOnlyIMD1Test is TokenOnlyPoolScenarios {
    function _pairFirst() internal pure override returns (bool) {
        return false;
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FirstBuyNeedsNoExistingIMD(bool exactInput, uint96 amountSeed, uint8 elapsedSeed) public {
        _firstBuy(exactInput, amountSeed, elapsedSeed);
    }
}
