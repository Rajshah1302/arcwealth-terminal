import { useState } from 'react'
import { useAccount, useReadContracts } from 'wagmi'
import { ArrowDownToLine, ExternalLink, Loader2 } from 'lucide-react'
import { CHAIN_ID, txUrl } from '@/lib/chain'
import { useTx } from '@/lib/hooks'
import { vaultAbi } from '@/shared/abis'
import { formatUsdc, parseUsdc } from '@/onchain-money'
import { num } from '@/lib/format'
import { Notice } from '@/components/ui'
import type { Position } from '@/lib/api'
import type { Address } from 'viem'

export default function WithdrawPanel({ p, onDone }: { p: Position; onDone: () => void }) {
  const { address } = useAccount()
  const vault = p.vault as Address
  const tx = useTx()
  const [amt, setAmt] = useState('')
  const { data, refetch } = useReadContracts({
    allowFailure: true,
    contracts: address ? [
      { address: vault, abi: vaultAbi, functionName: 'maxWithdraw', args: [address], chainId: CHAIN_ID },
      { address: vault, abi: vaultAbi, functionName: 'balanceOf', args: [address], chainId: CHAIN_ID },
      { address: vault, abi: vaultAbi, functionName: 'claimable', args: [address], chainId: CHAIN_ID },
      { address: vault, abi: vaultAbi, functionName: 'pendingRedeem', args: [address], chainId: CHAIN_ID },
    ] : [],
    query: { enabled: !!address, refetchInterval: 6000 },
  })
  const maxW = (data?.[0]?.result) ?? 0n
  const shares = (data?.[1]?.result) ?? 0n
  const claimable = (data?.[2]?.result) ?? 0n
  const pending = (data?.[3]?.result) ?? 0n

  async function go(fn: () => Promise<unknown>) { if (await fn()) { await refetch(); onDone() } }
  let raw = 0n
  try { raw = amt ? parseUsdc(amt) : 0n } catch { raw = 0n }

  return (
    <div className="rounded-xl border border-white/[0.07] bg-black/25 p-4">
      <div className="flex items-center gap-2">
        <ArrowDownToLine className="h-4 w-4 text-brand" aria-hidden />
        <span className="font-display text-sm font-semibold text-ink">Withdraw</span>
      </div>
      <p className="mt-1.5 text-[12px] leading-relaxed text-ink-3">
        Instant withdrawals are limited to the idle buffer: <span className="num font-semibold text-ink">{formatUsdc(maxW)} USDC</span> available now. Larger exits are requested, the keeper unwinds sleeves, then you claim.
      </p>
      <div className="mt-3 flex flex-wrap items-center gap-2">
        <input
          className="input num !min-h-[42px] max-w-[160px]"
          inputMode="decimal"
          placeholder="USDC"
          value={amt}
          onChange={(e) => { setAmt(e.target.value.replace(/[^0-9.]/g, '')); tx.reset() }}
          aria-label="Withdraw amount in USDC"
        />
        <button className="btn-ghost !min-h-[38px] !px-3 text-xs" onClick={() => setAmt(formatUsdc(maxW))} disabled={maxW === 0n}>Max</button>
        <button className="btn-primary !min-h-[38px] !px-3.5 text-xs" disabled={tx.busy || raw === 0n || raw > maxW || !address} onClick={() => void go(() => tx.run({ address: vault, abi: vaultAbi, functionName: 'withdraw', args: [raw, address, address] }))}>
          {tx.busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <ArrowDownToLine className="h-3.5 w-3.5" />} Withdraw instantly
        </button>
      </div>
      <div className="mt-3 flex flex-wrap gap-2">
        <button className="btn-ghost !min-h-[36px] !px-3 text-xs" disabled={tx.busy || shares === 0n} onClick={() => void go(() => tx.run({ address: vault, abi: vaultAbi, functionName: 'requestRedeem', args: [shares] }))}>
          Request full withdrawal ({num(Number(shares) / 1e12, 4)} shares)
        </button>
        {pending > 0n && <button className="btn-ghost !min-h-[36px] !px-3 text-xs" disabled={tx.busy} onClick={() => void go(() => tx.run({ address: vault, abi: vaultAbi, functionName: 'cancelRedeem' }))}>Cancel request ({num(Number(pending) / 1e12, 4)} shares)</button>}
        {claimable > 0n && <button className="btn-primary !min-h-[36px] !px-3 text-xs" disabled={tx.busy} onClick={() => void go(() => tx.run({ address: vault, abi: vaultAbi, functionName: 'claimRedeem' }))}>Claim {formatUsdc(claimable)} USDC</button>}
      </div>
      {pending > 0n && claimable === 0n && <div className="mt-3"><Notice>Your request is queued. The keeper unwinds sleeves and fulfils it within its next cycle (about 10 minutes), then a Claim button appears.</Notice></div>}
      {tx.status === 'success' && tx.hash && <a className="mt-2 inline-flex items-center gap-1 text-xs text-brand-2 underline underline-offset-2" href={txUrl(tx.hash)} target="_blank" rel="noopener noreferrer">Confirmed. View on explorer <ExternalLink className="h-3.5 w-3.5" /></a>}
      {tx.error && <div className="mt-3"><Notice tone="error">{tx.error}</Notice></div>}
      <span className="sr-only">{p.name}</span>
    </div>
  )
}
