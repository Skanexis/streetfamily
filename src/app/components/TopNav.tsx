import { useState } from 'react'
import { Bell, ShoppingCart, Star, ShieldCheck, X } from 'lucide-react'
import type { Broadcast, Page } from '../data'

interface TopNavProps {
  page: Page
  navigate: (p: Page) => void
  cartCount: number
  onCartOpen: () => void
  tokens: number
  isAdmin?: boolean
  onAdmin?: () => void
  onLogout?: () => void | Promise<void>
  broadcasts?: Broadcast[]
  onBroadcastProduct?: (productId: string) => void
}

const NAV_LINKS: { label: string; page: Page }[] = [
  { label: 'Inizio', page: 'home' },
  { label: 'Catalogo', page: 'catalog' },
  { label: 'Giochi', page: 'games' },
  { label: 'Regolamento', page: 'info' },
  { label: 'Profilo', page: 'profile' },
]

export function TopNav({ page, navigate, cartCount, onCartOpen, tokens, isAdmin, onAdmin, onLogout, broadcasts = [], onBroadcastProduct }: TopNavProps) {
  const [broadcastOpen, setBroadcastOpen] = useState(false)

  return (
    <nav
      className="fixed top-0 left-0 right-0 z-50 flex items-center justify-between px-4 md:px-8"
      style={{
        height: 64,
        background: 'rgba(8, 12, 14, 0.94)',
        backdropFilter: 'blur(20px)',
        borderBottom: '1px solid rgba(126, 156, 168, 0.2)',
      }}
    >
      {/* Logo */}
      <button
        onClick={() => navigate('home')}
        className="flex items-center gap-2 select-none"
      >
        <div
          className="flex items-center justify-center"
          style={{
            width: 38,
            height: 38,
            background: '#D7FE55',
            fontFamily: 'Orbitron, sans-serif',
            fontWeight: 900,
            fontSize: 14,
            color: '#080C0E',
          }}
        >
          SF
        </div>
        <span
          className="hidden sm:block"
          style={{
            fontFamily: 'Space Grotesk, sans-serif',
            fontWeight: 700,
            fontSize: 18,
            color: '#F5F5F5',
            letterSpacing: '0.08em',
          }}
        >
          STREET FAMILY
        </span>
      </button>

      {/* Desktop nav links */}
      <div className="hidden md:flex items-center gap-1">
        {NAV_LINKS.map((link) => (
          <button
            key={link.page}
            onClick={() => navigate(link.page)}
            className="px-4 py-2 rounded-lg transition-all"
            style={{
              fontFamily: 'Inter, sans-serif',
              fontWeight: 500,
              fontSize: 14,
              color: page === link.page ? '#D7FE55' : 'rgba(245, 245, 245, 0.6)',
              background: 'transparent',
              borderBottom: page === link.page ? '1px solid #D7FE55' : '1px solid transparent',
            }}
          >
            {link.label}
          </button>
        ))}
      </div>

      {/* Right: tokens + cart */}
      <div className="flex items-center gap-3">
        {isAdmin && (
          <button onClick={onAdmin} className="hidden sm:flex items-center gap-1 px-3 py-2 rounded-lg" style={{ color: '#D7FE55', border: '1px solid rgba(215,254,85,.3)', fontSize: 13 }}><ShieldCheck size={14} /> Amministrazione</button>
        )}
        <div
          className="hidden sm:flex items-center gap-1.5 px-3 py-1.5 rounded-full"
          style={{
            background: 'rgba(215, 254, 85, 0.08)',
            border: '1px solid rgba(215, 254, 85, 0.25)',
          }}
        >
          <Star size={13} style={{ color: '#D7FE55' }} fill="#D7FE55" />
          <span
            style={{
              fontFamily: 'Orbitron, sans-serif',
              fontWeight: 700,
              fontSize: 13,
              color: '#D7FE55',
            }}
          >
            {tokens}
          </span>
        </div>

        <button
          onClick={() => setBroadcastOpen(open => !open)}
          aria-label="Notizie"
          className="relative flex items-center justify-center rounded-lg transition-all"
          style={{
            width: 40,
            height: 40,
            background: broadcastOpen ? 'rgba(215,254,85,.12)' : 'rgba(126, 156, 168, 0.1)',
            border: '1px solid rgba(126, 156, 168, 0.3)',
            color: '#F5F5F5',
          }}
        >
          <Bell size={18} />
          {broadcasts.length > 0 && (
            <span className="absolute -top-1.5 -right-1.5 flex items-center justify-center rounded-full" style={{ minWidth: 18, height: 18, padding: '0 4px', background: '#D7FE55', color: '#080C0E', fontSize: 10, fontWeight: 700 }}>
              {broadcasts.length}
            </span>
          )}
        </button>

        <button
          onClick={onCartOpen}
          className="relative flex items-center justify-center rounded-lg transition-all"
          style={{
            width: 40,
            height: 40,
            background: 'rgba(126, 156, 168, 0.1)',
            border: '1px solid rgba(126, 156, 168, 0.3)',
            color: '#F5F5F5',
          }}
        >
          <ShoppingCart size={18} />
          {cartCount > 0 && (
            <span
              className="absolute -top-1.5 -right-1.5 flex items-center justify-center rounded-full"
              style={{
                width: 18,
                height: 18,
                background: '#D7FE55',
                color: '#080C0E',
                fontSize: 10,
                fontWeight: 700,
                fontFamily: 'Orbitron, sans-serif',
              }}
            >
              {cartCount}
            </span>
          )}
        </button>
        <button onClick={onLogout} className="hidden md:block" style={{ color: 'rgba(245,245,245,.55)', fontSize: 12 }}>Esci</button>
      </div>
      {broadcastOpen && (
        <div className="absolute right-4 top-16 mt-2 rounded-2xl p-4" style={{ width: 'min(390px, calc(100vw - 32px))', maxHeight: '70vh', overflowY: 'auto', background: '#11181B', border: '1px solid rgba(126,156,168,.3)', boxShadow: '0 16px 42px rgba(0,0,0,.5)' }}>
          <div className="flex items-center justify-between mb-3">
            <strong style={{ fontFamily: 'Space Grotesk', fontSize: 18 }}>Notizie</strong>
            <button onClick={() => setBroadcastOpen(false)} aria-label="Chiudi notizie" style={{ color: 'rgba(245,245,245,.7)' }}><X size={17} /></button>
          </div>
          {broadcasts.length === 0 && <p style={{ color: 'rgba(245,245,245,.55)', fontSize: 13 }}>Nessuna notizia pubblicata.</p>}
          {broadcasts.map(broadcast => (
            <article key={broadcast.id} className="p-3 mb-2 rounded-xl" style={{ background: 'rgba(245,245,245,.045)' }}>
              <div style={{ color: broadcast.kind === 'product_new' ? '#D7FE55' : '#60A5FA', fontSize: 10, fontWeight: 700, marginBottom: 5 }}>
                {broadcast.kind === 'product_new' ? 'NUOVO PRODOTTO' : 'ANNUNCIO'}
              </div>
              <strong style={{ display: 'block', fontSize: 14 }}>{broadcast.title}</strong>
              <p style={{ color: 'rgba(245,245,245,.67)', fontSize: 13, marginTop: 5 }}>{broadcast.message}</p>
              {broadcast.productId && (
                <button
                  onClick={() => { onBroadcastProduct?.(broadcast.productId!); setBroadcastOpen(false) }}
                  style={{ color: '#D7FE55', fontSize: 12, marginTop: 7 }}
                >
                  Apri catalogo
                </button>
              )}
            </article>
          ))}
        </div>
      )}
    </nav>
  )
}
