import { adminClient, corsHeaders, json, publicErrorMessage } from '../_shared/clients.ts'

type Body = Record<string, unknown>

const extendedCorsHeaders = {
  ...corsHeaders,
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-manychat-estrazione-secret',
}

function suppliedSecret(req: Request, body: Body) {
  const auth = req.headers.get('Authorization') ?? ''
  return req.headers.get('x-manychat-estrazione-secret')
    ?? auth.replace(/^Bearer\s+/i, '')
    ?? stringValue(body.secret)
    ?? stringValue(body.manychat_secret)
}

function stringValue(value: unknown) {
  return typeof value === 'string' ? value.trim() : ''
}

function nestedSources(body: Body) {
  return [
    body,
    body.custom_fields,
    body.contact,
    (body.contact as Body | undefined)?.custom_fields,
    body.subscriber,
    (body.subscriber as Body | undefined)?.custom_fields,
  ].filter((value): value is Body => Boolean(value) && typeof value === 'object' && !Array.isArray(value))
}

function firstString(body: Body, keys: string[]) {
  for (const source of nestedSources(body)) {
    for (const key of keys) {
      const value = source[key]
      if (typeof value === 'string' && value.trim()) return value.trim()
      if (typeof value === 'number') return String(value)
    }
  }
  return ''
}

function firstBoolean(body: Body, keys: string[]) {
  for (const source of nestedSources(body)) {
    for (const key of keys) {
      const value = source[key]
      if (typeof value === 'boolean') return value
      if (typeof value === 'string') {
        const normalized = value.trim().toLowerCase()
        if (['true', 'yes', 'si', 'sì', '1', 'follow', 'following', 'follows'].includes(normalized)) return true
        if (['false', 'no', '0', 'not_following', 'not follows', 'not_follow'].includes(normalized)) return false
      }
      if (typeof value === 'number') return value !== 0
    }
  }
  return null
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: extendedCorsHeaders })
  if (req.method !== 'POST') return json({ error: 'Metodo non consentito' }, 405, extendedCorsHeaders)

  try {
    const secret = Deno.env.get('MANYCHAT_ESTRAZIONE_SECRET') ?? ''
    if (!secret) return json({ error: 'MANYCHAT_ESTRAZIONE_SECRET non configurato' }, 500, extendedCorsHeaders)

    const body = await req.json().catch(() => ({})) as Body
    if (suppliedSecret(req, body) !== secret) return json({ error: 'Non autorizzato' }, 401, extendedCorsHeaders)

    const follows = firstBoolean(body, [
      'follows',
      'following',
      'is_following',
      'isUserFollowBusiness',
      'is_user_follow_business',
      'follows_your_account',
    ])
    if (follows === false) {
      return json({ ok: false, verified: false, error: 'INSTAGRAM_FOLLOW_REQUIRED' }, 403, extendedCorsHeaders)
    }

    const verificationCode = firstString(body, [
      'verification_code',
      'verificationCode',
      'code',
      'estrazione_code',
      'estrazioneCode',
    ])
    const instagramUsername = firstString(body, [
      'instagram_username',
      'instagramUsername',
      'ig_username',
      'igUsername',
      'username',
      'user_name',
    ])

    if (!verificationCode) return json({ ok: false, error: 'Codice verifica mancante' }, 400, extendedCorsHeaders)

    const { data, error } = await adminClient().rpc('manychat_verify_estrazione_instagram', {
      p_verification_code: verificationCode,
      p_instagram_username: instagramUsername,
      p_payload: body,
    })
    if (error) throw new Error(error.message)

    const result = data && typeof data === 'object' && !Array.isArray(data) ? data as Body : {}
    return json({ ok: true, ...result }, 200, extendedCorsHeaders)
  } catch (caught) {
    return json({ ok: false, error: publicErrorMessage(caught, 'Verifica Instagram non riuscita.') }, 400, extendedCorsHeaders)
  }
})
