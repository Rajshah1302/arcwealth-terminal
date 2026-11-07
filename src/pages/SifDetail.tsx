import { Link, Navigate, useParams } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { ArrowUpRight, ExternalLink, LineChart, ShieldCheck } from 'lucide-react'
import { addrUrl, vaultOf } from '@/lib/chain'
import { useApi, type StrategyDetail } from '@/lib/api'
import { STRATEGY_BY_ID, FEE_TEXT } from '@/shared/strategies'
import { Card, Notice, PageTitle, Skeleton, Stat, TierBadge } from '@/components/ui'
import { AreaLine, Donut, Legend, PALETTE } from '@/components/charts'
import InvestPanel from '@/components/InvestPanel'
import { dateOnly, num, pct, short, usd } from '@/lib/format'

export default function SifDetail() {
  const { id = '' } = useParams()
  const qc = useQueryClient()
  const meta = STRATEGY_BY_ID[id]
  const { data, isLoading, error } = useApi<StrategyDetail>(meta ? `/strategies/${id}` : null, 15000)
  const nav = useApi<{ points: { ts: string; share_price: number }[] }>(meta ? `/strategies/${id}/nav` : null, 30000)
  if (!meta) return <Navigate to="/sif" replace />
  const donut = meta.sleeves.map((s) => ({ name: s.name, value: s.bps / 100 }))
  const live = data?.live
  const TVL_CAP = 1000
  const navPoints = nav.data?.points.map((p) => ({ t: p.ts, v: Number(p.share_price) })) ?? []

  return (
    <div>
      <PageTitle
        eyebrow={<Link to="/sif" className="transition hover:text-brand-2">Strategies / {meta.short}</Link>}
        title={`${meta.short} ${meta.name}`}
        sub={meta.objective}
        right={
          <>
            <span className="pill">{meta.risk} risk</span>
            <TierBadge tier="DEMO-ONCHAIN" />
            <a href="#invest" className="btn-primary">
              Invest <ArrowUpRight className="h-4 w-4" />
            </a>
          </>
        }
      />

      {error && (
        <div className="mb-4">
          <Notice tone="error">Could not load strategy data. The API may be starting; retrying.</Notice>
        </div>
      )}

      <div className="grid gap-4 lg:grid-cols-[1fr_380px]">
        <div className="min-w-0 space-y-4">
          <Card>
            <div className="grid grid-cols-2 gap-5 sm:grid-cols-4">
              <Stat label="NAV" value={live ? usd(live.navUsdc) : '…'} sub="Onchain" tier="DEMO-ONCHAIN" />
              <Stat label="Share price" value={live ? usd(live.sharePrice, 4) : '…'} sub="NAV / shares" />
              <Stat label="TVL cap" value={live ? `${num((live.navUsdc / TVL_CAP) * 100, 1)}%` : '…'} sub={`of ${usd(TVL_CAP, 0)}`} />
              <Stat label="Idle buffer" value={live ? usd(live.idleUsdc) : '…'} sub="Instant withdrawals" />
            </div>
          </Card>

          <Card>
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div>
                <div className="flex items-center gap-2">
                  <span className="label">Share price</span>
                  <TierBadge tier="DEMO-ONCHAIN" />
                </div>
                <h2 className="mt-1 font-display text-lg font-semibold text-ink">Onchain snapshots</h2>
              </div>
              <div className="text-right">
                <div className="label">Latest</div>
                <div className="num mt-1 font-display text-lg font-semibold text-ink">{live ? usd(live.sharePrice, 4) : '—'}</div>
              </div>
            </div>
            <div className="mt-4">
              {navPoints.length > 1 ? (
                <AreaLine data={navPoints} x="t" y="v" height={252} showGrid fmt={(v) => usd(v, 4)} />
              ) : (
                <div className="flex h-[252px] flex-col items-center justify-center gap-2 rounded-xl border border-dashed border-white/[0.08] bg-black/20 text-center">
                  <span className="flex h-10 w-10 items-center justify-center rounded-full border border-white/10 bg-white/[0.03] text-ink-3">
                    <LineChart className="h-4 w-4" />
                  </span>
                  <p className="text-sm font-medium text-ink-2">Snapshots appear every few minutes once the keeper runs.</p>
                  <p className="max-w-xs text-xs text-ink-3">Share price is recorded onchain by the strategy keeper.</p>
                </div>
              )}
            </div>
          </Card>

          <Card>
            <div className="flex items-center justify-between">
              <div>
                <span className="label">Composition</span>
                <h2 className="mt-1 font-display text-lg font-semibold text-ink">Allocation</h2>
              </div>
              <TierBadge tier="DEMO-ONCHAIN" />
            </div>
            <div className="mt-4 flex flex-wrap items-center gap-6">
              <Donut data={donut} size={156} />
              <div className="min-w-[220px] flex-1">
                <Legend data={donut} />
                <p className="mt-3 text-[11px] leading-relaxed text-ink-4">Share of invested capital. At least 10% of NAV stays idle in USDC.</p>
              </div>
            </div>
            <ul className="mt-5 grid gap-2.5 sm:grid-cols-2">
              {meta.sleeves.map((s, i) => (
                <li key={s.key} className="rounded-xl border border-white/[0.06] bg-white/[0.02] p-3.5 text-sm">
                  <div className="flex items-center justify-between gap-2">
                    <span className="flex items-center gap-2 font-semibold text-ink">
                      <span className="h-2 w-2 rounded-full" style={{ background: PALETTE[i % PALETTE.length] }} />
                      {s.name}
                    </span>
                    <TierBadge tier={s.tier} />
                  </div>
                  <div className="mt-1.5 text-xs leading-relaxed text-ink-3">{s.note}</div>
                  {live && <div className="num mt-1.5 text-[11px] text-ink-4">{usd(live.modules[meta.sleeves.indexOf(s)]?.valueUsdc ?? 0)} onchain</div>}
                </li>
              ))}
            </ul>
          </Card>

          {isLoading && <Skeleton className="h-40" />}

          {data?.bonds && (
            <Card className="!p-0 overflow-hidden">
              <div className="flex items-center justify-between p-5 sm:px-6">
                <div>
                  <span className="label">Fixed income</span>
                  <h2 className="mt-1 font-display text-lg font-semibold text-ink">Tokenized debt</h2>
                </div>
                <TierBadge tier="DEMO-ONCHAIN" />
              </div>
              <div className="overflow-x-auto border-t border-white/[0.06]">
                <table className="data-table">
                  <thead>
                    <tr>
                      <th>Bond</th>
                      <th>Rating</th>
                      <th className="text-right">Coupon</th>
                      <th>Maturity</th>
                      <th className="text-right">Held</th>
                      <th className="text-right">Accrued</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.bonds.map((b) => (
                      <tr key={b.id}>
                        <td className="font-medium text-ink">{b.name}</td>
                        <td><span className="pill !py-0.5 !text-[10px]">{b.rating}</span></td>
                        <td className="num text-right text-ink-2">{b.couponPct.toFixed(2)}%</td>
                        <td className="text-ink-2">{dateOnly(b.maturity)}</td>
                        <td className="num text-right text-ink">{usd(b.unitsUsdc)}</td>
                        <td className="num text-right text-up">{usd(b.accruedUsdc, 4)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              <p className="px-5 py-3.5 text-[11px] leading-relaxed text-ink-4 sm:px-6">Demo bonds with demo credit. Coupons are paid in real testnet USDC from a demo reserve, Actual/365. Demo yield (testnet, no monetary value). Disclosure: credit and default risk.</p>
            </Card>
          )}

          {data?.calls && (
            <Card className="!p-0 overflow-hidden">
              <div className="flex items-center justify-between p-5 sm:px-6">
                <div>
                  <span className="label">Options overlay</span>
                  <h2 className="mt-1 font-display text-lg font-semibold text-ink">Covered calls</h2>
                </div>
                <TierBadge tier="DEMO-ONCHAIN" />
              </div>
              {data.calls.length === 0 ? (
                <div className="border-t border-white/[0.06] px-5 py-8 text-center text-sm text-ink-3 sm:px-6">No calls written yet. The keeper writes calls when the sleeve holds underlying.</div>
              ) : (
                <div className="overflow-x-auto border-t border-white/[0.06]">
                  <table className="data-table min-w-[720px]">
                    <thead>
                      <tr>
                        <th>Asset</th>
                        <th className="text-right">Qty</th>
                        <th className="text-right">Strike</th>
                        <th>Expiry</th>
                        <th className="text-right">Premium</th>
                        <th className="text-right">MTM</th>
                        <th className="text-right">Delta</th>
                        <th>Status</th>
                      </tr>
                    </thead>
                    <tbody>
                      {data.calls.map((c) => (
                        <tr key={c.id}>
                          <td className="font-medium text-ink">{c.underlying}</td>
                          <td className="num text-right text-ink-2">{num(c.qty, 6)}</td>
                          <td className="num text-right text-ink-2">{usd(c.strike)}</td>
                          <td className="text-ink-2">{dateOnly(c.expiry)}</td>
                          <td className="num text-right text-up">{usd(c.premiumUsdc, 4)}</td>
                          <td className="num text-right text-ink-2">{usd(c.mtmUsdc, 4)}</td>
                          <td className="num text-right text-ink-2">{c.delta.toFixed(2)}</td>
                          <td><span className={`pill !py-0.5 !text-[10px] ${c.status === 'Open' ? '!border-emerald-400/20 !bg-emerald-400/[0.08] !text-emerald-300' : ''}`}>{c.status}</span></td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
              <div className="mx-5 mt-4 rounded-xl border border-amber-300/20 bg-amber-300/[0.06] p-3 text-[11px] leading-relaxed text-amber-100/90 sm:mx-6">
                Covered calls cap upside, retain downside and can be assigned at expiry. Premium is paid in real testnet USDC by a demo counterparty. MTM and delta are Black-Scholes on simulated 30d vol (SIMULATED-OFFCHAIN).
              </div>
              {data.calls.length > 0 && (
                <div className="px-5 py-4 sm:px-6">
                  <div className="label mb-2">Expiry calendar</div>
                  <ul className="flex flex-wrap gap-2">
                    {[...data.calls].sort((a, b) => a.expiry - b.expiry).map((c) => (
                      <li key={c.id} className="rounded-lg border border-white/[0.08] bg-white/[0.03] px-2.5 py-1.5 text-[11px] text-ink-2">
                        <span className="font-semibold text-ink">{dateOnly(c.expiry)}</span> · {c.underlying} · {c.status}
                      </li>
                    ))}
                  </ul>
                </div>
              )}
            </Card>
          )}

          {data?.tactical && (
            <Card>
              <div className="flex items-center justify-between">
                <div>
                  <span className="label">Dynamic sleeve</span>
                  <h2 className="mt-1 font-display text-lg font-semibold text-ink">Tactical allocation</h2>
                </div>
                <TierBadge tier="DEMO-ONCHAIN" />
              </div>
              <div className="mt-4 flex flex-wrap items-center gap-6">
                <Donut
                  size={130}
                  data={[
                    { name: 'USDC cash', value: data.tactical.cashBps / 100 },
                    { name: 'dTBILL', value: data.tactical.tbillBps / 100 },
                    { name: 'Put collateral', value: data.tactical.putsBps / 100 },
                  ]}
                />
                <div className="min-w-[180px] flex-1">
                  <Stat label="Regime" value={data.regime.name} sub={`30d realised vol ${data.regime.vol30dPct.toFixed(0)}%`} tier="SIMULATED-OFFCHAIN" />
                  <div className="mt-4">
                    <Legend
                      data={[
                        { name: 'USDC cash', value: data.tactical.cashBps / 100 },
                        { name: 'dTBILL', value: data.tactical.tbillBps / 100 },
                        { name: 'Put collateral', value: data.tactical.putsBps / 100 },
                      ]}
                    />
                  </div>
                </div>
              </div>
              <p className="mt-4 text-[11px] leading-relaxed text-ink-4">{data.tactical.note}. Regime table: risk-off 50/40/10, high 30/30/40, normal 25/55/20, calm 20/80/0 (cash / dTBILL / puts).</p>
            </Card>
          )}

          <Card>
            <div className="flex items-center gap-2">
              <ShieldCheck className="h-4 w-4 text-brand" aria-hidden />
              <h2 className="font-display text-lg font-semibold text-ink">Methodology, fees and risks</h2>
            </div>
            <div className="mt-4 grid gap-5 sm:grid-cols-2">
              <div>
                <div className="label mb-2">Approach</div>
                <ul className="space-y-2 text-[13px] leading-relaxed text-ink-2">
                  {meta.methodology.map((m) => (
                    <li key={m} className="flex gap-2">
                      <span className="mt-1.5 h-1 w-1 shrink-0 rounded-full bg-brand" aria-hidden />
                      {m}
                    </li>
                  ))}
                </ul>
              </div>
              <div>
                <div className="label mb-2">Risks</div>
                <ul className="space-y-2 text-[13px] leading-relaxed text-ink-2">
                  {meta.risks.map((m) => (
                    <li key={m} className="flex gap-2">
                      <span className="mt-1.5 h-1 w-1 shrink-0 rounded-full bg-down" aria-hidden />
                      {m}
                    </li>
                  ))}
                </ul>
              </div>
            </div>
            <div className="mt-4 rounded-xl border border-white/[0.06] bg-white/[0.02] px-3.5 py-3 text-[12px] leading-relaxed text-ink-3">
              <span className="font-semibold text-ink-2">Fees: </span>{FEE_TEXT}
            </div>
            {data?.backtest && (
              <p className="mt-3 text-[11px] leading-relaxed text-ink-4">
                Illustrative backtest: 1M {pct(data.backtest.ret1m * 100, 1)}, 3M {pct(data.backtest.ret3m * 100, 1)}, 6M {pct(data.backtest.ret6m * 100, 1)}, vol {num(data.backtest.volAnn * 100, 1)}%, max drawdown {num(data.backtest.maxDrawdown * 100, 1)}% (SIMULATED-OFFCHAIN).
              </p>
            )}
            <a className="mt-4 inline-flex items-center gap-1.5 text-xs font-medium text-brand-2 transition hover:text-white" href={addrUrl(vaultOf(id))} target="_blank" rel="noopener noreferrer">
              Vault {short(vaultOf(id))} <ExternalLink className="h-3.5 w-3.5" />
            </a>
          </Card>
        </div>

        <aside className="min-w-0 lg:sticky lg:top-24 lg:self-start" id="invest">
          <InvestPanel meta={meta} onDone={() => void qc.invalidateQueries({ queryKey: ['api'] })} />
          <div className="mt-3 text-center text-[11px] text-ink-4">
            <Link className="underline decoration-white/20 underline-offset-2 transition hover:text-ink-2" to="/portfolio">Manage withdrawals in Portfolio</Link>
          </div>
        </aside>
      </div>
    </div>
  )
}
