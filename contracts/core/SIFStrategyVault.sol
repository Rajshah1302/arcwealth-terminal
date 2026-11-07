// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IInvestorVault, IRiskManager, IStrategyManager, IStrategyModule} from "../interfaces/IArcWealth.sol";

/// @dev Optional accounting extension implemented by the companion InvestorVault, without changing shared interfaces.
interface IArcWealthPositionTransfers {
    function recordTransfer(address from, address to, uint256 shares) external;
}

/// @dev Optional price-freshness extension; view calls use STATICCALL and unsupported modules remain compatible.
interface IArcWealthModuleFreshness {
    function isStale() external view returns (bool);
}

/// @title ARCWEALTH single-investor-fund strategy vault
/// @notice ERC-4626 custody with restricted module routing and user-only asynchronous claims.
/// @dev Claims are liabilities, excluded from NAV and spendable idle. Role holders have no arbitrary asset transfer path.
contract SIFStrategyVault is ERC4626, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    uint256 public constant FEE_BPS = 100;
    IInvestorVault public immutable investorVault;
    IRiskManager public immutable risk;
    IStrategyManager public immutable manager;
    address public immutable feeRecipient;
    address[] public modules;
    mapping(address => bool) public isModule;
    mapping(address => uint256) public pendingRedeem;
    mapping(address => uint256) public claimable;
    uint256 public totalClaimable;
    uint256 public lastFeeTs;
    bool private _escrowTransfer;

    error ZeroAddress();
    error InvalidAssetDecimals();
    error DisclosureRequired();
    error DepositTooSmall(uint256 assets, uint256 minimum);
    error InvalidModule();
    error ModuleNotEmpty();
    error InvalidWeights();
    error InvalidShares();
    error EscrowOnly();
    error NothingToClaim();
    error PricesStale();
    error InsufficientUnwound(uint256 needed, uint256 available);
    event ModuleAdded(address indexed module);
    event ModuleRemoved(address indexed module);
    event RouteFailed(address indexed module, uint256 amount, bytes reason);
    event UnwindFailed(address indexed module, uint256 amount, bytes reason);
    event FeeCheckpoint(uint256 feeShares, uint256 dt, uint256 sharePrice);
    event RedeemRequested(address indexed user, uint256 shares);
    event RedeemCancelled(address indexed user, uint256 shares);
    event RedeemFulfilled(address indexed user, uint256 shares, uint256 assets);
    event RedeemClaimed(address indexed user, uint256 assets);

    /// @notice Sets immutable custody dependencies; USDC must expose six decimals.
    constructor(
        IERC20 usdc, string memory name, string memory symbol, address admin, address feeRecipient_,
        IInvestorVault investorVault_, IRiskManager risk_, IStrategyManager manager_
    ) ERC20(name, symbol) ERC4626(usdc) {
        if (address(usdc) == address(0) || admin == address(0) || feeRecipient_ == address(0)
            || feeRecipient_ == address(this) || address(investorVault_) == address(0)
            || address(risk_) == address(0) || address(manager_) == address(0)) revert ZeroAddress();
        if (IERC20Metadata(address(usdc)).decimals() != 6) revert InvalidAssetDecimals();
        investorVault = investorVault_;
        risk = risk_;
        manager = manager_;
        feeRecipient = feeRecipient_;
        lastFeeTs = block.timestamp;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Returns live module NAV plus cash, excluding already fulfilled user claims.
    function totalAssets() public view override returns (uint256 assets) {
        assets = IERC20(asset()).balanceOf(address(this));
        for (uint256 i; i < modules.length; ++i) assets += IStrategyModule(modules[i]).totalValue();
        assets = assets > totalClaimable ? assets - totalClaimable : 0;
    }

    /// @notice USDC units represented by one whole twelve-decimal share.
    function sharePrice() public view returns (uint256) { return convertToAssets(10 ** decimals()); }

    /// @notice Unreserved cash available for instant exits or investment, excluding claims.
    function idle() public view returns (uint256) {
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        return cash > totalClaimable ? cash - totalClaimable : 0;
    }

    /// @notice Returns the number of whitelisted modules.
    function moduleCount() external view returns (uint256) { return modules.length; }

    /// @notice Returns modules in allocation order and their live USDC valuations.
    function moduleBreakdown() external view returns (address[] memory mods, uint256[] memory values) {
        mods = modules;
        values = new uint256[](mods.length);
        for (uint256 i; i < mods.length; ++i) values[i] = IStrategyModule(mods[i]).totalValue();
    }

    /// @notice Whitelists a demo module permanently bound to this vault.
    function addModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (module == address(0) || module.code.length == 0 || isModule[module]
            || IStrategyModule(module).vault() != address(this) || !IStrategyModule(module).isDemo()) revert InvalidModule();
        isModule[module] = true;
        modules.push(module);
        emit ModuleAdded(module);
    }

    /// @notice Removes an empty module, preserving the relative ordering of remaining modules.
    /// @dev Governance must coordinate replacement weights with the changed module order.
    function removeModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (!isModule[module]) revert InvalidModule();
        if (IStrategyModule(module).totalValue() != 0) revert ModuleNotEmpty();
        IERC20(asset()).forceApprove(module, 0);
        for (uint256 i; i < modules.length; ++i) {
            if (modules[i] != module) continue;
            for (uint256 j = i; j + 1 < modules.length; ++j) modules[j] = modules[j + 1];
            modules.pop();
            break;
        }
        isModule[module] = false;
        emit ModuleRemoved(module);
    }

    /// @notice Returns deposit capacity, including the receiver's escrowed economic position.
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (paused() || receiver == address(0) || receiver == address(this) || _modulesStale()) return 0;
        return risk.maxDeposit(address(this), totalAssets(), convertToAssets(balanceOf(receiver) + pendingRedeem[receiver]));
    }

    /// @notice Returns the maximum mint consistent with asset caps and rounding.
    function maxMint(address receiver) public view override returns (uint256) {
        uint256 capacity = maxDeposit(receiver);
        return capacity == 0 ? 0 : convertToShares(capacity);
    }

    /// @notice Maximum instant withdrawal; claims cannot be spent by other shareholders.
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (owner == address(this) || _modulesStale()) return 0;
        return Math.min(convertToAssets(balanceOf(owner)), idle());
    }

    /// @notice Maximum instant redemption, conservatively rounded down to available idle.
    function maxRedeem(address owner) public view override returns (uint256) {
        if (owner == address(this) || _modulesStale()) return 0;
        return Math.min(balanceOf(owner), convertToShares(idle()));
    }

    /// @notice Deposits USDC after fee accrual, disclosure and capacity validation.
    function deposit(uint256 assets, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
        _checkpointFee();
        return super.deposit(assets, receiver);
    }

    /// @notice Mints shares with the same restrictions as deposits.
    function mint(uint256 shares, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
        _checkpointFee();
        return super.mint(shares, receiver);
    }

    /// @notice Withdraws only available idle to the owner or an allowance-authorised recipient, even while paused.
    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256) {
        _checkpointFee();
        return super.withdraw(assets, receiver, owner);
    }

    /// @notice Redeems liquid shares without a privileged bypass, even while paused.
    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        _checkpointFee();
        return super.redeem(shares, receiver, owner);
    }

    /// @notice Transfers shares voluntarily with proportional cost-basis accounting.
    function transfer(address to, uint256 value) public override(ERC20, IERC20) nonReentrant returns (bool) { return super.transfer(to, value); }

    /// @notice Transfers shares only using standard ERC-20 allowance, never role permissions.
    function transferFrom(address from, address to, uint256 value) public override(ERC20, IERC20) nonReentrant returns (bool) {
        return super.transferFrom(from, to, value);
    }

    /// @notice Escrows additional shares into the caller's single pending exit request.
    function requestRedeem(uint256 shares) external nonReentrant {
        if (shares == 0) revert InvalidShares();
        _checkpointFee();
        pendingRedeem[msg.sender] += shares;
        _escrowTransfer = true;
        _transfer(msg.sender, address(this), shares);
        _escrowTransfer = false;
        emit RedeemRequested(msg.sender, shares);
    }

    /// @notice Returns only the caller's escrowed shares; no role may cancel another user's exit.
    function cancelRedeem() external nonReentrant {
        uint256 shares = pendingRedeem[msg.sender];
        if (shares == 0) revert InvalidShares();
        delete pendingRedeem[msg.sender];
        _escrowTransfer = true;
        _transfer(address(this), msg.sender, shares);
        _escrowTransfer = false;
        emit RedeemCancelled(msg.sender, shares);
    }

    /// @notice Reserves the requested user's proceeds; the keeper cannot select a different recipient.
    function fulfillRedeem(address user) external onlyRole(KEEPER_ROLE) nonReentrant {
        if (_modulesStale()) revert PricesStale();
        uint256 shares = pendingRedeem[user];
        if (shares == 0) revert InvalidShares();
        _checkpointFee();
        uint256 assets = convertToAssets(shares);
        if (idle() < assets) _unwind(assets - idle());
        // Realised unwind losses are borne by all still-outstanding shares, including this request.
        assets = convertToAssets(shares);
        uint256 available = idle();
        if (available < assets) revert InsufficientUnwound(assets, available);
        delete pendingRedeem[user];
        _burn(address(this), shares);
        claimable[user] += assets;
        totalClaimable += assets;
        investorVault.recordWithdraw(user, assets, shares);
        emit RedeemFulfilled(user, shares, assets);
    }

    /// @notice Pulls only the caller's fulfilled claim, using checks-effects-interactions.
    function claimRedeem() external nonReentrant { _claimRedeem(msg.sender); }

    /// @notice Pull the caller's fulfilled claim to a nonzero recipient chosen only by the caller.
    function claimRedeemTo(address receiver) external nonReentrant {
        if (receiver == address(0)) revert ZeroAddress();
        _claimRedeem(receiver);
    }

    function _claimRedeem(address receiver) private {
        uint256 assets = claimable[msg.sender];
        if (assets == 0) revert NothingToClaim();
        delete claimable[msg.sender];
        totalClaimable -= assets;
        IERC20(asset()).safeTransfer(receiver, assets);
        emit RedeemClaimed(msg.sender, assets);
    }

    /// @notice Pulls up to the requested additional amount into vault idle, most liquid module first.
    function unwind(uint256 amount) external onlyRole(KEEPER_ROLE) nonReentrant {
        if (_modulesStale()) revert PricesStale();
        _unwind(amount);
    }

    /// @notice Moves module positions toward target weights, never spending reserved claims or the idle floor.
    function rebalance() external onlyRole(KEEPER_ROLE) whenNotPaused nonReentrant {
        _checkpointFee();
        uint16[] memory weights = manager.targetWeights(address(this));
        if (!_validWeights(weights)) revert InvalidWeights();
        uint256 nav = totalAssets();
        uint256 investable = nav - _idleFloor(nav);
        for (uint256 i; i < modules.length; ++i) {
            uint256 target = Math.mulDiv(investable, weights[i], 10_000);
            uint256 value = IStrategyModule(modules[i]).totalValue();
            if (value > target) _pull(modules[i], value - target);
        }
        nav = totalAssets();
        investable = nav - _idleFloor(nav);
        for (uint256 i; i < modules.length; ++i) {
            uint256 target = Math.mulDiv(investable, weights[i], 10_000);
            uint256 value = IStrategyModule(modules[i]).totalValue();
            if (target > value) _invest(modules[i], target - value);
        }
    }

    /// @notice Accrues the one-percent annual management fee in shares, never in transferred USDC.
    function checkpointFee() public nonReentrant { _checkpointFee(); }

    /// @notice Pauses deposits and allocation, but never withdrawals or user claims.
    function pause() public onlyRole(PAUSER_ROLE) { _pause(); }

    /// @notice Resumes deposits and allocation.
    function unpause() public onlyRole(PAUSER_ROLE) { _unpause(); }

    function _decimalsOffset() internal pure override returns (uint8) { return 6; }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (receiver == address(0) || receiver == address(this)) revert ZeroAddress();
        if (!investorVault.hasAccepted(receiver, address(this))) revert DisclosureRequired();
        uint256 minimum = risk.minDeposit(address(this));
        if (assets < minimum) revert DepositTooSmall(assets, minimum);
        if (shares == 0) revert InvalidShares();
        super._deposit(caller, receiver, assets, shares);
        investorVault.recordDeposit(receiver, assets, shares);
        _route(assets);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal override {
        if (receiver == address(0) || receiver == address(this) || owner == address(this)) revert ZeroAddress();
        investorVault.recordWithdraw(owner, assets, shares);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            if ((from == address(this) || to == address(this)) && !_escrowTransfer) revert EscrowOnly();
            if (!_escrowTransfer && from != to) {
                IArcWealthPositionTransfers(address(investorVault)).recordTransfer(from, to, value);
            }
        }
        super._update(from, to, value);
    }

    function _modulesStale() private view returns (bool) {
        for (uint256 i; i < modules.length; ++i) {
            try IArcWealthModuleFreshness(modules[i]).isStale() returns (bool stale) {
                if (stale) return true;
            } catch {}
        }
        return false;
    }

    function _checkpointFee() private {
        uint256 dt = block.timestamp - lastFeeTs;
        if (dt == 0) return;
        lastFeeTs = block.timestamp;
        uint256 feeShares = Math.mulDiv(totalSupply(), FEE_BPS * dt, 10_000 * 365 days);
        if (feeShares != 0) {
            _mint(feeRecipient, feeShares);
            // Fee shares have zero acquisition cost but must participate in the economic-share ledger.
            investorVault.recordDeposit(feeRecipient, 0, feeShares);
        }
        emit FeeCheckpoint(feeShares, dt, sharePrice());
    }

    function _idleFloor(uint256 nav) private view returns (uint256) {
        uint256 bps = risk.minIdleBps(address(this));
        if (bps < 1000 || bps > 10_000) revert InvalidWeights();
        return Math.mulDiv(nav, bps, 10_000, Math.Rounding.Ceil);
    }

    function _validWeights(uint16[] memory weights) private view returns (bool) {
        if (weights.length != modules.length || weights.length == 0) return false;
        uint256 sum;
        for (uint256 i; i < weights.length; ++i) sum += weights[i];
        return sum == 10_000;
    }

    function _route(uint256 assets) private whenNotPaused {
        uint16[] memory weights = manager.targetWeights(address(this));
        // Setup gaps leave cash idle rather than stranding a user's otherwise valid deposit.
        if (!_validWeights(weights)) return;
        uint256 nav = totalAssets();
        uint256 floor = _idleFloor(nav);
        uint256 cash = idle();
        uint256 budget = Math.min(assets, cash > floor ? cash - floor : 0);
        for (uint256 i; i < modules.length; ++i) _invest(modules[i], Math.mulDiv(budget, weights[i], 10_000));
    }

    function _invest(address module, uint256 requested) private {
        uint256 cash = idle();
        uint256 floor = _idleFloor(totalAssets());
        uint256 amount = Math.min(requested, cash > floor ? cash - floor : 0);
        if (amount == 0) return;
        IERC20 token = IERC20(asset());
        token.forceApprove(module, amount);
        try IStrategyModule(module).deposit(amount) {} catch (bytes memory reason) {
            emit RouteFailed(module, amount, reason);
        }
        token.forceApprove(module, 0);
    }

    function _pull(address module, uint256 amount) private {
        if (amount == 0) return;
        try IStrategyModule(module).withdraw(amount) returns (uint256) {} catch (bytes memory reason) {
            emit UnwindFailed(module, amount, reason);
        }
    }

    function _unwind(uint256 amount) private {
        uint256 start = idle();
        uint256 length = modules.length;
        address[] memory order = modules;
        uint256[] memory liquidity = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            try IStrategyModule(order[i]).liquidValue() returns (uint256 value) { liquidity[i] = value; }
            catch { liquidity[i] = 0; }
        }
        for (uint256 i; i < length; ++i) {
            for (uint256 j = i + 1; j < length; ++j) {
                if (liquidity[j] > liquidity[i]) {
                    (liquidity[i], liquidity[j]) = (liquidity[j], liquidity[i]);
                    (order[i], order[j]) = (order[j], order[i]);
                }
            }
            uint256 nowIdle = idle();
            uint256 received = nowIdle > start ? nowIdle - start : 0;
            if (received >= amount) break;
            _pull(order[i], amount - received);
        }
    }
}
