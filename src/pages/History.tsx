import { useState } from 'react'
import { useAccount } from 'wagmi'
import { ArrowDownToLine, ArrowUpFromLine, ExternalLink, FileCheck2, ReceiptText, Repeat2, History as HistoryIcon } from 'lucide-react'
import { clsx } from 'clsx'
import { addrUrl, txUrl } from '@/lib/chain'
import { useApi, type HistoryRow } from '@/lib/api'
import { Card, Empty, PageTitle, Skeleton, TierBadge } from '@/components/ui'
import { ConnectButton } from '@/components/Layout'
import { short, when } from '@/lib/format'

const NAMES: Record<string, string> = {
  Deposit: 'Deposit into strategy', Withdraw: 'Instant withdrawal', DisclosureAccepted: 'Disclosure accepted', RedeemRequested: 'Withdrawal requested',
  RedeemFulfilled: 'Withdrawal fulfilled', RedeemClaimed: 'Withdrawal claimed', Transfer: 'Token transfer', Approval: 'Approval', Swapped: 'Demo swap',
  Subscribed: 'Bond subscription', CouponPaid: 'Coupon paid (USDC)', CallWritten: 'Call written', CallSettled: 'Call settled',
}

const FILTERS: { key: string; label: string; events?: string[] }[] = [
  { key: 'All', label: 'All activity' },
  { key: 'Deposits', label: 'Deposits', events: ['Deposit', 'Subscribed'] },
  { key: 'Withdrawals', label: 'Withdrawals', events: ['Withdraw', 'RedeemRequested', 'RedeemFulfilled', 'RedeemClaimed'] },
  { key: 'Trades', label: 'Trades', events: ['Swapped', 'Transfer', 'Approval'] },
  { key: 'Strategy', label: 'Strategy', events: ['DisclosureAccepted', 'CouponPaid', 'CallWritten', 'CallSettled'] },
]

function EventIcon({ name }: { name: string }) {
  const map: Record<string, { icon: typeof ArrowDownToLine; className: string }> = {
    Deposit: { icon: ArrowDownToLine, className: 'text-emerald-300 border-emerald-400/20 bg-emerald-400/[0.08]' },
    Subscribed: { icon: ArrowDownToLine, className: 'text-emerald-300 border-emerald-400/20 bg-emerald-400/[0.08]' },
    Withdraw: { icon: ArrowUpFromLine, className: 'text-brand-2 border-brand/25 bg-brand/10' },
    RedeemRequested: { icon: ArrowUpFromLine, className: 'text-brand-2 border-brand/25 bg-brand/10' },
    RedeemFulfilled: { icon: ArrowUpFromLine, className: 'text-brand-2 border-brand/25 bg-brand/10' },
    RedeemClaimed: { icon: ArrowUpFromLine, className: 'text-brand-2 border-brand/25 bg-brand/10' },
    Swapped: { icon: Repeat2, className: 'text-violet border-violet/25 bg-violet/10' },
    Transfer: { icon: Repeat2, className: 'text-violet border-violet/25 bg-violet/10' },
    CouponPaid: { icon: ReceiptText, className: 'text-amber-200 border-amber-300/20 bg-amber-300/[0.08]' },
    CallWritten: { icon: FileCheck2, className: 'text-silver border-white/15 bg-white/[0.05]' },
    CallSettled: { icon: FileCheck2, className: 'text-silver border-white/15 bg-white/[0.05]' },
  }
  const entry = map[name] ?? { icon: FileCheck2, className: 'text-ink-3 border-white/10 bg-white/[0.04]' }
  const Icon = entry.icon
  return (
    <span className={clsx('flex h-8 w-8 items-center justify-center rounded-lg border', entry.className)}>
      <Icon className="h-3.5 w-3.5" aria-hidden />
    </span>
  )
}

export default function History() {
  const { address, isConnected } = useAccount()
  const { data, isLoading } = useApi<HistoryRow[]>(address ? `/history/${address}` : null, 10000)
  const [filter, setFilter] = useState('All')

  if (!isConnected)
    return (
      <div>
        <PageTitle eyebrow="Workspace" title="Activity" />
        <Empty
          icon={<HistoryIcon className="h-5 w-5" />}
          title="Connect your wallet"
          body="Indexed onchain activity for your address, with explorer links and tier badges."
          action={<ConnectButton />}
        />
      </div>
    )

  const active = FILTERS.find((f) => f.key === filter)
  const rows = (data ?? []).filter((r) => filter === 'All' || active?.events?.includes(r.event_name))

  return (
    <div>
      <PageTitle
        eyebrow="Workspace"
        title="Activity"
        sub="Events indexed from Arc Testnet logs. Each event is stored once, even if the indexer rescans."
        right={<span className="pill"><span className="h-1.5 w-1.5 rounded-full bg-emerald-400" aria-hidden /> Live indexer</span>}
      />

      <div className="mb-4 flex flex-wrap gap-1.5">
        {FILTERS.map((f) => (
          <button
            key={f.key}
            onClick={() => setFilter(f.key)}
            className={clsx('chip', filter === f.key && '!border-brand/40 !bg-brand/[0.12] !text-ink')}
          >
            {f.label}
          </button>
        ))}
      </div>

      {isLoading && <Skeleton className="h-48" />}

      {!isLoading && (data?.length ?? 0) === 0 && (
        <Empty
          icon={<ReceiptText className="h-5 w-5" />}
          title="No activity yet"
          body="Your deposits, withdrawals and trades appear here within a few seconds of confirmation."
        />
      )}

      {data && data.length > 0 && rows.length === 0 && (
        <Card className="text-center">
          <p className="text-sm text-ink-3">No events match this filter.</p>
        </Card>
      )}

      {rows.length > 0 && (
        <Card className="!p-0 overflow-hidden">
          <div className="overflow-x-auto">
            <table className="data-table min-w-[760px]">
              <thead>
                <tr>
                  <th>Time</th>
                  <th>Event</th>
                  <th>Contract</th>
                  <th>Tier</th>
                  <th className="text-right">Transaction</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={`${r.tx_hash}-${r.log_index}`}>
                    <td className="whitespace-nowrap text-[13px] text-ink-2">{r.block_time ? when(r.block_time) : `#${r.block_number}`}</td>
                    <td>
                      <div className="flex items-center gap-3">
                        <EventIcon name={r.event_name} />
                        <span className="font-medium text-ink">{NAMES[r.event_name] ?? r.event_name}</span>
                      </div>
                    </td>
                    <td>
                      <a className="mono text-xs text-ink-3 underline decoration-white/15 underline-offset-2 transition hover:text-ink" href={addrUrl(r.emitter)} target="_blank" rel="noopener noreferrer">
                        {short(r.emitter)}
                      </a>
                    </td>
                    <td><TierBadge tier={r.tier} /></td>
                    <td className="text-right">
                      <a className="inline-flex items-center gap-1 text-xs font-medium text-brand-2 transition hover:text-white" href={txUrl(r.tx_hash)} target="_blank" rel="noopener noreferrer">
                        {short(r.tx_hash)} <ExternalLink className="h-3 w-3" />
                      </a>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Card>
      )}
    </div>
  )
}
