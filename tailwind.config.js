/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,ts,jsx,tsx}'],
  theme: {
    extend: {
      colors: {
        void: '#050507',
        panel: '#0b0b10',
        surface: '#111118',
        elevated: '#16161f',
        navy: '#0b0b10',
        'navy-2': '#111118',
        ink: {
          DEFAULT: '#eef1f6',
          2: '#c6ccd8',
          3: '#8b93a7',
          4: '#5f6678',
        },
        brand: {
          DEFAULT: '#5b8cff',
          2: '#7aa2ff',
          3: '#3d6ef5',
          soft: 'rgba(91, 140, 255, 0.12)',
        },
        violet: '#a78bfa',
        silver: '#c9ced8',
        up: '#3ddc97',
        down: '#ff6b81',
        warn: '#f5b544',
      },
      fontFamily: {
        display: ['"Inter Tight"', 'Inter', 'system-ui', 'sans-serif'],
        sans: ['Inter', 'system-ui', '-apple-system', 'sans-serif'],
        mono: ['"JetBrains Mono"', 'Menlo', 'monospace'],
      },
      boxShadow: {
        card: '0 1px 0 rgba(255,255,255,0.04) inset, 0 24px 60px -32px rgba(0,0,0,0.9)',
        glow: '0 0 0 1px rgba(91,140,255,0.28), 0 18px 50px -18px rgba(61,110,245,0.55)',
        'inner-line': 'inset 0 1px 0 rgba(255,255,255,0.06)',
      },
      backgroundImage: {
        'brand-sheen': 'linear-gradient(180deg, #6b9bff 0%, #3f6ff0 100%)',
        'panel-sheen': 'linear-gradient(180deg, rgba(255,255,255,0.045), rgba(255,255,255,0.012))',
        'grid-fade':
          'linear-gradient(to right, rgba(255,255,255,0.04) 1px, transparent 1px), linear-gradient(to bottom, rgba(255,255,255,0.04) 1px, transparent 1px)',
      },
      keyframes: {
        'fade-up': {
          '0%': { opacity: '0', transform: 'translateY(8px)' },
          '100%': { opacity: '1', transform: 'translateY(0)' },
        },
        'pulse-soft': {
          '0%, 100%': { opacity: '1' },
          '50%': { opacity: '0.45' },
        },
        shimmer: {
          '0%': { backgroundPosition: '-200% 0' },
          '100%': { backgroundPosition: '200% 0' },
        },
      },
      animation: {
        'fade-up': 'fade-up 0.5s cubic-bezier(0.22, 1, 0.36, 1) both',
        'pulse-soft': 'pulse-soft 2.4s ease-in-out infinite',
        shimmer: 'shimmer 2s linear infinite',
      },
    },
  },
  plugins: [],
}
