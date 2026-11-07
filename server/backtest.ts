// Illustrative backtests (SIMULATED-OFFCHAIN): replay the seeded GBM history through each strategy rule set.
import { MARKET, blackScholesCall, generateHistory, type MarketAsset } from '../src/shared/market'

export interface BacktestResult {
  id: string
  tier: 'SIMULATED-OFFCHAIN'
  label: 'illustrative backtest'
  ret1m: number
  ret3m: number
  ret6m: number
  volAnn: number
  maxDrawdown: number
  series: { day: number; nav: number }[]
}

const asset = (s: string) => MARKET.find((m) => m.symbol === s) as MarketAsset
const closes = (s: string) => generateHistory(asset(s)).map((d) => d.price)

const sigmaAt = (c: number[], i: number) => {
  const w = c.slice(Math.max(0, i - 30), i + 1)
  const r: number[] = []
  for (let k = 1; k < w.length; k++) r.push(Math.log(w[k] / w[k - 1]))
  if (r.length < 2) return 0.5
  const m = r.reduce((a, b) => a + b, 0) / r.length
  return Math.max(0.1, Math.sqrt(r.reduce((a, b) => a + (b - m) ** 2, 0) / (r.length - 1)) * Math.sqrt(365))
}

/** Daily returns of a weekly-rolled covered call (strike = spot * strikeMult). */
function coveredCallDaily(c: number[], strikeMult: number): number[] {
  const out = new Array(c.length).fill(0)
  for (let i = 0; i + 7 < c.length; i += 7) {
    const S0 = c[i], K = S0 * strikeMult, ST = c[i + 7]
    const prem = blackScholesCall(S0, K, 7 / 365, 0.045, sigmaAt(c, i)).price
    const weekRet = (Math.min(ST, K) + prem) / S0 - 1
    for (let d = 1; d <= 7; d++) out[i + d] = Math.pow(1 + weekRet, 1 / 7) - 1
  }
  return out
}

const dailyReturns = (c: number[]) => c.map((p, i) => (i === 0 ? 0 : p / c[i - 1] - 1))
const blend = (parts: { w: number; r: number[] }[]) => parts[0].r.map((_, i) => parts.reduce((a, p) => a + p.w * p.r[i], 0))

function summarise(id: string, daily: number[]): BacktestResult {
  const nav: number[] = [1]
  for (let i = 1; i < daily.length; i++) nav.push(nav[i - 1] * (1 + daily[i]))
  const n = nav.length
  const ret = (d: number) => nav[n - 1] / nav[n - 1 - d] - 1
  const rets = daily.slice(1)
  const m = rets.reduce((a, b) => a + b, 0) / rets.length
  const vol = Math.sqrt(rets.reduce((a, b) => a + (b - m) ** 2, 0) / (rets.length - 1)) * Math.sqrt(365)
  let peak = 1, mdd = 0
  for (const v of nav) { peak = Math.max(peak, v); mdd = Math.min(mdd, v / peak - 1) }
  return {
    id, tier: 'SIMULATED-OFFCHAIN', label: 'illustrative backtest',
    ret1m: ret(30), ret3m: ret(90), ret6m: ret(180), volAnn: vol, maxDrawdown: mdd,
    series: nav.slice(-180).map((v, i) => ({ day: i - 179, nav: v })),
  }
}

export function runBacktests(): Record<string, BacktestResult> {
  const bond = new Array(365).fill(0.0725 / 365)
  const tbill = new Array(365).fill(0.045 / 365)
  const cash = new Array(365).fill(0)
  const btc = closes('dBTC'), eth = closes('dETH'), sol = closes('dSOL')
  const calls12 = blend([{ w: 0.5, r: coveredCallDaily(btc, 0.95) }, { w: 0.5, r: coveredCallDaily(eth, 0.95) }])
  const tactical = blend([{ w: 0.25, r: cash }, { w: 0.55, r: tbill }, { w: 0.2, r: tbill }])
  const s1 = blend([{ w: 0.9 * 0.4, r: bond }, { w: 0.9 * 0.4, r: calls12 }, { w: 0.9 * 0.2, r: tactical }, { w: 0.1, r: cash }])
  const metals = blend([
    { w: 0.5, r: dailyReturns(closes('dXAU')) }, { w: 0.3, r: dailyReturns(closes('dXAG')) }, { w: 0.2, r: dailyReturns(closes('dCOPR')) },
  ])
  const s2 = blend([{ w: 0.9, r: metals }, { w: 0.1, r: cash }])
  const s3calls = blend([{ w: 0.4, r: coveredCallDaily(btc, 1.03) }, { w: 0.3, r: coveredCallDaily(eth, 1.03) }, { w: 0.3, r: coveredCallDaily(sol, 1.03) }])
  const s3 = blend([{ w: 0.9, r: s3calls }, { w: 0.1, r: cash }])
  const feeDaily = 0.01 / 365
  const net = (r: number[]) => r.map((x, i) => (i === 0 ? 0 : x - feeDaily))
  return { s1: summarise('s1', net(s1)), s2: summarise('s2', net(s2)), s3: summarise('s3', net(s3)) }
}
