// Attempts explorer verification (Blockscout API) of every deployed contract. Constructor args are recovered from the deploy tx input.
// Run: bun run scripts/verify-all.ts   Results: deployments/verification.json
import { execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import type { Hex } from 'viem'
import { requireChain } from '../src/onchain-facts'
import { CHAIN_ID, ROOT, loadArtifact, loadDeployments, publicClient } from '../server/chain'

const dep = loadDeployments()
const facts = requireChain(CHAIN_ID)
const apiUrl = `${facts.explorerBase}/api/`

// progress key -> [source file, contract]
const SRC: Record<string, [string, string]> = {
  oracle: ['demo/DemoPriceOracle.sol', 'DemoPriceOracle'], router: ['demo/DemoSwapRouter.sol', 'DemoSwapRouter'], issuer: ['demo/DemoBondIssuer.sol', 'DemoBondIssuer'],
  counterparty: ['demo/DemoOptionsCounterparty.sol', 'DemoOptionsCounterparty'], lending: ['demo/DemoLendingPool.sol', 'DemoLendingPool'],
  risk: ['core/RiskManager.sol', 'RiskManager'], strategyManager: ['core/StrategyManager.sol', 'StrategyManager'], investorVault: ['core/InvestorVault.sol', 'InvestorVault'],
  timelock: ['core/ArcWealthTimelock.sol', 'ArcWealthTimelock'],
  'vault:s1': ['core/SIFStrategyVault.sol', 'SIFStrategyVault'], 'vault:s2': ['core/SIFStrategyVault.sol', 'SIFStrategyVault'], 'vault:s3': ['core/SIFStrategyVault.sol', 'SIFStrategyVault'],
  'mod:s1:bond': ['modules/BondInvestmentModule.sol', 'BondInvestmentModule'], 'mod:s1:calls': ['modules/CoveredCallModule.sol', 'CoveredCallModule'],
  'mod:s1:tactical': ['modules/TacticalSleeveModule.sol', 'TacticalSleeveModule'], 'mod:s2:allocator': ['modules/AssetAllocatorModule.sol', 'AssetAllocatorModule'],
  'mod:s3:calls': ['modules/CoveredCallModule.sol', 'CoveredCallModule'],
}
for (const s of ['dBTC', 'dETH', 'dSOL', 'dXAU', 'dXAG', 'dCOPR', 'dTBILL']) SRC[`token:${s}`] = ['demo/DemoERC20.sol', 'DemoERC20']

const addrOf = (key: string): string | undefined => {
  if (key in dep.contracts) return dep.contracts[key]
  if (key.startsWith('token:')) return dep.tokens[key.slice(6)]?.address
  const m = key.match(/^vault:(s\d)$/)
  if (m) return dep.strategies[m[1]].vault
  const mm = key.match(/^mod:(s\d):(\w+)$/)
  if (mm) return dep.strategies[mm[1]].modules[mm[2]]
  return undefined
}

const results: Record<string, string> = {}
for (const [key, [file, name]] of Object.entries(SRC)) {
  const address = addrOf(key)
  const txHash = dep.txs[`deploy:${key}`]
  if (!address || !txHash) { results[key] = 'skipped (no address)'; continue }
  try {
    const tx = await publicClient.getTransaction({ hash: txHash as Hex })
    const art = loadArtifact(name)
    const args = tx.input.length > art.bytecode.length ? (`0x${tx.input.slice(art.bytecode.length)}`) : '0x'
    const out = execFileSync('forge', ['verify-contract', address, `contracts/${file}:${name}`, '--verifier', 'blockscout', '--verifier-url', apiUrl, '--chain-id', String(CHAIN_ID), '--constructor-args', args, '--compiler-version', '0.8.28', '--num-of-optimizations', '200', '--evm-version', 'cancun'], { cwd: ROOT, timeout: 120_000, encoding: 'utf8' })
    results[key] = out.split('\n').filter(Boolean).slice(-2).join(' | ').slice(0, 200)
  } catch (e) {
    results[key] = `failed: ${String((e as Error).message).split('\n').filter(Boolean).slice(-1)[0]?.slice(0, 160)}`
  }
  console.log(key, results[key])
}
writeFileSync(resolve(ROOT, 'deployments/verification.json'), JSON.stringify(results, null, 2))
