-- MS-09: RPCs Sala de Controlo — réplica GAS obterDadosSupervisao, reatribuirCasoServidor, alterarPrioridadeServidor

-- ---------------------------------------------------------------------------
-- Helper: limite SLA (4 dias úteis recuados — MVP alinhado ao GAS calcularDataLimiteSLA)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._data_limite_sla()
RETURNS DATE
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_data   DATE := (now() AT TIME ZONE 'Europe/Lisbon')::date;
  v_uteis  INT := 0;
  v_alvo   INT := 4;
BEGIN
  WHILE v_uteis < v_alvo LOOP
    v_data := v_data - 1;
    IF EXTRACT(ISODOW FROM v_data) NOT IN (6, 7) THEN
      v_uteis := v_uteis + 1;
    END IF;
  END LOOP;
  RETURN v_data;
END;
$$;

-- ---------------------------------------------------------------------------
-- obter_dados_supervisao — réplica GAS obterDadosSupervisao (MVP POC)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obter_dados_supervisao(
  p_equipas_filtro UUID[] DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id       UUID;
  v_hoje_inicio   TIMESTAMPTZ;
  v_hoje_fim      TIMESTAMPTZ;
  v_sla_limite    DATE;
  v_equipa        JSONB := '[]'::jsonb;
  v_equipas_master JSONB := '[]'::jsonb;
  v_fila          JSONB;
  v_lista_todos   JSONB := '[]'::jsonb;
  v_lista_livres  JSONB := '[]'::jsonb;
  v_lista_atras   JSONB := '[]'::jsonb;
  v_lista_rqs_atr JSONB := '[]'::jsonb;
  v_lista_rqs_hj  JSONB := '[]'::jsonb;
  v_lista_outro   JSONB := '[]'::jsonb;
  v_caso          RECORD;
  v_caso_json     JSONB;
  v_grupo         TEXT;
  v_intercalar    BOOLEAN;
  v_global_trat   INT := 0;
  v_global_concl  INT := 0;
  v_global_tempo  BIGINT := 0;
  v_tmt_global    TEXT;
  v_u             RECORD;
  v_tratadas      INT;
  v_concluidas    INT;
  v_caso_ativo    RECORD;
  v_nome_vis      TEXT;
  v_partes        TEXT[];
  v_tmt_seg       INT;
  v_m             TEXT;
  v_s             TEXT;
  v_presenca_lbl  TEXT;
  v_is_super      BOOLEAN;
BEGIN
  IF NOT public.has_permissao('supervisao.dashboard') THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_PERMISSAO',
      'mensagem', 'Sem permissão para aceder à Sala de Controlo.'
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

  -- Agregação fila + listas drill-down
  FOR v_caso IN
    SELECT
      c.*,
      e.nome AS equipa_nome,
      e.codigo AS equipa_codigo,
      u.email AS resp_email,
      u.nome AS resp_nome
    FROM public.casos c
    JOIN public.equipas e ON e.id = c.equipa_id
    LEFT JOIN public.utilizadores u ON u.id = c.colaborador_id
    WHERE c.area_id = v_area_id
      AND (p_equipas_filtro IS NULL OR c.equipa_id = ANY(p_equipas_filtro))
  LOOP
    v_intercalar := v_caso.intercalar_em IS NOT NULL;

    v_caso_json := jsonb_build_object(
      'id', v_caso.id_externo,
      'caso_id', v_caso.id,
      'skill', COALESCE(v_caso.equipa_codigo, '-'),
      'equipa_id', v_caso.equipa_id,
      'equipa', v_caso.equipa_nome,
      'criacao', to_char(v_caso.criado_em AT TIME ZONE 'Europe/Lisbon', 'DD/MM/YYYY'),
      'rqs', COALESCE(to_char(v_caso.data_rqs AT TIME ZONE 'Europe/Lisbon', 'DD/MM/YYYY'), '-'),
      'agendIso', COALESCE(to_char(v_caso.data_agendamento AT TIME ZONE 'Europe/Lisbon', 'YYYY-MM-DD"T"HH24:MI'), ''),
      'estado', CASE v_caso.status
        WHEN 'livre' THEN 'Livre'
        WHEN 'em_tratamento' THEN 'Em Tratamento'
        WHEN 'pendente' THEN 'Pendente'
        WHEN 'por_tratar' THEN 'Por tratar'
        WHEN 'agendado' THEN 'Agendado'
        WHEN 'suspenso' THEN 'Suspenso'
        WHEN 'outro' THEN 'Outro'
        WHEN 'concluido' THEN 'Concluído'
        WHEN 'cancelado' THEN 'Cancelado'
        ELSE v_caso.status::text
      END,
      'status', v_caso.status,
      'resp', COALESCE(split_part(v_caso.resp_email, '@', 1), '-'),
      'resp_email', COALESCE(v_caso.resp_email, ''),
      'colaborador_id', v_caso.colaborador_id,
      'obsCompleta', COALESCE(v_caso.notas, ''),
      'obsTruncada', CASE
        WHEN length(COALESCE(v_caso.notas, '')) > 30
        THEN left(v_caso.notas, 30) || '...'
        ELSE COALESCE(v_caso.notas, '')
      END,
      'intercalar', CASE WHEN v_intercalar THEN v_caso.intercalar_em::text ELSE '' END,
      'prioridade', CASE WHEN v_caso.prioridade_flash THEN 'SIM' ELSE '' END,
      'prioridade_flash', v_caso.prioridade_flash,
      'inicio_tratamento', v_caso.inicio_tratamento
    );

    IF v_caso.status NOT IN ('concluido', 'cancelado') THEN
      v_lista_todos := v_lista_todos || jsonb_build_array(v_caso_json);
    END IF;

    IF v_caso.status = 'outro' THEN
      v_lista_outro := v_lista_outro || jsonb_build_array(v_caso_json);
    END IF;

    IF v_caso.status IN ('livre', 'por_tratar') THEN
      v_lista_livres := v_lista_livres || jsonb_build_array(v_caso_json);
    END IF;

    v_grupo := CASE
      WHEN v_caso.status IN ('livre', 'por_tratar') THEN 'livres'
      WHEN v_caso.status IN ('concluido', 'cancelado') THEN 'fechados'
      ELSE 'trabalho'
    END;

    IF (v_caso.criado_em AT TIME ZONE 'Europe/Lisbon')::date <= v_sla_limite THEN
      IF v_grupo = 'livres' THEN
        v_lista_atras := v_lista_atras || jsonb_build_array(v_caso_json);
      ELSIF v_grupo = 'trabalho' THEN
        v_lista_atras := v_lista_atras || jsonb_build_array(v_caso_json);
      END IF;
    END IF;

    IF v_caso.data_rqs IS NOT NULL AND NOT v_intercalar THEN
      IF (v_caso.data_rqs AT TIME ZONE 'Europe/Lisbon')::date < (v_hoje_inicio AT TIME ZONE 'Europe/Lisbon')::date THEN
        IF v_grupo IN ('livres', 'trabalho') THEN
          v_lista_rqs_atr := v_lista_rqs_atr || jsonb_build_array(v_caso_json);
        END IF;
      END IF;
      IF v_caso.data_rqs <= v_hoje_fim THEN
        IF v_grupo IN ('livres', 'trabalho') THEN
          v_lista_rqs_hj := v_lista_rqs_hj || jsonb_build_array(v_caso_json);
        END IF;
      END IF;
    END IF;
  END LOOP;

  -- Stats globais do dia (eventos)
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
    WHERE c.area_id = v_area_id
      AND c.status = 'em_tratamento'
      AND c.inicio_tratamento IS NOT NULL;
  ELSIF v_global_trat > 0 AND v_global_tempo > 0 THEN
    NULL;
  ELSE
    v_global_tempo := 0;
  END IF;

  IF v_global_trat > 0 AND v_global_tempo > 0 THEN
    v_tmt_seg := (v_global_tempo)::int;
  ELSE
    v_tmt_seg := 0;
  END IF;

  v_m := lpad((v_tmt_seg / 60)::text, 2, '0');
  v_s := lpad((v_tmt_seg % 60)::text, 2, '0');
  v_tmt_global := v_m || ':' || v_s;

  v_fila := jsonb_build_object(
    'livres', jsonb_array_length(v_lista_livres),
    'emTratamento', (
      SELECT COUNT(*)::int FROM public.casos c
      WHERE c.area_id = v_area_id
        AND c.status = 'em_tratamento'
        AND (p_equipas_filtro IS NULL OR c.equipa_id = ANY(p_equipas_filtro))
    ),
    'suspensos', (
      SELECT COUNT(*)::int FROM public.casos c
      WHERE c.area_id = v_area_id AND c.status = 'suspenso'
        AND (p_equipas_filtro IS NULL OR c.equipa_id = ANY(p_equipas_filtro))
    ),
    'carteira', jsonb_array_length(v_lista_todos),
    'outro', jsonb_array_length(v_lista_outro),
    'atrasadosLivres', (
      SELECT COUNT(*)::int FROM jsonb_array_elements(v_lista_atras) el
      WHERE el->>'estado' IN ('Livre', 'Por tratar')
    ),
    'atrasadosTrabalho', (
      SELECT COUNT(*)::int FROM jsonb_array_elements(v_lista_atras) el
      WHERE el->>'estado' NOT IN ('Livre', 'Por tratar', 'Concluído', 'Cancelado')
    ),
    'rqsUltrapassadasLivres', (
      SELECT COUNT(*)::int FROM jsonb_array_elements(v_lista_rqs_atr) el
      WHERE el->>'estado' IN ('Livre', 'Por tratar')
    ),
    'rqsUltrapassadasTrabalho', (
      SELECT COUNT(*)::int FROM jsonb_array_elements(v_lista_rqs_atr) el
      WHERE el->>'estado' NOT IN ('Livre', 'Por tratar', 'Concluído', 'Cancelado')
    ),
    'rqsHojeLivres', (
      SELECT COUNT(*)::int FROM jsonb_array_elements(v_lista_rqs_hj) el
      WHERE el->>'estado' IN ('Livre', 'Por tratar')
    ),
    'rqsHojeTrabalho', (
      SELECT COUNT(*)::int FROM jsonb_array_elements(v_lista_rqs_hj) el
      WHERE el->>'estado' NOT IN ('Livre', 'Por tratar', 'Concluído', 'Cancelado')
    ),
    'tratadasDia', v_global_trat,
    'concluidasDia', v_global_concl,
    'tmtGlobal', v_tmt_global,
    'listaAtrasados', v_lista_atras,
    'listaRqsUltrapassadas', v_lista_rqs_atr,
    'listaRqsHoje', v_lista_rqs_hj,
    'listaLivres', v_lista_livres,
    'listaTodos', v_lista_todos,
    'listaOutro', v_lista_outro
  );

  -- Equipa
  FOR v_u IN
    SELECT
      u.id,
      u.email,
      u.nome,
      u.presenca,
      u.role,
      u.ultimo_ping,
      e.nome AS equipa_nome,
      p.slug AS perfil_slug
    FROM public.utilizadores u
    JOIN public.equipas e ON e.id = u.equipa_id
    LEFT JOIN public.perfis p ON p.id = u.perfil_id
    WHERE u.area_id = v_area_id
    ORDER BY
      CASE u.presenca WHEN 'disponivel' THEN 0 WHEN 'pausa' THEN 1 ELSE 2 END,
      u.nome
  LOOP
    v_is_super := COALESCE(v_u.perfil_slug IN ('supervisor', 'coordenador', 'admin'), false)
      OR v_u.role = 'supervisor';

    SELECT COUNT(DISTINCT ec.caso_id) INTO v_tratadas
    FROM public.eventos_caso ec
    WHERE ec.actor_id = v_u.id
      AND ec.acao = 'atribuir_tarefa'
      AND ec.criado_em >= v_hoje_inicio;

    SELECT COUNT(DISTINCT ec.caso_id) INTO v_concluidas
    FROM public.eventos_caso ec
    WHERE ec.actor_id = v_u.id
      AND ec.acao = 'concluir_caso'
      AND ec.criado_em >= v_hoje_inicio;

    SELECT COALESCE(AVG(
      EXTRACT(EPOCH FROM (ec_fim.criado_em - ec_ini.criado_em))
    )::int, 0) INTO v_tmt_seg
    FROM public.eventos_caso ec_fim
    JOIN public.eventos_caso ec_ini ON ec_ini.caso_id = ec_fim.caso_id
      AND ec_ini.acao = 'atribuir_tarefa'
      AND ec_ini.actor_id = v_u.id
      AND ec_ini.criado_em <= ec_fim.criado_em
    WHERE ec_fim.actor_id = v_u.id
      AND ec_fim.acao = 'concluir_caso'
      AND ec_fim.criado_em >= v_hoje_inicio;

    SELECT c.id_externo, c.inicio_tratamento, c.id
    INTO v_caso_ativo
    FROM public.casos c
    WHERE c.colaborador_id = v_u.id AND c.status = 'em_tratamento'
    LIMIT 1;

    v_partes := string_to_array(trim(v_u.nome), ' ');
    IF array_length(v_partes, 1) > 1 THEN
      v_nome_vis := v_partes[1] || ' ' || v_partes[array_length(v_partes, 1)];
    ELSE
      v_nome_vis := v_partes[1];
    END IF;

    IF v_tmt_seg = 0 AND v_caso_ativo.inicio_tratamento IS NOT NULL THEN
      v_tmt_seg := GREATEST(0, EXTRACT(EPOCH FROM (now() - v_caso_ativo.inicio_tratamento))::int);
    END IF;

    v_m := lpad((v_tmt_seg / 60)::text, 2, '0');
    v_s := lpad((v_tmt_seg % 60)::text, 2, '0');

    v_presenca_lbl := CASE v_u.presenca
      WHEN 'disponivel' THEN 'Disponível'
      WHEN 'pausa' THEN 'Pausa'
      ELSE 'Offline'
    END;

    v_equipa := v_equipa || jsonb_build_array(jsonb_build_object(
      'id', v_u.id,
      'email', v_u.email,
      'nome', v_nome_vis,
      'loja', v_u.equipa_nome,
      'equipaOp', v_u.equipa_nome,
      'estado', v_presenca_lbl,
      'presenca', v_u.presenca,
      'horaMudanca', COALESCE(
        EXTRACT(EPOCH FROM v_u.ultimo_ping) * 1000,
        EXTRACT(EPOCH FROM now()) * 1000
      ),
      'tratadas', COALESCE(v_tratadas, 0),
      'concluidas', COALESCE(v_concluidas, 0),
      'tmtFormatado', v_m || ':' || v_s,
      'tmtSegundos', v_tmt_seg,
      'isSuper', v_is_super,
      'casoAtivoId', v_caso_ativo.id_externo,
      'casoAtivoCasoId', v_caso_ativo.id,
      'casoAtivoTs', CASE
        WHEN v_caso_ativo.inicio_tratamento IS NOT NULL
        THEN EXTRACT(EPOCH FROM v_caso_ativo.inicio_tratamento) * 1000
        ELSE NULL
      END
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'sucesso', true,
    'equipa', v_equipa,
    'fila', v_fila,
    'equipasMaster', v_equipas_master
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- reatribuir_caso — réplica GAS reatribuirCasoServidor
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.reatribuir_caso(
  p_caso_id         UUID,
  p_colaborador_id  UUID DEFAULT NULL,
  p_flash           BOOLEAN DEFAULT false
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caso   public.casos%ROWTYPE;
  v_email  TEXT;
  v_nota   TEXT;
  v_user   TEXT;
  v_novo   public.caso_status;
BEGIN
  IF NOT public.has_permissao('casos.actualizar_area') THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_PERMISSAO',
      'mensagem', 'Sem permissão para reatribuir casos.'
    );
  END IF;

  SELECT c.* INTO v_caso
  FROM public.casos c
  WHERE c.id = p_caso_id AND c.area_id = public.get_user_area_id()
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Caso não encontrado.');
  END IF;

  SELECT u.email INTO v_email FROM public.utilizadores u WHERE u.id = auth.uid();
  v_user := split_part(COALESCE(v_email, 'supervisao'), '@', 1);

  IF p_colaborador_id IS NULL THEN
    UPDATE public.casos
    SET
      status = 'livre',
      colaborador_id = NULL,
      inicio_tratamento = NULL,
      data_agendamento = NULL,
      prioridade_flash = false,
      notas = public._prepend_nota_caso(
        v_caso.notas,
        '[Auto] Caso DEVOLVIDO à Fila Geral por ' || v_user || '. Estado limpo.',
        v_email
      ),
      versao = versao + 1
    WHERE id = p_caso_id
    RETURNING * INTO v_caso;
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM public.utilizadores u
      WHERE u.id = p_colaborador_id AND u.area_id = v_caso.area_id
    ) THEN
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Colaborador inválido.');
    END IF;

    v_novo := CASE
      WHEN v_caso.status IN ('suspenso', 'em_tratamento', 'livre', 'por_tratar') THEN 'pendente'::public.caso_status
      ELSE v_caso.status
    END;

    v_nota := '[Auto] Reatribuído por ' || v_user
      || CASE WHEN p_flash THEN ' (Com PRIORIDADE FLASH)' ELSE '' END || '.';

    UPDATE public.casos
    SET
      status = v_novo,
      colaborador_id = p_colaborador_id,
      inicio_tratamento = NULL,
      prioridade_flash = p_flash,
      notas = public._prepend_nota_caso(v_caso.notas, v_nota, v_email),
      versao = versao + 1
    WHERE id = p_caso_id
    RETURNING * INTO v_caso;
  END IF;

  PERFORM public._registar_evento_caso(
    v_caso.id, v_caso.area_id, 'reatribuir_caso',
    jsonb_build_object(
      'colaborador_id', p_colaborador_id,
      'flash', p_flash
    )
  );

  RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Caso reatribuído com sucesso!');
END;
$$;

-- ---------------------------------------------------------------------------
-- alterar_prioridade_flash — réplica GAS alterarPrioridadeServidor
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.alterar_prioridade_flash(
  p_caso_id UUID,
  p_flash   BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caso  public.casos%ROWTYPE;
  v_email TEXT;
  v_txt   TEXT;
BEGIN
  IF NOT public.has_permissao('casos.actualizar_area') THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_PERMISSAO',
      'mensagem', 'Sem permissão para alterar prioridade.'
    );
  END IF;

  SELECT c.* INTO v_caso
  FROM public.casos c
  WHERE c.id = p_caso_id AND c.area_id = public.get_user_area_id()
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Caso não encontrado.');
  END IF;

  SELECT u.email INTO v_email FROM public.utilizadores u WHERE u.id = auth.uid();
  v_txt := '[Auto] Prioridade ' || CASE WHEN p_flash THEN 'ativada (Flash)' ELSE 'removida' END
    || ' pela Supervisão.';

  UPDATE public.casos
  SET
    prioridade_flash = p_flash,
    notas = public._prepend_nota_caso(v_caso.notas, v_txt, v_email),
    versao = versao + 1
  WHERE id = p_caso_id
  RETURNING * INTO v_caso;

  PERFORM public._registar_evento_caso(
    v_caso.id, v_caso.area_id, 'alterar_prioridade_flash',
    jsonb_build_object('flash', p_flash)
  );

  RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Prioridade atualizada!');
END;
$$;

GRANT EXECUTE ON FUNCTION public._data_limite_sla() TO authenticated;
GRANT EXECUTE ON FUNCTION public.obter_dados_supervisao(UUID[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reatribuir_caso(UUID, UUID, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.alterar_prioridade_flash(UUID, BOOLEAN) TO authenticated;
