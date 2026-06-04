// Liste des origines autorisées pour l'Edge Function invite-user.
// Ajouter ici les domaines de production si nécessaire.
const ALLOWED_ORIGINS = [
  'http://localhost',
  'http://localhost:3000',
  'http://localhost:5173',
  'http://127.0.0.1',
  'https://flowtym.com',
  'https://app.flowtym.com',
  'https://rh.flowtym.com',
  // Supabase dashboard (pour tests manuels)
  'https://hzrzkvdebaadditvbqis.supabase.co',
];

export function getCorsHeaders(origin: string | null): Record<string, string> {
  const allowed = origin && ALLOWED_ORIGINS.some(o => origin.startsWith(o));
  return {
    'Access-Control-Allow-Origin': allowed ? origin! : ALLOWED_ORIGINS[0],
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  };
}

// Rétrocompatibilité : export de l'objet statique pour les imports existants
// Note: utiliser getCorsHeaders(origin) dans les nouvelles fonctions
export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
