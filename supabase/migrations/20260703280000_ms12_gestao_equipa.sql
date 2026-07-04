-- MS-12: Gestao de Equipa & Estrutura — RPCs + seed regras_fila SU Eletricidade
-- Replica GAS: obterDadosGestaoEquipa, guardarUtilizadorServidor, eliminarUtilizadorServidor,
--              atualizarListaSistema, regras_fila.config por area

-- ---------------------------------------------------------------------------
-- Fix vincular_conta_oauth: preservar ponto_atendimento_id (MS-10b)
-- ---------------------------------------------------------------------------

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
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem sessao');
  END IF;

  IF EXISTS (SELECT 1 FROM public.utilizadores WHERE id = v_uid) THEN
    RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Ja vinculado');
  END IF;

  SELECT lower(trim(email))
  INTO v_email
  FROM auth.users
  WHERE id = v_uid;

  IF v_email IS NULL OR v_email = '' THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Email nao encontrado na sessao');
  END IF;

  SELECT *
  INTO v_old
  FROM public.utilizadores u
  WHERE lower(trim(u.email)) = v_email
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', 'Nao tens acesso ao sistema.'
    );
  END IF;

  IF v_old.id = v_uid THEN
    RETURN jsonb_build_object('sucesso', true);
  END IF;

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

  UPDATE public.utilizador_equipas
  SET utilizador_id = v_uid
  WHERE utilizador_id = v_old.id;

  DELETE FROM public.utilizadores WHERE id = v_old.id;

  INSERT INTO public.utilizadores (
    id, area_id, equipa_id, ponto_atendimento_id, email, nome, role, perfil_id,
    presenca, ultimo_ping, criado_em
  ) VALUES (
    v_uid, v_old.area_id, v_old.equipa_id, v_old.ponto_atendimento_id, v_old.email, v_old.nome,
    v_old.role, v_old.perfil_id, v_old.presenca, v_old.ultimo_ping, v_old.criado_em
  );

  DELETE FROM auth.users WHERE id = v_old.id AND id <> v_uid;

  RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Conta vinculada');
END;
$$;

-- ---------------------------------------------------------------------------
-- Helper: role legacy a partir do slug do perfil
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._role_from_perfil_slug(p_slug TEXT)
RETURNS public.user_role
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_slug TEXT := lower(trim(COALESCE(p_slug, '')));
BEGIN
  IF v_slug = 'developer' THEN
    RETURN 'developer'::public.user_role;
  END IF;
  IF v_slug IN ('supervisor', 'coordenador', 'admin') THEN
    RETURN 'supervisor'::public.user_role;
  END IF;
  RETURN 'colaborador'::public.user_role;
END;
$$;

-- ---------------------------------------------------------------------------
-- obter_dados_gestao_equipa
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obter_dados_gestao_equipa()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id UUID;
  v_users   JSONB := '[]'::jsonb;
  v_pontos  JSONB := '[]'::jsonb;
  v_skills  JSONB := '[]'::jsonb;
  v_perfis  JSONB := '[]'::jsonb;
  v_config  JSONB := '{}'::jsonb;
BEGIN
  IF NOT (
    public.has_permissao_developer()
    OR public.has_permissao('utilizadores.gerir')
    OR public.has_permissao('admin.equipas')
    OR public.has_permissao('admin.regras_fila')
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissao para gestao de equipa.');
  END IF;

  v_area_id := public.get_user_area_id();

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', u.id,
      'email', u.email,
      'nome', u.nome,
      'ponto_atendimento_id', u.ponto_atendimento_id,
      'ponto_nome', pt.nome,
      'equipa_id', u.equipa_id,
      'equipa_nome', eq.nome,
      'perfil_id', u.perfil_id,
      'perfil_nome', COALESCE(p.nome, initcap(u.role::text)),
      'perfil_slug', COALESCE(p.slug, u.role::text),
      'role', u.role::text,
      'tem_auth', EXISTS (SELECT 1 FROM auth.users au WHERE au.id = u.id)
    )
    ORDER BY u.nome
  ), '[]'::jsonb)
  INTO v_users
  FROM public.utilizadores u
  LEFT JOIN public.pontos_atendimento pt ON pt.id = u.ponto_atendimento_id
  LEFT JOIN public.equipas eq ON eq.id = u.equipa_id
  LEFT JOIN public.perfis p ON p.id = u.perfil_id
  WHERE u.area_id = v_area_id;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object('id', p.id, 'nome', p.nome, 'codigo', p.codigo, 'ativo', p.ativo)
    ORDER BY p.nome
  ), '[]'::jsonb)
  INTO v_pontos
  FROM public.pontos_atendimento p
  WHERE p.area_id = v_area_id;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object('id', e.id, 'nome', e.nome, 'codigo', e.codigo, 'ativo', e.ativo)
    ORDER BY e.nome
  ), '[]'::jsonb)
  INTO v_skills
  FROM public.equipas e
  WHERE e.area_id = v_area_id;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', p.id,
      'nome', p.nome,
      'slug', p.slug,
      'is_system', p.is_system,
      'utilizadores', (
        SELECT count(*)::int
        FROM public.utilizadores u
        WHERE u.perfil_id = p.id AND u.area_id = v_area_id
      )
    )
    ORDER BY p.nome
  ), '[]'::jsonb)
  INTO v_perfis
  FROM public.perfis p
  WHERE p.area_id IS NULL OR p.area_id = v_area_id;

  SELECT COALESCE(rf.config, '{}'::jsonb)
  INTO v_config
  FROM public.regras_fila rf
  WHERE rf.area_id = v_area_id;

  RETURN jsonb_build_object(
    'sucesso', true,
    'utilizadores', v_users,
    'pontos', v_pontos,
    'skills', v_skills,
    'perfis', v_perfis,
    'regras_fila', v_config,
    'permissoes', jsonb_build_object(
      'gerir_utilizadores', public.has_permissao_developer() OR public.has_permissao('utilizadores.gerir'),
      'gerir_equipas', public.has_permissao_developer() OR public.has_permissao('admin.equipas'),
      'gerir_regras', public.has_permissao_developer() OR public.has_permissao('admin.regras_fila'),
      'gerir_perfis', public.has_permissao_gerir_perfis()
    )
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- guardar_utilizador — replica guardarUtilizadorServidor
-- ---------------------------------------------------------------------------

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

    UPDATE public.utilizadores
    SET email = v_email,
        nome = v_nome,
        ponto_atendimento_id = p_ponto_id,
        equipa_id = p_equipa_id,
        perfil_id = p_perfil_id,
        role = v_role
    WHERE id = v_uid;

    UPDATE auth.users
    SET email = v_email,
        raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('nome', v_nome)
    WHERE id = v_uid;

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

-- ---------------------------------------------------------------------------
-- eliminar_utilizador — replica eliminarUtilizadorServidor
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.eliminar_utilizador(p_email TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id UUID;
  v_email   TEXT := lower(trim(COALESCE(p_email, '')));
  v_uid     UUID;
BEGIN
  IF NOT (
    public.has_permissao_developer()
    OR public.has_permissao('utilizadores.gerir')
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissao para gerir utilizadores.');
  END IF;

  IF v_email = '' THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Email obrigatorio.');
  END IF;

  v_area_id := public.get_user_area_id();

  SELECT u.id INTO v_uid
  FROM public.utilizadores u
  WHERE u.area_id = v_area_id AND lower(trim(u.email)) = v_email;

  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Utilizador nao encontrado.');
  END IF;

  IF v_uid = auth.uid() THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Nao podes eliminar a tua propria conta.');
  END IF;

  UPDATE public.casos SET colaborador_id = NULL WHERE colaborador_id = v_uid;

  DELETE FROM public.utilizador_equipas WHERE utilizador_id = v_uid;
  DELETE FROM public.utilizadores WHERE id = v_uid;
  DELETE FROM auth.users WHERE id = v_uid;

  RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Utilizador removido com sucesso!');
END;
$$;

-- ---------------------------------------------------------------------------
-- gerir_ponto_atendimento — CRUD pontos
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gerir_ponto_atendimento(
  p_acao   TEXT,
  p_id     UUID DEFAULT NULL,
  p_nome   TEXT DEFAULT NULL,
  p_codigo TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id UUID;
  v_acao    TEXT := lower(trim(COALESCE(p_acao, '')));
  v_nome    TEXT := trim(COALESCE(p_nome, ''));
  v_codigo  TEXT := upper(trim(COALESCE(p_codigo, '')));
  v_new_id  UUID;
BEGIN
  IF NOT (
    public.has_permissao_developer()
    OR public.has_permissao('admin.equipas')
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissao para gerir pontos.');
  END IF;

  v_area_id := public.get_user_area_id();

  IF v_acao = 'adicionar' THEN
    IF v_nome = '' OR v_codigo = '' THEN
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Nome e codigo obrigatorios.');
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.pontos_atendimento p
      WHERE p.area_id = v_area_id AND p.codigo = v_codigo
    ) THEN
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Codigo ja existe nesta area.');
    END IF;

    INSERT INTO public.pontos_atendimento (area_id, nome, codigo, ativo)
    VALUES (v_area_id, v_nome, v_codigo, true)
    RETURNING id INTO v_new_id;

    RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Ponto adicionado!', 'id', v_new_id);
  END IF;

  IF p_id IS NULL THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'ID obrigatorio.');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.pontos_atendimento p
    WHERE p.id = p_id AND p.area_id = v_area_id
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Ponto nao encontrado.');
  END IF;

  IF v_acao = 'editar' THEN
    IF v_nome = '' OR v_codigo = '' THEN
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Nome e codigo obrigatorios.');
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.pontos_atendimento p
      WHERE p.area_id = v_area_id AND p.codigo = v_codigo AND p.id <> p_id
    ) THEN
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Codigo ja existe nesta area.');
    END IF;

    UPDATE public.pontos_atendimento
    SET nome = v_nome, codigo = v_codigo
    WHERE id = p_id;

    RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Ponto actualizado!');
  END IF;

  IF v_acao = 'desactivar' THEN
    UPDATE public.pontos_atendimento SET ativo = false WHERE id = p_id;
    RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Ponto desactivado.');
  END IF;

  IF v_acao = 'activar' THEN
    UPDATE public.pontos_atendimento SET ativo = true WHERE id = p_id;
    RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Ponto activado.');
  END IF;

  RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Accao invalida.');
END;
$$;

-- ---------------------------------------------------------------------------
-- gerir_skill — CRUD equipas (skills master)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gerir_skill(
  p_acao   TEXT,
  p_id     UUID DEFAULT NULL,
  p_nome   TEXT DEFAULT NULL,
  p_codigo TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id UUID;
  v_acao    TEXT := lower(trim(COALESCE(p_acao, '')));
  v_nome    TEXT := trim(COALESCE(p_nome, ''));
  v_codigo  TEXT := upper(trim(COALESCE(p_codigo, '')));
  v_new_id  UUID;
BEGIN
  IF NOT (
    public.has_permissao_developer()
    OR public.has_permissao('admin.equipas')
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissao para gerir skills.');
  END IF;

  v_area_id := public.get_user_area_id();

  IF v_acao = 'adicionar' THEN
    IF v_nome = '' OR v_codigo = '' THEN
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Nome e codigo obrigatorios.');
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.equipas e
      WHERE e.area_id = v_area_id AND e.codigo = v_codigo
    ) THEN
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Codigo ja existe nesta area.');
    END IF;

    INSERT INTO public.equipas (area_id, nome, codigo, ativo)
    VALUES (v_area_id, v_nome, v_codigo, true)
    RETURNING id INTO v_new_id;

    RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Skill adicionada!', 'id', v_new_id);
  END IF;

  IF p_id IS NULL THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'ID obrigatorio.');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.equipas e
    WHERE e.id = p_id AND e.area_id = v_area_id
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Skill nao encontrada.');
  END IF;

  IF v_acao = 'editar' THEN
    IF v_nome = '' OR v_codigo = '' THEN
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Nome e codigo obrigatorios.');
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.equipas e
      WHERE e.area_id = v_area_id AND e.codigo = v_codigo AND e.id <> p_id
    ) THEN
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Codigo ja existe nesta area.');
    END IF;

    UPDATE public.equipas SET nome = v_nome, codigo = v_codigo WHERE id = p_id;
    RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Skill actualizada!');
  END IF;

  IF v_acao = 'desactivar' THEN
    UPDATE public.equipas SET ativo = false WHERE id = p_id;
    RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Skill desactivada.');
  END IF;

  IF v_acao = 'activar' THEN
    UPDATE public.equipas SET ativo = true WHERE id = p_id;
    RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Skill activada.');
  END IF;

  RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Accao invalida.');
END;
$$;

-- ---------------------------------------------------------------------------
-- obter_regras_fila / salvar_regras_fila
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obter_regras_fila()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id UUID;
  v_config  JSONB;
BEGIN
  IF NOT (
    public.has_permissao_developer()
    OR public.has_permissao('admin.regras_fila')
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissao para ver regras de fila.');
  END IF;

  v_area_id := public.get_user_area_id();

  SELECT COALESCE(rf.config, '{}'::jsonb)
  INTO v_config
  FROM public.regras_fila rf
  WHERE rf.area_id = v_area_id;

  RETURN jsonb_build_object('sucesso', true, 'config', COALESCE(v_config, '{}'::jsonb));
END;
$$;

CREATE OR REPLACE FUNCTION public.salvar_regras_fila(p_config JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id UUID;
  v_config  JSONB := COALESCE(p_config, '{}'::jsonb);
  v_nudges  JSONB;
BEGIN
  IF NOT (
    public.has_permissao_developer()
    OR public.has_permissao('admin.regras_fila')
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissao para editar regras de fila.');
  END IF;

  IF jsonb_typeof(v_config) <> 'object' THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Config invalida — objecto JSON esperado.');
  END IF;

  v_area_id := public.get_user_area_id();

  SELECT COALESCE(rf.config->'nudge_mensagens', '[]'::jsonb)
  INTO v_nudges
  FROM public.regras_fila rf
  WHERE rf.area_id = v_area_id;

  IF NOT (v_config ? 'nudge_mensagens') AND v_nudges IS NOT NULL THEN
    v_config := v_config || jsonb_build_object('nudge_mensagens', v_nudges);
  END IF;

  INSERT INTO public.regras_fila (area_id, versao, config)
  VALUES (
    v_area_id,
    COALESCE((v_config->'motor'->>'versao')::int, 2),
    v_config
  )
  ON CONFLICT (area_id) DO UPDATE
  SET config = EXCLUDED.config,
      versao = EXCLUDED.versao,
      atualizado_em = now();

  RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Regras de fila guardadas.');
END;
$$;

-- ---------------------------------------------------------------------------
-- Seed: regras_fila SU Eletricidade — contrato motor v2 (MS-11 consumira)
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_area_id UUID := 'b0000000-0000-4000-8000-000000000001';
  v_motor   JSONB := jsonb_build_object(
    'versao', 2,
    'filtros_elegibilidade', jsonb_build_object(
      'skill', jsonb_build_object('ativo', true, 'fonte', 'utilizador_equipas'),
      'ponto_atendimento', jsonb_build_object(
        'ativo', true,
        'modo', 'mesmo_ponto',
        'aplicar_tiers', jsonb_build_array('scan', 'dono_ausente', 'libertar_14h')
      )
    ),
    'tiers_completos', true,
    'libertar_14h', jsonb_build_object(
      'ativo', true,
      'hora', '14:00',
      'timezone', 'Europe/Lisbon'
    )
  );
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.areas WHERE id = v_area_id) THEN
    RAISE NOTICE 'MS-12: area demo nao encontrada — skip seed regras_fila.';
    RETURN;
  END IF;

  UPDATE public.regras_fila rf
  SET config = (rf.config - 'mvp' - 'tiers_completos') || jsonb_build_object('motor', v_motor),
      versao = 2,
      atualizado_em = now()
  WHERE rf.area_id = v_area_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

GRANT EXECUTE ON FUNCTION public.obter_dados_gestao_equipa() TO authenticated;
GRANT EXECUTE ON FUNCTION public.guardar_utilizador(TEXT, TEXT, TEXT, UUID, UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.eliminar_utilizador(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gerir_ponto_atendimento(TEXT, UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gerir_skill(TEXT, UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obter_regras_fila() TO authenticated;
GRANT EXECUTE ON FUNCTION public.salvar_regras_fila(JSONB) TO authenticated;
