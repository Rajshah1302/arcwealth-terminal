import { useQuery } from '@tanstack/react-query'
import type { StrategyMeta } from '@/shared/strategies'

async function get<T>(path: string): Promise<T> {
  const r = await fetch(`/api${path}`)
  if (!r.ok) throw new Error(((await r.json().catch(() => ({}))) as { error?: string }).error ?? `API ${r.status}`)
  return (await r.json()) as T
}

export const useApi = <T,>(path: string | null, refetchMs = 15000) =>
  useQuery({ queryKey: ['api', path], queryFn: () => get<T>(path as string), enabled: !!path, refetchInterval: refetchMs, retry: 1 })

export interface PriceRow { symbol: string; name: string; price: number; change24hPct: number; assetTier: string; tier: string; address?: string; decimals: number }
export interface Backtest { ret1m: number; ret3m: number; ret6m: number; volAnn: number; maxDrawdown: number; series: { day: number; nav: number }[] }
export interface Live { vault: string; navUsdc: number; shares: number; idleUsdc: number; sharePrice: number; modules: { module: string; valueUsdc: number }[] }
export interface StrategyRow { meta: StrategyMeta; live: Live; backtest: Backtest }
export interface Bond { id: number; name: string; rating: string; couponPct: number; issuedAt: number; maturity: number; unitsUsdc: number; accruedUsdc: number; active: boolean }
export interface CallRow { id: number; underlying: string; qty: number; strike: number; expiry: number; premiumUsdc: number; status: string; mtmUsdc: number; delta: number }
export interface StrategyDetail extends StrategyRow {
  regime: { id: number; name: string; vol30dPct: number }
  bonds?: Bond[]
  calls?: CallRow[]
  tactical?: { cashBps: number; tbillBps: number; putsBps: number; note: string }
  modules: Record<string, string>
  disclosureHash: `0x${string}`
  configHash: `0x${string}`
}
export interface Position { strategy: string; name: string; vault: string; shares: number; costBasisUsdc: number; valueUsdc: number; sharePrice: number; entrySharePrice: number; pnlUsdc: number; totalReturnPct: number; pendingRedeemShares: number; claimableUsdc: number }
export interface HistoryRow { tx_hash: string; log_index: number; block_number: number; block_time: string; emitter: string; event_name: string; args: Record<string, string>; tier: string }
