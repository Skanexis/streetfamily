import { useCallback, useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { motion, useReducedMotion } from 'motion/react'
import confetti from 'canvas-confetti'
import { ArrowLeft, ArrowRight, Coins, Fingerprint, Gift, LockKeyhole, RotateCw, ShieldCheck, Smartphone, Sparkles, Ticket, Trophy, X } from 'lucide-react'
import type { GamePlayResult, GameType, PlayableGame, TicketPurchaseResult, User } from '../data'
import { getPlayableGames } from '../lib/api'
import { italianErrorMessage } from '../lib/errors'

interface Props {
  user: User
  onPlay: (gameType: GameType) => Promise<GamePlayResult>
  onBuyTicket: (gameType: GameType) => Promise<TicketPurchaseResult>
  onComplete: () => Promise<void>
}

const gameCards: Array<{ type: GameType; title: string; subtitle: string; tag: string; Icon: typeof Ticket }> = [
  { type: 'spin', title: 'Ruota dei premi', subtitle: 'Gira e scopri il premio', tag: 'LIVE', Icon: RotateCw },
  { type: 'scratch', title: 'Scratch', subtitle: 'Gratta la carta misteriosa', tag: 'REVEAL', Icon: Sparkles },
  { type: 'box', title: 'Mystery Box', subtitle: 'Apri la cassa fortunata', tag: 'DROP', Icon: Gift },
]

export function GamesPage({ user, onPlay, onBuyTicket, onComplete }: Props) {
  const [games, setGames] = useState<PlayableGame[]>([])
  const [selected, setSelected] = useState<GameType | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const closeGame = useCallback(() => setSelected(null), [])

  const load = async () => {
    try {
      setGames(await getPlayableGames())
      setError('')
    } catch (caught) {
      setError(italianErrorMessage(caught, 'Caricamento giochi non riuscito.'))
    } finally {
      setLoading(false)
    }
  }
  useEffect(() => { void load() }, [])

  const available = (type: GameType) => games.find(game => game.gameType === type && game.options.length > 0)
  const tickets = (type: GameType) => type === 'spin' ? user.spinTickets : type === 'scratch' ? user.scratchTickets : user.boxTickets
  const totalTickets = user.spinTickets + user.scratchTickets + user.boxTickets
  const current = selected ? available(selected) : undefined
  const refresh = async () => {
    await onComplete()
    await load()
  }

  return (
    <div className="sf-arcade min-h-screen px-4 md:px-8 py-10" style={{ paddingTop: 92 }}>
      <div className="sf-arcade-orb sf-arcade-orb-purple" />
      <div className="sf-arcade-orb sf-arcade-orb-green" />
      <div className="max-w-6xl mx-auto relative">
        <section className="sf-arcade-hero">
          <div className="max-w-2xl">
            <div className="sf-arcade-eyebrow"><span className="sf-live-dot" /> Arcade room online</div>
            <div className="sf-casino-lights" aria-hidden="true">{Array.from({ length: 12 }, (_, index) => <span key={index} />)}</div>
            <h1 className="sf-arcade-title">SCEGLI IL TUO<br /><span>GIOCO</span></h1>
            <p className="sf-arcade-copy">Tre esperienze, un sistema protetto. Ogni premio viene estratto sul server prima che inizi lo spettacolo.</p>
            <div className="sf-arcade-trust">
              <TrustBadge Icon={ShieldCheck} label="Server verified" />
              <TrustBadge Icon={Fingerprint} label="Premi protetti" />
              <TrustBadge Icon={Smartphone} label="Touch ready" />
            </div>
          </div>
          <div className="sf-arcade-pass">
            <div className="sf-pass-label"><ShieldCheck size={14} /> WALLET GIOCHI</div>
            <div className="sf-pass-value">{totalTickets}</div>
            <div className="sf-pass-caption">biglietti disponibili</div>
            <div className="sf-pass-tickets">
              <MiniTicket label="Ruota" value={user.spinTickets} />
              <MiniTicket label="Scratch" value={user.scratchTickets} />
              <MiniTicket label="Box" value={user.boxTickets} />
            </div>
          </div>
        </section>
        {error && <StateMessage text={error} tone="error" />}
        {loading ? <StateMessage text="Caricamento giochi..." /> : (
          <div className="sf-game-grid">
            {gameCards.map(({ type, title, subtitle, tag, Icon }, index) => {
              const playable = available(type)
              const enabled = Boolean(playable)
              const canBuy = isPurchasable(type) && enabled
              return (
                <motion.button key={type} initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: index * .08 }}
                  onClick={() => setSelected(type)} className={`sf-game-card sf-game-card-${type} text-left`} style={gameCard}>
                  <div className="sf-game-card-noise" />
                  <div className="sf-game-card-head">
                    <span className="sf-game-tag">{tag}</span>
                    <span style={pill}><Ticket size={13} /> {tickets(type)}</span>
                  </div>
                  <div className="sf-card-layout">
                    <div>
                      <div className="sf-game-card-icon"><Icon size={32} /></div>
                      <h2 className="sf-game-card-title">{title}</h2>
                      <p className="sf-game-card-copy">{enabled ? subtitle : 'Configurazione in arrivo'}</p>
                      {canBuy && <p className="sf-game-card-price"><Coins size={13} /> Biglietto {playable?.ticketPrice ?? 0} gettoni</p>}
                    </div>
                    <GameArtwork type={type} />
                  </div>
                  <div className={`sf-game-card-status ${enabled ? 'is-ready' : ''}`}>
                    {enabled ? <><span className="sf-live-dot" /> Disponibile <ArrowRight size={15} /></> : <><LockKeyhole size={14} /> In preparazione</>}
                  </div>
                </motion.button>
              )
            })}
          </div>
        )}
      </div>
      {selected && createPortal(
        <GameOverlay title={gameCards.find(game => game.type === selected)!.title} onClose={closeGame}>
          {!current ? (
            <UnavailableGame onClose={closeGame} />
          ) : selected === 'spin' ? (
            <WheelGame user={user} game={current} onPlay={onPlay} onBuyTicket={onBuyTicket} onComplete={refresh} />
          ) : selected === 'scratch' ? (
            <ScratchGame user={user} game={current} onPlay={onPlay} onBuyTicket={onBuyTicket} onComplete={refresh} />
          ) : (
            <BoxGame user={user} game={current} onPlay={onPlay} onComplete={refresh} />
          )}
        </GameOverlay>
      , document.body)}
    </div>
  )
}

function GameOverlay({ title, onClose, children }: { title: string; onClose: () => void; children: React.ReactNode }) {
  useEffect(() => {
    const scrollY = window.scrollY
    const appRoot = document.getElementById('root')
    const previousAriaHidden = appRoot?.getAttribute('aria-hidden')
    const previous = {
      overflow: document.body.style.overflow,
      position: document.body.style.position,
      top: document.body.style.top,
      width: document.body.style.width,
    }
    document.body.style.overflow = 'hidden'
    document.body.style.position = 'fixed'
    document.body.style.top = `-${scrollY}px`
    document.body.style.width = '100%'
    document.documentElement.classList.add('sf-game-modal-open')
    appRoot?.setAttribute('inert', '')
    appRoot?.setAttribute('aria-hidden', 'true')
    const escape = (event: KeyboardEvent) => { if (event.key === 'Escape') onClose() }
    window.addEventListener('keydown', escape)
    const telegram = (window as Window & { Telegram?: { WebApp?: { BackButton?: { show?: () => void; hide?: () => void; onClick?: (callback: () => void) => void; offClick?: (callback: () => void) => void } } } }).Telegram?.WebApp
    telegram?.BackButton?.show?.()
    telegram?.BackButton?.onClick?.(onClose)
    return () => {
      window.removeEventListener('keydown', escape)
      telegram?.BackButton?.offClick?.(onClose)
      telegram?.BackButton?.hide?.()
      document.body.style.overflow = previous.overflow
      document.body.style.position = previous.position
      document.body.style.top = previous.top
      document.body.style.width = previous.width
      document.documentElement.classList.remove('sf-game-modal-open')
      appRoot?.removeAttribute('inert')
      if (previousAriaHidden == null) appRoot?.removeAttribute('aria-hidden')
      else appRoot?.setAttribute('aria-hidden', previousAriaHidden)
      window.scrollTo({ top: scrollY, behavior: 'instant' })
    }
  }, [onClose])

  return (
    <motion.div role="dialog" aria-modal="true" aria-label={title} initial={{ opacity: 0 }} animate={{ opacity: 1 }} className="sf-game-overlay fixed inset-0 overflow-y-auto">
      <div className="sf-overlay-glow" />
      <div className="sf-game-overlay-frame max-w-xl mx-auto px-4 flex flex-col relative">
        <header className="sf-overlay-header sticky top-0 z-10 flex items-center justify-between mb-7">
          <div><div className="sf-overlay-label">Street Family Arcade</div><h2 className="sf-overlay-title">{title}</h2></div>
          <button className="sf-overlay-close" aria-label="Chiudi gioco" onClick={onClose} style={iconButton}><X size={20} /></button>
        </header>
        <div className="sf-overlay-content flex-1 flex items-center justify-center">{children}</div>
      </div>
    </motion.div>
  )
}

function UnavailableGame({ onClose }: { onClose: () => void }) {
  return (
    <div className="sf-game-stage sf-unavailable w-full text-center p-6 rounded-3xl">
      <div className="sf-locked-mark"><LockKeyhole size={30} /></div>
      <div className="sf-overlay-label">Prossimamente</div>
      <h3>Gioco in preparazione</h3>
      <p>Questo gioco non ha ancora premi configurati. Torna nella sala e prova un'esperienza disponibile.</p>
      <button className="sf-return-action" onClick={onClose}><ArrowLeft size={17} /> Torna ai giochi</button>
    </div>
  )
}

function WheelGame({ user, game, onPlay, onBuyTicket, onComplete }: { user: User; game: PlayableGame; onPlay: Props['onPlay']; onBuyTicket: Props['onBuyTicket']; onComplete: () => Promise<void> }) {
  const reducedMotion = useReducedMotion()
  const [result, setResult] = useState<GamePlayResult | null>(null)
  const [rotation, setRotation] = useState(0)
  const [busy, setBusy] = useState(false)
  const [buying, setBuying] = useState(false)
  const [error, setError] = useState('')
  const colors = game.options.map(option => option.color)
  const gradient = wheelGradient(colors)
  const hasTicket = user.spinTickets > 0

  const buyTicket = async () => {
    setBuying(true); setError('')
    try {
      await onBuyTicket('spin')
      await onComplete()
    } catch (caught) {
      setError(italianErrorMessage(caught, 'Acquisto biglietto non riuscito.'))
    } finally {
      setBuying(false)
    }
  }

  const spin = async () => {
    setBusy(true); setResult(null); setError('')
    try {
      const played = await onPlay('spin')
      setRotation(value => value + (reducedMotion ? 360 : 1440) + ((played.angle - (value % 360) + 360) % 360))
      const duration = reducedMotion ? 250 : 1450
      playTicks(duration)
      await wait(duration)
      setResult(played)
      if (!reducedMotion) confetti({ particleCount: 58, spread: 55, colors: ['#D7FE55', '#22C55E', '#B99361'] })
      setBusy(false)
      await onComplete()
    } catch (caught) {
      setError(italianErrorMessage(caught, 'Estrazione non disponibile.'))
      setBusy(false)
    }
  }
  return (
    <div className="sf-game-stage w-full text-center p-5 sm:p-7 rounded-3xl" style={gamePanel}>
      <TicketBalance value={user.spinTickets} />
      <TicketShop user={user} game={game} buying={buying} onBuy={buyTicket} />
      <div className="sf-wheel-wrap">
        <div className="sf-wheel-pointer" />
        <motion.div className="sf-wheel mx-auto my-8 rounded-full flex items-center justify-center" animate={{ rotate: rotation }}
          transition={{ duration: reducedMotion ? .25 : 1.45, ease: [0.12, 0.85, 0.2, 1] }}
          style={{ background: `conic-gradient(${gradient})`, boxShadow: result ? '0 0 54px rgba(34,197,94,.42)' : undefined }}>
          <div className="sf-wheel-center">SPIN</div>
        </motion.div>
      </div>
      {result && <Reward result={result} />}
      <GameButton
        disabled={busy || buying || (!hasTicket && user.tokens < game.ticketPrice)}
        onClick={hasTicket ? spin : buyTicket}
        label={busy ? 'Estrazione...' : buying ? 'Acquisto...' : hasTicket ? 'Usa 1 biglietto' : user.tokens >= game.ticketPrice ? `Compra 1 biglietto - ${game.ticketPrice} gettoni` : `Servono ${game.ticketPrice} gettoni`}
      />
      {error && <StateMessage text={error} tone="error" />}
    </div>
  )
}

function ScratchGame({ user, game, onPlay, onBuyTicket, onComplete }: { user: User; game: PlayableGame; onPlay: Props['onPlay']; onBuyTicket: Props['onBuyTicket']; onComplete: () => Promise<void> }) {
  const reducedMotion = useReducedMotion()
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const pointerRef = useRef<number | null>(null)
  const paintFrameRef = useRef<number | null>(null)
  const revealFrameRef = useRef<number | null>(null)
  const pointsRef = useRef<Array<{ x: number; y: number; start: boolean }>>([])
  const paintedPointRef = useRef<{ x: number; y: number } | null>(null)
  const measuredAtRef = useRef(0)
  const completingRef = useRef(false)
  const particleAtRef = useRef(0)
  const [result, setResult] = useState<GamePlayResult | null>(null)
  const [revealed, setRevealed] = useState(false)
  const [finishing, setFinishing] = useState(false)
  const [busy, setBusy] = useState(false)
  const [buying, setBuying] = useState(false)
  const [error, setError] = useState('')
  const [percent, setPercent] = useState(0)
  const hasTicket = user.scratchTickets > 0

  useEffect(() => {
    if (!result || !canvasRef.current) return
    const canvas = canvasRef.current
    const context = canvas.getContext('2d')
    if (!context) return
    context.globalCompositeOperation = 'source-over'
    const mask = context.createLinearGradient(0, 0, canvas.width, canvas.height)
    mask.addColorStop(0, '#A78BFA')
    mask.addColorStop(.48, '#7C3AED')
    mask.addColorStop(1, '#4C1D95')
    context.fillStyle = mask
    context.fillRect(0, 0, canvas.width, canvas.height)
    context.fillStyle = 'rgba(255,255,255,.09)'
    for (let x = 10; x < canvas.width; x += 34) {
      for (let y = 10; y < canvas.height; y += 34) {
        context.beginPath()
        context.arc(x, y, 2, 0, Math.PI * 2)
        context.fill()
      }
    }
    context.fillStyle = 'rgba(255,255,255,.78)'
    context.font = 'bold 28px Orbitron, sans-serif'
    context.textAlign = 'center'
    context.fillText('SCRATCH', canvas.width / 2, canvas.height / 2)
    context.fillStyle = 'rgba(255,255,255,.45)'
    context.font = '16px Inter, sans-serif'
    context.fillText('GRATTA PER RIVELARE', canvas.width / 2, canvas.height / 2 + 38)
  }, [result])

  useEffect(() => {
    if (!result || revealed) return
    document.documentElement.classList.add('sf-scratching')
    return () => { document.documentElement.classList.remove('sf-scratching') }
  }, [result, revealed])

  useEffect(() => () => {
    document.documentElement.classList.remove('sf-scratching')
    if (paintFrameRef.current !== null) cancelAnimationFrame(paintFrameRef.current)
    if (revealFrameRef.current !== null) cancelAnimationFrame(revealFrameRef.current)
  }, [])

  const start = async () => {
    completingRef.current = false
    pointerRef.current = null
    pointsRef.current = []
    paintedPointRef.current = null
    setBusy(true); setError(''); setResult(null); setRevealed(false); setFinishing(false); setPercent(0)
    try {
      setResult(await onPlay('scratch'))
    } catch (caught) {
      setError(italianErrorMessage(caught, 'Scratch non disponibile.'))
    } finally {
      setBusy(false)
    }
  }

  const buyTicket = async () => {
    setBuying(true); setError('')
    try {
      await onBuyTicket('scratch')
      await onComplete()
    } catch (caught) {
      setError(italianErrorMessage(caught, 'Acquisto biglietto non riuscito.'))
    } finally {
      setBuying(false)
    }
  }

  const completeReveal = () => {
    setPercent(100)
    setFinishing(false)
    setRevealed(true)
    if (!reducedMotion) confetti({ particleCount: 46, colors: ['#8B5CF6', '#22C55E'] })
    navigator.vibrate?.(45)
    void onComplete()
  }

  const autoErase = () => {
    if (completingRef.current) return
    completingRef.current = true
    pointerRef.current = null
    pointsRef.current = []
    setFinishing(true)
    const canvas = canvasRef.current
    const context = canvas?.getContext('2d')
    if (!canvas || !context || reducedMotion) {
      context?.clearRect(0, 0, canvas?.width ?? 0, canvas?.height ?? 0)
      completeReveal()
      return
    }
    const startedAt = performance.now()
    const finishDuration = 430
    const erase = (now: number) => {
      const progress = Math.min((now - startedAt) / finishDuration, 1)
      const eased = 1 - Math.pow(1 - progress, 3)
      const distance = canvas.height * .54 * eased
      context.save()
      context.globalCompositeOperation = 'destination-out'
      context.fillRect(0, canvas.height / 2 - distance, canvas.width, distance * 2)
      context.restore()
      setPercent(Math.min(100, Math.round(60 + progress * 40)))
      if (progress < 1) {
        revealFrameRef.current = requestAnimationFrame(erase)
        return
      }
      context.clearRect(0, 0, canvas.width, canvas.height)
      revealFrameRef.current = null
      completeReveal()
    }
    revealFrameRef.current = requestAnimationFrame(erase)
  }

  const measureScratch = (context: CanvasRenderingContext2D, canvas: HTMLCanvasElement) => {
    const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data
    const center = { left: canvas.width * .22, right: canvas.width * .78, top: canvas.height * .27, bottom: canvas.height * .73 }
    let cleared = 0
    let sampled = 0
    let centerCleared = 0
    let centerSampled = 0
    for (let y = 0; y < canvas.height; y += 4) {
      for (let x = 0; x < canvas.width; x += 4) {
        const alpha = pixels[((y * canvas.width + x) * 4) + 3]
        sampled += 1
        if (alpha < 80) cleared += 1
        if (x >= center.left && x <= center.right && y >= center.top && y <= center.bottom) {
          centerSampled += 1
          if (alpha < 80) centerCleared += 1
        }
      }
    }
    const value = Math.round(cleared / sampled * 100)
    const centerValue = Math.round(centerCleared / centerSampled * 100)
    setPercent(value)
    if (value > 60 || centerValue >= 38) autoErase()
  }

  const paintQueuedPoints = () => {
    const actualCanvas = canvasRef.current
    if (!actualCanvas || completingRef.current) return
    const context = actualCanvas.getContext('2d')
    if (!context) return
    const queued = pointsRef.current.splice(0)
    context.save()
    context.globalCompositeOperation = 'destination-out'
    context.strokeStyle = '#000'
    context.fillStyle = '#000'
    context.lineWidth = 68
    context.lineCap = 'round'
    context.lineJoin = 'round'
    queued.forEach(point => {
      if (point.start) paintedPointRef.current = null
      context.beginPath()
      if (paintedPointRef.current) context.moveTo(paintedPointRef.current.x, paintedPointRef.current.y)
      else context.moveTo(point.x, point.y)
      context.lineTo(point.x, point.y)
      context.stroke()
      context.beginPath()
      context.arc(point.x, point.y, 34, 0, Math.PI * 2)
      context.fill()
      paintedPointRef.current = point
    })
    context.restore()
    const now = performance.now()
    if (now - measuredAtRef.current >= 65) {
      measuredAtRef.current = now
      measureScratch(context, actualCanvas)
    }
    paintFrameRef.current = null
    if (pointsRef.current.length) paintFrameRef.current = requestAnimationFrame(paintQueuedPoints)
  }

  const enqueuePoint = (event: React.PointerEvent<HTMLCanvasElement>, start = false) => {
    if (!result || revealed || completingRef.current) return
    event.preventDefault()
    const canvas = event.currentTarget
    const rect = canvas.getBoundingClientRect()
    const x = (event.clientX - rect.left) * canvas.width / rect.width
    const y = (event.clientY - rect.top) * canvas.height / rect.height
    pointsRef.current.push({ x, y, start })
    if (paintFrameRef.current === null) paintFrameRef.current = requestAnimationFrame(paintQueuedPoints)
    const now = performance.now()
    if (!reducedMotion && now - particleAtRef.current > 90) {
      particleAtRef.current = now
      confetti({
        particleCount: 2,
        spread: 24,
        startVelocity: 12,
        colors: ['#8B5CF6', '#22C55E'],
        origin: { x: event.clientX / window.innerWidth, y: event.clientY / window.innerHeight },
      })
    }
  }

  const beginScratch = (event: React.PointerEvent<HTMLCanvasElement>) => {
    if (!result || revealed || completingRef.current) return
    event.preventDefault()
    pointerRef.current = event.pointerId
    event.currentTarget.setPointerCapture(event.pointerId)
    enqueuePoint(event, true)
  }
  const moveScratch = (event: React.PointerEvent<HTMLCanvasElement>) => {
    if (pointerRef.current !== event.pointerId) return
    enqueuePoint(event)
  }
  const endScratch = (event: React.PointerEvent<HTMLCanvasElement>) => {
    if (pointerRef.current !== event.pointerId) return
    event.preventDefault()
    pointerRef.current = null
    if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId)
  }
  return (
    <div className="sf-game-stage sf-scratch-stage w-full text-center p-5 sm:p-7 rounded-3xl" style={gamePanel}>
      <TicketBalance value={user.scratchTickets} />
      <TicketShop user={user} game={game} buying={buying} onBuy={buyTicket} hidden={Boolean(result)} />
      {!result ? <div className="sf-idle-state"><Sparkles size={34} /><strong>Carta sigillata</strong><span>Avviala e gratta per scoprire il premio.</span></div> : (
        <>
          <div className={`sf-scratch-ticket relative my-8 overflow-hidden rounded-2xl ${revealed ? 'is-revealed' : ''}`} style={{ height: 200 }}>
            <div className="absolute inset-0 flex items-center justify-center"><Reward result={result} compact /></div>
            {!revealed && <canvas ref={canvasRef} width={640} height={380} className="sf-scratch-canvas absolute inset-0 w-full h-full" onPointerDown={beginScratch} onPointerMove={moveScratch} onPointerUp={endScratch} onPointerCancel={endScratch} onContextMenu={event => event.preventDefault()} />}
          </div>
          <div className={`sf-progress ${revealed ? 'is-complete' : ''}`}><div className="sf-progress-label"><span>{revealed ? 'Premio rivelato' : finishing ? 'Rivelazione premio...' : 'Superficie scoperta'}</span><strong>{percent}%</strong></div><div className="sf-progress-track"><div style={{ width: `${Math.min(percent / 60 * 100, 100)}%` }} /></div></div>
        </>
      )}
      {!result && (
        <GameButton
          disabled={busy || buying || (!hasTicket && user.tokens < game.ticketPrice)}
          onClick={hasTicket ? start : buyTicket}
          label={busy ? 'Preparazione...' : buying ? 'Acquisto...' : hasTicket ? 'Usa 1 biglietto' : user.tokens >= game.ticketPrice ? `Compra 1 biglietto - ${game.ticketPrice} gettoni` : `Servono ${game.ticketPrice} gettoni`}
        />
      )}
      {error && <StateMessage text={error} tone="error" />}
    </div>
  )
}

function BoxGame({ user, game, onPlay, onComplete }: { user: User; game: PlayableGame; onPlay: Props['onPlay']; onComplete: () => Promise<void> }) {
  const reducedMotion = useReducedMotion()
  const viewportRef = useRef<HTMLDivElement>(null)
  const [result, setResult] = useState<GamePlayResult | null>(null)
  const [items, setItems] = useState<Array<{ label: string; color: string }>>([])
  const [x, setX] = useState(0)
  const [busy, setBusy] = useState(false)
  const [finished, setFinished] = useState(false)
  const [error, setError] = useState('')
  const start = async () => {
    setBusy(true); setFinished(false); setResult(null); setX(0); setError('')
    try {
      const played = await onPlay('box')
      const line = Array.from({ length: 110 }, (_, index) => game.options[index % game.options.length])
      line[played.boxStopIndex] = { code: played.code, label: played.label, color: played.rewardColor }
      setItems(line)
      setResult(played)
      requestAnimationFrame(() => {
        const width = viewportRef.current?.clientWidth ?? 330
        setX(-(played.boxStopIndex * 128) + width / 2 - 59)
      })
    } catch (caught) {
      setBusy(false)
      setError(italianErrorMessage(caught, 'Mystery Box non disponibile.'))
    }
  }
  return (
    <div className="sf-game-stage w-full text-center p-5 sm:p-7 rounded-3xl" style={gamePanel}>
      <TicketBalance value={user.boxTickets} />
      <div ref={viewportRef} className="sf-box-viewport relative overflow-hidden my-9 py-5">
        <div className="sf-box-marker" />
        {!items.length ? <div className="sf-idle-state sf-idle-compact"><Gift size={34} /><strong>Cassa chiusa</strong><span>Apri la scatola per avviare l'estrazione.</span></div> : (
          <motion.div className="sf-box-reel flex gap-[10px]" animate={{ x }}
            transition={{ duration: reducedMotion ? .25 : 4.2, ease: [0.1, 0.7, 0.1, 1] }}
            onAnimationComplete={() => { if (x !== 0) { setBusy(false); setFinished(true); if (!reducedMotion) confetti({ particleCount: 44, spread: 52, colors: ['#8B5CF6', '#22C55E'] }); void onComplete() } }}>
            {items.map((item, index) => (
              <div key={index} className="sf-box-item shrink-0 flex items-center justify-center rounded-xl px-2" style={{ width: 118, height: 82, borderColor: item.color }}>
                <span style={{ fontSize: 12 }}>{item.label}</span>
              </div>
            ))}
          </motion.div>
        )}
      </div>
      {finished && result && <Reward result={result} />}
      {!items.length && <GameButton disabled={busy || user.boxTickets < 1} onClick={start} label={busy ? 'Apertura...' : user.boxTickets ? 'Apri Mystery Box' : 'Nessun biglietto'} />}
      {error && <StateMessage text={error} tone="error" />}
    </div>
  )
}

function Reward({ result, compact = false }: { result: GamePlayResult; compact?: boolean }) {
  return (
    <div className={compact ? 'sf-reward-compact' : 'sf-reward-card p-4 mb-5 rounded-xl'}>
      <Trophy size={compact ? 22 : 18} style={{ color: '#22C55E', margin: '0 auto 8px' }} />
      <strong style={{ display: 'block', color: '#22C55E', fontSize: compact ? 20 : undefined }}>{result.label}</strong>
      {(result.tokensAwarded > 0 || result.xpAwarded > 0) && <span style={{ fontSize: 13 }}>+{result.tokensAwarded} gettoni / +{result.xpAwarded} XP</span>}
    </div>
  )
}
function TicketBalance({ value }: { value: number }) {
  return <div className="sf-ticket-balance flex justify-between p-4 rounded-xl"><span className="flex items-center gap-2"><Ticket size={17} /> Biglietti disponibili</span><strong>{value.toString().padStart(2, '0')}</strong></div>
}
function TicketShop({ user, game, buying, hidden, onBuy }: { user: User; game: PlayableGame; buying: boolean; hidden?: boolean; onBuy: () => void }) {
  if (hidden) return null
  const canBuy = user.tokens >= game.ticketPrice
  return (
    <div className="sf-ticket-shop">
      <div>
        <span>Biglietto</span>
        <strong>{game.ticketPrice} gettoni</strong>
      </div>
      <div>
        <span>Saldo</span>
        <strong>{user.tokens} gettoni</strong>
      </div>
      <button type="button" disabled={buying || !canBuy} onClick={onBuy}>
        {buying ? 'Acquisto...' : canBuy ? 'Compra 1 biglietto' : 'Saldo insufficiente'}
      </button>
    </div>
  )
}
function GameButton({ disabled, onClick, label }: { disabled: boolean; onClick: () => void; label: string }) {
  return <button disabled={disabled} onClick={onClick} className="sf-game-action w-full py-4 rounded-xl">{label}<ArrowRight size={17} /></button>
}
function StateMessage({ text, tone }: { text: string; tone?: 'error' }) {
  return <div className={`sf-game-message ${tone ? 'is-error' : ''} p-4 my-4 rounded-xl text-center`}>{text}</div>
}
function MiniTicket({ label, value }: { label: string; value: number }) {
  return <div><span>{label}</span><strong>{value.toString().padStart(2, '0')}</strong></div>
}
function TrustBadge({ Icon, label }: { Icon: typeof ShieldCheck; label: string }) {
  return <span><Icon size={13} /> {label}</span>
}
function GameArtwork({ type }: { type: GameType }) {
  if (type === 'spin') {
    return <div className="sf-card-art sf-card-wheel"><div className="sf-card-wheel-disc"><span /></div></div>
  }
  if (type === 'scratch') {
    return <div className="sf-card-art sf-card-scratch"><div><span>SF</span><strong>?</strong></div></div>
  }
  return <div className="sf-card-art sf-card-box"><div className="sf-card-box-lid" /><div className="sf-card-box-body"><span /></div></div>
}
function playTicks(duration: number) {
  try {
    const context = new AudioContext()
    const interval = window.setInterval(() => {
      const oscillator = context.createOscillator()
      const gain = context.createGain()
      oscillator.frequency.value = 720
      gain.gain.value = 0.025
      oscillator.connect(gain).connect(context.destination)
      oscillator.start()
      oscillator.stop(context.currentTime + .02)
    }, 110)
    window.setTimeout(() => { window.clearInterval(interval); void context.close() }, duration)
  } catch {
    // Audio is optional and can be blocked by browser policies.
  }
}
function wait(ms: number) {
  return new Promise(resolve => window.setTimeout(resolve, ms))
}
function wheelGradient(colors: string[]) {
  if (!colors.length) return '#7E9CA8 0 50%, #D7FE55 50% 100%'
  const step = 100 / colors.length
  return colors.map((color, index) => `${color} ${index * step}% ${(index + 1) * step}%`).join(',')
}
function isPurchasable(type: GameType) {
  return type === 'spin' || type === 'scratch'
}

const gameCard = { color: '#F5F5F5' }
const gamePanel = {}
const pill = { display: 'inline-flex', alignItems: 'center', gap: 5, padding: '6px 10px', borderRadius: 30, background: 'rgba(139,92,246,.16)', color: '#F5F5F5', fontSize: 13 }
const iconButton = { borderRadius: 12, padding: 10, background: 'rgba(255,255,255,.05)', border: '1px solid rgba(255,255,255,.1)', color: '#F5F5F5' }
