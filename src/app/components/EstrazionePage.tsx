import { type ReactNode, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useParams } from 'react-router-dom'
import { motion, useReducedMotion } from 'motion/react'
import confetti from 'canvas-confetti'
import { AtSign, CalendarClock, Check, Clock3, Coins, ExternalLink, Hash, Loader2, RadioTower, ShieldCheck, Sparkles, Ticket, Trophy } from 'lucide-react'
import type { CurrentEstrazione, Estrazione, EstrazioneWinner, User } from '../data'
import { buyEstrazioneTicket, getCurrentEstrazione } from '../lib/api'
import { italianErrorMessage } from '../lib/errors'

interface Props {
  user: User
  onComplete: () => Promise<void>
}

const numberList = Array.from({ length: 99 }, (_, index) => index + 1)

export function EstrazionePage({ user, onComplete }: Props) {
  const [data, setData] = useState<CurrentEstrazione | null>(null)
  const [selectedNumber, setSelectedNumber] = useState<number | null>(null)
  const [loading, setLoading] = useState(true)
  const [buying, setBuying] = useState(false)
  const [instagramUsername, setInstagramUsername] = useState('')
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    try {
      setData(await getCurrentEstrazione())
      setError('')
    } catch (caught) {
      setError(italianErrorMessage(caught, 'Caricamento Estrazione non riuscito.'))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { void load() }, [load])

  const draw = data?.estrazione ?? null
  const sold = useMemo(() => new Set(data?.soldNumbers ?? []), [data?.soldNumbers])
  const ownNumber = data?.userTicket?.selectedNumber ?? null
  const balance = data?.userBalance ?? user.tokens
  const soldOut = draw ? draw.soldCount >= draw.maxTickets || draw.status === 'sold_out' : false
  const instagramReady = !draw?.instagramRequired || isValidInstagramUsername(instagramUsername)
  const canSelectNumber = Boolean(draw && draw.status === 'open' && !data?.userTicket && data?.userEligible && balance >= draw.ticketPrice && !soldOut)
  const canBuy = Boolean(canSelectNumber && instagramReady)

  useEffect(() => {
    if (data?.userTicket?.instagramUsername) setInstagramUsername(data.userTicket.instagramUsername)
  }, [data?.userTicket?.instagramUsername])

  const buy = async () => {
    if (!draw || selectedNumber === null) return
    setBuying(true)
    setError('')
    try {
      const next = await buyEstrazioneTicket(draw.id, selectedNumber, instagramUsername)
      setData(next)
      setSelectedNumber(null)
      confetti({ particleCount: 42, spread: 48, colors: ['#D7FE55', '#7E9CA8', '#F5F5F5'] })
      await onComplete()
      await load()
    } catch (caught) {
      setError(italianErrorMessage(caught, 'Acquisto biglietto Estrazione non riuscito.'))
    } finally {
      setBuying(false)
    }
  }

  return (
    <div className="sf-estrazione min-h-screen px-3 sm:px-4 md:px-8">
      <div className="sf-estrazione-grid-bg" />
      <div className="max-w-6xl mx-auto">
        <section className="sf-estrazione-hero">
          <div>
            <div className="sf-estrazione-eyebrow"><RadioTower size={14} /> Estrazione live</div>
            <h1>ESTRAZIONE</h1>
            <p>Compra un biglietto, scegli un numero da 1 a 99 e segui l’estrazione in diretta.</p>
          </div>
          <div className="sf-estrazione-wallet">
            <span>Saldo</span>
            <strong>{balance}</strong>
            <small>gettoni</small>
          </div>
        </section>

        {error && <StateCard tone="error" text={error} />}
        {loading ? (
          <StateCard text="Caricamento Estrazione..." />
        ) : !draw ? (
          <EmptyEstrazione />
        ) : (
          <>
            <RulesCard draw={draw} />
            <DrawSummary draw={draw} completedOrders={data?.userCompletedOrders ?? 0} eligible={Boolean(data?.userEligible)} ownNumber={ownNumber} />
            {data?.userTicket ? (
              <OwnedTicket number={data.userTicket.selectedNumber} instagramUsername={data.userTicket.instagramUsername} draw={draw} />
            ) : (
              <section className="sf-number-panel">
                {draw.instagramRequired && (
                  <InstagramGate
                    draw={draw}
                    username={instagramUsername}
                    onUsernameChange={setInstagramUsername}
                  />
                )}
                <div className="sf-number-panel-head">
                  <div>
                    <span>Scegli numero</span>
                    <strong>{selectedNumber === null ? '1-99' : formatNumber(selectedNumber)}</strong>
                  </div>
                  <p>{draw.status === 'open' ? 'Ogni numero può essere venduto una sola volta.' : statusLabel(draw.status)}</p>
                </div>
                <div className="sf-number-grid" aria-label="Numeri Estrazione">
                  {numberList.map(number => {
                    const isSold = sold.has(number)
                    const selected = selectedNumber === number
                    return (
                      <button
                        key={number}
                        type="button"
                        className={`sf-number-cell ${isSold ? 'is-sold' : ''} ${selected ? 'is-selected' : ''}`}
                        disabled={!canSelectNumber || isSold || buying}
                        onClick={() => setSelectedNumber(number)}
                      >
                        {formatNumber(number)}
                      </button>
                    )
                  })}
                </div>
                <div className="sf-estrazione-sticky">
                  <div>
                    <span>Biglietto</span>
                    <strong>{draw.ticketPrice} gettoni</strong>
                  </div>
                  <div>
                    <span>Numero</span>
                    <strong>{selectedNumber === null ? '--' : formatNumber(selectedNumber)}</strong>
                  </div>
                  <button type="button" disabled={!canBuy || selectedNumber === null || buying} onClick={buy}>
                    {buying ? <><Loader2 size={16} className="sf-spin" /> Acquisto...</> : !data?.userEligible ? `Servono ${draw.minCompletedOrders} ordini` : !instagramReady ? 'Inserisci Instagram' : balance < draw.ticketPrice ? 'Gettoni insufficienti' : 'Conferma'}
                  </button>
                </div>
              </section>
            )}
            {draw.publicToken && <LiveLink token={draw.publicToken} />}
          </>
        )}
      </div>
    </div>
  )
}

function RulesCard({ draw }: { draw: Estrazione }) {
  const visiblePrizes = [
    { label: 'Valore primo premio', value: draw.prizeFirstValue },
    { label: 'Valore secondo premio', value: draw.prizeSecondValue },
    { label: 'Valore terzo premio', value: draw.prizeThirdValue },
  ].slice(0, Math.min(draw.winnersCount, 3))
  const tagFriendsLabel = draw.instagramTagFriendsCount === 1
    ? '1 amico reale'
    : `${draw.instagramTagFriendsCount} amici reali`
  const ordersLabel = draw.minCompletedOrders <= 0
    ? 'Nessun ordine minimo richiesto'
    : `Effettuare almeno ${draw.minCompletedOrders} ${draw.minCompletedOrders === 1 ? 'ordine' : 'ordini'}`
  const postUrl = draw.instagramVerificationUrl.trim()

  return (
    <section className="sf-rules-card" aria-label="Regole Estrazione">
      <div className="sf-rules-head">
        <div>
          <span>Regole per attivare</span>
          <h2>ESTRAZIONE</h2>
        </div>
        <div className="sf-rules-badges">
          <strong>{draw.maxTickets} biglietti disponibili</strong>
          <strong>Costo biglietto {formatEuro(draw.ticketPrice)} l’uno</strong>
        </div>
      </div>

      <div className="sf-rules-prizes">
        {visiblePrizes.map(prize => (
          <div key={prize.label} className="sf-rules-prize">
            <span>{prize.label}</span>
            <strong>{formatEuro(prize.value)}</strong>
          </div>
        ))}
      </div>

      <div className="sf-rules-subtitle">Per sbloccare Estrazione dovete</div>
      <ul className="sf-rules-list">
        <RuleItem>Entrare sul sito</RuleItem>
        <RuleItem>Effettuare verifica identità</RuleItem>
        <RuleItem>{ordersLabel}</RuleItem>
        {draw.instagramRequired && <RuleItem>Seguire pagina Instagram{draw.instagramTargetUsername ? ` @${draw.instagramTargetUsername}` : ''}</RuleItem>}
        {draw.instagramRequired && (
          <RuleItem>
            <span>Taggare {tagFriendsLabel} sotto</span>
            {postUrl ? (
              <a className="sf-rules-post-link" href={postUrl} target="_blank" rel="noreferrer">
                POST <ExternalLink size={13} />
              </a>
            ) : (
              <strong className="sf-rules-post-text">POST</strong>
            )}
          </RuleItem>
        )}
        <RuleItem>Comprare biglietto costo {formatEuro(draw.ticketPrice)}</RuleItem>
      </ul>
    </section>
  )
}

function RuleItem({ children }: { children: ReactNode }) {
  return <li><Check size={15} /> <span className="sf-rules-item-content">{children}</span></li>
}

function InstagramGate({
  draw,
  username,
  onUsernameChange,
}: {
  draw: Estrazione
  username: string
  onUsernameChange: (value: string) => void
}) {
  const target = draw.instagramTargetUsername
  const valid = isValidInstagramUsername(username)
  return (
    <div className={`sf-instagram-gate ${valid ? 'is-verified' : ''}`}>
      <div className="sf-instagram-gate-head">
        <div><AtSign size={18} /><span>Instagram richiesto</span></div>
        <strong>{target ? `Follow @${target}` : 'Controllo manuale'}</strong>
      </div>
      <div className="sf-instagram-gate-row">
        <label>
          <span>Il tuo Instagram</span>
          <input value={username} onChange={event => onUsernameChange(event.currentTarget.value)} placeholder="username" />
        </label>
      </div>
      <p>L’amministrazione controllerà manualmente l’account Instagram al momento dell’Estrazione.</p>
    </div>
  )
}

export function EstrazioneLivePage() {
  const { token } = useParams()
  const [data, setData] = useState<CurrentEstrazione | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const celebratedRef = useRef('')

  const load = useCallback(async () => {
    if (!token) return
    try {
      setData(await getCurrentEstrazione(token))
      setError('')
    } catch (caught) {
      setError(italianErrorMessage(caught, 'Caricamento live Estrazione non riuscito.'))
    } finally {
      setLoading(false)
    }
  }, [token])

  useEffect(() => {
    void load()
    const timer = window.setInterval(() => { void load() }, 8000)
    return () => window.clearInterval(timer)
  }, [load])

  const draw = data?.estrazione ?? null
  const countdown = useCountdown(draw?.scheduledAt ?? null)
  const liveActive = Boolean(draw && (draw.status === 'running' || (draw.status === 'scheduled' && countdown.totalMs <= 0)))

  useEffect(() => {
    if (!draw?.completedAt || !data?.winners.length || celebratedRef.current === draw.completedAt) return
    celebratedRef.current = draw.completedAt
    confetti({ particleCount: 76, spread: 65, colors: ['#D7FE55', '#7E9CA8', '#F5F5F5'] })
  }, [draw?.completedAt, data?.winners.length])

  return (
    <div className="sf-estrazione-live min-h-screen px-3 sm:px-4">
      <div className="max-w-4xl mx-auto">
        {error && <StateCard tone="error" text={error} />}
        {loading ? (
          <StateCard text="Caricamento live..." />
        ) : !draw ? (
          <StateCard text="Estrazione live non trovata." />
        ) : (
          <section className="sf-live-stage">
            <div className="sf-estrazione-eyebrow"><Sparkles size={14} /> Diretta Street Family</div>
            <h1>{draw.title}</h1>
            <p>{draw.soldCount} numeri in gara / {draw.winnersCount} posti vincenti</p>
            {draw.status === 'completed' ? (
              <WinnerReveal winners={data?.winners ?? []} />
            ) : (
              <>
                <CountdownBlock countdown={countdown} status={draw.status} />
                <DrawAnimation numbers={data?.soldNumbers ?? []} active={liveActive} />
              </>
            )}
          </section>
        )}
      </div>
    </div>
  )
}

function DrawSummary({ draw, completedOrders, eligible, ownNumber }: { draw: Estrazione; completedOrders: number; eligible: boolean; ownNumber: number | null }) {
  return (
    <section className="sf-estrazione-summary">
      <Metric Icon={Ticket} label="Biglietti" value={`${draw.soldCount}/${draw.maxTickets}`} />
      <Metric Icon={Coins} label="Prezzo" value={`${draw.ticketPrice}`} suffix="gettoni" />
      <Metric Icon={ShieldCheck} label="Ordini richiesti" value={`${completedOrders}/${draw.minCompletedOrders}`} tone={eligible ? 'ok' : 'warn'} />
      <Metric Icon={Trophy} label="Posti" value={String(draw.winnersCount)} />
      <div className="sf-estrazione-status">
        <span>{statusLabel(draw.status)}</span>
        {draw.scheduledAt && <strong><CalendarClock size={14} /> {formatDate(draw.scheduledAt)}</strong>}
        {ownNumber && <strong><Hash size={14} /> Il tuo numero {formatNumber(ownNumber)}</strong>}
      </div>
    </section>
  )
}

function Metric({ Icon, label, value, suffix, tone }: { Icon: typeof Ticket; label: string; value: string; suffix?: string; tone?: 'ok' | 'warn' }) {
  return <div className={`sf-estrazione-metric ${tone ? `is-${tone}` : ''}`}><Icon size={17} /><span>{label}</span><strong>{value}</strong>{suffix && <small>{suffix}</small>}</div>
}

function OwnedTicket({ number, instagramUsername, draw }: { number: number; instagramUsername: string; draw: Estrazione }) {
  return (
    <section className="sf-owned-ticket">
      <div><Ticket size={26} /><span>Biglietto confermato</span></div>
      <strong>{formatNumber(number)}</strong>
      {instagramUsername && <p><AtSign size={14} style={{ display: 'inline', marginRight: 4 }} />{instagramUsername}</p>}
      <p>{draw.status === 'open' || draw.status === 'sold_out' ? 'Attendi la programmazione dell’Estrazione.' : statusLabel(draw.status)}</p>
    </section>
  )
}

function LiveLink({ token }: { token: string }) {
  const href = `/estrazione/live/${token}`
  return <a className="sf-live-link" href={href}><RadioTower size={17} /> Apri pagina live Estrazione</a>
}

function EmptyEstrazione() {
  return (
    <section className="sf-owned-ticket">
      <div><Clock3 size={26} /><span>Nessuna Estrazione attiva</span></div>
      <p>Quando l’amministrazione aprirà una nuova Estrazione, potrai scegliere il tuo numero qui.</p>
    </section>
  )
}

function CountdownBlock({ countdown, status }: { countdown: Countdown; status: Estrazione['status'] }) {
  if (status === 'sold_out') return <div className="sf-countdown"><span>Sold out</span><strong>Orario in arrivo</strong></div>
  if (status === 'running') return <div className="sf-countdown is-live"><span>Live</span><strong>Estrazione in corso</strong></div>
  return (
    <div className="sf-countdown">
      <span>Countdown</span>
      <strong>{countdown.totalMs <= 0 ? '00:00' : `${countdown.minutes}:${countdown.seconds}`}</strong>
    </div>
  )
}

function DrawAnimation({ numbers, active }: { numbers: number[]; active: boolean }) {
  const reducedMotion = useReducedMotion()
  const pool = numbers.length ? numbers : numberList
  const [current, setCurrent] = useState(pool[0] ?? 1)

  useEffect(() => {
    if (!active || reducedMotion) return
    const timer = window.setInterval(() => {
      setCurrent(pool[Math.floor(Math.random() * pool.length)] ?? 1)
    }, 88)
    return () => window.clearInterval(timer)
  }, [active, pool, reducedMotion])

  return (
    <div className={`sf-draw-animation ${active ? 'is-active' : ''}`}>
      <motion.div animate={active && !reducedMotion ? { scale: [1, 1.04, 1] } : { scale: 1 }} transition={{ repeat: active ? Infinity : 0, duration: .7 }}>
        {formatNumber(current)}
      </motion.div>
      <p>{active ? 'La sorte sta scegliendo tra i numeri venduti.' : 'I numeri venduti entreranno nell’urna digitale.'}</p>
    </div>
  )
}

function WinnerReveal({ winners }: { winners: EstrazioneWinner[] }) {
  return (
    <div className="sf-winner-list">
      {winners.map(winner => (
        <motion.article key={winner.place} initial={{ opacity: 0, y: 18 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: winner.place * .18 }}>
          <span>{winner.place}° posto</span>
          <strong>{formatNumber(winner.selectedNumber)}</strong>
          <p>{winnerName(winner)}</p>
        </motion.article>
      ))}
      {!winners.length && <StateCard text="Risultati in preparazione..." />}
    </div>
  )
}

function StateCard({ text, tone }: { text: string; tone?: 'error' }) {
  return <div className={`sf-estrazione-state ${tone === 'error' ? 'is-error' : ''}`}>{text}</div>
}

type Countdown = { totalMs: number; minutes: string; seconds: string }

function useCountdown(date: string | null): Countdown {
  const [now, setNow] = useState(Date.now())
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(timer)
  }, [])
  const totalMs = date ? new Date(date).getTime() - now : 0
  const safeSeconds = Math.max(0, Math.floor(totalMs / 1000))
  return {
    totalMs,
    minutes: String(Math.floor(safeSeconds / 60)).padStart(2, '0'),
    seconds: String(safeSeconds % 60).padStart(2, '0'),
  }
}

function statusLabel(status: Estrazione['status']) {
  const labels: Record<Estrazione['status'], string> = {
    draft: 'Bozza',
    open: 'Aperta',
    sold_out: 'Sold out',
    scheduled: 'Programmata',
    running: 'In corso',
    completed: 'Completata',
    cancelled: 'Annullata',
  }
  return labels[status]
}

function winnerName(winner: EstrazioneWinner) {
  const profile = winner.username ? `@${winner.username}` : winner.telegramSubject ? `Telegram ${winner.telegramSubject}` : 'Utente Street Family'
  if (winner.instagramUsername) return `${profile} / IG @${winner.instagramUsername}`
  return profile
}

function isValidInstagramUsername(value: string) {
  const normalized = value.trim().replace(/^@+/, '').toLowerCase()
  return /^[a-z0-9._]{1,30}$/.test(normalized)
}

function formatNumber(value: number) {
  return String(value).padStart(2, '0')
}

function formatDate(value: string) {
  return new Date(value).toLocaleString('it-IT', { dateStyle: 'short', timeStyle: 'short' })
}

function formatEuro(value: number) {
  return `${value}€`
}
