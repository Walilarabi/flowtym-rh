-- =============================================================================
-- 62_pointage_terminals.sql
-- Module Pointage v2 — un QR Code identifie désormais un TERMINAL DE POINTAGE,
-- plus jamais un salarié. Un hôtel peut posséder N terminaux (Réception,
-- Entrée du personnel, Cuisine…). Chaque terminal a un token unique signé.
-- Le salarié est identifié par sa session (auth.uid) au moment du scan.
--
-- Compatible avec l'existant : la table hotel_qr_tokens (héritée du modèle
-- "1 QR par hôtel") reste lisible, et un backfill crée un terminal
-- « Réception » par hôtel disposant déjà d'un token actif.
--
-- Rejouable (IF NOT EXISTS / ON CONFLICT DO NOTHING).
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── 1. Table des terminaux ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.pointage_terminals (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id          uuid        NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  name              text        NOT NULL,
  location          text,
  token             text        NOT NULL UNIQUE
                                DEFAULT ('ftt_' || encode(gen_random_bytes(18), 'hex')),
  is_active         boolean     NOT NULL DEFAULT true,
  created_by        uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  created_by_email  text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deactivated_at    timestamptz,
  CONSTRAINT pointage_terminals_name_not_blank CHECK (btrim(name) <> '')
);

CREATE INDEX IF NOT EXISTS idx_pointage_terminals_hotel
  ON public.pointage_terminals(hotel_id) WHERE is_active;

CREATE INDEX IF NOT EXISTS idx_pointage_terminals_token
  ON public.pointage_terminals(token) WHERE is_active;

COMMENT ON TABLE public.pointage_terminals IS
  'Terminaux de pointage : un QR Code par terminal. Le salarié est authentifié via sa session Flowtym, jamais via le QR.';
COMMENT ON COLUMN public.pointage_terminals.token IS
  'Jeton opaque signé, embarqué dans le QR Code (URL: /salarie?action=clock&token=…).';
COMMENT ON COLUMN public.pointage_terminals.location IS
  'Précision libre affichée dans l''app (« près de la banque d''accueil »…). Optionnel.';

-- ── 2. RLS : accès managers par hôtel ──────────────────────────────────────
ALTER TABLE public.pointage_terminals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pointage_terminals_hotel_isolation ON public.pointage_terminals;
CREATE POLICY pointage_terminals_hotel_isolation ON public.pointage_terminals
  FOR ALL
  USING      (hotel_id IN (SELECT public.pl_my_hotels()))
  WITH CHECK (hotel_id IN (SELECT public.pl_my_hotels()));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.pointage_terminals TO authenticated;

-- ── 3. Trigger d'updated_at ────────────────────────────────────────────────
DROP TRIGGER IF EXISTS pointage_terminals_touch ON public.pointage_terminals;
CREATE TRIGGER pointage_terminals_touch
  BEFORE UPDATE ON public.pointage_terminals
  FOR EACH ROW EXECUTE FUNCTION public.pl_touch_updated_at();

-- ── 4. Référence terminal_id sur staff_clockings ───────────────────────────
ALTER TABLE public.staff_clockings
  ADD COLUMN IF NOT EXISTS terminal_id uuid
    REFERENCES public.pointage_terminals(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_staff_clockings_terminal
  ON public.staff_clockings(terminal_id) WHERE terminal_id IS NOT NULL;

-- ── 5. Backfill : reprendre les hotel_qr_tokens existants ──────────────────
-- Un terminal « Réception » est créé pour chaque hôtel qui possédait déjà
-- un token actif (rétrocompatibilité stricte : le token est conservé).
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'hotel_qr_tokens'
  ) THEN
    INSERT INTO public.pointage_terminals(hotel_id, name, token, is_active, created_at)
    SELECT DISTINCT ON (t.hotel_id)
           t.hotel_id,
           'Réception',
           t.token,
           true,
           t.created_at
      FROM public.hotel_qr_tokens t
     WHERE t.is_active = true
       AND NOT EXISTS (
         SELECT 1 FROM public.pointage_terminals p
          WHERE p.token = t.token
       )
     ORDER BY t.hotel_id, t.created_at DESC
    ON CONFLICT (token) DO NOTHING;
  END IF;
END $$;

-- ── 6. RPC : liste des terminaux (utilisée par l'admin) ────────────────────
-- Facultatif — la RLS permet déjà .from('pointage_terminals').select().
-- On garde une fonction dédiée pour la cohérence avec l'existant.
CREATE OR REPLACE FUNCTION public.list_pointage_terminals(p_hotel uuid)
RETURNS TABLE (
  id uuid, name text, location text, token text,
  is_active boolean, created_at timestamptz, deactivated_at timestamptz
)
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = public
AS $$
  SELECT id, name, location, token, is_active, created_at, deactivated_at
    FROM public.pointage_terminals
   WHERE hotel_id = p_hotel
   ORDER BY is_active DESC, created_at DESC
$$;
GRANT EXECUTE ON FUNCTION public.list_pointage_terminals(uuid) TO authenticated;
