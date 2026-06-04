# Tests — Flowtym RH

## Lancer les tests

```bash
npm install   # une seule fois
npm test      # jest --coverage
```

## Architecture

```
tests/
├── lib/
│   ├── testBE.js       # makeTestBE() en CommonJS (backend mémoire, sans Supabase)
│   └── permissions.js  # PERMS / canSee / canFicheFull
├── absences.test.js     # P1 : listAbsences + workflow demande/approbation
├── employees.test.js    # CRUD employés + photo (upload / suppression)
├── invitation.test.js   # P3 : invitation + révocation utilisateur
├── notifications.test.js # cloche alertes — listAbsences
├── payroll.test.js      # éléments variables : planning + pointages
└── permissions.test.js  # matrice rôles : canSee / canFicheFull / canManageUsers
```

## Couverture cible

| Module | Tests |
|--------|-------|
| Absences (P1 bug) | ✅ |
| Paie | ✅ |
| Notifications | ✅ |
| Invitation utilisateur | ✅ |
| Employés / Photo | ✅ |
| Permissions | ✅ |
