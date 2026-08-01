-- ============================================================================
-- sql/90_phase2_performance_hardening_fk_indexes_and_rls_initplan.sql
-- Durcissement performance des tables Phase 2 — trouvé par un audit
-- get_advisors (security+performance) exécuté sur la branche de staging
-- après application cumulative de sql/70-89.
--
-- Portée strictement additive et non fonctionnelle : aucun comportement
-- observable ne change, aucune ligne de données n'est touchée.
--
-- A. Index manquants sur 23 clés étrangères des tables Phase 2 (billing,
--    support, notifications, catalogue). Chaque FK sans index couvrant
--    dégrade les JOIN/DELETE CASCADE et les vérifications de contrainte à
--    mesure que ces tables grossissent en production. CREATE INDEX
--    IF NOT EXISTS : idempotent, sans verrou bloquant significatif sur des
--    tables encore vides à ce stade (pas encore en production).
--
-- B. Réécriture de 4 policies RLS (support_tickets.support_insert/select/
--    update, support_ticket_replies.hotel_select_own_visible_replies) pour
--    envelopper auth.uid() dans un sous-select scalaire — (select auth.uid())
--    au lieu de auth.uid() nu. Sémantique strictement identique (le
--    planificateur PostgreSQL peut alors l'évaluer une seule fois par
--    requête au lieu d'une fois par ligne — cf. lint Supabase
--    auth_rls_initplan). ALTER POLICY, pas de DROP/CREATE : aucune fenêtre
--    sans policy.
--
-- Périmètre volontairement exclu (documenté, pas oublié) :
--   - Les 220 "unused_index" et 265 "multiple_permissive_policies" relevés
--     par le même audit couvrent trois cas non pertinents ici : (a) very
--     largement des tables préexistantes à Phase 2, hors périmètre ; (b) sur
--     les tables Phase 2, les "unused_index" (ex. idx_platform_notifications_
--     pending) sont un artefact de mesure sur une branche fraîchement
--     rejouée sans trafic réel, pas une preuve d'inutilité — les supprimer
--     serait une régression cachée de performance en production ; (c) les
--     policies "multiple permissive" reflètent le patron architectural
--     déjà en place dans tout le dépôt (policy large platform_admin_all +
--     policy étroite par table) — les consolider serait un chantier de
--     refonte RLS transverse à tout le produit, hors périmètre Phase 2 et
--     hors "aucun développement fonctionnel nouveau".
-- ============================================================================

-- A. Index de couverture sur les FK Phase 2 sans index
CREATE INDEX IF NOT EXISTS idx_hotel_addon_subscriptions_addon_id ON public.hotel_addon_subscriptions (addon_id);
CREATE INDEX IF NOT EXISTS idx_hotel_addon_subscriptions_hotel_id ON public.hotel_addon_subscriptions (hotel_id);
CREATE INDEX IF NOT EXISTS idx_hotel_app_subscriptions_plan_id ON public.hotel_app_subscriptions (plan_id);
CREATE INDEX IF NOT EXISTS idx_hotel_subscriptions_plan_id ON public.hotel_subscriptions (plan_id);
CREATE INDEX IF NOT EXISTS idx_hotel_subscriptions_promo_code_id ON public.hotel_subscriptions (promo_code_id);
CREATE INDEX IF NOT EXISTS idx_platform_contracts_hotel_id ON public.platform_contracts (hotel_id);
CREATE INDEX IF NOT EXISTS idx_platform_contracts_plan_id ON public.platform_contracts (plan_id);
CREATE INDEX IF NOT EXISTS idx_platform_credit_notes_created_by ON public.platform_credit_notes (created_by);
CREATE INDEX IF NOT EXISTS idx_platform_credit_notes_hotel_id ON public.platform_credit_notes (hotel_id);
CREATE INDEX IF NOT EXISTS idx_platform_invoices_hotel_id ON public.platform_invoices (hotel_id);
CREATE INDEX IF NOT EXISTS idx_platform_invoices_subscription_id ON public.platform_invoices (subscription_id);
CREATE INDEX IF NOT EXISTS idx_platform_logs_admin_id ON public.platform_logs (admin_id);
CREATE INDEX IF NOT EXISTS idx_platform_logs_hotel_id ON public.platform_logs (hotel_id);
CREATE INDEX IF NOT EXISTS idx_platform_payments_recorded_by ON public.platform_payments (recorded_by);
CREATE INDEX IF NOT EXISTS idx_platform_settings_updated_by ON public.platform_settings (updated_by);
CREATE INDEX IF NOT EXISTS idx_support_ticket_attachment_access_log_user_id ON public.support_ticket_attachment_access_log (user_id);
CREATE INDEX IF NOT EXISTS idx_support_ticket_attachments_deleted_by ON public.support_ticket_attachments (deleted_by);
CREATE INDEX IF NOT EXISTS idx_support_ticket_attachments_reply_id ON public.support_ticket_attachments (reply_id);
CREATE INDEX IF NOT EXISTS idx_support_ticket_attachments_uploaded_by ON public.support_ticket_attachments (uploaded_by);
CREATE INDEX IF NOT EXISTS idx_support_ticket_replies_author_user_id ON public.support_ticket_replies (author_user_id);
CREATE INDEX IF NOT EXISTS idx_support_ticket_replies_corrects_reply_id ON public.support_ticket_replies (corrects_reply_id);
CREATE INDEX IF NOT EXISTS idx_support_ticket_replies_hidden_by ON public.support_ticket_replies (hidden_by);
CREATE INDEX IF NOT EXISTS idx_support_tickets_user_id ON public.support_tickets (user_id);

-- B. RLS initplan : auth.uid() -> (select auth.uid()), sémantique inchangée
ALTER POLICY support_insert ON public.support_tickets
  WITH CHECK (
    hotel_id IN (
      SELECT uh.hotel_id
      FROM user_hotels uh
      JOIN users u ON u.id = uh.user_id
      WHERE u.auth_id = (select auth.uid())
    )
  );

ALTER POLICY support_select ON public.support_tickets
  USING (
    hotel_id IN (
      SELECT uh.hotel_id
      FROM user_hotels uh
      JOIN users u ON u.id = uh.user_id
      WHERE u.auth_id = (select auth.uid())
    )
  );

ALTER POLICY support_update ON public.support_tickets
  USING (
    hotel_id IN (
      SELECT uh.hotel_id
      FROM user_hotels uh
      JOIN users u ON u.id = uh.user_id
      WHERE u.auth_id = (select auth.uid())
    )
  );

ALTER POLICY hotel_select_own_visible_replies ON public.support_ticket_replies
  USING (
    (NOT is_internal_note)
    AND (hidden_at IS NULL)
    AND (ticket_id IN (
      SELECT support_tickets.id
      FROM support_tickets
      WHERE support_tickets.hotel_id IN (
        SELECT uh.hotel_id
        FROM user_hotels uh
        JOIN users u ON u.id = uh.user_id
        WHERE u.auth_id = (select auth.uid())
      )
    ))
  );
