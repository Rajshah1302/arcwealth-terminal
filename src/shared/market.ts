// Market definitions shared by the deploy script, backend and frontend.
// Prices are SIMULATED-OFFCHAIN reference prices (seeded GBM). Demo tokens have no monetary value.

export type Tier = 'LIVE-TESTNET' | 'DEMO-ONCHAIN' | 'SIMULATED-OFFCHAIN'

export interface MarketAsset {
  symbol: string
  name: string
  kind: 'demo' | 'live'
  tier: Tier
  decimals: number
  /** starting reference price in USD */
  base: number
  /** annualised drift and vol for the seeded GBM */
  mu: number
  sigma: number
  seed: number
  /** USD notional minted by one faucet claim (demo tokens only) */
  faucetUsd?: number
  address?: `0x${string}`
}

export const USDC_ADDRESS = '0x3600000000000000000000000000000000000000' as const
export const ARC_CHAIN_ID = 5042002

export const LIVE_ADDRESSES = {
  EURC: '0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a',
  cirBTC: '0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF',
  WETH: '0x2c4047028a72803939b6fb674D01bC059B5C4961',
} as const

export const MARKET: MarketAsset[] = [
  { symbol: 'dBTC', name: 'Demo Bitcoin', kind: 'demo', tier: 'DEMO-ONCHAIN', decimals: 18, base: 65000, mu: 0.18, sigma: 0.55, seed: 11, faucetUsd: 25 },
  { symbol: 'dETH', name: 'Demo Ether', kind: 'demo', tier: 'DEMO-ONCHAIN', decimals: 18, base: 3200, mu: 0.15, sigma: 0.65, seed: 12, faucetUsd: 25 },
  { symbol: 'dSOL', name: 'Demo Solana', kind: 'demo', tier: 'DEMO-ONCHAIN', decimals: 18, base: 150, mu: 0.2, sigma: 0.85, seed: 13, faucetUsd: 25 },
  { symbol: 'dXAU', name: 'Demo Gold', kind: 'demo', tier: 'DEMO-ONCHAIN', decimals: 18, base: 2400, mu: 0.06, sigma: 0.14, seed: 14, faucetUsd: 25 },
  { symbol: 'dXAG', name: 'Demo Silver', kind: 'demo', tier: 'DEMO-ONCHAIN', decimals: 18, base: 30, mu: 0.07, sigma: 0.28, seed: 15, faucetUsd: 25 },
  { symbol: 'dCOPR', name: 'Demo Copper', kind: 'demo', tier: 'DEMO-ONCHAIN', decimals: 18, base: 4.5, mu: 0.05, sigma: 0.24, seed: 16, faucetUsd: 25 },
  { symbol: 'dTBILL', name: 'Demo T-Bill', kind: 'demo', tier: 'DEMO-ONCHAIN', decimals: 18, base: 100, mu: 0.045, sigma: 0.01, seed: 17, faucetUsd: 25 },
  { symbol: 'cirBTC', name: 'Circle Bitcoin', kind: 'live', tier: 'LIVE-TESTNET', decimals: 8, base: 65000, mu: 0.18, sigma: 0.55, seed: 11, address: LIVE_ADDRESSES.cirBTC },
  { symbol: 'WETH', name: 'Wrapped Ether', kind: 'live', tier: 'LIVE-TESTNET', decimals: 18, base: 3200, mu: 0.15, sigma: 0.65, seed: 12, address: LIVE_ADDRESSES.WETH },
  { symbol: 'EURC', name: 'Euro Coin', kind: 'live', tier: 'LIVE-TESTNET', decimals: 6, base: 1.08, mu: 0, sigma: 0.07, seed: 18, address: LIVE_ADDRESSES.EURC },
]

export const DEMO_SYMBOLS = MARKET.filter((m) => m.kind === 'demo').map((m) => m.symbol)

export const FOOTER_DISCLAIMER =
  'Hackathon demo on Arc Testnet. Demo tokens have no monetary value. Not investment advice. Strategy performance is simulated and illustrative.'

// ---- seeded GBM (deterministic) ----
export function mulberry32(seed: number) {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

export function gauss(rng: () => number) {
  const u = Math.max(rng(), 1e-12)
  const v = rng()
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v)
}

/** Regime multipliers: calm / normal / stressed. */
export const REGIMES = [
  { name: 'calm', mu: 1.5, sigma: 0.7 },
  { name: 'normal', mu: 1, sigma: 1 },
  { name: 'stressed', mu: -2, sigma: 1.7 },
] as const

/**
 * 365 daily closes ending at `asset.base`. Deterministic per seed.
 * A three-state Markov chain switches regimes; the series is rescaled so the last close equals base.
 */
export function generateHistory(asset: MarketAsset, days = 365): { day: number; price: number; regime: number }[] {
  const rng = mulberry32(asset.seed * 7919)
  const dt = 1 / 365
  let regime = 1
  let p = 1
  const raw: { price: number; regime: number }[] = []
  for (let i = 0; i < days; i++) {
    const r = rng()
    if (r < 0.03) regime = Math.min(2, regime + 1)
    else if (r < 0.06) regime = Math.max(0, regime - 1)
    const mu = asset.mu * REGIMES[regime].mu
    const sg = asset.sigma * REGIMES[regime].sigma
    p *= Math.exp((mu - (sg * sg) / 2) * dt + sg * Math.sqrt(dt) * gauss(rng))
    raw.push({ price: p, regime })
  }
  const scale = asset.base / raw[raw.length - 1].price
  return raw.map((x, i) => ({ day: i - (days - 1), price: x.price * scale, regime: x.regime }))
}

export function realisedVol30d(closes: number[]): number {
  const w = closes.slice(-31)
  const rets: number[] = []
  for (let i = 1; i < w.length; i++) rets.push(Math.log(w[i] / w[i - 1]))
  const m = rets.reduce((a, b) => a + b, 0) / rets.length
  const v = rets.reduce((a, b) => a + (b - m) ** 2, 0) / Math.max(1, rets.length - 1)
  return Math.sqrt(v) * Math.sqrt(365)
}

const erf = (x: number) => {
  const s = Math.sign(x)
  x = Math.abs(x)
  const t = 1 / (1 + 0.3275911 * x)
  const y = 1 - ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * Math.exp(-x * x)
  return s * y
}
export const normCdf = (x: number) => 0.5 * (1 + erf(x / Math.SQRT2))

/** Black-Scholes European call value and delta. */
export function blackScholesCall(S: number, K: number, T: number, r: number, sigma: number) {
  if (T <= 0 || sigma <= 0) return { price: Math.max(S - K, 0), delta: S > K ? 1 : 0 }
  const d1 = (Math.log(S / K) + (r + (sigma * sigma) / 2) * T) / (sigma * Math.sqrt(T))
  const d2 = d1 - sigma * Math.sqrt(T)
  return { price: S * normCdf(d1) - K * Math.exp(-r * T) * normCdf(d2), delta: normCdf(d1) }
}
