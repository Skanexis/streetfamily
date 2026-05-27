import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { getAccessProfile, getAccountBlocked } from '../lib/api'
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
  beginTelegramBotLogin: () => Promise<{ token: string; botUrl: string }>
  checkTelegramBotLogin: (token: string) => Promise<'pending' | 'confirmed' | 'denied' | 'expired'>
  loginFromTelegramMiniApp: (initData: string) => Promise<void>
  logout: () => Promise<void>
  refreshProfile: () => Promise<void>
}

const AuthContext = createContext<AuthValue | undefined>(undefined)

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
  const [loading, setLoading] = useState(isSupabaseConfigured)

  const refreshProfile = async () => {
    if (!supabase) return
    const accountBlocked = await getAccountBlocked()
    if (accountBlocked) {
      setProfile(null)
      setBlocked(true)
      setDenied(false)
      return
    }
    const current = await getAccessProfile()
    setProfile(current)
    setBlocked(false)
    setDenied(!current)
  }

  useEffect(() => {
    if (!supabase) return
    supabase.auth.getSession().then(async ({ data }) => {
      setSession(data.session)
      if (data.session) await refreshProfile()
      setLoading(false)
    }).catch(() => setLoading(false))
    const { data: listener } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      setSession(nextSession)
      if (!nextSession) {
        setProfile(null)
        setDenied(false)
        setBlocked(false)
        setLoading(false)
        return
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
        const verified = await db.auth.verifyOtp({ token_hash: data.tokenHash, type: 'magiclink' })
        if (verified.error) throw new Error(italianErrorMessage(verified.error.message, 'Accesso Telegram non riuscito.'))
      }
      return data.state
    },
    loginFromTelegramMiniApp: async (initData: string) => {
      const db = requireSupabase()
      const { data, error } = await db.functions.invoke('telegram-miniapp-auth', { body: { initData } })
      if (error) {
        const message = await edgeFunctionError(error, 'Accesso alla mini applicazione non riuscito.')
        if (message === 'Il tuo account è bloccato.') {
          setBlocked(true)
          return
        }
        throw new Error(message)
      }
      const verified = await db.auth.verifyOtp({ token_hash: data.tokenHash, type: 'magiclink' })
      if (verified.error) throw new Error(italianErrorMessage(verified.error.message, 'Accesso Telegram non riuscito.'))
    },
    logout: async () => {
      const db = requireSupabase()
      await db.auth.signOut()
    },
    refreshProfile,
  }), [loading, session, profile, denied, blocked])

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth() {
  const value = useContext(AuthContext)
  if (!value) throw new Error('useAuth deve essere utilizzato in AuthProvider.')
  return value
}
