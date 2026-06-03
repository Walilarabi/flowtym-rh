# Flowtym RH — Module RH multi-hôtel

Application mono-fichier branchée sur Supabase. Authentification, multi-hôtel
avec **RLS stricte par hôtel**, planning mensuel avec **édition en masse**,
fiches collaborateurs avec documents, et tableau de bord / reporting /
configuration.

## Contenu de l'archive

```
flowtym_rh.html                            l'application (un seul fichier)
sql/
  01_rh_staff_module_schema.sql            crée les 7 tables + RLS + index + vue
  02_rh_data_migration_pl_to_new.sql       migre les données du prototype pl_*
  03_rh_cleanup_pl_prototype.sql           supprime pl_* après vérification
  04_rh_add_employee_departure_date.sql    ajoute la colonne departure_date
types/
  flowtym_rh.types.ts                      types TypeScript alignés sur Supabase
docs/
  CHANGELOG.md                             historique des évolutions
```

## Architecture

- **Frontend** : HTML/CSS/JS vanilla, librairies chargées via jsDelivr
  (Supabase JS v2, SheetJS pour l'import Excel, Font Awesome 6, Google Fonts Inter).
- **Backend** : Supabase. Authentification e-mail/mot de passe. RLS appliquée
  à chaque table via `hotel_id IN (SELECT pl_my_hotels())`.
- **Multi-tenant** : isolation garantie par la RLS, l'utilisateur ne voit que
  les hôtels auxquels son compte est rattaché dans `user_hotels`.

## Déploiement de la base (Supabase)

Dans l'ordre, dans l'éditeur SQL Supabase :

1. `01_rh_staff_module_schema.sql` — tables, RLS, policies, vue.
2. `02_rh_data_migration_pl_to_new.sql` — uniquement si vous aviez utilisé
   le prototype `pl_*` (sinon sauter).
3. `04_rh_add_employee_departure_date.sql` — colonne de date de départ.
4. `03_rh_cleanup_pl_prototype.sql` — **après** vérification du résultat
   de la 02 (compter `staff_planning` et `employees`).

Toutes les migrations sont **rejouables**. La 03 est la seule destructive
et reste explicite.

## Configuration de l'application

En haut du `<script>` du fichier `flowtym_rh.html` :

```js
const SUPABASE_URL      = "https://<votre-projet>.supabase.co";
const SUPABASE_ANON_KEY = "<votre clé anon>";
```

La clé **anon** est publique (la sécurité repose sur la RLS, pas la clé).
Ne mettez jamais la clé `service_role` ici.

## Déploiement du frontend

Le fichier doit être servi en **HTTP/HTTPS** (pas `file://`) :

- **Test local** : `python3 -m http.server 8000` puis
  http://localhost:8000/flowtym_rh.html
- **CDN statique** : Vercel, Netlify, Cloudflare Pages, S3, Nginx — aucun
  build nécessaire.
- **Sous-route d'un site existant** : copier le fichier dans un sous-dossier.

Servez en HTTPS en production (Supabase Auth exige TLS).

## Onglets fonctionnels

- **Tableau de bord** — KPI, équipe active, activité récente du mois.
- **Planning** — grille mensuelle, édition en masse, sauvegarde par lots,
  import Excel, fiche, totaux.
- **Reporting** — graphes (services/rôles, top jours, top CP, statuts).
- **Personnel** — cartes avec recherche, filtre Actif/Parti/Tous.
- **Contrats** — tableau récapitulatif des contrats.
- **Documents** — matrice complète, toggle Fourni/Manquant.
- **Paramètres** — CRUD services et rôles par hôtel.

## Onglets en roadmap

Pointage, Suivi du temps, Paie, Recrutement affichent un panneau
« Module à venir ». Chaque module nécessitera ses propres tables et
logique métier dans des itérations futures.

## Rattachement utilisateur → hôtels

Pour qu'un utilisateur accède à un hôtel :

- compte Supabase (auth.users)
- ligne dans `public.users` reliant `auth_id` à `id`
- ligne dans `public.user_hotels(user_id, hotel_id, role)` par hôtel accessible
- optionnellement `public.user_active_hotel(user_id, hotel_id)` (maintenu
  automatiquement par l'app)

La fonction `public.pl_my_hotels()` renvoie les hôtels accessibles à
`auth.uid()`. Les policies RLS l'utilisent en USING et WITH CHECK.

## Mode test local

Ajoutez `?test=1` à l'URL pour passer en mode hors-ligne avec un jeu de
données en mémoire (démo, tests automatisés).

## Tests automatisés

52 tests jsdom : rendu, navigation entre onglets, édition en masse,
persistance, gestion des départs, bascule de la barre latérale.
Tests SQL : contraintes, upsert d'unicité, cascade, vue, dates d'absences.

## Sécurité

- Clé `anon` publique, RLS partout — aucune fuite possible entre hôtels.
- Aucune donnée sensible en `localStorage` (uniquement préférences UI).
- Changement d'hôtel met à jour `user_active_hotel` pour que la RLS
  s'applique au nouvel hôtel.
