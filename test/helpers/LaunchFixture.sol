// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SIMDTEST} from "../../src/SIMDTEST.sol";
import {SIMDTESTHook} from "../../src/SIMDTESTHook.sol";
import {SIMDTESTVault} from "../../src/SIMDTESTVault.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {MineHook} from "../../script/MineHook.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PoolRouter} from "./PoolRouter.sol";

abstract contract LaunchFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant MAINNET_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    uint160 constant PRICE = 79228162514264337593543950336;
    IPoolManager manager;
    SIMDTEST token;
    IERC20 imd;
    SIMDTESTHook hook;
    SIMDTESTVault vault;
    PoolRouter router;
    PoolKey key;
    address alice;
    address bob;
    bool forked;

    function _setup(bool useFork) internal {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        forked = useFork;
        if (useFork) {
            // Opt in using forge test --fork-url; the default offline suite makes no RPC or env calls.
            if (block.chainid != 1 || MAINNET_MANAGER.code.length == 0) {
                vm.skip(true);
                return;
            }
            assertGt(IMD.code.length, 0, "IMD missing at fork block");
            manager = IPoolManager(MAINNET_MANAGER);
        } else {
            manager = IPoolManager(address(new PoolManager(address(this))));
            vm.etch(IMD, address(new MockERC20("IMD", "IMD", 0)).code);
        }
        imd = IERC20(IMD);
        token = _deployToken();
        (bytes32 salt, address predicted) = new MineHook().find(address(this), manager, token, 0, 200_000);
        hook = new SIMDTESTHook{salt: salt}(manager, token);
        assertEq(address(hook), predicted);
        vault = hook.vault();
        bool pair0 = IMD < address(token);
        key = PoolKey(
            Currency.wrap(pair0 ? IMD : address(token)),
            Currency.wrap(pair0 ? address(token) : IMD),
            12500,
            60,
            IHooks(address(hook))
        );
        router = new PoolRouter(manager);
        if (useFork) deal(IMD, address(this), 1e27);
        else MockERC20(IMD).mint(address(this), 1e27);
        token.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        token.approve(address(vault), type(uint256).max);
        token.transfer(alice, 10_000 ether);
        token.transfer(bob, 10_000 ether);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
        manager.initialize(key, PRICE);
        _seedLiquidity();
    }

    function _seedLiquidity() internal virtual {
        router.liquidity(key, 1_000_000 ether);
    }

    function _deployToken() internal virtual returns (SIMDTEST) {
        return new SIMDTEST();
    }

    function _swap(bool buy, bool exactInput, uint256 amount) internal returns (BalanceDelta) {
        bool zeroForOne = buy == hook.pairIsCurrency0();
        return router.swap(
            key,
            SwapParams(
                zeroForOne,
                exactInput ? -int256(amount) : int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
    }

    function _pairDelta(BalanceDelta delta) internal view returns (int256) {
        return hook.pairIsCurrency0() ? int256(delta.amount0()) : int256(delta.amount1());
    }

    function _tokenDelta(BalanceDelta delta) internal view returns (int256) {
        return hook.pairIsCurrency0() ? int256(delta.amount1()) : int256(delta.amount0());
    }

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        vault.stake(amount);
    }

    function _assertSettled() internal view {
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(IMD)), 0);
        assertEq(manager.currencyDelta(address(router), Currency.wrap(IMD)), 0);
        assertEq(manager.currencyDelta(address(router), Currency.wrap(address(token))), 0);
        assertFalse(manager.isUnlocked());
        assertEq(manager.balanceOf(address(hook), Currency.wrap(IMD).toId()), hook.antiSnipeFees() + hook.stakingFees());
    }
}
