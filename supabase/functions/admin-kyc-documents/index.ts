import { adminClient, corsHeaders, json, publicErrorMessage, userClient } from '../_shared/clients.ts'

function externalOrigin(req: Request) {
  const forwardedHost = req.headers.get('x-forwarded-host')?.split(',')[0]?.trim()
  const host = forwardedHost || req.headers.get('host')?.trim()
  const forwardedProto = req.headers.get('x-forwarded-proto')?.split(',')[0]?.trim()
  const localHost = host?.startsWith('localhost') || host?.startsWith('127.0.0.1')
  const proto = localHost ? (forwardedProto || 'http') : 'https'
  if (host) return `${proto}://${host}`
  return Deno.env.get('SUPABASE_PUBLIC_URL') || Deno.env.get('API_EXTERNAL_URL') || Deno.env.get('SUPABASE_URL') || ''
}

function exposeSignedUrl(signedUrl: string, req: Request) {
  const origin = externalOrigin(req)
  if (!origin) return signedUrl
  const internal = new URL(signedUrl)
  const external = new URL(origin)
  internal.protocol = external.protocol
  internal.host = external.host
  return internal.toString()
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Metodo non consentito' }, 405)
  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return json({ error: 'Non autorizzato' }, 401)
  const { userId } = await req.json()
  const userDb = userClient(authHeader)
  const logged = await userDb.rpc('admin_log_kyc_view', { p_user_id: userId })
  if (logged.error) return json({ error: publicErrorMessage(logged.error.message, 'Accesso ai documenti non riuscito.') }, 403)
  const db = adminClient()
  const { data, error } = await db.from('kyc_documents').select('id,document_type,storage_path,captured_at,content_type,byte_size').eq('user_id', userId)
  if (error) return json({ error: publicErrorMessage(error.message, 'Lettura documenti non riuscita.') }, 500)
  const documents = await Promise.all((data ?? []).map(async row => {
    const signed = await db.storage.from('kyc-documents').createSignedUrl(row.storage_path, 300)
    if (signed.error || !signed.data?.signedUrl) {
      return {
        id: row.id,
        documentType: row.document_type,
        capturedAt: row.captured_at,
        storagePath: row.storage_path,
        contentType: row.content_type,
        byteSize: row.byte_size,
        signedUrl: '',
        error: publicErrorMessage(signed.error?.message, 'Link documento non disponibile.'),
      }
    }
    return {
      id: row.id,
      documentType: row.document_type,
      capturedAt: row.captured_at,
      storagePath: row.storage_path,
      contentType: row.content_type,
      byteSize: row.byte_size,
      signedUrl: exposeSignedUrl(signed.data.signedUrl, req),
      error: '',
    }
  }))
  return json({ documents, expiresInSeconds: 300 }, 200, {
    'Cache-Control': 'no-store, private, max-age=0',
    Pragma: 'no-cache',
  })
})
