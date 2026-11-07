import { useId } from 'react'
import { Area, AreaChart, CartesianGrid, Cell, Pie, PieChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts'

export const PALETTE = ['#5b8cff', '#a78bfa', '#c9ced8', '#3ddc97', '#f5b544', '#7b8498']

export function Donut({
  data,
  size = 180,
  center,
}: {
  data: { name: string; value: number }[]
  size?: number
  center?: { label: string; value: string }
}) {
  return (
    <div
      className="relative shrink-0"
      style={{ width: size, height: size }}
      role="img"
      aria-label={`Allocation: ${data.map((d) => `${d.name} ${d.value}%`).join(', ')}`}
    >
      <ResponsiveContainer>
        <PieChart>
          <Pie data={data} dataKey="value" innerRadius="65%" outerRadius="98%" paddingAngle={3} cornerRadius={5} stroke="none" isAnimationActive={false}>
            {data.map((_, i) => (
              <Cell key={i} fill={PALETTE[i % PALETTE.length]} />
            ))}
          </Pie>
        </PieChart>
      </ResponsiveContainer>
      {center && (
        <div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center">
          <span className="text-[9px] font-semibold uppercase tracking-[0.16em] text-ink-3">{center.label}</span>
          <span className="num mt-1 font-display text-lg font-semibold text-ink">{center.value}</span>
        </div>
      )}
    </div>
  )
}

export function Legend({ data }: { data: { name: string; value: number }[] }) {
  return (
    <ul className="w-full space-y-2 text-sm">
      {data.map((d, i) => (
        <li key={d.name} className="flex items-center gap-2.5">
          <span
            className="h-2 w-2 rounded-full"
            style={{ background: PALETTE[i % PALETTE.length], boxShadow: `0 0 10px 0 ${PALETTE[i % PALETTE.length]}66` }}
          />
          <span className="truncate text-ink-2">{d.name}</span>
          <span className="num ml-auto font-medium text-ink">{d.value}%</span>
        </li>
      ))}
    </ul>
  )
}

function GlassTooltip({
  active,
  payload,
  fmt,
  labelFmt,
}: {
  active?: boolean
  payload?: { value?: number | string }[]
  label?: string | number
  fmt: (v: number) => string
  labelFmt?: (v: number | string) => string
}) {
  if (!active || !payload?.length) return null
  return (
    <div className="rounded-xl border border-white/10 bg-[#0b0b10]/95 px-3 py-2 shadow-[0_20px_50px_-20px_rgba(0,0,0,0.9)] backdrop-blur-xl">
      <div className="text-[10px] uppercase tracking-[0.14em] text-ink-3">{labelFmt ? 'Date' : 'Value'}</div>
      <div className="num mt-0.5 font-display text-sm font-semibold text-ink">{fmt(Number(payload[0].value))}</div>
    </div>
  )
}

export function AreaLine({
  data,
  x,
  y,
  height = 200,
  color = '#5b8cff',
  fmt = (v: number) => String(v),
  showGrid = false,
  labelFmt,
}: {
  data: Record<string, number | string>[]
  x: string
  y: string
  height?: number
  color?: string
  fmt?: (v: number) => string
  showGrid?: boolean
  labelFmt?: (v: number | string) => string
}) {
  const raw = useId()
  const id = `area-${raw.replace(/[^a-zA-Z0-9]/g, '')}`
  const values = data.map((d) => Number(d[y])).filter((n) => Number.isFinite(n))
  const lo = values.length ? Math.min(...values) : 0
  const hi = values.length ? Math.max(...values) : 1
  const span = hi - lo || Math.abs(hi) * 0.004 || 1
  const domain: [number, number] = [lo - span * 0.12, hi + span * 0.12]
  return (
    <div style={{ height }} className="w-full">
      <ResponsiveContainer>
        <AreaChart data={data} margin={{ top: 8, right: 2, bottom: 0, left: 2 }}>
          <defs>
            <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor={color} stopOpacity={0.32} />
              <stop offset="55%" stopColor={color} stopOpacity={0.08} />
              <stop offset="100%" stopColor={color} stopOpacity={0} />
            </linearGradient>
          </defs>
          {showGrid && <CartesianGrid stroke="rgba(255,255,255,0.05)" vertical={false} />}
          <XAxis dataKey={x} hide />
          <YAxis domain={domain} hide />
          <Tooltip
            content={<GlassTooltip fmt={fmt} labelFmt={labelFmt} />}
            cursor={{ stroke: 'rgba(255,255,255,0.16)', strokeDasharray: '3 4' }}
          />
          <Area
            type="monotone"
            dataKey={y}
            stroke={color}
            strokeWidth={2}
            fill={`url(#${id})`}
            isAnimationActive={false}
            activeDot={{ r: 3.5, fill: color, stroke: '#050507', strokeWidth: 2 }}
          />
        </AreaChart>
      </ResponsiveContainer>
    </div>
  )
}

export function Sparkline({
  data,
  x = 't',
  y = 'v',
  height = 56,
  color = '#5b8cff',
}: {
  data: Record<string, number | string>[]
  x?: string
  y?: string
  height?: number
  color?: string
}) {
  const raw = useId()
  const id = `spark-${raw.replace(/[^a-zA-Z0-9]/g, '')}`
  const values = data.map((d) => Number(d[y])).filter((n) => Number.isFinite(n))
  const lo = values.length ? Math.min(...values) : 0
  const hi = values.length ? Math.max(...values) : 1
  const span = hi - lo || Math.abs(hi) * 0.004 || 1
  const domain: [number, number] = [lo - span * 0.15, hi + span * 0.15]
  return (
    <div style={{ height }} className="w-full">
      <ResponsiveContainer>
        <AreaChart data={data} margin={{ top: 4, right: 0, bottom: 0, left: 0 }}>
          <defs>
            <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor={color} stopOpacity={0.3} />
              <stop offset="100%" stopColor={color} stopOpacity={0} />
            </linearGradient>
          </defs>
          <XAxis dataKey={x} hide />
          <YAxis domain={domain} hide />
          <Area type="monotone" dataKey={y} stroke={color} strokeWidth={1.6} fill={`url(#${id})`} isAnimationActive={false} />
        </AreaChart>
      </ResponsiveContainer>
    </div>
  )
}
