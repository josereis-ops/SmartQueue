-- MS-20: Criar caso manual (paridade GAS criarCasoManualServidor)
-- + normalização ID em atribuir_tarefa_especifica (puxar caso por ID)

CREATE OR REPLACE FUNCTION public.criar_caso_manual(
  p_id_externo   TEXT,
  p_canal        TEXT,
  p_data_criacao DATE,
  p_data_rqs     DATE,
  p_equipa_id    UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user      RECORD;
  v_id_norm   TEXT;
  v_caso      public.casos%ROWTYPE;
  v_criacao   TIMESTAMPTZ;
  v_rqs       TIMESTAMPTZ;
  v_nota      TEXT;
BEGIN
  IF NOT public.has_permissao('casos.pedir_tarefa') THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_PERMISSAO',
      'mensagem', 'Sem permissão para criar casos.'
    );
  END IF;

  SELECT u.id, u.area_id, u.equipa_id, u.email, u.ponto_atendimento_id
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

  v_id_norm := public._normalizar_id_importacao(p_id_externo);
  IF v_id_norm = '' THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Insere o número do caso.');
  END IF;

  IF trim(COALESCE(p_canal, '')) = '' THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'O canal é obrigatório.');
  END IF;

  IF p_data_criacao IS NULL THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'A data de criação é obrigatória.');
  END IF;

  IF p_data_rqs IS NULL THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'A data de RQS é obrigatória.');
  END IF;

  IF p_equipa_id IS NULL THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'A skill é obrigatória.');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.equipas e
    WHERE e.id = p_equipa_id
      AND e.area_id = v_user.area_id
      AND e.ativo = true
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Skill inválida para a tua área.');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.utilizador_equipas ue
    WHERE ue.utilizador_id = v_user.id
      AND ue.equipa_id = p_equipa_id
  ) AND p_equipa_id IS DISTINCT FROM v_user.equipa_id THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', 'Não tens permissão para criar casos nesta skill.'
    );
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.casos c
    WHERE c.area_id = v_user.area_id
      AND public._normalizar_id_importacao(c.id_externo) = v_id_norm
  ) THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', format('O Caso ''%s'' já se encontra registado na fila!', v_id_norm)
    );
  END IF;

  v_criacao := (p_data_criacao::text || ' 00:00:00')::timestamp AT TIME ZONE 'Europe/Lisbon';
  v_rqs := (p_data_rqs::text || ' 23:59:59')::timestamp AT TIME ZONE 'Europe/Lisbon';
  v_nota := 'Caso criado manualmente no painel por ' || COALESCE(v_user.email, 'operador');

  INSERT INTO public.casos (
    area_id,
    equipa_id,
    ponto_atendimento_id,
    colaborador_id,
    id_externo,
    status,
    canal,
    notas,
    data_rqs,
    criado_em,
    inicio_tratamento,
    distribuido_em
  ) VALUES (
    v_user.area_id,
    p_equipa_id,
    v_user.ponto_atendimento_id,
    v_user.id,
    v_id_norm,
    'em_tratamento',
    trim(p_canal),
    v_nota,
    v_rqs,
    v_criacao,
    now(),
    now()
  )
  RETURNING * INTO v_caso;

  PERFORM public._registar_evento_caso(
    v_caso.id,
    v_caso.area_id,
    'criar_caso_manual',
    jsonb_build_object(
      'id_externo', v_id_norm,
      'canal', trim(p_canal),
      'equipa_id', p_equipa_id
    )
  );

  PERFORM public._registar_evento_caso(
    v_caso.id,
    v_caso.area_id,
    'atribuir_tarefa',
    jsonb_build_object('origem', 'criar_caso_manual')
  );

  RETURN jsonb_build_object(
    'sucesso', true,
    'tarefa', public._motor_tarefa_json(v_caso)
  );
END;
$$;

-- Puxar caso: normalizar ID como no GAS (_normIdCaso_)
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

  v_id_norm := public._normalizar_id_importacao(p_id_externo);
  IF v_id_norm = '' THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Identificador do caso em falta.');
  END IF;

  SELECT c.*
  INTO v_caso
  FROM public.casos c
  WHERE c.area_id = v_user.area_id
    AND public._normalizar_id_importacao(c.id_externo) = v_id_norm
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Caso não encontrado na base de dados.');
  END IF;

  IF v_caso.status IN ('concluido', 'cancelado') THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'O caso já está Concluído.');
  END IF;

  IF v_caso.status = 'em_tratamento'
    AND v_caso.colaborador_id IS NOT NULL
    AND v_caso.colaborador_id IS DISTINCT FROM auth.uid()
  THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', 'O caso já está a ser tratado por outro colaborador.'
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
        'mensagem', 'Caso não elegível para o teu perfil (skill ou ponto).'
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

GRANT EXECUTE ON FUNCTION public.criar_caso_manual(TEXT, TEXT, DATE, DATE, UUID) TO authenticated;
