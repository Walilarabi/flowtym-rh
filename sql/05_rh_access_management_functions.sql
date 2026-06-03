-- =====================================================================
-- Flowtym RH · 05 — Fonctions de gestion des accès par hôtel
-- Trois RPC SECURITY DEFINER pour le module RH. Vérifient le rôle de
-- l'appelant. N'affectent ni le PMS, ni les policies existantes.
-- =====================================================================

create or replace function public.rh_my_role(p_hotel uuid)
returns text
language sql stable security definer
set search_path = public
as $$
  select uh.role::text
  from public.user_hotels uh
  join public.users u on u.id = uh.user_id
  where u.auth_id = auth.uid()
    and uh.hotel_id = p_hotel
  limit 1
$$;
grant execute on function public.rh_my_role(uuid) to authenticated;

create or replace function public.rh_list_users_for_hotel(p_hotel uuid)
returns table(user_id uuid, email text, full_name text, role text, is_default boolean, granted_at timestamptz)
language plpgsql stable security definer
set search_path = public
as $$
declare my_role text;
begin
  my_role := public.rh_my_role(p_hotel);
  if my_role is null or my_role not in ('direction','admin_hotel') then
    raise exception 'Accès refusé : seuls les administrateurs peuvent consulter la liste des accès' using errcode = '42501';
  end if;
  return query
  select u.id, u.email, u.full_name, uh.role::text, uh.is_default, uh.granted_at
  from public.user_hotels uh
  join public.users u on u.id = uh.user_id
  where uh.hotel_id = p_hotel
  order by u.full_name nulls last, u.email;
end;
$$;
grant execute on function public.rh_list_users_for_hotel(uuid) to authenticated;

create or replace function public.rh_update_user_role(p_hotel uuid, p_user_id uuid, p_role text)
returns void
language plpgsql security definer
set search_path = public
as $$
declare my_role text; my_user_id uuid;
begin
  my_role := public.rh_my_role(p_hotel);
  if my_role is null or my_role not in ('direction','admin_hotel') then
    raise exception 'Accès refusé : seuls les administrateurs peuvent modifier les rôles' using errcode = '42501';
  end if;

  select id into my_user_id from public.users where auth_id = auth.uid() limit 1;
  if my_user_id = p_user_id then
    raise exception 'Vous ne pouvez pas modifier votre propre rôle. Demandez à un autre administrateur.' using errcode = '42501';
  end if;

  if p_role not in ('reception','gouvernante','femme_de_chambre','maintenance','breakfast','direction','admin_hotel','comptabilite','revenue_manager') then
    raise exception 'Rôle inconnu : %', p_role using errcode = '22023';
  end if;

  update public.user_hotels
     set role = p_role::admin_user_role
   where hotel_id = p_hotel and user_id = p_user_id;

  if not found then
    raise exception 'Utilisateur introuvable dans cet hôtel' using errcode = 'P0002';
  end if;
end;
$$;
grant execute on function public.rh_update_user_role(uuid, uuid, text) to authenticated;
