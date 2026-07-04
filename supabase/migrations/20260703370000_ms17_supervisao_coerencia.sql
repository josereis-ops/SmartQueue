-- MS-17: Sala de Controlo coerente
-- Fix: record v_caso_ativo não assignável campo-a-campo em PL/pgSQL
-- KPI emTratamento alinhado com badges visíveis (presença mantém caso activo)
-- Backfill: suspender casos em_tratamento órfãos (dono Offline/Pausa/etc.)

DO $$
DECLARE
  v_u     RECORD;
  v_total INT := 0;
  v_n     INT;
BEGIN
  FOR v_u IN
    SELECT u.id, u.presenca
    FROM public.utilizadores u
    WHERE NOT public._presenca_mantem_caso_ativo(u.presenca)
      AND EXISTS (
        SELECT 1
        FROM public.casos c
        WHERE c.colaborador_id = u.id
          AND c.status = 'em_tratamento'
      )
  LOOP
    v_n := public._suspender_casos_em_tratamento(
      v_u.id,
      'Backfill MS-17: presença «'
        || public._presenca_label(v_u.presenca)
        || '» não mantém caso activo'
    );
    v_total := v_total + v_n;
  END LOOP;

  RAISE NOTICE 'MS-17 backfill: % caso(s) em_tratamento suspensos', v_total;
END;
$$;

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
  v_area_id        UUID;
  v_hoje_inicio    TIMESTAMPTZ;
  v_hoje_fim       TIMESTAMPTZ;
  v_sla_limite     DATE;
  v_equipa         JSONB := '[]'::jsonb;
  v_equipas_master JSONB := '[]'::jsonb;
  v_fila           JSONB;
  v_lista_todos    JSONB := '[]'::jsonb;
  v_lista_livres   JSONB := '[]'::jsonb;
  v_lista_atras    JSONB := '[]'::jsonb;
  v_lista_rqs_atr  JSONB := '[]'::jsonb;
  v_lista_rqs_hj   JSONB := '[]'::jsonb;
  v_lista_outro    JSONB := '[]'::jsonb;
  v_caso           RECORD;
  v_caso_json      JSONB;
  v_grupo          TEXT;
  v_intercalar     BOOLEAN;
  v_global_trat    INT := 0;
  v_global_concl   INT := 0;
  v_global_tempo   BIGINT := 0;
  v_tmt_global     TEXT;
  v_u              RECORD;
  v_tratadas       INT;
  v_concluidas     INT;
  v_caso_ativo_id_externo TEXT;
  v_caso_ativo_inicio     TIMESTAMPTZ;
  v_caso_ativo_id         UUID;
  v_nome_vis       TEXT;
  v_partes         TEXT[];
  v_tmt_seg        INT;
  v_m              TEXT;
  v_s              TEXT;
  v_presenca_lbl   TEXT;
  v_is_super       BOOLEAN;
  v_skills_csv     TEXT;
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

  FOR v_caso IN
    SELECT
      c.*,
      e.nome AS equipa_nome,
      e.codigo AS equipa_codigo,
      pt.nome AS ponto_nome,
      u.email AS resp_email,
      u.nome AS resp_nome
    FROM public.casos c
    JOIN public.equipas e ON e.id = c.equipa_id
    LEFT JOIN public.pontos_atendimento pt ON pt.id = c.ponto_atendimento_id
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
      'loja', COALESCE(v_caso.loja, v_caso.ponto_nome, '-'),
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
        WHEN 'concluido' THEN 'Concluido'
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
      SELECT COUNT(*)::int
      FROM public.casos c
      JOIN public.utilizadores u ON u.id = c.colaborador_id
      WHERE c.area_id = v_area_id
        AND c.status = 'em_tratamento'
        AND public._presenca_mantem_caso_ativo(u.presenca)
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
      WHERE el->>'estado' NOT IN ('Livre', 'Por tratar', 'Concluido', 'Cancelado')
    ),
    'rqsUltrapassadasLivres', (
      SELECT COUNT(*)::int FROM jsonb_array_elements(v_lista_rqs_atr) el
      WHERE el->>'estado' IN ('Livre', 'Por tratar')
    ),
    'rqsUltrapassadasTrabalho', (
      SELECT COUNT(*)::int FROM jsonb_array_elements(v_lista_rqs_atr) el
      WHERE el->>'estado' NOT IN ('Livre', 'Por tratar', 'Concluido', 'Cancelado')
    ),
    'rqsHojeLivres', (
      SELECT COUNT(*)::int FROM jsonb_array_elements(v_lista_rqs_hj) el
      WHERE el->>'estado' IN ('Livre', 'Por tratar')
    ),
    'rqsHojeTrabalho', (
      SELECT COUNT(*)::int FROM jsonb_array_elements(v_lista_rqs_hj) el
      WHERE el->>'estado' NOT IN ('Livre', 'Por tratar', 'Concluido', 'Cancelado')
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

  FOR v_u IN
    SELECT
      u.id,
      u.email,
      u.nome,
      u.presenca,
      u.role,
      u.ultimo_ping,
      e.nome AS skill_primaria,
      pt.nome AS ponto_nome,
      p.slug AS perfil_slug
    FROM public.utilizadores u
    JOIN public.equipas e ON e.id = u.equipa_id
    LEFT JOIN public.pontos_atendimento pt ON pt.id = u.ponto_atendimento_id
    LEFT JOIN public.perfis p ON p.id = u.perfil_id
    WHERE u.area_id = v_area_id
    ORDER BY
      public._presenca_ordem(u.presenca),
      u.nome
  LOOP
    v_is_super := COALESCE(v_u.perfil_slug IN ('supervisor', 'coordenador', 'admin'), false)
      OR v_u.role = 'supervisor';

    SELECT string_agg(eq.nome, ', ' ORDER BY eq.nome)
    INTO v_skills_csv
    FROM public.utilizador_equipas ue
    JOIN public.equipas eq ON eq.id = ue.equipa_id
    WHERE ue.utilizador_id = v_u.id;

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

    v_caso_ativo_id_externo := NULL;
    v_caso_ativo_inicio := NULL;
    v_caso_ativo_id := NULL;

    IF public._presenca_mantem_caso_ativo(v_u.presenca) THEN
      SELECT c.id_externo, c.inicio_tratamento, c.id
      INTO v_caso_ativo_id_externo, v_caso_ativo_inicio, v_caso_ativo_id
      FROM public.casos c
      WHERE c.colaborador_id = v_u.id AND c.status = 'em_tratamento'
      LIMIT 1;
    END IF;

    v_partes := string_to_array(trim(v_u.nome), ' ');
    IF array_length(v_partes, 1) > 1 THEN
      v_nome_vis := v_partes[1] || ' ' || v_partes[array_length(v_partes, 1)];
    ELSE
      v_nome_vis := v_partes[1];
    END IF;

    IF v_tmt_seg = 0 AND v_caso_ativo_inicio IS NOT NULL THEN
      v_tmt_seg := GREATEST(0, EXTRACT(EPOCH FROM (now() - v_caso_ativo_inicio))::int);
    END IF;

    v_m := lpad((v_tmt_seg / 60)::text, 2, '0');
    v_s := lpad((v_tmt_seg % 60)::text, 2, '0');

    v_presenca_lbl := public._presenca_label(v_u.presenca);

    v_equipa := v_equipa || jsonb_build_array(jsonb_build_object(
      'id', v_u.id,
      'email', v_u.email,
      'nome', v_nome_vis,
      'loja', COALESCE(v_u.ponto_nome, '—'),
      'equipaOp', COALESCE(v_skills_csv, v_u.skill_primaria, '—'),
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
      'casoAtivoId', v_caso_ativo_id_externo,
      'casoAtivoCasoId', v_caso_ativo_id,
      'casoAtivoTs', CASE
        WHEN v_caso_ativo_inicio IS NOT NULL
        THEN EXTRACT(EPOCH FROM v_caso_ativo_inicio) * 1000
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
