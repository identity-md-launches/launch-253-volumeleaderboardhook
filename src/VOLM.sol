// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply Sepolia test token. The factory receives the entire supply on deployment.
contract VOLM is ERC20 {
    constructor() ERC20("Volume", "VOLM") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
