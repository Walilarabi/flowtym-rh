# Leçons apprises — projet Flowtym RH (jusqu'à RC1)

Analyse **honnête** du projet, destinée à servir de référence pour la suite (RC2 et les
prochains modules : Revenue, Finance, PMS, Housekeeping…). Inclut les réussites **et**
les erreurs, y compris celles commises pendant le développement lui-même.

## 1. Ce qui a très bien fonctionné

- **Modèle A (segments = vérité, grille = projection)** : décision structurante qui a
  éliminé le double compte d'heures à la racine, tout en préservant la rétro-compatibilité.
- **Preuve runtime plutôt que théorie** : exiger une **concurrence réellement exécutée à
  deux connexions** (et non des suppositions) a validé les invariants critiques et donné
  une base de confiance solide. Idem pour la reconstruction depuis le dépôt.
- **Tests comme filet de sécurité** : plusieurs bugs réels ont été **attrapés par les
  tests**, pas par la relecture (voir §4). Les 24/24 et 7/7 ne sont pas décoratifs.
- **Réversibilité par flag + garde-fou paie** : ces deux garde-fous rendent le pilote
  **peu risqué**, ce qui a permis un GO pilote honnête malgré une chaîne de release
  encore imparfaite.
- **Refus de « faire plaisir »** : la revue de préparation a produit un **NO-GO
  production** franc et a révélé une dette majeure (reproductibilité) au lieu de la masquer.

## 2. Ce qui aurait dû être fait autrement (dès le départ)

- **Versionner le schéma dès le jour 1.** La découverte la plus grave : la base n'était
  **pas reconstructible depuis le dépôt** (fondation créée par un amorçage pré-`01` jamais
  versionné ; migrations 46–53 laissées en **stubs documentaires**). Une discipline
  « migration réelle exécutable, sinon rien » aurait évité cette dette.
- **CI dès le premier commit.** L'absence de CI pendant l'essentiel du projet a laissé la
  reproductibilité et la non-régression non garanties trop longtemps.
- **Migrer les consommateurs au fil de l'eau.** Les calculs d'heures dupliqués dans le
  frontend auraient dû être centralisés plus tôt (fonction canonique en premier), pas en
  fin de parcours.
- **Éviter le monolithe.** `index.html` (16k+ lignes) est un risque de maintenabilité
  installé tôt et coûteux à défaire.

## 3. Erreurs d'architecture ÉVITÉES (à conserver comme réflexe)

- **GUC falsifiable comme signal de confiance** : un garde-fou basé sur
  `set_config('flowtym.allow_move_write')` a été **prouvé contournable** par un rôle
  authentifié, puis **remplacé** par un contrôle non falsifiable (`current_user`). Leçon :
  ne jamais fonder une garantie de sécurité sur un signal que l'appelant peut positionner.
- **`FOR UPDATE` seul pour la concurrence** : insuffisant sans ligne préexistante ;
  corrigé par des **advisory locks** (ADR-003). Leçon : verrouiller la **clé logique**,
  pas seulement les lignes existantes.
- **Grille comme source d'heures** : abandonné au profit des segments (ADR-001).
- **Rollback par migration d'abord** : remplacé par **rollback par flag** (ADR-007).

## 4. Erreurs commises (et rattrapées par les tests)

> Transparence : ces bugs ont été introduits **puis détectés** avant toute mise en prod.

- **`jsonb_set` ne crée pas un parent manquant** : `set_group_hours_source` ne posait
  pas réellement le flag (`{hours,source}` sur `{}`) → le moteur segments restait inactif.
  **Détecté par les tests P0** (résultats incohérents), corrigé par une fusion `||`.
- **Marqueur « journée entière » compté 24 h** : un segment `0..1440` était sommé comme
  24 h → puis, après correction naïve, **7 h** (perte d'1 h) → violation de la règle
  « un déplacement ne supprime pas d'heures ». **Détecté par le test T10**, corrigé en
  **préservant l'intervalle réel d'origine** dans `group_move_apply` (+ non-régression
  concurrence revérifiée 7/7).
- **Seeds de test incomplets** révélés par la **fondation fidèle** (`NOT NULL` sur
  `hotel_id`) — un bon signal : un schéma strict attrape les données de test bâclées.
- **Mots réservés SQL** (`overlaps`) et **pipelines shell trompeurs** (`grep | head`
  masquant le code retour) : petites erreurs d'outillage, corrigées ; rappel de toujours
  vérifier le **vrai** signal, pas un signal dérivé.

## 5. Bonnes pratiques à conserver

- **Invariants au niveau base** (contrainte d'exclusion, PK d'idempotence, triggers de
  garde) plutôt que vérifications applicatives contournables.
- **Codes d'erreur stables et machine-lisibles** (`FL001`, `FL002`).
- **Feature flag par unité métier**, défaut sûr (legacy), **journalisé**.
- **Preuves reproductibles** attachées aux décisions (tests rejouables, runbooks).
- **Documenter les décisions en ADR** au moment où on les prend.
- **Revue critique honnête** (GO/NO-GO argumenté) avant tout jalon.

## 6. Recommandations pour les prochains modules (Revenue, Finance, PMS, Housekeeping)

1. **Schéma versionné et reconstructible dès le premier commit** (migration réelle,
   `db reset` vert en CI). Ne jamais laisser un stub tenir lieu de migration.
2. **CI bloquante immédiate** : build/lint + reconstruction + tests d'invariants.
3. **Source de vérité unique par domaine** (comme les segments pour les heures) ; les
   autres représentations sont des projections reconstructibles.
4. **Fonction/So­urce canonique** pour tout calcul sensible (finance, tarifs, stocks) —
   interdire la duplication de formules dans le frontend.
5. **Garde-fous non contournables** pour les données engageantes (clôtures comptables,
   facturation) sur le modèle `FL001`.
6. **Concurrence testée à deux connexions** dès qu'un chemin d'écriture peut être
   concurrent (réservations PMS, facturation…), en **gate CI**.
7. **Activation progressive par flag** + **rollback par flag** comme standard produit.
8. **Éviter le monolithe** : composer en modules dès le départ.
9. **Observabilité runtime** (logs structurés + alerting) prévue dès la conception, pas
   après coup.
10. **Documentation de gouvernance** (ADR, RC, registres) tenue **en continu**, pas en
    fin de cycle.

---

Ce document est vivant : il doit être **complété par le post-mortem du pilote** (retours
terrain, incidents réels, métriques) avant l'ouverture de RC2.
