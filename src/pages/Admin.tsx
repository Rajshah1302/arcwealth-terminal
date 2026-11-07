import { useState } from 'react'
import { useAccount, useReadContracts } from 'wagmi'
import { keccak256, toBytes } from 'viem'
import { useQueryClient } from '@tanstack/react-query'
import { Clock3, Loader2, ScrollText, Settings2, ShieldCheck, SlidersHorizontal } from 'lucide-react'
import { CHAIN_ID, D, addrUrl, vaultOf } from '@/lib/chain'
import { useApi } from '@/lib/api'
import { useTx } from '@/lib/hooks'
import { strategyManagerAbi, riskManagerAbi } from '@/shared/abis'
import { STRATEGIES } from '@/shared/strategies'
import { Card, Notice, PageTitle, TierBadge } from '@/components/ui'
import { ConnectButton } from '@/components/Layout'
import { short, when } from '@/lib/format'

const SM = D.contracts.strategyManager
const RISK = D.contracts.riskManager
const MANAGER = keccak256(toBytes('MANAGER_ROLE'))
const ADMIN = '0x0000000000000000000000000000000000000000000000000000000000000000' as const
const REGIMES = ['Risk-off', 'High vol', 'Normal', 'Calm']

interface AdminHistory { audit: { id: number; actor: string; action: string; reason: string; tx_hash: string; created_at: string }[]; configChanges: { tx_hash: string; block_time: string; args: Record<string, unknown> }[] }

export default function Admin() {
  const { address } = useAccount()
  const qc = useQueryClient()
  const tx = useTx()
  const hist = useApi<AdminHistory>('/admin/history', 20000)
  const s1 = vaultOf('s1')
  const [cash, setCash] = useState('0')
  const [tbill, setTbill] = useState('0')
  const [reason, setReason] = useState('')
  const [weights, setWeights] = useState(['4000', '4000', '2000'])

  const { data } = useReadContracts({
    allowFailure: true,
    contracts: [
      ...(address ? [{ address: SM, abi: strategyManagerAbi, functionName: 'hasRole' as const, args: [MANAGER, address] as const, chainId: CHAIN_ID }, { address: SM, abi: strategyManagerAbi, functionName: 'hasRole' as const, args: [ADMIN, address] as const, chainId: CHAIN_ID }] : []),
      { address: SM, abi: strategyManagerAbi, functionName: 'currentRegime', chainId: CHAIN_ID },
      ...STRATEGIES.map((s) => ({ address: SM, abi: strategyManagerAbi, functionName: 'targetWeights' as const, args: [vaultOf(s.id)] as const, chainId: CHAIN_ID })),
      { address: SM, abi: strategyManagerAbi, functionName: 'tacticalAllocation', args: [s1], chainId: CHAIN_ID },
      { address: RISK, abi: riskManagerAbi, functionName: 'minDeposit', args: [s1], chainId: CHAIN_ID },
      { address: RISK, abi: riskManagerAbi, functionName: 'minIdleBps', args: [s1], chainId: CHAIN_ID },
    ],
    query: { refetchInterval: 10000 },
  })
  const off = address ? 2 : 0
  const isManager = Boolean(address && data?.[0]?.result)
  const isAdmin = Boolean(address && data?.[1]?.result)
  const regime = Number((data?.[off]?.result as number | undefined) ?? 0)
  const targets = STRATEGIES.map((_, i) => (data?.[off + 1 + i]?.result as readonly number[] | undefined) ?? [])
  const tac = data?.[off + 1 + STRATEGIES.length]?.result as readonly [number, number, number] | undefined

  async function audit(action: string, before: unknown, after: unknown, txHash: string) {
    if (!address) return
    await fetch('/api/admin/audit', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ actor: address, action, reason, before, after, txHash }) })
    void qc.invalidateQueries({ queryKey: ['api'] })
  }

  async function override() {
    const h = await tx.run({ address: SM, abi: strategyManagerAbi, functionName: 'tacticalOverride', args: [s1, Number(cash), Number(tbill), reason] })
    if (h) await audit('tacticalOverride', { tac }, { cashDeltaBps: Number(cash), tbillDeltaBps: Number(tbill) }, h)
  }
  async function setW() {
    const w = weights.map(Number)
    const newHash = keccak256(toBytes(JSON.stringify({ weights: w, reason })))
    const h = await tx.run({ address: SM, abi: strategyManagerAbi, functionName: 'setModuleWeights', args: [s1, w, newHash, reason] })
    if (h) await audit('setModuleWeights', { weights: targets[0] }, { weights: w }, h)
  }
  const sum = weights.reduce((a, b) => a + Number(b || 0), 0)

  return (
    <div>
      <PageTitle
        eyebrow="System"
        title="Administration"
        sub="Strategy configuration for the MANAGER and DEFAULT_ADMIN roles. No control here can move investor funds or shares. Every change is recorded on chain and in the public history below."
        right={<TierBadge tier="DEMO-ONCHAIN" />}
      />

      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <div className="flex items-center gap-2">
            <ShieldCheck className="h-4 w-4 text-brand" aria-hidden />
            <h2 className="font-display text-lg font-semibold text-ink">Your roles</h2>
          </div>
          {!address ? <div className="mt-4"><ConnectButton /></div> : (
            <div className="mt-4 space-y-2.5 text-sm">
              <div className="flex items-center justify-between rounded-xl border border-white/[0.06] bg-black/20 px-3.5 py-2.5">
                <span className="text-ink-3">Wallet</span>
                <span className="mono text-xs text-ink-2">{short(address)}</span>
              </div>
              <div className="flex items-center justify-between rounded-xl border border-white/[0.06] bg-black/20 px-3.5 py-2.5">
                <span className="text-ink-3">MANAGER</span>
                <span className={isManager ? 'font-medium text-up' : 'text-ink-3'}>{isManager ? 'Granted' : 'Not held'}</span>
              </div>
              <div className="flex items-center justify-between rounded-xl border border-white/[0.06] bg-black/20 px-3.5 py-2.5">
                <span className="text-ink-3">DEFAULT_ADMIN (timelock only)</span>
                <span className={isAdmin ? 'font-medium text-up' : 'text-ink-3'}>{isAdmin ? 'Granted' : 'Not held'}</span>
              </div>
            </div>
          )}
          <p className="mt-3 text-[11px] leading-relaxed text-ink-4">
            <Clock3 className="mr-1 inline h-3.5 w-3.5 align-text-bottom" aria-hidden />
            Risk limits, module whitelist and caps change only through the 10-minute TimelockController:{' '}
            <a className="text-brand-2 underline underline-offset-2 transition hover:text-white" href={addrUrl(D.contracts.timelock)} target="_blank" rel="noopener noreferrer">{short(D.contracts.timelock)}</a>.
          </p>
        </Card>

        <Card>
          <div className="flex items-center gap-2">
            <SlidersHorizontal className="h-4 w-4 text-brand" aria-hidden />
            <h2 className="font-display text-lg font-semibold text-ink">Allocations (read-only)</h2>
          </div>
          <p className="mt-2 text-sm text-ink-3">
            Regime: <span className="font-medium text-ink">{REGIMES[regime]}</span> <span className="text-[11px] text-ink-4">(SIMULATED-OFFCHAIN input)</span>
          </p>
          <ul className="mt-3 space-y-2 text-sm">
            {STRATEGIES.map((s, i) => (
              <li key={s.id} className="flex items-center justify-between gap-3 border-b border-white/[0.05] pb-2">
                <span className="text-ink-3">{s.short} module weights</span>
                <span className="num text-right font-medium text-ink-2">{targets[i].length ? targets[i].map((x) => `${x / 100}%`).join(' / ') : '…'}</span>
              </li>
            ))}
            <li className="flex items-center justify-between gap-3 border-b border-white/[0.05] pb-2">
              <span className="text-ink-3">S1 tactical (cash / dTBILL / puts)</span>
              <span className="num text-right font-medium text-ink-2">{tac ? tac.map((x) => `${x / 100}%`).join(' / ') : '…'}</span>
            </li>
            <li className="flex items-center justify-between gap-3">
              <span className="text-ink-3">S1 minimum deposit / idle floor</span>
              <span className="num text-right font-medium text-ink-2">
                {data ? `${Number((data[off + 2 + STRATEGIES.length]?.result as bigint | undefined) ?? 0n) / 1e6} USDC / ${Number((data[off + 3 + STRATEGIES.length]?.result as number | undefined) ?? 0) / 100}%` : '…'}
              </span>
            </li>
          </ul>
        </Card>

        <Card>
          <div className="flex items-center gap-2">
            <Settings2 className="h-4 w-4 text-brand" aria-hidden />
            <h2 className="font-display text-lg font-semibold text-ink">Tactical override (S1)</h2>
          </div>
          <p className="mt-2 text-sm leading-relaxed text-ink-3">Shift up to 10 percentage points between cash and dTBILL; puts absorb the rest. A reason is required and recorded.</p>
          <div className="mt-4 grid grid-cols-2 gap-3">
            <div>
              <label className="label" htmlFor="cash">Cash delta (bps)</label>
              <input id="cash" className="input num mt-1" value={cash} onChange={(e) => setCash(e.target.value)} />
            </div>
            <div>
              <label className="label" htmlFor="tb">dTBILL delta (bps)</label>
              <input id="tb" className="input num mt-1" value={tbill} onChange={(e) => setTbill(e.target.value)} />
            </div>
          </div>
          <label className="label mt-4 block" htmlFor="reason">Reason</label>
          <input id="reason" className="input mt-1" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. volatility spike" />
          <button className="btn-primary mt-4" disabled={!isManager || !reason || tx.busy} onClick={() => void override()}>
            {tx.busy && <Loader2 className="h-4 w-4 animate-spin" />} Apply override
          </button>
        </Card>

        <Card>
          <div className="flex items-center gap-2">
            <SlidersHorizontal className="h-4 w-4 text-brand" aria-hidden />
            <h2 className="font-display text-lg font-semibold text-ink">Sleeve weights (S1)</h2>
          </div>
          <p className="mt-2 text-sm leading-relaxed text-ink-3">Debt / calls / tactical in bps, within the risk bands (+/-10pp of 40/40/20). Must sum to 10000.</p>
          <div className="mt-4 grid grid-cols-3 gap-3">
            {weights.map((w, i) => (
              <div key={i}>
                <label className="label" htmlFor={`w${i}`}>{['Debt', 'Calls', 'Tactical'][i]}</label>
                <input id={`w${i}`} className="input num mt-1" value={w} onChange={(e) => setWeights(weights.map((x, j) => (j === i ? e.target.value : x)))} />
              </div>
            ))}
          </div>
          <div className={`mt-1.5 text-xs ${sum === 10000 ? 'text-ink-4' : 'text-down'}`}>Sum: {sum} / 10000</div>
          <button className="btn-primary mt-4" disabled={!isManager || sum !== 10000 || !reason || tx.busy} onClick={() => void setW()}>Update weights</button>
          {!isManager && address && <div className="mt-3"><Notice>Your wallet does not hold MANAGER. Controls are read-only.</Notice></div>}
          {tx.error && <div className="mt-3"><Notice tone="error">{tx.error}</Notice></div>}
          {tx.status === 'success' && <div className="mt-3"><Notice>Change confirmed on chain and recorded.</Notice></div>}
        </Card>

        <Card className="lg:col-span-2">
          <div className="flex items-center gap-2">
            <ScrollText className="h-4 w-4 text-brand" aria-hidden />
            <h2 className="font-display text-lg font-semibold text-ink">Public change history</h2>
          </div>
          <ul className="mt-4 divide-y divide-white/[0.06] text-sm">
            {(hist.data?.audit ?? []).map((a) => (
              <li key={a.id} className="flex flex-wrap items-center gap-x-2 gap-y-1 py-3">
                <span className="font-medium text-ink">{a.action}</span>
                <span className="text-ink-3">by {short(a.actor)}</span>
                <span className="text-ink-3">· {a.reason}</span>
                <span className="ml-auto text-[11px] text-ink-4">{when(a.created_at)}</span>
              </li>
            ))}
            {(hist.data?.configChanges ?? []).map((c) => (
              <li key={c.tx_hash} className="flex flex-wrap items-center gap-x-2 gap-y-1 py-3">
                <span className="font-medium text-ink">StrategyConfigChanged</span>
                <span className="text-ink-3">· {typeof c.args.reason === 'string' ? c.args.reason : ''}</span>
                <span className="ml-auto text-[11px] text-ink-4">{c.block_time ? when(c.block_time) : ''}</span>
              </li>
            ))}
            {!hist.data?.audit.length && !hist.data?.configChanges.length && <li className="py-3 text-ink-3">No changes recorded yet.</li>}
          </ul>
        </Card>
      </div>
      <span className="sr-only">{(address) ?? ''}</span>
    </div>
  )
}
