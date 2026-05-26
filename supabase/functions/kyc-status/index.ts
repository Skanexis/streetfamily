import { corsHeaders, json, publicErrorMessage, userClient } from '../_shared/clients.ts'

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return json({ error: 'Non autorizzato' }, 401)
  const { data, error } = await userClient(authHeader).rpc('get_my_kyc_status')
  if (error) return json({ error: publicErrorMessage(error.message, 'Lettura verifica non riuscita.') }, 403)
  return json(data)
})
