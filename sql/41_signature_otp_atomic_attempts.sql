-- 41_signature_otp_atomic_attempts.sql
-- Incrément atomique du compteur de tentatives OTP (anti brute-force concurrent).
-- Corrige la course read-then-increment de sig-sign/verify_otp : plusieurs
-- requêtes simultanées ne peuvent plus dépasser la limite de 5 tentatives.
-- Appelée par sig-sign (service_role) via sb.rpc('sig_bump_otp_attempts', ...).

CREATE OR REPLACE FUNCTION public.sig_bump_otp_attempts(p_request_id uuid)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_new int;
BEGIN
  UPDATE public.signature_requests
     SET otp_attempts = COALESCE(otp_attempts,0) + 1
   WHERE id = p_request_id
  RETURNING otp_attempts INTO v_new;
  RETURN v_new;
END;
$$;

REVOKE ALL ON FUNCTION public.sig_bump_otp_attempts(uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sig_bump_otp_attempts(uuid) TO service_role;
