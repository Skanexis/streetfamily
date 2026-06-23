import { useState } from 'react'
import { motion } from 'motion/react'
import { Package, ShieldCheck, Star, Ticket, Trophy } from 'lucide-react'
import type { LedgerEntry, Level, TestOrder, User, UserReward } from '../data'
import { submitFeedback } from '../lib/api'
import { italianErrorMessage } from '../lib/errors'

interface Props { user: User; levels: Level[]; orders: TestOrder[]; ledger: LedgerEntry[]; rewards: UserReward[]; onChanged: () => Promise<void>; onAdmin?: () => void }
type Tab = 'orders' | 'tokens' | 'levels'
const statusLabel = { submitted: 'Inviato', processing: 'In revisione', completed: 'Completato', cancelled: 'Annullato' }
const feedbackLabel = { pending: 'In moderazione', published: 'Pubblicata', hidden: 'Nascosta' }

export function ProfilePage({ user, levels, orders, ledger, rewards, onChanged, onAdmin }: Props) {
  const [tab, setTab] = useState<Tab>('orders')
  const current = levels.find(level => level.level === user.level) ?? levels[0]
  if (!current) return null
  const totalTickets = user.spinTickets + user.scratchTickets
  return <div className="min-h-screen px-4 md:px-8 py-10" style={{ paddingTop: 100 }}>
    <div className="max-w-2xl mx-auto">
      <div className="sf-kicker mb-5">Profilo</div>
      <section className="p-6 mb-7" style={panel}>
        <h1 style={{ fontFamily: 'Orbitron', fontSize: 25 }}>@{user.name}</h1>
        <p style={{ color: '#D7FE55', margin: '7px 0 22px' }}>{current.name} / LV. {user.level}</p>
        {user.role === 'admin' && <button onClick={onAdmin} className="mb-5 px-4 py-3 flex items-center gap-2" style={notice}><ShieldCheck size={17} /> Amministratore / Apri pannello amministrazione</button>}
        <div className="grid grid-cols-3 gap-3">
          <Stat Icon={Star} value={user.tokens} label="Gettoni" />
          <Stat Icon={Ticket} value={totalTickets} label="Biglietti" />
          <Stat Icon={Package} value={user.completedOrders} label="Completati" />
        </div>
        {user.tokens >= 100 && <p className="p-3 mt-5" style={notice}>Limite gettoni raggiunto: negli ordini puoi usarli come sconto fino al 5% del totale.</p>}
      </section>
      <div className="flex gap-2 mb-6">{([['orders', 'Richieste', Package], ['tokens', 'Gettoni', Star], ['levels', 'Livelli', Trophy]] as const).map(([id, label, Icon]) => <button key={id} onClick={() => setTab(id)} className="flex-1 py-3 flex justify-center gap-2" style={{ ...panel, color: tab === id ? '#D7FE55' : '#F5F5F5' }}><Icon size={16} />{label}</button>)}</div>
      {tab === 'orders' && <div className="flex flex-col gap-3">{orders.map(order => <OrderCard key={order.id} order={order} onChanged={onChanged} />)}</div>}
      {tab === 'tokens' && <div>
        <div className="p-5 mb-5" style={notice}><strong style={{ fontFamily: 'Orbitron', fontSize: 34 }}>{user.tokens}</strong><div>Gettoni disponibili / massimo 100</div></div>
        {ledger.map(entry => <div key={entry.id} className="p-3 flex justify-between mb-2" style={panel}><div>{entry.reason}<div style={small}>{new Date(entry.createdAt).toLocaleDateString('it-IT')}</div></div><strong style={{ color: '#D7FE55' }}>{entry.tokens > 0 ? '+' : ''}{entry.tokens}</strong></div>)}
      </div>}
      {tab === 'levels' && <div className="flex flex-col gap-3">{levels.map(level => <div key={level.id} className="p-4 flex justify-between" style={panel}><strong>{level.name}</strong><span style={{ color: level.level <= user.level ? '#D7FE55' : 'rgba(245,245,245,.4)' }}>LV. {level.level} / {level.xpMin} XP</span></div>)}</div>}
      {rewards.length > 0 && <section className="p-5 mt-7" style={panel}><h2 style={{ fontWeight: 700, marginBottom: 12 }}>Premi attivi</h2>{rewards.filter(reward => reward.state === 'available').map(reward => <div key={reward.id}>{reward.label}</div>)}</section>}
    </div>
  </div>
}

function OrderCard({ order, onChanged }: { order: TestOrder; onChanged: () => Promise<void> }) {
  const [open, setOpen] = useState(false)
  const [rating, setRating] = useState(5)
  const [message, setMessage] = useState('')
  const [error, setError] = useState('')
  const send = async () => {
    try { await submitFeedback(order.id, rating, message); setOpen(false); await onChanged() }
    catch (caught) { setError(italianErrorMessage(caught, 'Recensione non salvata.')) }
  }
  return <motion.div initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} className="p-4" style={panel}>
    <div className="flex justify-between mb-2"><strong>{order.displayId}</strong><span style={{ color: order.status === 'completed' ? '#D7FE55' : '#B99361' }}>{statusLabel[order.status]}</span></div>
    <p style={small}>{order.totalUnits} g / EUR {order.total}</p>
    <div className="flex gap-2 flex-wrap my-3">{order.items.map(item => <span key={item} style={tag}>{item}</span>)}</div>
    {order.status === 'completed' && !order.feedbackStatus && <button onClick={() => setOpen(value => !value)} style={{ color: '#D7FE55' }}>Lascia una recensione</button>}
    {order.feedbackStatus && <span style={small}>Recensione: {feedbackLabel[order.feedbackStatus]}</span>}
    {open && <div className="mt-4 flex flex-col gap-3"><select value={rating} onChange={e => setRating(Number(e.target.value))} style={input}>{[5, 4, 3, 2, 1].map(value => <option key={value} value={value}>{value} stelle</option>)}</select><textarea value={message} onChange={e => setMessage(e.target.value)} maxLength={500} placeholder="Recensione sull'ordine" style={input} /><button onClick={send} style={{ background: '#D7FE55', color: '#080C0E', padding: 10, fontWeight: 700 }}>Invia per moderazione</button>{error && <span style={{ color: '#EF4444' }}>{error}</span>}</div>}
  </motion.div>
}
function Stat({ Icon, value, label }: { Icon: typeof Star; value: number; label: string }) { return <div className="p-3 text-center" style={notice}><Icon size={16} style={{ color: '#D7FE55', margin: '0 auto 7px' }} /><strong>{value}</strong><div style={small}>{label}</div></div> }
const panel = { background: '#11181B', border: '1px solid rgba(126,156,168,.18)' }
const notice = { background: 'rgba(215,254,85,.06)', border: '1px solid rgba(215,254,85,.2)', color: '#D7FE55' }
const small = { color: 'rgba(245,245,245,.52)', fontSize: 12 }
const tag = { background: 'rgba(126,156,168,.12)', padding: '4px 8px', fontSize: 12 }
const input = { padding: 10, background: '#080C0E', color: '#F5F5F5', border: '1px solid rgba(126,156,168,.25)' }
