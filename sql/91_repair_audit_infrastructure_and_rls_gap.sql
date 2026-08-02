-- ============================================================================
-- sql/91_repair_audit_infrastructure_and_rls_gap.sql
-- Régularisation — infrastructure d'audit, RLS et RPC multi-hôtel manquantes
-- de l'historique de migrations trackées (ADR-012 §9, audit de dérive du
-- 2026-08-02)
--
-- Contexte : un audit exhaustif (comparaison colonne/contrainte/index/
-- trigger/policy/commentaire/type entre production et une branche vierge
-- créée le jour même par pur rejeu des 262 migrations trackées) a prouvé
-- avec certitude — pas une hypothèse — que production a divergé de son
-- propre historique de migrations. La migration `20260511000000_0010_
-- repair_app_schema_history_gap` (déjà trackée) l'a documenté elle-même
-- pour un premier lot d'objets : « créés hors bande, jamais capturés par
-- une migration trackée... son seul effet réel est de combler le trou
-- d'historique... sans viser la parité complète ». Ce fichier complète
-- cette parité pour l'infrastructure d'audit et les policies RLS que 0010
-- n'avait pas couvertes.
--
-- Preuve de la dérive (recherche exhaustive par nom exact sur le texte des
-- 262 migrations, `supabase_migrations.schema_migrations.statements`) :
-- AUCUNE occurrence des noms d'objets ci-dessous, dans aucune migration.
-- Sources : audit_trigger_fn, audit_resolve_actor, audit_rate_prices_change,
-- audit_jsonb_diff, list_user_hotels, rh_grant_hotel_access, set_active_hotel
-- (fonctions) ; idx_audit_entity, idx_audit_hotel_date, idx_audit_logs_actor,
-- idx_audit_logs_entity, idx_audit_logs_hotel_created (index) ;
-- audit_hotel_read, audit_logs_modify, audit_logs_select,
-- user_active_hotel_select_own, user_active_hotel_upsert_own,
-- user_hotels_select_own (policies) ; activation RLS sur audit_logs,
-- user_active_hotel, user_hotels (aucun `ENABLE ROW LEVEL SECURITY` sur ces
-- tables trouvé dans le texte trackée).
--
-- Portée : uniquement les objets liés à `audit_logs`/`user_active_hotel`/
-- `user_hotels` (périmètre Phase 2). `invoices`/`payments`/`hotels`/`rooms`
-- sont traités par sql/92 et sql/93. `get_user_hotel_id()` diverge aussi
-- dans son corps (résolution 3 niveaux via user_active_hotel/user_hotels
-- en production, fallback direct users.hotel_id seul après rejeu pur) —
-- corrigée ici puisqu'elle conditionne le bon fonctionnement des policies
-- ci-dessous.
--
-- Trois états (absent/conforme/divergent) appliqué où une ambiguïté réelle
-- existe (RLS, policies) ; CREATE OR REPLACE (idempotent par construction)
-- pour les fonctions ; CREATE INDEX IF NOT EXISTS pour les index. Aucune
-- perte de données possible : ce fichier n'exécute aucun DROP.
--
-- Pas de BEGIN/COMMIT/ROLLBACK. SQL pur, compatible apply_migration.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- A) Fonctions d'audit — corps exact extrait de production le 2026-08-02 via
--    pg_get_functiondef(oid), reproduites verbatim (CREATE OR REPLACE :
--    idempotent, no-op si déjà identique).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.audit_jsonb_diff(before_row jsonb, after_row jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  k text;
  acc jsonb := '{}'::jsonb;
  ignored text[] := array['updated_at', 'created_at', 'version', 'dispatch_locked_at'];
begin
  if before_row is null or after_row is null then return null; end if;
  for k in select jsonb_object_keys(after_row) loop
    if k = any(ignored) then continue; end if;
    if (before_row->k) is distinct from (after_row->k) then
      acc := acc || jsonb_build_object(k, jsonb_build_array(before_row->k, after_row->k));
    end if;
  end loop;
  return acc;
end;
$function$;

CREATE OR REPLACE FUNCTION public.audit_resolve_actor()
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  _auth_uid uuid;
  _pub_id   uuid;
BEGIN
  BEGIN
    _auth_uid := auth.uid();
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END;

  IF _auth_uid IS NULL THEN
    RETURN NULL;
  END IF;

  BEGIN
    SELECT id INTO _pub_id
    FROM public.users
    WHERE auth_id = _auth_uid
    LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END;

  RETURN _pub_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.audit_trigger_fn()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_entity    text := tg_argv[0];
  v_action    text;
  v_entity_id uuid;
  v_hotel_id  uuid;
  v_payload   jsonb;
  v_before    jsonb;
  v_after     jsonb;
BEGIN
  BEGIN
    IF (tg_op = 'INSERT') THEN
      v_action    := 'created';
      v_after     := to_jsonb(NEW);
      v_entity_id := (NEW).id;
      v_hotel_id  := ((NEW).hotel_id)::uuid;
      v_payload   := jsonb_build_object('after', v_after);
    ELSIF (tg_op = 'UPDATE') THEN
      v_action    := 'updated';
      v_before    := to_jsonb(OLD);
      v_after     := to_jsonb(NEW);
      v_entity_id := (NEW).id;
      v_hotel_id  := ((NEW).hotel_id)::uuid;
      IF public.audit_jsonb_diff(v_before, v_after) = '{}'::jsonb THEN
        RETURN NEW;
      END IF;
      v_payload := jsonb_build_object('diff', public.audit_jsonb_diff(v_before, v_after));
    ELSIF (tg_op = 'DELETE') THEN
      v_action    := 'deleted';
      v_before    := to_jsonb(OLD);
      v_entity_id := (OLD).id;
      v_hotel_id  := ((OLD).hotel_id)::uuid;
      v_payload   := jsonb_build_object('before', v_before);
    END IF;

    IF v_hotel_id IS NULL THEN
      RETURN COALESCE(NEW, OLD);
    END IF;

    INSERT INTO public.audit_logs (hotel_id, actor_user_id, entity, entity_id, action, payload)
    VALUES (v_hotel_id, public.audit_resolve_actor(), v_entity, v_entity_id, v_action, v_payload);

  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'audit_trigger_fn swallowed error on % %: %', tg_table_name, tg_op, SQLERRM;
  END;

  RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE FUNCTION public.audit_rate_prices_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_payload jsonb;
  v_actor uuid;
BEGIN
  BEGIN
    v_actor := public.audit_resolve_actor();

    IF tg_op = 'INSERT' THEN
      v_payload := jsonb_build_object('after', to_jsonb(NEW));
    ELSIF tg_op = 'UPDATE' THEN
      IF NEW.price = OLD.price
         AND NEW.status = OLD.status
         AND NEW.plan_closed = OLD.plan_closed THEN
        RETURN NEW;
      END IF;
      v_payload := jsonb_build_object(
        'before', jsonb_build_object('price', OLD.price, 'status', OLD.status),
        'after',  jsonb_build_object('price', NEW.price, 'status', NEW.status),
        'source', NEW.source
      );
    ELSIF tg_op = 'DELETE' THEN
      v_payload := jsonb_build_object('before', to_jsonb(OLD));
    END IF;

    INSERT INTO public.audit_logs (hotel_id, actor_user_id, entity, entity_id, action, payload)
    VALUES (
      COALESCE(NEW.hotel_id, OLD.hotel_id),
      v_actor,
      'rate_price',
      COALESCE(NEW.id, OLD.id),
      tg_op,
      v_payload
    );

  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'audit_rate_prices_change swallowed: %', SQLERRM;
  END;
  RETURN COALESCE(NEW, OLD);
END;
$function$;

-- ----------------------------------------------------------------------------
-- B) get_user_hotel_id() — corps corrigé (résolution 3 niveaux : hôtel actif
--    user_active_hotel avec vérification d'accès via user_hotels, sinon
--    hôtel par défaut user_hotels.is_default, sinon repli legacy
--    users.hotel_id). Corps exact extrait de production. Remplace le corps
--    à une seule requête `SELECT hotel_id FROM users WHERE auth_id=auth.uid()`
--    issu du rejeu pur, qui ignore complètement user_active_hotel/user_hotels
--    — divergence fonctionnelle réelle, pas cosmétique.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_user_hotel_id()
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_auth_uid    uuid := auth.uid();
  v_user_id     uuid;
  v_hotel_id    uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT id INTO v_user_id
  FROM public.users
  WHERE auth_id = v_auth_uid
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT uah.hotel_id INTO v_hotel_id
  FROM public.user_active_hotel uah
  WHERE uah.user_id = v_user_id
    AND EXISTS (
      SELECT 1 FROM public.user_hotels uh
      WHERE uh.user_id = v_user_id AND uh.hotel_id = uah.hotel_id
    )
  LIMIT 1;

  IF v_hotel_id IS NOT NULL THEN
    RETURN v_hotel_id;
  END IF;

  SELECT uh.hotel_id INTO v_hotel_id
  FROM public.user_hotels uh
  WHERE uh.user_id = v_user_id AND uh.is_default = true
  LIMIT 1;

  IF v_hotel_id IS NOT NULL THEN
    RETURN v_hotel_id;
  END IF;

  SELECT u.hotel_id INTO v_hotel_id
  FROM public.users u
  WHERE u.id = v_user_id
  LIMIT 1;

  RETURN v_hotel_id;
END;
$function$;

-- Le rejeu pur accorde EXECUTE à PUBLIC (jamais révoqué) ; production ne
-- l'accorde qu'à authenticated/postgres/service_role. Alignement.
REVOKE ALL ON FUNCTION public.get_user_hotel_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_user_hotel_id() TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- C) RPC multi-hôtel manquantes — corps exacts extraits de production.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_user_hotels()
 RETURNS TABLE(hotel_id uuid, name text, city text, country text, role admin_user_role, is_default boolean, is_active boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_user_id    uuid;
  v_active_id  uuid;
BEGIN
  SELECT id INTO v_user_id
  FROM public.users
  WHERE auth_id = auth.uid()
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  SELECT uah.hotel_id INTO v_active_id
  FROM public.user_active_hotel uah
  WHERE uah.user_id = v_user_id
  LIMIT 1;

  IF v_active_id IS NULL THEN
    SELECT uh.hotel_id INTO v_active_id
    FROM public.user_hotels uh
    WHERE uh.user_id = v_user_id AND uh.is_default = true
    LIMIT 1;
  END IF;

  RETURN QUERY
  SELECT
    uh.hotel_id,
    h.name,
    h.city,
    h.country,
    uh.role,
    uh.is_default,
    (uh.hotel_id = v_active_id) AS is_active
  FROM public.user_hotels uh
  JOIN public.hotels h ON h.id = uh.hotel_id
  WHERE uh.user_id = v_user_id
  ORDER BY uh.is_default DESC, h.name ASC;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_user_hotels() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.list_user_hotels() TO authenticated;

CREATE OR REPLACE FUNCTION public.set_active_hotel(p_hotel_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_user_id     uuid;
  v_has_access  boolean;
BEGIN
  SELECT id INTO v_user_id
  FROM public.users
  WHERE auth_id = auth.uid()
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not authenticated' USING ERRCODE = '42501';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.user_hotels
    WHERE user_id = v_user_id AND hotel_id = p_hotel_id
  ) INTO v_has_access;

  IF NOT v_has_access THEN
    RAISE EXCEPTION 'User does not have access to hotel %', p_hotel_id
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.user_active_hotel (user_id, hotel_id, switched_at)
  VALUES (v_user_id, p_hotel_id, now())
  ON CONFLICT (user_id) DO UPDATE
    SET hotel_id = EXCLUDED.hotel_id,
        switched_at = EXCLUDED.switched_at;

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.set_active_hotel(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.set_active_hotel(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.rh_grant_hotel_access(p_auth_id uuid, p_email text, p_full_name text, p_hotel_id uuid, p_role admin_user_role)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid;
BEGIN
  INSERT INTO public.users (auth_id, email, full_name, hotel_id, role)
  VALUES (p_auth_id, p_email, COALESCE(NULLIF(p_full_name,''), p_email), p_hotel_id, p_role)
  ON CONFLICT (auth_id) DO UPDATE
    SET email     = EXCLUDED.email,
        full_name = COALESCE(NULLIF(EXCLUDED.full_name,''), EXCLUDED.email)
  RETURNING id INTO v_user_id;

  INSERT INTO public.user_hotels (user_id, hotel_id, role)
  VALUES (v_user_id, p_hotel_id, p_role)
  ON CONFLICT (user_id, hotel_id) DO UPDATE
    SET role = EXCLUDED.role;

  RETURN v_user_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.rh_grant_hotel_access(uuid, text, text, uuid, admin_user_role) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rh_grant_hotel_access(uuid, text, text, uuid, admin_user_role) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- D) audit_logs — trois-états : index manquants, RLS, policies, commentaire.
-- ----------------------------------------------------------------------------
DO $repair_audit_logs$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='audit_logs' AND relkind='r') THEN
    RAISE EXCEPTION '[audit_logs] table absente — hors périmètre attendu de cette migration, arrêt.';
  END IF;

  CREATE INDEX IF NOT EXISTS idx_audit_entity ON public.audit_logs USING btree (entity, entity_id);
  CREATE INDEX IF NOT EXISTS idx_audit_hotel_date ON public.audit_logs USING btree (hotel_id, created_at DESC);
  CREATE INDEX IF NOT EXISTS idx_audit_logs_actor ON public.audit_logs USING btree (hotel_id, actor_user_id, created_at DESC);
  CREATE INDEX IF NOT EXISTS idx_audit_logs_entity ON public.audit_logs USING btree (hotel_id, entity, created_at DESC);
  CREATE INDEX IF NOT EXISTS idx_audit_logs_hotel_created ON public.audit_logs USING btree (hotel_id, created_at DESC);

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.audit_logs'::regclass) THEN
    EXECUTE 'ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='audit_logs' AND policyname='audit_hotel_read') THEN
    EXECUTE $pol$CREATE POLICY audit_hotel_read ON public.audit_logs FOR SELECT USING (hotel_id = get_user_hotel_id())$pol$;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='audit_logs' AND policyname='audit_logs_modify') THEN
    EXECUTE $pol$CREATE POLICY audit_logs_modify ON public.audit_logs FOR ALL TO authenticated USING (hotel_id = get_user_hotel_id()) WITH CHECK (hotel_id = get_user_hotel_id())$pol$;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='audit_logs' AND policyname='audit_logs_select') THEN
    EXECUTE $pol$CREATE POLICY audit_logs_select ON public.audit_logs FOR SELECT TO authenticated USING (hotel_id = get_user_hotel_id())$pol$;
  END IF;

  IF col_description('public.audit_logs'::regclass::oid, (SELECT ordinal_position FROM information_schema.columns WHERE table_schema='public' AND table_name='audit_logs' AND column_name='actor_label')) IS NULL THEN
    EXECUTE $cmt$COMMENT ON COLUMN public.audit_logs.actor_label IS 'Étiquette humainement lisible de l''acteur (nom/email) capturée au moment de l''écriture, indépendante de toute résolution ultérieure de l''utilisateur.'$cmt$;
  END IF;

  RAISE NOTICE '[audit_logs] régularisation terminée (index, RLS, policies, commentaire).';
END
$repair_audit_logs$;

-- ----------------------------------------------------------------------------
-- E) user_active_hotel — RLS + policies + commentaire.
-- ----------------------------------------------------------------------------
DO $repair_user_active_hotel$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='user_active_hotel' AND relkind='r') THEN
    RAISE EXCEPTION '[user_active_hotel] table absente — hors périmètre attendu de cette migration, arrêt.';
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.user_active_hotel'::regclass) THEN
    EXECUTE 'ALTER TABLE public.user_active_hotel ENABLE ROW LEVEL SECURITY';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_active_hotel' AND policyname='user_active_hotel_select_own') THEN
    EXECUTE $pol$CREATE POLICY user_active_hotel_select_own ON public.user_active_hotel FOR SELECT TO authenticated USING (user_id = (SELECT users.id FROM users WHERE users.auth_id = auth.uid()))$pol$;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_active_hotel' AND policyname='user_active_hotel_upsert_own') THEN
    EXECUTE $pol$CREATE POLICY user_active_hotel_upsert_own ON public.user_active_hotel FOR ALL TO authenticated USING (user_id = (SELECT users.id FROM users WHERE users.auth_id = auth.uid())) WITH CHECK (user_id = (SELECT users.id FROM users WHERE users.auth_id = auth.uid()))$pol$;
  END IF;

  IF obj_description('public.user_active_hotel'::regclass) IS NULL THEN
    EXECUTE $cmt$COMMENT ON TABLE public.user_active_hotel IS 'Stocke l''hôtel actif (sélectionné par le sélecteur UI) pour chaque utilisateur multi-hôtel.'$cmt$;
  END IF;

  RAISE NOTICE '[user_active_hotel] régularisation terminée (RLS, policies, commentaire).';
END
$repair_user_active_hotel$;

-- ----------------------------------------------------------------------------
-- F) user_hotels — index manquants + RLS + policy + commentaire.
-- ----------------------------------------------------------------------------
DO $repair_user_hotels$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='user_hotels' AND relkind='r') THEN
    RAISE EXCEPTION '[user_hotels] table absente — hors périmètre attendu de cette migration, arrêt.';
  END IF;

  CREATE INDEX IF NOT EXISTS user_hotels_hotel_id_idx ON public.user_hotels USING btree (hotel_id);
  -- NB : user_hotels_one_default_idx (production ET rejeu) et
  -- user_hotels_one_default_per_user (production uniquement) sont deux index
  -- UNIQUE fonctionnellement redondants (même prédicat sémantique, noms
  -- différents — signe d'une double tentative hors bande de garantir la même
  -- contrainte). On les fait coexister ici pour une parité stricte avec
  -- production sans en supprimer aucun (aucune preuve de laquelle des deux
  -- est réellement utilisée par du code) ; nettoyage du doublon laissé à une
  -- PR dédiée avec preuve d'innocuité.
  CREATE UNIQUE INDEX IF NOT EXISTS user_hotels_one_default_per_user ON public.user_hotels USING btree (user_id) WHERE (is_default = true);

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.user_hotels'::regclass) THEN
    EXECUTE 'ALTER TABLE public.user_hotels ENABLE ROW LEVEL SECURITY';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_hotels' AND policyname='user_hotels_select_own') THEN
    EXECUTE $pol$CREATE POLICY user_hotels_select_own ON public.user_hotels FOR SELECT TO authenticated USING (user_id = (SELECT users.id FROM users WHERE users.auth_id = auth.uid()))$pol$;
  END IF;

  IF obj_description('public.user_hotels'::regclass) IS NULL THEN
    EXECUTE $cmt$COMMENT ON TABLE public.user_hotels IS 'Multi-tenant access: une row par (user, hotel) — un utilisateur peut avoir accès à plusieurs hôtels avec un rôle par hôtel.'$cmt$;
  END IF;

  RAISE NOTICE '[user_hotels] régularisation terminée (index, RLS, policy, commentaire).';
END
$repair_user_hotels$;
