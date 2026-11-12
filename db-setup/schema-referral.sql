-- SmarTeam D'Elite: link referral della rete e messaggi d'invito.
-- Migrazione additiva: si esegue dopo schema.sql (e schema-crm.sql) e non tocca i dati esistenti.
-- Si può rieseguire senza problemi.
--
-- Come funziona:
-- - ognuno ha un codice fisso (persone.codice_invito) e un link "#/r/CODICE" da mandare a chi vuole;
-- - chi apre il link si registra ed entra subito sotto chi lo ha invitato, con il livello successivo
--   (sotto il Board un visionario, sotto un visionario un co-leader, poi membri) e il primo posto libero:
--   con i 18 posti pieni entra lo stesso, oltre il 18;
-- - la registrazione la fa la Edge Function "registrati" (account + scheda), mai il browser da solo;
-- - i messaggi d'invito standard li scrive il Board nella tabella impostazioni.

-- ---------- colonne nuove ----------
alter table public.persone add column if not exists codice_invito text;
alter table public.persone add column if not exists entrato_da text;
do $$ begin
  alter table public.persone add constraint persone_entrato_da_check check (entrato_da in ('link'));
exception when duplicate_object then null; end $$;
create unique index if not exists persone_codice_invito_idx on public.persone (codice_invito) where codice_invito is not null;

-- codice ed entrata li scrive solo il server (funzioni qui sotto e chiave di servizio)
create or replace function public.proteggi_referral() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'INSERT' then
    new.codice_invito := null;
    new.entrato_da := null;
  elsif coalesce(current_setting('smarteam.referral', true), '') <> '1' then
    new.codice_invito := old.codice_invito;
    new.entrato_da := old.entrato_da;
  end if;
  return new;
end
$$;
drop trigger if exists proteggi_referral on public.persone;
create trigger proteggi_referral before insert or update on public.persone
  for each row execute function public.proteggi_referral();

-- ---------- il proprio link ----------
-- Chi invita: la propria scheda. Per il Board (accesso unico) la persona del Board
-- sotto cui stanno i visionari (Alex), come per "A bordo" nei Contatti.
create or replace function public.titolare_referral() returns uuid
language sql stable security definer set search_path = public as $$
  select case when not public.is_board() then public.my_persona_id() else coalesce(
    (select v.sponsor_id from public.persone v join public.persone s on s.id = v.sponsor_id
      where v.ruolo = 'visionario' and s.ruolo = 'board' order by v.creato_il limit 1),
    (select id from public.persone where ruolo = 'board' and lower(nome) = 'alex' order by creato_il limit 1),
    public.my_persona_id()) end
$$;

create or replace function public.mio_codice_invito() returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  chi uuid := public.titolare_referral();
  cod text;
  alfabeto constant text := 'abcdefghjkmnpqrstuvwxyz23456789';
  i int;
begin
  if chi is null then raise exception 'Accedi con un account della rete per avere il tuo link'; end if;
  select codice_invito into cod from public.persone where id = chi;
  if cod is not null then return cod; end if;
  loop
    cod := '';
    for i in 1..8 loop
      cod := cod || substr(alfabeto, 1 + (get_byte(gen_random_bytes(1), 0) % length(alfabeto)), 1);
    end loop;
    exit when not exists (select 1 from public.persone where codice_invito = cod);
  end loop;
  perform set_config('smarteam.referral', '1', true);
  update public.persone set codice_invito = cod where id = chi and codice_invito is null;
  perform set_config('smarteam.referral', '', true);
  select codice_invito into cod from public.persone where id = chi;
  return cod;
end
$$;

-- Chi apre il link vede chi lo invita e con che livello entra. Codice inesistente: null.
create or replace function public.leggi_referral(cod text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'sponsor', case when s.ruolo = 'board' then 'il Board SmarTeam' else trim(s.nome || ' ' || s.cognome) end,
    'ruolo', case s.ruolo when 'board' then 'visionario' when 'visionario' then 'coleader' else 'membro' end)
  from public.persone s
  where s.codice_invito = lower(coalesce(cod, ''))
$$;

-- ---------- la registrazione (solo dalla Edge Function, con la chiave di servizio) ----------
-- Crea la scheda sotto chi ha il codice, collegata all'account appena creato.
create or replace function public.registra_da_link(cod text, uid uuid, p_nome text, p_cognome text, p_telefono text, p_email text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  s public.persone;
  posto int;
  nuovo uuid;
begin
  -- una registrazione alla volta per lo stesso sponsor: i posti non si sovrappongono
  select * into s from public.persone where codice_invito = lower(coalesce(cod, '')) for update;
  if s.id is null then raise exception 'Questo link non è valido: chiedi a chi te lo ha mandato di rimandartelo'; end if;
  if exists (select 1 from public.persone where lower(email) = lower(p_email)) then
    raise exception 'Questa email è già nella rete: se hai già un accesso entra con quella';
  end if;
  select coalesce(min(n), (select greatest(18, coalesce(max(slot), 0)) + 1 from public.persone where sponsor_id = s.id))
    into posto
    from generate_series(1, 18) n
    where not exists (select 1 from public.persone where sponsor_id = s.id and slot = n);
  if posto > 99 then raise exception 'Questa squadra è al completo: contatta chi ti ha mandato il link'; end if;
  insert into public.persone (sponsor_id, ruolo, slot, nome, cognome, telefono, email, auth_user_id, entrato_da, iscrizione_data)
  values (s.id, case s.ruolo when 'board' then 'visionario' when 'visionario' then 'coleader' else 'membro' end,
          posto, trim(p_nome), trim(p_cognome), trim(p_telefono), lower(trim(p_email)), uid, 'link', current_date)
  returning id into nuovo;
  return nuovo;
end
$$;

revoke execute on function public.registra_da_link(text, uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.registra_da_link(text, uuid, text, text, text, text) to service_role;
revoke execute on function public.titolare_referral() from public, anon;
grant execute on function public.titolare_referral() to authenticated;
revoke execute on function public.mio_codice_invito() from public, anon;
grant execute on function public.mio_codice_invito() to authenticated;
grant execute on function public.leggi_referral(text) to anon, authenticated;

-- ---------- messaggi d'invito standard ----------
-- Stanno nella tabella impostazioni dei Contatti (schema-crm.sql): qui si aggiungono le tre chiavi.
-- Se schema-crm.sql non è ancora stato eseguito, la tabella si crea uguale.
create table if not exists public.impostazioni (
  chiave text primary key,
  valore text not null default '',
  aggiornato_il timestamptz not null default now()
);
alter table public.impostazioni drop constraint if exists impostazioni_chiave_check;
alter table public.impostazioni add constraint impostazioni_chiave_check check (chiave in (
  'data_obiettivo', 'link_video1', 'link_video2', 'invito_whatsapp', 'invito_email_oggetto', 'invito_email'));
alter table public.impostazioni enable row level security;
-- stesse regole dei Contatti: legge chi è nella rete, scrive solo il Board
drop policy if exists impostazioni_leggi on public.impostazioni;
create policy impostazioni_leggi on public.impostazioni for select to authenticated using (public.my_persona_id() is not null);
drop policy if exists impostazioni_scrivi on public.impostazioni;
create policy impostazioni_scrivi on public.impostazioni for all to authenticated using (public.is_board()) with check (public.is_board());
drop policy if exists impostazioni_modifica on public.impostazioni;
drop policy if exists impostazioni_elimina on public.impostazioni;
revoke all on public.impostazioni from anon;
grant select, insert, update, delete on public.impostazioni to authenticated;
