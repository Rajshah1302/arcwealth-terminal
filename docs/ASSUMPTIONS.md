# Assumptions

1. **Framework**: Arc Studio runs Vite + React + TypeScript, so the brief's Next.js App Router is implemented as React Router on Vite. Backend is a separate Bun server proxied at `/api`.
2. **Deployment path**: contracts are deployed by a viem script (`scripts/deploy-arcwealth.ts`) signing with `DEPLOYER_PRIVATE_KEY` (generated, kept only in `.env`). This account is deployer, initial admin, MANAGER, KEEPER and PAUSER, then DEFAULT_ADMIN moves to the 10-minute timelock. No funds are controlled by roles.
3. **Strategies S2/S3**: deployed as separate vault instances of the same `SIFStrategyVault`. S3 reuses `CoveredCallModule` with a wider strike band (ITM 5% to OTM 10%). S2 on-chain overlay is record-only.
4. **Share decimals**: vault shares have 12 decimals (6 asset + 6 offset); share price 1.0 at inception.
5. **Demo underlying decimals**: 18. Prices have 8 decimals (USD).
6. **Bonds**: one `DemoBondIssuer` hosts three series (6.5% AAA 14d, 7.25% AA 45d, 8.0% BBB 90d). Early redemption at par is a demo feature. Coupons are paid in real testnet USDC from a reserve funded by the deployer; it has no monetary value.
7. **Option premiums** come from Black-Scholes computed off-chain by the keeper with 30d realised vol and a risk-free rate of 4.5%; the on-chain cap is `maxPremiumBps` of notional.
8. **Expiry range** is 7 to 30 days per spec. Expiry settlement therefore cannot be shown live in a 3-minute demo; the UI shows the schedule and the keeper settles when due.
9. **Regime inputs** are posted by the keeper from the simulated 30d vol and the 50d/200d trend of the simulated dBTC series.
10. **App Kit (Swap/Earn/Borrow)** needs `CIRCLE_API_KEY`; they are P1 and presented as LIVE-TESTNET only when the key is present, otherwise a DEMO-ONCHAIN fallback is shown.
11. **Verification** on the explorer is attempted via Blockscout-compatible verification; if it fails it is logged in KNOWN_LIMITATIONS.md.
12. **Disclosure hash** is keccak256 of the disclosure text in `src/lib/disclosure.ts`.
13. **No fiat, KYC, mainnet or unlimited approvals.** Approvals are for the exact deposit amount.
