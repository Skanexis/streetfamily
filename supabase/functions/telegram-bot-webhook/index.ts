import { adminClient, envAdminIds, json, sendTelegramMessage, sha256 } from '../_shared/clients.ts'

interface TelegramUpdate {
  message?: {
    chat: { id: number }
    from?: { id: number; username?: string; first_name?: string }
    text?: string
  }
}

Deno.serve(async req => {
  const webhookSecret = Deno.env.get('TELEGRAM_WEBHOOK_SECRET')
  if (!webhookSecret || req.headers.get('X-Telegram-Bot-Api-Secret-Token') !== webhookSecret) {
    return json({ error: 'Unauthorized' }, 401)
  }
  const update: TelegramUpdate = await req.json()
  const message = update.message
  const match = message?.text?.match(/^\/start\s+login_([A-Za-z0-9_-]+)$/)
  if (!message || !message.from || !match) return json({ ok: true })
  const telegramId = String(message.from.id)
  const tokenHash = await sha256(match[1])
  const db = adminClient()
  const { data: challenge } = await db.from('telegram_login_challenges')
    .select('id,state,expires_at')
    .eq('token_hash', tokenHash)
    .eq('state', 'pending')
    .maybeSingle()
  if (!challenge || new Date(challenge.expires_at) < new Date()) {
    await sendTelegramMessage(String(message.chat.id), 'Link di accesso non valido o scaduto.')
    return json({ ok: true })
  }

  const isAdmin = envAdminIds().has(telegramId)
  if (isAdmin) {
    await db.from('staging_allowlist').upsert({ telegram_subject: telegramId, role: 'admin', enabled: true, note: 'TELEGRAM_ADMIN_IDS' })
  }
  const { data: allowed } = await db.from('staging_allowlist').select('role,enabled').eq('telegram_subject', telegramId).eq('enabled', true).maybeSingle()
  if (!allowed) {
    await db.from('telegram_login_challenges').update({ state: 'denied', telegram_id: telegramId }).eq('id', challenge.id)
    await sendTelegramMessage(String(message.chat.id), 'Il tuo account non e autorizzato allo staging.')
    return json({ ok: true })
  }

  const email = `telegram_${telegramId}@street-family.invalid`
  const metadata = { telegram_id: telegramId, username: message.from.username ?? message.from.first_name ?? 'member', first_name: message.from.first_name }
  const { data: profile } = await db.from('profiles').select('id').eq('telegram_subject', telegramId).maybeSingle()
  if (!profile) {
    const created = await db.auth.admin.createUser({ email, email_confirm: true, user_metadata: metadata })
    if (created.error) return json({ error: created.error.message }, 500)
  }
  const generated = await db.auth.admin.generateLink({ type: 'magiclink', email, options: { data: metadata } })
  if (generated.error) return json({ error: generated.error.message }, 500)
  const authTokenHash = generated.data.properties.hashed_token
  await db.from('telegram_login_challenges').update({
    telegram_id: telegramId,
    state: 'confirmed',
    auth_token_hash: authTokenHash,
    confirmed_at: new Date().toISOString(),
  }).eq('id', challenge.id)
  await sendTelegramMessage(String(message.chat.id), isAdmin ? 'Accesso admin confermato. Torna al sito per aprire la dashboard.' : 'Accesso confermato. Torna al sito.')
  return json({ ok: true })
})
