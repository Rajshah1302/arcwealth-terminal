import { useState } from 'react'
import { NavLink, Link, Outlet, useLocation } from 'react-router-dom'
import { motion } from 'framer-motion'
import { ConnectKitButton } from 'connectkit'
import { useAccount, useSwitchChain } from 'wagmi'
import {
  AlertTriangle,
  ArrowUpRight,
  Briefcase,
  CandlestickChart,
  ChevronRight,
  History,
  Landmark,
  Layers3,
  LayoutDashboard,
  Menu,
  Radio,
  Settings2,
  UserRound,
  Wallet,
  X,
  type LucideIcon,
} from 'lucide-react'
import { clsx } from 'clsx'
import { CHAIN_ID } from '@/lib/chain'
import { useUsdcBalance } from '@/lib/hooks'
import { usd } from '@/lib/format'
import { FOOTER_DISCLAIMER } from '@/shared/market'

type NavItem = { to: string; label: string; icon: LucideIcon }

const GROUPS: { label: string; items: NavItem[] }[] = [
  {
    label: 'Workspace',
    items: [
      { to: '/dashboard', label: 'Overview', icon: LayoutDashboard },
      { to: '/portfolio', label: 'Portfolio', icon: Briefcase },
      { to: '/history', label: 'Activity', icon: History },
    ],
  },
  {
    label: 'Markets',
    items: [
      { to: '/trading', label: 'Trading', icon: CandlestickChart },
      { to: '/lending', label: 'Lending', icon: Landmark },
    ],
  },
  {
    label: 'Strategies',
    items: [{ to: '/sif', label: 'SIF Vaults', icon: Layers3 }],
  },
  {
    label: 'System',
    items: [
      { to: '/profile', label: 'Account', icon: UserRound },
      { to: '/admin', label: 'Administration', icon: Settings2 },
    ],
  },
]

const ALL_ITEMS = GROUPS.flatMap((g) => g.items)

function Logo() {
  return (
    <Link to="/" className="group flex items-center gap-3" aria-label="ARCWEALTH home">
      <span className="relative flex h-10 w-10 items-center justify-center overflow-hidden rounded-xl border border-white/10 bg-[#0c0c12] shadow-inner-line">
        <span className="absolute inset-0 bg-gradient-to-br from-brand/25 via-transparent to-violet/20" />
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" aria-hidden className="relative">
          <path d="M4 19 L9.5 4 L14 13 L16.5 9 L20 19" stroke="#dbe6ff" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </span>
      <span className="min-w-0">
        <span className="block font-display text-[14px] font-semibold tracking-[0.18em] text-ink">ARCWEALTH</span>
        <span className="block text-[8.5px] uppercase tracking-[0.22em] text-ink-4">Digital Asset Management</span>
      </span>
    </Link>
  )
}

function WrongNetwork() {
  const { isConnected, chainId } = useAccount()
  const { switchChain, isPending } = useSwitchChain()
  if (!isConnected || chainId === CHAIN_ID) return null
  return (
    <div role="alert" className="flex flex-wrap items-center justify-center gap-2 border-b border-amber-300/20 bg-amber-300/[0.08] px-4 py-2 text-center text-[13px] text-amber-100">
      <AlertTriangle className="h-4 w-4 text-amber-300" aria-hidden />
      Your wallet is on the wrong network. ARCWEALTH runs on Arc Testnet only.
      <button className="font-semibold underline decoration-amber-300/50 underline-offset-2 hover:text-white disabled:opacity-60" disabled={isPending} onClick={() => switchChain({ chainId: CHAIN_ID })}>
        {isPending ? 'Switching…' : 'Switch to Arc Testnet'}
      </button>
    </div>
  )
}

export function ConnectButton({ className }: { className?: string }) {
  return (
    <ConnectKitButton.Custom>
      {({ isConnected, show, truncatedAddress }) => (
        <button
          onClick={show}
          className={clsx(
            isConnected ? 'btn-ghost' : 'btn-primary',
            'min-h-[42px] whitespace-nowrap',
            className,
          )}
        >
          <Wallet className="h-4 w-4 opacity-80" aria-hidden />
          {isConnected ? <span className="mono text-xs">{truncatedAddress}</span> : 'Connect wallet'}
        </button>
      )}
    </ConnectKitButton.Custom>
  )
}

function NetworkCard() {
  const { address, isConnected } = useAccount()
  const bal = useUsdcBalance(address)
  return (
    <div className="rounded-xl border border-white/[0.07] bg-white/[0.02] p-3.5">
      <div className="flex items-center justify-between">
        <span className="flex items-center gap-2 text-xs font-medium text-ink-2">
          <span className="relative flex h-2 w-2">
            <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-400 opacity-40" />
            <span className="relative inline-flex h-2 w-2 rounded-full bg-emerald-400" />
          </span>
          Arc Testnet
        </span>
        <span className="text-[9px] font-semibold uppercase tracking-[0.16em] text-emerald-300/80">Live</span>
      </div>
      <div className="mt-3 flex items-baseline justify-between border-t border-white/[0.06] pt-3">
        <span className="text-[9px] font-semibold uppercase tracking-[0.16em] text-ink-4">Wallet USDC</span>
        <span className="num font-display text-sm font-semibold text-ink">{isConnected ? usd(Number(bal.data ?? 0n) / 1e6) : '—'}</span>
      </div>
    </div>
  )
}

function Sidebar({ onNavigate }: { onNavigate?: () => void }) {
  return (
    <div className="flex h-full flex-col gap-6 p-4">
      <div className="flex items-center justify-between px-1 pt-1">
        <Logo />
      </div>

      <nav className="flex-1 space-y-6 overflow-y-auto pb-2" aria-label="Primary">
        {GROUPS.map((group) => (
          <div key={group.label}>
            <div className="mb-2 px-3 text-[9px] font-semibold uppercase tracking-[0.2em] text-ink-4">{group.label}</div>
            <div className="space-y-0.5">
              {group.items.map(({ to, label, icon: Icon }) => (
                <NavLink
                  key={to}
                  to={to}
                  onClick={onNavigate}
                  className={({ isActive }) =>
                    clsx(
                      'group flex items-center gap-2.5 rounded-xl px-3 py-2.5 text-[13px] font-medium transition duration-200',
                      isActive
                        ? 'bg-white/[0.06] text-ink shadow-inner-line'
                        : 'text-ink-3 hover:bg-white/[0.03] hover:text-ink-2',
                    )
                  }
                >
                  {({ isActive }) => (
                    <>
                      <Icon className={clsx('h-[17px] w-[17px] transition', isActive ? 'text-brand' : 'text-ink-4 group-hover:text-ink-2')} aria-hidden />
                      <span>{label}</span>
                      {isActive && <span className="ml-auto h-1 w-1 rounded-full bg-brand shadow-[0_0_10px_2px_rgba(91,140,255,0.75)]" />}
                    </>
                  )}
                </NavLink>
              ))}
            </div>
          </div>
        ))}
      </nav>

      <div className="space-y-2.5">
        <NetworkCard />
        <a
          href="https://faucet.circle.com"
          target="_blank"
          rel="noopener noreferrer"
          className="flex items-center justify-between rounded-xl border border-brand/20 bg-brand/[0.07] px-3.5 py-2.5 text-xs font-medium text-brand-2 transition hover:border-brand/40 hover:bg-brand/[0.12]"
        >
          <span className="flex items-center gap-2">
            <Radio className="h-3.5 w-3.5" aria-hidden /> Get test USDC
          </span>
          <ArrowUpRight className="h-3.5 w-3.5" aria-hidden />
        </a>
        <ConnectButton className="w-full" />
      </div>
    </div>
  )
}

export default function Layout() {
  const [open, setOpen] = useState(false)
  const location = useLocation()
  const current = ALL_ITEMS.find((i) => location.pathname === i.to || location.pathname.startsWith(i.to + '/'))

  return (
    <div className="min-h-dvh lg:grid lg:grid-cols-[272px_1fr]">
      <aside className="hidden lg:block">
        <div className="sticky top-0 h-dvh border-r border-white/[0.06] bg-panel/40 backdrop-blur-xl">
          <Sidebar />
        </div>
      </aside>

      <div className="flex min-h-dvh min-w-0 flex-col">
        <WrongNetwork />
        <header className="sticky top-0 z-30 border-b border-white/[0.06] glass">
          <div className="flex h-16 items-center gap-3 px-4 sm:px-6 lg:px-8">
            <button
              className="btn-ghost !min-h-[38px] !px-2.5 lg:hidden"
              aria-label="Open menu"
              aria-expanded={open}
              onClick={() => setOpen(true)}
            >
              <Menu className="h-5 w-5" />
            </button>

            <div className="hidden items-center gap-2 text-[13px] sm:flex">
              <Link to="/dashboard" className="text-ink-3 transition hover:text-ink-2">
                Workspace
              </Link>
              <ChevronRight className="h-3.5 w-3.5 text-ink-4" aria-hidden />
              <span className="font-medium text-ink">{current?.label ?? 'Home'}</span>
            </div>

            <div className="ml-auto flex items-center gap-2.5">
              <span className="pill hidden sm:inline-flex">
                <span className="h-1.5 w-1.5 rounded-full bg-emerald-400 shadow-[0_0_8px_1px_rgba(52,211,153,0.6)]" aria-hidden />
                Arc Testnet
              </span>
              <ConnectButton />
            </div>
          </div>
        </header>

        <main className="flex-1 px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
          <motion.div
            key={location.pathname}
            initial={{ opacity: 0, y: 8 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.35, ease: [0.22, 1, 0.36, 1] }}
            className="mx-auto w-full max-w-[1400px]"
          >
            <Outlet />
          </motion.div>
        </main>

        <footer className="mt-4 border-t border-white/[0.06]">
          <div className="mx-auto flex max-w-[1400px] flex-col gap-3 px-4 py-6 pb-20 sm:px-6 lg:px-8">
            <p className="max-w-4xl text-[11px] leading-relaxed text-ink-4 text-pretty">{FOOTER_DISCLAIMER}</p>
            <div className="flex flex-wrap items-center justify-between gap-2 text-[10px] uppercase tracking-[0.16em] text-ink-4">
              <span>© 2026 ARCWEALTH · Institutional digital asset management</span>
              <span className="flex items-center gap-2">
                <span className="h-1 w-1 rounded-full bg-emerald-400" aria-hidden /> Chain 5042002 · Arc Testnet
              </span>
            </div>
          </div>
        </footer>
      </div>

      {open && (
        <div className="fixed inset-0 z-50 lg:hidden" role="dialog" aria-modal="true" aria-label="Navigation">
          <button className="absolute inset-0 bg-black/70 backdrop-blur-sm" aria-label="Close menu" onClick={() => setOpen(false)} />
          <div className="absolute inset-y-0 left-0 w-[286px] border-r border-white/[0.08] glass motion-safe:animate-fade-up">
            <button
              className="absolute right-3 top-4 z-10 flex h-8 w-8 items-center justify-center rounded-lg border border-white/10 bg-white/[0.04] text-ink-2 transition hover:bg-white/[0.08]"
              aria-label="Close menu"
              onClick={() => setOpen(false)}
            >
              <X className="h-4 w-4" />
            </button>
            <Sidebar onNavigate={() => setOpen(false)} />
          </div>
        </div>
      )}
    </div>
  )
}
