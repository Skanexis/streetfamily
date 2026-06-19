import type { CSSProperties } from 'react'
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
    ? <video src={media.url} muted autoPlay loop playsInline preload="metadata" className="w-full h-full object-cover" />
    : <img src={media.url} alt={media.alt ?? productName} className="w-full h-full object-cover" />
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
