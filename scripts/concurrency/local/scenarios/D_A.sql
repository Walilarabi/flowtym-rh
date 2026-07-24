BEGIN;
SELECT set_config('request.jwt.claim.sub','55555555-5555-5555-5555-555555555555',true);
SELECT public.cc_apply('D','A',(SELECT pid FROM cc_map WHERE name='D1'),'KEY-D1');
SELECT pg_sleep(3);
COMMIT;
