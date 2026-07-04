-- MS-13b: Import Evalyze cron — service_role + area explícita (réplica GAS trigger 1h)

CREATE OR REPLACE FUNCTION public._is_service_role()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(auth.jwt()->>'role', '') = 'service_role';
$$;

-- Evitar overload ambíguo (2 args → 3 args com default)
DROP FUNCTION IF EXISTS public.importar_casos_evalyze(JSONB, TEXT);

-- Patch importar_casos_evalyze: 3º arg opcional para cron Vercel (sem sessão utilizador)
CREATE OR REPLACE FUNCTION public.importar_casos_evalyze(
  p_linhas         JSONB,
  p_origem         TEXT DEFAULT 'manual',
  p_area_id_cron   UUID DEFAULT NULL
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
  IF p_area_id_cron IS NOT NULL THEN
    IF NOT public._is_service_role() THEN
      RETURN jsonb_build_object(
        'sucesso', false,
        'mensagem', 'Importacao cron requer service_role.',
        'importados', 0,
        'duplicados', 0,
        'ignoradosCampos', 0
      );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.areas a WHERE a.id = p_area_id_cron) THEN
      RETURN jsonb_build_object(
        'sucesso', false,
        'mensagem', 'Area Evalyze invalida.',
        'importados', 0,
        'duplicados', 0,
        'ignoradosCampos', 0
      );
    END IF;

    v_area_id := p_area_id_cron;
    v_user_id := NULL;
  ELSE
    IF NOT public.has_permissao('importacao.evalyze') THEN
      RETURN jsonb_build_object(
        'sucesso', false,
        'mensagem', 'Sem permissao importacao.evalyze.',
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

GRANT EXECUTE ON FUNCTION public._is_service_role() TO service_role;
GRANT EXECUTE ON FUNCTION public.importar_casos_evalyze(JSONB, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.importar_casos_evalyze(JSONB, TEXT, UUID) TO service_role;
