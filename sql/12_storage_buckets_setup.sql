-- Flowtym RH · 12 — Buckets Supabase Storage (hr-templates + hr-documents) avec RLS par hôtel
-- Convention : la première partie du path = UUID de l'hôtel
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('hr-templates','hr-templates',false,5242880,array['text/html','application/pdf','application/vnd.openxmlformats-officedocument.wordprocessingml.document']),
  ('hr-documents','hr-documents',false,10485760,array['application/pdf','image/jpeg','image/png','image/heic','image/webp'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- 8 policies : SELECT/INSERT/UPDATE/DELETE × 2 buckets, toutes vérifient
-- que la première partie du path est un UUID d'hôtel auquel l'utilisateur a accès
do $$
declare bkt text; act text;
begin
  for bkt in select unnest(array['hr-templates','hr-documents']) loop
    for act in select unnest(array['select','insert','update','delete']) loop
      execute format($p$
        drop policy if exists "%1$s_%2$s_own_hotel" on storage.objects;
        create policy "%1$s_%2$s_own_hotel" on storage.objects for %2$s
        %3$s (
          bucket_id = '%1$s'
          and case when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                   then (storage.foldername(name))[1]::uuid in (select public.pl_my_hotels())
                   else false end
        );
      $p$, replace(bkt,'-','_'), act, case when act='insert' then 'with check' else 'using' end);
    end loop;
  end loop;
end $$;
