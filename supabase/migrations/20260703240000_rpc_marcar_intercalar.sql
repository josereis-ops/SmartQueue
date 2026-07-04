-- marcar_intercalar — réplica GAS marcarIntercalarServidor

CREATE OR REPLACE FUNCTION public.marcar_intercalar(p_caso_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caso public.casos%ROWTYPE;
BEGIN
  IF NOT public.has_permissao('casos.actualizar_proprios') THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_PERMISSAO',
      'mensagem', 'Sem permissão para marcar intercalar.'
    );
  END IF;

  SELECT * INTO v_caso
  FROM public.casos
  WHERE id = p_caso_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', 'Caso não encontrado.'
    );
  END IF;

  IF v_caso.colaborador_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'codigo_erro', 'SQ_SEM_PERMISSAO',
      'mensagem', 'Este caso não está atribuído a ti.'
    );
  END IF;

  IF v_caso.status IS DISTINCT FROM 'em_tratamento' THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'ejetar', true,
      'mensagem', 'O caso já não está em tratamento.'
    );
  END IF;

  IF v_caso.intercalar_em IS NOT NULL THEN
    RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Intercalar já estava marcada.');
  END IF;

  UPDATE public.casos
  SET intercalar_em = now(), versao = versao + 1
  WHERE id = p_caso_id
  RETURNING * INTO v_caso;

  PERFORM public._registar_evento_caso(
    v_caso.id, v_caso.area_id, 'marcar_intercalar', '{}'::jsonb
  );

  RETURN jsonb_build_object(
    'sucesso', true,
    'mensagem', 'Intercalar marcada com sucesso.',
    'intercalar_em', v_caso.intercalar_em
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.marcar_intercalar(UUID) TO authenticated;
