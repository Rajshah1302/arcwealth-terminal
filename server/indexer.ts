// Indexer: logs -> chain_events. Idempotent on (tx_hash, log_index). Small getLogs ranges with backoff; the fallback transport rotates RPCs.
// USDC: only the ERC-20 emitter (0x3600..) is indexed. Native USDC moves also emit Transfer from the system emitter
// 0xffff..fffe (18 dec); those duplicates are intentionally ignored so each transfer is counted once.
import { decodeEventLog, toEventSelector, type Abi, type AbiEvent, type Hex, type Log } from 'viem'
import { getUsdc } from '../src/onchain-facts'
import { CHAIN_ID, loadArtifact, loadDeployments, publicClient } from './chain'
import { sql } from './db'

const dep = loadDeployments()
const USDC = getUsdc(CHAIN_ID)!.address.toLowerCase() as Hex
const RANGE = 2000n
const ID = 'arcwealth-main'

const contractNames = ['SIFStrategyVault', 'InvestorVault', 'RiskManager', 'StrategyManager', 'DemoPriceOracle', 'DemoSwapRouter', 'DemoBondIssuer', 'DemoOptionsCounterparty',
  'DemoLendingPool', 'BondInvestmentModule', 'CoveredCallModule', 'TacticalSleeveModule', 'AssetAllocatorModule', 'DemoERC20', 'ArcWealthTimelock']

const eventAbi: Abi = (() => {
  const seen = new Set<string>()
  const out: AbiEvent[] = []
  for (const n of contractNames) {
    for (const item of loadArtifact(n).abi) {
      if (item.type !== 'event') continue
      const key = `${item.name}(${item.inputs.map((i) => i.type).join(',')})`
      if (!seen.has(key)) { seen.add(key); out.push(item) }
    }
  }
  return out
})()

export const watched: Hex[] = [...new Set([
  ...Object.entries(dep.contracts).filter(([k]) => k !== 'USDC').map(([, v]) => v),
  ...Object.values(dep.strategies).flatMap((s) => [s.vault, ...Object.values(s.modules)]),
  ...Object.entries(dep.tokens).filter(([, t]) => t.tier === 'DEMO-ONCHAIN').map(([, t]) => t.address),
].map((a) => a.toLowerCase() as Hex))]

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const jsonSafe = (v: unknown): unknown => JSON.parse(JSON.stringify(v, (_k, x) => (typeof x === 'bigint' ? x.toString() : x)))
const blockTimes = new Map<bigint, Date>()

async function timeOf(n: bigint): Promise<Date> {
  const hit = blockTimes.get(n)
  if (hit) return hit
  const b = await publicClient.getBlock({ blockNumber: n })
  const d = new Date(Number(b.timestamp) * 1000)
  blockTimes.set(n, d)
  if (blockTimes.size > 500) { const first = blockTimes.keys().next(); if (!first.done) blockTimes.delete(first.value) }
  return d
}

async function store(logs: Log[]) {
  let inserted = 0
  for (const log of logs) {
    if (log.blockNumber == null || log.logIndex == null || !log.transactionHash) continue
    let name = 'Unknown'
    let args: unknown = {}
    try {
      const d = decodeEventLog({ abi: eventAbi, data: log.data, topics: log.topics as [Hex, ...Hex[]] })
      name = String(d.eventName)
      args = jsonSafe(d.args ?? {})
    } catch { /* undecodable log (e.g. foreign event) */ }
    const res = await sql`INSERT INTO chain_events (tx_hash, log_index, block_number, block_time, emitter, event_name, args)
      VALUES (${log.transactionHash}, ${log.logIndex}, ${Number(log.blockNumber)}, ${await timeOf(log.blockNumber)}, ${log.address.toLowerCase()}, ${name}, ${JSON.stringify(args)}::jsonb)
      ON CONFLICT (tx_hash, log_index) DO NOTHING RETURNING tx_hash`
    inserted += (res as unknown[]).length
  }
  return inserted
}

async function withBackoff<T>(fn: () => Promise<T>): Promise<T> {
  let delay = 500
  for (let i = 0; ; i++) {
    try { return await fn() } catch (e) {
      if (i >= 6) throw e
      await sleep(delay)
      delay = Math.min(delay * 2, 8000)
    }
  }
}

async function startBlock(): Promise<bigint> {
  const rows = await sql`SELECT last_block FROM indexer_state WHERE id = ${ID}`
  if (rows.length) return BigInt(String(rows[0].last_block)) + 1n
  const hashes = Object.entries(dep.txs).filter(([k]) => k.startsWith('deploy:')).map(([, v]) => v as Hex)
  const first = await publicClient.getTransactionReceipt({ hash: hashes[0] })
  return first.blockNumber
}

const topicAddr = (a: string) => ('0x' + a.toLowerCase().slice(2).padStart(64, '0')) as Hex
const TRANSFER = toEventSelector('Transfer(address,address,uint256)')

export async function indexOnce(): Promise<{ from: bigint; to: bigint; head: bigint; inserted: number } | null> {
  const head = await withBackoff(() => publicClient.getBlockNumber())
  const from = await startBlock()
  if (from > head) return null
  const to = from + RANGE - 1n < head ? from + RANGE - 1n : head
  const logs = await withBackoff(() => publicClient.getLogs({ address: watched, fromBlock: from, toBlock: to }))
  const ours = watched.map(topicAddr)
  const out = await withBackoff(() => publicClient.request({ method: 'eth_getLogs', params: [{ address: USDC, fromBlock: `0x${from.toString(16)}`, toBlock: `0x${to.toString(16)}`, topics: [TRANSFER, ours] }] }))
  const inn = await withBackoff(() => publicClient.request({ method: 'eth_getLogs', params: [{ address: USDC, fromBlock: `0x${from.toString(16)}`, toBlock: `0x${to.toString(16)}`, topics: [TRANSFER, null, ours] }] }))
  const toLog = (r: Record<string, unknown>): Log => ({
    address: r.address as Hex, blockNumber: BigInt(r.blockNumber as string), logIndex: Number(BigInt(r.logIndex as string)),
    transactionHash: r.transactionHash as Hex, data: r.data as Hex, topics: r.topics as Hex[],
  } as Log)
  const usdcLogs = [...(out as Record<string, unknown>[]), ...(inn as Record<string, unknown>[])].map(toLog)
  const ins = await store([...logs, ...usdcLogs])
  await sql`INSERT INTO indexer_state (id, last_block, updated_at) VALUES (${ID}, ${Number(to)}, now())
    ON CONFLICT (id) DO UPDATE SET last_block = EXCLUDED.last_block, updated_at = now()`
  return { from, to, head, inserted: ins }
}

export function startIndexer() {
  let running = false
  const tick = async () => {
    if (running) return
    running = true
    try {
      for (let i = 0; i < 50; i++) {
        const r = await indexOnce()
        if (!r || r.to >= r.head) break
      }
    } catch (e) { console.warn('[indexer]', String((e as Error).message).split('\n')[0]) } finally { running = false }
  }
  void tick()
  setInterval(() => void tick(), 8000)
}

export async function indexerStatus() {
  const rows = await sql`SELECT last_block FROM indexer_state WHERE id = ${ID}`
  return rows.length ? Number(rows[0].last_block) : 0
}
