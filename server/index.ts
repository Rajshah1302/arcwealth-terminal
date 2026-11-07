// Backend entrypoint: bun run server (also serves the built frontend from dist/ when present)
import { existsSync } from 'node:fs'
import { join, normalize, resolve } from 'node:path'
import { handle } from './api'
import { ROOT } from './chain'
import { migrate } from './db'
import { startIndexer } from './indexer'
import { keepersEnabled, startKeepers } from './keepers'
import { initPrices, stepPrices } from './prices'

await migrate()
initPrices()
setInterval(stepPrices, 5000)
startIndexer()
if (keepersEnabled()) startKeepers()
else console.log('keepers disabled (no DEPLOYER_PRIVATE_KEY or KEEPERS=off): read-only API')

const dist = resolve(ROOT, 'dist')
const port = Number(process.env.PORT ?? process.env.API_PORT ?? 3001)

Bun.serve({
  port,
  async fetch(req) {
    const url = new URL(req.url)
    if (url.pathname.startsWith('/api') || !existsSync(dist)) return handle(req)
    const file = resolve(dist, '.' + normalize(url.pathname))
    if (url.pathname !== '/' && file.startsWith(dist) && (await Bun.file(file).exists())) return new Response(Bun.file(file))
    return new Response(Bun.file(join(dist, 'index.html')))
  },
})
console.log(`ARCWEALTH on :${port}`)
