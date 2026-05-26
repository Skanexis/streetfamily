import { adminClient, corsHeaders, envAdminIds, json, sendTelegramMessage, userClient } from '../_shared/clients.ts'

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Metodo non consentito' }, 405)
  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return json({ error: 'Non autorizzato' }, 401)
  const session = userClient(authHeader)
  const { data: { user }, error: authError } = await session.auth.getUser()
  if (authError || !user) return json({ error: 'Non autorizzato' }, 401)
  const access = await session.rpc('get_my_kyc_status')
  if (access.error) return json({ error: access.error.message }, 403)
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
  if (update.error) return json({ error: update.error.message }, 500)
  await db.from('admin_audit_log').insert({
    actor_id: user.id,
    action: 'kyc.submitted',
    entity_type: 'profile',
    entity_id: user.id,
    details: { document_count: 3 },
  })
  const username = user.user_metadata?.username ?? user.user_metadata?.first_name ?? user.id
  await Promise.allSettled(Array.from(envAdminIds()).map(id => sendTelegramMessage(id, `KYC da revisionare\nUtente: @${username}\nApri il pannello amministrazione.`)))
  return json({ status: 'submitted' })
})
