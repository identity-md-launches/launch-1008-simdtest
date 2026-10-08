// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Same storage layout as MockERC20 (plain OpenZeppelin ERC20), so it can be etched over it.
/// Every transfer delivers one unit less than requested and burns that unit.
contract ShavingERC20 is ERC20 {
    constructor() ERC20("Shaving", "SHV") {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value != 0) {
            super._update(from, address(0), 1);
            value -= 1;
        }
        super._update(from, to, value);
    }
}
