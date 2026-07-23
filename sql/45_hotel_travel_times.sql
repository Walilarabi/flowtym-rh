-- 45_hotel_travel_times.sql
-- Contrat des temps de trajet inter-hôtels (fournis, aucune API carto).
-- Consommé par la couche d'adaptation du simulateur (lecture seule).
-- Appliqué via migrations MCP : hotel_travel_times + group_travel_times +
-- hotel_travel_times_harden. Ce fichier fait foi pour le dépôt.

CREATE TABLE IF NOT EXISTS public.hotel_travel_times (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_hotel_id     uuid NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  to_hotel_id       uuid NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  duration_min      int  NOT NULL CHECK (duration_min >= 0),
  safety_margin_min int  NOT NULL DEFAULT 10 CHECK (safety_margin_min >= 0),
  transport_type    text,
  valid_from        date,
  valid_to          date,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (from_hotel_id <> to_hotel_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_travel_pair ON public.hotel_travel_times(from_hotel_id, to_hotel_id, coalesce(valid_from,'0001-01-01'::date));

ALTER TABLE public.hotel_travel_times ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS htt_manager ON public.hotel_travel_times;
CREATE POLICY htt_manager ON public.hotel_travel_times FOR ALL
  USING (from_hotel_id IN (SELECT public.pl_my_hotels()) AND to_hotel_id IN (SELECT public.pl_my_hotels()))
  WITH CHECK (from_hotel_id IN (SELECT public.pl_my_hotels()) AND to_hotel_id IN (SELECT public.pl_my_hotels()));

-- Durcissement : écritures clientes révoquées (config via RPC ultérieure).
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.hotel_travel_times FROM authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, SELECT ON public.hotel_travel_times FROM anon;

CREATE OR REPLACE FUNCTION public.group_travel_times()
 RETURNS TABLE(from_hotel_id uuid, to_hotel_id uuid, duration_min int, safety_margin_min int, transport_type text, valid_from date, valid_to date)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT from_hotel_id, to_hotel_id, duration_min, safety_margin_min, transport_type, valid_from, valid_to
  FROM hotel_travel_times
  WHERE from_hotel_id IN (SELECT public.pl_my_hotels()) AND to_hotel_id IN (SELECT public.pl_my_hotels());
$$;
REVOKE ALL ON FUNCTION public.group_travel_times() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.group_travel_times() TO authenticated;
