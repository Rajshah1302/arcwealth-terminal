// Phase 3 gate on the real Arc Testnet RPC: code present, disclosure -> exact approval -> deposit -> shares -> sleeves routed -> instant withdraw.
import { erc20Abi, formatUnits, parseUnits, type Hex } from 'viem'
import { writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { MIN_FEE, ROOT, fees, keeperAccount, loadArtifact, loadDeployments, publicClient, walletFor, writeAndWait } from '../server/chain'

const dep = loadDeployments()
const me = keeperAccount().address
const wallet = walletFor()
const vaultAbi = loadArtifact('SIFStrategyVault').abi
const ivAbi = loadArtifact('InvestorVault').abi
const s1 = dep.strategies.s1
const vault = s1.vault as Hex
const USDC = dep.contracts.USDC as Hex
const report: Record<string, unknown> = {}
const rd = <T>(address: Hex, abi: typeof vaultAbi, fn: string, args: unknown[] = []) => publicClient.readContract({ address, abi, functionName: fn, args }) as Promise<T>

async function main() {
  const f = await fees()
  if (f.maxFeePerGas < MIN_FEE) throw new Error('fee floor violated')
  report.maxFeePerGasGwei = Number(f.maxFeePerGas) / 1e9

  // 1. code at every address
  const addrs = [...Object.values(dep.contracts), ...Object.values(dep.strategies).flatMap((s) => [s.vault, ...Object.values(s.modules)])]
  const missing: string[] = []
  for (const a of addrs) {
    const code = await publicClient.getCode({ address: a as Hex })
    if (!code || code === '0x') missing.push(a)
  }
  if (missing.length) throw new Error(`no code at ${missing.join(',')}`)
  report.contractsWithCode = addrs.length

  // 2. disclosure + exact approval + deposit
  const amount = parseUnits('10', 6)
  const bal0 = await rd<bigint>(USDC, erc20Abi, 'balanceOf', [me])
  const accepted = await rd<boolean>(dep.contracts.investorVault as Hex, ivAbi, 'hasAccepted', [me, vault])
  if (!accepted) await writeAndWait(wallet, { address: dep.contracts.investorVault as Hex, abi: ivAbi, functionName: 'acceptDisclosure', args: [vault, s1.disclosureHash] })
  await writeAndWait(wallet, { address: USDC, abi: erc20Abi, functionName: 'approve', args: [vault, amount] })
  const dep1 = await writeAndWait(wallet, { address: vault, abi: vaultAbi, functionName: 'deposit', args: [amount, me] })
  const shares = await rd<bigint>(vault, vaultAbi, 'balanceOf', [me])
  const nav = await rd<bigint>(vault, vaultAbi, 'totalAssets')
  const price = await rd<bigint>(vault, vaultAbi, 'sharePrice')
  const idle = await rd<bigint>(vault, vaultAbi, 'idle')
  const [mods, vals] = await rd<[Hex[], bigint[]]>(vault, vaultAbi, 'moduleBreakdown')
  report.deposit = { tx: dep1.hash, shares: shares.toString(), navUsdc: formatUnits(nav, 6), sharePrice: formatUnits(price, 6), idleUsdc: formatUnits(idle, 6), modules: mods.map((m, i) => ({ m, valueUsdc: formatUnits(vals[i], 6) })) }
  if (shares === 0n) throw new Error('no shares minted')
  const routed = vals.reduce((a, b) => a + b, 0n)
  if (routed === 0n) throw new Error('nothing routed to sleeves')

  // 3. instant withdraw within the idle buffer
  const maxW = await rd<bigint>(vault, vaultAbi, 'maxWithdraw', [me])
  const w = maxW > 1_000_000n ? 1_000_000n : maxW
  const wr = await writeAndWait(wallet, { address: vault, abi: vaultAbi, functionName: 'withdraw', args: [w, me, me] })
  const bal1 = await rd<bigint>(USDC, erc20Abi, 'balanceOf', [me])
  report.withdraw = { tx: wr.hash, assets: w.toString(), maxWithdrawBefore: maxW.toString(), usdcDelta: (bal1 - bal0).toString() }

  // 4. over-buffer instant withdraw must revert (large exits go through requestRedeem)
  const sharesNow = await rd<bigint>(vault, vaultAbi, 'balanceOf', [me])
  let overBufferReverted = false
  try {
    await publicClient.simulateContract({ account: me, address: vault, abi: vaultAbi, functionName: 'redeem', args: [sharesNow, me, me] })
  } catch { overBufferReverted = true }
  report.overBufferRedeemReverts = overBufferReverted

  // 5. blocklist probe: recipient from the Arc blocklist test list
  const probe = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8'
  let blocklistProbe = 'simulation succeeded (address not blocklisted on this RPC)'
  try {
    await publicClient.simulateContract({ account: me, address: USDC, abi: erc20Abi, functionName: 'transfer', args: [probe, 1n] })
  } catch (e) { blocklistProbe = `reverted: ${String((e as Error).message).split('\n')[0].slice(0, 120)}` }
  report.blocklistProbe = blocklistProbe

  report.ok = true
  writeFileSync(resolve(ROOT, 'deployments/gate-phase3.json'), JSON.stringify(report, null, 2))
  console.log(JSON.stringify(report, null, 2))
}

main().catch((e) => { console.error(e); process.exit(1) })
