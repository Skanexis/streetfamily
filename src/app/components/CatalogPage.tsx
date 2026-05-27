import { useEffect, useState } from 'react'
import { AnimatePresence, motion } from 'motion/react'
import { ShoppingCart, Star, X } from 'lucide-react'
import type { CartItem, Feedback, Product, ProductVariant } from '../data'

type AddFn = (item: Omit<CartItem, 'id'>) => void
interface Props { products: Product[]; feedback: Feedback[]; addToCart: AddFn; selectedProductId: string | null; onProductSelect: (id: string | null) => void }
const minimumGrams = 25
const gramStep = 25

export function CatalogPage({ products, feedback, addToCart, selectedProductId, onProductSelect }: Props) {
  const [category, setCategory] = useState('Tutti')
  const categories = ['Tutti', ...Array.from(new Set(products.map(product => product.category)))]
  const shown = products.filter(product => category === 'Tutti' || product.category === category)
  return <div className="min-h-screen px-4 md:px-8 py-10" style={{ paddingTop: 100 }}>
    <div className="max-w-6xl mx-auto">
      <div className="sf-kicker mb-4">Catalogo</div>
      <h1 style={{ fontFamily: 'Space Grotesk', fontWeight: 700, fontSize: 36 }}>Collezioni</h1>
      <p style={{ color: 'rgba(245,245,245,.58)', margin: '8px 0 28px' }}>Prezzi per peso e scelta personalizzata in grammi.</p>
      <div className="flex gap-2 mb-8 overflow-x-auto">{categories.map(value => <button key={value} onClick={() => setCategory(value)} className="px-4 py-2" style={{ background: category === value ? '#D7FE55' : '#11181B', color: category === value ? '#080C0E' : '#F5F5F5', border: '1px solid rgba(126,156,168,.2)' }}>{value}</button>)}</div>
      <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">{shown.map(product => <Card key={product.id} product={product} onClick={() => onProductSelect(product.id)} />)}</div>
    </div>
    <AnimatePresence>{selectedProductId && <Detail product={products.find(product => product.id === selectedProductId)} feedback={feedback} onClose={() => onProductSelect(null)} addToCart={addToCart} />}</AnimatePresence>
  </div>
}

function Card({ product, onClick }: { product: Product; onClick: () => void }) {
  return <motion.button whileHover={{ y: -3 }} onClick={onClick} className="text-left overflow-hidden" style={panel}>
    {product.img ? <img src={product.img} alt={product.name} className="w-full object-cover" style={{ height: 176, background: '#182226' }} /> : <div className="flex items-center justify-center" style={{ height: 176, background: '#182226', color: 'rgba(245,245,245,.35)', fontFamily: 'Orbitron', fontSize: 11 }}>MEDIA</div>}
    <div className="p-4"><span style={kicker}>{product.category}</span><h2 style={{ fontFamily: 'Space Grotesk', fontWeight: 700, margin: '5px 0 12px' }}>{product.name}</h2><div className="flex justify-between"><span style={{ color: 'rgba(245,245,245,.55)', fontSize: 12 }}>da 25 g</span><strong style={{ color: '#D7FE55' }}>EUR {formatPrice(product.startingPrice)}</strong></div></div>
  </motion.button>
}

function Detail({ product, feedback, onClose, addToCart }: { product?: Product; feedback: Feedback[]; onClose: () => void; addToCart: AddFn }) {
  const initialGrams = product?.variants.find(item => item.available && item.unitAmount >= minimumGrams)?.unitAmount ?? minimumGrams
  const [customGrams, setCustomGrams] = useState(String(initialGrams))
  const [selectedMediaId, setSelectedMediaId] = useState(product?.media[0]?.id ?? '')
  const [added, setAdded] = useState(false)
  useEffect(() => {
    const previous = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => { document.body.style.overflow = previous }
  }, [])
  useEffect(() => {
    const firstWeight = product?.variants.find(item => item.available && item.unitAmount >= minimumGrams)?.unitAmount ?? minimumGrams
    setCustomGrams(String(firstWeight))
    setSelectedMediaId(product?.media[0]?.id ?? '')
  }, [product?.id])
  if (!product) return null
  const availableVariants = product.variants.filter(item => item.available).sort((a, b) => a.unitAmount - b.unitAmount)
  const selectableVariants = availableVariants.filter(item => item.unitAmount >= minimumGrams)
  const maximumGrams = selectableVariants[selectableVariants.length - 1]?.unitAmount ?? 0
  const grams = Number(customGrams)
  const price = calculatePrice(selectableVariants, grams)
  const validWeight = Number.isInteger(grams) && grams >= minimumGrams && grams <= maximumGrams && grams % gramStep === 0 && price !== null
  const variantsBelowWeight = selectableVariants.filter(item => item.unitAmount <= grams)
  const pricingVariant = variantsBelowWeight[variantsBelowWeight.length - 1]
  const tokenAward = pricingVariant?.tokenAward ?? 0
  if (maximumGrams < minimumGrams) return null
  const media = product.media.filter(item => item.url).slice(0, 8)
  const activeMedia = media.find(item => item.id === selectedMediaId) ?? media[0]
  const add = () => {
    if (!validWeight || price === null || !pricingVariant) return
    addToCart({ productId: product.id, variantId: pricingVariant.id, name: product.name, variantLabel: `${grams} g`, unitAmount: grams, tokenAward, price, img: product.img })
    setAdded(true); window.setTimeout(() => setAdded(false), 1200)
  }
  return <motion.div className="fixed inset-0 flex items-end md:items-center justify-center p-0 md:p-6" style={{ zIndex: 70, background: 'rgba(8,12,14,.88)' }} initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} onClick={onClose}>
    <motion.div className="w-full md:max-w-2xl overflow-y-auto p-4 md:p-6" style={{ ...panel, maxHeight: 'calc(100dvh - env(safe-area-inset-top, 0px) - env(safe-area-inset-bottom, 0px) - 12px)', paddingBottom: 'max(18px, env(safe-area-inset-bottom, 0px))' }} onClick={event => event.stopPropagation()} initial={{ y: 30 }} animate={{ y: 0 }}>
      <div className="flex items-start justify-between gap-3 mb-3">
        <div><span style={kicker}>{product.category}</span><h2 style={{ fontFamily: 'Space Grotesk', fontWeight: 700, fontSize: 25, margin: '5px 0 0' }}>{product.name}</h2></div>
        <button onClick={onClose} className="p-2" aria-label="Chiudi"><X size={20} /></button>
      </div>
      {activeMedia && <div className="mb-3">
        {activeMedia.type === 'video'
          ? <video src={activeMedia.url} controls playsInline preload="metadata" className="w-full object-cover" style={{ height: 210, background: '#080C0E' }} />
          : <img src={activeMedia.url} alt={activeMedia.alt ?? product.name} className="w-full object-cover" style={{ height: 210, background: '#080C0E' }} />}
        {media.length > 1 && <div className="flex gap-2 overflow-x-auto mt-2 pb-1">
          {media.map(item => <button key={item.id} onClick={() => setSelectedMediaId(item.id)} className="shrink-0 overflow-hidden" style={{ width: 58, height: 48, border: `1px solid ${activeMedia.id === item.id ? '#D7FE55' : 'rgba(126,156,168,.24)'}`, background: '#080C0E' }}>
            {item.type === 'video' ? <video src={item.url} muted playsInline preload="metadata" className="w-full h-full object-cover" /> : <img src={item.url} alt="" className="w-full h-full object-cover" />}
          </button>)}
        </div>}
      </div>}
      <p style={{ color: 'rgba(245,245,245,.6)', marginBottom: 14, fontSize: 13 }}>{product.description}</p>
      <div className="grid grid-cols-3 md:grid-cols-6 gap-2 mb-3">{availableVariants.map(variant => {
        const selectable = variant.unitAmount >= minimumGrams
        const selected = selectable && grams === variant.unitAmount
        return <button key={variant.id} disabled={!selectable} onClick={() => setCustomGrams(String(variant.unitAmount))} className="py-2 px-1" style={{ minHeight: 64, opacity: selectable ? 1 : .62, border: `1px solid ${selected ? '#D7FE55' : 'rgba(126,156,168,.2)'}`, background: selected ? 'rgba(215,254,85,.06)' : '#080C0E' }}><strong style={{ display: 'block', fontSize: 17 }}>{variant.unitAmount}g</strong><div style={{ color: '#D7FE55', marginTop: 2, fontSize: 13 }}>EUR {formatPrice(variant.price)}</div></button>
      })}</div>
      <label className="block mb-3" style={{ color: 'rgba(245,245,245,.65)', fontSize: 13 }}>
        Scegli i grammi (minimo {minimumGrams} g, multipli di {gramStep} g)
        <div className="flex items-center gap-3 mt-2">
          <input inputMode="numeric" pattern="[0-9]*" value={customGrams} onChange={event => setCustomGrams(event.target.value.replace(/\D/g, ''))} placeholder="0" style={weightInput} />
          <strong style={{ color: validWeight ? '#D7FE55' : '#EF4444' }}>{validWeight && price !== null ? `EUR ${formatPrice(price)}` : 'Peso non valido'}</strong>
        </div>
      </label>
      <div className="px-3 py-2 mb-3" style={{ background: 'rgba(215,254,85,.06)', color: '#D7FE55', fontSize: 13 }}>+{tokenAward} gettoni dopo un ordine completato</div>
      <button onClick={add} disabled={!validWeight} className="w-full py-3 flex justify-center gap-2" style={{ background: '#D7FE55', color: '#080C0E', fontWeight: 700, opacity: validWeight ? 1 : .5 }}><ShoppingCart size={18} />{added ? 'Aggiunto' : 'Aggiungi al carrello'}</button>
      <h3 style={{ fontFamily: 'Space Grotesk', fontSize: 19, fontWeight: 700, margin: '22px 0 12px' }}>Recensioni pubblicate dalla community</h3>
      {feedback.length === 0 && <p style={{ color: 'rgba(245,245,245,.5)' }}>Nessuna recensione pubblicata.</p>}
      {feedback.map(item => <div key={item.id} className="p-3 mb-2" style={{ background: '#080C0E' }}><div className="flex gap-1 mb-2">{Array.from({ length: item.rating }, (_, index) => <Star key={index} size={12} fill="#D7FE55" style={{ color: '#D7FE55' }} />)}</div><p style={{ fontSize: 13 }}>{item.message}</p></div>)}
    </motion.div>
  </motion.div>
}

function calculatePrice(variants: ProductVariant[], grams: number) {
  if (!Number.isInteger(grams) || grams < minimumGrams || grams % gramStep !== 0) return null
  const lowerVariants = variants.filter(variant => variant.unitAmount <= grams)
  const lower = lowerVariants[lowerVariants.length - 1]
  const upper = variants.find(variant => variant.unitAmount >= grams)
  if (!lower || !upper) return null
  if (lower.unitAmount === upper.unitAmount) return roundPrice(lower.price)
  const ratio = (grams - lower.unitAmount) / (upper.unitAmount - lower.unitAmount)
  return roundPrice(lower.price + ((upper.price - lower.price) * ratio))
}

function formatPrice(price: number) {
  return roundPrice(price).toLocaleString('it-IT', { maximumFractionDigits: 0 })
}

function roundPrice(price: number) {
  return Math.round(price / 5) * 5
}

const panel = { background: '#11181B', border: '1px solid rgba(126,156,168,.18)' }
const kicker = { color: '#B99361', fontSize: 10, fontFamily: 'Orbitron', letterSpacing: '.1em' }
const weightInput = { minWidth: 130, padding: '11px 12px', background: '#080C0E', border: '1px solid rgba(126,156,168,.28)', color: '#F5F5F5' }
