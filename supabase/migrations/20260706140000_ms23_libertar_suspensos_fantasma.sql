-- MS-23: Job background — libertar suspensos fantasma (sem tratamento + TMT < 90s)
-- Não altera pedirNovaTarefa / atribuir_proxima_tarefa (hot path).

CREATE OR REPLACE FUNCTION public._caso_tem_obs_antes_retido(p_notas TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_text TEXT := COALESCE(trim(p_notas), '');
  v_sep  INT;
  v_resto TEXT;
BEGIN
  IF v_text = '' THEN
    RETURN false;
  END IF;

  v_sep := strpos(v_text, E'\n\n');
  IF v_sep = 0 THEN
    RETURN false;
  END IF;

  v_resto := trim(substring(v_text FROM v_sep + 2));
  RETURN v_resto <> '';
END;
$$;

CREATE OR REPLACE FUNCTION public._caso_tmt_ultima_sessao_seg(p_caso_id UUID)
RETURNS INT
LANGUAGE sql
STABLE
AS $$
  SELECT GREATEST(0, EXTRACT(EPOCH FROM (es.criado_em - ea.criado_em))::int)
  FROM public.eventos_caso es
  JOIN LATERAL (
    SELECT ec.criado_em
    FROM public.eventos_caso ec
    WHERE ec.caso_id = p_caso_id
      AND ec.acao = 'atribuir_tarefa'
      AND ec.criado_em <= es.criado_em
    ORDER BY ec.criado_em DESC
    LIMIT 1
  ) ea ON true
  WHERE es.caso_id = p_caso_id
    AND es.acao = 'suspender_caso_presenca'
  ORDER BY es.criado_em DESC
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.libertar_suspensos_fantasma(
  p_tmt_max_seg INT DEFAULT 90
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caso   public.casos%ROWTYPE;
  v_tmt    INT;
  v_total  INT := 0;
  v_ids    TEXT[] := '{}';
BEGIN
  FOR v_caso IN
    SELECT c.*
    FROM public.casos c
    WHERE c.status = 'suspenso'
      AND c.colaborador_id IS NOT NULL
    FOR UPDATE SKIP LOCKED
  LOOP
    IF public._caso_tem_obs_antes_retido(v_caso.notas) THEN
      CONTINUE;
    END IF;

    v_tmt := public._caso_tmt_ultima_sessao_seg(v_caso.id);
    IF v_tmt IS NULL OR v_tmt >= p_tmt_max_seg THEN
      CONTINUE;
    END IF;

    UPDATE public.casos
    SET
      status = 'livre',
      colaborador_id = NULL,
      ponto_atendimento_id = NULL,
      inicio_tratamento = NULL,
      prioridade_flash = false,
      notas = public._prepend_nota_caso(
        v_caso.notas,
        '[Auto] Libertado — suspensão fantasma (job background).',
        'sistema'
      ),
      versao = versao + 1
    WHERE id = v_caso.id;

    PERFORM public._registar_evento_caso(
      v_caso.id,
      v_caso.area_id,
      'libertar_suspenso_fantasma',
      jsonb_build_object(
        'tmt_segundos', v_tmt,
        'colaborador_anterior', v_caso.colaborador_id
      )
    );

    v_total := v_total + 1;
    v_ids := array_append(v_ids, v_caso.id_externo);
  END LOOP;

  RETURN jsonb_build_object(
    'sucesso', true,
    'libertados', v_total,
    'ids', to_jsonb(v_ids)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.libertar_suspensos_fantasma(INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.libertar_suspensos_fantasma(INT) TO service_role;
