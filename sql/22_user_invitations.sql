-- =============================================================================
-- 22_user_invitations.sql
-- Ajoute rh_revoke_user_access() : retire l'accès d'un utilisateur à un hôtel
-- La création/invitation passe par l'Edge Function invite-user (service_role)
-- =============================================================================

-- Révocation d'accès (appelée depuis le frontend par direction/admin_hotel)
CREATE OR REPLACE FUNCTION public.rh_revoke_user_access(p_hotel uuid, p_user_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  my_role   text;
  my_uid    uuid;
BEGIN
  my_role := public.rh_my_role(p_hotel);
  IF my_role IS NULL OR my_role NOT IN ('direction','admin_hotel') THEN
    RAISE EXCEPTION 'Accès refusé : droits administrateur requis' USING ERRCODE = '42501';
  END IF;

  SELECT id INTO my_uid FROM public.users WHERE auth_id = auth.uid() LIMIT 1;
  IF my_uid = p_user_id THEN
    RAISE EXCEPTION 'Vous ne pouvez pas révoquer votre propre accès' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.user_hotels
  WHERE hotel_id = p_hotel AND user_id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Accès introuvable pour cet utilisateur et cet hôtel' USING ERRCODE = 'P0002';
  END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rh_revoke_user_access(uuid, uuid) TO authenticated;
