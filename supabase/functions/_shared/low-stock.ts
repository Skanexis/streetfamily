import { envAdminIds, sendTelegramMessageWithOptions } from './clients.ts'

type DbClient = {
  from: (table: string) => any
}

type LowStockNotification = {
  id: string
  stock_quantity: number
  threshold_quantity: number
  products?: { name?: string } | null
}

export async function sendPendingLowStockNotifications(db: DbClient) {
  const pending = await db.from('low_stock_notifications')
    .select('id,stock_quantity,threshold_quantity,products(name)')
    .eq('status', 'pending')
    .order('created_at', { ascending: true })
    .limit(25)
  if (pending.error) throw new Error(pending.error.message)

  const notifications = (pending.data ?? []) as LowStockNotification[]
  if (!notifications.length) return { processed: 0, telegramSent: 0, telegramFailed: 0 }

  const ids = notifications.map(notification => notification.id)
  const claimed = await db.from('low_stock_notifications')
    .update({ status: 'processing', error: null })
    .in('id', ids)
    .eq('status', 'pending')
    .select('id')
  if (claimed.error) throw new Error(claimed.error.message)
  const claimedIds = new Set((claimed.data ?? []).map((row: { id: string }) => row.id))
  const recipients = Array.from(envAdminIds())
  let telegramSent = 0
  let telegramFailed = 0

  for (const notification of notifications.filter(notification => claimedIds.has(notification.id))) {
    const productName = notification.products?.name ?? 'Prodotto'
    const text = [
      'Magazzino: prodotto quasi finito',
      `Prodotto: ${productName}`,
      `Rimanenza: ${notification.stock_quantity} g`,
      `Soglia notifica: ${notification.threshold_quantity} g`,
    ].join('\n')
    const results = await Promise.allSettled(recipients.map(chatId => sendTelegramMessageWithOptions(chatId, text)))
    const sent = results.filter(result => result.status === 'fulfilled').length
    const failed = results.filter(result => result.status === 'rejected').length
    telegramSent += sent
    telegramFailed += failed
    const saved = await db.from('low_stock_notifications').update({
      status: failed > 0 ? 'failed' : 'sent',
      telegram_sent: sent,
      telegram_failed: failed,
      error: failed > 0 ? 'Alcuni messaggi Telegram non sono stati inviati.' : null,
      sent_at: new Date().toISOString(),
    }).eq('id', notification.id)
    if (saved.error) throw new Error(saved.error.message)
  }

  return { processed: claimedIds.size, telegramSent, telegramFailed }
}
