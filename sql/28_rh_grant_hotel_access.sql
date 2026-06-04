-- Fonction atomique : upsert public.users + user_hotels lors d'une invitation
CREATE OR REPLACE FUNCTION public.rh_grant_hotel_access(
  p_auth_id   uuid,
  p_email     text,
  p_full_name text,
  p_hotel_id  uuid,
  p_role      admin_user_role
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  INSERT INTO public.users (auth_id, email, full_name, hotel_id, role)
  VALUES (p_auth_id, p_email, COALESCE(NULLIF(p_full_name,''), p_email), p_hotel_id, p_role)
  ON CONFLICT (auth_id) DO UPDATE
    SET email     = EXCLUDED.email,
        full_name = COALESCE(NULLIF(EXCLUDED.full_name,''), EXCLUDED.email)
  RETURNING id INTO v_user_id;

  INSERT INTO public.user_hotels (user_id, hotel_id, role)
  VALUES (v_user_id, p_hotel_id, p_role)
  ON CONFLICT (user_id, hotel_id) DO UPDATE
    SET role = EXCLUDED.role;

  RETURN v_user_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.rh_grant_hotel_access FROM PUBLIC, anon, authenticated;
