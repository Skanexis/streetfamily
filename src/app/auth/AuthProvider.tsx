import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { getAccessProfile, getAccountAccessState, type AccountAccessStatus } from '../lib/api'
import { isSupabaseConfigured, requireSupabase, supabase } from '../lib/supabase'
import { italianErrorMessage } from '../lib/errors'
import type { Profile } from '../data'

interface AuthValue {
  configured: boolean
  loading: boolean
  session: Session | null
  profile: Profile | null
  denied: boolean
  blocked: boolean
  accessStatus: AccountAccessStatus
  beginTelegramBotLogin: () => Promise<{ token: string; botUrl: string }>
  checkTelegramBotLogin: (token: string) => Promise<'pending' | 'confirmed' | 'denied' | 'expired'>
  loginFromTelegramMiniApp: (initData: string) => Promise<void>
  logout: () => Promise<void>
  refreshProfile: () => Promise<void>
}

const AuthContext = createContext<AuthValue | undefined>(undefined)

function telegramMiniAppInitData() {
  return (window as Window & { Telegram?: { WebApp?: { initData?: string } } }).Telegram?.WebApp?.initData ?? ''
}

async function edgeFunctionError(error: unknown, fallback: string) {
  const functionError = error as { message?: string; context?: Response }
  try {
    if (functionError.context) {
      const body = await functionError.context.clone().json() as { error?: string }
      if (body.error) return italianErrorMessage(body.error, fallback)
    }
  } catch {
    // Keep the client fallback when the failed response is not JSON.
  }
  return italianErrorMessage(functionError.message, fallback)
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [denied, setDenied] = useState(false)
  const [blocked, setBlocked] = useState(false)
  const [accessStatus, setAccessStatus] = useState<AccountAccessStatus>('pending')
  const [loading, setLoading] = useState(isSupabaseConfigured)

  const refreshProfile = async () => {
    if (!supabase) return
    const { data: initialAuth } = await supabase.auth.getSession()
    const expectedUserId = initialAuth.session?.user.id
    if (!expectedUserId) {
      setProfile(null)
      return
    }
    const accessState = await getAccountAccessState()
    const { data: currentAuth } = await supabase.auth.getSession()
    if (currentAuth.session?.user.id !== expectedUserId) return
    setAccessStatus(accessState.accessStatus)
    if (accessState.blocked || accessState.accessStatus === 'rejected') {
      setProfile(null)
      setBlocked(true)
      setDenied(false)
      return
    }
    if (accessState.accessStatus === 'pending') {
      setProfile(null)
      setBlocked(false)
      setDenied(false)
      return
    }
    const current = await getAccessProfile()
    const { data: finalAuth } = await supabase.auth.getSession()
    if (finalAuth.session?.user.id !== expectedUserId || (current && current.id !== expectedUserId)) return
    setProfile(current)
    setBlocked(false)
    setDenied(!current)
  }

  const exchangeTelegramMiniAppSession = async (initData: string) => {
    const db = requireSupabase()
    setLoading(true)
    setProfile(null)
    setDenied(false)
    setBlocked(false)
    setAccessStatus('pending')
    const { data, error } = await db.functions.invoke('telegram-miniapp-auth', { body: { initData } })
    if (error) {
      const message = await edgeFunctionError(error, 'Accesso alla mini applicazione non riuscito.')
      if (message === 'Il tuo account è bloccato.') {
        await db.auth.signOut()
        setSession(null)
        setProfile(null)
        setDenied(false)
        setBlocked(true)
        setAccessStatus('rejected')
        setLoading(false)
        return
      }
      setLoading(false)
      throw new Error(message)
    }
    const verified = await db.auth.verifyOtp({ token_hash: data.tokenHash, type: 'magiclink' })
    if (verified.error) {
      setLoading(false)
      throw new Error(italianErrorMessage(verified.error.message, 'Accesso Telegram non riuscito.'))
    }
    setSession(verified.data.session)
    await refreshProfile()
    setLoading(false)
  }

  useEffect(() => {
    if (!supabase) return
    const db = supabase
    db.auth.getSession().then(async ({ data }) => {
      const initData = telegramMiniAppInitData()
      if (initData) {
        try {
          await exchangeTelegramMiniAppSession(initData)
        } catch {
          await db.auth.signOut()
        } finally {
          setLoading(false)
        }
        return
      }
      setSession(data.session)
      if (data.session) await refreshProfile()
      setLoading(false)
    }).catch(() => setLoading(false))
    const { data: listener } = db.auth.onAuthStateChange((event, nextSession) => {
      setSession(nextSession)
      if (!nextSession) {
        setProfile(null)
        setDenied(false)
        setBlocked(false)
        setAccessStatus('pending')
        setLoading(false)
        return
      }
      if (event === 'SIGNED_IN' || event === 'USER_UPDATED') {
        setProfile(null)
        setDenied(false)
        setBlocked(false)
        setAccessStatus('pending')
        setLoading(true)
      }
      window.setTimeout(() => {
        refreshProfile().finally(() => setLoading(false))
      }, 0)
    })
    return () => listener.subscription.unsubscribe()
  }, [])

  useEffect(() => {
    if (!session) return
    const checkAccess = () => { void refreshProfile().catch(() => undefined) }
    const timer = window.setInterval(checkAccess, 30000)
    window.addEventListener('focus', checkAccess)
    return () => {
      window.clearInterval(timer)
      window.removeEventListener('focus', checkAccess)
    }
  }, [session])

  const value = useMemo<AuthValue>(() => ({
    configured: isSupabaseConfigured,
    loading,
    session,
    profile,
    denied,
    blocked,
    accessStatus,
    beginTelegramBotLogin: async () => {
      const db = requireSupabase()
      const { data, error } = await db.functions.invoke('telegram-auth-start', { body: {} })
      if (error) throw new Error(await edgeFunctionError(error, 'Impossibile avviare Telegram.'))
      return data as { token: string; botUrl: string }
    },
    checkTelegramBotLogin: async (token: string) => {
      const db = requireSupabase()
      const { data, error } = await db.functions.invoke('telegram-auth-status', { body: { token } })
      if (error) throw new Error(await edgeFunctionError(error, 'Impossibile verificare Telegram.'))
      if (data.state === 'confirmed') {
        setLoading(true)
        setProfile(null)
        setDenied(false)
        setBlocked(false)
        setAccessStatus('pending')
        const verified = await db.auth.verifyOtp({ token_hash: data.tokenHash, type: 'magiclink' })
        if (verified.error) {
          setLoading(false)
          throw new Error(italianErrorMessage(verified.error.message, 'Accesso Telegram non riuscito.'))
        }
      }
      return data.state
    },
    loginFromTelegramMiniApp: async (initData: string) => {
      await exchangeTelegramMiniAppSession(initData)
    },
    logout: async () => {
      const db = requireSupabase()
      await db.auth.signOut()
    },
    refreshProfile,
  }), [loading, session, profile, denied, blocked, accessStatus])

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth() {
  const value = useContext(AuthContext)
  if (!value) throw new Error('useAuth deve essere utilizzato in AuthProvider.')
  return value
}
