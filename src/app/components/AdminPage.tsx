import { useEffect, useState, type FormEvent, type ReactNode } from 'react'
import { ShieldCheck, Package, Users, Gamepad2, ClipboardList, Settings, Megaphone, MessageSquare } from 'lucide-react'
import { useAuth } from '../auth/AuthProvider'
import { adminAdjustWallet, getAdminDashboard, getAdminKycDocuments, reviewKyc } from '../lib/api'
import { requireSupabase } from '../lib/supabase'
import type { Broadcast, DashboardData, KycReviewDocument } from '../data'

type Tab = 'catalog' | 'broadcasts' | 'users' | 'orders' | 'economy' | 'feedback' | 'settings'
type Row = Record<string, any>

export function AdminPage() {
  const auth = useAuth()
  const [tab, setTab] = useState<Tab>('catalog')
  const [dashboard, setDashboard] = useState<DashboardData | null>(null)
  const [products, setProducts] = useState<Row[]>([])
  const [categories, setCategories] = useState<Row[]>([])
  const [profiles, setProfiles] = useState<Row[]>([])
  const [orders, setOrders] = useState<Row[]>([])
  const [games, setGames] = useState<Row[]>([])
  const [locations, setLocations] = useState<Row[]>([])
  const [allowlist, setAllowlist] = useState<Row[]>([])
  const [settings, setSettings] = useState<Row[]>([])
  const [broadcasts, setBroadcasts] = useState<Broadcast[]>([])
  const [feedback, setFeedback] = useState<Row[]>([])
  const [rewardOptions, setRewardOptions] = useState<Row[]>([])
  const [tokenTiers, setTokenTiers] = useState<Row[]>([])
  const [error, setError] = useState('')

  const load = async () => {
    if (!auth.isAdminMfa) return
    try {
      const db = requireSupabase()
      const [summary, productResult, categoryResult, profileResult, orderResult, gameResult, locationResult, allowlistResult, settingsResult, broadcastResult, feedbackResult, optionsResult, tiersResult] = await Promise.all([
        getAdminDashboard(),
        db.from('products').select('id,name,badge,published,featured,categories(name),product_variants(id,label,price,unit_amount,token_award,inventory_status(available)),product_media(id,url,storage_path,media_type,upload_status,sort_order)').order('name'),
        db.from('categories').select('*').order('sort_order'),
        db.from('profiles').select('id,username,telegram_subject,role,blocked,wallet_balances(points,xp,spin_tickets),kyc_cases(status,submitted_at,rejection_reason,retain_until),orders(status),feedback(status)').order('created_at', { ascending: false }),
        db.from('orders').select('id,display_id,status,total,total_units,tokens_reserved,scenario_type,scenario_city,scenario_street,points_awarded,xp_awarded,created_at,profiles(username)').order('created_at', { ascending: false }),
        db.from('game_configs').select('*').order('game_type'),
        db.from('service_areas').select('*').order('sort_order'),
        db.from('staging_allowlist').select('*').order('created_at', { ascending: false }),
        db.from('app_settings').select('*'),
        db.from('broadcasts').select('id,kind,title,message,product_id,status,published_at,created_at').order('created_at', { ascending: false }),
        db.from('feedback').select('id,rating,message,status,created_at,profiles(username),orders(display_id)').order('created_at', { ascending: false }),
        db.from('game_reward_options').select('*').eq('game_type', 'spin').order('id'),
        db.from('token_reward_tiers').select('*').order('minimum_units'),
      ])
      for (const result of [productResult, categoryResult, profileResult, orderResult, gameResult, locationResult, allowlistResult, settingsResult, broadcastResult, feedbackResult, optionsResult, tiersResult]) {
        if (result.error) throw new Error(result.error.message)
      }
      setDashboard(summary)
      setProducts(productResult.data ?? [])
      setCategories(categoryResult.data ?? [])
      setProfiles(profileResult.data ?? [])
      setOrders(orderResult.data ?? [])
      setGames(gameResult.data ?? [])
      setLocations(locationResult.data ?? [])
      setAllowlist(allowlistResult.data ?? [])
      setSettings(settingsResult.data ?? [])
      setFeedback(feedbackResult.data ?? [])
      setRewardOptions(optionsResult.data ?? [])
      setTokenTiers(tiersResult.data ?? [])
      setBroadcasts((broadcastResult.data ?? []).map((broadcast: Row) => ({
        id: broadcast.id,
        kind: broadcast.kind,
        title: broadcast.title,
        message: broadcast.message,
        productId: broadcast.product_id,
        status: broadcast.status,
        publishedAt: broadcast.published_at,
        createdAt: broadcast.created_at,
      })))
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Errore admin.')
    }
  }

  useEffect(() => { load() }, [auth.isAdminMfa])

  if (!auth.isAdminMfa) {
    return (
      <AdminFrame>
        <MfaGate onVerified={auth.refreshProfile} />
      </AdminFrame>
    )
  }

  return (
    <AdminFrame>
      <div className="flex justify-between items-center mb-7">
        <div><div style={{ color: '#D7FE55', fontFamily: 'Orbitron', fontSize: 11 }}>ADMIN / TEST MODE</div><h1 style={heading}>Control Center</h1></div>
        <button style={smallButton} onClick={load}>Aggiorna</button>
      </div>
      {error && <div className="p-3 mb-5 rounded-xl" style={{ color: '#EF4444', background: 'rgba(239,68,68,.12)' }}>{error}</div>}
      {dashboard && (
        <div className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-7">
          <Metric label="Allowlist" value={dashboard.allowlistedUsers} />
          <Metric label="Richieste inviate" value={dashboard.submittedOrders} />
          <Metric label="Partite" value={dashboard.gamePlays} />
          <Metric label="Gettoni emessi" value={dashboard.issuedPoints} />
        </div>
      )}
      <div className="flex flex-wrap gap-2 mb-6">
        {([
          ['catalog', Package, 'Catalogo'],
          ['broadcasts', Megaphone, 'Broadcast'],
          ['users', Users, 'Utenti'],
          ['orders', ClipboardList, 'Richieste'],
          ['economy', Gamepad2, 'Economia'],
          ['feedback', MessageSquare, 'Feedback'],
          ['settings', Settings, 'Impostazioni'],
        ] as const).map(([id, Icon, label]) => (
          <button key={id} onClick={() => setTab(id)} style={{ ...smallButton, background: tab === id ? '#7E9CA8' : '#11181B' }}><Icon size={15} /> {label}</button>
        ))}
      </div>
      {tab === 'catalog' && <CatalogAdmin products={products} categories={categories} reload={load} />}
      {tab === 'broadcasts' && <BroadcastAdmin broadcasts={broadcasts} reload={load} />}
      {tab === 'users' && <UsersAdmin profiles={profiles} allowlist={allowlist} reload={load} />}
      {tab === 'orders' && <OrdersAdmin orders={orders} reload={load} />}
      {tab === 'economy' && <EconomyAdmin games={games} options={rewardOptions} reload={load} />}
      {tab === 'feedback' && <FeedbackAdmin feedback={feedback} reload={load} />}
      {tab === 'settings' && <SettingsAdmin locations={locations} settings={settings} tokenTiers={tokenTiers} reload={load} />}
    </AdminFrame>
  )
}

function MfaGate({ onVerified }: { onVerified: () => Promise<void> }) {
  const [factorId, setFactorId] = useState('')
  const [qr, setQr] = useState('')
  const [code, setCode] = useState('')
  const [message, setMessage] = useState('')
  const prepare = async () => {
    const db = requireSupabase()
    const factors = await db.auth.mfa.listFactors()
    const existing = factors.data?.totp.find(factor => factor.status === 'verified')
    if (existing) {
      setFactorId(existing.id)
      setMessage('Inserisci il codice della tua app autenticatore.')
      return
    }
    const enrollment = await db.auth.mfa.enroll({ factorType: 'totp', friendlyName: 'Street Family Admin' })
    if (enrollment.error) throw new Error(enrollment.error.message)
    setFactorId(enrollment.data.id)
    setQr(enrollment.data.totp.qr_code)
    setMessage('Scansiona il QR e inserisci il primo codice.')
  }
  const verify = async (event: FormEvent) => {
    event.preventDefault()
    const { error } = await requireSupabase().auth.mfa.challengeAndVerify({ factorId, code })
    if (error) {
      setMessage(error.message)
      return
    }
    await onVerified()
  }
  useEffect(() => { prepare().catch(error => setMessage(error.message)) }, [])
  return (
    <div className="p-8 rounded-2xl max-w-lg" style={panel}>
      <ShieldCheck size={38} style={{ color: '#F59E0B', marginBottom: 12 }} />
      <h1 style={heading}>MFA obbligatoria</h1>
      <p style={muted}>La dashboard amministrativa richiede assurance level `aal2`.</p>
      {qr && <img src={qr} alt="QR TOTP per MFA admin" className="my-5 rounded-xl" style={{ width: 190, height: 190 }} />}
      {message && <p style={{ ...muted, margin: '15px 0' }}>{message}</p>}
      {factorId && (
        <form onSubmit={verify} className="flex gap-2">
          <input required inputMode="numeric" value={code} onChange={event => setCode(event.target.value)} placeholder="Codice MFA" style={input} />
          <button style={primary}>Verifica</button>
        </form>
      )}
    </div>
  )
}

function CatalogAdmin({ products, categories, reload }: { products: Row[]; categories: Row[]; reload: () => Promise<void> }) {
  const toggle = async (product: Row, key: 'published' | 'featured') => {
    const { error } = await requireSupabase().from('products').update({ [key]: !product[key] }).eq('id', product.id)
    if (error) throw new Error(error.message)
    await reload()
  }
  const addCategory = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const name = String(new FormData(event.currentTarget).get('name'))
    const { error } = await requireSupabase().from('categories').insert({ name, slug: name.toLowerCase().replace(/\s+/g, '-') })
    if (error) throw new Error(error.message)
    event.currentTarget.reset()
    await reload()
  }
  const addProduct = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const values = new FormData(event.currentTarget)
    const db = requireSupabase()
    const name = String(values.get('name'))
    const { error } = await db.rpc('admin_create_demo_product', {
      p_name: name,
      p_category_id: values.get('category'),
      p_prices: Object.fromEntries([50, 100, 300, 500, 1000].map(unit => [unit, Number(values.get(`price${unit}`))])),
      p_announce: values.get('announce') === 'on',
    })
    if (error) throw new Error(error.message)
    event.currentTarget.reset()
    await reload()
  }
  const setPrice = async (variantId: string, price: number) => {
    const { error } = await requireSupabase().from('product_variants').update({ price }).eq('id', variantId)
    if (error) throw new Error(error.message)
    await reload()
  }
  const setAvailability = async (variant: Row) => {
    const active = variant.inventory_status?.available ?? false
    const { error } = await requireSupabase().from('inventory_status').update({ available: !active }).eq('variant_id', variant.id)
    if (error) throw new Error(error.message)
    await reload()
  }
  return (
    <Section title="Catalogo demo" note="Soltanto pacchetti in units; nessuna vendita o consegna reale.">
      <form onSubmit={addCategory} className="flex gap-2 mb-4">
        <input name="name" required placeholder="Nuova categoria" style={input} />
        <button style={primary}>Categoria</button>
      </form>
      <form onSubmit={addProduct} className="grid md:grid-cols-4 gap-2 mb-6">
        <input name="name" required placeholder="Demo item" style={input} />
        <select name="category" required style={input}><option value="">Categoria</option>{categories.map(category => <option value={category.id} key={category.id}>{category.name}</option>)}</select>
        {[50, 100, 300, 500, 1000].map(unit => <input key={unit} name={`price${unit}`} type="number" min="0" required placeholder={`EUR ${unit} units`} style={input} />)}
        <button style={primary}>Crea non pubblicato</button>
        <label className="md:col-span-4 flex items-center gap-2" style={muted}>
          <input type="checkbox" name="announce" />
          Crea news nuovo prodotto come bozza (pubblicala dopo media e pubblicazione catalogo)
        </label>
      </form>
      {products.map(product => (
        <div key={product.id} className="p-3 mb-2 rounded-xl" style={{ background: 'rgba(245,245,245,.035)' }}>
          <div className="flex gap-2 items-center mb-3">
            <div className="flex-1"><strong>{product.name}</strong><div style={muted}>{product.categories?.name} {product.badge ? `/ ${product.badge}` : ''}</div></div>
            <Toggle label="Featured" active={product.featured} onClick={() => toggle(product, 'featured')} />
            <Toggle label="Pubblicato" active={product.published} onClick={() => toggle(product, 'published')} />
          </div>
          <div className="flex gap-2">
            {(product.product_variants ?? []).filter((variant: Row) => variant.unit_amount).map((variant: Row) => (
              <div key={variant.id} className="flex gap-2 items-center">
                <span>{variant.unit_amount} units / +{variant.token_award}</span>
                <input type="number" min="0" defaultValue={variant.price} onBlur={event => setPrice(variant.id, Number(event.target.value))} style={{ ...input, width: 78 }} />
                <Toggle label="Stock" active={variant.inventory_status?.available ?? false} onClick={() => setAvailability(variant)} />
              </div>
            ))}
          </div>
          <MediaUploader product={product} reload={reload} />
        </div>
      ))}
    </Section>
  )
}

function BroadcastAdmin({ broadcasts, reload }: { broadcasts: Broadcast[]; reload: () => Promise<void> }) {
  const [message, setMessage] = useState('')
  const create = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    setMessage('')
    const values = new FormData(event.currentTarget)
    const { error } = await requireSupabase().rpc('admin_create_broadcast', {
      p_title: values.get('title'),
      p_message: values.get('message'),
      p_publish: values.get('publish') === 'on',
    })
    if (error) {
      setMessage(error.message)
      return
    }
    event.currentTarget.reset()
    await reload()
  }
  const setStatus = async (broadcast: Broadcast, status: Broadcast['status']) => {
    setMessage('')
    const updates = status === 'published'
      ? { status, published_at: broadcast.publishedAt ?? new Date().toISOString() }
      : { status }
    const { error } = await requireSupabase().from('broadcasts').update(updates).eq('id', broadcast.id)
    if (error) {
      setMessage(error.message)
      return
    }
    await reload()
  }
  return (
    <Section title="Broadcast staging" note="Gli annunci pubblicati appaiono nel centro notifiche degli utenti ammessi. Le news prodotto vengono create come bozze.">
      <form onSubmit={create} className="grid md:grid-cols-2 gap-2 mb-6">
        <input name="title" maxLength={120} required placeholder="Titolo annuncio" style={input} />
        <input name="message" maxLength={500} required placeholder="Messaggio" style={input} />
        <label className="flex items-center gap-2" style={muted}><input type="checkbox" name="publish" /> Pubblica subito</label>
        <button style={primary}>Crea broadcast</button>
      </form>
      {message && <p className="mb-4" style={{ color: '#EF4444' }}>{message}</p>}
      {broadcasts.map(broadcast => (
        <div key={broadcast.id} style={row}>
          <div className="flex-1">
            <strong>{broadcast.title}</strong>
            <div style={muted}>{broadcast.kind} / {broadcast.status} / {new Date(broadcast.createdAt).toLocaleDateString('it-IT')}</div>
            <div style={{ ...muted, marginTop: 4 }}>{broadcast.message}</div>
          </div>
          {broadcast.status !== 'published' && <button style={smallButton} onClick={() => setStatus(broadcast, 'published')}>Pubblica</button>}
          {broadcast.status !== 'archived' && <button style={smallButton} onClick={() => setStatus(broadcast, 'archived')}>Archivia</button>}
        </div>
      ))}
    </Section>
  )
}

function MediaUploader({ product, reload }: { product: Row; reload: () => Promise<void> }) {
  const [uploads, setUploads] = useState<Record<string, { progress: number; status: string }>>({})
  const [uploadError, setUploadError] = useState('')
  const existing = product.product_media ?? []
  const imageCount = existing.filter((media: Row) => media.media_type === 'image' && media.upload_status !== 'failed').length
  const videoCount = existing.filter((media: Row) => media.media_type === 'video' && media.upload_status !== 'failed').length

  const selectFiles = async (event: React.ChangeEvent<HTMLInputElement>) => {
    try {
      setUploadError('')
      const files = Array.from(event.target.files ?? [])
      let images = imageCount
      let videos = videoCount
      for (const file of files) {
        const kind = file.type.startsWith('image/') ? 'image' : file.type.startsWith('video/') ? 'video' : null
        if (!kind) throw new Error('Sono accettati solo file immagine o video.')
        if (kind === 'image' && ++images > 5) throw new Error('Massimo 5 foto per prodotto.')
        if (kind === 'video' && ++videos > 3) throw new Error('Massimo 3 video per prodotto.')
        await uploadFile(file, kind)
      }
      await reload()
    } catch (caught) {
      setUploadError(caught instanceof Error ? caught.message : 'Upload non riuscito.')
      await reload()
    } finally {
      event.target.value = ''
    }
  }

  const uploadFile = async (file: File, mediaType: 'image' | 'video') => {
    const db = requireSupabase()
    const storagePath = `${product.id}/${crypto.randomUUID()}-${file.name.replace(/[^a-zA-Z0-9._-]/g, '_')}`
    const inserted = await db.from('product_media').insert({
      product_id: product.id,
      url: null,
      storage_path: storagePath,
      media_type: mediaType,
      upload_status: 'uploading',
      alt: `${product.name} ${mediaType}`,
      sort_order: existing.length,
    }).select('id').single()
    if (inserted.error) throw new Error(inserted.error.message)
    const mediaId = inserted.data.id
    setUploads(current => ({ ...current, [mediaId]: { progress: 0, status: 'uploading' } }))
    try {
      await xhrStorageUpload(storagePath, file, progress => {
        setUploads(current => ({ ...current, [mediaId]: { progress, status: 'uploading' } }))
      })
      const ready = await db.from('product_media').update({ upload_status: 'ready' }).eq('id', mediaId)
      if (ready.error) throw new Error(ready.error.message)
      setUploads(current => ({ ...current, [mediaId]: { progress: 100, status: 'ready' } }))
    } catch (caught) {
      await db.from('product_media').update({ upload_status: 'failed' }).eq('id', mediaId)
      setUploads(current => ({ ...current, [mediaId]: { progress: 0, status: 'failed' } }))
      throw caught
    }
  }

  return (
    <div className="mt-3 pt-3" style={{ borderTop: '1px solid rgba(245,245,245,.08)' }}>
      <div className="flex justify-between items-center mb-2">
        <span style={muted}>Media: {imageCount}/5 foto, {videoCount}/3 video</span>
        <label style={{ ...smallButton, cursor: 'pointer' }}>
          Carica file
          <input hidden type="file" multiple accept="image/*,video/*" onChange={selectFiles} />
        </label>
      </div>
      {existing.map((media: Row) => {
        const status = uploads[media.id]?.status ?? media.upload_status
        const progress = uploads[media.id]?.progress ?? 0
        return (
          <div key={media.id} className="flex gap-2 items-center mb-1" style={{ fontSize: 12 }}>
            <span className="flex-1">{media.media_type} {media.storage_path?.split('/').pop() ?? 'seed media'}</span>
            {status === 'uploading' && <span style={{ color: '#7E9CA8' }}>Uploading {progress}%</span>}
            {status === 'ready' && <span style={{ color: '#D7FE55' }}>Ready</span>}
            {status === 'failed' && <span style={{ color: '#EF4444' }}>Failed</span>}
          </div>
        )
      })}
      {Object.entries(uploads).filter(([id]) => !existing.some((media: Row) => media.id === id)).map(([id, state]) => (
        <div key={id} style={{ color: '#7E9CA8', fontSize: 12 }}>Uploading {state.progress}%</div>
      ))}
      {uploadError && <div style={{ color: '#EF4444', fontSize: 12 }}>{uploadError}</div>}
    </div>
  )
}

async function xhrStorageUpload(path: string, file: File, onProgress: (value: number) => void) {
  const { data } = await requireSupabase().auth.getSession()
  const endpoint = `${import.meta.env.VITE_SUPABASE_URL}/storage/v1/object/product-media/${path.split('/').map(encodeURIComponent).join('/')}`
  return new Promise<void>((resolve, reject) => {
    const request = new XMLHttpRequest()
    request.open('POST', endpoint)
    request.setRequestHeader('Authorization', `Bearer ${data.session?.access_token}`)
    request.setRequestHeader('apikey', import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY)
    request.setRequestHeader('Content-Type', file.type)
    request.setRequestHeader('x-upsert', 'false')
    request.upload.onprogress = progress => progress.lengthComputable && onProgress(Math.round(progress.loaded / progress.total * 100))
    request.onload = () => request.status >= 200 && request.status < 300 ? resolve() : reject(new Error('Upload Storage non riuscito.'))
    request.onerror = () => reject(new Error('Upload Storage non riuscito.'))
    request.send(file)
  })
}

function UsersAdmin({ profiles, allowlist, reload }: { profiles: Row[]; allowlist: Row[]; reload: () => Promise<void> }) {
  const [query, setQuery] = useState('')
  const [selected, setSelected] = useState('')
  const [points, setPoints] = useState(0)
  const [xp, setXp] = useState(0)
  const [reason, setReason] = useState('')
  const [reviewUser, setReviewUser] = useState<Row | null>(null)
  const [documents, setDocuments] = useState<KycReviewDocument[]>([])
  const [kycError, setKycError] = useState('')
  const visibleProfiles = profiles.filter(profile => `${profile.username} ${profile.telegram_subject}`.toLowerCase().includes(query.toLowerCase()))
  const adjust = async (event: FormEvent) => {
    event.preventDefault()
    await adminAdjustWallet(selected, points, xp, reason)
    setReason('')
    await reload()
  }
  const addAccess = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const values = new FormData(event.currentTarget)
    const { error } = await requireSupabase().from('staging_allowlist').insert({
      telegram_subject: values.get('subject'),
      role: values.get('role'),
      note: 'Creato da admin UI',
    })
    if (error) throw new Error(error.message)
    event.currentTarget.reset()
    await reload()
  }
  const openKyc = async (profile: Row) => {
    setKycError('')
    setReviewUser(profile)
    try {
      setDocuments(await getAdminKycDocuments(profile.id))
    } catch (caught) {
      setKycError(caught instanceof Error ? caught.message : 'Accesso documenti negato.')
    }
  }
  const decide = async (decision: 'approved' | 'rejected') => {
    if (!reviewUser) return
    const rejectionReason = decision === 'rejected'
      ? window.prompt('Motivo del rifiuto (obbligatorio):', '') ?? ''
      : ''
    if (decision === 'rejected' && rejectionReason.trim().length < 4) return
    try {
      await reviewKyc(reviewUser.id, decision, rejectionReason)
      setReviewUser(null)
      setDocuments([])
      await reload()
    } catch (caught) {
      setKycError(caught instanceof Error ? caught.message : 'Decisione non salvata.')
    }
  }
  return (
    <Section title="Utenti e wallet" note="Contatti Telegram, KYC e correzioni gettoni sono tracciati nell'audit log.">
      <form onSubmit={addAccess} className="mb-5 flex gap-2">
        <input name="subject" required placeholder="Telegram numeric user ID" style={input} />
        <select name="role" style={input}><option value="user">user</option><option value="admin">admin</option></select>
        <button style={primary}>Allowlist</button>
      </form>
      {allowlist.map(entry => <div key={entry.telegram_subject} style={row}><span className="flex-1">{entry.telegram_subject}</span><span>{entry.role} / {entry.enabled ? 'enabled' : 'blocked'}</span></div>)}
      <h3 className="mt-5 mb-3">Profili registrati</h3>
      <input value={query} onChange={event => setQuery(event.target.value)} placeholder="Cerca username o Telegram ID" style={{ ...input, width: '100%', marginBottom: 12 }} />
      {visibleProfiles.map(profile => (
        <div key={profile.id} style={row}>
          <div className="flex-1">
            <strong>@{profile.username}</strong>
            <div style={muted}>{profile.role} / {profile.telegram_subject}</div>
            <div style={muted}>
              {(profile.orders ?? []).filter((order: Row) => order.status === 'completed').length} completed / {(profile.feedback ?? []).length} feedback
              {profile.kyc_cases?.retain_until ? ` / documenti fino a ${new Date(profile.kyc_cases.retain_until).toLocaleDateString('it-IT')}` : ''}
            </div>
          </div>
          <span style={{ color: profile.kyc_cases?.status === 'approved' ? '#D7FE55' : '#F59E0B' }}>KYC: {profile.kyc_cases?.status ?? 'not_started'}</span>
          {profile.kyc_cases?.status && profile.kyc_cases.status !== 'not_started' && <button style={smallButton} onClick={() => openKyc(profile)}>Documenti</button>}
          <span>{profile.wallet_balances?.points ?? 0} gettoni / {profile.wallet_balances?.xp ?? 0} XP / {profile.wallet_balances?.spin_tickets ?? 0} ticket</span>
        </div>
      ))}
      <form onSubmit={adjust} className="mt-5 grid md:grid-cols-4 gap-2">
        <select required value={selected} onChange={e => setSelected(e.target.value)} style={input}><option value="">Utente</option>{profiles.map(p => <option key={p.id} value={p.id}>@{p.username}</option>)}</select>
        <input type="number" value={points} onChange={e => setPoints(Number(e.target.value))} placeholder="Gettoni +/-" style={input} />
        <input required value={reason} onChange={e => setReason(e.target.value)} placeholder="Motivo audit" style={input} />
        <button style={primary}>Registra</button>
      </form>
      {reviewUser && (
        <div className="fixed inset-0 z-50 p-5 flex items-center justify-center" style={{ background: 'rgba(0,0,0,.85)' }}>
          <div className="p-5 rounded-2xl max-w-4xl w-full max-h-[90vh] overflow-y-auto" style={panel}>
            <div className="flex justify-between mb-4">
              <div>
                <h2 style={{ ...heading, fontSize: 22 }}>KYC @{reviewUser.username}</h2>
                <p style={muted}>Link temporanei validi 60 secondi. Visualizzazione registrata nell'audit log.</p>
              </div>
              <button style={smallButton} onClick={() => { setReviewUser(null); setDocuments([]) }}>Chiudi</button>
            </div>
            {kycError && <p style={{ color: '#EF4444' }}>{kycError}</p>}
            <div className="grid md:grid-cols-3 gap-3 mb-5">
              {documents.map(document => (
                <div key={document.id}>
                  <div style={{ ...muted, marginBottom: 6 }}>{document.documentType}</div>
                  <img src={document.signedUrl} alt={document.documentType} className="w-full rounded-xl" style={{ maxHeight: 340, objectFit: 'contain', background: '#080C0E' }} referrerPolicy="no-referrer" />
                </div>
              ))}
            </div>
            {reviewUser.kyc_cases?.status === 'submitted' && (
              <div className="flex gap-2">
                <button style={{ ...primary, background: '#10B981' }} onClick={() => decide('approved')}>Approva KYC</button>
                <button style={{ ...primary, background: '#EF4444' }} onClick={() => decide('rejected')}>Rifiuta KYC</button>
              </div>
            )}
          </div>
        </div>
      )}
    </Section>
  )
}

function OrdersAdmin({ orders, reload }: { orders: Row[]; reload: () => Promise<void> }) {
  const updateStatus = async (orderId: string, status: string) => {
    const db = requireSupabase()
    const { error } = await db.rpc('admin_update_order_status', { p_order_id: orderId, p_status: status, p_note: 'Updated from admin panel' })
    if (error) throw new Error(error.message)
    await reload()
  }
  return (
    <Section title="Richieste test" note="Questi record non attivano pagamento, spedizione o meetup.">
      {orders.map(order => (
        <div key={order.id} style={row}>
          <div className="flex-1"><strong>{order.display_id}</strong><div style={muted}>@{order.profiles?.username} / {order.total_units} units / EUR {order.total} demo / {order.scenario_type} {order.scenario_city}</div><div style={muted}>Riserva: {order.tokens_reserved} / premio completed: +{order.points_awarded} gettoni</div></div>
          <select value={order.status} onChange={event => updateStatus(order.id, event.target.value)} style={input}>
            {['submitted', 'processing', 'completed', 'cancelled'].map(status => <option key={status}>{status}</option>)}
          </select>
        </div>
      ))}
    </Section>
  )
}

function EconomyAdmin({ games, options, reload }: { games: Row[]; options: Row[]; reload: () => Promise<void> }) {
  const update = async (game: Row, changes: Row) => {
    const { error } = await requireSupabase().from('game_configs').update(changes).eq('game_type', game.game_type)
    if (error) throw new Error(error.message)
    await reload()
  }
  const updateOption = async (id: string, changes: Row) => {
    const { error } = await requireSupabase().from('game_reward_options').update(changes).eq('id', id)
    if (error) throw new Error(error.message)
    await reload()
  }
  return (
    <Section title="Ruota dei premi" note="Un ticket viene emesso ogni cinque richieste demo completate; l'estrazione avviene server-side.">
      {games.filter(game => game.game_type === 'spin').map(game => (
        <div key={game.game_type} style={row}>
          <div className="flex-1"><strong>{game.title}</strong><div style={muted}>{game.game_type}</div></div>
          <Toggle label="Attivo" active={game.active} onClick={() => update(game, { active: !game.active })} />
        </div>
      ))}
      <h3 className="my-4">Caselle configurabili</h3>
      {options.map(option => <div key={option.id} style={row}>
        <input defaultValue={option.label} onBlur={event => updateOption(option.id, { label: event.target.value })} style={{ ...input, flex: 1 }} />
        <label style={muted}>Gettoni <input type="number" min={0} defaultValue={option.points_awarded} onBlur={event => updateOption(option.id, { points_awarded: Number(event.target.value) })} style={{ ...input, width: 70 }} /></label>
        <label style={muted}>Peso <input type="number" min={1} defaultValue={option.weight} onBlur={event => updateOption(option.id, { weight: Number(event.target.value) })} style={{ ...input, width: 65 }} /></label>
        <Toggle label="Attiva" active={option.active} onClick={() => updateOption(option.id, { active: !option.active })} />
      </div>)}
    </Section>
  )
}

function FeedbackAdmin({ feedback, reload }: { feedback: Row[]; reload: () => Promise<void> }) {
  const moderate = async (id: string, status: 'published' | 'hidden') => {
    const { error } = await requireSupabase().rpc('admin_moderate_feedback', { p_feedback_id: id, p_status: status })
    if (error) throw new Error(error.message)
    await reload()
  }
  return (
    <Section title="Feedback demo" note="Solo feedback approvati vengono mostrati ai membri staging.">
      {feedback.map(item => <div key={item.id} className="p-4 mb-3" style={row}>
        <div className="flex-1">
          <strong>@{item.profiles?.username ?? 'member'} / {item.rating} stelle</strong>
          <div style={muted}>{item.orders?.display_id} / {item.status}</div>
          <p style={{ marginTop: 7 }}>{item.message}</p>
        </div>
        {item.status !== 'published' && <button style={smallButton} onClick={() => moderate(item.id, 'published')}>Pubblica</button>}
        {item.status !== 'hidden' && <button style={smallButton} onClick={() => moderate(item.id, 'hidden')}>Nascondi</button>}
      </div>)}
    </Section>
  )
}

function SettingsAdmin({ locations, settings, tokenTiers, reload }: { locations: Row[]; settings: Row[]; tokenTiers: Row[]; reload: () => Promise<void> }) {
  const retention = settings.find(setting => setting.key === 'kyc_retention')?.value ?? { approved_days: 365 }
  const rules = settings.find(setting => setting.key === 'demo_rules')?.value ?? { disclaimer: 'Ambiente demo: nessun pagamento, scambio o fulfillment reale.' }
  const links = settings.find(setting => setting.key === 'community_links')?.value ?? { instagram: '', viber: '', signal: null }
  const addLocation = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const values = new FormData(event.currentTarget)
    const scenario = String(values.get('scenario'))
    const { error } = await requireSupabase().from('service_areas').insert({
      scenario_type: scenario,
      city: values.get('city'),
      minimum_units: Number(values.get('minimum')),
      requires_street: scenario !== 'meetup',
    })
    if (error) throw new Error(error.message)
    event.currentTarget.reset()
    await reload()
  }
  const updateRetention = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const values = new FormData(event.currentTarget)
    const value = { approved_days: Number(values.get('days')) }
    if (value.approved_days < 1) throw new Error('Retention non valida')
    const { error } = await requireSupabase().from('app_settings').upsert({ key: 'kyc_retention', value })
    if (error) throw new Error(error.message)
    await reload()
  }
  const updateTier = async (minimumUnits: number, tokensAwarded: number) => {
    const { error } = await requireSupabase().rpc('admin_set_token_tier', {
      p_minimum_units: minimumUnits,
      p_tokens_awarded: tokensAwarded,
    })
    if (error) throw new Error(error.message)
    await reload()
  }
  const updatePublicInfo = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const values = new FormData(event.currentTarget)
    const db = requireSupabase()
    const results = await Promise.all([
      db.from('app_settings').upsert({ key: 'demo_rules', value: { ...rules, disclaimer: String(values.get('disclaimer')) } }),
      db.from('app_settings').upsert({ key: 'community_links', value: {
        instagram: String(values.get('instagram')), viber: String(values.get('viber')),
        signal: String(values.get('signal') ?? '').trim() || null,
      } }),
    ])
    const error = results.find(result => result.error)?.error
    if (error) throw new Error(error.message)
    await reload()
  }
  return (
    <Section title="Scenari e privacy" note="Tutte le location sono campi demo; non devono descrivere esecuzioni reali.">
      <form onSubmit={updatePublicInfo} className="grid gap-2 mb-6">
        <h3>Regolamento e community links</h3>
        <input name="disclaimer" required defaultValue={rules.disclaimer} placeholder="Disclaimer demo" style={input} />
        <input name="instagram" defaultValue={links.instagram} placeholder="Instagram news URL" style={input} />
        <input name="viber" defaultValue={links.viber} placeholder="Viber news URL" style={input} />
        <input name="signal" defaultValue={links.signal ?? ''} placeholder="Signal URL (opzionale)" style={input} />
        <button style={primary}>Salva informazioni pubbliche</button>
      </form>
      <form onSubmit={updateRetention} className="flex gap-2 mb-5 items-center">
        <label>KYC retention giorni <input name="days" type="number" min="1" defaultValue={retention.approved_days} style={{ ...input, width: 90 }} /></label>
        <button style={primary}>Salva retention</button>
      </form>
      <h3 className="mb-3">Gettoni per scenario completato</h3>
      <div className="flex flex-wrap gap-3 mb-6">
        {tokenTiers.map(tier => <label key={tier.minimum_units} style={muted}>{tier.minimum_units}+ units
          <input type="number" min={0} max={100} defaultValue={tier.tokens_awarded} onBlur={event => updateTier(tier.minimum_units, Number(event.target.value))} style={{ ...input, width: 70, display: 'block' }} />
        </label>)}
      </div>
      {locations.map(location => <div key={location.id} style={row}><strong>{location.city}</strong><span>{location.scenario_type} / minimo {location.minimum_units} units</span></div>)}
      <form onSubmit={addLocation} className="flex flex-wrap gap-2 mt-4">
        <select name="scenario" style={input}><option value="meetup">meetup</option><option value="delivery_zone">delivery_zone</option><option value="delivery_italia">delivery_italia</option></select>
        <input name="city" required placeholder="Citta demo" style={input} />
        <input name="minimum" type="number" min="1" required placeholder="Minimum units" style={input} />
        <button style={primary}>Aggiungi</button>
      </form>
    </Section>
  )
}

function AdminFrame({ children }: { children: ReactNode }) {
  return <div style={{ minHeight: '100vh', padding: '120px 20px 40px', background: '#080C0E', color: '#F5F5F5' }}><div className="max-w-6xl mx-auto">{children}</div></div>
}
function Section({ title, note, children }: { title: string; note: string; children: ReactNode }) {
  return <section className="p-5 rounded-2xl" style={panel}><h2 style={{ ...heading, fontSize: 21 }}>{title}</h2><p style={{ ...muted, marginBottom: 18 }}>{note}</p>{children}</section>
}
function Metric({ label, value }: { label: string; value: number }) {
  return <div className="p-4 rounded-xl" style={panel}><div style={muted}>{label}</div><div style={{ fontFamily: 'Orbitron', fontSize: 25, color: '#D7FE55' }}>{value}</div></div>
}
function Toggle({ label, active, onClick }: { label: string; active: boolean; onClick: () => void }) {
  return <button onClick={onClick} style={{ ...smallButton, color: active ? '#D7FE55' : 'rgba(245,245,245,.55)' }}>{label}: {active ? 'ON' : 'OFF'}</button>
}
const panel = { background: '#11181B', border: '1px solid rgba(126,156,168,.18)' }
const row = { display: 'flex', alignItems: 'center', gap: 12, padding: 12, marginBottom: 8, background: 'rgba(245,245,245,.035)', borderRadius: 10 }
const heading = { fontFamily: 'Space Grotesk', fontWeight: 700, fontSize: 30, color: '#F5F5F5' }
const muted = { color: 'rgba(245,245,245,.55)', fontSize: 13 }
const input = { padding: '9px 12px', background: '#080C0E', border: '1px solid rgba(245,245,245,.18)', color: '#F5F5F5', borderRadius: 8 }
const primary = { ...input, background: '#7E9CA8', fontWeight: 700 }
const smallButton = { display: 'inline-flex', alignItems: 'center', gap: 5, padding: '9px 12px', borderRadius: 8, border: '1px solid rgba(126,156,168,.25)', background: '#11181B', color: '#F5F5F5' }
