-- MS-16: Ordenacao configuravel por area + validacao motor v3

-- ---------------------------------------------------------------------------
-- Defaults ordenacao (replica GAS actual — backfill mantem comportamento)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._motor_ordenacao_defaults()
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'usar_rqs', true,
    'usar_flash', true,
    'desempate', jsonb_build_array('agendamento', 'rqs', 'criado_em'),
    'tier_livre_sem_rqs', 'antiguidade',
    'tier_livre_com_rqs', 'rqs_primeiro'
  );
$$;

CREATE OR REPLACE FUNCTION public._motor_ordenacao_normalizada(p_config JSONB)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_defaults JSONB := public._motor_ordenacao_defaults();
  v_motor     JSONB := COALESCE(p_config->'motor', '{}'::jsonb);
  v_ord       JSONB := COALESCE(v_motor->'ordenacao', '{}'::jsonb);
  v_desempate JSONB;
  v_campo     TEXT;
  v_ok        BOOLEAN := true;
BEGIN
  v_desempate := COALESCE(v_ord->'desempate', v_defaults->'desempate');

  IF jsonb_typeof(v_desempate) <> 'array' OR jsonb_array_length(v_desempate) = 0 THEN
    v_desempate := v_defaults->'desempate';
  ELSE
    FOR v_campo IN SELECT jsonb_array_elements_text(v_desempate)
    LOOP
      IF v_campo NOT IN ('agendamento', 'rqs', 'criado_em') THEN
        v_ok := false;
        EXIT;
      END IF;
    END LOOP;
    IF NOT v_ok THEN
      v_desempate := v_defaults->'desempate';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'usar_rqs', COALESCE((v_ord->>'usar_rqs')::boolean, (v_defaults->>'usar_rqs')::boolean),
    'usar_flash', COALESCE((v_ord->>'usar_flash')::boolean, (v_defaults->>'usar_flash')::boolean),
    'desempate', v_desempate,
    'tier_livre_sem_rqs', COALESCE(NULLIF(v_ord->>'tier_livre_sem_rqs', ''), v_defaults->>'tier_livre_sem_rqs'),
    'tier_livre_com_rqs', COALESCE(NULLIF(v_ord->>'tier_livre_com_rqs', ''), v_defaults->>'tier_livre_com_rqs')
  );
END;
$$;

CREATE OR REPLACE FUNCTION public._motor_desempate_fragment(p_campo TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_campo
    WHEN 'agendamento' THEN
      'COALESCE(c.data_agendamento, c.data_rqs, c.criado_em) ASC NULLS LAST'
    WHEN 'rqs' THEN
      'CASE WHEN (c.data_rqs IS NOT NULL AND c.data_rqs <= public._motor_limite_hoje() AND c.intercalar_em IS NULL) THEN 0 ELSE 1 END ASC'
    WHEN 'criado_em' THEN
      'c.criado_em ASC'
    ELSE
      'c.criado_em ASC'
  END;
$$;

CREATE OR REPLACE FUNCTION public._motor_build_order_clause(p_ordenacao JSONB)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_parts   TEXT[] := ARRAY['t.tier ASC'];
  v_campo   TEXT;
  v_desempate JSONB;
BEGIN
  IF COALESCE(p_ordenacao->>'tier_livre_sem_rqs', 'antiguidade') = 'antiguidade' THEN
    v_parts := array_append(
      v_parts,
      'CASE WHEN t.tier = 4 THEN c.criado_em END ASC NULLS LAST'
    );
  END IF;

  IF COALESCE(p_ordenacao->>'tier_livre_com_rqs', 'rqs_primeiro') = 'antiguidade' THEN
    v_parts := array_append(
      v_parts,
      'CASE WHEN t.tier = 3 THEN c.criado_em END ASC NULLS LAST'
    );
  END IF;

  IF NOT COALESCE((p_ordenacao->>'usar_rqs')::boolean, true) THEN
    v_parts := array_append(v_parts, 'c.criado_em ASC');
    RETURN array_to_string(v_parts, ', ');
  END IF;

  v_desempate := COALESCE(
    p_ordenacao->'desempate',
    public._motor_ordenacao_defaults()->'desempate'
  );

  FOR v_campo IN SELECT jsonb_array_elements_text(v_desempate)
  LOOP
    v_parts := array_append(v_parts, public._motor_desempate_fragment(v_campo));
  END LOOP;

  RETURN array_to_string(v_parts, ', ');
END;
$$;

-- ---------------------------------------------------------------------------
-- Template default motor v3
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._regras_fila_default_config(
  p_filtro_loja_ativo BOOLEAN DEFAULT false,
  p_timezone          TEXT DEFAULT 'Europe/Lisbon'
)
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'motor', jsonb_build_object(
      'versao', 3,
      'filtros_elegibilidade', jsonb_build_object(
        'skill', jsonb_build_object('ativo', true, 'fonte', 'utilizador_equipas'),
        'ponto_atendimento', jsonb_build_object(
          'ativo', p_filtro_loja_ativo,
          'modo', 'mesmo_ponto',
          'aplicar_tiers', jsonb_build_array('scan', 'dono_ausente', 'libertar_14h')
        )
      ),
      'ordenacao', public._motor_ordenacao_defaults(),
      'tiers_completos', true,
      'libertar_14h', jsonb_build_object(
        'ativo', true,
        'hora', '14:00',
        'timezone', COALESCE(NULLIF(trim(p_timezone), ''), 'Europe/Lisbon')
      )
    ),
    'nudge_mensagens', '[]'::jsonb
  );
$$;

-- ---------------------------------------------------------------------------
-- Validacao motor v2 (runtime defaults) ou v3 (schema completo)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._validar_config_regras_fila(p_config JSONB)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_motor JSONB;
  v_filtros JSONB;
  v_ponto JSONB;
  v_ordenacao JSONB;
  v_tier TEXT;
  v_campo TEXT;
  v_tier_ok BOOLEAN := true;
  v_desempate_ok BOOLEAN := true;
  v_versao INT;
BEGIN
  IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
    RETURN 'Config invalida — objecto JSON esperado.';
  END IF;

  IF NOT (p_config ? 'motor') OR jsonb_typeof(p_config->'motor') <> 'object' THEN
    RETURN 'Campo obrigatorio em falta: motor.';
  END IF;

  v_motor := p_config->'motor';
  v_versao := COALESCE((v_motor->>'versao')::int, 0);

  IF v_versao NOT IN (2, 3) THEN
    RETURN 'motor.versao deve ser 2 ou 3.';
  END IF;

  IF NOT (v_motor ? 'filtros_elegibilidade')
     OR jsonb_typeof(v_motor->'filtros_elegibilidade') <> 'object' THEN
    RETURN 'Campo obrigatorio em falta: motor.filtros_elegibilidade.';
  END IF;

  v_filtros := v_motor->'filtros_elegibilidade';

  IF NOT (v_filtros ? 'skill') OR jsonb_typeof(v_filtros->'skill') <> 'object' THEN
    RETURN 'Campo obrigatorio em falta: motor.filtros_elegibilidade.skill.';
  END IF;

  IF NOT (v_filtros->'skill' ? 'ativo') THEN
    RETURN 'Campo obrigatorio em falta: motor.filtros_elegibilidade.skill.ativo.';
  END IF;

  IF COALESCE(v_filtros->'skill'->>'fonte', '') <> 'utilizador_equipas' THEN
    RETURN 'motor.filtros_elegibilidade.skill.fonte deve ser utilizador_equipas.';
  END IF;

  IF NOT (v_filtros ? 'ponto_atendimento')
     OR jsonb_typeof(v_filtros->'ponto_atendimento') <> 'object' THEN
    RETURN 'Campo obrigatorio em falta: motor.filtros_elegibilidade.ponto_atendimento.';
  END IF;

  v_ponto := v_filtros->'ponto_atendimento';

  IF NOT (v_ponto ? 'ativo') THEN
    RETURN 'Campo obrigatorio em falta: motor.filtros_elegibilidade.ponto_atendimento.ativo.';
  END IF;

  IF COALESCE(v_ponto->>'modo', '') NOT IN ('mesmo_ponto') THEN
    RETURN 'motor.filtros_elegibilidade.ponto_atendimento.modo invalido — use mesmo_ponto.';
  END IF;

  IF NOT (v_ponto ? 'aplicar_tiers') OR jsonb_typeof(v_ponto->'aplicar_tiers') <> 'array' THEN
    RETURN 'Campo obrigatorio em falta: motor.filtros_elegibilidade.ponto_atendimento.aplicar_tiers (array).';
  END IF;

  FOR v_tier IN SELECT jsonb_array_elements_text(v_ponto->'aplicar_tiers')
  LOOP
    IF v_tier NOT IN ('scan', 'dono_ausente', 'libertar_14h') THEN
      v_tier_ok := false;
      EXIT;
    END IF;
  END LOOP;

  IF NOT v_tier_ok THEN
    RETURN 'aplicar_tiers contem valor invalido — permitidos: scan, dono_ausente, libertar_14h.';
  END IF;

  IF NOT (v_motor ? 'tiers_completos') THEN
    RETURN 'Campo obrigatorio em falta: motor.tiers_completos.';
  END IF;

  IF NOT (v_motor ? 'libertar_14h') OR jsonb_typeof(v_motor->'libertar_14h') <> 'object' THEN
    RETURN 'Campo obrigatorio em falta: motor.libertar_14h.';
  END IF;

  IF NOT (v_motor->'libertar_14h' ? 'ativo')
     OR NOT (v_motor->'libertar_14h' ? 'hora')
     OR NOT (v_motor->'libertar_14h' ? 'timezone') THEN
    RETURN 'motor.libertar_14h requer ativo, hora e timezone.';
  END IF;

  IF v_versao = 3 THEN
    IF NOT (v_motor ? 'ordenacao') OR jsonb_typeof(v_motor->'ordenacao') <> 'object' THEN
      RETURN 'Campo obrigatorio em falta: motor.ordenacao (motor v3).';
    END IF;

    v_ordenacao := v_motor->'ordenacao';

    IF NOT (v_ordenacao ? 'usar_rqs') OR NOT (v_ordenacao ? 'usar_flash') THEN
      RETURN 'motor.ordenacao requer usar_rqs e usar_flash.';
    END IF;

    IF NOT (v_ordenacao ? 'desempate') OR jsonb_typeof(v_ordenacao->'desempate') <> 'array' THEN
      RETURN 'motor.ordenacao.desempate deve ser um array.';
    END IF;

    IF jsonb_array_length(v_ordenacao->'desempate') = 0 THEN
      RETURN 'motor.ordenacao.desempate nao pode ser vazio.';
    END IF;

    FOR v_campo IN SELECT jsonb_array_elements_text(v_ordenacao->'desempate')
    LOOP
      IF v_campo NOT IN ('agendamento', 'rqs', 'criado_em') THEN
        v_desempate_ok := false;
        EXIT;
      END IF;
    END LOOP;

    IF NOT v_desempate_ok THEN
      RETURN 'motor.ordenacao.desempate — valores permitidos: agendamento, rqs, criado_em.';
    END IF;

    IF COALESCE(v_ordenacao->>'tier_livre_sem_rqs', '') NOT IN ('antiguidade') THEN
      RETURN 'motor.ordenacao.tier_livre_sem_rqs invalido — use antiguidade.';
    END IF;

    IF COALESCE(v_ordenacao->>'tier_livre_com_rqs', '') NOT IN ('rqs_primeiro', 'antiguidade') THEN
      RETURN 'motor.ordenacao.tier_livre_com_rqs invalido — use rqs_primeiro ou antiguidade.';
    END IF;
  END IF;

  IF p_config ? 'nudge_mensagens' AND jsonb_typeof(p_config->'nudge_mensagens') <> 'array' THEN
    RETURN 'nudge_mensagens deve ser um array.';
  END IF;

  RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- Motor: tiers respeitam usar_rqs / usar_flash; ORDER BY dinamico
-- ---------------------------------------------------------------------------

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
  v_ordenacao       JSONB := public._motor_ordenacao_normalizada(p_config);
  v_usar_rqs        BOOLEAN := COALESCE((v_ordenacao->>'usar_rqs')::boolean, true);
  v_usar_flash      BOOLEAN := COALESCE((v_ordenacao->>'usar_flash')::boolean, true);
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
BEGIN
  IF p_caso.status IN ('concluido', 'cancelado') THEN
    RETURN 99;
  END IF;

  IF NOT v_sou_dono THEN
    IF NOT public._motor_operador_tem_skill(
      p_operador_id, p_caso.equipa_id, p_operador_equipa, v_skill_ativo
    ) THEN
      RETURN 99;
    END IF;
  END IF;

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

  IF p_caso.status = 'por_tratar' AND v_sou_dono AND p_caso.data_agendamento IS NULL THEN
    v_estado_tier := 'livre';
  END IF;

  v_sou_dono_livre := (
    v_dono_id IS NULL OR v_sou_dono OR v_dono_ausente OR v_libertar_14h
  );

  IF (v_dono_ausente OR v_libertar_14h)
    AND NOT v_sou_dono
    AND v_ponto_ativo
    AND NOT public._motor_mesmo_ponto(p_caso.ponto_atendimento_id, p_operador_ponto)
  THEN
    RETURN 99;
  END IF;

  IF v_estado_tier = 'em_tratamento' AND v_sou_dono THEN
    RETURN -3;
  END IF;

  IF v_estado_tier = 'suspenso' AND v_sou_dono THEN
    RETURN -2;
  END IF;

  IF v_usar_flash
    AND p_caso.prioridade_flash
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
    IF v_usar_rqs
      AND p_caso.data_rqs IS NOT NULL
      AND p_caso.data_rqs <= v_limite_hoje
    THEN
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
  v_caso      public.casos;
  v_agora     TIMESTAMPTZ := now();
  v_ordenacao JSONB;
  v_order     TEXT;
  v_sql       TEXT;
BEGIN
  v_ordenacao := public._motor_ordenacao_normalizada(p_config);
  v_order := public._motor_build_order_clause(v_ordenacao);

  v_sql := format(
    'SELECT c.*
     FROM public.casos c
     CROSS JOIN LATERAL (
       SELECT public._motor_caso_tier(
         c, $1, $2, $3, $4, $5, $6
       ) AS tier
     ) t
     WHERE c.area_id = $7
       AND t.tier < 99
     ORDER BY %s
     FOR UPDATE OF c SKIP LOCKED
     LIMIT 1',
    v_order
  );

  EXECUTE v_sql
  INTO v_caso
  USING
    p_operador_id,
    p_operador_email,
    p_operador_equipa,
    p_operador_ponto,
    p_config,
    v_agora,
    p_area_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN v_caso;
END;
$$;

-- ---------------------------------------------------------------------------
-- Backfill: areas existentes → motor v3 com defaults GAS (comportamento identico)
-- ---------------------------------------------------------------------------

UPDATE public.regras_fila rf
SET
  config = jsonb_set(
    jsonb_set(rf.config, '{motor,versao}', '3'::jsonb, true),
    '{motor,ordenacao}',
    public._motor_ordenacao_defaults(),
    true
  ),
  versao = GREATEST(rf.versao, 3),
  atualizado_em = now()
WHERE COALESCE((rf.config->'motor'->>'versao')::int, 0) < 3;
