// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SwapCounterToken} from "../src/SwapCounterToken.sol";

contract SwapCounterTokenTest is Test {
    SwapCounterToken internal token;
    uint256 internal constant SUPPLY = 1e27;

    function setUp() public {
        token = new SwapCounterToken();
    }

    function test_entireFixedSupplyGoesToDeployer() public view {
        assertEq(token.name(), "Swap Counter");
        assertEq(token.symbol(), "SWPC");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testFuzz_transferConservesSupply(address recipient, uint256 rawAmount) public {
        vm.assume(recipient != address(0) && recipient != address(this));
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approvalAndTransferFrom() public {
        address spender = address(0xBEEF);
        assertTrue(token.approve(spender, 3 ether));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), address(0xCAFE), 2 ether));
        assertEq(token.allowance(address(this), spender), 1 ether);
        assertEq(token.balanceOf(address(0xCAFE)), 2 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 2 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_insufficientBalanceReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(1), 0, 1)
        );
        vm.prank(address(1));
        token.transfer(address(2), 1);
    }

    function test_insufficientAllowanceReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(1), 0, 1)
        );
        vm.prank(address(1));
        token.transferFrom(address(this), address(2), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_transferToZeroReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_selfAndZeroTransfers() public {
        assertTrue(token.transfer(address(this), SUPPLY));
        assertTrue(token.transfer(address(1), 0));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_deployerAndStrangerCannotMintPauseOrUpgrade() public {
        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", address(1), 1);
        calls[1] = abi.encodeWithSignature("transferOwnership(address)", address(1));
        calls[2] = abi.encodeWithSignature("upgradeTo(address)", address(1));
        calls[3] = abi.encodeWithSignature("pause()");
        calls[4] = abi.encodeWithSignature("initialize(address)", address(1));
        calls[5] = abi.encodeWithSignature("burn(uint256)", 1);
        for (uint256 i; i < calls.length; ++i) {
            (bool deployerOk,) = address(token).call(calls[i]);
            assertFalse(deployerOk);
            vm.prank(address(1));
            (bool strangerOk,) = address(token).call(calls[i]);
            assertFalse(strangerOk);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(1)), 0);
    }
}
