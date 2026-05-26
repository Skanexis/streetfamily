import { adminClient, json } from '../_shared/clients.ts'

Deno.serve(async req => {
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const expected = Deno.env.get('KYC_PURGE_SECRET')
  if (!expected || req.headers.get('X-Kyc-Purge-Secret') !== expected) return json({ error: 'Unauthorized' }, 401)

  const db = adminClient()
  const expired = await db.from('kyc_cases')
    .select('user_id')
    .eq('status', 'approved')
    .not('retain_until', 'is', null)
    .lt('retain_until', new Date().toISOString())
  if (expired.error) return json({ error: expired.error.message }, 500)

  let purged = 0
  for (const item of expired.data ?? []) {
    const documents = await db.from('kyc_documents').select('storage_path').eq('user_id', item.user_id)
    if (documents.error) continue
    const paths = (documents.data ?? []).map(row => row.storage_path)
    if (paths.length) await db.storage.from('kyc-documents').remove(paths)
    await db.from('kyc_documents').delete().eq('user_id', item.user_id)
    await db.from('kyc_cases').update({ documents_purged_at: new Date().toISOString() }).eq('user_id', item.user_id)
    purged += paths.length
  }
  return json({ expiredCases: expired.data?.length ?? 0, purgedDocuments: purged })
})
