-- Tests pour sql/75_super_admin_phase2e_lot4_billing.sql
-- Exécuté à l'intérieur d'un BEGIN...ROLLBACK (jamais committé). Helpers pg_temp zz6_.

BEGIN;

CREATE TEMP TABLE zz6_results(test_no int, name text, status text, detail text);
CREATE OR REPLACE FUNCTION pg_temp.zz6_log(p_no int, p_name text, p_status text, p_detail text) RETURNS void AS $$
BEGIN INSERT INTO zz6_results VALUES (p_no, p_name, p_status, p_detail); END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz6_mk_hotel() RETURNS uuid AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.hotels (id, name, status, hotel_code)
  VALUES (gen_random_uuid(), 'ZZ6 Hotel '||substr(gen_random_uuid()::text,1,6), 'active', upper(substr(gen_random_uuid()::text,1,5)))
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz6_mk_admin() RETURNS uuid AS $$
DECLARE v_auth uuid;
BEGIN
  INSERT INTO auth.users(id) VALUES (gen_random_uuid()) RETURNING id INTO v_auth;
  INSERT INTO public.platform_admins (auth_id, email, role, is_active)
  VALUES (v_auth, 'zz6admin-'||v_auth::text||'@example.invalid', 'super_admin', true);
  RETURN v_auth;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz6_mk_nonadmin() RETURNS uuid AS $$
DECLARE v_auth uuid;
BEGIN
  INSERT INTO auth.users(id) VALUES (gen_random_uuid()) RETURNING id INTO v_auth;
  RETURN v_auth;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz6_mk_plan() RETURNS uuid AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.subscription_plans (id, name, slug, price_monthly, is_active, sort_order)
  VALUES (gen_random_uuid(), 'ZZ6 Plan', 'zz6-plan-'||substr(gen_random_uuid()::text,1,8), 49, true, 999)
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz6_mk_subscription(p_hotel uuid, p_plan uuid) RETURNS uuid AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.hotel_subscriptions (id, hotel_id, plan_id, status, billing_cycle)
  VALUES (gen_random_uuid(), p_hotel, p_plan, 'active', 'monthly')
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz6_as(p_auth uuid) RETURNS void AS $$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_auth)::text, true);
$$ LANGUAGE sql;

-- Test 1 : création d'une facture proforma — montants TVA/TTC corrects, statut proforma
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_row public.platform_invoices;
BEGIN
  v_admin := pg_temp.zz6_mk_admin();
  v_hotel := pg_temp.zz6_mk_hotel();
  PERFORM pg_temp.zz6_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE + 30, 100, 20, CURRENT_DATE + 15, 'test');
  SELECT * INTO v_row FROM public.platform_invoices WHERE id = v_inv;
  IF v_row.status = 'proforma' AND v_row.tva_amount = 20 AND v_row.amount_ttc = 120 THEN
    PERFORM pg_temp.zz6_log(1, 'Création facture proforma : montants corrects', 'PASS', format('ttc=%s tva=%s', v_row.amount_ttc, v_row.tva_amount));
  ELSE
    PERFORM pg_temp.zz6_log(1, 'Création facture proforma : montants corrects', 'FAIL', to_jsonb(v_row)::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz6_log(1, 'Création facture proforma : montants corrects', 'FAIL', SQLERRM);
END $$;

-- Test 2 : émission — numéro attribué, issued_at posé, snapshot bill_to_* rempli
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_row public.platform_invoices;
BEGIN
  v_admin := pg_temp.zz6_mk_admin();
  v_hotel := pg_temp.zz6_mk_hotel();
  UPDATE public.hotels SET company = 'ZZ6 SAS', address='1 rue Test', tva_number='FR123' WHERE id = v_hotel;
  PERFORM pg_temp.zz6_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE + 30, 100, 20, CURRENT_DATE + 15, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  SELECT * INTO v_row FROM public.platform_invoices WHERE id = v_inv;
  IF v_row.status = 'issued' AND v_row.number LIKE 'FLOW-%' AND v_row.issued_at IS NOT NULL AND v_row.bill_to_name = 'ZZ6 SAS' THEN
    PERFORM pg_temp.zz6_log(2, 'Émission : numéro + snapshot bill_to corrects', 'PASS', format('number=%s bill_to=%s', v_row.number, v_row.bill_to_name));
  ELSE
    PERFORM pg_temp.zz6_log(2, 'Émission : numéro + snapshot bill_to corrects', 'FAIL', to_jsonb(v_row)::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz6_log(2, 'Émission : numéro + snapshot bill_to corrects', 'FAIL', SQLERRM);
END $$;

-- Test 3 : impossible de ré-émettre une facture déjà émise
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_failed boolean := false;
BEGIN
  v_admin := pg_temp.zz6_mk_admin();
  v_hotel := pg_temp.zz6_mk_hotel();
  PERFORM pg_temp.zz6_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE + 30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  BEGIN
    PERFORM public.admin_issue_platform_invoice(v_inv);
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz6_log(3, 'Impossible de ré-émettre une facture déjà émise', 'PASS', 'exception levée comme attendu');
  ELSE
    PERFORM pg_temp.zz6_log(3, 'Impossible de ré-émettre une facture déjà émise', 'FAIL', 'aucune exception');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz6_log(3, 'Impossible de ré-émettre une facture déjà émise', 'FAIL', SQLERRM);
END $$;

-- Test 4 : paiement enregistré augmente paid_amount, pose paid_at si règlement intégral
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_row public.platform_invoices;
BEGIN
  v_admin := pg_temp.zz6_mk_admin();
  v_hotel := pg_temp.zz6_mk_hotel();
  PERFORM pg_temp.zz6_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE + 30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  PERFORM public.admin_record_platform_payment(v_inv, 120, 'bank_transfer', 'REF1', 'recorded', NULL);
  SELECT * INTO v_row FROM public.platform_invoices WHERE id = v_inv;
  IF v_row.paid_amount = 120 AND v_row.paid_at IS NOT NULL THEN
    PERFORM pg_temp.zz6_log(4, 'Paiement intégral : paid_amount + paid_at corrects', 'PASS', format('paid_amount=%s', v_row.paid_amount));
  ELSE
    PERFORM pg_temp.zz6_log(4, 'Paiement intégral : paid_amount + paid_at corrects', 'FAIL', to_jsonb(v_row)::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz6_log(4, 'Paiement intégral : paid_amount + paid_at corrects', 'FAIL', SQLERRM);
END $$;

-- Test 5 : paiement qui dépasserait le solde est refusé
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_failed boolean := false;
BEGIN
  v_admin := pg_temp.zz6_mk_admin();
  v_hotel := pg_temp.zz6_mk_hotel();
  PERFORM pg_temp.zz6_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE + 30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  BEGIN
    PERFORM public.admin_record_platform_payment(v_inv, 500, 'bank_transfer', NULL, 'recorded', NULL);
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz6_log(5, 'Paiement dépassant le solde refusé', 'PASS', 'exception levée comme attendu');
  ELSE
    PERFORM pg_temp.zz6_log(5, 'Paiement dépassant le solde refusé', 'FAIL', 'aucune exception');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz6_log(5, 'Paiement dépassant le solde refusé', 'FAIL', SQLERRM);
END $$;

-- Test 6 : paiement 'pending' n'augmente pas paid_amount tant qu'il n'est pas confirmé
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_pay uuid; v_row public.platform_invoices;
BEGIN
  v_admin := pg_temp.zz6_mk_admin();
  v_hotel := pg_temp.zz6_mk_hotel();
  PERFORM pg_temp.zz6_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE + 30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  v_pay := public.admin_record_platform_payment(v_inv, 120, 'card', NULL, 'pending', NULL);
  SELECT * INTO v_row FROM public.platform_invoices WHERE id = v_inv;
  IF v_row.paid_amount = 0 THEN
    PERFORM public.admin_update_platform_payment_status(v_pay, 'recorded');
    SELECT * INTO v_row FROM public.platform_invoices WHERE id = v_inv;
    IF v_row.paid_amount = 120 THEN
      PERFORM pg_temp.zz6_log(6, 'Paiement pending puis confirmé : paid_amount mis à jour au bon moment', 'PASS', '0 puis 120');
    ELSE
      PERFORM pg_temp.zz6_log(6, 'Paiement pending puis confirmé : paid_amount mis à jour au bon moment', 'FAIL', format('après confirmation: %s', v_row.paid_amount));
    END IF;
  ELSE
    PERFORM pg_temp.zz6_log(6, 'Paiement pending puis confirmé : paid_amount mis à jour au bon moment', 'FAIL', format('paid_amount déjà %s avant confirmation', v_row.paid_amount));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz6_log(6, 'Paiement pending puis confirmé : paid_amount mis à jour au bon moment', 'FAIL', SQLERRM);
END $$;

-- Test 7 : impossible de payer une facture proforma
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_failed boolean := false;
BEGIN
  v_admin := pg_temp.zz6_mk_admin();
  v_hotel := pg_temp.zz6_mk_hotel();
  PERFORM pg_temp.zz6_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE + 30, 100, 20, NULL, NULL);
  BEGIN
    PERFORM public.admin_record_platform_payment(v_inv, 50, 'card', NULL, 'recorded', NULL);
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz6_log(7, 'Impossible de payer une facture proforma', 'PASS', 'exception levée comme attendu');
  ELSE
    PERFORM pg_temp.zz6_log(7, 'Impossible de payer une facture proforma', 'FAIL', 'aucune exception');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz6_log(7, 'Impossible de payer une facture proforma', 'FAIL', SQLERRM);
END $$;

-- Test 8 : annulation interdite si déjà payée (utiliser un avoir)
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_failed boolean := false;
BEGIN
  v_admin := pg_temp.zz6_mk_admin();
  v_hotel := pg_temp.zz6_mk_hotel();
  PERFORM pg_temp.zz6_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE + 30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  PERFORM public.admin_record_platform_payment(v_inv, 50, 'card', NULL, 'recorded', NULL);
  BEGIN
    PERFORM public.admin_cancel_platform_invoice(v_inv, 'test annulation');
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz6_log(8, 'Annulation interdite si déjà payée', 'PASS', 'exception levée comme attendu');
  ELSE
    PERFORM pg_temp.zz6_log(8, 'Annulation interdite si déjà payée', 'FAIL', 'aucune exception');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz6_log(8, 'Annulation interdite si déjà payée', 'FAIL', SQLERRM);
END $$;

-- Test 9 : annulation d'une proforma réussit
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_status text;
BEGIN
  v_admin := pg_temp.zz6_mk_admin();
  v_hotel := pg_temp.zz6_mk_hotel();
  PERFORM pg_temp.zz6_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE + 30, 100, 20, NULL, NULL);
  PERFORM public.admin_cancel_platform_invoice(v_inv, 'test');
  SELECT status INTO v_status FROM public.platform_invoices WHERE id = v_inv;
  IF v_status = 'cancelled' THEN
    PERFORM pg_temp.zz6_log(9, 'Annulation d''une proforma réussit', 'PASS', 'statut cancelled confirmé');
  ELSE
    PERFORM pg_temp.zz6_log(9, 'Annulation d''une proforma réussit', 'FAIL', format('statut=%s', v_status));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz6_log(9, 'Annulation d''une proforma réussit', 'FAIL', SQLERRM);
END $$;

-- Test 10 : avoir émis réduit le solde affiché sans modifier amount_ttc/paid_amount de la facture
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_cn uuid; v_row record; v_ttc_unchanged numeric;
BEGIN
  v_admin := pg_temp.zz6_mk_admin();
  v_hotel := pg_temp.zz6_mk_hotel();
  PERFORM pg_temp.zz6_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE + 30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  SELECT amount_ttc INTO v_ttc_unchanged FROM public.platform_invoices WHERE id = v_inv;
  v_cn := public.admin_create_platform_credit_note(v_inv, 50, 10, 'geste commercial');
  SELECT * INTO v_row FROM public.admin_list_platform_invoices() WHERE id = v_inv;
  IF v_row.balance = 60 AND v_row.credited_ttc = 60 AND v_ttc_unchanged = 120 THEN
    PERFORM pg_temp.zz6_log(10, 'Avoir : solde recalculé sans altérer la facture', 'PASS', format('balance=%s credited=%s ttc_facture=%s', v_row.balance, v_row.credited_ttc, v_ttc_unchanged));
  ELSE
    PERFORM pg_temp.zz6_log(10, 'Avoir : solde recalculé sans altérer la facture', 'FAIL', format('balance=%s credited=%s ttc_facture=%s', v_row.balance, v_row.credited_ttc, v_ttc_unchanged));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz6_log(10, 'Avoir : solde recalculé sans altérer la facture', 'FAIL', SQLERRM);
END $$;

-- Test 11 : avoir ne peut pas dépasser le montant total de la facture
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_failed boolean := false;
BEGIN
  v_admin := pg_temp.zz6_mk_admin();
  v_hotel := pg_temp.zz6_mk_hotel();
  PERFORM pg_temp.zz6_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE + 30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  BEGIN
    PERFORM public.admin_create_platform_credit_note(v_inv, 500, 0, 'trop');
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz6_log(11, 'Avoir ne peut pas dépasser le montant de la facture', 'PASS', 'exception levée comme attendu');
  ELSE
    PERFORM pg_temp.zz6_log(11, 'Avoir ne peut pas dépasser le montant de la facture', 'FAIL', 'aucune exception');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz6_log(11, 'Avoir ne peut pas dépasser le montant de la facture', 'FAIL', SQLERRM);
END $$;

-- Test 12 : annulation (void) d'un avoir
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_cn uuid; v_status text;
BEGIN
  v_admin := pg_temp.zz6_mk_admin();
  v_hotel := pg_temp.zz6_mk_hotel();
  PERFORM pg_temp.zz6_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE + 30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  v_cn := public.admin_create_platform_credit_note(v_inv, 50, 10, 'test');
  PERFORM public.admin_void_platform_credit_note(v_cn, 'erreur de saisie');
  SELECT status INTO v_status FROM public.platform_credit_notes WHERE id = v_cn;
  IF v_status = 'voided' THEN
    PERFORM pg_temp.zz6_log(12, 'Annulation (void) d''un avoir', 'PASS', 'statut voided confirmé');
  ELSE
    PERFORM pg_temp.zz6_log(12, 'Annulation (void) d''un avoir', 'FAIL', format('statut=%s', v_status));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz6_log(12, 'Annulation (void) d''un avoir', 'FAIL', SQLERRM);
END $$;

-- Test 13 : suspension pour impayé — motif normalisé + détecté par le tableau de bord
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_plan uuid; v_sub uuid; v_inv uuid; v_kpis jsonb; v_before_count int;
BEGIN
  v_admin := pg_temp.zz6_mk_admin();
  v_hotel := pg_temp.zz6_mk_hotel();
  v_plan := pg_temp.zz6_mk_plan();
  v_sub := pg_temp.zz6_mk_subscription(v_hotel, v_plan);
  PERFORM pg_temp.zz6_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, v_sub, CURRENT_DATE, CURRENT_DATE + 30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);

  SELECT COALESCE((public.platform_billing_dashboard_kpis()->>'subscriptions_suspended_nonpayment')::int, 0) INTO v_before_count;
  PERFORM public.admin_suspend_subscription_for_nonpayment(v_sub, v_inv, 'relance sans réponse');
  v_kpis := public.platform_billing_dashboard_kpis();

  IF (v_kpis->>'subscriptions_suspended_nonpayment')::int = v_before_count + 1 THEN
    PERFORM pg_temp.zz6_log(13, 'Suspension pour impayé détectée par le tableau de bord', 'PASS', v_kpis->>'subscriptions_suspended_nonpayment');
  ELSE
    PERFORM pg_temp.zz6_log(13, 'Suspension pour impayé détectée par le tableau de bord', 'FAIL', format('avant=%s après=%s', v_before_count, v_kpis->>'subscriptions_suspended_nonpayment'));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz6_log(13, 'Suspension pour impayé détectée par le tableau de bord', 'FAIL', SQLERRM);
END $$;

-- Test 14 : tableau de bord — agrégats cohérents (facturé/encaissé)
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_kpis jsonb;
BEGIN
  v_admin := pg_temp.zz6_mk_admin();
  v_hotel := pg_temp.zz6_mk_hotel();
  PERFORM pg_temp.zz6_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE + 30, 1000, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  PERFORM public.admin_record_platform_payment(v_inv, 600, 'bank_transfer', NULL, 'recorded', NULL);
  v_kpis := public.platform_billing_dashboard_kpis();
  IF (v_kpis->>'total_billed_ttc')::numeric >= 1200 AND (v_kpis->>'total_collected')::numeric >= 600 THEN
    PERFORM pg_temp.zz6_log(14, 'Dashboard : facturé/encaissé cohérents', 'PASS', format('billed=%s collected=%s', v_kpis->>'total_billed_ttc', v_kpis->>'total_collected'));
  ELSE
    PERFORM pg_temp.zz6_log(14, 'Dashboard : facturé/encaissé cohérents', 'FAIL', v_kpis::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz6_log(14, 'Dashboard : facturé/encaissé cohérents', 'FAIL', SQLERRM);
END $$;

-- Test 15 : ACL — nouvelles RPC fermées à anon/service_role, ouvertes à authenticated
DO $$
DECLARE v_fail text := '';
BEGIN
  IF has_function_privilege('anon', 'public.admin_create_platform_invoice(uuid,uuid,date,date,numeric,numeric,date,text)', 'EXECUTE') THEN v_fail := v_fail || 'anon_create_invoice '; END IF;
  IF has_function_privilege('service_role', 'public.admin_record_platform_payment(uuid,numeric,text,text,text,text)', 'EXECUTE') THEN v_fail := v_fail || 'service_role_record_payment '; END IF;
  IF NOT has_function_privilege('authenticated', 'public.platform_billing_dashboard_kpis()', 'EXECUTE') THEN v_fail := v_fail || 'authenticated_dashboard_missing '; END IF;
  IF has_function_privilege('anon', 'public._next_platform_invoice_number()', 'EXECUTE') THEN v_fail := v_fail || 'anon_internal_helper '; END IF;
  IF has_function_privilege('authenticated', 'public._next_platform_invoice_number()', 'EXECUTE') THEN v_fail := v_fail || 'authenticated_internal_helper '; END IF;
  IF v_fail = '' THEN
    PERFORM pg_temp.zz6_log(15, 'ACL fonctions : anon/service_role fermés, authenticated ouvert, helper interne fermé partout', 'PASS', 'conforme');
  ELSE
    PERFORM pg_temp.zz6_log(15, 'ACL fonctions : anon/service_role fermés, authenticated ouvert, helper interne fermé partout', 'FAIL', v_fail);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz6_log(15, 'ACL fonctions : anon/service_role fermés, authenticated ouvert, helper interne fermé partout', 'FAIL', SQLERRM);
END $$;

-- Test 16 : ACL — tables platform_invoices/platform_contracts/platform_payments/platform_credit_notes fermées à anon
DO $$
DECLARE v_fail text := '';
BEGIN
  IF has_table_privilege('anon', 'public.platform_invoices', 'INSERT') THEN v_fail := v_fail || 'platform_invoices '; END IF;
  IF has_table_privilege('anon', 'public.platform_contracts', 'UPDATE') THEN v_fail := v_fail || 'platform_contracts '; END IF;
  IF has_table_privilege('anon', 'public.platform_payments', 'INSERT') THEN v_fail := v_fail || 'platform_payments '; END IF;
  IF has_table_privilege('anon', 'public.platform_credit_notes', 'INSERT') THEN v_fail := v_fail || 'platform_credit_notes '; END IF;
  IF v_fail = '' THEN
    PERFORM pg_temp.zz6_log(16, 'ACL tables : anon sans privilège DML sur les 4 tables de facturation', 'PASS', 'conforme');
  ELSE
    PERFORM pg_temp.zz6_log(16, 'ACL tables : anon sans privilège DML sur les 4 tables de facturation', 'FAIL', v_fail);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz6_log(16, 'ACL tables : anon sans privilège DML sur les 4 tables de facturation', 'FAIL', SQLERRM);
END $$;

-- Test 17 : appelant non-admin refusé sur la création de facture
DO $$
DECLARE v_plain uuid; v_hotel uuid; v_failed boolean := false;
BEGIN
  v_plain := pg_temp.zz6_mk_nonadmin();
  v_hotel := pg_temp.zz6_mk_hotel();
  PERFORM pg_temp.zz6_as(v_plain);
  BEGIN
    PERFORM public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE + 30, 100, 20, NULL, NULL);
  EXCEPTION WHEN OTHERS THEN v_failed := SQLSTATE = '42501';
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz6_log(17, 'Utilisateur non-admin refusé pour créer une facture', 'PASS', 'errcode 42501 confirmé');
  ELSE
    PERFORM pg_temp.zz6_log(17, 'Utilisateur non-admin refusé pour créer une facture', 'FAIL', 'aucune exception 42501');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz6_log(17, 'Utilisateur non-admin refusé pour créer une facture', 'FAIL', SQLERRM);
END $$;

-- Test 18 : admin_update_hotel_full persiste billing_email (régression + nouveau champ)
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_email text;
BEGIN
  v_admin := pg_temp.zz6_mk_admin();
  v_hotel := pg_temp.zz6_mk_hotel();
  PERFORM pg_temp.zz6_as(v_admin);
  PERFORM public.admin_update_hotel_full(v_hotel, jsonb_build_object('billing_email', 'compta@zz6test.invalid'));
  SELECT billing_email INTO v_email FROM public.hotels WHERE id = v_hotel;
  IF v_email = 'compta@zz6test.invalid' THEN
    PERFORM pg_temp.zz6_log(18, 'admin_update_hotel_full persiste billing_email', 'PASS', v_email);
  ELSE
    PERFORM pg_temp.zz6_log(18, 'admin_update_hotel_full persiste billing_email', 'FAIL', coalesce(v_email, 'NULL'));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz6_log(18, 'admin_update_hotel_full persiste billing_email', 'FAIL', SQLERRM);
END $$;

-- Test 19 : historique de la fiche facture retrace création/émission/paiement
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_inv uuid; v_detail jsonb; v_actions text[];
BEGIN
  v_admin := pg_temp.zz6_mk_admin();
  v_hotel := pg_temp.zz6_mk_hotel();
  PERFORM pg_temp.zz6_as(v_admin);
  v_inv := public.admin_create_platform_invoice(v_hotel, NULL, CURRENT_DATE, CURRENT_DATE + 30, 100, 20, NULL, NULL);
  PERFORM public.admin_issue_platform_invoice(v_inv);
  PERFORM public.admin_record_platform_payment(v_inv, 50, 'card', NULL, 'recorded', NULL);
  v_detail := public.admin_get_platform_invoice_detail(v_inv);
  SELECT array_agg(e->>'action') INTO v_actions FROM jsonb_array_elements(v_detail->'history') e;
  IF 'invoice.create_proforma' = ANY(v_actions) AND 'invoice.issue' = ANY(v_actions) AND 'payment.record' = ANY(v_actions) THEN
    PERFORM pg_temp.zz6_log(19, 'Historique retrace création/émission/paiement', 'PASS', array_to_string(v_actions, ','));
  ELSE
    PERFORM pg_temp.zz6_log(19, 'Historique retrace création/émission/paiement', 'FAIL', coalesce(array_to_string(v_actions, ','), 'vide'));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz6_log(19, 'Historique retrace création/émission/paiement', 'FAIL', SQLERRM);
END $$;

DO $$
DECLARE v_fail_count int;
BEGIN
  SELECT count(*) INTO v_fail_count FROM zz6_results WHERE status = 'FAIL';
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'ECHEC DE % TEST(S)', v_fail_count;
  END IF;
END $$;

SELECT test_no, name, status, detail FROM zz6_results ORDER BY test_no;

ROLLBACK;
