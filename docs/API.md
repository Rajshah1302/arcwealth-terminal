# API (Bun server, proxied at `/api`)

All responses are JSON. Every figure that is not read directly from a LIVE-TESTNET contract carries `"tier"`.

| Method | Path | Returns |
|---|---|---|
| GET | `/health` | `{ ok, chainId, head, indexerBlock, keeperAddress, priceAgeSec }` |
| GET | `/deployments` | contents of `deployments/arc-testnet.json` |
| GET | `/prices` | latest simulated prices `{ symbol, price, change24hPct, tier }[]` |
| GET | `/prices/:symbol/history?days=365` | `[{ ts, price }]`, tier SIMULATED-OFFCHAIN |
| GET | `/strategies` | S1/S2/S3 metadata, sleeve weights, methodology, simulated 1M/3M/6M illustrative backtest, comparison metrics |
| GET | `/strategies/:id` | detail incl. config JSON + on-chain hash, regime, bonds, calls, expiry calendar |
| GET | `/strategies/:id/nav?days=` | NAV/share price snapshots |
| GET | `/events?account=&emitter=&limit=` | indexed `chain_events` (idempotent) |
| GET | `/portfolio/:address` | chain positions (shares, cost basis, NAV value, P&L) + indexed events |
| GET | `/history/:address` | account tx history with explorer links and tier badges |
| GET | `/strategy-events?limit=` | keeper activity feed |
| GET | `/admin/history` | public config change history (audit_log + StrategyConfigChanged) |
| POST | `/admin/audit` | `{ actor, action, reason, before, after, txHash }` recorded after an on-chain tx (server verifies the receipt) |
| GET | `/lending/markets` | DemoLendingPool utilisation, APRs (tier DEMO-ONCHAIN) |

Errors: `{ error: string }` with 4xx/5xx. The server never signs for users and never holds user funds.
