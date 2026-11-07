/// <reference types="vite/client" />

declare module '@circlefin/compass-chains' {
  export interface CompassChain {
    name: string
    explorerUrl?: string
    nativeCurrency: { name: string; symbol: string; decimals: number }
  }
  export function getChain(chain: string): CompassChain
}
