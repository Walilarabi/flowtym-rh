-- Flowtym RH · 07 — Champs civils sur les collaborateurs (données sensibles RGPD)
alter table public.employees
  add column if not exists birth_date              date,
  add column if not exists birth_place             text,
  add column if not exists nationality             text,
  add column if not exists social_security_number  text,
  add column if not exists residency_permit_number text,
  add column if not exists residency_permit_expires date;
