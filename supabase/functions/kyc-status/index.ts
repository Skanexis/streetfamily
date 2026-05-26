import { corsHeaders, json, userClient } from '../_shared/clients.ts'

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return json({ error: 'Unauthorized' }, 401)
  const { data, error } = await userClient(authHeader).rpc('get_my_kyc_status')
  if (error) return json({ error: error.message }, 403)
  return json(data)
})
