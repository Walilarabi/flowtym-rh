import { createClient } from 'npm:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY') ?? '';

const ALLOWED = [
  'http://localhost','http://localhost:3000','http://localhost:5173',
  'https://flowtym.com','https://app.flowtym.com','https://rh.flowtym.com',
  'https://hzrzkvdebaadditvbqis.supabase.co',
  'https://flowtym-rh-git-main-walis-projects-e22749ce.vercel.app',
  'https://flowtym-rh.vercel.app',
];
const cors = (o: string|null) => {
  const allowed = o && (
    ALLOWED.some(a => o.startsWith(a)) ||
    /^https:\/\/flowtym-[a-z0-9]+-walis-projects-e22749ce\.vercel\.app$/.test(o)
  ) ? o : ALLOWED[0];
  return {
    'Access-Control-Allow-Origin': allowed,
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };
};

Deno.serve(async (req) => {
  const origin = req.headers.get('origin');
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors(origin) });

  try {
    // Vérification immédiate de la clé — retourne un code métier sans détail technique
    if (!ANTHROPIC_API_KEY) {
      return new Response(
        JSON.stringify({ error: 'NOT_CONFIGURED' }),
        { status: 503, headers: { ...cors(origin), 'Content-Type': 'application/json' } }
      );
    }

    const authHeader = req.headers.get('authorization') ?? '';
    const token = authHeader.replace('Bearer ', '');
    if (!token) {
      return new Response(JSON.stringify({ error: 'Non autorisé' }), { status: 401, headers: cors(origin) });
    }

    const body = await req.json();
    const { hotel_id, messages, context } = body;
    if (!hotel_id || !Array.isArray(messages)) {
      return new Response(JSON.stringify({ error: 'Paramètres manquants' }), { status: 400, headers: cors(origin) });
    }

    // Chargement des données RH via service_role — jamais exposé au frontend
    const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
    const [staffRes, absRes, trainingRes, medicalRes] = await Promise.all([
      sb.from('employees')
        .select('id,first_name,last_name,department,role,contract_type,active,hire_date,departure_date')
        .eq('hotel_id', hotel_id),
      sb.from('absence_requests')
        .select('id,employee_id,start_date,end_date,status')
        .eq('hotel_id', hotel_id)
        .gte('start_date', new Date(Date.now() - 90 * 864e5).toISOString().slice(0, 10)),
      sb.from('employee_trainings')
        .select('id,employee_id,training_name,expiry_date')
        .eq('hotel_id', hotel_id),
      sb.from('medical_visits')
        .select('id,employee_id,visit_date,next_visit_date')
        .eq('hotel_id', hotel_id),
    ]);

    const employees = staffRes.data ?? [];
    const active = employees.filter((e: any) => e.active !== false);
    const absences = absRes.data ?? [];
    const trainings = trainingRes.data ?? [];
    const medicalVisits = medicalRes.data ?? [];
    const today = new Date().toISOString().slice(0, 10);

    const systemPrompt = `Tu es l'Assistant RH IA de Flowtym, un logiciel RH pour hôtels. Tu aides les gestionnaires RH avec une expertise professionnelle, concise et bienveillante.
Tu ne dois JAMAIS divulguer de données personnelles sensibles (n° SS, mots de passe, données bancaires). Si on te le demande, refuse poliment.
Tu travailles uniquement sur les données de l'hôtel fourni. Ne mentionne jamais d'autres hôtels.

DONNÉES RH — ${context?.hotel_name ?? 'Hôtel'} (au ${today}) :
- Effectif actif : ${active.length} collaborateurs
- Services : ${(context?.departments ?? []).map((d: any) => `${d.name} (${d.count})`).join(', ') || 'N/A'}
- Contrats : ${JSON.stringify(context?.contracts ?? {})}
- Absences (90 derniers jours) : ${absences.length} demandes (${absences.filter((a: any) => a.status === 'pending').length} en attente, ${absences.filter((a: any) => a.status === 'approved').length} approuvées)
- Formations : ${trainings.length} enregistrées (${trainings.filter((t: any) => t.expiry_date && t.expiry_date < today).length} expirées)
- Visites médicales : ${medicalVisits.length} (${medicalVisits.filter((v: any) => v.next_visit_date && v.next_visit_date < today).length} en retard, ${active.filter((e: any) => !medicalVisits.find((v: any) => v.employee_id === e.id)).length} sans visite)

Réponds toujours en français. Sois précis, professionnel et orienté action.`;

    const anthropicResp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': ANTHROPIC_API_KEY,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 1024,
        system: systemPrompt,
        messages: messages.map((m: any) => ({ role: m.role, content: m.content })),
      }),
    });

    if (!anthropicResp.ok) {
      // Log le détail côté serveur, ne le renvoie pas au client
      const errText = await anthropicResp.text();
      console.error('Anthropic API error:', anthropicResp.status, errText);
      if (anthropicResp.status === 401) {
        return new Response(JSON.stringify({ error: 'NOT_CONFIGURED' }), { status: 503, headers: cors(origin) });
      }
      throw new Error('Erreur IA temporaire');
    }

    const aiData = await anthropicResp.json();
    const reply = aiData.content?.[0]?.text ?? "Je n'ai pas pu générer de réponse.";

    return new Response(JSON.stringify({ reply }), {
      status: 200,
      headers: { ...cors(origin), 'Content-Type': 'application/json' },
    });

  } catch (e: any) {
    console.error('rh-assistant error:', e);
    // Ne jamais renvoyer le message d'erreur brut au client
    return new Response(
      JSON.stringify({ error: 'SERVICE_ERROR' }),
      { status: 500, headers: { ...cors(origin), 'Content-Type': 'application/json' } }
    );
  }
});
