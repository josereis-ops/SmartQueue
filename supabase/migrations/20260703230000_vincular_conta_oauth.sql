-- Smart Queue v2 — MS-07b: vincular conta Google OAuth ao registo pré-provisionado por email
--
-- Gestão cria email em utilizadores; no 1.º login Google o auth.uid() é novo.
-- Esta função migra o registo do placeholder para o UUID real da sessão.

CREATE OR REPLACE FUNCTION public.vincular_conta_oauth()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid   UUID := auth.uid();
  v_email TEXT;
  v_old   public.utilizadores%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem sessão');
  END IF;

  IF EXISTS (SELECT 1 FROM public.utilizadores WHERE id = v_uid) THEN
    RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Já vinculado');
  END IF;

  SELECT lower(trim(email))
  INTO v_email
  FROM auth.users
  WHERE id = v_uid;

  IF v_email IS NULL OR v_email = '' THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Email não encontrado na sessão');
  END IF;

  SELECT *
  INTO v_old
  FROM public.utilizadores u
  WHERE lower(trim(u.email)) = v_email
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', 'Não tens acesso ao sistema.'
    );
  END IF;

  IF v_old.id = v_uid THEN
    RETURN jsonb_build_object('sucesso', true);
  END IF;

  -- Migrar referências para o UUID OAuth antes de remover o registo antigo
  UPDATE public.casos
  SET colaborador_id = v_uid
  WHERE colaborador_id = v_old.id;

  UPDATE public.notificacoes
  SET destinatario_id = v_uid
  WHERE destinatario_id = v_old.id;

  UPDATE public.notificacoes
  SET remetente_id = v_uid
  WHERE remetente_id = v_old.id;

  UPDATE public.eventos_caso
  SET actor_id = v_uid
  WHERE actor_id = v_old.id;

  DELETE FROM public.utilizadores WHERE id = v_old.id;

  INSERT INTO public.utilizadores (
    id, area_id, equipa_id, email, nome, role, perfil_id, presenca, ultimo_ping, criado_em
  ) VALUES (
    v_uid, v_old.area_id, v_old.equipa_id, v_old.email, v_old.nome,
    v_old.role, v_old.perfil_id, v_old.presenca, v_old.ultimo_ping, v_old.criado_em
  );

  -- Remover auth placeholder da gestão (se existir e for diferente)
  DELETE FROM auth.users WHERE id = v_old.id AND id <> v_uid;

  RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Conta vinculada');
END;
$$;

GRANT EXECUTE ON FUNCTION public.vincular_conta_oauth() TO authenticated;

-- get_perfil_utilizador: tentar vincular por email antes de rejeitar
CREATE OR REPLACE FUNCTION public.get_perfil_utilizador()
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user RECORD;
  v_link JSONB;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', 'Sessão expirada. Faz F5.',
      'email_tentativa', NULL
    );
  END IF;

  SELECT
    u.id,
    u.email,
    u.nome,
    u.area_id,
    u.equipa_id,
    u.presenca,
    u.role,
    p.slug   AS perfil_slug,
    p.nome   AS perfil_nome,
    a.nome   AS area_nome,
    a.slug   AS area_slug,
    e.nome   AS equipa_nome,
    e.codigo AS equipa_codigo
  INTO v_user
  FROM public.utilizadores u
  LEFT JOIN public.perfis p ON p.id = u.perfil_id
  JOIN public.areas a ON a.id = u.area_id
  JOIN public.equipas e ON e.id = u.equipa_id
  WHERE u.id = auth.uid();

  IF NOT FOUND THEN
    v_link := public.vincular_conta_oauth();

    IF COALESCE((v_link->>'sucesso')::boolean, false) THEN
      SELECT
        u.id,
        u.email,
        u.nome,
        u.area_id,
        u.equipa_id,
        u.presenca,
        u.role,
        p.slug   AS perfil_slug,
        p.nome   AS perfil_nome,
        a.nome   AS area_nome,
        a.slug   AS area_slug,
        e.nome   AS equipa_nome,
        e.codigo AS equipa_codigo
      INTO v_user
      FROM public.utilizadores u
      LEFT JOIN public.perfis p ON p.id = u.perfil_id
      JOIN public.areas a ON a.id = u.area_id
      JOIN public.equipas e ON e.id = u.equipa_id
      WHERE u.id = auth.uid();
    END IF;
  END IF;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', COALESCE(v_link->>'mensagem', 'Não tens acesso ao sistema.'),
      'email_tentativa', (SELECT email FROM auth.users WHERE id = auth.uid())
    );
  END IF;

  RETURN jsonb_build_object(
    'sucesso', true,
    'utilizador', jsonb_build_object(
      'id', v_user.id,
      'email', v_user.email,
      'nome', v_user.nome,
      'perfil', COALESCE(v_user.perfil_nome, initcap(v_user.role::text)),
      'perfil_slug', COALESCE(v_user.perfil_slug, v_user.role::text),
      'area_id', v_user.area_id,
      'area', v_user.area_nome,
      'equipa_id', v_user.equipa_id,
      'equipa', v_user.equipa_nome,
      'presenca', v_user.presenca,
      'is_supervisao', (
        public.has_permissao('supervisao.dashboard')
        OR public.has_permissao('casos.ver_area')
      )
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_perfil_utilizador() TO authenticated;
