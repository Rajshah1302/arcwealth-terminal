# ARCWEALTH architecture

Hackathon demo on Arc Testnet (chain 5042002). Demo tokens have no monetary value. Not investment advice.

```mermaid
flowchart LR
  subgraph Browser
    UI[React + wagmi + viem + Recharts]
  end
  subgraph Backend[Bun API + keepers]
    API[REST API]
    PX[Seeded GBM price engine]
    KP[Keepers: prices, NAV, coupons, expiry, regime]
    IDX[Indexer: logs to chain_events]
    DB[(Postgres)]
  end
  subgraph Arc[Arc Testnet]
    USDC[(USDC ERC-20 0x3600..)]
    IV[InvestorVault]
    V[SIFStrategyVault x3 ERC-4626]
    SM[StrategyManager]
    RM[RiskManager]
    TL[Timelock 10 min]
    M1[BondInvestmentModule]
    M2[CoveredCallModule]
    M3[TacticalSleeveModule]
    M4[AssetAllocatorModule]
    OR[DemoPriceOracle]
    RT[DemoSwapRouter]
    BI[DemoBondIssuer]
    CP[DemoOptionsCounterparty]
    LP[DemoLendingPool]
  end
  UI -->|reads/writes via wallet| V
  UI -->|disclosure| IV
  UI --> API
  API --> DB
  PX --> DB
  KP -->|setPrice, settle, claim| OR
  KP --> M2
  KP --> M1
  IDX -->|getLogs small ranges| Arc
  IDX --> DB
  V --> M1 & M2 & M3 & M4
  V -.reads.-> SM & RM
  M1 --> BI
  M2 --> RT & CP
  M3 --> RT
  M4 --> RT
  RT --> OR
  TL -->|DEFAULT_ADMIN| V & RM & SM & IV
  V --> USDC
```

## Deposit sequence
```mermaid
sequenceDiagram
  participant U as Investor (MetaMask)
  participant IV as InvestorVault
  participant V as SIFStrategyVault
  participant M as Modules
  U->>IV: acceptDisclosure(strategy, hash)
  U->>V: USDC.approve(vault, exact amount)
  U->>V: deposit(amount, receiver)
  V->>V: checkpointFee, risk checks, mint shares
  V->>IV: recordDeposit(cost basis)
  V->>M: route per StrategyManager weights (>=10% idle)
  M-->>V: try/catch, failures leave USDC idle
  V-->>U: shares + receipt
```

## Honesty tiers
| Tier | Meaning | Examples |
|---|---|---|
| LIVE-TESTNET | Real Arc contract we do not own | USDC, EURC, cirBTC, WETH, App Kit, Morpho |
| DEMO-ONCHAIN | Our stand-in, real txs, no value | demo bonds, dBTC.., options counterparty, lending pool, swap router |
| SIMULATED-OFFCHAIN | Backend computed | GBM prices, charts, backtests, Black-Scholes premium inputs |

Every API figure carries `tier`; the UI renders a badge. Demo/simulated figures are labelled "Demo yield (testnet, no monetary value)".

## Components
- Contracts: see CONTRACTS.md. Deployments: `deployments/arc-testnet.json`.
- Backend (`server/`): Bun HTTP server on :3001 (Vite proxies `/api`). Postgres via Bun.sql (see DB_SCHEMA.sql).
- Keepers (`server/keepers.ts`): hold the keeper key from `DEPLOYER_PRIVATE_KEY`. Every tx uses EIP-1559 type 2 with `maxFeePerGas >= 20 gwei`.
- Indexer (`server/indexer.ts`): small-range `eth_getLogs`, rotates fallback RPCs with backoff, idempotent on `(tx_hash, log_index)`, dedupes USDC Transfer by emitter (ERC-20 `0x3600..` vs native system emitter `0xffff..fffe`).
- Frontend (`src/`): React + Vite (Next.js in the brief is replaced, see ASSUMPTIONS).

## Arc rules enforced
Native gas USDC is 18 decimals, the ERC-20 is 6; all accounting uses the ERC-20 view. maxFeePerGas floor 20 gwei. No push loops (pull claims). Zero-address recipients rejected. No native value to contracts. Receipts awaited before UI updates.
