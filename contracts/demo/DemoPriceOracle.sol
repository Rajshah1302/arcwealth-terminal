// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IDemo, IPriceSource} from "../interfaces/IArcWealth.sol";

/// @notice DEMO-ONCHAIN price store; prices and volatility are simulated offchain inputs.
contract DemoPriceOracle is AccessControl, IPriceSource, IDemo {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    uint256 public constant STALENESS = 1 hours;
    mapping(address => uint256) private _prices;
    mapping(address => uint256) private _updatedAt;
    mapping(address => uint256) public vol30dBps;

    error ZeroAddress();
    error InvalidPrice();
    error LengthMismatch();
    error StepTooLarge();
    error PriceNotSet();
    error StalePrice(address token, uint256 age);
    event PriceSet(address indexed token, uint256 price8, uint256 ts);
    event VolSet(address indexed token, uint256 volBps);

    /// @notice Grants administration and price-posting permissions to nonzero accounts.
    constructor(address admin, address keeper) {
        if (admin == address(0) || keeper == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, keeper);
    }

    /// @notice Posts a nonzero price with at most a ten-percent change from the last price.
    function setPrice(address token, uint256 price8) external onlyRole(KEEPER_ROLE) { _set(token, price8, false); }

    /// @notice Atomically posts a batch of bounded price updates.
    function setPrices(address[] calldata tokens, uint256[] calldata prices8) external onlyRole(KEEPER_ROLE) {
        if (tokens.length != prices8.length) revert LengthMismatch();
        for (uint256 i; i < tokens.length; ++i) _set(tokens[i], prices8[i], false);
    }

    /// @notice Reseeds a price without the keeper's step limit; reserved to administration.
    function resetPrice(address token, uint256 price8) external onlyRole(DEFAULT_ADMIN_ROLE) { _set(token, price8, true); }

    /// @notice Records informational simulated-offchain thirty-day realised volatility in bps.
    function setVol(address token, uint256 volBps) external onlyRole(KEEPER_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        vol30dBps[token] = volBps;
        emit VolSet(token, volBps);
    }

    /// @notice Returns a fresh eight-decimal USD price, reverting if unset or stale.
    function getPrice(address token) external view override returns (uint256) {
        uint256 price = _prices[token];
        if (price == 0) revert PriceNotSet();
        uint256 age = block.timestamp - _updatedAt[token];
        if (age > STALENESS) revert StalePrice(token, age);
        return price;
    }

    /// @notice Returns the last update timestamp, or zero when unset.
    function lastUpdated(address token) external view override returns (uint256) { return _updatedAt[token]; }

    /// @notice Returns raw stored data without enforcing freshness.
    function getPriceUnsafe(address token) external view returns (uint256 price8, uint256 updatedAt) {
        return (_prices[token], _updatedAt[token]);
    }

    /// @notice Identifies this contract as a demo stand-in.
    function isDemo() external pure override returns (bool) { return true; }

    function _set(address token, uint256 price, bool reset) private {
        if (token == address(0)) revert ZeroAddress();
        if (price == 0) revert InvalidPrice();
        uint256 old = _prices[token];
        uint256 difference = price > old ? price - old : old - price;
        if (!reset && old != 0 && difference > old / 10) revert StepTooLarge();
        _prices[token] = price;
        _updatedAt[token] = block.timestamp;
        emit PriceSet(token, price, block.timestamp);
    }
}
