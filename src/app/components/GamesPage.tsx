import { useState } from 'react'
import { motion } from 'motion/react'
import confetti from 'canvas-confetti'
import { Ticket, Trophy } from 'lucide-react'
import type { GamePlayResult, User } from '../data'

interface Props {
  user: User
  onSpin: () => Promise<GamePlayResult>
  onComplete: () => Promise<void>
}

const wheelColors = ['#7E9CA8', '#B99361', '#D7FE55', '#182226', '#7E9CA8', '#B99361', '#D7FE55', '#182226']

export function GamesPage({ user, onSpin, onComplete }: Props) {
  const [result, setResult] = useState<GamePlayResult | null>(null)
  const [rotation, setRotation] = useState(0)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const spin = async () => {
    setBusy(true)
    setError('')
    try {
      const played = await onSpin()
      setRotation(value => value + 1800 + Math.floor(Math.random() * 8) * 45)
      window.setTimeout(() => {
        setResult(played)
        confetti({ particleCount: 70, colors: ['#D7FE55', '#B99361'] })
      }, 1450)
      await onComplete()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Spin non disponibile.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="min-h-screen px-4 md:px-8 py-10" style={{ paddingTop: 100 }}>
      <div className="max-w-lg mx-auto">
        <div className="sf-kicker mb-4">Earned reward</div>
        <h1 style={{ fontFamily: 'Space Grotesk', fontWeight: 700, fontSize: 34, marginBottom: 10 }}>Ruota dei premi</h1>
        <p style={{ color: 'rgba(245,245,245,.58)', marginBottom: 26 }}>Ricevi 1 ticket ogni 5 scenari demo completati. La ruota non consuma gettoni.</p>
        <div className="flex justify-between p-4 mb-6" style={panel}>
          <span className="flex items-center gap-2"><Ticket size={17} style={{ color: '#D7FE55' }} /> Ticket disponibili</span>
          <strong style={{ color: '#D7FE55', fontFamily: 'Orbitron' }}>{user.spinTickets}</strong>
        </div>
        <div className="p-7 text-center" style={panel}>
          <motion.div
            className="mx-auto mb-7 rounded-full flex items-center justify-center"
            animate={{ rotate: rotation }}
            transition={{ duration: 1.45, ease: [0.12, 0.85, 0.2, 1] }}
            style={{ width: 250, height: 250, background: `conic-gradient(${wheelColors.join(',')})`, border: '5px solid #11181B' }}
          >
            <div className="rounded-full flex items-center justify-center" style={{ width: 92, height: 92, background: '#080C0E', border: '1px solid rgba(215,254,85,.25)', fontFamily: 'Orbitron', color: '#D7FE55' }}>SPIN</div>
          </motion.div>
          {result && (
            <div className="p-4 mb-5" style={{ background: 'rgba(215,254,85,.07)', border: '1px solid rgba(215,254,85,.22)' }}>
              <Trophy size={18} style={{ color: '#D7FE55', margin: '0 auto 8px' }} />
              <strong style={{ display: 'block', color: '#D7FE55' }}>{result.label}</strong>
              {(result.tokensAwarded > 0 || result.xpAwarded > 0) && <span style={{ fontSize: 13 }}>+{result.tokensAwarded} gettoni / +{result.xpAwarded} XP</span>}
            </div>
          )}
          <button disabled={busy || user.spinTickets < 1} onClick={spin} className="w-full py-4" style={{ ...button, opacity: busy || user.spinTickets < 1 ? .45 : 1 }}>
            {busy ? 'Estrazione...' : user.spinTickets > 0 ? 'Usa 1 ticket' : 'Nessun ticket disponibile'}
          </button>
          {error && <p style={{ color: '#EF4444', marginTop: 14 }}>{error}</p>}
        </div>
      </div>
    </div>
  )
}

const panel = { background: '#11181B', border: '1px solid rgba(126,156,168,.18)' }
const button = { background: '#D7FE55', color: '#080C0E', border: 'none', fontFamily: 'Space Grotesk', fontWeight: 700 }
