-- Tests pour sql/76_super_admin_phase2f_lot5_dashboard_audit_settings_supervision.sql
-- Couvre aussi les réserves du Lot 4 (paid_at, financial_state, garde d'annulation).
-- Exécuté à l'intérieur d'un BEGIN...ROLLBACK (jamais committé). Helpers pg_temp zz7_.

BEGIN;

CREATE TEMP TABLE zz7_results(test_no int, name text, status text, detail text);
CREATE OR REPLACE FUNCTION pg_temp.zz7_log(p_no int, p_name text, p_status text, p_detail text) RETURNS void AS $$
BEGIN INSERT INTO zz7_results VALUES (p_no, p_name, p_status, p_detail); END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz7_mk_hotel() RETURNS uuid AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.hotels (id, name, status, hotel_code)
  VALUES (gen_random_uuid(), 'ZZ7 Hotel '||substr(gen_random_uuid()::text,1,6), 'active', upper(substr(gen_random_uuid()::text,1,5)))
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz7_mk_admin() RETURNS uuid AS $$
DECLARE v_auth uuid;
BEGIN
  INSERT INTO auth.users(id) VALUES (gen_random_uuid()) RETURNING id INTO v_auth;
  INSERT INTO public.platform_admins (auth_id, email, role, is_active)
  VALUES (v_auth, 'zz7admin-'||v_auth::text||'@example.invalid', 'super_admin', true);
  RETURN v_auth;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz7_mk_nonadmin() RETURNS uuid AS $$
DECLARE v_auth uuid;
BEGIN
  INSERT INTO auth.users(id) VALUES (gen_random_uuid()) RETURNING id INTO v_auth;
  RETURN v_auth;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz7_as(p_auth uuid) RETURNS void AS $$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_auth)::text, true);
$$ LANGUAGE sql;

-- ============================================================================
-- Réserve Lot 4 : sémantique de paid_at
-- ============================================================================

-- Test 1 : un paiement partiel laisse paid_at à NULL
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_row public.platform_invoices;
BEGIN
  v_admin := pg_temp.zz7_mk_admin(); v_hotel := pg_temp.zz7_mk_hotel();
  PERFORM pg_temp.zz7_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE+30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  PERFORM public.admin_record_platform_payment(v_inv, 50, 'card', NULL, 'recorded', NULL);
  SELECT * INTO v_row FROM public.platform_invoices WHERE id = v_inv;
  IF v_row.paid_amount = 50 AND v_row.paid_at IS NULL THEN
    PERFORM pg_temp.zz7_log(1, 'Paiement partiel laisse paid_at a NULL', 'PASS', 'paid_amount=50, paid_at NULL');
  ELSE
    PERFORM pg_temp.zz7_log(1, 'Paiement partiel laisse paid_at a NULL', 'FAIL', to_jsonb(v_row)::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(1, 'Paiement partiel laisse paid_at a NULL', 'FAIL', SQLERRM);
END $$;

-- Test 2 : paiement confirme couvrant la totalite (brute) remplit paid_at
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_row public.platform_invoices;
BEGIN
  v_admin := pg_temp.zz7_mk_admin(); v_hotel := pg_temp.zz7_mk_hotel();
  PERFORM pg_temp.zz7_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE+30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  PERFORM public.admin_record_platform_payment(v_inv, 120, 'card', NULL, 'recorded', NULL);
  SELECT * INTO v_row FROM public.platform_invoices WHERE id = v_inv;
  IF v_row.paid_at IS NOT NULL THEN
    PERFORM pg_temp.zz7_log(2, 'Paiement total remplit paid_at', 'PASS', 'paid_at renseigne');
  ELSE
    PERFORM pg_temp.zz7_log(2, 'Paiement total remplit paid_at', 'FAIL', 'paid_at NULL');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(2, 'Paiement total remplit paid_at', 'FAIL', SQLERRM);
END $$;

-- Test 3 : double confirmation idempotente (paiement pending confirme deux fois)
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_pay uuid; v_row public.platform_invoices;
BEGIN
  v_admin := pg_temp.zz7_mk_admin(); v_hotel := pg_temp.zz7_mk_hotel();
  PERFORM pg_temp.zz7_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE+30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  v_pay := public.admin_record_platform_payment(v_inv, 120, 'card', NULL, 'pending', NULL);
  PERFORM public.admin_update_platform_payment_status(v_pay, 'recorded');
  PERFORM public.admin_update_platform_payment_status(v_pay, 'recorded'); -- reconfirmation
  SELECT * INTO v_row FROM public.platform_invoices WHERE id = v_inv;
  IF v_row.paid_amount = 120 THEN
    PERFORM pg_temp.zz7_log(3, 'Double confirmation idempotente (pas de double comptage)', 'PASS', format('paid_amount=%s', v_row.paid_amount));
  ELSE
    PERFORM pg_temp.zz7_log(3, 'Double confirmation idempotente (pas de double comptage)', 'FAIL', format('paid_amount=%s (attendu 120)', v_row.paid_amount));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(3, 'Double confirmation idempotente (pas de double comptage)', 'FAIL', SQLERRM);
END $$;

-- Test 4 : surpaiement refuse explicitement
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_failed boolean := false;
BEGIN
  v_admin := pg_temp.zz7_mk_admin(); v_hotel := pg_temp.zz7_mk_hotel();
  PERFORM pg_temp.zz7_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE+30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  BEGIN
    PERFORM public.admin_record_platform_payment(v_inv, 500, 'card', NULL, 'recorded', NULL);
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz7_log(4, 'Surpaiement refuse explicitement', 'PASS', 'exception levee');
  ELSE
    PERFORM pg_temp.zz7_log(4, 'Surpaiement refuse explicitement', 'FAIL', 'aucune exception');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(4, 'Surpaiement refuse explicitement', 'FAIL', SQLERRM);
END $$;

-- Test 5 : avoir partiel -> financial_state partially_paid, pas paid_at
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_row record;
BEGIN
  v_admin := pg_temp.zz7_mk_admin(); v_hotel := pg_temp.zz7_mk_hotel();
  PERFORM pg_temp.zz7_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE+30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  PERFORM public.admin_create_platform_credit_note(v_inv, 30, 6, 'geste partiel');
  SELECT * INTO v_row FROM public.admin_list_platform_invoices() WHERE id = v_inv;
  IF v_row.financial_state = 'partially_paid' AND v_row.balance = 84 THEN
    PERFORM pg_temp.zz7_log(5, 'Avoir partiel : financial_state partially_paid, solde correct', 'PASS', format('state=%s balance=%s', v_row.financial_state, v_row.balance));
  ELSE
    PERFORM pg_temp.zz7_log(5, 'Avoir partiel : financial_state partially_paid, solde correct', 'FAIL', format('state=%s balance=%s', v_row.financial_state, v_row.balance));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(5, 'Avoir partiel : financial_state partially_paid, solde correct', 'FAIL', SQLERRM);
END $$;

-- Test 6 : avoir total (ramene le solde a zero) -> fully_credited, jamais assimile a un paiement
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_row record;
BEGIN
  v_admin := pg_temp.zz7_mk_admin(); v_hotel := pg_temp.zz7_mk_hotel();
  PERFORM pg_temp.zz7_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE+30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  PERFORM public.admin_create_platform_credit_note(v_inv, 100, 20, 'annulation totale');
  SELECT * INTO v_row FROM public.admin_list_platform_invoices() WHERE id = v_inv;
  IF v_row.financial_state = 'fully_credited' AND v_row.balance = 0 THEN
    PERFORM pg_temp.zz7_log(6, 'Avoir total : fully_credited, jamais assimile a paid', 'PASS', format('state=%s', v_row.financial_state));
  ELSE
    PERFORM pg_temp.zz7_log(6, 'Avoir total : fully_credited, jamais assimile a paid', 'FAIL', format('state=%s balance=%s', v_row.financial_state, v_row.balance));
  END IF;
  -- paid_at doit rester NULL (aucun argent reel recu)
  PERFORM 1 FROM public.platform_invoices WHERE id = v_inv AND paid_at IS NULL;
  IF FOUND THEN
    PERFORM pg_temp.zz7_log(60, 'Avoir total seul : paid_at reste NULL', 'PASS', 'confirme');
  ELSE
    PERFORM pg_temp.zz7_log(60, 'Avoir total seul : paid_at reste NULL', 'FAIL', 'paid_at a ete rempli a tort');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(6, 'Avoir total : fully_credited, jamais assimile a paid', 'FAIL', SQLERRM);
END $$;

-- Test 7 : annulation d'un avoir recalcule correctement le solde
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_cn uuid; v_row record;
BEGIN
  v_admin := pg_temp.zz7_mk_admin(); v_hotel := pg_temp.zz7_mk_hotel();
  PERFORM pg_temp.zz7_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE+30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  v_cn := public.admin_create_platform_credit_note(v_inv, 100, 20, 'test');
  PERFORM public.admin_void_platform_credit_note(v_cn, 'erreur');
  SELECT * INTO v_row FROM public.admin_list_platform_invoices() WHERE id = v_inv;
  IF v_row.balance = 120 AND v_row.financial_state = 'unpaid' THEN
    PERFORM pg_temp.zz7_log(7, 'Annulation d''avoir recalcule le solde', 'PASS', format('balance=%s state=%s', v_row.balance, v_row.financial_state));
  ELSE
    PERFORM pg_temp.zz7_log(7, 'Annulation d''avoir recalcule le solde', 'FAIL', format('balance=%s state=%s', v_row.balance, v_row.financial_state));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(7, 'Annulation d''avoir recalcule le solde', 'FAIL', SQLERRM);
END $$;

-- Test 8 : renversement d'un paiement recalcule paid_at (le vide si necessaire) et paid_amount
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_pay uuid; v_row public.platform_invoices;
BEGIN
  v_admin := pg_temp.zz7_mk_admin(); v_hotel := pg_temp.zz7_mk_hotel();
  PERFORM pg_temp.zz7_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE+30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  v_pay := public.admin_record_platform_payment(v_inv, 120, 'card', NULL, 'recorded', NULL);
  SELECT * INTO v_row FROM public.platform_invoices WHERE id = v_inv;
  IF v_row.paid_at IS NULL THEN
    PERFORM pg_temp.zz7_log(8, 'Renversement de paiement recalcule paid_at', 'FAIL', 'paid_at pas rempli avant renversement (test invalide)');
  ELSE
    PERFORM public.admin_reverse_platform_payment(v_pay, 'cheque rejete');
    SELECT * INTO v_row FROM public.platform_invoices WHERE id = v_inv;
    IF v_row.paid_amount = 0 AND v_row.paid_at IS NULL THEN
      PERFORM pg_temp.zz7_log(8, 'Renversement de paiement recalcule paid_at', 'PASS', 'paid_amount=0, paid_at NULL apres renversement');
    ELSE
      PERFORM pg_temp.zz7_log(8, 'Renversement de paiement recalcule paid_at', 'FAIL', to_jsonb(v_row)::text);
    END IF;
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(8, 'Renversement de paiement recalcule paid_at', 'FAIL', SQLERRM);
END $$;

-- Test 9 : annulation interdite si un avoir a deja ete emis (meme sans paiement)
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_failed boolean := false;
BEGIN
  v_admin := pg_temp.zz7_mk_admin(); v_hotel := pg_temp.zz7_mk_hotel();
  PERFORM pg_temp.zz7_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE+30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  PERFORM public.admin_create_platform_credit_note(v_inv, 20, 4, 'partiel');
  BEGIN
    PERFORM public.admin_cancel_platform_invoice(v_inv, 'tentative annulation');
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz7_log(9, 'Annulation interdite si avoir deja emis', 'PASS', 'exception levee comme attendu');
  ELSE
    PERFORM pg_temp.zz7_log(9, 'Annulation interdite si avoir deja emis', 'FAIL', 'aucune exception');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(9, 'Annulation interdite si avoir deja emis', 'FAIL', SQLERRM);
END $$;

-- ============================================================================
-- Lot 5 : dashboard, alertes, audit, parametres, ACL
-- ============================================================================

-- Test 10 : agregats hotels/abonnements coherents (essai expirant sous 7 jours detecte)
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_plan uuid; v_sub uuid; v_kpis jsonb; v_before int;
BEGIN
  v_admin := pg_temp.zz7_mk_admin(); v_hotel := pg_temp.zz7_mk_hotel();
  INSERT INTO public.subscription_plans (id, name, slug, price_monthly, is_active, sort_order)
  VALUES (gen_random_uuid(), 'ZZ7 Plan', 'zz7-plan-'||substr(gen_random_uuid()::text,1,8), 49, true, 999) RETURNING id INTO v_plan;
  INSERT INTO public.hotel_subscriptions (id, hotel_id, plan_id, status, billing_cycle, trial_ends_at)
  VALUES (gen_random_uuid(), v_hotel, v_plan, 'trial', 'monthly', now() + interval '3 days') RETURNING id INTO v_sub;
  PERFORM pg_temp.zz7_as(v_admin);
  v_kpis := public.admin_platform_overview_kpis('this_month', NULL, NULL);
  IF (v_kpis->'subscriptions'->>'trial_expiring_7d')::int >= 1 AND (v_kpis->'hotels'->>'total')::int >= 1 THEN
    PERFORM pg_temp.zz7_log(10, 'KPIs hotels/abonnements : essai expirant sous 7j detecte', 'PASS', v_kpis->'subscriptions'->>'trial_expiring_7d');
  ELSE
    PERFORM pg_temp.zz7_log(10, 'KPIs hotels/abonnements : essai expirant sous 7j detecte', 'FAIL', v_kpis::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(10, 'KPIs hotels/abonnements : essai expirant sous 7j detecte', 'FAIL', SQLERRM);
END $$;

-- Test 11 : KPIs abonnement sans plan coherent detecte
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_kpis jsonb; v_before int;
BEGIN
  v_admin := pg_temp.zz7_mk_admin(); v_hotel := pg_temp.zz7_mk_hotel();
  PERFORM pg_temp.zz7_as(v_admin);
  v_before := (public.admin_platform_overview_kpis('this_month', NULL, NULL)->'subscriptions'->>'plan_incoherent')::int;
  INSERT INTO public.hotel_subscriptions (id, hotel_id, plan_id, status, billing_cycle)
  VALUES (gen_random_uuid(), v_hotel, NULL, 'active', 'monthly');
  IF (public.admin_platform_overview_kpis('this_month', NULL, NULL)->'subscriptions'->>'plan_incoherent')::int = v_before + 1 THEN
    PERFORM pg_temp.zz7_log(11, 'KPIs : abonnement sans plan detecte comme incoherent', 'PASS', 'compteur incremente de 1');
  ELSE
    PERFORM pg_temp.zz7_log(11, 'KPIs : abonnement sans plan detecte comme incoherent', 'FAIL', format('avant=%s', v_before));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(11, 'KPIs : abonnement sans plan detecte comme incoherent', 'FAIL', SQLERRM);
END $$;

-- Test 12 : KPIs facturation periode (facture emise ce mois comptee)
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_before numeric; v_after numeric;
BEGIN
  v_admin := pg_temp.zz7_mk_admin(); v_hotel := pg_temp.zz7_mk_hotel();
  PERFORM pg_temp.zz7_as(v_admin);
  v_before := (public.admin_platform_overview_kpis('this_month', NULL, NULL)->'billing'->>'period_billed_ttc')::numeric;
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE+30, 300, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  v_after := (public.admin_platform_overview_kpis('this_month', NULL, NULL)->'billing'->>'period_billed_ttc')::numeric;
  IF v_after >= v_before + 360 THEN
    PERFORM pg_temp.zz7_log(12, 'KPIs facturation : facture emise ce mois comptee', 'PASS', format('avant=%s apres=%s', v_before, v_after));
  ELSE
    PERFORM pg_temp.zz7_log(12, 'KPIs facturation : facture emise ce mois comptee', 'FAIL', format('avant=%s apres=%s', v_before, v_after));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(12, 'KPIs facturation : facture emise ce mois comptee', 'FAIL', SQLERRM);
END $$;

-- Test 13 : KPIs utilisateurs sans acces + hotels sans administrateur
-- Note : trg_grant_superadmin_on_new_hotel (trigger de production preexistant) accorde
-- automatiquement un role 'direction' au super admin actif sur toute nouvelle creation de
-- hotel -- on retire cette ligne pour reellement tester le cas "aucun administrateur"
-- (meme correctif que le Test 14).
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_auth uuid; v_kpis jsonb;
BEGIN
  v_admin := pg_temp.zz7_mk_admin(); v_hotel := pg_temp.zz7_mk_hotel();
  DELETE FROM public.user_hotels WHERE hotel_id = v_hotel;
  INSERT INTO auth.users(id) VALUES (gen_random_uuid()) RETURNING id INTO v_auth;
  INSERT INTO public.users (auth_id, hotel_id, email, full_name, role, is_active)
  VALUES (v_auth, v_hotel, 'zz7-noaccess-'||v_auth::text||'@example.invalid', 'ZZ7 NoAccess', 'reception', true);
  PERFORM pg_temp.zz7_as(v_admin);
  v_kpis := public.admin_platform_overview_kpis('this_month', NULL, NULL);
  IF (v_kpis->'users_detail'->>'without_access')::int >= 1 AND (v_kpis->'users_detail'->>'hotels_without_admin')::int >= 1 THEN
    PERFORM pg_temp.zz7_log(13, 'KPIs : utilisateur sans acces + hotel sans admin detectes', 'PASS', (v_kpis->'users_detail')::text);
  ELSE
    PERFORM pg_temp.zz7_log(13, 'KPIs : utilisateur sans acces + hotel sans admin detectes', 'FAIL', (v_kpis->'users_detail')::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(13, 'KPIs : utilisateur sans acces + hotel sans admin detectes', 'FAIL', SQLERRM);
END $$;

-- Test 14 : alerte hotel_without_admin presente
-- Note : trg_grant_superadmin_on_new_hotel (trigger de production preexistant) accorde
-- automatiquement un role 'direction' au super admin actif sur toute nouvelle creation de
-- hotel -- on retire cette ligne pour reellement tester le cas "aucun administrateur".
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_found boolean;
BEGIN
  v_admin := pg_temp.zz7_mk_admin(); v_hotel := pg_temp.zz7_mk_hotel();
  DELETE FROM public.user_hotels WHERE hotel_id = v_hotel;
  PERFORM pg_temp.zz7_as(v_admin);
  SELECT EXISTS(SELECT 1 FROM public.admin_platform_alerts() WHERE alert_type='hotel_without_admin' AND hotel_id=v_hotel) INTO v_found;
  IF v_found THEN
    PERFORM pg_temp.zz7_log(14, 'Alerte hotel sans administrateur presente', 'PASS', 'trouvee');
  ELSE
    PERFORM pg_temp.zz7_log(14, 'Alerte hotel sans administrateur presente', 'FAIL', 'absente');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(14, 'Alerte hotel sans administrateur presente', 'FAIL', SQLERRM);
END $$;

-- Test 15 : alerte facture en retard presente et pointe vers la bonne facture
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_found boolean;
BEGIN
  v_admin := pg_temp.zz7_mk_admin(); v_hotel := pg_temp.zz7_mk_hotel();
  PERFORM pg_temp.zz7_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE+30, 100, 20, CURRENT_DATE - 5, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  SELECT EXISTS(SELECT 1 FROM public.admin_platform_alerts() WHERE alert_type='invoice_overdue' AND entity_id=v_inv::text) INTO v_found;
  IF v_found THEN
    PERFORM pg_temp.zz7_log(15, 'Alerte facture en retard pointe vers la bonne facture', 'PASS', 'trouvee');
  ELSE
    PERFORM pg_temp.zz7_log(15, 'Alerte facture en retard pointe vers la bonne facture', 'FAIL', 'absente');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(15, 'Alerte facture en retard pointe vers la bonne facture', 'FAIL', SQLERRM);
END $$;

-- Test 16 : journal d'audit filtre + pagine (total_count coherent)
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_rows int; v_total bigint;
BEGIN
  v_admin := pg_temp.zz7_mk_admin(); v_hotel := pg_temp.zz7_mk_hotel();
  PERFORM pg_temp.zz7_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE+30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  SELECT count(*), max(total_count) INTO v_rows, v_total
  FROM public.admin_list_platform_audit_log(NULL, NULL, v_hotel, NULL, 'platform_invoice', NULL, NULL, NULL, NULL, 50, 0);
  IF v_rows = 2 AND v_total = 2 THEN -- create_proforma + issue
    PERFORM pg_temp.zz7_log(16, 'Audit filtre par hotel+entite, total_count coherent', 'PASS', format('rows=%s total=%s', v_rows, v_total));
  ELSE
    PERFORM pg_temp.zz7_log(16, 'Audit filtre par hotel+entite, total_count coherent', 'FAIL', format('rows=%s total=%s', v_rows, v_total));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(16, 'Audit filtre par hotel+entite, total_count coherent', 'FAIL', SQLERRM);
END $$;

-- Test 17 : mise a jour d'un parametre valide + audite
DO $$
DECLARE v_admin uuid; v_before jsonb; v_after jsonb; v_hist_found boolean;
BEGIN
  v_admin := pg_temp.zz7_mk_admin();
  PERFORM pg_temp.zz7_as(v_admin);
  SELECT value INTO v_before FROM public.platform_settings WHERE key='support_email';
  PERFORM public.admin_update_platform_setting('support_email', '"nouveau-support@flowtym.com"'::jsonb, 'test');
  SELECT value INTO v_after FROM public.platform_settings WHERE key='support_email';
  SELECT EXISTS(SELECT 1 FROM public.platform_logs WHERE action='setting.update' AND entity_id='support_email') INTO v_hist_found;
  IF v_after = '"nouveau-support@flowtym.com"'::jsonb AND v_hist_found THEN
    PERFORM pg_temp.zz7_log(17, 'Mise a jour parametre valide + auditee', 'PASS', v_after::text);
  ELSE
    PERFORM pg_temp.zz7_log(17, 'Mise a jour parametre valide + auditee', 'FAIL', format('after=%s audit=%s', v_after, v_hist_found));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(17, 'Mise a jour parametre valide + auditee', 'FAIL', SQLERRM);
END $$;

-- Test 18 : parametre inconnu refuse (jamais de cle inventee)
DO $$
DECLARE v_admin uuid; v_failed boolean := false;
BEGIN
  v_admin := pg_temp.zz7_mk_admin();
  PERFORM pg_temp.zz7_as(v_admin);
  BEGIN
    PERFORM public.admin_update_platform_setting('cle_inexistante_zz7', '"x"'::jsonb, NULL);
  EXCEPTION WHEN OTHERS THEN v_failed := SQLSTATE = 'P0002';
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz7_log(18, 'Parametre inconnu refuse', 'PASS', 'errcode P0002 confirme');
  ELSE
    PERFORM pg_temp.zz7_log(18, 'Parametre inconnu refuse', 'FAIL', 'aucune exception P0002');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(18, 'Parametre inconnu refuse', 'FAIL', SQLERRM);
END $$;

-- Test 19 : type de valeur invalide refuse (nombre attendu, chaine fournie)
DO $$
DECLARE v_admin uuid; v_failed boolean := false;
BEGIN
  v_admin := pg_temp.zz7_mk_admin();
  PERFORM pg_temp.zz7_as(v_admin);
  BEGIN
    PERFORM public.admin_update_platform_setting('mrr_target', '"pas-un-nombre"'::jsonb, NULL);
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz7_log(19, 'Type de valeur invalide refuse', 'PASS', 'exception levee');
  ELSE
    PERFORM pg_temp.zz7_log(19, 'Type de valeur invalide refuse', 'FAIL', 'aucune exception');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(19, 'Type de valeur invalide refuse', 'FAIL', SQLERRM);
END $$;

-- Test 20 : utilisateur non-admin refuse sur toutes les nouvelles RPC de lecture/ecriture
-- (chaque sous-verification part de "non refuse" par defaut : un appel qui reussirait SANS
-- exception doit etre detecte comme un echec, pas silencieusement ignore)
DO $$
DECLARE v_plain uuid; v_fail text := ''; v_refused boolean;
BEGIN
  v_plain := pg_temp.zz7_mk_nonadmin();
  PERFORM pg_temp.zz7_as(v_plain);

  v_refused := false;
  BEGIN PERFORM public.admin_platform_overview_kpis('this_month', NULL, NULL);
  EXCEPTION WHEN OTHERS THEN v_refused := SQLSTATE = '42501';
  END;
  IF NOT v_refused THEN v_fail := v_fail || 'overview_kpis '; END IF;

  v_refused := false;
  BEGIN PERFORM public.admin_platform_alerts();
  EXCEPTION WHEN OTHERS THEN v_refused := SQLSTATE = '42501';
  END;
  IF NOT v_refused THEN v_fail := v_fail || 'alerts '; END IF;

  v_refused := false;
  BEGIN PERFORM public.admin_list_platform_audit_log(NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,50,0);
  EXCEPTION WHEN OTHERS THEN v_refused := SQLSTATE = '42501';
  END;
  IF NOT v_refused THEN v_fail := v_fail || 'audit_log '; END IF;

  v_refused := false;
  BEGIN PERFORM public.admin_update_platform_setting('support_email', '"x@x.com"'::jsonb, NULL);
  EXCEPTION WHEN OTHERS THEN v_refused := SQLSTATE = '42501';
  END;
  IF NOT v_refused THEN v_fail := v_fail || 'update_setting '; END IF;

  v_refused := false;
  BEGIN PERFORM public.admin_supervision_status();
  EXCEPTION WHEN OTHERS THEN v_refused := SQLSTATE = '42501';
  END;
  IF NOT v_refused THEN v_fail := v_fail || 'supervision '; END IF;

  IF v_fail = '' THEN
    PERFORM pg_temp.zz7_log(20, 'Non-admin refuse (42501) sur toutes les nouvelles RPC', 'PASS', 'conforme');
  ELSE
    PERFORM pg_temp.zz7_log(20, 'Non-admin refuse (42501) sur toutes les nouvelles RPC', 'FAIL', v_fail);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(20, 'Non-admin refuse (42501) sur toutes les nouvelles RPC', 'FAIL', SQLERRM);
END $$;

-- Test 21 : ACL fonctions fermees anon/service_role, ouvertes authenticated
DO $$
DECLARE v_fail text := '';
BEGIN
  IF has_function_privilege('anon', 'public.admin_platform_overview_kpis(text,date,date)', 'EXECUTE') THEN v_fail := v_fail || 'anon_overview '; END IF;
  IF has_function_privilege('service_role', 'public.admin_platform_alerts()', 'EXECUTE') THEN v_fail := v_fail || 'service_role_alerts '; END IF;
  IF NOT has_function_privilege('authenticated', 'public.admin_list_platform_audit_log(text,text,uuid,uuid,text,text,text,timestamptz,timestamptz,int,int)', 'EXECUTE') THEN v_fail := v_fail || 'authenticated_audit_missing '; END IF;
  IF has_function_privilege('anon', 'public._recompute_invoice_paid_at(uuid)', 'EXECUTE') THEN v_fail := v_fail || 'anon_internal_helper '; END IF;
  IF has_function_privilege('authenticated', 'public._recompute_invoice_paid_at(uuid)', 'EXECUTE') THEN v_fail := v_fail || 'authenticated_internal_helper '; END IF;
  IF v_fail = '' THEN
    PERFORM pg_temp.zz7_log(21, 'ACL : fonctions Lot 5 fermees anon/service_role, ouvertes authenticated, helper interne ferme partout', 'PASS', 'conforme');
  ELSE
    PERFORM pg_temp.zz7_log(21, 'ACL : fonctions Lot 5 fermees anon/service_role, ouvertes authenticated, helper interne ferme partout', 'FAIL', v_fail);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(21, 'ACL : fonctions Lot 5 fermees anon/service_role, ouvertes authenticated, helper interne ferme partout', 'FAIL', SQLERRM);
END $$;

-- Test 22 : ACL tables platform_settings/platform_logs fermees a anon
DO $$
DECLARE v_fail text := '';
BEGIN
  IF has_table_privilege('anon', 'public.platform_settings', 'UPDATE') THEN v_fail := v_fail || 'platform_settings '; END IF;
  IF has_table_privilege('anon', 'public.platform_logs', 'INSERT') THEN v_fail := v_fail || 'platform_logs '; END IF;
  IF v_fail = '' THEN
    PERFORM pg_temp.zz7_log(22, 'ACL tables : anon sans privilege DML sur platform_settings/platform_logs', 'PASS', 'conforme');
  ELSE
    PERFORM pg_temp.zz7_log(22, 'ACL tables : anon sans privilege DML sur platform_settings/platform_logs', 'FAIL', v_fail);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(22, 'ACL tables : anon sans privilege DML sur platform_settings/platform_logs', 'FAIL', SQLERRM);
END $$;

-- Test 23 : les RPC de lecture n'ecrivent rien (aucune ligne creee par un simple appel)
DO $$
DECLARE v_admin uuid; v_before_pi int; v_after_pi int; v_before_pl int; v_after_pl int;
BEGIN
  v_admin := pg_temp.zz7_mk_admin();
  PERFORM pg_temp.zz7_as(v_admin);
  SELECT count(*) INTO v_before_pi FROM public.platform_invoices;
  SELECT count(*) INTO v_before_pl FROM public.platform_logs;
  PERFORM public.admin_platform_overview_kpis('this_month', NULL, NULL);
  PERFORM public.admin_platform_alerts();
  PERFORM public.admin_list_platform_audit_log(NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,50,0);
  PERFORM public.admin_supervision_status();
  SELECT count(*) INTO v_after_pi FROM public.platform_invoices;
  SELECT count(*) INTO v_after_pl FROM public.platform_logs;
  IF v_before_pi = v_after_pi AND v_before_pl = v_after_pl THEN
    PERFORM pg_temp.zz7_log(23, 'Aucune ecriture depuis les RPC de lecture', 'PASS', 'compteurs inchanges');
  ELSE
    PERFORM pg_temp.zz7_log(23, 'Aucune ecriture depuis les RPC de lecture', 'FAIL', format('invoices %s->%s logs %s->%s', v_before_pi, v_after_pi, v_before_pl, v_after_pl));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(23, 'Aucune ecriture depuis les RPC de lecture', 'FAIL', SQLERRM);
END $$;

-- Test 24 : supervision honnete (pas de faux badge vert)
DO $$
DECLARE v_admin uuid; v_status jsonb;
BEGIN
  v_admin := pg_temp.zz7_mk_admin();
  PERFORM pg_temp.zz7_as(v_admin);
  v_status := public.admin_supervision_status();
  IF (v_status->>'mutation_error_monitoring_available')::boolean = false
     AND (v_status->>'edge_function_error_monitoring_available')::boolean = false
     AND v_status->>'last_migration_name' IS NOT NULL THEN
    PERFORM pg_temp.zz7_log(24, 'Supervision honnete : signaux non mesures explicitement a false', 'PASS', v_status::text);
  ELSE
    PERFORM pg_temp.zz7_log(24, 'Supervision honnete : signaux non mesures explicitement a false', 'FAIL', v_status::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz7_log(24, 'Supervision honnete : signaux non mesures explicitement a false', 'FAIL', SQLERRM);
END $$;

DO $$
DECLARE v_fail_count int;
BEGIN
  SELECT count(*) INTO v_fail_count FROM zz7_results WHERE status = 'FAIL';
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'ECHEC DE % TEST(S)', v_fail_count;
  END IF;
END $$;

SELECT test_no, name, status, detail FROM zz7_results ORDER BY test_no;

ROLLBACK;
