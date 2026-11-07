// REST API (see docs/API.md). Reads chain state directly; never signs for users.
import { getAddress, isAddress, type Abi, type Hex } from 'viem'
import { blackScholesCall, MARKET } from '../src/shared/market'
import { STRATEGIES, STRATEGY_BY_ID } from '../src/shared/strategies'
import { runBacktests } from './backtest'
import { loadArtifact, loadDeployments, publicClient, ROOT } from './chain'
import { sql } from './db'
import { indexerStatus } from './indexer'
import { keeperAddress } from './keepers'
import { allSeries, change24h, getSeries, historyFor, priceOf, vol30d } from './prices'

const dep = loadDeployments()
const ab = (n: string): Abi => loadArtifact(n).abi
const A = { vault: ab('SIFStrategyVault'), iv: ab('InvestorVault'), issuer: ab('DemoBondIssuer'), cc: ab('CoveredCallModule'), sm: ab('StrategyManager'), tac: ab('TacticalSleeveModule'), oracle: ab('DemoPriceOracle'), lending: ab('DemoLendingPool') }
const rd = <T>(address: string, abi: Abi, functionName: string, args: unknown[] = []) => publicClient.readContract({ address: address as Hex, abi, functionName, args }) as Promise<T>
const ser = (v: unknown): unknown => JSON.parse(JSON.stringify(v, (_k, x) => (typeof x === 'bigint' ? x.toString() : x)))
const backtests = runBacktests()

const headers = { 'content-type': 'application/json', 'access-control-allow-origin': '*', 'access-control-allow-headers': 'content-type' }
const json = (body: unknown, status = 200) => new Response(JSON.stringify(ser(body)), { status, headers })
const err = (status: number, message: string) => json({ error: message }, status)
const num = (b: bigint, d: number) => Number(b) / 10 ** d

async function strategyLive(id: string) {
  const s = dep.strategies[id]
  const vault = s.vault
  const [assets, supply, idle, price, breakdown] = await Promise.all([
    rd<bigint>(vault, A.vault, 'totalAssets'), rd<bigint>(vault, A.vault, 'totalSupply'), rd<bigint>(vault, A.vault, 'idle'),
    rd<bigint>(vault, A.vault, 'sharePrice'), rd<[string[], bigint[]]>(vault, A.vault, 'moduleBreakdown'),
  ])
  return {
    vault, tier: 'DEMO-ONCHAIN', navUsdc: num(assets, 6), shares: num(supply, 12), idleUsdc: num(idle, 6), sharePrice: num(price, 6),
    modules: breakdown[0].map((m, i) => ({ module: m, valueUsdc: num(breakdown[1][i], 6) })),
  }
}

async function strategyDetail(id: string) {
  const meta = STRATEGY_BY_ID[id]
  const st = dep.strategies[id]
  const live = await strategyLive(id)
  const out: Record<string, unknown> = { meta, live, backtest: backtests[id], disclosureHash: st.disclosureHash, configHash: st.configHash, modules: st.modules }
  const regime = await rd<number>(dep.contracts.strategyManager, A.sm, 'currentRegime')
  out.regime = { id: Number(regime), name: ['Risk-off', 'High vol', 'Normal', 'Calm'][Number(regime)], vol30dPct: vol30d('dBTC') * 100, tier: 'SIMULATED-OFFCHAIN' }
  if (st.modules.bond) {
    const n = Number(await rd<bigint>(dep.contracts.issuer, A.issuer, 'seriesCount'))
    const bonds = []
    for (let i = 0; i < n; i++) {
      const [name, rating, couponBps, issuedAt, maturity, active] = await rd<[string, string, number, bigint, bigint, boolean]>(dep.contracts.issuer, A.issuer, 'seriesInfo', [BigInt(i)])
      const [units, pending] = await Promise.all([
        rd<bigint>(dep.contracts.issuer, A.issuer, 'unitsOf', [BigInt(i), st.modules.bond]), rd<bigint>(dep.contracts.issuer, A.issuer, 'pendingCoupon', [BigInt(i), st.modules.bond]),
      ])
      bonds.push({ id: i, name, rating, couponPct: Number(couponBps) / 100, issuedAt: Number(issuedAt), maturity: Number(maturity), active, unitsUsdc: num(units, 6), accruedUsdc: num(pending, 6), tier: 'DEMO-ONCHAIN' })
    }
    out.bonds = bonds
  }
  const ccAddr = st.modules.calls
  if (ccAddr) {
    const n = Number(await rd<bigint>(ccAddr, A.cc, 'callCount'))
    const calls = []
    for (let i = Math.max(0, n - 20); i < n; i++) {
      const c = await rd<{ underlying: string; qty: bigint; strike: bigint; expiry: bigint; premium: bigint; counterparty: string; status: number }>(ccAddr, A.cc, 'getCall', [BigInt(i)])
      const sym = Object.entries(dep.tokens).find(([, t]) => t.address.toLowerCase() === c.underlying.toLowerCase())?.[0] ?? 'unknown'
      const spot = priceOf(sym)
      const T = Math.max(0, (Number(c.expiry) - Date.now() / 1000) / (365 * 86400))
      const bs = blackScholesCall(spot, num(c.strike, 8), T, 0.045, Math.max(0.1, vol30d(sym)))
      calls.push({ id: i, underlying: sym, qty: num(c.qty, 18), strike: num(c.strike, 8), expiry: Number(c.expiry), premiumUsdc: num(c.premium, 6), counterparty: c.counterparty, status: ['Open', 'Assigned', 'Expired'][c.status], mtmUsdc: c.status === 0 ? bs.price * num(c.qty, 18) : 0, delta: c.status === 0 ? bs.delta : 0, tier: 'DEMO-ONCHAIN' })
    }
    out.calls = calls
  }
  if (st.modules.tactical) {
    const [cash, tbill, puts] = await rd<[number, number, number]>(dep.contracts.strategyManager, A.sm, 'tacticalAllocation', [st.vault])
    out.tactical = { cashBps: Number(cash), tbillBps: Number(tbill), putsBps: Number(puts), note: 'puts are reserved USDC collateral; SLBM is a placeholder' }
  }
  return out
}

async function portfolio(address: string) {
  const positions = []
  for (const meta of STRATEGIES) {
    const vault = dep.strategies[meta.id].vault
    const [shares, pos, price] = await Promise.all([
      rd<bigint>(vault, A.vault, 'balanceOf', [address]), rd<[bigint, bigint, bigint]>(dep.contracts.investorVault, A.iv, 'positionOf', [address, vault]), rd<bigint>(vault, A.vault, 'sharePrice'),
    ])
    const pending = await rd<bigint>(vault, A.vault, 'pendingRedeem', [address])
    const claimable = await rd<bigint>(vault, A.vault, 'claimable', [address])
    if (shares === 0n && pos[0] === 0n && pending === 0n && claimable === 0n) continue
    const value = num(await rd<bigint>(vault, A.vault, 'convertToAssets', [shares]), 6)
    const basis = num(pos[0], 6)
    positions.push({
      strategy: meta.id, name: meta.name, vault, shares: num(shares, 12), costBasisUsdc: basis, valueUsdc: value,
      sharePrice: num(price, 6), entrySharePrice: pos[1] > 0n ? basis / num(pos[1], 12) : 0, pnlUsdc: value - basis, totalReturnPct: basis > 0 ? (value / basis - 1) * 100 : 0,
      pendingRedeemShares: num(pending, 12), claimableUsdc: num(claimable, 6), tier: 'DEMO-ONCHAIN',
    })
  }
  return { address, positions }
}

async function events(params: URLSearchParams) {
  const limit = Math.min(200, Number(params.get('limit') ?? 50))
  const emitter = params.get('emitter')?.toLowerCase()
  const account = params.get('account')?.toLowerCase()
  const rows = await sql`SELECT tx_hash, log_index, block_number, block_time, emitter, event_name, args FROM chain_events
    WHERE (${emitter ?? null}::text IS NULL OR emitter = ${emitter ?? ''}) AND (${account ?? null}::text IS NULL OR lower(args::text) LIKE ${'%' + (account ?? '') + '%'})
    ORDER BY block_number DESC, log_index DESC LIMIT ${limit}`
  return rows
}

export async function handle(req: Request): Promise<Response> {
  const url = new URL(req.url)
  const p = url.pathname.replace(/^\/api/, '')
  if (req.method === 'OPTIONS') return json({})
  try {
    if (p === '/health') {
      const head = await publicClient.getBlockNumber()
      const [, updated] = await rd<[bigint, bigint]>(dep.contracts.oracle, A.oracle, 'getPriceUnsafe', [dep.tokens.dBTC.address])
      return json({ ok: true, chainId: dep.chainId, head, indexerBlock: await indexerStatus(), keeperAddress: keeperAddress(), priceAgeSec: Math.floor(Date.now() / 1000) - Number(updated) })
    }
    if (p === '/deployments') return json(dep)
    if (p === '/prices') {
      return json(allSeries().map((s) => ({ symbol: s.asset.symbol, name: s.asset.name, price: s.price, change24hPct: change24h(s.asset.symbol), assetTier: s.asset.tier, tier: 'SIMULATED-OFFCHAIN', note: 'Simulated reference prices', address: dep.tokens[s.asset.symbol]?.address, decimals: s.asset.decimals })))
    }
    let m = p.match(/^\/prices\/([A-Za-z]+)\/history$/)
    if (m) {
      if (!getSeries(m[1])) return err(404, 'unknown symbol')
      return json({ symbol: m[1], tier: 'SIMULATED-OFFCHAIN', points: historyFor(m[1], Math.min(365, Number(url.searchParams.get('days') ?? 365))) })
    }
    if (p === '/strategies') {
      const out = []
      for (const meta of STRATEGIES) out.push({ meta, live: await strategyLive(meta.id), backtest: backtests[meta.id] })
      return json(out)
    }
    m = p.match(/^\/strategies\/(s[123])$/)
    if (m) return json(await strategyDetail(m[1]))
    m = p.match(/^\/strategies\/(s[123])\/nav$/)
    if (m) {
      const rows = await sql`SELECT ts, nav_usdc, share_price, idle_usdc FROM nav_snapshots WHERE strategy_id = ${m[1]} ORDER BY ts DESC LIMIT 500`
      return json({ tier: 'DEMO-ONCHAIN', points: [...rows].reverse() })
    }
    if (p === '/events') return json(await events(url.searchParams))
    m = p.match(/^\/portfolio\/(0x[0-9a-fA-F]{40})$/)
    if (m) return json(await portfolio(getAddress(m[1])))
    m = p.match(/^\/history\/(0x[0-9a-fA-F]{40})$/)
    if (m) {
      const a = m[1].toLowerCase()
      const rows = await sql`SELECT tx_hash, log_index, block_number, block_time, emitter, event_name, args FROM chain_events WHERE lower(args::text) LIKE ${'%' + a + '%'} ORDER BY block_number DESC, log_index DESC LIMIT 200`
      return json(rows.map((r: Record<string, unknown>) => ({ ...r, tier: r.event_name === 'Transfer' ? 'LIVE-TESTNET' : 'DEMO-ONCHAIN' })))
    }
    if (p === '/strategy-events') {
      const rows = await sql`SELECT id, strategy_id, kind, detail, tx_hash, created_at FROM strategy_events ORDER BY id DESC LIMIT ${Math.min(200, Number(url.searchParams.get('limit') ?? 50))}`
      return json(rows)
    }
    if (p === '/admin/history') {
      const audit = await sql`SELECT id, actor, action, reason, before, after, tx_hash, created_at FROM audit_log ORDER BY id DESC LIMIT 100`
      const cfg = await sql`SELECT tx_hash, block_number, block_time, emitter, args FROM chain_events WHERE event_name = 'StrategyConfigChanged' ORDER BY block_number DESC LIMIT 100`
      return json({ audit, configChanges: cfg })
    }
    if (p === '/admin/audit' && req.method === 'POST') {
      const b = (await req.json()) as { actor?: string; action?: string; reason?: string; before?: unknown; after?: unknown; txHash?: string }
      if (!b.actor || !isAddress(b.actor) || !b.action || !b.txHash) return err(400, 'actor, action and txHash required')
      const rc = await publicClient.getTransactionReceipt({ hash: b.txHash as Hex }).catch(() => null)
      if (!rc || rc.status !== 'success' || rc.from.toLowerCase() !== b.actor.toLowerCase()) return err(400, 'tx receipt does not verify actor')
      await sql`INSERT INTO audit_log (actor, action, reason, before, after, tx_hash) VALUES (${b.actor}, ${b.action}, ${b.reason ?? null}, ${JSON.stringify(b.before ?? null)}::jsonb, ${JSON.stringify(b.after ?? null)}::jsonb, ${b.txHash})`
      return json({ ok: true })
    }
    if (p === '/lending/markets') {
      const [util, sup, bor] = await Promise.all([rd<bigint>(dep.contracts.lending, A.lending, 'utilisation'), rd<bigint>(dep.contracts.lending, A.lending, 'supplyApr'), rd<bigint>(dep.contracts.lending, A.lending, 'borrowApr')])
      return json({ tier: 'DEMO-ONCHAIN', pool: dep.contracts.lending, utilisationPct: Number(util) / 1e16, supplyAprPct: Number(sup) / 1e16, borrowAprPct: Number(bor) / 1e16, ltvPct: 70, liquidationPct: 80, note: 'Demo yield (testnet, no monetary value)', collateral: ['cirBTC'] })
    }
    if (p === '/market') return json(MARKET.map((x) => ({ symbol: x.symbol, name: x.name, kind: x.kind, tier: x.tier, decimals: x.decimals, address: dep.tokens[x.symbol]?.address })))
    void ROOT
    return err(404, 'not found')
  } catch (e) {
    return err(500, String((e as Error).message).split('\n')[0].slice(0, 300))
  }
}
