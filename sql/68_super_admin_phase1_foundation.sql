-- 68_super_admin_phase1_foundation.sql
-- Super Admin portal (/admin) — Phase 1: Dashboard + Hôtels + Groupes + Utilisateurs + Audit
--
-- Contexte : la plupart des tables nécessaires existent déjà (platform_admins, hotel_groups,
-- hotels, hotel_subscriptions, subscription_plans, audit_logs, platform_logs...) mais ont été
-- créées directement en prod sans jamais être versionnées (même anti-pattern déjà documenté
-- dans db/reconstruct/README.md). Cette migration versionne les correctifs et RPC manquants,
-- de façon strictement additive : aucun DROP, aucun RENAME, aucune donnée supprimée.
--
-- Deux vrais trous RLS corrigés ici : un platform_admin sans hôtel personnel (le cas normal)
-- ne pouvait ni lire ni écrire hotel_groups, et ne pouvait pas lire audit_logs/invoices/payments
-- (policies existantes filtrées uniquement sur hotel_id = get_user_hotel_id(), sans bypass admin).

-- ============================================================================
-- 1. RLS — bypass platform_admin manquant
-- ============================================================================

DROP POLICY IF EXISTS hotel_groups_admin_all ON public.hotel_groups;
CREATE POLICY hotel_groups_admin_all ON public.hotel_groups
  FOR ALL USING (public.is_platform_admin()) WITH CHECK (public.is_platform_admin());

DROP POLICY IF EXISTS audit_logs_admin_read ON public.audit_logs;
CREATE POLICY audit_logs_admin_read ON public.audit_logs
  FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS invoices_admin_read ON public.invoices;
CREATE POLICY invoices_admin_read ON public.invoices
  FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS payments_admin_read ON public.payments;
CREATE POLICY payments_admin_read ON public.payments
  FOR SELECT USING (public.is_platform_admin());

-- ============================================================================
-- 2. platform_logs — durcissement (immuabilité) + colonne user_agent
-- ============================================================================
-- platform_logs a déjà une policy ALL is_platform_admin() correcte (vérifié), mais aucune
-- protection contre UPDATE/DELETE au niveau trigger (contrairement à audit_logs). On applique
-- le même motif que app.audit_logs_immutable(), en le réutilisant directement.

ALTER TABLE public.platform_logs ADD COLUMN IF NOT EXISTS user_agent text;

DROP TRIGGER IF EXISTS trg_platform_logs_no_update ON public.platform_logs;
DROP TRIGGER IF EXISTS trg_platform_logs_no_delete ON public.platform_logs;
CREATE TRIGGER trg_platform_logs_no_update BEFORE UPDATE ON public.platform_logs
  FOR EACH ROW EXECUTE FUNCTION app.audit_logs_immutable();
CREATE TRIGGER trg_platform_logs_no_delete BEFORE DELETE ON public.platform_logs
  FOR EACH ROW EXECUTE FUNCTION app.audit_logs_immutable();

-- ============================================================================
-- 3. Helpers internes partagés
-- ============================================================================

-- Écrit une ligne d'audit platform-level. IP/user-agent lus côté serveur depuis les headers
-- PostgREST (non falsifiables par le client), pas transmis en paramètre.
CREATE OR REPLACE FUNCTION public._platform_log(
  p_action    text,
  p_entity    text,
  p_entity_id text,
  p_hotel_id  uuid DEFAULT NULL,
  p_hotel_name text DEFAULT NULL,
  p_payload   jsonb DEFAULT '{}'::jsonb,
  p_level     text DEFAULT 'info'
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_admin_id    uuid;
  v_admin_email text;
  v_headers     jsonb;
  v_ip          text;
  v_ua          text;
BEGIN
  SELECT id, email INTO v_admin_id, v_admin_email
  FROM public.platform_admins WHERE auth_id = auth.uid() LIMIT 1;

  BEGIN
    v_headers := current_setting('request.headers', true)::jsonb;
    v_ip := coalesce(split_part(v_headers->>'x-forwarded-for', ',', 1), v_headers->>'x-real-ip');
    v_ua := v_headers->>'user-agent';
  EXCEPTION WHEN OTHERS THEN
    v_ip := NULL; v_ua := NULL;
  END;

  INSERT INTO public.platform_logs
    (admin_id, admin_email, action, entity, entity_id, hotel_id, hotel_name, payload, ip_address, user_agent, level)
  VALUES
    (v_admin_id, v_admin_email, p_action, p_entity, p_entity_id, p_hotel_id, p_hotel_name, coalesce(p_payload,'{}'::jsonb), v_ip, v_ua, p_level);
END;
$function$;

-- Génère un hotel_code unique à partir du nom (même algorithme que org_provision(),
-- dupliqué intentionnellement plutôt que refactoré en commun pour ne pas toucher à
-- org_provision(), fonction self-service existante déjà utilisée en prod).
CREATE OR REPLACE FUNCTION public._generate_hotel_code(p_name text)
RETURNS text
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_base text; v_code text; v_n int;
BEGIN
  v_base := coalesce((SELECT upper(string_agg(left(w,1),'')) FROM (
              SELECT w FROM unnest(regexp_split_to_array(regexp_replace(coalesce(p_name,''),'[^A-Za-z ]','','g'),'\s+')) AS w
              WHERE w<>'' LIMIT 2) t),'');
  IF length(v_base) < 2 THEN
    v_base := upper(left(regexp_replace(coalesce(p_name,'HT'),'[^A-Za-z]','','g')||'HT',2));
  END IF;
  v_n := 1;
  LOOP
    v_code := v_base || lpad(v_n::text,3,'0');
    EXIT WHEN NOT EXISTS(SELECT 1 FROM public.hotels WHERE upper(hotel_code)=v_code);
    v_n := v_n + 1;
  END LOOP;
  RETURN v_code;
END;
$function$;

-- ============================================================================
-- 4. RPC — Hôtels (super admin, sans dépendance à pl_my_hotels())
-- ============================================================================

CREATE OR REPLACE FUNCTION public.admin_create_hotel(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_new  uuid;
  v_code text;
  v_name text := trim(coalesce(p->>'name',''));
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF v_name = '' THEN
    RAISE EXCEPTION 'NOM_VIDE';
  END IF;

  v_code := upper(trim(coalesce(p->>'hotel_code','')));
  IF v_code <> '' AND EXISTS(SELECT 1 FROM public.hotels WHERE upper(hotel_code)=v_code) THEN
    RAISE EXCEPTION 'CODE_EXISTANT';
  END IF;
  IF v_code = '' THEN
    v_code := public._generate_hotel_code(v_name);
  END IF;

  INSERT INTO public.hotels (
    name, address, city, zip, country, phone, email, website, siret, tva_number,
    company, stars, total_rooms, currency, timezone, hotel_code, group_id,
    status, active
  ) VALUES (
    v_name, nullif(p->>'address',''), nullif(p->>'city',''), nullif(p->>'zip',''),
    coalesce(nullif(p->>'country',''),'France'), nullif(p->>'phone',''), nullif(p->>'email',''),
    nullif(p->>'website',''), nullif(p->>'siret',''), nullif(p->>'tva_number',''),
    nullif(p->>'company',''), nullif(p->>'stars','')::int, nullif(p->>'total_rooms','')::int,
    coalesce(nullif(p->>'currency',''),'EUR'), coalesce(nullif(p->>'timezone',''),'Europe/Paris'),
    v_code, nullif(p->>'group_id','')::uuid,
    coalesce(nullif(p->>'status',''),'draft'), coalesce(nullif(p->>'status',''),'draft')='active'
  ) RETURNING id INTO v_new;

  PERFORM public._platform_log('hotel.create', 'hotel', v_new::text, v_new, v_name, jsonb_build_object('after', p));

  RETURN (SELECT to_jsonb(h) FROM public.hotels h WHERE h.id = v_new);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_update_hotel(p_hotel uuid, p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_before jsonb; v_name text;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  SELECT to_jsonb(h) INTO v_before FROM public.hotels h WHERE h.id = p_hotel;
  IF v_before IS NULL THEN
    RAISE EXCEPTION 'HOTEL_INTROUVABLE';
  END IF;

  UPDATE public.hotels SET
    name        = coalesce(nullif(trim(p->>'name'),''), name),
    address     = coalesce(p->>'address', address),
    city        = coalesce(p->>'city', city),
    zip         = coalesce(p->>'zip', zip),
    country     = coalesce(p->>'country', country),
    phone       = coalesce(p->>'phone', phone),
    email       = coalesce(p->>'email', email),
    website     = coalesce(p->>'website', website),
    siret       = coalesce(p->>'siret', siret),
    tva_number  = coalesce(p->>'tva_number', tva_number),
    company     = coalesce(p->>'company', company),
    stars       = coalesce(nullif(p->>'stars','')::int, stars),
    total_rooms = coalesce(nullif(p->>'total_rooms','')::int, total_rooms),
    currency    = coalesce(nullif(p->>'currency',''), currency),
    timezone    = coalesce(nullif(p->>'timezone',''), timezone)
  WHERE id = p_hotel
  RETURNING name INTO v_name;

  PERFORM public._platform_log('hotel.update', 'hotel', p_hotel::text, p_hotel, v_name,
    jsonb_build_object('before', v_before, 'after', p));

  RETURN (SELECT to_jsonb(h) FROM public.hotels h WHERE h.id = p_hotel);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_hotel_status(p_hotel uuid, p_status text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_before text; v_name text;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_status NOT IN ('draft','active','suspended','archived') THEN
    RAISE EXCEPTION 'STATUT_INVALIDE';
  END IF;

  SELECT status, name INTO v_before, v_name FROM public.hotels WHERE id = p_hotel;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'HOTEL_INTROUVABLE';
  END IF;

  UPDATE public.hotels SET status = p_status, active = (p_status = 'active') WHERE id = p_hotel;

  PERFORM public._platform_log('hotel.status_change', 'hotel', p_hotel::text, p_hotel, v_name,
    jsonb_build_object('before', v_before, 'after', p_status));

  RETURN (SELECT to_jsonb(h) FROM public.hotels h WHERE h.id = p_hotel);
END;
$function$;

-- ============================================================================
-- 5. RPC — Groupes hôteliers (super admin)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.admin_create_group(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_new uuid; v_name text := trim(coalesce(p->>'name',''));
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF v_name = '' THEN
    RAISE EXCEPTION 'NOM_VIDE';
  END IF;

  INSERT INTO public.hotel_groups (name, logo_url, status)
  VALUES (v_name, nullif(p->>'logo_url',''), 'active')
  RETURNING id INTO v_new;

  PERFORM public._platform_log('group.create', 'hotel_group', v_new::text, NULL, v_name, jsonb_build_object('after', p));

  RETURN (SELECT to_jsonb(g) FROM public.hotel_groups g WHERE g.id = v_new);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_update_group(p_group uuid, p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_before jsonb; v_name text;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  SELECT to_jsonb(g) INTO v_before FROM public.hotel_groups g WHERE g.id = p_group;
  IF v_before IS NULL THEN
    RAISE EXCEPTION 'GROUPE_INTROUVABLE';
  END IF;

  UPDATE public.hotel_groups SET
    name     = coalesce(nullif(trim(p->>'name'),''), name),
    logo_url = coalesce(p->>'logo_url', logo_url)
  WHERE id = p_group
  RETURNING name INTO v_name;

  PERFORM public._platform_log('group.update', 'hotel_group', p_group::text, NULL, v_name,
    jsonb_build_object('before', v_before, 'after', p));

  RETURN (SELECT to_jsonb(g) FROM public.hotel_groups g WHERE g.id = p_group);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_delete_group(p_group uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_name text; v_hotel_count int;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  SELECT name INTO v_name FROM public.hotel_groups WHERE id = p_group;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'GROUPE_INTROUVABLE';
  END IF;

  SELECT count(*) INTO v_hotel_count FROM public.hotels WHERE group_id = p_group;
  IF v_hotel_count > 0 THEN
    RAISE EXCEPTION 'GROUPE_NON_VIDE : détachez d''abord les % hôtel(s) rattaché(s)', v_hotel_count;
  END IF;

  UPDATE public.hotel_groups SET status = 'archived' WHERE id = p_group;

  PERFORM public._platform_log('group.archive', 'hotel_group', p_group::text, NULL, v_name, '{}'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_attach_hotel_to_group(p_hotel uuid, p_group uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_hotel_name text;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.hotel_groups WHERE id = p_group) THEN
    RAISE EXCEPTION 'GROUPE_INTROUVABLE';
  END IF;

  UPDATE public.hotels SET group_id = p_group WHERE id = p_hotel RETURNING name INTO v_hotel_name;
  IF v_hotel_name IS NULL THEN
    RAISE EXCEPTION 'HOTEL_INTROUVABLE';
  END IF;

  PERFORM public._platform_log('group.attach_hotel', 'hotel', p_hotel::text, p_hotel, v_hotel_name,
    jsonb_build_object('group_id', p_group));
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_detach_hotel_from_group(p_hotel uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_hotel_name text; v_prev_group uuid;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  SELECT name, group_id INTO v_hotel_name, v_prev_group FROM public.hotels WHERE id = p_hotel;
  IF v_hotel_name IS NULL THEN
    RAISE EXCEPTION 'HOTEL_INTROUVABLE';
  END IF;

  UPDATE public.hotels SET group_id = NULL WHERE id = p_hotel;

  PERFORM public._platform_log('group.detach_hotel', 'hotel', p_hotel::text, p_hotel, v_hotel_name,
    jsonb_build_object('previous_group_id', v_prev_group));
END;
$function$;

-- ============================================================================
-- 6. RPC — Utilisateurs : réconciliation des comptes auth.users orphelins
-- ============================================================================

CREATE OR REPLACE FUNCTION public.admin_list_unlinked_auth_users()
RETURNS TABLE(auth_id uuid, email text, created_at timestamptz, last_sign_in_at timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  SELECT au.id, au.email, au.created_at, au.last_sign_in_at
  FROM auth.users au
  WHERE public.is_platform_admin()
    AND NOT EXISTS (SELECT 1 FROM public.users u WHERE u.auth_id = au.id)
  ORDER BY au.last_sign_in_at DESC NULLS LAST;
$function$;

-- ============================================================================
-- 7. RPC — Dashboard KPIs
-- ============================================================================

CREATE OR REPLACE FUNCTION public.platform_dashboard_kpis()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  SELECT jsonb_build_object(
    'hotels', jsonb_build_object(
      'total',     (SELECT count(*) FROM public.hotels),
      'active',    (SELECT count(*) FROM public.hotels WHERE status = 'active'),
      'suspended', (SELECT count(*) FROM public.hotels WHERE status = 'suspended'),
      'draft',     (SELECT count(*) FROM public.hotels WHERE status = 'draft'),
      'archived',  (SELECT count(*) FROM public.hotels WHERE status = 'archived'),
      'in_trial',  (SELECT count(DISTINCT hotel_id) FROM public.hotel_subscriptions WHERE status = 'trial')
    ),
    'groups', jsonb_build_object(
      'total', (SELECT count(*) FROM public.hotel_groups WHERE status <> 'archived')
    ),
    'users', jsonb_build_object(
      'total',  (SELECT count(*) FROM public.users),
      'active', (SELECT count(*) FROM public.users WHERE is_active),
      'unlinked_auth_accounts', (SELECT count(*) FROM public.admin_list_unlinked_auth_users())
    ),
    'subscriptions', jsonb_build_object(
      'total',   (SELECT count(*) FROM public.hotel_subscriptions),
      'active',  (SELECT count(*) FROM public.hotel_subscriptions WHERE status = 'active'),
      'trial',   (SELECT count(*) FROM public.hotel_subscriptions WHERE status = 'trial'),
      'cancelled', (SELECT count(*) FROM public.hotel_subscriptions WHERE status = 'cancelled'),
      'expiring_30d', (SELECT count(*) FROM public.hotel_subscriptions
                        WHERE status IN ('trial','active')
                          AND coalesce(trial_ends_at, expires_at) BETWEEN now() AND now() + interval '30 days')
    ),
    'mrr_estimate', coalesce((
      SELECT sum(
        CASE
          WHEN hs.custom_price IS NOT NULL THEN hs.custom_price
          WHEN hs.billing_cycle = 'annual' THEN sp.price_annual / 12
          ELSE sp.price_monthly
        END
      )
      FROM public.hotel_subscriptions hs
      LEFT JOIN public.subscription_plans sp ON sp.id = hs.plan_id
      WHERE hs.status = 'active'
    ), 0),
    'generated_at', now()
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

-- ============================================================================
-- 8. Correctif ciblé — org_set_hotel_status acceptait 'maintenance', valeur absente
--    de la contrainte hotels_status_check (draft|active|suspended|archived) : tout
--    appel avec cette valeur échouait déjà systématiquement. On aligne la liste
--    acceptée sur la contrainte réelle (comportement self-service inchangé sinon).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.org_set_hotel_status(p_hotel uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_gid uuid;
BEGIN
  SELECT group_id INTO v_gid FROM hotels WHERE id IN (SELECT public.pl_my_hotels()) AND group_id IS NOT NULL LIMIT 1;
  IF v_gid IS NULL OR NOT EXISTS(SELECT 1 FROM hotels WHERE id=p_hotel AND group_id=v_gid) THEN RAISE EXCEPTION 'NON_AUTORISE'; END IF;
  IF p_status NOT IN ('active','suspended') THEN RAISE EXCEPTION 'STATUT_INVALIDE'; END IF;
  UPDATE hotels SET status=p_status, active=(p_status='active') WHERE id=p_hotel;
  RETURN public.org_get();
END $function$;

-- ============================================================================
-- 9. Nettoyage de données — ligne invoice_sequences corrompue (year = -2026)
-- ============================================================================
-- Deux lignes existent pour le même hôtel : (year=2026, last_seq=4) et (year=-2026, last_seq=7).
-- La numérotation de facture ne doit jamais reculer ni être réutilisée (conformité) : on
-- conserve le compteur le plus haut sous l'année correcte, puis on supprime la ligne corrompue.

UPDATE public.invoice_sequences a
SET last_seq = GREATEST(a.last_seq, b.last_seq)
FROM public.invoice_sequences b
WHERE a.hotel_id = b.hotel_id AND a.year = 2026 AND b.year = -2026;

DELETE FROM public.invoice_sequences WHERE year = -2026;

-- ============================================================================
-- 10. Grants — cohérent avec le motif déjà en place pour les autres RPC admin_*
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.admin_create_hotel(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_hotel(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_hotel_status(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_group(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_group(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_group(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_attach_hotel_to_group(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_detach_hotel_from_group(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_unlinked_auth_users() TO authenticated;
GRANT EXECUTE ON FUNCTION public.platform_dashboard_kpis() TO authenticated;
