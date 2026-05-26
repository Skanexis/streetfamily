import { adminClient, corsHeaders, json, publicErrorMessage, userClient } from '../_shared/clients.ts'

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
  const { data, error } = await db.from('kyc_documents').select('id,document_type,storage_path,captured_at').eq('user_id', userId)
  if (error) return json({ error: publicErrorMessage(error.message, 'Lettura documenti non riuscita.') }, 500)
  const documents = await Promise.all((data ?? []).map(async row => {
    const signed = await db.storage.from('kyc-documents').createSignedUrl(row.storage_path, 60)
    return { id: row.id, documentType: row.document_type, capturedAt: row.captured_at, signedUrl: signed.data?.signedUrl }
  }))
  return json({ documents, expiresInSeconds: 60 }, 200, {
    'Cache-Control': 'no-store, private, max-age=0',
    Pragma: 'no-cache',
  })
})
