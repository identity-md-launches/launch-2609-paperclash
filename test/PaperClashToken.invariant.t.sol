// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PaperClashToken} from "../src/PaperClashToken.sol";

/// @notice Drives the token with bounded random calls from a fixed set of actors and keeps its own
/// ledger of what every balance and allowance must be. Every call either succeeds and moves exactly
/// what it says, or reverts with the exact error and changes nothing; anything else is counted.
contract PaperClashHandler is Test {
    PaperClashToken public immutable token;
    address[] public actors;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public unexpected; // a call whose outcome disagreed with the ledger
    uint256 public successes;
    uint256 public expectedReverts;
    uint256 public mintProbes;

    constructor(PaperClashToken token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
        // The ledger starts from whatever the actors hold when the handler is created.
        for (uint256 i; i < actors_.length; ++i) {
            ghostBalance[actors_[i]] = token_.balanceOf(actors_[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Amounts cluster on the edges that matter: zero, one wei, the whole balance, one more
    /// than the balance, and the full supply, with uniform values between.
    function _amount(uint256 seed, uint256 held) internal pure returns (uint256) {
        uint256 pick = seed % 8;
        if (pick == 0) return 0;
        if (pick == 1) return 1;
        if (pick == 2) return held;
        if (pick == 3) return held + 1;
        if (pick == 4) return 1_000_000_000 ether;
        if (pick == 5) return type(uint256).max;
        return bound(seed >> 8, 0, held);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = ghostBalance[from];
        uint256 amount = _amount(amountSeed, held);

        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            if (!ok || amount > held) {
                unexpected++;
                return;
            }
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            successes++;
        } catch (bytes memory reason) {
            bytes memory want = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount);
            if (amount <= held || keccak256(reason) != keccak256(want)) unexpected++;
            else expectedReverts++;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = _amount(amountSeed, ghostBalance[owner]);

        vm.prank(owner);
        try token.approve(spender, amount) returns (bool ok) {
            if (!ok) {
                unexpected++;
                return;
            }
            ghostAllowance[owner][spender] = amount;
            successes++;
        } catch {
            unexpected++;
        }
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = ghostBalance[from];
        uint256 allowed = ghostAllowance[from][spender];
        uint256 amount = _amount(amountSeed, held < allowed ? held : allowed);

        vm.prank(spender);
        try token.transferFrom(from, to, amount) returns (bool ok) {
            if (!ok || amount > held || amount > allowed) {
                unexpected++;
                return;
            }
            if (allowed != type(uint256).max) ghostAllowance[from][spender] = allowed - amount;
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            successes++;
        } catch (bytes memory reason) {
            // The allowance is checked before the balance.
            bytes memory want = amount > allowed
                ? abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
                : abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount);
            if ((amount <= held && amount <= allowed) || keccak256(reason) != keccak256(want)) unexpected++;
            else expectedReverts++;
        }
    }

    /// @dev Sending to the zero address must always revert: the supply cannot be burnt that way.
    function transferToZero(uint256 fromSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        uint256 amount = _amount(amountSeed, ghostBalance[from]);
        vm.prank(from);
        try token.transfer(address(0), amount) {
            unexpected++;
        } catch (bytes memory reason) {
            if (keccak256(reason) != keccak256(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)))) {
                unexpected++;
            } else {
                expectedReverts++;
            }
        }
    }

    /// @dev Any actor, the deployer included, tries the selectors a minting, burning or seizing token
    /// would expose. None may exist.
    function privilegedProbe(uint256 callerSeed, uint256 targetSeed, uint256 selectorSeed, uint256 amount) external {
        address caller = _actor(callerSeed);
        address target = _actor(targetSeed);
        bytes4[8] memory selectors = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("burn(uint256)")),
            bytes4(keccak256("burnFrom(address,uint256)")),
            bytes4(keccak256("burn(address,uint256)")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("blacklist(address)")),
            bytes4(keccak256("freeze(address)")),
            bytes4(keccak256("seize(address,uint256)"))
        ];
        bytes memory data = abi.encodeWithSelector(selectors[selectorSeed % selectors.length], target, amount);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        if (ok) unexpected++;
        mintProbes++;
    }
}

contract PaperClashTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    PaperClashToken token;
    PaperClashHandler handler;
    address[] actors;

    function setUp() public {
        address deployer = makeAddr("deployer");
        actors.push(deployer);
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));

        vm.prank(deployer);
        token = new PaperClashToken();

        // Spread some of the supply so random calls from every actor have something to move.
        vm.startPrank(deployer);
        for (uint256 i = 1; i < actors.length; ++i) {
            token.transfer(actors[i], SUPPLY / 10);
        }
        vm.stopPrank();
        handler = new PaperClashHandler(token, actors);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_actorsHoldTheWholeSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply(), "tokens left the actor set or were created");
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesMatchTheLedger() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.ghostBalance(actors[i]), "balance drifted from the ledger");
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_allowancesMatchTheLedger() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.ghostAllowance(actors[i], actors[j]),
                    "allowance drifted from the ledger"
                );
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyCallBehavedAsSpecified() public view {
        assertEq(handler.unexpected(), 0, "a call succeeded or reverted against the spec");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_metadataIsFixed() public view {
        assertEq(token.name(), "PAPERCLASH");
        assertEq(token.symbol(), "PCLASH");
        assertEq(token.decimals(), 18);
    }

    /// @dev The ledger starts from the split setUp made, so the invariants compare against real state.
    function test_setUpDistribution() public view {
        assertEq(token.balanceOf(actors[0]), SUPPLY - (SUPPLY / 10) * 4);
        for (uint256 i = 1; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), SUPPLY / 10);
            assertEq(handler.ghostBalance(actors[i]), SUPPLY / 10);
        }
        assertEq(handler.ghostBalance(actors[0]), SUPPLY - (SUPPLY / 10) * 4);
    }

    /// @dev The handler is not vacuous: its calls reach both the success and the revert branches,
    /// and a wrong outcome would be counted.
    function test_handlerExercisesBothOutcomes() public {
        // alice -> bob, whole balance (pick 2): succeeds.
        handler.transfer(1, 2, 2);
        assertEq(token.balanceOf(actors[2]), 2 * (SUPPLY / 10));
        // alice now holds nothing; one wei (pick 1) reverts with the exact error.
        handler.transfer(1, 3, 1);
        // carol approves dave for max (pick 5), dave pulls one wei (pick 1): allowance stays max.
        handler.approve(3, 4, 5);
        handler.transferFrom(4, 3, 0, 1);
        assertEq(token.allowance(actors[3], actors[4]), type(uint256).max);
        // dave pulls from bob with no allowance: reverts.
        handler.transferFrom(4, 2, 0, 1);
        handler.transferToZero(0, 1);
        handler.privilegedProbe(0, 1, 0, SUPPLY);
        assertEq(handler.successes(), 3);
        assertEq(handler.expectedReverts(), 3);
        assertEq(handler.mintProbes(), 1);
        assertEq(handler.unexpected(), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
