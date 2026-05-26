import { useCallback, useEffect, useState } from 'react'
import { Navigate, Route, Routes, useLocation, useNavigate } from 'react-router-dom'
import type { Broadcast, CartItem, DemoInfo, Feedback, KycStatus, LedgerEntry, Level, Page, Product, ServiceArea, TestOrder, UserReward } from './data'
import { TopNav } from './components/TopNav'
import { BottomNav } from './components/BottomNav'
import { HomePage } from './components/HomePage'
import { CatalogPage } from './components/CatalogPage'
import { GamesPage } from './components/GamesPage'
import { ProfilePage } from './components/ProfilePage'
import { InfoPage } from './components/InfoPage'
import { CartDrawer } from './components/CartDrawer'
import { AdminPage } from './components/AdminPage'
import { AccessDeniedPage, CallbackPage, LoginPage, RequireAdmin, RequireMember } from './components/AuthPages'
import { StagingBanner } from './components/StagingBanner'
import { useAuth } from './auth/AuthProvider'
import { getBroadcasts, getCatalog, getDemoInfo, getKycStatus, getLevels, getProfileActivity, getServiceAreas, playWheel, submitTestOrder } from './lib/api'
import '../styles/fonts.css'

const PAGE_PATHS: Record<Page, string> = { home: '/', catalog: '/catalog', games: '/games', profile: '/profile', info: '/info' }

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route path="/auth/callback" element={<CallbackPage />} />
      <Route path="/access-denied" element={<AccessDeniedPage />} />
      <Route path="/*" element={<RequireMember><MemberApplication /></RequireMember>} />
    </Routes>
  )
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
  const [levels, setLevels] = useState<Level[]>([])
  const [broadcasts, setBroadcasts] = useState<Broadcast[]>([])
  const [orders, setOrders] = useState<TestOrder[]>([])
  const [ledger, setLedger] = useState<LedgerEntry[]>([])
  const [rewards, setRewards] = useState<UserReward[]>([])
  const [feedback, setFeedback] = useState<Feedback[]>([])
  const [serviceAreas, setServiceAreas] = useState<ServiceArea[]>([])
  const [demoInfo, setDemoInfo] = useState<DemoInfo>({ disclaimer: 'Ambiente demo: nessun pagamento, scambio o fulfillment reale.', instagram: '', viber: '', signal: null })
  const [kycStatus, setKycStatus] = useState<KycStatus>({ status: 'not_started', documents: [], submittedAt: null, rejectionReason: null })
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const loadData = useCallback(async () => {
    try {
      const [catalog, availableLevels, activity, currentKyc, publishedBroadcasts, areas, info] = await Promise.all([
        getCatalog(),
        getLevels(),
        getProfileActivity(),
        getKycStatus(),
        getBroadcasts(),
        getServiceAreas(),
        getDemoInfo(),
      ])
      setProducts(catalog)
      setLevels(availableLevels)
      setOrders(activity.orders)
      setLedger(activity.ledger)
      setRewards(activity.rewards)
      setFeedback(activity.feedback)
      setServiceAreas(areas)
      setDemoInfo(info)
      setKycStatus(currentKyc)
      setBroadcasts(publishedBroadcasts)
      setError('')
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Errore nel caricamento staging.')
    } finally {
      setLoading(false)
    }
  }, [])

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
        : 'home'
  const navigate = (destination: Page) => {
    navigateRouter(PAGE_PATHS[destination])
    window.scrollTo({ top: 0, behavior: 'smooth' })
  }
  const addToCart = (item: Omit<CartItem, 'id'>) => {
    setCart(previous => {
      if (previous.some(current => current.variantId === item.variantId)) return previous
      return [...previous, { ...item, id: `${item.variantId}-${Date.now()}` }]
    })
    setCartOpen(true)
  }
  return (
    <div style={{ minHeight: '100vh', background: '#080C0E', color: '#F5F5F5', fontFamily: 'Inter, sans-serif' }}>
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
      <StagingBanner />
      {error && <div className="fixed z-50 left-4 right-4 rounded-xl p-3" style={{ top: 100, background: '#35161e', color: '#FCA5A5' }}>{error}</div>}
      {loading ? (
        <div className="flex justify-center" style={{ paddingTop: 140 }}>Caricamento dati test...</div>
      ) : (
        <main className="pb-20 md:pb-0" style={{ paddingTop: 28 }}>
          <Routes>
            <Route path="/" element={<HomePage navigate={navigate} products={products} levels={levels} addToCart={addToCart} user={user} onProductSelect={(id) => { setSelectedProductId(id); navigate('catalog') }} />} />
            <Route path="/catalog" element={<CatalogPage products={products} feedback={feedback} addToCart={addToCart} selectedProductId={selectedProductId} onProductSelect={setSelectedProductId} />} />
            <Route path="/games" element={<GamesPage user={user} onSpin={playWheel} onComplete={refreshAccount} />} />
            <Route path="/profile" element={<ProfilePage user={user} levels={levels} orders={orders} ledger={ledger} rewards={rewards} onChanged={refreshAccount} onAdmin={() => navigateRouter('/admin')} />} />
            <Route path="/info" element={<InfoPage info={demoInfo} />} />
            <Route path="/admin" element={<RequireAdmin><AdminPage /></RequireAdmin>} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </main>
      )}
      {location.pathname !== '/admin' && (
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
        kycStatus={kycStatus}
        onKycChanged={loadData}
        onSubmit={(selection) => submitTestOrder(cart, selection)}
        onComplete={async () => { setCart([]); await refreshAccount() }}
      />
    </div>
  )
}
