import { SQL } from 'bun'
import { PGlite } from '@electric-sql/pglite'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { ROOT } from './chain'

type Row = Record<string, unknown>
interface Db {
  (strings: TemplateStringsArray, ...values: unknown[]): Promise<Row[]>
  unsafe(statement: string): Promise<unknown>
}

/** Postgres via Bun.sql when DATABASE_URL is set; otherwise an in-process Postgres (PGlite) so the API runs anywhere. */
function connect(): Db {
  const url = process.env.DATABASE_URL
  if (url) return new SQL(url) as unknown as Db
  const pg = new PGlite()
  const tag = (async (strings: TemplateStringsArray, ...values: unknown[]) => {
    let text = strings[0]
    for (let i = 0; i < values.length; i++) text += `$${i + 1}${strings[i + 1]}`
    const res = await pg.query(text, values)
    return res.rows as Row[]
  }) as Db
  tag.unsafe = (statement: string) => pg.exec(statement)
  return tag
}

export const sql: Db = connect()

/** Applies docs/DB_SCHEMA.sql (idempotent: CREATE ... IF NOT EXISTS). */
export async function migrate() {
  const ddl = readFileSync(resolve(ROOT, 'docs/DB_SCHEMA.sql'), 'utf8')
  for (const stmt of ddl.split(/;\s*\n/).map((s) => s.replace(/^\s*--.*$/gm, '').trim()).filter(Boolean)) {
    await sql.unsafe(stmt)
  }
}

const safe = (v: unknown) => JSON.stringify(v, (_k, x) => (typeof x === 'bigint' ? x.toString() : x))

export async function logEvent(kind: string, detail: Record<string, unknown>, strategyId?: string, txHash?: string) {
  await sql`INSERT INTO strategy_events (strategy_id, kind, detail, tx_hash) VALUES (${strategyId ?? null}, ${kind}, ${safe(detail)}::jsonb, ${txHash ?? null})`
}
