// Keepers: prices, regime, covered-call writing/settlement, coupons, tactical/allocator rebalances, NAV snapshots, redeem fulfilment.
// All txs are EIP-1559 type 2 with maxFeePerGas >= 20 gwei (see chain.ts). Keepers never move investor funds: they only call role-gated vault/module functions.
import { erc20Abi, type Abi, type Hex } from 'viem'
import { blackScholesCall } from '../src/shared/market'
import { STRATEGIES } from '../src/shared/strategies'
import { keeperAccount, loadArtifact, loadDeployments, publicClient, walletFor, writeAndWait, type Deployments } from './chain'
import { logEvent, sql } from './db'
import { priceOf, trendUp, vol30d } from './prices'

const dep: Deployments = loadDeployments()
let walletInstance: ReturnType<typeof walletFor> | undefined
const wallet = () => (walletInstance ??= walletFor())
const abi = (n: string): Abi => loadArtifact(n).abi
const A = {
  oracle: abi('DemoPriceOracle'), vault: abi('SIFStrategyVault'), cc: abi('CoveredCallModule'), bond: abi('BondInvestmentModule'),
  tac: abi('TacticalSleeveModule'), alloc: abi('AssetAllocatorModule'), sm: abi('StrategyManager'), cp: abi('DemoOptionsCounterparty'),
}
const USDC = dep.contracts.USDC as Hex
const oracle = dep.contracts.oracle as Hex
const ONE = 10n ** 8n

async function send(label: string, address: string, a: Abi, fn: string, args: unknown[], strategyId?: string) {
  try {
    const { hash } = await writeAndWait(wallet(), { address: address as Hex, abi: a, functionName: fn, args })
    await logEvent(label, { fn, args }, strategyId, hash)
    return hash
  } catch (e) {
    const msg = String((e as Error).message).split('\n')[0].slice(0, 300)
    await logEvent('error', { label, fn, msg }, strategyId)
    console.warn('[keeper]', label, fn, msg)
    return undefined
  }
}

const read = <T>(address: string, a: Abi, functionName: string, args: unknown[] = []) =>
  publicClient.readContract({ address: address as Hex, abi: a, functionName, args }) as Promise<T>

const tokenAddr = (sym: string) => dep.tokens[sym].address as Hex

// ---------------- prices ----------------
export async function postPrices() {
  const syms = Object.keys(dep.tokens).filter((s) => s !== 'EURC' || dep.tokens[s].address)
  const toks: Hex[] = []
  const vals: bigint[] = []
  for (const s of syms) {
    const target = BigInt(Math.round(priceOf(s) * 1e8))
    if (target === 0n) continue
    let next = target
    try {
      const [cur] = await read<[bigint, bigint]>(oracle, A.oracle, 'getPriceUnsafe', [tokenAddr(s)])
      if (cur > 0n) {
        const hi = (cur * 109n) / 100n // stay inside the oracle 10% step limit
        const lo = (cur * 91n) / 100n
        next = target > hi ? hi : target < lo ? lo : target
      }
    } catch {
      /* first price: any value */
    }
    toks.push(tokenAddr(s))
    vals.push(next)
  }
  const hash = await send('price', oracle, A.oracle, 'setPrices', [toks, vals])
  if (hash) {
    const now = new Date()
    for (const [i, s] of syms.entries()) {
      await sql`INSERT INTO price_history (symbol, ts, price) VALUES (${s}, ${now}, ${Number(vals[i]) / 1e8}) ON CONFLICT DO NOTHING`
    }
  }
}

export async function postRegime() {
  const vol = Math.round(vol30d('dBTC') * 100)
  await send('regime', dep.contracts.strategyManager, A.sm, 'postRegimeInputs', [vol, trendUp('dBTC'), 450, 1000])
}

// ---------------- covered calls ----------------
async function writeCalls(strategyId: string, module: Hex, otmBps: bigint, underlyings: string[]) {
  const cpLiquidity = await read<bigint>(dep.contracts.counterparty, A.cp, 'availableLiquidity')
  for (const sym of underlyings) {
    const token = tokenAddr(sym)
    const [bal, short, count] = await Promise.all([
      read<bigint>(token, erc20Abi, 'balanceOf', [module]),
      read<bigint>(module, A.cc, 'openShortQty', [token]),
      read<bigint>(module, A.cc, 'openShortCount', [token]),
    ])
    const unlocked = bal > short ? bal - short : 0n
    const [spot8] = await read<[bigint, bigint]>(oracle, A.oracle, 'getPriceUnsafe', [token])
    const notional = (unlocked * spot8) / 10n ** 20n // USDC 6 dec
    if (notional < 1_000_000n || count >= 3n) continue
    const strike8 = (spot8 * otmBps) / 10_000n
    const T = (7 * 86400 + 7200) / (365 * 86400)
    const bs = blackScholesCall(Number(spot8) / 1e8, Number(strike8) / 1e8, T, 0.045, Math.max(0.1, vol30d(sym)))
    const qtyFloat = Number(unlocked) / 1e18
    let premium = BigInt(Math.floor(bs.price * qtyFloat * 1e6))
    const cap = (notional * 1400n) / 10_000n
    if (premium > cap) premium = cap
    if (premium + 500_000n > cpLiquidity) {
      await logEvent('error', { label: 'writeCall', msg: 'counterparty liquidity too low', premium: premium.toString(), cpLiquidity: cpLiquidity.toString() }, strategyId)
      continue
    }
    const expiry = BigInt(Math.floor(Date.now() / 1000) + 7 * 86400 + 7200)
    await send('call-written', module, A.cc, 'writeCall', [token, unlocked, strike8, expiry, premium], strategyId)
  }
}

async function settleCalls(strategyId: string, module: Hex) {
  const n = Number(await read<bigint>(module, A.cc, 'callCount'))
  const now = BigInt(Math.floor(Date.now() / 1000))
  for (let id = 0; id < n; id++) {
    const c = await read<{ expiry: bigint; status: number }>(module, A.cc, 'getCall', [BigInt(id)])
    if (c.status === 0 && c.expiry < now) await send('call-settled', module, A.cc, 'settle', [BigInt(id)], strategyId)
  }
}

// ---------------- per-strategy upkeep ----------------
export async function upkeep() {
  for (const meta of STRATEGIES) {
    const st = dep.strategies[meta.id]
    if (!st) continue
    const vault = st.vault as Hex
    const m = st.modules
    for (const addr of [m.calls, m.tactical, m.allocator]) if (addr) await send('checkpoint', addr, A.cc, 'refreshCheckpoint', [], meta.id)
    if (m.calls) {
      await writeCalls(meta.id, m.calls as Hex, meta.id === 's3' ? 10_300n : 9_500n, meta.id === 's3' ? ['dBTC', 'dETH', 'dSOL'] : ['dBTC', 'dETH'])
      await settleCalls(meta.id, m.calls as Hex)
    }
    if (m.bond) {
      await send('coupons', m.bond, A.bond, 'claimCoupons', [], meta.id)
      await send('roll', m.bond, A.bond, 'rollMatured', [], meta.id)
    }
    if (m.tactical) await send('tactical', m.tactical, A.tac, 'rebalanceTactical', [], meta.id)
    if (m.allocator) await send('allocator', m.allocator, A.alloc, 'rebalance', [], meta.id)
    await fulfilRedeems(meta.id, vault)
    await snapshot(meta.id, vault)
  }
}

async function fulfilRedeems(strategyId: string, vault: Hex) {
  const rows = await sql`SELECT DISTINCT args->>'user' AS u FROM chain_events WHERE emitter = ${vault.toLowerCase()} AND event_name = 'RedeemRequested'`
  for (const r of rows as { u: string }[]) {
    if (!r.u) continue
    const pending = await read<bigint>(vault, A.vault, 'pendingRedeem', [r.u])
    if (pending === 0n) continue
    const assets = await read<bigint>(vault, A.vault, 'convertToAssets', [pending])
    const idle = await read<bigint>(vault, A.vault, 'idle')
    if (assets > idle) await send('unwind', vault, A.vault, 'unwind', [assets - idle], strategyId)
    await send('fulfil-redeem', vault, A.vault, 'fulfillRedeem', [r.u], strategyId)
  }
}

export async function snapshot(strategyId: string, vault: Hex) {
  try {
    const [nav, shares, idle, price] = await Promise.all([
      read<bigint>(vault, A.vault, 'totalAssets'), read<bigint>(vault, A.vault, 'totalSupply'),
      read<bigint>(vault, A.vault, 'idle'), read<bigint>(vault, A.vault, 'sharePrice'),
    ])
    await sql`INSERT INTO nav_snapshots (strategy_id, ts, nav_usdc, total_shares, share_price, idle_usdc)
      VALUES (${strategyId}, now(), ${Number(nav) / 1e6}, ${Number(shares) / 1e12}, ${Number(price) / 1e6}, ${Number(idle) / 1e6})`
  } catch (e) {
    console.warn('[snapshot]', strategyId, String((e as Error).message).split('\n')[0])
  }
}

export const keepersEnabled = () => Boolean(process.env.DEPLOYER_PRIVATE_KEY) && process.env.KEEPERS !== 'off'

export function keeperAddress(): string | null {
  return process.env.DEPLOYER_PRIVATE_KEY ? keeperAccount().address : null
}

export function startKeepers() {
  let busy = false
  const guard = (name: string, fn: () => Promise<void>) => async () => {
    if (busy) return
    busy = true
    try { await fn() } catch (e) { console.warn('[keeper]', name, String((e as Error).message).split('\n')[0]) } finally { busy = false }
  }
  const prices = guard('prices', postPrices)
  const regime = guard('regime', postRegime)
  const ops = guard('upkeep', upkeep)
  void (async () => { await prices(); await regime(); await ops() })()
  setInterval(() => void prices(), 5 * 60_000)
  setInterval(() => void regime(), 15 * 60_000)
  setInterval(() => void ops(), 10 * 60_000)
}
