# ARCWEALTH

> Built with Arc Studio - money-powered apps in minutes

This is the **project memory** - what Arc Studio remembers about building this app. It helps future agents (or humans) understand and extend the project.

---

## What This App Does

USDC investing demo on Arc Testnet: crypto trading, lending/borrowing and three SIF strategy vaults (ERC-4626) with an honesty-tier model (LIVE-TESTNET, DEMO-ONCHAIN, SIMULATED-OFFCHAIN). Docs in docs/.

## Tech Stack

- Frontend: React 18, Vite, TypeScript, Tailwind CSS
- Web3: wagmi v2, viem v2, ConnectKit
- Contracts: Solidity 0.8.28 + Foundry. Sources in `contracts/`, unit tests in `contracts/test/*.t.sol`. Build with `bun run contracts:build` (`forge build`), test with `bun run contracts:test` (`forge test`).
- Wallet: injected (MetaMask, etc.)
- Chain: Arc Testnet (Chain ID: 5042002, imported from `viem/chains`)
- Token: USDC (6 decimals) (Address: 0x3600000000000000000000000000000000000000, Chain: Arc Testnet)
- Toasts: Sonner

## Key Files

- `src/App.tsx` - Main application logic
- `src/components/` - UI components
- `src/config.ts` - wagmi config (chains, connectors, transports)

## Share links

- Starter apps already ship `getShareBase`, `buildShareLink` and `installShareSync` in `src/lib/share.ts`; import them instead of rewriting them.
- Keep shareable state in the URL path or query, not in the `#fragment`.
- Never put a secret (private key, claim secret, seed phrase, session token, API key) in the URL path or query, encoded or not: every in-app path and query is mirrored to the visitor's studio.arc.io address bar and browser history and reaches servers. A bearer claim secret goes only in the `#fragment` appended to the share link (`` `${await buildShareLink('/claim')}#${secret}` ``) and is read from `location.hash` on load. A link to the app's own share URL shown inside the app must be copy-only or open in a new tab with `target="_blank" rel="noopener noreferrer"`.
- Build every link a user copies or sends with `buildShareLink()` from `src/lib/share.ts`.
- Keep the `installShareSync()` call in `src/main.tsx` when editing it; it keeps the Studio address bar in step with in-app navigation.
- Navigate inside the app with relative links.

## To Run

```bash
bun install
bun run dev
```

## Deployed on Arc Testnet (5042002)
Source of truth: deployments/arc-testnet.json (mirrored to src/shared/deployments.json).
- USDC: 0x3600000000000000000000000000000000000000
- oracle: 0x7e7eBf2b872741d4c3904ccB891917107CDB7bcB
- router: 0xB8CeF38d18AF827AC1D46bDa599e31a0fA440E54
- issuer: 0x4AfaB11Aa0027DFF6e57831f23f2478EB8802016
- counterparty: 0x196b6363c4E15Fcdc4Dbe19Acc897417F3a4Fa75
- lending: 0xF146c37c9aF50784bf558BDE3Db56247d33E2212
- riskManager: 0xF6525a24d659B49E039c2E06200Fe9392FA4B156
- strategyManager: 0xCc8C0A58Ee0bf9d7b4684EA0E8264F6c1C598532
- investorVault: 0xbf8aD962b790b1E79a74af2d33EBe0931943Ae09
- timelock: 0x4d87Cd4cf0ec9AFd7D09c84065BB47C95bd64D57
- vault s1: 0xd2CFeb21c1703f3DF65F7E9E96478c49cc88FE73
  - module s1.bond: 0x4ae376E3fC676E755075161447FEC4faf7878CF1
  - module s1.calls: 0xe418046db719031fB0A32ACA1AB23C2689B67a41
  - module s1.tactical: 0xc5AD02de68b65a95Cde603926CF7b9B8E0aCb5c6
- vault s2: 0x567C87b9B1794C6b624f15C9eb6EB3CB3536a76c
  - module s2.allocator: 0xF7880D35D2c731F5aee9bCde153f1dBE5BC62F23
- vault s3: 0x128A5bAB0293667Ba655199f4725ea650281bC66
  - module s3.calls: 0x0dc96D0f788C91d1280E4ebE488D9fDfF4d33fA2
- token dBTC (DEMO-ONCHAIN): 0x9fC03C672fe2e3EBcf72E9E6B11F2551D658fa1e
- token dETH (DEMO-ONCHAIN): 0xf78bcA77ED3516f9bcEF1279047036EFb1C8b8a4
- token dSOL (DEMO-ONCHAIN): 0xFF16c6aC6b87e0A1cB682a9ab33a4fD8eB24fAe6
- token dXAU (DEMO-ONCHAIN): 0xcBccaAe65E6382a5D7934B002e612ac03752c237
- token dXAG (DEMO-ONCHAIN): 0xDAfCD3a837522D42F43f72c0574888D13B876914
- token dCOPR (DEMO-ONCHAIN): 0x9f634F92a980C6E88C970A8E065452f9ADA5908d
- token dTBILL (DEMO-ONCHAIN): 0x7047b9A19E7Fc8Fc977789Bf9257c6A56CdAC423
- token cirBTC (LIVE-TESTNET): 0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF
- token WETH (LIVE-TESTNET): 0x2c4047028a72803939b6fb674D01bC059B5C4961
- token EURC (LIVE-TESTNET): 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a

## Architecture notes
- Frontend: Vite + React Router (Next.js in the brief was replaced; see docs/ASSUMPTIONS.md).
- Backend: `bun run server` (API :3001 proxied at /api, keepers, indexer, Postgres via DATABASE_URL).
- Deployer/keeper key is DEPLOYER_PRIVATE_KEY in .env (testnet only). All txs use type 2 fees with maxFeePerGas >= 20 gwei.
- All amounts: ERC-20 USDC view (6 dec). Native gas view (18 dec) is never summed with it.
- Regenerate frontend ABIs with `bun run scripts/export-abis.ts` after contract changes.
