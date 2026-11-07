// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDemo, IPriceSource} from "../interfaces/IArcWealth.sol";

/// @notice DEMO-ONCHAIN overcollateralised USDC lending with indexed, nontransferable positions.
/// @dev Registered collateral may include real cirBTC or demo dBTC. Oracle quotes use each token's address.
/// Base APR 2%, slope1 4% up to 80% utilisation, slope2 75% above the kink (81% maximum APR).
/// Ten percent of borrower interest is retained as a nonwithdrawable reserve spread.
/// Liquidations credit collateral for later pull claims; no keeper can redirect an investor's assets.
/// There is no bad-debt socialisation or external backstop: severe price gaps can strand supplier liquidity.
contract DemoLendingPool is AccessControl, ReentrancyGuard, IDemo {
    using SafeERC20 for IERC20;
    uint256 public constant WAD = 1e18;
    uint256 public constant LTV_BPS = 7000;
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 8000;
    uint256 public constant LIQUIDATION_BONUS_BPS = 500;
    uint256 public constant BASE_APR = 2e16;
    uint256 public constant SLOPE1 = 4e16;
    uint256 public constant SLOPE2 = 75e16;
    uint256 public constant KINK = 8e17;
    uint256 public constant MAX_COLLATERAL_TOKENS = 16;
    IERC20 public immutable usdc;
    IPriceSource public immutable oracle;
    uint256 public supplyIndex = WAD;
    uint256 public borrowIndex = WAD;
    uint256 public lastAccrual;
    uint256 public totalSupplyShares;
    uint256 public totalDebtShares;
    mapping(address => uint256) public supplyShares;
    mapping(address => uint256) public debtShares;
    address[] public collateralTokens;
    mapping(address => bool) public registeredCollateral;
    mapping(address => uint256) public collateralScale;
    mapping(address => mapping(address => uint256)) public collateralOf;
    mapping(address => mapping(address => uint256)) public claimableCollateral;

    error ZeroAddress();
    error InvalidAmount();
    error InvalidCollateral();
    error TooManyTokens();
    error InsufficientLiquidity();
    error InsufficientPosition();
    error UnsafePosition();
    error NotLiquidatable();
    error ExcessiveLiquidation();
    error SelfLiquidation();
    event CollateralRegistered(address indexed token, uint8 decimals);
    event Supplied(address indexed user, uint256 amount, uint256 shares);
    event Withdrawn(address indexed user, uint256 amount, uint256 shares);
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(address indexed user, address indexed liquidator, uint256 repaid, uint256 seizeValue);
    event CollateralClaimed(address indexed user, address indexed token, uint256 amount);
    event InterestAccrued(uint256 supplyIndex, uint256 borrowIndex, uint256 timestamp);

    /// @notice Configures six-decimal USDC, a price oracle and the collateral-registration administrator.
    constructor(address usdc_, address oracle_, address admin) {
        if (usdc_ == address(0) || oracle_ == address(0) || admin == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
        oracle = IPriceSource(oracle_);
        lastAccrual = block.timestamp;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Registers collateral once, preserving its token decimals; USDC itself cannot be collateral.
    /// @dev Registration is bounded to keep valuation and liquidation loops tractable. No delisting exists.
    function registerCollateral(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (token == address(usdc) || registeredCollateral[token]) revert InvalidCollateral();
        if (collateralTokens.length >= MAX_COLLATERAL_TOKENS) revert TooManyTokens();
        uint8 dec = IERC20Metadata(token).decimals();
        if (dec > 18) revert InvalidCollateral();
        registeredCollateral[token] = true;
        collateralScale[token] = 10 ** uint256(dec) * 100;
        collateralTokens.push(token);
        emit CollateralRegistered(token, dec);
    }

    /// @notice Checkpoints global borrower and supplier indices; callable by anyone.
    function accrueInterest() external nonReentrant { _accrue(); }

    /// @notice Pulls USDC from caller and credits nontransferable supply shares, rounding in favour of the pool.
    function supply(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        _accrue();
        uint256 shares = Math.mulDiv(amount, WAD, supplyIndex);
        if (shares == 0) revert InvalidAmount();
        supplyShares[msg.sender] += shares;
        totalSupplyShares += shares;
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Supplied(msg.sender, amount, shares);
    }

    /// @notice Pulls available supplied USDC to caller, burning shares rounded up; collateral debt is separate.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        _accrue();
        uint256 shares = Math.mulDiv(amount, WAD, supplyIndex, Math.Rounding.Ceil);
        if (shares > supplyShares[msg.sender]) revert InsufficientPosition();
        if (amount > usdc.balanceOf(address(this))) revert InsufficientLiquidity();
        supplyShares[msg.sender] -= shares;
        totalSupplyShares -= shares;
        usdc.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, shares);
    }

    /// @notice Pulls registered collateral into the caller's own position; no receipt tokens are transferable.
    function depositCollateral(address token, uint256 amount) external nonReentrant {
        if (!registeredCollateral[token]) revert InvalidCollateral();
        if (amount == 0) revert InvalidAmount();
        _accrue();
        collateralOf[msg.sender][token] += amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralDeposited(msg.sender, token, amount);
    }

    /// @notice Pulls caller collateral only if the resulting position remains within seventy-percent LTV.
    function withdrawCollateral(address token, uint256 amount) external nonReentrant {
        if (!registeredCollateral[token]) revert InvalidCollateral();
        if (amount == 0) revert InvalidAmount();
        _accrue();
        if (amount > collateralOf[msg.sender][token]) revert InsufficientPosition();
        collateralOf[msg.sender][token] -= amount;
        _checkLtv(msg.sender);
        IERC20(token).safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, token, amount);
    }

    /// @notice Borrows USDC to caller only, enforcing seventy-percent LTV with fresh collateral prices.
    function borrow(uint256 usdcAmount) external nonReentrant {
        if (usdcAmount == 0) revert InvalidAmount();
        _accrue();
        if (usdcAmount > usdc.balanceOf(address(this))) revert InsufficientLiquidity();
        uint256 shares = Math.mulDiv(usdcAmount, WAD, borrowIndex, Math.Rounding.Ceil);
        debtShares[msg.sender] += shares;
        totalDebtShares += shares;
        _checkLtv(msg.sender);
        usdc.safeTransfer(msg.sender, usdcAmount);
        emit Borrowed(msg.sender, usdcAmount);
    }

    /// @notice Pulls up to the requested USDC to repay caller debt; rounds partial repayment shares down.
    /// @return paid Actual USDC pulled, capped at the caller's outstanding debt.
    function repay(uint256 usdcAmount) external nonReentrant returns (uint256 paid) {
        if (usdcAmount == 0) revert InvalidAmount();
        _accrue();
        uint256 shares;
        (paid, shares) = _repayment(msg.sender, usdcAmount);
        debtShares[msg.sender] -= shares;
        totalDebtShares -= shares;
        usdc.safeTransferFrom(msg.sender, address(this), paid);
        emit Repaid(msg.sender, paid);
    }

    /// @notice Repays an unhealthy user's debt and credits seized collateral plus five-percent bonus to caller.
    /// @dev Seizure follows registration order, never pushes tokens, and requires full collateral coverage.
    /// Token precision can reduce the bonus by less than one smallest unit per collateral token.
    function liquidate(address user, uint256 repayAmount) external nonReentrant returns (uint256 paid) {
        if (user == address(0)) revert ZeroAddress();
        if (user == msg.sender) revert SelfLiquidation();
        if (repayAmount == 0) revert InvalidAmount();
        _accrue();
        uint256 debt = _debt(user, borrowIndex);
        uint256 value = collateralValue(user);
        if (debt == 0 || debt <= Math.mulDiv(value, LIQUIDATION_THRESHOLD_BPS, 10_000)) revert NotLiquidatable();
        uint256 shares;
        (paid, shares) = _repayment(user, repayAmount);
        uint256 seizeValue = Math.mulDiv(paid, 10_000 + LIQUIDATION_BONUS_BPS, 10_000);
        if (seizeValue > value) revert ExcessiveLiquidation();
        debtShares[user] -= shares;
        totalDebtShares -= shares;
        _seize(user, seizeValue);
        usdc.safeTransferFrom(msg.sender, address(this), paid);
        emit Liquidated(user, msg.sender, paid, seizeValue);
    }

    /// @dev Moves collateral from `user` to the caller's claimable balance worth `seizeValue` USDC.
    function _seize(address user, uint256 seizeValue) private {
        uint256 remaining = seizeValue;
        for (uint256 i; i < collateralTokens.length && remaining != 0; ++i) {
            address token = collateralTokens[i];
            uint256 held = collateralOf[user][token];
            if (held == 0) continue;
            uint256 price = oracle.getPrice(token);
            uint256 tokenValue = Math.mulDiv(held, price, collateralScale[token]);
            if (tokenValue == 0) continue;
            uint256 budget = Math.min(remaining, tokenValue);
            uint256 qty = budget == tokenValue ? held : Math.mulDiv(budget, collateralScale[token], price);
            collateralOf[user][token] = held - qty;
            claimableCollateral[msg.sender][token] += qty;
            remaining -= budget;
        }
    }

    /// @notice Pulls caller's liquidation collateral credits to caller only.
    function claimCollateral(address token, uint256 amount) external nonReentrant {
        if (!registeredCollateral[token]) revert InvalidCollateral();
        if (amount == 0) revert InvalidAmount();
        if (amount > claimableCollateral[msg.sender][token]) revert InsufficientPosition();
        claimableCollateral[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit CollateralClaimed(msg.sender, token, amount);
    }

    /// @notice Returns total collateral value in six-decimal USDC using fresh eight-decimal oracle prices.
    function collateralValue(address user) public view returns (uint256 value) {
        for (uint256 i; i < collateralTokens.length; ++i) {
            address token = collateralTokens[i];
            uint256 amount = collateralOf[user][token];
            if (amount != 0) value += Math.mulDiv(amount, oracle.getPrice(token), collateralScale[token]);
        }
    }

    /// @notice Returns liquidation-threshold collateral/debt in 1e18 scale, or uint256 max for no debt.
    function healthFactor(address user) external view returns (uint256) {
        (, uint256 bi) = _projectIndices();
        uint256 debt = _debt(user, bi);
        if (debt == 0) return type(uint256).max;
        return Math.mulDiv(Math.mulDiv(collateralValue(user), LIQUIDATION_THRESHOLD_BPS, 10_000), WAD, debt);
    }

    /// @notice Returns caller-independent utilisation in 1e18 scale including projected interest.
    function utilisation() public view returns (uint256) {
        (, uint256 bi) = _projectIndices();
        return _utilisation(Math.mulDiv(totalDebtShares, bi, WAD, Math.Rounding.Ceil));
    }

    /// @notice Returns the current annual borrow rate in 1e18 scale.
    function borrowApr() external view returns (uint256) { return _rate(utilisation()); }

    /// @notice Returns annual supplier APR in 1e18 scale after the ten-percent reserve spread.
    function supplyApr() external view returns (uint256) {
        uint256 u = utilisation();
        return Math.mulDiv(Math.mulDiv(_rate(u), u, WAD), 9000, 10_000);
    }

    /// @notice Returns a user's projected supplied USDC, rounded down.
    function suppliedBalance(address user) external view returns (uint256) {
        (uint256 si,) = _projectIndices();
        return Math.mulDiv(supplyShares[user], si, WAD);
    }

    /// @notice Returns a user's projected USDC debt, rounded up.
    function debtOf(address user) external view returns (uint256) {
        (, uint256 bi) = _projectIndices();
        return _debt(user, bi);
    }

    /// @notice Identifies this contract as a demo stand-in.
    function isDemo() external pure override returns (bool) { return true; }

    function _checkLtv(address user) private view {
        uint256 debt = _debt(user, borrowIndex);
        if (debt != 0 && debt > Math.mulDiv(collateralValue(user), LTV_BPS, 10_000)) revert UnsafePosition();
    }

    function _debt(address user, uint256 index) private view returns (uint256) {
        return Math.mulDiv(debtShares[user], index, WAD, Math.Rounding.Ceil);
    }

    function _repayment(address user, uint256 requested) private view returns (uint256 paid, uint256 shares) {
        uint256 debt = _debt(user, borrowIndex);
        if (debt == 0) revert InsufficientPosition();
        if (requested >= debt) return (debt, debtShares[user]);
        shares = Math.mulDiv(requested, WAD, borrowIndex);
        if (shares == 0) revert InvalidAmount();
        paid = Math.mulDiv(shares, borrowIndex, WAD, Math.Rounding.Ceil);
    }

    function _utilisation(uint256 debt) private view returns (uint256) {
        uint256 total = debt + usdc.balanceOf(address(this));
        return total == 0 ? 0 : Math.mulDiv(debt, WAD, total);
    }

    function _rate(uint256 u) private pure returns (uint256) {
        if (u <= KINK) return BASE_APR + Math.mulDiv(SLOPE1, u, KINK);
        return BASE_APR + SLOPE1 + Math.mulDiv(SLOPE2, u - KINK, WAD - KINK);
    }

    function _projectIndices() private view returns (uint256 si, uint256 bi) {
        si = supplyIndex;
        bi = borrowIndex;
        uint256 elapsed = block.timestamp - lastAccrual;
        if (elapsed == 0 || totalDebtShares == 0) return (si, bi);
        uint256 oldDebt = Math.mulDiv(totalDebtShares, bi, WAD);
        uint256 rate = _rate(_utilisation(oldDebt));
        bi += Math.mulDiv(bi, rate * elapsed, WAD * 365 days);
        uint256 newDebt = Math.mulDiv(totalDebtShares, bi, WAD);
        if (totalSupplyShares != 0) {
            uint256 supplierInterest = Math.mulDiv(newDebt - oldDebt, 9000, 10_000);
            si += Math.mulDiv(supplierInterest, WAD, totalSupplyShares);
        }
    }

    function _accrue() private {
        (supplyIndex, borrowIndex) = _projectIndices();
        lastAccrual = block.timestamp;
        emit InterestAccrued(supplyIndex, borrowIndex, block.timestamp);
    }
}
