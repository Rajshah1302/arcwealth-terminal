// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IRiskManager, IStrategyManager} from "../interfaces/IArcWealth.sol";

/// @dev The risk reference is obtained from the registered vault, preserving the specified constructor.
interface IArcWealthRiskReference {
    function risk() external view returns (IRiskManager);
}

/// @title ARCWEALTH strategy targets and regime registry
/// @notice Publishes configuration, without custody or authority over investor shares.
contract StrategyManager is AccessControl, IStrategyManager {
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    struct Strategy {
        bool registered;
        string name;
        bytes32 hash;
        uint16[] weights;
        address[] tokens;
        uint16[] assetBps;
        int16 cashDelta;
        int16 tbillDelta;
    }
    mapping(address => Strategy) private _strategies;
    mapping(address => mapping(address => bool)) private _options;
    mapping(address => bool) public noOptions;
    uint8 public override currentRegime = 3;
    uint16 public vol30dX100;
    bool public trendUp = true;
    uint16 public benchmarkRateBps;
    uint16 public idleRatioBps;

    error ZeroAddress();
    error UnknownStrategy();
    error AlreadyRegistered();
    error InvalidWeights();
    error WeightOutsideBand(uint256 index);
    error OptionsDisabled(address token);
    error InvalidOverride();
    event StrategyConfigChanged(address indexed vault, bytes32 oldHash, bytes32 newHash, uint16[] weights, address indexed actor, string reason);
    event StrategyRegistered(address indexed vault, string name, bytes32 configHash);
    event RegimeChanged(uint8 indexed oldRegime, uint8 indexed newRegime, uint16 vol30dX100, bool trendUp, uint16 benchmarkRateBps, uint16 idleRatioBps);
    event OptionsAvailabilityChanged(address indexed vault, address indexed token, bool available);
    event NoOptionsChanged(address indexed token, bool disabled);

    /// @notice Initializes the administrative authority; operating roles are granted explicitly.
    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Registers a strategy and validates its initial module allocation against its risk manager.
    function registerStrategy(address vault, string calldata name, uint16[] calldata weights, bytes32 hash)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (vault == address(0) || vault.code.length == 0) revert ZeroAddress();
        Strategy storage s = _strategies[vault];
        if (s.registered) revert AlreadyRegistered();
        _validateWeights(vault, weights);
        s.registered = true;
        s.name = name;
        s.weights = weights;
        s.hash = hash;
        emit StrategyRegistered(vault, name, hash);
        emit StrategyConfigChanged(vault, bytes32(0), hash, weights, msg.sender, "registration");
    }

    /// @notice Replaces module targets; index order must match the vault's module list.
    function setModuleWeights(address vault, uint16[] calldata weights, bytes32 newHash, string calldata reason)
        external onlyRole(MANAGER_ROLE)
    {
        Strategy storage s = _strategy(vault);
        _validateWeights(vault, weights);
        s.weights = weights;
        _change(s, vault, newHash, reason);
    }

    /// @notice Sets nonduplicated asset allocations totaling 10000 bps and bounded by risk ceilings.
    function setAssetWeights(address vault, address[] calldata tokens, uint16[] calldata bps, bytes32 newHash, string calldata reason)
        external onlyRole(MANAGER_ROLE)
    {
        Strategy storage s = _strategy(vault);
        if (tokens.length == 0 || tokens.length != bps.length) revert InvalidWeights();
        IRiskManager r = IArcWealthRiskReference(vault).risk();
        uint256 sum;
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == address(0)) revert ZeroAddress();
            if (bps[i] > r.assetMaxBps(vault, tokens[i])) revert WeightOutsideBand(i);
            for (uint256 j; j < i; ++j) if (tokens[j] == tokens[i]) revert InvalidWeights();
            sum += bps[i];
        }
        if (sum != 10_000) revert InvalidWeights();
        s.tokens = tokens;
        s.assetBps = bps;
        _change(s, vault, newHash, reason);
    }

    /// @notice Flags an asset such as dCOPR as ineligible for options across all strategies.
    function setNoOptions(address token, bool disabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        noOptions[token] = disabled;
        emit NoOptionsChanged(token, disabled);
    }

    /// @notice Changes an asset's options permission, subject to the administrator's global exclusion.
    function setOptionsAvailable(address vault, address token, bool available) external onlyRole(MANAGER_ROLE) {
        _strategy(vault);
        if (token == address(0)) revert ZeroAddress();
        if (available && noOptions[token]) revert OptionsDisabled(token);
        _options[vault][token] = available;
        emit OptionsAvailabilityChanged(vault, token, available);
    }

    /// @notice Posts informational regime inputs; volatility is expressed as whole annualised percent.
    function postRegimeInputs(uint16 vol, bool up, uint16 benchmark, uint16 idleBps) external onlyRole(KEEPER_ROLE) {
        if (idleBps > 10_000) revert InvalidWeights();
        uint8 old = currentRegime;
        currentRegime = vol > 80 || !up ? 0 : vol >= 60 ? 1 : vol > 30 ? 2 : 3;
        vol30dX100 = vol;
        trendUp = up;
        benchmarkRateBps = benchmark;
        idleRatioBps = idleBps;
        emit RegimeChanged(old, currentRegime, vol, up, benchmark, idleBps);
    }

    /// @notice Applies at most ten percentage points of cash/tbill deviation; puts absorbs the difference.
    /// @dev Overrides must remain valid for every regime, so a later keeper regime post cannot break allocation views.
    function tacticalOverride(address vault, int16 cashDeltaBps, int16 tbillDeltaBps, string calldata reason)
        external onlyRole(MANAGER_ROLE)
    {
        Strategy storage s = _strategy(vault);
        if (cashDeltaBps < -1000 || cashDeltaBps > 1000 || tbillDeltaBps < -1000 || tbillDeltaBps > 1000)
            revert InvalidOverride();
        for (uint8 i; i < 4; ++i) _allocation(i, cashDeltaBps, tbillDeltaBps);
        s.cashDelta = cashDeltaBps;
        s.tbillDelta = tbillDeltaBps;
        bytes32 hash = keccak256(abi.encode(s.hash, vault, cashDeltaBps, tbillDeltaBps, reason));
        _change(s, vault, hash, reason);
    }

    /// @inheritdoc IStrategyManager
    function targetWeights(address vault) external view override returns (uint16[] memory) { return _strategies[vault].weights; }

    /// @inheritdoc IStrategyManager
    function configHash(address vault) external view override returns (bytes32) { return _strategies[vault].hash; }

    /// @inheritdoc IStrategyManager
    function assetWeights(address vault) external view override returns (address[] memory tokens, uint16[] memory bps) {
        return (_strategies[vault].tokens, _strategies[vault].assetBps);
    }

    /// @inheritdoc IStrategyManager
    function optionsAvailable(address vault, address token) external view override returns (bool) {
        return _strategies[vault].registered && !noOptions[token] && _options[vault][token];
    }

    /// @inheritdoc IStrategyManager
    function tacticalAllocation(address vault) external view override returns (uint16 cashBps, uint16 tbillBps, uint16 putsBps) {
        Strategy storage s = _strategies[vault];
        return _allocation(currentRegime, s.cashDelta, s.tbillDelta);
    }

    function _strategy(address vault) private view returns (Strategy storage s) {
        s = _strategies[vault];
        if (!s.registered) revert UnknownStrategy();
    }

    function _validateWeights(address vault, uint16[] calldata weights) private view {
        if (weights.length == 0 || weights.length > 256) revert InvalidWeights();
        IRiskManager r = IArcWealthRiskReference(vault).risk();
        uint256 sum;
        for (uint256 i; i < weights.length; ++i) {
            (uint16 minimum, uint16 maximum) = r.sleeveBand(vault, uint8(i));
            if (weights[i] < minimum || weights[i] > maximum) revert WeightOutsideBand(i);
            sum += weights[i];
        }
        if (sum != 10_000) revert InvalidWeights();
    }

    function _change(Strategy storage s, address vault, bytes32 hash, string memory reason) private {
        bytes32 old = s.hash;
        s.hash = hash;
        emit StrategyConfigChanged(vault, old, hash, s.weights, msg.sender, reason);
    }

    function _allocation(uint8 regime, int16 cashDelta, int16 tbillDelta) private pure returns (uint16, uint16, uint16) {
        int256 cash = regime == 0 ? int256(5000) : regime == 1 ? int256(3000) : regime == 2 ? int256(2500) : int256(2000);
        int256 tbill = regime == 0 ? int256(4000) : regime == 1 ? int256(3000) : regime == 2 ? int256(5500) : int256(8000);
        cash += cashDelta;
        tbill += tbillDelta;
        int256 puts = 10_000 - cash - tbill;
        if (cash < 0 || tbill < 0 || puts < 0) revert InvalidOverride();
        return (uint16(uint256(cash)), uint16(uint256(tbill)), uint16(uint256(puts)));
    }
}
