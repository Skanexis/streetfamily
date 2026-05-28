import { useCallback, useEffect, useState } from 'react'
import { Navigate, Route, Routes, useLocation, useNavigate } from 'react-router-dom'
import type { Broadcast, CartItem, Feedback, KycStatus, LedgerEntry, Level, Page, Product, ServiceArea, TestOrder, UserReward } from './data'
import { TopNav } from './components/TopNav'
import { BottomNav } from './components/BottomNav'
import { HomePage } from './components/HomePage'
import { CatalogPage } from './components/CatalogPage'
import { GamesPage } from './components/GamesPage'
import { ProfilePage } from './components/ProfilePage'
import { InfoPage } from './components/InfoPage'
import { ContactsPage } from './components/ContactsPage'
import { CartDrawer } from './components/CartDrawer'
import { AdminPage } from './components/AdminPage'
import { AccessDeniedPage, AccessPendingPage, BlockedPage, CallbackPage, LoginPage, RequireAdmin, RequireMember } from './components/AuthPages'

import { useAuth } from './auth/AuthProvider'
import { getBroadcasts, getCatalog, getCatalogCategories, getKycStatus, getLevels, getProfileActivity, getServiceAreas, playGame, submitTestOrder } from './lib/api'
import { italianErrorMessage } from './lib/errors'
import '../styles/fonts.css'

const PAGE_PATHS: Record<Page, string> = { home: '/', catalog: '/catalog', games: '/games', profile: '/profile', info: '/info', contacts: '/contacts' }

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route path="/auth/callback" element={<CallbackPage />} />
      <Route path="/access-denied" element={<AccessDeniedPage />} />
      <Route path="/access-pending" element={<AccessPendingPage />} />
      <Route path="/blocked" element={<BlockedPage />} />
      <Route path="/*" element={<RequireMember><CurrentMemberApplication /></RequireMember>} />
    </Routes>
  )
}

function CurrentMemberApplication() {
  const auth = useAuth()
  return <MemberApplication key={auth.profile!.id} />
}

function MemberApplication() {
  const auth = useAuth()
  const navigateRouter = useNavigate()
  const location = useLocation()
  const user = auth.profile!
  const [cart, setCart] = useState<CartItem[]>([])
  const [cartOpen, setCartOpen] = useState(false)
  const [selectedProductId, setSelectedProductId] = useState<string | null>(null)
  const [products, setProducts] = useState<Product[]>([])
  const [catalogCategories, setCatalogCategories] = useState<string[]>([])
  const [levels, setLevels] = useState<Level[]>([])
  const [broadcasts, setBroadcasts] = useState<Broadcast[]>([])
  const [orders, setOrders] = useState<TestOrder[]>([])
  const [ledger, setLedger] = useState<LedgerEntry[]>([])
  const [rewards, setRewards] = useState<UserReward[]>([])
  const [feedback, setFeedback] = useState<Feedback[]>([])
  const [serviceAreas, setServiceAreas] = useState<ServiceArea[]>([])
  const [kycStatus, setKycStatus] = useState<KycStatus>({ status: 'not_started', documents: [], submittedAt: null, rejectionReason: null })
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  useEffect(() => {
    type TelegramViewport = {
      initData?: string
      viewportHeight?: number
      viewportStableHeight?: number
      expand?: () => void
      ready?: () => void
      disableVerticalSwipes?: () => void
      onEvent?: (event: string, callback: () => void) => void
      offEvent?: (event: string, callback: () => void) => void
    }
    const telegram = (window as Window & { Telegram?: { WebApp?: TelegramViewport } }).Telegram?.WebApp
    const root = document.documentElement
    const isMiniApp = Boolean(telegram?.initData)
    const setViewportHeight = () => {
      const height = telegram?.viewportStableHeight || telegram?.viewportHeight || window.visualViewport?.height || window.innerHeight
      root.style.setProperty('--sf-app-height', `${Math.round(height)}px`)
    }
    root.classList.toggle('sf-telegram-app', isMiniApp)
    setViewportHeight()
    if (isMiniApp) {
      telegram?.ready?.()
      telegram?.expand?.()
      telegram?.disableVerticalSwipes?.()
    }
    window.visualViewport?.addEventListener('resize', setViewportHeight)
    window.addEventListener('orientationchange', setViewportHeight)
    telegram?.onEvent?.('viewportChanged', setViewportHeight)
    return () => {
      root.classList.remove('sf-telegram-app')
      root.style.removeProperty('--sf-app-height')
      window.visualViewport?.removeEventListener('resize', setViewportHeight)
      window.removeEventListener('orientationchange', setViewportHeight)
      telegram?.offEvent?.('viewportChanged', setViewportHeight)
    }
  }, [])

  const loadData = useCallback(async () => {
    try {
      const [catalog, categories, availableLevels, activity, currentKyc, publishedBroadcasts, areas] = await Promise.all([
        getCatalog(),
        getCatalogCategories(),
        getLevels(),
        getProfileActivity(user.id),
        getKycStatus(),
        getBroadcasts(),
        getServiceAreas(),
      ])
      setProducts(catalog)
      setCatalogCategories(categories)
      setLevels(availableLevels)
      setOrders(activity.orders)
      setLedger(activity.ledger)
      setRewards(activity.rewards)
      setFeedback(activity.feedback)
      setServiceAreas(areas)
      setKycStatus(currentKyc)
      setBroadcasts(publishedBroadcasts)
      setError('')
    } catch (caught) {
      setError(italianErrorMessage(caught, 'Errore nel caricamento dati.'))
    } finally {
      setLoading(false)
    }
  }, [user.id])

  const refreshAccount = async () => {
    await auth.refreshProfile()
    await loadData()
  }

  useEffect(() => { loadData() }, [loadData])

  const page: Page = location.pathname === '/catalog'
    ? 'catalog'
    : location.pathname === '/games'
      ? 'games'
    : location.pathname === '/profile'
        ? 'profile'
        : location.pathname === '/info'
          ? 'info'
        : location.pathname === '/contacts'
          ? 'contacts'
        : 'home'
  const navigate = (destination: Page) => {
    navigateRouter(PAGE_PATHS[destination])
    window.scrollTo({ top: 0, behavior: 'smooth' })
  }
  const addToCart = (item: Omit<CartItem, 'id'>) => {
    setCart(previous => {
      if (previous.some(current => current.productId === item.productId && current.unitAmount === item.unitAmount)) return previous
      return [...previous, { ...item, id: `${item.productId}-${item.unitAmount}-${Date.now()}` }]
    })
    setCartOpen(true)
  }
  return (
    <div className="sf-app-shell" style={{ background: '#080C0E', color: '#F5F5F5', fontFamily: 'Inter, sans-serif' }}>
      <TopNav
        page={page}
        navigate={navigate}
        cartCount={cart.length}
        onCartOpen={() => setCartOpen(true)}
        tokens={user.tokens}
        isAdmin={user.role === 'admin'}
        onAdmin={() => navigateRouter('/admin')}
        onLogout={auth.logout}
        broadcasts={broadcasts}
        onBroadcastProduct={(id) => { setSelectedProductId(id); navigate('catalog') }}
      />

      {error && <div className="fixed z-50 left-4 right-4 rounded-xl p-3" style={{ top: 100, background: '#35161e', color: '#FCA5A5' }}>{error}</div>}
      {loading ? (
        <div className="flex justify-center" style={{ paddingTop: 140 }}>Caricamento dati...</div>
      ) : (
        <main className="sf-mobile-nav-space" style={{ paddingTop: 28 }}>
          <Routes>
            <Route path="/" element={<HomePage navigate={navigate} products={products} levels={levels} addToCart={addToCart} user={user} onProductSelect={(id) => { setSelectedProductId(id); navigate('catalog') }} />} />
            <Route path="/catalog" element={<CatalogPage products={products} categories={catalogCategories} feedback={feedback} addToCart={addToCart} selectedProductId={selectedProductId} onProductSelect={setSelectedProductId} />} />
            <Route path="/games" element={<GamesPage user={user} onPlay={playGame} onComplete={refreshAccount} />} />
            <Route path="/profile" element={<ProfilePage user={user} levels={levels} orders={orders} ledger={ledger} rewards={rewards} onChanged={refreshAccount} onAdmin={() => navigateRouter('/admin')} />} />
            <Route path="/info" element={<InfoPage />} />
            <Route path="/contacts" element={<ContactsPage />} />
            <Route path="/admin" element={<RequireAdmin><AdminPage /></RequireAdmin>} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </main>
      )}
      {location.pathname !== '/admin' && !cartOpen && !selectedProductId && (
        <BottomNav page={page} navigate={navigate} cartCount={cart.length} onCartOpen={() => setCartOpen(true)} />
      )}
      <CartDrawer
        open={cartOpen}
        onClose={() => setCartOpen(false)}
        cart={cart}
        removeFromCart={id => setCart(previous => previous.filter(item => item.id !== id))}
        tokens={user.tokens}
        serviceAreas={serviceAreas}
        firstOrder={orders.length === 0}
        isAdmin={user.role === 'admin'}
        kycStatus={kycStatus}
        onKycChanged={refreshAccount}
        onSubmit={(selection) => submitTestOrder(cart, selection)}
        onComplete={async () => { setCart([]); await refreshAccount() }}
      />
    </div>
  )
}
