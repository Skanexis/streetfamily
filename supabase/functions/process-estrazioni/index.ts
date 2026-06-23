import {
  adminClient,
  corsHeaders,
  envAdminIds,
  json,
  publicErrorMessage,
  sendTelegramMessageWithOptions,
} from '../_shared/clients.ts'

type Draw = {
  id: string
  title: string
  status: 'sold_out' | 'scheduled' | 'running'
  max_tickets: number
  winners_count: number
  scheduled_at: string | null
  public_token: string
  admin_notified_at: string | null
  reminder_sent_at: string | null
}

function suppliedSecret(req: Request) {
  const auth = req.headers.get('Authorization') ?? ''
  return req.headers.get('x-estrazione-cron-secret') ?? auth.replace(/^Bearer\s+/i, '')
}

function miniAppUrl(path: string, params: Record<string, string> = {}) {
  const base = Deno.env.get('TELEGRAM_MINI_APP_URL') || Deno.env.get('SITE_URL') || ''
  if (!base) return ''
  try {
    const url = new URL(base)
    url.pathname = path
    for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value)
    return url.toString()
  } catch {
    return base
  }
}

async function saveTelegramResult(
  db: ReturnType<typeof adminClient>,
  drawId: string,
  telegramSubject: string,
  kind: 'admin_sold_out' | 'reminder',
  result: PromiseSettledResult<{ ok: boolean; result?: { message_id?: number } }>,
) {
  const payload = result.status === 'fulfilled'
    ? {
      estrazione_id: drawId,
      telegram_subject: telegramSubject,
      kind,
      message_id: result.value.result?.message_id ?? null,
      error: null,
      sent_at: new Date().toISOString(),
    }
    : {
      estrazione_id: drawId,
      telegram_subject: telegramSubject,
      kind,
      message_id: null,
      error: result.reason instanceof Error ? result.reason.message : String(result.reason),
      sent_at: new Date().toISOString(),
    }
  await db.from('estrazione_telegram_messages')
    .upsert(payload, { onConflict: 'estrazione_id,telegram_subject,kind' })
}

async function notifyAdminsSoldOut(db: ReturnType<typeof adminClient>, draw: Draw) {
  if (draw.admin_notified_at) return { sent: 0, failed: 0 }
  const recipients = Array.from(envAdminIds())
  const adminUrl = miniAppUrl('/admin', { tab: 'estrazione' })
  const text = [
    'Estrazione sold out',
    draw.title,
    '',
    `Biglietti venduti: ${draw.max_tickets}/${draw.max_tickets}`,
    `Posti vincenti: ${draw.winners_count}`,
    '',
    'Apri il pannello e programma l’orario dell’Estrazione.',
  ].join('\n')
  const keyboard = adminUrl
    ? { inline_keyboard: [[{ text: 'Apri amministrazione', web_app: { url: adminUrl } }]] }
    : undefined
  const results = await Promise.allSettled(recipients.map(chatId => sendTelegramMessageWithOptions(chatId, text, keyboard)))
  await Promise.all(results.map((result, index) => saveTelegramResult(db, draw.id, recipients[index], 'admin_sold_out', result)))
  await db.from('estrazioni').update({ admin_notified_at: new Date().toISOString() }).eq('id', draw.id)
  return {
    sent: results.filter(result => result.status === 'fulfilled').length,
    failed: results.filter(result => result.status === 'rejected').length,
  }
}

async function notifyApprovedUsers(db: ReturnType<typeof adminClient>, draw: Draw) {
  if (draw.reminder_sent_at || !draw.scheduled_at) return { sent: 0, failed: 0 }
  const scheduledAt = new Date(draw.scheduled_at).getTime()
  const now = Date.now()
  if (scheduledAt - now > 60_000 || scheduledAt - now < -300_000) return { sent: 0, failed: 0 }

  const profiles = await db.from('profiles')
    .select('telegram_subject')
    .not('telegram_subject', 'is', null)
    .eq('blocked', false)
  if (profiles.error) throw new Error(profiles.error.message)

  const allowlist = await db.from('staging_allowlist')
    .select('telegram_subject')
    .eq('enabled', true)
    .eq('access_status', 'approved')
  if (allowlist.error) throw new Error(allowlist.error.message)

  const already = await db.from('estrazione_telegram_messages')
    .select('telegram_subject')
    .eq('estrazione_id', draw.id)
    .eq('kind', 'reminder')
  if (already.error) throw new Error(already.error.message)

  const allowed = new Set((allowlist.data ?? []).map(row => row.telegram_subject))
  const sentBefore = new Set((already.data ?? []).map(row => row.telegram_subject))
  const recipients = (profiles.data ?? [])
    .map(row => row.telegram_subject)
    .filter((value): value is string => (
      typeof value === 'string'
      && value.length > 0
      && allowed.has(value)
      && !sentBefore.has(value)
    ))

  const liveUrl = miniAppUrl(`/estrazione/live/${draw.public_token}`)
  const text = [
    'Estrazione inizia tra 1 minuto',
    draw.title,
    '',
    'Apri la pagina live per seguire il countdown e l’estrazione.',
  ].join('\n')
  const keyboard = liveUrl
    ? { inline_keyboard: [[{ text: 'Apri Estrazione live', web_app: { url: liveUrl } }]] }
    : undefined
  const results = await Promise.allSettled(recipients.map(chatId => sendTelegramMessageWithOptions(chatId, text, keyboard)))
  await Promise.all(results.map((result, index) => saveTelegramResult(db, draw.id, recipients[index], 'reminder', result)))
  await db.from('estrazioni').update({ reminder_sent_at: new Date().toISOString() }).eq('id', draw.id)
  return {
    sent: results.filter(result => result.status === 'fulfilled').length,
    failed: results.filter(result => result.status === 'rejected').length,
  }
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Metodo non consentito' }, 405)

  const expected = Deno.env.get('ESTRAZIONE_CRON_SECRET')?.trim()
  if (!expected) return json({ error: 'ESTRAZIONE_CRON_SECRET non configurato' }, 500)
  if (suppliedSecret(req) !== expected) return json({ error: 'Non autorizzato' }, 401)

  try {
    const db = adminClient()
    const { data, error } = await db.from('estrazioni')
      .select('id,title,status,max_tickets,winners_count,scheduled_at,public_token,admin_notified_at,reminder_sent_at')
      .in('status', ['sold_out', 'scheduled', 'running'])
    if (error) return json({ error: publicErrorMessage(error.message, 'Lettura estrazioni non riuscita.') }, 500)

    let adminSent = 0
    let adminFailed = 0
    let reminderSent = 0
    let reminderFailed = 0
    let drawsRun = 0
    const drawErrors: string[] = []

    for (const draw of (data ?? []) as Draw[]) {
      if (draw.status === 'sold_out') {
        const result = await notifyAdminsSoldOut(db, draw)
        adminSent += result.sent
        adminFailed += result.failed
      }
      if (draw.status === 'scheduled') {
        const result = await notifyApprovedUsers(db, draw)
        reminderSent += result.sent
        reminderFailed += result.failed
        if (draw.scheduled_at && new Date(draw.scheduled_at).getTime() <= Date.now()) {
          const run = await db.rpc('run_estrazione_internal', { p_id: draw.id, p_force: false })
          if (run.error) drawErrors.push(`${draw.id}: ${run.error.message}`)
          else drawsRun += 1
        }
      }
    }

    return json({ adminSent, adminFailed, reminderSent, reminderFailed, drawsRun, drawErrors })
  } catch (caught) {
    return json({ error: publicErrorMessage(caught, 'Elaborazione Estrazione non riuscita.') }, 500)
  }
})
