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
        <div className="sf-kicker mb-5">ℹ️ REGOLAMENTO ℹ️</div>
        <h1 style={{ fontFamily: 'Space Grotesk', fontSize: 'clamp(32px,5vw,48px)', fontWeight: 700, marginBottom: 18 }}>Condizioni di servizio</h1>

        <div className="grid lg:grid-cols-[1.2fr_.8fr] gap-6">
          <section className="p-6" style={panel}>
            <h2 style={heading}>Prezzi e tariffe</h2>
            <p style={copy}>Da 300g fino a 3kg aggiungere ai prezzi menù <strong>10€ ogni 100g</strong>. Da 5kg in su prezzi compreso trasporto.</p>
            
            <h3 style={{ ...heading, fontSize: 18, marginTop: 20, marginBottom: 10 }}>INCONTRI UFFICIALI</h3>
            <p style={copy}>Possono scegliere solo città</p>
            <Rule Icon={MapPin} title="Minimo ordine 50g" text="Spoleto, Foligno, Gualdo, Bastia" />
            <Rule Icon={MapPin} title="Minimo ordine 100g" text="Perugia, Gubbio, Terni" />
            
            <h3 style={{ ...heading, fontSize: 18, marginTop: 20, marginBottom: 10 }}>CONSEGNA IN ZONA UMBRA</h3>
            <p style={copy}>Possono scegliere città/via</p>
            <p style={copy}>Minimo ordine: 300g (aggiungere 10€ ogni 100g)</p>
            
            <h3 style={{ ...heading, fontSize: 18, marginTop: 20, marginBottom: 10 }}>CONSEGNA FUORI REGIONE</h3>
            <p style={copy}>Possono inserire città/via</p>
            <p style={copy}>Minimo ordine: 500g. La tariffa di consegna verrà stabilita in base alla distanza e alla quantità.</p>
            
            <h3 style={{ ...heading, fontSize: 18, marginTop: 20, marginBottom: 10, color: '#D7FE55' }}>PRENOTAZIONE</h3>
            <p style={{ ...copy, color: '#D7FE55', fontWeight: 500 }}>Per avere un posto sicuro prenotarsi la sera prima dello scambio, oppure entro le 16:00 dello stesso giorno!</p>
            
            <h3 style={{ ...heading, fontSize: 18, marginTop: 20, marginBottom: 10, color: '#D7FE55' }}>VERIFICA KYC</h3>
            <p style={{ ...copy, color: '#D7FE55' }}>Per i nuovi clienti abbiamo bisogno di una verifica d'identità per procedere con l'ordine. Una volta verificati saremo noi a decidere se andare avanti o no.</p>
            <p style={{ ...copy, color: '#D7FE55', marginTop: 10 }}>Non accettiamo grandi ordini fuori regione per chi non ha mai comprato. Per usufruire del servizio di consegna per quantità dovete essere clienti di fiducia!</p>
          </section>

          <section className="p-6" style={panel}>
            <h2 style={heading}>Link ufficiali / Notizie della community</h2>
            <p style={copy}>Canali dedicati agli aggiornamenti della community. Non vengono usati dal sito per pagamenti o gestione degli ordini.</p>
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
