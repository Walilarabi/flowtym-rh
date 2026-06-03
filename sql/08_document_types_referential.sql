-- Flowtym RH · 08 — Référentiel des types de documents administratifs
create table if not exists public.document_types (
  code text primary key, label text not null,
  category text not null check (category in ('identity','admin','rh','health','banking','other')),
  has_expiration boolean not null default false,
  alert_days_before int not null default 30,
  required_default boolean not null default false,
  sort_order int not null default 99, active boolean not null default true,
  created_at timestamptz not null default now()
);
insert into public.document_types (code, label, category, has_expiration, alert_days_before, required_default, sort_order) values
  ('cni','Carte nationale d''identité','identity',true,60,true,10),
  ('passport','Passeport','identity',true,60,false,20),
  ('titre_sejour','Titre de séjour','identity',true,90,false,30),
  ('permis_travail','Permis / autorisation de travail','identity',true,90,false,35),
  ('carte_vitale','Carte Vitale','health',false,0,true,40),
  ('visite_med','Visite médicale','health',true,60,true,45),
  ('rib','RIB','banking',false,0,true,50),
  ('domicile','Justificatif de domicile','admin',true,90,true,60),
  ('hebergement','Attestation d''hébergement','admin',false,0,false,65),
  ('mutuelle','Attestation mutuelle','rh',true,60,false,70),
  ('contrat','Contrat de travail signé','rh',false,0,true,80),
  ('diplome','Diplôme / certification','rh',false,0,false,90),
  ('autre','Autre document','other',false,0,false,99)
on conflict (code) do nothing;
alter table public.document_types enable row level security;
drop policy if exists document_types_read_all on public.document_types;
create policy document_types_read_all on public.document_types for select using (true);
grant select on public.document_types to authenticated;
