import { adminClient, corsHeaders, json, sha256 } from '../_shared/clients.ts'

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Metodo non consentito' }, 405)
  const { token } = await req.json()
  if (!token || typeof token !== 'string') return json({ error: 'Codice non valido' }, 400)
  const db = adminClient()
  const { data, error } = await db.from('telegram_login_challenges')
    .select('id,state,auth_token_hash,expires_at')
    .eq('token_hash', await sha256(token))
    .maybeSingle()
  if (error || !data) return json({ error: 'Richiesta di accesso non trovata' }, 404)
  if (new Date(data.expires_at) < new Date() && data.state === 'pending') {
    await db.from('telegram_login_challenges').update({ state: 'expired' }).eq('id', data.id)
    return json({ state: 'expired' })
  }
  return json({ state: data.state, tokenHash: data.state === 'confirmed' ? data.auth_token_hash : undefined })
})
