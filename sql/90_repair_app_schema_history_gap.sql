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
-- Même constat pour deux autres fonctions référencées par le même bloc P1-1
-- de 0011 : public.set_updated_at() et public.audit_jsonb_diff(jsonb, jsonb).
-- (public.update_updated_at(), la 3e fonction du bloc, est elle bien créée par
-- 00001 — pas de gap sur celle-là.)
--
-- Même constat, un cran plus loin dans l'historique, pour la migration
-- suivante 20260511142334_0013_security_views_refactor : sa sanity-check
-- exige 13 vues déjà existantes (v_cli01_debtors, v_cli05_clv, ... ) avant de
-- les basculer en SECURITY INVOKER — vues elles aussi absentes de 00001.
-- Créées ici directement avec security_invoker=on (état final réel de
-- production), ce qui rend le ALTER VIEW de 0013 idempotent.
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
-- 3. Fonctions public.* également absentes de 00001 mais requises par le
--    bloc P1-1 de 0011 (ALTER FUNCTION ... SET search_path)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$function$;

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

-- ----------------------------------------------------------------------------
-- 4. public.provision_user_for_hotel
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

-- ----------------------------------------------------------------------------
-- 5. Colonnes public.reservations absentes de 00001, requises pour que les
--    13 vues de la section 6 puissent compiler.
--
--    Preuve de cause racine : balayage complet des 247 migrations trackées,
--    zéro occurrence de `ALTER TABLE reservations ADD COLUMN` — aucune
--    migration, à aucun moment de l'historique, ne fait jamais évoluer cette
--    table depuis sa définition 00001 (16 colonnes) vers sa forme réelle en
--    production (49 colonnes). Tout l'écart a été appliqué hors bande.
--    Portée limitée ici aux colonnes effectivement référencées par les 13
--    vues (pas les 33 colonnes manquantes au total — celles-ci ne bloquent
--    aucun rejeu tant qu'aucune migration trackée ne les utilise).
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='reservations' AND column_name='check_in_date')
     AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='reservations' AND column_name='check_in') THEN
    ALTER TABLE public.reservations RENAME COLUMN check_in_date TO check_in;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='reservations' AND column_name='check_out_date')
     AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='reservations' AND column_name='check_out') THEN
    ALTER TABLE public.reservations RENAME COLUMN check_out_date TO check_out;
  END IF;

  IF (SELECT data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='reservations' AND column_name='status') <> 'text' THEN
    ALTER TABLE public.reservations ALTER COLUMN status TYPE text USING status::text;
    ALTER TABLE public.reservations ALTER COLUMN status SET DEFAULT 'confirmed'::text;
  END IF;
END$$;

ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS reference text,
  ADD COLUMN IF NOT EXISTS room_number text,
  ADD COLUMN IF NOT EXISTS guest_id uuid,
  ADD COLUMN IF NOT EXISTS guest_email text,
  ADD COLUMN IF NOT EXISTS nights integer,
  ADD COLUMN IF NOT EXISTS checkin_status text DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS total_amount numeric(12,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS paid_amount numeric(12,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS solde numeric(12,2),
  ADD COLUMN IF NOT EXISTS source text DEFAULT 'Direct',
  ADD COLUMN IF NOT EXISTS payment_mode text DEFAULT 'Carte bancaire',
  ADD COLUMN IF NOT EXISTS no_show_at timestamptz;
-- no_show_at : cause racine révélée par 20260522130241_crm_c1_sync_orphans,
-- qui fait un UPDATE ... FROM (SELECT ... no_show_at ... FROM reservations)
-- en DML DIRECTE au niveau migration (pas dans un corps plpgsql non
-- validé statiquement comme les occurrences précédentes) — c'est ce qui l'a
-- révélée avant les autres colonnes déjà manquantes référencées seulement
-- à l'intérieur de fonctions.

-- ----------------------------------------------------------------------------
-- 5b. Table guests (minimale) — même cause racine : aucune migration trackée
--     ne crée jamais public.guests (une seule, crm_c1_schema, l'ALTER pour y
--     ajouter des colonnes CRM — elle suppose son existence préalable, elle
--     ne la crée pas). Créée ici avec les seules colonnes requises par les
--     vues de la section 6 ; crm_c1_schema complètera le reste plus tard
--     dans l'historique sans conflit (ADD COLUMN IF NOT EXISTS).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.guests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  first_name text,
  last_name text NOT NULL,
  email text,
  country text DEFAULT 'FR',
  loyalty_level text DEFAULT 'Standard',
  total_stays integer DEFAULT 0,
  total_spent numeric DEFAULT 0
);

-- 5b(bis). guests.updated_at — cause racine 20260522130241_crm_c1_sync_orphans
-- (même backfill que no_show_at ci-dessus, UPDATE guests SET ... updated_at
-- = now() en DML directe). Un ADD COLUMN updated_at existe bien ailleurs
-- dans l'historique (20260531193337) mais sur `invoices`, pas `guests` —
-- faux positif du premier balayage (texte "guests" présent dans une AUTRE
-- clause du même statement, une FK non liée). Zéro création réelle pour
-- guests.updated_at.
ALTER TABLE public.guests
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

-- ----------------------------------------------------------------------------
-- 5c. rooms.active — cause racine légèrement différente : une migration
--     trackée ajoute bien cette colonne (ALTER TABLE rooms ADD COLUMN
--     active...), mais elle est positionnée bien plus tard dans l'historique
--     que cette réparation (qui doit s'exécuter avant 0011/0013). Ajout ici
--     en IF NOT EXISTS : sans effet sur production, et sans conflit avec la
--     migration tardive qui refera le même ADD COLUMN IF NOT EXISTS plus loin.
-- ----------------------------------------------------------------------------
ALTER TABLE public.rooms ADD COLUMN IF NOT EXISTS active boolean DEFAULT true;

-- ----------------------------------------------------------------------------
-- 5d. Table payments (minimale) — même cause racine que guests : aucune
--     migration trackée ne crée jamais public.payments.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id uuid,
  amount numeric NOT NULL,
  payment_method text NOT NULL DEFAULT 'Carte bancaire',
  status text DEFAULT 'completed'
);

-- 5d(bis). Colonnes payments manquantes — même cause racine, révélée
--          seulement à la compilation de la 13e et dernière vue
--          (v_fec_entries, CTE `pay`, réfère p.reference/p.transaction_id/
--          p.payment_date, aucune des trois absente de la définition
--          minimale ci-dessus). Portée alignée sur l'état réel de
--          production (introspection information_schema.columns).
ALTER TABLE public.payments
  ADD COLUMN IF NOT EXISTS reservation_id uuid,
  ADD COLUMN IF NOT EXISTS payment_date timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS reference text,
  ADD COLUMN IF NOT EXISTS transaction_id text,
  ADD COLUMN IF NOT EXISTS payment_type text DEFAULT 'settlement',
  ADD COLUMN IF NOT EXISTS notes text,
  ADD COLUMN IF NOT EXISTS created_by uuid,
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS invoice_id uuid,
  ADD COLUMN IF NOT EXISTS currency text NOT NULL DEFAULT 'EUR',
  ADD COLUMN IF NOT EXISTS method text NOT NULL DEFAULT 'other',
  ADD COLUMN IF NOT EXISTS reversal_of uuid,
  ADD COLUMN IF NOT EXISTS reversal_reason text,
  ADD COLUMN IF NOT EXISTS collected_at timestamptz NOT NULL DEFAULT now();

-- ----------------------------------------------------------------------------
-- 5e. Table prestations (minimale) — même cause racine.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.prestations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  prestation_date date DEFAULT CURRENT_DATE,
  tva_rate numeric DEFAULT 10.0,
  total_amount numeric,
  tva_amount numeric,
  status text DEFAULT 'active'
);

-- ----------------------------------------------------------------------------
-- 5f. Type rie_decision + table reservation_validations (minimale) — même
--     cause racine, dernier objet manquant pour les 13 vues.
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'rie_decision') THEN
    CREATE TYPE public.rie_decision AS ENUM ('AUTO_INTEGRATE', 'WARNING', 'MANUAL_REVIEW', 'QUARANTINE');
  END IF;
END$$;

CREATE TABLE IF NOT EXISTS public.reservation_validations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id uuid NOT NULL,
  partner_id uuid,
  score integer NOT NULL DEFAULT 0,
  decision public.rie_decision NOT NULL DEFAULT 'MANUAL_REVIEW',
  delta_amount numeric,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- 5g. Table invoices (minimale) — même cause racine, dernière table
--     manquante pour la 13e et dernière vue (v_fec_entries).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id uuid,
  hotel_id uuid,
  invoice_number text NOT NULL,
  guest_name text,
  issue_date date DEFAULT CURRENT_DATE,
  total_ht numeric,
  total_tva numeric,
  total_ttc numeric,
  status text DEFAULT 'draft',
  created_at timestamptz DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- 5h. Tables sas_* (Service Après-Séjour / gestion des litiges partenaires) —
--     même cause racine, révélée seulement à la migration
--     20260514130954_fix_sas_rls_policies, qui recrée des policies RLS sur
--     ces 5 tables en tenant pour acquis qu'elles existent déjà. Preuve :
--     balayage complet des 247 migrations trackées, zéro occurrence de
--     `CREATE TABLE ... sas_*` — seule cette migration de policies les
--     référence, jamais une création. Colonnes/types/defaults alignés sur
--     l'état réel de production (introspection information_schema.columns) ;
--     aucune contrainte (PK/FK/UNIQUE) déclarée en production sur ces 5
--     tables, donc aucune ajoutée ici pour rester fidèle à la réalité.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sas_partners (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  hotel_id uuid NOT NULL,
  code text NOT NULL,
  name text NOT NULL,
  status text DEFAULT 'active' NOT NULL,
  timezone text DEFAULT 'Europe/Paris' NOT NULL,
  currency character(3) DEFAULT 'EUR' NOT NULL,
  country character(2),
  api_provider text,
  metadata jsonb DEFAULT '{}'::jsonb,
  account_manager_name text,
  account_manager_email text,
  support_email text,
  dispute_email text,
  phone text,
  contract_reference text,
  commission_rate numeric(5,2),
  auto_send_disputes boolean DEFAULT false NOT NULL,
  dispute_sla_days integer DEFAULT 7 NOT NULL,
  followup_days integer[] DEFAULT '{2,5,10}'::integer[] NOT NULL,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.sas_disputes (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  hotel_id uuid NOT NULL,
  reference text NOT NULL,
  incoming_id uuid,
  validation_id uuid,
  partner_id uuid,
  expected_amount numeric(12,2),
  received_amount numeric(12,2),
  claimed_amount numeric(12,2),
  recovered_amount numeric(12,2) DEFAULT 0,
  subject text,
  explanation text,
  email_subject text,
  email_body text,
  recipients jsonb DEFAULT '[]'::jsonb,
  status text DEFAULT 'DRAFT' NOT NULL,
  sent_at timestamptz,
  acknowledged_at timestamptz,
  resolved_at timestamptz,
  next_followup_at timestamptz,
  followup_count integer DEFAULT 0 NOT NULL,
  created_by uuid,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.sas_dispute_messages (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  hotel_id uuid NOT NULL,
  dispute_id uuid NOT NULL,
  direction text DEFAULT 'INTERNAL' NOT NULL,
  content text NOT NULL,
  attachments jsonb DEFAULT '[]'::jsonb,
  sent_at timestamptz,
  created_by uuid,
  created_at timestamptz DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.sas_dispute_status_history (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  hotel_id uuid NOT NULL,
  dispute_id uuid NOT NULL,
  old_status text,
  new_status text NOT NULL,
  reason text,
  changed_by uuid,
  changed_at timestamptz DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.sas_email_logs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  hotel_id uuid NOT NULL,
  dispute_id uuid,
  followup_id uuid,
  resend_id text,
  from_email text NOT NULL,
  to_emails jsonb DEFAULT '[]'::jsonb NOT NULL,
  subject text NOT NULL,
  status text DEFAULT 'queued' NOT NULL,
  sent_at timestamptz,
  error_msg text,
  created_at timestamptz DEFAULT now() NOT NULL
);

-- ----------------------------------------------------------------------------
-- 5i. Table user_hotels (association utilisateur ↔ hôtel + rôle) — même
--     cause racine, révélée seulement à 20260518102844_rms_decisions_
--     append_only_audit, la première d'au moins 14 migrations qui
--     référencent user_hotels en la tenant pour acquise. Preuve : le motif
--     naïf `create table ... user_hotels` remonte 14 faux positifs (FK vers
--     user_hotels dans un CREATE TABLE d'une AUTRE table) ; le motif strict
--     `CREATE TABLE (IF NOT EXISTS )?public\.user_hotels\(` ne remonte
--     aucune occurrence sur les 247 migrations trackées — zéro création
--     réelle. Le type public.admin_user_role qu'utilise sa colonne `role`
--     est, lui, bien créé par 00001 (pas de gap sur le type).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_hotels (
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  hotel_id uuid NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  role public.admin_user_role NOT NULL DEFAULT 'reception',
  is_default boolean NOT NULL DEFAULT false,
  granted_at timestamptz NOT NULL DEFAULT now(),
  granted_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  PRIMARY KEY (user_id, hotel_id)
);

-- ----------------------------------------------------------------------------
-- 5j. Table lighthouse_imports (import RMS de benchmark concurrentiel) —
--     cause racine différente des précédentes : ce n'est pas une simple
--     absence de création trackée, c'est une INCOHÉRENCE entre deux
--     migrations trackées. La migration 20260518112224_lighthouse_imports_
--     extend_for_persistence contient elle-même un `CREATE TABLE IF NOT
--     EXISTS lighthouse_imports (...)` de bootstrap — mais avec un schéma
--     réduit (12 colonnes : id, hotel_id, file_name, our_hotel_name,
--     competitor_names, sheets_found, warnings, is_active, days_count,
--     imported_at, imported_by, archived_at) — suivi d'un `CREATE INDEX
--     ... (uploaded_at DESC)` qui suppose une colonne `uploaded_at`
--     absente de ce schéma réduit. Sur production, le bootstrap était un
--     no-op (la vraie table, créée hors bande, existait déjà avec 26
--     colonnes incluant uploaded_at) donc l'incohérence ne s'est jamais
--     révélée. Sur un rejeu vierge, le bootstrap CRÉE réellement la table
--     avec le schéma réduit, et l'index sur uploaded_at échoue :
--     ERROR: column "uploaded_at" does not exist.
--     Correction : créer ici le schéma RÉEL et complet de production, pour
--     que le bootstrap de 20260518112224 soit un no-op au rejeu aussi,
--     exactement comme il l'est en production.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lighthouse_imports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id uuid NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  filename text NOT NULL,
  file_size_bytes bigint,
  storage_path text,
  ota text,
  rate_type text,
  los integer,
  guests integer,
  client_hotel_name text,
  competitor_count integer,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','processing','completed','failed','cancelled')),
  rows_ingested integer NOT NULL DEFAULT 0,
  rows_skipped integer NOT NULL DEFAULT 0,
  error_message text,
  warnings jsonb NOT NULL DEFAULT '[]'::jsonb,
  uploaded_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  uploaded_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  duration_seconds numeric,
  is_active boolean NOT NULL DEFAULT false,
  our_hotel_name text,
  competitor_names jsonb NOT NULL DEFAULT '[]'::jsonb,
  sheets_found jsonb,
  archived_at timestamptz,
  days_count integer NOT NULL DEFAULT 0
);

-- ----------------------------------------------------------------------------
-- 5k. Table audit_logs + ses 2 triggers d'immuabilité — cause racine
--     démontrée sur la migration 20260522113519_finance_audit_chain_f7_setup,
--     qui contient un `ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS seq`
--     en DDL DIRECTE (pas dans un corps de fonction plpgsql non validé
--     statiquement, contrairement aux occurrences vues dans les migrations
--     précédentes qui ne faisaient que RÉFÉRENCER audit_logs à l'intérieur
--     de CREATE FUNCTION). Preuve : `create table ... audit_logs` strict
--     remonte zéro occurrence sur les 247 migrations trackées. La même
--     migration fait aussi `ALTER TABLE audit_logs DISABLE TRIGGER
--     trg_audit_logs_no_update` — ce trigger (et son jumeau
--     trg_audit_logs_no_delete), bien que liés à app.audit_logs_immutable()
--     déjà réparée en section 2, n'étaient eux-mêmes jamais créés par une
--     migration trackée. Colonnes seq/prev_hash/entry_hash volontairement
--     omises ici : elles sont ajoutées par 20260522113519 lui-même via
--     ALTER ... ADD COLUMN IF NOT EXISTS, donc déjà idempotentes.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id uuid NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  actor_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
  entity text NOT NULL,
  entity_id uuid NOT NULL,
  action text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  correlation_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  actor_label text
);

DROP TRIGGER IF EXISTS trg_audit_logs_no_update ON public.audit_logs;
CREATE TRIGGER trg_audit_logs_no_update
  BEFORE UPDATE ON public.audit_logs
  FOR EACH ROW EXECUTE FUNCTION app.audit_logs_immutable();

DROP TRIGGER IF EXISTS trg_audit_logs_no_delete ON public.audit_logs;
CREATE TRIGGER trg_audit_logs_no_delete
  BEFORE DELETE ON public.audit_logs
  FOR EACH ROW EXECUTE FUNCTION app.audit_logs_immutable();

-- ----------------------------------------------------------------------------
-- 6. Les 13 vues attendues par 0013_security_views_refactor
--    (créées directement avec security_invoker=on, état final réel de
--    production — rend le ALTER VIEW de 0013 idempotent)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_cli01_debtors WITH (security_invoker=on) AS
 SELECT id,
    reference,
    guest_name,
    guest_email,
    check_in,
    check_out,
    source AS canal,
    total_amount,
    paid_amount,
    solde AS amount_due,
    payment_mode
   FROM reservations r
  WHERE solde > 0::numeric AND (status <> ALL (ARRAY['cancelled'::text, 'no_show'::text]))
  ORDER BY solde DESC;

CREATE OR REPLACE VIEW public.v_cli05_clv WITH (security_invoker=on) AS
 SELECT id,
    (first_name || ' '::text) || last_name AS full_name,
    email,
    country,
    loyalty_level,
    total_stays,
    total_spent,
        CASE
            WHEN total_stays > 0 THEN round(total_spent / total_stays::numeric, 2)
            ELSE 0::numeric
        END AS clv
   FROM guests g
  ORDER BY total_spent DESC;

CREATE OR REPLACE VIEW public.v_dir01_direction WITH (security_invoker=on) AS
 SELECT ( SELECT sum(reservations.total_amount) AS sum
           FROM reservations
          WHERE EXTRACT(month FROM reservations.check_in) = EXTRACT(month FROM CURRENT_DATE)) AS ca_month,
    ( SELECT round(avg(reservations.total_amount / NULLIF(reservations.nights, 0)::numeric), 2) AS round
           FROM reservations
          WHERE reservations.status <> ALL (ARRAY['cancelled'::text, 'no_show'::text])) AS adr,
    ( SELECT count(*) AS count
           FROM reservations
          WHERE reservations.status = 'no_show'::text) AS total_noshow,
    ( SELECT count(*) AS count
           FROM reservations
          WHERE reservations.status = 'cancelled'::text) AS total_cancellations,
    ( SELECT sum(reservations.solde) AS sum
           FROM reservations
          WHERE reservations.solde > 0::numeric AND (reservations.status <> ALL (ARRAY['cancelled'::text, 'no_show'::text]))) AS total_impaye;

CREATE OR REPLACE VIEW public.v_exp01_occupation WITH (security_invoker=on) AS
 SELECT count(DISTINCT id) AS occupied_rooms,
    ( SELECT count(*) AS count
           FROM rooms
          WHERE rooms.active = true) AS total_rooms,
    round(count(DISTINCT id)::numeric * 100.0 / NULLIF(( SELECT count(*) AS count
           FROM rooms
          WHERE rooms.active = true), 0)::numeric, 1) AS to_pct,
    count(
        CASE
            WHEN check_in = CURRENT_DATE THEN 1
            ELSE NULL::integer
        END) AS arrivals_today,
    count(
        CASE
            WHEN check_out = CURRENT_DATE THEN 1
            ELSE NULL::integer
        END) AS departures_today
   FROM reservations r
  WHERE check_in <= CURRENT_DATE AND check_out > CURRENT_DATE AND (status = ANY (ARRAY['confirmed'::text, 'checked_in'::text]));

CREATE OR REPLACE VIEW public.v_exp09_noshow WITH (security_invoker=on) AS
 SELECT id,
    reference,
    guest_name,
    check_in,
    check_out,
    source AS canal,
    total_amount AS montant_perdu,
    status
   FROM reservations r
  WHERE status = 'no_show'::text OR check_in < CURRENT_DATE AND checkin_status = 'pending'::text AND status = 'confirmed'::text
  ORDER BY check_in DESC;

CREATE OR REPLACE VIEW public.v_exp10_departures WITH (security_invoker=on) AS
 SELECT id,
    reference,
    room_number,
    guest_name,
    check_in,
    check_out,
    status,
    solde
   FROM reservations r
  WHERE check_out = CURRENT_DATE AND (status <> ALL (ARRAY['cancelled'::text, 'no_show'::text]))
  ORDER BY room_number;

CREATE OR REPLACE VIEW public.v_fec_entries WITH (security_invoker=on) AS
 WITH payment_account_map AS (
         SELECT 'CB'::text AS method,
            '512100'::text AS compte_num,
            'Banque - CB'::text AS compte_lib
        UNION ALL
         SELECT 'CARD'::text,
            '512100'::text,
            'Banque - CB'::text
        UNION ALL
         SELECT 'CARTE BANCAIRE'::text,
            '512100'::text,
            'Banque - CB'::text
        UNION ALL
         SELECT 'CARTE'::text,
            '512100'::text,
            'Banque - CB'::text
        UNION ALL
         SELECT 'VIREMENT'::text,
            '512000'::text,
            'Banque - Virement'::text
        UNION ALL
         SELECT 'TRANSFER'::text,
            '512000'::text,
            'Banque - Virement'::text
        UNION ALL
         SELECT 'WIRE'::text,
            '512000'::text,
            'Banque - Virement'::text
        UNION ALL
         SELECT 'CHEQUE'::text,
            '512110'::text,
            'Banque - Chèque'::text
        UNION ALL
         SELECT 'CHÈQUE'::text,
            '512110'::text,
            'Banque - Chèque'::text
        UNION ALL
         SELECT 'CHECK'::text,
            '512110'::text,
            'Banque - Chèque'::text
        UNION ALL
         SELECT 'ESPECES'::text,
            '530000'::text,
            'Caisse - Espèces'::text
        UNION ALL
         SELECT 'ESPÈCES'::text,
            '530000'::text,
            'Caisse - Espèces'::text
        UNION ALL
         SELECT 'CASH'::text,
            '530000'::text,
            'Caisse - Espèces'::text
        UNION ALL
         SELECT 'OTA'::text,
            '512200'::text,
            'Banque - Payout OTA'::text
        UNION ALL
         SELECT 'PAYPAL'::text,
            '512300'::text,
            'Banque - PayPal'::text
        UNION ALL
         SELECT 'STRIPE'::text,
            '512300'::text,
            'Banque - Stripe'::text
        UNION ALL
         SELECT 'PMS'::text,
            '512300'::text,
            'Banque - PMS'::text
        ), inv AS (
         SELECT i.id AS src_id,
            i.hotel_id,
            'VE'::text AS journal_code,
            'Journal des Ventes'::text AS journal_lib,
            i.invoice_number AS piece_ref,
            COALESCE(i.issue_date, i.created_at::date) AS ecr_date,
            COALESCE(i.issue_date, i.created_at::date) AS piece_date,
            COALESCE(NULLIF(i.guest_name, ''::text), 'Client divers'::text) AS guest_name,
            COALESCE(i.total_ht, 0::numeric) AS ht,
            COALESCE(i.total_tva, 0::numeric) AS tva,
            COALESCE(i.total_ttc, 0::numeric) AS ttc,
            (('Facture '::text || i.invoice_number) || ' - '::text) || COALESCE(i.guest_name, 'Client'::text) AS ecr_lib,
            i.reservation_id,
            COALESCE(i.created_at, now()) AS valid_date
           FROM invoices i
          WHERE COALESCE(i.status, 'draft'::text) <> 'cancelled'::text
        ), inv_lines AS (
         SELECT inv.hotel_id,
            inv.src_id,
            inv.journal_code,
            inv.journal_lib,
            inv.piece_ref,
            inv.ecr_date,
            inv.piece_date,
            inv.valid_date,
            '411000'::text AS compte_num,
            'Clients'::text AS compte_lib,
            NULL::text AS compaux_num,
            NULL::text AS compaux_lib,
            inv.ttc AS debit,
            0::numeric AS credit,
            inv.ecr_lib,
            1 AS sub_order
           FROM inv
        UNION ALL
         SELECT inv.hotel_id,
            inv.src_id,
            inv.journal_code,
            inv.journal_lib,
            inv.piece_ref,
            inv.ecr_date,
            inv.piece_date,
            inv.valid_date,
            '707000'::text AS compte_num,
            'Ventes - Hébergement'::text AS compte_lib,
            NULL::text AS compaux_num,
            NULL::text AS compaux_lib,
            0::numeric AS debit,
            inv.ht AS credit,
            inv.ecr_lib,
            2
           FROM inv
          WHERE inv.ht > 0::numeric
        UNION ALL
         SELECT inv.hotel_id,
            inv.src_id,
            inv.journal_code,
            inv.journal_lib,
            inv.piece_ref,
            inv.ecr_date,
            inv.piece_date,
            inv.valid_date,
            '445710'::text AS compte_num,
            'TVA collectée'::text AS compte_lib,
            NULL::text AS compaux_num,
            NULL::text AS compaux_lib,
            0::numeric AS debit,
            inv.tva AS credit,
            inv.ecr_lib,
            3
           FROM inv
          WHERE inv.tva > 0::numeric
        ), pay AS (
         SELECT p.id AS src_id,
            p.hotel_id,
            'BQ'::text AS journal_code,
            'Journal de Banque'::text AS journal_lib,
            COALESCE(p.reference, p.transaction_id, p.id::text) AS piece_ref,
            COALESCE(p.payment_date::date, p.created_at::date) AS ecr_date,
            COALESCE(p.payment_date::date, p.created_at::date) AS piece_date,
            COALESCE(p.amount, 0::numeric) AS ttc,
            upper(COALESCE(p.payment_method, 'CB'::text)) AS method,
            (('Encaissement '::text || COALESCE(p.payment_method, 'CB'::text)) || ' - '::text) || COALESCE(p.reference, p.id::text) AS ecr_lib,
            COALESCE(p.created_at, now()) AS valid_date
           FROM payments p
          WHERE COALESCE(p.status, 'completed'::text) <> 'cancelled'::text
        ), pay_lines AS (
         SELECT py.hotel_id,
            py.src_id,
            py.journal_code,
            py.journal_lib,
            py.piece_ref,
            py.ecr_date,
            py.piece_date,
            py.valid_date,
            COALESCE(m.compte_num, '512000'::text) AS compte_num,
            COALESCE(m.compte_lib, 'Banque - Autre'::text) AS compte_lib,
            NULL::text AS compaux_num,
            NULL::text AS compaux_lib,
            py.ttc AS debit,
            0::numeric AS credit,
            py.ecr_lib,
            1 AS sub_order
           FROM pay py
             LEFT JOIN payment_account_map m ON m.method = py.method
        UNION ALL
         SELECT py.hotel_id,
            py.src_id,
            py.journal_code,
            py.journal_lib,
            py.piece_ref,
            py.ecr_date,
            py.piece_date,
            py.valid_date,
            '411000'::text AS compte_num,
            'Clients'::text AS compte_lib,
            NULL::text AS compaux_num,
            NULL::text AS compaux_lib,
            0::numeric AS debit,
            py.ttc AS credit,
            py.ecr_lib,
            2
           FROM pay py
        ), all_lines AS (
         SELECT inv_lines.hotel_id,
            inv_lines.src_id,
            inv_lines.journal_code,
            inv_lines.journal_lib,
            inv_lines.piece_ref,
            inv_lines.ecr_date,
            inv_lines.piece_date,
            inv_lines.valid_date,
            inv_lines.compte_num,
            inv_lines.compte_lib,
            inv_lines.compaux_num,
            inv_lines.compaux_lib,
            inv_lines.debit,
            inv_lines.credit,
            inv_lines.ecr_lib,
            inv_lines.sub_order
           FROM inv_lines
        UNION ALL
         SELECT pay_lines.hotel_id,
            pay_lines.src_id,
            pay_lines.journal_code,
            pay_lines.journal_lib,
            pay_lines.piece_ref,
            pay_lines.ecr_date,
            pay_lines.piece_date,
            pay_lines.valid_date,
            pay_lines.compte_num,
            pay_lines.compte_lib,
            pay_lines.compaux_num,
            pay_lines.compaux_lib,
            pay_lines.debit,
            pay_lines.credit,
            pay_lines.ecr_lib,
            pay_lines.sub_order
           FROM pay_lines
        ), numbered AS (
         SELECT all_lines.hotel_id,
            all_lines.journal_code,
            all_lines.journal_lib,
            dense_rank() OVER (PARTITION BY all_lines.hotel_id, all_lines.journal_code, (date_part('year'::text, all_lines.ecr_date)) ORDER BY all_lines.ecr_date, all_lines.src_id) AS ecr_num,
            all_lines.ecr_date,
            all_lines.compte_num,
            all_lines.compte_lib,
            all_lines.compaux_num,
            all_lines.compaux_lib,
            all_lines.piece_ref,
            all_lines.piece_date,
            all_lines.ecr_lib,
            all_lines.debit,
            all_lines.credit,
            all_lines.valid_date,
            all_lines.src_id,
            all_lines.sub_order
           FROM all_lines
        )
 SELECT hotel_id,
    journal_code AS "JournalCode",
    journal_lib AS "JournalLib",
    (journal_code || to_char(ecr_date::timestamp with time zone, 'YYYY'::text)) || lpad(ecr_num::text, 6, '0'::text) AS "EcritureNum",
    to_char(ecr_date::timestamp with time zone, 'YYYYMMDD'::text) AS "EcritureDate",
    compte_num AS "CompteNum",
    compte_lib AS "CompteLib",
    COALESCE(compaux_num, ''::text) AS "CompAuxNum",
    COALESCE(compaux_lib, ''::text) AS "CompAuxLib",
    piece_ref AS "PieceRef",
    to_char(piece_date::timestamp with time zone, 'YYYYMMDD'::text) AS "PieceDate",
    ecr_lib AS "EcritureLib",
    to_char(debit, 'FM999999990D00'::text) AS "Debit",
    to_char(credit, 'FM999999990D00'::text) AS "Credit",
    ''::text AS "EcritureLet",
    ''::text AS "DateLet",
    to_char(valid_date, 'YYYYMMDD'::text) AS "ValidDate",
    ''::text AS "Montantdevise",
    ''::text AS "Idevise",
    src_id,
    sub_order,
    ecr_num
   FROM numbered;

CREATE OR REPLACE VIEW public.v_fin02_payments WITH (security_invoker=on) AS
 SELECT payment_method,
    count(*) AS nb_transactions,
    sum(amount) AS total_amount,
    round(sum(amount) * 100.0 / NULLIF(sum(sum(amount)) OVER (), 0::numeric), 1) AS share_pct
   FROM payments
  WHERE status = 'completed'::text
  GROUP BY payment_method
  ORDER BY (sum(amount)) DESC;

CREATE OR REPLACE VIEW public.v_fin09_tva WITH (security_invoker=on) AS
 SELECT date_trunc('month'::text, prestation_date::timestamp with time zone) AS month,
    tva_rate,
    sum(total_amount) AS total_ttc,
    sum(tva_amount) AS tva_collected,
    count(*) AS nb_lines
   FROM prestations
  WHERE status <> 'cancelled'::text
  GROUP BY (date_trunc('month'::text, prestation_date::timestamp with time zone)), tva_rate
  ORDER BY (date_trunc('month'::text, prestation_date::timestamp with time zone)) DESC;

CREATE OR REPLACE VIEW public.v_sta01_dashboard WITH (security_invoker=on) AS
 SELECT count(*) AS total_reservations,
    sum(total_amount) AS ca_total,
    sum(paid_amount) AS ca_encaisse,
    sum(COALESCE(solde, 0::numeric)) AS ca_impaye,
    round(avg(total_amount / NULLIF(nights, 0)::numeric), 2) AS adr,
    sum(nights) AS total_nights,
    count(
        CASE
            WHEN status = 'cancelled'::text THEN 1
            ELSE NULL::integer
        END) AS cancellations,
    count(
        CASE
            WHEN status = 'no_show'::text THEN 1
            ELSE NULL::integer
        END) AS no_shows
   FROM reservations;

CREATE OR REPLACE VIEW public.v_sta05_channels WITH (security_invoker=on) AS
 SELECT COALESCE(source, 'Direct'::text) AS canal,
    count(*) AS bookings,
    sum(total_amount) AS revenue,
    round(sum(total_amount) * 100.0 / NULLIF(sum(sum(total_amount)) OVER (), 0::numeric), 1) AS share_pct
   FROM reservations
  GROUP BY (COALESCE(source, 'Direct'::text))
  ORDER BY (sum(total_amount)) DESC;

CREATE OR REPLACE VIEW public.v_sta06_nationalities WITH (security_invoker=on) AS
 SELECT COALESCE(g.country, 'FR'::text) AS country,
    count(DISTINCT r.id) AS reservations,
    sum(r.nights) AS total_nights,
    sum(r.total_amount) AS revenue
   FROM reservations r
     LEFT JOIN guests g ON r.guest_id = g.id
  GROUP BY g.country
  ORDER BY (sum(r.total_amount)) DESC;

CREATE OR REPLACE VIEW public.partner_reliability_view WITH (security_invoker=on) AS
 SELECT hotel_id,
    partner_id,
    count(*)::integer AS runs,
    round(avg(score), 1) AS avg_score_30d,
    sum(
        CASE
            WHEN decision = 'AUTO_INTEGRATE'::rie_decision THEN 1
            ELSE 0
        END)::integer AS auto_count,
    sum(
        CASE
            WHEN decision = 'WARNING'::rie_decision THEN 1
            ELSE 0
        END)::integer AS warning_count,
    sum(
        CASE
            WHEN decision = 'MANUAL_REVIEW'::rie_decision THEN 1
            ELSE 0
        END)::integer AS manual_count,
    sum(
        CASE
            WHEN decision = 'QUARANTINE'::rie_decision THEN 1
            ELSE 0
        END)::integer AS quarantine_count,
    sum(abs(COALESCE(delta_amount, 0::numeric)))::numeric(14,2) AS cumulative_delta_30d,
    max(created_at) AS last_run_at
   FROM reservation_validations v
  WHERE created_at >= (now() - '30 days'::interval)
  GROUP BY hotel_id, partner_id;

COMMIT;
