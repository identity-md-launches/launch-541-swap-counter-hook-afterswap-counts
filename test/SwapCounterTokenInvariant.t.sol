// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SwapCounterToken} from "src/SwapCounterToken.sol";

/// @dev A closed set of holders makes supply conservation exact. No balance/storage cheatcodes.
contract CounterTokenHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    SwapCounterToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor() {
        token = new SwapCounterToken();
        actors = [address(this), address(0xA11CE), address(0xB0B), address(0xCAFE)];
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        for (uint256 i = 1; i < actors.length; ++i) {
            assertTrue(token.transfer(actors[i], SUPPLY / 4));
        }
        for (uint256 i; i < actors.length; ++i) {
            expectedBalance[actors[i]] = SUPPLY / 4;
        }
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint256 rawAmount) public {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint8 ownerSeed, uint8 spenderSeed, uint256 amount) public {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function spend(uint8 ownerSeed, uint8 spenderSeed, uint8 toSeed, uint256 rawAmount) public {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        address to = actors[toSeed % 4];
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 maximum = expectedBalance[owner] < allowed ? expectedBalance[owner] : allowed;
        uint256 amount = bound(rawAmount, 0, maximum);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowed != type(uint256).max) expectedAllowance[owner][spender] -= amount;
    }

    function transferEntireBalance(uint8 fromSeed, uint8 toSeed) public {
        address from = actors[fromSeed % 4];
        transfer(fromSeed, toSeed, expectedBalance[from]);
    }

    function revokeThenAttemptSpend(uint8 ownerSeed, uint8 spenderSeed, uint8 toSeed) public {
        approve(ownerSeed, spenderSeed, 0);
        address spender = actors[spenderSeed % 4];
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1)
        );
        vm.prank(spender);
        token.transferFrom(actors[ownerSeed % 4], actors[toSeed % 4], 1);
    }

    function attemptOverdraw(uint8 ownerSeed, uint8 spenderSeed, uint8 toSeed) public {
        address owner = actors[ownerSeed % 4];
        uint256 balance = expectedBalance[owner];
        uint256 amount = balance + 1;
        // Finite allowance is deliberately sufficient. Its attempted decrement must roll back.
        approve(ownerSeed, spenderSeed, amount);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
        );
        vm.prank(actors[spenderSeed % 4]);
        token.transferFrom(owner, actors[toSeed % 4], amount);
    }

    function attemptZeroReceiver(uint8 ownerSeed, uint8 spenderSeed) public {
        approve(ownerSeed, spenderSeed, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(actors[spenderSeed % 4]);
        token.transferFrom(actors[ownerSeed % 4], address(0), 1);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SwapCounterTokenInvariantTest is Test {
    CounterTokenHandler internal handler;
    SwapCounterToken internal token;

    function setUp() public {
        handler = new CounterTokenHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = CounterTokenHandler.transfer.selector;
        selectors[1] = CounterTokenHandler.approve.selector;
        selectors[2] = CounterTokenHandler.spend.selector;
        selectors[3] = CounterTokenHandler.transferEntireBalance.selector;
        selectors[4] = CounterTokenHandler.revokeThenAttemptSpend.selector;
        selectors[5] = CounterTokenHandler.attemptOverdraw.selector;
        selectors[6] = CounterTokenHandler.attemptZeroReceiver.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_fixedSupplyAndExactBalances() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor), "holder balance diverged");
            sum += balance;
        }
        assertEq(sum, handler.SUPPLY());
        assertEq(token.totalSupply(), handler.SUPPLY());
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariant_allowancesMatchAuthorizationsAndSuccessfulSpends() public view {
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
        }
    }

    // These sequences pin boundaries and ensure the handler reaches nonzero delegated transfers.
    function test_fullSupplyInfiniteApprovalRevocationAndOneWei() public {
        handler.transferEntireBalance(1, 0);
        handler.transferEntireBalance(2, 0);
        handler.transferEntireBalance(3, 0);
        assertEq(token.balanceOf(handler.actors(0)), handler.SUPPLY());
        handler.approve(0, 1, type(uint256).max);
        handler.spend(0, 1, 2, handler.SUPPLY());
        assertEq(token.balanceOf(handler.actors(2)), handler.SUPPLY());
        assertEq(token.allowance(handler.actors(0), handler.actors(1)), type(uint256).max);
        handler.transfer(2, 0, 1);
        handler.spend(0, 1, 3, 1);
        handler.spend(0, 1, 3, 0);
        handler.revokeThenAttemptSpend(0, 1, 2);
        invariant_fixedSupplyAndExactBalances();
        invariant_allowancesMatchAuthorizationsAndSuccessfulSpends();
    }

    function test_finiteAllowanceSelfTransferAndFailedSpendsAreAtomic() public {
        handler.approve(0, 1, 2);
        handler.spend(0, 1, 0, 1);
        assertEq(token.balanceOf(handler.actors(0)), handler.SUPPLY() / 4);
        assertEq(token.allowance(handler.actors(0), handler.actors(1)), 1);
        handler.spend(0, 1, 2, 1);
        assertEq(token.allowance(handler.actors(0), handler.actors(1)), 0);
        handler.attemptOverdraw(0, 1, 2);
        handler.attemptZeroReceiver(2, 3);
        invariant_fixedSupplyAndExactBalances();
        invariant_allowancesMatchAuthorizationsAndSuccessfulSpends();
    }
}
