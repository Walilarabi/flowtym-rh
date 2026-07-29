# Audit du moteur de signature électronique — Flowtym RH

**Date :** 2026-07-29 · **Périmètre :** moteur natif `sig-send`/`sig-sign` (eIDAS simple), tables `signature_requests` / `signature_events` / `generated_contracts`, compat Yousign historique, téléchargement (`contract-pdf-url`).
**Méthode :** revue du code source (edge functions + SQL + frontend `index.html`) + observation de l'état **réellement déployé en production** (projet `hzrzkvdebaadditvbqis`) : versions des fonctions, GRANTs, policies RLS, RPC, complétude des preuves sur données réelles, cohérence de hash. Le flux live n'a **pas** été déclenché end-to-end pour ne pas polluer la prod ni envoyer d'e-mails réels (chemin destructif) ; la logique PDF/hash est prouvée hors-ligne par `scripts/proofs/pdf-hash-coherence.mjs`.

## Verdict global : **FAIL conditionnel — le flux fonctionne, mais 1 risque juridique bloquant + corrections obligatoires avant M5.**

Le moteur est fonctionnel, cloisonné, les preuves techniques (IP/UA/horodatage/hash) sont capturées et cohérentes, la confidentialité pré-OTP est réellement appliquée côté serveur, et la compat Yousign au téléchargement est gérée. **Mais l'artefact signé archivé n'est pas une reproduction fidèle du document présenté au signataire** (WYSIWYS rompu) — point rédhibitoire pour la valeur probante eIDAS.

---

## Résultats par axe testé

| Axe | Verdict | Détail |
|---|---|---|
| Flux E2E (création → sig-send → OTP → canvas → PDF → archivage → download) | ✅ PASS | Enchaînement complet et cohérent ; état terminal correct ; re-signature bloquée (409). |
| Le PDF signé contient le contrat original | ❌ **FAIL** | Le PDF archivé est une **extraction texte brut** (`htmlToText`) du contrat, pas le document rendu que le signataire a lu/consenti. Voir R1. |
| Preuves stockées (IP, UA, horodatage, hashes SHA-256) | ✅ PASS | Sur la seule demande signée en prod : 0 preuve manquante (`signer_ip`, `signer_ua`, `signed_at`, `document_hash_sha256`, `signed_document_hash_sha256`, `signed_pdf_storage_path` tous présents). |
| Cohérence du hash du document signé | ✅ PASS | Rendu unique : `signed_document_hash_sha256` == SHA-256 des octets archivés (prouvé hors-ligne + test d'intégration recalcule depuis le storage). |
| `signature_events` append-only | ⚠️ PARTIEL | UPDATE/DELETE révoqués aux rôles clients ; INSERT client bloqué par **RLS** (aucune policy INSERT). Mais `sql/42` (REVOKE INSERT) **non appliqué** et **aucun verrou d'immutabilité DB** (service_role/postgres peuvent réécrire). Voir R3/R4. |
| Confidentialité pré-OTP | ✅ PASS | `get_document` exige `status='otp_verified'` ; le GET ne renvoie jamais `generated_html`. Masquage nom/e-mail. |
| Contrôle d'accès au téléchargement | ✅ PASS | `contract-pdf-url` vérifie accès hôtel (`user_hotels`) **ou** e-mail signataire ; signed URL privée 15 min. Pas d'IDOR. |
| Compat contrats Yousign historiques | ✅ PASS (avec réserves) | `contract-pdf-url` résout les deux moteurs (natif `hr-documents` via `signature_request_id` ; Yousign `contracts`/`portal-documents`). Frontend : chemin de download unique, aucune branche provider. Réserves R5/R6. |

---

## Findings & corrections

### 🔴 R1 — CRITIQUE (bloquant M5) : le PDF archivé n'est pas fidèle au document signé (WYSIWYS rompu)
`sig-sign > buildSignedPDF` reconstruit le contrat via `htmlToText()` : suppression de **toutes** les balises, CSS perdu, **tableaux aplatis** (`</td>`→2 espaces, `</tr>`→saut de ligne). Or le signataire lit, à l'étape `get_document`, le **HTML rendu** (`contract_html`, police Times New Roman, mise en forme, grilles de salaire/horaires). L'artefact archivé diffère donc **matériellement en présentation** de ce qui a été consenti.
- Conséquence juridique : le principe *« ce que je vois est ce que je signe »* n'est pas garanti ; une grille salariale/horaire peut devenir illisible ou ambiguë dans le PDF.
- Le `document_hash_sha256` porte sur le **HTML**, pas sur le PDF texte : aucune empreinte ne lie la **vue rendue effectivement lue** à l'artefact archivé.
- **Correction obligatoire :** générer le PDF par un rendu fidèle du HTML (impression headless / HTML→PDF) **ou** afficher au signataire exactement le même texte brut que celui embarqué dans le PDF. Le hash source doit porter sur l'artefact présenté.

### 🟠 R2 — MAJEUR : durée de vie OTP de 48 h + hachage non salé
- OTP à 6 chiffres, `otp_hash = SHA-256(otp)` **sans sel ni secret serveur**. En cas de fuite de la table avant expiration, l'espace de 900 000 valeurs est inversé instantanément hors-ligne.
- **48 h de validité** est très long pour un code de vérification (usage : 5–15 min). Fenêtre d'attaque élevée.
- **Correction :** HMAC-SHA256 avec secret serveur (ou bcrypt) ; réduire le TTL (≤ 30 min pour la vérification, découplé de la validité du lien) ; conserver le plafond de 5 tentatives (déjà atomique via `sig_bump_otp_attempts`, ✅ appliqué).

### 🟠 R3 — MAJEUR : `send_otp`/`resend` sans limitation de débit
`sig-sign` (POST, `verify_jwt=false`) expose `send_otp` sans throttling : un tiers connaissant le `request_id` peut déclencher un envoi d'e-mails en boucle vers le signataire (nuisance + coût Resend). **Correction :** rate-limit par `request_id`/IP (ex. cooldown 60 s, max N/heure) + journalisation.

### 🟡 R4 — MOYEN : append-only en défense unique (RLS), non durci au niveau DB
Aujourd'hui l'immutabilité repose sur : (a) absence de policy INSERT (RLS bloque anon/authenticated) et (b) REVOKE UPDATE/DELETE clients. **Mais** `sql/42` (REVOKE INSERT — ceinture en plus des bretelles) **n'est pas appliqué en prod**, et **aucun trigger** n'empêche `service_role`/`postgres` de réécrire/supprimer un événement. Pour une valeur probante « append-only » stricte : **Correction :** appliquer `sql/42` + ajouter un trigger `BEFORE UPDATE OR DELETE` levant une exception sur `signature_events` (immutabilité indépendante du rôle).

### 🟡 R5 — MOYEN : self-suffisance du dépôt & cohabitation des moteurs
- La fonction `contract-pdf-url` (seul résolveur de téléchargement, y compris Yousign) **n'existe pas dans le dépôt** (déployée v2 uniquement). À versionner.
- `yousign-create` / `yousign-webhook` restent **ACTIFS** en prod alors que le frontend a retiré Yousign (`_syncYousign` désactivé). `yousign-webhook` peut donc encore écrire `status='signed'`, `signature_provider='yousign'` sur `generated_contracts`. **Correction :** désactiver explicitement (kill-switch 410) ou documenter que le webhook reste ouvert pour la clôture des demandes historiques uniquement.
- `signature_provider` a pour défaut `'yousign'` : tout contrat jamais touché par le natif est étiqueté Yousign. Sans incidence sur le download (fallback par `signed_pdf_storage_path`), mais trompeur en reporting.

### 🟡 R6 — MOYEN : preuves hétérogènes entre moteurs (compat)
Le flux Yousign historique **ne stocke pas** IP/UA/hash localement pour les contrats `generated_contracts` (le webhook ne télécharge pas l'audit trail Yousign, seulement le PDF signé) ; les preuves vivent chez Yousign. Le natif stocke tout en base. **Conséquence :** registre de preuves non uniforme selon l'origine du contrat. **Correction :** pour les contrats Yousign, télécharger et archiver l'audit trail Yousign (déjà fait côté portail via `audit_trail_path`), ou documenter la dépendance externe.

### 🔵 R7 — MINEUR
- `x-forwarded-for` : première valeur retenue → IP potentiellement usurpable par en-tête ; acceptable en eIDAS simple, à documenter.
- `sign` non idempotent/verrouillé : deux appels concurrents `otp_verified` peuvent produire un double `employee_documents` (le PDF s'écrase, même chemin). Ajouter un garde d'unicité ou un `SELECT ... FOR UPDATE`.
- Robustesse `contract-pdf-url` : un contrat `signature_provider='flowtym'` sans `signature_request_id` retomberait sur le mauvais bucket (`portal-documents`). `sig-sign` renseigne toujours ce champ ; garde défensif recommandé.

---

## Ce qui est solide (à conserver)
- Confidentialité serveur (contenu jamais émis avant OTP) — testée, non contournable côté client.
- Rendu PDF **unique** → hash cohérent avec l'octet archivé + **vérification post-upload** (download avant de marquer `signed`, anti-PDF-fantôme).
- Contrôle d'accès au download (hôtel **ou** signataire), URL signée privée courte.
- Compteur OTP atomique (`sig_bump_otp_attempts`, `sql/41` appliqué) anti brute-force concurrent.
- Chaîne d'événements complète : `created → otp_sent → otp_verified → terms_accepted → signed → pdf_archived`.
- Moteur v1 (`contract-sign`/`contract-send-signature`) correctement neutralisé (410).

## Corrections obligatoires avant M5
1. **R1** — Fidélité de l'artefact signé (WYSIWYS). *(bloquant)*
2. **R2** — Durcir l'OTP (HMAC/sel + TTL court).
3. **R3** — Rate-limit `send_otp`.
4. **R4** — Appliquer `sql/42` + trigger d'immutabilité `signature_events`.
5. **R5** — Versionner `contract-pdf-url` + statut explicite des fonctions Yousign.

R6/R7 : recommandés, non bloquants.
