-- SmarTeam D'Elite: schema del database (Supabase / Postgres)
-- Da incollare nel SQL Editor di Supabase ed eseguire una volta.
-- Regola di fondo: ogni utente vede e modifica solo la propria rete (sé stesso e
-- tutto il suo grappolo, a ogni livello). Il Board vede tutto.

create extension if not exists pgcrypto;

-- ---------- tabelle ----------
create table if not exists public.persone (
  id uuid primary key default gen_random_uuid(),
  sponsor_id uuid references public.persone(id) on delete cascade,
  ruolo text not null default 'membro' check (ruolo in ('board', 'visionario', 'coleader', 'membro')),
  slot smallint check (slot between 1 and 99),
  nome text not null default '',
  cognome text not null default '',
  telefono text not null default '',
  email text not null default '',
  provincia text not null default '',
  referral_link text not null default '',
  zoom_pro boolean not null default false,
  ticket boolean not null default false,
  contratto_tipo text check (contratto_tipo in ('AZ', 'UL')),
  contratto_stato text not null default 'nessuno' check (contratto_stato in ('nessuno', 'incompleto', 'inserito', 'verifica', 'fornitura', 'uscito')),
  contratto_data date,
  iscrizione_data date not null default current_date,
  note text not null default '',
  auth_user_id uuid unique,
  invitato_il timestamptz,
  ultimo_accesso timestamptz,
  creato_il timestamptz not null default now(),
  aggiornato_il timestamptz not null default now()
);
-- per chi aveva già creato la tabella con la versione precedente
alter table public.persone add column if not exists invitato_il timestamptz;
alter table public.persone add column if not exists ultimo_accesso timestamptz;
create index if not exists persone_sponsor_idx on public.persone (sponsor_id);
create index if not exists persone_email_idx on public.persone (lower(email));

create table if not exists public.presenze (
  persona_id uuid not null references public.persone(id) on delete cascade,
  data date not null,
  slot text not null check (slot in ('0845', '1430', '2200')),
  primary key (persona_id, data, slot)
);
create index if not exists presenze_data_idx on public.presenze (data);

create table if not exists public.checkin (
  persona_id uuid not null references public.persone(id) on delete cascade,
  data date not null,
  contatti smallint not null default 0 check (contatti >= 0),
  appuntamenti smallint not null default 0 check (appuntamenti >= 0),
  ingressi smallint not null default 0 check (ingressi >= 0),
  aggiornato_il timestamptz not null default now(),
  primary key (persona_id, data)
);
create index if not exists checkin_data_idx on public.checkin (data);

-- Kit strumenti: video, presentazioni, Excel, Word e documenti che il Board mette a disposizione di tutta la rete
create table if not exists public.risorse (
  id uuid primary key default gen_random_uuid(),
  titolo text not null check (length(trim(titolo)) > 0),
  descrizione text not null default '',
  tipo text not null check (tipo in ('video', 'presentazione', 'excel', 'word', 'pdf', 'link', 'altro')),
  url text not null default '',
  file_path text,
  file_nome text,
  file_byte bigint,
  creato_da uuid references public.persone(id) on delete set null,
  creato_il timestamptz not null default now()
);
create index if not exists risorse_creato_idx on public.risorse (creato_il desc);

-- Inviti con link (WhatsApp o email): chi riceve il link sceglie la sua password.
-- Del link si salva solo l'impronta (sha256): chi legge la tabella non può ricostruirlo.
create table if not exists public.inviti (
  token_hash text primary key,
  persona_id uuid not null references public.persone(id) on delete cascade,
  creato_da uuid references public.persone(id) on delete set null,
  creato_il timestamptz not null default now(),
  scade_il timestamptz not null default now() + interval '14 days',
  usato_il timestamptz
);
create index if not exists inviti_persona_idx on public.inviti (persona_id);

-- ---------- funzioni di supporto (security definer: leggono senza passare dalle policy) ----------
create or replace function public.my_persona_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.persone where auth_user_id = auth.uid() limit 1
$$;

create or replace function public.is_board() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.persone where auth_user_id = auth.uid() and ruolo = 'board')
$$;

-- tutta la rete sotto una persona, lei compresa
create or replace function public.subtree_ids(radice uuid) returns setof uuid
language sql stable security definer set search_path = public as $$
  with recursive t(id) as (
    select id from public.persone where id = radice
    union
    select p.id from public.persone p join t on p.sponsor_id = t.id
  )
  select id from t
$$;

-- Collega l'account (email del login) alla scheda persona con la stessa email.
-- Restituisce l'id della persona, o null se l'email non è nella rete.
create or replace function public.claim_profile() returns uuid
language plpgsql security definer set search_path = public as $$
declare
  mia_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  pid uuid;
begin
  if auth.uid() is null then return null; end if;
  select id into pid from public.persone where auth_user_id = auth.uid() limit 1;
  if pid is null and mia_email <> '' then
    update public.persone set auth_user_id = auth.uid()
      where id = (select id from public.persone where lower(email) = mia_email and auth_user_id is null order by creato_il limit 1)
      returning id into pid;
  end if;
  if pid is not null then
    -- ultimo accesso, per il monitoraggio del Board (al massimo una scrittura ogni 5 minuti)
    perform set_config('smarteam.accesso', '1', true);
    update public.persone set ultimo_accesso = now()
      where id = pid and (ultimo_accesso is null or ultimo_accesso < now() - interval '5 minutes');
    perform set_config('smarteam.accesso', '', true);
  end if;
  return pid;
end
$$;

-- Crea il link d'invito per una persona della propria rete (il Board: per chiunque).
-- Restituisce il codice da mettere nel link; i link precedenti non ancora usati smettono di valere.
create or replace function public.crea_invito(persona uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  io uuid := public.my_persona_id();
  b public.persone;
  tok text;
begin
  if io is null then raise exception 'Accedi con un account della rete per invitare'; end if;
  select * into b from public.persone where id = persona;
  if b.id is null then raise exception 'Persona non trovata'; end if;
  if b.ruolo = 'board' then raise exception 'Il Board entra con il suo accesso unico'; end if;
  if b.id = io then raise exception 'Non puoi invitare te stesso'; end if;
  if not (public.is_board() or b.id in (select public.subtree_ids(io))) then
    raise exception 'Questa persona non è nella tua rete';
  end if;
  tok := translate(encode(gen_random_bytes(24), 'base64'), '+/=', '-_');
  delete from public.inviti where persona_id = persona and usato_il is null;
  insert into public.inviti (token_hash, persona_id, creato_da) values (encode(digest(tok, 'sha256'), 'hex'), persona, io);
  perform set_config('smarteam.accesso', '1', true);
  update public.persone set invitato_il = now() where id = persona;
  perform set_config('smarteam.accesso', '', true);
  return tok;
end
$$;

-- Chi apre il link vede a chi è intestato (nome, email già scritta, chi lo invita). Link scaduto o usato: null.
create or replace function public.leggi_invito(tok text) returns json
language sql stable security definer set search_path = public, extensions as $$
  select json_build_object(
    'nome', p.nome, 'cognome', p.cognome, 'email', p.email, 'ruolo', p.ruolo,
    'sponsor', case when s.ruolo = 'board' or s.id is null then 'il Board SmarTeam' else trim(s.nome || ' ' || s.cognome) end,
    'gia_attivo', p.auth_user_id is not null)
  from public.inviti i
  join public.persone p on p.id = i.persona_id
  left join public.persone s on s.id = p.sponsor_id
  where i.token_hash = encode(digest(coalesce(tok, ''), 'sha256'), 'hex') and i.usato_il is null and i.scade_il > now()
$$;

-- ---------- protezioni sulle modifiche ----------
create or replace function public.proteggi_persona() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.aggiornato_il := now();
  -- SQL Editor e chiave di servizio (nessun utente nel token): nessun limite
  if auth.uid() is null then return new; end if;
  -- data dell'invito e ultimo accesso li scrivono solo la funzione inviti e claim_profile
  if tg_op = 'INSERT' then
    new.invitato_il := null;
    new.ultimo_accesso := null;
  elsif coalesce(current_setting('smarteam.accesso', true), '') <> '1' then
    new.invitato_il := old.invitato_il;
    new.ultimo_accesso := old.ultimo_accesso;
  end if;
  if public.is_board() then return new; end if;
  -- solo il Board crea o promuove persone del Board
  if new.ruolo = 'board' and (tg_op = 'INSERT' or old.ruolo <> 'board') then
    raise exception 'Solo il Board può assegnare il ruolo Board';
  end if;
  if tg_op = 'UPDATE' then
    if new.ruolo <> old.ruolo and old.id = public.my_persona_id() then
      raise exception 'Non puoi cambiare il tuo ruolo';
    end if;
    if new.sponsor_id is distinct from old.sponsor_id and old.id = public.my_persona_id() then
      raise exception 'Non puoi cambiare il tuo sponsor';
    end if;
    -- il collegamento all'account lo fa solo claim_profile (da vuoto all'utente stesso)
    if new.auth_user_id is distinct from old.auth_user_id
       and not (old.auth_user_id is null and new.auth_user_id = auth.uid() and lower(old.email) = lower(coalesce(auth.jwt() ->> 'email', ''))) then
      raise exception 'Collegamento account non consentito';
    end if;
  elsif new.auth_user_id is not null then
    raise exception 'Collegamento account non consentito';
  end if;
  return new;
end
$$;

drop trigger if exists proteggi_persona on public.persone;
create trigger proteggi_persona before insert or update on public.persone
  for each row execute function public.proteggi_persona();

-- ---------- Row Level Security ----------
alter table public.persone enable row level security;
alter table public.presenze enable row level security;
alter table public.checkin enable row level security;
alter table public.risorse enable row level security;

drop policy if exists persone_leggi on public.persone;
create policy persone_leggi on public.persone for select to authenticated
  using (public.is_board() or id in (select public.subtree_ids(public.my_persona_id())));

drop policy if exists persone_inserisci on public.persone;
create policy persone_inserisci on public.persone for insert to authenticated
  with check (public.is_board() or sponsor_id in (select public.subtree_ids(public.my_persona_id())));

drop policy if exists persone_modifica on public.persone;
create policy persone_modifica on public.persone for update to authenticated
  using (public.is_board() or id in (select public.subtree_ids(public.my_persona_id())))
  with check (public.is_board() or id = public.my_persona_id() or sponsor_id in (select public.subtree_ids(public.my_persona_id())));

drop policy if exists persone_elimina on public.persone;
create policy persone_elimina on public.persone for delete to authenticated
  using (public.is_board() or (id <> public.my_persona_id() and id in (select public.subtree_ids(public.my_persona_id()))));

drop policy if exists presenze_tutto on public.presenze;
create policy presenze_tutto on public.presenze for all to authenticated
  using (public.is_board() or persona_id in (select public.subtree_ids(public.my_persona_id())))
  with check (public.is_board() or persona_id in (select public.subtree_ids(public.my_persona_id())));

drop policy if exists checkin_tutto on public.checkin;
create policy checkin_tutto on public.checkin for all to authenticated
  using (public.is_board() or persona_id in (select public.subtree_ids(public.my_persona_id())))
  with check (public.is_board() or persona_id in (select public.subtree_ids(public.my_persona_id())));

-- il kit lo vede chiunque sia nella rete, lo cambia solo il Board
drop policy if exists risorse_leggi on public.risorse;
create policy risorse_leggi on public.risorse for select to authenticated
  using (public.my_persona_id() is not null);
drop policy if exists risorse_inserisci on public.risorse;
create policy risorse_inserisci on public.risorse for insert to authenticated with check (public.is_board());
drop policy if exists risorse_modifica on public.risorse;
create policy risorse_modifica on public.risorse for update to authenticated using (public.is_board()) with check (public.is_board());
drop policy if exists risorse_elimina on public.risorse;
create policy risorse_elimina on public.risorse for delete to authenticated using (public.is_board());

-- gli inviti non si leggono né si scrivono direttamente: solo con crea_invito, leggi_invito e la funzione accetta-invito
alter table public.inviti enable row level security;

revoke all on public.persone, public.presenze, public.checkin, public.risorse, public.inviti from anon;
revoke all on public.inviti from authenticated;
grant select, insert, update, delete on public.persone, public.presenze, public.checkin, public.risorse to authenticated;
revoke execute on function public.claim_profile(), public.my_persona_id(), public.is_board(), public.subtree_ids(uuid), public.crea_invito(uuid), public.leggi_invito(text) from public;
grant execute on function public.claim_profile(), public.my_persona_id(), public.is_board(), public.subtree_ids(uuid), public.crea_invito(uuid) to authenticated;
revoke execute on function public.claim_profile(), public.my_persona_id(), public.is_board(), public.subtree_ids(uuid), public.crea_invito(uuid) from anon;
grant execute on function public.leggi_invito(text) to anon, authenticated;

-- ---------- file del kit (Supabase Storage, cartella privata "kit", 50 MB a file) ----------
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit) values ('kit', 'kit', false, 52428800)
      on conflict (id) do update set public = false, file_size_limit = 52428800;
    drop policy if exists kit_leggi on storage.objects;
    create policy kit_leggi on storage.objects for select to authenticated
      using (bucket_id = 'kit' and public.my_persona_id() is not null);
    drop policy if exists kit_carica on storage.objects;
    create policy kit_carica on storage.objects for insert to authenticated
      with check (bucket_id = 'kit' and public.is_board());
    drop policy if exists kit_modifica on storage.objects;
    create policy kit_modifica on storage.objects for update to authenticated
      using (bucket_id = 'kit' and public.is_board());
    drop policy if exists kit_elimina on storage.objects;
    create policy kit_elimina on storage.objects for delete to authenticated
      using (bucket_id = 'kit' and public.is_board());
  end if;
end
$$;
