// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IInvestorVault} from "../interfaces/IArcWealth.sol";

/// @title Noncustodial investor disclosure and cost-basis registry
contract InvestorVault is AccessControl, IInvestorVault {
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    mapping(address => bool) public registered;
    mapping(address => bytes32) public disclosureHash;
    mapping(address => mapping(address => bytes32)) public accepted;
    mapping(address => mapping(address => uint256)) public acceptedAt;
    mapping(address => mapping(address => uint256)) public costBasis;
    mapping(address => mapping(address => uint256)) public sharesHeld;

    error ZeroAddress();
    error InvalidDisclosure();
    error UnregisteredStrategy();
    error InvalidShares();
    event StrategyRegistered(address indexed strategy, bytes32 disclosureHash);
    event DisclosureAccepted(address indexed user, address indexed strategy, bytes32 hash);
    event PositionRecorded(address indexed user, address indexed strategy, uint256 costBasis, uint256 shares);

    /// @notice Sets the initial administrator; the registry never takes custody.
    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    modifier onlyStrategy() {
        if (!registered[msg.sender]) revert UnregisteredStrategy();
        _;
    }

    /// @notice Registers a strategy or replaces its disclosure, invalidating previous acceptances.
    function registerStrategy(address vault, bytes32 hash) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (vault == address(0) || vault.code.length == 0) revert ZeroAddress();
        if (hash == bytes32(0)) revert InvalidDisclosure();
        registered[vault] = true;
        disclosureHash[vault] = hash;
        emit StrategyRegistered(vault, hash);
    }

    /// @notice Records the caller's acceptance of the currently registered disclosure.
    function acceptDisclosure(address strategy, bytes32 hash) external {
        if (!registered[strategy]) revert UnregisteredStrategy();
        if (hash == bytes32(0) || hash != disclosureHash[strategy]) revert InvalidDisclosure();
        accepted[msg.sender][strategy] = hash;
        acceptedAt[msg.sender][strategy] = block.timestamp;
        emit DisclosureAccepted(msg.sender, strategy, hash);
    }

    /// @inheritdoc IInvestorVault
    function hasAccepted(address user, address strategy) external view override returns (bool) {
        return registered[strategy] && accepted[user][strategy] == disclosureHash[strategy];
    }

    /// @inheritdoc IInvestorVault
    function recordDeposit(address user, uint256 assets, uint256 shares) external override onlyStrategy {
        if (user == address(0)) revert ZeroAddress();
        costBasis[user][msg.sender] += assets;
        sharesHeld[user][msg.sender] += shares;
        _emitPosition(user);
    }

    /// @inheritdoc IInvestorVault
    function recordWithdraw(address user, uint256, uint256 shares) external override onlyStrategy {
        _remove(user, shares);
        _emitPosition(user);
    }

    /// @notice Carries proportional basis on voluntary ERC-20 share transfers; escrow is not a disposal.
    /// @dev Called only by the registered strategy whose shares are being transferred.
    function recordTransfer(address from, address to, uint256 shares) external onlyStrategy {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        uint256 basis = _remove(from, shares);
        sharesHeld[to][msg.sender] += shares;
        costBasis[to][msg.sender] += basis;
        _emitPosition(from);
        _emitPosition(to);
    }

    /// @notice Returns the remaining acquisition cost, economic shares (including escrow), and acceptance time.
    function positionOf(address user, address strategy) external view returns (uint256 basis, uint256 shares, uint256 timestamp) {
        return (costBasis[user][strategy], sharesHeld[user][strategy], acceptedAt[user][strategy]);
    }

    function _remove(address user, uint256 shares) private returns (uint256 basis) {
        uint256 held = sharesHeld[user][msg.sender];
        if (shares > held) revert InvalidShares();
        basis = shares == 0 ? 0 : Math.mulDiv(costBasis[user][msg.sender], shares, held);
        sharesHeld[user][msg.sender] = held - shares;
        costBasis[user][msg.sender] -= basis;
    }

    function _emitPosition(address user) private {
        emit PositionRecorded(user, msg.sender, costBasis[user][msg.sender], sharesHeld[user][msg.sender]);
    }
}
