import {
  adminClient,
  corsHeaders,
  deleteTelegramMessage,
  json,
  publicErrorMessage,
  sendTelegramMessageWithOptions,
  userClient,
} from '../_shared/clients.ts'

type Action = 'publish' | 'archive' | 'delete'

function broadcastText(kind: string, title: string, message: string) {
  if (kind !== 'product_new') return message
  return `${title}\n\n${message}`
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Metodo non consentito' }, 405)
  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return json({ error: 'Non autorizzato' }, 401)

  try {
    const { broadcastId, action } = await req.json() as { broadcastId?: string; action?: Action }
    if (!broadcastId || !['publish', 'archive', 'delete'].includes(String(action))) {
      return json({ error: 'Azione notizia non valida.' }, 400)
    }

    const userDb = userClient(authHeader)
    const profile = await userDb.rpc('get_my_profile')
    if (profile.error || profile.data?.role !== 'admin') return json({ error: 'Non autorizzato' }, 403)

    const db = adminClient()
    const broadcast = await db.from('broadcasts')
      .select('id,kind,title,message,status,published_at')
      .eq('id', broadcastId)
      .maybeSingle()
    if (broadcast.error) return json({ error: publicErrorMessage(broadcast.error.message, 'Lettura della notizia non riuscita.') }, 500)
    if (!broadcast.data) return json({ error: 'Notizia non trovata.' }, 404)

    if (action === 'archive') {
      const archived = await db.from('broadcasts').update({ status: 'archived' }).eq('id', broadcastId)
      if (archived.error) return json({ error: publicErrorMessage(archived.error.message, 'Archiviazione della notizia non riuscita.') }, 500)
      return json({ status: 'archived' })
    }

    if (action === 'delete') {
      const sent = await db.from('broadcast_telegram_messages')
        .select('telegram_subject,message_id')
        .eq('broadcast_id', broadcastId)
      if (sent.error) return json({ error: publicErrorMessage(sent.error.message, 'Lettura messaggi Telegram non riuscita.') }, 500)
      const results = await Promise.allSettled((sent.data ?? []).map(row =>
        deleteTelegramMessage(row.telegram_subject, Number(row.message_id))
      ))
      await db.from('broadcast_telegram_messages').delete().eq('broadcast_id', broadcastId)
      const removed = await db.from('broadcasts').delete().eq('id', broadcastId)
      if (removed.error) return json({ error: publicErrorMessage(removed.error.message, 'Eliminazione della notizia non riuscita.') }, 500)
      return json({
        status: 'deleted',
        telegramDeleted: results.filter(result => result.status === 'fulfilled').length,
        telegramFailed: results.filter(result => result.status === 'rejected').length,
      })
    }

    const profilesResult = await db.from('profiles')
      .select('telegram_subject')
      .not('telegram_subject', 'is', null)
      .eq('blocked', false)
    if (profilesResult.error) {
      return json({ error: publicErrorMessage(profilesResult.error.message, 'Lettura destinatari Telegram non riuscita.') }, 500)
    }
    const allowedResult = await db.from('staging_allowlist')
      .select('telegram_subject')
      .eq('enabled', true)
      .eq('access_status', 'approved')
    if (allowedResult.error) {
      return json({ error: publicErrorMessage(allowedResult.error.message, 'Lettura autorizzazioni Telegram non riuscita.') }, 500)
    }
    const allowedSubjects = new Set((allowedResult.data ?? []).map(row => row.telegram_subject))

    const alreadyResult = await db.from('broadcast_telegram_messages')
      .select('telegram_subject')
      .eq('broadcast_id', broadcastId)
    if (alreadyResult.error) {
      return json({ error: publicErrorMessage(alreadyResult.error.message, 'Lettura invii Telegram non riuscita.') }, 500)
    }
    const alreadySent = new Set((alreadyResult.data ?? []).map(row => row.telegram_subject))
    const recipients = (profilesResult.data ?? [])
      .map(row => row.telegram_subject)
      .filter((value): value is string => (
        typeof value === 'string'
        && value.length > 0
        && allowedSubjects.has(value)
        && !alreadySent.has(value)
      ))

    const text = broadcastText(broadcast.data.kind, broadcast.data.title, broadcast.data.message)
    const appUrl = Deno.env.get('TELEGRAM_MINI_APP_URL')
    const keyboard = appUrl
      ? { inline_keyboard: [[{ text: 'Apri Street Family', web_app: { url: appUrl } }]] }
      : undefined
    const sent = await Promise.allSettled(recipients.map(async telegramSubject => {
      const response = await sendTelegramMessageWithOptions(telegramSubject, text, keyboard)
      const messageId = response.result?.message_id
      if (!messageId) throw new Error('Telegram non ha restituito message_id.')
      const saved = await db.from('broadcast_telegram_messages').upsert({
        broadcast_id: broadcastId,
        telegram_subject: telegramSubject,
        message_id: messageId,
      }, { onConflict: 'broadcast_id,telegram_subject' })
      if (saved.error) throw new Error(saved.error.message)
    }))

    const published = await db.from('broadcasts').update({
      status: 'published',
      published_at: broadcast.data.published_at ?? new Date().toISOString(),
    }).eq('id', broadcastId)
    if (published.error) return json({ error: publicErrorMessage(published.error.message, 'Pubblicazione della notizia non riuscita.') }, 500)

    return json({
      status: 'published',
      telegramSent: sent.filter(result => result.status === 'fulfilled').length,
      telegramFailed: sent.filter(result => result.status === 'rejected').length,
    })
  } catch (caught) {
    return json({ error: publicErrorMessage(caught, 'Azione notizia non riuscita.') }, 500)
  }
})
