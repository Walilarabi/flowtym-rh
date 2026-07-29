-- 77_super_admin_rc1_acl_hygiene.sql
-- RC1 stabilisation — correctif de sécurité pur (aucun changement de comportement).
--
-- Deux fonctions historiques (antérieures aux lots 0-5, jamais retouchées par ce projet)
-- n'avaient jamais reçu le REVOKE/GRANT appliqué systématiquement à toutes les autres
-- fonctions admin_* du portail Super Admin :
--
-- 1. admin_set_default_hotel(p_user_id, p_hotel_id) : véritable mutation Super Admin (garde
--    is_platform_admin() déjà présente dans le corps de la fonction), mais ouverte par défaut
--    à anon/authenticated/service_role (grant PUBLIC jamais révoqué à sa création). Aucune
--    exploitation possible (la garde interne refuse tout appelant non-admin), mais incohérent
--    avec la défense en profondeur appliquée à toutes les autres fonctions admin_*.
--
-- 2. grant_superadmin_on_new_hotel() : fonction du trigger trg_grant_superadmin_on_new_hotel
--    (AFTER INSERT ON hotels), RETURNS trigger. Non invocable directement via RPC (Postgres
--    refuse l'appel d'une fonction trigger hors contexte trigger), donc aucun risque réel, mais
--    même incohérence ACL.
--
-- Aucun changement de logique : uniquement REVOKE/GRANT, comme pour toutes les autres
-- fonctions admin_* de ce projet.

REVOKE ALL ON FUNCTION public.admin_set_default_hotel(uuid, uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_set_default_hotel(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.grant_superadmin_on_new_hotel() FROM PUBLIC, anon, authenticated, service_role;
