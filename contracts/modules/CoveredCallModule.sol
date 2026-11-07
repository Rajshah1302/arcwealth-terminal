// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStrategyModule, IExecutionAdapter, IPriceSource, IOptionsCounterparty, IRiskManager} from "../interfaces/IArcWealth.sol";

/// @title CoveredCallModule
/// @notice DEMO-ONCHAIN, fully covered calls with real USDC premiums and demo underlying assignment.
/// @dev NAV uses current balances at last-good asset prices when stale; it is not a live liquidation quote.
contract CoveredCallModule is IStrategyModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum CallStatus { Open, Assigned, Expired }
    struct Call {
        address underlying;
        uint256 qty;
        uint256 strike;
        uint64 expiry;
        uint256 premium;
        address counterparty;
        CallStatus status;
    }

    error ZeroAddress();
    error OnlyVault();
    error OnlyKeeper();
    error InvalidWeights();
    error InvalidUnderlying(address token);
    error InvalidAmount();
    error InvalidStrike();
    error InvalidExpiry();
    error TooManyShorts();
    error PremiumTooLarge();
    error InvalidCall(uint256 id);
    error CallNotOpen();
    error NotExpired();
    error InvalidPrice(address token);

    event CallWritten(uint256 indexed id, address indexed underlying, uint256 qty, uint256 strike, uint64 expiry, uint256 premium, address counterparty);
    event CallSettled(uint256 indexed id, uint256 spot, bool assigned);
    event Reinvested(address indexed underlying, uint256 usdcAmount);

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    IERC20 public immutable usdc;
    address public immutable override vault;
    IExecutionAdapter public immutable router;
    IPriceSource public immutable oracle;
    IOptionsCounterparty public immutable counterparty;
    IRiskManager public immutable risk;
    address[] public underlyings;
    uint16[] public underlyingBps;
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public openShortQty;
    mapping(address => uint256) public openShortCount;
    mapping(address => uint256) public lastGoodPrice;
    uint256 public lastGoodValue;
    Call[] private _calls;
    uint256[] private _openCallIds;
    mapping(uint256 => uint256) private _openCallIndex;

    /// @notice Configure immutable dependencies and nonduplicated, 100%-weighted demo underlyings.
    constructor(address usdc_, address vault_, address router_, address oracle_, address counterparty_, address risk_, address[] memory underlyings_, uint16[] memory underlyingBps_) {
        if (usdc_ == address(0) || vault_ == address(0) || router_ == address(0) || oracle_ == address(0) || counterparty_ == address(0) || risk_ == address(0)) revert ZeroAddress();
        if (underlyings_.length == 0 || underlyings_.length != underlyingBps_.length) revert InvalidWeights();
        usdc = IERC20(usdc_);
        vault = vault_;
        router = IExecutionAdapter(router_);
        oracle = IPriceSource(oracle_);
        counterparty = IOptionsCounterparty(counterparty_);
        risk = IRiskManager(risk_);
        uint256 sum;
        for (uint256 i; i < underlyings_.length; ++i) {
            address token = underlyings_[i];
            if (token == address(0) || token == usdc_ || whitelisted[token]) revert InvalidUnderlying(token);
            whitelisted[token] = true;
            underlyings.push(token);
            underlyingBps.push(underlyingBps_[i]);
            sum += underlyingBps_[i];
        }
        if (sum != 10_000) revert InvalidWeights();
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
        usdc.safeTransferFrom(vault, address(this), amount);
        for (uint256 i; i < underlyings.length; ++i) {
            uint256 part = Math.mulDiv(amount, underlyingBps[i], 10_000);
            if (part != 0) _buy(underlyings[i], part);
        }
        _checkpoint();
    }

    /// @inheritdoc IStrategyModule
    function totalValue() external view override returns (uint256 value) {
        value = usdc.balanceOf(address(this));
        for (uint256 i; i < underlyings.length; ++i) {
            address token = underlyings[i];
            if (IERC20(token).balanceOf(address(this)) == 0 && openShortQty[token] == 0) continue;
            try oracle.getPrice(token) returns (uint256 spot) {
                value += _component(token, spot == 0 ? lastGoodPrice[token] : spot);
            } catch { value += _component(token, lastGoodPrice[token]); }
        }
    }

    /// @inheritdoc IStrategyModule
    /// @dev Uses executable router quotes for unlocked units, excluding stale or unquotable assets.
    function liquidValue() external view override returns (uint256 value) {
        value = usdc.balanceOf(address(this));
        for (uint256 i; i < underlyings.length; ++i) {
            address token = underlyings[i];
            uint256 unlocked = _unlocked(token);
            if (unlocked == 0) continue;
            try router.quoteTokenForUsdc(token, unlocked) returns (uint256 out) {
                value += Math.mulDiv(out, 9900, 10_000);
            } catch {}
        }
    }

    /// @inheritdoc IStrategyModule
    function withdraw(uint256 amount) external override onlyVault nonReentrant returns (uint256 sent) {
        for (uint256 i; i < underlyings.length && usdc.balanceOf(address(this)) < amount; ++i) {
            address token = underlyings[i];
            _sellAvailable(token, _unlocked(token), amount - usdc.balanceOf(address(this)));
        }
        sent = Math.min(amount, usdc.balanceOf(address(this)));
        if (sent != 0) usdc.safeTransfer(vault, sent);
        _checkpoint();
    }

    /// @notice Write a fully covered call; strike and spot are 8-decimal USD, quantity is 18 decimals.
    function writeCall(address underlying, uint256 qty, uint256 strike, uint64 expiry, uint256 premium) external onlyKeeper nonReentrant {
        if (!whitelisted[underlying]) revert InvalidUnderlying(underlying);
        if (qty == 0) revert InvalidAmount();
        uint256 spot = _spot(underlying);
        IRiskManager.CallLimits memory limits = risk.callLimits(address(this));
        uint256 strikeBps = Math.mulDiv(strike, 10_000, spot);
        if (strike == 0 || strikeBps < limits.minStrikeBps || strikeBps > limits.maxStrikeBps) revert InvalidStrike();
        if (expiry <= block.timestamp || uint256(expiry) < block.timestamp + limits.minExpiry || uint256(expiry) > block.timestamp + limits.maxExpiry) revert InvalidExpiry();
        if (openShortCount[underlying] >= limits.maxShortsPerAsset) revert TooManyShorts();
        uint256 newShort = openShortQty[underlying] + qty;
        risk.checkCoverage(IERC20(underlying).balanceOf(address(this)), newShort);
        uint256 notional = Math.mulDiv(qty, spot, 1e20);
        if (notional == 0) revert InvalidAmount();
        if (premium > Math.mulDiv(notional, limits.maxPremiumBps, 10_000)) revert PremiumTooLarge();
        uint256 id = _calls.length;
        _calls.push(Call(underlying, qty, strike, expiry, premium, address(counterparty), CallStatus.Open));
        _openCallIndex[id] = _openCallIds.length;
        _openCallIds.push(id);
        openShortQty[underlying] = newShort;
        ++openShortCount[underlying];
        counterparty.payPremium(address(this), premium, notional);
        emit CallWritten(id, underlying, qty, strike, expiry, premium, address(counterparty));
        _checkpoint();
    }

    /// @notice Settle an expired call against fresh spot; in-the-money calls deliver the locked tokens.
    function settle(uint256 id) external onlyKeeper nonReentrant {
        if (id >= _calls.length) revert InvalidCall(id);
        Call storage position = _calls[id];
        if (position.status != CallStatus.Open) revert CallNotOpen();
        if (block.timestamp < position.expiry) revert NotExpired();
        uint256 spot = _spot(position.underlying);
        bool assigned = spot > position.strike;
        position.status = assigned ? CallStatus.Assigned : CallStatus.Expired;
        openShortQty[position.underlying] -= position.qty;
        --openShortCount[position.underlying];
        uint256 index = _openCallIndex[id];
        uint256 lastId = _openCallIds[_openCallIds.length - 1];
        _openCallIds[index] = lastId;
        _openCallIndex[lastId] = index;
        _openCallIds.pop();
        delete _openCallIndex[id];
        if (assigned) {
            IERC20 token = IERC20(position.underlying);
            token.forceApprove(position.counterparty, position.qty);
            IOptionsCounterparty(position.counterparty).settleAssignment(position.underlying, position.qty, Math.mulDiv(position.qty, position.strike, 1e20), address(this));
            token.forceApprove(position.counterparty, 0);
        }
        emit CallSettled(id, spot, assigned);
        _checkpoint();
    }

    /// @notice Reinvest module cash into a whitelisted underlying; premiums need not be fully reinvested.
    function reinvest(address underlying, uint256 usdcAmount) external onlyKeeper nonReentrant {
        if (!whitelisted[underlying]) revert InvalidUnderlying(underlying);
        if (usdcAmount == 0 || usdcAmount > usdc.balanceOf(address(this))) revert InvalidAmount();
        _buy(underlying, usdcAmount);
        emit Reinvested(underlying, usdcAmount);
        _checkpoint();
    }

    /// @notice Return the number of calls ever written.
    function callCount() external view returns (uint256) { return _calls.length; }

    /// @notice Return the immutable terms and current status of a call.
    function getCall(uint256 id) external view returns (Call memory) {
        if (id >= _calls.length) revert InvalidCall(id);
        return _calls[id];
    }

    /// @notice Return the underlying quantity locked by all open calls for an asset.
    function openShort(address underlying) external view returns (uint256) { return openShortQty[underlying]; }

    function _spot(address token) private returns (uint256 spot) {
        spot = oracle.getPrice(token);
        if (spot == 0) revert InvalidPrice(token);
        lastGoodPrice[token] = spot;
    }

    function _buy(address token, uint256 amount) private {
        _spot(token);
        uint256 quote = router.quoteUsdcForToken(token, amount);
        if (quote == 0) revert InvalidAmount();
        usdc.forceApprove(address(router), amount);
        router.swapExactUsdcForToken(token, amount, Math.max(1, Math.mulDiv(quote, 9900, 10_000)), address(this));
        usdc.forceApprove(address(router), 0);
    }

    function _unlocked(address token) private view returns (uint256) {
        uint256 held = IERC20(token).balanceOf(address(this));
        return held > openShortQty[token] ? held - openShortQty[token] : 0;
    }

    function _sellAvailable(address token, uint256 available, uint256 needed) private {
        if (available == 0) return;
        try router.quoteTokenForUsdc(token, available) returns (uint256 fullQuote) {
            if (fullQuote == 0) return;
            uint256 qty = needed >= fullQuote ? available : Math.mulDiv(available, needed, fullQuote, Math.Rounding.Ceil);
            try router.quoteTokenForUsdc(token, qty) returns (uint256 quote) {
                if (quote == 0) return;
                IERC20(token).forceApprove(address(router), qty);
                try router.swapExactTokenForUsdc(token, qty, Math.max(1, Math.mulDiv(quote, 9900, 10_000)), address(this)) returns (uint256) {} catch {}
                IERC20(token).forceApprove(address(router), 0);
            } catch {}
        } catch {}
    }

    function _component(address token, uint256 spot) private view returns (uint256) {
        uint256 gross = Math.mulDiv(IERC20(token).balanceOf(address(this)), spot, 1e20);
        uint256 liability;
        for (uint256 i; i < _openCallIds.length; ++i) {
            Call storage position = _calls[_openCallIds[i]];
            if (position.underlying == token && spot > position.strike) {
                liability += Math.mulDiv(spot - position.strike, position.qty, 1e20);
            }
        }
        return gross > liability ? gross - liability : 0;
    }

    /// @notice Whether any price needed for current holdings or open calls is stale or unset.
    function isStale() external view returns (bool) {
        for (uint256 i; i < underlyings.length; ++i) {
            address token = underlyings[i];
            if (IERC20(token).balanceOf(address(this)) == 0 && openShortQty[token] == 0) continue;
            try oracle.getPrice(token) returns (uint256 spot) {
                if (spot == 0) return true;
            } catch { return true; }
        }
        return false;
    }

    /// @notice Refresh the NAV checkpoint only when all required prices are fresh.
    function refreshCheckpoint() external nonReentrant { _checkpoint(); }

    function _checkpoint() private {
        uint256 value = usdc.balanceOf(address(this));
        bool allFresh = true;
        for (uint256 i; i < underlyings.length; ++i) {
            address token = underlyings[i];
            if (IERC20(token).balanceOf(address(this)) == 0 && openShortQty[token] == 0) continue;
            try oracle.getPrice(token) returns (uint256 spot) {
                if (spot == 0) { allFresh = false; continue; }
                lastGoodPrice[token] = spot;
                value += _component(token, spot);
            } catch { allFresh = false; }
        }
        if (allFresh) lastGoodValue = value;
    }
}
