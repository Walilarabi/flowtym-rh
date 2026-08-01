-- 90_repair_app_schema_history_gap.sql
-- ============================================================================
-- Répare un trou dans l'historique de migrations tracké par Supabase.
--
-- Constat (preuve : requêtes en lecture seule sur supabase_migrations.schema_
-- migrations en production) : la migration 00001_initial_schema (le squash/
-- baseline censé représenter tout ce qui précède l'historique tracké) ne
-- contient AUCUNE création du schéma `app` ni de public.provision_user_for_hotel.
-- Or la migration suivante, 20260511141513_0011_security_hardening, contient
-- un bloc de sanity-check qui RAISE EXCEPTION si ces objets n'existent pas déjà.
--
-- Conséquence : le rejeu automatique de branche Supabase (Branching 2.0, qui
-- rejoue le texte stocké des migrations sur une base vierge — pas un dump de
-- la production) échoue toujours et déterministiquement à 0011.
--
-- Ces objets existent réellement en production aujourd'hui (créés hors bande,
-- jamais capturés par une migration trackée). Cette migration ne change RIEN
-- fonctionnellement en production : chaque statement est idempotent
-- (IF NOT EXISTS / OR REPLACE / DROP...IF EXISTS + CREATE). Son seul effet
-- réel est de combler le trou d'historique pour que les FUTURS rejeux de
-- branche recréent ces objets avant d'atteindre 0011, au lieu de les supposer
-- déjà présents.
--
-- IMPORTANT : cette migration doit être enregistrée dans
-- supabase_migrations.schema_migrations avec une version explicitement
-- positionnée AVANT 20260511141513 (0011) et APRÈS 00001 — sinon l'insertion
-- ne corrige rien pour le rejeu de branche. Voir procédure d'application
-- associée (insertion d'historique contrôlée, pas un apply_migration standard
-- qui timestamperait "maintenant").
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Schéma + table de suivi applicatif (utilisée par app.* et par 0011)
-- ----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS app;

CREATE TABLE IF NOT EXISTS app.schema_migrations (
  version    text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE app.schema_migrations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS service_role_only_schema_migrations ON app.schema_migrations;
CREATE POLICY service_role_only_schema_migrations ON app.schema_migrations
  FOR ALL
  TO authenticated, anon
  USING (false)
  WITH CHECK (false);

-- ----------------------------------------------------------------------------
-- 2. Fonctions app.* (les 12 réellement présentes en production, pas
--    seulement les 5 citées par la sanity-check de 0011)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'app', 'public', 'pg_temp'
AS $function$
begin new.updated_at := now(); return new; end;
$function$;

CREATE OR REPLACE FUNCTION app.audit_logs_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'app', 'public', 'pg_temp'
AS $function$
begin raise exception 'audit_logs are immutable'; end;
$function$;

CREATE OR REPLACE FUNCTION app.dispute_messages_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'app', 'public', 'pg_temp'
AS $function$
begin raise exception 'ota_dispute_messages are immutable'; end;
$function$;

CREATE OR REPLACE FUNCTION app.bump_reservation_version()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'app', 'public', 'pg_temp'
AS $function$
begin
  if (new.version is null) or (new.version = old.version) then
    new.version := old.version + 1;
  end if;
  new.updated_at := now();
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION app.rv_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'app', 'public', 'pg_temp'
AS $function$
begin raise exception 'reservation_validations are immutable'; end;
$function$;

CREATE OR REPLACE FUNCTION app.set_updated_at_flowday()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$function$;

CREATE OR REPLACE FUNCTION app.set_updated_at_sas()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$function$;

CREATE OR REPLACE FUNCTION app.fec_exports_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
BEGIN RAISE EXCEPTION 'fec_exports are immutable — create a new export instead'; END;
$function$;

CREATE OR REPLACE FUNCTION app.resolve_actor_user_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION app.log_reservation_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  _actor uuid;
  _payload jsonb;
BEGIN
  _actor := app.resolve_actor_user_id(); -- NULL-safe, jamais d'erreur FK

  IF TG_OP = 'DELETE' THEN
    _payload := to_jsonb(OLD);
    INSERT INTO public.audit_logs (hotel_id, actor_user_id, entity, entity_id, action, payload)
    VALUES (OLD.hotel_id, _actor, 'reservation', OLD.id, 'DELETE', _payload);
    RETURN OLD;
  END IF;

  _payload := to_jsonb(NEW);
  -- Supprimer les champs inutiles pour alléger le payload
  _payload := _payload - 'hotel_id' - 'version' - 'updated_at';

  INSERT INTO public.audit_logs (hotel_id, actor_user_id, entity, entity_id, action, payload)
  VALUES (
    NEW.hotel_id,
    _actor,
    'reservation',
    NEW.id,
    TG_OP,
    _payload
  )
  ON CONFLICT DO NOTHING;  -- idempotence

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION app.audit_reservations()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_hotel_id  uuid;
  v_entity_id uuid;
  v_action    text;
  v_payload   jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_hotel_id  := NEW.hotel_id;
    v_entity_id := NEW.id;
    v_action    := 'INSERT';
    v_payload   := to_jsonb(NEW);
  ELSIF TG_OP = 'UPDATE' THEN
    v_hotel_id  := NEW.hotel_id;
    v_entity_id := NEW.id;
    v_action := CASE
      WHEN OLD.status IS DISTINCT FROM NEW.status THEN
        'STATUS_' || upper(coalesce(NEW.status, 'UNKNOWN'))
      ELSE 'UPDATE'
    END;
    v_payload := jsonb_build_object(
      'before', jsonb_build_object(
        'status', OLD.status, 'total_amount', OLD.total_amount,
        'paid_amount', OLD.paid_amount, 'room_id', OLD.room_id,
        'check_in', OLD.check_in, 'check_out', OLD.check_out
      ),
      'after', jsonb_build_object(
        'status', NEW.status, 'total_amount', NEW.total_amount,
        'paid_amount', NEW.paid_amount, 'room_id', NEW.room_id,
        'check_in', NEW.check_in, 'check_out', NEW.check_out
      )
    );
    NEW.version := OLD.version + 1;
  ELSIF TG_OP = 'DELETE' THEN
    v_hotel_id  := OLD.hotel_id;
    v_entity_id := OLD.id;
    v_action    := 'DELETE';
    v_payload   := to_jsonb(OLD);
  END IF;

  IF v_hotel_id IS NOT NULL THEN
    INSERT INTO public.audit_logs (
      hotel_id, actor_user_id, entity, entity_id,
      action, payload, correlation_id
    ) VALUES (
      v_hotel_id, auth.uid(), 'reservation', v_entity_id,
      v_action, v_payload, gen_random_uuid()
    );
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION app.ensure_user_profile(p_hotel_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  _auth_user_id uuid;
  _email text;
  _full_name text;
  _existing_id uuid;
  _hotel_id uuid;
BEGIN
  _auth_user_id := auth.uid();
  IF _auth_user_id IS NULL THEN RETURN NULL; END IF;

  -- Vérifier si le profil existe déjà
  SELECT id INTO _existing_id
  FROM public.users
  WHERE auth_id = _auth_user_id
  LIMIT 1;

  IF _existing_id IS NOT NULL THEN
    RETURN _existing_id;
  END IF;

  -- Récupérer email depuis auth.users
  SELECT email INTO _email
  FROM auth.users
  WHERE id = _auth_user_id;

  -- Récupérer full_name depuis auth.users metadata
  SELECT
    COALESCE(
      raw_user_meta_data->>'full_name',
      raw_user_meta_data->>'name',
      split_part(_email, '@', 1)
    ) INTO _full_name
  FROM auth.users
  WHERE id = _auth_user_id;

  -- Utiliser le premier hôtel disponible si hotel_id non fourni
  IF p_hotel_id IS NULL THEN
    SELECT id INTO _hotel_id FROM public.hotels LIMIT 1;
  ELSE
    _hotel_id := p_hotel_id;
  END IF;

  IF _hotel_id IS NULL THEN
    -- Pas d'hôtel disponible → pas de profil possible, retourner NULL
    RETURN NULL;
  END IF;

  -- Créer le profil
  INSERT INTO public.users (auth_id, hotel_id, email, full_name, role)
  VALUES (_auth_user_id, _hotel_id, _email, _full_name, 'admin')
  ON CONFLICT (hotel_id, email) DO UPDATE
    SET auth_id = EXCLUDED.auth_id,
        full_name = COALESCE(EXCLUDED.full_name, public.users.full_name),
        updated_at = now()
  RETURNING id INTO _existing_id;

  RETURN _existing_id;
END;
$function$;

-- Grants sur les fonctions app.* qui dépassent le défaut (PUBLIC + owner)
GRANT EXECUTE ON FUNCTION app.ensure_user_profile(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION app.resolve_actor_user_id() TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. public.provision_user_for_hotel
--    Note : les GRANT/REVOKE d'exécution définitifs sur cette fonction sont
--    déjà gérés par 0011_security_hardening (REVOKE anon/authenticated/public)
--    qui s'exécute juste après dans l'historique — pas dupliqué ici.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.provision_user_for_hotel(
  p_auth_user_id uuid, p_email text, p_full_name text, p_hotel_id uuid, p_role admin_user_role
)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare v_user_id uuid;
begin
  if p_auth_user_id is null then raise exception 'p_auth_user_id required'; end if;
  if p_hotel_id is null then raise exception 'p_hotel_id required'; end if;

  insert into public.users (auth_id, hotel_id, email, full_name, role)
  values (p_auth_user_id, p_hotel_id, p_email, coalesce(p_full_name, p_email), p_role)
  on conflict (auth_id) do update
    set hotel_id = excluded.hotel_id,
        full_name = coalesce(excluded.full_name, public.users.full_name),
        role = excluded.role,
        is_active = true,
        updated_at = now()
  returning id into v_user_id;

  update auth.users
     set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb)
                              || jsonb_build_object('hotel_id', p_hotel_id::text,
                                                    'role', p_role::text)
   where id = p_auth_user_id;

  return v_user_id;
end;
$function$;

COMMIT;
