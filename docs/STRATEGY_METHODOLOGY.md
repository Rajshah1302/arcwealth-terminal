# Strategy methodology

Disclosure: strategy performance is simulated and illustrative. Demo tokens have no monetary value. Not investment advice.

## Pricing engine (SIMULATED-OFFCHAIN)
Seeded geometric Brownian motion per demo underlying: `S(t+dt) = S(t) * exp((mu - sigma^2/2) dt + sigma sqrt(dt) Z)`, with a deterministic PRNG (mulberry32 seeded by symbol). 365 days of daily history and live ticks. A three-state regime chain (calm / normal / stressed) switches `mu` and `sigma`. The keeper posts prices to `DemoPriceOracle` (max 10% step, 1 hour staleness). 30-day realised annualised volatility = stdev(daily log returns) * sqrt(365).

## Option pricing
Black-Scholes European call: `C = S N(d1) - K e^{-rT} N(d2)`, `d1 = (ln(S/K) + (r + sigma^2/2) T) / (sigma sqrt(T))`, r = 4.5%, sigma = 30d realised vol. Delta = N(d1). Premium is the quoted value; on-chain it must be within `maxPremiumBps` of notional.

## NAV
`NAV = idle USDC + sum(module.totalValue())`. Bonds = principal units + accrued Actual/365 coupon. Covered calls = underlying market value - call liability (intrinsic) + cash (includes premium received). Commodities = market value. `sharePrice = NAV / shares`. Total return = `sharePrice / entrySharePrice - 1`. Fees: 1% per year charged as newly minted shares at checkpoints; no entry or exit fee.

## S1 Hybrid Long-Short (Moderate), 40/40/20
- A Tokenized Debt (40%): three demo bonds, coupons 6.5% (AAA, 14d), 7.25% (AA, 45d), 8.0% (BBB, 90d). Credit and default risk is disclosed even though bonds are demo.
- B ITM Covered Calls (40%): dBTC/dETH held via DemoSwapRouter; strike = spot * (1 - itmDepth), default 5% (2% to 10%); expiry 7 to 30 days; coverage must be >= 100% on chain. Upside capped, downside retained, assignment possible.
- C Tactical (20%): USDC cash, dTBILL, cash-secured put collateral, SLBM placeholder. Regime table (cash / dTBILL / puts):

| Regime | Condition | Cash | dTBILL | Puts |
|---|---|---|---|---|
| Risk-off | vol > 80 or downtrend | 50 | 40 | 10 |
| High | 60 to 80 | 30 | 30 | 40 |
| Normal | 30 to 60 | 25 | 55 | 20 |
| Calm | <= 30 and uptrend | 20 | 80 | 0 |

Manager override up to +/-10 percentage points with a recorded reason.

## S2 Asset Allocator (Moderate-High)
dXAU 50 / dXAG 30 / dCOPR 20 (bands 30-70 / 10-40 / 0-30). Options overlay is available on dXAU and dXAG only; dCOPR options are auto-disabled on chain. Overlay (OTM 5% calls up to 50%, protective puts in high vol, +/-10pp tilt) is recorded-only in this demo.

## S3 Aggressive Covered Call (Very High)
100% covered calls on dBTC, dETH, dSOL (ITM 5% to OTM 10%, 7 to 30 days, coverage <= 100%). 50% of premium is reinvested at expiry. Capped upside, full downside, assignment risk.

## Illustrative backtest
1M/3M/6M returns on cards come from replaying the seeded GBM history through each strategy rule set. They are SIMULATED-OFFCHAIN and are not a forecast.

## Vault liquidity
Min deposit 10 USDC, TVL cap 1,000 USDC, per-user cap 250 USDC, at least 10% idle. Instant withdrawals up to the idle buffer; larger exits use request, keeper unwind, then pull claim.
