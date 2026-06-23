const exactMessages: Record<string, string> = {
  FEEDBACK_INVALID: 'La recensione non è valida.',
  COMPLETED_ORDER_REQUIRED: 'Puoi lasciare una recensione solo dopo un ordine completato.',
  SPIN_TICKET_REQUIRED: 'Non hai biglietti disponibili per la ruota.',
  SCRATCH_TICKET_REQUIRED: 'Non hai biglietti disponibili per Scratch.',
  BOX_TICKET_REQUIRED: 'Non hai biglietti disponibili per Mystery Box.',
  GAME_NOT_AVAILABLE: 'Questo gioco non è ancora disponibile.',
  TICKET_PURCHASE_UNAVAILABLE: 'Questo biglietto non è acquistabile.',
  TICKET_BALANCE_REQUIRED: 'Gettoni insufficienti per acquistare il biglietto.',
  TICKET_PRICE_INVALID: 'Prezzo biglietto non valido.',
  REWARD_DISTRIBUTION_INVALID: 'Le probabilità attive devono totalizzare esattamente 100%.',
  ESTR_NOT_OPEN: 'Questa Estrazione non è aperta.',
  ESTR_NUMBER_INVALID: 'Seleziona un numero valido da 1 a 99.',
  ESTR_NUMBER_TAKEN: 'Questo numero è già stato scelto.',
  ESTR_TICKET_ALREADY_BOUGHT: 'Hai già acquistato un biglietto per questa Estrazione.',
  ESTR_TICKET_BALANCE_REQUIRED: 'Gettoni insufficienti per acquistare il biglietto Estrazione.',
  ESTR_SOLD_OUT: 'Biglietti esauriti.',
  ESTR_TITLE_INVALID: 'Titolo Estrazione non valido.',
  ESTR_PRICE_INVALID: 'Prezzo Estrazione non valido.',
  ESTR_MIN_ORDERS_INVALID: 'Numero minimo ordini non valido.',
  ESTR_MAX_TICKETS_INVALID: 'Numero massimo biglietti non valido.',
  ESTR_WINNERS_INVALID: 'Numero vincitori non valido.',
  ESTR_NOT_FOUND: 'Estrazione non trovata.',
  ESTR_LOCKED: 'Questa Estrazione non può più essere modificata.',
  ESTR_OPEN_INVALID_STATUS: 'Puoi aprire solo una Estrazione in bozza.',
  ESTR_SCHEDULE_TOO_SOON: 'Programma l’Estrazione almeno 75 secondi nel futuro.',
  ESTR_SCHEDULE_INVALID_STATUS: 'Puoi programmare solo una Estrazione sold out.',
  ESTR_NOT_ENOUGH_TICKETS: 'Non ci sono abbastanza biglietti per i posti vincenti.',
  ESTR_RUN_INVALID_STATUS: 'Questa Estrazione non può essere avviata.',
  ESTR_NOT_DUE: 'L’orario dell’Estrazione non è ancora arrivato.',
  ONLY_EARNED_WHEEL_AVAILABLE: 'È disponibile solo la ruota dei premi.',
  'Reward configuration invalid': 'Configurazione premi non valida.',
  'Staging access denied': 'Accesso non autorizzato.',
  KYC_REQUIRED_FIRST_ORDER: 'Completa prima la verifica dell’identità.',
  SCENARIO_INVALID: 'Scenario non valido.',
  CART_EMPTY: 'Il carrello è vuoto.',
  ITEM_UNAVAILABLE: 'Prodotto non disponibile.',
  CITY_STREET_REQUIRED: 'Inserisci città e via.',
  CITY_NOT_AVAILABLE: 'Città non disponibile.',
  STREET_REQUIRED: 'Inserisci la via.',
  TOKEN_RESERVE_INVALID: 'Numero di gettoni non valido.',
  TOKEN_SPEND_REQUIRED: 'Usa almeno un gettone per continuare.',
  GRAM_AMOUNT_INVALID: 'Inserisci almeno 25 g, in multipli di 25 g.',
  ORDER_MUST_BE_ACCEPTED: 'Accetta prima l’ordine.',
  INVALID_ORDER_TRANSITION: 'Transizione ordine non valida.',
  'Account bloccato.': 'Il tuo account è bloccato.',
  'Username Telegram richiesto.': 'Imposta un username @ nelle impostazioni Telegram prima di accedere.',
}

export function italianErrorMessage(error: unknown, fallback = 'Operazione non riuscita. Riprova.') {
  const message = error instanceof Error
    ? error.message
    : typeof error === 'string'
      ? error
      : ''

  if (!message) return fallback
  if (exactMessages[message]) return exactMessages[message]
  if (message.startsWith('STOCK_NOT_ENOUGH:')) return `Magazzino insufficiente: ${message.split(':').slice(1).join(':')}.`
  if (message.startsWith('MINIMUM_UNITS_REQUIRED:')) return `Sono necessari almeno ${message.split(':')[1]} g.`
  if (message.startsWith('MAXIMUM_UNITS_SUPPORTED:')) return `Sono supportati al massimo ${message.split(':')[1]} g.`
  if (message.startsWith('ESTR_COMPLETED_ORDERS_REQUIRED:')) return `Servono almeno ${message.split(':')[1]} ordini completati per acquistare il biglietto.`
  if (/more than one relationship|could not embed|schema cache/i.test(message)) return 'Impossibile caricare i dati collegati. Aggiorna la pagina e riprova.'
  if (/duplicate key|already registered|already exists|unique constraint/i.test(message)) return 'Esiste già un elemento con questi dati.'
  if (/foreign key|still referenced|violates.*constraint/i.test(message)) return 'Operazione non possibile perché esistono dati collegati.'
  if (/row-level security|permission denied|not authorized|unauthorized|jwt|allowlist|access denied/i.test(message)) return 'Non sei autorizzato a eseguire questa operazione.'
  if (/failed to fetch|fetch failed|network|load failed/i.test(message)) return 'Connessione non disponibile. Controlla la rete e riprova.'
  if (/invalid login credentials|email not confirmed|otp|token.*expired/i.test(message)) return 'Accesso non valido o scaduto. Riprova.'
  if (/^Errore|^Impossibile|^Non |^Accesso |^Operazione |^La |^Il |^Inserisci |^Acquisisci |^KYC |^Fotocamera |^Foto |^Nessun |^Prodotto |^Categoria |^Configurazione |^Caricamento |^Invio |^Lettura |^Decisione |^Verifica |^Autorizzazione |^Dati |^Richiesta |^Codice |^Metodo |^Motivo |^Saldo |^Sono |^Puoi |^Completa |^Questo |^Seleziona |^Conservazione /i.test(message)) return message
  return fallback
}
