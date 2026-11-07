import { Link } from 'react-router-dom'
import { ArrowRight, ArrowUpRight, Coins, Globe2, Landmark, LineChart, ShieldCheck, Sparkles } from 'lucide-react'
import { useAccount } from 'wagmi'
import { STRATEGIES } from '@/shared/strategies'
import { useApi, type StrategyRow } from '@/lib/api'
import { Card, TierBadge } from '@/components/ui'
import { Donut, Legend, PALETTE, Sparkline } from '@/components/charts'
import { ConnectButton } from '@/components/Layout'
import { pct, usd } from '@/lib/format'
const VERTICALS = [
  { to: '/trading', icon: Coins, title: 'Crypto Trading', body: 'Trade live Arc Testnet tokens and clearly labelled demo tokens with simulated reference charts.' },
  { to: '/lending', icon: Landmark, title: 'Lending & Borrowing', body: 'Supply USDC or borrow against cirBTC on a transparent demo pool with a liquidation simulator.' },
  { to: '/sif', icon: LineChart, title: 'SIF Strategies', body: 'Three ERC-4626 strategy funds: bonds, covered calls and tactical sleeves, accounted on chain.' },
]

export default function Landing() {
  const { isConnected } = useAccount()
  const { data } = useApi<StrategyRow[]>('/strategies', 60000)
  const s1 = STRATEGIES[0]
  const donut = s1.sleeves.map((s) => ({ name: s.name, value: s.bps / 100 }))
  const row = data?.find((d) => d.meta.id === 's1')
  const bt = row?.backtest
  const series = bt?.series?.map((p) => ({ d: p.day, v: p.nav })) ?? []
  const tvl = data?.reduce((a, r) => a + r.live.navUsdc, 0) ?? 0

  return (
    <div className="space-y-4">
      <section className="relative overflow-hidden rounded-3xl border border-white/[0.08] bg-panel-sheen p-6 shadow-card backdrop-blur-xl sm:p-10">
        <div className="pointer-events-none absolute -left-24 -top-28 h-72 w-72 rounded-full bg-brand/20 blur-3xl" aria-hidden />
        <div className="pointer-events-none absolute -right-20 top-10 h-64 w-64 rounded-full bg-violet/[0.15] blur-3xl" aria-hidden />

        <div className="relative grid items-center gap-10 lg:grid-cols-[1.12fr_0.88fr]">
          <div>
            <span className="pill !border-brand/25 !bg-brand/10 !text-brand-2">
              <Sparkles className="h-3.5 w-3.5" aria-hidden /> Arc Testnet · USDC settlement
            </span>
            <h1 className="mt-5 max-w-2xl text-balance font-display text-[36px] font-semibold leading-[1.04] tracking-[-0.035em] text-ink sm:text-[54px]">
              Onchain alternate investment
            </h1>
            <p className="mt-5 max-w-xl text-pretty text-[15px] leading-relaxed text-ink-3">
              ARCWEALTH is a USDC investing demo on Arc Testnet. Every asset, position, price and yield wears an honesty badge, so you always know what is real testnet, what is a demo stand-in and what is simulated.
            </p>
            <div className="mt-7 flex flex-wrap items-center gap-2.5">
              <Link to="/sif" className="btn-primary">
                Explore SIF strategies <ArrowRight className="h-4 w-4" />
              </Link>
              {!isConnected && <ConnectButton className="!border-white/15 !bg-white/[0.05]" />}
              <Link to="/dashboard" className="btn-subtle">
                Open dashboard <ArrowUpRight className="h-4 w-4" />
              </Link>
            </div>

            <dl className="mt-9 grid grid-cols-2 gap-6 border-t border-white/[0.06] pt-6 sm:grid-cols-4">
              {[
                ['Onchain NAV', tvl > 0 ? usd(tvl) : '—'],
                ['Strategies', '3'],
                ['Assets', '12'],
                ['Settlement', 'USDC'],
              ].map(([k, v]) => (
                <div key={k}>
                  <dt className="text-[9px] font-semibold uppercase tracking-[0.18em] text-ink-4">{k}</dt>
                  <dd className="num mt-1.5 font-display text-lg font-semibold text-ink">{v}</dd>
                </div>
              ))}
            </dl>
          </div>

          <div className="relative">
            <Card className="!p-4 sm:!p-5">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                  <span className="icon-tile !h-8 !w-8 font-display text-[11px] font-semibold">S1</span>
                  <div>
                    <div className="text-[13px] font-semibold text-ink">Hybrid Long-Short</div>
                    <div className="text-[10px] uppercase tracking-[0.14em] text-ink-4">Flagship strategy</div>
                  </div>
                </div>
                <TierBadge tier="DEMO-ONCHAIN" />
              </div>
              <div className="mt-4 flex items-end justify-between">
                <div>
                  <div className="text-[9px] font-semibold uppercase tracking-[0.18em] text-ink-4">Live NAV</div>
                  <div className="num mt-1 font-display text-2xl font-semibold text-ink">{row ? usd(row.live.navUsdc) : '—'}</div>
                </div>
                <div className="text-right">
                  <div className="text-[9px] font-semibold uppercase tracking-[0.18em] text-ink-4">Share price</div>
                  <div className="num mt-1 font-display text-sm font-semibold text-ink">{row ? usd(row.live.sharePrice, 4) : '—'}</div>
                </div>
              </div>
              <div className="mt-3">
                {series.length > 1 ? <Sparkline data={series} x="d" y="v" height={72} color={PALETTE[0]} /> : <div className="h-[72px] rounded-lg bg-white/[0.02]" />}
              </div>
              <div className="mt-3 grid grid-cols-3 gap-2">
                {[
                  ['1M', bt?.ret1m],
                  ['3M', bt?.ret3m],
                  ['6M', bt?.ret6m],
                ].map(([k, v]) => (
                  <div key={k as string} className="rounded-lg border border-white/[0.06] bg-black/20 px-2 py-2 text-center">
                    <div className="text-[9px] uppercase tracking-[0.14em] text-ink-4">{k as string}</div>
                    <div className={`num mt-0.5 text-[13px] font-semibold ${v === undefined ? 'text-ink-4' : (v as number) >= 0 ? 'text-up' : 'text-down'}`}>
                      {v === undefined ? '…' : pct((v as number) * 100, 1)}
                    </div>
                  </div>
                ))}
              </div>
              <Link to="/sif/s1" className="btn-ghost mt-3 w-full !min-h-[36px] text-xs">
                Open strategy <ArrowUpRight className="h-3.5 w-3.5" />
              </Link>
            </Card>
            <div className="absolute -bottom-3 -right-2 hidden rounded-full border border-white/10 bg-[#0a0a10]/90 px-3 py-1.5 text-[10px] font-medium text-ink-2 shadow-card backdrop-blur sm:block">
              <span className="mr-1.5 inline-block h-1.5 w-1.5 rounded-full bg-emerald-400" aria-hidden /> Keeper live
            </div>
          </div>
        </div>
      </section>

      <section className="grid gap-4 md:grid-cols-3">
        {VERTICALS.map((v) => (
          <Link key={v.to} to={v.to} className="card card-hover group">
            <span className="icon-tile transition group-hover:border-brand/30 group-hover:text-brand">
              <v.icon className="h-4 w-4" aria-hidden />
            </span>
            <h2 className="mt-4 font-display text-lg font-semibold text-ink">{v.title}</h2>
            <p className="mt-1.5 text-[13px] leading-relaxed text-ink-3">{v.body}</p>
            <span className="mt-4 inline-flex items-center gap-1 text-xs font-semibold text-brand-2">
              Open <ArrowUpRight className="h-3.5 w-3.5 transition group-hover:translate-x-0.5" />
            </span>
          </Link>
        ))}
      </section>

      <section className="grid gap-4 lg:grid-cols-[1.2fr_1fr]">
        <Card>
          <div className="flex flex-wrap items-start justify-between gap-2">
            <div>
              <div className="label">SIF spotlight · {s1.risk}</div>
              <h2 className="mt-1 font-display text-xl font-semibold text-ink">{s1.short} {s1.name}</h2>
            </div>
            <TierBadge tier="DEMO-ONCHAIN" />
          </div>
          <p className="mt-2 text-pretty text-[13px] leading-relaxed text-ink-3">{s1.objective}</p>
          <div className="mt-5 flex flex-wrap items-center gap-6">
            <Donut data={donut} size={140} />
            <div className="min-w-[200px] flex-1">
              <Legend data={donut} />
            </div>
          </div>
          <div className="mt-5 flex flex-wrap items-center gap-4 text-xs text-ink-3">
            <span>Min <span className="num text-ink">{s1.minDeposit} USDC</span></span>
            <span>1% / yr fee</span>
            {bt && (
              <span>
                Illustrative 3M <span className={`num font-semibold ${bt.ret3m >= 0 ? 'text-up' : 'text-down'}`}>{pct(bt.ret3m * 100, 1)}</span>{' '}
                <TierBadge tier="SIMULATED-OFFCHAIN" />
              </span>
            )}
          </div>
          <div className="mt-5 flex flex-wrap gap-2">
            <Link to="/sif/s1?invest=1" className="btn-primary">Invest in S1</Link>
            <Link to="/sif/s1" className="btn-ghost">Details</Link>
          </div>
        </Card>

        <Card>
          <div className="flex items-center gap-2">
            <ShieldCheck className="h-4 w-4 text-brand" aria-hidden />
            <h2 className="font-display text-lg font-semibold text-ink">How we label everything</h2>
          </div>
          <ul className="mt-4 space-y-3.5 text-[13px]">
            <li>
              <TierBadge tier="LIVE-TESTNET" />
              <p className="mt-1.5 leading-relaxed text-ink-3">Real Arc Testnet contracts we do not own: USDC, EURC, cirBTC, WETH.</p>
            </li>
            <li>
              <TierBadge tier="DEMO-ONCHAIN" />
              <p className="mt-1.5 leading-relaxed text-ink-3">Our stand-ins: demo bonds, tokens, options counterparty. Real transactions, no value.</p>
            </li>
            <li>
              <TierBadge tier="SIMULATED-OFFCHAIN" />
              <p className="mt-1.5 leading-relaxed text-ink-3">Backend computed prices, charts and backtests. Illustrative only.</p>
            </li>
          </ul>
          <p className="mt-4 flex items-center gap-1.5 text-[11px] text-ink-4">
            <Globe2 className="h-3.5 w-3.5" aria-hidden /> Demo yield (testnet, no monetary value). Unaudited contracts. Not investment advice.
          </p>
        </Card>
      </section>

      <section>
        <Card className="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h2 className="font-display text-xl font-semibold text-ink">Ready to try it?</h2>
            <p className="mt-1 text-sm text-ink-3">Connect MetaMask, switch to Arc Testnet, grab test USDC, and invest 50 USDC in S1.</p>
          </div>
          <div className="flex flex-wrap gap-2">
            {isConnected ? <Link to="/profile" className="btn-primary">Set up wallet</Link> : <ConnectButton />}
            <Link to="/profile" className="btn-ghost">Faucet and network</Link>
          </div>
        </Card>
      </section>
    </div>
  )
}
