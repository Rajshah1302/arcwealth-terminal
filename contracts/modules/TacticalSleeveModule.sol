// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStrategyModule, IExecutionAdapter, IPriceSource, IStrategyManager} from "../interfaces/IArcWealth.sol";

/// @title TacticalSleeveModule
/// @notice DEMO-ONCHAIN cash/dTBILL sleeve. The put allocation is cash collateral only.
/// @dev SLBM and puts are placeholders: this module never writes on-chain put options.
contract TacticalSleeveModule is IStrategyModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error OnlyVault();
    error OnlyKeeper();
    error InvalidAllocation();
    error InvalidPrice();
    error ZeroQuote();

    event TacticalRebalanced(uint256 nav, uint256 targetTbillValue, uint16 putsBps);

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    IERC20 public immutable usdc;
    address public immutable override vault;
    IExecutionAdapter public immutable router;
    IPriceSource public immutable oracle;
    IStrategyManager public immutable manager;
    IERC20 public immutable tbill;
    uint256 public lastGoodPrice;
    uint256 public lastGoodValue;

    /// @notice Configure immutable vault, token, oracle, execution and allocation dependencies.
    constructor(address usdc_, address vault_, address router_, address oracle_, address manager_, address tbill_) {
        if (usdc_ == address(0) || vault_ == address(0) || router_ == address(0) || oracle_ == address(0) || manager_ == address(0) || tbill_ == address(0)) revert ZeroAddress();
        if (tbill_ == usdc_) revert InvalidAllocation();
        usdc = IERC20(usdc_);
        vault = vault_;
        router = IExecutionAdapter(router_);
        oracle = IPriceSource(oracle_);
        manager = IStrategyManager(manager_);
        tbill = IERC20(tbill_);
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
    /// @dev Holds new deposits as cash until the keeper explicitly rebalances the tactical allocation.
    function deposit(uint256 amount) external override onlyVault nonReentrant {
        if (amount != 0) usdc.safeTransferFrom(vault, address(this), amount);
        _checkpoint();
    }

    /// @inheritdoc IStrategyModule
    function totalValue() external view override returns (uint256) {
        uint256 cash = usdc.balanceOf(address(this));
        uint256 held = tbill.balanceOf(address(this));
        if (held == 0) return cash;
        try oracle.getPrice(address(tbill)) returns (uint256 spot) {
            return cash + Math.mulDiv(held, spot == 0 ? lastGoodPrice : spot, 1e20);
        } catch { return cash + Math.mulDiv(held, lastGoodPrice, 1e20); }
    }

    /// @inheritdoc IStrategyModule
    function liquidValue() external view override returns (uint256 value) {
        value = usdc.balanceOf(address(this));
        uint256 held = tbill.balanceOf(address(this));
        if (held == 0) return value;
        try router.quoteTokenForUsdc(address(tbill), held) returns (uint256 quote) {
            value += Math.mulDiv(quote, 9900, 10_000);
        } catch {}
    }

    /// @inheritdoc IStrategyModule
    /// @dev Collateral is only a cash allocation marker, not a lock against vault redemptions.
    function withdraw(uint256 amount) external override onlyVault nonReentrant returns (uint256 sent) {
        uint256 cash = usdc.balanceOf(address(this));
        if (cash < amount) {
            uint256 held = tbill.balanceOf(address(this));
            if (held != 0) {
                try router.quoteTokenForUsdc(address(tbill), held) returns (uint256 fullQuote) {
                    if (fullQuote != 0) {
                        uint256 needed = amount - cash;
                        uint256 qty = needed >= fullQuote ? held : Math.mulDiv(held, needed, fullQuote, Math.Rounding.Ceil);
                        _trySell(qty);
                    }
                } catch {}
            }
        }
        sent = Math.min(amount, usdc.balanceOf(address(this)));
        if (sent != 0) usdc.safeTransfer(vault, sent);
        _checkpoint();
    }

    /// @notice Rebalance to the manager's dTBILL target, trading only outside a 2%-of-NAV band.
    /// @dev Fresh spot is mandatory; cashBps plus putsBps stays in USDC. Trading uses 1% slippage limits.
    function rebalanceTactical() external onlyKeeper nonReentrant {
        (uint16 cashBps, uint16 tbillBps, uint16 putsBps) = manager.tacticalAllocation(vault);
        if (uint256(cashBps) + tbillBps + putsBps != 10_000) revert InvalidAllocation();
        uint256 spot = oracle.getPrice(address(tbill));
        if (spot == 0) revert InvalidPrice();
        lastGoodPrice = spot;
        uint256 heldValue = Math.mulDiv(tbill.balanceOf(address(this)), spot, 1e20);
        uint256 nav = usdc.balanceOf(address(this)) + heldValue;
        uint256 target = Math.mulDiv(nav, tbillBps, 10_000);
        uint256 tolerance = Math.mulDiv(nav, 200, 10_000);
        if (heldValue < target && target - heldValue > tolerance) {
            uint256 amount = Math.min(target - heldValue, usdc.balanceOf(address(this)));
            if (amount != 0) {
                uint256 quote = router.quoteUsdcForToken(address(tbill), amount);
                if (quote == 0) revert ZeroQuote();
                usdc.forceApprove(address(router), amount);
                router.swapExactUsdcForToken(address(tbill), amount, Math.max(1, Math.mulDiv(quote, 9900, 10_000)), address(this));
                usdc.forceApprove(address(router), 0);
            }
        } else if (heldValue > target && heldValue - target > tolerance) {
            uint256 qty = Math.min(tbill.balanceOf(address(this)), Math.mulDiv(heldValue - target, 1e20, spot, Math.Rounding.Ceil));
            uint256 quote = router.quoteTokenForUsdc(address(tbill), qty);
            if (quote == 0) revert ZeroQuote();
            tbill.forceApprove(address(router), qty);
            router.swapExactTokenForUsdc(address(tbill), qty, Math.max(1, Math.mulDiv(quote, 9900, 10_000)), address(this));
            tbill.forceApprove(address(router), 0);
        }
        _checkpoint();
        emit TacticalRebalanced(nav, target, putsBps);
    }

    /// @notice Return the currently reserved put cash, capped by cash actually held; no live puts exist.
    function putCollateral() external view returns (uint256) {
        (uint16 cashBps, uint16 tbillBps, uint16 putsBps) = manager.tacticalAllocation(vault);
        if (uint256(cashBps) + tbillBps + putsBps != 10_000) revert InvalidAllocation();
        return Math.min(usdc.balanceOf(address(this)), Math.mulDiv(this.totalValue(), putsBps, 10_000));
    }

    function _trySell(uint256 qty) private {
        if (qty == 0) return;
        try router.quoteTokenForUsdc(address(tbill), qty) returns (uint256 quote) {
            if (quote == 0) return;
            tbill.forceApprove(address(router), qty);
            try router.swapExactTokenForUsdc(address(tbill), qty, Math.max(1, Math.mulDiv(quote, 9900, 10_000)), address(this)) returns (uint256) {} catch {}
            tbill.forceApprove(address(router), 0);
        } catch {}
    }

    /// @notice Whether a price needed to value current holdings is stale or unset.
    function isStale() external view returns (bool) {
        if (tbill.balanceOf(address(this)) == 0) return false;
        try oracle.getPrice(address(tbill)) returns (uint256 spot) {
            return spot == 0;
        } catch { return true; }
    }

    /// @notice Refresh the NAV checkpoint only when all required prices are fresh.
    function refreshCheckpoint() external nonReentrant { _checkpoint(); }

    function _checkpoint() private {
        uint256 value = usdc.balanceOf(address(this));
        uint256 held = tbill.balanceOf(address(this));
        if (held != 0) {
            try oracle.getPrice(address(tbill)) returns (uint256 spot) {
                if (spot == 0) return;
                lastGoodPrice = spot;
                value += Math.mulDiv(held, spot, 1e20);
            } catch { return; }
        }
        lastGoodValue = value;
    }
}
