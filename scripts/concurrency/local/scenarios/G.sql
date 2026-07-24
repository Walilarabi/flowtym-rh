SELECT set_config('request.jwt.claim.sub','55555555-5555-5555-5555-555555555555',false);
BEGIN; SELECT public.cc_apply('G','A',(SELECT pid FROM cc_map WHERE name='G'),'KEY-G'); COMMIT;
BEGIN; SELECT public.cc_apply('G','A-retry',(SELECT pid FROM cc_map WHERE name='G'),'KEY-G'); COMMIT;
