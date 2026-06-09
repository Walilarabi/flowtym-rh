-- Migration 37 : Bucket Storage pour PDFs de contrats signés
-- Bucket privé "contracts" — accès via signed URLs (10 ans depuis l'Edge Function)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'contracts',
  'contracts',
  false,
  10485760, -- 10 MB
  ARRAY['application/pdf']
)
ON CONFLICT (id) DO UPDATE SET
  public = false,
  file_size_limit = 10485760,
  allowed_mime_types = ARRAY['application/pdf'];
