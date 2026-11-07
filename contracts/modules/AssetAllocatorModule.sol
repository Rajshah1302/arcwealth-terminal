// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStrategyModule, IExecutionAdapter, IPriceSource, IStrategyManager, IRiskManager} from "../interfaces/IArcWealth.sol";

/// @title AssetAllocatorModule
/// @notice DEMO-ONCHAIN S2 asset basket. Options overlays are recorded-only, never executed.
/// @dev No keeper function redirects assets; swaps always pay this module and withdrawals only pay its vault.
contract AssetAllocatorModule is IStrategyModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error OnlyVault();
    error OnlyKeeper();
    error InvalidToken(address token);
    error InvalidWeights();
    error AssetLimitExceeded(address token);
    error OptionsDisabled(address token);
    error InvalidNotional();
    error InvalidPrice(address token);
    error ZeroQuote();

    event OverlayRecorded(address indexed token, bytes32 indexed kind, uint16 notionalBps, string reason);
    event Rebalanced(uint256 nav);

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    IERC20 public immutable usdc;
    address public immutable override vault;
    IExecutionAdapter public immutable router;
    IPriceSource public immutable oracle;
    IStrategyManager public immutable manager;
    IRiskManager public immutable risk;
    address[] public tokens;
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public lastGoodPrice;
    uint256 public lastGoodValue;

    /// @notice Configure the immutable S2 token universe and shared-interface dependencies.
    constructor(address usdc_, address vault_, address router_, address oracle_, address manager_, address risk_, address[] memory tokens_) {
        if (usdc_ == address(0) || vault_ == address(0) || router_ == address(0) || oracle_ == address(0) || manager_ == address(0) || risk_ == address(0)) revert ZeroAddress();
        if (tokens_.length == 0) revert InvalidWeights();
        usdc = IERC20(usdc_);
        vault = vault_;
        router = IExecutionAdapter(router_);
        oracle = IPriceSource(oracle_);
        manager = IStrategyManager(manager_);
        risk = IRiskManager(risk_);
        for (uint256 i; i < tokens_.length; ++i) {
            address token = tokens_[i];
            if (token == address(0) || token == usdc_ || whitelisted[token]) revert InvalidToken(token);
            whitelisted[token] = true;
            tokens.push(token);
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
    /// @dev Missing weights remain cash. Targets and resulting mark-to-market exposures must obey risk caps.
    function deposit(uint256 amount) external override onlyVault nonReentrant {
        uint16[] memory weights = _weights();
        if (amount != 0) usdc.safeTransferFrom(vault, address(this), amount);
        for (uint256 i; i < tokens.length; ++i) {
            uint256 part = Math.mulDiv(amount, weights[i], 10_000);
            if (part != 0) _buy(tokens[i], part);
        }
        _enforceCaps();
        _checkpoint();
    }

    /// @inheritdoc IStrategyModule
    function totalValue() external view override returns (uint256 value) {
        value = usdc.balanceOf(address(this));
        for (uint256 i; i < tokens.length; ++i) {
            uint256 held = IERC20(tokens[i]).balanceOf(address(this));
            if (held == 0) continue;
            try oracle.getPrice(tokens[i]) returns (uint256 spot) {
                value += Math.mulDiv(held, spot == 0 ? lastGoodPrice[tokens[i]] : spot, 1e20);
            } catch { value += Math.mulDiv(held, lastGoodPrice[tokens[i]], 1e20); }
        }
    }

    /// @inheritdoc IStrategyModule
    function liquidValue() external view override returns (uint256 value) {
        value = usdc.balanceOf(address(this));
        for (uint256 i; i < tokens.length; ++i) {
            uint256 held = IERC20(tokens[i]).balanceOf(address(this));
            if (held == 0) continue;
            try router.quoteTokenForUsdc(tokens[i], held) returns (uint256 quote) {
                value += Math.mulDiv(quote, 9900, 10_000);
            } catch {}
        }
    }

    /// @inheritdoc IStrategyModule
    /// @dev Exits are best effort and never blocked by reduced risk caps or changed manager weights.
    function withdraw(uint256 amount) external override onlyVault nonReentrant returns (uint256 sent) {
        for (uint256 i; i < tokens.length && usdc.balanceOf(address(this)) < amount; ++i) {
            address token = tokens[i];
            uint256 held = IERC20(token).balanceOf(address(this));
            if (held == 0) continue;
            try router.quoteTokenForUsdc(token, held) returns (uint256 fullQuote) {
                if (fullQuote == 0) continue;
                uint256 needed = amount - usdc.balanceOf(address(this));
                uint256 qty = needed >= fullQuote ? held : Math.mulDiv(held, needed, fullQuote, Math.Rounding.Ceil);
                _trySell(token, qty);
            } catch {}
        }
        sent = Math.min(amount, usdc.balanceOf(address(this)));
        if (sent != 0) usdc.safeTransfer(vault, sent);
        _checkpoint();
    }

    /// @notice Sell overweight assets first, then buy underweights at fresh spot and 1% quote slippage.
    /// @dev Final exposure checks can revert at exact caps because of fees or rounding; configure headroom.
    function rebalance() external onlyKeeper nonReentrant {
        uint16[] memory weights = _weights();
        uint256[] memory prices = new uint256[](tokens.length);
        uint256 nav = usdc.balanceOf(address(this));
        for (uint256 i; i < tokens.length; ++i) {
            prices[i] = _spot(tokens[i]);
            nav += Math.mulDiv(IERC20(tokens[i]).balanceOf(address(this)), prices[i], 1e20);
        }
        for (uint256 i; i < tokens.length; ++i) {
            uint256 held = IERC20(tokens[i]).balanceOf(address(this));
            uint256 targetQty = Math.mulDiv(Math.mulDiv(nav, weights[i], 10_000), 1e20, prices[i]);
            if (held > targetQty) _sell(tokens[i], held - targetQty);
        }
        // Recompute NAV after sell fees before calculating purchase targets.
        nav = _freshValue();
        for (uint256 i; i < tokens.length; ++i) {
            uint256 current = Math.mulDiv(IERC20(tokens[i]).balanceOf(address(this)), prices[i], 1e20);
            uint256 target = Math.mulDiv(nav, weights[i], 10_000);
            if (target > current) {
                uint256 amount = Math.min(target - current, usdc.balanceOf(address(this)));
                if (amount != 0) _buy(tokens[i], amount);
            }
        }
        _enforceCaps();
        _checkpoint();
        emit Rebalanced(lastGoodValue);
    }

    /// @notice Record an informational overlay only; kind is an application-defined bytes32 label.
    /// @dev This neither opens an option nor transfers funds; manager permission is authoritative.
    function recordOverlay(address token, bytes32 kind, uint16 notionalBps, string calldata reason) external onlyKeeper nonReentrant {
        if (!whitelisted[token]) revert InvalidToken(token);
        if (!manager.optionsAvailable(vault, token)) revert OptionsDisabled(token);
        if (notionalBps > 10_000) revert InvalidNotional();
        emit OverlayRecorded(token, kind, notionalBps, reason);
        _checkpoint();
    }

    function _weights() private view returns (uint16[] memory aligned) {
        (address[] memory configured, uint16[] memory bps) = manager.assetWeights(vault);
        if (configured.length != bps.length) revert InvalidWeights();
        aligned = new uint16[](tokens.length);
        uint256 sum;
        for (uint256 i; i < configured.length; ++i) {
            address token = configured[i];
            if (!whitelisted[token]) revert InvalidToken(token);
            for (uint256 j; j < i; ++j) {
                if (configured[j] == token) revert InvalidWeights();
            }
            if (bps[i] > risk.assetMaxBps(vault, token)) revert AssetLimitExceeded(token);
            sum += bps[i];
            for (uint256 j; j < tokens.length; ++j) {
                if (tokens[j] == token) { aligned[j] = bps[i]; break; }
            }
        }
        if (sum > 10_000) revert InvalidWeights();
    }

    function _spot(address token) private returns (uint256 spot) {
        spot = oracle.getPrice(token);
        if (spot == 0) revert InvalidPrice(token);
        lastGoodPrice[token] = spot;
    }

    function _freshValue() private returns (uint256 value) {
        value = usdc.balanceOf(address(this));
        for (uint256 i; i < tokens.length; ++i) {
            uint256 held = IERC20(tokens[i]).balanceOf(address(this));
            if (held != 0) value += Math.mulDiv(held, _spot(tokens[i]), 1e20);
        }
    }

    function _enforceCaps() private {
        uint256 nav = _freshValue();
        if (nav == 0) return;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 held = IERC20(tokens[i]).balanceOf(address(this));
            if (held == 0) continue;
            uint256 value = Math.mulDiv(held, _spot(tokens[i]), 1e20);
            if (value > Math.mulDiv(nav, risk.assetMaxBps(vault, tokens[i]), 10_000)) revert AssetLimitExceeded(tokens[i]);
        }
    }

    function _buy(address token, uint256 amount) private {
        _spot(token);
        uint256 quote = router.quoteUsdcForToken(token, amount);
        if (quote == 0) revert ZeroQuote();
        usdc.forceApprove(address(router), amount);
        router.swapExactUsdcForToken(token, amount, Math.max(1, Math.mulDiv(quote, 9900, 10_000)), address(this));
        usdc.forceApprove(address(router), 0);
    }

    function _sell(address token, uint256 qty) private {
        uint256 quote = router.quoteTokenForUsdc(token, qty);
        if (quote == 0) revert ZeroQuote();
        IERC20(token).forceApprove(address(router), qty);
        router.swapExactTokenForUsdc(token, qty, Math.max(1, Math.mulDiv(quote, 9900, 10_000)), address(this));
        IERC20(token).forceApprove(address(router), 0);
    }

    function _trySell(address token, uint256 qty) private {
        if (qty == 0) return;
        try router.quoteTokenForUsdc(token, qty) returns (uint256 quote) {
            if (quote == 0) return;
            IERC20(token).forceApprove(address(router), qty);
            try router.swapExactTokenForUsdc(token, qty, Math.max(1, Math.mulDiv(quote, 9900, 10_000)), address(this)) returns (uint256) {} catch {}
            IERC20(token).forceApprove(address(router), 0);
        } catch {}
    }

    /// @notice Whether any price needed to value current holdings is stale or unset.
    function isStale() external view returns (bool) {
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            if (IERC20(token).balanceOf(address(this)) == 0) continue;
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
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 held = IERC20(token).balanceOf(address(this));
            if (held == 0) continue;
            try oracle.getPrice(token) returns (uint256 spot) {
                if (spot == 0) { allFresh = false; continue; }
                lastGoodPrice[token] = spot;
                value += Math.mulDiv(held, spot, 1e20);
            } catch { allFresh = false; }
        }
        if (allFresh) lastGoodValue = value;
    }
}
