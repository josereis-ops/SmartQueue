-- Smart Queue v2 — Sprint 2: RLS multi-área + Realtime

-- ---------------------------------------------------------------------------
-- Helpers (SECURITY DEFINER — leem utilizadores com auth.uid())
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_user_area_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT area_id FROM public.utilizadores WHERE id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.get_user_equipa_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT equipa_id FROM public.utilizadores WHERE id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS public.user_role
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT role FROM public.utilizadores WHERE id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.is_developer()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.utilizadores
    WHERE id = auth.uid()
      AND role = 'developer'
  );
$$;

CREATE OR REPLACE FUNCTION public.is_supervisor_or_developer()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.utilizadores
    WHERE id = auth.uid()
      AND role IN ('supervisor', 'developer')
  );
$$;

-- ---------------------------------------------------------------------------
-- Activar RLS
-- ---------------------------------------------------------------------------

ALTER TABLE public.areas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.equipas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.utilizadores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.regras_fila ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.casos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notificacoes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.eventos_caso ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- areas
-- ---------------------------------------------------------------------------

CREATE POLICY areas_select ON public.areas
  FOR SELECT TO authenticated
  USING (public.is_developer() OR id = public.get_user_area_id());

CREATE POLICY areas_all_developer ON public.areas
  FOR ALL TO authenticated
  USING (public.is_developer())
  WITH CHECK (public.is_developer());

-- ---------------------------------------------------------------------------
-- equipas
-- ---------------------------------------------------------------------------

CREATE POLICY equipas_select ON public.equipas
  FOR SELECT TO authenticated
  USING (public.is_developer() OR area_id = public.get_user_area_id());

CREATE POLICY equipas_all_developer ON public.equipas
  FOR ALL TO authenticated
  USING (public.is_developer())
  WITH CHECK (public.is_developer());

-- ---------------------------------------------------------------------------
-- utilizadores
-- ---------------------------------------------------------------------------

CREATE POLICY utilizadores_select ON public.utilizadores
  FOR SELECT TO authenticated
  USING (
    public.is_developer()
    OR id = auth.uid()
    OR (
      public.is_supervisor_or_developer()
      AND area_id = public.get_user_area_id()
    )
  );

CREATE POLICY utilizadores_update_self ON public.utilizadores
  FOR UPDATE TO authenticated
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

CREATE POLICY utilizadores_all_developer ON public.utilizadores
  FOR ALL TO authenticated
  USING (public.is_developer())
  WITH CHECK (public.is_developer());

-- ---------------------------------------------------------------------------
-- regras_fila
-- ---------------------------------------------------------------------------

CREATE POLICY regras_fila_select ON public.regras_fila
  FOR SELECT TO authenticated
  USING (public.is_developer() OR area_id = public.get_user_area_id());

CREATE POLICY regras_fila_all_developer ON public.regras_fila
  FOR ALL TO authenticated
  USING (public.is_developer())
  WITH CHECK (public.is_developer());

-- ---------------------------------------------------------------------------
-- casos
-- ---------------------------------------------------------------------------

CREATE POLICY casos_select_colaborador ON public.casos
  FOR SELECT TO authenticated
  USING (
    public.is_developer()
    OR (
      public.get_my_role() = 'supervisor'
      AND area_id = public.get_user_area_id()
    )
    OR (
      public.get_my_role() = 'colaborador'
      AND area_id = public.get_user_area_id()
      AND (
        colaborador_id = auth.uid()
        OR (
          equipa_id = public.get_user_equipa_id()
          AND status IN ('livre', 'por_tratar')
        )
      )
    )
  );

CREATE POLICY casos_update_colaborador ON public.casos
  FOR UPDATE TO authenticated
  USING (
    public.is_developer()
    OR (
      public.get_my_role() = 'colaborador'
      AND colaborador_id = auth.uid()
    )
  )
  WITH CHECK (
    public.is_developer()
    OR (
      public.get_my_role() = 'colaborador'
      AND colaborador_id = auth.uid()
    )
  );

CREATE POLICY casos_supervisor_update ON public.casos
  FOR UPDATE TO authenticated
  USING (
    public.get_my_role() = 'supervisor'
    AND area_id = public.get_user_area_id()
  )
  WITH CHECK (
    public.get_my_role() = 'supervisor'
    AND area_id = public.get_user_area_id()
  );

CREATE POLICY casos_insert_supervisor ON public.casos
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_developer()
    OR (
      public.get_my_role() = 'supervisor'
      AND area_id = public.get_user_area_id()
    )
  );

CREATE POLICY casos_all_developer ON public.casos
  FOR ALL TO authenticated
  USING (public.is_developer())
  WITH CHECK (public.is_developer());

-- ---------------------------------------------------------------------------
-- notificacoes
-- ---------------------------------------------------------------------------

CREATE POLICY notificacoes_select ON public.notificacoes
  FOR SELECT TO authenticated
  USING (
    public.is_developer()
    OR destinatario_id = auth.uid()
    OR remetente_id = auth.uid()
    OR (
      public.is_supervisor_or_developer()
      AND area_id = public.get_user_area_id()
    )
  );

CREATE POLICY notificacoes_insert ON public.notificacoes
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_developer()
    OR (
      public.is_supervisor_or_developer()
      AND area_id = public.get_user_area_id()
      AND remetente_id = auth.uid()
    )
  );

CREATE POLICY notificacoes_update_destinatario ON public.notificacoes
  FOR UPDATE TO authenticated
  USING (destinatario_id = auth.uid())
  WITH CHECK (destinatario_id = auth.uid());

CREATE POLICY notificacoes_all_developer ON public.notificacoes
  FOR ALL TO authenticated
  USING (public.is_developer())
  WITH CHECK (public.is_developer());

-- ---------------------------------------------------------------------------
-- eventos_caso
-- ---------------------------------------------------------------------------

CREATE POLICY eventos_caso_select ON public.eventos_caso
  FOR SELECT TO authenticated
  USING (public.is_developer() OR area_id = public.get_user_area_id());

CREATE POLICY eventos_caso_insert ON public.eventos_caso
  FOR INSERT TO authenticated
  WITH CHECK (public.is_developer() OR area_id = public.get_user_area_id());

CREATE POLICY eventos_caso_all_developer ON public.eventos_caso
  FOR ALL TO authenticated
  USING (public.is_developer())
  WITH CHECK (public.is_developer());

-- ---------------------------------------------------------------------------
-- Grants (RLS filtra; authenticated precisa de permissões base)
-- ---------------------------------------------------------------------------

GRANT USAGE ON SCHEMA public TO authenticated;

GRANT SELECT ON public.areas TO authenticated;
GRANT SELECT ON public.equipas TO authenticated;
GRANT SELECT, UPDATE ON public.utilizadores TO authenticated;
GRANT SELECT ON public.regras_fila TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.casos TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.notificacoes TO authenticated;
GRANT SELECT, INSERT ON public.eventos_caso TO authenticated;

GRANT EXECUTE ON FUNCTION public.get_user_area_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_equipa_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_role() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_developer() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_supervisor_or_developer() TO authenticated;

-- ---------------------------------------------------------------------------
-- Realtime (WebSockets para dashboard supervisor + nudges)
-- ---------------------------------------------------------------------------

ALTER PUBLICATION supabase_realtime ADD TABLE public.casos;
ALTER PUBLICATION supabase_realtime ADD TABLE public.notificacoes;
