-- MS-11: Motor fila por area — multi-skill M:N, filtro ponto, tiers GAS
-- Replica GAS pedirNovaTarefa via regras_fila.config por area_id

-- ---------------------------------------------------------------------------
-- Helpers motor
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._motor_limite_hoje()
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
AS $$
  SELECT (
    date_trunc('day', now() AT TIME ZONE 'Europe/Lisbon')
    + interval '23 hours 59 minutes 59 seconds'
  ) AT TIME ZONE 'Europe/Lisbon';
$$;

CREATE OR REPLACE FUNCTION public._motor_inicio_hoje()
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
AS $$
  SELECT date_trunc('day', now() AT TIME ZONE 'Europe/Lisbon') AT TIME ZONE 'Europe/Lisbon';
$$;

CREATE OR REPLACE FUNCTION public._motor_config_area(p_area_id UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    (SELECT rf.config FROM public.regras_fila rf WHERE rf.area_id = p_area_id),
    '{}'::jsonb
  );
$$;

CREATE OR REPLACE FUNCTION public._motor_passou_hora(
  p_config JSONB,
  p_agora TIMESTAMPTZ DEFAULT now()
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_cfg     JSONB := COALESCE(p_config->'motor'->'libertar_14h', '{}'::jsonb);
  v_ativo   BOOLEAN := COALESCE((v_cfg->>'ativo')::boolean, true);
  v_hora    INT := COALESCE(NULLIF(split_part(COALESCE(v_cfg->>'hora', '14:00'), ':', 1), '')::int, 14);
  v_local   TIMESTAMP;
BEGIN
  IF NOT v_ativo THEN
    RETURN false;
  END IF;

  v_local := p_agora AT TIME ZONE COALESCE(v_cfg->>'timezone', 'Europe/Lisbon');
  RETURN EXTRACT(HOUR FROM v_local)::int >= v_hora;
END;
$$;

CREATE OR REPLACE FUNCTION public._motor_dono_offline(p_dono_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.utilizadores u
    WHERE u.id = p_dono_id
      AND u.presenca = 'offline'
      AND (
        u.ultimo_ping IS NULL
        OR u.ultimo_ping < public._motor_inicio_hoje()
      )
  );
$$;

CREATE OR REPLACE FUNCTION public._motor_dono_ausente(p_dono_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.utilizadores u
    WHERE u.id = p_dono_id
      AND u.presenca = 'offline'
      AND (
        u.ultimo_ping IS NULL
        OR u.ultimo_ping < (now() - interval '3 days')
      )
  );
$$;

CREATE OR REPLACE FUNCTION public._motor_operador_tem_skill(
  p_operador_id   UUID,
  p_equipa_id     UUID,
  p_equipa_prim   UUID,
  p_skill_ativo   BOOLEAN
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
  SELECT CASE
    WHEN NOT p_skill_ativo THEN p_equipa_id = p_equipa_prim
    ELSE (
      EXISTS (
        SELECT 1 FROM public.utilizador_equipas ue
        WHERE ue.utilizador_id = p_operador_id AND ue.equipa_id = p_equipa_id
      )
      OR p_equipa_id = p_equipa_prim
    )
  END;
$$;

CREATE OR REPLACE FUNCTION public._motor_mesmo_ponto(
  p_caso_ponto_id UUID,
  p_op_ponto_id   UUID
)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    p_caso_ponto_id IS NULL
    OR p_op_ponto_id IS NULL
    OR p_caso_ponto_id = p_op_ponto_id;
$$;

-- Tier GAS por caso/operador; 99 = nao elegivel
CREATE OR REPLACE FUNCTION public._motor_caso_tier(
  p_caso            public.casos,
  p_operador_id     UUID,
  p_operador_email  TEXT,
  p_operador_equipa UUID,
  p_operador_ponto  UUID,
  p_config          JSONB,
  p_agora           TIMESTAMPTZ DEFAULT now()
)
RETURNS INT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_motor           JSONB := COALESCE(p_config->'motor', '{}'::jsonb);
  v_filtros         JSONB := COALESCE(v_motor->'filtros_elegibilidade', '{}'::jsonb);
  v_skill_ativo     BOOLEAN := COALESCE((v_filtros->'skill'->>'ativo')::boolean, true);
  v_ponto_ativo     BOOLEAN := COALESCE((v_filtros->'ponto_atendimento'->>'ativo')::boolean, false);
  v_dono_id         UUID := p_caso.colaborador_id;
  v_sou_dono        BOOLEAN := (v_dono_id = p_operador_id);
  v_estado          public.caso_status := p_caso.status;
  v_estado_tier     public.caso_status := p_caso.status;
  v_limite_hoje     TIMESTAMPTZ := public._motor_limite_hoje();
  v_despertador     TIMESTAMPTZ := COALESCE(p_caso.data_agendamento, p_caso.data_rqs, p_agora);
  v_sem_intercalar  BOOLEAN := (p_caso.intercalar_em IS NULL);
  v_rqs_hoje        BOOLEAN := (p_caso.data_rqs IS NOT NULL AND p_caso.data_rqs <= v_limite_hoje);
  v_dono_offline    BOOLEAN := false;
  v_dono_ausente    BOOLEAN := false;
  v_libertar_14h    BOOLEAN := false;
  v_agend_futuro    BOOLEAN := false;
  v_sou_dono_livre  BOOLEAN;
  v_tier            INT := 99;
BEGIN
  IF p_caso.status IN ('concluido', 'cancelado') THEN
    RETURN 99;
  END IF;

  -- Filtro skill (dono actual isento)
  IF NOT v_sou_dono THEN
    IF NOT public._motor_operador_tem_skill(
      p_operador_id, p_caso.equipa_id, p_operador_equipa, v_skill_ativo
    ) THEN
      RETURN 99;
    END IF;
  END IF;

  -- Filtro ponto / loja (dono actual isento — GAS filtroLoja)
  IF NOT v_sou_dono AND v_ponto_ativo THEN
    IF NOT public._motor_mesmo_ponto(p_caso.ponto_atendimento_id, p_operador_ponto) THEN
      RETURN 99;
    END IF;
  END IF;

  IF v_dono_id IS NOT NULL THEN
    v_dono_offline := public._motor_dono_offline(v_dono_id);
    v_dono_ausente := public._motor_dono_ausente(v_dono_id);
  END IF;

  v_libertar_14h := public._motor_passou_hora(p_config, p_agora)
    AND COALESCE((v_motor->'libertar_14h'->>'ativo')::boolean, true)
    AND v_dono_id IS NOT NULL
    AND NOT v_sou_dono
    AND v_dono_offline
    AND p_caso.status NOT IN ('em_tratamento', 'suspenso')
    AND v_rqs_hoje
    AND v_sem_intercalar;

  v_agend_futuro := p_caso.status IN ('agendado', 'pendente', 'por_tratar', 'outro')
    AND v_despertador > p_agora;

  IF v_libertar_14h AND v_agend_futuro THEN
    v_libertar_14h := false;
  END IF;

  -- por_tratar com resp sem agenda => Livre (GAS)
  IF p_caso.status = 'por_tratar' AND v_sou_dono AND p_caso.data_agendamento IS NULL THEN
    v_estado_tier := 'livre';
  END IF;

  v_sou_dono_livre := (
    v_dono_id IS NULL OR v_sou_dono OR v_dono_ausente OR v_libertar_14h
  );

  -- Regra loja para apanhar caso de colega ausente / 14h
  IF (v_dono_ausente OR v_libertar_14h)
    AND NOT v_sou_dono
    AND v_ponto_ativo
    AND NOT public._motor_mesmo_ponto(p_caso.ponto_atendimento_id, p_operador_ponto)
  THEN
    RETURN 99;
  END IF;

  -- Tiers GAS
  IF v_estado_tier = 'em_tratamento' AND v_sou_dono THEN
    RETURN -3;
  END IF;

  IF v_estado_tier = 'suspenso' AND v_sou_dono THEN
    RETURN -2;
  END IF;

  IF p_caso.prioridade_flash
    AND v_estado_tier IN ('livre', 'por_tratar')
    AND (v_estado_tier <> 'por_tratar' OR v_sou_dono)
    AND v_sou_dono_livre
  THEN
    RETURN -1;
  END IF;

  IF (
    (
      p_caso.status IN ('agendado', 'pendente', 'por_tratar', 'outro', 'suspenso')
      AND v_despertador <= p_agora
    )
    OR v_libertar_14h
  ) THEN
    IF v_sou_dono THEN
      RETURN 1;
    ELSIF v_dono_id IS NULL OR v_dono_ausente OR v_libertar_14h THEN
      RETURN 2;
    END IF;
  END IF;

  IF v_estado_tier = 'livre' AND v_sou_dono_livre THEN
    IF p_caso.data_rqs IS NOT NULL AND p_caso.data_rqs <= v_limite_hoje THEN
      RETURN 3;
    ELSE
      RETURN 4;
    END IF;
  END IF;

  RETURN 99;
END;
$$;

CREATE OR REPLACE FUNCTION public._motor_melhor_caso(
  p_operador_id     UUID,
  p_operador_email  TEXT,
  p_area_id         UUID,
  p_operador_equipa UUID,
  p_operador_ponto  UUID,
  p_config          JSONB
)
RETURNS public.casos
LANGUAGE plpgsql
AS $$
DECLARE
  v_caso public.casos;
  v_agora TIMESTAMPTZ := now();
BEGIN
  SELECT c.*
  INTO v_caso
  FROM public.casos c
  CROSS JOIN LATERAL (
    SELECT public._motor_caso_tier(
      c, p_operador_id, p_operador_email,
      p_operador_equipa, p_operador_ponto, p_config, v_agora
    ) AS tier
  ) t
  WHERE c.area_id = p_area_id
    AND t.tier < 99
  ORDER BY
    t.tier ASC,
    CASE WHEN t.tier = 4 THEN c.criado_em END ASC NULLS LAST,
    COALESCE(c.data_agendamento, c.data_rqs, c.criado_em) ASC NULLS LAST,
    CASE WHEN (c.data_rqs IS NOT NULL AND c.data_rqs <= public._motor_limite_hoje() AND c.intercalar_em IS NULL)
      THEN 0 ELSE 1 END,
    c.criado_em ASC
  FOR UPDATE OF c SKIP LOCKED
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN v_caso;
END;
$$;

CREATE OR REPLACE FUNCTION public._motor_tarefa_json(p_caso public.casos)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object(
    'id', p_caso.id,
    'idUnico', p_caso.id_externo,
    'loja', COALESCE(
      (SELECT pt.nome FROM public.pontos_atendimento pt WHERE pt.id = p_caso.ponto_atendimento_id),
      p_caso.loja,
      (SELECT eq.nome FROM public.equipas eq WHERE eq.id = p_caso.equipa_id),
      ''
    ),
    'canal', p_caso.canal,
    'pn', COALESCE(p_caso.pn, '-'),
    'observacoes', COALESCE(p_caso.notas, ''),
    'dataRqsIso', p_caso.data_rqs,
    'dataDespertadorIso', COALESCE(p_caso.data_agendamento, p_caso.data_rqs),
    'intercalar', p_caso.intercalar_em,
    'prioridade_flash', p_caso.prioridade_flash,
    'equipa_id', p_caso.equipa_id,
    'skill', (SELECT eq.nome FROM public.equipas eq WHERE eq.id = p_caso.equipa_id)
  );
$$;

-- ---------------------------------------------------------------------------
-- atribuir_tarefa — motor v2 (multi-skill + regras por area)
-- p_equipa_id ignorado (retrocompat); motor usa utilizador_equipas + config
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.atribuir_tarefa(p_equipa_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user        RECORD;
  v_config      JSONB;
  v_caso        public.casos;
  v_recuperacao BOOLEAN := false;
  v_tier        INT;
  v_skills      INT;
BEGIN
  IF NOT public.has_permissao('casos.pedir_tarefa') THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_PERMISSAO',
      'mensagem', 'Sem permissao para pedir tarefa.'
    );
  END IF;

  SELECT
    u.id, u.area_id, u.equipa_id, u.email, u.presenca,
    u.ponto_atendimento_id
  INTO v_user
  FROM public.utilizadores u
  WHERE u.id = auth.uid();

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SESSAO_INVALIDA',
      'mensagem', 'Sessao nao identificada. Atualiza a pagina (F5).'
    );
  END IF;

  IF v_user.presenca IS DISTINCT FROM 'disponivel' THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_OPERADOR_NAO_DISPONIVEL',
      'mensagem', 'Auto-atribuicao bloqueada: operador nao esta Disponivel.'
    );
  END IF;

  v_config := public._motor_config_area(v_user.area_id);

  SELECT count(*)::int INTO v_skills
  FROM public.utilizador_equipas ue
  WHERE ue.utilizador_id = v_user.id;

  v_caso := public._motor_melhor_caso(
    v_user.id,
    v_user.email,
    v_user.area_id,
    v_user.equipa_id,
    v_user.ponto_atendimento_id,
    v_config
  );

  IF v_caso IS NULL THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_ELEGIVEIS',
      'mensagem', 'Sem tarefas disponiveis para o teu perfil.',
      'diag', jsonb_build_object(
        'skills_operador', v_skills,
        'filtro_loja_ativo', COALESCE(
          (v_config->'motor'->'filtros_elegibilidade'->'ponto_atendimento'->>'ativo')::boolean,
          false
        )
      )
    );
  END IF;

  v_tier := public._motor_caso_tier(
    v_caso, v_user.id, v_user.email,
    v_user.equipa_id, v_user.ponto_atendimento_id, v_config
  );

  v_recuperacao := (v_tier IN (-3, -2));

  UPDATE public.casos
  SET
    status = 'em_tratamento',
    colaborador_id = auth.uid(),
    inicio_tratamento = COALESCE(inicio_tratamento, now()),
    distribuido_em = COALESCE(distribuido_em, now()),
    prioridade_flash = CASE
      WHEN v_recuperacao THEN prioridade_flash
      WHEN prioridade_flash THEN false
      ELSE prioridade_flash
    END,
    versao = versao + 1
  WHERE id = v_caso.id
  RETURNING * INTO v_caso;

  PERFORM public._registar_evento_caso(
    v_caso.id, v_caso.area_id, 'atribuir_tarefa',
    jsonb_build_object(
      'recuperacao', v_recuperacao,
      'tier', v_tier,
      'motor_versao', COALESCE((v_config->'motor'->>'versao')::int, 1)
    )
  );

  RETURN jsonb_build_object(
    'sucesso', true,
    'recuperacao', v_recuperacao,
    'tier', v_tier,
    'tarefa', public._motor_tarefa_json(v_caso)
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- atribuir_tarefa_especifica — valida skill/ponto para casos nao proprios
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.atribuir_tarefa_especifica(p_id_externo TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user    RECORD;
  v_caso    public.casos%ROWTYPE;
  v_config  JSONB;
  v_id_norm TEXT;
  v_tier    INT;
BEGIN
  IF NOT public.has_permissao('casos.pedir_tarefa') THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_PERMISSAO',
      'mensagem', 'Sem permissao para pedir tarefa.'
    );
  END IF;

  SELECT
    u.id, u.area_id, u.equipa_id, u.email, u.ponto_atendimento_id
  INTO v_user
  FROM public.utilizadores u
  WHERE u.id = auth.uid();

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SESSAO_INVALIDA',
      'mensagem', 'Sessao nao identificada. Atualiza a pagina (F5).'
    );
  END IF;

  v_id_norm := trim(p_id_externo);
  IF v_id_norm = '' THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Identificador do caso em falta.');
  END IF;

  SELECT c.*
  INTO v_caso
  FROM public.casos c
  WHERE c.area_id = v_user.area_id
    AND c.id_externo = v_id_norm
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Caso nao encontrado na base de dados.');
  END IF;

  IF v_caso.status IN ('concluido', 'cancelado') THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'O caso ja esta Concluido.');
  END IF;

  IF v_caso.status = 'em_tratamento'
    AND v_caso.colaborador_id IS NOT NULL
    AND v_caso.colaborador_id IS DISTINCT FROM auth.uid()
  THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', 'O caso ja esta a ser tratado por outro colaborador.'
    );
  END IF;

  v_config := public._motor_config_area(v_user.area_id);

  IF v_caso.colaborador_id IS DISTINCT FROM auth.uid() THEN
    v_tier := public._motor_caso_tier(
      v_caso, v_user.id, v_user.email,
      v_user.equipa_id, v_user.ponto_atendimento_id, v_config
    );
    IF v_tier >= 99 THEN
      RETURN jsonb_build_object(
        'sucesso', false,
        'mensagem', 'Caso nao elegivel para o teu perfil (skill ou ponto).'
      );
    END IF;
  END IF;

  UPDATE public.casos
  SET
    status = 'em_tratamento',
    colaborador_id = auth.uid(),
    inicio_tratamento = COALESCE(inicio_tratamento, now()),
    distribuido_em = COALESCE(distribuido_em, now()),
    versao = versao + 1
  WHERE id = v_caso.id
  RETURNING * INTO v_caso;

  PERFORM public._registar_evento_caso(
    v_caso.id, v_caso.area_id, 'atribuir_tarefa_especifica',
    jsonb_build_object('id_externo', v_id_norm)
  );

  RETURN jsonb_build_object(
    'sucesso', true,
    'tarefa', public._motor_tarefa_json(v_caso)
  );
END;
$$;

-- Indice auxiliar motor multi-skill (scan por area + status)
CREATE INDEX IF NOT EXISTS idx_casos_motor_area_status
  ON public.casos (area_id, status, prioridade_flash DESC, data_rqs ASC NULLS LAST, criado_em ASC)
  WHERE status NOT IN ('concluido', 'cancelado');

GRANT EXECUTE ON FUNCTION public.atribuir_tarefa(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.atribuir_tarefa_especifica(TEXT) TO authenticated;
