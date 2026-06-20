import { useMemo, useState } from 'react'
import { AnimatePresence, motion } from 'motion/react'
import { Check, ChevronLeft, ChevronRight, MapPin, Star, Trash2, Truck, X } from 'lucide-react'
import type { CartItem, KycStatus, OrderSubmitResult, ScenarioSelection, ScenarioType, ServiceArea } from '../data'
import { KycCapture } from './KycCapture'
import { italianErrorMessage } from '../lib/errors'

interface Props {
  open: boolean
  onClose: () => void
  cart: CartItem[]
  removeFromCart: (id: string) => void
  tokens: number
  serviceAreas: ServiceArea[]
  firstOrder: boolean
  isAdmin: boolean
  kycStatus: KycStatus
  onKycChanged: () => Promise<void>
  onSubmit: (selection: ScenarioSelection) => Promise<OrderSubmitResult>
  onComplete: () => Promise<void>
}

type Step = 'cart' | 'scenario' | 'details' | 'summary' | 'success'
const scenarios: { key: ScenarioType; label: string; Icon: typeof MapPin }[] = [
  { key: 'meetup', label: 'MEETUP', Icon: MapPin },
  { key: 'delivery_zone', label: 'DELIVERY LOCALE', Icon: Truck },
  { key: 'delivery_italia', label: 'DELIVERY TUTTA ITALIA', Icon: Truck },
]

function tokenRewardForUnits(units: number) {
  if (units >= 5000) return 100
  if (units >= 3000) return 70
  if (units >= 1000) return 50
  if (units >= 500) return 30
  if (units >= 300) return 20
  if (units >= 100) return 10
  return units >= 50 ? 5 : 0
}

export function CartDrawer({ open, onClose, cart, removeFromCart, tokens, serviceAreas, firstOrder, isAdmin, kycStatus, onKycChanged, onSubmit, onComplete }: Props) {
  const [step, setStep] = useState<Step>('cart')
  const [scenarioType, setScenarioType] = useState<ScenarioType>('meetup')
  const [city, setCity] = useState('')
  const [street, setStreet] = useState('')
  const [tokensToReserve, setTokensToReserve] = useState('')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const [result, setResult] = useState<OrderSubmitResult | null>(null)
  const [kycOpen, setKycOpen] = useState(false)
  const subtotal = cart.reduce((sum, item) => sum + item.price, 0)
  const totalUnits = cart.reduce((sum, item) => sum + item.unitAmount, 0)
  const tokenReward = tokenRewardForUnits(totalUnits)
  const surcharge = scenarioType === 'delivery_zone' ? Math.floor(totalUnits / 100) * 10 : 0
  const grossTotal = subtotal + surcharge
  const maximumReserve = Math.min(tokens, Math.floor(grossTotal * 0.05))
  const reservedTokens = tokensToReserve === '' ? 0 : Number(tokensToReserve)
  const displayedTokenCredit = Number.isInteger(reservedTokens) && reservedTokens > 0 ? Math.min(reservedTokens, maximumReserve) : 0
  const selectedAreas = useMemo(() => serviceAreas.filter(area => area.scenarioType === scenarioType), [serviceAreas, scenarioType])
  const requiresKyc = !isAdmin && firstOrder && kycStatus.status !== 'approved'

  const reset = () => {
    setStep('cart'); setScenarioType('meetup'); setCity(''); setStreet(''); setTokensToReserve(''); setError(''); setResult(null); setKycOpen(false)
  }
  const close = () => { onClose(); window.setTimeout(reset, 250) }
  const chooseScenario = (value: ScenarioType) => {
    setScenarioType(value); setCity(''); setStreet(''); setStep('details')
  }
  const continueDetails = () => {
    const min = scenarioMinimum(serviceAreas, scenarioType, city)
    if (totalUnits > 5000) return setError('Sono supportati al massimo 5000 g per ordine.')
    if (!city.trim()) return setError('Seleziona o inserisci una città.')
    if (scenarioType !== 'delivery_italia' && !selectedAreas.some(area => area.city === city)) return setError('Città non disponibile.')
    if ((scenarioType !== 'meetup') && !street.trim()) return setError('Inserisci una via.')
    if (min && totalUnits < min) return setError(`Questo servizio richiede almeno ${min} g.`)
    setError(''); setStep('summary')
  }
  const confirm = async () => {
    if (!Number.isInteger(reservedTokens) || reservedTokens < 0 || reservedTokens > maximumReserve) {
      setError(`Inserisci un numero intero di gettoni da 0 a ${maximumReserve}.`)
      return
    }
    setSaving(true); setError('')
    try {
      const submitted = await onSubmit({ scenarioType, city, street, tokensToReserve: reservedTokens })
      setResult(submitted); setStep('success'); await onComplete()
    } catch (caught) {
      setError(italianErrorMessage(caught, 'Impossibile inviare la richiesta.'))
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
                {item.img ? <img src={item.img} alt={item.name} className="object-cover" style={{ width: 52, height: 52 }} /> : <div className="flex items-center justify-center" style={{ width: 52, height: 52, background: '#182226', color: 'rgba(245,245,245,.35)', fontSize: 9 }}>MEDIA</div>}
                <div className="flex-1"><strong>{item.name}</strong><div style={muted}>{item.variantLabel}</div></div>
                <span>EUR {item.price}</span><button onClick={() => removeFromCart(item.id)} style={{ color: '#EF4444' }}><Trash2 size={16} /></button>
              </div>)}
              {cart.length > 0 && <div className="p-4" style={accent}><Star size={14} className="inline mr-2" />{totalUnits} g / +{tokenReward} gettoni dopo il completamento dell'ordine</div>}
            </div>}
            {step === 'scenario' && <div className="flex flex-col gap-3">
              <p style={muted}>Seleziona un servizio.</p>
              {scenarios.map(({ key, label, Icon }) => <button key={key} onClick={() => chooseScenario(key)} className="p-5 flex gap-4 text-left" style={panel}><Icon style={{ color: '#D7FE55' }} /><div><strong>{label}</strong><ServiceMinimum service={key} serviceAreas={serviceAreas} /></div></button>)}
            </div>}
            {step === 'details' && <div className="flex flex-col gap-4">
              <div>
                <div style={muted}>Città</div>
                {scenarioType !== 'delivery_italia' && <p style={{ ...muted, marginTop: 5 }}>Scegli la zona disponibile per questo servizio.</p>}
              </div>
              {scenarioType === 'delivery_italia'
                ? <input value={city} onChange={e => setCity(e.target.value)} placeholder="Città" style={input} />
                : <div className="grid grid-cols-2 gap-2">
                    {selectedAreas.map(area => {
                      const selected = city === area.city
                      return (
                        <button
                          key={area.id}
                          type="button"
                          onClick={() => { setCity(area.city); setError('') }}
                          className="p-3 text-left rounded-xl min-w-0"
                          style={{
                            background: selected ? 'rgba(215,254,85,.09)' : '#11181B',
                            border: `1px solid ${selected ? '#D7FE55' : 'rgba(126,156,168,.24)'}`,
                          }}
                        >
                          <div className="flex items-center justify-between gap-1">
                            <strong className="truncate" style={{ fontSize: 14 }}>{area.city}</strong>
                            {selected && <Check size={15} style={{ flexShrink: 0, color: '#D7FE55' }} />}
                          </div>
                          <div style={{ ...muted, marginTop: 4 }}>Minimo {area.minimumUnits} g</div>
                        </button>
                      )
                    })}
                  </div>}
              {scenarioType !== 'meetup' && <><label style={muted}>Via</label><input value={street} onChange={e => setStreet(e.target.value)} placeholder="Via" style={input} /></>}
              {error && <p style={{ color: '#EF4444' }}>{error}</p>}
            </div>}
            {step === 'summary' && <div className="flex flex-col gap-4">
              <div className="p-4" style={panel}><div style={muted}>SERVIZIO</div><strong>{scenarios.find(item => item.key === scenarioType)?.label}</strong><div>{city}{street && ` / ${street}`}</div></div>
              <Line label="Subtotale" value={subtotal} />
              {surcharge > 0 && <Line label="Sovrapprezzo" value={surcharge} />}
              <label style={muted}>Usa gettoni (saldo: {tokens})</label>
              <input inputMode="numeric" value={tokensToReserve} onChange={event => setTokensToReserve(event.target.value.replace(/\D/g, ''))} placeholder="0" style={input} />
              <p style={accent}>Puoi usare fino a {maximumReserve} gettoni (5% del totale prima dello sconto).</p>
              {displayedTokenCredit > 0 && <Line label="Sconto gettoni" value={-displayedTokenCredit} />}
              <Line label="Totale" value={Math.max(grossTotal - displayedTokenCredit, 0)} strong />
              {error && <p style={{ color: '#EF4444' }}>{error}</p>}
            </div>}
            {step === 'success' && result && <div className="text-center py-12"><Check size={50} style={{ color: '#D7FE55', margin: '0 auto 16px' }} /><h2 style={{ color: '#D7FE55', fontFamily: 'Orbitron' }}>ORDINE INVIATO</h2><p>{result.displayId}</p>{result.disclaimer && <p style={muted}>{result.disclaimer}</p>}{result.firstOrderGift > 0 && <div className="p-4 mt-6" style={accent}>+{result.firstOrderGift} gettoni regalo accreditati subito per il primo ordine</div>}{result.itemRewards.length > 0 && <div className="p-4 mt-6" style={accent}>Premi attivati su questo ordine: {result.itemRewards.map(reward => reward.label).join(', ')}</div>}<div className="p-4 mt-6" style={panel}>EUR {result.simulatedTotal} / {result.totalUnits} g<br />+{result.tokensOnComplete} gettoni dopo il completamento</div></div>}
          </div>
          {step !== 'success' && cart.length > 0 && <footer className="p-5" style={{ borderTop: '1px solid rgba(245,245,245,.08)' }}>
            {step === 'cart' && <Action onClick={() => setStep('scenario')} label="Continua" />}
            {step === 'details' && <Action onClick={continueDetails} label="Riepilogo" />}
            {step === 'summary' && requiresKyc && <Action onClick={() => setKycOpen(true)} label="Verifica identità per continuare" />}
            {step === 'summary' && !requiresKyc && <Action onClick={confirm} label={saving ? 'Invio...' : 'Conferma ordine'} disabled={saving} />}
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
                    <div><h2 style={{ fontFamily: 'Space Grotesk', fontSize: 23, fontWeight: 700 }}>Verifica identità</h2><p style={muted}>Richiesta prima del primo ordine.</p></div>
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
function scenarioMinimum(serviceAreas: ServiceArea[], service: ScenarioType, city: string) {
  if (service === 'delivery_italia') return serviceAreas.find(area => area.scenarioType === 'delivery_italia')?.minimumUnits ?? 500
  return serviceAreas.find(area => area.scenarioType === service && area.city === city)?.minimumUnits
}
function groupAreas(areas: ServiceArea[]) {
  const groups: Array<{ minimumUnits: number; cities: string[] }> = []
  for (const area of areas) {
    const existing = groups.find(group => group.minimumUnits === area.minimumUnits)
    if (existing) existing.cities.push(area.city)
    else groups.push({ minimumUnits: area.minimumUnits, cities: [area.city] })
  }
  return groups.sort((left, right) => left.minimumUnits - right.minimumUnits)
}
function ServiceMinimum({ service, serviceAreas }: { service: ScenarioType; serviceAreas: ServiceArea[] }) {
  if (service === 'meetup') {
    const groups = groupAreas(serviceAreas.filter(area => area.scenarioType === 'meetup'))
    return <div style={muted}>{groups.map(group => <span key={`${group.minimumUnits}-${group.cities.join('-')}`}>{group.cities.join(' / ').toUpperCase()} - minimo {group.minimumUnits} g<br /></span>)}</div>
  }
  if (service === 'delivery_zone') {
    const groups = groupAreas(serviceAreas.filter(area => area.scenarioType === 'delivery_zone'))
    return <div style={muted}>{groups.map(group => <span key={`${group.minimumUnits}-${group.cities.join('-')}`}>{group.cities.join(' / ').toUpperCase()} - minimo {group.minimumUnits} g<br /></span>)}+10€ ogni 100 g</div>
  }
  const minimum = serviceAreas.find(area => area.scenarioType === 'delivery_italia')?.minimumUnits ?? 500
  return <div style={muted}>Minimo {minimum} g / tariffa in base a distanza e quantità</div>
}
function Action({ onClick, label, disabled }: { onClick: () => void; label: string; disabled?: boolean }) {
  return <button onClick={onClick} disabled={disabled} className="w-full py-4 flex justify-center items-center gap-2" style={{ background: '#D7FE55', color: '#080C0E', fontWeight: 700, opacity: disabled ? .5 : 1 }}>{label}<ChevronRight size={16} /></button>
}
const panel = { background: '#11181B', border: '1px solid rgba(126,156,168,.2)' }
const muted = { color: 'rgba(245,245,245,.58)', fontSize: 13 }
const accent = { color: '#D7FE55', background: 'rgba(215,254,85,.06)', border: '1px solid rgba(215,254,85,.2)' }
const input = { background: '#11181B', border: '1px solid rgba(126,156,168,.28)', color: '#F5F5F5', padding: '12px 13px' }
