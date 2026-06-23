export type Page = 'home' | 'catalog' | 'games' | 'estrazione' | 'profile' | 'info' | 'contacts'
export type GameType = 'spin' | 'scratch' | 'box'
export type ScenarioType = 'meetup' | 'delivery_zone' | 'delivery_italia'

export interface ProductVariant {
  id: string
  label: string
  price: number
  unitAmount: number
  tokenAward: number
  available: boolean
}

export interface ProductMedia {
  id: string
  url: string
  storagePath: string | null
  uploadStatus: 'uploading' | 'ready' | 'failed'
  type: 'image' | 'video'
  alt: string | null
  sortOrder: number
}

export interface Product {
  id: string
  name: string
  category: string
  img: string
  startingPrice: number
  rating: number
  badge: 'HOT' | 'NEW' | null
  promoTag: string
  reviews: number
  description: string
  variants: ProductVariant[]
  media: ProductMedia[]
  available: boolean
}

export interface CartItem {
  id: string
  productId: string
  variantId: string
  name: string
  variantLabel: string
  unitAmount: number
  tokenAward: number
  price: number
  img: string
}

export interface Profile {
  id: string
  name: string
  avatarUrl: string | null
  role: 'user' | 'admin'
  level: number
  xp: number
  xpNeeded: number
  tokens: number
  spinTickets: number
  scratchTickets: number
  boxTickets: number
  streak: number
  totalOrders: number
  completedOrders: number
}

export type User = Profile

export interface Level {
  id: string
  level: number
  name: string
  xpMin: number
  xpMax: number | null
  color: string
  icon: string
}

export interface LedgerEntry {
  id: string
  createdAt: string
  reason: string
  tokens: number
  xp: number
}

export interface TestOrder {
  id: string
  displayId: string
  createdAt: string
  status: 'submitted' | 'processing' | 'completed' | 'cancelled'
  items: string[]
  total: number
  totalUnits: number
  tokensReserved: number
  tokensAwarded: number
  xpAwarded: number
  feedbackStatus: FeedbackStatus | null
}

export interface UserReward {
  id: string
  label: string
  kind: 'discount' | 'free_delivery' | 'xp_boost' | 'item'
  state: 'available' | 'redeemed' | 'expired'
}

export interface GamePlayResult {
  playId: string
  gameType: GameType
  code: string
  label: string
  tokensAwarded: number
  xpAwarded: number
  rewardKind: UserReward['kind'] | null
  rewardColor: string
  balance: number
  xp: number
  spinTickets: number
  scratchTickets: number
  boxTickets: number
  angle: number
  segmentIndex: number
  segmentCount: number
  boxStopIndex: number
}

export interface PlayableGame {
  gameType: GameType
  title: string
  ticketPrice: number
  options: Array<{ code: string; label: string; color: string }>
}

export interface TicketPurchaseResult {
  gameType: GameType
  ticketPrice: number
  balance: number
  spinTickets: number
  scratchTickets: number
  boxTickets: number
}

export type EstrazioneStatus = 'draft' | 'open' | 'sold_out' | 'scheduled' | 'running' | 'completed' | 'cancelled'

export interface Estrazione {
  id: string
  title: string
  status: EstrazioneStatus
  ticketPrice: number
  minCompletedOrders: number
  maxTickets: number
  winnersCount: number
  scheduledAt: string | null
  publicToken: string
  adminNotifiedAt: string | null
  reminderSentAt: string | null
  drawStartedAt: string | null
  completedAt: string | null
  cancelledAt: string | null
  createdAt: string
  updatedAt: string
  soldCount: number
  remainingCount: number
}

export interface EstrazioneUserTicket {
  id: string
  selectedNumber: number
  paidPoints: number
  purchasedAt: string
}

export interface EstrazioneWinner {
  place: number
  selectedNumber: number
  username: string | null
  telegramSubject: string | null
  ticketId?: string
}

export interface CurrentEstrazione {
  estrazione: Estrazione | null
  soldNumbers: number[]
  userTicket: EstrazioneUserTicket | null
  winners: EstrazioneWinner[]
  userCompletedOrders: number
  userEligible: boolean
  userBalance: number
}

export interface AdminEstrazioneTicket extends EstrazioneUserTicket {
  userId: string
  username: string | null
  telegramSubject: string | null
  status: 'active' | 'cancelled'
}

export interface AdminEstrazione extends Estrazione {
  tickets: AdminEstrazioneTicket[]
  winners: EstrazioneWinner[]
  messageCounts: {
    adminSoldOut: number
    reminder: number
    errors: number
  }
}

export interface ScenarioSelection {
  scenarioType: ScenarioType
  city: string
  street: string
  tokensToReserve: number
}

export interface ServiceArea {
  id: string
  scenarioType: ScenarioType
  city: string
  minimumUnits: number
  requiresStreet: boolean
}

export interface DemoInfo {
  disclaimer: string
  instagram: string
  viber: string
  signal: string | null
}

export interface OrderSubmitResult {
  orderId: string
  displayId: string
  simulatedSubtotal: number
  simulatedSurcharge: number
  simulatedTokenCredit: number
  simulatedTotal: number
  totalUnits: number
  tokensReserved: number
  tokensOnComplete: number
  xpOnComplete: number
  firstOrderGift: number
  itemRewards: Array<{ id: string; label: string }>
  balance: number
  disclaimer: string
}

export interface DashboardData {
  allowlistedUsers: number
  submittedOrders: number
  gamePlays: number
  issuedPoints: number
}

export type BroadcastKind = 'announcement' | 'product_new'
export type BroadcastStatus = 'draft' | 'published' | 'archived'

export interface Broadcast {
  id: string
  kind: BroadcastKind
  title: string
  message: string
  productId: string | null
  status: BroadcastStatus
  publishedAt: string | null
  createdAt: string
}

export type FeedbackStatus = 'pending' | 'published' | 'hidden'

export interface Feedback {
  id: string
  orderId: string
  rating: number
  message: string
  status: FeedbackStatus
  createdAt: string
}

export type KycDocumentType = 'document_front' | 'document_back' | 'selfie_with_document'
export type KycState = 'not_started' | 'collecting' | 'submitted' | 'approved' | 'rejected'

export interface KycStatus {
  status: KycState
  documents: KycDocumentType[]
  submittedAt: string | null
  rejectionReason: string | null
}

export interface KycReviewDocument {
  id: string
  documentType: KycDocumentType
  capturedAt: string
  signedUrl: string
}
