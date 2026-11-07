import { useState } from 'react'
import { useAccount, useDisconnect, useReadContracts, useSwitchChain } from 'wagmi'
import { numberToHex } from 'viem'
import { Check, Copy, ExternalLink, Globe2, ShieldCheck, Wallet } from 'lucide-react'
import { CHAIN_ID, INVESTOR_VAULT, addrUrl, chainFacts, faucetUrl, vaultOf } from '@/lib/chain'
import { useUsdcBalance } from '@/lib/hooks'
import { investorVaultAbi } from '@/shared/abis'
import { STRATEGIES } from '@/shared/strategies'
import { Card, Notice, PageTitle, Stat, TierBadge } from '@/components/ui'
import { ConnectButton } from '@/components/Layout'
import { FOOTER_DISCLAIMER } from '@/shared/market'
import { short, usd } from '@/lib/format'

export default function Profile() {
  const { address, isConnected, chainId, connector } = useAccount()
  const { disconnect } = useDisconnect()
  const { switchChainAsync, isPending } = useSwitchChain()
  const bal = useUsdcBalance(address)
  const [msg, setMsg] = useState<string>()
  const [copied, setCopied] = useState(false)
  const { data } = useReadContracts({
    allowFailure: true,
    contracts: address ? STRATEGIES.map((s) => ({ address: INVESTOR_VAULT, abi: investorVaultAbi, functionName: 'hasAccepted' as const, args: [address, vaultOf(s.id)] as const, chainId: CHAIN_ID })) : [],
    query: { enabled: !!address },
  })

  async function addArc() {
    setMsg(undefined)
    try {
      await switchChainAsync({ chainId: CHAIN_ID })
      setMsg('Arc Testnet is active in your wallet.')
    } catch {
      try {
        const provider = (await connector?.getProvider()) as { request: (a: { method: string; params: unknown[] }) => Promise<unknown> } | undefined
        await provider?.request({
          method: 'wallet_addEthereumChain',
          params: [{ chainId: numberToHex(CHAIN_ID), chainName: chainFacts.name, nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: 18 }, rpcUrls: [...chainFacts.rpcUrls], blockExplorerUrls: [chainFacts.explorerBase] }],
        })
        setMsg('Arc Testnet added to your wallet.')
      } catch { setMsg('Your wallet declined or could not add the network.') }
    }
  }

  async function copyAddress() {
    if (!address) return
    try {
      await navigator.clipboard.writeText(address)
      setCopied(true)
      setTimeout(() => setCopied(false), 1600)
    } catch { /* clipboard unavailable */ }
  }

  return (
    <div>
      <PageTitle eyebrow="System" title="Account" sub="Wallet, network and disclosures." />
      <div className="grid gap-4 md:grid-cols-2">
        <Card>
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2">
              <Wallet className="h-4 w-4 text-brand" aria-hidden />
              <h2 className="font-display text-lg font-semibold text-ink">Wallet</h2>
            </div>
            {isConnected && chainId === CHAIN_ID && <span className="pill !border-emerald-400/20 !bg-emerald-400/[0.08] !text-emerald-300"><span className="h-1.5 w-1.5 rounded-full bg-emerald-400" aria-hidden /> Arc Testnet</span>}
          </div>
          {isConnected ? (
            <div className="mt-4 space-y-4">
              <div className="flex items-center gap-2 rounded-xl border border-white/[0.06] bg-black/20 px-3.5 py-3">
                <span className="mono min-w-0 flex-1 break-all text-xs text-ink-2">{address}</span>
                <button onClick={() => void copyAddress()} className="text-ink-3 transition hover:text-ink" aria-label="Copy address">
                  {copied ? <Check className="h-4 w-4 text-up" /> : <Copy className="h-4 w-4" />}
                </button>
              </div>
              <Stat label="USDC balance" value={usd(Number(bal.data ?? 0n) / 1e6)} sub="Arc ERC-20 view (also pays gas)" tier="LIVE-TESTNET" />
              <div className="flex flex-wrap gap-2">
                <a className="btn-ghost !min-h-[36px] !px-3 text-xs" href={addrUrl(address as string)} target="_blank" rel="noopener noreferrer">
                  Explorer <ExternalLink className="h-3.5 w-3.5" />
                </a>
                <button className="btn-ghost !min-h-[36px] !px-3 text-xs" onClick={() => disconnect()}>Disconnect</button>
              </div>
            </div>
          ) : (
            <div className="mt-4">
              <p className="mb-3 text-sm text-ink-3">Connect a wallet to view your address, balance and onchain disclosures.</p>
              <ConnectButton />
            </div>
          )}
        </Card>

        <Card>
          <div className="flex items-center gap-2">
            <Globe2 className="h-4 w-4 text-brand" aria-hidden />
            <h2 className="font-display text-lg font-semibold text-ink">Network and funds</h2>
          </div>
          <dl className="mt-4 space-y-2.5 text-sm">
            {[
              ['Network', chainFacts.name],
              ['Chain ID', String(CHAIN_ID)],
              ['Gas token', 'USDC (18-decimal native view)'],
              ['Fee floor', '20 gwei maxFeePerGas'],
            ].map(([k, v]) => (
              <div key={k} className="flex items-center justify-between gap-3 border-b border-white/[0.05] pb-2.5 last:border-0 last:pb-0">
                <dt className="text-ink-3">{k}</dt>
                <dd className="num text-right font-medium text-ink-2">{v}</dd>
              </div>
            ))}
          </dl>
          <div className="mt-4 flex flex-wrap gap-2">
            <button className="btn-primary !min-h-[38px] !px-3.5 text-xs" disabled={isPending} onClick={() => void addArc()}>Add / switch to Arc Testnet</button>
            <a className="btn-ghost !min-h-[38px] !px-3.5 text-xs" href={faucetUrl} target="_blank" rel="noopener noreferrer">
              Faucet (USDC, EURC, cirBTC) <ExternalLink className="h-3.5 w-3.5" />
            </a>
          </div>
          {msg && <div className="mt-3"><Notice>{msg}</Notice></div>}
        </Card>

        <Card className="md:col-span-2">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="flex items-center gap-2">
              <ShieldCheck className="h-4 w-4 text-brand" aria-hidden />
              <h2 className="font-display text-lg font-semibold text-ink">Disclosures</h2>
            </div>
            <TierBadge tier="DEMO-ONCHAIN" />
          </div>
          <p className="mt-2 text-[13px] leading-relaxed text-ink-3">Acceptance is recorded on chain per strategy when you invest. {FOOTER_DISCLAIMER}</p>
          <ul className="mt-4 divide-y divide-white/[0.06]">
            {STRATEGIES.map((s, i) => (
              <li key={s.id} className="flex flex-wrap items-center justify-between gap-2 py-3 text-sm">
                <span className="flex items-center gap-2 text-ink-2">
                  <span className="icon-tile !h-7 !w-7 font-display text-[10px] font-semibold text-ink">{s.short}</span>
                  {s.short} {s.name}
                  <span className="mono text-[11px] text-ink-4">{short(vaultOf(s.id))}</span>
                </span>
                {isConnected ? (
                  data?.[i]?.result ? (
                    <span className="flex items-center gap-1 text-xs font-medium text-up"><Check className="h-3.5 w-3.5" /> Accepted onchain</span>
                  ) : (
                    <span className="text-xs text-ink-4">Not accepted</span>
                  )
                ) : (
                  <TierBadge tier="DEMO-ONCHAIN" />
                )}
              </li>
            ))}
          </ul>
        </Card>
      </div>
    </div>
  )
}
