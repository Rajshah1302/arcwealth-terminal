import { useMemo } from 'react'
import { useReadContracts } from 'wagmi'
import { erc20Abi, type Address } from 'viem'
import { CHAIN_ID } from '@/lib/chain'
import { useApi, type PriceRow } from '@/lib/api'

export interface Holding { symbol: string; name: string; tier: string; balance: number; price: number; value: number; change24hPct: number; address: Address; decimals: number }

/** Balances of every tradable asset (live + demo) priced with the simulated reference prices. */
export function useHoldings(owner?: Address) {
  const prices = useApi<PriceRow[]>('/prices', 10000)
  const rows = useMemo(() => (prices.data ?? []).filter((p) => p.address), [prices.data])
  const reads = useReadContracts({
    allowFailure: true,
    contracts: owner ? rows.map((r) => ({ address: r.address as Address, abi: erc20Abi, functionName: 'balanceOf' as const, args: [owner] as const, chainId: CHAIN_ID })) : [],
    query: { enabled: !!owner && rows.length > 0, refetchInterval: 8000 },
  })
  const holdings: Holding[] = rows.map((r, i) => {
    const raw = (reads.data?.[i]?.result) ?? 0n
    const balance = Number(raw) / 10 ** r.decimals
    return { symbol: r.symbol, name: r.name, tier: r.assetTier, balance, price: r.price, value: balance * r.price, change24hPct: r.change24hPct, address: r.address as Address, decimals: r.decimals }
  })
  return { holdings, prices, refetch: reads.refetch }
}
