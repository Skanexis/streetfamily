import { envAdminIds, sendTelegramMessageWithOptions } from './clients.ts'

type DbClient = {
  from: (table: string) => any
}

type AccessRow = {
  enabled?: boolean
  access_status?: 'pending' | 'approved' | 'rejected'
  access_notified_at?: string | null
}

export async function ensureAccessRequest(
  db: DbClient,
  telegramId: string,
  username: string,
  isAdmin: boolean,
) {
  const existing = await db.from('staging_allowlist')
    .select('enabled,access_status,access_notified_at')
    .eq('telegram_subject', telegramId)
    .maybeSingle()
  if (existing.error) throw new Error(existing.error.message)
  const row = existing.data as AccessRow | null

  if (isAdmin) {
    const saved = await db.from('staging_allowlist').upsert({
      telegram_subject: telegramId,
      role: 'admin',
      enabled: true,
      access_status: 'approved',
      access_requested_at: row ? undefined : new Date().toISOString(),
      access_decided_at: new Date().toISOString(),
      note: 'TELEGRAM_ADMIN_IDS',
    }, { onConflict: 'telegram_subject' })
    if (saved.error) throw new Error(saved.error.message)
    return { status: 'approved' as const, notified: false }
  }

  if (row?.access_status === 'approved') {
    if (!row.enabled) {
      const fixed = await db.from('staging_allowlist')
        .update({
          enabled: true,
          access_decided_at: new Date().toISOString(),
          note: 'Approved access normalized during Telegram login',
        })
        .eq('telegram_subject', telegramId)
        .eq('access_status', 'approved')
      if (fixed.error) throw new Error(fixed.error.message)
    }
    return { status: 'approved' as const, notified: false }
  }
  if (row?.access_status === 'rejected') return { status: 'rejected' as const, notified: false }

  const now = new Date().toISOString()
  const saved = await db.from('staging_allowlist').upsert({
    telegram_subject: telegramId,
    role: 'user',
    enabled: false,
    access_status: 'pending',
    access_requested_at: row ? undefined : now,
    access_username: username,
    note: 'Richiesta accesso in attesa',
  }, { onConflict: 'telegram_subject' })
  if (saved.error) throw new Error(saved.error.message)

  if (!row?.access_notified_at) {
    const text = [
      'Nuova richiesta accesso Street Family',
      `Telegram ID: ${telegramId}`,
      `Username: @${username}`,
    ].join('\n')
    const keyboard = {
      inline_keyboard: [[
        { text: 'ACCETTA', callback_data: `acc:a:${telegramId}` },
        { text: 'RIFIUTA', callback_data: `acc:r:${telegramId}` },
      ]],
    }
    await Promise.allSettled(Array.from(envAdminIds()).map(chatId => sendTelegramMessageWithOptions(chatId, text, keyboard)))
    const marked = await db.from('staging_allowlist')
      .update({ access_notified_at: now })
      .eq('telegram_subject', telegramId)
      .eq('access_status', 'pending')
    if (marked.error) throw new Error(marked.error.message)
    return { status: 'pending' as const, notified: true }
  }

  return { status: 'pending' as const, notified: false }
}
