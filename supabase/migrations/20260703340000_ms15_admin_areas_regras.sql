-- MS-15: Admin Multi-Area — CRUD areas + regras_fila por area (formulario UI)

-- ---------------------------------------------------------------------------
-- Helpers: template default + validacao schema motor v2
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
      'versao', 2,
      'filtros_elegibilidade', jsonb_build_object(
        'skill', jsonb_build_object('ativo', true, 'fonte', 'utilizador_equipas'),
        'ponto_atendimento', jsonb_build_object(
          'ativo', p_filtro_loja_ativo,
          'modo', 'mesmo_ponto',
          'aplicar_tiers', jsonb_build_array('scan', 'dono_ausente', 'libertar_14h')
        )
      ),
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

CREATE OR REPLACE FUNCTION public._validar_config_regras_fila(p_config JSONB)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_motor JSONB;
  v_filtros JSONB;
  v_ponto JSONB;
  v_tiers JSONB;
  v_tier TEXT;
  v_tier_ok BOOLEAN := true;
BEGIN
  IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
    RETURN 'Config invalida — objecto JSON esperado.';
  END IF;

  IF NOT (p_config ? 'motor') OR jsonb_typeof(p_config->'motor') <> 'object' THEN
    RETURN 'Campo obrigatorio em falta: motor.';
  END IF;

  v_motor := p_config->'motor';

  IF COALESCE((v_motor->>'versao')::int, 0) <> 2 THEN
    RETURN 'motor.versao deve ser 2.';
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

  IF p_config ? 'nudge_mensagens' AND jsonb_typeof(p_config->'nudge_mensagens') <> 'array' THEN
    RETURN 'nudge_mensagens deve ser um array.';
  END IF;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public._pode_aceder_area(p_area_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    public.has_permissao_developer()
    OR public.has_permissao('admin.areas')
    OR (
      public.has_permissao('admin.regras_fila')
      AND p_area_id = public.get_user_area_id()
    );
$$;

CREATE OR REPLACE FUNCTION public._pode_gerir_areas()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.has_permissao_developer() OR public.has_permissao('admin.areas');
$$;

-- ---------------------------------------------------------------------------
-- RLS: admin.areas pode CRUD areas (alem de developer)
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS areas_all_developer ON public.areas;

CREATE POLICY areas_all_developer ON public.areas
  FOR ALL TO authenticated
  USING (public.is_developer() OR public.has_permissao('admin.areas'))
  WITH CHECK (public.is_developer() OR public.has_permissao('admin.areas'));

DROP POLICY IF EXISTS regras_fila_all_developer ON public.regras_fila;

CREATE POLICY regras_fila_all_developer ON public.regras_fila
  FOR ALL TO authenticated
  USING (
    public.is_developer()
    OR public.has_permissao('admin.areas')
    OR (
      public.has_permissao('admin.regras_fila')
      AND area_id = public.get_user_area_id()
    )
  )
  WITH CHECK (
    public.is_developer()
    OR public.has_permissao('admin.areas')
    OR (
      public.has_permissao('admin.regras_fila')
      AND area_id = public.get_user_area_id()
    )
  );

-- ---------------------------------------------------------------------------
-- obter_acesso_admin_areas — permissoes UI
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obter_acesso_admin_areas()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_gerir_areas  BOOLEAN := public._pode_gerir_areas();
  v_gerir_regras BOOLEAN := public.has_permissao_developer()
    OR public.has_permissao('admin.regras_fila')
    OR public.has_permissao('admin.areas');
BEGIN
  IF NOT v_gerir_areas AND NOT v_gerir_regras THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissao para admin multi-area.');
  END IF;

  RETURN jsonb_build_object(
    'sucesso', true,
    'permissoes', jsonb_build_object(
      'gerir_areas', v_gerir_areas,
      'gerir_regras', v_gerir_regras,
      'multi_area', v_gerir_areas
    ),
    'area_id', public.get_user_area_id()
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- listar_areas
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.listar_areas()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_areas JSONB;
BEGIN
  IF NOT (
    public._pode_gerir_areas()
    OR public.has_permissao('admin.regras_fila')
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissao para listar areas.');
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', a.id,
      'nome', a.nome,
      'slug', a.slug,
      'timezone', a.timezone,
      'ativo', a.ativo,
      'criado_em', a.criado_em
    ) ORDER BY a.nome
  ), '[]'::jsonb)
  INTO v_areas
  FROM public.areas a
  WHERE public._pode_gerir_areas()
     OR a.id = public.get_user_area_id();

  RETURN jsonb_build_object('sucesso', true, 'areas', v_areas);
END;
$$;

-- ---------------------------------------------------------------------------
-- criar_area
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.criar_area(
  p_nome              TEXT,
  p_slug              TEXT,
  p_timezone          TEXT DEFAULT 'Europe/Lisbon',
  p_filtro_loja_ativo BOOLEAN DEFAULT false
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_nome     TEXT := trim(COALESCE(p_nome, ''));
  v_slug     TEXT := lower(regexp_replace(trim(COALESCE(p_slug, '')), '[^a-z0-9-]+', '-', 'g'));
  v_tz       TEXT := COALESCE(NULLIF(trim(p_timezone), ''), 'Europe/Lisbon');
  v_id       UUID;
  v_config   JSONB;
BEGIN
  IF NOT public._pode_gerir_areas() THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissao admin.areas para criar area.');
  END IF;

  IF v_nome = '' THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Nome da area obrigatorio.');
  END IF;

  IF v_slug = '' OR v_slug ~ '^-|-$' THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Slug invalido — use letras, numeros e hifens.');
  END IF;

  IF EXISTS (SELECT 1 FROM public.areas a WHERE a.slug = v_slug) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Slug ja existe — escolhe outro.');
  END IF;

  v_config := public._regras_fila_default_config(p_filtro_loja_ativo, v_tz);

  INSERT INTO public.areas (nome, slug, timezone, ativo)
  VALUES (v_nome, v_slug, v_tz, true)
  RETURNING id INTO v_id;

  INSERT INTO public.regras_fila (area_id, versao, config)
  VALUES (v_id, 2, v_config);

  RETURN jsonb_build_object(
    'sucesso', true,
    'mensagem', 'Area criada com regras de fila default.',
    'id', v_id,
    'slug', v_slug
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- actualizar_area / desactivar_area
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.actualizar_area(
  p_id       UUID,
  p_nome     TEXT DEFAULT NULL,
  p_slug     TEXT DEFAULT NULL,
  p_timezone TEXT DEFAULT NULL,
  p_ativo    BOOLEAN DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_slug TEXT;
BEGIN
  IF NOT public._pode_gerir_areas() THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissao admin.areas.');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.areas a WHERE a.id = p_id) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Area nao encontrada.');
  END IF;

  IF p_slug IS NOT NULL THEN
    v_slug := lower(regexp_replace(trim(p_slug), '[^a-z0-9-]+', '-', 'g'));
    IF v_slug = '' OR v_slug ~ '^-|-$' THEN
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Slug invalido.');
    END IF;
    IF EXISTS (SELECT 1 FROM public.areas a WHERE a.slug = v_slug AND a.id <> p_id) THEN
      RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Slug ja em uso.');
    END IF;
  END IF;

  UPDATE public.areas a
  SET
    nome     = COALESCE(NULLIF(trim(p_nome), ''), a.nome),
    slug     = COALESCE(v_slug, a.slug),
    timezone = COALESCE(NULLIF(trim(p_timezone), ''), a.timezone),
    ativo    = COALESCE(p_ativo, a.ativo)
  WHERE a.id = p_id;

  RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Area actualizada.');
END;
$$;

CREATE OR REPLACE FUNCTION public.desactivar_area(p_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public._pode_gerir_areas() THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissao admin.areas.');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.areas a WHERE a.id = p_id) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Area nao encontrada.');
  END IF;

  UPDATE public.areas SET ativo = false WHERE id = p_id;

  RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Area desactivada.');
END;
$$;

-- ---------------------------------------------------------------------------
-- obter_regras_fila_area / salvar_regras_fila_area
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obter_regras_fila_area(p_area_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_config JSONB;
BEGIN
  IF NOT public._pode_aceder_area(p_area_id) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissao para ver regras desta area.');
  END IF;

  SELECT COALESCE(rf.config, public._regras_fila_default_config(false))
  INTO v_config
  FROM public.regras_fila rf
  WHERE rf.area_id = p_area_id;

  IF v_config IS NULL THEN
    v_config := public._regras_fila_default_config(false);
  END IF;

  RETURN jsonb_build_object(
    'sucesso', true,
    'area_id', p_area_id,
    'config', v_config
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.salvar_regras_fila_area(
  p_area_id UUID,
  p_config  JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_config  JSONB := COALESCE(p_config, '{}'::jsonb);
  v_erro    TEXT;
  v_nudges  JSONB;
BEGIN
  IF NOT public._pode_aceder_area(p_area_id) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissao para editar regras desta area.');
  END IF;

  IF NOT (
    public.has_permissao_developer()
    OR public.has_permissao('admin.regras_fila')
    OR public.has_permissao('admin.areas')
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissao admin.regras_fila.');
  END IF;

  v_erro := public._validar_config_regras_fila(v_config);
  IF v_erro IS NOT NULL THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', v_erro);
  END IF;

  SELECT COALESCE(rf.config->'nudge_mensagens', '[]'::jsonb)
  INTO v_nudges
  FROM public.regras_fila rf
  WHERE rf.area_id = p_area_id;

  IF NOT (v_config ? 'nudge_mensagens') AND v_nudges IS NOT NULL THEN
    v_config := v_config || jsonb_build_object('nudge_mensagens', v_nudges);
  END IF;

  INSERT INTO public.regras_fila (area_id, versao, config)
  VALUES (
    p_area_id,
    COALESCE((v_config->'motor'->>'versao')::int, 2),
    v_config
  )
  ON CONFLICT (area_id) DO UPDATE
  SET config = EXCLUDED.config,
      versao = EXCLUDED.versao,
      atualizado_em = now();

  RETURN jsonb_build_object('sucesso', true, 'mensagem', 'Regras de fila guardadas.');
END;
$$;

-- ---------------------------------------------------------------------------
-- Actualizar wrappers existentes (area do utilizador)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obter_regras_fila()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id UUID;
BEGIN
  IF NOT (
    public.has_permissao_developer()
    OR public.has_permissao('admin.regras_fila')
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissao para ver regras de fila.');
  END IF;

  v_area_id := public.get_user_area_id();
  RETURN public.obter_regras_fila_area(v_area_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.salvar_regras_fila(p_config JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_area_id UUID;
BEGIN
  IF NOT (
    public.has_permissao_developer()
    OR public.has_permissao('admin.regras_fila')
  ) THEN
    RETURN jsonb_build_object('sucesso', false, 'mensagem', 'Sem permissao para editar regras de fila.');
  END IF;

  v_area_id := public.get_user_area_id();
  RETURN public.salvar_regras_fila_area(v_area_id, p_config);
END;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

GRANT EXECUTE ON FUNCTION public.obter_acesso_admin_areas() TO authenticated;
GRANT EXECUTE ON FUNCTION public.listar_areas() TO authenticated;
GRANT EXECUTE ON FUNCTION public.criar_area(TEXT, TEXT, TEXT, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.actualizar_area(UUID, TEXT, TEXT, TEXT, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.desactivar_area(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obter_regras_fila_area(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.salvar_regras_fila_area(UUID, JSONB) TO authenticated;
