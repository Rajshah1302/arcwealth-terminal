// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDemo, IPriceSource, IExecutionAdapter} from "../interfaces/IArcWealth.sol";
import {DemoERC20} from "./DemoERC20.sol";

/// @notice DEMO-ONCHAIN mint/burn execution adapter, backed by a finite real-USDC reserve.
contract DemoSwapRouter is AccessControl, ReentrancyGuard, IExecutionAdapter, IDemo {
    using SafeERC20 for IERC20;
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    uint256 public constant FEE_BPS = 30;
    IERC20 public immutable usdc;
    IPriceSource public immutable oracle;
    mapping(address => bool) public registeredTokens;

    error ZeroAddress();
    error TokenNotSupported();
    error InvalidToken();
    error SlippageExceeded();
    error InsufficientLiquidity();
    error ZeroOutput();
    event TokenRegistered(address indexed token);
    event Swapped(address indexed caller, address indexed token, address indexed to, bool buy, uint256 amountIn, uint256 amountOut);
    event ReserveFunded(address indexed funder, uint256 amount);

    /// @notice Configures USDC and oracle; admin initially also receives MANAGER_ROLE.
    constructor(address usdc_, address oracle_, address admin) {
        if (usdc_ == address(0) || oracle_ == address(0) || admin == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
        oracle = IPriceSource(oracle_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MANAGER_ROLE, admin);
    }

    /// @notice Registers an eighteen-decimal demo token; its admin must grant this router MINTER_ROLE.
    function registerToken(address token) external onlyRole(MANAGER_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (token == address(usdc) || !IDemo(token).isDemo() || IERC20Metadata(token).decimals() != 18) revert InvalidToken();
        registeredTokens[token] = true;
        emit TokenRegistered(token);
    }

    /// @notice Quotes minted underlying after the thirty-bps USDC input fee.
    function quoteUsdcForToken(address token, uint256 usdcIn) public view override returns (uint256) {
        if (!registeredTokens[token]) revert TokenNotSupported();
        uint256 price = oracle.getPrice(token);
        uint256 net = usdcIn - Math.mulDiv(usdcIn, FEE_BPS, 10_000);
        return Math.mulDiv(net, 1e20, price);
    }

    /// @notice Quotes USDC proceeds after the thirty-bps output fee.
    function quoteTokenForUsdc(address token, uint256 tokenIn) public view override returns (uint256) {
        if (!registeredTokens[token]) revert TokenNotSupported();
        uint256 gross = Math.mulDiv(tokenIn, oracle.getPrice(token), 1e20);
        return gross - Math.mulDiv(gross, FEE_BPS, 10_000);
    }

    /// @notice Pulls caller USDC and mints quoted demo tokens to the nonzero recipient.
    function swapExactUsdcForToken(address token, uint256 usdcIn, uint256 minTokenOut, address to)
        external override nonReentrant returns (uint256 tokenOut)
    {
        if (to == address(0)) revert ZeroAddress();
        tokenOut = quoteUsdcForToken(token, usdcIn);
        if (tokenOut < minTokenOut) revert SlippageExceeded();
        if (tokenOut == 0) revert ZeroOutput();
        usdc.safeTransferFrom(msg.sender, address(this), usdcIn);
        DemoERC20(token).mint(to, tokenOut);
        emit Swapped(msg.sender, token, to, true, usdcIn, tokenOut);
    }

    /// @notice Burns caller tokens using allowance and sends reserve USDC to the nonzero recipient.
    function swapExactTokenForUsdc(address token, uint256 tokenIn, uint256 minUsdcOut, address to)
        external override nonReentrant returns (uint256 usdcOut)
    {
        if (to == address(0)) revert ZeroAddress();
        usdcOut = quoteTokenForUsdc(token, tokenIn);
        if (usdcOut < minUsdcOut) revert SlippageExceeded();
        if (usdcOut == 0) revert ZeroOutput();
        if (usdc.balanceOf(address(this)) < usdcOut) revert InsufficientLiquidity();
        DemoERC20(token).burnFrom(msg.sender, tokenIn);
        usdc.safeTransfer(to, usdcOut);
        emit Swapped(msg.sender, token, to, false, tokenIn, usdcOut);
    }

    /// @notice Pulls caller USDC into the reserve, without creating a withdrawal entitlement.
    function fundReserve(uint256 amount) external nonReentrant {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit ReserveFunded(msg.sender, amount);
    }

    /// @notice Identifies this contract as a demo stand-in.
    function isDemo() external pure override returns (bool) { return true; }
}
