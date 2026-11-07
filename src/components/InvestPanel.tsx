import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useAccount, useReadContracts } from 'wagmi'
import { erc20Abi } from 'viem'
import { useQueryClient } from '@tanstack/react-query'
import { ArrowUpRight, Check, ExternalLink, Loader2, ShieldCheck, Sparkles } from 'lucide-react'
import { clsx } from 'clsx'
import { CHAIN_ID, INVESTOR_VAULT, USDC, faucetUrl, txUrl, vaultOf } from '@/lib/chain'
import { useTx } from '@/lib/hooks'
import { investorVaultAbi, vaultAbi } from '@/shared/abis'
import { DISCLOSURE_TEXT, FEE_TEXT, disclosureHash, type StrategyMeta } from '@/shared/strategies'
import { formatUsdc, parseUsdc } from '@/onchain-money'
import { usd, num, short } from '@/lib/format'
import { Notice, TierBadge } from '@/components/ui'
import { ConnectButton } from '@/components/Layout'

const CHIPS = ['10', '50', '100', '250']

export default function InvestPanel({ meta, onDone }: { meta: StrategyMeta; onDone?: () => void }) {
  const vault = vaultOf(meta.id)
  const { address, isConnected } = useAccount()
  const qc = useQueryClient()
  const [amount, setAmount] = useState('50')
  const [agree, setAgree] = useState(false)
  const [sharesBefore, setSharesBefore] = useState<bigint>()
  const [receipt, setReceipt] = useState<{ hash: string; shares: bigint; price: bigint } | null>(null)
  const tx = useTx()

  const { data, refetch } = useReadContracts({
    allowFailure: true,
    contracts: address
      ? [
          { address: USDC, abi: erc20Abi, functionName: 'balanceOf', args: [address], chainId: CHAIN_ID },
          { address: USDC, abi: erc20Abi, functionName: 'allowance', args: [address, vault], chainId: CHAIN_ID },
          { address: INVESTOR_VAULT, abi: investorVaultAbi, functionName: 'hasAccepted', args: [address, vault], chainId: CHAIN_ID },
          { address: vault, abi: vaultAbi, functionName: 'maxDeposit', args: [address], chainId: CHAIN_ID },
          { address: vault, abi: vaultAbi, functionName: 'paused', chainId: CHAIN_ID },
          { address: vault, abi: vaultAbi, functionName: 'balanceOf', args: [address], chainId: CHAIN_ID },
          { address: vault, abi: vaultAbi, functionName: 'sharePrice', chainId: CHAIN_ID },
        ]
      : [],
    query: { enabled: !!address, refetchInterval: 6000 },
  })
  const bal = (data?.[0]?.result) ?? 0n
  const allowance = (data?.[1]?.result) ?? 0n
  const accepted = Boolean(data?.[2]?.result)
  const maxDep = (data?.[3]?.result) ?? 0n
  const paused = Boolean(data?.[4]?.result)
  const shares = (data?.[5]?.result) ?? 0n
  const price = (data?.[6]?.result) ?? 0n

  let raw = 0n
  let parseErr: string | undefined
  try { raw = amount ? parseUsdc(amount) : 0n } catch { parseErr = 'Enter a valid USDC amount.' }

  const problem = useMemo(() => {
    if (parseErr) return parseErr
    if (raw < parseUsdc(String(meta.minDeposit))) return `Minimum deposit is ${meta.minDeposit} USDC.`
    if (paused) return 'Deposits are paused for this strategy.'
    if (isConnected && raw > bal) return `Balance is ${formatUsdc(bal)} USDC. Get test USDC from the faucet.`
    if (isConnected && raw > maxDep) return maxDep === 0n ? 'Deposits are unavailable (cap reached or prices stale).' : `Current limit is ${formatUsdc(maxDep)} USDC (250 per investor, 1,000 strategy cap).`
    return undefined
  }, [parseErr, raw, paused, bal, maxDep, isConnected, meta.minDeposit])

  const hasAllowance = allowance >= raw && raw > 0n
  const step: 'disclosure' | 'approve' | 'deposit' = !accepted ? 'disclosure' : !hasAllowance ? 'approve' : 'deposit'
  const amt = Number(amount || 0)
  const idle = amt * 0.1
  const gasEstimate = 0.05

  useEffect(() => { if (tx.status === 'success') void refetch() }, [tx.status, refetch])

  async function act() {
    if (step === 'disclosure') {
      if (await tx.run({ address: INVESTOR_VAULT, abi: investorVaultAbi, functionName: 'acceptDisclosure', args: [vault, disclosureHash(meta)] })) { tx.reset(); await refetch() }
    } else if (step === 'approve') {
      if (await tx.run({ address: USDC, abi: erc20Abi, functionName: 'approve', args: [vault, raw] })) { tx.reset(); await refetch() }
    } else {
      setSharesBefore(shares)
      const ok = await tx.run({ address: vault, abi: vaultAbi, functionName: 'deposit', args: [raw, address] })
      if (ok) {
        const fresh = await refetch()
        const now = (fresh.data?.[5]?.result) ?? shares
        setReceipt({ hash: ok, shares: now - (sharesBefore ?? shares), price: (fresh.data?.[6]?.result) ?? price })
        void qc.invalidateQueries({ queryKey: ['api'] })
        onDone?.()
      }
    }
  }

  if (receipt) {
    return (
      <div className="card">
        <div className="flex items-center gap-3">
          <span className="flex h-11 w-11 items-center justify-center rounded-2xl border border-up/25 bg-up/10 text-up">
            <Check className="h-5 w-5" />
          </span>
          <div>
            <div className="label">Confirmed</div>
            <h3 className="font-display text-xl font-semibold text-ink">Investment complete</h3>
          </div>
        </div>
        <dl className="mt-5 space-y-2.5 rounded-xl border border-white/[0.06] bg-black/20 p-4 text-sm">
          <Row k="Deposited" v={`${num(amt)} USDC`} />
          <Row k="Shares received" v={num(Number(receipt.shares) / 1e12, 6)} />
          <Row k="Share price" v={`${usd(Number(receipt.price) / 1e6, 4)} USDC`} />
        </dl>
        <div className="mt-4 flex flex-wrap gap-2">
          {receipt.hash && <a className="btn-ghost !min-h-[38px] !px-3.5 text-xs" href={txUrl(receipt.hash)} target="_blank" rel="noopener noreferrer">Explorer <ExternalLink className="h-3.5 w-3.5" /></a>}
          <Link to="/portfolio" className="btn-primary !min-h-[38px] !px-3.5 text-xs">View portfolio</Link>
          <button className="btn-ghost !min-h-[38px] !px-3.5 text-xs" onClick={() => { setReceipt(null); tx.reset() }}>Invest more</button>
        </div>
        <p className="mt-3 text-[11px] leading-relaxed text-ink-4">Position value reads the vault on chain. Demo yield (testnet, no monetary value).</p>
      </div>
    )
  }

  const stepState = (s: string) => (step === s ? 'current' : ['disclosure', 'approve', 'deposit'].indexOf(s) < ['disclosure', 'approve', 'deposit'].indexOf(step) ? 'done' : 'todo')

  return (
    <div className="card">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2.5">
          <span className="icon-tile">
            <Sparkles className="h-4 w-4" />
          </span>
          <h3 className="font-display text-lg font-semibold text-ink">Invest in {meta.short}</h3>
        </div>
        <TierBadge tier="DEMO-ONCHAIN" />
      </div>

      <label htmlFor="amt" className="label mt-4 block">Amount (USDC)</label>
      <div className="relative mt-1">
        <input
          id="amt"
          inputMode="decimal"
          className="input num !min-h-[58px] !pr-16 !text-2xl font-semibold"
          value={amount}
          onChange={(e) => { setAmount(e.target.value.replace(/[^0-9.]/g, '')); tx.reset() }}
          aria-invalid={!!problem}
          aria-describedby="amt-help"
        />
        <span className="pointer-events-none absolute right-4 top-1/2 -translate-y-1/2 text-xs font-semibold text-ink-3">USDC</span>
      </div>

      <div className="mt-2.5 flex flex-wrap items-center gap-1.5">
        {CHIPS.map((c) => (
          <button key={c} className="chip" onClick={() => setAmount(c)}>{c}</button>
        ))}
        {isConnected && (
          <button className="chip" onClick={() => setAmount(formatUsdc(bal < maxDep || maxDep === 0n ? bal : maxDep))}>Max</button>
        )}
        {isConnected && <span className="ml-auto text-[11px] text-ink-4">Balance <span className="num text-ink-3">{num(Number(bal) / 1e6)}</span> USDC</span>}
      </div>

      <p id="amt-help" className={clsx('mt-2 min-h-5 text-xs', problem ? 'text-down' : 'text-ink-4')}>
        {problem ?? 'Within limits.'}{' '}
        {problem?.includes('faucet') && <a className="text-brand-2 underline underline-offset-2" href={faucetUrl} target="_blank" rel="noopener noreferrer">faucet.circle.com</a>}
      </p>

      <div className="mt-3 rounded-xl border border-white/[0.06] bg-black/20 p-4 text-[13px]">
        <div className="label mb-2.5">Sleeve allocation</div>
        <ul className="space-y-1.5">
          <li className="flex justify-between"><span className="text-ink-3">Idle USDC buffer (10%)</span><span className="num text-ink-2">{usd(idle)}</span></li>
          {meta.sleeves.map((s) => (
            <li key={s.key} className="flex justify-between"><span className="text-ink-3">{s.name} ({s.bps / 100}%)</span><span className="num text-ink-2">{usd((amt * 0.9 * s.bps) / 10000)}</span></li>
          ))}
        </ul>
        <div className="label mb-1.5 mt-3.5">Fees</div>
        <p className="text-[11px] leading-relaxed text-ink-4">{FEE_TEXT} Estimated network fee about {usd(gasEstimate)} in USDC.</p>
      </div>

      {isConnected && (
        <ol className="mt-4 space-y-2.5 text-sm" aria-label="Steps">
          {([['disclosure', 'Accept disclosure onchain'], ['approve', `Approve exactly ${num(amt)} USDC`], ['deposit', 'Deposit']] as const).map(([k, label]) => {
            const st = stepState(k)
            return (
              <li key={k} className="flex items-center gap-2.5">
                <span className={clsx('flex h-5 w-5 items-center justify-center rounded-full text-[10px] font-bold', st === 'done' ? 'bg-up/90 text-[#05110b]' : st === 'current' ? 'bg-brand text-white shadow-[0_0_12px_rgba(91,140,255,0.55)]' : 'bg-white/[0.07] text-ink-4')}>
                  {st === 'done' ? <Check className="h-3 w-3" /> : ['disclosure', 'approve', 'deposit'].indexOf(k) + 1}
                </span>
                <span className={st === 'todo' ? 'text-ink-4' : 'text-ink-2'}>{label}</span>
              </li>
            )
          })}
        </ol>
      )}

      {isConnected && step === 'disclosure' && (
        <div className="mt-3 rounded-xl border border-white/[0.08] bg-white/[0.02] p-3.5 text-[11px] leading-relaxed text-ink-3">
          <div className="mb-1.5 flex items-center gap-1.5 font-semibold text-ink"><ShieldCheck className="h-4 w-4 text-brand" /> Disclosure (hash {short(disclosureHash(meta))})</div>
          {DISCLOSURE_TEXT(meta)}
          <label className="mt-2.5 flex items-start gap-2 text-ink-2">
            <input type="checkbox" className="mt-0.5 h-4 w-4 accent-[#5b8cff]" checked={agree} onChange={(e) => setAgree(e.target.checked)} />
            I have read and accept this disclosure.
          </label>
        </div>
      )}

      <div className="mt-4">
        {!isConnected ? (
          <ConnectButton className="w-full" />
        ) : (
          <button className="btn-primary w-full" disabled={!!problem || tx.busy || (step === 'disclosure' && !agree)} onClick={() => void act()}>
            {tx.status === 'wallet' && (<><Loader2 className="h-4 w-4 animate-spin" /> Confirm in wallet…</>)}
            {tx.status === 'confirming' && (<><Loader2 className="h-4 w-4 animate-spin" /> Confirming onchain…</>)}
            {!tx.busy && (step === 'disclosure' ? 'Accept disclosure' : step === 'approve' ? `Approve ${num(amt)} USDC` : `Deposit ${num(amt)} USDC`)}
          </button>
        )}
      </div>

      {tx.hash && tx.busy && (
        <a className="mt-2 inline-flex items-center gap-1 text-[11px] text-brand-2 underline underline-offset-2" href={txUrl(tx.hash)} target="_blank" rel="noopener noreferrer">
          View pending transaction <ExternalLink className="h-3 w-3" />
        </a>
      )}
      {tx.error && <div className="mt-3"><Notice tone={tx.status === 'error' ? 'error' : 'info'}>{tx.error}</Notice></div>}

      <div className="mt-3 flex items-center justify-center gap-1 text-[10px] uppercase tracking-[0.14em] text-ink-4">
        <ShieldCheck className="h-3 w-3" aria-hidden /> Non-custodial · Onchain accounting
        <ArrowUpRight className="h-3 w-3" aria-hidden />
      </div>
    </div>
  )
}

const Row = ({ k, v }: { k: string; v: string }) => (
  <div className="flex justify-between">
    <dt className="text-ink-3">{k}</dt>
    <dd className="num font-medium text-ink">{v}</dd>
  </div>
)
