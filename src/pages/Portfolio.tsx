import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useAccount } from 'wagmi'
import { useQueryClient } from '@tanstack/react-query'
import { ArrowUpRight, Briefcase, Layers3, TrendingUp } from 'lucide-react'
import { useApi, type Position } from '@/lib/api'
import { Card, Empty, PageTitle, Skeleton, Stat, TierBadge } from '@/components/ui'
import { ConnectButton } from '@/components/Layout'
import WithdrawPanel from '@/components/WithdrawPanel'
import { Donut, Legend, PALETTE } from '@/components/charts'
import { num, pct, usd } from '@/lib/format'

export default function Portfolio() {
  const { address, isConnected } = useAccount()
  const qc = useQueryClient()
  const { data, isLoading } = useApi<{ positions: Position[] }>(address ? `/portfolio/${address}` : null, 8000)
  const [open, setOpen] = useState<string | null>(null)

  if (!isConnected)
    return (
      <div>
        <PageTitle eyebrow="Holdings" title="Portfolio" />
        <Empty
          icon={<Briefcase className="h-5 w-5" />}
          title="Connect your wallet"
          body="Your SIF shares, cost basis, NAV and P&L are read from the vault contracts on Arc Testnet."
          action={<ConnectButton />}
        />
      </div>
    )

  const positions = data?.positions ?? []
  const value = positions.reduce((a, p) => a + p.valueUsdc, 0)
  const basis = positions.reduce((a, p) => a + p.costBasisUsdc, 0)
  const ret = basis > 0 ? (value / basis - 1) * 100 : 0
  const pnl = value - basis
  const allocation = positions
    .filter((p) => p.valueUsdc > 0)
    .map((p) => ({ name: p.name, value: Number(((p.valueUsdc / (value || 1)) * 100).toFixed(1)) }))

  return (
    <div>
      <PageTitle
        eyebrow="Holdings"
        title="Portfolio"
        sub="Positions are read from the strategy vaults and the investor registry on chain. Returns are demo yield (testnet, no monetary value)."
        right={
          <Link to="/sif" className="btn-primary">
            Invest <ArrowUpRight className="h-4 w-4" />
          </Link>
        }
      />

      <Card className="overflow-hidden">
        <div className="grid gap-6 lg:grid-cols-[1.45fr_1fr]">
          <div className="min-w-0">
            <div className="flex items-center gap-2">
              <span className="label">Current NAV</span>
              <TierBadge tier="DEMO-ONCHAIN" />
            </div>
            <div className="num mt-2.5 font-display text-[40px] font-semibold leading-none tracking-[-0.03em] text-ink sm:text-[46px]">{usd(value)}</div>
            <div className="mt-2.5 flex flex-wrap items-center gap-2 text-xs">
              <span className={`pill ${pnl >= 0 ? '!border-up/25 !bg-up/10 !text-up' : '!border-down/25 !bg-down/10 !text-down'}`}>
                <TrendingUp className="h-3 w-3" aria-hidden />
                {usd(pnl, 4)} · {pct(ret)}
              </span>
              <span className="text-ink-3">on {usd(basis)} cost basis</span>
            </div>
            <div className="mt-6 grid grid-cols-2 gap-5 border-t border-white/[0.06] pt-5 sm:grid-cols-3">
              <Stat label="Cost basis" value={usd(basis)} sub="Deposited capital" />
              <Stat label="P&L" value={usd(pnl, 4)} tone={pnl >= 0 ? 'up' : 'down'} sub="Mark to onchain NAV" />
              <Stat label="Positions" value={String(positions.length)} sub="Active SIF vaults" icon={<Layers3 className="h-3.5 w-3.5" />} />
            </div>
          </div>

          <div className="rounded-2xl border border-white/[0.06] bg-black/20 p-4">
            <div className="flex items-center justify-between">
              <span className="label">Allocation</span>
              <span className="text-[10px] uppercase tracking-[0.14em] text-ink-4">By NAV</span>
            </div>
            {allocation.length === 0 ? (
              <p className="mt-6 text-center text-sm text-ink-3">No allocation yet.</p>
            ) : (
              <div className="mt-4 flex flex-col items-center gap-4 sm:flex-row lg:flex-col">
                <Donut data={allocation} size={150} />
                <div className="w-full">
                  <Legend data={allocation} />
                </div>
              </div>
            )}
          </div>
        </div>
      </Card>

      {isLoading && <Skeleton className="mt-4 h-40" />}

      {!isLoading && positions.length === 0 && (
        <div className="mt-4">
          <Empty
            icon={<Layers3 className="h-5 w-5" />}
            title="No SIF positions yet"
            body="Invest at least 10 USDC in a strategy to see shares, cost basis and NAV here."
            action={<Link to="/sif" className="btn-primary">Browse strategies</Link>}
          />
        </div>
      )}

      <div className="mt-4 space-y-4">
        {positions.map((p, i) => (
          <Card key={p.strategy} className="!p-0 overflow-hidden transition duration-300 hover:border-white/[0.13]">
            <div className="flex flex-wrap items-center justify-between gap-3 border-b border-white/[0.06] p-5 sm:px-6">
              <div className="flex items-center gap-3">
                <span className="icon-tile" style={{ color: PALETTE[i % PALETTE.length] }}>
                  <Layers3 className="h-4 w-4" />
                </span>
                <div>
                  <div className="flex items-center gap-2">
                    <h2 className="font-display text-lg font-semibold text-ink">{p.name}</h2>
                    <TierBadge tier="DEMO-ONCHAIN" />
                  </div>
                  <div className="mt-0.5 text-[11px] uppercase tracking-[0.12em] text-ink-4">{p.strategy} · {p.vault.slice(0, 6)}…{p.vault.slice(-4)}</div>
                </div>
              </div>
              <div className="flex gap-2">
                <Link className="btn-ghost !min-h-[36px] !px-3 text-xs" to={`/sif/${p.strategy}`}>
                  View <ArrowUpRight className="h-3.5 w-3.5" />
                </Link>
                <button className="btn-ghost !min-h-[36px] !px-3 text-xs" onClick={() => setOpen(open === p.strategy ? null : p.strategy)}>
                  {open === p.strategy ? 'Hide withdraw' : 'Withdraw'}
                </button>
              </div>
            </div>
            <div className="grid grid-cols-2 gap-5 p-5 sm:grid-cols-5 sm:px-6">
              <Stat label="Shares" value={num(p.shares, 4)} />
              <Stat label="Share price" value={usd(p.sharePrice, 4)} sub={`Entry ${usd(p.entrySharePrice, 4)}`} />
              <Stat label="NAV" value={usd(p.valueUsdc)} />
              <Stat label="Cost basis" value={usd(p.costBasisUsdc)} />
              <Stat label="Return" value={pct(p.totalReturnPct)} tone={p.totalReturnPct >= 0 ? 'up' : 'down'} />
            </div>
            {(p.pendingRedeemShares > 0 || p.claimableUsdc > 0) && (
              <p className="mx-5 mb-4 rounded-xl border border-white/[0.06] bg-white/[0.02] px-3 py-2 text-xs text-ink-3 sm:mx-6">
                Pending withdrawal: <span className="num text-ink-2">{num(p.pendingRedeemShares, 4)}</span> shares queued,{' '}
                <span className="num text-ink-2">{usd(p.claimableUsdc)}</span> claimable.
              </p>
            )}
            {open === p.strategy && (
              <div className="border-t border-white/[0.06] p-5 sm:px-6">
                <WithdrawPanel p={p} onDone={() => void qc.invalidateQueries({ queryKey: ['api'] })} />
              </div>
            )}
          </Card>
        ))}
      </div>
    </div>
  )
}
