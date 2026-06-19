import { MapPin, Truck, type LucideIcon } from 'lucide-react'
import type { ServiceArea } from '../data'

interface Props {
  serviceAreas: ServiceArea[]
}

export function InfoPage({ serviceAreas }: Props) {
  const meetupGroups = groupAreas(serviceAreas.filter(area => area.scenarioType === 'meetup'))
  const deliveryGroups = groupAreas(serviceAreas.filter(area => area.scenarioType === 'delivery_zone'))
  const deliveryItaliaMinimum = serviceAreas.find(area => area.scenarioType === 'delivery_italia')?.minimumUnits ?? 500
  return (
    <div className="min-h-screen px-4 md:px-8 py-10" style={{ paddingTop: 100 }}>
      <div className="max-w-3xl mx-auto">
        <div className="sf-kicker mb-5">ℹ️ REGOLAMENTO ℹ️</div>
        <div>
          <section className="p-6" style={panel}>
            <p style={{ ...copy, fontSize: 16 }}>Da 300g fino a 3kg aggiungere ai prezzi menù <strong>10€ ogni 100g</strong>, da 5kg in su prezzi compreso trasporto.</p>
            
            <h3 style={serviceHeading}>MEET UP UFFICIALI</h3>
            {meetupGroups.map(group => <Rule key={`meetup-${group.minimumUnits}-${group.cities.join('-')}`} Icon={MapPin} title={group.cities.join(' / ').toUpperCase()} detail={`Minimo ordine ${group.minimumUnits}g`} />)}
            
            <h3 style={serviceHeading}>DELIVERY SEGUENTI ZONE</h3>
            {deliveryGroups.map(group => <Rule key={`delivery-${group.minimumUnits}-${group.cities.join('-')}`} Icon={Truck} title={group.cities.join(' / ').toUpperCase()} detail={`Minimo ordine ${group.minimumUnits}g`} />)}
            <p style={{ ...copy, marginTop: 8 }}>(Aggiungere 10€ ogni 100g)</p>
            
            <h3 style={serviceHeading}>DELIVERY TUTTA ITALIA</h3>
            <Rule Icon={Truck} title={`Minimo ordine ${deliveryItaliaMinimum}g`} text="La tariffa Delivery verrà stabilità in base la distanza e la quantità!" />
            
            <div className="p-4 mt-7 rounded-xl" style={highlight}>
              <p style={{ ...copy, color: '#D7FE55', fontWeight: 700, textTransform: 'uppercase' }}>
                Per avere un posto sicuro prenotarsi la sera prima dello scambio, oppure entro le 16.00 dello stesso giorno!
              </p>
            </div>
            
            <div className="p-4 mt-4 rounded-xl" style={notice}>
              <p style={{ ...copy, color: '#F5F5F5', fontWeight: 500, textTransform: 'uppercase' }}>
                Per i nuovi clienti abbiamo bisogno di una verifica d'identità per procedere con ordine! Una volta verificati saremo noi a decidere se andare avanti o no.
              </p>
              <p style={{ ...copy, color: '#D7FE55', fontWeight: 700, marginTop: 14, textTransform: 'uppercase' }}>
                Verifica approvata e primo ordine confermato: 5 gettoni in regalo subito. Il regalo viene accreditato una sola volta.
              </p>
              <p style={{ ...copy, color: '#D7FE55', fontWeight: 700, marginTop: 14, textTransform: 'uppercase' }}>
                Non accettiamo grandi ordini fuori regione per chi non ha mai comprato. Per usufruire del servizio Delivery quantità dovete essere clienti di fiducia!
              </p>
            </div>
          </section>
        </div>
      </div>
    </div>
  )
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

function Rule({ Icon, title, text, detail }: { Icon: LucideIcon; title: string; text?: string; detail?: string }) {
  return <div className="flex gap-4 mt-4 p-3 rounded-xl" style={rule}><Icon size={20} style={{ color: '#D7FE55', flexShrink: 0 }} /><div><strong>{title}</strong>{text && <p style={{ ...copy, marginTop: 5 }}>{text}</p>}{detail && <p style={{ ...copy, color: '#D7FE55', marginTop: 5, fontWeight: 700 }}>{detail}</p>}</div></div>
}

const panel = { background: '#11181B', border: '1px solid rgba(126,156,168,.18)' }
const heading = { fontFamily: 'Space Grotesk', fontWeight: 700, fontSize: 23, marginBottom: 12 }
const serviceHeading = { ...heading, fontSize: 18, marginTop: 28, marginBottom: 12, color: '#D7FE55', letterSpacing: '.04em' }
const copy = { color: 'rgba(245,245,245,.63)', fontSize: 14, lineHeight: 1.65 }
const rule = { background: 'rgba(245,245,245,.025)', border: '1px solid rgba(126,156,168,.16)' }
const highlight = { background: 'rgba(215,254,85,.06)', border: '1px solid rgba(215,254,85,.24)' }
const notice = { background: 'rgba(126,156,168,.08)', border: '1px solid rgba(215,254,85,.24)' }
