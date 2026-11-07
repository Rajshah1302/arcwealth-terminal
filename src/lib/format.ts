export const usd = (n: number, digits = 2) =>
  new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', minimumFractionDigits: digits, maximumFractionDigits: digits }).format(n)

export const num = (n: number, digits = 2) =>
  new Intl.NumberFormat('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits }).format(n)

export const pct = (n: number, digits = 2) => `${n >= 0 ? '+' : ''}${n.toFixed(digits)}%`

export const short = (a?: string) => (a ? `${a.slice(0, 6)}...${a.slice(-4)}` : '')

export const priceFmt = (p: number) => (p >= 100 ? usd(p, 0) : p >= 1 ? usd(p, 2) : usd(p, 4))

export const when = (ts: number | string) => new Date(ts).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })

export const dateOnly = (secs: number) => new Date(secs * 1000).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })
