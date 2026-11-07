/*
 *  ███████╗████████╗██╗   ██╗██████╗ ██╗ ██████╗
 *  ██╔════╝╚══██╔══╝██║   ██║██╔══██╗██║██╔═══██╗
 *  ███████╗   ██║   ██║   ██║██║  ██║██║██║   ██║
 *  ╚════██║   ██║   ██║   ██║██║  ██║██║██║   ██║
 *  ███████║   ██║   ╚██████╔╝██████╔╝██║╚██████╔╝
 *  ╚══════╝   ╚═╝    ╚═════╝ ╚═════╝ ╚═╝ ╚═════╝
 *
 *  Built with Arc Studio
 *  https://studio.arc.io
 */

import './tracing'
import './console-capture'

import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { WagmiProvider } from 'wagmi'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { ConnectKitProvider } from 'connectkit'
import { Toaster } from 'sonner'
import { config } from './config'
import App from './App'
import { installShareSync } from './lib/share'
import './index.css'

const queryClient = new QueryClient()

const connectKitTheme: Record<string, string> = {
  '--ck-font-family': 'Inter, system-ui, sans-serif',
  '--ck-border-radius': '16px',
  '--ck-overlay-background': 'rgba(3, 3, 5, 0.82)',
  '--ck-modal-background': '#0b0b10',
  '--ck-modal-box-shadow': '0 40px 120px -40px rgba(0,0,0,0.9)',
  '--ck-body-background': '#0b0b10',
  '--ck-body-background-secondary': '#111118',
  '--ck-body-background-tertiary': '#16161f',
  '--ck-body-color': '#eef1f6',
  '--ck-body-color-muted': '#8b93a7',
  '--ck-body-color-danger': '#ff6b81',
  '--ck-body-divider': 'rgba(255,255,255,0.08)',
  '--ck-primary-button-background': 'rgba(255,255,255,0.05)',
  '--ck-primary-button-border-radius': '12px',
  '--ck-primary-button-hover-background': 'rgba(255,255,255,0.09)',
  '--ck-primary-button-color': '#eef1f6',
  '--ck-secondary-button-background': '#111118',
  '--ck-secondary-button-hover-background': '#17171f',
  '--ck-secondary-button-color': '#eef1f6',
  '--ck-tertiary-button-background': 'rgba(255,255,255,0.04)',
  '--ck-tertiary-button-border-color': 'rgba(255,255,255,0.1)',
  '--ck-accent-color': '#5b8cff',
  '--ck-accent-text-color': '#ffffff',
  '--ck-qr-dot-color': '#0b0b10',
  '--ck-qr-background': '#ffffff',
}

const StudioLogo = () => (
  <svg width="13" height="15" viewBox="0 0 20 22" fill="none" xmlns="http://www.w3.org/2000/svg">
    <path d="M0 21.5001C0.167192 16.2366 1.02308 11.3243 2.45378 7.50459C4.26573 2.66517 6.88869 0 9.83904 0C12.7894 0 15.412 2.66517 17.2243 7.50459C18.1669 10.0216 18.8605 13.0121 19.2713 16.2655C19.3081 16.556 19.3393 16.8513 19.3714 17.146C19.3819 17.1642 19.3881 17.1811 19.386 17.1949C19.386 17.1949 19.6275 18.7674 19.6788 21.5001H19.6515C19.2934 21.1937 15.0694 17.7329 8.06739 18.735C8.17304 17.4996 8.31833 16.2974 8.50603 15.1452C8.51562 15.0863 8.52671 15.0294 8.53649 14.9709C11.2828 14.8846 13.6866 15.2171 15.5299 15.6529C15.5231 15.6073 15.5173 15.5603 15.5103 15.5149C15.1314 13.0547 14.5724 10.8024 13.8517 8.87761C12.6732 5.73037 11.1354 3.77496 9.83904 3.77496C8.54269 3.77496 7.00493 5.73037 5.82649 8.87761C5.54123 9.63889 5.28154 10.4508 5.04866 11.3071C4.72126 12.507 4.44621 13.7934 4.22654 15.1451C3.90141 17.1412 3.69827 19.2821 3.62345 21.5001H0Z" fill="currentColor"/>
  </svg>
)

const StudioWatermark = () => (
  <a
    href="https://studio.arc.io/"
    target="_blank"
    rel="noopener noreferrer"
    style={{
      position: 'fixed',
      bottom: '14px',
      right: '14px',
      display: 'flex',
      alignItems: 'center',
      gap: '6px',
      padding: '6px 12px',
      fontSize: '11px',
      fontWeight: 600,
      fontFamily: 'Inter, system-ui, sans-serif',
      letterSpacing: '0.01em',
      color: '#c6ccd8',
      textDecoration: 'none',
      cursor: 'pointer',
      background: 'rgba(10, 10, 15, 0.72)',
      backdropFilter: 'blur(14px) saturate(150%)',
      WebkitBackdropFilter: 'blur(14px) saturate(150%)',
      borderRadius: '999px',
      border: '1px solid rgba(255,255,255,0.1)',
      zIndex: 9999,
      boxShadow: '0 10px 30px -12px rgba(0,0,0,0.8)',
    }}
  >
    <StudioLogo />
    Built with Arc Studio
  </a>
)

installShareSync()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <ConnectKitProvider mode="dark" customTheme={connectKitTheme}>
          <App />
          <StudioWatermark />
          <Toaster
            position="top-right"
            theme="dark"
            toastOptions={{
              style: {
                background: 'rgba(11,11,16,0.94)',
                border: '1px solid rgba(255,255,255,0.1)',
                color: '#eef1f6',
                borderRadius: '14px',
                backdropFilter: 'blur(16px)',
              },
            }}
          />
        </ConnectKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  </StrictMode>,
)
