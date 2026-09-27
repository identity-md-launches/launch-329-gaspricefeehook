// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Gas Tax
/// @notice Fixed supply of one billion GASP, with 18 decimals, minted to the constructor caller.
/// @dev The launch factory must deploy this contract itself to receive the supply. There is no
/// owner, external mint, burn, transfer tax, upgrade path, or privileged account.
contract GASP is ERC20 {
    constructor() ERC20("Gas Tax", "GASP") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
