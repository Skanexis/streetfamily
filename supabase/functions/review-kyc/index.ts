import { adminClient, corsHeaders, json, publicErrorMessage, sendTelegramMessage, userClient } from '../_shared/clients.ts'

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Metodo non consentito' }, 405)
  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return json({ error: 'Non autorizzato' }, 401)
  const { userId, decision, reason } = await req.json()
  const { error } = await userClient(authHeader).rpc('admin_review_kyc', {
    p_user_id: userId,
    p_decision: decision,
    p_reason: reason ?? '',
  })
  if (error) return json({ error: publicErrorMessage(error.message, 'Decisione sulla verifica non riuscita.') }, 403)
  const db = adminClient()
  if (decision === 'rejected') {
    const documents = await db.from('kyc_documents').select('storage_path').eq('user_id', userId)
    const paths = (documents.data ?? []).map(row => row.storage_path)
    if (paths.length) await db.storage.from('kyc-documents').remove(paths)
    await db.from('kyc_documents').delete().eq('user_id', userId)
  }
  if (decision === 'approved') {
    const settings = await db.from('app_settings').select('value').eq('key', 'kyc_retention').maybeSingle()
    const retentionDays = Number(settings.data?.value?.approved_days ?? 36500)
    await db.from('kyc_cases').update({
      retain_until: new Date(Date.now() + retentionDays * 24 * 60 * 60 * 1000).toISOString(),
    }).eq('user_id', userId)
  }
  const recipient = await db.from('profiles').select('telegram_subject').eq('id', userId).maybeSingle()
  if (recipient.data?.telegram_subject) {
    const text = decision === 'approved'
      ? 'Verifica approvata. Ora puoi proseguire con l’ordine.'
      : 'Verifica non approvata. Effettua nuovamente la procedura dal sito.'
    await Promise.allSettled([sendTelegramMessage(recipient.data.telegram_subject, text)])
  }
  return json({ status: decision })
})
