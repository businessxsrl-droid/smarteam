-- Il Board. Da eseguire una volta nel SQL Editor DOPO schema.sql.
--
-- Alex, Emanuele e Luca restano nella rete come nomi (i visionari stanno sotto il codice di Alex),
-- ma entrano nell'app con un solo accesso condiviso: la scheda "Board SmarTeam".
-- Prima di eseguire, scrivi al posto di EMAIL-ACCESSO-BOARD l'email dell'account Board
-- che crei in Authentication → Users (la stessa che va in config.js alla voce boardEmail).
--
-- Gli id sono fissi e uguali a quelli della modalità test: così i backup fatti
-- sui dispositivi in prova si ripristinano qui senza perdere chi sta sotto chi.
insert into public.persone (id, ruolo, nome, cognome, email) values
  ('00000000-0000-4000-8000-000000000001', 'board', 'Alex', 'Panciroli', ''),
  ('00000000-0000-4000-8000-000000000002', 'board', 'Emanuele', 'Caputo', ''),
  ('00000000-0000-4000-8000-000000000003', 'board', 'Luca', 'D''Alessandro', ''),
  ('00000000-0000-4000-8000-000000000004', 'board', 'Board', 'SmarTeam', 'EMAIL-ACCESSO-BOARD')
on conflict (id) do nothing;

-- Controllo: devono comparire quattro righe, l'ultima con l'email dell'accesso Board.
select nome, cognome, email from public.persone where ruolo = 'board' order by id;
