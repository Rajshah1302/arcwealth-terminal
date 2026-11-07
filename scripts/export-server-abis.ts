// Bundles ABIs used by the backend into deployments/abis.json so deployed environments need no Foundry output.
import { writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { ROOT, loadArtifact } from '../server/chain'

const names = ['DemoPriceOracle', 'SIFStrategyVault', 'CoveredCallModule', 'BondInvestmentModule', 'TacticalSleeveModule', 'AssetAllocatorModule', 'StrategyManager', 'DemoOptionsCounterparty',
  'InvestorVault', 'DemoBondIssuer', 'DemoLendingPool', 'DemoERC20', 'RiskManager', 'DemoSwapRouter', 'ArcWealthTimelock']
const out: Record<string, unknown> = {}
for (const n of names) out[n] = loadArtifact(n).abi
writeFileSync(resolve(ROOT, 'deployments/abis.json'), JSON.stringify(out))
console.log('abis bundled', names.length)
