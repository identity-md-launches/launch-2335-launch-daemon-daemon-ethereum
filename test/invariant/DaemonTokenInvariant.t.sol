// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DaemonToken} from "../../src/DaemonToken.sol";

/// @notice Moves DAEMON between a fixed set of holders in random order: transfers, approvals,
/// transferFroms, and attempts that must fail (overspending a balance or an allowance).
contract DaemonTokenHandler is Test {
    DaemonToken public immutable token;
    address[5] public actors;

    // Expected allowance per (owner, spender), maintained from the calls that succeeded.
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    uint256 public ghostOverspendSuccesses;
    uint256 public ghostWrongAmountMoves;
    uint256 public ghostTransfers;

    constructor(DaemonToken token_, address[5] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % 5];
        address to = actors[toSeed % 5];
        uint256 bal = token.balanceOf(from);
        amount = bound(amount, 0, bal);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        token.transfer(to, amount);
        if (from != to) {
            if (token.balanceOf(from) != bal - amount || token.balanceOf(to) != toBefore + amount) {
                ghostWrongAmountMoves++;
            }
        } else if (token.balanceOf(from) != bal) {
            ghostWrongAmountMoves++;
        }
        ghostTransfers++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner_ = actors[ownerSeed % 5];
        address spender = actors[spenderSeed % 5];
        // Mostly bounded amounts, sometimes the infinite allowance.
        if (amount % 7 != 0) amount = bound(amount, 0, 1_000_000_000 ether);
        else amount = type(uint256).max;
        vm.prank(owner_);
        token.approve(spender, amount);
        expectedAllowance[owner_][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner_ = actors[ownerSeed % 5];
        address spender = actors[spenderSeed % 5];
        address to = actors[toSeed % 5];
        uint256 allowed = token.allowance(owner_, spender);
        uint256 bal = token.balanceOf(owner_);
        uint256 cap = allowed < bal ? allowed : bal;
        amount = bound(amount, 0, cap);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(spender);
        token.transferFrom(owner_, to, amount);
        if (allowed != type(uint256).max) expectedAllowance[owner_][spender] = allowed - amount;
        if (owner_ != to) {
            if (token.balanceOf(owner_) != bal - amount || token.balanceOf(to) != toBefore + amount) {
                ghostWrongAmountMoves++;
            }
        }
        ghostTransfers++;
    }

    /// @dev Tries to send more than the balance; must revert.
    function overspendBalance(uint256 fromSeed, uint256 toSeed, uint256 extra) external {
        address from = actors[fromSeed % 5];
        address to = actors[toSeed % 5];
        uint256 bal = token.balanceOf(from);
        extra = bound(extra, 1, type(uint256).max - bal);
        vm.prank(from);
        try token.transfer(to, bal + extra) {
            ghostOverspendSuccesses++;
        } catch {}
    }

    /// @dev Tries to pull more than the allowance; must revert.
    function overspendAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 extra) external {
        address owner_ = actors[ownerSeed % 5];
        address spender = actors[spenderSeed % 5];
        uint256 allowed = token.allowance(owner_, spender);
        if (allowed == type(uint256).max) return;
        extra = bound(extra, 1, type(uint256).max - allowed);
        vm.prank(spender);
        try token.transferFrom(owner_, spender, allowed + extra) {
            ghostOverspendSuccesses++;
        } catch {}
    }
}

contract DaemonTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    DaemonToken token;
    DaemonTokenHandler handler;
    address[5] actors = [address(0xA11CE), address(0xB0B), address(0xC0C0), address(0xD00D), address(0xE0E0)];

    function setUp() public {
        // The handler deploys nothing; this test is the "factory" that receives the supply, then
        // splits it unevenly among the holders.
        token = new DaemonToken();
        token.transfer(actors[0], SUPPLY / 2);
        token.transfer(actors[1], SUPPLY / 4);
        token.transfer(actors[2], SUPPLY / 8);
        token.transfer(actors[3], SUPPLY / 16);
        token.transfer(actors[4], token.balanceOf(address(this)));
        handler = new DaemonTokenHandler(token, actors);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_supplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_holdersOwnTheWholeSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < 5; i++) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY, "tokens appeared or vanished");
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_transfersMoveExactlyAndOverspendsFail() public view {
        assertEq(handler.ghostWrongAmountMoves(), 0, "a transfer moved a different amount than asked");
        assertEq(handler.ghostOverspendSuccesses(), 0, "a transfer beyond balance or allowance succeeded");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_allowancesFollowTheModel() public view {
        for (uint256 i = 0; i < 5; i++) {
            for (uint256 j = 0; j < 5; j++) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.expectedAllowance(actors[i], actors[j]),
                    "allowance drifted from approve/transferFrom"
                );
            }
        }
    }
}
