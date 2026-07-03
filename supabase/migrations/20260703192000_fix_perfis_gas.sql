-- Smart Queue v2 — MS-04b: corrigir seed perfis ↔ GAS
--
-- GAS Sala de Controlo: supervisor / coordenador / admin importam grelha + Evalyze.
-- Gestão de equipa (utilizadores) também é supervisor+.
-- admin.perfis reservado ao developer (editar permissões do sistema).

-- ---------------------------------------------------------------------------
-- 1. Permissões em falta: supervisor + coordenador
-- ---------------------------------------------------------------------------

INSERT INTO public.perfil_permissoes (perfil_id, permissao_codigo)
VALUES
  ('a0000000-0000-4000-8000-000000000002', 'importacao.grelha'),
  ('a0000000-0000-4000-8000-000000000002', 'importacao.evalyze'),
  ('a0000000-0000-4000-8000-000000000002', 'utilizadores.gerir'),
  ('a0000000-0000-4000-8000-000000000003', 'importacao.grelha'),
  ('a0000000-0000-4000-8000-000000000003', 'importacao.evalyze'),
  ('a0000000-0000-4000-8000-000000000003', 'utilizadores.gerir')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. admin.perfis só no developer (GAS: gestão de perfis = dev)
-- ---------------------------------------------------------------------------

DELETE FROM public.perfil_permissoes
WHERE perfil_id = 'a0000000-0000-4000-8000-000000000004'
  AND permissao_codigo = 'admin.perfis';

-- Garantir developer com catálogo completo (incl. admin.perfis)
INSERT INTO public.perfil_permissoes (perfil_id, permissao_codigo)
SELECT 'a0000000-0000-4000-8000-000000000005', p.codigo
FROM public.permissoes p
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. Fallback role enum alinhado ao GAS supervisor
-- ---------------------------------------------------------------------------

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
      'utilizadores.ver_proprio','utilizadores.ver_area','utilizadores.gerir','presenca.actualizar',
      'notificacoes.ver_proprias','notificacoes.marcar_lida',
      'importacao.grelha','importacao.evalyze'
    ]
    WHEN 'colaborador' THEN ARRAY[
      'casos.ver_proprios','casos.pedir_tarefa','casos.actualizar_proprios',
      'utilizadores.ver_proprio','presenca.actualizar',
      'notificacoes.ver_proprias','notificacoes.marcar_lida'
    ]
  END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Helpers para RPCs futuras (importação / gestão perfis)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.has_permissao_importacao()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.has_permissao_developer()
    OR public.has_permissao('importacao.grelha')
    OR public.has_permissao('importacao.evalyze');
$$;

CREATE OR REPLACE FUNCTION public.has_permissao_gerir_perfis()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.has_permissao_developer()
    OR public.has_permissao('admin.perfis');
$$;

-- ---------------------------------------------------------------------------
-- 5. RLS perfis: developer edita sempre
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS perfis_manage ON public.perfis;

CREATE POLICY perfis_manage ON public.perfis
  FOR ALL TO authenticated
  USING (public.has_permissao_gerir_perfis())
  WITH CHECK (public.has_permissao_gerir_perfis());

DROP POLICY IF EXISTS perfil_permissoes_manage ON public.perfil_permissoes;

CREATE POLICY perfil_permissoes_manage ON public.perfil_permissoes
  FOR ALL TO authenticated
  USING (public.has_permissao_gerir_perfis())
  WITH CHECK (public.has_permissao_gerir_perfis());

GRANT EXECUTE ON FUNCTION public.has_permissao_importacao() TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_permissao_gerir_perfis() TO authenticated;
