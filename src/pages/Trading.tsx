import { useMemo, useState } from 'react'
import { useAccount, useReadContracts } from 'wagmi'
import { erc20Abi, parseUnits } from 'viem'
import { ExternalLink, Loader2, ArrowUpRight } from 'lucide-react'
import { clsx } from 'clsx'
import { CHAIN_ID, D, USDC, faucetUrl, txUrl } from '@/lib/chain'
import { useApi } from '@/lib/api'
import { useHoldings, type Holding } from '@/lib/holdings'
import { useTx } from '@/lib/hooks'
import { demoTokenAbi, routerAbi } from '@/shared/abis'
import { formatUsdc, parseUsdc } from '@/onchain-money'
import { Card, Empty, Notice, PageTitle, Skeleton, TierBadge } from '@/components/ui'
import { AreaLine } from '@/components/charts'
import { ConnectButton } from '@/components/Layout'
import { num, pct, priceFmt, usd } from '@/lib/format'

function TradePanel({ h, onDone }: { h: Holding; onDone: () => void }) {
  const { address, isConnected } = useAccount()
  const router = D.contracts.router
  const [mode, setMode] = useState<'buy' | 'sell'>('buy')
  const [amt, setAmt] = useState('10')
  const tx = useTx()
  const isDemo = h.tier === 'DEMO-ONCHAIN'
  let inRaw = 0n
  try { inRaw = amt ? (mode === 'buy' ? parseUsdc(amt) : parseUnits(amt, h.decimals)) : 0n } catch { inRaw = 0n }

  const { data, refetch } = useReadContracts({
    allowFailure: true,
    contracts: address && isDemo ? [
      { address: USDC, abi: erc20Abi, functionName: 'balanceOf', args: [address], chainId: CHAIN_ID },
      { address: USDC, abi: erc20Abi, functionName: 'allowance', args: [address, router], chainId: CHAIN_ID },
      { address: h.address, abi: erc20Abi, functionName: 'allowance', args: [address, router], chainId: CHAIN_ID },
      mode === 'buy'
        ? { address: router, abi: routerAbi, functionName: 'quoteUsdcForToken', args: [h.address, inRaw], chainId: CHAIN_ID }
        : { address: router, abi: routerAbi, functionName: 'quoteTokenForUsdc', args: [h.address, inRaw], chainId: CHAIN_ID },
    ] : [],
    query: { enabled: !!address && isDemo && inRaw > 0n, refetchInterval: 8000 },
  })
  const usdcBal = (data?.[0]?.result) ?? 0n
  const allowUsdc = (data?.[1]?.result) ?? 0n
  const allowTok = (data?.[2]?.result) ?? 0n
  const quote = (data?.[3]?.result) ?? 0n
  const tokenBal = BigInt(Math.floor(h.balance * 10 ** h.decimals))

  const needApprove = mode === 'buy' ? allowUsdc < inRaw : allowTok < inRaw
  const problem = inRaw === 0n ? 'Enter an amount.' : mode === 'buy' && inRaw > usdcBal ? 'Not enough USDC.' : mode === 'sell' && inRaw > tokenBal ? `Not enough ${h.symbol}.` : undefined
  const outText = mode === 'buy' ? `${num(Number(quote) / 10 ** h.decimals, 6)} ${h.symbol}` : `${formatUsdc(quote)} USDC`

  async function act() {
    if (!address) return
    if (needApprove) {
      const ok = mode === 'buy'
        ? await tx.run({ address: USDC, abi: erc20Abi, functionName: 'approve', args: [router, inRaw] })
        : await tx.run({ address: h.address, abi: erc20Abi, functionName: 'approve', args: [router, inRaw] })
      if (ok) { tx.reset(); await refetch() }
      return
    }
    const minOut = (quote * 99n) / 100n
    const ok = mode === 'buy'
      ? await tx.run({ address: router, abi: routerAbi, functionName: 'swapExactUsdcForToken', args: [h.address, inRaw, minOut, address] })
      : await tx.run({ address: router, abi: routerAbi, functionName: 'swapExactTokenForUsdc', args: [h.address, inRaw, minOut, address] })
    if (ok) { await refetch(); onDone() }
  }

  if (!isDemo) {
    return (
      <Card>
        <div className="flex items-center gap-3">
          <span className="icon-tile font-display text-sm font-semibold text-ink">{h.symbol.slice(0, 2)}</span>
          <div className="flex items-center gap-2">
            <h3 className="font-display text-lg font-semibold text-ink">{h.symbol}</h3>
            <TierBadge tier="LIVE-TESTNET" />
          </div>
        </div>
        <p className="mt-3 text-sm leading-relaxed text-ink-3">
          {h.name} is a real Arc Testnet token. Swapping USDC to {h.symbol} uses Circle App Kit Swap, which needs a Circle API key that is not configured in this demo. Get testnet {h.symbol} from the Circle faucet.
        </p>
        <a className="btn-primary mt-4 w-full" href={faucetUrl} target="_blank" rel="noopener noreferrer">
          Open faucet <ExternalLink className="h-4 w-4" />
        </a>
      </Card>
    )
  }

  return (
    <Card>
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <span className="icon-tile font-display text-sm font-semibold text-ink">{h.symbol.slice(0, 2)}</span>
          <div>
            <h3 className="font-display text-lg font-semibold leading-tight text-ink">Trade {h.symbol}</h3>
            <div className="text-[11px] text-ink-4">{h.name}</div>
          </div>
        </div>
        <TierBadge tier="DEMO-ONCHAIN" />
      </div>

      <div className="segmented mt-4 grid-cols-2" role="tablist">
        {(['buy', 'sell'] as const).map((m) => (
          <button
            key={m}
            role="tab"
            aria-selected={mode === m}
            onClick={() => { setMode(m); tx.reset() }}
            className={clsx('seg-btn', mode === m && 'seg-btn-active')}
          >
            {m}
          </button>
        ))}
      </div>

      <label htmlFor="trade-amt" className="label mt-4 block">{mode === 'buy' ? 'Pay (USDC)' : `Sell (${h.symbol})`}</label>
      <div className="relative mt-1">
        <input
          id="trade-amt"
          className="input num !min-h-[56px] !pr-20 !text-xl font-semibold"
          inputMode="decimal"
          value={amt}
          onChange={(e) => { setAmt(e.target.value.replace(/[^0-9.]/g, '')); tx.reset() }}
        />
        <span className="pointer-events-none absolute right-4 top-1/2 -translate-y-1/2 text-xs font-semibold text-ink-3">{mode === 'buy' ? 'USDC' : h.symbol}</span>
      </div>

      <div className="mt-3 space-y-2 rounded-xl border border-white/[0.06] bg-black/20 p-3.5 text-[13px]">
        <div className="flex justify-between"><span className="text-ink-3">You receive (est.)</span><span className="num font-semibold text-ink">{inRaw > 0n ? outText : '—'}</span></div>
        <div className="flex justify-between"><span className="text-ink-3">Router fee</span><span className="num text-ink-2">0.30%</span></div>
        <div className="flex justify-between"><span className="text-ink-3">Max slippage</span><span className="num text-ink-2">1.00%</span></div>
      </div>

      <p className={clsx('mt-2 min-h-5 text-xs', problem ? 'text-down' : 'text-ink-4')}>{isConnected ? problem ?? `Balance ${num(h.balance, 4)} ${h.symbol}` : ''}</p>

      <div className="mt-2">
        {!isConnected ? <ConnectButton className="w-full" /> : (
          <button className="btn-primary w-full" disabled={!!problem || tx.busy} onClick={() => void act()}>
            {tx.busy && <Loader2 className="h-4 w-4 animate-spin" />}
            {tx.status === 'wallet' ? 'Confirm in wallet…' : tx.status === 'confirming' ? 'Confirming…' : needApprove ? `Approve exactly ${amt || 0} ${mode === 'buy' ? 'USDC' : h.symbol}` : mode === 'buy' ? `Buy ${h.symbol}` : `Sell ${h.symbol}`}
          </button>
        )}
      </div>

      {tx.status === 'success' && tx.hash && (
        <a className="mt-2 inline-flex items-center gap-1 text-xs text-brand-2 underline underline-offset-2" href={txUrl(tx.hash)} target="_blank" rel="noopener noreferrer">
          Done. View transaction <ExternalLink className="h-3.5 w-3.5" />
        </a>
      )}
      {tx.error && <div className="mt-3"><Notice tone="error">{tx.error}</Notice></div>}

      <button
        className="btn-ghost mt-4 w-full"
        disabled={tx.busy || !isConnected}
        onClick={() => void tx.run({ address: h.address, abi: demoTokenAbi, functionName: 'faucet' }).then((ok) => { if (ok) void refetch() })}
      >
        Claim free demo {h.symbol}
      </button>
      <p className="mt-2.5 text-[11px] leading-relaxed text-ink-4">Hourly faucet. Demo tokens have no monetary value; trades execute on the DemoSwapRouter at the simulated oracle price.</p>
    </Card>
  )
}

export default function Trading() {
  const { address } = useAccount()
  const { holdings, prices, refetch } = useHoldings(address)
  const [sel, setSel] = useState('dBTC')
  const cur = useMemo(() => holdings.find((h) => h.symbol === sel) ?? holdings[0], [holdings, sel])
  const hist = useApi<{ points: { ts: number; price: number }[] }>(cur ? `/prices/${cur.symbol}/history?days=90` : null, 60000)

  return (
    <div>
      <PageTitle
        eyebrow="Markets"
        title="Trading"
        sub="Live Arc Testnet tokens (cirBTC, WETH, EURC) and labelled demo tokens. Charts show simulated reference prices."
        right={<span className="pill">Simulated reference prices</span>}
      />

      <div className="grid gap-4 lg:grid-cols-[1fr_380px]">
        <div className="min-w-0 space-y-4">
          <Card className="!p-0 overflow-hidden">
            <div className="flex items-center justify-between p-5 sm:px-6">
              <div>
                <span className="label">Universe</span>
                <h2 className="mt-1 font-display text-lg font-semibold text-ink">Markets</h2>
              </div>
              <TierBadge tier="SIMULATED-OFFCHAIN" />
            </div>
            <div className="divide-y divide-white/[0.05] border-t border-white/[0.06] sm:hidden">
              {prices.isLoading && <div className="p-5"><Skeleton className="h-24" /></div>}
              {holdings.map((h) => (
                <button
                  key={h.symbol}
                  onClick={() => setSel(h.symbol)}
                  className={clsx('flex w-full items-center gap-3 px-5 py-3.5 text-left transition', cur?.symbol === h.symbol ? 'bg-brand/[0.06]' : 'hover:bg-white/[0.03]')}
                >
                  <span className={clsx('flex h-9 w-9 shrink-0 items-center justify-center rounded-lg border text-[10px] font-semibold', cur?.symbol === h.symbol ? 'border-brand/40 bg-brand/[0.15] text-brand-2' : 'border-white/[0.08] bg-white/[0.03] text-ink-3')}>
                    {h.symbol.slice(0, 2)}
                  </span>
                  <span className="min-w-0 flex-1">
                    <span className="flex items-center justify-between gap-2">
                      <span className="font-semibold text-ink">{h.symbol}</span>
                      <span className="num text-[13px] font-medium text-ink">{priceFmt(h.price)}</span>
                    </span>
                    <span className="mt-0.5 flex items-center justify-between gap-2">
                      <span className="truncate text-[11px] text-ink-4">{h.name}</span>
                      <span className={clsx('num text-[11px] font-medium', h.change24hPct >= 0 ? 'text-up' : 'text-down')}>{pct(h.change24hPct)}</span>
                    </span>
                    <span className="mt-1 flex items-center gap-2 text-[10px] text-ink-4">
                      <TierBadge tier={h.tier} />
                      <span className="num">{num(h.balance, 4)}</span>
                      <span>· {usd(h.value)}</span>
                    </span>
                  </span>
                </button>
              ))}
            </div>
            <div className="hidden overflow-x-auto border-t border-white/[0.06] sm:block">
              <table className="data-table min-w-[680px]">
                <thead>
                  <tr>
                    <th>Asset</th>
                    <th>Tier</th>
                    <th className="text-right">Price</th>
                    <th className="text-right">24h</th>
                    <th className="text-right">Holdings</th>
                  </tr>
                </thead>
                <tbody>
                  {prices.isLoading && <tr><td colSpan={5} className="p-5"><Skeleton className="h-24" /></td></tr>}
                  {holdings.map((h) => (
                    <tr
                      key={h.symbol}
                      onClick={() => setSel(h.symbol)}
                      className={clsx('cursor-pointer', cur?.symbol === h.symbol && 'bg-brand/[0.06] hover:bg-brand/[0.08]')}
                      tabIndex={0}
                      onKeyDown={(e) => e.key === 'Enter' && setSel(h.symbol)}
                    >
                      <td>
                        <div className="flex items-center gap-3">
                          <span className={clsx('flex h-8 w-8 items-center justify-center rounded-lg border text-[10px] font-semibold', cur?.symbol === h.symbol ? 'border-brand/40 bg-brand/[0.15] text-brand-2' : 'border-white/[0.08] bg-white/[0.03] text-ink-3')}>
                            {h.symbol.slice(0, 2)}
                          </span>
                          <div>
                            <div className="font-semibold text-ink">{h.symbol}</div>
                            <div className="text-[11px] text-ink-4">{h.name}</div>
                          </div>
                        </div>
                      </td>
                      <td><TierBadge tier={h.tier} /></td>
                      <td className="num text-right font-medium text-ink">{priceFmt(h.price)}</td>
                      <td className={clsx('num text-right font-medium', h.change24hPct >= 0 ? 'text-up' : 'text-down')}>{pct(h.change24hPct)}</td>
                      <td className="num text-right text-ink-2">
                        {num(h.balance, 4)}
                        <div className="text-[11px] text-ink-4">{usd(h.value)}</div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </Card>

          {cur && (
            <Card>
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <div className="flex items-center gap-2">
                    <span className="label">{cur.symbol} / USDC</span>
                    <TierBadge tier="SIMULATED-OFFCHAIN" />
                  </div>
                  <div className="mt-1.5 flex items-baseline gap-2.5">
                    <span className="num font-display text-2xl font-semibold text-ink">{priceFmt(cur.price)}</span>
                    <span className={clsx('pill', cur.change24hPct >= 0 ? '!border-up/25 !bg-up/10 !text-up' : '!border-down/25 !bg-down/10 !text-down')}>{pct(cur.change24hPct)}</span>
                  </div>
                </div>
                <span className="text-[11px] text-ink-4">90-day simulated series</span>
              </div>
              <div className="mt-4">
                {hist.data ? <AreaLine data={hist.data.points} x="ts" y="price" height={280} showGrid fmt={priceFmt} /> : <Skeleton className="mt-3 h-64" />}
              </div>
              <div className="mt-3 flex flex-wrap items-center justify-between gap-2 text-[11px] text-ink-4">
                <span>Seeded geometric Brownian motion · illustrative only</span>
                <a className="inline-flex items-center gap-1 font-medium text-brand-2 transition hover:text-white" href={faucetUrl} target="_blank" rel="noopener noreferrer">
                  Get testnet assets <ArrowUpRight className="h-3 w-3" />
                </a>
              </div>
            </Card>
          )}
        </div>

        <aside className="min-w-0 lg:sticky lg:top-24 lg:self-start">
          {cur ? <TradePanel key={cur.symbol} h={cur} onDone={() => void refetch()} /> : <Empty title="Loading markets" body="Prices stream from the backend." />}
        </aside>
      </div>
    </div>
  )
}
