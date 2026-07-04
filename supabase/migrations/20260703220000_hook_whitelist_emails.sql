-- Smart Queue v2 — MS-07: hook whitelist emails (before-user-created)
--
-- Bloqueia criação de contas Auth para emails fora de public.utilizadores.
-- Réplica GAS: só entra quem gestão já registou na lista.
-- Configurar no Dashboard: Auth → Hooks → before-user-created
--   URI: pg-functions://postgres/public/hook_before_user_created

CREATE OR REPLACE FUNCTION public.hook_before_user_created(event JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email TEXT;
BEGIN
  v_email := lower(trim(COALESCE(event->'user'->>'email', '')));

  IF v_email = '' THEN
    RETURN jsonb_build_object(
      'error', jsonb_build_object(
        'http_code', 400,
        'message', 'Email obrigatório para autenticação.'
      )
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.utilizadores u
    WHERE lower(trim(u.email)) = v_email
  ) THEN
    RETURN jsonb_build_object(
      'error', jsonb_build_object(
        'http_code', 403,
        'message', 'Não tens acesso ao sistema.'
      )
    );
  END IF;

  RETURN '{}'::jsonb;
END;
$$;

REVOKE ALL ON FUNCTION public.hook_before_user_created(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.hook_before_user_created(JSONB) TO supabase_auth_admin;
