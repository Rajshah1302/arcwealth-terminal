import type { ReactNode } from 'react'
import { clsx } from 'clsx'
import { Info, ShieldAlert, TriangleAlert } from 'lucide-react'

export type Tier = 'LIVE-TESTNET' | 'DEMO-ONCHAIN' | 'SIMULATED-OFFCHAIN'

const TIER_STYLE: Record<Tier, string> = {
  'LIVE-TESTNET': 'border-emerald-400/20 bg-emerald-400/[0.08] text-emerald-300',
  'DEMO-ONCHAIN': 'border-amber-300/20 bg-amber-300/[0.08] text-amber-200',
  'SIMULATED-OFFCHAIN': 'border-white/10 bg-white/[0.05] text-ink-3',
}
const TIER_DOT: Record<Tier, string> = {
  'LIVE-TESTNET': 'bg-emerald-400 shadow-[0_0_8px_1px_rgba(52,211,153,0.75)]',
  'DEMO-ONCHAIN': 'bg-amber-300 shadow-[0_0_8px_1px_rgba(252,211,77,0.6)]',
  'SIMULATED-OFFCHAIN': 'bg-ink-3',
}
const TIER_HELP: Record<Tier, string> = {
  'LIVE-TESTNET': 'Real Arc Testnet contract we do not own',
  'DEMO-ONCHAIN': 'Our stand-in contract: real transactions, no monetary value',
  'SIMULATED-OFFCHAIN': 'Computed by the backend: illustrative only',
}

export function TierBadge({ tier, className }: { tier: string; className?: string }) {
  const t = (tier in TIER_STYLE ? tier : 'SIMULATED-OFFCHAIN') as Tier
  return (
    <span
      title={TIER_HELP[t]}
      className={clsx('inline-flex items-center gap-1.5 whitespace-nowrap rounded-full border px-2 py-0.5 text-[9px] font-semibold uppercase tracking-[0.1em]', TIER_STYLE[t], className)}
    >
      <span className={clsx('h-1.5 w-1.5 rounded-full', TIER_DOT[t])} aria-hidden />
      {t}
    </span>
  )
}

export function Card({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={clsx('card', className)}>{children}</div>
}

export function Stat({
  label,
  value,
  sub,
  tier,
  tone,
  icon,
  className,
}: {
  label: string
  value: ReactNode
  sub?: ReactNode
  tier?: string
  tone?: 'up' | 'down'
  icon?: ReactNode
  className?: string
}) {
  return (
    <div className={clsx('group min-w-0', className)}>
      <div className="flex items-center gap-2">
        {icon && <span className="text-brand/80">{icon}</span>}
        <span className="label">{label}</span>
        {tier && <TierBadge tier={tier} />}
      </div>
      <div className={clsx('num mt-2.5 truncate font-display text-[26px] font-semibold leading-none tracking-[-0.02em] text-ink sm:text-[30px]', tone === 'up' && 'text-up', tone === 'down' && 'text-down')}>
        {value}
      </div>
      {sub && <div className="mt-1.5 truncate text-xs text-ink-3">{sub}</div>}
    </div>
  )
}

export function Notice({ children, tone = 'info' }: { children: ReactNode; tone?: 'info' | 'warn' | 'error' }) {
  const Icon = tone === 'error' ? ShieldAlert : tone === 'warn' ? TriangleAlert : Info
  return (
    <div
      role={tone === 'error' ? 'alert' : 'note'}
      className={clsx(
        'flex items-start gap-2.5 rounded-xl border px-3.5 py-3 text-[13px] leading-relaxed',
        tone === 'info' && 'border-white/10 bg-white/[0.04] text-ink-2',
        tone === 'warn' && 'border-amber-300/20 bg-amber-300/[0.07] text-amber-100',
        tone === 'error' && 'border-down/25 bg-down/[0.09] text-rose-200',
      )}
    >
      <Icon className={clsx('mt-0.5 h-4 w-4 shrink-0', tone === 'warn' ? 'text-amber-200' : tone === 'error' ? 'text-down' : 'text-brand')} aria-hidden />
      <div className="min-w-0">{children}</div>
    </div>
  )
}

export function Skeleton({ className }: { className?: string }) {
  return <div className={clsx('skeleton', className)} />
}

export function PageTitle({
  title,
  sub,
  right,
  eyebrow,
}: {
  title: string
  sub?: ReactNode
  right?: ReactNode
  eyebrow?: ReactNode
}) {
  return (
    <div className="mb-7 flex flex-wrap items-end justify-between gap-4">
      <div className="min-w-0">
        {eyebrow && <div className="mb-2 flex items-center gap-2 text-[10px] font-semibold uppercase tracking-[0.2em] text-brand/80">{eyebrow}</div>}
        <h1 className="font-display text-[28px] font-semibold leading-tight tracking-[-0.025em] text-ink sm:text-[34px]">{title}</h1>
        {sub && <p className="mt-2 max-w-2xl text-pretty text-sm leading-relaxed text-ink-3">{sub}</p>}
      </div>
      {right && <div className="flex shrink-0 flex-wrap items-center gap-2">{right}</div>}
    </div>
  )
}

export function Empty({ title, body, action, icon }: { title: string; body: string; action?: ReactNode; icon?: ReactNode }) {
  return (
    <div className="card flex flex-col items-center gap-3 px-6 py-14 text-center">
      <div className="mb-1 flex h-12 w-12 items-center justify-center rounded-2xl border border-white/10 bg-gradient-to-b from-white/[0.09] to-transparent text-brand">
        {icon ?? <Info className="h-5 w-5" />}
      </div>
      <div className="font-display text-xl font-semibold text-ink">{title}</div>
      <p className="max-w-md text-pretty text-sm leading-relaxed text-ink-3">{body}</p>
      {action && <div className="mt-2">{action}</div>}
    </div>
  )
}
