-- MS-09b: presença com suspensão de casos + supervisor forçar estado (réplica GAS)

-- ---------------------------------------------------------------------------
-- Helper: suspender casos em_tratamento de um colaborador
-- Réplica GAS suspenderCasosEmTratamentoServidor (mantém colaborador_id)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._suspender_casos_em_tratamento(
  p_utilizador_id UUID,
  p_motivo        TEXT DEFAULT 'Operador indisponível'
)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caso   public.casos%ROWTYPE;
  v_email  TEXT;
  v_nota   TEXT;
  v_count  INT := 0;
BEGIN
  SELECT u.email INTO v_email
  FROM public.utilizadores u
  WHERE u.id = p_utilizador_id;

  v_nota := '[Auto] Caso Suspenso (' || COALESCE(p_motivo, 'Operador indisponível')
    || ') - Retido para o operador.';

  FOR v_caso IN
    SELECT c.*
    FROM public.casos c
    WHERE c.colaborador_id = p_utilizador_id
      AND c.status = 'em_tratamento'
    FOR UPDATE
  LOOP
    UPDATE public.casos
    SET
      status = 'suspenso',
      inicio_tratamento = NULL,
      prioridade_flash = true,
      notas = public._prepend_nota_caso(v_caso.notas, v_nota, v_email),
      versao = versao + 1
    WHERE id = v_caso.id;

    PERFORM public._registar_evento_caso(
      v_caso.id, v_caso.area_id, 'suspender_caso_presenca',
      jsonb_build_object('motivo', p_motivo, 'utilizador_id', p_utilizador_id)
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

-- ---------------------------------------------------------------------------
-- atualizar_presenca — operador altera o próprio estado (réplica GAS atualizarEstadoOperador)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.atualizar_presenca(
  p_presenca public.presenca_status
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
    RETURN jsonb_build_object('sucesso', true, 'sem_alteracao', true);
  END IF;

  UPDATE public.utilizadores
  SET presenca = p_presenca, ultimo_ping = now()
  WHERE id = auth.uid();

  -- GAS: só mantém caso activo em Disponível ou Trabalho manual (MVP: só disponivel)
  IF p_presenca IS DISTINCT FROM 'disponivel' THEN
    v_motivo := CASE p_presenca
      WHEN 'pausa' THEN 'Operador em Pausa'
      WHEN 'offline' THEN 'Operador Offline'
      ELSE 'Operador indisponível'
    END;
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
-- forcar_estado_operador — supervisor altera estado de colaborador
-- Réplica GAS forcarEstadoOperador / alterarEstadoTerceiro
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

  v_lbl := CASE p_presenca
    WHEN 'disponivel' THEN 'Disponível'
    WHEN 'pausa' THEN 'Pausa'
    WHEN 'offline' THEN 'Offline'
    ELSE p_presenca::text
  END;

  IF v_alvo.presenca IS NOT DISTINCT FROM p_presenca AND NOT p_reforco THEN
    RETURN jsonb_build_object('sucesso', true, 'sem_alteracao', true, 'presenca', p_presenca);
  END IF;

  UPDATE public.utilizadores
  SET presenca = p_presenca, ultimo_ping = now()
  WHERE id = p_utilizador_id;

  -- GAS forcarEstadoOperador: suspende SEMPRE (inclui reforço com caso activo)
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

GRANT EXECUTE ON FUNCTION public._suspender_casos_em_tratamento(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.atualizar_presenca(public.presenca_status) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forcar_estado_operador(UUID, public.presenca_status, BOOLEAN) TO authenticated;
