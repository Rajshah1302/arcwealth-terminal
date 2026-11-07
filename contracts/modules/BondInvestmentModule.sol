// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStrategyModule, IBondIssuer} from "../interfaces/IArcWealth.sol";

/// @title BondInvestmentModule
/// @notice DEMO-ONCHAIN bond sleeve. Early redemption at par is a demo issuer feature.
contract BondInvestmentModule is IStrategyModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error OnlyVault();
    error OnlyKeeper();
    error DuplicateSeries(uint256 id);

    event CouponsClaimed(uint256 total);
    event RedemptionSkipped(uint256 indexed seriesId);

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    IERC20 public immutable usdc;
    address public immutable override vault;
    IBondIssuer public immutable issuer;
    uint256[] public seriesIds;

    /// @notice Configure the sole vault, settlement token, issuer and immutable series universe.
    constructor(address usdc_, address vault_, address issuer_, uint256[] memory seriesIds_) {
        if (usdc_ == address(0) || vault_ == address(0) || issuer_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
        vault = vault_;
        issuer = IBondIssuer(issuer_);
        for (uint256 i; i < seriesIds_.length; ++i) {
            for (uint256 j; j < i; ++j) {
                if (seriesIds_[j] == seriesIds_[i]) revert DuplicateSeries(seriesIds_[i]);
            }
            // Validate series through the shared interface, without depending on its implementation.
            issuer.seriesInfo(seriesIds_[i]);
            seriesIds.push(seriesIds_[i]);
        }
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    modifier onlyKeeper() {
        if (!IAccessControl(vault).hasRole(KEEPER_ROLE, msg.sender)) revert OnlyKeeper();
        _;
    }

    /// @notice Always true: DEMO-ONCHAIN stand-in.
    function isDemo() external pure override returns (bool) { return true; }

    /// @inheritdoc IStrategyModule
    function deposit(uint256 amount) external override onlyVault nonReentrant {
        if (amount == 0) return;
        usdc.safeTransferFrom(vault, address(this), amount);
        _invest(amount);
    }

    /// @inheritdoc IStrategyModule
    function totalValue() external view override returns (uint256 value) {
        value = usdc.balanceOf(address(this));
        uint256 coupons;
        for (uint256 i; i < seriesIds.length; ++i) {
            value += issuer.unitsOf(seriesIds[i], address(this));
            coupons += issuer.pendingCoupon(seriesIds[i], address(this));
        }
        value += Math.min(coupons, issuer.couponReserve());
    }

    /// @inheritdoc IStrategyModule
    /// @dev Counts principal at par and caps aggregate coupons by the issuer's coupon reserve.
    /// Issuer errors are ignored; a reserve shared with other holders is not a guarantee of liquidity.
    function liquidValue() external view override returns (uint256 value) {
        value = usdc.balanceOf(address(this));
        uint256 coupons;
        for (uint256 i; i < seriesIds.length; ++i) {
            uint256 id = seriesIds[i];
            try issuer.unitsOf(id, address(this)) returns (uint256 units) {
                value += units;
                try issuer.pendingCoupon(id, address(this)) returns (uint256 coupon) {
                    coupons += coupon;
                } catch {}
            } catch {}
        }
        try issuer.couponReserve() returns (uint256 reserve) {
            value += Math.min(coupons, reserve);
        } catch {}
    }

    /// @inheritdoc IStrategyModule
    function withdraw(uint256 amount) external override onlyVault nonReentrant returns (uint256 sent) {
        for (uint256 i; i < seriesIds.length && usdc.balanceOf(address(this)) < amount; ++i) {
            _redeemFor(seriesIds[i], amount - usdc.balanceOf(address(this)));
        }
        sent = Math.min(amount, usdc.balanceOf(address(this)));
        if (sent != 0) usdc.safeTransfer(vault, sent);
    }

    /// @notice Claim each series' coupons into this module; one CouponsClaimed event per successful series.
    /// @dev Reserve-short series are skipped so another series can still be claimed.
    function claimCoupons() external nonReentrant {
        for (uint256 i; i < seriesIds.length; ++i) {
            try issuer.claimCoupon(seriesIds[i]) returns (uint256 paid) {
                emit CouponsClaimed(paid);
            } catch {}
        }
    }

    /// @notice Redeem matured bonds and split available cash equally among active, non-matured series.
    function rollMatured() external onlyKeeper nonReentrant {
        for (uint256 i; i < seriesIds.length; ++i) {
            (,,,, uint64 maturity,) = issuer.seriesInfo(seriesIds[i]);
            if (block.timestamp >= maturity) _redeemFor(seriesIds[i], type(uint256).max);
        }
        _invest(usdc.balanceOf(address(this)));
    }

    function _invest(uint256 amount) private {
        bool[] memory eligible = new bool[](seriesIds.length);
        uint256 count;
        for (uint256 i; i < seriesIds.length; ++i) {
            (,,,, uint64 maturity, bool active) = issuer.seriesInfo(seriesIds[i]);
            eligible[i] = active && block.timestamp < maturity;
            if (eligible[i]) ++count;
        }
        if (count == 0 || amount == 0) return;
        uint256 remaining = amount;
        for (uint256 i; i < seriesIds.length; ++i) {
            if (!eligible[i]) continue;
            uint256 part = remaining / count;
            remaining -= part;
            --count;
            if (part == 0) continue;
            usdc.forceApprove(address(issuer), part);
            issuer.subscribe(seriesIds[i], part);
            usdc.forceApprove(address(issuer), 0);
        }
    }

    function _redeemFor(uint256 id, uint256 needed) private {
        // Principal is redeemable at par independently of coupon liquidity.
        try issuer.unitsOf(id, address(this)) returns (uint256 units) {
            if (units == 0) {
                try issuer.claimCoupon(id) returns (uint256 paid) { emit CouponsClaimed(paid); } catch {}
                return;
            }
            uint256 principal = Math.min(needed, units);
            if (principal == 0) return;
            try issuer.redeem(id, principal) returns (uint256) {} catch {
                emit RedemptionSkipped(id);
            }
        } catch { emit RedemptionSkipped(id); }
    }
}
