# ADR-005 — Les feature flags sont activés par groupe hôtelier

**Statut** : Accepté.

## Contexte
Le moteur d'heures segments doit être piloté progressivement, sans exposer tous les
clients d'un coup.

## Problème
Choisir la granularité d'activation qui minimise le risque et permet un pilote isolé,
réversible et traçable.

## Décision
Flag `hotel_groups.features.hours.source ∈ {legacy, segments}`, **par groupe**, défaut
`legacy`, activation manuelle via `set_group_hours_source` (journalisée dans
`hotel_group_flag_audit`), sans basculement automatique.

## Alternatives étudiées
1. Flag global unique → tout ou rien, risque maximal.
2. Flag par hôtel → un salarié déplacé entre 2 hôtels du même groupe aurait un calcul
   incohérent selon l'hôtel ; le groupe est l'unité métier du déplacement inter-hôtels.
3. **Flag par groupe (retenu)** → cohérent avec le périmètre du déplacement.

## Avantages
- Pilote isolé sur un seul groupe ; autres groupes inchangés (défaut legacy).
- Cohérence : un déplacement reste dans un groupe → un seul régime de calcul.
- Réversible et journalisé (audit des bascules).

## Inconvénients
- Un groupe très hétérogène bascule d'un bloc (pas de sous-granularité hôtel).

## Impacts futurs
- Modèle réutilisable pour les futurs flags produit (une clé sous `features`).
