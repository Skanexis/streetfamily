import { adminClient, corsHeaders, json, publicErrorMessage, userClient } from '../_shared/clients.ts'

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Metodo non consentito' }, 405)
  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return json({ error: 'Non autorizzato' }, 401)

  try {
    const { telegramSubject, decision } = await req.json() as { telegramSubject?: string; decision?: 'approved' | 'rejected' }
    if (!telegramSubject || !['approved', 'rejected'].includes(String(decision))) {
      return json({ error: 'Decisione accesso non valida.' }, 400)
    }

    const userDb = userClient(authHeader)
    const profile = await userDb.rpc('get_my_profile')
    if (profile.error || profile.data?.role !== 'admin') return json({ error: 'Non autorizzato' }, 403)

    const result = await adminClient().rpc('admin_review_access_request', {
      p_actor_id: profile.data.id,
      p_telegram_subject: telegramSubject,
      p_decision: decision,
    })
    if (result.error) return json({ error: publicErrorMessage(result.error.message, 'Aggiornamento accesso non riuscito.') }, 400)
    return json(result.data)
  } catch (caught) {
    return json({ error: publicErrorMessage(caught, 'Aggiornamento accesso non riuscito.') }, 500)
  }
})
