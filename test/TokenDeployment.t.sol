// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";

contract TokenDeploymentTest is Test {
    SIMDTEST token;
    address recipient;
    address spender;

    function setUp() public {
        token = new SIMDTEST();
        recipient = makeAddr("token recipient");
        spender = makeAddr("token spender");
    }

    function test_FullSupplyAndMetadata() public view {
        assertEq(token.name(), "SIMDTEST");
        assertEq(token.symbol(), "SIMDTEST");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_TransfersConserveSupplyAndNeverTax(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_AllowanceRequiredAndConsumed() public {
        vm.startPrank(spender);
        vm.expectRevert();
        token.transferFrom(address(this), recipient, 1 ether);
        vm.stopPrank();
        assertTrue(token.approve(spender, 3 ether));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), recipient, 2 ether));
        assertEq(token.allowance(address(this), spender), 1 ether);
        assertEq(token.balanceOf(recipient), 2 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 2 ether);
        vm.startPrank(spender);
        vm.expectRevert();
        token.transferFrom(address(this), recipient, 2 ether);
        vm.stopPrank();
    }

    function test_DeployerAndStrangerCannotMintOrAcquireAdminPowers() public {
        string[10] memory selectors = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            bytes memory data = abi.encodeWithSignature(selectors[i], recipient, 1e27);
            (bool deployerSucceeded,) = address(token).call(data);
            assertFalse(deployerSucceeded, selectors[i]);
            vm.prank(recipient);
            (bool recipientSucceeded,) = address(token).call(data);
            assertFalse(recipientSucceeded, selectors[i]);
            assertEq(token.totalSupply(), 1e27);
            assertEq(token.balanceOf(address(this)), 1e27);
            assertEq(token.balanceOf(recipient), 0);
        }
    }
}
