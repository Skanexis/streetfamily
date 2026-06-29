import { Camera, MessageSquareText, PackageCheck, Quote, Star, TicketCheck } from 'lucide-react'
import type { ReviewFeedback, ReviewProduct, ReviewScreenshot, ReviewsWallData } from '../data'

interface Props {
  reviews: ReviewsWallData
  onProductSelect: (productId: string) => void
}

export function ReviewsPage({ reviews, onProductSelect }: Props) {
  const totalReviews = reviews.feedback.length + reviews.screenshots.length
  const averageRating = reviews.feedback.length
    ? reviews.feedback.reduce((sum, item) => sum + item.rating, 0) / reviews.feedback.length
    : 0
  const featured = reviews.feedback[0]

  return (
    <div className="min-h-screen px-4 md:px-8 py-10" style={{ paddingTop: 100 }}>
      <div className="max-w-6xl mx-auto">
        <div className="sf-kicker mb-4">Recensioni</div>
        <section className="grid lg:grid-cols-[1.15fr_.85fr] gap-4 mb-6">
          <div className="p-5 md:p-7" style={heroPanel}>
            <div className="inline-flex items-center gap-2 px-3 py-2 mb-5" style={heroBadge}>
              <Star size={14} fill="#D7FE55" /> Community verificata
            </div>
            <h1 style={heading}>Esperienze reali, prodotti verificati.</h1>
            <p style={copy}>Ogni recensione pubblicata resta collegata al prodotto ordinato e all’ordine completato.</p>
            <div className="grid grid-cols-3 gap-2 mt-6">
              <Metric Icon={MessageSquareText} value={totalReviews} label="storie" />
              <Metric Icon={Star} value={averageRating ? averageRating.toFixed(1) : '0.0'} label="media" />
              <Metric Icon={Camera} value={reviews.screenshots.length} label="chat" />
            </div>
          </div>
          <div className="p-5 md:p-6" style={featurePanel}>
            <div className="flex items-center gap-2 mb-3" style={{ color: '#D7FE55', fontSize: 12, fontWeight: 700 }}>
              <TicketCheck size={16} /> Ultima recensione verificata
            </div>
            {featured ? <ReviewCard review={featured} onProductSelect={onProductSelect} compact /> : <p style={copy}>Le recensioni pubblicate appariranno qui dopo la moderazione.</p>}
          </div>
        </section>

        {reviews.feedback.length > 0 && (
          <section className="mb-8">
            <div className="flex items-center justify-between gap-3 mb-3">
              <h2 style={sectionTitle}>Recensioni dai prodotti</h2>
              <span style={subtle}>{reviews.feedback.length} pubblicate</span>
            </div>
            <div className="grid md:grid-cols-2 xl:grid-cols-3 gap-4">
              {reviews.feedback.map(review => <ReviewCard key={review.id} review={review} onProductSelect={onProductSelect} />)}
            </div>
          </section>
        )}

        {reviews.screenshots.length > 0 && (
          <section>
            <div className="flex items-center justify-between gap-3 mb-3">
              <h2 style={sectionTitle}>Screenshot dalle chat</h2>
              <span style={subtle}>caricati dall’amministrazione</span>
            </div>
            <div className="grid sm:grid-cols-2 lg:grid-cols-3 gap-4">
              {reviews.screenshots.map(item => <ScreenshotCard key={item.id} item={item} onProductSelect={onProductSelect} />)}
            </div>
          </section>
        )}

        {totalReviews === 0 && (
          <section className="p-6 text-center" style={panel}>
            <MessageSquareText size={28} style={{ color: '#D7FE55', margin: '0 auto 12px' }} />
            <h2 style={{ ...sectionTitle, marginBottom: 6 }}>Nessuna recensione pubblicata</h2>
            <p style={copy}>Quando un ordine completato riceve una recensione approvata, comparirà in questa pagina.</p>
          </section>
        )}
      </div>
    </div>
  )
}

function ReviewCard({ review, onProductSelect, compact = false }: { review: ReviewFeedback; onProductSelect: (productId: string) => void; compact?: boolean }) {
  return (
    <article className="p-4 relative overflow-hidden" style={reviewPanel}>
      <div style={cardAccent} />
      <div className="flex items-start justify-between gap-3 mb-3">
        <div className="min-w-0 flex items-center gap-3">
          <div className="shrink-0 flex items-center justify-center" style={avatarCircle}>
            {(review.username ?? 'S').slice(0, 1).toUpperCase()}
          </div>
          <div className="min-w-0">
            <div className="flex gap-1 mt-1" aria-label={`${review.rating} stelle`}>
            {Array.from({ length: 5 }, (_, index) => (
              <Star key={index} size={14} fill={index < review.rating ? '#D7FE55' : 'transparent'} style={{ color: index < review.rating ? '#D7FE55' : 'rgba(245,245,245,.28)' }} />
            ))}
            </div>
          </div>
        </div>
        <div className="text-right" style={subtle}>
          <div>{review.order.displayId}</div>
          <div>{formatDate(review.createdAt)}</div>
        </div>
      </div>
      <div className="flex items-center gap-2 mb-2" style={verifiedLine}>
        <TicketCheck size={14} /> Ordine completato / {review.order.totalUnits} g
      </div>
      <div className="relative">
        <Quote size={22} style={quoteMark} />
        <p style={{ ...messageText, WebkitLineClamp: compact ? 4 : undefined }}>{review.message}</p>
      </div>
      <div className="flex flex-wrap gap-2 mt-4">
        {review.products.map((product, index) => <ProductChip key={product.id ?? `${product.name}-${index}`} product={product} onProductSelect={onProductSelect} />)}
      </div>
      <div className="grid grid-cols-2 gap-2 mt-4">
        <OrderFact label="Ordine" value={review.order.displayId} />
        <OrderFact label="Quantità" value={`${review.order.totalUnits} g`} />
      </div>
    </article>
  )
}

function ScreenshotCard({ item, onProductSelect }: { item: ReviewScreenshot; onProductSelect: (productId: string) => void }) {
  return (
    <article className="overflow-hidden" style={panel}>
      <div style={{ aspectRatio: '4 / 5', background: '#080C0E' }}>
        {item.imageUrl
          ? <img src={item.imageUrl} alt={item.message || 'Screenshot recensione chat'} className="w-full h-full object-cover" />
          : <div className="w-full h-full flex items-center justify-center" style={subtle}>Screenshot</div>}
      </div>
      <div className="p-4">
        <div className="flex items-center gap-2 mb-2" style={{ color: '#D7FE55', fontSize: 12, fontWeight: 700 }}>
          <Camera size={15} /> Chat cliente
        </div>
        <strong>{item.customerLabel || 'Cliente'}</strong>
        {item.message && <p style={{ ...messageText, marginTop: 8 }}>{item.message}</p>}
        {item.product && <div className="mt-3"><ProductChip product={item.product} onProductSelect={onProductSelect} /></div>}
        {item.orderLabel && <div className="mt-3" style={subtle}>Ordine: {item.orderLabel}</div>}
      </div>
    </article>
  )
}

function ProductChip({ product, onProductSelect }: { product: ReviewProduct; onProductSelect: (productId: string) => void }) {
  const content = (
    <>
      <PackageCheck size={14} />
      <span>{product.name}</span>
      {product.variantLabels.length > 0 && <small>{product.variantLabels.join(', ')}</small>}
    </>
  )
  if (!product.id) {
    return (
      <span className="inline-flex items-center gap-2 px-3 py-2" style={archivedProductChip} title="Prodotto non più presente nel catalogo">
        {content}
      </span>
    )
  }
  return (
    <button type="button" onClick={() => onProductSelect(product.id!)} className="inline-flex items-center gap-2 px-3 py-2" style={productChip}>
      {content}
    </button>
  )
}

function Metric({ Icon, value, label }: { Icon: typeof Star; value: string | number; label: string }) {
  return <div className="p-3" style={metric}><Icon size={16} style={{ color: '#D7FE55', marginBottom: 9 }} /><strong>{value}</strong><div>{label}</div></div>
}

function OrderFact({ label, value }: { label: string; value: string }) {
  return <div className="p-3" style={fact}><span>{label}</span><strong>{value}</strong></div>
}

function formatDate(value: string) {
  return value ? new Date(value).toLocaleDateString('it-IT') : ''
}

const panel = { background: '#11181B', border: '1px solid rgba(126,156,168,.18)', borderRadius: 8 }
const heroPanel = { ...panel, background: 'linear-gradient(135deg, rgba(17,24,27,.98), rgba(30,39,42,.98))' }
const featurePanel = { ...panel, background: 'rgba(215,254,85,.055)' }
const reviewPanel = { ...panel, boxShadow: '0 16px 42px rgba(0,0,0,.22)' }
const cardAccent = { position: 'absolute' as const, left: 0, top: 0, bottom: 0, width: 3, background: '#D7FE55' }
const heroBadge = { background: 'rgba(215,254,85,.08)', border: '1px solid rgba(215,254,85,.22)', color: '#D7FE55', borderRadius: 8, fontSize: 12, fontWeight: 700 }
const avatarCircle = { width: 38, height: 38, borderRadius: 8, background: 'rgba(215,254,85,.12)', border: '1px solid rgba(215,254,85,.2)', color: '#D7FE55', fontFamily: 'Orbitron', fontWeight: 800 }
const verifiedLine = { color: 'rgba(215,254,85,.82)', fontSize: 12, fontWeight: 700 }
const quoteMark = { position: 'absolute' as const, right: 0, top: -4, color: 'rgba(215,254,85,.16)' }
const heading = { fontFamily: 'Space Grotesk', fontSize: 'clamp(32px, 6vw, 58px)', lineHeight: 1, fontWeight: 800, letterSpacing: 0 }
const sectionTitle = { fontFamily: 'Space Grotesk', fontSize: 24, fontWeight: 700 }
const copy = { color: 'rgba(245,245,245,.63)', fontSize: 14, lineHeight: 1.65, marginTop: 14 }
const subtle = { color: 'rgba(245,245,245,.52)', fontSize: 12 }
const messageText = { color: 'rgba(245,245,245,.86)', fontSize: 14, lineHeight: 1.62, whiteSpace: 'pre-wrap' as const, overflowWrap: 'anywhere' as const, display: '-webkit-box', WebkitBoxOrient: 'vertical' as const, overflow: 'hidden' }
const metric = { background: 'rgba(8,12,14,.55)', border: '1px solid rgba(126,156,168,.18)', borderRadius: 8, color: 'rgba(245,245,245,.64)', fontSize: 12 }
const fact = { background: '#080C0E', border: '1px solid rgba(126,156,168,.12)', borderRadius: 8, color: 'rgba(245,245,245,.52)', fontSize: 11 }
const productChip = { background: 'rgba(215,254,85,.08)', border: '1px solid rgba(215,254,85,.2)', color: '#D7FE55', borderRadius: 8, fontSize: 12 }
const archivedProductChip = { ...productChip, background: 'rgba(126,156,168,.08)', border: '1px solid rgba(126,156,168,.18)', color: 'rgba(245,245,245,.72)' }
