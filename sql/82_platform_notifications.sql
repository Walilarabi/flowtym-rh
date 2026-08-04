-- ============================================================================
-- sql/82_platform_notifications.sql
-- Lot 2 — Fondation transverse platform_notifications (ADR-012 §3.0)
--
-- File de notifications métier (pas une file de tâches générique). Aucun
-- accès client (anon/authenticated) — service_role uniquement, jamais
-- invoquée directement, seulement via l'Edge Function platform-send-notification.
-- Idempotence stricte par dedupe_key UNIQUE. Retries bornés (max_attempts).
-- Pas de cron (déclenchement manuel/Edge Function uniquement).
--
-- Pas de BEGIN/COMMIT/ROLLBACK (doctrine sql/80/sql/81). SQL pur, sans
-- méta-commande client — compatible apply_migration.
-- ============================================================================

DO $create_platform_notifications$
DECLARE
  v_exists boolean;
BEGIN
  SELECT EXISTS (SELECT 1 FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='platform_notifications' AND relkind='r')
    INTO v_exists;

  IF NOT v_exists THEN
    RAISE NOTICE '[platform_notifications] absente — création.';

    EXECUTE $ddl$
      CREATE TABLE public.platform_notifications (
        id uuid NOT NULL DEFAULT gen_random_uuid(),
        category text NOT NULL,
        reference_type text NOT NULL,
        reference_id uuid NOT NULL,
        dedupe_key text NOT NULL,
        channel text NOT NULL DEFAULT 'email',
        recipient_email text NOT NULL,
        template text NOT NULL,
        template_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
        status text NOT NULL DEFAULT 'pending',
        attempts integer NOT NULL DEFAULT 0,
        max_attempts integer NOT NULL DEFAULT 3,
        next_attempt_at timestamptz,
        last_error text,
        final_error text,
        created_at timestamptz NOT NULL DEFAULT now(),
        processed_at timestamptz,
        sent_at timestamptz,
        failed_at timestamptz,
        CONSTRAINT platform_notifications_pkey PRIMARY KEY (id),
        CONSTRAINT platform_notifications_dedupe_key_key UNIQUE (dedupe_key),
        CONSTRAINT platform_notifications_category_check CHECK (category IN ('dunning','trial_ending','support_ticket_update','support_ticket_new')),
        CONSTRAINT platform_notifications_channel_check CHECK (channel = 'email'),
        CONSTRAINT platform_notifications_status_check CHECK (status IN ('pending','sending','sent','failed','abandoned')),
        CONSTRAINT platform_notifications_attempts_check CHECK (attempts >= 0),
        CONSTRAINT platform_notifications_max_attempts_check CHECK (max_attempts > 0)
      )
    $ddl$;

    EXECUTE $ddl$ CREATE INDEX idx_platform_notifications_pending ON public.platform_notifications USING btree (status, next_attempt_at) WHERE status IN ('pending') $ddl$;
    EXECUTE $ddl$ CREATE INDEX idx_platform_notifications_reference ON public.platform_notifications USING btree (reference_type, reference_id) $ddl$;
    EXECUTE $ddl$ CREATE INDEX idx_platform_notifications_created ON public.platform_notifications USING btree (created_at DESC) $ddl$;

    EXECUTE $ddl$ COMMENT ON TABLE public.platform_notifications IS 'Lot 2 (ADR-012 §3.0) — file de notifications métier centralisée. Idempotence stricte via dedupe_key. Aucun accès client (service_role uniquement, via Edge Function platform-send-notification). Pas de cron.' $ddl$;

    EXECUTE $ddl$ ALTER TABLE public.platform_notifications ENABLE ROW LEVEL SECURITY $ddl$;
    -- Aucune policy créée volontairement : RLS activée + zéro policy = zéro accès pour
    -- anon/authenticated (même en cas d'erreur de grant future, défense en profondeur).
    -- service_role bypasse RLS par construction (rolbypassrls=true).

    EXECUTE $ddl$ REVOKE ALL ON public.platform_notifications FROM PUBLIC, anon, authenticated $ddl$;
    EXECUTE $ddl$ GRANT SELECT, INSERT, UPDATE ON public.platform_notifications TO service_role $ddl$;

    RAISE NOTICE '[platform_notifications] création terminée.';
  ELSE
    -- Vérification minimale de non-divergence (table déjà présente — ne devrait
    -- survenir qu'en cas de rejeu ; pas de fingerprint complet ici, contrairement
    -- à sql/80, car ce n'est pas une rétro-versionnement d'un existant de
    -- production mais la création normale d'un objet Phase 2 nouveau).
    IF (SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='platform_notifications') <> 19 THEN
      RAISE EXCEPTION '[platform_notifications] la table existe déjà mais son nombre de colonnes diverge de ce qui est attendu (19). Aucune correction automatique — vérifier manuellement avant de rejouer cette migration.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.platform_notifications'::regclass AND conname='platform_notifications_dedupe_key_key') THEN
      RAISE EXCEPTION '[platform_notifications] la contrainte UNIQUE(dedupe_key) est absente sur une table déjà existante — état inattendu, aucune correction automatique.';
    END IF;
    RAISE NOTICE '[platform_notifications] déjà présente et conforme — aucune action.';
  END IF;
END
$create_platform_notifications$;
