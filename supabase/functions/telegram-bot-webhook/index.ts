import { adminClient, answerTelegramCallbackQuery, editTelegramMessage, envAdminIds, json, publicErrorMessage, sendTelegramMessage, sendTelegramMessageWithOptions, setTelegramMiniAppMenu, sha256 } from '../_shared/clients.ts'

interface TelegramUpdate {
  message?: {
    chat: { id: number }
    from?: { id: number; username?: string; first_name?: string }
    text?: string
  }
  callback_query?: {
    id: string
    from: { id: number; username?: string; first_name?: string }
    data?: string
    message?: {
      chat: { id: number }
      message_id: number
      text?: string
    }
  }
}

Deno.serve(async req => {
  const webhookSecret = Deno.env.get('TELEGRAM_WEBHOOK_SECRET')
  if (!webhookSecret || req.headers.get('X-Telegram-Bot-Api-Secret-Token') !== webhookSecret) {
    return json({ error: 'Non autorizzato' }, 401)
  }
  const update: TelegramUpdate = await req.json()
  const callback = update.callback_query
  if (callback?.data) {
    const telegramId = String(callback.from.id)
    if (!envAdminIds().has(telegramId)) {
      await answerTelegramCallbackQuery(callback.id, 'Azione non autorizzata.')
      return json({ ok: true })
    }
    const match = callback.data.match(/^ord:([ar]):([0-9a-f-]{36})$/i)
    if (!match) {
      await answerTelegramCallbackQuery(callback.id, 'Azione non valida.')
      return json({ ok: true })
    }
    const db = adminClient()
    const { data: actor } = await db.from('profiles')
      .select('id')
      .eq('telegram_subject', telegramId)
      .eq('role', 'admin')
      .maybeSingle()
    if (!actor) {
      await answerTelegramCallbackQuery(callback.id, 'Apri prima la mini applicazione come amministratore.')
      return json({ ok: true })
    }
    const action = match[1] === 'a' ? 'accept' : 'reject'
    const result = await db.rpc('telegram_admin_order_action', {
      p_actor_id: actor.id,
      p_order_id: match[2],
      p_action: action,
    })
    if (result.error) {
      await answerTelegramCallbackQuery(callback.id, publicErrorMessage(result.error.message, 'Aggiornamento ordine non riuscito.'))
      return json({ ok: true })
    }
    const statusText = action === 'accept' ? 'ORDINE ACCETTATO' : 'ORDINE RIFIUTATO'
    if (callback.message) {
      const currentText = callback.message.text ?? 'Ordine Street Family'
      await editTelegramMessage(
        String(callback.message.chat.id),
        callback.message.message_id,
        `${currentText}\n\n${statusText}`,
      )
    }
    await answerTelegramCallbackQuery(callback.id, action === 'accept' ? 'Ordine accettato.' : 'Ordine rifiutato.')
    return json({ ok: true })
  }
  const message = update.message
  const match = message?.text?.match(/^\/start\s+login_([A-Za-z0-9_-]+)$/)
  if (!message || !message.from) return json({ ok: true })
  const telegramId = String(message.from.id)
  const db = adminClient()
  const isAdmin = envAdminIds().has(telegramId)

  if (message.text?.match(/^\/start(?:\s*)$/)) {
    if (!isAdmin && !message.from.username?.trim()) {
      await sendTelegramMessage(String(message.chat.id), 'Imposta un username @ nelle impostazioni Telegram prima di accedere.')
      return json({ ok: true })
    }
    const appUrl = Deno.env.get('TELEGRAM_MINI_APP_URL')
    if (!appUrl) {
      await sendTelegramMessage(String(message.chat.id), 'Mini applicazione non configurata. Contatta un amministratore.')
      return json({ ok: true })
    }
    const { data: existing } = await db.from('staging_allowlist').select('enabled,role').eq('telegram_subject', telegramId).maybeSingle()
    if (existing?.enabled === false && !isAdmin) {
      await sendTelegramMessage(String(message.chat.id), 'Il tuo account non è autorizzato.')
      return json({ ok: true })
    }
    const { data: existingProfile } = await db.from('profiles').select('blocked').eq('telegram_subject', telegramId).maybeSingle()
    if (existingProfile?.blocked && !isAdmin) {
      await sendTelegramMessage(String(message.chat.id), "Il tuo account è bloccato. L'accesso non è disponibile.")
      return json({ ok: true })
    }
    await db.from('staging_allowlist').upsert({
      telegram_subject: telegramId,
      role: isAdmin ? 'admin' : existing?.role ?? 'user',
      enabled: true,
      note: isAdmin ? 'TELEGRAM_ADMIN_IDS' : 'Avvio bot Telegram',
    })
    const adminUrl = new URL('/admin', appUrl).toString()
    await Promise.allSettled([
      setTelegramMiniAppMenu(
        telegramId,
        isAdmin ? adminUrl : appUrl,
        isAdmin ? 'Pannello admin' : 'Apri Street Family',
      ),
    ])
    await sendTelegramMessageWithOptions(
      String(message.chat.id),
      isAdmin ? 'Accesso amministratore disponibile.' : 'Benvenuto. Apri Street Family per accedere.',
      isAdmin
        ? { inline_keyboard: [[{ text: 'Pannello amministrazione', web_app: { url: adminUrl } }], [{ text: 'Apri Street Family', web_app: { url: appUrl } }]] }
        : { inline_keyboard: [[{ text: 'Apri Street Family', web_app: { url: appUrl } }]] },
    )
    return json({ ok: true })
  }

  if (!match) return json({ ok: true })
  const tokenHash = await sha256(match[1])
  const { data: challenge } = await db.from('telegram_login_challenges')
    .select('id,state,expires_at')
    .eq('token_hash', tokenHash)
    .eq('state', 'pending')
    .maybeSingle()
  if (!challenge || new Date(challenge.expires_at) < new Date()) {
    await sendTelegramMessage(String(message.chat.id), 'Link di accesso non valido o scaduto.')
    return json({ ok: true })
  }
  if (!isAdmin && !message.from.username?.trim()) {
    await db.from('telegram_login_challenges').update({ state: 'denied', telegram_id: telegramId }).eq('id', challenge.id)
    await sendTelegramMessage(String(message.chat.id), 'Imposta un username @ nelle impostazioni Telegram prima di accedere.')
    return json({ ok: true })
  }

  const { data: loginProfile } = await db.from('profiles').select('id,blocked').eq('telegram_subject', telegramId).maybeSingle()
  if (loginProfile?.blocked && !isAdmin) {
    await db.from('telegram_login_challenges').update({ state: 'denied', telegram_id: telegramId }).eq('id', challenge.id)
    await sendTelegramMessage(String(message.chat.id), "Il tuo account è bloccato. L'accesso non è disponibile.")
    return json({ ok: true })
  }

  const { data: existing } = await db.from('staging_allowlist').select('enabled').eq('telegram_subject', telegramId).maybeSingle()
  if (!existing || isAdmin) {
    await db.from('staging_allowlist').upsert({
      telegram_subject: telegramId,
      role: isAdmin ? 'admin' : 'user',
      enabled: true,
      note: isAdmin ? 'TELEGRAM_ADMIN_IDS' : 'Registrazione accesso Telegram',
    })
  }
  const { data: allowed } = await db.from('staging_allowlist').select('role,enabled').eq('telegram_subject', telegramId).eq('enabled', true).maybeSingle()
  if (!allowed) {
    await db.from('telegram_login_challenges').update({ state: 'denied', telegram_id: telegramId }).eq('id', challenge.id)
    await sendTelegramMessage(String(message.chat.id), 'Il tuo account non è autorizzato.')
    return json({ ok: true })
  }

  const email = `telegram_${telegramId}@street-family.invalid`
  const metadata = { telegram_id: telegramId, username: message.from.username ?? message.from.first_name ?? 'membro', first_name: message.from.first_name }
  const { data: profile } = await db.from('profiles').select('id').eq('telegram_subject', telegramId).maybeSingle()
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
    const repaired = await db.from('profiles').upsert({
      id: userId,
      telegram_subject: telegramId,
      username: metadata.username,
      role: isAdmin ? 'admin' : allowed.role,
    }, { onConflict: 'id' })
    if (repaired.error) return json({ error: publicErrorMessage(repaired.error.message, 'Creazione account non riuscita.') }, 500)
    const wallet = await db.from('wallet_balances').upsert({ user_id: userId, points: 0 }, { onConflict: 'user_id', ignoreDuplicates: true })
    if (wallet.error) return json({ error: publicErrorMessage(wallet.error.message, 'Creazione account non riuscita.') }, 500)
  } else {
    const updated = await db.from('profiles').update({ username: metadata.username }).eq('id', profile.id)
    if (updated.error) return json({ error: publicErrorMessage(updated.error.message, 'Accesso Telegram non riuscito.') }, 500)
  }
  const authTokenHash = generated.data.properties.hashed_token
  await db.from('telegram_login_challenges').update({
    telegram_id: telegramId,
    state: 'confirmed',
    auth_token_hash: authTokenHash,
    confirmed_at: new Date().toISOString(),
  }).eq('id', challenge.id)
  if (isAdmin) {
    const appUrl = Deno.env.get('TELEGRAM_MINI_APP_URL')
    const adminUrl = appUrl ? new URL('/admin', appUrl).toString() : null
    await sendTelegramMessageWithOptions(
      String(message.chat.id),
      'Accesso amministratore confermato.',
      adminUrl ? { inline_keyboard: [[{ text: 'Pannello amministrazione', web_app: { url: adminUrl } }]] } : undefined,
    )
  } else {
    await sendTelegramMessage(String(message.chat.id), 'Accesso confermato. Torna al sito.')
  }
  return json({ ok: true })
})
