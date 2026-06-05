-- Migration 29 : Module Contrats complet (DPAE, generated_contracts, améliorations contract_templates)

-- 1. Enrichir la table hotels avec les infos établissement
ALTER TABLE public.hotels
  ADD COLUMN IF NOT EXISTS siret text,
  ADD COLUMN IF NOT EXISTS ape_code text,
  ADD COLUMN IF NOT EXISTS address text,
  ADD COLUMN IF NOT EXISTS urssaf_office text,
  ADD COLUMN IF NOT EXISTS siret_verified boolean DEFAULT false;

-- 2. Enrichir contract_templates
ALTER TABLE public.contract_templates
  DROP CONSTRAINT IF EXISTS contract_templates_status_check;
ALTER TABLE public.contract_templates
  ADD COLUMN IF NOT EXISTS service_name text,
  ADD COLUMN IF NOT EXISTS collective_agreement text DEFAULT 'HCR – Hôtels Cafés Restaurants',
  ADD COLUMN IF NOT EXISTS source_file_url text,
  ADD COLUMN IF NOT EXISTS variables_json jsonb DEFAULT '[]';
ALTER TABLE public.contract_templates
  ADD CONSTRAINT contract_templates_status_check
  CHECK (status IN ('draft','active','archived'));

-- 3. Table des contrats générés
CREATE TABLE IF NOT EXISTS public.generated_contracts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id uuid NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  template_id uuid REFERENCES public.contract_templates(id) ON DELETE SET NULL,
  contract_number text NOT NULL,
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft','generated','preview_ok','sent_signature','pending_signature','signed','archived','cancelled','error_yousign')),
  contract_type text,
  start_date date,
  end_date date,
  weekly_hours numeric(5,1),
  monthly_hours numeric(6,1),
  salary_type text CHECK (salary_type IN ('brut_mensuel','taux_horaire')),
  salary_amount numeric(10,2),
  trial_period text,
  work_location text,
  manager_id uuid REFERENCES public.employees(id) ON DELETE SET NULL,
  generated_html text,
  generated_pdf_url text,
  signed_pdf_url text,
  yousign_sr_id text,
  yousign_status text,
  signature_method text DEFAULT 'email' CHECK (signature_method IN ('email','portal','both')),
  sent_at timestamptz,
  signed_at timestamptz,
  archived_at timestamptz,
  created_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.generated_contracts ENABLE ROW LEVEL SECURITY;
CREATE POLICY gc_hotel_isolation ON public.generated_contracts FOR ALL
  USING (hotel_id IN (SELECT public.pl_my_hotels()))
  WITH CHECK (hotel_id IN (SELECT public.pl_my_hotels()));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.generated_contracts TO authenticated;

DROP TRIGGER IF EXISTS generated_contracts_touch ON public.generated_contracts;
CREATE TRIGGER generated_contracts_touch BEFORE UPDATE ON public.generated_contracts
  FOR EACH ROW EXECUTE FUNCTION public.pl_touch_updated_at();

-- Sequence for contract numbers
CREATE SEQUENCE IF NOT EXISTS public.contract_number_seq START 1000;

-- Function to generate contract number
CREATE OR REPLACE FUNCTION public.next_contract_number(p_hotel_id uuid)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  year_part text := to_char(now(), 'YYYY');
  seq_val int;
BEGIN
  seq_val := nextval('public.contract_number_seq');
  RETURN 'CTR-' || year_part || '-' || lpad(seq_val::text, 4, '0');
END;
$$;

-- 4. Table DPAE
CREATE TABLE IF NOT EXISTS public.dpae_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id uuid NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft','transmitted','cancelled','error')),
  start_date date,
  due_date date,
  submitted_at timestamptz,
  receipt_number text,
  urssaf_url text,
  notes text,
  created_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.dpae_records ENABLE ROW LEVEL SECURITY;
CREATE POLICY dpae_hotel_isolation ON public.dpae_records FOR ALL
  USING (hotel_id IN (SELECT public.pl_my_hotels()))
  WITH CHECK (hotel_id IN (SELECT public.pl_my_hotels()));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.dpae_records TO authenticated;

DROP TRIGGER IF EXISTS dpae_records_touch ON public.dpae_records;
CREATE TRIGGER dpae_records_touch BEFORE UPDATE ON public.dpae_records
  FOR EACH ROW EXECUTE FUNCTION public.pl_touch_updated_at();
