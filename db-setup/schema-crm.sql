-- SmarTeam D'Elite: sezione Contatti (CRM della lista referenze, Metodo 18!)
-- Migrazione SOLO ADDITIVA: da eseguire dopo schema.sql, nel SQL Editor di Supabase.
-- Non cancella e non rinomina nessuna tabella esistente. Si può rieseguire.
--
-- Chi vede cosa:
--   - ogni persona legge e modifica solo i propri contatti;
--   - lo sponsor legge (sola lettura) la lista dei suoi diretti;
--   - il Board legge tutte le liste della rete.

-- ---------- tabelle ----------
create table if not exists public.contatti (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.persone(id) on delete cascade,
  num integer not null check (num > 0),
  priorita integer not null default 0,
  cognome text not null default '',
  nome text not null default '',
  cellulare text not null default '' check (cellulare = '' or cellulare ~ '^\+[1-9][0-9]{5,14}$'),
  email text not null default '',
  eta_fascia smallint check (eta_fascia between 1 and 4),
  prov text not null default '' check (length(prov) <= 3),
  professione text not null default '',
  grande_perche text not null default '' check (grande_perche ~ '^S?D?R?$'),
  tipo text not null check (tipo in ('C', 'T', 'F')),
  note text not null default '',
  -- stato del funnel (una riga per contatto); il percorso completo è in contatti_eventi
  s1 text check (s1 in ('A', 'I', 'N')),
  s1_fascia text check (s1_fascia in ('M', 'P', 'S')),
  s2 text check (s2 in ('A', 'I', 'N')),
  s2_fascia text check (s2_fascia in ('M', 'P', 'S')),
  s3 text check (s3 in ('A', 'I', 'N')),
  s4 text check (s4 in ('A', 'I', 'N')),
  s5 text check (s5 in ('A', 'I')),
  s6 text check (s6 in ('I', 'N')),
  s7 text check (s7 in ('I', 'N', 'R')),
  s8 text check (s8 in ('V', 'N')),
  s9 text check (s9 in ('V', 'N')),
  ricontatto_dal date,
  video1_alle timestamptz,
  persona_id uuid references public.persone(id) on delete set null,
  creato_il timestamptz not null default now(),
  aggiornato_il timestamptz not null default now(),
  unique (owner_id, num)
);
create index if not exists contatti_owner_idx on public.contatti (owner_id);
create unique index if not exists contatti_cell_unico on public.contatti (owner_id, cellulare) where cellulare <> '';
create unique index if not exists contatti_email_unica on public.contatti (owner_id, lower(email)) where email <> '';

create table if not exists public.contatti_eventi (
  id uuid primary key default gen_random_uuid(),
  contatto_id uuid not null references public.contatti(id) on delete cascade,
  owner_id uuid not null references public.persone(id) on delete cascade,
  step smallint not null check (step between 0 and 9), -- 0 = creato o importato
  valore text,                                         -- null = valore tolto
  fascia text check (fascia in ('M', 'P', 'S')),
  quando timestamptz not null default now(),
  nota text not null default ''
);
create index if not exists eventi_contatto_idx on public.contatti_eventi (contatto_id);
create index if not exists eventi_owner_quando_idx on public.contatti_eventi (owner_id, quando);

create table if not exists public.appuntamenti (
  id uuid primary key default gen_random_uuid(),
  contatto_id uuid not null references public.contatti(id) on delete cascade,
  owner_id uuid not null references public.persone(id) on delete cascade,
  quando timestamptz not null,
  modo text not null default 'zoom' check (modo in ('zoom', 'live')),
  dove text not null default '',            -- link Zoom o indirizzo
  partecipante_id uuid references public.persone(id) on delete set null,
  conferma_inviata boolean not null default false,
  d1 text not null default '',
  d2 text not null default '',
  d3_tipo text not null default '' check (d3_tipo ~ '^S?D?R?$'),
  d3_testo text not null default '',
  creato_il timestamptz not null default now()
);
create index if not exists appuntamenti_owner_idx on public.appuntamenti (owner_id, quando);
create index if not exists appuntamenti_partecipante_idx on public.appuntamenti (partecipante_id, quando);

create table if not exists public.attivita (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.persone(id) on delete cascade,
  contatto_id uuid references public.contatti(id) on delete cascade,
  tipo text not null check (tipo in ('video1', 'richiamata', 'rifissare', 'kit', 'conferma', 'altro')),
  scade_il timestamptz not null,
  fatto_il timestamptz,
  testo text not null default '',
  creato_il timestamptz not null default now()
);
create index if not exists attivita_owner_idx on public.attivita (owner_id, scade_il);

create table if not exists public.agenda_slot (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.persone(id) on delete cascade,
  inizio timestamptz not null,
  con_sponsor boolean not null default false,
  nota text not null default '',
  unique (owner_id, inizio)
);

create table if not exists public.crm_profilo (
  persona_id uuid primary key references public.persone(id) on delete cascade,
  obiettivo smallint not null default 180 check (obiettivo in (180, 360, 540, 720)),
  aggiornato_il timestamptz not null default now()
);

-- Script del funnel (nel kit): li scrive il Board, li legge tutta la rete
create table if not exists public.script (
  id uuid primary key default gen_random_uuid(),
  titolo text not null check (length(trim(titolo)) > 0),
  step smallint check (step between 1 and 9),
  variante text not null default '',
  testo text not null default '',       -- la traccia da seguire
  messaggio text not null default '',   -- il testo da mandare su WhatsApp
  ordine integer not null default 0,
  creato_da uuid references public.persone(id) on delete set null,
  creato_il timestamptz not null default now()
);

-- Impostazioni del metodo (data dell'obiettivo, link dei video): le scrive il Board
create table if not exists public.impostazioni (
  chiave text primary key check (chiave in ('data_obiettivo', 'link_video1', 'link_video2')),
  valore text not null default '',
  aggiornato_il timestamptz not null default now()
);

-- ---------- chi può leggere la lista di chi ----------
create or replace function public.vede_lista(owner uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select owner = public.my_persona_id()
      or public.is_board()
      or exists (select 1 from public.persone where id = owner and sponsor_id = public.my_persona_id())
$$;

-- ---------- protezioni ----------
create or replace function public.proteggi_contatto() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  ruolo_owner text;
begin
  new.aggiornato_il := now();
  -- regole di scrittura uguali all'app: cognome MAIUSCOLO, nome con l'iniziale maiuscola
  new.cognome := upper(btrim(new.cognome));
  new.nome := initcap(lower(btrim(new.nome)));
  new.email := lower(btrim(new.email));
  new.prov := upper(btrim(new.prov));
  if tg_op = 'UPDATE' then
    new.owner_id := old.owner_id;  -- il proprietario non cambia
    new.num := old.num;            -- il numero non cambia mai
    new.creato_il := old.creato_il;
  end if;
  -- il contatto si collega solo a una persona del proprio grappolo (per il Board: ai visionari)
  if new.persona_id is not null and new.persona_id is distinct from (case when tg_op = 'UPDATE' then old.persona_id end) then
    select ruolo into ruolo_owner from public.persone where id = new.owner_id;
    if not exists (
      select 1 from public.persone p
      where p.id = new.persona_id and (p.sponsor_id = new.owner_id or (ruolo_owner = 'board' and p.ruolo = 'visionario'))
    ) then
      raise exception 'Questa persona non è nel tuo grappolo';
    end if;
  end if;
  return new;
end
$$;
drop trigger if exists proteggi_contatto on public.contatti;
create trigger proteggi_contatto before insert or update on public.contatti
  for each row execute function public.proteggi_contatto();

-- numero progressivo assegnato dal database se l'app non lo manda
create or replace function public.numera_contatto() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.num is null then
    perform pg_advisory_xact_lock(hashtext(new.owner_id::text));
    select coalesce(max(num), 0) + 1 into new.num from public.contatti where owner_id = new.owner_id;
  end if;
  return new;
end
$$;
drop trigger if exists numera_contatto on public.contatti;
create trigger numera_contatto before insert on public.contatti
  for each row execute function public.numera_contatto();

-- ---------- Row Level Security ----------
alter table public.contatti enable row level security;
alter table public.contatti_eventi enable row level security;
alter table public.appuntamenti enable row level security;
alter table public.attivita enable row level security;
alter table public.agenda_slot enable row level security;
alter table public.crm_profilo enable row level security;
alter table public.script enable row level security;
alter table public.impostazioni enable row level security;

-- contatti: legge chi vede la lista, scrive solo il proprietario
drop policy if exists contatti_leggi on public.contatti;
create policy contatti_leggi on public.contatti for select to authenticated using (public.vede_lista(owner_id));
drop policy if exists contatti_inserisci on public.contatti;
create policy contatti_inserisci on public.contatti for insert to authenticated with check (owner_id = public.my_persona_id());
drop policy if exists contatti_modifica on public.contatti;
create policy contatti_modifica on public.contatti for update to authenticated
  using (owner_id = public.my_persona_id()) with check (owner_id = public.my_persona_id());
drop policy if exists contatti_elimina on public.contatti;
create policy contatti_elimina on public.contatti for delete to authenticated using (owner_id = public.my_persona_id());

-- eventi: si aggiungono solo ai propri contatti, non si modificano
drop policy if exists eventi_leggi on public.contatti_eventi;
create policy eventi_leggi on public.contatti_eventi for select to authenticated using (public.vede_lista(owner_id));
drop policy if exists eventi_inserisci on public.contatti_eventi;
create policy eventi_inserisci on public.contatti_eventi for insert to authenticated
  with check (owner_id = public.my_persona_id()
              and exists (select 1 from public.contatti c where c.id = contatto_id and c.owner_id = public.my_persona_id()));

-- appuntamenti: anche il partecipante (sponsor o Board) li vede
drop policy if exists appuntamenti_leggi on public.appuntamenti;
create policy appuntamenti_leggi on public.appuntamenti for select to authenticated
  using (public.vede_lista(owner_id) or partecipante_id = public.my_persona_id());
drop policy if exists appuntamenti_scrivi on public.appuntamenti;
create policy appuntamenti_scrivi on public.appuntamenti for all to authenticated
  using (owner_id = public.my_persona_id())
  with check (owner_id = public.my_persona_id()
              and exists (select 1 from public.contatti c where c.id = contatto_id and c.owner_id = public.my_persona_id()));

drop policy if exists attivita_leggi on public.attivita;
create policy attivita_leggi on public.attivita for select to authenticated using (public.vede_lista(owner_id));
drop policy if exists attivita_scrivi on public.attivita;
create policy attivita_scrivi on public.attivita for all to authenticated
  using (owner_id = public.my_persona_id()) with check (owner_id = public.my_persona_id());

drop policy if exists slot_leggi on public.agenda_slot;
create policy slot_leggi on public.agenda_slot for select to authenticated using (public.vede_lista(owner_id));
drop policy if exists slot_scrivi on public.agenda_slot;
create policy slot_scrivi on public.agenda_slot for all to authenticated
  using (owner_id = public.my_persona_id()) with check (owner_id = public.my_persona_id());

drop policy if exists profilo_leggi on public.crm_profilo;
create policy profilo_leggi on public.crm_profilo for select to authenticated using (public.vede_lista(persona_id));
drop policy if exists profilo_scrivi on public.crm_profilo;
create policy profilo_scrivi on public.crm_profilo for all to authenticated
  using (persona_id = public.my_persona_id()) with check (persona_id = public.my_persona_id());

drop policy if exists script_leggi on public.script;
create policy script_leggi on public.script for select to authenticated using (public.my_persona_id() is not null);
drop policy if exists script_scrivi on public.script;
create policy script_scrivi on public.script for all to authenticated using (public.is_board()) with check (public.is_board());

drop policy if exists impostazioni_leggi on public.impostazioni;
create policy impostazioni_leggi on public.impostazioni for select to authenticated using (public.my_persona_id() is not null);
drop policy if exists impostazioni_scrivi on public.impostazioni;
create policy impostazioni_scrivi on public.impostazioni for all to authenticated using (public.is_board()) with check (public.is_board());

-- ---------- numeri per i cruscotti ----------
-- Conteggi per persona: tipo (C/T/F), valori di ogni step, a bordo negli ultimi 7 giorni.
-- Restituisce solo le liste che chi chiede può vedere (Board: tutte).
create or replace function public.crm_numeri() returns table (owner_id uuid, campo text, valore text, n integer)
language sql stable security definer set search_path = public as $$
  with visibili as (
    select c.* from public.contatti c where public.vede_lista(c.owner_id)
  )
  select v.owner_id, x.campo, x.valore, count(*)::int
  from visibili v
  cross join lateral (values ('tipo', v.tipo), ('s1', v.s1), ('s2', v.s2), ('s3', v.s3), ('s4', v.s4), ('s5', v.s5),
                             ('s6', v.s6), ('s7', v.s7), ('s8', v.s8), ('s9', v.s9),
                             ('ricontatto', case when v.ricontatto_dal is not null then 'S' end)) as x(campo, valore)
  where x.valore is not null
  group by 1, 2, 3
  union all
  select v.owner_id, 'bordo7', 'I', count(distinct v.id)::int
  from visibili v join public.contatti_eventi e on e.contatto_id = v.id
  where v.s7 = 'I' and e.step = 7 and e.valore = 'I' and e.quando >= now() - interval '7 days'
  group by 1
$$;

-- ---------- primi script (dal documento "Script per FUNNEL CONTATTO", 2/11/2026) ----------
-- Si caricano solo se la tabella è vuota; poi il Board li modifica dal Kit.
insert into public.script (titolo, step, variante, testo, messaggio, ordine)
select * from (values
    ($s$1° contatto telefonico$s$, 1, $s$Solo contatti caldi$s$, $s$D: Ciao {NOME}, tutto ok?
(Brevissimo small talk)
Vado dritto al punto: "Siccome ho grande considerazione di te e tengo molto alla tua opinione (COMPLIMENTO SINCERO), se ti mandassi un video di un minuto (frutto di anni di esperienza), mi daresti un feedback?"
R: Sì ok, ma di cosa si tratta?
D1: Lo scoprirai nel video, {NOME}. Proprio per questo ti ho chiamato.
(D2: Si tratta di scoprire un Metodo innovativo per guadagnare almeno 9.000€ al mese di Rendita. Non di guadagno!… Conosci la differenza, vero?)
D: Quando pensi di poterlo vedere?
R1: Anche ora.
D1: Ok, allora ti chiamo tra un paio di minuti e mi dici cosa ti è piaciuto di più, ok?
R2: Stasera verso le 19:30/40.
D2: Ok perfetto, allora ti mando il link del video stasera a quell'ora. Poi, se sei d'accordo, ti chiamo dopo un paio di minuti e mi dici cosa ti è piaciuto di più… ok? Sai che ci tengo molto al tuo feedback…
R: Ok.

CHIAMATA DOPO 2 MINUTI
D: Cosa ti è piaciuto di più del video?
R: Mah, interessante… la Rendita… ma 9.000€ al mese entro aprile mi sembra un po' esagerato…
D: Capisco… anche io lo credevo… ma poi ho realizzato che è davvero possibile attraverso questo Metodo del 18 Fattoriale (18!)… Se ci fissassimo uno Zoom di 15-20 minuti max in cui andiamo nel dettaglio a capire come sia possibile, senza praticamente nessun investimento, arrivare in 6 mesi ad avere una Rendita di 9.000€ al mese, potrebbe interessarti?
R: Sì ok, voglio approfondire.
D: Perfetto, guardo l'agenda… Preferisci mattino, pomeriggio o sera, questa settimana o meglio la prossima (se questa siamo già full!)?
R: Pomeriggio.
D: Allora ti propongo o venerdì alle 15 o la prossima settimana martedì alle 18?
R: Ok, venerdì alle 15.
D: Perfetto. Segnato in agenda. Ti mando un messaggio di conferma il giorno prima, ok?
R: Perfetto! A venerdì!$s$, $s$$s$, 0),
    ($s$2° contatto telefonico$s$, 2, $s$Solo contatti caldi, in una fascia diversa dal 1°$s$, $s$(Da chiamare in una fascia oraria diversa dal primo contatto: M 9-12, P 12-18, S 18-21)
D: Ciao {NOME}, avevo provato a contattarti stamattina / nel pomeriggio / ieri sera…
R: Sì, ero impegnato… scusa se non sono riuscito poi a richiamarti…
D: Non ti preoccupare…
(Ripetiamo lo schema di prima)
Vado dritto al punto: "Siccome ho grande considerazione di te e tengo molto alla tua opinione (COMPLIMENTO SINCERO), se ti mandassi un video di un minuto, frutto di anni di esperienza, mi daresti un feedback?"
R: Sì ok, ma di cosa si tratta?
D: Lo scoprirai nel video, {NOME}. Proprio per questo ti ho chiamato.
(D: Si tratta di scoprire un Metodo innovativo per guadagnare almeno 9.000€ al mese di Rendita. Non di guadagno!… Conosci la differenza, vero?)
D: Quando pensi di poterlo vedere?
R1: Anche ora.
D1: Ok, allora ti chiamo tra un paio di minuti e mi dici cosa ti è piaciuto di più, ok?
R2: Stasera verso le 19:30/40.
D2: Ok perfetto, allora ti mando il link del video stasera a quell'ora. Poi, se sei d'accordo, ti chiamo dopo un paio di minuti e mi dici cosa ti è piaciuto di più… ok? Sai che ci tengo molto al tuo feedback…
R: Ok.

CHIAMATA DOPO 2 MINUTI
D: Cosa ti è piaciuto di più del video?
R: Mah, interessante… la Rendita… ma 9.000€ al mese entro aprile mi sembra un po' esagerato…
D: Capisco… anche io lo credevo… ma poi ho realizzato che è davvero possibile attraverso questo Metodo del 18 Fattoriale (18!)… Se ci fissassimo uno Zoom di 15-20 minuti max in cui andiamo nel dettaglio a capire come sia possibile, senza praticamente nessun investimento, arrivare in 6 mesi ad avere una Rendita di 9.000€ al mese, potrebbe interessarti?
R: Sì ok, voglio approfondire.
D: Perfetto, guardo l'agenda… Preferisci mattino, pomeriggio o sera, questa settimana o meglio la prossima (se questa siamo già full!)?
R: Pomeriggio.
D: Allora ti propongo o venerdì alle 15 o la prossima settimana martedì alle 18?
R: Ok, venerdì alle 15.
D: Perfetto. Segnato in agenda. Ti mando un messaggio di conferma il giorno prima, ok?
R: Perfetto! A venerdì!$s$, $s$$s$, 1),
    ($s$Script WhatsApp v1$s$, 3, $s$Caldi che non hanno risposto alle 2 telefonate (meglio un audio)$s$, $s$Ciao {NOME}, come stai? Ho provato a chiamarti un paio di volte ma probabilmente eri impegnato. Vado dritto al punto… premesso che ho grande stima di te e ci tengo molto al tuo parere… se ti mandassi un breve video di meno di un minuto, mi daresti un feedback?
R: Non ora però… sono molto incasinato in questo periodo…
D: Immagino, so che sei sempre molto impegnato ma, come ti dicevo, tengo molto al tuo feedback… quando potresti avere un minuto per guardarlo?
R: Mah, proviamo domani alle 19:30/20.
D: Ok perfetto, allora ti mando il link del video domani a quell'ora. Poi, se sei d'accordo, ti chiamo dopo un paio di minuti e mi dici cosa ti è piaciuto di più… ok? Sai che ci tengo molto al tuo feedback.$s$, $s$Ciao {NOME}, come stai? Ho provato a chiamarti un paio di volte ma probabilmente eri impegnato. Vado dritto al punto… premesso che ho grande stima di te e ci tengo molto al tuo parere… se ti mandassi un breve video di meno di un minuto, mi daresti un feedback?$s$, 2),
    ($s$Script WhatsApp v2$s$, 3, $s$Contatti tiepidi e freddi$s$, $s$D: Ciao {NOME}, come stai? È un po' che non ci sentiamo… sai che ho pensato proprio a te l'altro giorno…
R: Ciao, tutto bene dai… e tu? A proposito di cosa?
D: Tutto benissimo grazie… sono supercontento perché finalmente, dopo anni, ho scoperto un Metodo molto innovativo che mi permette di vivere di Rendita… a tal proposito… siccome sai quanto ti stimo (COMPLIMENTO SINCERO) e tengo molto al tuo parere…
"Se ti mandassi un breve video di meno di un minuto, mi daresti un feedback?"
R: Ok, ma di cosa si tratta?
D: (Lo scoprirai nel video, {NOME}. Proprio per questo ho pensato a te!)
D: Si tratta di scoprire un Metodo innovativo per vivere di Rendita, ovvero arrivare ad almeno 9.000€ al mese di Rendita. Non di guadagno!… Conosci la differenza, vero?
D: Quando pensi di poterlo vedere?
R1: Anche ora.
D1: Ok, allora ti mando il link del video e ti chiamo tra un paio di minuti così mi dici cosa ti è piaciuto di più, ok?
R2: Stasera verso le 19:30/40.
D2: Ok perfetto, allora ti mando il link del video stasera a quell'ora. Poi, se sei d'accordo, ti chiamo dopo un paio di minuti e mi dici cosa ti è piaciuto di più… ok? Sai che ci tengo molto al tuo feedback…
R: Ok.

CHIAMATA DOPO 2 MINUTI
D: Cosa ti è piaciuto di più del video?
R: Mah, interessante… la Rendita… ma 9.000€ al mese entro aprile mi sembra un po' esagerato…
D: Capisco… anche io lo credevo… ma poi ho realizzato che è davvero possibile attraverso questo Metodo del 18 Fattoriale (18!)… Se ci fissassimo uno Zoom di 15-20 minuti max in cui andiamo nel dettaglio a capire come sia possibile, senza praticamente nessun investimento, arrivare in 6 mesi ad avere una Rendita di 9.000€ al mese, potrebbe interessarti?
R: Sì ok, voglio approfondire.
D: Perfetto, guardo l'agenda… Preferisci mattino, pomeriggio o sera, questa settimana o meglio la prossima (se questa siamo già full!)?
R: Pomeriggio.
D: Allora ti propongo o venerdì alle 15 o la prossima settimana martedì alle 18?
R: Ok, venerdì alle 15.
D: Perfetto. Segnato in agenda. Ti mando un messaggio di conferma il giorno prima, ok?
R: Perfetto! A venerdì!$s$, $s$Ciao {NOME}, come stai? È un po' che non ci sentiamo… sai che ho pensato proprio a te l'altro giorno…$s$, 3),
    ($s$Presentazione con il Video 2 e chiusura$s$, 6, $s$Zoom o dal vivo: obiettivo farlo salire a bordo$s$, $s$(Small talk)
Fai partire il video dicendo appena prima:
"Mi raccomando, prendi appunti e ascolta molto attentamente perché ogni parola potrebbe stravolgerti la vita…"

Alla seconda slide fermi il video dopo ognuna delle 3 domande, lasci parlare la persona e ti scrivi le risposte.
D1: "Quando mi parlavi di almeno 9.000€ al mese di Rendita, lo dicevi sul serio o tanto per dire?"
D2: "Immagina quell'obiettivo con una data: {DATA_OBIETTIVO}. Cosa cambierebbe nella tua vita?"
D3: "Qual è il tuo Grande Perché? Un Grande Sogno, una Grande Sfida o un Grande Dolore?"
(Specifica che il Grande Perché deve richiedere tanti soldi per realizzarlo: più sarà grande il perché, prima si raggiunge la prima tappa dei 9.000€ al mese di Rendita. Think big: il simbolo ∞ del Metodo 1∞!)
Poi fai ripartire il video fino alla fine.

COSA DIRE ESATTAMENTE ALLA FINE DEL VIDEO
"Nel momento della decisione si plasma il tuo destino…" (Tony Robbins)
(Con decisione)
{NOME}, IL TRENO È GIÀ PARTITO. IO E {NOME_PARTECIPANTE} INIZIAMO LA PIANIFICAZIONE DEI TUOI 18 STASERA STESSA. HO BISOGNO DI UN BUON NO O DI UN BUON SÌ. SE SEI DENTRO, FIRMIAMO IL PATTO DI FOCUS TOTALE PER QUESTI 6 MESI. SE DEVI PENSARCI, RISPETTO IL TUO TEMPO, MA DEVO LIBERARE IL POSTO PER IL PROSSIMO PROFILO. COSA FACCIAMO?$s$, $s$$s$, 4)
) as v(titolo, step, variante, testo, messaggio, ordine)
where not exists (select 1 from public.script);

-- ---------- permessi ----------
revoke all on public.contatti, public.contatti_eventi, public.appuntamenti, public.attivita, public.agenda_slot,
  public.crm_profilo, public.script, public.impostazioni from anon;
grant select, insert, update, delete on public.contatti, public.appuntamenti, public.attivita, public.agenda_slot,
  public.crm_profilo, public.script, public.impostazioni to authenticated;
grant select, insert on public.contatti_eventi to authenticated;
revoke execute on function public.vede_lista(uuid), public.crm_numeri() from public;
grant execute on function public.vede_lista(uuid), public.crm_numeri() to authenticated;

-- ---------- ripristino dei contatti dal backup (solo Board) ----------
-- Aggiunge quello che manca, non cancella e non sovrascrive niente.
-- L'app prepara i dati (liste di persone presenti, numeri liberi, niente doppioni);
-- qui ogni contatto entra da solo: se uno non entra (es. persona collegata non più nel grappolo)
-- si riprova senza il collegamento, e gli altri entrano comunque.
create or replace function public.crm_ripristina(dati jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare
  r public.contatti;
  n integer := 0;
  k integer;
begin
  if not public.is_board() then
    raise exception 'Solo il Board può ripristinare i contatti';
  end if;
  for r in select * from jsonb_populate_recordset(null::public.contatti, coalesce(dati->'contatti', '[]'::jsonb)) loop
    begin
      insert into public.contatti select r.* on conflict do nothing;
      get diagnostics k = row_count; n := n + k;
    exception when others then
      begin
        r.persona_id := null;
        insert into public.contatti select r.* on conflict do nothing;
        get diagnostics k = row_count; n := n + k;
      exception when others then null;
      end;
    end;
  end loop;
  insert into public.contatti_eventi
    select e.* from jsonb_populate_recordset(null::public.contatti_eventi, coalesce(dati->'eventi', '[]'::jsonb)) e
    where exists (select 1 from public.contatti c where c.id = e.contatto_id and c.owner_id = e.owner_id)
    on conflict do nothing;
  insert into public.appuntamenti
    select a.* from jsonb_populate_recordset(null::public.appuntamenti, coalesce(dati->'appuntamenti', '[]'::jsonb)) a
    where exists (select 1 from public.contatti c where c.id = a.contatto_id and c.owner_id = a.owner_id)
      and (a.partecipante_id is null or exists (select 1 from public.persone p where p.id = a.partecipante_id))
    on conflict do nothing;
  insert into public.attivita
    select t.* from jsonb_populate_recordset(null::public.attivita, coalesce(dati->'attivita', '[]'::jsonb)) t
    where exists (select 1 from public.persone p where p.id = t.owner_id)
      and (t.contatto_id is null or exists (select 1 from public.contatti c where c.id = t.contatto_id and c.owner_id = t.owner_id))
    on conflict do nothing;
  insert into public.agenda_slot
    select s.* from jsonb_populate_recordset(null::public.agenda_slot, coalesce(dati->'slot', '[]'::jsonb)) s
    where exists (select 1 from public.persone p where p.id = s.owner_id)
    on conflict do nothing;
  insert into public.crm_profilo (persona_id, obiettivo)
    select p.persona_id, p.obiettivo from jsonb_populate_recordset(null::public.crm_profilo, coalesce(dati->'profili', '[]'::jsonb)) p
    where exists (select 1 from public.persone x where x.id = p.persona_id)
    on conflict do nothing;
  return n;
end
$$;
revoke execute on function public.crm_ripristina(jsonb) from public;
grant execute on function public.crm_ripristina(jsonb) to authenticated;
