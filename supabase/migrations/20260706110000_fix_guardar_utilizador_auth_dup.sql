-- Corrige guardar_utilizador quando auth.users OAuth já tem o email
-- (duplicate key users_email_partial_key ao editar/criar utilizador)

CREATE OR REPLACE FUNCTION public._fundir_utilizador_auth_id(
  p_old_id UUID,
  p_new_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old public.utilizadores%ROWTYPE;
BEGIN
  IF p_old_id IS NULL OR p_new_id IS NULL OR p_old_id = p_new_id THEN
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.utilizadores u WHERE u.id = p_old_id) THEN
    RETURN;
  END IF;

  IF EXISTS (SELECT 1 FROM public.utilizadores u WHERE u.id = p_new_id) THEN
    UPDATE public.casos SET colaborador_id = p_new_id WHERE colaborador_id = p_old_id;
    UPDATE public.notificacoes SET destinatario_id = p_new_id WHERE destinatario_id = p_old_id;
    UPDATE public.notificacoes SET remetente_id = p_new_id WHERE remetente_id = p_old_id;
    UPDATE public.eventos_caso SET actor_id = p_new_id WHERE actor_id = p_old_id;
    DELETE FROM public.utilizador_equipas WHERE utilizador_id = p_old_id;
    DELETE FROM public.utilizadores WHERE id = p_old_id;
    DELETE FROM auth.users WHERE id = p_old_id AND id <> p_new_id;
    RETURN;
  END IF;

  SELECT * INTO v_old FROM public.utilizadores u WHERE u.id = p_old_id;

  UPDATE public.casos SET colaborador_id = p_new_id WHERE colaborador_id = p_old_id;
  UPDATE public.notificacoes SET destinatario_id = p_new_id WHERE destinatario_id = p_old_id;
  UPDATE public.notificacoes SET remetente_id = p_new_id WHERE remetente_id = p_old_id;
  UPDATE public.eventos_caso SET actor_id = p_new_id WHERE actor_id = p_old_id;

  DELETE FROM public.utilizador_equipas WHERE utilizador_id = p_old_id;
  DELETE FROM public.utilizadores WHERE id = p_old_id;

  INSERT INTO public.utilizadores (
    id, area_id, equipa_id, ponto_atendimento_id, email, nome, role, perfil_id, presenca, ultimo_ping, criado_em
  ) VALUES (
    p_new_id, v_old.area_id, v_old.equipa_id, v_old.ponto_atendimento_id, v_old.email, v_old.nome,
    v_old.role, v_old.perfil_id, v_old.presenca, v_old.ultimo_ping, v_old.criado_em
  );

  INSERT INTO public.utilizador_equipas (utilizador_id, equipa_id)
  VALUES (p_new_id, v_old.equipa_id)
  ON CONFLICT (utilizador_id, equipa_id) DO NOTHING;

  DELETE FROM auth.users WHERE id = p_old_id AND id <> p_new_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.guardar_utilizador(
  p_email_original TEXT,
  p_email          TEXT,
  p_nome           TEXT,
  p_ponto_id       UUID DEFAULT NULL,
  p_equipa_id      UUID DEFAULT NULL,
  p_perfil_id      UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id        UUID;
  v_email_orig     TEXT := lower(trim(COALESCE(p_email_original, '')));
  v_email          TEXT := lower(trim(COALESCE(p_email, '')));
  v_nome           TEXT := trim(COALESCE(p_nome, ''));
  v_uid            UUID;
  v_auth_id        UUID;
  v_perfil_slug    TEXT;
  v_role           public.user_role;
  v_instance       UUID;
  v_new_id         UUID := gen_random_uuid();
BEGIN
  IF NOT (
    public.has_permissao_developer()
    OR public.has_permissao('utilizadores.gerir')
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissao para gerir utilizadores.');
  END IF;

  IF v_email = '' OR v_nome = '' THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Email e nome sao obrigatorios.');
  END IF;

  IF p_equipa_id IS NULL THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Skill primaria obrigatoria.');
  END IF;

  v_area_id := public.get_user_area_id();

  IF NOT EXISTS (
    SELECT 1 FROM public.equipas e
    WHERE e.id = p_equipa_id AND e.area_id = v_area_id AND e.ativo
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Skill invalida para esta area.');
  END IF;

  IF p_ponto_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.pontos_atendimento p
    WHERE p.id = p_ponto_id AND p.area_id = v_area_id AND p.ativo
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Ponto de atendimento invalido.');
  END IF;

  IF p_perfil_id IS NOT NULL THEN
    SELECT p.slug INTO v_perfil_slug
    FROM public.perfis p
    WHERE p.id = p_perfil_id
      AND (p.area_id IS NULL OR p.area_id = v_area_id);

    IF v_perfil_slug IS NULL THEN
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Perfil invalido.');
    END IF;

    IF v_perfil_slug = 'developer' AND NOT public.has_permissao_developer() THEN
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Apenas developer pode atribuir perfil developer.');
    END IF;
  ELSE
    v_perfil_slug := 'colaborador';
    p_perfil_id := 'a0000000-0000-4000-8000-000000000001';
  END IF;

  v_role := public._role_from_perfil_slug(v_perfil_slug);

  -- Actualizar existente
  IF v_email_orig <> '' THEN
    SELECT u.id INTO v_uid
    FROM public.utilizadores u
    WHERE u.area_id = v_area_id
      AND lower(trim(u.email)) = v_email_orig;

    IF v_uid IS NULL THEN
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Utilizador nao encontrado.');
    END IF;

    IF v_email <> v_email_orig AND EXISTS (
      SELECT 1 FROM public.utilizadores u
      WHERE lower(trim(u.email)) = v_email AND u.id <> v_uid
    ) THEN
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Ja existe um utilizador com este e-mail!');
    END IF;

    -- Conta OAuth Google pode ter UUID diferente do placeholder em utilizadores
    SELECT au.id INTO v_auth_id
    FROM auth.users au
    WHERE lower(trim(au.email)) = v_email
    LIMIT 1;

    IF v_auth_id IS NOT NULL AND v_auth_id <> v_uid THEN
      PERFORM public._fundir_utilizador_auth_id(v_uid, v_auth_id);
      v_uid := v_auth_id;
    END IF;

    UPDATE public.utilizadores
    SET email = v_email,
        nome = v_nome,
        ponto_atendimento_id = p_ponto_id,
        equipa_id = p_equipa_id,
        perfil_id = p_perfil_id,
        role = v_role
    WHERE id = v_uid;

    IF v_auth_id IS NOT NULL THEN
      UPDATE auth.users
      SET raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('nome', v_nome)
      WHERE id = v_auth_id;

      IF v_email <> v_email_orig
         AND NOT EXISTS (
           SELECT 1 FROM auth.users au
           WHERE lower(trim(au.email)) = v_email AND au.id <> v_auth_id
         )
      THEN
        UPDATE auth.users
        SET email = v_email
        WHERE id = v_auth_id;
      END IF;
    ELSIF EXISTS (SELECT 1 FROM auth.users au WHERE au.id = v_uid) THEN
      IF NOT EXISTS (
        SELECT 1 FROM auth.users au
        WHERE lower(trim(au.email)) = v_email AND au.id <> v_uid
      ) THEN
        UPDATE auth.users
        SET email = v_email,
            raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('nome', v_nome)
        WHERE id = v_uid;
      END IF;
    END IF;

    INSERT INTO public.utilizador_equipas (utilizador_id, equipa_id)
    VALUES (v_uid, p_equipa_id)
    ON CONFLICT (utilizador_id, equipa_id) DO NOTHING;

    RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Utilizador actualizado com sucesso!');
  END IF;

  -- Criar novo
  IF EXISTS (
    SELECT 1 FROM public.utilizadores u WHERE lower(trim(u.email)) = v_email
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Ja existe um utilizador com este e-mail!');
  END IF;

  SELECT au.id INTO v_auth_id
  FROM auth.users au
  WHERE lower(trim(au.email)) = v_email
  LIMIT 1;

  IF v_auth_id IS NOT NULL THEN
    v_new_id := v_auth_id;
  ELSE
    SELECT au.instance_id INTO v_instance FROM auth.users au LIMIT 1;
    IF v_instance IS NULL THEN
      v_instance := '00000000-0000-0000-0000-000000000000'::uuid;
    END IF;

    INSERT INTO auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at, confirmation_token, email_change,
      email_change_token_new, recovery_token, is_anonymous
    ) VALUES (
      v_instance, v_new_id, 'authenticated', 'authenticated',
      v_email, '', NULL,
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('nome', v_nome),
      now(), now(), '', '', '', '', false
    );
  END IF;

  INSERT INTO public.utilizadores (
    id, area_id, equipa_id, ponto_atendimento_id, email, nome, role, perfil_id, presenca
  ) VALUES (
    v_new_id, v_area_id, p_equipa_id, p_ponto_id, v_email, v_nome, v_role, p_perfil_id, 'offline'
  );

  INSERT INTO public.utilizador_equipas (utilizador_id, equipa_id)
  VALUES (v_new_id, p_equipa_id)
  ON CONFLICT (utilizador_id, equipa_id) DO NOTHING;

  RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Novo utilizador criado com sucesso!');
END;
$$;
