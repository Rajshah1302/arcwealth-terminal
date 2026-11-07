// Shared Arc Testnet clients for scripts and the backend (Bun runtime).
import { createPublicClient, createWalletClient, defineChain, fallback, http, parseGwei, type Abi, type Hex, type PublicClient, type WalletClient } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { existsSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { requireChain } from '../src/onchain-facts'

export const ROOT = resolve(import.meta.dir, '..')
export const CHAIN_ID = 5042002
const facts = requireChain(CHAIN_ID)

/** Arc Testnet: native gas currency is USDC with 18 decimals; the ERC-20 view has 6. */
export const arcTestnet = defineChain({
  id: CHAIN_ID,
  name: facts.name,
  nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: facts.nativeCurrency.decimals },
  rpcUrls: { default: { http: [...facts.rpcUrls] } },
  blockExplorers: { default: { name: 'Arc Explorer', url: facts.explorerBase } },
})

export const MIN_FEE = parseGwei('20') // Arc mempool floor: lower maxFeePerGas is silently dropped

/** RPC order: per-chain override, provisioned proxy, ARC_TESTNET_RPC_URL, optional fallbacks, registry default. */
function rpcList(): string[] {
  const out: string[] = []
  const env = process.env
  if (env.RPC_URL_Arc_Testnet) out.push(env.RPC_URL_Arc_Testnet)
  const proxied = (env.RPC_PROXY_CHAINS || '').split(',').includes('Arc_Testnet')
  if (proxied && env.RPC_PROXY_BASE_URL) out.push(`${env.RPC_PROXY_BASE_URL}/api/rpc/Arc_Testnet?_rpc_token=${env.RPC_PROXY_TOKEN}`)
  if (env.ARC_TESTNET_RPC_URL) out.push(env.ARC_TESTNET_RPC_URL)
  for (const u of (env.ARC_TESTNET_FALLBACK_RPCS || '').split(',')) if (u.trim()) out.push(u.trim())
  out.push(...facts.rpcUrls)
  return [...new Set(out)]
}

export const transport = fallback(
  rpcList().map((u) => http(u, { retryCount: 3, retryDelay: 400, timeout: 20_000 })),
  { rank: false },
)

export const publicClient: PublicClient = createPublicClient({ chain: arcTestnet, transport })

export function keeperAccount() {
  const key = process.env.DEPLOYER_PRIVATE_KEY as Hex | undefined
  if (!key || !/^0x[0-9a-fA-F]{64}$/.test(key)) throw new Error('DEPLOYER_PRIVATE_KEY is not set (run: bun run scripts/gen-key.ts)')
  return privateKeyToAccount(key)
}

export function walletFor(): WalletClient {
  return createWalletClient({ account: keeperAccount(), chain: arcTestnet, transport })
}

/** EIP-1559 type-2 fees clamped to at least 20 gwei maxFeePerGas. */
export async function fees() {
  const est = await publicClient.estimateFeesPerGas()
  let maxFeePerGas = ((est.maxFeePerGas ?? MIN_FEE) * 12n) / 10n
  if (maxFeePerGas < MIN_FEE) maxFeePerGas = MIN_FEE
  let maxPriorityFeePerGas = est.maxPriorityFeePerGas ?? 1n
  if (maxPriorityFeePerGas > maxFeePerGas) maxPriorityFeePerGas = maxFeePerGas
  return { type: 'eip1559' as const, maxFeePerGas, maxPriorityFeePerGas }
}

export interface Artifact {
  abi: Abi
  bytecode: Hex
}

export function loadArtifact(name: string): Artifact {
  const p = resolve(ROOT, `contracts/out/${name}.sol/${name}.json`)
  if (!existsSync(p)) {
    // deployed environments ship only ABIs (deployments/abis.json, see scripts/export-server-abis.ts)
    const bundled = resolve(ROOT, 'deployments/abis.json')
    if (existsSync(bundled)) {
      const all = JSON.parse(readFileSync(bundled, 'utf8')) as Record<string, Abi>
      if (all[name]) return { abi: all[name], bytecode: '0x' }
    }
    throw new Error(`missing artifact ${p}; run forge build`)
  }
  const j = JSON.parse(readFileSync(p, 'utf8')) as { abi: Abi; bytecode: { object: Hex } }
  return { abi: j.abi, bytecode: j.bytecode.object }
}

export interface Deployments {
  chainId: number
  network: string
  deployer: string
  deployedAt: string
  contracts: Record<string, string>
  strategies: Record<string, { vault: string; modules: Record<string, string>; disclosureHash: string; configHash: string }>
  tokens: Record<string, { address: string; decimals: number; tier: string }>
  txs: Record<string, string>
}

export function loadDeployments(): Deployments {
  const p = resolve(ROOT, 'deployments/arc-testnet.json')
  if (!existsSync(p)) throw new Error('deployments/arc-testnet.json not found; run the deploy script')
  return JSON.parse(readFileSync(p, 'utf8')) as Deployments
}

/** Sends a write, waits for the receipt (finality is sub-second on Arc) and throws on revert. */
export async function writeAndWait(wallet: WalletClient, params: { address: Hex; abi: Abi; functionName: string; args?: readonly unknown[] }) {
  const f = await fees()
  const hash = await wallet.writeContract({ ...params, ...f, account: wallet.account!, chain: arcTestnet })
  const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 60_000 })
  if (receipt.status !== 'success') throw new Error(`${params.functionName} reverted (${hash})`)
  return { hash, receipt }
}
