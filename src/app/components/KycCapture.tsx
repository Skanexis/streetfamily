import { useEffect, useRef, useState } from 'react'
import { Camera, Check, LoaderCircle, ShieldAlert, X } from 'lucide-react'
import type { KycDocumentType, KycStatus } from '../data'
import { submitKyc, uploadKycCapture } from '../lib/api'
import { italianErrorMessage } from '../lib/errors'

interface Props {
  status: KycStatus
  onChanged: () => Promise<void>
}

const captures: { type: KycDocumentType; label: string; facingMode: 'environment' | 'user' }[] = [
  { type: 'document_front', label: 'Fronte documento', facingMode: 'environment' },
  { type: 'document_back', label: 'Retro documento', facingMode: 'environment' },
  { type: 'selfie_with_document', label: 'Selfie con documento', facingMode: 'user' },
]

export function KycCapture({ status, onChanged }: Props) {
  const videoRef = useRef<HTMLVideoElement>(null)
  const streamRef = useRef<MediaStream | null>(null)
  const [active, setActive] = useState<(typeof captures)[number] | null>(null)
  const [cameraReady, setCameraReady] = useState(false)
  const [cameraAttempt, setCameraAttempt] = useState(0)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const stopStream = () => {
    streamRef.current?.getTracks().forEach(track => track.stop())
    streamRef.current = null
    if (videoRef.current) videoRef.current.srcObject = null
  }
  const stopCamera = () => {
    stopStream()
    setCameraReady(false)
    setActive(null)
  }

  useEffect(() => {
    if (!active) return
    let cancelled = false
    const startCamera = async () => {
      setCameraReady(false)
      stopStream()
      try {
        if (!navigator.mediaDevices?.getUserMedia) throw new Error('Fotocamera non disponibile in questo browser.')
        let stream: MediaStream
        try {
          stream = await navigator.mediaDevices.getUserMedia({
            audio: false,
            video: { facingMode: { ideal: active.facingMode }, width: { ideal: 1280 }, height: { ideal: 720 } },
          })
        } catch (firstError) {
          if (firstError instanceof DOMException && ['NotAllowedError', 'SecurityError'].includes(firstError.name)) throw firstError
          stream = await navigator.mediaDevices.getUserMedia({ audio: false, video: { facingMode: active.facingMode } })
        }
        if (cancelled) {
          stream.getTracks().forEach(track => track.stop())
          return
        }
        streamRef.current = stream
        const video = videoRef.current
        if (!video) throw new Error('Anteprima fotocamera non disponibile.')
        video.srcObject = stream
        await video.play()
      } catch (caught) {
        if (!cancelled) {
          stopStream()
          setError(cameraErrorMessage(caught))
        }
      }
    }
    void startCamera()
    return () => {
      cancelled = true
      stopStream()
    }
  }, [active, cameraAttempt])

  const openCamera = (capture: (typeof captures)[number]) => {
    setError('')
    setCameraAttempt(attempt => attempt + 1)
    setActive(capture)
  }
  const restartCamera = () => {
    setError('')
    setCameraAttempt(attempt => attempt + 1)
  }

  const takePhoto = async () => {
    if (!active || !videoRef.current) return
    setBusy(true)
    setError('')
    try {
      const video = videoRef.current
      if (!video.videoWidth || !video.videoHeight) throw new Error('Fotocamera non pronta.')
      const canvas = document.createElement('canvas')
      canvas.width = video.videoWidth
      canvas.height = video.videoHeight
      const context = canvas.getContext('2d')
      if (!context) throw new Error('Impossibile acquisire la foto.')
      context.drawImage(video, 0, 0, canvas.width, canvas.height)
      const blob = await new Promise<Blob>((resolve, reject) => canvas.toBlob(value => value ? resolve(value) : reject(new Error('Foto non valida.')), 'image/jpeg', 0.9))
      await uploadKycCapture(active.type, blob)
      stopCamera()
      await onChanged()
    } catch (caught) {
      setError(italianErrorMessage(caught, 'Acquisizione non riuscita.'))
    } finally {
      setBusy(false)
    }
  }

  const sendForReview = async () => {
    setBusy(true)
    try {
      await submitKyc()
      await onChanged()
    } catch (caught) {
      setError(italianErrorMessage(caught, 'Invio KYC non riuscito.'))
    } finally {
      setBusy(false)
    }
  }

  if (status.status === 'submitted') {
    return <Notice text="Documenti inviati. Il primo ordine sarà disponibile dopo la verifica dell'amministratore." />
  }
  if (status.status === 'approved') {
    return <Notice text="Identità verificata. Puoi completare il primo ordine." ok />
  }

  const allCaptured = captures.every(capture => status.documents.includes(capture.type))
  return (
    <div>
      <div className="p-3 rounded-xl mb-4" style={{ background: 'rgba(249,115,22,.1)', border: '1px solid rgba(249,115,22,.3)' }}>
        <ShieldAlert size={16} className="inline mr-2" style={{ color: '#F97316' }} />
        Verifica richiesta solo al primo ordine. Nessun file esterno: acquisizione esclusivamente dalla fotocamera.
      </div>
      {status.status === 'rejected' && <p style={{ color: '#F87171' }}>Verifica rifiutata: {status.rejectionReason}. Ripeti le acquisizioni.</p>}
      <div className="grid grid-cols-1 gap-2 my-4">
        {captures.map(capture => (
          <button key={capture.type} onClick={() => openCamera(capture)} className="flex justify-between p-3 rounded-xl" style={{ background: '#11181B', border: '1px solid rgba(126,156,168,.2)', color: '#F5F5F5' }}>
            <span><Camera size={16} className="inline mr-2" />{capture.label}</span>
            {status.documents.includes(capture.type) && <Check size={17} style={{ color: '#D7FE55' }} />}
          </button>
        ))}
      </div>
      {allCaptured && !active && <button disabled={busy} onClick={sendForReview} style={buttonStyle}>Invia documenti alla verifica</button>}
      {error && <p style={{ color: '#F87171', marginTop: 12 }}>{error}</p>}
      {active && (
        <div className="fixed inset-0 flex items-center justify-center p-4" style={{ zIndex: 92, background: 'rgba(0,0,0,.88)' }}>
          <div className="w-full max-w-xl p-4 rounded-2xl" style={{ background: '#11181B', border: '1px solid rgba(126,156,168,.3)' }}>
            <header className="flex justify-between items-center gap-3 mb-3">
              <div>
                <strong style={{ fontFamily: 'Space Grotesk', fontSize: 20 }}>{active.label}</strong>
                <div style={{ color: 'rgba(245,245,245,.58)', fontSize: 13 }}>Posiziona il documento nel riquadro e scatta una foto.</div>
              </div>
              <button onClick={stopCamera} aria-label="Chiudi fotocamera" style={iconButton}><X size={20} /></button>
            </header>
            <div className="relative mb-3 rounded-xl overflow-hidden" style={{ minHeight: 320, background: '#000' }}>
              <video
                ref={videoRef}
                autoPlay
                muted
                playsInline
                disablePictureInPicture
                onPlaying={() => setCameraReady(true)}
                className="w-full"
                style={{ height: 420, maxHeight: '62vh', objectFit: 'cover', background: '#000' }}
              />
              {!cameraReady && (
                <div className="absolute inset-0 flex flex-col items-center justify-center gap-3" style={{ color: '#F5F5F5', background: 'rgba(0,0,0,.65)' }}>
                  <LoaderCircle size={28} className="animate-spin" />
                  <span>Avvio fotocamera...</span>
                </div>
              )}
            </div>
            <div className="flex flex-wrap gap-2">
              <button disabled={busy || !cameraReady} onClick={takePhoto} style={{ ...buttonStyle, opacity: busy || !cameraReady ? .55 : 1 }}>Scatta e carica</button>
              <button disabled={busy} onClick={restartCamera} style={secondaryStyle}>Riavvia fotocamera</button>
              <button onClick={stopCamera} style={secondaryStyle}>Annulla</button>
            </div>
            {error && <p style={{ color: '#F87171', marginTop: 12 }}>{error}</p>}
          </div>
        </div>
      )}
    </div>
  )
}

function cameraErrorMessage(caught: unknown) {
  if (caught instanceof DOMException) {
    if (caught.name === 'NotAllowedError' || caught.name === 'SecurityError') return 'Accesso alla fotocamera negato. Controlla il permesso del browser e riapri la verifica.'
    if (caught.name === 'NotFoundError') return 'Nessuna fotocamera trovata sul dispositivo.'
    if (caught.name === 'NotReadableError') return 'La fotocamera è occupata da un’altra applicazione. Chiudila e riprova.'
  }
  return italianErrorMessage(caught, 'Impossibile avviare la fotocamera.')
}

function Notice({ text, ok }: { text: string; ok?: boolean }) {
  return <div className="p-4 rounded-xl" style={{ color: ok ? '#D7FE55' : '#F59E0B', background: ok ? 'rgba(215,254,85,.08)' : 'rgba(245,158,11,.08)', border: `1px solid ${ok ? 'rgba(215,254,85,.25)' : 'rgba(245,158,11,.25)'}` }}>{text}</div>
}
const buttonStyle = { padding: '12px 18px', border: 'none', borderRadius: 10, color: '#F5F5F5', fontWeight: 700, background: 'linear-gradient(135deg,#7E9CA8,#B99361)' }
const secondaryStyle = { ...buttonStyle, background: 'rgba(245,245,245,.1)' }
const iconButton = { padding: 8, borderRadius: 10, color: '#F5F5F5', background: 'rgba(245,245,245,.08)' }
