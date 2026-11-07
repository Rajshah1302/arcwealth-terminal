import type { Address } from 'viem'
import dep from '@/shared/deployments.json'
import { buildAddressExplorerUrl, buildTxExplorerUrl, requireChain } from '@/onchain-facts'

export const CHAIN_ID = 5042002 as const
export const chainFacts = requireChain(CHAIN_ID)

export const D = dep as unknown as {
  contracts: Record<string, Address>
  strategies: Record<string, { vault: Address; modules: Record<string, Address>; disclosureHash: `0x${string}`; configHash: `0x${string}` }>
  tokens: Record<string, { address: Address; decimals: number; tier: string }>
}

export const USDC = D.contracts.USDC
export const INVESTOR_VAULT = D.contracts.investorVault
export const vaultOf = (id: string) => D.strategies[id].vault
export const txUrl = (hash: string) => buildTxExplorerUrl(CHAIN_ID, hash)
export const addrUrl = (a: string) => buildAddressExplorerUrl(CHAIN_ID, a)
export const faucetUrl = 'https://faucet.circle.com'
