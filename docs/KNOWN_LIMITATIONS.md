# Known limitations

Hackathon demo on Arc Testnet. Demo tokens have no monetary value. Not investment advice. Unaudited.

- Local Foundry simulations cannot reproduce Arc precompiles or the USDC blocklist; blocklist behaviour is tested with mocks and confirmed on the real RPC where possible.
- Demo swap router and options counterparty hold finite USDC reserves funded from faucet USDC; large trades can revert with `InsufficientLiquidity`.
- Expiry range is 7 to 30 days, so assignment cannot be observed in a short demo.
- Backtests, prices and volatility are simulated and illustrative.
- Early bond redemption at par is a demo-only feature.
- S2 options overlay and tactical cash-secured puts / SLBM are recorded-only placeholders.
- Accepted trust assumption (review finding): DEFAULT_ADMIN is a 10-minute timelock that can whitelist new strategy modules. A malicious module could be added after the delay; mainnet would need a much longer delay, an immutable module registry, or a freeze switch. Investors can always exit up to the idle buffer.
- Accepted trust assumption (review finding): demo tokens have a public faucet and the swap router pays real testnet USDC from its reserve when they are sold, so a faucet farmer can drain the router reserve and the vault's demo-underlying sleeves would then be hard to unwind. Mitigations: small faucet amounts, `setFaucetAmount(0)` kill switch, only the real cirBTC is registered as lending collateral. Demo reserves hold testnet USDC only.
- While any module price is stale (>1 hour), deposits and instant withdrawals pause; request, cancel and claim keep working.
- Explorer source verification was attempted for all 24 contracts with Blockscout-style verification but the explorer API answered "Too many requests" and no ABI endpoint, so contracts are deployed and bytecode-checked on chain but not source-verified (`deployments/verification.json`). Rebuild with `forge build` (solc 0.8.28, cancun, optimizer 200) to reproduce bytecode.
- Wallet support is the injected connector (MetaMask and other browser wallets). WalletConnect needs a project id that is not configured.
- App Kit Swap, Earn (Morpho) and Borrow need a Circle API key and are not provisioned; Trading shows live tokens read-only and Lending uses the labelled demo pool.
- The deployer key is the testnet deployer, MANAGER, KEEPER, PAUSER and the timelock proposer/executor. It cannot move investor funds or shares, but it can propose timelocked changes. Production would split these roles across multisigs.
- The router charges 0.3% on each sleeve purchase and the cost is borne by all holders (shares mint at pre-fee NAV), so share price starts slightly below 1.0000 after the first routed deposit.
- The 1,000 USDC strategy cap is slightly under-fillable after router fees.
- I verified the P0 flow end to end on the real RPC with a script (`bun run gate:phase3`): disclosure, exact approval, deposit, shares, routed sleeves, instant withdraw, over-buffer revert. The browser journey with MetaMask itself was not exercised in this environment.
- Review rounds: two rounds of automated review were run (balanced depth); the last fixes (stale-price valuation, bond principal and coupon separation) were covered by new tests (225 passing) but not re-reviewed a third time.
