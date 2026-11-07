import { useCallback, useState } from 'react'
import { useAccount, usePublicClient, useReadContract, useSwitchChain, useWriteContract } from 'wagmi'
import { BaseError, ContractFunctionRevertedError, erc20Abi, parseGwei, type Abi, type Address, type Hash } from 'viem'
import { CHAIN_ID, USDC } from '@/lib/chain'

export const MIN_FEE = parseGwei('20') // Arc mempool floor: anything lower is silently dropped

/** Friendly messages for the custom errors raised by ARCWEALTH contracts. */
const ERRORS: Record<string, string> = {
  DisclosureRequired: 'Accept the strategy disclosure on chain first.',
  DepositTooSmall: 'Below the 10 USDC minimum deposit.',
  ERC4626ExceededMaxDeposit: 'Over the current deposit limit (10 USDC minimum, 250 USDC per investor, 1,000 USDC strategy cap) or deposits are paused or prices are stale.',
  ERC4626ExceededMaxWithdraw: 'More than the instant-withdrawal buffer. Use "Request large withdrawal" instead.',
  ERC4626ExceededMaxRedeem: 'More than the instant-withdrawal buffer. Use "Request large withdrawal" instead.',
  EnforcedPause: 'Deposits are paused by the pauser role.',
  PricesStale: 'Simulated oracle prices are stale. The keeper will refresh them shortly.',
  StalePrice: 'Oracle price is older than one hour. The keeper will refresh it shortly.',
  StepTooLarge: 'Price move exceeds the oracle 10% step limit.',
  InsufficientLiquidity: 'The demo swap router does not hold enough USDC reserve for this sale.',
  SlippageExceeded: 'Price moved. Try again.',
  FaucetCooldown: 'Demo faucet is limited to one claim per hour per address.',
  FaucetDisabled: 'Demo faucet is disabled.',
  NothingToClaim: 'Nothing to claim.',
  ERC20InsufficientBalance: 'Insufficient balance.',
  ERC20InsufficientAllowance: 'Approval is lower than the amount. Approve the exact amount again.',
  AccessControlUnauthorizedAccount: 'Your wallet does not hold the required role.',
  TimelockUnauthorizedCaller: 'Only the timelock proposer can do this.',
}

export function parseTxError(e: unknown): { message: string; rejected: boolean } {
  const msg = String((e as { message?: string })?.message ?? e)
  const code = (e as { code?: number; cause?: { code?: number } })?.code ?? (e as { cause?: { code?: number } })?.cause?.code
  if (code === 4001 || /user rejected|user denied/i.test(msg)) return { message: 'Transaction cancelled in your wallet.', rejected: true }
  if (e instanceof BaseError) {
    const r = e.walk((x) => x instanceof ContractFunctionRevertedError)
    if (r instanceof ContractFunctionRevertedError && r.data?.errorName) return { message: ERRORS[r.data.errorName] ?? `Reverted: ${r.data.errorName}`, rejected: false }
  }
  if (/insufficient funds/i.test(msg)) return { message: 'Not enough USDC for gas. Use "Get test USDC" in the sidebar or the Profile faucet link.', rejected: false }
  if (/timeout|network|fetch|rpc/i.test(msg)) return { message: 'Network or RPC issue. Check your connection and retry; your input is kept.', rejected: false }
  if (/dropped|replaced|underpriced/i.test(msg)) return { message: 'Transaction was dropped. Fees on Arc must be at least 20 gwei; retry.', rejected: false }
  return { message: msg.split('\n')[0].slice(0, 200) || 'Something went wrong. Please try again.', rejected: false }
}

export function useUsdcBalance(address?: Address) {
  return useReadContract({ address: USDC, abi: erc20Abi, functionName: 'balanceOf', args: address ? [address] : undefined, chainId: CHAIN_ID, query: { enabled: !!address, refetchInterval: 8000 } })
}

export type TxStatus = 'idle' | 'wallet' | 'confirming' | 'success' | 'error'

/** Runs one contract write: switches chain, clamps fees to >= 20 gwei (type 2), waits for the receipt before reporting success. */
export function useTx() {
  const { chainId, address } = useAccount()
  const { switchChainAsync } = useSwitchChain()
  const client = usePublicClient({ chainId: CHAIN_ID })
  const { writeContractAsync } = useWriteContract()
  const [status, setStatus] = useState<TxStatus>('idle')
  const [hash, setHash] = useState<Hash>()
  const [error, setError] = useState<string>()

  const reset = useCallback(() => { setStatus('idle'); setHash(undefined); setError(undefined) }, [])

  const run = useCallback(
    async (p: { address: Address; abi: Abi; functionName: string; args?: readonly unknown[] }): Promise<Hash | false> => {
      if (!client || !address) { setError('Connect your wallet first.'); setStatus('error'); return false }
      setError(undefined); setHash(undefined)
      try {
        if (chainId !== CHAIN_ID) await switchChainAsync({ chainId: CHAIN_ID })
        setStatus('wallet')
        const est = await client.estimateFeesPerGas()
        let maxFeePerGas = ((est.maxFeePerGas ?? MIN_FEE) * 12n) / 10n
        if (maxFeePerGas < MIN_FEE) maxFeePerGas = MIN_FEE
        const prio = est.maxPriorityFeePerGas ?? 1n
        const h = await writeContractAsync({ ...p, account: address, chainId: CHAIN_ID, type: 'eip1559', maxFeePerGas, maxPriorityFeePerGas: prio > maxFeePerGas ? maxFeePerGas : prio } as never)
        setHash(h)
        setStatus('confirming')
        const rc = await client.waitForTransactionReceipt({ hash: h, timeout: 60_000 })
        if (rc.status !== 'success') throw new Error('Transaction reverted onchain.')
        setStatus('success')
        return h
      } catch (e) {
        const { message, rejected } = parseTxError(e)
        if (rejected) { setStatus('idle'); setError(message) } else { setStatus('error'); setError(message) }
        return false
      }
    },
    [client, address, chainId, switchChainAsync, writeContractAsync],
  )

  return { run, status, hash, error, reset, busy: status === 'wallet' || status === 'confirming' }
}
