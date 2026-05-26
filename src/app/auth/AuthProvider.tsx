import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { getAccessProfile } from '../lib/api'
import { isSupabaseConfigured, requireSupabase, supabase } from '../lib/supabase'
import type { Profile } from '../data'

interface AuthValue {
  configured: boolean
  loading: boolean
  session: Session | null
  profile: Profile | null
  denied: boolean
  isAdminMfa: boolean
  beginTelegramBotLogin: () => Promise<{ token: string; botUrl: string }>
  checkTelegramBotLogin: (token: string) => Promise<'pending' | 'confirmed' | 'denied' | 'expired'>
  logout: () => Promise<void>
  refreshProfile: () => Promise<void>
}

const AuthContext = createContext<AuthValue | undefined>(undefined)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [denied, setDenied] = useState(false)
  const [isAdminMfa, setIsAdminMfa] = useState(false)
  const [loading, setLoading] = useState(isSupabaseConfigured)

  const refreshProfile = async () => {
    if (!supabase) return
    const current = await getAccessProfile()
    setProfile(current)
    setDenied(!current)
    const { data } = await requireSupabase().auth.mfa.getAuthenticatorAssuranceLevel()
    setIsAdminMfa(data?.currentLevel === 'aal2')
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
        setLoading(false)
        return
      }
      window.setTimeout(() => {
        refreshProfile().finally(() => setLoading(false))
      }, 0)
    })
    return () => listener.subscription.unsubscribe()
  }, [])

  const value = useMemo<AuthValue>(() => ({
    configured: isSupabaseConfigured,
    loading,
    session,
    profile,
    denied,
    isAdminMfa,
    beginTelegramBotLogin: async () => {
      const db = requireSupabase()
      const { data, error } = await db.functions.invoke('telegram-auth-start', { body: {} })
      if (error) throw new Error(error.message)
      return data as { token: string; botUrl: string }
    },
    checkTelegramBotLogin: async (token: string) => {
      const db = requireSupabase()
      const { data, error } = await db.functions.invoke('telegram-auth-status', { body: { token } })
      if (error) throw new Error(error.message)
      if (data.state === 'confirmed') {
        const verified = await db.auth.verifyOtp({ token_hash: data.tokenHash, type: 'magiclink' })
        if (verified.error) throw new Error(verified.error.message)
      }
      return data.state
    },
    logout: async () => {
      const db = requireSupabase()
      await db.auth.signOut()
    },
    refreshProfile,
  }), [loading, session, profile, denied, isAdminMfa])

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth() {
  const value = useContext(AuthContext)
  if (!value) throw new Error('useAuth deve essere utilizzato in AuthProvider.')
  return value
}
