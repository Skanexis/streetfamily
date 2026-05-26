import { useMemo, useState } from 'react'
import { AnimatePresence, motion } from 'motion/react'
import { Check, ChevronLeft, ChevronRight, MapPin, Star, Trash2, Truck, X } from 'lucide-react'
import type { CartItem, KycStatus, OrderSubmitResult, ScenarioSelection, ScenarioType, ServiceArea } from '../data'
import { KycCapture } from './KycCapture'

interface Props {
  open: boolean
  onClose: () => void
  cart: CartItem[]
  removeFromCart: (id: string) => void
  tokens: number
  serviceAreas: ServiceArea[]
  firstOrder: boolean
  kycStatus: KycStatus
  onKycChanged: () => Promise<void>
  onSubmit: (selection: ScenarioSelection) => Promise<OrderSubmitResult>
  onComplete: () => Promise<void>
}

type Step = 'cart' | 'scenario' | 'details' | 'summary' | 'success'
const scenarios: { key: ScenarioType; label: string; Icon: typeof MapPin }[] = [
  { key: 'meetup', label: 'Incontro simulato', Icon: MapPin },
  { key: 'delivery_zone', label: 'Consegna in zona simulata', Icon: Truck },
  { key: 'delivery_italia', label: 'Consegna Italia simulata', Icon: Truck },
]

export function CartDrawer({ open, onClose, cart, removeFromCart, tokens, serviceAreas, firstOrder, kycStatus, onKycChanged, onSubmit, onComplete }: Props) {
  const [step, setStep] = useState<Step>('cart')
  const [scenarioType, setScenarioType] = useState<ScenarioType>('meetup')
  const [city, setCity] = useState('')
  const [street, setStreet] = useState('')
  const [tokensToReserve, setTokensToReserve] = useState(0)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const [result, setResult] = useState<OrderSubmitResult | null>(null)
  const [kycOpen, setKycOpen] = useState(false)
  const subtotal = cart.reduce((sum, item) => sum + item.price, 0)
  const totalUnits = cart.reduce((sum, item) => sum + item.unitAmount, 0)
  const tokenReward = totalUnits >= 1000 ? 50 : totalUnits >= 500 ? 30 : totalUnits >= 300 ? 20 : totalUnits >= 100 ? 10 : 5
  const surcharge = scenarioType === 'delivery_zone' ? Math.floor(totalUnits / 100) * 10 : 0
  const maximumReserve = Math.min(tokens, Math.floor(subtotal + surcharge))
  const selectedAreas = useMemo(() => serviceAreas.filter(area => area.scenarioType === scenarioType), [serviceAreas, scenarioType])
  const requiresKyc = firstOrder && kycStatus.status !== 'approved'

  const reset = () => {
    setStep('cart'); setScenarioType('meetup'); setCity(''); setStreet(''); setTokensToReserve(0); setError(''); setResult(null); setKycOpen(false)
  }
  const close = () => { onClose(); window.setTimeout(reset, 250) }
  const chooseScenario = (value: ScenarioType) => {
    setScenarioType(value); setCity(''); setStreet(''); setStep('details')
  }
  const continueDetails = () => {
    const min = scenarioType === 'delivery_italia' ? 500 : selectedAreas.find(area => area.city === city)?.minimumUnits
    if (totalUnits > 1000) return setError('La prima versione supporta al massimo 1000 g per richiesta dimostrativa.')
    if (!city.trim()) return setError('Seleziona o inserisci una città dimostrativa.')
    if ((scenarioType !== 'meetup') && !street.trim()) return setError('Inserisci una via di esempio per lo scenario dimostrativo.')
    if (min && totalUnits < min) return setError(`Questo scenario richiede almeno ${min} g.`)
    setError(''); setStep('summary')
  }
  const confirm = async () => {
    setSaving(true); setError('')
    try {
      const submitted = await onSubmit({ scenarioType, city, street, tokensToReserve })
      setResult(submitted); setStep('success'); await onComplete()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Impossibile inviare la richiesta dimostrativa.')
    } finally { setSaving(false) }
  }

  return (
    <AnimatePresence>
      {open && <>
        <motion.div className="fixed inset-0" style={{ zIndex: 70, background: 'rgba(0,0,0,.68)' }} initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} onClick={close} />
        <motion.div className="fixed right-0 top-0 bottom-0 flex flex-col w-full sm:max-w-md" style={{ zIndex: 71, paddingBottom: 'env(safe-area-inset-bottom, 0px)', background: '#080C0E', borderLeft: '1px solid rgba(126,156,168,.2)' }} initial={{ x: '100%' }} animate={{ x: 0 }} exit={{ x: '100%' }}>
          <header className="p-5 flex items-center gap-3" style={{ borderBottom: '1px solid rgba(245,245,245,.08)' }}>
            {!['cart', 'success'].includes(step) && <button onClick={() => setStep(step === 'summary' ? 'details' : step === 'details' ? 'scenario' : 'cart')}><ChevronLeft size={20} /></button>}
            <div className="flex-1"><strong style={{ fontFamily: 'Space Grotesk', fontSize: 20 }}>Richiesta</strong></div>
            <button onClick={close}><X size={20} /></button>
          </header>
          <div className="flex-1 overflow-y-auto p-5">
            {step === 'cart' && <div className="flex flex-col gap-3">
              {cart.length === 0 && <p style={muted}>Il carrello è vuoto.</p>}
              {cart.map(item => <div key={item.id} className="flex gap-3 p-3" style={panel}>
                {item.img ? <img src={item.img} alt={item.name} className="object-cover" style={{ width: 52, height: 52 }} /> : <div className="flex items-center justify-center" style={{ width: 52, height: 52, background: '#182226', color: 'rgba(245,245,245,.35)', fontSize: 9 }}>PROVA</div>}
                <div className="flex-1"><strong>{item.name}</strong><div style={muted}>{item.variantLabel}</div></div>
                <span>EUR {item.price}</span><button onClick={() => removeFromCart(item.id)} style={{ color: '#EF4444' }}><Trash2 size={16} /></button>
              </div>)}
              {cart.length > 0 && <div className="p-4" style={accent}><Star size={14} className="inline mr-2" />{totalUnits} g / +{tokenReward} gettoni soltanto dopo il completamento della prova</div>}
            </div>}
            {step === 'scenario' && <div className="flex flex-col gap-3">
              <p style={muted}>Seleziona unicamente uno scenario dimostrativo.</p>
              {scenarios.map(({ key, label, Icon }) => <button key={key} onClick={() => chooseScenario(key)} className="p-5 flex gap-4 text-left" style={panel}><Icon style={{ color: '#D7FE55' }} /><div><strong>{label}</strong><div style={muted}>Nessun servizio reale verrà richiesto</div></div></button>)}
            </div>}
            {step === 'details' && <div className="flex flex-col gap-4">
              <p style={accent}>Usa solo dati di esempio: questa è una prova dell'interfaccia.</p>
              <label style={muted}>Città dimostrativa</label>
              {scenarioType === 'delivery_italia'
                ? <input value={city} onChange={e => setCity(e.target.value)} placeholder="Città dimostrativa" style={input} />
                : <select value={city} onChange={e => setCity(e.target.value)} style={input}><option value="">Seleziona città</option>{selectedAreas.map(area => <option key={area.id} value={area.city}>{area.city} - min {area.minimumUnits} g</option>)}</select>}
              {scenarioType !== 'meetup' && <><label style={muted}>Via di esempio</label><input value={street} onChange={e => setStreet(e.target.value)} placeholder="Via dimostrativa" style={input} /></>}
              {error && <p style={{ color: '#EF4444' }}>{error}</p>}
            </div>}
            {step === 'summary' && <div className="flex flex-col gap-4">
              <div className="p-4" style={panel}><div style={muted}>SCENARIO DIMOSTRATIVO</div><strong>{scenarios.find(item => item.key === scenarioType)?.label}</strong><div>{city}{street && ` / ${street}`}</div></div>
              <Line label="Subtotale simulato" value={subtotal} />
              {surcharge > 0 && <Line label="Sovrapprezzo simulato" value={surcharge} />}
              <label style={muted}>Usa gettoni come credito dimostrativo (saldo: {tokens})</label>
              <input type="number" min={tokens >= 100 ? 1 : 0} max={maximumReserve} value={tokensToReserve} onChange={event => setTokensToReserve(Number(event.target.value))} style={input} />
              {tokens >= 100 && <p style={accent}>Saldo massimo raggiunto: usa almeno 1 gettone per inviare una nuova richiesta dimostrativa.</p>}
              <Line label="Totale simulato" value={Math.max(subtotal + surcharge - tokensToReserve, 0)} strong />
              {error && <p style={{ color: '#EF4444' }}>{error}</p>}
            </div>}
            {step === 'success' && result && <div className="text-center py-12"><Check size={50} style={{ color: '#D7FE55', margin: '0 auto 16px' }} /><h2 style={{ color: '#D7FE55', fontFamily: 'Orbitron' }}>RICHIESTA DIMOSTRATIVA INVIATA</h2><p>{result.displayId}</p><p style={muted}>{result.disclaimer}</p><div className="p-4 mt-6" style={panel}>EUR {result.simulatedTotal} / {result.totalUnits} g<br />+{result.tokensOnComplete} gettoni dopo il completamento</div></div>}
          </div>
          {step !== 'success' && cart.length > 0 && <footer className="p-5" style={{ borderTop: '1px solid rgba(245,245,245,.08)' }}>
            {step === 'cart' && <Action onClick={() => setStep('scenario')} label="Continua" />}
            {step === 'details' && <Action onClick={continueDetails} label="Riepilogo" />}
            {step === 'summary' && requiresKyc && <Action onClick={() => setKycOpen(true)} label="Verifica identità per continuare" />}
            {step === 'summary' && !requiresKyc && <Action onClick={confirm} label={saving ? 'Invio...' : 'Conferma richiesta dimostrativa'} disabled={saving} />}
          </footer>}
          {step === 'success' && <div className="p-5"><Action onClick={close} label="Chiudi" /></div>}
        </motion.div>
        <AnimatePresence>
          {kycOpen && (
            <>
              <motion.div className="fixed inset-0" style={{ zIndex: 80, background: 'rgba(0,0,0,.78)' }} initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} onClick={() => setKycOpen(false)} />
              <motion.div className="fixed inset-0 flex items-center justify-center p-4" style={{ zIndex: 81 }} initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: 20 }} onClick={() => setKycOpen(false)}>
                <div className="w-full max-w-lg overflow-y-auto p-5 rounded-2xl" style={{ ...panel, maxHeight: 'calc(100dvh - 32px)' }} onClick={event => event.stopPropagation()}>
                  <header className="flex justify-between items-start gap-3 mb-4">
                    <div><h2 style={{ fontFamily: 'Space Grotesk', fontSize: 23, fontWeight: 700 }}>Verifica identità</h2><p style={muted}>Richiesta prima della prima simulazione.</p></div>
                    <button onClick={() => setKycOpen(false)} aria-label="Chiudi verifica"><X size={20} /></button>
                  </header>
                  <KycCapture status={kycStatus} onChanged={onKycChanged} />
                  {kycStatus.status === 'approved' && <button onClick={() => setKycOpen(false)} className="w-full mt-4 py-3" style={{ background: '#D7FE55', color: '#080C0E', fontWeight: 700 }}>Torna al riepilogo</button>}
                </div>
              </motion.div>
            </>
          )}
        </AnimatePresence>
      </>}
    </AnimatePresence>
  )
}

function Line({ label, value, strong }: { label: string; value: number; strong?: boolean }) {
  return <div className="flex justify-between" style={strong ? { borderTop: '1px solid rgba(245,245,245,.12)', paddingTop: 14, color: '#D7FE55' } : undefined}><span>{label}</span><strong>EUR {value}</strong></div>
}
function Action({ onClick, label, disabled }: { onClick: () => void; label: string; disabled?: boolean }) {
  return <button onClick={onClick} disabled={disabled} className="w-full py-4 flex justify-center items-center gap-2" style={{ background: '#D7FE55', color: '#080C0E', fontWeight: 700, opacity: disabled ? .5 : 1 }}>{label}<ChevronRight size={16} /></button>
}
const panel = { background: '#11181B', border: '1px solid rgba(126,156,168,.2)' }
const muted = { color: 'rgba(245,245,245,.58)', fontSize: 13 }
const accent = { color: '#D7FE55', background: 'rgba(215,254,85,.06)', border: '1px solid rgba(215,254,85,.2)' }
const input = { background: '#11181B', border: '1px solid rgba(126,156,168,.28)', color: '#F5F5F5', padding: '12px 13px' }
