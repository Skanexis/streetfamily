import { adminClient, corsHeaders, json, sha256 } from '../_shared/clients.ts'

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const bytes = crypto.getRandomValues(new Uint8Array(24))
  const token = btoa(String.fromCharCode(...bytes)).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '')
  const hash = await sha256(token)
  const db = adminClient()
  const { error } = await db.from('telegram_login_challenges').insert({ token_hash: hash })
  if (error) return json({ error: error.message }, 500)
  const botUsername = Deno.env.get('TELEGRAM_BOT_USERNAME')
  if (!botUsername) return json({ error: 'TELEGRAM_BOT_USERNAME missing' }, 500)
  return json({
    token,
    expiresInSeconds: 600,
    botUrl: `https://t.me/${botUsername}?start=login_${token}`,
  })
})
