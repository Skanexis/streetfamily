import { motion } from 'motion/react'
import { ArrowRight, MapPin, Ticket, Truck } from 'lucide-react'
import type { CartItem, Level, Page, Product, User } from '../data'

interface Props {
  navigate: (page: Page) => void
  addToCart: (item: Omit<CartItem, 'id'>) => void
  user: User
  products: Product[]
  levels: Level[]
  onProductSelect: (id: string) => void
}

export function HomePage({ navigate, user, products, levels, onProductSelect }: Props) {
  const currentLevel = levels.find(level => level.level === user.level) ?? levels[0]
  const nextLevel = levels.find(level => level.level === user.level + 1)
  if (!currentLevel) return null
  const progress = nextLevel ? ((user.xp - currentLevel.xpMin) / (nextLevel.xpMin - currentLevel.xpMin)) * 100 : 100
  return <div style={{ paddingTop: 64 }}>
    <section className="relative overflow-hidden px-4 md:px-8 py-16 md:py-24" style={{ minHeight: 'calc(100vh - 92px)' }}>
      <div className="relative max-w-6xl mx-auto grid gap-12 lg:grid-cols-[1.1fr_.9fr] items-center">
        <div>
          <div className="sf-kicker mb-8">Closed community / demo environment</div>
          <motion.h1 initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} style={{ fontFamily: 'Orbitron', fontWeight: 900, fontSize: 'clamp(48px,9vw,92px)', lineHeight: .92, letterSpacing: '-.055em', marginBottom: 26 }}>STREET<br /><span style={{ color: '#D7FE55' }}>FAMILY</span></motion.h1>
          <p style={{ maxWidth: 490, color: 'rgba(245,245,245,.63)', fontSize: 21, lineHeight: 1.55, marginBottom: 36 }}>Catalogo dimostrativo, gettoni e rewards in un'area riservata. Nessuna operazione comporta pagamento o fulfillment reale.</p>
          <div className="flex gap-3 flex-wrap">
            <button onClick={() => navigate('catalog')} style={primary}>Esplora catalogo <ArrowRight size={16} /></button>
            <button onClick={() => navigate('info')} style={secondary}>Leggi regolamento</button>
          </div>
        </div>
        <aside className="p-7" style={panel}>
          <div className="sf-kicker mb-7">Member status</div>
          <div className="flex justify-between mb-8"><div><span style={caption}>Livello</span><h2 style={{ fontFamily: 'Space Grotesk', fontSize: 30, fontWeight: 700 }}>{currentLevel.name}</h2></div><strong style={{ color: '#D7FE55', fontFamily: 'Orbitron' }}>LV. {user.level}</strong></div>
          <div className="grid grid-cols-3 mb-8" style={{ border: '1px solid rgba(126,156,168,.16)' }}>
            {[[user.tokens, 'Gettoni'], [user.xp, 'XP'], [user.spinTickets, 'Ticket']].map(([value, label], index) => <div key={String(label)} className="py-5 text-center" style={{ borderLeft: index ? '1px solid rgba(126,156,168,.16)' : 'none' }}><strong style={{ color: '#D7FE55', fontFamily: 'Orbitron' }}>{value}</strong><div style={caption}>{label}</div></div>)}
          </div>
          {nextLevel && <><div className="flex justify-between mb-2" style={caption}><span>Verso {nextLevel.name}</span><span>{user.xp}/{nextLevel.xpMin} XP</span></div><div style={{ height: 3, background: 'rgba(245,245,245,.12)' }}><div style={{ height: '100%', width: `${Math.min(progress, 100)}%`, background: '#D7FE55' }} /></div></>}
        </aside>
      </div>
    </section>
    <section className="px-4 md:px-8 py-14"><div className="max-w-6xl mx-auto">
      <div className="flex justify-between mb-7"><div><div className="sf-kicker mb-3">Catalogo demo</div><h2 style={title}>Collections</h2></div><button onClick={() => navigate('catalog')} style={{ color: '#D7FE55' }}>Vedi tutto</button></div>
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">{products.slice(0, 4).map(product => <button key={product.id} onClick={() => { onProductSelect(product.id); navigate('catalog') }} className="text-left overflow-hidden" style={panel}>{product.img ? <img src={product.img} alt={product.name} className="w-full object-cover" style={{ height: 150 }} /> : <div className="flex justify-center items-center" style={{ height: 150, background: '#182226', color: 'rgba(245,245,245,.35)', fontFamily: 'Orbitron', fontSize: 10 }}>DEMO MEDIA</div>}<div className="p-4"><strong>{product.name}</strong><div style={{ ...caption, marginTop: 8 }}>da EUR {product.startingPrice} / 50 units</div></div></button>)}</div>
    </div></section>
    <section className="px-4 md:px-8 py-14"><div className="max-w-6xl mx-auto grid md:grid-cols-3 gap-4">
      <Info Icon={Ticket} title="Ruota dei premi" body="Un ticket gratuito ogni 5 scenari demo completati." onClick={() => navigate('games')} />
      <Info Icon={MapPin} title="Meet up demo" body="Selezione citta e minimi in units visibili nel regolamento." onClick={() => navigate('info')} />
      <Info Icon={Truck} title="Delivery demo" body="Dati di esempio e surcharge soltanto simulato." onClick={() => navigate('info')} />
    </div></section>
  </div>
}

function Info({ Icon, title, body, onClick }: { Icon: typeof Ticket; title: string; body: string; onClick: () => void }) {
  return <button onClick={onClick} className="p-6 text-left" style={panel}><Icon size={22} style={{ color: '#D7FE55', marginBottom: 17 }} /><h3 style={{ fontFamily: 'Space Grotesk', fontSize: 21, fontWeight: 700, marginBottom: 8 }}>{title}</h3><p style={{ color: 'rgba(245,245,245,.58)', lineHeight: 1.6 }}>{body}</p></button>
}
const panel = { background: '#11181B', border: '1px solid rgba(126,156,168,.18)' }
const primary = { display: 'inline-flex', alignItems: 'center', gap: 12, padding: '15px 25px', background: '#D7FE55', color: '#080C0E', fontWeight: 700 }
const secondary = { padding: '15px 25px', border: '1px solid rgba(245,245,245,.2)', background: '#11181B', fontWeight: 600 }
const title = { fontFamily: 'Space Grotesk', fontSize: 30, fontWeight: 700 }
const caption = { color: 'rgba(245,245,245,.5)', fontSize: 11, textTransform: 'uppercase' as const, letterSpacing: '.08em' }
