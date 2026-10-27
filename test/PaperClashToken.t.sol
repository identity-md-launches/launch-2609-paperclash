// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PaperClashToken} from "../src/PaperClashToken.sol";

/// @notice Stands in for the launch factory: deploys the token through CREATE2 and so becomes the
/// `msg.sender` of its constructor, exactly as the real factory will.
contract FactoryProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    function move(IERC20 token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract PaperClashTokenTest is Test {
    uint256 constant EXPECTED_SUPPLY = 1_000_000_000 ether; // 1e9 tokens * 1e18

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    PaperClashToken token;

    function setUp() public {
        vm.prank(deployer);
        token = new PaperClashToken();
    }

    // ---------------------------------------------------------------- metadata and supply

    function test_metadata() public view {
        assertEq(token.name(), "PAPERCLASH");
        assertEq(token.symbol(), "PCLASH");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "PAPERCLASH");
        assertEq(token.TOKEN_SYMBOL(), "PCLASH");
        assertEq(token.TOKEN_DECIMALS(), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
    }

    function test_wholeSupplyIsMintedToTheDeployer() public view {
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsOneTransferFromZeroToDeployer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), alice, EXPECTED_SUPPLY);
        vm.prank(alice);
        new PaperClashToken();
    }

    /// @dev The launch factory deploys the token through CREATE2 in its own call; the supply must
    /// land on the factory, not on the EOA that called it.
    function test_factoryDeploymentMintsToTheFactoryNotTheCaller() public {
        FactoryProbe factory = new FactoryProbe();
        vm.prank(alice);
        address deployed = factory.deploy(type(PaperClashToken).creationCode, bytes32(uint256(7)));
        PaperClashToken launched = PaperClashToken(deployed);
        assertEq(launched.totalSupply(), EXPECTED_SUPPLY);
        assertEq(launched.balanceOf(address(factory)), EXPECTED_SUPPLY);
        assertEq(launched.balanceOf(alice), 0);
        // The factory can pay the supply out in full, with nothing withheld.
        assertTrue(factory.move(launched, bob, EXPECTED_SUPPLY / 10));
        assertEq(launched.balanceOf(bob), EXPECTED_SUPPLY / 10);
        assertEq(launched.balanceOf(address(factory)), EXPECTED_SUPPLY - EXPECTED_SUPPLY / 10);
    }

    function test_creationCodeTakesNoConstructorArguments() public {
        // Deploying the bare creation code with nothing appended succeeds: no argument is expected.
        bytes memory code = type(PaperClashToken).creationCode;
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        assertTrue(deployed != address(0));
        assertEq(PaperClashToken(deployed).balanceOf(address(this)), EXPECTED_SUPPLY);
    }

    // ---------------------------------------------------------------- transfer

    function test_transferMovesExactAmount() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, 1_000 ether);
        assertTrue(token.transfer(alice, 1_000 ether));
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 1_000 ether);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_transferOfZeroSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        token.transfer(deployer, 5 ether);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10 ether, 11 ether)
        );
        token.transfer(bob, 11 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferRevertsWithNoBalanceAtAll() public {
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, carol, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    // ---------------------------------------------------------------- approve / transferFrom

    function test_approveSetsAllowanceAndEmits() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(deployer, alice, 50 ether);
        assertTrue(token.approve(alice, 50 ether));
        assertEq(token.allowance(deployer, alice), 50 ether);
    }

    function test_approveOverwritesPreviousAllowance() public {
        vm.startPrank(deployer);
        token.approve(alice, 50 ether);
        token.approve(alice, 20 ether);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 20 ether);
    }

    function test_approveToZeroAddressReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 50 ether);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, bob, 30 ether);
        assertTrue(token.transferFrom(deployer, bob, 30 ether));
        assertEq(token.balanceOf(bob), 30 ether);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 30 ether);
        assertEq(token.allowance(deployer, alice), 20 ether);
        assertEq(token.balanceOf(alice), 0, "the spender itself received nothing");
    }

    function test_transferFromRevertsBeyondAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 50 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 50 ether, 51 ether)
        );
        token.transferFrom(deployer, bob, 51 ether);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(deployer, alice), 50 ether);
    }

    function test_transferFromRevertsWithoutAnyAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, alice, 1);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_transferFromRevertsWhenOwnerBalanceIsShort() public {
        vm.prank(deployer);
        token.transfer(alice, 5 ether);
        vm.prank(alice);
        token.approve(bob, 100 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 5 ether, 6 ether));
        token.transferFrom(alice, carol, 6 ether);
        assertEq(token.balanceOf(alice), 5 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    // ---------------------------------------------------------------- no privileged surface

    function test_supplyIsFixedAndNothingCanMint() public {
        address attacker = makeAddr("attacker");
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(deployer);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);
        string[10] memory signatures = [
            "pause()",
            "blacklist(address)",
            "freeze(address)",
            "setBlacklist(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "burn(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        // The deployer holds no allowance from alice, so it cannot pull her balance either.
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 100 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 50 ether));
        assertEq(token.balanceOf(bob), 50 ether);
    }

    function test_unknownSelectorAndPlainEtherReverts() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "the token has no owner");
        (ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token accepts no ether");
        vm.deal(address(this), 1 ether);
        (ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token accepts no ether");
    }

    /// @dev Reachable runtime code contains no DELEGATECALL, CALLCODE or SELFDESTRUCT (the launch
    /// floor's own walk: PUSH data is skipped, and bytes after a terminating opcode up to the next
    /// JUMPDEST are not instructions).
    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        bool reachable = true;
        for (uint256 i; i < runtime.length; ++i) {
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

    // ---------------------------------------------------------------- fuzz: conservation

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        uint256 deployerBefore = token.balanceOf(deployer);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        if (to == deployer) {
            assertEq(token.balanceOf(deployer), deployerBefore);
        } else {
            assertEq(token.balanceOf(deployer), deployerBefore - amount);
            assertEq(token.balanceOf(to), toBefore + amount);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 amount) public {
        held = bound(held, 0, EXPECTED_SUPPLY - 1);
        amount = bound(amount, held + 1, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount));
        token.transfer(bob, amount);
    }

    function testFuzz_transferFromSpendsExactlyTheAmount(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, EXPECTED_SUPPLY);
        amount = bound(amount, 0, allowed);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, amount));
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.allowance(deployer, alice), allowed - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferFromBeyondAllowanceReverts(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, EXPECTED_SUPPLY - 1);
        amount = bound(amount, allowed + 1, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowed, amount)
        );
        token.transferFrom(deployer, bob, amount);
        assertEq(token.balanceOf(bob), 0);
    }
}
