// Checksums addresses in deployments/arc-testnet.json and mirrors it to src/shared/deployments.json for the frontend.
import { getAddress } from 'viem'
import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import type { Deployments } from '../server/chain'

const root = resolve(import.meta.dir, '..')
const d = JSON.parse(readFileSync(resolve(root, 'deployments/arc-testnet.json'), 'utf8')) as Deployments
const cs = (a: string) => (a && a.startsWith('0x') && a.length === 42 ? getAddress(a) : a)
for (const k of Object.keys(d.contracts)) d.contracts[k] = cs(d.contracts[k])
for (const s of Object.values(d.strategies)) {
  s.vault = cs(s.vault)
  for (const k of Object.keys(s.modules)) s.modules[k] = cs(s.modules[k])
}
for (const t of Object.values(d.tokens)) t.address = cs(t.address)
d.deployer = cs(d.deployer)
writeFileSync(resolve(root, 'deployments/arc-testnet.json'), JSON.stringify(d, null, 2))
const { txs: _txs, ...pub } = d
writeFileSync(resolve(root, 'src/shared/deployments.json'), JSON.stringify(pub, null, 2))
console.log('synced')
