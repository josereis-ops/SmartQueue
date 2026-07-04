-- MS-09b: atribuir tarefa específica — réplica GAS pedirTarefaEspecifica / tratarPendente

CREATE OR REPLACE FUNCTION public.atribuir_tarefa_especifica(p_id_externo TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user        RECORD;
  v_caso        public.casos%ROWTYPE;
  v_equipa_nome TEXT;
  v_id_norm     TEXT;
BEGIN
  IF NOT public.has_permissao('casos.pedir_tarefa') THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_PERMISSAO',
      'mensagem', 'Sem permissão para pedir tarefa.'
    );
  END IF;

  SELECT u.id, u.area_id, u.equipa_id, u.email
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

  UPDATE public.casos
  SET
    status = 'em_tratamento',
    colaborador_id = auth.uid(),
    inicio_tratamento = COALESCE(inicio_tratamento, now()),
    distribuido_em = COALESCE(distribuido_em, now()),
    versao = versao + 1
  WHERE id = v_caso.id
  RETURNING * INTO v_caso;

  SELECT e.nome INTO v_equipa_nome
  FROM public.equipas e WHERE e.id = v_caso.equipa_id;

  PERFORM public._registar_evento_caso(
    v_caso.id, v_caso.area_id, 'atribuir_tarefa_especifica',
    jsonb_build_object('id_externo', v_id_norm)
  );

  RETURN jsonb_build_object(
    'sucesso', true,
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

GRANT EXECUTE ON FUNCTION public.atribuir_tarefa_especifica(TEXT) TO authenticated;
