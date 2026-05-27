import { adminClient, corsHeaders, json, publicErrorMessage, userClient } from '../_shared/clients.ts'

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Metodo non consentito' }, 405)
  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return json({ error: 'Non autorizzato' }, 401)

  const userDb = userClient(authHeader)
  const { data: { user }, error: authError } = await userDb.auth.getUser()
  if (authError || !user) return json({ error: 'Non autorizzato' }, 401)
  const { data: isAdmin, error: adminError } = await userDb.rpc('is_admin')
  if (adminError || !isAdmin) return json({ error: 'Non sei autorizzato a eliminare utenti.' }, 403)

  const { userId } = await req.json()
  if (typeof userId !== 'string' || !userId) return json({ error: 'Utente non valido.' }, 400)

  const db = adminClient()
  const { data: target, error: targetError } = await db.from('profiles')
    .select('id,role')
    .eq('id', userId)
    .maybeSingle()
  if (targetError) return json({ error: publicErrorMessage(targetError.message, 'Eliminazione account non riuscita.') }, 500)
  if (!target) return json({ error: 'Utente non trovato.' }, 404)
  if (target.role === 'admin') return json({ error: 'Un amministratore non può essere eliminato.' }, 403)

  const prepared = await userDb.rpc('admin_prepare_account_deletion', { p_user_id: userId })
  if (prepared.error) return json({ error: publicErrorMessage(prepared.error.message, 'Eliminazione account non riuscita.') }, 403)

  const documents = await db.from('kyc_documents').select('storage_path').eq('user_id', userId)
  if (documents.error) return json({ error: publicErrorMessage(documents.error.message, 'Eliminazione documenti non riuscita.') }, 500)
  const paths = (documents.data ?? []).map(document => document.storage_path).filter(Boolean)
  if (paths.length) {
    const removed = await db.storage.from('kyc-documents').remove(paths)
    if (removed.error) return json({ error: publicErrorMessage(removed.error.message, 'Eliminazione documenti non riuscita.') }, 500)
  }

  const deleted = await db.auth.admin.deleteUser(userId)
  if (deleted.error) return json({ error: publicErrorMessage(deleted.error.message, 'Eliminazione account non riuscita.') }, 500)
  return json({ deleted: true })
})
