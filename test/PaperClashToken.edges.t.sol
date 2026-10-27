// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PaperClashToken} from "../src/PaperClashToken.sol";

/// @notice Edge and failure paths the main suite does not pin: the zero address on `transferFrom`,
/// infinite allowances against short balances, self-spending, the maximum amount, and the events a
/// launch indexer would read.
contract PaperClashTokenEdgesTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    PaperClashToken token;

    function setUp() public {
        vm.prank(deployer);
        token = new PaperClashToken();
    }

    function test_transferFromToZeroAddressRevertsAndKeepsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 1 ether);
        assertEq(token.allowance(deployer, alice), 10 ether, "a reverted call spent allowance");
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromTheZeroAddressReverts() public {
        // Nobody can hold an allowance from address(0), so the allowance check fails first.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(0), alice, 1);
    }

    function test_infiniteAllowanceDoesNotBypassBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 3 ether);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 3 ether, 4 ether));
        token.transferFrom(alice, bob, 4 ether);
        assertEq(token.balanceOf(alice), 3 ether);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_holderNeedsAllowanceToTransferFromThemself() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(deployer, alice, 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_maxAmountTransferReverts() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        token.transfer(alice, type(uint256).max);
    }

    function test_wholeSupplyMovesInOneTransfer() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, 0, 1));
        token.transfer(alice, 1);
    }

    function test_zeroAmountTransferFromNeedsNoAllowance() public {
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 0));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_holderWithNoBalanceCanApprove() public {
        vm.prank(alice);
        assertTrue(token.approve(bob, 7));
        assertEq(token.allowance(alice, bob), 7);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 7));
        token.transferFrom(alice, bob, 7);
        assertEq(token.allowance(alice, bob), 7, "a reverted call spent allowance");
    }

    function test_approveZeroRevokes() public {
        vm.startPrank(deployer);
        token.approve(alice, 5 ether);
        token.approve(alice, 0);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, alice, 1);
    }

    function test_allowancesAreDirectionalAndPerSpender() public {
        vm.prank(deployer);
        token.approve(alice, 5 ether);
        assertEq(token.allowance(alice, deployer), 0);
        assertEq(token.allowance(deployer, bob), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1 ether));
        token.transferFrom(deployer, bob, 1 ether);
    }

    function test_transferFromEmitsOnlyTransferNoApproval() public {
        vm.prank(deployer);
        token.approve(alice, 5 ether);
        vm.recordLogs();
        vm.prank(alice);
        token.transferFrom(deployer, bob, 2 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(deployer))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(bob))));
        assertEq(abi.decode(logs[0].data, (uint256)), 2 ether);
    }

    function test_constructorEmitsExactlyOneEvent() public {
        vm.recordLogs();
        vm.prank(alice);
        PaperClashToken fresh = new PaperClashToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "the constructor emitted more than the mint");
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(alice))));
    }

    /// @dev Two deployments are independent: neither shares balances nor supply with the other.
    function test_separateDeploymentsAreIndependent() public {
        vm.prank(alice);
        PaperClashToken other = new PaperClashToken();
        vm.prank(alice);
        other.transfer(bob, 1 ether);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(other.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_strangerCannotMoveAnotherHoldersTokens(address stranger, uint256 amount) public {
        vm.assume(stranger != deployer);
        amount = bound(amount, 1, SUPPLY);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        token.transferFrom(deployer, stranger, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_roundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromWithInfiniteAllowanceMovesExactAmount(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }
}
