-- MS-24: Jobs agendados no Supabase (pg_cron + pg_net)
-- Vercel = frontend estático; sem crons serverless.
--
-- Verificação (Dashboard SQL):
--   SELECT jobid, jobname, schedule, command, active FROM cron.job ORDER BY jobname;
--   SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;
--
-- Secrets Vault (pg_cron → Edge Function import-evalyze):
--   SELECT vault.create_secret('<CRON_SECRET>', 'cron_secret', 'Bearer para pg_net invocar import-evalyze');
-- Edge Function secrets (supabase secrets set …):
--   CRON_SECRET, EVALYZE_AREA_ID, EVALYZE_SHEET_ID,
--   GOOGLE_SERVICE_ACCOUNT_EMAIL, GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY
-- Vercel (só UI): NEXT_PUBLIC_SUPABASE_* — sem credenciais Google

-- pg_cron: já activado manualmente no projeto; só criar se em falta (evita erro de privilégios).
DO $ext$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    CREATE EXTENSION pg_cron WITH SCHEMA pg_catalog;
  END IF;
END;
$ext$;

DO $ext$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    CREATE EXTENSION pg_net WITH SCHEMA extensions;
  END IF;
END;
$ext$;

-- Invoca Edge Function import-evalyze (1h). Sem secret no Vault → aviso e skip.
CREATE OR REPLACE FUNCTION public._cron_invoke_import_evalyze()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_url    TEXT := 'https://gwjfwdbwydwtkxffhysb.supabase.co/functions/v1/import-evalyze';
  v_secret TEXT;
BEGIN
  BEGIN
    SELECT decrypted_secret INTO v_secret
    FROM vault.decrypted_secrets
    WHERE name = 'cron_secret'
    LIMIT 1;
  EXCEPTION
    WHEN undefined_table OR invalid_schema_name THEN
      v_secret := NULL;
  END;

  IF v_secret IS NULL OR trim(v_secret) = '' THEN
    RAISE WARNING 'MS-24 import-evalyze: cron_secret em falta no Vault — job ignorado.';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || trim(v_secret)
    ),
    body := '{}'::jsonb
  );
END;
$$;

REVOKE ALL ON FUNCTION public._cron_invoke_import_evalyze() FROM PUBLIC;

-- libertar_suspensos_fantasma: cada 5 min (paridade com GAS / Dashboard manual)
DO $ms24$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'libertar_suspensos_fantasma') THEN
    PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname = 'libertar_suspensos_fantasma' LIMIT 1));
  END IF;

  PERFORM cron.schedule(
    'libertar_suspensos_fantasma',
    '*/5 * * * *',
    $job$SELECT public.libertar_suspensos_fantasma(90)$job$
  );
END;
$ms24$;

-- import-evalyze: cada hora (réplica GAS configurarTriggerImportacaoEvalyze)
DO $ms24$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'import_evalyze_hourly') THEN
    PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname = 'import_evalyze_hourly' LIMIT 1));
  END IF;

  PERFORM cron.schedule(
    'import_evalyze_hourly',
    '0 * * * *',
    $job$SELECT public._cron_invoke_import_evalyze()$job$
  );
END;
$ms24$;
