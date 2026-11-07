# ARCWEALTH

A USDC investing demo on Arc Testnet: crypto trading, lending and three strategy investment funds (SIFs) whose vault accounting lives on chain. Every figure carries an honesty badge: live testnet, demo onchain, or simulated.

Built with [Arc Studio](https://studio.arc.io)

Hackathon demo on Arc Testnet. Demo tokens have no monetary value. Not investment advice. Strategy performance is simulated and illustrative.

## What you can do
- Connect MetaMask, switch to Arc Testnet and grab test USDC.
- Browse three SIFs, compare them, accept the disclosure onchain and invest from 10 USDC.
- Watch shares, share price, sleeves, bonds, covered calls and the tactical regime update.
- Withdraw instantly up to the idle buffer, or request a larger withdrawal and claim it later.
- Trade demo tokens, view live testnet tokens, and try the demo lending pool.
- Review portfolio, history with explorer links, and public strategy-change history.

## Tech stack
React, Vite, TypeScript, Tailwind, Recharts, wagmi and viem. Solidity 0.8.28 with OpenZeppelin v5 and Foundry. Bun API server with Postgres, keepers and a log indexer.

## Development
Prerequisites: Bun, Foundry, Docker (for Postgres).

```bash
bun install
forge build && forge test                # contracts and tests
docker run -d --name arcwealth-pg -e POSTGRES_USER=arcwealth -e POSTGRES_PASSWORD=arcwealth -e POSTGRES_DB=arcwealth -v arcwealth_pg:/var/lib/postgresql -p 5432:5432 postgres:18-alpine
cp .env.example .env && bun run scripts/gen-key.ts   # creates DEPLOYER_PRIVATE_KEY; fund its address from faucet.circle.com
bun run deploy:arcwealth                  # deploy and seed on Arc Testnet (resumable)
bun run scripts/sync-deployments.ts       # checksum addresses and mirror them to the frontend
bun run gate:phase3                       # real-RPC deposit, shares and withdraw check
bun run server                            # API, keepers and indexer on :3001
bun run dev                               # frontend on :5173 (proxies /api)
```

Build: `bunx vite build`. `bun run start` serves the API and the built frontend together; without `DATABASE_URL` it uses an in-process Postgres. Lint and typecheck: `bun run check`.

### Environment variables
| Name | Purpose |
|---|---|
| `DEPLOYER_PRIVATE_KEY` | Testnet deployer and keeper key. Never commit. |
| `ARC_TESTNET_RPC_URL` | Primary Arc Testnet RPC (defaults to the registry value). |
| `ARC_TESTNET_FALLBACK_RPCS` | Comma separated fallback RPCs, rotated on failure. |
| `DATABASE_URL` | Postgres connection string. |
| `API_PORT` | API port (default 3001). |
| `KEEPERS` | Set to `off` to run the API without keepers (keepers also stay off when no deployer key is set). |
| `PORT` | Port for the combined API and frontend server (falls back to `API_PORT`). |
| `ROUTER_RESERVE_USDC`, `BOND_RESERVE_USDC`, `CP_RESERVE_USDC` | Optional deploy-time demo reserves. |
| `RPC_PROXY_BASE_URL`, `RPC_PROXY_TOKEN`, `RPC_PROXY_CHAINS`, `RPC_URL_Arc_Testnet` | Optional outside Arc Studio. Provisioned RPC proxy or per-chain override. |

## Docs
See `docs/` for architecture, contracts, API, database schema, methodology, integration matrix, assumptions, known limitations and the demo script.

Unaudited testnet software. No mainnet, no real securities, no fiat.
