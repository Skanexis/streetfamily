import { createClient } from 'npm:@supabase/supabase-js@2'

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

export function adminClient() {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false, autoRefreshToken: false },
  })
}

export function userClient(authHeader: string) {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  })
}

export function json(data: unknown, status = 200, additionalHeaders: Record<string, string> = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json', ...additionalHeaders },
  })
}

export function publicErrorMessage(error: unknown, fallback = 'Operazione non riuscita. Riprova.') {
  const message = error instanceof Error
    ? error.message
    : typeof error === 'string'
      ? error
      : ''
  if (!message) return fallback
  if (/more than one relationship|could not embed|schema cache/i.test(message)) return 'Impossibile caricare i dati collegati. Aggiorna la pagina e riprova.'
  if (/duplicate key|already registered|already exists|unique constraint/i.test(message)) return 'Esiste già un elemento con questi dati.'
  if (/foreign key|still referenced|violates.*constraint/i.test(message)) return 'Operazione non possibile perché esistono dati collegati.'
  if (/row-level security|permission denied|not authorized|unauthorized|jwt|allowlist|access denied/i.test(message)) return 'Non sei autorizzato a eseguire questa operazione.'
  if (/failed to fetch|fetch failed|network|load failed/i.test(message)) return 'Connessione non disponibile. Controlla la rete e riprova.'
  if (/invalid login credentials|email not confirmed|otp|token.*expired/i.test(message)) return 'Accesso non valido o scaduto. Riprova.'
  if (/^Errore|^Impossibile|^Non |^Accesso |^Operazione |^La |^Il |^Inserisci |^Acquisisci |^KYC |^Fotocamera |^Foto |^Nessun |^Prodotto |^Categoria |^Configurazione |^Caricamento |^Invio |^Lettura |^Decisione |^Verifica |^Autorizzazione |^Dati |^Richiesta |^Codice |^Metodo |^Sono |^Puoi |^Completa /i.test(message)) return message
  return fallback
}

export async function sha256(value: string) {
  const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
  return Array.from(new Uint8Array(hash)).map(byte => byte.toString(16).padStart(2, '0')).join('')
}

export function envAdminIds() {
  return new Set((Deno.env.get('TELEGRAM_ADMIN_IDS') ?? '').split(',').map(value => value.trim()).filter(Boolean))
}

export async function sendTelegramMessage(chatId: string, text: string) {
  return sendTelegramMessageWithOptions(chatId, text)
}

export async function sendTelegramMessageWithOptions(chatId: string, text: string, replyMarkup?: unknown) {
  const token = Deno.env.get('TELEGRAM_BOT_TOKEN')
  if (!token) throw new Error('Token del bot Telegram non configurato')
  const response = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chatId, text, reply_markup: replyMarkup }),
  })
  if (!response.ok) throw new Error(`Invio messaggio Telegram non riuscito: ${response.status}`)
  return await response.json() as { ok: boolean; result?: { message_id?: number } }
}

export async function deleteTelegramMessage(chatId: string, messageId: number) {
  const token = Deno.env.get('TELEGRAM_BOT_TOKEN')
  if (!token) throw new Error('Token del bot Telegram non configurato')
  const response = await fetch(`https://api.telegram.org/bot${token}/deleteMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chatId, message_id: messageId }),
  })
  if (!response.ok) throw new Error(`Eliminazione messaggio Telegram non riuscita: ${response.status}`)
}

export async function answerTelegramCallbackQuery(callbackQueryId: string, text: string) {
  const token = Deno.env.get('TELEGRAM_BOT_TOKEN')
  if (!token) throw new Error('Token del bot Telegram non configurato')
  const response = await fetch(`https://api.telegram.org/bot${token}/answerCallbackQuery`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ callback_query_id: callbackQueryId, text }),
  })
  if (!response.ok) throw new Error(`Risposta azione Telegram non riuscita: ${response.status}`)
}

export async function editTelegramMessage(chatId: string, messageId: number, text: string) {
  const token = Deno.env.get('TELEGRAM_BOT_TOKEN')
  if (!token) throw new Error('Token del bot Telegram non configurato')
  const response = await fetch(`https://api.telegram.org/bot${token}/editMessageText`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      chat_id: chatId,
      message_id: messageId,
      text,
      reply_markup: { inline_keyboard: [] },
    }),
  })
  if (!response.ok) throw new Error(`Aggiornamento messaggio Telegram non riuscito: ${response.status}`)
}

export async function setTelegramMiniAppMenu(chatId: string, url: string, text = 'Apri Street Family') {
  const token = Deno.env.get('TELEGRAM_BOT_TOKEN')
  if (!token) throw new Error('Token del bot Telegram non configurato')
  const response = await fetch(`https://api.telegram.org/bot${token}/setChatMenuButton`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      chat_id: chatId,
      menu_button: { type: 'web_app', text, web_app: { url } },
    }),
  })
  if (!response.ok) throw new Error(`Configurazione menu Telegram non riuscita: ${response.status}`)
}
