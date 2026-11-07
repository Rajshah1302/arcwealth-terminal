// Seeded GBM price engine (SIMULATED-OFFCHAIN). Deterministic per asset seed; live ticks continue the same path.
import { MARKET, REGIMES, gauss, generateHistory, mulberry32, realisedVol30d, type MarketAsset } from '../src/shared/market'

export const TICK_SECONDS = 15
const TICK_DT = TICK_SECONDS / (365 * 86400)
/** Fixed anchor so every restart reproduces the same path. */
const ANCHOR = Math.floor(new Date('2026-11-06T00:00:00Z').getTime() / 1000 / TICK_SECONDS)

export interface Series {
  asset: MarketAsset
  daily: { day: number; price: number; regime: number }[]
  price: number
  ticks: { t: number; p: number }[] // ~1 per minute for the last 25h
  regime: number
}

const state = new Map<string, Series>()

function build(asset: MarketAsset): Series {
  const daily = generateHistory(asset)
  const rng = mulberry32(asset.seed * 104729 + 7)
  let p = asset.base
  let regime = daily[daily.length - 1].regime
  const nowTick = Math.floor(Date.now() / 1000 / TICK_SECONDS)
  const ticks: { t: number; p: number }[] = []
  const keepFrom = nowTick - Math.floor((25 * 3600) / TICK_SECONDS)
  for (let k = ANCHOR; k <= nowTick; k++) {
    const r = rng()
    if (r < 0.002) regime = Math.min(2, regime + 1)
    else if (r < 0.004) regime = Math.max(0, regime - 1)
    const mu = asset.mu * REGIMES[regime].mu
    const sg = asset.sigma * REGIMES[regime].sigma
    p *= Math.exp((mu - (sg * sg) / 2) * TICK_DT + sg * Math.sqrt(TICK_DT) * gauss(rng))
    if (k >= keepFrom && k % 4 === 0) ticks.push({ t: k * TICK_SECONDS * 1000, p })
  }
  // for anchors in the future (clock before anchor) the loop is empty and price stays at base
  return { asset, daily, price: p, ticks, regime }
}

let rngs = new Map<string, () => number>()

export function initPrices() {
  state.clear()
  rngs = new Map()
  for (const a of MARKET) state.set(a.symbol, build(a))
}

/** Advance live prices to "now" (called by a timer). */
let lastTick = Math.floor(Date.now() / 1000 / TICK_SECONDS)
export function stepPrices() {
  const nowTick = Math.floor(Date.now() / 1000 / TICK_SECONDS)
  for (const s of state.values()) {
    let rng = rngs.get(s.asset.symbol)
    if (!rng) {
      rng = mulberry32(s.asset.seed * 15485863 + nowTick)
      rngs.set(s.asset.symbol, rng)
    }
    for (let k = lastTick + 1; k <= nowTick; k++) {
      const mu = s.asset.mu * REGIMES[s.regime].mu
      const sg = s.asset.sigma * REGIMES[s.regime].sigma
      s.price *= Math.exp((mu - (sg * sg) / 2) * TICK_DT + sg * Math.sqrt(TICK_DT) * gauss(rng))
      if (k % 4 === 0) s.ticks.push({ t: k * TICK_SECONDS * 1000, p: s.price })
    }
    const cutoff = Date.now() - 25 * 3600 * 1000
    while (s.ticks.length && s.ticks[0].t < cutoff) s.ticks.shift()
  }
  lastTick = nowTick
}

export const getSeries = (symbol: string) => state.get(symbol)
export const allSeries = () => [...state.values()]
export const priceOf = (symbol: string) => state.get(symbol)?.price ?? 0

export function change24h(symbol: string): number {
  const s = state.get(symbol)
  if (!s || s.ticks.length === 0) return 0
  const target = Date.now() - 24 * 3600 * 1000
  const old = s.ticks.find((t) => t.t >= target) ?? s.ticks[0]
  return ((s.price - old.p) / old.p) * 100
}

/** 30d realised annualised vol (as a fraction) using daily closes plus the live price as the last point. */
export function vol30d(symbol: string): number {
  const s = state.get(symbol)
  if (!s) return 0.5
  const closes = s.daily.map((d) => d.price)
  closes[closes.length - 1] = s.price
  return realisedVol30d(closes)
}

export function trendUp(symbol: string): boolean {
  const s = state.get(symbol)
  if (!s) return true
  const c = s.daily.map((d) => d.price)
  c[c.length - 1] = s.price
  const sma = (n: number) => c.slice(-n).reduce((a, b) => a + b, 0) / Math.min(n, c.length)
  return sma(50) >= sma(200)
}

export function historyFor(symbol: string, days: number) {
  const s = state.get(symbol)
  if (!s) return []
  const now = Date.now()
  return s.daily.slice(-days).map((d) => ({ ts: now + d.day * 86400_000, price: d.price }))
}
