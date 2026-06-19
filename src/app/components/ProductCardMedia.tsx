import { useEffect, useRef, type CSSProperties } from 'react'
import { Tag } from 'lucide-react'
import type { Product, ProductMedia } from '../data'

interface Props {
  product: Product
  height: number
}

export function ProductCardMedia({ product, height }: Props) {
  const media = product.media.find(item => item.url) ?? null
  return (
    <div className="relative w-full overflow-hidden" style={{ height, background: '#182226' }}>
      {media ? (
        <Media media={media} productName={product.name} />
      ) : product.img ? (
        <img src={product.img} alt={product.name} className="w-full h-full object-cover" />
      ) : (
        <div className="flex w-full h-full items-center justify-center" style={{ color: 'rgba(245,245,245,.35)', fontFamily: 'Orbitron', fontSize: 11 }}>MEDIA</div>
      )}
      {product.promoTag.trim() && (
        <div className="absolute left-3 bottom-3 flex items-center gap-2 px-3 py-2" style={tagPill}>
          <Tag size={17} style={{ color: '#F5A400', flexShrink: 0 }} />
          <span className="truncate">{product.promoTag.trim()}</span>
        </div>
      )}
    </div>
  )
}

function Media({ media, productName }: { media: ProductMedia; productName: string }) {
  return media.type === 'video'
    ? <VideoPreview src={media.url} className="w-full h-full object-cover" />
    : <img src={media.url} alt={media.alt ?? productName} className="w-full h-full object-cover" />
}

export function VideoPreview({ src, className, style }: { src: string; className?: string; style?: CSSProperties }) {
  const videoRef = useRef<HTMLVideoElement | null>(null)
  const seekedRef = useRef(false)

  useEffect(() => {
    seekedRef.current = false
    const video = videoRef.current
    if (!video) return
    video.muted = true
    video.load()
    void video.play().catch(() => {
      // Browser autoplay policy can still refuse; the decoded frame remains visible.
    })
  }, [src])

  const warmPreview = () => {
    const video = videoRef.current
    if (!video) return
    video.muted = true
    if (!seekedRef.current && Number.isFinite(video.duration) && video.duration > 0.4) {
      seekedRef.current = true
      try {
        video.currentTime = Math.min(0.35, Math.max(0.12, video.duration * 0.04))
      } catch {
        // Some mobile browsers can reject early seeks until more data is buffered.
      }
    }
    void video.play().catch(() => {
      // Keep the frame preview even if autoplay is blocked.
    })
  }

  return (
    <video
      ref={videoRef}
      src={src}
      muted
      autoPlay
      loop
      playsInline
      preload="auto"
      onLoadedMetadata={warmPreview}
      onLoadedData={warmPreview}
      onCanPlay={warmPreview}
      className={className}
      style={style}
    />
  )
}

const tagPill: CSSProperties = {
  maxWidth: 'calc(100% - 24px)',
  background: 'rgba(32,27,24,.94)',
  color: '#F5F5F5',
  borderRadius: 12,
  fontFamily: 'Space Grotesk',
  fontSize: 19,
  fontWeight: 800,
  lineHeight: 1,
  boxShadow: '0 8px 20px rgba(0,0,0,.28)',
}
