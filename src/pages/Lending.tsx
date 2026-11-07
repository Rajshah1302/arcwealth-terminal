import { useState } from 'react'
import { useAccount, useReadContracts } from 'wagmi'
import { erc20Abi, parseUnits, type Address } from 'viem'
import { ExternalLink, Loader2, ShieldAlert, Landmark } from 'lucide-react'
import { clsx } from 'clsx'
import { CHAIN_ID, D, USDC, txUrl } from '@/lib/chain'
import { useApi } from '@/lib/api'
import { useTx } from '@/lib/hooks'
import { lendingAbi } from '@/shared/abis'
import { formatUsdc, parseUsdc } from '@/onchain-money'
import { Card, Notice, PageTitle, Stat, TierBadge } from '@/components/ui'
import { ConnectButton } from '@/components/Layout'
import { num, usd } from '@/lib/format'

const POOL = D.contracts.lending
const CIRBTC = D.tokens.cirBTC.address

interface Market { utilisationPct: number; supplyAprPct: number; borrowAprPct: number; ltvPct: number; liquidationPct: number; note: string }

type ActionKey = 'supply' | 'withdraw' | 'collateral' | 'borrow' | 'repay'
const ACTIONS: { key: ActionKey; label: string; unit: 'USDC' | 'cirBTC'; fn: string; approve?: Address; hint: string }[] = [
  { key: 'supply', label: 'Supply', unit: 'USDC', fn: 'supply', approve: USDC, hint: 'Lend USDC to the demo pool and earn demo yield.' },
  { key: 'withdraw', label: 'Withdraw', unit: 'USDC', fn: 'withdraw', hint: 'Take supplied USDC back (subject to pool liquidity).' },
  { key: 'collateral', label: 'Add collateral', unit: 'cirBTC', fn: 'depositCollateral', approve: CIRBTC, hint: 'Deposit real testnet cirBTC as collateral.' },
  { key: 'borrow', label: 'Borrow', unit: 'USDC', fn: 'borrow', hint: 'Borrow USDC up to 70% LTV. Liquidation at 80%.' },
  { key: 'repay', label: 'Repay', unit: 'USDC', fn: 'repay', approve: USDC, hint: 'Repay debt. Approve the exact amount first.' },
]

export default function Lending() {
  const { address, isConnected } = useAccount()
  const { data: m } = useApi<Market>('/lending/markets', 15000)
  const [act, setAct] = useState<ActionKey>('supply')
  const [amt, setAmt] = useState('')
  const [drop, setDrop] = useState(0)
  const tx = useTx()
  const a = ACTIONS.find((x) => x.key === act)!
  const decimals = a.unit === 'USDC' ? 6 : 8
  let raw = 0n
  try { raw = amt ? (a.unit === 'USDC' ? parseUsdc(amt) : parseUnits(amt, decimals)) : 0n } catch { raw = 0n }

  const { data, refetch } = useReadContracts({
    allowFailure: true,
    contracts: address ? [
      { address: POOL, abi: lendingAbi, functionName: 'suppliedBalance', args: [address], chainId: CHAIN_ID },
      { address: POOL, abi: lendingAbi, functionName: 'debtOf', args: [address], chainId: CHAIN_ID },
      { address: POOL, abi: lendingAbi, functionName: 'collateralOf', args: [address, CIRBTC], chainId: CHAIN_ID },
      { address: POOL, abi: lendingAbi, functionName: 'collateralValue', args: [address], chainId: CHAIN_ID },
      { address: POOL, abi: lendingAbi, functionName: 'healthFactor', args: [address], chainId: CHAIN_ID },
      { address: USDC, abi: erc20Abi, functionName: 'allowance', args: [address, POOL], chainId: CHAIN_ID },
      { address: CIRBTC, abi: erc20Abi, functionName: 'allowance', args: [address, POOL], chainId: CHAIN_ID },
      { address: CIRBTC, abi: erc20Abi, functionName: 'balanceOf', args: [address], chainId: CHAIN_ID },
    ] : [],
    query: { enabled: !!address, refetchInterval: 8000 },
  })
  const g = (i: number) => (data?.[i]?.result) ?? 0n
  const supplied = g(0), debt = g(1), coll = g(2), collVal = g(3), hf = g(4)
  const allow = a.approve === USDC ? g(5) : g(6)
  const needApprove = !!a.approve && allow < raw

  async function go() {
    if (needApprove && a.approve) {
      const ok = await tx.run({ address: a.approve, abi: erc20Abi, functionName: 'approve', args: [POOL, raw] })
      if (ok) { tx.reset(); await refetch() }
      return
    }
    const args: unknown[] = a.key === 'collateral' ? [CIRBTC, raw] : [raw]
    if (await tx.run({ address: POOL, abi: lendingAbi, functionName: a.fn, args })) { await refetch(); setAmt('') }
  }

  const collUsd = Number(collVal) / 1e6
  const debtUsd = Number(debt) / 1e6
  const maxBorrow = collUsd * 0.7
  const simHf = debtUsd > 0 ? (collUsd * (1 - drop / 100) * 0.8) / debtUsd : Infinity
  const hfNum = hf > 10n ** 30n ? Infinity : Number(hf) / 1e18
  const utilisation = m ? Math.min(100, m.utilisationPct) : 0

  return (
    <div>
      <PageTitle
        eyebrow="Markets"
        title="Lending & Borrowing"
        sub="Supply USDC or borrow against real testnet cirBTC on the demo lending pool. Earn Kit (Morpho) is not provisioned, so this uses the labelled demo pool."
        right={<span className="pill"><Landmark className="h-3.5 w-3.5" aria-hidden /> Demo pool</span>}
      />
      <div className="mb-4">
        <Notice tone="warn">Demo yield (testnet, no monetary value). Rates come from the pool utilisation model: 2% base, steeper after the 80% kink. Not real lending yield.</Notice>
      </div>

      <div className="grid gap-4 lg:grid-cols-[1fr_380px]">
        <div className="min-w-0 space-y-4">
          <Card>
            <div className="flex items-center justify-between">
              <div>
                <span className="label">Credit market</span>
                <h2 className="mt-1 font-display text-lg font-semibold text-ink">USDC pool</h2>
              </div>
              <TierBadge tier="DEMO-ONCHAIN" />
            </div>
            <div className="mt-5 grid grid-cols-2 gap-5 sm:grid-cols-4">
              <Stat label="Utilisation" value={m ? `${num(m.utilisationPct, 1)}%` : '…'} />
              <Stat label="Supply APR" value={m ? `${num(m.supplyAprPct, 2)}%` : '…'} sub="Demo" tone="up" />
              <Stat label="Borrow APR" value={m ? `${num(m.borrowAprPct, 2)}%` : '…'} sub="Demo" />
              <Stat label="LTV / Liq." value={`${m?.ltvPct ?? 70}% / ${m?.liquidationPct ?? 80}%`} sub="cirBTC" />
            </div>
            <div className="mt-5">
              <div className="mb-2 flex items-center justify-between text-[10px] uppercase tracking-[0.14em] text-ink-4">
                <span>Pool utilisation</span>
                <span className="num text-ink-3">{m ? `${num(m.utilisationPct, 1)}%` : '—'}</span>
              </div>
              <div className="h-1.5 w-full overflow-hidden rounded-full bg-white/[0.06]">
                <div className="h-full rounded-full bg-gradient-to-r from-brand to-violet transition-all duration-500" style={{ width: `${utilisation}%` }} />
              </div>
            </div>
          </Card>

          <Card>
            <div className="flex items-center justify-between">
              <div>
                <span className="label">Account</span>
                <h2 className="mt-1 font-display text-lg font-semibold text-ink">Your position</h2>
              </div>
              <TierBadge tier="DEMO-ONCHAIN" />
            </div>
            {!isConnected ? <div className="mt-4"><ConnectButton /></div> : (
              <div className="mt-5 grid grid-cols-2 gap-5 sm:grid-cols-4">
                <Stat label="Supplied" value={usd(Number(supplied) / 1e6)} />
                <Stat label="Collateral" value={`${num(Number(coll) / 1e8, 6)} cirBTC`} sub={usd(collUsd)} tier="LIVE-TESTNET" />
                <Stat label="Debt" value={usd(debtUsd)} sub={`Max borrow ${usd(maxBorrow)}`} />
                <Stat label="Health factor" value={Number.isFinite(hfNum) ? hfNum.toFixed(2) : 'No debt'} tone={Number.isFinite(hfNum) && hfNum < 1.2 ? 'down' : 'up'} />
              </div>
            )}
          </Card>

          <Card>
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <ShieldAlert className="h-4 w-4 text-amber-200" aria-hidden />
                <h2 className="font-display text-lg font-semibold text-ink">Liquidation simulation</h2>
              </div>
              <TierBadge tier="SIMULATED-OFFCHAIN" />
            </div>
            <p className="mt-2 text-sm leading-relaxed text-ink-3">See how a cirBTC price drop would change your health factor. This does not send a transaction.</p>
            <div className="mt-4 flex items-center justify-between text-xs">
              <label htmlFor="drop" className="label">cirBTC price drop</label>
              <span className="num pill !text-ink">{drop}%</span>
            </div>
            <input id="drop" type="range" min={0} max={60} value={drop} onChange={(e) => setDrop(Number(e.target.value))} className="range mt-3 w-full" />
            <div className="mt-4 flex flex-wrap items-center gap-3 rounded-xl border border-white/[0.06] bg-black/20 px-4 py-3 text-sm">
              <span className="text-ink-3">Simulated health factor</span>
              <span className={clsx('num font-display text-lg font-semibold', simHf < 1 ? 'text-down' : 'text-up')}>{Number.isFinite(simHf) ? simHf.toFixed(2) : 'No debt'}</span>
              {simHf < 1 && <span className="text-xs text-down">Position would be liquidatable (5% liquidation bonus).</span>}
            </div>
          </Card>
        </div>

        <aside className="min-w-0 lg:sticky lg:top-24 lg:self-start">
          <Card>
            <div className="segmented grid-cols-3" role="tablist">
              {ACTIONS.map((x) => (
                <button
                  key={x.key}
                  role="tab"
                  aria-selected={act === x.key}
                  className={clsx('seg-btn !px-1 !text-[11px]', act === x.key && 'seg-btn-active')}
                  onClick={() => { setAct(x.key); setAmt(''); tx.reset() }}
                >
                  {x.label === 'Add collateral' ? 'Collateral' : x.label}
                </button>
              ))}
            </div>
            <p className="mt-3 text-[13px] leading-relaxed text-ink-3">{a.hint}</p>

            <label htmlFor="l-amt" className="label mt-4 block">Amount ({a.unit})</label>
            <div className="relative mt-1">
              <input
                id="l-amt"
                className="input num !min-h-[56px] !pr-20 !text-xl font-semibold"
                inputMode="decimal"
                value={amt}
                onChange={(e) => { setAmt(e.target.value.replace(/[^0-9.]/g, '')); tx.reset() }}
              />
              <span className="pointer-events-none absolute right-4 top-1/2 -translate-y-1/2 text-xs font-semibold text-ink-3">{a.unit}</span>
            </div>

            {a.unit === 'USDC' && a.key === 'repay' && debt > 0n && (
              <button className="mt-2 text-xs text-brand-2 underline underline-offset-2 transition hover:text-white" onClick={() => setAmt(formatUsdc(debt))}>
                Repay full debt ({formatUsdc(debt)})
              </button>
            )}

            <div className="mt-4">
              {!isConnected ? <ConnectButton className="w-full" /> : (
                <button className="btn-primary w-full" disabled={raw === 0n || tx.busy} onClick={() => void go()}>
                  {tx.busy && <Loader2 className="h-4 w-4 animate-spin" />}
                  {tx.status === 'wallet' ? 'Confirm in wallet…' : tx.status === 'confirming' ? 'Confirming…' : needApprove ? `Approve exactly ${amt} ${a.unit}` : `${a.label} ${amt || ''} ${a.unit}`}
                </button>
              )}
            </div>

            {tx.status === 'success' && tx.hash && (
              <a className="mt-2 inline-flex items-center gap-1 text-xs text-brand-2 underline underline-offset-2" href={txUrl(tx.hash)} target="_blank" rel="noopener noreferrer">
                Confirmed. Explorer <ExternalLink className="h-3.5 w-3.5" />
              </a>
            )}
            {tx.error && <div className="mt-3"><Notice tone="error">{tx.error}</Notice></div>}
            {a.unit === 'cirBTC' && <p className="mt-2.5 text-[11px] leading-relaxed text-ink-4">Your cirBTC balance: <span className="num text-ink-3">{num(Number(g(7)) / 1e8, 6)}</span>. Get cirBTC from faucet.circle.com.</p>}
          </Card>
        </aside>
      </div>
    </div>
  )
}
