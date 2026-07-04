-- MS-14 (parte 2): helpers presença + RPCs (após commit dos novos enum values)

-- ---------------------------------------------------------------------------
-- Helpers presença (réplica GAS Dashboard.html prioridadeEstado / labels)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._presenca_mantem_caso_ativo(p_presenca public.presenca_status)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT p_presenca IN ('disponivel', 'trabalho_manual');
$$;

CREATE OR REPLACE FUNCTION public._presenca_label(p_presenca public.presenca_status)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_presenca
    WHEN 'disponivel' THEN 'Disponível'
    WHEN 'atendimento_loja' THEN 'Atendimento Loja'
    WHEN 'pausa' THEN 'Pausa'
    WHEN 'refeicao' THEN 'Refeição'
    WHEN 'reuniao' THEN 'Reunião'
    WHEN 'trabalho_manual' THEN 'Trabalho manual'
    WHEN 'atendimento_cc' THEN 'Atendimento cc'
    WHEN 'formacao' THEN 'Formação'
    WHEN 'trabalhos_spv' THEN 'Trabalhos SPV'
    WHEN 'offline' THEN 'Offline'
    ELSE p_presenca::text
  END;
$$;

CREATE OR REPLACE FUNCTION public._presenca_ordem(p_presenca public.presenca_status)
RETURNS INT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_presenca
    WHEN 'disponivel' THEN 0
    WHEN 'trabalho_manual' THEN 1
    WHEN 'trabalhos_spv' THEN 1
    WHEN 'pausa' THEN 2
    WHEN 'refeicao' THEN 2
    WHEN 'formacao' THEN 2
    WHEN 'reuniao' THEN 2
    WHEN 'atendimento_loja' THEN 2
    WHEN 'atendimento_cc' THEN 2
    WHEN 'offline' THEN 3
    ELSE 2
  END;
$$;

CREATE OR REPLACE FUNCTION public._presenca_motivo_suspensao(
  p_presenca public.presenca_status,
  p_custom   TEXT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(
    NULLIF(trim(p_custom), ''),
    CASE p_presenca
      WHEN 'pausa' THEN 'Operador em Pausa'
      WHEN 'offline' THEN 'Operador Offline'
      WHEN 'atendimento_loja' THEN 'Cliente Presencial na Loja'
      WHEN 'refeicao' THEN 'Operador em Refeição'
      WHEN 'reuniao' THEN 'Operador em Reunião'
      WHEN 'trabalho_manual' THEN 'Operador em Trabalho manual'
      WHEN 'atendimento_cc' THEN 'Operador em Atendimento cc'
      WHEN 'formacao' THEN 'Operador em Formação'
      WHEN 'trabalhos_spv' THEN 'Operador em Trabalhos SPV'
      ELSE 'Operador indisponível'
    END
  );
$$;

-- Assinatura anterior (1 arg) — evitar overload ambíguo
DROP FUNCTION IF EXISTS public.atualizar_presenca(public.presenca_status);

-- ---------------------------------------------------------------------------
-- atualizar_presenca — GAS atualizarEstadoOperador (manter caso: Disponível + Trabalho manual)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.atualizar_presenca(
  p_presenca              public.presenca_status,
  p_motivo_suspensao_opt  TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user       RECORD;
  v_suspensos  INT := 0;
  v_motivo     TEXT;
BEGIN
  IF NOT public.has_permissao('presenca.actualizar') THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_PERMISSAO',
      'mensagem', 'Sem permissão para actualizar presença.'
    );
  END IF;

  SELECT u.id, u.presenca, u.area_id
  INTO v_user
  FROM public.utilizadores u
  WHERE u.id = auth.uid();

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SESSAO_INVALIDA',
      'mensagem', 'Sessão não identificada.'
    );
  END IF;

  IF v_user.presenca IS NOT DISTINCT FROM p_presenca THEN
    RETURN jsonb_build_object('sucesso', true, 'sem_alteracao', true, 'presenca', p_presenca);
  END IF;

  UPDATE public.utilizadores
  SET presenca = p_presenca, ultimo_ping = now()
  WHERE id = auth.uid();

  IF NOT public._presenca_mantem_caso_ativo(p_presenca) THEN
    v_motivo := public._presenca_motivo_suspensao(p_presenca, p_motivo_suspensao_opt);
    v_suspensos := public._suspender_casos_em_tratamento(auth.uid(), v_motivo);
  END IF;

  RETURN jsonb_build_object(
    'sucesso', true,
    'presenca', p_presenca,
    'casos_suspensos', v_suspensos
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- ativar_atendimento_loja_flash — GAS ativarClienteNaLojaFlashServidor
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.ativar_atendimento_loja_flash()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res JSONB;
BEGIN
  v_res := public.atualizar_presenca(
    'atendimento_loja'::public.presenca_status,
    'Cliente Presencial na Loja'
  );

  IF COALESCE((v_res->>'sucesso')::boolean, false) THEN
    RETURN jsonb_build_object(
      'sucesso', true,
      'mensagem', 'Atendimento Loja ativado e caso suspenso.',
      'presenca', 'atendimento_loja',
      'casos_suspensos', COALESCE((v_res->>'casos_suspensos')::int, 0)
    );
  END IF;

  RETURN v_res;
END;
$$;

-- ---------------------------------------------------------------------------
-- forcar_estado_operador — labels GAS completos
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.forcar_estado_operador(
  p_utilizador_id UUID,
  p_presenca      public.presenca_status,
  p_reforco       BOOLEAN DEFAULT false
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_alvo       RECORD;
  v_super      RECORD;
  v_suspensos  INT := 0;
  v_motivo     TEXT;
  v_lbl        TEXT;
BEGIN
  IF NOT public.has_permissao('supervisao.dashboard') THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_PERMISSAO',
      'mensagem', 'Não tens permissão para alterar estados.'
    );
  END IF;

  SELECT u.id, u.email, u.nome, u.area_id, u.presenca
  INTO v_alvo
  FROM public.utilizadores u
  WHERE u.id = p_utilizador_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Operador alvo não encontrado.');
  END IF;

  SELECT u.id, u.area_id INTO v_super
  FROM public.utilizadores u
  WHERE u.id = auth.uid();

  IF v_alvo.area_id IS DISTINCT FROM v_super.area_id THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', 'Operador fora da tua área.'
    );
  END IF;

  v_lbl := public._presenca_label(p_presenca);

  IF v_alvo.presenca IS NOT DISTINCT FROM p_presenca AND NOT p_reforco THEN
    RETURN jsonb_build_object('sucesso', true, 'sem_alteracao', true, 'presenca', p_presenca);
  END IF;

  UPDATE public.utilizadores
  SET presenca = p_presenca, ultimo_ping = now()
  WHERE id = p_utilizador_id;

  v_motivo := 'Forçado a ' || v_lbl || ' por SPV';
  v_suspensos := public._suspender_casos_em_tratamento(p_utilizador_id, v_motivo);

  RETURN jsonb_build_object(
    'sucesso', true,
    'mensagem', 'Estado ' || v_lbl || ' aplicado a ' || COALESCE(v_alvo.nome, v_alvo.email) || '.',
    'presenca', p_presenca,
    'casos_suspensos', v_suspensos,
    'reforco', p_reforco
  );
END;
$$;

-- Patch obter_dados_supervisao: labels + ordenacao GAS (corpo intacto MS-10b)
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
  v_skills_csv    TEXT;
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

GRANT EXECUTE ON FUNCTION public._presenca_mantem_caso_ativo(public.presenca_status) TO authenticated;
GRANT EXECUTE ON FUNCTION public._presenca_label(public.presenca_status) TO authenticated;
GRANT EXECUTE ON FUNCTION public._presenca_ordem(public.presenca_status) TO authenticated;
GRANT EXECUTE ON FUNCTION public.atualizar_presenca(public.presenca_status, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ativar_atendimento_loja_flash() TO authenticated;
GRANT EXECUTE ON FUNCTION public.forcar_estado_operador(UUID, public.presenca_status, BOOLEAN) TO authenticated;
