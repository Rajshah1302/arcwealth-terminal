import { Link } from 'react-router-dom'
import { ArrowUpRight } from 'lucide-react'
import { useApi, type StrategyRow } from '@/lib/api'
import { STRATEGIES } from '@/shared/strategies'
import { Card, PageTitle, Skeleton, TierBadge } from '@/components/ui'
import { PALETTE, Sparkline } from '@/components/charts'
import { pct } from '@/lib/format'

const RISK_DOTS = (n: number) =>
  Array.from({ length: 5 }, (_, i) => (
    <span key={i} className={`h-1 w-5 rounded-full ${i < n ? 'bg-gradient-to-r from-brand to-violet' : 'bg-white/10'}`} />
  ))

function Ret({ label, v }: { label: string; v?: number }) {
  const val = v === undefined ? undefined : v * 100
  return (
    <div className="rounded-xl border border-white/[0.06] bg-black/20 px-3 py-2.5 text-center">
      <div className="text-[9px] font-semibold uppercase tracking-[0.16em] text-ink-4">{label}</div>
      <div className={`num mt-1 font-display text-[15px] font-semibold ${val === undefined ? 'text-ink-3' : val >= 0 ? 'text-up' : 'text-down'}`}>{val === undefined ? '…' : pct(val, 1)}</div>
    </div>
  )
}

const RISK_COLOR = ['#5b8cff', '#a78bfa', '#c9ced8']

export default function SifList() {
  const { data, isLoading } = useApi<StrategyRow[]>('/strategies', 30000)
  return (
    <div>
      <PageTitle
        eyebrow="Strategies"
        title="Strategy Investment Funds"
        sub="Three demo SIFs on Arc Testnet. Each is an ERC-4626 vault over real testnet USDC that routes into demo sleeves. Performance shown is an illustrative backtest on simulated prices."
        right={<span className="pill">3 vaults · from 10 USDC</span>}
      />

      <div className="grid gap-4 lg:grid-cols-3">
        {STRATEGIES.map((s, i) => {
          const row = data?.find((d) => d.meta.id === s.id)
          const series = row?.backtest.series?.map((p) => ({ d: p.day, v: p.nav })) ?? []
          const color = RISK_COLOR[i % RISK_COLOR.length]
          return (
            <Card key={s.id} className="card-hover flex flex-col overflow-hidden">
              <div className="flex items-start justify-between gap-2">
                <div>
                  <div className="label">{s.short} · {s.risk}</div>
                  <h2 className="mt-1 font-display text-[22px] font-semibold tracking-[-0.02em] text-ink">{s.name}</h2>
                </div>
                <TierBadge tier="DEMO-ONCHAIN" />
              </div>
              <div className="mt-2.5 flex items-center gap-1" aria-label={`Risk ${s.riskLevel} of 5`}>
                {RISK_DOTS(s.riskLevel)}
                <span className="ml-2 text-[10px] uppercase tracking-[0.12em] text-ink-4">Risk {s.riskLevel}/5</span>
              </div>
              <p className="mt-3 text-pretty text-[13px] leading-relaxed text-ink-3">{s.objective}</p>

              <div className="mt-4 rounded-xl border border-white/[0.06] bg-black/20 p-3">
                <div className="flex items-center justify-between">
                  <span className="text-[9px] font-semibold uppercase tracking-[0.16em] text-ink-4">Illustrative 6M NAV</span>
                  <TierBadge tier="SIMULATED-OFFCHAIN" />
                </div>
                {isLoading ? (
                  <Skeleton className="mt-2 h-16" />
                ) : series.length > 1 ? (
                  <Sparkline data={series} x="d" y="v" height={64} color={color} />
                ) : (
                  <div className="mt-2 h-16 rounded-lg bg-white/[0.02]" />
                )}
              </div>

              <div className="mt-3 grid grid-cols-3 gap-2">
                <Ret label="1M" v={row?.backtest.ret1m} />
                <Ret label="3M" v={row?.backtest.ret3m} />
                <Ret label="6M" v={row?.backtest.ret6m} />
              </div>

              <div className="mt-4">
                <div className="mb-2 flex items-center justify-between">
                  <span className="label">Target allocation</span>
                  <span className="text-[10px] text-ink-4">of invested capital</span>
                </div>
                <div className="flex h-2 w-full overflow-hidden rounded-full border border-white/[0.06]">
                  {s.sleeves.map((x, j) => (
                    <span key={x.key} style={{ width: `${x.bps / 100}%`, background: PALETTE[j % PALETTE.length] }} className="h-full first:rounded-l-full last:rounded-r-full" title={`${x.name} ${x.bps / 100}%`} />
                  ))}
                </div>
                <div className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-[11px] text-ink-3">
                  {s.sleeves.map((x, j) => (
                    <span key={x.key} className="inline-flex items-center gap-1.5">
                      <span className="h-1.5 w-1.5 rounded-full" style={{ background: PALETTE[j % PALETTE.length] }} />
                      {x.name} <span className="num text-ink-4">{x.bps / 100}%</span>
                    </span>
                  ))}
                </div>
              </div>

              <dl className="mt-4 grid grid-cols-2 gap-3 rounded-xl border border-white/[0.06] bg-white/[0.02] p-3 text-xs">
                <div>
                  <dt className="text-[9px] font-semibold uppercase tracking-[0.14em] text-ink-4">Minimum</dt>
                  <dd className="num mt-1 font-medium text-ink-2">{s.minDeposit} USDC</dd>
                </div>
                <div>
                  <dt className="text-[9px] font-semibold uppercase tracking-[0.14em] text-ink-4">Horizon</dt>
                  <dd className="mt-1 font-medium text-ink-2">{s.horizon}</dd>
                </div>
              </dl>

              <div className="mt-4 grid grid-cols-3 gap-2 pt-1">
                <Link to={`/sif/${s.id}`} className="btn-ghost !min-h-[36px] !px-2 text-xs">Details</Link>
                <Link to={`/sif/${s.id}?invest=1`} className="btn-primary !min-h-[36px] !px-2 text-xs">Invest</Link>
                <Link to="/portfolio" className="btn-ghost !min-h-[36px] !px-2 text-xs">Portfolio</Link>
              </div>
            </Card>
          )
        })}
      </div>

      <Card className="mt-6 !p-0 overflow-hidden">
        <div className="flex items-center justify-between p-5 sm:px-6">
          <div>
            <span className="label">Comparison</span>
            <h2 className="mt-1 font-display text-lg font-semibold text-ink">Strategy matrix</h2>
          </div>
          <TierBadge tier="SIMULATED-OFFCHAIN" />
        </div>
        <div className="overflow-x-auto border-t border-white/[0.06]">
          <table className="data-table">
            <thead>
              <tr>
                <th>&nbsp;</th>
                {STRATEGIES.map((s) => (
                  <th key={s.id} className="!text-[11px] !tracking-[0.1em] !text-ink">{s.short} {s.name}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {(
                [
                  ['Risk', (s: (typeof STRATEGIES)[number]) => s.risk],
                  ['Illustrative return (annual)', (s: (typeof STRATEGIES)[number]) => s.compare.expectedReturn],
                  ['Volatility', (s: (typeof STRATEGIES)[number]) => s.compare.volatility],
                  ['Max drawdown', (s: (typeof STRATEGIES)[number]) => s.compare.maxDrawdown],
                  ['Fees', () => '1% / year, no entry fee'],
                  ['Liquidity', () => 'Instant up to idle buffer; larger via request'],
                ] as const
              ).map(([k, f]) => (
                <tr key={k}>
                  <td className="text-ink-3">{k}</td>
                  {STRATEGIES.map((s) => (
                    <td key={s.id} className="num text-ink-2">{f(s)}</td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <div className="flex flex-wrap items-center justify-between gap-2 px-5 py-3.5 text-[11px] text-ink-4 sm:px-6">
          <span>Figures are simulated and illustrative, not a forecast.</span>
          <Link to="/sif/s1" className="inline-flex items-center gap-1 font-medium text-brand-2 transition hover:text-white">
            Open S1 <ArrowUpRight className="h-3 w-3" />
          </Link>
        </div>
      </Card>
    </div>
  )
}
