// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBondIssuer} from "../interfaces/IArcWealth.sol";

/// @notice DEMO-ONCHAIN simple-interest bonds. Early redemption at par is intentionally permitted.
/// @dev Units and coupons use USDC's six decimals. Reserve funding does not create investor units.
contract DemoBondIssuer is AccessControl, ReentrancyGuard, IBondIssuer {
    using SafeERC20 for IERC20;
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    IERC20 public immutable usdc;
    struct Series {
        string name;
        string rating;
        uint16 couponBps;
        uint64 issuedAt;
        uint64 maturity;
        bool active;
    }
    Series[] private _series;
    mapping(uint256 => mapping(address => uint256)) private _units;
    mapping(uint256 => mapping(address => uint256)) public lastClaim;
    mapping(uint256 => mapping(address => uint256)) public accrued;
    mapping(uint256 => mapping(address => uint256)) public unpaidCoupon;
    uint256 public totalOutstanding;
    uint256 public principalOutstanding;

    error ZeroAddress();
    error InvalidSeries();
    error InvalidMaturity();
    error SeriesMatured();
    error InvalidAmount();
    error InsufficientUnits();
    error InsufficientReserve();
    error InsufficientCouponReserve();
    event SeriesCreated(uint256 indexed id, string name, string rating, uint16 couponBps, uint64 maturity);
    event Subscribed(uint256 indexed id, address indexed holder, uint256 amount);
    event CouponPaid(uint256 indexed id, address indexed holder, uint256 amount);
    event Redeemed(uint256 indexed id, address indexed holder, uint256 units, uint256 paid);
    event ReserveFunded(address indexed funder, uint256 amount);

    /// @notice Configures USDC; admin initially also receives series-management permission.
    constructor(address usdc_, address admin) {
        if (usdc_ == address(0) || admin == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MANAGER_ROLE, admin);
    }

    /// @notice Creates a series maturing inclusively fourteen to ninety days from now.
    function createSeries(string calldata name, string calldata rating, uint16 couponBps, uint64 maturity)
        external onlyRole(MANAGER_ROLE) returns (uint256 id)
    {
        if (maturity < block.timestamp + 14 days || maturity > block.timestamp + 90 days) revert InvalidMaturity();
        id = _series.length;
        _series.push(Series(name, rating, couponBps, uint64(block.timestamp), maturity, true));
        emit SeriesCreated(id, name, rating, couponBps, maturity);
    }

    /// @notice Returns the number of series; IDs start at zero.
    function seriesCount() external view override returns (uint256) { return _series.length; }

    /// @notice Returns series terms; active is false once maturity is reached.
    function seriesInfo(uint256 id) external view override returns (
        string memory name, string memory rating, uint16 couponBps, uint64 issuedAt, uint64 maturity, bool active
    ) {
        Series storage s = _getSeries(id);
        return (s.name, s.rating, s.couponBps, s.issuedAt, s.maturity, s.active && block.timestamp < s.maturity);
    }

    /// @notice Pulls caller USDC and credits par units after checkpointing existing coupons.
    function subscribe(uint256 id, uint256 usdcAmount) external override nonReentrant {
        Series storage s = _getSeries(id);
        if (!s.active || block.timestamp >= s.maturity) revert SeriesMatured();
        if (usdcAmount == 0) revert InvalidAmount();
        _accrue(id, msg.sender);
        _units[id][msg.sender] += usdcAmount;
        totalOutstanding += usdcAmount;
        principalOutstanding += usdcAmount;
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        emit Subscribed(id, msg.sender, usdcAmount);
    }

    /// @notice Returns the holder's six-decimal par units.
    function unitsOf(uint256 id, address holder) external view override returns (uint256) {
        _getSeries(id);
        return _units[id][holder];
    }

    /// @notice Returns accrued carry plus Actual/365 simple coupon, capped at maturity.
    function pendingCoupon(uint256 id, address holder) public view override returns (uint256) {
        Series storage s = _getSeries(id);
        uint256 end = block.timestamp < s.maturity ? block.timestamp : s.maturity;
        uint256 start = lastClaim[id][holder];
        uint256 incremental;
        if (start != 0 && end > start) {
            incremental = Math.mulDiv(_units[id][holder], uint256(s.couponBps) * (end - start), 10_000 * 365 days);
        }
        return unpaidCoupon[id][holder] + accrued[id][holder] + incremental;
    }

    /// @notice Pulls funded coupon, retaining any unpaid entitlement for later claims.
    function claimCoupon(uint256 id) external override nonReentrant returns (uint256 paid) {
        _accrue(id, msg.sender);
        uint256 due = unpaidCoupon[id][msg.sender] + accrued[id][msg.sender];
        paid = Math.min(due, _couponReserve());
        if (due != 0 && paid == 0) revert InsufficientCouponReserve();
        unpaidCoupon[id][msg.sender] = due - paid;
        accrued[id][msg.sender] = 0;
        if (paid != 0) usdc.safeTransfer(msg.sender, paid);
        emit CouponPaid(id, msg.sender, paid);
    }

    /// @notice Pulls principal plus funded coupon; early redemption at par is a DEMO feature.
    /// @dev Unfunded coupon remains claimable, with new accrual only on remaining units.
    function redeem(uint256 id, uint256 units) external override nonReentrant returns (uint256 paid) {
        if (units == 0) revert InvalidAmount();
        _accrue(id, msg.sender);
        if (units > _units[id][msg.sender]) revert InsufficientUnits();
        uint256 due = unpaidCoupon[id][msg.sender] + accrued[id][msg.sender];
        uint256 reserve = _couponReserve();
        if (usdc.balanceOf(address(this)) - reserve < units) revert InsufficientReserve();
        uint256 coupon = Math.min(due, reserve);
        paid = units + coupon;
        unpaidCoupon[id][msg.sender] = due - coupon;
        accrued[id][msg.sender] = 0;
        _units[id][msg.sender] -= units;
        totalOutstanding -= units;
        principalOutstanding -= units;
        usdc.safeTransfer(msg.sender, paid);
        if (coupon != 0) emit CouponPaid(id, msg.sender, coupon);
        emit Redeemed(id, msg.sender, units, paid);
    }

    /// @notice Returns USDC available for coupons, excluding all outstanding principal.
    function couponReserve() external view override returns (uint256) { return _couponReserve(); }

    function _couponReserve() private view returns (uint256) {
        uint256 balance = usdc.balanceOf(address(this));
        return balance > principalOutstanding ? balance - principalOutstanding : 0;
    }

    /// @notice Pulls caller USDC into the coupon reserve without minting units.
    function fundReserve(uint256 amount) external nonReentrant {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit ReserveFunded(msg.sender, amount);
    }

    /// @notice Identifies this contract as a demo stand-in.
    function isDemo() external pure override returns (bool) { return true; }

    function _accrue(uint256 id, address holder) private {
        accrued[id][holder] = pendingCoupon(id, holder) - unpaidCoupon[id][holder];
        uint256 maturity = _series[id].maturity;
        lastClaim[id][holder] = block.timestamp < maturity ? block.timestamp : maturity;
    }

    function _getSeries(uint256 id) private view returns (Series storage s) {
        if (id >= _series.length) revert InvalidSeries();
        return _series[id];
    }
}
