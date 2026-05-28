import { adminClient, corsHeaders, envAdminIds, json, publicErrorMessage } from '../_shared/clients.ts'
import { ensureAccessRequest } from '../_shared/access-requests.ts'

type TelegramUser = {
  id: number
  username?: string
  first_name?: string
  photo_url?: string
}

async function hmac(key: Uint8Array<ArrayBuffer>, value: string) {
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
  if (!botToken) throw new Error('Token del bot Telegram non configurato')
  const parameters = new URLSearchParams(initData)
  const receivedHash = parameters.get('hash')
  const userValue = parameters.get('user')
  const authDate = Number(parameters.get('auth_date'))
  if (!receivedHash || !userValue || !Number.isFinite(authDate)) throw new Error('Dati Telegram non validi')
  parameters.delete('hash')
  const checkString = Array.from(parameters.entries())
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, value]) => `${key}=${value}`)
    .join('\n')
  const secret = await hmac(new TextEncoder().encode('WebAppData'), botToken)
  const expectedHash = toHex(await hmac(secret, checkString))
  if (!constantTimeEqual(receivedHash.toLowerCase(), expectedHash)) throw new Error('Dati Telegram non validi')
  const configuredMaxAge = Number(Deno.env.get('TELEGRAM_INIT_DATA_MAX_AGE_SECONDS') ?? 600)
  const maxAge = Number.isFinite(configuredMaxAge) && configuredMaxAge > 0 ? configuredMaxAge : 600
  const age = Math.floor(Date.now() / 1000) - authDate
  if (age < -30 || age > maxAge) throw new Error('Autorizzazione Telegram scaduta')
  const user = JSON.parse(userValue) as TelegramUser
  if (!Number.isSafeInteger(user.id) || user.id <= 0) throw new Error('Dati Telegram non validi')
  return user
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Metodo non consentito' }, 405)
  try {
    const { initData } = await req.json()
    if (typeof initData !== 'string' || !initData) return json({ error: 'Dati di autorizzazione Telegram mancanti' }, 400)
    const telegramUser = await validateInitData(initData)
    const telegramId = String(telegramUser.id)
    const isAdmin = envAdminIds().has(telegramId)
    if (!isAdmin && !telegramUser.username?.trim()) return json({ error: 'Username Telegram richiesto.' }, 403)
    const db = adminClient()
    const access = await ensureAccessRequest(
      db,
      telegramId,
      telegramUser.username ?? telegramUser.first_name ?? 'membro',
      isAdmin,
    )
    if (access.status === 'rejected' && !isAdmin) return json({ error: 'Account bloccato.' }, 403)
    const email = `telegram_${telegramId}@street-family.invalid`
    const metadata = {
      telegram_id: telegramId,
      username: telegramUser.username ?? telegramUser.first_name ?? 'membro',
      first_name: telegramUser.first_name,
      avatar_url: telegramUser.photo_url,
    }
    const { data: profile, error: profileError } = await db.from('profiles').select('id,blocked').eq('telegram_subject', telegramId).maybeSingle()
    if (profileError) return json({ error: publicErrorMessage(profileError.message, 'Accesso Telegram non riuscito.') }, 500)
    if (profile?.blocked && !isAdmin) return json({ error: 'Account bloccato.' }, 403)
    if (!profile) {
      const created = await db.auth.admin.createUser({ email, email_confirm: true, user_metadata: metadata })
      if (created.error && !/already registered|already exists/i.test(created.error.message)) {
        return json({ error: publicErrorMessage(created.error.message, 'Creazione account non riuscita.') }, 500)
      }
    }
    const generated = await db.auth.admin.generateLink({ type: 'magiclink', email, options: { data: metadata } })
    if (generated.error) return json({ error: publicErrorMessage(generated.error.message, 'Accesso Telegram non riuscito.') }, 500)
    if (!profile) {
      const userId = generated.data.user?.id
      if (!userId) return json({ error: 'Creazione account non riuscita.' }, 500)
      const { error: repairProfileError } = await db.from('profiles').upsert({
        id: userId,
        telegram_subject: telegramId,
        username: metadata.username,
        avatar_url: metadata.avatar_url,
        role: isAdmin ? 'admin' : 'user',
      }, { onConflict: 'id' })
      if (repairProfileError) {
        return json({ error: publicErrorMessage(repairProfileError.message, 'Creazione account non riuscita.') }, 500)
      }
      const { error: walletError } = await db.from('wallet_balances').upsert({
        user_id: userId,
        points: 0,
      }, { onConflict: 'user_id', ignoreDuplicates: true })
      if (walletError) return json({ error: publicErrorMessage(walletError.message, 'Creazione account non riuscita.') }, 500)
    } else {
      const { error: updateProfileError } = await db.from('profiles').update({
        username: metadata.username,
        avatar_url: metadata.avatar_url,
        role: isAdmin ? 'admin' : 'user',
      }).eq('id', profile.id)
      if (updateProfileError) return json({ error: publicErrorMessage(updateProfileError.message, 'Accesso Telegram non riuscito.') }, 500)
    }
    return json({ tokenHash: generated.data.properties.hashed_token, isAdmin })
  } catch (caught) {
    return json({ error: publicErrorMessage(caught, 'Autorizzazione Telegram non riuscita.') }, 401)
  }
})
