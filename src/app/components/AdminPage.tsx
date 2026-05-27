import { useEffect, useState, type FormEvent, type ReactNode } from 'react'
import { Package, Tags, Users, Gamepad2, ClipboardList, Settings, Megaphone, MessageSquare, Minus, Plus, Wallet } from 'lucide-react'
import { useSearchParams } from 'react-router-dom'
import { adminAdjustWallet, adminBroadcastAction, adminDeleteAccount, adminDeleteGameOption, adminSaveGameOptions, adminSetGameActive, adminSimulateGame, getAdminDashboard, getAdminKycDocuments, reviewKyc } from '../lib/api'
import { requireSupabase } from '../lib/supabase'
import { italianErrorMessage } from '../lib/errors'
import type { Broadcast, DashboardData, GameType, KycReviewDocument } from '../data'

type Tab = 'catalog' | 'categories' | 'broadcasts' | 'users' | 'balance' | 'orders' | 'economy' | 'feedback' | 'settings'
type Row = Record<string, any>
type NumericDraft = string | number
const orderStatusLabel: Record<string, string> = { submitted: 'Inviata', processing: 'Accettata', completed: 'Completata', cancelled: 'Rifiutata' }
const feedbackStatusLabel: Record<string, string> = { pending: 'In moderazione', published: 'Pubblicata', hidden: 'Nascosta' }
const kycStatusLabel: Record<string, string> = { not_started: 'Non iniziata', collecting: 'In raccolta', submitted: 'Inviata', approved: 'Approvata', rejected: 'Rifiutata' }
const broadcastStatusLabel: Record<string, string> = { draft: 'Bozza', published: 'Pubblicato', archived: 'Archiviato' }
const scenarioLabel: Record<string, string> = { meetup: 'MEETUP', delivery_zone: 'DELIVERY LOCALE', delivery_italia: 'DELIVERY TUTTA ITALIA', delivery: 'DELIVERY' }
const documentLabel: Record<string, string> = { document_front: 'Fronte documento', document_back: 'Retro documento', selfie_with_document: 'Selfie con documento' }

export function AdminPage() {
  const [searchParams] = useSearchParams()
  const requestedTab = searchParams.get('tab') as Tab | null
  const requestedKycUserId = searchParams.get('kyc') ?? ''
  const [tab, setTab] = useState<Tab>(requestedTab === 'users' ? 'users' : 'catalog')
  const [dashboard, setDashboard] = useState<DashboardData | null>(null)
  const [products, setProducts] = useState<Row[]>([])
  const [categories, setCategories] = useState<Row[]>([])
  const [profiles, setProfiles] = useState<Row[]>([])
  const [orders, setOrders] = useState<Row[]>([])
  const [games, setGames] = useState<Row[]>([])
  const [locations, setLocations] = useState<Row[]>([])
  const [settings, setSettings] = useState<Row[]>([])
  const [broadcasts, setBroadcasts] = useState<Broadcast[]>([])
  const [feedback, setFeedback] = useState<Row[]>([])
  const [rewardOptions, setRewardOptions] = useState<Row[]>([])
  const [tokenTiers, setTokenTiers] = useState<Row[]>([])
  const [error, setError] = useState('')

  useEffect(() => {
    if (requestedTab === 'users') setTab('users')
  }, [requestedTab])

  const load = async () => {
    try {
      const db = requireSupabase()
      const [summary, productResult, categoryResult, profileResult, orderResult, gameResult, locationResult, settingsResult, broadcastResult, feedbackResult, optionsResult, tiersResult] = await Promise.all([
        getAdminDashboard(),
        db.from('products').select('id,category_id,name,badge,published,featured,categories(name),product_variants(id,label,price,unit_amount,token_award,inventory_status(available)),product_media(id,url,storage_path,media_type,upload_status,sort_order)').order('name'),
        db.from('categories').select('*').order('sort_order'),
        db.from('profiles').select('id,username,telegram_subject,role,blocked,wallet_balances(points,xp,spin_tickets,scratch_tickets,box_tickets),kyc_cases:kyc_cases!kyc_cases_user_id_fkey(status,submitted_at,rejection_reason,retain_until),orders(status),feedback:feedback!feedback_user_id_fkey(status)').order('created_at', { ascending: false }),
        db.from('orders').select('id,display_id,status,total,total_units,tokens_reserved,scenario_type,scenario_city,scenario_street,points_awarded,xp_awarded,created_at,profiles(username)').in('status', ['submitted', 'processing']).order('created_at', { ascending: false }),
        db.from('game_configs').select('*').order('game_type'),
        db.from('service_areas').select('*').order('sort_order'),
        db.from('app_settings').select('*'),
        db.from('broadcasts').select('id,kind,title,message,product_id,status,published_at,created_at').order('created_at', { ascending: false }),
        db.from('feedback').select('id,rating,message,status,created_at,profiles:profiles!feedback_user_id_fkey(username),orders(display_id)').order('created_at', { ascending: false }),
        db.from('game_reward_options').select('*').in('game_type', ['spin', 'scratch', 'box']).order('id'),
        db.from('token_reward_tiers').select('*').order('minimum_units'),
      ])
      for (const result of [productResult, categoryResult, profileResult, orderResult, gameResult, locationResult, settingsResult, broadcastResult, feedbackResult, optionsResult, tiersResult]) {
        if (result.error) throw new Error(italianErrorMessage(result.error.message, 'Impossibile caricare il pannello amministrazione.'))
      }
      setDashboard(summary)
      setProducts(productResult.data ?? [])
      setCategories(categoryResult.data ?? [])
      setProfiles(profileResult.data ?? [])
      setOrders(orderResult.data ?? [])
      setGames(gameResult.data ?? [])
      setLocations(locationResult.data ?? [])
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
      setError(italianErrorMessage(caught, 'Impossibile caricare il pannello amministrazione.'))
    }
  }

  useEffect(() => { load() }, [])

  return (
    <AdminFrame>
      <div className="flex flex-col sm:flex-row justify-between sm:items-center gap-3 mb-7">
        <div><h1 style={heading}>Centro di controllo</h1></div>
        <button style={smallButton} onClick={load}>Aggiorna</button>
      </div>
      {error && <div className="p-3 mb-5 rounded-xl" style={{ color: '#EF4444', background: 'rgba(239,68,68,.12)' }}>{error}</div>}
      {dashboard && (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3 mb-7">
          <Metric label="Utenti autorizzati" value={dashboard.allowlistedUsers} />
          <Metric label="Richieste inviate" value={dashboard.submittedOrders} />
          <Metric label="Partite" value={dashboard.gamePlays} />
          <Metric label="Gettoni emessi" value={dashboard.issuedPoints} />
        </div>
      )}
      <div className="flex gap-2 mb-6 overflow-x-auto pb-2">
        {([
          ['catalog', Package, 'Catalogo'],
          ['categories', Tags, 'Categorie'],
          ['broadcasts', Megaphone, 'Notizie'],
          ['users', Users, 'Utenti'],
          ['balance', Wallet, 'Saldo'],
          ['orders', ClipboardList, 'Richieste'],
          ['economy', Gamepad2, 'Economia'],
          ['feedback', MessageSquare, 'Recensioni'],
          ['settings', Settings, 'Impostazioni'],
        ] as const).map(([id, Icon, label]) => (
          <button key={id} className="shrink-0" onClick={() => setTab(id)} style={{ ...smallButton, background: tab === id ? '#7E9CA8' : '#11181B' }}><Icon size={15} /> {label}</button>
        ))}
      </div>
      {tab === 'catalog' && <CatalogAdmin products={products} categories={categories} reload={load} />}
      {tab === 'categories' && <CategoriesAdmin products={products} categories={categories} reload={load} />}
      {tab === 'broadcasts' && <BroadcastAdmin broadcasts={broadcasts} reload={load} />}
      {tab === 'users' && <UsersAdmin profiles={profiles} initialKycUserId={requestedKycUserId} reload={load} />}
      {tab === 'balance' && <BalanceAdmin profiles={profiles} reload={load} />}
      {tab === 'orders' && <OrdersAdmin orders={orders} reload={load} />}
      {tab === 'economy' && <EconomyAdmin games={games} options={rewardOptions} reload={load} />}
      {tab === 'feedback' && <FeedbackAdmin feedback={feedback} reload={load} />}
      {tab === 'settings' && <SettingsAdmin locations={locations} settings={settings} tokenTiers={tokenTiers} reload={load} />}
    </AdminFrame>
  )
}

function CatalogAdmin({ products, categories, reload }: { products: Row[]; categories: Row[]; reload: () => Promise<void> }) {
  const [message, setMessage] = useState('')
  const toggle = async (product: Row, key: 'published' | 'featured') => {
    const { error } = await requireSupabase().from('products').update({ [key]: !product[key] }).eq('id', product.id)
    if (error) throw new Error(italianErrorMessage(error.message, 'Aggiornamento del prodotto non riuscito.'))
    await reload()
  }
  const addProduct = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const values = new FormData(event.currentTarget)
    const db = requireSupabase()
    const name = String(values.get('name'))
    const prices = Object.fromEntries([25, 50, 100, 300, 500, 1000].map(grams => [grams, parseOptionalInteger(String(values.get(`price${grams}`))) ?? -1]))
    if (Object.values(prices).some(price => price < 0)) {
      setMessage('Inserisci prezzi validi.')
      return
    }
    const { error } = await db.rpc('admin_create_demo_product', {
      p_name: name,
      p_category_id: values.get('category'),
      p_prices: Object.fromEntries(Object.entries(prices).map(([grams, price]) => [grams, roundPrice(price)])),
      p_announce: values.get('announce') === 'on',
    })
    if (error) throw new Error(italianErrorMessage(error.message, 'Creazione del prodotto non riuscita.'))
    event.currentTarget.reset()
    await reload()
  }
  const setPrice = async (variantId: string, price: number) => {
    const { error } = await requireSupabase().from('product_variants').update({ price: roundPrice(price) }).eq('id', variantId)
    if (error) throw new Error(italianErrorMessage(error.message, 'Aggiornamento del prezzo non riuscito.'))
    await reload()
  }
  const setAvailability = async (variant: Row) => {
    const active = variant.inventory_status?.available ?? false
    const { error } = await requireSupabase().from('inventory_status').update({ available: !active }).eq('variant_id', variant.id)
    if (error) throw new Error(italianErrorMessage(error.message, 'Aggiornamento della disponibilità non riuscito.'))
    await reload()
  }
  const removeProduct = async (product: Row) => {
    if (!window.confirm(`Eliminare il prodotto "${product.name}"?`)) return
    setMessage('')
    const db = requireSupabase()
    const paths = (product.product_media ?? [])
      .map((media: Row) => media.storage_path)
      .filter((path: unknown): path is string => typeof path === 'string' && path.length > 0)
    const { error } = await db.rpc('admin_delete_product', { p_product_id: product.id })
    if (error) {
      setMessage(italianErrorMessage(error.message, 'Eliminazione del prodotto non riuscita.'))
      return
    }
    if (paths.length) {
      const removed = await db.storage.from('product-media').remove(paths)
      if (removed.error) setMessage('Prodotto eliminato, ma alcuni file multimediali non sono stati rimossi.')
    }
    await reload()
  }
  return (
    <Section title="Catalogo" note="Configura prodotti, prezzi per grammi e contenuti multimediali.">
      <form onSubmit={addProduct} className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-2 mb-6">
        <input className="w-full" name="name" required placeholder="Nome prodotto" style={input} />
        <select className="w-full" name="category" required style={input}><option value="">Categoria</option>{categories.map(category => <option value={category.id} key={category.id}>{category.name}</option>)}</select>
        {[25, 50, 100, 300, 500, 1000].map(grams => <input className="w-full" key={grams} name={`price${grams}`} inputMode="numeric" pattern="[0-9]*" required placeholder={`EUR ${grams} g`} style={input} />)}
        <button style={primary}>Crea e pubblica</button>
        <label className="sm:col-span-2 lg:col-span-4 flex items-start gap-2" style={muted}>
          <input type="checkbox" name="announce" />
          Crea una notizia in bozza per il nuovo prodotto
        </label>
      </form>
      {message && <p className="mb-4" style={{ color: '#EF4444' }}>{message}</p>}
      {products.map(product => (
        <div key={product.id} className="p-3 mb-2 rounded-xl" style={{ background: 'rgba(245,245,245,.035)' }}>
          <div className="flex flex-col sm:flex-row sm:flex-wrap gap-2 sm:items-center mb-3">
            <div className="flex-1 min-w-0"><strong>{product.name}</strong><div style={muted}>{product.categories?.name} {product.badge ? `/ ${product.badge === 'NEW' ? 'NOVITÀ' : 'IN EVIDENZA'}` : ''}</div></div>
            <Toggle label="In evidenza" active={product.featured} onClick={() => toggle(product, 'featured')} />
            <Toggle label="Pubblicato" active={product.published} onClick={() => toggle(product, 'published')} />
            <button type="button" style={dangerButton} onClick={() => removeProduct(product)}>Elimina</button>
          </div>
          <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-2">
            {(product.product_variants ?? []).filter((variant: Row) => variant.unit_amount).map((variant: Row) => (
              <div key={variant.id} className="grid grid-cols-[1fr_82px] sm:grid-cols-[1fr_82px_auto] gap-2 items-center p-2 rounded-lg" style={{ background: '#080C0E' }}>
                <span>{variant.unit_amount} g / +{variant.token_award}</span>
                <input inputMode="numeric" pattern="[0-9]*" defaultValue={roundPrice(Number(variant.price))} onBlur={event => {
                  const price = parseOptionalInteger(event.currentTarget.value)
                  if (price === null || price < 0) {
                    event.currentTarget.value = String(roundPrice(Number(variant.price)))
                    return
                  }
                  void setPrice(variant.id, price)
                }} style={{ ...input, width: 78 }} />
                <div className="col-span-2 sm:col-span-1"><Toggle label="Disponibile" active={variant.inventory_status?.available ?? false} onClick={() => setAvailability(variant)} /></div>
              </div>
            ))}
          </div>
          <MediaUploader product={product} reload={reload} />
        </div>
      ))}
    </Section>
  )
}

function CategoriesAdmin({ products, categories, reload }: { products: Row[]; categories: Row[]; reload: () => Promise<void> }) {
  const [message, setMessage] = useState('')
  const addCategory = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    setMessage('')
    const name = String(new FormData(event.currentTarget).get('name'))
    const { error } = await requireSupabase().from('categories').insert({ name, slug: name.toLowerCase().replace(/\s+/g, '-') })
    if (error) {
      setMessage(italianErrorMessage(error.message, 'Creazione della categoria non riuscita.'))
      return
    }
    event.currentTarget.reset()
    await reload()
  }
  const removeCategory = async (category: Row) => {
    const count = products.filter(product => product.category_id === category.id).length
    if (count > 0) {
      setMessage('La categoria contiene prodotti. Elimina prima i prodotti associati.')
      return
    }
    if (!window.confirm(`Eliminare la categoria "${category.name}"?`)) return
    setMessage('')
    const { error } = await requireSupabase().rpc('admin_delete_category', { p_category_id: category.id })
    if (error) {
      setMessage(italianErrorMessage(error.message, 'Eliminazione della categoria non riuscita.'))
      return
    }
    await reload()
  }
  return (
    <Section title="Categorie" note="Crea categorie e rimuovi quelle senza prodotti.">
      <form onSubmit={addCategory} className="grid grid-cols-1 sm:grid-cols-[1fr_auto] gap-2 mb-5">
        <input className="w-full" name="name" required placeholder="Nome categoria" style={input} />
        <button style={primary}>Crea categoria</button>
      </form>
      {message && <p className="mb-4" style={{ color: '#EF4444' }}>{message}</p>}
      {categories.map(category => {
        const count = products.filter(product => product.category_id === category.id).length
        return (
          <div key={category.id} className="flex flex-col sm:flex-row sm:items-center gap-3" style={row}>
            <div className="flex-1 min-w-0">
              <strong>{category.name}</strong>
              <div style={muted}>{count} {count === 1 ? 'prodotto' : 'prodotti'}</div>
            </div>
            <button
              type="button"
              disabled={count > 0}
              style={{ ...dangerButton, opacity: count > 0 ? 0.45 : 1 }}
              onClick={() => removeCategory(category)}
            >
              Elimina
            </button>
          </div>
        )
      })}
    </Section>
  )
}

function BroadcastAdmin({ broadcasts, reload }: { broadcasts: Broadcast[]; reload: () => Promise<void> }) {
  const [message, setMessage] = useState('')
  const [busyId, setBusyId] = useState('')
  const create = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    setMessage('')
    const values = new FormData(event.currentTarget)
    const { data: createdBroadcastId, error } = await requireSupabase().rpc('admin_create_broadcast', {
      p_title: values.get('title'),
      p_message: values.get('message'),
      p_publish: false,
    })
    if (error) {
      setMessage(italianErrorMessage(error.message, 'Creazione della notizia non riuscita.'))
      return
    }
    if (!createdBroadcastId) {
      setMessage('Notizia creata, ma ID non ricevuto per la pubblicazione Telegram.')
      await reload()
      return
    }
    if (values.get('publish') === 'on') await runBroadcastAction(String(createdBroadcastId), 'publish')
    event.currentTarget.reset()
    await reload()
  }
  const runBroadcastAction = async (broadcastId: string, action: 'publish' | 'archive' | 'delete') => {
    setMessage('')
    setBusyId(broadcastId)
    try {
      const result = await adminBroadcastAction(broadcastId, action)
      if (action === 'publish') {
        const failed = result.telegramFailed ?? 0
        setMessage(`Notizia pubblicata. Telegram inviati: ${result.telegramSent ?? 0}${failed ? `, errori: ${failed}` : ''}.`)
      }
      if (action === 'archive') setMessage('Notizia archiviata.')
      if (action === 'delete') {
        const failed = result.telegramFailed ?? 0
        setMessage(`Notizia eliminata. Messaggi Telegram eliminati: ${result.telegramDeleted ?? 0}${failed ? `, errori: ${failed}` : ''}.`)
      }
      await reload()
    } catch (caught) {
      setMessage(italianErrorMessage(caught, 'Aggiornamento della notizia non riuscito.'))
    } finally {
      setBusyId('')
    }
  }
  const removeBroadcast = async (broadcast: Broadcast) => {
    if (!window.confirm(`Eliminare la notizia "${broadcast.title}"? Il bot proverà a cancellare anche i messaggi Telegram inviati.`)) return
    await runBroadcastAction(broadcast.id, 'delete')
  }
  return (
    <Section title="Notizie" note="Pubblica comunicazioni visibili nell'app e inviate anche via Telegram agli utenti autorizzati.">
      <form onSubmit={create} className="grid grid-cols-1 md:grid-cols-2 gap-2 mb-6">
        <input className="w-full" name="title" maxLength={120} required placeholder="Titolo" style={input} />
        <input className="w-full" name="message" maxLength={500} required placeholder="Messaggio" style={input} />
        <label className="flex items-center gap-2" style={muted}><input type="checkbox" name="publish" /> Pubblica subito</label>
        <button style={primary}>Crea notizia</button>
      </form>
      {message && <p className="mb-4" style={{ color: message.includes('errori') || message.includes('non riuscit') ? '#EF4444' : '#D7FE55' }}>{message}</p>}
      {broadcasts.map(broadcast => (
        <div key={broadcast.id} className="flex flex-col sm:flex-row sm:items-center gap-3" style={row}>
          <div className="flex-1 min-w-0">
            <strong>{broadcast.title}</strong>
            <div style={muted}>{broadcast.kind === 'product_new' ? 'Nuovo prodotto' : 'Annuncio'} / {broadcastStatusLabel[broadcast.status]} / {new Date(broadcast.createdAt).toLocaleDateString('it-IT')}</div>
            <div style={{ ...muted, marginTop: 4 }}>{broadcast.message}</div>
          </div>
          {broadcast.status !== 'published' && <button disabled={busyId === broadcast.id} style={smallButton} onClick={() => runBroadcastAction(broadcast.id, 'publish')}>{busyId === broadcast.id ? 'Invio...' : 'Pubblica'}</button>}
          {broadcast.status !== 'archived' && <button disabled={busyId === broadcast.id} style={smallButton} onClick={() => runBroadcastAction(broadcast.id, 'archive')}>Archivia</button>}
          <button disabled={busyId === broadcast.id} style={dangerButton} onClick={() => removeBroadcast(broadcast)}>Elimina</button>
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
      setUploadError(italianErrorMessage(caught, 'Caricamento non riuscito.'))
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
    if (inserted.error) throw new Error(italianErrorMessage(inserted.error.message, 'Caricamento del file non riuscito.'))
    const mediaId = inserted.data.id
    setUploads(current => ({ ...current, [mediaId]: { progress: 0, status: 'uploading' } }))
    try {
      await xhrStorageUpload(storagePath, file, progress => {
        setUploads(current => ({ ...current, [mediaId]: { progress, status: 'uploading' } }))
      })
      const ready = await db.from('product_media').update({ upload_status: 'ready' }).eq('id', mediaId)
      if (ready.error) throw new Error(italianErrorMessage(ready.error.message, 'Salvataggio del file non riuscito.'))
      setUploads(current => ({ ...current, [mediaId]: { progress: 100, status: 'ready' } }))
    } catch (caught) {
      await db.from('product_media').update({ upload_status: 'failed' }).eq('id', mediaId)
      setUploads(current => ({ ...current, [mediaId]: { progress: 0, status: 'failed' } }))
      throw caught
    }
  }

  return (
    <div className="mt-3 pt-3" style={{ borderTop: '1px solid rgba(245,245,245,.08)' }}>
      <div className="flex flex-col sm:flex-row sm:justify-between sm:items-center gap-2 mb-2">
        <span style={muted}>Contenuti: {imageCount}/5 foto, {videoCount}/3 video</span>
        <label style={{ ...smallButton, cursor: 'pointer' }}>
          Carica file
          <input hidden type="file" multiple accept="image/*,video/*" onChange={selectFiles} />
        </label>
      </div>
      {existing.map((media: Row) => {
        const status = uploads[media.id]?.status ?? media.upload_status
        const progress = uploads[media.id]?.progress ?? 0
        return (
          <div key={media.id} className="flex flex-wrap gap-2 items-center mb-1" style={{ fontSize: 12 }}>
            <span className="flex-1 min-w-0 break-all">{media.media_type === 'image' ? 'foto' : 'video'} {media.storage_path?.split('/').pop() ?? 'contenuto iniziale'}</span>
            {status === 'uploading' && <span style={{ color: '#7E9CA8' }}>Caricamento {progress}%</span>}
            {status === 'ready' && <span style={{ color: '#D7FE55' }}>Pronto</span>}
            {status === 'failed' && <span style={{ color: '#EF4444' }}>Non riuscito</span>}
          </div>
        )
      })}
      {Object.entries(uploads).filter(([id]) => !existing.some((media: Row) => media.id === id)).map(([id, state]) => (
        <div key={id} style={{ color: '#7E9CA8', fontSize: 12 }}>Caricamento {state.progress}%</div>
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
    request.onload = () => request.status >= 200 && request.status < 300 ? resolve() : reject(new Error('Caricamento nell’archivio non riuscito.'))
    request.onerror = () => reject(new Error('Caricamento nell’archivio non riuscito.'))
    request.send(file)
  })
}

function UsersAdmin({ profiles, initialKycUserId, reload }: { profiles: Row[]; initialKycUserId: string; reload: () => Promise<void> }) {
  const [query, setQuery] = useState('')
  const [kycGroup, setKycGroup] = useState<'approved' | 'unapproved'>('unapproved')
  const [message, setMessage] = useState('')
  const [messageError, setMessageError] = useState(false)
  const [reviewUser, setReviewUser] = useState<Row | null>(null)
  const [documents, setDocuments] = useState<KycReviewDocument[]>([])
  const [kycError, setKycError] = useState('')
  const [openedKycUserId, setOpenedKycUserId] = useState('')
  const visibleProfiles = profiles.filter(profile => `${profile.username} ${profile.telegram_subject}`.toLowerCase().includes(query.toLowerCase()))
  const approvedProfiles = visibleProfiles.filter(profile => profile.kyc_cases?.status === 'approved')
  const unapprovedProfiles = visibleProfiles.filter(profile => profile.kyc_cases?.status !== 'approved')
  const displayedProfiles = kycGroup === 'approved' ? approvedProfiles : unapprovedProfiles
  const toggleBlocked = async (profile: Row) => {
    setMessage('')
    setMessageError(false)
    const nextBlocked = !profile.blocked
    const { error } = await requireSupabase().rpc('admin_set_profile_blocked', {
      p_user_id: profile.id,
      p_blocked: nextBlocked,
    })
    if (error) {
      setMessageError(true)
      setMessage(italianErrorMessage(error.message, 'Aggiornamento del blocco non riuscito.'))
      return
    }
    setMessage(nextBlocked ? 'Utente bloccato.' : 'Utente sbloccato.')
    await reload()
  }
  const removeAccount = async (profile: Row) => {
    if (!window.confirm(`Eliminare definitivamente l'account @${profile.username}? Tutti i dati associati verranno rimossi.`)) return
    setMessage('')
    setMessageError(false)
    try {
      await adminDeleteAccount(profile.id)
      if (reviewUser?.id === profile.id) {
        setReviewUser(null)
        setDocuments([])
      }
      setMessage('Account eliminato definitivamente.')
      await reload()
    } catch (caught) {
      setMessageError(true)
      setMessage(italianErrorMessage(caught, 'Eliminazione account non riuscita.'))
    }
  }
  const openKyc = async (profile: Row) => {
    setKycError('')
    setReviewUser(profile)
    try {
      setDocuments(await getAdminKycDocuments(profile.id))
    } catch (caught) {
      setKycError(italianErrorMessage(caught, 'Accesso documenti negato.'))
    }
  }
  useEffect(() => {
    if (!initialKycUserId || openedKycUserId === initialKycUserId) return
    const profile = profiles.find(entry => entry.id === initialKycUserId)
    if (!profile) return
    setOpenedKycUserId(initialKycUserId)
    void openKyc(profile)
  }, [initialKycUserId, openedKycUserId, profiles])
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
      setKycError(italianErrorMessage(caught, 'Decisione non salvata.'))
    }
  }
  const userRows = (items: Row[]) => items.map(profile => (
    <div key={profile.id} className="flex flex-col lg:flex-row lg:items-center gap-3" style={row}>
      <div className="flex-1 min-w-0">
        <strong>@{profile.username}</strong>
        <div className="break-all" style={muted}>Telegram ID: {profile.telegram_subject} / {profile.role === 'admin' ? 'amministratore' : 'utente'}</div>
        <div style={muted}>
          {(profile.orders ?? []).filter((order: Row) => order.status === 'completed').length} completate / {(profile.feedback ?? []).length} recensioni
          {profile.kyc_cases?.retain_until ? ` / documenti fino a ${new Date(profile.kyc_cases.retain_until).toLocaleDateString('it-IT')}` : ''}
        </div>
      </div>
      {profile.blocked && <span style={{ color: '#FCA5A5' }}>BLOCCATO</span>}
      <span style={{ color: profile.kyc_cases?.status === 'approved' ? '#D7FE55' : '#F59E0B' }}>KYC: {kycStatusLabel[profile.kyc_cases?.status ?? 'not_started']}</span>
      <button style={smallButton} onClick={() => openKyc(profile)}>Documenti</button>
      {profile.role !== 'admin' && (
        <>
          <button style={profile.blocked ? smallButton : dangerButton} onClick={() => toggleBlocked(profile)}>
            {profile.blocked ? 'Sblocca' : 'Blocca'}
          </button>
          <button style={dangerButton} onClick={() => removeAccount(profile)}>Elimina</button>
        </>
      )}
    </div>
  ))
  return (
    <Section title="Utenti" note="I profili vengono creati al primo accesso Telegram. Gestisci KYC, blocco o eliminazione definitiva dell’account.">
      {message && <p className="mb-4" style={{ color: messageError || message === 'Utente bloccato.' ? '#FCA5A5' : '#D7FE55' }}>{message}</p>}
      <input value={query} onChange={event => setQuery(event.target.value)} placeholder="Cerca username o Telegram ID" style={{ ...input, width: '100%', marginBottom: 12 }} />
      <div className="flex flex-col sm:flex-row gap-2" style={{ margin: '12px 0 16px' }}>
        <button
          style={kycGroup === 'unapproved' ? { ...smallButton, color: '#D7FE55', borderColor: 'rgba(215,254,85,.45)' } : smallButton}
          onClick={() => setKycGroup('unapproved')}
        >
          KYC non approvata ({unapprovedProfiles.length})
        </button>
        <button
          style={kycGroup === 'approved' ? { ...smallButton, color: '#D7FE55', borderColor: 'rgba(215,254,85,.45)' } : smallButton}
          onClick={() => setKycGroup('approved')}
        >
          KYC approvata ({approvedProfiles.length})
        </button>
      </div>
      {displayedProfiles.length
        ? userRows(displayedProfiles)
        : <p style={muted}>{kycGroup === 'approved' ? 'Nessun utente con verifica KYC approvata.' : 'Nessun utente in attesa di verifica KYC.'}</p>}
      {reviewUser && (
        <div className="fixed inset-0 z-50 p-3 sm:p-5 flex items-center justify-center" style={{ background: 'rgba(0,0,0,.85)' }}>
          <div className="p-5 rounded-2xl max-w-4xl w-full max-h-[90vh] overflow-y-auto" style={panel}>
            <div className="flex flex-col sm:flex-row justify-between gap-3 mb-4">
              <div className="min-w-0">
                <h2 style={{ ...heading, fontSize: 22 }}>KYC @{reviewUser.username}</h2>
                <p style={muted}>Link temporanei validi 60 secondi. Visualizzazione registrata nel registro di controllo.</p>
              </div>
              <button style={smallButton} onClick={() => { setReviewUser(null); setDocuments([]) }}>Chiudi</button>
            </div>
            {kycError && <p style={{ color: '#EF4444' }}>{kycError}</p>}
            <div className="grid grid-cols-1 md:grid-cols-3 gap-3 mb-5">
              {documents.length === 0 && !kycError && <p style={muted}>Nessun documento caricato.</p>}
              {documents.map(document => (
                <div key={document.id}>
                  <div style={{ ...muted, marginBottom: 6 }}>{documentLabel[document.documentType]}</div>
                  <img src={document.signedUrl} alt={documentLabel[document.documentType]} className="w-full rounded-xl" style={{ maxHeight: 340, objectFit: 'contain', background: '#080C0E' }} referrerPolicy="no-referrer" />
                </div>
              ))}
            </div>
            {reviewUser.kyc_cases?.status === 'submitted' && (
              <div className="flex flex-col sm:flex-row gap-2">
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

function BalanceAdmin({ profiles, reload }: { profiles: Row[]; reload: () => Promise<void> }) {
  const [query, setQuery] = useState('')
  const [selected, setSelected] = useState('')
  const [points, setPoints] = useState('')
  const [xp, setXp] = useState('')
  const [spinTickets, setSpinTickets] = useState('')
  const [scratchTickets, setScratchTickets] = useState('')
  const [boxTickets, setBoxTickets] = useState('')
  const [reason, setReason] = useState('')
  const [message, setMessage] = useState('')
  const visibleProfiles = profiles.filter(profile => `${profile.username} ${profile.telegram_subject}`.toLowerCase().includes(query.toLowerCase()))
  const selectedProfile = profiles.find(profile => profile.id === selected)
  const adjustDraft = (value: string, setter: (next: string) => void, delta: number) => setter(String((parseOptionalInteger(value) ?? 0) + delta))
  const adjust = async (event: FormEvent) => {
    event.preventDefault()
    setMessage('')
    try {
      const deltas = [points, xp, spinTickets, scratchTickets, boxTickets].map(value => parseOptionalInteger(value) ?? 0)
      if (deltas.every(value => value === 0)) {
        setMessage('Inserisci almeno una variazione.')
        return
      }
      await adminAdjustWallet(selected, deltas[0], deltas[1], deltas[2], deltas[3], deltas[4], reason)
      setPoints('')
      setXp('')
      setSpinTickets('')
      setScratchTickets('')
      setBoxTickets('')
      setReason('')
      setMessage('Saldo aggiornato.')
      await reload()
    } catch (caught) {
      setMessage(italianErrorMessage(caught, 'Aggiornamento del saldo non riuscito.'))
    }
  }
  return (
    <Section title="Saldo" note="Consulta tutti i partecipanti e registra modifiche a gettoni, XP o biglietti.">
      {message && <p className="mb-4" style={{ color: message.includes('aggiornato') ? '#D7FE55' : '#EF4444' }}>{message}</p>}
      <input value={query} onChange={event => setQuery(event.target.value)} placeholder="Cerca username o Telegram ID" style={{ ...input, width: '100%', marginBottom: 12 }} />
      {visibleProfiles.map(profile => (
        <div key={profile.id} className="sf-admin-wallet-row flex flex-col sm:flex-row sm:items-center gap-3" style={row}>
          <div className="flex-1 min-w-0">
            <strong>@{profile.username}</strong>
            <div className="break-all" style={muted}>Telegram ID: {profile.telegram_subject}{profile.blocked ? ' / bloccato' : ''}</div>
          </div>
          <div className="sf-admin-wallet-pills">
            <span>{profile.wallet_balances?.points ?? 0} gettoni</span>
            <span>XP {profile.wallet_balances?.xp ?? 0}</span>
            <span>Ruota {profile.wallet_balances?.spin_tickets ?? 0}</span>
            <span>Scratch {profile.wallet_balances?.scratch_tickets ?? 0}</span>
            <span>Box {profile.wallet_balances?.box_tickets ?? 0}</span>
          </div>
          <button type="button" style={smallButton} onClick={() => setSelected(profile.id)}>{selected === profile.id ? 'Selezionato' : 'Seleziona'}</button>
        </div>
      ))}
      <form onSubmit={adjust} className="sf-balance-editor mt-5">
        <div className="sf-balance-target">
          <select className="w-full" required value={selected} onChange={event => setSelected(event.target.value)} style={input}>
            <option value="">Seleziona partecipante</option>
            {profiles.map(profile => <option key={profile.id} value={profile.id}>@{profile.username}</option>)}
          </select>
          {selectedProfile && <span>Modifica saldo di <strong>@{selectedProfile.username}</strong></span>}
        </div>
        <div className="sf-balance-fields">
          <BalanceField label="Gettoni" value={points} setValue={setPoints} onDelta={delta => adjustDraft(points, setPoints, delta)} />
          <BalanceField label="XP" value={xp} setValue={setXp} onDelta={delta => adjustDraft(xp, setXp, delta)} />
          <BalanceField label="Ruota" value={spinTickets} setValue={setSpinTickets} onDelta={delta => adjustDraft(spinTickets, setSpinTickets, delta)} />
          <BalanceField label="Scratch" value={scratchTickets} setValue={setScratchTickets} onDelta={delta => adjustDraft(scratchTickets, setScratchTickets, delta)} />
          <BalanceField label="Mystery Box" value={boxTickets} setValue={setBoxTickets} onDelta={delta => adjustDraft(boxTickets, setBoxTickets, delta)} />
        </div>
        <div className="sf-balance-submit">
          <input className="w-full" required minLength={4} value={reason} onChange={event => setReason(event.target.value)} placeholder="Motivo della modifica" style={input} />
          <button style={primary}>Registra movimento</button>
        </div>
      </form>
    </Section>
  )
}

function OrdersAdmin({ orders, reload }: { orders: Row[]; reload: () => Promise<void> }) {
  const [message, setMessage] = useState('')
  const updateStatus = async (orderId: string, status: 'processing' | 'completed' | 'cancelled') => {
    setMessage('')
    const { error } = await requireSupabase().rpc('admin_update_order_status', {
      p_order_id: orderId,
      p_status: status,
      p_note: status === 'completed' ? 'Ordine completato e premi accreditati' : 'Aggiornato dal pannello amministrazione',
    })
    if (error) {
      setMessage(italianErrorMessage(error.message, 'Aggiornamento dell’ordine non riuscito.'))
      return
    }
    await reload()
  }
  return (
    <Section title="Ordini attivi" note="Accetta o rifiuta gli ordini. I premi vengono accreditati solo con la spunta su un ordine accettato.">
      {message && <p className="mb-4" style={{ color: '#EF4444' }}>{message}</p>}
      {orders.length === 0 && <p style={muted}>Nessun ordine attivo.</p>}
      {orders.map(order => (
        <div key={order.id} className="flex flex-col sm:flex-row sm:items-center gap-3" style={row}>
          <div className="flex-1 min-w-0">
            <strong>{order.display_id} / {orderStatusLabel[order.status]}</strong>
            <div style={muted}>@{order.profiles?.username} / {order.total_units} g / EUR {order.total} / {scenarioLabel[order.scenario_type] ?? order.scenario_type} {order.scenario_city}{order.scenario_street ? `, ${order.scenario_street}` : ''}</div>
            <div style={muted}>Gettoni usati: {order.tokens_reserved} / premio dopo completamento: +{order.points_awarded}</div>
          </div>
          <div className="flex flex-col sm:flex-row gap-2">
            {order.status === 'submitted' && <button style={{ ...primary, background: '#10B981' }} onClick={() => updateStatus(order.id, 'processing')}>Accetta</button>}
            {order.status === 'processing' && <button style={{ ...primary, background: '#10B981' }} onClick={() => updateStatus(order.id, 'completed')}>✓ Completa e accredita</button>}
            <button style={dangerButton} onClick={() => updateStatus(order.id, 'cancelled')}>Rifiuta</button>
          </div>
        </div>
      ))}
    </Section>
  )
}

function EconomyAdmin({ games, options, reload }: { games: Row[]; options: Row[]; reload: () => Promise<void> }) {
  const [selectedGame, setSelectedGame] = useState<GameType>('spin')
  const [drafts, setDrafts] = useState<Row[]>([])
  const [exampleSpins, setExampleSpins] = useState(1000)
  const [message, setMessage] = useState('')
  const [saving, setSaving] = useState(false)
  const [simulation, setSimulation] = useState<Record<string, number> | null>(null)

  useEffect(() => {
    setDrafts(options.filter(option => option.game_type === selectedGame))
    setSimulation(null)
    setMessage('')
  }, [options, selectedGame])

  const activeOptions = drafts.filter(option => option.active)
  const totalWeight = activeOptions.reduce((total, option) => total + Math.max(0, parseOptionalInteger(option.weight) ?? 0), 0)
  const expectedTokens = totalWeight > 0
    ? activeOptions.reduce((total, option) => total + (parseOptionalInteger(option.points_awarded) ?? 0) * (parseOptionalInteger(option.weight) ?? 0), 0) / totalWeight
    : 0
  const game = games.find(item => item.game_type === selectedGame)

  const toggleGame = async () => {
    setMessage('')
    try {
      await adminSetGameActive(selectedGame, !game?.active)
      await reload()
    } catch (caught) {
      setMessage(italianErrorMessage(caught, 'Aggiornamento del gioco non riuscito.'))
    }
  }
  const updateDraft = (draftKey: string, changes: Row) => {
    setDrafts(current => current.map(option => (option.id ?? option.draftKey) === draftKey ? { ...option, ...changes } : option))
  }
  const addPrize = () => {
    const draftKey = `new-${Date.now()}`
    setDrafts(current => [...current, {
      draftKey, game_type: selectedGame, code: makeRewardCode(selectedGame), label: '', points_awarded: '', xp_awarded: '',
      weight: '', color: '#8B5CF6', active: true, reward_definition_id: null,
    }])
  }
  const removePrize = async (option: Row) => {
    if (!option.id) {
      setDrafts(current => current.filter(entry => entry.draftKey !== option.draftKey))
      return
    }
    try {
      await adminDeleteGameOption(option.id)
      setMessage('Premio eliminato.')
      await reload()
    } catch (caught) {
      setMessage(italianErrorMessage(caught, 'Eliminazione del premio non riuscita.'))
    }
  }
  const saveOptions = async () => {
    setMessage('')
    if (activeOptions.length > 0 && totalWeight !== 100) {
      setMessage('Le probabilità attive devono totalizzare esattamente 100%.')
      return
    }
    if (game?.active && activeOptions.length === 0) {
      setMessage('Disattiva il gioco prima di rimuovere tutti i premi.')
      return
    }
    if (drafts.some(option => !String(option.label ?? '').trim() || !isIntegerAtLeast(option.weight, option.active ? 1 : 0) || !isIntegerAtLeast(option.points_awarded, 0) || !isIntegerAtLeast(option.xp_awarded, 0))) {
      setMessage('Inserisci nome, probabilità, gettoni e XP validi.')
      return
    }
    setSaving(true)
    try {
      await adminSaveGameOptions(selectedGame, drafts.map(option => ({
        code: String(option.code || makeRewardCode(selectedGame)).trim(),
        label: String(option.label).trim(),
        points_awarded: Number(option.points_awarded),
        xp_awarded: Number(option.xp_awarded),
        weight: Number(option.weight),
        color: String(option.color || '#8B5CF6'),
        active: Boolean(option.active),
        reward_definition_id: option.reward_definition_id ?? null,
      })))
      setMessage('Configurazione premi salvata.')
      await reload()
    } catch (caught) {
      setMessage(italianErrorMessage(caught, 'Aggiornamento del premio non riuscito.'))
    } finally {
      setSaving(false)
    }
  }
  const simulate = async () => {
    setMessage('')
    try {
      setSimulation(await adminSimulateGame(selectedGame, exampleSpins))
    } catch (caught) {
      setMessage(italianErrorMessage(caught, 'Simulazione non riuscita.'))
    }
  }
  return (
    <Section title="Giochi e premi" note="Configura probabilità e simula le estrazioni. Ogni gioco attivo richiede probabilità totali pari al 100%.">
      <div className="sf-admin-game-config">
      <div className="sf-admin-game-tabs flex gap-2 overflow-x-auto mb-4">
        {([['spin', 'Ruota'], ['scratch', 'Scratch'], ['box', 'Mystery Box']] as Array<[GameType, string]>).map(([type, label]) => (
          <button key={type} className={selectedGame === type ? 'is-active' : ''} onClick={() => setSelectedGame(type)}>{label}</button>
        ))}
      </div>
      <div className="sf-admin-game-header flex flex-col sm:flex-row sm:items-center gap-3">
        <div className="flex-1 min-w-0">
          <div className="sf-admin-game-label">CONFIGURAZIONE ATTIVA</div>
          <strong>{game?.title ?? selectedGame}</strong>
          {!drafts.length && <div style={muted}>Nessun premio configurato: il gioco resta non disponibile.</div>}
        </div>
        {game && <Toggle label="Attivo" active={game.active} onClick={toggleGame} />}
      </div>
      <div className="sf-admin-probability p-3 sm:p-4 my-5 rounded-xl">
        <div className="flex flex-col sm:flex-row sm:items-end justify-between gap-3 mb-4">
          <div>
            <strong>Anteprima probabilità</strong>
            <div style={muted}>La probabilità è percentuale: i premi attivi devono totalizzare 100.</div>
          </div>
          <label style={muted}>
            Simula
            <select value={exampleSpins} onChange={event => setExampleSpins(Number(event.target.value))} style={{ ...input, marginLeft: 8 }}>
              {[100, 1000, 10000].map(value => <option key={value} value={value}>{value} partite</option>)}
            </select>
          </label>
        </div>
        <div className="sf-admin-distribution">
          <div className="sf-admin-ring" style={{ background: `conic-gradient(${totalWeight === 100 && activeOptions.length ? '#22C55E' : '#8B5CF6'} ${Math.min(totalWeight, 100)}%, rgba(245,245,245,.08) 0)` }}>
            <div><strong>{totalWeight}%</strong><span>TOTALE</span></div>
          </div>
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-2 flex-1">
            <Metric label="Premi attivi" value={activeOptions.length} />
            <Metric label="Probabilità totale" value={totalWeight} />
            <div className="sf-admin-metric p-4 rounded-xl">
              <div style={muted}>Gettoni medi / giro</div>
              <div style={{ fontFamily: 'Orbitron', fontSize: 22, color: '#D7FE55' }}>{formatItalianNumber(expectedTokens, 2)}</div>
            </div>
          </div>
        </div>
        <div className="mt-3" style={muted}>
          In {exampleSpins} partite: valore atteso circa {formatItalianNumber(expectedTokens * exampleSpins, 0)} gettoni.
        </div>
        <div className={`sf-admin-validation ${totalWeight === 100 && activeOptions.length ? 'is-valid' : ''}`}>{activeOptions.length && totalWeight === 100 ? 'Distribuzione valida / pronta per il gioco' : `Da completare / ${totalWeight}% di 100%`}</div>
        <button type="button" onClick={simulate} disabled={!activeOptions.length || totalWeight !== 100} className="sf-admin-simulate" style={{ opacity: !activeOptions.length || totalWeight !== 100 ? .45 : 1 }}>Esegui simulazione server</button>
        {simulation && <div className="sf-admin-results mt-3 grid grid-cols-2 gap-2">{Object.entries(simulation).map(([code, count]) => <div key={code}><strong>{code}</strong><span>{count}</span></div>)}</div>}
      </div>
      <div className="sf-admin-reward-title flex items-center justify-between my-4"><h3>Premi configurabili</h3><button type="button" style={smallButton} onClick={addPrize}>+ Aggiungi premio</button></div>
      {!drafts.length && <p className="mb-4" style={muted}>Aggiungi il primo premio; potrai attivare il gioco dopo aver raggiunto il 100%.</p>}
      {drafts.map(option => {
        const weight = Math.max(0, parseOptionalInteger(option.weight) ?? 0)
        const probability = option.active ? weight / 100 : 0
        const expected = probability * exampleSpins
        const onceEvery = probability > 0 ? Math.round(1 / probability) : 0
        const key = option.id ?? option.draftKey
        return (
          <div key={key} className="sf-admin-reward-card p-3 mb-3 rounded-xl">
            <div className="grid grid-cols-2 md:grid-cols-5 gap-3 items-end">
              <label className="col-span-2 md:col-span-1" style={muted}>Nome premio
                <input className="w-full" value={option.label} onChange={event => updateDraft(key, { label: event.target.value })} style={{ ...input, display: 'block', marginTop: 5 }} />
              </label>
              <label style={muted}>Gettoni
                <input inputMode="numeric" value={String(option.points_awarded)} onChange={event => updateDraft(key, { points_awarded: integerDraft(event.target.value) })} placeholder="0" style={{ ...input, width: '100%', display: 'block', marginTop: 5 }} />
              </label>
              <label style={muted}>XP
                <input inputMode="numeric" value={String(option.xp_awarded)} onChange={event => updateDraft(key, { xp_awarded: integerDraft(event.target.value) })} placeholder="0" style={{ ...input, width: '100%', display: 'block', marginTop: 5 }} />
              </label>
              <label style={muted}>Probabilità %
                <input inputMode="numeric" value={String(option.weight)} onChange={event => updateDraft(key, { weight: integerDraft(event.target.value) })} placeholder="%" style={{ ...input, width: '100%', display: 'block', marginTop: 5 }} />
              </label>
              <label style={muted}>Colore
                <input type="color" value={option.color} onChange={event => updateDraft(key, { color: event.target.value })} style={{ ...input, width: '100%', height: 42, display: 'block', marginTop: 5 }} />
              </label>
            </div>
            <div className="flex flex-wrap justify-between gap-2 mt-3"><Toggle label="Attiva" active={option.active} onClick={() => updateDraft(key, { active: !option.active })} /><button type="button" style={dangerButton} onClick={() => removePrize(option)}>Elimina</button></div>
            <div className="grid grid-cols-1 sm:grid-cols-3 gap-2 mt-3">
              <div style={muted}>Probabilità: <strong style={{ color: option.active ? '#D7FE55' : 'rgba(245,245,245,.45)' }}>{option.active ? weight : 0}%</strong></div>
              <div style={muted}>Su {exampleSpins}: <strong style={{ color: '#F5F5F5' }}>{formatItalianNumber(expected, expected < 10 ? 1 : 0)} volte</strong></div>
              <div style={muted}>{onceEvery ? `Circa 1 ogni ${onceEvery} partite` : 'Premio disattivato'}</div>
            </div>
          </div>
        )
      })}
      {message && <p className="mb-4" style={{ color: message.includes('salvata') ? '#D7FE55' : '#EF4444' }}>{message}</p>}
      <button type="button" disabled={saving} onClick={saveOptions} style={{ ...primary, width: '100%', opacity: saving ? 0.65 : 1 }}>
        {saving ? 'Salvataggio...' : 'Salva configurazione premi'}
      </button>
      </div>
    </Section>
  )
}

function FeedbackAdmin({ feedback, reload }: { feedback: Row[]; reload: () => Promise<void> }) {
  const moderate = async (id: string, status: 'published' | 'hidden') => {
    const { error } = await requireSupabase().rpc('admin_moderate_feedback', { p_feedback_id: id, p_status: status })
    if (error) throw new Error(italianErrorMessage(error.message, 'Moderazione della recensione non riuscita.'))
    await reload()
  }
  return (
    <Section title="Recensioni" note="Pubblica o nascondi le recensioni degli utenti.">
      {feedback.map(item => <div key={item.id} className="flex flex-col sm:flex-row sm:items-start gap-3 p-4 mb-3" style={row}>
        <div className="flex-1 min-w-0">
          <strong>@{item.profiles?.username ?? 'membro'} / {item.rating} stelle</strong>
          <div style={muted}>{item.orders?.display_id} / {feedbackStatusLabel[item.status]}</div>
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
  const links = settings.find(setting => setting.key === 'community_links')?.value ?? { instagram: '', viber: '', signal: null }
  const addLocation = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const values = new FormData(event.currentTarget)
    const scenario = String(values.get('scenario'))
    const minimumUnits = parseOptionalInteger(String(values.get('minimum')))
    if (minimumUnits === null || minimumUnits < 1) throw new Error('Minimo non valido')
    const { error } = await requireSupabase().from('service_areas').insert({
      scenario_type: scenario,
      city: values.get('city'),
      minimum_units: minimumUnits,
      requires_street: scenario !== 'meetup',
    })
    if (error) throw new Error(italianErrorMessage(error.message, 'Aggiunta dell’area non riuscita.'))
    event.currentTarget.reset()
    await reload()
  }
  const updateRetention = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const values = new FormData(event.currentTarget)
    const approvedDays = parseOptionalInteger(String(values.get('days')))
    if (approvedDays === null || approvedDays < 1) throw new Error('Conservazione non valida')
    const value = { approved_days: approvedDays }
    const { error } = await requireSupabase().from('app_settings').upsert({ key: 'kyc_retention', value })
    if (error) throw new Error(italianErrorMessage(error.message, 'Salvataggio della conservazione non riuscito.'))
    await reload()
  }
  const updateTier = async (minimumUnits: number, tokensAwarded: number) => {
    const { error } = await requireSupabase().rpc('admin_set_token_tier', {
      p_minimum_units: minimumUnits,
      p_tokens_awarded: tokensAwarded,
    })
    if (error) throw new Error(italianErrorMessage(error.message, 'Aggiornamento dei gettoni non riuscito.'))
    await reload()
  }
  const updatePublicInfo = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const values = new FormData(event.currentTarget)
    const db = requireSupabase()
    const results = await Promise.all([
      db.from('app_settings').upsert({ key: 'community_links', value: {
        instagram: String(values.get('instagram')), viber: String(values.get('viber')),
        signal: String(values.get('signal') ?? '').trim() || null,
      } }),
    ])
    const error = results.find(result => result.error)?.error
    if (error) throw new Error(italianErrorMessage(error.message, 'Salvataggio delle informazioni non riuscito.'))
    await reload()
  }
  return (
    <Section title="Impostazioni" note="Configura informazioni pubbliche, KYC, premi e aree di servizio.">
      <form onSubmit={updatePublicInfo} className="grid gap-2 mb-6">
        <h3>Link pubblici</h3>
        <input className="w-full" name="instagram" defaultValue={links.instagram} placeholder="URL Instagram" style={input} />
        <input className="w-full" name="viber" defaultValue={links.viber} placeholder="URL Viber" style={input} />
        <input className="w-full" name="signal" defaultValue={links.signal ?? ''} placeholder="URL Signal (opzionale)" style={input} />
        <button style={primary}>Salva link</button>
      </form>
      <form onSubmit={updateRetention} className="flex flex-col sm:flex-row gap-2 mb-5 sm:items-end">
        <label style={muted}>Conservazione documenti KYC (giorni)<input name="days" required inputMode="numeric" pattern="[0-9]*" defaultValue={retention.approved_days} style={{ ...input, width: 150, display: 'block', marginTop: 5 }} /></label>
        <button style={primary}>Salva conservazione</button>
      </form>
      <h3 className="mb-3">Gettoni per ordine completato</h3>
      <div className="flex flex-wrap gap-3 mb-6">
        {tokenTiers.map(tier => <label key={tier.minimum_units} style={muted}>{tier.minimum_units}+ g
          <input inputMode="numeric" pattern="[0-9]*" defaultValue={tier.tokens_awarded} onBlur={event => {
            const tokens = parseOptionalInteger(event.currentTarget.value)
            if (tokens === null || tokens < 0 || tokens > 100) {
              event.currentTarget.value = String(tier.tokens_awarded)
              return
            }
            void updateTier(tier.minimum_units, tokens)
          }} style={{ ...input, width: 70, display: 'block' }} />
        </label>)}
      </div>
      <h3 className="mb-3 mt-6">MEETUP</h3>
      <div className="mb-4">
        {locations.filter(l => l.scenario_type === 'meetup').map(location => <div key={location.id} className="flex flex-wrap justify-between gap-2" style={row}><strong>{location.city}</strong><span>minimo {location.minimum_units} g</span></div>)}
      </div>
      <form onSubmit={addLocation} className="grid grid-cols-1 sm:grid-cols-[1fr_150px_auto] gap-2 mb-6">
        <input type="hidden" name="scenario" value="meetup" />
        <input className="w-full" name="city" required placeholder="Città" style={input} />
        <input className="w-full" name="minimum" inputMode="numeric" pattern="[0-9]*" required placeholder="Minimo g" style={input} />
        <button style={primary}>Aggiungi</button>
      </form>
      <h3 className="mb-3">DELIVERY LOCALE</h3>
      <div className="mb-4">
        {locations.filter(l => l.scenario_type === 'delivery_zone').map(location => <div key={location.id} className="flex flex-wrap justify-between gap-2" style={row}><strong>{location.city}</strong><span>minimo {location.minimum_units} g</span></div>)}
      </div>
      <form onSubmit={addLocation} className="grid grid-cols-1 sm:grid-cols-[1fr_150px_auto] gap-2 mb-6">
        <input type="hidden" name="scenario" value="delivery_zone" />
        <input className="w-full" name="city" required placeholder="Città" style={input} />
        <input className="w-full" name="minimum" inputMode="numeric" pattern="[0-9]*" required placeholder="Minimo g" style={input} />
        <button style={primary}>Aggiungi</button>
      </form>
      <h3 className="mb-3">DELIVERY TUTTA ITALIA</h3>
      <div className="mb-4">
        {locations.filter(l => l.scenario_type === 'delivery_italia').map(location => <div key={location.id} className="flex flex-wrap justify-between gap-2" style={row}><strong>{location.city}</strong><span>minimo {location.minimum_units} g</span></div>)}
      </div>
      <form onSubmit={addLocation} className="grid grid-cols-1 sm:grid-cols-[1fr_150px_auto] gap-2">
        <input type="hidden" name="scenario" value="delivery_italia" />
        <input className="w-full" name="city" required placeholder="Città" style={input} />
        <input className="w-full" name="minimum" inputMode="numeric" pattern="[0-9]*" required placeholder="Minimo g" style={input} />
        <button style={primary}>Aggiungi</button>
      </form>
    </Section>
  )
}

function AdminFrame({ children }: { children: ReactNode }) {
  return <div className="px-3 sm:px-5 pb-10" style={{ minHeight: '100vh', paddingTop: 'clamp(88px, 14vw, 120px)', background: '#080C0E', color: '#F5F5F5' }}><div className="max-w-6xl mx-auto min-w-0">{children}</div></div>
}
function Section({ title, note, children }: { title: string; note: string; children: ReactNode }) {
  return <section className="p-3 sm:p-5 rounded-2xl min-w-0" style={panel}><h2 style={{ ...heading, fontSize: 21 }}>{title}</h2><p style={{ ...muted, marginBottom: 18 }}>{note}</p>{children}</section>
}
function Metric({ label, value }: { label: string; value: number }) {
  return <div className="p-4 rounded-xl" style={panel}><div style={muted}>{label}</div><div style={{ fontFamily: 'Orbitron', fontSize: 25, color: '#D7FE55' }}>{value}</div></div>
}
function Toggle({ label, active, onClick }: { label: string; active: boolean; onClick: () => void }) {
  return <button onClick={onClick} style={{ ...smallButton, color: active ? '#D7FE55' : 'rgba(245,245,245,.55)' }}>{label}: {active ? 'SÌ' : 'NO'}</button>
}
function BalanceField({ label, value, setValue, onDelta }: { label: string; value: string; setValue: (next: string) => void; onDelta: (delta: number) => void }) {
  return <label className="sf-balance-field">
    <span>{label}</span>
    <div className="sf-balance-input">
      <button type="button" onClick={() => onDelta(-1)} aria-label={`Riduci ${label}`}><Minus size={15} /></button>
      <input inputMode="numeric" value={value} onChange={event => setValue(signedIntegerDraft(event.target.value))} placeholder="0" aria-label={label} />
      <button type="button" onClick={() => onDelta(1)} aria-label={`Aumenta ${label}`}><Plus size={15} /></button>
    </div>
    <div className="sf-balance-quick">
      <button type="button" onClick={() => onDelta(-5)}>-5</button>
      <button type="button" onClick={() => onDelta(5)}>+5</button>
    </div>
  </label>
}
function integerDraft(value: string) {
  return value.replace(/\D/g, '')
}
function signedIntegerDraft(value: string) {
  const cleaned = value.replace(/[^\d-]/g, '')
  return cleaned.startsWith('-') ? `-${cleaned.slice(1).replace(/-/g, '')}` : cleaned.replace(/-/g, '')
}
function parseOptionalInteger(value: NumericDraft) {
  const text = String(value ?? '').trim()
  if (!text || text === '-') return null
  const parsed = Number(text)
  return Number.isInteger(parsed) ? parsed : null
}
function isIntegerAtLeast(value: NumericDraft, minimum: number) {
  const parsed = parseOptionalInteger(value)
  return parsed !== null && parsed >= minimum
}
function makeRewardCode(type: GameType) {
  return `${type}_${crypto.randomUUID().replace(/-/g, '').slice(0, 12)}`
}
function roundPrice(price: number) {
  return Math.round(price / 5) * 5
}
function formatItalianNumber(value: number, digits: number) {
  return value.toLocaleString('it-IT', { minimumFractionDigits: 0, maximumFractionDigits: digits })
}
const panel = { background: '#11181B', border: '1px solid rgba(126,156,168,.18)' }
const row = { padding: 12, marginBottom: 8, background: 'rgba(245,245,245,.035)', borderRadius: 10, minWidth: 0 }
const heading = { fontFamily: 'Space Grotesk', fontWeight: 700, fontSize: 'clamp(24px, 7vw, 30px)', color: '#F5F5F5' }
const muted = { color: 'rgba(245,245,245,.55)', fontSize: 13 }
const input = { minWidth: 0, maxWidth: '100%', boxSizing: 'border-box' as const, padding: '9px 12px', background: '#080C0E', border: '1px solid rgba(245,245,245,.18)', color: '#F5F5F5', borderRadius: 8 }
const primary = { ...input, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', background: '#7E9CA8', fontWeight: 700 }
const smallButton = { display: 'inline-flex', alignItems: 'center', gap: 5, padding: '9px 12px', borderRadius: 8, border: '1px solid rgba(126,156,168,.25)', background: '#11181B', color: '#F5F5F5' }
const dangerButton = { ...smallButton, border: '1px solid rgba(239,68,68,.38)', color: '#FCA5A5' }
