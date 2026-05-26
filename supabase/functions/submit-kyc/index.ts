import { adminClient, corsHeaders, envAdminIds, json, publicErrorMessage, sendTelegramMessageWithOptions, userClient } from '../_shared/clients.ts'

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Metodo non consentito' }, 405)
  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return json({ error: 'Non autorizzato' }, 401)
  const session = userClient(authHeader)
  const { data: { user }, error: authError } = await session.auth.getUser()
  if (authError || !user) return json({ error: 'Non autorizzato' }, 401)
  const access = await session.rpc('get_my_kyc_status')
  if (access.error) return json({ error: publicErrorMessage(access.error.message, 'Accesso alla verifica non riuscito.') }, 403)
  const db = adminClient()
  const currentCase = await db.from('kyc_cases').select('status').eq('user_id', user.id).maybeSingle()
  if (currentCase.data?.status === 'approved') return json({ error: 'KYC già approvata.' }, 409)
  const documents = await db.from('kyc_documents').select('document_type').eq('user_id', user.id)
  if (documents.error || new Set((documents.data ?? []).map(row => row.document_type)).size !== 3) {
    return json({ error: 'Acquisisci tutte le tre immagini richieste.' }, 400)
  }
  const update = await db.from('kyc_cases').upsert({
    user_id: user.id,
    status: 'submitted',
    submitted_at: new Date().toISOString(),
    rejection_reason: null,
  }, { onConflict: 'user_id' })
  if (update.error) return json({ error: publicErrorMessage(update.error.message, 'Invio verifica non riuscito.') }, 500)
  await db.from('admin_audit_log').insert({
    actor_id: user.id,
    action: 'kyc.submitted',
    entity_type: 'profile',
    entity_id: user.id,
    details: { document_count: 3 },
  })
  const username = user.user_metadata?.username ?? user.user_metadata?.first_name ?? user.id
  const appUrl = Deno.env.get('TELEGRAM_MINI_APP_URL')
  const adminUrl = appUrl ? new URL('/admin', appUrl) : null
  if (adminUrl) {
    adminUrl.searchParams.set('tab', 'users')
    adminUrl.searchParams.set('kyc', user.id)
  }
  const keyboard = adminUrl
    ? { inline_keyboard: [[{ text: 'Apri KYC', web_app: { url: adminUrl.toString() } }]] }
    : undefined
  await Promise.allSettled(Array.from(envAdminIds()).map(id => sendTelegramMessageWithOptions(
    id,
    `Nuova richiesta KYC\nUtente: @${username}\nStato: da revisionare`,
    keyboard,
  )))
  return json({ status: 'submitted' })
})
