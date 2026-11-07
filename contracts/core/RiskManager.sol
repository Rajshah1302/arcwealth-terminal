// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IRiskManager} from "../interfaces/IArcWealth.sol";

/// @title ARCWEALTH risk configuration
/// @notice Administrative limits only; this contract never holds or moves investor assets.
contract RiskManager is AccessControl, IRiskManager {
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    struct Limits {
        uint256 minimum;
        uint256 tvlCap;
        uint256 userCap;
        uint16 idleBps;
        bool configured;
    }
    struct Band { uint16 minimum; uint16 maximum; bool configured; }
    struct AssetLimit { uint16 maximum; bool configured; }

    mapping(address => Limits) public limits;
    mapping(address => mapping(uint8 => Band)) private _bands;
    mapping(address => mapping(address => AssetLimit)) private _assetLimits;
    mapping(address => CallLimits) private _calls;

    error ZeroAddress();
    error InvalidLimits();
    error InvalidBand();
    error CoverageViolation(uint256 held, uint256 shortAfter);

    event LimitsChanged(address indexed strategy, uint256 minDeposit, uint256 tvlCap, uint256 userCap, uint16 minIdleBps);
    event SleeveBandChanged(address indexed strategy, uint8 indexed sleeve, uint16 minBps, uint16 maxBps);
    event AssetLimitChanged(address indexed strategy, address indexed token, uint16 bps);
    event CallLimitsChanged(address indexed module, CallLimits limits);

    /// @notice Sets the initial administrative authority; transfer it to the timelock after setup.
    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Configures deposit limits and the mandatory minimum ten-percent idle allocation.
    function setLimits(address strategy, uint256 minimum, uint256 tvlCap, uint256 userCap, uint16 idleBps)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (strategy == address(0)) revert ZeroAddress();
        if (idleBps < 1000 || idleBps > 10_000 || minimum == 0 || userCap > tvlCap) revert InvalidLimits();
        limits[strategy] = Limits(minimum, tvlCap, userCap, idleBps, true);
        emit LimitsChanged(strategy, minimum, tvlCap, userCap, idleBps);
    }

    /// @notice Sets the inclusive allocation band for a module index, including an explicit zero-only band.
    function setSleeveBand(address strategy, uint8 sleeve, uint16 minBps, uint16 maxBps)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (strategy == address(0)) revert ZeroAddress();
        if (minBps > maxBps || maxBps > 10_000) revert InvalidBand();
        _bands[strategy][sleeve] = Band(minBps, maxBps, true);
        emit SleeveBandChanged(strategy, sleeve, minBps, maxBps);
    }

    /// @notice Sets an inclusive per-asset concentration ceiling.
    function setAssetMaxBps(address strategy, address token, uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (strategy == address(0) || token == address(0)) revert ZeroAddress();
        if (bps > 10_000) revert InvalidBand();
        _assetLimits[strategy][token] = AssetLimit(bps, true);
        emit AssetLimitChanged(strategy, token, bps);
    }

    /// @notice Configures the expiry, strike, premium and short-count limits of a covered-call module.
    function setCallLimits(address module, CallLimits calldata config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (module == address(0)) revert ZeroAddress();
        if (config.minExpiry == 0 || config.minExpiry > config.maxExpiry || config.maxShortsPerAsset == 0
            || config.minStrikeBps == 0 || config.minStrikeBps > config.maxStrikeBps
            || config.maxPremiumBps > 10_000) revert InvalidLimits();
        _calls[module] = config;
        emit CallLimitsChanged(module, config);
    }

    /// @inheritdoc IRiskManager
    function minDeposit(address strategy) external view override returns (uint256) {
        return limits[strategy].configured ? limits[strategy].minimum : 10e6;
    }

    /// @inheritdoc IRiskManager
    function minIdleBps(address strategy) external view override returns (uint16) {
        return limits[strategy].configured ? limits[strategy].idleBps : 1000;
    }

    /// @inheritdoc IRiskManager
    function maxDeposit(address strategy, uint256 tvl, uint256 userAssets) external view override returns (uint256) {
        Limits memory l = limits[strategy];
        uint256 tvlCap = l.configured ? l.tvlCap : 1_000e6;
        uint256 userCap = l.configured ? l.userCap : 250e6;
        return Math.min(tvlCap > tvl ? tvlCap - tvl : 0, userCap > userAssets ? userCap - userAssets : 0);
    }

    /// @inheritdoc IRiskManager
    function sleeveBand(address strategy, uint8 sleeve) external view override returns (uint16 minBps, uint16 maxBps) {
        Band memory b = _bands[strategy][sleeve];
        return b.configured ? (b.minimum, b.maximum) : (uint16(0), uint16(10_000));
    }

    /// @inheritdoc IRiskManager
    function assetMaxBps(address strategy, address token) external view override returns (uint16) {
        AssetLimit memory l = _assetLimits[strategy][token];
        return l.configured ? l.maximum : 10_000;
    }

    /// @inheritdoc IRiskManager
    function callLimits(address module) external view override returns (CallLimits memory) { return _calls[module]; }

    /// @inheritdoc IRiskManager
    function checkCoverage(uint256 held, uint256 shortAfter) external pure override {
        if (shortAfter > held) revert CoverageViolation(held, shortAfter);
    }
}
