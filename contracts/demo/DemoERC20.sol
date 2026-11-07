// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IDemo} from "../interfaces/IArcWealth.sol";

/// @notice DEMO-ONCHAIN faucet token; not a claim on a real-world underlying.
contract DemoERC20 is ERC20, ERC20Burnable, AccessControl, IDemo {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    uint256 public constant FAUCET_COOLDOWN = 1 hours;
    uint256 public faucetAmount;
    uint8 private immutable _tokenDecimals;
    mapping(address => uint256) public nextFaucetAt;

    error ZeroAddress();
    error FaucetCooldown();
    error FaucetDisabled();

    event FaucetAmountChanged(uint256 amount);

    /// @notice Creates an unseeded demo token; admin grants the router MINTER_ROLE separately.
    constructor(string memory name, string memory symbol, uint8 decimals_, address admin, uint256 faucetAmount_)
        ERC20(name, symbol)
    {
        if (admin == address(0)) revert ZeroAddress();
        _tokenDecimals = decimals_;
        faucetAmount = faucetAmount_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Returns the configured token decimals.
    function decimals() public view override returns (uint8) { return _tokenDecimals; }

    /// @notice Set the faucet amount; zero disables faucet minting.
    function setFaucetAmount(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        faucetAmount = amount;
        emit FaucetAmountChanged(amount);
    }

    /// @notice Mints the configured amount to the caller, at most once per hour.
    function faucet() external {
        if (faucetAmount == 0) revert FaucetDisabled();
        if (block.timestamp < nextFaucetAt[msg.sender]) revert FaucetCooldown();
        nextFaucetAt[msg.sender] = block.timestamp + FAUCET_COOLDOWN;
        _mint(msg.sender, faucetAmount);
    }

    /// @notice Mints demo tokens to a nonzero recipient; restricted to authorised minters.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        _mint(to, amount);
    }

    /// @notice Identifies this contract as a demo stand-in.
    function isDemo() external pure override returns (bool) { return true; }
}
