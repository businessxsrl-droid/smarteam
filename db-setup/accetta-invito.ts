// Funzione "accetta-invito" (Supabase Edge Function).
// Chi apre il link d'invito (arrivato su WhatsApp o per email) sceglie email e password:
// la funzione controlla il link, crea l'account (o cambia la password se l'account c'è già)
// e lo collega alla sua scheda. Il link vale una volta sola.
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

async function impronta(tok: string): Promise<string> {
  const h = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(tok));
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return risposta(405, { error: 'Metodo non consentito' });

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false, autoRefreshToken: false } });
  let hash = '';
  let prenotato = false;
  try {
    const { token, email: e, password } = await req.json();
    const email = String(e ?? '').trim().toLowerCase();
    const pw = String(password ?? '');
    if (!token || typeof token !== 'string') return risposta(400, { error: 'Link non valido' });
    if (!/^\S+@\S+\.\S+$/.test(email)) return risposta(400, { error: "Scrivi un'email valida" });
    if (pw.length < 8 || !/[a-zA-Z]/.test(pw) || !/\d/.test(pw)) return risposta(400, { error: 'La password deve avere almeno 8 caratteri, con lettere e numeri' });

    hash = await impronta(token);
    const ora = new Date().toISOString();
    // il link si "prenota" subito: due aperture contemporanee non possono usarlo entrambe
    const { data: inv, error: errInv } = await admin.from('inviti').update({ usato_il: ora })
      .eq('token_hash', hash).is('usato_il', null).gt('scade_il', ora).select('persona_id').maybeSingle();
    if (errInv) throw errInv;
    if (!inv) return risposta(410, { error: 'Il link è scaduto o è già stato usato: chiedi un nuovo invito' });
    prenotato = true;

    const { data: p, error: errP } = await admin.from('persone').select('id, nome, ruolo, auth_user_id').eq('id', inv.persona_id).maybeSingle();
    if (errP) throw errP;
    if (!p || p.ruolo === 'board') throw Object.assign(new Error('Questa scheda non può ricevere un accesso con invito'), { status: 400 });

    // l'email non deve essere già di un'altra persona della rete
    const { data: altri } = await admin.from('persone').select('id').ilike('email', email.replace(/[\\%_]/g, '\\$&')).neq('id', p.id).limit(1);
    if (altri && altri.length) throw Object.assign(new Error("Questa email è già usata da un'altra persona della rete: scrivine un'altra"), { status: 409 });

    let uid: string;
    if (p.auth_user_id) {
      const { error } = await admin.auth.admin.updateUserById(p.auth_user_id, { email, password: pw, email_confirm: true });
      if (error) throw error;
      uid = p.auth_user_id;
    } else {
      const { data, error } = await admin.auth.admin.createUser({ email, password: pw, email_confirm: true, user_metadata: { nome: p.nome } });
      if (error) {
        if (/already|registered|exists/i.test(error.message)) throw Object.assign(new Error("Questa email ha già un accesso SmarTeam: usane un'altra"), { status: 409 });
        throw error;
      }
      uid = data.user.id;
    }
    const { error: errU } = await admin.from('persone').update({ email, auth_user_id: uid }).eq('id', p.id);
    if (errU) throw errU;
    return risposta(200, { email });
  } catch (err) {
    // se qualcosa va storto il link torna valido, così si può riprovare
    if (prenotato && hash) await admin.from('inviti').update({ usato_il: null }).eq('token_hash', hash);
    const e = err as Error & { status?: number };
    const msg = e.message ?? String(err);
    if (/password/i.test(msg) && /weak|short|least/i.test(msg)) return risposta(400, { error: 'Password troppo semplice: usa almeno 8 caratteri con lettere e numeri' });
    return risposta(e.status ?? 500, { error: msg });
  }
});
