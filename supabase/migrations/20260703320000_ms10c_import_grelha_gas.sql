-- MS-10c: Paridade import manual grelha GAS — normalização ID Excel E+15

CREATE OR REPLACE FUNCTION public._normalizar_id_importacao(p_val TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_s   TEXT;
  v_num NUMERIC;
BEGIN
  IF p_val IS NULL OR trim(p_val) = '' THEN
    RETURN '';
  END IF;

  v_s := upper(regexp_replace(trim(p_val), '\s+', '', 'g'));

  IF position('E+' IN v_s) > 0 OR length(v_s) > 10 THEN
    BEGIN
      v_num := replace(replace(trim(p_val), ',', '.'), ' ', '')::numeric;
      v_s := round(v_num)::bigint::text;
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  IF v_s = '' OR v_s = 'NULL' THEN
    RETURN '';
  END IF;

  RETURN v_s;
END;
$$;

-- importar_casos_lote — mensagem falhas alinhada GAS (bloqueio total se qualquer inválido)
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
  v_msg_bloq      TEXT;
  v_partes        TEXT[];
  v_f             JSONB;
  v_max_show      INT;
  v_fx            INT;
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

    v_id := public._normalizar_id_importacao(v_linha->>1);
    IF v_id = '' THEN CONTINUE; END IF;
    IF v_existentes ? v_id THEN CONTINUE; END IF;

    v_contacto := public._normalizar_id_importacao(v_linha->>16);
    IF v_contacto <> '' AND v_existentes ? v_contacto THEN CONTINUE; END IF;

    v_erros := ARRAY[]::TEXT[];
    IF trim(COALESCE(v_linha->>2, '')) = '' THEN v_erros := array_append(v_erros, 'Canal de entrada'); END IF;
    IF trim(COALESCE(v_linha->>14, '')) = '' THEN v_erros := array_append(v_erros, 'Skill'); END IF;
    IF public._parse_data_importacao(v_linha->>5) IS NULL THEN v_erros := array_append(v_erros, 'Data criação'); END IF;
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
    v_max_show := LEAST(3, jsonb_array_length(v_falhas)::int);
    v_partes := ARRAY[]::TEXT[];
    FOR v_fx IN 0 .. (v_max_show - 1) LOOP
      v_f := v_falhas->v_fx;
      v_partes := array_append(
        v_partes,
        'linha ' || (v_f->>'linha') || ' (ID ' || (v_f->>'id') || '): '
          || (SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(v_f->'erros') AS x)
      );
    END LOOP;

    v_msg_bloq := 'Importação bloqueada — campos obrigatórios em falta ou inválidos ('
      || jsonb_array_length(v_falhas)::text || ' caso(s)). '
      || array_to_string(v_partes, ' | ');

    IF jsonb_array_length(v_falhas) > v_max_show THEN
      v_msg_bloq := v_msg_bloq || ' (+' || (jsonb_array_length(v_falhas) - v_max_show)::text || ' outros)';
    END IF;

    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', v_msg_bloq,
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
