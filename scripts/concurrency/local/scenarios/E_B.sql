BEGIN;
SELECT set_config('request.jwt.claim.sub','55555555-5555-5555-5555-555555555555',true);
SELECT pg_sleep(1);
SELECT public.cc_apply('E','B',(SELECT pid FROM cc_map WHERE name='E'),'KEY-E2');
COMMIT;
