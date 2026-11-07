import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { useAccount } from 'wagmi'
import { ArrowUpRight, Coins, PieChart, Sparkles, TrendingUp, Wallet } from 'lucide-react'
import { useApi, type Position } from '@/lib/api'
import { useHoldings } from '@/lib/holdings'
import { useUsdcBalance } from '@/lib/hooks'
import { Card, PageTitle, Stat, TierBadge } from '@/components/ui'
import { AreaLine, Donut, Legend } from '@/components/charts'
import { ConnectButton } from '@/components/Layout'
import { num, pct, usd } from '@/lib/format'

function MetricCard({ icon, label, value, sub, tier, tone }: { icon: ReactNode; label: string; value: string; sub?: string; tier?: string; tone?: 'up' | 'down' }) {
  return (
    <Card className="group p-5 transition duration-300 hover:border-white/[0.14] hover:shadow-glow">
      <div className="flex items-start justify-between gap-2">
        <Stat label={label} value={value} sub={sub} tier={tier} tone={tone} />
        <span className="icon-tile transition group-hover:border-brand/30 group-hover:text-brand">{icon}</span>
      </div>
    </Card>
  )
}

export default function Dashboard() {
  const { address, isConnected } = useAccount()
  const port = useApi<{ positions: Position[] }>(address ? `/portfolio/${address}` : null, 10000)
  const { holdings } = useHoldings(address)
  const bal = useUsdcBalance(address)
  const first = port.data?.positions[0]?.strategy
  const nav = useApi<{ points: { ts: string; share_price: number }[] }>(first ? `/strategies/${first}/nav` : null, 30000)

  if (!isConnected)
    return (
      <div>
        <PageTitle eyebrow="Overview" title="Dashboard" sub="Your command center for strategy positions, wallet liquidity and demo market exposure on Arc Testnet." />
        <div className="grid gap-4 lg:grid-cols-[1.35fr_1fr]">
          <Card className="relative overflow-hidden">
            <div className="pointer-events-none absolute -right-24 -top-24 h-64 w-64 rounded-full bg-brand/20 blur-3xl" aria-hidden />
            <div className="relative">
              <span className="flex h-12 w-12 items-center justify-center rounded-2xl border border-white/10 bg-gradient-to-b from-white/[0.1] to-transparent text-brand">
                <Wallet className="h-5 w-5" />
              </span>
              <h2 className="mt-5 font-display text-2xl font-semibold tracking-tight text-ink">Connect your wallet</h2>
              <p className="mt-2 max-w-md text-sm leading-relaxed text-ink-3">
                See SIF positions, wallet USDC and demo holdings in one place. Everything is read directly from Arc Testnet contracts.
              </p>
              <div className="mt-5">
                <ConnectButton />
              </div>
              <ul className="mt-8 grid gap-3 sm:grid-cols-3">
                {[
                  { icon: TrendingUp, t: 'Live NAV', d: 'Onchain share price and returns' },
                  { icon: PieChart, t: 'Allocation', d: 'Exposure across strategies' },
                  { icon: Coins, t: 'Holdings', d: 'Wallet, live and demo assets' },
                ].map(({ icon: Icon, t, d }) => (
                  <li key={t} className="rounded-xl border border-white/[0.06] bg-white/[0.02] p-3">
                    <Icon className="h-4 w-4 text-brand/80" aria-hidden />
                    <div className="mt-2 text-xs font-semibold text-ink">{t}</div>
                    <div className="mt-0.5 text-[11px] leading-relaxed text-ink-3">{d}</div>
                  </li>
                ))}
              </ul>
            </div>
          </Card>
          <Card className="flex flex-col justify-between">
            <div>
              <div className="flex items-center gap-2">
                <span className="label">Platform</span>
                <TierBadge tier="DEMO-ONCHAIN" />
              </div>
              <h2 className="mt-2 font-display text-xl font-semibold text-ink">Institutional rails, testnet reality</h2>
              <p className="mt-2 text-sm leading-relaxed text-ink-3">Every figure carries an honesty tier so you know what is live testnet, what is a demo stand-in and what is simulated.</p>
            </div>
            <div className="mt-6 space-y-2.5">
              {(['LIVE-TESTNET', 'DEMO-ONCHAIN', 'SIMULATED-OFFCHAIN'] as const).map((t) => (
                <div key={t} className="flex items-center justify-between rounded-xl border border-white/[0.06] bg-black/20 px-3 py-2.5">
                  <TierBadge tier={t} />
                  <span className="text-[10px] text-ink-4">{t === 'LIVE-TESTNET' ? 'Real contracts' : t === 'DEMO-ONCHAIN' ? 'Our vaults' : 'Backend models'}</span>
                </div>
              ))}
            </div>
          </Card>
        </div>
      </div>
    )

  const sif = port.data?.positions ?? []
  const sifValue = sif.reduce((a, p) => a + p.valueUsdc, 0)
  const basis = sif.reduce((a, p) => a + p.costBasisUsdc, 0)
  const usdcBal = Number(bal.data ?? 0n) / 1e6
  const live = holdings.filter((h) => h.tier === 'LIVE-TESTNET').reduce((a, h) => a + h.value, 0)
  const demo = holdings.filter((h) => h.tier === 'DEMO-ONCHAIN').reduce((a, h) => a + h.value, 0)
  const ret = basis > 0 ? (sifValue / basis - 1) * 100 : 0
  const parts = [
    { name: 'SIF positions', value: sifValue },
    { name: 'Wallet USDC', value: usdcBal },
    { name: 'Live testnet tokens', value: live },
    { name: 'Demo tokens', value: demo },
  ].filter((x) => x.value > 0)
  const total = parts.reduce((a, b) => a + b.value, 0)
  const donut = parts.map((x) => ({ name: x.name, value: Number(((x.value / (total || 1)) * 100).toFixed(1)) }))
  const navPoints = nav.data?.points.map((p) => ({ t: p.ts, v: Number(p.share_price) })) ?? []
  const navReady = navPoints.length > 1
  const sharePrice = sif[0]?.sharePrice

  return (
    <div>
      <PageTitle
        eyebrow="Overview"
        title="Dashboard"
        sub="Wallet USDC is the Arc ERC-20 balance (the same pool that pays gas). Demo token values use simulated prices."
        right={
          <>
            <Link to="/portfolio" className="btn-ghost">
              Portfolio <ArrowUpRight className="h-4 w-4" />
            </Link>
            <Link to="/sif" className="btn-primary">
              Invest <ArrowUpRight className="h-4 w-4" />
            </Link>
          </>
        }
      />

      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <MetricCard icon={<Wallet className="h-[18px] w-[18px]" />} label="Wallet USDC" value={usd(usdcBal)} tier="LIVE-TESTNET" sub="ERC-20 balance" />
        <MetricCard icon={<Sparkles className="h-[18px] w-[18px]" />} label="SIF NAV" value={usd(sifValue)} tier="DEMO-ONCHAIN" sub={`Cost basis ${usd(basis)}`} />
        <MetricCard icon={<TrendingUp className="h-[18px] w-[18px]" />} label="Total return" value={pct(ret)} tone={ret >= 0 ? 'up' : 'down'} sub="Demo yield · no monetary value" />
        <MetricCard icon={<Coins className="h-[18px] w-[18px]" />} label="Demo token value" value={usd(demo)} tier="SIMULATED-OFFCHAIN" sub={`Live tokens ${usd(live)}`} />
      </div>

      <div className="mt-4 grid gap-4 xl:grid-cols-[1.6fr_1fr]">
        <Card className="overflow-hidden">
          <div className="flex flex-wrap items-start justify-between gap-4">
            <div>
              <div className="flex items-center gap-2">
                <span className="label">Total portfolio value</span>
                <TierBadge tier="DEMO-ONCHAIN" />
              </div>
              <div className="num mt-2.5 font-display text-[38px] font-semibold leading-none tracking-[-0.03em] text-ink sm:text-[44px]">{usd(total)}</div>
              <div className="mt-2.5 flex flex-wrap items-center gap-2 text-xs">
                <span className={`pill ${ret >= 0 ? '!border-up/25 !bg-up/10 !text-up' : '!border-down/25 !bg-down/10 !text-down'}`}>
                  <TrendingUp className="h-3 w-3" aria-hidden />
                  {pct(ret)}
                </span>
                <span className="text-ink-3">return on {usd(basis)} cost basis</span>
              </div>
            </div>
            <div className="text-right">
              <div className="label">Share price</div>
              <div className="num mt-1.5 font-display text-lg font-semibold text-ink">{sharePrice ? usd(sharePrice, 4) : '—'}</div>
              <div className="mt-0.5 text-[10px] uppercase tracking-[0.14em] text-ink-4">{sif[0]?.name ?? 'No position'}</div>
            </div>
          </div>
          <div className="mt-4">
            {navReady ? (
              <AreaLine data={navPoints} x="t" y="v" height={236} showGrid fmt={(v) => usd(v, 4)} />
            ) : (
              <div className="flex h-[236px] flex-col items-center justify-center gap-2 rounded-xl border border-dashed border-white/[0.08] bg-black/20 text-center">
                <span className="flex h-10 w-10 items-center justify-center rounded-full border border-white/10 bg-white/[0.03] text-ink-3">
                  <TrendingUp className="h-4 w-4" />
                </span>
                <p className="text-sm font-medium text-ink-2">{first ? 'Collecting onchain snapshots' : 'No strategy position yet'}</p>
                <p className="max-w-xs text-xs text-ink-3">
                  {first ? 'The keeper records a share-price snapshot every few minutes.' : 'Invest in a strategy to track its onchain share price here.'}
                </p>
                {!first && <Link to="/sif" className="btn-ghost mt-1 !min-h-[36px] !px-3 text-xs">Browse strategies</Link>}
              </div>
            )}
          </div>
        </Card>

        <Card>
          <div className="flex items-center justify-between">
            <div>
              <span className="label">Asset allocation</span>
              <h2 className="mt-1 font-display text-lg font-semibold text-ink">Portfolio mix</h2>
            </div>
            <PieChart className="h-4 w-4 text-ink-4" aria-hidden />
          </div>
          {donut.length === 0 ? (
            <div className="flex h-[260px] flex-col items-center justify-center gap-2 text-center">
              <p className="text-sm text-ink-3">Fund your wallet with the faucet, then invest to build an allocation.</p>
              <a href="https://faucet.circle.com" target="_blank" rel="noopener noreferrer" className="btn-ghost mt-1 !min-h-[36px] !px-3 text-xs">
                Open faucet <ArrowUpRight className="h-3.5 w-3.5" />
              </a>
            </div>
          ) : (
            <div className="mt-5 flex flex-col items-center gap-5">
              <Donut data={donut} size={186} center={{ label: 'Total', value: usd(total, 0) }} />
              <Legend data={donut} />
            </div>
          )}
        </Card>
      </div>

      <div className="mt-4 grid gap-4 xl:grid-cols-[1.6fr_1fr]">
        <Card className="!p-0">
          <div className="flex items-center justify-between p-5 sm:px-6">
            <div>
              <span className="label">Positions</span>
              <h2 className="mt-1 font-display text-lg font-semibold text-ink">Strategies held</h2>
            </div>
            <Link to="/portfolio" className="btn-subtle !min-h-[34px] !px-2.5 text-xs">
              Manage <ArrowUpRight className="h-3.5 w-3.5" />
            </Link>
          </div>
          {sif.length === 0 ? (
            <div className="border-t border-white/[0.06] px-6 py-10 text-center">
              <p className="text-sm text-ink-3">No SIF positions yet. Invest at least 10 USDC to get started.</p>
              <Link to="/sif" className="btn-primary mt-3 !min-h-[36px] !px-3 text-xs">
                Browse strategies
              </Link>
            </div>
          ) : (
            <div className="overflow-x-auto border-t border-white/[0.06]">
              <table className="data-table !min-w-[520px]">
                <thead>
                  <tr>
                    <th>Strategy</th>
                    <th className="text-right">Shares</th>
                    <th className="text-right">NAV</th>
                    <th className="text-right">Return</th>
                    <th className="text-right">&nbsp;</th>
                  </tr>
                </thead>
                <tbody>
                  {sif.map((p) => (
                    <tr key={p.strategy}>
                      <td>
                        <div className="font-semibold text-ink">{p.name}</div>
                        <div className="mt-0.5 text-[11px] uppercase tracking-[0.1em] text-ink-4">{p.strategy}</div>
                      </td>
                      <td className="num text-right text-ink-2">{num(p.shares, 4)}</td>
                      <td className="num text-right font-medium text-ink">{usd(p.valueUsdc)}</td>
                      <td className={`num text-right font-medium ${p.totalReturnPct >= 0 ? 'text-up' : 'text-down'}`}>{pct(p.totalReturnPct)}</td>
                      <td className="text-right">
                        <Link to={`/sif/${p.strategy}`} className="inline-flex items-center gap-1 text-xs font-medium text-brand-2 hover:text-white">
                          View <ArrowUpRight className="h-3 w-3" />
                        </Link>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </Card>

        <Card>
          <div className="flex items-center justify-between">
            <div>
              <span className="label">Shortcuts</span>
              <h2 className="mt-1 font-display text-lg font-semibold text-ink">Quick actions</h2>
            </div>
          </div>
          <div className="mt-4 space-y-2">
            {[
              { to: '/sif', label: 'Invest in a SIF vault', note: 'From 10 USDC', icon: Sparkles },
              { to: '/trading', label: 'Trade demo assets', note: 'dBTC, dETH, dXAU', icon: CandlestickChartIcon },
              { to: '/lending', label: 'Lend or borrow', note: 'Demo pool, 70% LTV', icon: LandmarkIcon },
            ].map(({ to, label, note, icon: Icon }) => (
              <Link key={to} to={to} className="group flex items-center gap-3 rounded-xl border border-transparent px-2 py-2.5 transition hover:border-white/[0.08] hover:bg-white/[0.03]">
                <span className="icon-tile !h-8 !w-8 transition group-hover:border-brand/30 group-hover:text-brand">
                  <Icon className="h-4 w-4" />
                </span>
                <span className="min-w-0">
                  <span className="block text-[13px] font-medium text-ink">{label}</span>
                  <span className="block text-[11px] text-ink-4">{note}</span>
                </span>
                <ArrowUpRight className="ml-auto h-3.5 w-3.5 text-ink-4 transition group-hover:text-ink-2" />
              </Link>
            ))}
            <a
              href="https://faucet.circle.com"
              target="_blank"
              rel="noopener noreferrer"
              className="group flex items-center gap-3 rounded-xl border border-transparent px-2 py-2.5 transition hover:border-white/[0.08] hover:bg-white/[0.03]"
            >
              <span className="icon-tile !h-8 !w-8 transition group-hover:border-brand/30 group-hover:text-brand">
                <Coins className="h-4 w-4" />
              </span>
              <span className="min-w-0">
                <span className="block text-[13px] font-medium text-ink">Get test USDC</span>
                <span className="block text-[11px] text-ink-4">Circle faucet</span>
              </span>
              <ArrowUpRight className="ml-auto h-3.5 w-3.5 text-ink-4 transition group-hover:text-ink-2" />
            </a>
          </div>
        </Card>
      </div>
    </div>
  )
}

function CandlestickChartIcon(props: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" className={props.className} aria-hidden>
      <path d="M7 4v3M7 17v3M17 4v5M17 15v5M4.5 7h5v10h-5zM14.5 9h5v6h-5z" />
    </svg>
  )
}

function LandmarkIcon(props: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" className={props.className} aria-hidden>
      <path d="M3 21h18M4 21V9l8-5 8 5v12M9 21v-6h6v6M8 12v.01M12 12v.01M16 12v.01" />
    </svg>
  )
}
