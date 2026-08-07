-- 101_fix_hotels_select_multi_hotel_rls.sql
--
-- BUG (production, constaté) : un utilisateur ayant plusieurs lignes
-- user_hotels (ex: rôle Direction attribué sur les 4 hôtels d'un groupe) ne
-- voyait qu'UN SEUL hôtel dans le sélecteur d'établissement, quel que soit le
-- nombre réel de lignes user_hotels correctement en base.
--
-- CAUSE RACINE (démontrée par test RLS réel, impersonation auth.uid()) :
-- `BE.listHotels()` (index.html) fait un embed PostgREST :
--   sb.from('user_hotels').select('hotel_id, hotels(id,name,...)').eq('user_id', u.id)
-- La policy SELECT sur `user_hotels` (user_hotels_select_own) autorise bien la
-- lecture de TOUTES les lignes de l'utilisateur. Mais l'embed `hotels(...)`
-- est un LEFT JOIN dont chaque ligne est filtrée INDÉPENDAMMENT par la RLS de
-- la table `hotels` elle-même. Or la policy `hotels_select` était :
--   USING (id = get_user_hotel_id())
-- c'est-à-dire limitée à l'unique "hôtel actif" de l'utilisateur (fonction
-- mono-hôtel), et non à l'ensemble de ses hôtels autorisés. Pour toute ligne
-- user_hotels dont l'hôtel n'est pas l'hôtel actif, l'embed `hotels` PostgREST
-- renvoie `null` — silencieusement éliminé par `.filter(Boolean)` côté client,
-- sans erreur réseau ni log.
--
-- FIX : aligner `hotels_select` sur `pl_my_hotels()`, la fonction multi-hôtel
-- déjà utilisée par toutes les autres tables métier (employees, staff_planning,
-- etc. — cf. sql/01_rh_staff_module_schema.sql) pour ce même besoin. Laisse
-- `hotels_update_own` inchangée (mono-hôtel = l'hôtel actif en cours d'édition,
-- comportement correct pour une mise à jour).
--
-- Vérifié en prod par impersonation RLS réelle (BEGIN; SET LOCAL ROLE
-- authenticated; set_config('request.jwt.claims', ...); SELECT; ROLLBACK) :
--   - utilisateur multi-hôtels (4 lignes user_hotels) : 4 hôtels retournés (était 1)
--   - utilisateur mono-hôtel (1 ligne user_hotels)     : 1 hôtel retourné (inchangé, pas de régression)

DROP POLICY IF EXISTS hotels_select ON public.hotels;
CREATE POLICY hotels_select ON public.hotels
  FOR SELECT
  TO authenticated
  USING (id IN (SELECT public.pl_my_hotels()));
