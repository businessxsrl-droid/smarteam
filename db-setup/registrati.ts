// Funzione "registrati" (Supabase Edge Function).
// Chi apre il link referral di un networker ("#/r/CODICE") scrive nome, cognome, cellulare,
// email e password: la funzione crea l'account e la scheda subito sotto chi lo ha invitato
// (livello e posto li sceglie il database con registra_da_link).
// Non serve nessun servizio email: il link lo manda chi invita.
// Da pubblicare con "Verify JWT" spento: chi la chiama non ha ancora un account.
import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function risposta(status: number, corpo: Record<string, unknown>) {
  return new Response(JSON.stringify(corpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

const testo = (v: unknown, max = 80) => String(v ?? '').trim().slice(0, max);

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return risposta(405, { error: 'Metodo non consentito' });

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false, autoRefreshToken: false } });
  let uid: string | null = null;
  try {
    const b = await req.json();
    const codice = testo(b.codice, 16).toLowerCase();
    const nome = testo(b.nome);
    const cognome = testo(b.cognome);
    const telefono = testo(b.telefono, 30);
    const email = testo(b.email, 120).toLowerCase();
    const pw = String(b.password ?? '');
    if (!/^[a-z2-9]{6,16}$/.test(codice)) return risposta(400, { error: 'Link non valido' });
    if (!nome || !cognome) return risposta(400, { error: 'Scrivi nome e cognome' });
    if (telefono.replace(/\D/g, '').length < 9) return risposta(400, { error: 'Scrivi il numero di cellulare' });
    if (!/^\S+@\S+\.\S+$/.test(email)) return risposta(400, { error: "Scrivi un'email valida" });
    if (pw.length < 8 || pw.length > 72 || !/[a-zA-Z]/.test(pw) || !/\d/.test(pw)) return risposta(400, { error: 'La password deve avere almeno 8 caratteri, con lettere e numeri' });

    // il link deve esistere prima di creare qualsiasi account
    const { data: info, error: errInfo } = await admin.rpc('leggi_referral', { cod: codice });
    if (errInfo) throw errInfo;
    if (!info) return risposta(404, { error: 'Questo link non è valido: chiedi a chi te lo ha mandato di rimandartelo' });

    const { data: gia } = await admin.from('persone').select('id').ilike('email', email.replace(/[\\%_]/g, '\\$&')).limit(1);
    if (gia && gia.length) return risposta(409, { error: 'Questa email è già nella rete: se hai già un accesso entra con quella' });

    const { data, error } = await admin.auth.admin.createUser({ email, password: pw, email_confirm: true, user_metadata: { nome } });
    if (error) {
      if (/already|registered|exists/i.test(error.message)) return risposta(409, { error: "Questa email ha già un accesso SmarTeam: usane un'altra o entra con quella" });
      throw error;
    }
    uid = data.user.id;

    const { error: errReg } = await admin.rpc('registra_da_link', { cod: codice, uid, p_nome: nome, p_cognome: cognome, p_telefono: telefono, p_email: email });
    if (errReg) throw Object.assign(new Error(errReg.message), { status: 409 });
    return risposta(200, { email });
  } catch (err) {
    // se la scheda non è stata creata, l'account appena fatto si toglie: si può riprovare
    if (uid) await admin.auth.admin.deleteUser(uid).catch(() => {});
    const e = err as Error & { status?: number };
    const msg = e.message ?? String(err);
    if (/password/i.test(msg) && /weak|short|least/i.test(msg)) return risposta(400, { error: 'Password troppo semplice: usa almeno 8 caratteri con lettere e numeri' });
    return risposta(e.status ?? 500, { error: msg });
  }
});
