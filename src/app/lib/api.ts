import { requireSupabase } from './supabase'
import { italianErrorMessage } from './errors'
import type {
  Broadcast,
  CartItem,
  DashboardData,
  DemoInfo,
  GamePlayResult,
  Feedback,
  LedgerEntry,
  Level,
  KycDocumentType,
  KycReviewDocument,
  KycStatus,
  OrderSubmitResult,
  Product,
  Profile,
  ScenarioSelection,
  ServiceArea,
  TestOrder,
  UserReward,
} from '../data'

type RecordValue = Record<string, any>

function unwrap<T>(result: { data: T | null; error: { message: string } | null }): T {
  if (result.error) throw new Error(italianErrorMessage(result.error.message))
  if (result.data == null) throw new Error('Nessun dato ricevuto.')
  return result.data
}

async function edgeFunctionError(error: unknown, fallback: string) {
  const functionError = error as { message?: string; context?: Response }
  try {
    if (functionError.context) {
      const body = await functionError.context.clone().json() as { error?: string }
      if (body.error) return italianErrorMessage(body.error, fallback)
    }
  } catch {
    // Usa il messaggio di riserva quando la risposta non contiene JSON leggibile.
  }
  return italianErrorMessage(functionError.message, fallback)
}

function ledgerReason(reason: string) {
  return reason
    .replace(/^Test order /, 'Ordine ')
    .replace(/^Daily Bonus$/, 'Bonus giornaliero')
    .replace(/^Game: /, 'Gioco: ')
    .replace(/^Admin gettoni:/, 'Amministrazione gettoni:')
    .replace(/^Ticket ruota guadagnato$/, 'Biglietto ruota guadagnato')
}

export async function getAccessProfile(): Promise<Profile | null> {
  const db = requireSupabase()
  const { data, error } = await db.rpc('get_my_profile')
  if (error) {
    if (/allowlist|access/i.test(error.message)) return null
    throw new Error(italianErrorMessage(error.message))
  }
  if (!data) return null
  const p = data as RecordValue
  return {
    id: p.id,
    name: p.username || 'Membro Street',
    avatarUrl: p.avatar_url,
    role: p.role,
    level: p.level_number,
    xp: p.xp,
    xpNeeded: p.next_level_xp ?? p.xp,
    tokens: p.tokens ?? p.points,
    spinTickets: p.spin_tickets ?? 0,
    streak: p.streak,
    totalOrders: p.total_orders,
    completedOrders: p.completed_orders ?? 0,
  }
}

export async function getCatalog(): Promise<Product[]> {
  const db = requireSupabase()
  const rows = unwrap(await db.rpc('get_catalog')) as RecordValue[]
  return Promise.all(rows.map(async (row) => {
    const variants = (row.variants ?? []).map((variant: RecordValue) => ({
      id: variant.id,
      label: variant.label,
      price: Number(variant.price),
      unitAmount: variant.unit_amount,
      tokenAward: variant.token_award,
      available: variant.available,
    }))
    const media = await Promise.all((row.media ?? []).map(async (entry: RecordValue) => {
      let resolvedUrl = entry.url
      if (entry.storage_path) {
        const signed = await db.storage.from('product-media').createSignedUrl(entry.storage_path, 3600)
        resolvedUrl = signed.data?.signedUrl ?? ''
      }
      return {
        id: entry.id,
        url: resolvedUrl,
        storagePath: entry.storage_path ?? null,
        uploadStatus: entry.upload_status ?? 'ready',
        type: entry.type,
        alt: entry.alt,
        sortOrder: entry.sort_order,
      }
    }))
    return {
      id: row.id,
      name: row.name,
      category: row.category,
      img: media.find((entry: { type: string }) => entry.type === 'image')?.url ?? row.cover_url ?? '',
      startingPrice: variants.find((variant: { unitAmount: number; available: boolean }) => variant.available && variant.unitAmount >= 25)?.price ?? 0,
      rating: Number(row.rating),
      badge: row.badge,
      reviews: row.review_count,
      description: row.description,
      variants,
      media,
      available: variants.some((v: { available: boolean }) => v.available),
    }
  }))
}

export async function getLevels(): Promise<Level[]> {
  const db = requireSupabase()
  const { data, error } = await db.from('levels').select('*').order('level_number')
  if (error) throw new Error(italianErrorMessage(error.message))
  return (data ?? []).map((level: RecordValue) => ({
    id: level.id,
    level: level.level_number,
    name: level.name,
    xpMin: level.xp_min,
    xpMax: level.xp_max,
    color: level.color,
    icon: level.icon,
  }))
}

export async function getBroadcasts(): Promise<Broadcast[]> {
  const db = requireSupabase()
  const { data, error } = await db
    .from('broadcasts')
    .select('id,kind,title,message,product_id,status,published_at,created_at')
    .eq('status', 'published')
    .order('published_at', { ascending: false })
    .limit(10)
  if (error) throw new Error(italianErrorMessage(error.message))
  return (data ?? []).map((broadcast: RecordValue) => ({
    id: broadcast.id,
    kind: broadcast.kind,
    title: broadcast.title,
    message: broadcast.message,
    productId: broadcast.product_id,
    status: broadcast.status,
    publishedAt: broadcast.published_at,
    createdAt: broadcast.created_at,
  }))
}

export async function getProfileActivity() {
  const db = requireSupabase()
  const [ordersResponse, ledgerResponse, rewardsResponse, feedbackResponse] = await Promise.all([
    db.from('orders').select('id,display_id,created_at,status,total,total_units,tokens_reserved,points_awarded,xp_awarded,order_items(name_snapshot,variant_label),feedback(status)').order('created_at', { ascending: false }),
    db.from('loyalty_ledger').select('id,created_at,reason,points_delta,xp_delta').order('created_at', { ascending: false }).limit(30),
    db.from('user_rewards').select('id,state,reward_definitions(label,kind)').order('created_at', { ascending: false }),
    db.from('feedback').select('id,order_id,rating,message,status,created_at').eq('status', 'published').order('created_at', { ascending: false }).limit(20),
  ])
  if (ordersResponse.error) throw new Error(italianErrorMessage(ordersResponse.error.message))
  if (ledgerResponse.error) throw new Error(italianErrorMessage(ledgerResponse.error.message))
  if (rewardsResponse.error) throw new Error(italianErrorMessage(rewardsResponse.error.message))
  if (feedbackResponse.error) throw new Error(italianErrorMessage(feedbackResponse.error.message))
  const orders: TestOrder[] = (ordersResponse.data ?? []).map((order: RecordValue) => ({
    id: order.id,
    displayId: order.display_id,
    createdAt: order.created_at,
    status: order.status,
    total: Number(order.total),
    totalUnits: order.total_units,
    tokensReserved: order.tokens_reserved,
    tokensAwarded: order.points_awarded,
    xpAwarded: order.xp_awarded,
    feedbackStatus: order.feedback?.[0]?.status ?? null,
    items: (order.order_items ?? []).map((item: RecordValue) => `${item.name_snapshot} ${item.variant_label}`),
  }))
  const ledger: LedgerEntry[] = (ledgerResponse.data ?? []).map((entry: RecordValue) => ({
    id: entry.id,
    createdAt: entry.created_at,
    reason: ledgerReason(entry.reason),
    tokens: entry.points_delta,
    xp: entry.xp_delta,
  }))
  const rewards: UserReward[] = (rewardsResponse.data ?? []).map((reward: RecordValue) => ({
    id: reward.id,
    state: reward.state,
    label: reward.reward_definitions.label,
    kind: reward.reward_definitions.kind,
  }))
  const feedback: Feedback[] = (feedbackResponse.data ?? []).map((entry: RecordValue) => ({
    id: entry.id, orderId: entry.order_id, rating: entry.rating, message: entry.message,
    status: entry.status, createdAt: entry.created_at,
  }))
  return { orders, ledger, rewards, feedback }
}

export async function playWheel(): Promise<GamePlayResult> {
  const db = requireSupabase()
  const response = await db.rpc('play_game', { p_game_type: 'spin' })
  if (response.error) throw new Error(italianErrorMessage(response.error.message))
  const result = unwrap(response) as RecordValue
  return {
    playId: result.play_id,
    gameType: 'spin',
    code: result.reward_code,
    label: result.reward_label,
    tokensAwarded: result.points_awarded,
    xpAwarded: result.xp_awarded,
    rewardKind: result.reward_kind,
    balance: result.balance,
    xp: result.xp,
    spinTickets: result.spin_tickets,
  }
}

export async function getServiceAreas(): Promise<ServiceArea[]> {
  const db = requireSupabase()
  const { data, error } = await db.from('service_areas').select('id,scenario_type,city,minimum_units,requires_street').eq('active', true).order('sort_order')
  if (error) throw new Error(italianErrorMessage(error.message))
  return (data ?? []).map((area: RecordValue) => ({
    id: area.id, scenarioType: area.scenario_type, city: area.city,
    minimumUnits: area.minimum_units, requiresStreet: area.requires_street,
  }))
}

export async function getDemoInfo(): Promise<DemoInfo> {
  const db = requireSupabase()
  const result = unwrap(await db.rpc('get_demo_info')) as RecordValue
  return {
    disclaimer: '',
    instagram: result.links?.instagram ?? '',
    viber: result.links?.viber ?? '',
    signal: result.links?.signal ?? null,
  }
}

export async function submitTestOrder(
  cart: CartItem[],
  selection: ScenarioSelection,
): Promise<OrderSubmitResult> {
  const db = requireSupabase()
  const payload = cart.map((item) => ({ product_id: item.productId, grams: item.unitAmount }))
  const response = await db.functions.invoke('submit-test-order', {
    body: { items: payload, ...selection },
  })
  if (response.error) throw new Error(await edgeFunctionError(response.error, 'Invio richiesta non riuscito.'))
  const result = unwrap(response) as RecordValue
  return {
    orderId: result.order_id,
    displayId: result.display_id,
    simulatedSubtotal: Number(result.simulated_subtotal),
    simulatedSurcharge: Number(result.simulated_surcharge),
    simulatedTokenCredit: Number(result.simulated_token_credit),
    simulatedTotal: Number(result.simulated_total),
    totalUnits: result.total_units,
    tokensReserved: result.tokens_reserved,
    tokensOnComplete: result.tokens_on_complete,
    xpOnComplete: result.xp_on_complete,
    balance: result.balance,
    disclaimer: '',
  }
}

export async function submitFeedback(orderId: string, rating: number, message: string) {
  const db = requireSupabase()
  const { error } = await db.rpc('submit_feedback', { p_order_id: orderId, p_rating: rating, p_message: message })
  if (error) throw new Error(italianErrorMessage(error.message))
}

export async function getAdminDashboard(): Promise<DashboardData> {
  const db = requireSupabase()
  const row = unwrap(await db.rpc('admin_dashboard')) as RecordValue
  return {
    allowlistedUsers: row.allowlisted_users,
    submittedOrders: row.submitted_orders,
    gamePlays: row.game_plays,
    issuedPoints: row.issued_points,
  }
}

export async function adminAdjustWallet(userId: string, points: number, xp: number, reason: string) {
  const db = requireSupabase()
  const { error } = await db.rpc('admin_adjust_wallet', {
    p_user_id: userId,
    p_points_delta: points,
    p_xp_delta: xp,
    p_reason: reason,
  })
  if (error) throw new Error(italianErrorMessage(error.message))
}

export async function getKycStatus(): Promise<KycStatus> {
  const db = requireSupabase()
  const response = await db.functions.invoke('kyc-status', { body: {} })
  if (response.error) throw new Error(await edgeFunctionError(response.error, 'Lettura verifica non riuscita.'))
  const result = unwrap(response) as RecordValue
  return {
    status: result.status,
    documents: result.documents ?? [],
    submittedAt: result.submitted_at ?? null,
    rejectionReason: result.rejection_reason ?? null,
  }
}

export async function uploadKycCapture(documentType: KycDocumentType, blob: Blob) {
  const db = requireSupabase()
  const form = new FormData()
  form.append('documentType', documentType)
  form.append('capturedAt', new Date().toISOString())
  form.append('capture', blob, `${documentType}.jpg`)
  const { error } = await db.functions.invoke('upload-kyc-capture', { body: form })
  if (error) throw new Error(await edgeFunctionError(error, 'Caricamento documento non riuscito.'))
}

export async function submitKyc(): Promise<KycStatus> {
  const db = requireSupabase()
  const response = await db.functions.invoke('submit-kyc', { body: {} })
  if (response.error) throw new Error(await edgeFunctionError(response.error, 'Invio verifica non riuscito.'))
  const result = unwrap(response) as RecordValue
  return { status: result.status, documents: [], submittedAt: null, rejectionReason: null }
}

export async function getAdminKycDocuments(userId: string): Promise<KycReviewDocument[]> {
  const db = requireSupabase()
  const response = await db.functions.invoke('admin-kyc-documents', { body: { userId } })
  if (response.error) throw new Error(await edgeFunctionError(response.error, 'Lettura documenti non riuscita.'))
  const result = unwrap(response) as RecordValue
  return (result.documents ?? []).map((document: RecordValue) => ({
    id: document.id,
    documentType: document.documentType,
    capturedAt: document.capturedAt,
    signedUrl: document.signedUrl,
  }))
}

export async function reviewKyc(userId: string, decision: 'approved' | 'rejected', reason = '') {
  const db = requireSupabase()
  const { error } = await db.functions.invoke('review-kyc', { body: { userId, decision, reason } })
  if (error) throw new Error(await edgeFunctionError(error, 'Decisione sulla verifica non riuscita.'))
}
