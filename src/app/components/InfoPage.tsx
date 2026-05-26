import { ExternalLink, Instagram, MapPin, MessageCircle, Truck } from 'lucide-react'
import type { DemoInfo } from '../data'

export function InfoPage({ info }: { info: DemoInfo }) {
  const links = [
    { label: 'Instagram', href: info.instagram, Icon: Instagram },
    { label: 'Canale Viber', href: info.viber, Icon: MessageCircle },
  ].filter(item => item.href)
  return (
    <div className="min-h-screen px-4 md:px-8 py-10" style={{ paddingTop: 100 }}>
      <div className="max-w-5xl mx-auto">
        <div className="sf-kicker mb-5">Regolamento demo</div>
        <h1 style={{ fontFamily: 'Space Grotesk', fontSize: 'clamp(32px,5vw,48px)', fontWeight: 700, marginBottom: 18 }}>Scenari e community news</h1>
        <div className="p-4 mb-9" style={{ color: '#D7FE55', background: 'rgba(215,254,85,.06)', border: '1px solid rgba(215,254,85,.25)' }}>
          {info.disclaimer}
        </div>

        <div className="grid lg:grid-cols-[1.2fr_.8fr] gap-6">
          <section className="p-6" style={panel}>
            <h2 style={heading}>Regole della simulazione</h2>
            <p style={copy}>La richiesta utilizza pacchetti dimostrativi espressi in units. I dati inseriti servono esclusivamente a testare interfaccia, approvazioni e rewards.</p>
            <Rule Icon={MapPin} title="Meet up simulato" text="Scegli solo una citta disponibile. Minimo 50 units in Spoleto, Foligno, Gualdo e Bastia; minimo 100 units in Perugia, Gubbio e Terni." />
            <Rule Icon={Truck} title="Delivery zone simulata" text="Citta disponibili: Umbertide, CDC, Matelica, Fabriano, Cagli e Cerreto Desi. Minimo 300 units, con via richiesta e surcharge demo di EUR 10 ogni 100 units." />
            <Rule Icon={Truck} title="Delivery Italia simulata" text="Inserisci citta e via. Minimo 500 units; eventuali condizioni sono solo informative nella richiesta demo." />
            <p style={{ ...copy, marginTop: 22 }}>La prima richiesta richiede una verifica identita: fronte documento, retro documento e selfie con documento. La revisione non garantisce l'accettazione di alcun servizio reale.</p>
          </section>

          <section className="p-6" style={panel}>
            <h2 style={heading}>Link ufficiali / Community news</h2>
            <p style={copy}>Canali dedicati ad aggiornamenti della community. Non vengono usati dal sito per pagamenti o fulfillment.</p>
            <div className="flex flex-col gap-3 mt-6">
              {links.map(({ label, href, Icon }) => (
                <a key={label} href={href} target="_blank" rel="noreferrer" className="flex justify-between items-center p-4" style={link}>
                  <span className="flex items-center gap-3"><Icon size={17} /> {label}</span><ExternalLink size={15} />
                </a>
              ))}
              <div className="p-4 flex justify-between" style={{ ...link, color: 'rgba(245,245,245,.46)' }}>
                <span className="flex gap-3"><MessageCircle size={17} /> Signal</span><span>{info.signal ?? 'In arrivo'}</span>
              </div>
            </div>
          </section>
        </div>
      </div>
    </div>
  )
}

function Rule({ Icon, title, text }: { Icon: typeof MapPin; title: string; text: string }) {
  return <div className="flex gap-4 mt-6"><Icon size={20} style={{ color: '#D7FE55', flexShrink: 0 }} /><div><strong>{title}</strong><p style={{ ...copy, marginTop: 5 }}>{text}</p></div></div>
}

const panel = { background: '#11181B', border: '1px solid rgba(126,156,168,.18)' }
const heading = { fontFamily: 'Space Grotesk', fontWeight: 700, fontSize: 23, marginBottom: 12 }
const copy = { color: 'rgba(245,245,245,.63)', fontSize: 14, lineHeight: 1.65 }
const link = { color: '#F5F5F5', border: '1px solid rgba(126,156,168,.22)', background: 'rgba(245,245,245,.025)' }
