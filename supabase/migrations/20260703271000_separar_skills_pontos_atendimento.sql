-- MS-10b fix: separar skills (equipas) de pontos de atendimento (GAS col C vs col M)

-- ---------------------------------------------------------------------------
-- Pontos de atendimento (loja / localizaÃ§Ã£o operacional)
-- ---------------------------------------------------------------------------

CREATE TABLE public.pontos_atendimento (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  area_id    UUID NOT NULL REFERENCES public.areas (id) ON DELETE CASCADE,
  nome       TEXT NOT NULL,
  codigo     TEXT NOT NULL,
  ativo      BOOLEAN NOT NULL DEFAULT true,
  criado_em  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (area_id, codigo)
);

CREATE INDEX idx_pontos_atendimento_area ON public.pontos_atendimento (area_id);

ALTER TABLE public.utilizadores
  ADD COLUMN ponto_atendimento_id UUID REFERENCES public.pontos_atendimento (id) ON DELETE SET NULL;

ALTER TABLE public.casos
  ADD COLUMN ponto_atendimento_id UUID REFERENCES public.pontos_atendimento (id) ON DELETE SET NULL;

CREATE INDEX idx_utilizadores_ponto ON public.utilizadores (ponto_atendimento_id);
CREATE INDEX idx_casos_ponto ON public.casos (ponto_atendimento_id);

-- ---------------------------------------------------------------------------
-- RLS pontos_atendimento
-- ---------------------------------------------------------------------------

ALTER TABLE public.pontos_atendimento ENABLE ROW LEVEL SECURITY;

CREATE POLICY pontos_atendimento_select ON public.pontos_atendimento
  FOR SELECT TO authenticated
  USING (
    public.has_permissao_developer()
    OR area_id = public.get_user_area_id()
  );

CREATE POLICY pontos_atendimento_manage ON public.pontos_atendimento
  FOR ALL TO authenticated
  USING (
    public.has_permissao_developer()
    OR public.has_permissao('admin.equipas')
  )
  WITH CHECK (
    public.has_permissao_developer()
    OR public.has_permissao('admin.equipas')
  );

GRANT SELECT ON public.pontos_atendimento TO authenticated;

-- ---------------------------------------------------------------------------
-- Migrar demo SU Eletricidade: equipas actuais eram localizaÃ§Ãµes, nÃ£o skills
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_area_id UUID := 'b0000000-0000-4000-8000-000000000001';
  -- Pontos (localizaÃ§Ãµes â€” reutilizam IDs antigos das "equipas" localizaÃ§Ã£o)
  v_p_lis  UUID := 'b0000000-0000-4000-8000-000000000101';
  v_p_pto  UUID := 'b0000000-0000-4000-8000-000000000102';
  v_p_alg  UUID := 'b0000000-0000-4000-8000-000000000103';
  v_p_bo   UUID := 'b0000000-0000-4000-8000-000000000104';
  -- Skills (novos IDs — Backoffice RQS reutiliza v_p_bo como skill)
  v_s_prod UUID := 'b0000000-0000-4000-8000-000000000201';
  v_s_cons UUID := 'b0000000-0000-4000-8000-000000000202';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.areas WHERE id = v_area_id) THEN
    RAISE NOTICE 'MS-10b: Ã¡rea demo nÃ£o encontrada â€” skip migraÃ§Ã£o dados.';
    RETURN;
  END IF;

  -- 1. Copiar localizaÃ§Ãµes actuais para pontos_atendimento
  INSERT INTO public.pontos_atendimento (id, area_id, nome, codigo, ativo)
  SELECT e.id, e.area_id, e.nome, e.codigo, e.ativo
  FROM public.equipas e
  WHERE e.area_id = v_area_id
  ON CONFLICT DO NOTHING;

  -- 2. Associar utilizadores e casos ao ponto (era equipa_id = localizaÃ§Ã£o)
  UPDATE public.utilizadores u
  SET ponto_atendimento_id = u.equipa_id
  WHERE u.area_id = v_area_id AND u.ponto_atendimento_id IS NULL;

  UPDATE public.casos c
  SET
    ponto_atendimento_id = c.equipa_id,
    loja = COALESCE(c.loja, (SELECT p.nome FROM public.pontos_atendimento p WHERE p.id = c.equipa_id))
  WHERE c.area_id = v_area_id;

  -- 3. Inserir skills geograficas (Producao, Consumo) — BO-RQS ja existe como equipa
  INSERT INTO public.equipas (id, area_id, nome, codigo) VALUES
    (v_s_prod, v_area_id, 'Producao', 'PROD'),
    (v_s_cons, v_area_id, 'Consumo',  'CONS')
  ON CONFLICT DO NOTHING;

  -- 4. Casos: skill conforme antiga localizacao (antes de apagar equipas-localizacao)
  UPDATE public.casos c
  SET equipa_id = CASE
    WHEN c.equipa_id = v_p_bo THEN v_p_bo
    WHEN c.equipa_id IN (v_p_lis, v_p_pto, v_p_alg) AND (abs(hashtext(c.id_externo)) % 2 = 0) THEN v_s_prod
    WHEN c.equipa_id IN (v_p_lis, v_p_pto, v_p_alg) THEN v_s_cons
    ELSE v_s_prod
  END
  WHERE c.area_id = v_area_id;

  -- 5. Primary skill por utilizador (qualquer ref. a equipa-geografica)
  UPDATE public.utilizadores u
  SET equipa_id = CASE
    WHEN u.equipa_id = v_p_bo THEN v_p_bo
    WHEN abs(hashtext(u.id::text)) % 2 = 0 THEN v_s_prod
    ELSE v_s_cons
  END
  WHERE u.area_id = v_area_id
    AND u.equipa_id IN (v_p_lis, v_p_pto, v_p_alg);

  UPDATE public.utilizadores SET equipa_id = v_s_prod
  WHERE id IN (
    'c0000000-0000-4000-8000-000000000004',
    'c0000000-0000-4000-8000-000000000007',
    'c0000000-0000-4000-8000-000000000006',
    'c0000000-0000-4000-8000-000000000002',
    'c0000000-0000-4000-8000-000000000003'
  );
  UPDATE public.utilizadores SET equipa_id = v_s_cons
  WHERE id IN (
    'c0000000-0000-4000-8000-000000000005',
    'c0000000-0000-4000-8000-000000000008'
  );
  UPDATE public.utilizadores SET equipa_id = v_p_bo
  WHERE id = 'c0000000-0000-4000-8000-000000000001';

  -- 6. M:N skills
  DELETE FROM public.utilizador_equipas ue
  USING public.utilizadores u
  WHERE ue.utilizador_id = u.id AND u.area_id = v_area_id;

  INSERT INTO public.utilizador_equipas (utilizador_id, equipa_id) VALUES
    ('c0000000-0000-4000-8000-000000000004', v_s_prod),
    ('c0000000-0000-4000-8000-000000000004', v_s_cons),
    ('c0000000-0000-4000-8000-000000000005', v_s_cons),
    ('c0000000-0000-4000-8000-000000000006', v_s_prod),
    ('c0000000-0000-4000-8000-000000000006', v_s_cons),
    ('c0000000-0000-4000-8000-000000000007', v_s_prod),
    ('c0000000-0000-4000-8000-000000000008', v_s_cons),
    ('c0000000-0000-4000-8000-000000000001', v_p_bo)
  ON CONFLICT DO NOTHING;

  -- 6b. Limpar referencias residuais a equipas geograficas
  DELETE FROM public.utilizador_equipas
  WHERE equipa_id IN (v_p_lis, v_p_pto, v_p_alg);

  UPDATE public.casos c
  SET equipa_id = CASE
    WHEN abs(hashtext(c.id_externo)) % 2 = 0 THEN v_s_prod
    ELSE v_s_cons
  END
  WHERE c.area_id = v_area_id
    AND c.equipa_id IN (v_p_lis, v_p_pto, v_p_alg);

  UPDATE public.utilizadores u
  SET equipa_id = v_s_prod
  WHERE u.area_id = v_area_id
    AND u.equipa_id IN (v_p_lis, v_p_pto, v_p_alg);

  -- 7. Remover equipas-localizacao geografica (ja migradas para pontos_atendimento)
  DELETE FROM public.equipas
  WHERE id IN (v_p_lis, v_p_pto, v_p_alg);

  RAISE NOTICE 'MS-10b: skills vs pontos separados na demo SU Eletricidade.';
END;
$$;

-- ---------------------------------------------------------------------------
-- obter_objetivos_edicao â€” lojas = pontos_atendimento (nÃ£o skills)
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
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissÃ£o.');
  END IF;

  IF v_mes = '' THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'MÃªs invÃ¡lido.');
  END IF;

  v_area_id := public.get_user_area_id();

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'loja', p.nome,
      'objetivo', COALESCE(o.objetivo, 0)
    )
    ORDER BY p.nome
  ), '[]'::jsonb)
  INTO v_dados
  FROM public.pontos_atendimento p
  LEFT JOIN public.objetivos_mensais o
    ON o.area_id = v_area_id
   AND o.mes = v_mes
   AND o.ponto_atendimento = p.nome
  WHERE p.area_id = v_area_id AND p.ativo = true;

  RETURN jsonb_build_object('sucesso', true, 'dados', v_dados);
END;
$$;


-- ---------------------------------------------------------------------------
-- importar_casos_lote â€” loja via ponto_atendimento, skill via equipas
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
  v_idx           INT;
  v_id            TEXT;
  v_contacto      TEXT;
  v_erros         TEXT[];
  v_falhas        JSONB := '[]'::jsonb;
  v_inseridos     INT := 0;
  v_equipa_id     UUID;
  v_ponto_id      UUID;
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
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissÃ£o de importaÃ§Ã£o.');
  END IF;

  IF p_linhas IS NULL OR jsonb_typeof(p_linhas) <> 'array' THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Matriz invÃ¡lida.');
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

    v_id := public._normalizar_id_importacao(v_linha->>1);
    IF v_id = '' THEN CONTINUE; END IF;
    IF v_existentes ? v_id THEN CONTINUE; END IF;

    v_contacto := public._normalizar_id_importacao(v_linha->>16);
    IF v_contacto <> '' AND v_existentes ? v_contacto THEN CONTINUE; END IF;

    v_erros := ARRAY[]::TEXT[];
    IF trim(COALESCE(v_linha->>2, '')) = '' THEN v_erros := array_append(v_erros, 'Canal de entrada'); END IF;
    IF trim(COALESCE(v_linha->>14, '')) = '' THEN v_erros := array_append(v_erros, 'Skill'); END IF;
    IF public._parse_data_importacao(v_linha->>5) IS NULL THEN v_erros := array_append(v_erros, 'Data criaÃ§Ã£o'); END IF;
    IF public._parse_data_importacao(v_linha->>6) IS NULL THEN v_erros := array_append(v_erros, 'Data RQS'); END IF;

    IF array_length(v_erros, 1) > 0 THEN
      v_falhas := v_falhas || jsonb_build_object('linha', v_idx, 'id', v_id, 'erros', to_jsonb(v_erros));
      CONTINUE;
    END IF;

    v_skill := trim(v_linha->>14);
    v_equipa_id := public._resolver_equipa_por_skill(v_area_id, v_skill);
    IF v_equipa_id IS NULL THEN
      v_falhas := v_falhas || jsonb_build_object(
        'linha', v_idx, 'id', v_id,
        'erros', jsonb_build_array('Skill desconhecida: ' || v_skill)
      );
      CONTINUE;
    END IF;

    v_criacao := public._parse_data_importacao(v_linha->>5);
    v_rqs := public._parse_data_importacao(v_linha->>6);
    v_agend := public._parse_data_importacao(v_linha->>12);
    v_intercalar := public._parse_data_importacao(v_linha->>7);
    v_canal := trim(COALESCE(v_linha->>>2, ''));
    v_loja := trim(COALESCE(v_linha->>>0, ''));
    v_resp_email := lower(trim(COALESCE(v_linha->>>10, '')));
    v_status := public._map_estado_gas_importacao(v_linha->>>9);
    v_ponto_id := NULL;
    v_colaborador := NULL;

    IF v_resp_email <> '' THEN
      SELECT u.id, u.ponto_atendimento_id, p.nome
      INTO v_colaborador, v_ponto_id, v_loja
      FROM public.utilizadores u
      LEFT JOIN public.pontos_atendimento p ON p.id = u.ponto_atendimento_id
      WHERE u.area_id = v_area_id AND lower(u.email) = v_resp_email
      LIMIT 1;

      IF v_status = 'livre' AND v_colaborador IS NOT NULL THEN
        v_status := 'por_tratar';
      END IF;
    END IF;

    IF v_loja <> '' AND v_ponto_id IS NULL THEN
      SELECT p.id INTO v_ponto_id
      FROM public.pontos_atendimento p
      WHERE p.area_id = v_area_id AND lower(p.nome) = lower(v_loja)
      LIMIT 1;
    END IF;

    INSERT INTO public.casos (
      area_id, equipa_id, ponto_atendimento_id, colaborador_id, id_externo, status,
      prioridade_flash, canal, email_contacto, pn, notas,
      loja, contacto_aux, intercalar_em, data_rqs, data_agendamento,
      inicio_tratamento, distribuido_em, criado_em
    ) VALUES (
      v_area_id,
      v_equipa_id,
      v_ponto_id,
      v_colaborador,
      v_id,
      v_status,
      upper(trim(COALESCE(v_linha->>>15, ''))) IN ('SIM', 'S', 'TRUE', '1', 'X'),
      v_canal,
      NULLIF(trim(COALESCE(v_linha->>>3, '')), ''),
      NULLIF(trim(COALESCE(v_linha->>>4, '')), ''),
      NULLIF(trim(COALESCE(v_linha->>>8, '')), ''),
      NULLIF(v_loja, ''),
      NULLIF(v_contacto, ''),
      v_intercalar,
      v_rqs,
      v_agend,
      public._parse_data_importacao(v_linha->>11),
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
      'mensagem', 'ImportaÃ§Ã£o bloqueada â€” campos obrigatÃ³rios em falta ou invÃ¡lidos (' ||
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

