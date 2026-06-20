import { adminClient, corsHeaders, envAdminIds, json, publicErrorMessage, sendTelegramMessageWithOptions, userClient } from '../_shared/clients.ts'

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
  if (message === 'GRAM_AMOUNT_INVALID') return 'Inserisci almeno 25 g, in multipli di 25 g.'
  return messages[message] ?? publicErrorMessage(message, 'Invio richiesta non riuscito.')
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
  const tokensToReserve = Number(body.tokensToReserve ?? 0)
  if (!Number.isInteger(tokensToReserve) || tokensToReserve < 0) {
    return json({ error: orderErrorMessage('TOKEN_RESERVE_INVALID') }, 400)
  }
  const db = adminClient()
  const { data, error } = await db.rpc('submit_test_order_internal', {
    p_user_id: user.id,
    p_items: body.items,
    p_scenario_type: body.scenarioType,
    p_city: body.city ?? '',
    p_street: body.street ?? '',
    p_tokens_to_reserve: tokensToReserve,
  })
  if (error) return json({ error: orderErrorMessage(error.message) }, 400)

  const username = user.user_metadata?.username ?? user.user_metadata?.first_name ?? user.id
  const { data: items } = await db.from('order_items')
    .select('name_snapshot,variant_label,unit_price')
    .eq('order_id', data.order_id)
  const { data: rewards } = await db.from('user_rewards')
    .select('reward_definitions(label,kind)')
    .eq('redeemed_order_id', data.order_id)
  const itemRewards = (rewards ?? [])
    .filter(reward => reward.reward_definitions?.kind === 'item')
    .map(reward => reward.reward_definitions?.label)
    .filter(Boolean)
  const scenarioLabels: Record<string, string> = {
    meetup: 'MEETUP',
    delivery_zone: 'DELIVERY LOCALE',
    delivery_italia: 'DELIVERY TUTTA ITALIA',
  }
  const address = [body.city, body.street].filter(Boolean).join(', ')
  const text = [
    'Nuovo ordine Street Family',
    `Ordine: ${data.display_id}`,
    `Utente: @${username}`,
    '',
    'Prodotti:',
    ...(items ?? []).map(item => `- ${item.name_snapshot} / ${item.variant_label}: EUR ${item.unit_price}`),
    '',
    `Servizio: ${scenarioLabels[body.scenarioType] ?? body.scenarioType}`,
    `Destinazione: ${address}`,
    `Subtotale: EUR ${data.simulated_subtotal}`,
    `Supplemento: EUR ${data.simulated_surcharge}`,
    `Gettoni usati: ${data.tokens_reserved}`,
    `Totale: EUR ${data.simulated_total}`,
    `Grammi: ${data.total_units}`,
    ...(itemRewards.length ? ['', 'Premi da consegnare:', ...itemRewards.map(label => `- ${label}`)] : []),
    `Premio dopo completamento: +${data.tokens_on_complete} gettoni / +${data.xp_on_complete} XP`,
  ].join('\n')
  const keyboard = {
    inline_keyboard: [[
      { text: 'ACCETTA', callback_data: `ord:a:${data.order_id}` },
      { text: 'RIFIUTA', callback_data: `ord:r:${data.order_id}` },
    ]],
  }
  await Promise.allSettled(Array.from(envAdminIds()).map(chatId => sendTelegramMessageWithOptions(chatId, text, keyboard)))
  return json(data)
})
