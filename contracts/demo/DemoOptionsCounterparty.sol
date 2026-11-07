// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDemo, IExecutionAdapter, IOptionsCounterparty} from "../interfaces/IArcWealth.sol";

/// @notice DEMO-ONCHAIN option counterparty paying real reserve USDC to authorised modules.
/// @dev Modules enforce covered-call economics; this reserve trusts MODULE_ROLE for notional/strike inputs.
contract DemoOptionsCounterparty is AccessControl, ReentrancyGuard, IOptionsCounterparty {
    using SafeERC20 for IERC20;
    bytes32 public constant MODULE_ROLE = keccak256("MODULE_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    IERC20 public immutable usdc;
    IExecutionAdapter public router;
    uint256 public maxPremiumBps = 1500;

    error ZeroAddress();
    error InvalidBps();
    error PremiumTooLarge();
    error InsufficientLiquidity();
    error InvalidRecipient();
    error InvalidUnderlying();
    error RouterNotSet();
    event RouterSet(address indexed router);
    event PremiumCapSet(uint256 bps);
    event PremiumPaid(address indexed module, uint256 premium, uint256 notional);
    event AssignmentSettled(address indexed module, address indexed underlying, uint256 qty, uint256 strikeValue);
    event Recycled(address indexed token, uint256 amount, uint256 usdcOut);
    event ReserveFunded(address indexed funder, uint256 amount);

    /// @notice Configures USDC/admin; the router must be assigned separately through setRouter.
    constructor(address usdc_, address admin) {
        if (usdc_ == address(0) || admin == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, admin);
    }

    /// @notice Selects the demo execution adapter used exclusively to recycle held demo tokens.
    function setRouter(address router_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (router_ == address(0)) revert ZeroAddress();
        if (!IDemo(router_).isDemo()) revert InvalidUnderlying();
        router = IExecutionAdapter(router_);
        emit RouterSet(router_);
    }

    /// @notice Sets the premium/notional cap, at most one hundred percent.
    function setMaxPremiumBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 10_000) revert InvalidBps();
        maxPremiumBps = bps;
        emit PremiumCapSet(bps);
    }

    /// @notice Lets an authorised module pull a bounded premium only to itself.
    function payPremium(address to, uint256 premium, uint256 notional) external override onlyRole(MODULE_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (to != msg.sender) revert InvalidRecipient();
        if (premium > Math.mulDiv(notional, maxPremiumBps, 10_000)) revert PremiumTooLarge();
        if (premium > availableLiquidity()) revert InsufficientLiquidity();
        if (premium != 0) usdc.safeTransfer(to, premium);
        emit PremiumPaid(msg.sender, premium, notional);
    }

    /// @notice Pulls assigned demo underlying from the calling module and pays that same module strike USDC.
    function settleAssignment(address underlying, uint256 qty, uint256 strikeValue, address from)
        external override onlyRole(MODULE_ROLE) nonReentrant
    {
        if (from == address(0)) revert ZeroAddress();
        if (from != msg.sender) revert InvalidRecipient();
        if (underlying == address(0) || underlying == address(usdc)) revert InvalidUnderlying();
        if (!IDemo(underlying).isDemo()) revert InvalidUnderlying();
        if (strikeValue > availableLiquidity()) revert InsufficientLiquidity();
        IERC20(underlying).safeTransferFrom(from, address(this), qty);
        if (strikeValue != 0) usdc.safeTransfer(from, strikeValue);
        emit AssignmentSettled(from, underlying, qty, strikeValue);
    }

    /// @notice Sells held demo tokens into the configured router and retains all resulting reserve USDC.
    function recycle(address token, uint256 amount) external onlyRole(KEEPER_ROLE) nonReentrant returns (uint256 usdcOut) {
        if (address(router) == address(0)) revert RouterNotSet();
        if (token == address(0) || token == address(usdc)) revert InvalidUnderlying();
        if (!IDemo(token).isDemo()) revert InvalidUnderlying();
        uint256 minOut = router.quoteTokenForUsdc(token, amount);
        IERC20(token).forceApprove(address(router), amount);
        usdcOut = router.swapExactTokenForUsdc(token, amount, minOut, address(this));
        IERC20(token).forceApprove(address(router), 0);
        emit Recycled(token, amount, usdcOut);
    }

    /// @notice Pulls caller USDC into the reserve without granting a withdrawal claim.
    function fundReserve(uint256 amount) external nonReentrant {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit ReserveFunded(msg.sender, amount);
    }

    /// @notice Returns the reserve's real six-decimal ERC-20 USDC liquidity.
    function availableLiquidity() public view override returns (uint256) { return usdc.balanceOf(address(this)); }

    /// @notice Identifies this contract as a demo stand-in.
    function isDemo() external pure override returns (bool) { return true; }
}
