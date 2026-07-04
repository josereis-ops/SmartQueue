-- MS-13: Import Evalyze automatico — log + RPCs (replica GAS importarCasosEvalyzeAutomatico)

-- ---------------------------------------------------------------------------
-- Log de execucoes Evalyze
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.import_evalyze_log (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  area_id          UUID NOT NULL REFERENCES public.areas(id) ON DELETE CASCADE,
  executado_por    UUID REFERENCES public.utilizadores(id) ON DELETE SET NULL,
  executado_em     TIMESTAMPTZ NOT NULL DEFAULT now(),
  origem           TEXT NOT NULL DEFAULT 'manual',
  sucesso          BOOLEAN NOT NULL DEFAULT true,
  importados       INT NOT NULL DEFAULT 0,
  duplicados       INT NOT NULL DEFAULT 0,
  ignorados_campos INT NOT NULL DEFAULT 0,
  mensagem         TEXT,
  duracao_ms       INT
);

CREATE INDEX IF NOT EXISTS idx_import_evalyze_log_area_em
  ON public.import_evalyze_log (area_id, executado_em DESC);

ALTER TABLE public.import_evalyze_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY import_evalyze_log_select ON public.import_evalyze_log
  FOR SELECT TO authenticated
  USING (
    area_id = public.get_user_area_id()
    AND public.has_permissao('importacao.evalyze')
  );

-- ---------------------------------------------------------------------------
-- importar_casos_evalyze — dedupe + skip linhas invalidas (nao falha o lote)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.importar_casos_evalyze(
  p_linhas JSONB,
  p_origem TEXT DEFAULT 'manual'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id          UUID;
  v_user_id          UUID;
  v_linha            JSONB;
  v_id               TEXT;
  v_contacto         TEXT;
  v_erros            TEXT[];
  v_importados       INT := 0;
  v_duplicados       INT := 0;
  v_ignorados        INT := 0;
  v_equipa_id        UUID;
  v_ponto_id         UUID;
  v_colaborador      UUID;
  v_status           public.caso_status;
  v_criacao          TIMESTAMPTZ;
  v_rqs              TIMESTAMPTZ;
  v_agend            TIMESTAMPTZ;
  v_intercalar       TIMESTAMPTZ;
  v_loja             TEXT;
  v_resp_email       TEXT;
  v_skill            TEXT;
  v_canal            TEXT;
  v_existentes       JSONB;
  v_inicio           TIMESTAMPTZ := clock_timestamp();
  v_msg              TEXT;
  v_log_id           UUID;
BEGIN
  IF NOT public.has_permissao('importacao.evalyze') THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', 'Sem permissao importacao.evalyze.',
      'importados', 0,
      'duplicados', 0,
      'ignoradosCampos', 0
    );
  END IF;

  IF p_linhas IS NULL OR jsonb_typeof(p_linhas) <> 'array' THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', 'Matriz invalida.',
      'importados', 0,
      'duplicados', 0,
      'ignoradosCampos', 0
    );
  END IF;

  v_area_id := public.get_user_area_id();
  SELECT u.id INTO v_user_id
  FROM public.utilizadores u
  WHERE u.auth_user_id = auth.uid()
  LIMIT 1;

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

  IF jsonb_array_length(p_linhas) = 0 THEN
    v_msg := 'Relatorio Smart Queue sem linhas de dados.';
    INSERT INTO public.import_evalyze_log (
      area_id, executado_por, origem, sucesso, importados, duplicados,
      ignorados_campos, mensagem, duracao_ms
    ) VALUES (
      v_area_id, v_user_id, COALESCE(NULLIF(trim(p_origem), ''), 'manual'),
      true, 0, 0, 0, v_msg,
      (EXTRACT(EPOCH FROM (clock_timestamp() - v_inicio)) * 1000)::INT
    )
    RETURNING id INTO v_log_id;

    RETURN jsonb_build_object(
      'sucesso', true,
      'mensagem', v_msg,
      'importados', 0,
      'duplicados', 0,
      'ignoradosCampos', 0,
      'log_id', v_log_id
    );
  END IF;

  FOR v_linha IN SELECT * FROM jsonb_array_elements(p_linhas) LOOP
    v_id := public._normalizar_id_importacao(v_linha->>1);
    IF v_id = '' THEN
      CONTINUE;
    END IF;

    IF v_existentes ? v_id THEN
      v_duplicados := v_duplicados + 1;
      CONTINUE;
    END IF;

    v_contacto := public._normalizar_id_importacao(v_linha->>16);
    IF v_contacto <> '' AND v_existentes ? v_contacto THEN
      v_duplicados := v_duplicados + 1;
      CONTINUE;
    END IF;

    v_erros := ARRAY[]::TEXT[];
    IF trim(COALESCE(v_linha->>2, '')) = '' THEN v_erros := array_append(v_erros, 'Canal de entrada'); END IF;
    IF trim(COALESCE(v_linha->>14, '')) = '' THEN v_erros := array_append(v_erros, 'Skill'); END IF;
    IF public._parse_data_importacao(v_linha->>5) IS NULL THEN v_erros := array_append(v_erros, 'Data criacao'); END IF;
    IF public._parse_data_importacao(v_linha->>6) IS NULL THEN v_erros := array_append(v_erros, 'Data RQS'); END IF;

    IF array_length(v_erros, 1) > 0 THEN
      v_ignorados := v_ignorados + 1;
      CONTINUE;
    END IF;

    v_skill := trim(v_linha->>14);
    v_equipa_id := public._resolver_equipa_por_skill(v_area_id, v_skill);
    IF v_equipa_id IS NULL THEN
      v_ignorados := v_ignorados + 1;
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

    v_importados := v_importados + 1;
  END LOOP;

  v_msg := v_importados || ' importados';
  IF v_duplicados > 0 THEN
    v_msg := v_msg || ', ' || v_duplicados || ' duplicados ignorados';
  END IF;
  IF v_ignorados > 0 THEN
    v_msg := v_msg || ', ' || v_ignorados || ' ignorados (campos obrigatorios em falta)';
  END IF;
  IF v_importados = 0 AND v_duplicados = 0 AND v_ignorados = 0 THEN
    v_msg := 'Nenhum caso novo encontrado no relatorio Smart Queue.';
  END IF;

  INSERT INTO public.import_evalyze_log (
    area_id, executado_por, origem, sucesso, importados, duplicados,
    ignorados_campos, mensagem, duracao_ms
  ) VALUES (
    v_area_id, v_user_id, COALESCE(NULLIF(trim(p_origem), ''), 'manual'),
    true, v_importados, v_duplicados, v_ignorados, v_msg,
    (EXTRACT(EPOCH FROM (clock_timestamp() - v_inicio)) * 1000)::INT
  )
  RETURNING id INTO v_log_id;

  RETURN jsonb_build_object(
    'sucesso', true,
    'mensagem', v_msg,
    'importados', v_importados,
    'duplicados', v_duplicados,
    'ignoradosCampos', v_ignorados,
    'log_id', v_log_id
  );
EXCEPTION WHEN OTHERS THEN
  INSERT INTO public.import_evalyze_log (
    area_id, executado_por, origem, sucesso, importados, duplicados,
    ignorados_campos, mensagem, duracao_ms
  ) VALUES (
    v_area_id, v_user_id, COALESCE(NULLIF(trim(p_origem), ''), 'manual'),
    false, v_importados, v_duplicados, v_ignorados, SQLERRM,
    (EXTRACT(EPOCH FROM (clock_timestamp() - v_inicio)) * 1000)::INT
  );

  RETURN jsonb_build_object(
    'sucesso', false,
    'mensagem', SQLERRM,
    'importados', v_importados,
    'duplicados', v_duplicados,
    'ignoradosCampos', v_ignorados
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- obter_status_import_evalyze — ultima execucao da area
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obter_status_import_evalyze()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id UUID;
  v_row     public.import_evalyze_log%ROWTYPE;
BEGIN
  IF NOT public.has_permissao('importacao.evalyze') THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissao importacao.evalyze.');
  END IF;

  v_area_id := public.get_user_area_id();

  SELECT * INTO v_row
  FROM public.import_evalyze_log l
  WHERE l.area_id = v_area_id
  ORDER BY l.executado_em DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'sucesso', true,
      'mensagem', 'Nenhuma importacao Evalyze registada.',
      'ultima', NULL
    );
  END IF;

  RETURN jsonb_build_object(
    'sucesso', true,
    'ultima', jsonb_build_object(
      'id', v_row.id,
      'executado_em', v_row.executado_em,
      'origem', v_row.origem,
      'sucesso', v_row.sucesso,
      'importados', v_row.importados,
      'duplicados', v_row.duplicados,
      'ignoradosCampos', v_row.ignorados_campos,
      'mensagem', v_row.mensagem,
      'duracao_ms', v_row.duracao_ms
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.importar_casos_evalyze(JSONB, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obter_status_import_evalyze() TO authenticated;
