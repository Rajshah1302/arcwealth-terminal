# Integration matrix

| Component | Tier | Priority | Status | Notes |
|---|---|---|---|---|
| USDC `0x3600..0000` | LIVE-TESTNET | P0 | integrated | ERC-20 view only, 6 dec; deposits, coupons, premiums |
| EURC `0x89B5..D72a` | LIVE-TESTNET | P0 | read-only price/holding in Trading | faucet.circle.com |
| cirBTC `0xf0C4..32BF` | LIVE-TESTNET | P0 | holdings + simulated reference price | 8 dec |
| WETH `0x2c40..4961` | LIVE-TESTNET | P0 | holdings + simulated reference price | 18 dec |
| Permit2 / Multicall3 / CREATE2 | LIVE-TESTNET | n/a | not required | exact approvals used instead of Permit2 |
| USYC | n/a | n/a | not used | institution-only allowlist |
| App Kit Swap (USDC to EURC/cirBTC) | LIVE-TESTNET | P1 | gated on `CIRCLE_API_KEY` | falls back to DemoSwapRouter, labelled |
| App Kit Earn (Morpho) | LIVE-TESTNET | P1 | not provisioned | falls back to DemoLendingPool |
| App Kit Borrow | LIVE-TESTNET | P1 | not provisioned | DemoLendingPool borrow flow used |
| SIFStrategyVault S1/S2/S3 | DEMO-ONCHAIN | P0/P1 | deployed | ERC-4626 over real USDC; strategy performance is demo |
| InvestorVault | DEMO-ONCHAIN | P0 | deployed | disclosures and cost basis |
| StrategyManager / RiskManager / Timelock | DEMO-ONCHAIN | P0 | deployed | |
| BondInvestmentModule + DemoBondIssuer | DEMO-ONCHAIN | P0 | deployed | real USDC coupons, demo credit |
| CoveredCallModule + DemoOptionsCounterparty | DEMO-ONCHAIN | P0/P1 | deployed | premium and delivery are real USDC/demo tokens |
| TacticalSleeveModule | DEMO-ONCHAIN | P1 | deployed | puts and SLBM are placeholders |
| AssetAllocatorModule | DEMO-ONCHAIN | P1 | deployed | overlay record-only |
| DemoERC20 (dBTC dETH dSOL dXAU dXAG dCOPR dTBILL) | DEMO-ONCHAIN | P0 | deployed | faucet, no value |
| DemoPriceOracle / DemoSwapRouter | DEMO-ONCHAIN | P0 | deployed | stale 1h, 10% step, 0.3% fee |
| DemoLendingPool | DEMO-ONCHAIN | P1 | deployed | no demo yield claimed as real |
| Price engine (GBM) | SIMULATED-OFFCHAIN | P0 | running | seeded, regime-switching |
| Backtests / charts | SIMULATED-OFFCHAIN | P0 | running | "illustrative backtest" |
| Indexer | n/a | P0 | running | idempotent |
