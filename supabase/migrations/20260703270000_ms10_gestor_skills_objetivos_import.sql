-- MS-10: Gestor skills / objetivos / importação manual + nudge presets

-- ---------------------------------------------------------------------------
-- Schema: utilizador_equipas (M:N skills), objetivos_mensais, casos extras
-- ---------------------------------------------------------------------------

CREATE TABLE public.utilizador_equipas (
  utilizador_id UUID NOT NULL REFERENCES public.utilizadores (id) ON DELETE CASCADE,
  equipa_id     UUID NOT NULL REFERENCES public.equipas (id) ON DELETE CASCADE,
  criado_em     TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (utilizador_id, equipa_id)
);

CREATE INDEX idx_utilizador_equipas_equipa ON public.utilizador_equipas (equipa_id);

INSERT INTO public.utilizador_equipas (utilizador_id, equipa_id)
SELECT u.id, u.equipa_id FROM public.utilizadores u
ON CONFLICT DO NOTHING;

CREATE TABLE public.objetivos_mensais (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  area_id           UUID NOT NULL REFERENCES public.areas (id) ON DELETE CASCADE,
  mes               TEXT NOT NULL,
  ponto_atendimento TEXT NOT NULL,
  objetivo          INT NOT NULL DEFAULT 0,
  atualizado_em     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (area_id, mes, ponto_atendimento)
);

CREATE INDEX idx_objetivos_mensais_area_mes ON public.objetivos_mensais (area_id, mes);

ALTER TABLE public.casos
  ADD COLUMN IF NOT EXISTS loja TEXT,
  ADD COLUMN IF NOT EXISTS contacto_aux TEXT;

CREATE INDEX idx_casos_contacto_aux
  ON public.casos (area_id, contacto_aux)
  WHERE contacto_aux IS NOT NULL AND contacto_aux <> '';

-- Nudge presets default (merge into existing config)
UPDATE public.regras_fila rf
SET config = rf.config || jsonb_build_object(
  'nudge_mensagens', COALESCE(
    rf.config->'nudge_mensagens',
    '["Preciso da tua ajuda num caso.", "Por favor, atende a chamada activa.", "Vem à sala de controlo, p.f."]'::jsonb
  )
),
atualizado_em = now()
WHERE NOT (rf.config ? 'nudge_mensagens');

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

ALTER TABLE public.utilizador_equipas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.objetivos_mensais ENABLE ROW LEVEL SECURITY;

CREATE POLICY utilizador_equipas_select ON public.utilizador_equipas
  FOR SELECT TO authenticated
  USING (
    public.has_permissao_developer()
    OR public.has_permissao('utilizadores.ver_area')
    OR utilizador_id = auth.uid()
  );

CREATE POLICY utilizador_equipas_manage ON public.utilizador_equipas
  FOR ALL TO authenticated
  USING (public.has_permissao_developer() OR public.has_permissao('utilizadores.gerir'))
  WITH CHECK (public.has_permissao_developer() OR public.has_permissao('utilizadores.gerir'));

CREATE POLICY objetivos_mensais_select ON public.objetivos_mensais
  FOR SELECT TO authenticated
  USING (
    public.has_permissao_developer()
    OR (
      public.has_permissao('supervisao.dashboard')
      AND area_id = public.get_user_area_id()
    )
  );

CREATE POLICY objetivos_mensais_manage ON public.objetivos_mensais
  FOR ALL TO authenticated
  USING (
    public.has_permissao_developer()
    OR (
      public.has_permissao('supervisao.dashboard')
      AND area_id = public.get_user_area_id()
    )
  )
  WITH CHECK (
    public.has_permissao_developer()
    OR (
      public.has_permissao('supervisao.dashboard')
      AND area_id = public.get_user_area_id()
    )
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON public.utilizador_equipas TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.objetivos_mensais TO authenticated;

-- ---------------------------------------------------------------------------
-- Helpers importação
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._normalizar_id_importacao(p_val TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT upper(regexp_replace(trim(COALESCE(p_val, '')), '\s+', '', 'g'));
$$;

CREATE OR REPLACE FUNCTION public._parse_data_importacao(p_val TEXT)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_txt TEXT := trim(COALESCE(p_val, ''));
  v_ts  TIMESTAMPTZ;
BEGIN
  IF v_txt = '' THEN
    RETURN NULL;
  END IF;

  BEGIN
    v_ts := v_txt::timestamptz;
    IF v_ts IS NOT NULL THEN RETURN v_ts; END IF;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    v_ts := to_timestamp(v_txt, 'DD/MM/YYYY HH24:MI:SS') AT TIME ZONE 'Europe/Lisbon';
    IF v_ts IS NOT NULL THEN RETURN v_ts; END IF;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    v_ts := to_timestamp(v_txt, 'DD/MM/YYYY') AT TIME ZONE 'Europe/Lisbon';
    IF v_ts IS NOT NULL THEN RETURN v_ts; END IF;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    v_ts := to_timestamp(v_txt, 'YYYY-MM-DD') AT TIME ZONE 'Europe/Lisbon';
    IF v_ts IS NOT NULL THEN RETURN v_ts; END IF;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public._map_estado_gas_importacao(p_estado TEXT)
RETURNS public.caso_status
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v TEXT := lower(trim(COALESCE(p_estado, '')));
BEGIN
  IF v IN ('', 'livre') THEN RETURN 'livre'; END IF;
  IF v LIKE '%tratamento%' THEN RETURN 'em_tratamento'; END IF;
  IF v LIKE '%por tratar%' THEN RETURN 'por_tratar'; END IF;
  IF v LIKE '%suspenso%' THEN RETURN 'suspenso'; END IF;
  IF v LIKE '%agendado%' THEN RETURN 'agendado'; END IF;
  IF v LIKE '%pendente%' THEN RETURN 'pendente'; END IF;
  IF v LIKE '%conclu%' THEN RETURN 'concluido'; END IF;
  IF v LIKE '%cancel%' THEN RETURN 'cancelado'; END IF;
  IF v LIKE '%outro%' THEN RETURN 'outro'; END IF;
  RETURN 'livre';
END;
$$;

CREATE OR REPLACE FUNCTION public._resolver_equipa_por_skill(
  p_area_id UUID,
  p_skill TEXT
)
RETURNS UUID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_skill TEXT := trim(COALESCE(p_skill, ''));
  v_id    UUID;
BEGIN
  IF v_skill = '' THEN RETURN NULL; END IF;

  SELECT e.id INTO v_id
  FROM public.equipas e
  WHERE e.area_id = p_area_id AND e.ativo
    AND (lower(e.nome) = lower(v_skill) OR lower(e.codigo) = lower(v_skill))
  LIMIT 1;

  RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- obter_dados_gestor_skills
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obter_dados_gestor_skills()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id UUID;
  v_users   JSONB := '[]'::jsonb;
  v_skills  JSONB := '[]'::jsonb;
BEGIN
  IF NOT public.has_permissao('utilizadores.gerir') THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissão para gerir skills.');
  END IF;

  v_area_id := public.get_user_area_id();

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object('id', e.id, 'nome', e.nome, 'codigo', e.codigo)
    ORDER BY e.nome
  ), '[]'::jsonb)
  INTO v_skills
  FROM public.equipas e
  WHERE e.area_id = v_area_id AND e.ativo = true;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'email', u.email,
      'nome', u.nome,
      'skills', COALESCE((
        SELECT jsonb_agg(eq.nome ORDER BY eq.nome)
        FROM public.utilizador_equipas ue
        JOIN public.equipas eq ON eq.id = ue.equipa_id
        WHERE ue.utilizador_id = u.id
      ), '[]'::jsonb)
    )
    ORDER BY u.nome
  ), '[]'::jsonb)
  INTO v_users
  FROM public.utilizadores u
  WHERE u.area_id = v_area_id
    AND u.role = 'colaborador';

  RETURN jsonb_build_object('sucesso', true, 'users', v_users, 'skills', v_skills);
END;
$$;

-- ---------------------------------------------------------------------------
-- atualizar_skills_em_massa
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.atualizar_skills_em_massa(
  p_emails TEXT[],
  p_skills TEXT[],
  p_acao   TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id       UUID;
  v_email         TEXT;
  v_skill         TEXT;
  v_uid           UUID;
  v_equipa_id     UUID;
  v_alterados     INT := 0;
  v_acao          TEXT := lower(trim(COALESCE(p_acao, '')));
BEGIN
  IF NOT public.has_permissao('utilizadores.gerir') THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissão para gerir skills.');
  END IF;

  IF p_emails IS NULL OR array_length(p_emails, 1) IS NULL
     OR p_skills IS NULL OR array_length(p_skills, 1) IS NULL THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Seleciona pelo menos um operador e uma skill.');
  END IF;

  IF v_acao NOT IN ('adicionar', 'remover') THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Acção inválida.');
  END IF;

  v_area_id := public.get_user_area_id();

  FOREACH v_email IN ARRAY p_emails LOOP
    SELECT u.id INTO v_uid
    FROM public.utilizadores u
    WHERE u.area_id = v_area_id
      AND lower(trim(u.email)) = lower(trim(v_email))
      AND u.role = 'colaborador';

    IF v_uid IS NULL THEN CONTINUE; END IF;

    FOREACH v_skill IN ARRAY p_skills LOOP
      v_equipa_id := public._resolver_equipa_por_skill(v_area_id, v_skill);
      IF v_equipa_id IS NULL THEN CONTINUE; END IF;

      IF v_acao = 'adicionar' THEN
        INSERT INTO public.utilizador_equipas (utilizador_id, equipa_id)
        VALUES (v_uid, v_equipa_id)
        ON CONFLICT DO NOTHING;
      ELSE
        DELETE FROM public.utilizador_equipas ue
        WHERE ue.utilizador_id = v_uid AND ue.equipa_id = v_equipa_id;
      END IF;
    END LOOP;

    v_alterados := v_alterados + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'sucesso', true,
    'mensagem', v_alterados || ' operador(es) actualizado(s) com sucesso!'
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- obter_objetivos_edicao / salvar_objetivos_massa
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obter_objetivos_edicao(p_mes TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id UUID;
  v_mes     TEXT := trim(COALESCE(p_mes, ''));
  v_dados   JSONB := '[]'::jsonb;
BEGIN
  IF NOT public.has_permissao('supervisao.dashboard') THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissão.');
  END IF;

  IF v_mes = '' THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Mês inválido.');
  END IF;

  v_area_id := public.get_user_area_id();

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'loja', lojas.nome,
      'objetivo', COALESCE(o.objetivo, 0)
    )
    ORDER BY lojas.nome
  ), '[]'::jsonb)
  INTO v_dados
  FROM (
    SELECT DISTINCT e.nome
    FROM public.equipas e
    WHERE e.area_id = v_area_id AND e.ativo = true
  ) lojas(nome)
  LEFT JOIN public.objetivos_mensais o
    ON o.area_id = v_area_id
   AND o.mes = v_mes
   AND o.ponto_atendimento = lojas.nome;

  RETURN jsonb_build_object('sucesso', true, 'dados', v_dados);
END;
$$;

CREATE OR REPLACE FUNCTION public.salvar_objetivos_massa(
  p_mes        TEXT,
  p_objetivos  JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id UUID;
  v_mes     TEXT := trim(COALESCE(p_mes, ''));
  v_item    JSONB;
  v_loja    TEXT;
  v_valor   INT;
  v_count   INT := 0;
BEGIN
  IF NOT public.has_permissao('supervisao.dashboard') THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissão.');
  END IF;

  IF v_mes = '' OR p_objetivos IS NULL OR jsonb_typeof(p_objetivos) <> 'array' THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Dados inválidos.');
  END IF;

  v_area_id := public.get_user_area_id();

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_objetivos) LOOP
    v_loja := trim(COALESCE(v_item->>'loja', ''));
    v_valor := COALESCE((v_item->>'objetivo')::int, 0);
    IF v_loja = '' THEN CONTINUE; END IF;

    INSERT INTO public.objetivos_mensais (area_id, mes, ponto_atendimento, objetivo)
    VALUES (v_area_id, v_mes, v_loja, v_valor)
    ON CONFLICT (area_id, mes, ponto_atendimento)
    DO UPDATE SET objetivo = EXCLUDED.objetivo, atualizado_em = now();

    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'sucesso', true,
    'mensagem', 'Objetivos de ' || v_count || ' lojas gravados com sucesso!'
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- obter_ids_importacao — lista negra dedupe (ID + contacto aux)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obter_ids_importacao()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id UUID;
  v_ids     JSONB := '[]'::jsonb;
BEGIN
  IF NOT public.has_permissao_importacao() THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissão de importação.');
  END IF;

  v_area_id := public.get_user_area_id();

  SELECT COALESCE(jsonb_agg(DISTINCT val), '[]'::jsonb)
  INTO v_ids
  FROM (
    SELECT public._normalizar_id_importacao(c.id_externo) AS val
    FROM public.casos c
    WHERE c.area_id = v_area_id
      AND c.id_externo <> ''
    UNION
    SELECT public._normalizar_id_importacao(c.contacto_aux) AS val
    FROM public.casos c
    WHERE c.area_id = v_area_id
      AND c.contacto_aux IS NOT NULL
      AND c.contacto_aux <> ''
  ) t
  WHERE val <> '';

  RETURN jsonb_build_object('sucesso', true, 'ids', v_ids);
END;
$$;

-- ---------------------------------------------------------------------------
-- importar_casos_lote — matriz 17 cols (índices GAS)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.importar_casos_lote(p_linhas JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id       UUID;
  v_linha         JSONB;
  v_arr           JSONB;
  v_idx           INT;
  v_id            TEXT;
  v_contacto      TEXT;
  v_erros         TEXT[];
  v_falhas        JSONB := '[]'::jsonb;
  v_inseridos     INT := 0;
  v_equipa_id     UUID;
  v_colaborador   UUID;
  v_status        public.caso_status;
  v_criacao       TIMESTAMPTZ;
  v_rqs           TIMESTAMPTZ;
  v_agend         TIMESTAMPTZ;
  v_intercalar    TIMESTAMPTZ;
  v_loja          TEXT;
  v_resp_email    TEXT;
  v_skill         TEXT;
  v_canal         TEXT;
  v_existentes    JSONB;
BEGIN
  IF NOT public.has_permissao_importacao() THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissão de importação.');
  END IF;

  IF p_linhas IS NULL OR jsonb_typeof(p_linhas) <> 'array' THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Matriz inválida.');
  END IF;

  v_area_id := public.get_user_area_id();

  SELECT COALESCE(jsonb_object_agg(val, true), '{}'::jsonb)
  INTO v_existentes
  FROM (
    SELECT public._normalizar_id_importacao(c.id_externo) AS val
    FROM public.casos c WHERE c.area_id = v_area_id
    UNION
    SELECT public._normalizar_id_importacao(c.contacto_aux)
    FROM public.casos c
    WHERE c.area_id = v_area_id AND c.contacto_aux IS NOT NULL AND c.contacto_aux <> ''
  ) t
  WHERE val <> '';

  v_idx := 0;
  FOR v_linha IN SELECT * FROM jsonb_array_elements(p_linhas) LOOP
    v_idx := v_idx + 1;
    v_arr := v_linha;

    v_id := public._normalizar_id_importacao(v_arr->>1);
    IF v_id = '' THEN CONTINUE; END IF;

    IF v_existentes ? v_id THEN CONTINUE; END IF;

    v_contacto := public._normalizar_id_importacao(v_arr->>16);
    IF v_contacto <> '' AND v_existentes ? v_contacto THEN CONTINUE; END IF;

    v_erros := ARRAY[]::TEXT[];
    IF trim(COALESCE(v_arr->>2, '')) = '' THEN v_erros := array_append(v_erros, 'Canal de entrada'); END IF;
    IF trim(COALESCE(v_arr->>14, '')) = '' THEN v_erros := array_append(v_erros, 'Skill'); END IF;
    IF public._parse_data_importacao(v_arr->>5) IS NULL THEN v_erros := array_append(v_erros, 'Data criação'); END IF;
    IF public._parse_data_importacao(v_arr->>6) IS NULL THEN v_erros := array_append(v_erros, 'Data RQS'); END IF;

    IF array_length(v_erros, 1) > 0 THEN
      v_falhas := v_falhas || jsonb_build_object('linha', v_idx, 'id', v_id, 'erros', to_jsonb(v_erros));
      CONTINUE;
    END IF;

    v_skill := trim(v_arr->>14);
    v_equipa_id := public._resolver_equipa_por_skill(v_area_id, v_skill);
    IF v_equipa_id IS NULL THEN
      v_falhas := v_falhas || jsonb_build_object(
        'linha', v_idx, 'id', v_id,
        'erros', jsonb_build_array('Skill desconhecida: ' || v_skill)
      );
      CONTINUE;
    END IF;

    v_criacao := public._parse_data_importacao(v_arr->>5);
    v_rqs := public._parse_data_importacao(v_arr->>6);
    v_agend := public._parse_data_importacao(v_arr->>12);
    v_intercalar := public._parse_data_importacao(v_arr->>7);
    v_canal := trim(COALESCE(v_arr->>>2, ''));
    v_loja := trim(COALESCE(v_arr->>>0, ''));
    v_resp_email := lower(trim(COALESCE(v_arr->>>10, '')));
    v_status := public._map_estado_gas_importacao(v_arr->>>9);

    v_colaborador := NULL;
    IF v_resp_email <> '' THEN
      SELECT u.id, e.nome
      INTO v_colaborador, v_loja
      FROM public.utilizadores u
      JOIN public.equipas e ON e.id = u.equipa_id
      WHERE u.area_id = v_area_id AND lower(u.email) = v_resp_email
      LIMIT 1;

      IF v_status = 'livre' AND v_colaborador IS NOT NULL THEN
        v_status := 'por_tratar';
      END IF;
    END IF;

    IF v_loja = '' THEN
      SELECT e.nome INTO v_loja FROM public.equipas e WHERE e.id = v_equipa_id;
    END IF;

    INSERT INTO public.casos (
      area_id, equipa_id, colaborador_id, id_externo, status,
      prioridade_flash, canal, email_contacto, pn, notas,
      loja, contacto_aux, intercalar_em, data_rqs, data_agendamento,
      inicio_tratamento, distribuido_em, criado_em
    ) VALUES (
      v_area_id,
      v_equipa_id,
      v_colaborador,
      v_id,
      v_status,
      upper(trim(COALESCE(v_arr->>>15, ''))) IN ('SIM', 'S', 'TRUE', '1', 'X'),
      v_canal,
      NULLIF(trim(COALESCE(v_arr->>>3, '')), ''),
      NULLIF(trim(COALESCE(v_arr->>>4, '')), ''),
      NULLIF(trim(COALESCE(v_arr->>>8, '')), ''),
      NULLIF(v_loja, ''),
      NULLIF(v_contacto, ''),
      v_intercalar,
      v_rqs,
      v_agend,
      public._parse_data_importacao(v_arr->>11),
      now(),
      v_criacao
    );

    v_existentes := v_existentes || jsonb_build_object(v_id, true);
    IF v_contacto <> '' THEN
      v_existentes := v_existentes || jsonb_build_object(v_contacto, true);
    END IF;

    v_inseridos := v_inseridos + 1;
  END LOOP;

  IF jsonb_array_length(v_falhas) > 0 THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', 'Importação bloqueada — campos obrigatórios em falta ou inválidos (' ||
        jsonb_array_length(v_falhas)::text || ' caso(s)).',
      'falhas', v_falhas
    );
  END IF;

  IF v_inseridos = 0 THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Nenhum caso novo (duplicados ou vazios).');
  END IF;

  RETURN jsonb_build_object(
    'sucesso', true,
    'mensagem', v_inseridos || ' casos importados!',
    'inseridos', v_inseridos
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Nudge presets em regras_fila.config
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obter_nudge_mensagens()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id UUID;
  v_msgs    JSONB;
BEGIN
  IF NOT public.has_permissao('supervisao.nudges') THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissão.');
  END IF;

  v_area_id := public.get_user_area_id();

  SELECT COALESCE(rf.config->'nudge_mensagens', '[]'::jsonb)
  INTO v_msgs
  FROM public.regras_fila rf
  WHERE rf.area_id = v_area_id;

  IF v_msgs IS NULL OR jsonb_typeof(v_msgs) <> 'array' THEN
    v_msgs := '[]'::jsonb;
  END IF;

  RETURN jsonb_build_object('sucesso', true, 'mensagens', v_msgs);
END;
$$;

CREATE OR REPLACE FUNCTION public.salvar_nudge_mensagens(p_mensagens TEXT[])
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id UUID;
  v_json    JSONB;
BEGIN
  IF NOT (
    public.has_permissao_developer()
    OR public.has_permissao('admin.regras_fila')
    OR public.has_permissao('supervisao.nudges')
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissão.');
  END IF;

  v_area_id := public.get_user_area_id();
  v_json := COALESCE(to_jsonb(p_mensagens), '[]'::jsonb);

  INSERT INTO public.regras_fila (area_id, versao, config)
  VALUES (v_area_id, 1, jsonb_build_object('nudge_mensagens', v_json))
  ON CONFLICT (area_id) DO UPDATE
  SET config = regras_fila.config || jsonb_build_object('nudge_mensagens', v_json),
      atualizado_em = now();

  RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Mensagens guardadas.');
END;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

GRANT EXECUTE ON FUNCTION public.obter_dados_gestor_skills() TO authenticated;
GRANT EXECUTE ON FUNCTION public.atualizar_skills_em_massa(TEXT[], TEXT[], TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obter_objetivos_edicao(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.salvar_objetivos_massa(TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obter_ids_importacao() TO authenticated;
GRANT EXECUTE ON FUNCTION public.importar_casos_lote(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obter_nudge_mensagens() TO authenticated;
GRANT EXECUTE ON FUNCTION public.salvar_nudge_mensagens(TEXT[]) TO authenticated;
