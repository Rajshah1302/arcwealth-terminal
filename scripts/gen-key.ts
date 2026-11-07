// Generates DEPLOYER_PRIVATE_KEY into .env if missing. Prints only the public address.
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { appendFileSync, existsSync, readFileSync } from 'node:fs'

const envPath = new URL('../.env', import.meta.url).pathname
const body = existsSync(envPath) ? readFileSync(envPath, 'utf8') : ''
if (/^DEPLOYER_PRIVATE_KEY=0x[0-9a-fA-F]{64}/m.test(body)) {
  const key = body.match(/^DEPLOYER_PRIVATE_KEY=(0x[0-9a-fA-F]{64})/m)![1] as `0x${string}`
  console.log('exists', privateKeyToAccount(key).address)
} else {
  const key = generatePrivateKey()
  appendFileSync(envPath, `${body.endsWith('\n') || body === '' ? '' : '\n'}DEPLOYER_PRIVATE_KEY=${key}\n`)
  console.log('created', privateKeyToAccount(key).address)
}
