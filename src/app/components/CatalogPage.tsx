import { useEffect, useState } from 'react'
import { AnimatePresence, motion } from 'motion/react'
import { ShoppingCart, Star, X } from 'lucide-react'
import type { CartItem, Feedback, Product, ProductVariant } from '../data'

type AddFn = (item: Omit<CartItem, 'id'>) => void
interface Props { products: Product[]; feedback: Feedback[]; addToCart: AddFn; selectedProductId: string | null; onProductSelect: (id: string | null) => void }

export function CatalogPage({ products, feedback, addToCart, selectedProductId, onProductSelect }: Props) {
  const [category, setCategory] = useState('Tutti')
  const categories = ['Tutti', ...Array.from(new Set(products.map(product => product.category)))]
  const shown = products.filter(product => category === 'Tutti' || product.category === category)
  return <div className="min-h-screen px-4 md:px-8 py-10" style={{ paddingTop: 100 }}>
    <div className="max-w-6xl mx-auto">
      <div className="sf-kicker mb-4">Catalogo demo</div>
      <h1 style={{ fontFamily: 'Space Grotesk', fontWeight: 700, fontSize: 36 }}>Demo collections</h1>
      <p style={{ color: 'rgba(245,245,245,.58)', margin: '8px 0 28px' }}>Pacchetti in units per testare richieste e rewards. Nessuna vendita o consegna reale.</p>
      <div className="flex gap-2 mb-8 overflow-x-auto">{categories.map(value => <button key={value} onClick={() => setCategory(value)} className="px-4 py-2" style={{ background: category === value ? '#D7FE55' : '#11181B', color: category === value ? '#080C0E' : '#F5F5F5', border: '1px solid rgba(126,156,168,.2)' }}>{value}</button>)}</div>
      <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">{shown.map(product => <Card key={product.id} product={product} onClick={() => onProductSelect(product.id)} />)}</div>
    </div>
    <AnimatePresence>{selectedProductId && <Detail product={products.find(product => product.id === selectedProductId)} feedback={feedback} onClose={() => onProductSelect(null)} addToCart={addToCart} />}</AnimatePresence>
  </div>
}

function Card({ product, onClick }: { product: Product; onClick: () => void }) {
  return <motion.button whileHover={{ y: -3 }} onClick={onClick} className="text-left overflow-hidden" style={panel}>
    {product.img ? <img src={product.img} alt={product.name} className="w-full object-cover" style={{ height: 176, background: '#182226' }} /> : <div className="flex items-center justify-center" style={{ height: 176, background: '#182226', color: 'rgba(245,245,245,.35)', fontFamily: 'Orbitron', fontSize: 11 }}>DEMO MEDIA</div>}
    <div className="p-4"><span style={kicker}>{product.category}</span><h2 style={{ fontFamily: 'Space Grotesk', fontWeight: 700, margin: '5px 0 12px' }}>{product.name}</h2><div className="flex justify-between"><span style={{ color: 'rgba(245,245,245,.55)', fontSize: 12 }}>da 50 units</span><strong style={{ color: '#D7FE55' }}>EUR {product.startingPrice}</strong></div></div>
  </motion.button>
}

function Detail({ product, feedback, onClose, addToCart }: { product?: Product; feedback: Feedback[]; onClose: () => void; addToCart: AddFn }) {
  const [selected, setSelected] = useState<ProductVariant | undefined>(product?.variants.find(item => item.available))
  const [selectedMediaId, setSelectedMediaId] = useState(product?.media[0]?.id ?? '')
  const [added, setAdded] = useState(false)
  useEffect(() => {
    const previous = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => { document.body.style.overflow = previous }
  }, [])
  if (!product || !selected) return null
  const media = product.media.filter(item => item.url).slice(0, 8)
  const activeMedia = media.find(item => item.id === selectedMediaId) ?? media[0]
  const add = () => {
    addToCart({ productId: product.id, variantId: selected.id, name: product.name, variantLabel: selected.label, unitAmount: selected.unitAmount, tokenAward: selected.tokenAward, price: selected.price, img: product.img })
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
      <div className="grid grid-cols-3 md:grid-cols-5 gap-2 mb-3">{product.variants.filter(item => item.available).map(variant => <button key={variant.id} onClick={() => setSelected(variant)} className="py-2 px-1" style={{ minHeight: 64, border: `1px solid ${selected.id === variant.id ? '#D7FE55' : 'rgba(126,156,168,.2)'}`, background: selected.id === variant.id ? 'rgba(215,254,85,.06)' : '#080C0E' }}><strong style={{ display: 'block', fontSize: 17 }}>{variant.unitAmount}</strong><span style={{ fontSize: 10, color: 'rgba(245,245,245,.58)' }}>units</span><div style={{ color: '#D7FE55', marginTop: 2, fontSize: 13 }}>EUR {variant.price}</div></button>)}</div>
      <div className="px-3 py-2 mb-3" style={{ background: 'rgba(215,254,85,.06)', color: '#D7FE55', fontSize: 13 }}>+{selected.tokenAward} gettoni dopo uno scenario completato</div>
      <button onClick={add} className="w-full py-3 flex justify-center gap-2" style={{ background: '#D7FE55', color: '#080C0E', fontWeight: 700 }}><ShoppingCart size={18} />{added ? 'Aggiunto' : 'Aggiungi alla richiesta demo'}</button>
      <h3 style={{ fontFamily: 'Space Grotesk', fontSize: 19, fontWeight: 700, margin: '22px 0 12px' }}>Feedback community pubblicati</h3>
      {feedback.length === 0 && <p style={{ color: 'rgba(245,245,245,.5)' }}>Nessun feedback pubblicato.</p>}
      {feedback.map(item => <div key={item.id} className="p-3 mb-2" style={{ background: '#080C0E' }}><div className="flex gap-1 mb-2">{Array.from({ length: item.rating }, (_, index) => <Star key={index} size={12} fill="#D7FE55" style={{ color: '#D7FE55' }} />)}</div><p style={{ fontSize: 13 }}>{item.message}</p></div>)}
    </motion.div>
  </motion.div>
}

const panel = { background: '#11181B', border: '1px solid rgba(126,156,168,.18)' }
const kicker = { color: '#B99361', fontSize: 10, fontFamily: 'Orbitron', letterSpacing: '.1em' }
