-- MS-19: Performance Sala de Controlo — KPIs/agregados SQL + drill-down paginado
-- obter_dados_supervisao: modo resumo (default) sem listas JSON de milhares de casos
-- obter_casos_supervisao_drilldown: 100/página sob demanda

-- ---------------------------------------------------------------------------
-- Índices auxiliares supervisão
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_casos_supervisao_carteira
  ON public.casos (area_id, equipa_id, status, criado_em)
  WHERE status NOT IN ('concluido', 'cancelado');

CREATE INDEX IF NOT EXISTS idx_eventos_caso_area_acao_dia
  ON public.eventos_caso (area_id, acao, criado_em);

CREATE INDEX IF NOT EXISTS idx_eventos_caso_actor_acao_dia
  ON public.eventos_caso (actor_id, acao, criado_em);

-- ---------------------------------------------------------------------------
-- Helper: JSON de caso para grelha supervisão
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._supervisao_caso_json(
  p_caso            public.casos,
  p_equipa_nome     TEXT,
  p_ponto_nome      TEXT,
  p_resp_email      TEXT
)
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'id', p_caso.id_externo,
    'caso_id', p_caso.id,
    'skill', COALESCE(p_equipa_nome, '-'),
    'equipa_id', p_caso.equipa_id,
    'equipa', p_equipa_nome,
    'loja', COALESCE(p_caso.loja, p_ponto_nome, '-'),
    'criacao', to_char(p_caso.criado_em AT TIME ZONE 'Europe/Lisbon', 'DD/MM/YYYY'),
    'rqs', COALESCE(to_char(p_caso.data_rqs AT TIME ZONE 'Europe/Lisbon', 'DD/MM/YYYY'), '-'),
    'agendIso', COALESCE(
      to_char(p_caso.data_agendamento AT TIME ZONE 'Europe/Lisbon', 'YYYY-MM-DD"T"HH24:MI'),
      ''
    ),
    'estado', CASE p_caso.status
      WHEN 'livre' THEN 'Livre'
      WHEN 'em_tratamento' THEN 'Em Tratamento'
      WHEN 'pendente' THEN 'Pendente'
      WHEN 'por_tratar' THEN 'Por tratar'
      WHEN 'agendado' THEN 'Agendado'
      WHEN 'suspenso' THEN 'Suspenso'
      WHEN 'outro' THEN 'Outro'
      WHEN 'concluido' THEN 'Concluido'
      WHEN 'cancelado' THEN 'Cancelado'
      ELSE p_caso.status::text
    END,
    'status', p_caso.status,
    'resp', COALESCE(split_part(p_resp_email, '@', 1), '-'),
    'resp_email', COALESCE(p_resp_email, ''),
    'colaborador_id', p_caso.colaborador_id,
    'obsCompleta', COALESCE(p_caso.notas, ''),
    'obsTruncada', CASE
      WHEN length(COALESCE(p_caso.notas, '')) > 30
      THEN left(p_caso.notas, 30) || '...'
      ELSE COALESCE(p_caso.notas, '')
    END,
    'intercalar', CASE
      WHEN p_caso.intercalar_em IS NOT NULL THEN p_caso.intercalar_em::text
      ELSE ''
    END,
    'prioridade', CASE WHEN p_caso.prioridade_flash THEN 'SIM' ELSE '' END,
    'prioridade_flash', p_caso.prioridade_flash,
    'inicio_tratamento', p_caso.inicio_tratamento
  );
$$;

-- Predicado partilhado drill-down
CREATE OR REPLACE FUNCTION public._supervisao_drilldown_match(
  p_caso        public.casos,
  p_tipo        TEXT,
  p_hoje_inicio TIMESTAMPTZ,
  p_hoje_fim    TIMESTAMPTZ,
  p_sla_limite  DATE
)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(trim(COALESCE(p_tipo, '')))
    WHEN 'livres' THEN
      p_caso.status IN ('livre', 'por_tratar')
    WHEN 'carteira' THEN
      p_caso.status NOT IN ('concluido', 'cancelado')
    WHEN 'outro' THEN
      p_caso.status = 'outro'
    WHEN 'atrasados' THEN
      (p_caso.criado_em AT TIME ZONE 'Europe/Lisbon')::date <= p_sla_limite
      AND p_caso.status NOT IN ('concluido', 'cancelado')
    WHEN 'ultrapassadas' THEN
      p_caso.data_rqs IS NOT NULL
      AND p_caso.intercalar_em IS NULL
      AND (p_caso.data_rqs AT TIME ZONE 'Europe/Lisbon')::date
          < (p_hoje_inicio AT TIME ZONE 'Europe/Lisbon')::date
      AND p_caso.status NOT IN ('concluido', 'cancelado')
    WHEN 'hoje' THEN
      p_caso.data_rqs IS NOT NULL
      AND p_caso.intercalar_em IS NULL
      AND p_caso.data_rqs <= p_hoje_fim
      AND p_caso.status NOT IN ('concluido', 'cancelado')
    ELSE false
  END;
$$;

-- ---------------------------------------------------------------------------
-- Drill-down paginado
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obter_casos_supervisao_drilldown(
  p_tipo            TEXT,
  p_offset          INT DEFAULT 0,
  p_limit           INT DEFAULT 100,
  p_equipas_filtro  UUID[] DEFAULT NULL,
  p_pesquisa        TEXT DEFAULT NULL,
  p_sort_col        TEXT DEFAULT 'id',
  p_sort_asc        BOOLEAN DEFAULT true
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id     UUID;
  v_hoje_inicio TIMESTAMPTZ;
  v_hoje_fim    TIMESTAMPTZ;
  v_sla_limite  DATE;
  v_tipo        TEXT := lower(trim(COALESCE(p_tipo, '')));
  v_offset      INT := GREATEST(COALESCE(p_offset, 0), 0);
  v_limit       INT := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
  v_total       BIGINT;
  v_casos       JSONB;
  v_sort_col    TEXT := lower(trim(COALESCE(p_sort_col, 'id')));
  v_order       TEXT;
BEGIN
  IF NOT public.has_permissao('supervisao.dashboard') THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_PERMISSAO',
      'mensagem', 'Sem permissao para aceder a Sala de Controlo.'
    );
  END IF;

  IF v_tipo NOT IN ('atrasados', 'ultrapassadas', 'hoje', 'livres', 'carteira', 'outro') THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Tipo de drill-down invalido.');
  END IF;

  v_area_id := public.get_user_area_id();
  v_hoje_inicio := date_trunc('day', now() AT TIME ZONE 'Europe/Lisbon');
  v_hoje_fim := v_hoje_inicio + interval '23 hours 59 minutes 59 seconds';
  v_sla_limite := public._data_limite_sla();

  v_order := CASE v_sort_col
    WHEN 'criacao' THEN 'c.criado_em'
    WHEN 'rqs' THEN 'c.data_rqs NULLS LAST'
    WHEN 'skill' THEN 'e.nome'
    WHEN 'estado' THEN 'c.status'
    WHEN 'agendiso' THEN 'c.data_agendamento NULLS LAST'
    WHEN 'resp' THEN 'u.email'
    WHEN 'prioridade' THEN 'c.prioridade_flash DESC, c.id_externo'
    WHEN 'obs' THEN 'c.notas'
    ELSE 'c.id_externo'
  END;

  IF NOT p_sort_asc AND v_sort_col NOT IN ('prioridade') THEN
    v_order := v_order || ' DESC';
  ELSIF p_sort_asc AND v_sort_col = 'prioridade' THEN
    v_order := 'c.prioridade_flash ASC, c.id_externo ASC';
  END IF;

  SELECT COUNT(*)::bigint
  INTO v_total
  FROM public.casos c
  WHERE c.area_id = v_area_id
    AND (p_equipas_filtro IS NULL OR c.equipa_id = ANY(p_equipas_filtro))
    AND public._supervisao_drilldown_match(
      c, v_tipo, v_hoje_inicio, v_hoje_fim, v_sla_limite
    )
    AND (
      p_pesquisa IS NULL OR trim(p_pesquisa) = ''
      OR c.id_externo ILIKE '%' || trim(p_pesquisa) || '%'
      OR COALESCE(c.notas, '') ILIKE '%' || trim(p_pesquisa) || '%'
      OR COALESCE(c.loja, '') ILIKE '%' || trim(p_pesquisa) || '%'
    );

  EXECUTE format(
    'SELECT COALESCE(jsonb_agg(row_json), ''[]''::jsonb)
     FROM (
       SELECT public._supervisao_caso_json(c, e.nome, pt.nome, u.email) AS row_json
       FROM public.casos c
       JOIN public.equipas e ON e.id = c.equipa_id
       LEFT JOIN public.pontos_atendimento pt ON pt.id = c.ponto_atendimento_id
       LEFT JOIN public.utilizadores u ON u.id = c.colaborador_id
       WHERE c.area_id = $1
         AND ($2 IS NULL OR c.equipa_id = ANY($2))
         AND public._supervisao_drilldown_match(c, $3, $4, $5, $6)
         AND ($7 IS NULL OR trim($7) = '''' OR (
           c.id_externo ILIKE ''%%'' || trim($7) || ''%%''
           OR COALESCE(c.notas, '''') ILIKE ''%%'' || trim($7) || ''%%''
           OR COALESCE(c.loja, '''') ILIKE ''%%'' || trim($7) || ''%%''
         ))
       ORDER BY %s
       OFFSET $8 LIMIT $9
     ) sub',
    v_order
  )
  INTO v_casos
  USING
    v_area_id,
    p_equipas_filtro,
    v_tipo,
    v_hoje_inicio,
    v_hoje_fim,
    v_sla_limite,
    p_pesquisa,
    v_offset,
    v_limit;

  RETURN jsonb_build_object(
    'sucesso', true,
    'total', COALESCE(v_total, 0),
    'offset', v_offset,
    'limit', v_limit,
    'casos', COALESCE(v_casos, '[]'::jsonb)
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- obter_dados_supervisao — modo resumo (default) + retrocompat listas
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.obter_dados_supervisao(UUID[]);

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
  v_tmt_agente     INT;
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

  -- Equipa: uma query com LATERAL (evita N+1 eventos por utilizador)
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
        'isSuper', (
          COALESCE(p.slug IN ('supervisor', 'coordenador', 'admin'), false)
          OR u.role = 'supervisor'
        ),
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
  ) sub;

  RETURN jsonb_build_object(
    'sucesso', true,
    'equipa', v_equipa,
    'fila', v_fila,
    'equipasMaster', v_equipas_master
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public._supervisao_caso_json(public.casos, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public._supervisao_drilldown_match(public.casos, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obter_casos_supervisao_drilldown(TEXT, INT, INT, UUID[], TEXT, TEXT, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obter_dados_supervisao(UUID[], BOOLEAN) TO authenticated;
