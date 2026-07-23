# Preuves reproductibles

## pdf-hash-coherence.mjs
Démontre que le nouveau flux de `sig-sign` (rendu PDF unique) garantit
`signed_document_hash_sha256 == SHA-256(fichier archivé)`, et que l'ancien
flux (double rendu) produisait un hash ≠ fichier archivé (intégrité
invérifiable).

```bash
npm install pdf-lib@1.17.1
node scripts/proofs/pdf-hash-coherence.mjs
```
