import { useEffect, useRef, useState } from 'react'
import { Camera, Check, ShieldAlert } from 'lucide-react'
import type { KycDocumentType, KycStatus } from '../data'
import { submitKyc, uploadKycCapture } from '../lib/api'

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
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const stopCamera = () => {
    streamRef.current?.getTracks().forEach(track => track.stop())
    streamRef.current = null
    if (videoRef.current) videoRef.current.srcObject = null
    setActive(null)
  }
  useEffect(() => () => stopCamera(), [])

  const openCamera = async (capture: (typeof captures)[number]) => {
    setError('')
    stopCamera()
    try {
      if (!navigator.mediaDevices?.getUserMedia) throw new Error('Fotocamera non disponibile in questo browser.')
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: false,
        video: { facingMode: { ideal: capture.facingMode }, width: { ideal: 1600 }, height: { ideal: 1200 } },
      })
      streamRef.current = stream
      setActive(capture)
      window.setTimeout(() => {
        if (videoRef.current) {
          videoRef.current.srcObject = stream
          void videoRef.current.play()
        }
      }, 0)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Permesso fotocamera negato.')
    }
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
      setError(caught instanceof Error ? caught.message : 'Acquisizione fallita.')
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
      setError(caught instanceof Error ? caught.message : 'Invio KYC fallito.')
    } finally {
      setBusy(false)
    }
  }

  if (status.status === 'submitted') {
    return <Notice text="Documenti inviati. Il primo ordine sara disponibile dopo la verifica admin." />
  }
  if (status.status === 'approved') {
    return <Notice text="Identita verificata. Puoi completare il primo ordine." ok />
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
      {active && (
        <div className="mb-4">
          <video ref={videoRef} muted playsInline className="w-full rounded-xl mb-3" style={{ maxHeight: 300, objectFit: 'cover', background: '#000' }} />
          <div className="flex gap-2">
            <button disabled={busy} onClick={takePhoto} style={buttonStyle}>Scatta e carica</button>
            <button onClick={stopCamera} style={secondaryStyle}>Annulla</button>
          </div>
        </div>
      )}
      {allCaptured && !active && <button disabled={busy} onClick={sendForReview} style={buttonStyle}>Invia documenti alla verifica</button>}
      {error && <p style={{ color: '#F87171', marginTop: 12 }}>{error}</p>}
    </div>
  )
}

function Notice({ text, ok }: { text: string; ok?: boolean }) {
  return <div className="p-4 rounded-xl" style={{ color: ok ? '#D7FE55' : '#F59E0B', background: ok ? 'rgba(215,254,85,.08)' : 'rgba(245,158,11,.08)', border: `1px solid ${ok ? 'rgba(215,254,85,.25)' : 'rgba(245,158,11,.25)'}` }}>{text}</div>
}
const buttonStyle = { padding: '12px 18px', border: 'none', borderRadius: 10, color: '#F5F5F5', fontWeight: 700, background: 'linear-gradient(135deg,#7E9CA8,#B99361)' }
const secondaryStyle = { ...buttonStyle, background: 'rgba(245,245,245,.1)' }
