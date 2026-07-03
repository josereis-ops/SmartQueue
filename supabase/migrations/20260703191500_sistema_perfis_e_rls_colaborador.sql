-- Smart Queue v2 — Sprint 2b: sistema de perfis + RLS alinhado ao GAS
--
-- GAS: colaborador NÃO vê fila livre — só obterMeusPendentes (resp = email).
--      pedirNovaTarefa atribui server-side sem expor outros casos.
--      Supervisor/Coordenador/Admin vêem Sala de Controlo (obterDadosSupervisao).

-- ---------------------------------------------------------------------------
-- Catálogo de permissões (extensível por módulo)
-- ---------------------------------------------------------------------------

CREATE TABLE public.permissoes (
  codigo    TEXT PRIMARY KEY,
  nome      TEXT NOT NULL,
  descricao TEXT,
  modulo    TEXT NOT NULL
);

CREATE TABLE public.perfis (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  area_id     UUID REFERENCES public.areas (id) ON DELETE CASCADE,
  nome        TEXT NOT NULL,
  slug        TEXT NOT NULL,
  descricao   TEXT,
  is_system   BOOLEAN NOT NULL DEFAULT false,
  criado_em   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (area_id, slug)
);

CREATE TABLE public.perfil_permissoes (
  perfil_id         UUID NOT NULL REFERENCES public.perfis (id) ON DELETE CASCADE,
  permissao_codigo  TEXT NOT NULL REFERENCES public.permissoes (codigo) ON DELETE CASCADE,
  PRIMARY KEY (perfil_id, permissao_codigo)
);

-- perfil_id em utilizadores (mantém role enum como fallback legacy)
ALTER TABLE public.utilizadores
  ADD COLUMN perfil_id UUID REFERENCES public.perfis (id) ON DELETE SET NULL;

CREATE INDEX idx_utilizadores_perfil ON public.utilizadores (perfil_id);

-- ---------------------------------------------------------------------------
-- Seed: permissões
-- ---------------------------------------------------------------------------

INSERT INTO public.permissoes (codigo, nome, descricao, modulo) VALUES
  -- Casos / operador
  ('casos.ver_proprios',       'Ver casos próprios',           'Lista Meus Pendentes — só casos atribuídos ao colaborador', 'casos'),
  ('casos.pedir_tarefa',       'Pedir tarefa',                 'RPC atribuir_tarefa — fila server-side', 'casos'),
  ('casos.actualizar_proprios','Actualizar casos próprios',    'Concluir, agendar, suspender casos atribuídos', 'casos'),
  ('casos.ver_area',           'Ver casos da área',            'Sala de Controlo — todos os casos da área', 'casos'),
  ('casos.actualizar_area',    'Actualizar casos da área',     'Flash, notas supervisor, reatribuir', 'casos'),
  ('casos.inserir',            'Inserir casos',                'Importação manual / criar caso', 'casos'),
  ('casos.alterar_equipa',     'Alterar equipa do caso',       'Encaminhamento skill (estado Outro)', 'casos'),
  -- Supervisão
  ('supervisao.dashboard',     'Dashboard supervisão',         'KPIs, cards RQS, carteira, drill-down', 'supervisao'),
  ('supervisao.nudges',        'Enviar nudges',                'Notificações a colaboradores', 'supervisao'),
  -- Utilizadores
  ('utilizadores.ver_proprio', 'Ver perfil próprio',           NULL, 'utilizadores'),
  ('utilizadores.ver_area',    'Ver utilizadores da área',     'Lista colaboradores para nudges/gestão', 'utilizadores'),
  ('utilizadores.gerir',       'Gerir utilizadores',           'CRUD utilizadores e atribuição de perfis', 'utilizadores'),
  ('presenca.actualizar',      'Actualizar presença',          'Disponível / Pausa / Offline', 'utilizadores'),
  -- Notificações
  ('notificacoes.ver_proprias','Ver notificações recebidas',   NULL, 'notificacoes'),
  ('notificacoes.marcar_lida', 'Marcar notificação lida',      NULL, 'notificacoes'),
  -- Importação
  ('importacao.grelha',        'Importação grelha',            'Upload CSV/Excel em massa', 'importacao'),
  ('importacao.evalyze',       'Importação Evalyze',           'Trigger automático Evalyze', 'importacao'),
  -- Admin / config
  ('admin.perfis',             'Gerir perfis',                 'Criar perfis e atribuir permissões', 'admin'),
  ('admin.regras_fila',        'Gerir regras de fila',         'Config JSONB por área', 'admin'),
  ('admin.areas',              'Gerir áreas',                  'CRUD áreas (multi-tenant)', 'admin'),
  ('admin.equipas',            'Gerir equipas',                'CRUD equipas/skills', 'admin'),
  -- Developer
  ('developer.acesso_total',   'Acesso total',                 'Bypass RLS — apenas perfil developer', 'developer');

-- ---------------------------------------------------------------------------
-- Seed: perfis sistema (area_id NULL = templates reutilizáveis)
-- ---------------------------------------------------------------------------

INSERT INTO public.perfis (id, area_id, nome, slug, descricao, is_system) VALUES
  ('a0000000-0000-4000-8000-000000000001', NULL, 'Colaborador',  'colaborador',  'Operador de fila — GAS operador padrão', true),
  ('a0000000-0000-4000-8000-000000000002', NULL, 'Supervisor',   'supervisor',   'Sala de Controlo — GAS supervisor', true),
  ('a0000000-0000-4000-8000-000000000003', NULL, 'Coordenador',  'coordenador',  'Igual supervisor + visão equipa alargada', true),
  ('a0000000-0000-4000-8000-000000000004', NULL, 'Admin',        'admin',        'Administração área + importação', true),
  ('a0000000-0000-4000-8000-000000000005', NULL, 'Developer',    'developer',    'Acesso total POC/dev', true);

-- Colaborador (GAS: operador — só casos próprios + pedir tarefa)
INSERT INTO public.perfil_permissoes (perfil_id, permissao_codigo)
SELECT 'a0000000-0000-4000-8000-000000000001', codigo FROM public.permissoes
WHERE codigo IN (
  'casos.ver_proprios', 'casos.pedir_tarefa', 'casos.actualizar_proprios',
  'utilizadores.ver_proprio', 'presenca.actualizar',
  'notificacoes.ver_proprias', 'notificacoes.marcar_lida'
);

-- Supervisor
INSERT INTO public.perfil_permissoes (perfil_id, permissao_codigo)
SELECT 'a0000000-0000-4000-8000-000000000002', codigo FROM public.permissoes
WHERE codigo IN (
  'casos.ver_proprios', 'casos.pedir_tarefa', 'casos.actualizar_proprios',
  'casos.ver_area', 'casos.actualizar_area', 'casos.inserir', 'casos.alterar_equipa',
  'supervisao.dashboard', 'supervisao.nudges',
  'utilizadores.ver_proprio', 'utilizadores.ver_area', 'presenca.actualizar',
  'notificacoes.ver_proprias', 'notificacoes.marcar_lida'
);

-- Coordenador (= supervisor no GAS)
INSERT INTO public.perfil_permissoes (perfil_id, permissao_codigo)
SELECT 'a0000000-0000-4000-8000-000000000003', pp.permissao_codigo
FROM public.perfil_permissoes pp
WHERE pp.perfil_id = 'a0000000-0000-4000-8000-000000000002';

-- Admin
INSERT INTO public.perfil_permissoes (perfil_id, permissao_codigo)
SELECT 'a0000000-0000-4000-8000-000000000004', codigo FROM public.permissoes
WHERE codigo IN (
  'casos.ver_proprios', 'casos.pedir_tarefa', 'casos.actualizar_proprios',
  'casos.ver_area', 'casos.actualizar_area', 'casos.inserir', 'casos.alterar_equipa',
  'supervisao.dashboard', 'supervisao.nudges',
  'utilizadores.ver_proprio', 'utilizadores.ver_area', 'utilizadores.gerir', 'presenca.actualizar',
  'notificacoes.ver_proprias', 'notificacoes.marcar_lida',
  'importacao.grelha', 'importacao.evalyze',
  'admin.perfis', 'admin.regras_fila', 'admin.equipas'
);

-- Developer (todas)
INSERT INTO public.perfil_permissoes (perfil_id, permissao_codigo)
SELECT 'a0000000-0000-4000-8000-000000000005', codigo FROM public.permissoes;

-- ---------------------------------------------------------------------------
-- Helpers de permissão
-- ---------------------------------------------------------------------------

-- Fallback: utilizadores sem perfil_id usam role enum (compat. sprint 2)
CREATE OR REPLACE FUNCTION public._permissoes_role_legacy(p_role public.user_role)
RETURNS TEXT[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_role
    WHEN 'developer' THEN ARRAY(SELECT codigo FROM public.permissoes)
    WHEN 'supervisor' THEN ARRAY[
      'casos.ver_proprios','casos.pedir_tarefa','casos.actualizar_proprios',
      'casos.ver_area','casos.actualizar_area','casos.inserir','casos.alterar_equipa',
      'supervisao.dashboard','supervisao.nudges',
      'utilizadores.ver_proprio','utilizadores.ver_area','presenca.actualizar',
      'notificacoes.ver_proprias','notificacoes.marcar_lida'
    ]
    WHEN 'colaborador' THEN ARRAY[
      'casos.ver_proprios','casos.pedir_tarefa','casos.actualizar_proprios',
      'utilizadores.ver_proprio','presenca.actualizar',
      'notificacoes.ver_proprias','notificacoes.marcar_lida'
    ]
  END;
$$;

CREATE OR REPLACE FUNCTION public.has_permissao_developer()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.utilizadores u
    JOIN public.perfis p ON p.id = u.perfil_id
    WHERE u.id = auth.uid()
      AND p.slug = 'developer'
  )
  OR EXISTS (
    SELECT 1 FROM public.utilizadores u
    WHERE u.id = auth.uid() AND u.role = 'developer'
  );
$$;

CREATE OR REPLACE FUNCTION public.has_permissao(p_codigo TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.has_permissao_developer()
  OR EXISTS (
    SELECT 1
    FROM public.utilizadores u
    JOIN public.perfil_permissoes pp ON pp.perfil_id = u.perfil_id
    WHERE u.id = auth.uid()
      AND pp.permissao_codigo = p_codigo
  )
  OR EXISTS (
    SELECT 1
    FROM public.utilizadores u
    WHERE u.id = auth.uid()
      AND u.perfil_id IS NULL
      AND p_codigo = ANY (public._permissoes_role_legacy(u.role))
  );
$$;

CREATE OR REPLACE FUNCTION public.is_developer()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.has_permissao_developer();
$$;

CREATE OR REPLACE FUNCTION public.has_permissao_supervisao()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.has_permissao('supervisao.dashboard')
    OR public.has_permissao('casos.ver_area')
    OR public.has_permissao_developer();
$$;

-- ---------------------------------------------------------------------------
-- Corrigir RLS casos: colaborador SÓ vê casos próprios (GAS obterMeusPendentes)
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS casos_select_colaborador ON public.casos;

CREATE POLICY casos_select ON public.casos
  FOR SELECT TO authenticated
  USING (
    public.has_permissao_developer()
    OR (
      public.has_permissao('casos.ver_area')
      AND area_id = public.get_user_area_id()
    )
    OR (
      public.has_permissao('casos.ver_proprios')
      AND colaborador_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS casos_update_colaborador ON public.casos;

CREATE POLICY casos_update_proprios ON public.casos
  FOR UPDATE TO authenticated
  USING (
    public.has_permissao_developer()
    OR (
      public.has_permissao('casos.actualizar_proprios')
      AND colaborador_id = auth.uid()
    )
  )
  WITH CHECK (
    public.has_permissao_developer()
    OR (
      public.has_permissao('casos.actualizar_proprios')
      AND colaborador_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS casos_supervisor_update ON public.casos;

CREATE POLICY casos_update_area ON public.casos
  FOR UPDATE TO authenticated
  USING (
    public.has_permissao('casos.actualizar_area')
    AND area_id = public.get_user_area_id()
  )
  WITH CHECK (
    public.has_permissao('casos.actualizar_area')
    AND area_id = public.get_user_area_id()
  );

DROP POLICY IF EXISTS casos_insert_supervisor ON public.casos;

CREATE POLICY casos_insert ON public.casos
  FOR INSERT TO authenticated
  WITH CHECK (
    public.has_permissao('casos.inserir')
    AND area_id = public.get_user_area_id()
  );

-- ---------------------------------------------------------------------------
-- Actualizar políticas utilizadores / notificações para perfis
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS utilizadores_select ON public.utilizadores;

CREATE POLICY utilizadores_select ON public.utilizadores
  FOR SELECT TO authenticated
  USING (
    public.has_permissao_developer()
    OR (public.has_permissao('utilizadores.ver_proprio') AND id = auth.uid())
    OR (
      public.has_permissao('utilizadores.ver_area')
      AND area_id = public.get_user_area_id()
    )
  );

DROP POLICY IF EXISTS notificacoes_insert ON public.notificacoes;

CREATE POLICY notificacoes_insert ON public.notificacoes
  FOR INSERT TO authenticated
  WITH CHECK (
    public.has_permissao_developer()
    OR (
      public.has_permissao('supervisao.nudges')
      AND area_id = public.get_user_area_id()
      AND remetente_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- RLS nas tabelas de perfis
-- ---------------------------------------------------------------------------

ALTER TABLE public.permissoes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.perfis ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.perfil_permissoes ENABLE ROW LEVEL SECURITY;

CREATE POLICY permissoes_select ON public.permissoes
  FOR SELECT TO authenticated
  USING (true);

CREATE POLICY perfis_select ON public.perfis
  FOR SELECT TO authenticated
  USING (
    public.has_permissao_developer()
    OR area_id IS NULL
    OR area_id = public.get_user_area_id()
  );

CREATE POLICY perfis_manage ON public.perfis
  FOR ALL TO authenticated
  USING (public.has_permissao('admin.perfis'))
  WITH CHECK (public.has_permissao('admin.perfis'));

CREATE POLICY perfil_permissoes_select ON public.perfil_permissoes
  FOR SELECT TO authenticated
  USING (
    public.has_permissao_developer()
    OR EXISTS (
      SELECT 1 FROM public.perfis p
      WHERE p.id = perfil_id
        AND (p.area_id IS NULL OR p.area_id = public.get_user_area_id())
    )
  );

CREATE POLICY perfil_permissoes_manage ON public.perfil_permissoes
  FOR ALL TO authenticated
  USING (public.has_permissao('admin.perfis'))
  WITH CHECK (public.has_permissao('admin.perfis'));

GRANT SELECT ON public.permissoes TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.perfis TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.perfil_permissoes TO authenticated;

GRANT EXECUTE ON FUNCTION public.has_permissao(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_permissao_developer() TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_permissao_supervisao() TO authenticated;
