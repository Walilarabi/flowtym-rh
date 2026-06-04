-- =============================================================================
-- 25_staff_coverage_rules.sql
-- Règles de couverture des postes + données prévisionnelles d'occupation.
--
-- Architecture extensible en deux tables :
--   - staff_coverage_rules   : les règles (formule configurable par hôtel)
--   - hotel_occupancy_forecast : les données d'entrée des formules dynamiques
--
-- La formule de calcul du minimum requis est :
--   formula_type = 'static'          → min = min_staff_base
--   formula_type = 'occupancy_based' → min = min_staff_base
--                                          + CEIL(occupied_rooms × per_room_ratio)
--   formula_type = 'workload_based'  → min = min_staff_base
--                                          + CEIL(arrivals       × per_arrival)
--                                          + CEIL(departures     × per_departure)
--                                          + CEIL(rooms_deep_clean × per_deep_clean)
--
-- Aujourd'hui : formula_type = 'static', formula_params = '{}'.
-- Demain sans migration : renseigner hotel_occupancy_forecast et changer formula_type.
--
-- Rejouable : IF NOT EXISTS / CREATE OR REPLACE / ON CONFLICT DO NOTHING.
-- =============================================================================

-- ── 1. Règles de couverture ───────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.staff_coverage_rules (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id        uuid        NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,

  -- Cible de la règle
  department      text        NOT NULL,   -- 'reception' | 'etages' | 'technique' | ...
  shift_label     text        NOT NULL,   -- 'M' | 'S' | 'N' | 'J' | 'PD' | 'C'
  day_of_week     integer,               -- NULL=tous, 0=lundi … 6=dimanche
  role_required   text,                  -- optionnel : rôle spécifique exigé

  -- Plancher absolu (toujours respecté, indépendamment de la formule)
  min_staff_base  integer     NOT NULL DEFAULT 1 CHECK (min_staff_base >= 0),

  -- Formule dynamique (extensible sans migration)
  formula_type    text        NOT NULL DEFAULT 'static'
                              CHECK (formula_type IN ('static','occupancy_based','workload_based')),
  formula_params  jsonb       NOT NULL DEFAULT '{}',
  -- Exemples formula_params :
  --   static          : {}
  --   occupancy_based : { "per_room_ratio": 0.05 }
  --                     → min = base + CEIL(occupied_rooms × 0.05)
  --   workload_based  : { "per_arrival": 0.3, "per_departure": 0.2, "per_deep_clean": 0.5 }
  --                     → min = base + CEIL(arr×0.3 + dep×0.2 + clean×0.5)

  active          boolean     NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  UNIQUE (hotel_id, department, shift_label, day_of_week)
);

CREATE INDEX IF NOT EXISTS idx_coverage_rules_hotel
  ON public.staff_coverage_rules(hotel_id)
  WHERE active = true;

ALTER TABLE public.staff_coverage_rules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "coverage_rules_hotel" ON public.staff_coverage_rules;
CREATE POLICY "coverage_rules_hotel" ON public.staff_coverage_rules
  FOR ALL USING   (hotel_id IN (SELECT public.pl_my_hotels()))
  WITH CHECK      (hotel_id IN (SELECT public.pl_my_hotels()));

COMMENT ON TABLE public.staff_coverage_rules IS
  'Règles de couverture minimale par poste et par shift. Formule configurable : static (fixe), occupancy_based (taux occupation), workload_based (arrivées/départs/chambres à blanc).';
COMMENT ON COLUMN public.staff_coverage_rules.formula_params IS
  'Paramètres JSONB de la formule. static={}, occupancy_based={"per_room_ratio":0.05}, workload_based={"per_arrival":0.3,"per_departure":0.2,"per_deep_clean":0.5}';

-- ── 2. Données prévisionnelles d'occupation ───────────────────────────────────
-- Données d'entrée pour les formules occupancy_based et workload_based.
-- Renseignées manuellement aujourd'hui, synchronisées PMS demain (source='pms_sync').

CREATE TABLE IF NOT EXISTS public.hotel_occupancy_forecast (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id            uuid        NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  date                date        NOT NULL,

  -- Données nuit
  total_rooms         integer     NOT NULL DEFAULT 0 CHECK (total_rooms >= 0),
  occupied_rooms      integer     NOT NULL DEFAULT 0 CHECK (occupied_rooms >= 0),
  occupancy_rate      numeric(5,4) GENERATED ALWAYS AS (
                        CASE WHEN total_rooms > 0
                          THEN ROUND(occupied_rooms::numeric / total_rooms, 4)
                          ELSE 0
                        END
                      ) STORED,

  -- Flux du jour
  arrivals            integer     NOT NULL DEFAULT 0 CHECK (arrivals >= 0),
  departures          integer     NOT NULL DEFAULT 0 CHECK (departures >= 0),
  rooms_deep_clean    integer     NOT NULL DEFAULT 0 CHECK (rooms_deep_clean >= 0),
  -- "chambres à blanc" : remise à neuf complète, charge de travail 2× supérieure

  -- Métadonnées
  source              text        NOT NULL DEFAULT 'manual'
                                  CHECK (source IN ('manual','pms_sync','estimate')),
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),

  UNIQUE (hotel_id, date)
);

CREATE INDEX IF NOT EXISTS idx_occupancy_hotel_date
  ON public.hotel_occupancy_forecast(hotel_id, date);

ALTER TABLE public.hotel_occupancy_forecast ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "occupancy_forecast_hotel" ON public.hotel_occupancy_forecast;
CREATE POLICY "occupancy_forecast_hotel" ON public.hotel_occupancy_forecast
  FOR ALL USING   (hotel_id IN (SELECT public.pl_my_hotels()))
  WITH CHECK      (hotel_id IN (SELECT public.pl_my_hotels()));

COMMENT ON TABLE public.hotel_occupancy_forecast IS
  'Données prévisionnelles d'occupation par hôtel et par jour. Entrée des formules de couverture dynamiques. source=manual (saisie directe) | pms_sync (import PMS) | estimate (projection).';
COMMENT ON COLUMN public.hotel_occupancy_forecast.rooms_deep_clean IS
  'Chambres à blanc : remise à neuf complète, charge de travail des étages estimée à 2× une chambre standard.';
COMMENT ON COLUMN public.hotel_occupancy_forecast.occupancy_rate IS
  'Taux d''occupation calculé (occupied/total). Colonne GENERATED STORED — mise à jour automatique.';

-- ── 3. Trigger updated_at ─────────────────────────────────────────────────────

CREATE TRIGGER trg_coverage_rules_touch
  BEFORE UPDATE ON public.staff_coverage_rules
  FOR EACH ROW EXECUTE FUNCTION public.pl_touch_updated_at();

CREATE TRIGGER trg_occupancy_forecast_touch
  BEFORE UPDATE ON public.hotel_occupancy_forecast
  FOR EACH ROW EXECUTE FUNCTION public.pl_touch_updated_at();
