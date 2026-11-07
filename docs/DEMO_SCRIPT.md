# 3-minute demo script

Hackathon demo on Arc Testnet. Demo tokens have no monetary value. Not investment advice.

**0:00 Landing.** "ARCWEALTH labels everything: green LIVE-TESTNET, amber DEMO-ONCHAIN, grey SIMULATED-OFFCHAIN. Nothing demo is ever called real yield."

**0:20 Wallet.** Connect MetaMask. If the banner shows a wrong network, click Switch to Arc Testnet (Profile has Add network and the faucet link). Use "Get test USDC" in the Arc Studio sidebar to fund the wallet.

**0:45 SIF discovery.** Open /sif. Three cards: S1 Hybrid Long-Short, S2 Asset Allocator, S3 Aggressive Covered Call, each with donut, illustrative backtest (badged SIMULATED) and the compare table.

**1:05 Invest 50 USDC in S1.**
1. Enter 50. The panel shows the sleeve split (10% idle, then 40/40/20), 1%/yr fee, no entry fee.
2. Accept the disclosure: a real transaction (the hash is stored in InvestorVault).
3. Approve exactly 50 USDC. Never unlimited.
4. Deposit. Receipt, shares and share price appear after the confirmed receipt, with an explorer link.

**1:50 Proof.** Open the S1 detail page: bonds with accrued Actual/365 coupons, covered calls written by the keeper (strike below spot, premium paid in real testnet USDC by the demo counterparty), tactical regime panel and expiry calendar.

**2:15 Portfolio.** Shares, cost basis, NAV, P&L, badges. Withdraw up to the idle buffer instantly. Larger exits: Request, keeper unwinds, Claim.

**2:35 Safety talking points.** The manager role cannot move funds (admin page shows read-only allocations and bounded overrides). Covered calls revert if short exceeds unlocked underlying. Stale oracle prices block deposits and instant exits. Fees are floored at 20 gwei maxFeePerGas.

**2:50 History and close.** History lists indexed events with explorer links. Footer repeats the disclaimer.

Backup if the wallet is unavailable: run `bun run gate:phase3` to execute the same flow on the real RPC and show `deployments/gate-phase3.json`.
