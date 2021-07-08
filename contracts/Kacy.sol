// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Kacy is ERC20 {

    constructor() ERC20("Kassandra", "KACY") {
        _mint(msg.sender, 10_000_000 * 1e18);
    }

}