// Deploys and seeds ARCWEALTH on Arc Testnet. Resumable: progress is stored in deployments/.progress.json.
// Run: bun run scripts/deploy-arcwealth.ts
import { encodeDeployData, getAddress, keccak256, parseUnits, toBytes, type Abi, type Hex } from 'viem'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { getUsdc } from '../src/onchain-facts'
import { MARKET } from '../src/shared/market'
import { STRATEGIES, configHash, disclosureHash } from '../src/shared/strategies'
import { CHAIN_ID, ROOT, arcTestnet, fees, keeperAccount, loadArtifact, publicClient, walletFor, writeAndWait, type Deployments } from '../server/chain'

const USDC = getUsdc(CHAIN_ID)!.address as Hex
const wallet = walletFor()
const me = keeperAccount().address

// Reserves funded from the deployer's faucet USDC (testnet, no monetary value). Override via env.
const R = (k: string, d: string) => parseUnits(process.env[k] ?? d, 6)
const ROUTER_RESERVE = R('ROUTER_RESERVE_USDC', '10')
const BOND_RESERVE = R('BOND_RESERVE_USDC', '3')
const CP_RESERVE = R('CP_RESERVE_USDC', '10')

mkdirSync(resolve(ROOT, 'deployments'), { recursive: true })
const progressPath = resolve(ROOT, 'deployments/.progress.json')
type Progress = { addr: Record<string, string>; done: Record<string, string> }
const progress: Progress = existsSync(progressPath) ? (JSON.parse(readFileSync(progressPath, 'utf8')) as Progress) : { addr: {}, done: {} }
const save = () => writeFileSync(progressPath, JSON.stringify(progress, null, 2))

const abis: Record<string, Abi> = {}
const abiOf = (n: string) => (abis[n] ??= loadArtifact(n).abi)

async function deploy(key: string, contract: string, args: unknown[] = []): Promise<Hex> {
  if (progress.addr[key]) return progress.addr[key] as Hex
  const art = loadArtifact(contract)
  const data = encodeDeployData({ abi: art.abi, bytecode: art.bytecode, args })
  const f = await fees()
  const hash = await wallet.sendTransaction({ data, ...f, account: wallet.account!, chain: arcTestnet, to: undefined })
  const rc = await publicClient.waitForTransactionReceipt({ hash, timeout: 90_000 })
  if (rc.status !== 'success' || !rc.contractAddress) throw new Error(`deploy ${key} failed (${hash})`)
  await waitCode(rc.contractAddress)
  progress.addr[key] = rc.contractAddress
  progress.done[`deploy:${key}`] = hash
  save()
  console.log('deployed', key, rc.contractAddress)
  return rc.contractAddress
}

async function call(id: string, contract: string, to: Hex, fn: string, args: unknown[] = []) {
  if (progress.done[id]) return
  let hash: Hex = '0x'
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      hash = (await writeAndWait(wallet, { address: to, abi: abiOf(contract), functionName: fn, args })).hash
      break
    } catch (e) {
      const msg = String((e as Error).message)
      if (attempt === 4 || !/no data|not found|-32014|nonce|replacement|timed out|fetch/i.test(msg)) throw e
      await sleep(1500)
    }
  }
  progress.done[id] = hash
  save()
  console.log('tx', id)
}

// role ids are keccak256 of the role name (OpenZeppelin AccessControl); no RPC read needed
const role = (_contract: string, _to: Hex, name: string): Hex => keccak256(toBytes(name))
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
async function waitCode(addr: Hex) {
  for (let i = 0; i < 20; i++) {
    const code = await publicClient.getCode({ address: addr })
    if (code && code !== '0x') return
    await sleep(1000)
  }
  throw new Error(`no code at ${addr}`)
}

async function main() {
  const bal = (await publicClient.readContract({ address: USDC, abi: loadArtifact('DemoERC20').abi, functionName: 'balanceOf', args: [me] })) as bigint
  console.log('deployer', me, 'USDC (ERC-20 view, 6 dec):', bal)
  const need = ROUTER_RESERVE + BOND_RESERVE + CP_RESERVE + parseUnits('3', 6)
  if (bal < need) throw new Error(`need about ${Number(need) / 1e6} USDC, have ${Number(bal) / 1e6}`)

  // ---------------- demo layer ----------------
  const oracle = await deploy('oracle', 'DemoPriceOracle', [me, me])
  const router = await deploy('router', 'DemoSwapRouter', [USDC, oracle, me])
  const tokens: Record<string, Hex> = {}
  for (const m of MARKET.filter((x) => x.kind === 'demo')) {
    const faucet = parseUnits(((m.faucetUsd ?? 25) / m.base).toFixed(8), m.decimals)
    tokens[m.symbol] = await deploy(`token:${m.symbol}`, 'DemoERC20', [m.name, m.symbol, m.decimals, me, faucet])
    await call(`minter:${m.symbol}`, 'DemoERC20', tokens[m.symbol], 'grantRole', [role('DemoERC20', tokens[m.symbol], 'MINTER_ROLE'), router])
  }
  await call('router:manager', 'DemoSwapRouter', router, 'grantRole', [role('DemoSwapRouter', router, 'MANAGER_ROLE'), me])
  for (const s of Object.keys(tokens)) await call(`router:reg:${s}`, 'DemoSwapRouter', router, 'registerToken', [tokens[s]])
  // initial oracle prices (8 decimals USD); live tokens get reference prices for the lending pool and Trading page
  const priceTokens: Record<string, Hex> = { ...tokens }
  for (const m of MARKET.filter((x) => x.kind === 'live' && x.address)) priceTokens[m.symbol] = getAddress(m.address!)
  const syms = Object.keys(priceTokens)
  const prices = syms.map((s) => BigInt(Math.round(MARKET.find((m) => m.symbol === s)!.base * 1e8)))
  await call('oracle:prices', 'DemoPriceOracle', oracle, 'setPrices', [syms.map((s) => priceTokens[s]), prices])

  const usdcAbi = loadArtifact('DemoERC20').abi
  const approveFund = async (id: string, to: Hex, contract: string, amount: bigint) => {
    if (progress.done[id]) return
    await writeAndWait(wallet, { address: USDC, abi: usdcAbi, functionName: 'approve', args: [to, amount] })
    await call(id, contract, to, 'fundReserve', [amount])
  }
  await approveFund('router:fund', router, 'DemoSwapRouter', ROUTER_RESERVE)

  const issuer = await deploy('issuer', 'DemoBondIssuer', [USDC, me])
  await call('issuer:manager', 'DemoBondIssuer', issuer, 'grantRole', [role('DemoBondIssuer', issuer, 'MANAGER_ROLE'), me])
  const now = BigInt(Math.floor(Date.now() / 1000))
  const day = 86400n
  const series = [
    ['Arc Treasury Note 14d', 'AAA', 650, 14n],
    ['Arc Corporate Note 45d', 'AA', 725, 45n],
    ['Arc High-Yield Note 90d', 'BBB', 800, 90n],
  ] as const
  for (const [i, s] of series.entries()) await call(`issuer:series${i}`, 'DemoBondIssuer', issuer, 'createSeries', [s[0], s[1], s[2], now + s[3] * day + (s[3] === 90n ? -7200n : 7200n)])
  await approveFund('issuer:fund', issuer, 'DemoBondIssuer', BOND_RESERVE)

  const cp = await deploy('counterparty', 'DemoOptionsCounterparty', [USDC, me])
  await call('cp:router', 'DemoOptionsCounterparty', cp, 'setRouter', [router])
  await approveFund('cp:fund', cp, 'DemoOptionsCounterparty', CP_RESERVE)

  const lending = await deploy('lending', 'DemoLendingPool', [USDC, oracle, me])
  const cirBtc = priceTokens['cirBTC']
  await call('lending:collateral', 'DemoLendingPool', lending, 'registerCollateral', [cirBtc])

  // ---------------- core ----------------
  const risk = await deploy('risk', 'RiskManager', [me])
  const sm = await deploy('strategyManager', 'StrategyManager', [me])
  const iv = await deploy('investorVault', 'InvestorVault', [me])
  await call('sm:manager', 'StrategyManager', sm, 'grantRole', [role('StrategyManager', sm, 'MANAGER_ROLE'), me])
  await call('sm:keeper', 'StrategyManager', sm, 'grantRole', [role('StrategyManager', sm, 'KEEPER_ROLE'), me])

  const out: Deployments = {
    chainId: CHAIN_ID,
    network: 'Arc Testnet',
    deployer: me,
    deployedAt: new Date().toISOString(),
    contracts: { USDC, oracle, router, issuer, counterparty: cp, lending, riskManager: risk, strategyManager: sm, investorVault: iv },
    strategies: {},
    tokens: {},
    txs: progress.done,
  }
  for (const m of MARKET) out.tokens[m.symbol] = { address: priceTokens[m.symbol] ?? tokens[m.symbol] ?? '', decimals: m.decimals, tier: m.tier }
  out.tokens['EURC'] = { address: getAddress(MARKET.find((m) => m.symbol === 'EURC')!.address!), decimals: 6, tier: 'LIVE-TESTNET' }

  const sw = (symbols: string[]) => symbols.map((s) => tokens[s])
  for (const meta of STRATEGIES) {
    const k = meta.id
    const vault = await deploy(`vault:${k}`, 'SIFStrategyVault', [USDC, `ARCWEALTH ${meta.short} ${meta.name}`, meta.symbol, me, me, iv, risk, sm])
    const modules: Record<string, Hex> = {}
    let weights: number[] = []
    let callLimits: { minStrikeBps: number; maxStrikeBps: number } | undefined
    if (k === 's1') {
      modules.bond = await deploy('mod:s1:bond', 'BondInvestmentModule', [USDC, vault, issuer, [0n, 1n, 2n]])
      modules.calls = await deploy('mod:s1:calls', 'CoveredCallModule', [USDC, vault, router, oracle, cp, risk, sw(['dBTC', 'dETH']), [5000, 5000]])
      modules.tactical = await deploy('mod:s1:tactical', 'TacticalSleeveModule', [USDC, vault, router, oracle, sm, tokens['dTBILL']])
      weights = [4000, 4000, 2000]
      callLimits = { minStrikeBps: 9000, maxStrikeBps: 9800 }
    } else if (k === 's2') {
      modules.allocator = await deploy('mod:s2:allocator', 'AssetAllocatorModule', [USDC, vault, router, oracle, sm, risk, sw(['dXAU', 'dXAG', 'dCOPR'])])
      weights = [10000]
    } else {
      modules.calls = await deploy('mod:s3:calls', 'CoveredCallModule', [USDC, vault, router, oracle, cp, risk, sw(['dBTC', 'dETH', 'dSOL']), [4000, 3000, 3000]])
      weights = [10000]
      callLimits = { minStrikeBps: 9500, maxStrikeBps: 11000 }
    }
    const order = Object.values(modules)
    for (const [i, m] of order.entries()) await call(`vault:${k}:addModule${i}`, 'SIFStrategyVault', vault, 'addModule', [m])
    await call(`iv:reg:${k}`, 'InvestorVault', iv, 'registerStrategy', [vault, disclosureHash(meta)])
    await call(`risk:limits:${k}`, 'RiskManager', risk, 'setLimits', [vault, parseUnits('10', 6), parseUnits('1000', 6), parseUnits('250', 6), 1000])
    // sleeve bands: +/-10pp around target for multi-sleeve strategies, fixed for single-sleeve
    for (const [i, w] of weights.entries()) {
      const lo = weights.length === 1 ? 9000 : Math.max(0, w - 1000)
      const hi = weights.length === 1 ? 10000 : Math.min(10000, w + 1000)
      await call(`risk:band:${k}:${i}`, 'RiskManager', risk, 'setSleeveBand', [vault, i, lo, hi])
    }
    if (callLimits) {
      const cc = modules.calls
      await call(`risk:calls:${k}`, 'RiskManager', risk, 'setCallLimits', [cc, { minExpiry: 7 * 86400, maxExpiry: 30 * 86400, maxShortsPerAsset: 3, ...callLimits, maxPremiumBps: 1500 }])
      await call(`cp:module:${k}`, 'DemoOptionsCounterparty', cp, 'grantRole', [role('DemoOptionsCounterparty', cp, 'MODULE_ROLE'), cc])
    }
    if (k === 's2') {
      const maxes = { dXAU: 7000, dXAG: 4000, dCOPR: 3000 } as const
      for (const s of ['dXAU', 'dXAG', 'dCOPR'] as const) await call(`risk:asset:${s}`, 'RiskManager', risk, 'setAssetMaxBps', [vault, tokens[s], maxes[s]])
      await call('sm:noOptions:dCOPR', 'StrategyManager', sm, 'setNoOptions', [tokens['dCOPR'], true])
    }
    await call(`sm:reg:${k}`, 'StrategyManager', sm, 'registerStrategy', [vault, `${meta.short} ${meta.name}`, weights, configHash(meta)])
    if (k === 's2') {
      await call('sm:assets:s2', 'StrategyManager', sm, 'setAssetWeights', [vault, sw(['dXAU', 'dXAG', 'dCOPR']), [5000, 3000, 2000], configHash(meta), 'initial weights'])
      for (const s of ['dXAU', 'dXAG']) await call(`sm:opt:${s}`, 'StrategyManager', sm, 'setOptionsAvailable', [vault, tokens[s], true])
    }
    for (const r of ['MANAGER_ROLE', 'KEEPER_ROLE', 'PAUSER_ROLE']) await call(`vault:${k}:${r}`, 'SIFStrategyVault', vault, 'grantRole', [role('SIFStrategyVault', vault, r), me])
    out.strategies[k] = { vault, modules, disclosureHash: disclosureHash(meta), configHash: configHash(meta) }
  }

  // ---------------- keeper roles on demo contracts ----------------
  await call('cp:keeper', 'DemoOptionsCounterparty', cp, 'grantRole', [role('DemoOptionsCounterparty', cp, 'KEEPER_ROLE'), me])

  // ---------------- timelock handover ----------------
  const tl = await deploy('timelock', 'ArcWealthTimelock', [600n, [me], [me], '0x0000000000000000000000000000000000000000'])
  out.contracts.timelock = tl
  const admin: Hex = '0x0000000000000000000000000000000000000000000000000000000000000000'
  const adminTargets: [string, string, Hex][] = [
    ['DemoPriceOracle', 'oracle', oracle], ['DemoSwapRouter', 'router', router], ['DemoBondIssuer', 'issuer', issuer],
    ['DemoOptionsCounterparty', 'cp', cp], ['DemoLendingPool', 'lending', lending], ['RiskManager', 'risk', risk],
    ['StrategyManager', 'sm', sm], ['InvestorVault', 'iv', iv],
    ...STRATEGIES.map((s) => ['SIFStrategyVault', `vault:${s.id}`, out.strategies[s.id].vault as Hex] as [string, string, Hex]),
    ...Object.entries(tokens).map(([s, a]) => ['DemoERC20', `token:${s}`, a] as [string, string, Hex]),
  ]
  for (const [c, id, a] of adminTargets) {
    await call(`handover:grant:${id}`, c, a, 'grantRole', [admin, tl])
    await call(`handover:renounce:${id}`, c, a, 'renounceRole', [admin, me])
  }
  out.txs = progress.done
  writeFileSync(resolve(ROOT, 'deployments/arc-testnet.json'), JSON.stringify(out, null, 2))
  console.log('done. deployments/arc-testnet.json written')
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
