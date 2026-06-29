import { useEffect, useState } from 'react'
import { Instagram, MessageCircle, Send } from 'lucide-react'
import type { DemoInfo } from '../data'
import { getDemoInfo } from '../lib/api'
import { italianErrorMessage } from '../lib/errors'

const emptyContacts: DemoInfo = { disclaimer: '', instagram: '', telegram: null, viber: '', signal: null }

export function ContactsPage() {
  const [contacts, setContacts] = useState<DemoInfo>(emptyContacts)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  useEffect(() => {
    let active = true
    getDemoInfo()
      .then(info => {
        if (active) setContacts(info)
      })
      .catch(caught => {
        if (active) setError(italianErrorMessage(caught, 'Contatti non disponibili.'))
      })
      .finally(() => {
        if (active) setLoading(false)
      })
    return () => { active = false }
  }, [])

  return (
    <div className="min-h-screen px-4 md:px-8 py-10" style={{ paddingTop: 100 }}>
      <div className="max-w-2xl mx-auto">
        <div className="sf-kicker mb-5">Contatti</div>
        <section className="p-6" style={panel}>
          <h1 style={heading}>Rimani in contatto</h1>
          <p style={copy}>Apri uno dei canali ufficiali disponibili.</p>
          {loading && <p className="mt-7" style={copy}>Caricamento contatti...</p>}
          {error && <p className="p-3 mt-6 rounded-xl" style={errorPanel}>{error}</p>}
          {!loading && !error && (
            <div className="grid gap-3 mt-7">
              <ContactLink Icon={Instagram} label="Instagram" href={contacts.instagram} />
              <ContactLink Icon={Send} label="Telegram" href={contacts.telegram} />
              <ContactLink Icon={MessageCircle} label="Viber" href={contacts.viber} />
              <ContactLink Icon={MessageCircle} label="Signal" href={contacts.signal} />
            </div>
          )}
        </section>
      </div>
    </div>
  )
}

function ContactLink({ Icon, label, href }: { Icon: typeof Instagram; label: string; href: string | null }) {
  const content = (
    <>
      <Icon size={22} style={{ color: '#D7FE55', flexShrink: 0 }} />
      <strong>{label}</strong>
      <span style={{ ...copy, marginLeft: 'auto', color: href ? '#D7FE55' : 'rgba(245,245,245,.42)' }}>
        {href ? 'Apri' : 'In arrivo'}
      </span>
    </>
  )
  if (!href) return <div className="flex items-center gap-4 p-4 rounded-xl" style={linkPanel}>{content}</div>
  return (
    <a href={href} target="_blank" rel="noopener noreferrer" className="flex items-center gap-4 p-4 rounded-xl" style={{ ...linkPanel, textDecoration: 'none', color: '#F5F5F5' }}>
      {content}
    </a>
  )
}

const panel = { background: '#11181B', border: '1px solid rgba(126,156,168,.18)' }
const heading = { fontFamily: 'Space Grotesk', fontWeight: 700, fontSize: 27, marginBottom: 12 }
const copy = { color: 'rgba(245,245,245,.63)', fontSize: 14, lineHeight: 1.65 }
const linkPanel = { background: 'rgba(245,245,245,.025)', border: '1px solid rgba(126,156,168,.16)' }
const errorPanel = { color: '#FCA5A5', background: '#35161e', border: '1px solid rgba(252,165,165,.25)' }
