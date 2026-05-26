import { adminClient, corsHeaders, envAdminIds, json } from '../_shared/clients.ts'

type TelegramUser = {
  id: number
  username?: string
  first_name?: string
  photo_url?: string
}

async function hmac(key: Uint8Array, value: string) {
  const cryptoKey = await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  return new Uint8Array(await crypto.subtle.sign('HMAC', cryptoKey, new TextEncoder().encode(value)))
}

function toHex(bytes: Uint8Array) {
  return Array.from(bytes).map(byte => byte.toString(16).padStart(2, '0')).join('')
}

function constantTimeEqual(left: string, right: string) {
  if (left.length !== right.length) return false
  let result = 0
  for (let index = 0; index < left.length; index += 1) result |= left.charCodeAt(index) ^ right.charCodeAt(index)
  return result === 0
}

async function validateInitData(initData: string): Promise<TelegramUser> {
  const botToken = Deno.env.get('TELEGRAM_BOT_TOKEN')
  if (!botToken) throw new Error('TELEGRAM_BOT_TOKEN missing')
  const parameters = new URLSearchParams(initData)
  const receivedHash = parameters.get('hash')
  const userValue = parameters.get('user')
  const authDate = Number(parameters.get('auth_date'))
  if (!receivedHash || !userValue || !Number.isFinite(authDate)) throw new Error('TELEGRAM_INIT_DATA_INVALID')
  parameters.delete('hash')
  parameters.delete('signature')
  const checkString = Array.from(parameters.entries())
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, value]) => `${key}=${value}`)
    .join('\n')
  const secret = await hmac(new TextEncoder().encode('WebAppData'), botToken)
  const expectedHash = toHex(await hmac(secret, checkString))
  if (!constantTimeEqual(receivedHash.toLowerCase(), expectedHash)) throw new Error('TELEGRAM_INIT_DATA_INVALID')
  const configuredMaxAge = Number(Deno.env.get('TELEGRAM_INIT_DATA_MAX_AGE_SECONDS') ?? 600)
  const maxAge = Number.isFinite(configuredMaxAge) && configuredMaxAge > 0 ? configuredMaxAge : 600
  const age = Math.floor(Date.now() / 1000) - authDate
  if (age < -30 || age > maxAge) throw new Error('TELEGRAM_INIT_DATA_EXPIRED')
  const user = JSON.parse(userValue) as TelegramUser
  if (!Number.isSafeInteger(user.id) || user.id <= 0) throw new Error('TELEGRAM_INIT_DATA_INVALID')
  return user
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  try {
    const { initData } = await req.json()
    if (typeof initData !== 'string' || !initData) return json({ error: 'TELEGRAM_INIT_DATA_REQUIRED' }, 400)
    const telegramUser = await validateInitData(initData)
    const telegramId = String(telegramUser.id)
    const isAdmin = envAdminIds().has(telegramId)
    const db = adminClient()
    const { data: access } = await db.from('staging_allowlist')
      .select('enabled,role')
      .eq('telegram_subject', telegramId)
      .maybeSingle()
    if (access && !access.enabled && !isAdmin) return json({ error: 'Staging access denied' }, 403)
    if (isAdmin || !access) {
      const { error } = await db.from('staging_allowlist').upsert({
        telegram_subject: telegramId,
        role: isAdmin ? 'admin' : 'user',
        enabled: true,
        note: isAdmin ? 'TELEGRAM_ADMIN_IDS' : 'Telegram Mini App registration',
      })
      if (error) return json({ error: error.message }, 500)
    }
    const email = `telegram_${telegramId}@street-family.invalid`
    const metadata = {
      telegram_id: telegramId,
      username: telegramUser.username ?? telegramUser.first_name ?? 'member',
      first_name: telegramUser.first_name,
      avatar_url: telegramUser.photo_url,
    }
    const { data: profile } = await db.from('profiles').select('id').eq('telegram_subject', telegramId).maybeSingle()
    if (!profile) {
      const created = await db.auth.admin.createUser({ email, email_confirm: true, user_metadata: metadata })
      if (created.error) return json({ error: created.error.message }, 500)
    }
    const generated = await db.auth.admin.generateLink({ type: 'magiclink', email, options: { data: metadata } })
    if (generated.error) return json({ error: generated.error.message }, 500)
    return json({ tokenHash: generated.data.properties.hashed_token, isAdmin })
  } catch (caught) {
    return json({ error: caught instanceof Error ? caught.message : 'TELEGRAM_AUTH_FAILED' }, 401)
  }
})
