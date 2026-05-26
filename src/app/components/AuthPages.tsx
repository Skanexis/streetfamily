import { Navigate } from 'react-router-dom'
import { ShieldAlert, Send } from 'lucide-react'
import { useEffect, useState } from 'react'
import type { ReactElement, ReactNode } from 'react'
import { useAuth } from '../auth/AuthProvider'

const card = {
  maxWidth: 460,
  margin: '0 auto',
  background: '#11181B',
  border: '1px solid rgba(126,156,168,.25)',
  borderRadius: 20,
  padding: 32,
}

export function LoginPage() {
  const auth = useAuth()
  const [challenge, setChallenge] = useState<{ token: string; botUrl: string } | null>(null)
  const [preparedChallenge, setPreparedChallenge] = useState<{ token: string; botUrl: string } | null>(null)
  const [preparingBotLink, setPreparingBotLink] = useState(false)
  const [botLinkAttempted, setBotLinkAttempted] = useState(false)
  const [miniAppData, setMiniAppData] = useState('')
  const [miniAppAttempted, setMiniAppAttempted] = useState(false)
  const [error, setError] = useState('')
  const prepareBotLogin = async () => {
    setBotLinkAttempted(true)
    setPreparingBotLink(true)
    setError('')
    try {
      const created = await auth.beginTelegramBotLogin()
      setPreparedChallenge(created)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Impossibile avviare Telegram.')
    } finally {
      setPreparingBotLink(false)
    }
  }
  const loginMiniApp = async (initData: string) => {
    setError('')
    try {
      await auth.loginFromTelegramMiniApp(initData)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Accesso Mini App non riuscito.')
    }
  }
  useEffect(() => {
    const telegram = (window as Window & {
      Telegram?: { WebApp?: { initData?: string; ready?: () => void; expand?: () => void } }
    }).Telegram?.WebApp
    if (miniAppAttempted || auth.session || !telegram?.initData) return
    setMiniAppData(telegram.initData)
    setMiniAppAttempted(true)
    telegram.ready?.()
    telegram.expand?.()
    loginMiniApp(telegram.initData)
  }, [auth, miniAppAttempted])
  useEffect(() => {
    if (!auth.configured || miniAppData || challenge || preparedChallenge || preparingBotLink || botLinkAttempted) return
    void prepareBotLogin()
  }, [auth.configured, botLinkAttempted, challenge, miniAppData, preparedChallenge, preparingBotLink])
  useEffect(() => {
    if (!challenge) return
    const timer = window.setInterval(async () => {
      try {
        const state = await auth.checkTelegramBotLogin(challenge.token)
        if (state === 'confirmed') {
          window.clearInterval(timer)
          setChallenge(null)
        }
        if (state === 'denied' || state === 'expired') {
          window.clearInterval(timer)
          setError(state === 'denied' ? 'Account non autorizzato allo staging.' : 'Richiesta scaduta. Riprova.')
          setChallenge(null)
        }
      } catch (caught) {
        window.clearInterval(timer)
        setError(caught instanceof Error ? caught.message : 'Accesso non riuscito.')
      }
    }, 1800)
    return () => window.clearInterval(timer)
  }, [challenge])
  if (auth.profile) return <Navigate to="/" replace />
  return (
    <Centered>
      <div style={card}>
        <div style={{ fontFamily: 'Orbitron', fontWeight: 900, fontSize: 25, marginBottom: 8 }}>STREET FAMILY</div>
        <div style={{ color: '#D7FE55', fontFamily: 'Orbitron', fontSize: 11, marginBottom: 24 }}>CLOSED TEST MODE</div>
        <p style={{ color: 'rgba(245,245,245,.65)', marginBottom: 24 }}>{miniAppAttempted ? 'Autorizzazione Telegram Mini App in corso...' : 'Apri il bot Telegram e premi Start per confermare il tuo account. Ambiente staging senza pagamento o fulfillment.'}</p>
        {!auth.configured ? (
          <p style={{ color: '#F59E0B' }}>Configura `VITE_SUPABASE_URL` e `VITE_SUPABASE_PUBLISHABLE_KEY` per abilitare l'accesso.</p>
        ) : miniAppData ? (
          error && <button onClick={() => loginMiniApp(miniAppData)} style={primaryButton}><Send size={17} /> Riprova accesso Mini App</button>
        ) : (
          challenge
            ? <button disabled style={{ ...primaryButton, opacity: .65 }}><Send size={17} /> In attesa del bot...</button>
            : preparedChallenge
              ? <a href={preparedChallenge.botUrl} target="_blank" rel="noopener noreferrer" onClick={() => { setError(''); setChallenge(preparedChallenge); setPreparedChallenge(null) }} style={{ ...primaryButton, textDecoration: 'none' }}><Send size={17} /> Apri il bot Telegram</a>
              : <button onClick={() => void prepareBotLogin()} disabled={preparingBotLink} style={{ ...primaryButton, opacity: preparingBotLink ? .65 : 1 }}><Send size={17} /> {preparingBotLink ? 'Preparazione...' : 'Riprova'}</button>
        )}
        {challenge && <p style={{ color: '#D7FE55', marginTop: 16 }}>Conferma nel bot, poi questa pagina accedera automaticamente.</p>}
        {error && <p style={{ color: '#F87171', marginTop: 16 }}>{error}</p>}
      </div>
    </Centered>
  )
}

export function CallbackPage() {
  const auth = useAuth()
  if (auth.loading) return <Centered>Verifica accesso staging...</Centered>
  if (auth.denied) return <Navigate to="/access-denied" replace />
  if (auth.profile) return <Navigate to="/" replace />
  return <Navigate to="/login" replace />
}

export function AccessDeniedPage() {
  const { logout } = useAuth()
  return (
    <Centered>
      <div style={card}>
        <ShieldAlert size={36} style={{ color: '#F59E0B', marginBottom: 15 }} />
        <h1 style={{ fontFamily: 'Space Grotesk', fontWeight: 700 }}>Accesso non autorizzato</h1>
        <p style={{ color: 'rgba(245,245,245,.65)', margin: '12px 0 24px' }}>Il tuo account Telegram non e nella allowlist dello staging.</p>
        <button style={primaryButton} onClick={logout}>Esci</button>
      </div>
    </Centered>
  )
}

export function RequireMember({ children }: { children: ReactElement }) {
  const auth = useAuth()
  if (auth.loading) return <Centered>Caricamento...</Centered>
  if (!auth.session) return <Navigate to="/login" replace />
  if (!auth.profile) return <Navigate to="/access-denied" replace />
  return children
}

export function RequireAdmin({ children }: { children: ReactElement }) {
  const auth = useAuth()
  if (!auth.profile || auth.profile.role !== 'admin') return <Navigate to="/" replace />
  return children
}

function Centered({ children }: { children: ReactNode }) {
  return <div className="flex items-center justify-center px-5" style={{ minHeight: '100vh', background: '#080C0E', color: '#F5F5F5' }}>{children}</div>
}

const primaryButton = {
  display: 'inline-flex',
  alignItems: 'center',
  justifyContent: 'center',
  gap: 8,
  width: '100%',
  padding: '13px 18px',
  borderRadius: 12,
  border: 'none',
  background: 'linear-gradient(135deg, #7E9CA8, #B99361)',
  color: '#F5F5F5',
  fontFamily: 'Space Grotesk',
  fontWeight: 700,
}
