// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Shared interfaces for ARCWEALTH. All USDC amounts are the 6-decimal ERC-20 view.
/// Prices are USD with 8 decimals (price8). Demo underlyings use 18 decimals.

interface IDemo {
    /// @dev Always true for stand-in (DEMO-ONCHAIN) contracts.
    function isDemo() external view returns (bool);
}

interface IPriceSource {
    /// @return price8 USD price with 8 decimals. Reverts StalePrice if older than the staleness window.
    function getPrice(address token) external view returns (uint256 price8);
    function lastUpdated(address token) external view returns (uint256);
}

interface IExecutionAdapter {
    function swapExactUsdcForToken(address token, uint256 usdcIn, uint256 minTokenOut, address to)
        external
        returns (uint256 tokenOut);
    function swapExactTokenForUsdc(address token, uint256 tokenIn, uint256 minUsdcOut, address to)
        external
        returns (uint256 usdcOut);
    function quoteUsdcForToken(address token, uint256 usdcIn) external view returns (uint256 tokenOut);
    function quoteTokenForUsdc(address token, uint256 tokenIn) external view returns (uint256 usdcOut);
}

/// @notice A sleeve of a SIF vault. Only the owning vault may call deposit/withdraw.
interface IStrategyModule is IDemo {
    function vault() external view returns (address);
    /// @return NAV of the module in USDC (6 dec).
    function totalValue() external view returns (uint256);
    /// @return USDC that withdraw() could return right now without reverting.
    function liquidValue() external view returns (uint256);
    /// @dev Pulls `amount` USDC from the vault via transferFrom (vault approves first).
    function deposit(uint256 amount) external;
    /// @dev Best effort: sends up to `amount` USDC to the vault, returns what was sent.
    function withdraw(uint256 amount) external returns (uint256 sent);
}

interface IBondIssuer is IDemo {
    function seriesCount() external view returns (uint256);
    function seriesInfo(uint256 id)
        external
        view
        returns (string memory name, string memory rating, uint16 couponBps, uint64 issuedAt, uint64 maturity, bool active);
    /// @dev Pulls USDC from msg.sender, credits 1:1 bond units to msg.sender.
    function subscribe(uint256 id, uint256 usdcAmount) external;
    function unitsOf(uint256 id, address holder) external view returns (uint256);
    function pendingCoupon(uint256 id, address holder) external view returns (uint256);
    function couponReserve() external view returns (uint256);
    /// @dev Pays accrued USDC coupon to msg.sender (pull). Reverts InsufficientCouponReserve if the coupon reserve is short.
    function claimCoupon(uint256 id) external returns (uint256 paid);
    /// @dev Burns units, pays principal + accrued coupon to msg.sender. Before maturity is early redemption at par (DEMO).
    function redeem(uint256 id, uint256 units) external returns (uint256 paid);
}

interface IOptionsCounterparty is IDemo {
    /// @dev Only authorised modules. Reverts if premium exceeds the configured cap of `notional`.
    function payPremium(address to, uint256 premium, uint256 notional) external;
    /// @dev Only authorised modules. Pulls `qty` underlying from `from`, pays `strikeValue` USDC to `from`.
    function settleAssignment(address underlying, uint256 qty, uint256 strikeValue, address from) external;
    function availableLiquidity() external view returns (uint256);
}

interface IRiskManager {
    struct CallLimits {
        uint32 minExpiry; // seconds from now
        uint32 maxExpiry;
        uint8 maxShortsPerAsset;
        uint16 minStrikeBps; // strike / spot, e.g. 9000 = 10% ITM
        uint16 maxStrikeBps; // e.g. 11000 = 10% OTM
        uint16 maxPremiumBps; // premium / notional
    }

    function minDeposit(address strategy) external view returns (uint256);
    /// @return max additional assets allowed given TVL and per-user caps (0 if none).
    function maxDeposit(address strategy, uint256 tvl, uint256 userAssets) external view returns (uint256);
    function minIdleBps(address strategy) external view returns (uint16);
    function assetMaxBps(address strategy, address token) external view returns (uint16);
    function sleeveBand(address strategy, uint8 sleeve) external view returns (uint16 minBps, uint16 maxBps);
    function callLimits(address module) external view returns (CallLimits memory);
    /// @dev Reverts CoverageViolation unless held >= shortAfter (coverage >= 100%).
    function checkCoverage(uint256 held, uint256 shortAfter) external pure;
}

interface IStrategyManager {
    /// @return bps weights aligned with the vault's module order; sum == 10000 (idle is handled by the vault).
    function targetWeights(address strategy) external view returns (uint16[] memory);
    /// @return cashBps / tbillBps / putsBps of the tactical sleeve, regime table plus bounded override; sum == 10000.
    function tacticalAllocation(address strategy) external view returns (uint16 cashBps, uint16 tbillBps, uint16 putsBps);
    function assetWeights(address strategy) external view returns (address[] memory tokens, uint16[] memory bps);
    function optionsAvailable(address strategy, address token) external view returns (bool);
    function currentRegime() external view returns (uint8);
    function configHash(address strategy) external view returns (bytes32);
}

interface IInvestorVault {
    function hasAccepted(address user, address strategy) external view returns (bool);
    function recordDeposit(address user, uint256 assets, uint256 shares) external;
    function recordWithdraw(address user, uint256 assets, uint256 shares) external;
}
