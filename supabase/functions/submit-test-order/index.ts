import { adminClient, corsHeaders, envAdminIds, json, sendTelegramMessage, userClient } from '../_shared/clients.ts'

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return json({ error: 'Unauthorized' }, 401)
  const auth = userClient(authHeader)
  const { data: { user }, error: userError } = await auth.auth.getUser()
  if (userError || !user) return json({ error: 'Unauthorized' }, 401)
  const body = await req.json()
  const db = adminClient()
  const { data, error } = await db.rpc('submit_test_order_internal', {
    p_user_id: user.id,
    p_items: body.items,
    p_scenario_type: body.scenarioType,
    p_city: body.city ?? '',
    p_street: body.street ?? '',
    p_tokens_to_reserve: Number(body.tokensToReserve ?? 0),
  })
  if (error) return json({ error: error.message }, 400)

  const username = user.user_metadata?.username ?? user.user_metadata?.first_name ?? user.id
  const text = [
    'Nuova richiesta TEST Street Family',
    `Ordine: ${data.display_id}`,
    `Utente: @${username}`,
    `Totale simulato: EUR ${data.simulated_total}`,
    `Units: ${data.total_units}`,
    `Scenario: ${body.scenarioType} / ${body.city ?? ''}`,
    `Gettoni riservati: ${data.tokens_reserved}`,
    'Ambiente demo: nessun pagamento, scambio o fulfillment reale.',
  ].join('\n')
  await Promise.allSettled(Array.from(envAdminIds()).map(chatId => sendTelegramMessage(chatId, text)))
  return json(data)
})
