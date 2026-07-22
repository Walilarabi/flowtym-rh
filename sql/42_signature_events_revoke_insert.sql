-- 42_signature_events_revoke_insert.sql
-- DURCISSEMENT (préparé, à appliquer lors du déploiement — NON appliqué en prod à ce stade).
--
-- Démonstration d'innocuité (voir rapport) : aucun code frontend ni utilisateur
-- authentifié n'insère dans signature_events. Seules les Edge Functions sig-send /
-- sig-sign y écrivent, via service_role (non affecté par ce REVOKE). L'INSERT était
-- déjà bloqué par RLS (aucune policy INSERT) ; ce REVOKE ajoute une défense en
-- profondeur au niveau des GRANTs.
--
-- État actuel des GRANTs (vérifié) :
--   authenticated / anon : INSERT, SELECT, REFERENCES, TRIGGER   (UPDATE/DELETE/TRUNCATE déjà absents)
--   service_role         : ALL
-- Objectif : retirer INSERT à authenticated / anon.

REVOKE INSERT ON public.signature_events FROM authenticated;
REVOKE INSERT ON public.signature_events FROM anon;

-- Vérifications attendues après application (append-only strict pour les rôles clients) :
--   authenticated / anon : SELECT, REFERENCES, TRIGGER uniquement
--   Aucun UPDATE, DELETE, TRUNCATE, INSERT pour ces rôles.
