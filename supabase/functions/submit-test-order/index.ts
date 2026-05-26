import { adminClient, corsHeaders, envAdminIds, json, sendTelegramMessage, userClient } from '../_shared/clients.ts'

function orderErrorMessage(message: string) {
  const messages: Record<string, string> = {
    'Staging access denied': 'Accesso non autorizzato.',
    KYC_REQUIRED_FIRST_ORDER: 'Completa prima la verifica dell\'identità.',
    SCENARIO_INVALID: 'Scenario non valido.',
    CART_EMPTY: 'Il carrello è vuoto.',
    ITEM_UNAVAILABLE: 'Articolo non disponibile.',
    CITY_STREET_REQUIRED: 'Inserisci città e via.',
    CITY_NOT_AVAILABLE: 'Città non disponibile.',
    STREET_REQUIRED: 'Inserisci la via.',
    TOKEN_RESERVE_INVALID: 'Numero di gettoni non valido.',
    TOKEN_SPEND_REQUIRED: 'Usa almeno un gettone per continuare.',
  }
  if (message.startsWith('MINIMUM_UNITS_REQUIRED:')) {
    return `Sono necessari almeno ${message.split(':')[1]} g.`
  }
  if (message.startsWith('MAXIMUM_UNITS_SUPPORTED:')) {
    return `Sono supportati al massimo ${message.split(':')[1]} g.`
  }
  if (message === 'GRAM_AMOUNT_INVALID') return 'Inserisci almeno 50 g, in multipli di 25 g.'
  return messages[message] ?? message
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Metodo non consentito' }, 405)
  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return json({ error: 'Non autorizzato' }, 401)
  const auth = userClient(authHeader)
  const { data: { user }, error: userError } = await auth.auth.getUser()
  if (userError || !user) return json({ error: 'Non autorizzato' }, 401)
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
  if (error) return json({ error: orderErrorMessage(error.message) }, 400)

  const username = user.user_metadata?.username ?? user.user_metadata?.first_name ?? user.id
  const scenarioLabels: Record<string, string> = {
    meetup: 'Incontro',
    delivery_zone: 'Consegna in zona',
    delivery_italia: 'Consegna Italia',
  }
  const text = [
    'Nuova richiesta dimostrativa Street Family',
    `Richiesta: ${data.display_id}`,
    `Utente: @${username}`,
    `Totale simulato: EUR ${data.simulated_total}`,
    `Grammi: ${data.total_units}`,
    `Scenario: ${scenarioLabels[body.scenarioType] ?? body.scenarioType} / ${body.city ?? ''}`,
    `Gettoni riservati: ${data.tokens_reserved}`,
    'Ambiente dimostrativo: nessun pagamento, scambio o gestione reale degli ordini.',
  ].join('\n')
  await Promise.allSettled(Array.from(envAdminIds()).map(chatId => sendTelegramMessage(chatId, text)))
  return json(data)
})
