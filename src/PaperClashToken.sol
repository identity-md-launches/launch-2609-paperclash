// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title PAPERCLASH (PCLASH)
/// @notice A plain, fixed-supply ERC-20 token.
/// @dev The whole supply is minted once, in the constructor, to the deployer (`msg.sender`). There is
/// no owner, no minter, no pause, no blocklist, no fee and no hook on transfers: after deployment the
/// contract has no privileged function at all, and the supply can never grow. Holders may lower it by
/// sending tokens to an address nobody controls, which this contract neither helps nor prevents.
contract PaperClashToken is ERC20 {
    /// @notice The token name returned by `name()`.
    string public constant TOKEN_NAME = "PAPERCLASH";

    /// @notice The token symbol returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "PCLASH";

    /// @notice The number of decimals, the ERC-20 default (`decimals()` is inherited unchanged).
    uint8 public constant TOKEN_DECIMALS = 18;

    /// @notice The total supply in minor units: 1,000,000,000 tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(TOKEN_DECIMALS);

    /// @notice Mints `TOTAL_SUPPLY` to the deployer. No argument, no outside call, no further mint path.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
