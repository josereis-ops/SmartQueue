-- MS-18: Motor atribuir_tarefa (SQ_SEM_ELEGIVEIS) + gestor skills para developer/supervisor
--
-- Causa raiz: _motor_melhor_caso (MS-16) devolvia 0 linhas quando invocado como funcao PL/pgSQL
-- (format() multiline + CRLF); SQL equivalente inline funcionava. Fix: concatenacao + SECURITY DEFINER.
-- Gestor skills: obter/atualizar filtrava role=colaborador — developer nao aparecia na lista.
-- Seed: skills Producao+Consumo para dev/supervisor POC; pontos nos casos volume MS-17b.

-- ---------------------------------------------------------------------------
-- Fix _motor_melhor_caso — seleccao elegivel com ORDER BY dinamico
-- ---------------------------------------------------------------------------

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
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caso  public.casos;
  v_agora TIMESTAMPTZ := clock_timestamp();
  v_order TEXT;
  v_sql   TEXT;
BEGIN
  v_order := public._motor_build_order_clause(
    public._motor_ordenacao_normalizada(p_config)
  );

  v_sql :=
    'SELECT c.* FROM public.casos c '
    || 'CROSS JOIN LATERAL ('
    || '  SELECT public._motor_caso_tier(c, $1, $2, $3, $4, $5, $6) AS tier'
    || ') t '
    || 'WHERE c.area_id = $7 AND t.tier < 99 '
    || 'ORDER BY ' || v_order || ' '
    || 'FOR UPDATE OF c SKIP LOCKED LIMIT 1';

  BEGIN
    EXECUTE v_sql INTO STRICT v_caso
    USING
      p_operador_id,
      p_operador_email,
      p_operador_equipa,
      p_operador_ponto,
      p_config,
      v_agora,
      p_area_id;
  EXCEPTION
    WHEN no_data_found THEN
      RETURN NULL;
  END;

  RETURN v_caso;
END;
$$;

-- ---------------------------------------------------------------------------
-- Gestor skills: incluir developer e supervisor (POC / testes operador)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obter_dados_gestor_skills()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id UUID;
  v_users   JSONB := '[]'::jsonb;
  v_skills  JSONB := '[]'::jsonb;
BEGIN
  IF NOT public.has_permissao('utilizadores.gerir') THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissão para gerir skills.');
  END IF;

  v_area_id := public.get_user_area_id();

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object('id', e.id, 'nome', e.nome, 'codigo', e.codigo)
    ORDER BY e.nome
  ), '[]'::jsonb)
  INTO v_skills
  FROM public.equipas e
  WHERE e.area_id = v_area_id AND e.ativo = true;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'email', u.email,
      'nome', u.nome,
      'skills', COALESCE((
        SELECT jsonb_agg(eq.nome ORDER BY eq.nome)
        FROM public.utilizador_equipas ue
        JOIN public.equipas eq ON eq.id = ue.equipa_id
        WHERE ue.utilizador_id = u.id
      ), '[]'::jsonb)
    )
    ORDER BY u.nome
  ), '[]'::jsonb)
  INTO v_users
  FROM public.utilizadores u
  WHERE u.area_id = v_area_id
    AND u.role IN ('colaborador', 'supervisor', 'developer');

  RETURN jsonb_build_object('sucesso', true, 'users', v_users, 'skills', v_skills);
END;
$$;

CREATE OR REPLACE FUNCTION public.atualizar_skills_em_massa(
  p_emails TEXT[],
  p_skills TEXT[],
  p_acao   TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id       UUID;
  v_email         TEXT;
  v_skill         TEXT;
  v_uid           UUID;
  v_equipa_id     UUID;
  v_alterados     INT := 0;
  v_acao          TEXT := lower(trim(COALESCE(p_acao, '')));
BEGIN
  IF NOT public.has_permissao('utilizadores.gerir') THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissão para gerir skills.');
  END IF;

  IF p_emails IS NULL OR array_length(p_emails, 1) IS NULL
     OR p_skills IS NULL OR array_length(p_skills, 1) IS NULL THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Seleciona pelo menos um operador e uma skill.');
  END IF;

  IF v_acao NOT IN ('adicionar', 'remover') THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Acção inválida.');
  END IF;

  v_area_id := public.get_user_area_id();

  FOREACH v_email IN ARRAY p_emails LOOP
    SELECT u.id INTO v_uid
    FROM public.utilizadores u
    WHERE u.area_id = v_area_id
      AND lower(trim(u.email)) = lower(trim(v_email))
      AND u.role IN ('colaborador', 'supervisor', 'developer');

    IF v_uid IS NULL THEN CONTINUE; END IF;

    FOREACH v_skill IN ARRAY p_skills LOOP
      v_equipa_id := public._resolver_equipa_por_skill(v_area_id, v_skill);
      IF v_equipa_id IS NULL THEN CONTINUE; END IF;

      IF v_acao = 'adicionar' THEN
        INSERT INTO public.utilizador_equipas (utilizador_id, equipa_id)
        VALUES (v_uid, v_equipa_id)
        ON CONFLICT DO NOTHING;
      ELSE
        DELETE FROM public.utilizador_equipas ue
        WHERE ue.utilizador_id = v_uid AND ue.equipa_id = v_equipa_id;
      END IF;
    END LOOP;

    v_alterados := v_alterados + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'sucesso', true,
    'mensagem', v_alterados || ' operador(es) actualizado(s) com sucesso!'
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Demo SU Eletricidade: skills M:N dev/supervisor + pontos casos volume
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_area_id UUID := 'b0000000-0000-4000-8000-000000000001';
  v_s_prod  UUID;
  v_s_cons  UUID;
  v_p_lis   UUID := 'b0000000-0000-4000-8000-000000000101';
  v_p_pto   UUID := 'b0000000-0000-4000-8000-000000000102';
  v_p_alg   UUID := 'b0000000-0000-4000-8000-000000000103';
  v_skills  INT;
  v_pontos  INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.areas WHERE id = v_area_id) THEN
    RAISE NOTICE 'MS-18: area demo nao encontrada — skip seed.';
    RETURN;
  END IF;

  SELECT e.id INTO v_s_prod
  FROM public.equipas e
  WHERE e.area_id = v_area_id AND e.nome = 'Producao' AND e.ativo
  LIMIT 1;

  SELECT e.id INTO v_s_cons
  FROM public.equipas e
  WHERE e.area_id = v_area_id AND e.nome = 'Consumo' AND e.ativo
  LIMIT 1;

  IF v_s_prod IS NOT NULL AND v_s_cons IS NOT NULL THEN
    INSERT INTO public.utilizador_equipas (utilizador_id, equipa_id)
    SELECT u.id, e.id
    FROM public.utilizadores u
    JOIN public.equipas e ON e.area_id = u.area_id
      AND e.id IN (v_s_prod, v_s_cons)
    WHERE u.area_id = v_area_id
      AND u.role IN ('developer', 'supervisor')
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS v_skills = ROW_COUNT;
    RAISE NOTICE 'MS-18: +% skills M:N dev/supervisor (Producao+Consumo).', v_skills;
  END IF;

  UPDATE public.casos c
  SET
    ponto_atendimento_id = (
      ARRAY[v_p_lis, v_p_pto, v_p_alg]
    )[1 + (abs(hashtext(c.id_externo)) % 3)],
    loja = COALESCE(
      c.loja,
      (
        SELECT p.nome
        FROM public.pontos_atendimento p
        WHERE p.id = (
          ARRAY[v_p_lis, v_p_pto, v_p_alg]
        )[1 + (abs(hashtext(c.id_externo)) % 3)]
      )
    ),
    versao = c.versao + 1
  WHERE c.area_id = v_area_id
    AND c.ponto_atendimento_id IS NULL
    AND c.id_externo ~ '^SU-26-[0-9]+$'
    AND (regexp_match(c.id_externo, '^SU-26-([0-9]+)$'))[1]::int >= 201;

  GET DIAGNOSTICS v_pontos = ROW_COUNT;
  RAISE NOTICE 'MS-18: % casos volume com ponto_atendimento backfill.', v_pontos;
END;
$$;
