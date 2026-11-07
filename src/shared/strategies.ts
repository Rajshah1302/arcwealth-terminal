import { keccak256, toBytes } from 'viem'

export interface Sleeve {
  key: string
  name: string
  bps: number
  tier: 'DEMO-ONCHAIN' | 'SIMULATED-OFFCHAIN'
  note: string
}

export interface StrategyMeta {
  id: 's1' | 's2' | 's3'
  name: string
  short: string
  symbol: string
  risk: string
  riskLevel: 2 | 3 | 5
  objective: string
  horizon: string
  minDeposit: number
  liquidity: string
  sleeves: Sleeve[]
  /** illustrative annualised figures for the comparison table (SIMULATED-OFFCHAIN) */
  compare: { expectedReturn: string; volatility: string; maxDrawdown: string }
  methodology: string[]
  risks: string[]
  config: Record<string, unknown>
}

export const FEE_TEXT = '1% per year charged in newly minted shares. No entry or exit fee. You also pay Arc gas in USDC.'

export const STRATEGIES: StrategyMeta[] = [
  {
    id: 's1',
    name: 'Hybrid Long-Short',
    short: 'S1',
    symbol: 'aS1',
    risk: 'Moderate',
    riskLevel: 3,
    objective: 'Demo income from tokenized debt coupons and covered-call premium, with a regime-aware tactical sleeve.',
    horizon: '3 to 6 months',
    minDeposit: 10,
    liquidity: 'Instant up to the idle buffer (at least 10%); larger exits via request and keeper unwind.',
    sleeves: [
      { key: 'debt', name: 'Tokenized Debt', bps: 4000, tier: 'DEMO-ONCHAIN', note: '3 demo bonds, real USDC coupons, demo credit' },
      { key: 'calls', name: 'ITM Covered Calls', bps: 4000, tier: 'DEMO-ONCHAIN', note: 'dBTC / dETH, strike 2-10% in the money, 7-30 day expiry' },
      { key: 'tactical', name: 'Tactical', bps: 2000, tier: 'DEMO-ONCHAIN', note: 'USDC, dTBILL, put collateral, regime driven' },
    ],
    compare: { expectedReturn: '6 - 10%', volatility: '6 - 9%', maxDrawdown: '-8%' },
    methodology: [
      'Sleeves are 40/40/20 of invested capital, with at least 10% of NAV kept idle in USDC.',
      'Coupons accrue Actual/365 and are paid in testnet USDC from the demo bond reserve.',
      'Calls are written at spot x (1 - ITM depth), default 5%, priced with Black-Scholes on 30d realised vol.',
      'Tactical allocation follows a volatility and trend regime table with a +/-10pp manager override.',
    ],
    risks: [
      'Credit and default risk of the demo bond issuer (demo only).',
      'Capped upside, retained downside and assignment risk on covered calls.',
      'Strategy performance is simulated and illustrative.',
    ],
    config: { sleeves: [4000, 4000, 2000], bonds: [{ rating: 'AAA', couponBps: 650, days: 14 }, { rating: 'AA', couponBps: 725, days: 45 }, { rating: 'BBB', couponBps: 800, days: 90 }], itmDepthBps: 500, itmRangeBps: [200, 1000], expiryDays: [7, 30], underlyings: ['dBTC', 'dETH'], minIdleBps: 1000 },
  },
  {
    id: 's2',
    name: 'Asset Allocator',
    short: 'S2',
    symbol: 'aS2',
    risk: 'Moderate-High',
    riskLevel: 3,
    objective: 'Diversified demo commodity exposure with bounded rebalancing and an options overlay where available.',
    horizon: '6 to 12 months',
    minDeposit: 10,
    liquidity: 'Instant up to the idle buffer; larger exits via request and keeper unwind.',
    sleeves: [
      { key: 'xau', name: 'dXAU Gold', bps: 5000, tier: 'DEMO-ONCHAIN', note: 'band 30-70%, options available' },
      { key: 'xag', name: 'dXAG Silver', bps: 3000, tier: 'DEMO-ONCHAIN', note: 'band 10-40%, options available' },
      { key: 'copr', name: 'dCOPR Copper', bps: 2000, tier: 'DEMO-ONCHAIN', note: 'band 0-30%, options disabled' },
    ],
    compare: { expectedReturn: '5 - 12%', volatility: '12 - 18%', maxDrawdown: '-16%' },
    methodology: [
      'Weights 50/30/20 inside bands; the manager may tilt +/-10pp with a recorded reason.',
      'Options overlay (OTM 5% calls up to 50%, protective puts in high vol) is available on dXAU and dXAG only and is recorded-only in this demo.',
      'dCOPR options are auto-disabled on chain and can never be traded.',
    ],
    risks: ['Commodity price risk (simulated).', 'Overlay is not executed on chain in this demo.', 'Strategy performance is simulated and illustrative.'],
    config: { weights: { dXAU: 5000, dXAG: 3000, dCOPR: 2000 }, bands: { dXAU: [3000, 7000], dXAG: [1000, 4000], dCOPR: [0, 3000] }, optionsAvailable: ['dXAU', 'dXAG'], overlay: { otmCallBps: 500, maxOverlayBps: 5000, tiltPpMax: 10 } },
  },
  {
    id: 's3',
    name: 'Aggressive Covered Call',
    short: 'S3',
    symbol: 'aS3',
    risk: 'Very High',
    riskLevel: 5,
    objective: 'Maximise demo premium income by writing calls on the full crypto sleeve.',
    horizon: '1 to 3 months',
    minDeposit: 10,
    liquidity: 'Instant up to the idle buffer; larger exits via request and keeper unwind.',
    sleeves: [{ key: 'calls', name: 'Covered Calls', bps: 10000, tier: 'DEMO-ONCHAIN', note: 'dBTC / dETH / dSOL, ITM 5% to OTM 10%, 7-30 day expiry' }],
    compare: { expectedReturn: '8 - 20%', volatility: '25 - 40%', maxDrawdown: '-35%' },
    methodology: [
      '100% of invested capital is held in dBTC, dETH and dSOL and covered by short calls (coverage never above 100%).',
      '50% of premium is reinvested at expiry.',
      'Strike range runs from 5% ITM to 10% OTM; expiry 7 to 30 days.',
    ],
    risks: ['Capped upside with full downside to the underlyings.', 'Frequent assignment risk.', 'Strategy performance is simulated and illustrative.'],
    config: { weights: { dBTC: 4000, dETH: 3000, dSOL: 3000 }, strikeRangeBps: [9500, 11000], expiryDays: [7, 30], reinvestPremiumBps: 5000 },
  },
]

export const STRATEGY_BY_ID = Object.fromEntries(STRATEGIES.map((s) => [s.id, s])) as Record<string, StrategyMeta>

export const DISCLOSURE_TEXT = (s: StrategyMeta) =>
  `ARCWEALTH ${s.short} ${s.name} disclosure v1. Hackathon demo on Arc Testnet. Demo tokens, bonds, options and prices have no monetary value. ` +
  `Strategy performance is simulated and illustrative, not investment advice. Risks: ${s.risks.join(' ')} ` +
  `Fees: ${FEE_TEXT} Unaudited testnet contracts; you may lose all testnet USDC deposited.`

export const disclosureHash = (s: StrategyMeta) => keccak256(toBytes(DISCLOSURE_TEXT(s)))
export const configHash = (s: StrategyMeta) => keccak256(toBytes(JSON.stringify(s.config)))
