// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 6-decimal USDC stand-in. Etched at the canonical Arc USDC address in tests.
/// @dev Any transfer whose recipient is BLOCKED reverts (models a USDC blocklist). Minting is open.
///      The blocked address is a constant so it survives `vm.etch` (which does not copy storage).
contract MockUSDC is ERC20 {
    address public constant BLOCKED = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    error Blocklisted(address account);

    constructor() ERC20("Mock USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to == BLOCKED) revert Blocklisted(to);
        super._update(from, to, value);
    }
}
