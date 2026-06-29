import { Home, ShoppingBag, Gamepad2, MessageCircle, Star, User } from 'lucide-react'
import type { Page } from '../data'

interface BottomNavProps {
  page: Page
  navigate: (p: Page) => void
}

const NAV_ITEMS = [
  { label: 'Inizio', page: 'home' as Page, Icon: Home },
  { label: 'Catalogo', page: 'catalog' as Page, Icon: ShoppingBag },
  { label: 'Giochi', page: 'games' as Page, Icon: Gamepad2 },
  { label: 'Contatti', page: 'contacts' as Page, Icon: MessageCircle },
  { label: 'Recensioni', page: 'reviews' as Page, Icon: Star },
  { label: 'Profilo', page: 'profile' as Page, Icon: User },
]

export function BottomNav({ page, navigate }: BottomNavProps) {
  return (
    <nav
      className={`sf-bottom-nav ${page === 'games' ? 'sf-bottom-nav-arcade' : ''} md:hidden fixed bottom-0 left-0 right-0 z-50 flex items-center`}
      style={{
        height: 'calc(64px + env(safe-area-inset-bottom, 0px))',
        paddingBottom: 'env(safe-area-inset-bottom, 0px)',
        background: 'rgba(8, 12, 14, 0.97)',
        backdropFilter: 'blur(20px)',
        borderTop: '1px solid rgba(126, 156, 168, 0.15)',
      }}
    >
      {NAV_ITEMS.map(({ label, page: p, Icon }) => {
        const active = page === p
        return (
          <button
            key={p}
            onClick={() => navigate(p)}
            className="flex-1 flex flex-col items-center justify-center gap-1 py-2 transition-all"
            style={{ color: active ? '#D7FE55' : 'rgba(245, 245, 245, 0.4)' }}
          >
            <div
              className="relative"
              style={{ opacity: active ? 1 : .7 }}
            >
              <Icon size={20} />
            </div>
            <span style={{ fontSize: 10, fontFamily: 'Inter, sans-serif', fontWeight: active ? 600 : 400 }}>
              {label}
            </span>
            {active && (
              <div
                className="absolute bottom-0"
                style={{ width: 32, height: 2, background: '#D7FE55' }}
              />
            )}
          </button>
        )
      })}
    </nav>
  )
}
