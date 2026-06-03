-- =====================================================================
-- Flowtym · 03 — Nettoyage du prototype pl_*
-- À exécuter UNIQUEMENT après que la migration 02 a réussi.
-- ⚠️  DESTRUCTIVE : vérifiez d'abord les compteurs.
-- Les fonctions pl_my_hotels() et pl_touch_updated_at() restent.
-- =====================================================================
drop view  if exists public.pl_staff_month_summary cascade;
drop view  if exists public.pl_daily_totals       cascade;
drop view  if exists public.pl_cp_balance         cascade;
drop table if exists public.pl_entries            cascade;
drop table if exists public.pl_leave_balances     cascade;
drop table if exists public.pl_absence_types      cascade;
