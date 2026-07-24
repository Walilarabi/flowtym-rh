# Règles de triage — incidents & retours du pilote

Chaque signalement (utilisateur, checklist, alerte) est **classé** dans **une** des
catégories ci-dessous, puis **testé pour reproductibilité**, puis **consigné** dans le
bon registre. Le référent technique (Release Manager) tranche la catégorie.

## Catégories

| Catégorie | Définition | Registre | Action pilote |
|---|---|---|---|
| **Bug critique** | Perte/corruption de données, double compte paie, garde-fou défaillant, faille de sécurité, indisponibilité | `pilot-incidents.md` (gravité *Critique*) | **Exception au gel** : diagnostic + correctif minimal après validation ; kill-switch si besoin |
| **Bug mineur** | Anomalie sans impact données/paie/sécurité (affichage, cas limite non bloquant) | `pilot-incidents.md` (gravité Moyen/Faible) | Consigné ; correctif **différé RC2** sauf décision contraire |
| **UX** | Friction, libellé, ergonomie ; le produit fonctionne mais gêne | `user-feedback.md` (cat. UX) | Consigné → US RC2 |
| **Fonction manquante** | Besoin non couvert par le périmètre RC1 | `user-feedback.md` (cat. Fonction manquante) | Consigné → RC2-roadmap |
| **Formation utilisateur** | Le produit fait ce qu'il faut mais l'utilisateur ne sait pas s'en servir | `user-feedback.md` (cat. Compréhension) | Action de formation/doc ; **pas** de code |
| **Demande RC2** | Évolution explicitement hors pilote | `rc2-backlog.md` + `RC2-roadmap.md` | Enregistré, non implémenté |

## Test de reproductibilité (obligatoire avant classement définitif)

1. **Contexte** : hôtel, utilisateur, rôle, mois, flag (`segments`/`legacy`), navigateur.
2. **Rejeu** : reproduire les étapes exactes → *Reproductible : Oui / Non / Partiel*.
3. **Isolation** : le problème disparaît-il en `legacy` (bascule flag) ? (indice moteur segments)
4. **Données** : lancer les invariants (`daily-checklist.md` Bloc 1) — 0 attendu.
5. **Diagnostic** : requêtes `incident-runbook.md` §3 (segments/grille/audit du cas).

## Arbre de décision rapide

```
Perte de données / double compte paie / garde-fou KO / sécurité ?
  ├─ OUI → Bug critique  (incident-runbook.md, exception au gel)
  └─ NON → Anomalie fonctionnelle reproductible ?
            ├─ OUI, impact réel → Bug mineur (différé RC2 sauf décision)
            └─ NON → Gêne d'usage ?
                      ├─ ergonomie      → UX
                      ├─ besoin absent  → Fonction manquante
                      ├─ incompréhension→ Formation utilisateur
                      └─ évolution      → Demande RC2
```

## Règle absolue (rappel)
Hors **bug critique / anomalie reproduite / faille de sécurité / perte de données**,
**rien n'est développé** pendant le pilote. Tout le reste est enregistré et priorisé RC2.
