-- Smart Queue v2 — MS-05: RPCs motor de fila (réplica GAS MVP)
--
-- GAS: pedirNovaTarefa, obterMeusPendentes, finalizarTarefaServidor, enviarNudgeServidor
-- MVP: recuperação sessão (-3/-2) + fila livre SKIP LOCKED; tiers completos em MS-11.

-- ---------------------------------------------------------------------------
-- Helpers internos
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._prepend_nota_caso(
  p_notas       TEXT,
  p_observacao  TEXT,
  p_actor_email TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_obs   TEXT := NULLIF(trim(p_observacao), '');
  v_email TEXT := COALESCE(NULLIF(trim(p_actor_email), ''), 'sistema');
  v_user  TEXT := split_part(v_email, '@', 1);
  v_nova  TEXT;
BEGIN
  IF v_obs IS NULL THEN
    RETURN COALESCE(p_notas, '');
  END IF;

  v_nova := '[' || to_char(now() AT TIME ZONE 'Europe/Lisbon', 'DD/MM HH24:MI') || ' - ' || v_user || ']' || E'\n' || v_obs;

  IF COALESCE(trim(p_notas), '') = '' THEN
    RETURN v_nova;
  END IF;

  RETURN v_nova || E'\n\n' || p_notas;
END;
$$;

CREATE OR REPLACE FUNCTION public._caso_para_json(p_caso public.casos)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object(
    'id', p_caso.id,
    'id_externo', p_caso.id_externo,
    'status', p_caso.status,
    'canal', p_caso.canal,
    'pn', COALESCE(p_caso.pn, '-'),
    'notas', COALESCE(p_caso.notas, ''),
    'data_rqs', p_caso.data_rqs,
    'data_agendamento', p_caso.data_agendamento,
    'intercalar_em', p_caso.intercalar_em,
    'prioridade_flash', p_caso.prioridade_flash,
    'inicio_tratamento', p_caso.inicio_tratamento,
    'equipa_id', p_caso.equipa_id
  );
$$;

CREATE OR REPLACE FUNCTION public._registar_evento_caso(
  p_caso_id  UUID,
  p_area_id  UUID,
  p_acao     TEXT,
  p_detalhes JSONB DEFAULT NULL
)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  INSERT INTO public.eventos_caso (caso_id, area_id, actor_id, acao, detalhes)
  VALUES (p_caso_id, p_area_id, auth.uid(), p_acao, p_detalhes);
$$;

-- ---------------------------------------------------------------------------
-- obter_meus_pendentes — réplica GAS obterMeusPendentes
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obter_meus_pendentes()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_limite_hoje TIMESTAMPTZ;
  v_itens       JSONB := '[]'::jsonb;
  v_row         RECORD;
  v_obs         TEXT;
  v_obs_trunc   TEXT;
BEGIN
  IF NOT public.has_permissao('casos.ver_proprios') THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_PERMISSAO',
      'mensagem', 'Sem permissão para ver casos próprios.'
    );
  END IF;

  v_limite_hoje := date_trunc('day', now() AT TIME ZONE 'Europe/Lisbon')
    + interval '23 hours 59 minutes 59 seconds';

  FOR v_row IN
    SELECT
      c.id_externo,
      c.status,
      c.data_rqs,
      c.data_agendamento,
      c.notas,
      c.intercalar_em
    FROM public.casos c
    WHERE c.colaborador_id = auth.uid()
      AND c.status IN ('pendente', 'por_tratar', 'agendado', 'suspenso', 'outro')
    ORDER BY COALESCE(c.data_agendamento, c.data_rqs, c.criado_em) ASC
  LOOP
    v_obs := COALESCE(v_row.notas, '');
    v_obs_trunc := v_obs;
    IF length(v_obs_trunc) > 40 THEN
      v_obs_trunc := left(v_obs_trunc, 40) || '...';
    END IF;

    v_itens := v_itens || jsonb_build_array(jsonb_build_object(
      'id', v_row.id_externo,
      'estado', initcap(replace(v_row.status::text, '_', ' ')),
      'rqs', CASE
        WHEN v_row.data_rqs IS NOT NULL THEN to_char(v_row.data_rqs AT TIME ZONE 'Europe/Lisbon', 'DD/MM/YYYY HH24:MI')
        ELSE '-'
      END,
      'agendamento', CASE
        WHEN v_row.data_agendamento IS NOT NULL THEN to_char(v_row.data_agendamento AT TIME ZONE 'Europe/Lisbon', 'DD/MM/YYYY HH24:MI')
        ELSE '-'
      END,
      'obsCompleta', v_obs,
      'obsTruncada', v_obs_trunc,
      'hasIntercalar', (v_row.intercalar_em IS NOT NULL),
      'isRqsAtrasada', (v_row.data_rqs IS NOT NULL AND v_row.data_rqs <= v_limite_hoje)
    ));
  END LOOP;

  RETURN jsonb_build_object('sucesso', true, 'dados', v_itens);
END;
$$;

-- ---------------------------------------------------------------------------
-- atribuir_tarefa — réplica GAS pedirNovaTarefa (MVP)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.atribuir_tarefa(p_equipa_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user        RECORD;
  v_equipa_id   UUID;
  v_caso        public.casos%ROWTYPE;
  v_equipa_nome TEXT;
  v_recuperacao BOOLEAN := false;
BEGIN
  IF NOT public.has_permissao('casos.pedir_tarefa') THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_PERMISSAO',
      'mensagem', 'Sem permissão para pedir tarefa.'
    );
  END IF;

  SELECT u.id, u.area_id, u.equipa_id, u.email, u.presenca
  INTO v_user
  FROM public.utilizadores u
  WHERE u.id = auth.uid();

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SESSAO_INVALIDA',
      'mensagem', 'Sessão não identificada. Atualiza a página (F5).'
    );
  END IF;

  IF v_user.presenca IS DISTINCT FROM 'disponivel' THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_OPERADOR_NAO_DISPONIVEL',
      'mensagem', 'Auto-atribuição bloqueada: operador não está Disponível.'
    );
  END IF;

  v_equipa_id := COALESCE(p_equipa_id, v_user.equipa_id);

  IF NOT EXISTS (
    SELECT 1 FROM public.equipas e
    WHERE e.id = v_equipa_id AND e.area_id = v_user.area_id AND e.ativo
  ) THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_EQUIPA_INVALIDA',
      'mensagem', 'Equipa inválida para a tua área.'
    );
  END IF;

  -- Tier -3: recuperação em_tratamento
  SELECT c.*
  INTO v_caso
  FROM public.casos c
  WHERE c.area_id = v_user.area_id
    AND c.colaborador_id = auth.uid()
    AND c.status = 'em_tratamento'
  ORDER BY c.inicio_tratamento ASC NULLS LAST
  FOR UPDATE SKIP LOCKED
  LIMIT 1;

  IF NOT FOUND THEN
    -- Tier -2: recuperação suspenso
    SELECT c.*
    INTO v_caso
    FROM public.casos c
    WHERE c.area_id = v_user.area_id
      AND c.colaborador_id = auth.uid()
      AND c.status = 'suspenso'
    ORDER BY c.atualizado_em ASC
    FOR UPDATE SKIP LOCKED
    LIMIT 1;

    IF FOUND THEN
      v_recuperacao := true;
    END IF;
  ELSE
    v_recuperacao := true;
  END IF;

  IF NOT FOUND THEN
    -- Fila livre: flash → data_rqs → criado_em (MVP)
    SELECT c.*
    INTO v_caso
    FROM public.casos c
    WHERE c.area_id = v_user.area_id
      AND c.equipa_id = v_equipa_id
      AND c.status IN ('livre', 'por_tratar')
      AND (c.colaborador_id IS NULL OR (c.colaborador_id = auth.uid() AND c.status = 'por_tratar'))
    ORDER BY
      c.prioridade_flash DESC,
      COALESCE(c.data_agendamento, c.data_rqs) ASC NULLS LAST,
      c.criado_em ASC
    FOR UPDATE SKIP LOCKED
    LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_ELEGIVEIS',
      'mensagem', 'Sem tarefas disponíveis para o teu perfil.'
    );
  END IF;

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

  SELECT e.nome INTO v_equipa_nome
  FROM public.equipas e WHERE e.id = v_caso.equipa_id;

  PERFORM public._registar_evento_caso(
    v_caso.id, v_caso.area_id, 'atribuir_tarefa',
    jsonb_build_object('recuperacao', v_recuperacao, 'equipa_id', v_equipa_id)
  );

  RETURN jsonb_build_object(
    'sucesso', true,
    'recuperacao', v_recuperacao,
    'tarefa', jsonb_build_object(
      'id', v_caso.id,
      'idUnico', v_caso.id_externo,
      'loja', COALESCE(v_equipa_nome, ''),
      'canal', v_caso.canal,
      'pn', COALESCE(v_caso.pn, '-'),
      'observacoes', COALESCE(v_caso.notas, ''),
      'dataRqsIso', v_caso.data_rqs,
      'dataDespertadorIso', COALESCE(v_caso.data_agendamento, v_caso.data_rqs),
      'intercalar', v_caso.intercalar_em,
      'prioridade_flash', v_caso.prioridade_flash
    )
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- concluir_caso — réplica GAS finalizarTarefaServidor (concluído/cancelado)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.concluir_caso(
  p_caso_id     UUID,
  p_observacoes TEXT DEFAULT NULL,
  p_status      public.caso_status DEFAULT 'concluido'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caso  public.casos%ROWTYPE;
  v_email TEXT;
BEGIN
  IF p_status NOT IN ('concluido', 'cancelado') THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', 'Estado final inválido. Use concluido ou cancelado.'
    );
  END IF;

  SELECT c.* INTO v_caso
  FROM public.casos c
  WHERE c.id = p_caso_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Caso não encontrado.');
  END IF;

  IF public.has_permissao_developer()
    OR (public.has_permissao('casos.actualizar_area') AND v_caso.area_id = public.get_user_area_id())
  THEN
    NULL;
  ELSIF public.has_permissao('casos.actualizar_proprios')
    AND v_caso.colaborador_id = auth.uid()
  THEN
    IF v_caso.status IS DISTINCT FROM 'em_tratamento' THEN
      RETURN jsonb_build_object(
        'sucesso', false,
        'ejetar', true,
        'mensagem', 'O caso já não está em tratamento. O painel foi sincronizado para continuares.'
      );
    END IF;
  ELSE
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_PERMISSAO',
      'mensagem', 'Sem permissão para concluir este caso.'
    );
  END IF;

  SELECT u.email INTO v_email FROM public.utilizadores u WHERE u.id = auth.uid();

  UPDATE public.casos
  SET
    status = p_status,
    colaborador_id = NULL,
    inicio_tratamento = NULL,
    notas = public._prepend_nota_caso(v_caso.notas, p_observacoes, v_email),
    versao = versao + 1
  WHERE id = p_caso_id
  RETURNING * INTO v_caso;

  PERFORM public._registar_evento_caso(
    v_caso.id, v_caso.area_id, 'concluir_caso',
    jsonb_build_object('status', p_status)
  );

  RETURN jsonb_build_object('sucesso', true, 'caso', public._caso_para_json(v_caso));
END;
$$;

-- ---------------------------------------------------------------------------
-- agendar_caso — réplica GAS finalizarTarefaServidor (estados com despertador)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.agendar_caso(
  p_caso_id          UUID,
  p_status           public.caso_status,
  p_data_agendamento TIMESTAMPTZ,
  p_observacoes      TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caso       public.casos%ROWTYPE;
  v_email      TEXT;
  v_limite_max TIMESTAMPTZ;
  v_limite_rqs TIMESTAMPTZ;
BEGIN
  IF p_status NOT IN ('agendado', 'pendente', 'por_tratar', 'suspenso', 'outro') THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', 'Estado de agendamento inválido.'
    );
  END IF;

  IF p_data_agendamento IS NULL THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', 'Data de agendamento obrigatória.'
    );
  END IF;

  SELECT c.* INTO v_caso
  FROM public.casos c
  WHERE c.id = p_caso_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Caso não encontrado.');
  END IF;

  IF public.has_permissao_developer()
    OR (public.has_permissao('casos.actualizar_area') AND v_caso.area_id = public.get_user_area_id())
  THEN
    NULL;
  ELSIF public.has_permissao('casos.actualizar_proprios')
    AND v_caso.colaborador_id = auth.uid()
  THEN
    IF v_caso.status IS DISTINCT FROM 'em_tratamento' THEN
      RETURN jsonb_build_object(
        'sucesso', false,
        'ejetar', true,
        'mensagem', 'O caso já não está em tratamento. O painel foi sincronizado para continuares.'
      );
    END IF;
  ELSE
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_PERMISSAO',
      'mensagem', 'Sem permissão para agendar este caso.'
    );
  END IF;

  v_limite_max := (date_trunc('day', now() AT TIME ZONE 'Europe/Lisbon') + interval '7 days')
    + interval '23 hours 59 minutes 59 seconds';

  IF p_data_agendamento > v_limite_max THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', 'Não podes agendar com mais de 7 dias de antecedência.'
    );
  END IF;

  IF v_caso.intercalar_em IS NULL AND v_caso.data_rqs IS NOT NULL THEN
    v_limite_rqs := date_trunc('day', v_caso.data_rqs AT TIME ZONE 'Europe/Lisbon')
      + interval '20 hours';
    IF p_data_agendamento > v_limite_rqs THEN
      RETURN jsonb_build_object(
        'sucesso', false,
        'mensagem', 'Sem intercalar marcada, só podes agendar até ao limite da RQS (20:00 do dia da RQS).'
      );
    END IF;
  END IF;

  SELECT u.email INTO v_email FROM public.utilizadores u WHERE u.id = auth.uid();

  UPDATE public.casos
  SET
    status = p_status,
    data_agendamento = p_data_agendamento,
    inicio_tratamento = NULL,
    notas = public._prepend_nota_caso(v_caso.notas, p_observacoes, v_email),
    versao = versao + 1
  WHERE id = p_caso_id
  RETURNING * INTO v_caso;

  PERFORM public._registar_evento_caso(
    v_caso.id, v_caso.area_id, 'agendar_caso',
    jsonb_build_object('status', p_status, 'data_agendamento', p_data_agendamento)
  );

  RETURN jsonb_build_object('sucesso', true, 'caso', public._caso_para_json(v_caso));
END;
$$;

-- ---------------------------------------------------------------------------
-- marcar_outro — atalho GAS estado Outro
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.marcar_outro(
  p_caso_id          UUID,
  p_observacoes      TEXT DEFAULT NULL,
  p_data_agendamento TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.agendar_caso(
    p_caso_id,
    'outro'::public.caso_status,
    COALESCE(p_data_agendamento, now()),
    p_observacoes
  );
$$;

-- ---------------------------------------------------------------------------
-- enviar_nudge — réplica GAS enviarNudgeServidor (persiste em notificacoes)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.enviar_nudge(
  p_destinatario_id UUID,
  p_mensagem        TEXT,
  p_caso_id         UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id UUID;
  v_msg     TEXT := NULLIF(trim(p_mensagem), '');
  v_notif   public.notificacoes%ROWTYPE;
BEGIN
  IF NOT public.has_permissao('supervisao.nudges') THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_PERMISSAO',
      'mensagem', 'Sem permissão para enviar nudges.'
    );
  END IF;

  IF v_msg IS NULL THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Mensagem obrigatória.');
  END IF;

  v_area_id := public.get_user_area_id();

  IF NOT EXISTS (
    SELECT 1 FROM public.utilizadores u
    WHERE u.id = p_destinatario_id AND u.area_id = v_area_id
  ) THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', 'Destinatário inválido ou fora da tua área.'
    );
  END IF;

  IF p_caso_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.casos c
    WHERE c.id = p_caso_id AND c.area_id = v_area_id
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Caso inválido para esta área.');
  END IF;

  INSERT INTO public.notificacoes (area_id, destinatario_id, remetente_id, caso_id, mensagem)
  VALUES (v_area_id, p_destinatario_id, auth.uid(), p_caso_id, v_msg)
  RETURNING * INTO v_notif;

  RETURN jsonb_build_object(
    'sucesso', true,
    'notificacao_id', v_notif.id
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

GRANT EXECUTE ON FUNCTION public.obter_meus_pendentes() TO authenticated;
GRANT EXECUTE ON FUNCTION public.atribuir_tarefa(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.concluir_caso(UUID, TEXT, public.caso_status) TO authenticated;
GRANT EXECUTE ON FUNCTION public.agendar_caso(UUID, public.caso_status, TIMESTAMPTZ, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.marcar_outro(UUID, TEXT, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.enviar_nudge(UUID, TEXT, UUID) TO authenticated;
