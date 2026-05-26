import { adminClient, corsHeaders, json, userClient } from '../_shared/clients.ts'

const documentTypes = new Set(['document_front', 'document_back', 'selfie_with_document'])
const mimeTypes = new Set(['image/jpeg', 'image/png', 'image/webp'])
const maximumBytes = 10 * 1024 * 1024

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Metodo non consentito' }, 405)
  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return json({ error: 'Non autorizzato' }, 401)
  const session = userClient(authHeader)
  const { data: { user }, error: authError } = await session.auth.getUser()
  if (authError || !user) return json({ error: 'Non autorizzato' }, 401)
  const access = await session.rpc('get_my_kyc_status')
  if (access.error) return json({ error: access.error.message }, 403)

  const form = await req.formData()
  const documentType = String(form.get('documentType') ?? '')
  const capturedAt = String(form.get('capturedAt') ?? '')
  const capture = form.get('capture')
  if (!documentTypes.has(documentType) || !(capture instanceof File)) return json({ error: 'Acquisizione non valida' }, 400)
  if (!mimeTypes.has(capture.type) || capture.size > maximumBytes || capture.size === 0) return json({ error: 'File immagine non valido' }, 400)

  const db = adminClient()
  const currentCase = await db.from('kyc_cases').select('status').eq('user_id', user.id).maybeSingle()
  if (currentCase.data?.status === 'approved') return json({ error: 'KYC già approvata.' }, 409)
  const previous = await db.from('kyc_documents').select('storage_path').eq('user_id', user.id).eq('document_type', documentType).maybeSingle()
  const path = `${user.id}/${documentType}-${crypto.randomUUID()}.jpg`
  const upload = await db.storage.from('kyc-documents').upload(path, capture, { contentType: capture.type, upsert: false })
  if (upload.error) return json({ error: upload.error.message }, 500)
  const saved = await db.from('kyc_documents').upsert({
    user_id: user.id,
    document_type: documentType,
    storage_path: path,
    content_type: capture.type,
    byte_size: capture.size,
    captured_at: capturedAt || new Date().toISOString(),
  }, { onConflict: 'user_id,document_type' })
  if (saved.error) {
    await db.storage.from('kyc-documents').remove([path])
    return json({ error: saved.error.message }, 500)
  }
  if (previous.data?.storage_path) await db.storage.from('kyc-documents').remove([previous.data.storage_path])
  await db.from('kyc_cases').upsert({ user_id: user.id, status: 'collecting', rejection_reason: null }, { onConflict: 'user_id' })
  return json({ documentType, uploaded: true })
})
