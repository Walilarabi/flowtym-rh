-- =============================================================================
-- 23_fix_view_rls.sql
-- Sécurisation de la vue v_employee_documents_alerts
-- La vue était accessible à tous les utilisateurs authentifiés (cross-tenant)
-- Correction : security_invoker = ON pour que la RLS des tables sous-jacentes s'applique
-- Rejouable (CREATE OR REPLACE)
-- =============================================================================

-- Recrée la vue avec security_invoker = ON
-- Cela force la vue à s'exécuter dans le contexte de l'appelant,
-- déclenchant ainsi la RLS sur employee_documents et employees.
CREATE OR REPLACE VIEW public.v_employee_documents_alerts
WITH (security_invoker = ON)
AS
SELECT
  ed.id,
  ed.hotel_id,
  ed.employee_id,
  e.first_name,
  e.last_name,
  ed.doc_type_code,
  dt.label          AS doc_type_label,
  dt.alert_days_before,
  ed.expires_at,
  ed.status,
  ed.file_path,
  CASE
    WHEN ed.status = 'missing'                                          THEN 'missing'
    WHEN ed.expires_at IS NOT NULL AND ed.expires_at < CURRENT_DATE    THEN 'expired'
    WHEN ed.expires_at IS NOT NULL
     AND ed.expires_at < CURRENT_DATE + (dt.alert_days_before || ' days')::interval THEN 'expiring_soon'
    ELSE NULL
  END AS alert_kind
FROM public.employee_documents ed
JOIN public.employees e ON e.id = ed.employee_id
LEFT JOIN public.document_types dt ON dt.code = ed.doc_type_code
WHERE e.active = true;

-- Révocation du GRANT permissif précédent et re-grant correct
-- Le GRANT reste à authenticated, mais la RLS des tables sous-jacentes s'applique désormais
-- grâce à security_invoker = ON
REVOKE ALL ON public.v_employee_documents_alerts FROM authenticated;
GRANT SELECT ON public.v_employee_documents_alerts TO authenticated;

COMMENT ON VIEW public.v_employee_documents_alerts IS
  'Alertes documents employés. security_invoker=ON : la RLS de employees et employee_documents filtre par hotel_id via pl_my_hotels().';
