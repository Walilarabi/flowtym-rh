-- =============================================================================
-- 21_employee_photo.sql
-- Ajoute photo_url (base64 JPEG redimensionné côté client) sur employees
-- Rejouable : ADD COLUMN IF NOT EXISTS
-- =============================================================================

ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS photo_url text;
