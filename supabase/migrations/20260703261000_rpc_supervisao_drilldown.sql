-- MS-09b+: RPCs drill-down supervisão — réplica GAS alterarEstado/Agendamento/Skill/Nota/Concluir

CREATE OR REPLACE FUNCTION public._supervisor_pode_caso(p_caso_id UUID)
RETURNS public.casos
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caso public.casos%ROWTYPE;
BEGIN
  IF NOT public.has_permissao('casos.actualizar_area') THEN
    RAISE EXCEPTION 'SQ_SEM_PERMISSAO';
  END IF;

  SELECT c.* INTO v_caso
  FROM public.casos c
  WHERE c.id = p_caso_id AND c.area_id = public.get_user_area_id()
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SQ_CASO_NAO_ENCONTRADO';
  END IF;

  RETURN v_caso;
END;
$$;

-- Nota supervisão (histórico cumulativo — réplica adicionarObservacaoSupervisaoServidor)
CREATE OR REPLACE FUNCTION public.adicionar_observacao_supervisao(
  p_caso_id UUID,
  p_texto   TEXT
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
  IF p_texto IS NULL OR trim(p_texto) = '' THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'A observação não pode estar vazia.');
  END IF;
  IF length(trim(p_texto)) > 4000 THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Observação demasiado longa (máx. 4000 caracteres).');
  END IF;

  BEGIN
    v_caso := public._supervisor_pode_caso(p_caso_id);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'SQ_SEM_PERMISSAO' THEN
        RETURN jsonb_build_object('sucesso', false, 'codigo_erro', 'SQ_SEM_PERMISSAO', 'mensagem', 'Sem permissão.');
      END IF;
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Caso não encontrado.');
  END;

  SELECT u.email INTO v_email FROM public.utilizadores u WHERE u.id = auth.uid();

  UPDATE public.casos
  SET
    notas = public._prepend_nota_caso(v_caso.notas, trim(p_texto), v_email),
    versao = versao + 1
  WHERE id = p_caso_id
  RETURNING * INTO v_caso;

  PERFORM public._registar_evento_caso(
    v_caso.id, v_caso.area_id, 'observacao_supervisao',
    jsonb_build_object('tamanho', length(trim(p_texto)))
  );

  RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Observação registada no histórico do caso.');
END;
$$;

-- Alterar estado do caso (réplica alterarEstadoServidor)
CREATE OR REPLACE FUNCTION public.alterar_estado_caso_supervisao(
  p_caso_id UUID,
  p_status  public.caso_status
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caso   public.casos%ROWTYPE;
  v_email  TEXT;
  v_lbl    TEXT;
  v_nota   TEXT;
BEGIN
  IF p_status NOT IN ('livre', 'pendente', 'por_tratar', 'agendado', 'suspenso', 'outro', 'em_tratamento') THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Estado inválido para alteração pela supervisão.');
  END IF;

  BEGIN
    v_caso := public._supervisor_pode_caso(p_caso_id);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'SQ_SEM_PERMISSAO' THEN
        RETURN jsonb_build_object('sucesso', false, 'codigo_erro', 'SQ_SEM_PERMISSAO', 'mensagem', 'Sem permissão.');
      END IF;
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Caso não encontrado.');
  END;

  SELECT u.email INTO v_email FROM public.utilizadores u WHERE u.id = auth.uid();

  v_lbl := CASE p_status
    WHEN 'livre' THEN 'Livre'
    WHEN 'pendente' THEN 'Pendente'
    WHEN 'por_tratar' THEN 'Por tratar'
    WHEN 'agendado' THEN 'Agendado'
    WHEN 'suspenso' THEN 'Suspenso'
    WHEN 'outro' THEN 'Outro'
    WHEN 'em_tratamento' THEN 'Em Tratamento'
    ELSE p_status::text
  END;

  v_nota := '[Auto] Estado forçado para ''' || v_lbl || ''' pela Supervisão.';

  UPDATE public.casos
  SET
    status = p_status,
    colaborador_id = CASE WHEN p_status IN ('livre', 'por_tratar') THEN NULL ELSE colaborador_id END,
    inicio_tratamento = CASE WHEN p_status IN ('livre', 'por_tratar', 'pendente', 'agendado', 'suspenso', 'outro') THEN NULL ELSE inicio_tratamento END,
    notas = public._prepend_nota_caso(v_caso.notas, v_nota, v_email),
    versao = versao + 1
  WHERE id = p_caso_id
  RETURNING * INTO v_caso;

  PERFORM public._registar_evento_caso(
    v_caso.id, v_caso.area_id, 'alterar_estado_supervisao',
    jsonb_build_object('status', p_status)
  );

  RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Estado actualizado!');
END;
$$;

-- Alterar agendamento (réplica alterarAgendamentoServidor)
CREATE OR REPLACE FUNCTION public.alterar_agendamento_supervisao(
  p_caso_id          UUID,
  p_data_agendamento TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caso  public.casos%ROWTYPE;
  v_email TEXT;
  v_nota  TEXT;
BEGIN
  BEGIN
    v_caso := public._supervisor_pode_caso(p_caso_id);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'SQ_SEM_PERMISSAO' THEN
        RETURN jsonb_build_object('sucesso', false, 'codigo_erro', 'SQ_SEM_PERMISSAO', 'mensagem', 'Sem permissão.');
      END IF;
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Caso não encontrado.');
  END;

  SELECT u.email INTO v_email FROM public.utilizadores u WHERE u.id = auth.uid();

  IF p_data_agendamento IS NULL THEN
    v_nota := '[Auto] Agendamento REMOVIDO pela Supervisão.';
  ELSE
    v_nota := '[Auto] Agendamento alterado para '
      || to_char(p_data_agendamento AT TIME ZONE 'Europe/Lisbon', 'DD/MM/YYYY HH24:MI')
      || ' pela Supervisão.';
  END IF;

  UPDATE public.casos
  SET
    data_agendamento = p_data_agendamento,
    notas = public._prepend_nota_caso(v_caso.notas, v_nota, v_email),
    versao = versao + 1
  WHERE id = p_caso_id
  RETURNING * INTO v_caso;

  PERFORM public._registar_evento_caso(
    v_caso.id, v_caso.area_id, 'alterar_agendamento_supervisao',
    jsonb_build_object('data_agendamento', p_data_agendamento)
  );

  RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Agendamento actualizado!');
END;
$$;

-- Alterar skill/equipa (réplica alterarSkillServidor)
CREATE OR REPLACE FUNCTION public.alterar_equipa_caso_supervisao(
  p_caso_id   UUID,
  p_equipa_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caso        public.casos%ROWTYPE;
  v_email       TEXT;
  v_equipa_nome TEXT;
  v_nota        TEXT;
BEGIN
  BEGIN
    v_caso := public._supervisor_pode_caso(p_caso_id);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'SQ_SEM_PERMISSAO' THEN
        RETURN jsonb_build_object('sucesso', false, 'codigo_erro', 'SQ_SEM_PERMISSAO', 'mensagem', 'Sem permissão.');
      END IF;
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Caso não encontrado.');
  END;

  IF NOT EXISTS (
    SELECT 1 FROM public.equipas e
    WHERE e.id = p_equipa_id AND e.area_id = v_caso.area_id AND e.ativo
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Equipa/skill inválida.');
  END IF;

  SELECT e.nome INTO v_equipa_nome FROM public.equipas e WHERE e.id = p_equipa_id;
  SELECT u.email INTO v_email FROM public.utilizadores u WHERE u.id = auth.uid();

  v_nota := '[Auto] Skill alterada para ''' || COALESCE(v_equipa_nome, '?')
    || ''' pela Supervisão. Caso limpo e devolvido à fila.';

  UPDATE public.casos
  SET
    equipa_id = p_equipa_id,
    status = 'livre',
    colaborador_id = NULL,
    inicio_tratamento = NULL,
    data_agendamento = NULL,
    prioridade_flash = false,
    notas = public._prepend_nota_caso(v_caso.notas, v_nota, v_email),
    versao = versao + 1
  WHERE id = p_caso_id
  RETURNING * INTO v_caso;

  PERFORM public._registar_evento_caso(
    v_caso.id, v_caso.area_id, 'alterar_equipa_supervisao',
    jsonb_build_object('equipa_id', p_equipa_id)
  );

  RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Skill actualizada e caso reiniciado!');
END;
$$;

-- Concluir directo (réplica concluirCasoDiretoServidor)
CREATE OR REPLACE FUNCTION public.concluir_caso_direto_supervisao(
  p_caso_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caso  public.casos%ROWTYPE;
  v_email TEXT;
  v_nota  TEXT;
BEGIN
  BEGIN
    v_caso := public._supervisor_pode_caso(p_caso_id);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'SQ_SEM_PERMISSAO' THEN
        RETURN jsonb_build_object('sucesso', false, 'codigo_erro', 'SQ_SEM_PERMISSAO', 'mensagem', 'Sem permissão.');
      END IF;
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Caso não encontrado.');
  END;

  SELECT u.email INTO v_email FROM public.utilizadores u WHERE u.id = auth.uid();
  v_nota := '[Auto] Caso fechado directamente pela Supervisão. Sem atribuição de operacionais.';

  UPDATE public.casos
  SET
    status = 'concluido',
    colaborador_id = NULL,
    inicio_tratamento = NULL,
    prioridade_flash = false,
    notas = public._prepend_nota_caso(v_caso.notas, v_nota, v_email),
    versao = versao + 1
  WHERE id = p_caso_id
  RETURNING * INTO v_caso;

  PERFORM public._registar_evento_caso(
    v_caso.id, v_caso.area_id, 'concluir_caso_direto_supervisao',
    jsonb_build_object('id_externo', v_caso.id_externo)
  );

  RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Caso concluído e limpo!');
END;
$$;

GRANT EXECUTE ON FUNCTION public._supervisor_pode_caso(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.adicionar_observacao_supervisao(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.alterar_estado_caso_supervisao(UUID, public.caso_status) TO authenticated;
GRANT EXECUTE ON FUNCTION public.alterar_agendamento_supervisao(UUID, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.alterar_equipa_caso_supervisao(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.concluir_caso_direto_supervisao(UUID) TO authenticated;
