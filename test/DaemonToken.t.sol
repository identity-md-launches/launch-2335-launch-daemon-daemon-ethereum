// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {DaemonToken} from "../src/DaemonToken.sol";

contract DaemonTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    DaemonToken token;

    function setUp() public {
        token = new DaemonToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "DAEMON");
        assertEq(token.symbol(), "DAEMON");
        assertEq(token.decimals(), 18);
    }

    function test_mintsTheWholeSupplyToTheDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_transferMovesExactlyWhatItWasAsked() public {
        uint256 amount = 123_456 ether;
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);

        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, amount / 3));
        assertEq(token.balanceOf(BOB), amount / 3);
        assertEq(token.balanceOf(ALICE), amount - amount / 3);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromRespectsAllowance() public {
        token.transfer(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 4 ether);

        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, BOB, 4 ether));
        assertEq(token.balanceOf(BOB), 4 ether);
        assertEq(token.allowance(ALICE, BOB), 0);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(ALICE, BOB, 1);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.transfer(BOB, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    /// @dev No mint, owner, pause, blocklist or upgrade entry point exists; none of these calls
    /// changes the supply or a holder's balance, from a stranger or from the deployer.
    function test_noAdminEntryPointChangesSupplyOrBalances() public {
        token.transfer(ALICE, 1 ether);
        address stranger = address(0xBEEF);
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)",
            "setFee(uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], stranger, uint256(1 ether));
            vm.prank(stranger);
            (bool okStranger,) = address(token).call(data);
            assertFalse(okStranger, signatures[i]);
            (bool okDeployer,) = address(token).call(data);
            assertFalse(okDeployer, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.balanceOf(stranger), 0);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 1 ether));
    }

    /// @dev No proxy and no self-destruct in reachable runtime code (PUSH immediates skipped, data after
    /// a terminating opcode ignored until the next JUMPDEST).
    function test_runtimeCodeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        bool reachable = true;
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
