# Feature Flags — Flowtym RH (RC1)

Document de référence des drapeaux de fonctionnalité pilotant le comportement en
exploitation. **Un seul flag est critique pour le pilote** : `hours.source`.

## `hours.source` — moteur de calcul des heures

| Propriété | Valeur |
|---|---|
| Emplacement | `hotel_groups.features -> 'hours' ->> 'source'` (JSONB, **par groupe**) |
| Valeurs | `legacy` (défaut) · `segments` |
| Défaut | `legacy` (aucune ligne = legacy) |
| Portée | **par groupe hôtelier** (pas global, pas par hôtel) |
| Lecture (RPC front) | `group_hours_source(p_hotel uuid) -> text` |
| Écriture (RPC) | `set_group_hours_source(p_group uuid, p_source text) -> jsonb` |
| Journalisation | table `hotel_group_flag_audit` (auteur, avant/après, horodatage) |

### Effet
- `legacy` : les écrans de paie (C1) et suivi (C2) calculent les heures depuis la
  **grille** (`staff_planning`, `hours` sinon `hpd`). **Comportement historique inchangé.**
- `segments` : les mêmes écrans lisent les **heures nettes issues des segments**
  (`staff_hotel_hours_range`) — source de vérité, **aucun double compte** sur les
  jours fractionnés/déplacés.

### Lire l'état d'un groupe
```sql
SELECT g.id, g.name, coalesce(g.features->'hours'->>'source','legacy') AS hours_source
FROM hotel_groups g ORDER BY g.name;
```

### Activer sur UN groupe (pilote)
```sql
-- p_group = id du groupe pilote UNIQUEMENT
SELECT set_group_hours_source('<GROUP_ID>', 'segments');
```

### Revenir en legacy (rollback flag — instantané, réversible)
```sql
SELECT set_group_hours_source('<GROUP_ID>', 'legacy');
```

### Journal des bascules
```sql
SELECT changed_at, group_id, flag_path, old_value, new_value, changed_by
FROM hotel_group_flag_audit WHERE flag_path='hours.source'
ORDER BY changed_at DESC LIMIT 20;
```

## Garanties de sécurité du flag

1. **Ne contourne JAMAIS le garde-fou paie clôturée** (`FL001`). Même en `segments`,
   toute écriture sur une période close est refusée.
2. **Aucun basculement automatique** : seule l'exécution manuelle de
   `set_group_hours_source` change la valeur.
3. **Aucune destruction de données** : basculer `segments`↔`legacy` ne change que la
   **source de lecture** ; segments et grille restent intacts.
4. **Valeur invalide refusée** : `set_group_hours_source(..., 'xxx')` lève `FL002`.

## Autres drapeaux (non critiques pilote, lecture seule ici)
- `hotel_groups.features.coverage.*` : seuils de couverture Planning Groupe
  (configurables, sans effet sur la paie). Voir `docs/coverage-engine-design.md`.

> **Règle d'or pilote** : n'activer `segments` que sur **le groupe pilote**. Vérifier
> après chaque changement via le journal `hotel_group_flag_audit`.
