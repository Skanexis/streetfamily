import { adminClient, corsHeaders, json, publicErrorMessage, userClient } from '../_shared/clients.ts'
import { sendPendingLowStockNotifications } from '../_shared/low-stock.ts'

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Metodo non consentito' }, 405)
  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return json({ error: 'Non autorizzato' }, 401)

  try {
    const userDb = userClient(authHeader)
    const profile = await userDb.rpc('get_my_profile')
    if (profile.error || profile.data?.role !== 'admin') return json({ error: 'Non autorizzato' }, 403)

    const result = await sendPendingLowStockNotifications(adminClient())
    return json(result)
  } catch (caught) {
    return json({ error: publicErrorMessage(caught, 'Invio notifiche magazzino non riuscito.') }, 500)
  }
})
