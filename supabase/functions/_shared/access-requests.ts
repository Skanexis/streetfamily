import { envAdminIds, sendTelegramMessageWithOptions } from './clients.ts'

type DbClient = {
  from: (table: string) => any
  rpc?: (name: string, args?: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>
}

type AccessRow = {
  telegram_subject?: string
  role?: 'user' | 'admin'
  enabled?: boolean
  access_status?: 'pending' | 'approved' | 'rejected'
  access_notified_at?: string | null
}

type ProfileRow = {
  role?: 'user' | 'admin'
  blocked?: boolean
  username?: string | null
}

export async function ensureAccessRequest(
  db: DbClient,
  telegramId: string,
  username: string,
  isAdmin: boolean,
) {
  const telegramSubject = normalizeTelegramSubject(telegramId) ?? telegramId.trim()
  const effective = db.rpc
    ? await db.rpc('effective_access_row', { p_telegram_subject: telegramSubject })
    : null
  if (effective?.error && !/effective_access_row|schema cache|could not find/i.test(effective.error.message)) {
    throw new Error(effective.error.message)
  }
  const effectiveRow = Array.isArray(effective?.data) ? effective.data[0] as AccessRow : null
  const existing = await db.from('staging_allowlist')
    .select('enabled,access_status,access_notified_at')
    .eq('telegram_subject', telegramSubject)
    .maybeSingle()
  if (existing.error) throw new Error(existing.error.message)
  const row = existing.data as AccessRow | null

  if (isAdmin) {
    const saved = await db.from('staging_allowlist').upsert({
      telegram_subject: telegramSubject,
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

  if (effectiveRow?.access_status === 'approved' && effectiveRow.enabled !== false) {
    const fixed = await db.from('staging_allowlist').upsert({
      telegram_subject: telegramSubject,
      role: effectiveRow.role === 'admin' ? 'admin' : 'user',
      enabled: true,
      access_status: 'approved',
      access_decided_at: new Date().toISOString(),
      access_username: username,
      note: 'Approved access normalized during Telegram login',
    }, { onConflict: 'telegram_subject' })
    if (fixed.error) throw new Error(fixed.error.message)
    return { status: 'approved' as const, notified: false }
  }
  if (effectiveRow?.access_status === 'rejected') return { status: 'rejected' as const, notified: false }

  const existingProfile = await db.from('profiles')
    .select('role,blocked,username')
    .eq('telegram_subject', telegramSubject)
    .maybeSingle()
  if (existingProfile.error) throw new Error(existingProfile.error.message)
  const profile = existingProfile.data as ProfileRow | null
  if (profile?.blocked) return { status: 'rejected' as const, notified: false }

  const now = new Date().toISOString()
  const saved = await db.from('staging_allowlist').upsert({
    telegram_subject: telegramSubject,
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
      `Telegram ID: ${telegramSubject}`,
      `Username: @${username}`,
    ].join('\n')
    const keyboard = {
      inline_keyboard: [[
        { text: 'ACCETTA', callback_data: `acc:a:${telegramSubject}` },
        { text: 'RIFIUTA', callback_data: `acc:r:${telegramSubject}` },
      ]],
    }
    await Promise.allSettled(Array.from(envAdminIds()).map(chatId => sendTelegramMessageWithOptions(chatId, text, keyboard)))
    const marked = await db.from('staging_allowlist')
      .update({ access_notified_at: now })
      .eq('telegram_subject', telegramSubject)
      .eq('access_status', 'pending')
    if (marked.error) throw new Error(marked.error.message)
    return { status: 'pending' as const, notified: true }
  }

  return { status: 'pending' as const, notified: false }
}

function normalizeTelegramSubject(value: string) {
  const text = value.trim()
  if (/^[0-9]+$/.test(text)) return text
  const emailMatch = text.match(/^telegram_([0-9]+)@street-family\.invalid$/i)
  if (emailMatch) return emailMatch[1]
  const prefixedMatch = text.match(/^telegram_([0-9]+)$/i)
  if (prefixedMatch) return prefixedMatch[1]
  return null
}
