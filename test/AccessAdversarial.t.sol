// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {SIMDTESTVault} from "../src/SIMDTESTVault.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract AccessAdversarialTest is Test {
    PoolManager manager;
    SIMDTEST token;
    SIMDTESTHook hook;
    PoolKey key;

    function setUp() public {
        manager = new PoolManager(address(this));
        token = new SIMDTEST();
        bytes memory creation = abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, token));
        assertLe(creation.length, 49152);
        bytes32 h = keccak256(creation);
        bytes32 salt;
        address predicted;
        for (uint256 i; i < 200_000; i++) {
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), h)))));
            if (HookFlags.matches(predicted, HookFlags.REQUIRED)) {
                salt = bytes32(i);
                break;
            }
        }
        address pair = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
        (address c0, address c1) = address(token) < pair ? (address(token), pair) : (pair, address(token));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12500, 60, IHooks(predicted));
        // Permissioned initialize callback blocks pre-initialization at counterfactual address.
        vm.expectRevert();
        manager.initialize(key, uint160(1 << 96));
        address deployed;
        assembly ("memory-safe") { deployed := create2(0, add(creation, 32), mload(creation), salt) }
        require(deployed == predicted, "bad mining");
        hook = SIMDTESTHook(deployed);
    }

    function test_authAllEnabledAndUnlockAndQuote() public {
        SwapParams memory p = SwapParams(true, -1000, uint160(1 << 95));
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, uint160(1 << 96));
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, p, "");
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, p, BalanceDelta.wrap(0), "");
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(SIMDTESTHook.OnlySelf.selector);
        hook.quotePair(key, p);
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.UnexpectedUnlock.selector);
        hook.unlockCallback("");
        SIMDTESTVault targetVault = hook.vault();
        vm.expectRevert(SIMDTESTVault.OnlyHook.selector);
        targetVault.notifyReward(1);
    }

    function test_poolBoundFullKey() public {
        PoolKey memory bad = key;
        bad.fee = 3000;
        vm.expectRevert();
        manager.initialize(bad, uint160(1 << 96));
        bad = key;
        bad.tickSpacing = 1;
        vm.expectRevert();
        manager.initialize(bad, uint160(1 << 96));
        bad = key;
        bad.currency0 = Currency.wrap(address(1));
        vm.expectRevert();
        manager.initialize(bad, uint160(1 << 96));
        manager.initialize(key, uint160(1 << 96));
    }

    function test_immutableVaultRelationships() public view {
        assertEq(address(hook.vault().hook()), address(hook));
        assertEq(address(hook.vault().stakingToken()), address(token));
        assertEq(address(hook.vault().rewardToken()), hook.PAIRED_CURRENCY());
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.REQUIRED);
    }

    function test_noBannedOpcodes() public view {
        _scan(address(hook).code);
        _scan(address(hook.vault()).code);
        _scan(address(token).code);
    }

    function _scan(bytes memory code) private pure {
        require(code.length <= 24576, "oversize");
        for (uint256 i; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x60 + 1;
                continue;
            }
            require(op != 0xff && op != 0xf4 && op != 0xf2, "banned opcode");
        }
    }
}
