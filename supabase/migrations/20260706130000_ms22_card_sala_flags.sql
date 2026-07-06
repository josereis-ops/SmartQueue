-- MS-22: flags explícitas para card na Sala de Controlo e responsável de equipa
-- Permite developer/coordenador/admin com card e atribuição de colaboradores→supervisor

ALTER TABLE public.utilizadores
  ADD COLUMN IF NOT EXISTS exibir_card_sala BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS e_responsavel_equipa BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.utilizadores.exibir_card_sala IS
  'Mostrar card na Sala de Controlo (independente do perfil de sistema).';
COMMENT ON COLUMN public.utilizadores.e_responsavel_equipa IS
  'Responsável de equipa: secção 👑 e elegível no dropdown de atribuição.';

-- Backfill: colaboradores e supervisores operacionais
UPDATE public.utilizadores u
SET exibir_card_sala = true
FROM public.perfis p
WHERE p.id = u.perfil_id
  AND p.slug IN ('colaborador', 'supervisor');

UPDATE public.utilizadores u
SET e_responsavel_equipa = true
FROM public.perfis p
WHERE p.id = u.perfil_id
  AND p.slug = 'supervisor';

UPDATE public.utilizadores u
SET exibir_card_sala = true,
    e_responsavel_equipa = true
WHERE u.perfil_id IS NULL
  AND u.role IN ('colaborador', 'supervisor');

UPDATE public.utilizadores u
SET e_responsavel_equipa = true
WHERE u.perfil_id IS NULL
  AND u.role = 'supervisor';

CREATE OR REPLACE FUNCTION public._utilizador_exibir_card_sala(
  p_exibir_card BOOLEAN
)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(p_exibir_card, false);
$$;

-- Patch fusão OAuth: copiar flags
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

  IF NOT EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p_new_id) THEN
    RETURN;
  END IF;

  IF EXISTS (SELECT 1 FROM public.utilizadores u WHERE u.id = p_new_id) THEN
    UPDATE public.casos SET colaborador_id = p_new_id WHERE colaborador_id = p_old_id;
    UPDATE public.notificacoes SET destinatario_id = p_new_id WHERE destinatario_id = p_old_id;
    UPDATE public.notificacoes SET remetente_id = p_new_id WHERE remetente_id = p_old_id;
    UPDATE public.eventos_caso SET actor_id = p_new_id WHERE actor_id = p_old_id;
    UPDATE public.utilizadores SET supervisor_id = p_new_id WHERE supervisor_id = p_old_id;
    DELETE FROM public.utilizador_equipas WHERE utilizador_id = p_old_id;
    DELETE FROM public.utilizadores WHERE id = p_old_id;
    DELETE FROM auth.users WHERE id = p_old_id AND id <> p_new_id;
    RETURN;
  END IF;

  SELECT * INTO v_old FROM public.utilizadores u WHERE u.id = p_old_id;

  CREATE TEMP TABLE IF NOT EXISTS _sq_equipas_tmp (
    equipa_id UUID NOT NULL
  ) ON COMMIT DROP;

  DELETE FROM _sq_equipas_tmp;
  INSERT INTO _sq_equipas_tmp (equipa_id)
  SELECT ue.equipa_id
  FROM public.utilizador_equipas ue
  WHERE ue.utilizador_id = p_old_id;

  IF NOT EXISTS (SELECT 1 FROM _sq_equipas_tmp WHERE equipa_id = v_old.equipa_id) THEN
    INSERT INTO _sq_equipas_tmp (equipa_id) VALUES (v_old.equipa_id);
  END IF;

  UPDATE public.casos SET colaborador_id = p_new_id WHERE colaborador_id = p_old_id;
  UPDATE public.notificacoes SET destinatario_id = p_new_id WHERE destinatario_id = p_old_id;
  UPDATE public.notificacoes SET remetente_id = p_new_id WHERE remetente_id = p_old_id;
  UPDATE public.eventos_caso SET actor_id = p_new_id WHERE actor_id = p_old_id;
  UPDATE public.utilizadores SET supervisor_id = p_new_id WHERE supervisor_id = p_old_id;

  DELETE FROM public.utilizador_equipas WHERE utilizador_id = p_old_id;
  DELETE FROM public.utilizadores WHERE id = p_old_id;

  INSERT INTO public.utilizadores (
    id, area_id, equipa_id, ponto_atendimento_id, supervisor_id,
    exibir_card_sala, e_responsavel_equipa,
    email, nome, role, perfil_id, presenca, ultimo_ping, criado_em
  ) VALUES (
    p_new_id, v_old.area_id, v_old.equipa_id, v_old.ponto_atendimento_id, v_old.supervisor_id,
    v_old.exibir_card_sala, v_old.e_responsavel_equipa,
    v_old.email, v_old.nome, v_old.role, v_old.perfil_id, v_old.presenca, v_old.ultimo_ping, v_old.criado_em
  );

  INSERT INTO public.utilizador_equipas (utilizador_id, equipa_id)
  SELECT p_new_id, t.equipa_id
  FROM _sq_equipas_tmp t
  ON CONFLICT (utilizador_id, equipa_id) DO NOTHING;

  DELETE FROM auth.users WHERE id = p_old_id AND id <> p_new_id;
END;
$$;

-- obter_dados_gestao_equipa: expor flags
CREATE OR REPLACE FUNCTION public.obter_dados_gestao_equipa()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id UUID;
  v_users   JSONB;
  v_pontos  JSONB;
  v_skills  JSONB;
  v_perfis  JSONB;
  v_config  JSONB;
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
      'supervisor_id', u.supervisor_id,
      'supervisor_nome', sup.nome,
      'exibir_card_sala', u.exibir_card_sala,
      'e_responsavel_equipa', u.e_responsavel_equipa,
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
  LEFT JOIN public.utilizadores sup ON sup.id = u.supervisor_id
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

CREATE OR REPLACE FUNCTION public.guardar_utilizador(
  p_email_original       TEXT,
  p_email                TEXT,
  p_nome                 TEXT,
  p_ponto_id             UUID DEFAULT NULL,
  p_equipa_id            UUID DEFAULT NULL,
  p_perfil_id            UUID DEFAULT NULL,
  p_supervisor_id        UUID DEFAULT NULL,
  p_exibir_card_sala     BOOLEAN DEFAULT NULL,
  p_e_responsavel_equipa BOOLEAN DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id              UUID;
  v_email_orig           TEXT := lower(trim(COALESCE(p_email_original, '')));
  v_email                TEXT := lower(trim(COALESCE(p_email, '')));
  v_nome                 TEXT := trim(COALESCE(p_nome, ''));
  v_uid                  UUID;
  v_auth_id              UUID;
  v_perfil_slug          TEXT;
  v_role                 public.user_role;
  v_instance             UUID;
  v_new_id               UUID := gen_random_uuid();
  v_supervisor_id        UUID := NULL;
  v_exibir_card          BOOLEAN;
  v_e_responsavel        BOOLEAN;
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

  IF p_exibir_card_sala IS NOT NULL THEN
    v_exibir_card := p_exibir_card_sala;
  ELSIF v_perfil_slug IN ('colaborador', 'supervisor') THEN
    v_exibir_card := true;
  ELSE
    v_exibir_card := false;
  END IF;

  IF p_e_responsavel_equipa IS NOT NULL THEN
    v_e_responsavel := p_e_responsavel_equipa;
  ELSIF v_perfil_slug = 'supervisor' THEN
    v_e_responsavel := true;
  ELSE
    v_e_responsavel := false;
  END IF;

  IF v_perfil_slug = 'colaborador' THEN
    v_e_responsavel := false;
  END IF;

  IF NOT v_exibir_card THEN
    v_e_responsavel := false;
  END IF;

  IF v_perfil_slug = 'colaborador' AND p_supervisor_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.utilizadores sup
      LEFT JOIN public.perfis ps ON ps.id = sup.perfil_id
      WHERE sup.id = p_supervisor_id
        AND sup.area_id = v_area_id
        AND sup.e_responsavel_equipa = true
    ) THEN
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Responsavel de equipa invalido.');
    END IF;
    v_supervisor_id := p_supervisor_id;
  END IF;

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
        role = v_role,
        supervisor_id = CASE WHEN v_perfil_slug = 'colaborador' THEN v_supervisor_id ELSE NULL END,
        exibir_card_sala = v_exibir_card,
        e_responsavel_equipa = v_e_responsavel
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
        UPDATE auth.users SET email = v_email WHERE id = v_auth_id;
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
    id, area_id, equipa_id, ponto_atendimento_id, supervisor_id,
    exibir_card_sala, e_responsavel_equipa,
    email, nome, role, perfil_id, presenca
  ) VALUES (
    v_new_id, v_area_id, p_equipa_id, p_ponto_id,
    CASE WHEN v_perfil_slug = 'colaborador' THEN v_supervisor_id ELSE NULL END,
    v_exibir_card, v_e_responsavel,
    v_email, v_nome, v_role, p_perfil_id, 'offline'
  );

  INSERT INTO public.utilizador_equipas (utilizador_id, equipa_id)
  VALUES (v_new_id, p_equipa_id)
  ON CONFLICT (utilizador_id, equipa_id) DO NOTHING;

  RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Novo utilizador criado com sucesso!');
END;
$$;

-- obter_dados_supervisao: filtrar por exibir_card_sala; isSuper por e_responsavel_equipa
CREATE OR REPLACE FUNCTION public.obter_dados_supervisao(
  p_equipas_filtro  UUID[] DEFAULT NULL,
  p_incluir_listas  BOOLEAN DEFAULT false
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id        UUID;
  v_hoje_inicio    TIMESTAMPTZ;
  v_hoje_fim       TIMESTAMPTZ;
  v_sla_limite     DATE;
  v_equipa         JSONB := '[]'::jsonb;
  v_equipas_master JSONB := '[]'::jsonb;
  v_fila           JSONB;
  v_counts         RECORD;
  v_global_trat    INT := 0;
  v_global_concl   INT := 0;
  v_global_tempo   BIGINT := 0;
  v_tmt_global     TEXT;
  v_tmt_seg        INT;
  v_m              TEXT;
  v_s              TEXT;
  v_lista_vazia    JSONB := '[]'::jsonb;
  v_listas         JSONB;
BEGIN
  IF NOT public.has_permissao('supervisao.dashboard') THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_PERMISSAO',
      'mensagem', 'Sem permissao para aceder a Sala de Controlo.'
    );
  END IF;

  v_area_id := public.get_user_area_id();
  v_hoje_inicio := date_trunc('day', now() AT TIME ZONE 'Europe/Lisbon');
  v_hoje_fim := v_hoje_inicio + interval '23 hours 59 minutes 59 seconds';
  v_sla_limite := public._data_limite_sla();

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object('id', e.id, 'nome', e.nome, 'codigo', e.codigo)
    ORDER BY e.nome
  ), '[]'::jsonb)
  INTO v_equipas_master
  FROM public.equipas e
  WHERE e.area_id = v_area_id AND e.ativo = true;

  SELECT
    COUNT(*) FILTER (WHERE c.status IN ('livre', 'por_tratar'))::int AS livres,
    COUNT(*) FILTER (WHERE c.status NOT IN ('concluido', 'cancelado'))::int AS carteira,
    COUNT(*) FILTER (WHERE c.status = 'outro')::int AS outro,
    COUNT(*) FILTER (WHERE c.status = 'suspenso')::int AS suspensos,
    COUNT(*) FILTER (WHERE
      (c.criado_em AT TIME ZONE 'Europe/Lisbon')::date <= v_sla_limite
      AND c.status IN ('livre', 'por_tratar')
    )::int AS atrasados_livres,
    COUNT(*) FILTER (WHERE
      (c.criado_em AT TIME ZONE 'Europe/Lisbon')::date <= v_sla_limite
      AND c.status NOT IN ('livre', 'por_tratar', 'concluido', 'cancelado')
    )::int AS atrasados_trabalho,
    COUNT(*) FILTER (WHERE
      c.data_rqs IS NOT NULL AND c.intercalar_em IS NULL
      AND (c.data_rqs AT TIME ZONE 'Europe/Lisbon')::date
          < (v_hoje_inicio AT TIME ZONE 'Europe/Lisbon')::date
      AND c.status IN ('livre', 'por_tratar')
    )::int AS rqs_ultrap_livres,
    COUNT(*) FILTER (WHERE
      c.data_rqs IS NOT NULL AND c.intercalar_em IS NULL
      AND (c.data_rqs AT TIME ZONE 'Europe/Lisbon')::date
          < (v_hoje_inicio AT TIME ZONE 'Europe/Lisbon')::date
      AND c.status NOT IN ('livre', 'por_tratar', 'concluido', 'cancelado')
    )::int AS rqs_ultrap_trab,
    COUNT(*) FILTER (WHERE
      c.data_rqs IS NOT NULL AND c.intercalar_em IS NULL
      AND c.data_rqs <= v_hoje_fim
      AND c.status IN ('livre', 'por_tratar')
    )::int AS rqs_hoje_livres,
    COUNT(*) FILTER (WHERE
      c.data_rqs IS NOT NULL AND c.intercalar_em IS NULL
      AND c.data_rqs <= v_hoje_fim
      AND c.status NOT IN ('livre', 'por_tratar', 'concluido', 'cancelado')
    )::int AS rqs_hoje_trab
  INTO v_counts
  FROM public.casos c
  WHERE c.area_id = v_area_id
    AND (p_equipas_filtro IS NULL OR c.equipa_id = ANY(p_equipas_filtro));

  SELECT
    COUNT(DISTINCT ec.caso_id) FILTER (WHERE ec.acao = 'atribuir_tarefa'),
    COUNT(DISTINCT ec.caso_id) FILTER (WHERE ec.acao = 'concluir_caso')
  INTO v_global_trat, v_global_concl
  FROM public.eventos_caso ec
  WHERE ec.area_id = v_area_id
    AND ec.criado_em >= v_hoje_inicio;

  SELECT COALESCE(AVG(
    EXTRACT(EPOCH FROM (ec_fim.criado_em - ec_ini.criado_em))
  )::bigint, 0)
  INTO v_global_tempo
  FROM public.eventos_caso ec_fim
  JOIN public.eventos_caso ec_ini ON ec_ini.caso_id = ec_fim.caso_id
    AND ec_ini.acao = 'atribuir_tarefa'
    AND ec_ini.criado_em <= ec_fim.criado_em
  WHERE ec_fim.area_id = v_area_id
    AND ec_fim.acao = 'concluir_caso'
    AND ec_fim.criado_em >= v_hoje_inicio;

  IF v_global_trat > 0 AND v_global_tempo = 0 THEN
    SELECT COALESCE(AVG(
      EXTRACT(EPOCH FROM (now() - c.inicio_tratamento))
    )::bigint, 0)
    INTO v_global_tempo
    FROM public.casos c
    JOIN public.utilizadores u ON u.id = c.colaborador_id
    WHERE c.area_id = v_area_id
      AND c.status = 'em_tratamento'
      AND c.inicio_tratamento IS NOT NULL
      AND public._presenca_mantem_caso_ativo(u.presenca);
  END IF;

  v_tmt_seg := CASE WHEN v_global_trat > 0 AND v_global_tempo > 0 THEN v_global_tempo::int ELSE 0 END;
  v_m := lpad((v_tmt_seg / 60)::text, 2, '0');
  v_s := lpad((v_tmt_seg % 60)::text, 2, '0');
  v_tmt_global := v_m || ':' || v_s;

  v_fila := jsonb_build_object(
    'livres', COALESCE(v_counts.livres, 0),
    'emTratamento', (
      SELECT COUNT(*)::int
      FROM public.casos c
      JOIN public.utilizadores u ON u.id = c.colaborador_id
      WHERE c.area_id = v_area_id
        AND c.status = 'em_tratamento'
        AND public._presenca_mantem_caso_ativo(u.presenca)
        AND (p_equipas_filtro IS NULL OR c.equipa_id = ANY(p_equipas_filtro))
    ),
    'suspensos', COALESCE(v_counts.suspensos, 0),
    'carteira', COALESCE(v_counts.carteira, 0),
    'outro', COALESCE(v_counts.outro, 0),
    'atrasadosLivres', COALESCE(v_counts.atrasados_livres, 0),
    'atrasadosTrabalho', COALESCE(v_counts.atrasados_trabalho, 0),
    'rqsUltrapassadasLivres', COALESCE(v_counts.rqs_ultrap_livres, 0),
    'rqsUltrapassadasTrabalho', COALESCE(v_counts.rqs_ultrap_trab, 0),
    'rqsHojeLivres', COALESCE(v_counts.rqs_hoje_livres, 0),
    'rqsHojeTrabalho', COALESCE(v_counts.rqs_hoje_trab, 0),
    'tratadasDia', v_global_trat,
    'concluidasDia', v_global_concl,
    'tmtGlobal', v_tmt_global,
    'listaAtrasados', v_lista_vazia,
    'listaRqsUltrapassadas', v_lista_vazia,
    'listaRqsHoje', v_lista_vazia,
    'listaLivres', v_lista_vazia,
    'listaTodos', v_lista_vazia,
    'listaOutro', v_lista_vazia
  );

  IF COALESCE(p_incluir_listas, false) THEN
    SELECT jsonb_build_object(
      'listaLivres', COALESCE((
        SELECT jsonb_agg(public._supervisao_caso_json(c, e.nome, pt.nome, u.email) ORDER BY c.id_externo)
        FROM public.casos c
        JOIN public.equipas e ON e.id = c.equipa_id
        LEFT JOIN public.pontos_atendimento pt ON pt.id = c.ponto_atendimento_id
        LEFT JOIN public.utilizadores u ON u.id = c.colaborador_id
        WHERE c.area_id = v_area_id
          AND (p_equipas_filtro IS NULL OR c.equipa_id = ANY(p_equipas_filtro))
          AND c.status IN ('livre', 'por_tratar')
      ), '[]'::jsonb),
      'listaTodos', COALESCE((
        SELECT jsonb_agg(public._supervisao_caso_json(c, e.nome, pt.nome, u.email) ORDER BY c.id_externo)
        FROM public.casos c
        JOIN public.equipas e ON e.id = c.equipa_id
        LEFT JOIN public.pontos_atendimento pt ON pt.id = c.ponto_atendimento_id
        LEFT JOIN public.utilizadores u ON u.id = c.colaborador_id
        WHERE c.area_id = v_area_id
          AND (p_equipas_filtro IS NULL OR c.equipa_id = ANY(p_equipas_filtro))
          AND c.status NOT IN ('concluido', 'cancelado')
      ), '[]'::jsonb),
      'listaOutro', COALESCE((
        SELECT jsonb_agg(public._supervisao_caso_json(c, e.nome, pt.nome, u.email) ORDER BY c.id_externo)
        FROM public.casos c
        JOIN public.equipas e ON e.id = c.equipa_id
        LEFT JOIN public.pontos_atendimento pt ON pt.id = c.ponto_atendimento_id
        LEFT JOIN public.utilizadores u ON u.id = c.colaborador_id
        WHERE c.area_id = v_area_id
          AND (p_equipas_filtro IS NULL OR c.equipa_id = ANY(p_equipas_filtro))
          AND c.status = 'outro'
      ), '[]'::jsonb),
      'listaAtrasados', COALESCE((
        SELECT jsonb_agg(public._supervisao_caso_json(c, e.nome, pt.nome, u.email) ORDER BY c.id_externo)
        FROM public.casos c
        JOIN public.equipas e ON e.id = c.equipa_id
        LEFT JOIN public.pontos_atendimento pt ON pt.id = c.ponto_atendimento_id
        LEFT JOIN public.utilizadores u ON u.id = c.colaborador_id
        WHERE c.area_id = v_area_id
          AND (p_equipas_filtro IS NULL OR c.equipa_id = ANY(p_equipas_filtro))
          AND public._supervisao_drilldown_match(c, 'atrasados', v_hoje_inicio, v_hoje_fim, v_sla_limite)
      ), '[]'::jsonb),
      'listaRqsUltrapassadas', COALESCE((
        SELECT jsonb_agg(public._supervisao_caso_json(c, e.nome, pt.nome, u.email) ORDER BY c.id_externo)
        FROM public.casos c
        JOIN public.equipas e ON e.id = c.equipa_id
        LEFT JOIN public.pontos_atendimento pt ON pt.id = c.ponto_atendimento_id
        LEFT JOIN public.utilizadores u ON u.id = c.colaborador_id
        WHERE c.area_id = v_area_id
          AND (p_equipas_filtro IS NULL OR c.equipa_id = ANY(p_equipas_filtro))
          AND public._supervisao_drilldown_match(c, 'ultrapassadas', v_hoje_inicio, v_hoje_fim, v_sla_limite)
      ), '[]'::jsonb),
      'listaRqsHoje', COALESCE((
        SELECT jsonb_agg(public._supervisao_caso_json(c, e.nome, pt.nome, u.email) ORDER BY c.id_externo)
        FROM public.casos c
        JOIN public.equipas e ON e.id = c.equipa_id
        LEFT JOIN public.pontos_atendimento pt ON pt.id = c.ponto_atendimento_id
        LEFT JOIN public.utilizadores u ON u.id = c.colaborador_id
        WHERE c.area_id = v_area_id
          AND (p_equipas_filtro IS NULL OR c.equipa_id = ANY(p_equipas_filtro))
          AND public._supervisao_drilldown_match(c, 'hoje', v_hoje_inicio, v_hoje_fim, v_sla_limite)
      ), '[]'::jsonb)
    )
    INTO v_listas;

    v_fila := v_fila || v_listas;
  END IF;

  SELECT COALESCE(jsonb_agg(agente ORDER BY ordem_presenca, nome_ordem), '[]'::jsonb)
  INTO v_equipa
  FROM (
    SELECT
      jsonb_build_object(
        'id', u.id,
        'email', u.email,
        'nome', CASE
          WHEN array_length(string_to_array(trim(u.nome), ' '), 1) > 1 THEN
            (string_to_array(trim(u.nome), ' '))[1] || ' ' ||
            (string_to_array(trim(u.nome), ' '))[array_length(string_to_array(trim(u.nome), ' '), 1)]
          ELSE split_part(trim(u.nome), ' ', 1)
        END,
        'loja', COALESCE(pt.nome, '—'),
        'equipaOp', COALESCE(sk.skills_csv, e.nome, '—'),
        'estado', public._presenca_label(u.presenca),
        'presenca', u.presenca,
        'horaMudanca', COALESCE(
          EXTRACT(EPOCH FROM u.ultimo_ping) * 1000,
          EXTRACT(EPOCH FROM now()) * 1000
        ),
        'tratadas', COALESCE(st_trat.tratadas, 0),
        'concluidas', COALESCE(st_concl.concluidas, 0),
        'tmtFormatado', (
          SELECT lpad((seg / 60)::text, 2, '0') || ':' || lpad((seg % 60)::text, 2, '0')
          FROM (
            SELECT CASE
              WHEN COALESCE(st_tmt.tmt_seg, 0) = 0 AND ca.inicio_tratamento IS NOT NULL
              THEN GREATEST(0, EXTRACT(EPOCH FROM (now() - ca.inicio_tratamento))::int)
              ELSE COALESCE(st_tmt.tmt_seg, 0)
            END AS seg
          ) tmt_calc
        ),
        'tmtSegundos', (
          SELECT CASE
            WHEN COALESCE(st_tmt.tmt_seg, 0) = 0 AND ca.inicio_tratamento IS NOT NULL
            THEN GREATEST(0, EXTRACT(EPOCH FROM (now() - ca.inicio_tratamento))::int)
            ELSE COALESCE(st_tmt.tmt_seg, 0)
          END
        ),
        'isSuper', u.e_responsavel_equipa = true,
        'perfilSlug', COALESCE(p.slug, u.role::text),
        'supervisorId', u.supervisor_id,
        'casoAtivoId', ca.id_externo,
        'casoAtivoCasoId', ca.id,
        'casoAtivoTs', CASE
          WHEN ca.inicio_tratamento IS NOT NULL
          THEN EXTRACT(EPOCH FROM ca.inicio_tratamento) * 1000
          ELSE NULL
        END
      ) AS agente,
      public._presenca_ordem(u.presenca) AS ordem_presenca,
      u.nome AS nome_ordem
    FROM public.utilizadores u
    JOIN public.equipas e ON e.id = u.equipa_id
    LEFT JOIN public.pontos_atendimento pt ON pt.id = u.ponto_atendimento_id
    LEFT JOIN public.perfis p ON p.id = u.perfil_id
    LEFT JOIN LATERAL (
      SELECT string_agg(eq.nome, ', ' ORDER BY eq.nome) AS skills_csv
      FROM public.utilizador_equipas ue
      JOIN public.equipas eq ON eq.id = ue.equipa_id
      WHERE ue.utilizador_id = u.id
    ) sk ON true
    LEFT JOIN LATERAL (
      SELECT COUNT(DISTINCT ec.caso_id)::int AS tratadas
      FROM public.eventos_caso ec
      WHERE ec.actor_id = u.id
        AND ec.acao = 'atribuir_tarefa'
        AND ec.criado_em >= v_hoje_inicio
    ) st_trat ON true
    LEFT JOIN LATERAL (
      SELECT COUNT(DISTINCT ec.caso_id)::int AS concluidas
      FROM public.eventos_caso ec
      WHERE ec.actor_id = u.id
        AND ec.acao = 'concluir_caso'
        AND ec.criado_em >= v_hoje_inicio
    ) st_concl ON true
    LEFT JOIN LATERAL (
      SELECT COALESCE(AVG(
        EXTRACT(EPOCH FROM (ec_fim.criado_em - ec_ini.criado_em))
      )::int, 0) AS tmt_seg
      FROM public.eventos_caso ec_fim
      JOIN public.eventos_caso ec_ini ON ec_ini.caso_id = ec_fim.caso_id
        AND ec_ini.acao = 'atribuir_tarefa'
        AND ec_ini.actor_id = u.id
        AND ec_ini.criado_em <= ec_fim.criado_em
      WHERE ec_fim.actor_id = u.id
        AND ec_fim.acao = 'concluir_caso'
        AND ec_fim.criado_em >= v_hoje_inicio
    ) st_tmt ON true
    LEFT JOIN LATERAL (
      SELECT c.id, c.id_externo, c.inicio_tratamento
      FROM public.casos c
      WHERE c.colaborador_id = u.id
        AND c.status = 'em_tratamento'
        AND public._presenca_mantem_caso_ativo(u.presenca)
      LIMIT 1
    ) ca ON true
    WHERE u.area_id = v_area_id
      AND u.exibir_card_sala = true
  ) sub;

  RETURN jsonb_build_object(
    'sucesso', true,
    'equipa', v_equipa,
    'fila', v_fila,
    'equipasMaster', v_equipas_master
  );
END;
$$;
