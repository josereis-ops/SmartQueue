-- Smart Queue v2 — MS-06: seed demo SU Eletricidade
--
-- 1 área, 4 equipas, 8 utilizadores (5 colab + 2 sup + 1 dev), 200 casos sintéticos.
-- Utilizadores pré-provisionados (gestão cria email; login Google no MS-07).
-- Idempotente: ignora se área demo já existir.

-- ---------------------------------------------------------------------------
-- UUIDs fixos (demo reproduzível)
-- ---------------------------------------------------------------------------

-- Área
-- b0000000-0000-4000-8000-000000000001  SU Eletricidade
-- Equipas b000...0101..0104
-- Utilizadores c000...0001..0008

-- ---------------------------------------------------------------------------
-- get_perfil_utilizador — réplica GAS getPerfilUtilizador()
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_perfil_utilizador()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user RECORD;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', 'Sessão expirada. Faz F5.',
      'email_tentativa', NULL
    );
  END IF;

  SELECT
    u.id,
    u.email,
    u.nome,
    u.area_id,
    u.equipa_id,
    u.presenca,
    u.role,
    p.slug   AS perfil_slug,
    p.nome   AS perfil_nome,
    a.nome   AS area_nome,
    a.slug   AS area_slug,
    e.nome   AS equipa_nome,
    e.codigo AS equipa_codigo
  INTO v_user
  FROM public.utilizadores u
  LEFT JOIN public.perfis p ON p.id = u.perfil_id
  JOIN public.areas a ON a.id = u.area_id
  JOIN public.equipas e ON e.id = u.equipa_id
  WHERE u.id = auth.uid();

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'mensagem', 'Não tens acesso ao sistema.',
      'email_tentativa', (SELECT email FROM auth.users WHERE id = auth.uid())
    );
  END IF;

  RETURN jsonb_build_object(
    'sucesso', true,
    'utilizador', jsonb_build_object(
      'id', v_user.id,
      'email', v_user.email,
      'nome', v_user.nome,
      'perfil', COALESCE(v_user.perfil_nome, initcap(v_user.role::text)),
      'perfil_slug', COALESCE(v_user.perfil_slug, v_user.role::text),
      'area_id', v_user.area_id,
      'area', v_user.area_nome,
      'equipa_id', v_user.equipa_id,
      'equipa', v_user.equipa_nome,
      'presenca', v_user.presenca,
      'is_supervisao', (
        public.has_permissao('supervisao.dashboard')
        OR public.has_permissao('casos.ver_area')
      )
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_perfil_utilizador() TO authenticated;

-- ---------------------------------------------------------------------------
-- Seed (só se área demo ainda não existir)
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_area_id    UUID := 'b0000000-0000-4000-8000-000000000001';
  v_instance   UUID;
  v_exists     BOOLEAN;
BEGIN
  SELECT EXISTS (SELECT 1 FROM public.areas WHERE id = v_area_id) INTO v_exists;
  IF v_exists THEN
    RAISE NOTICE 'MS-06: seed demo já aplicado (área SU Eletricidade existe).';
    RETURN;
  END IF;

  SELECT id INTO v_instance FROM auth.instances LIMIT 1;
  IF v_instance IS NULL THEN
    v_instance := '00000000-0000-0000-0000-000000000000';
  END IF;

  -- Área
  INSERT INTO public.areas (id, nome, slug, timezone)
  VALUES (v_area_id, 'SU Eletricidade', 'su-eletricidade', 'Europe/Lisbon');

  -- Equipas (skills)
  INSERT INTO public.equipas (id, area_id, nome, codigo) VALUES
    ('b0000000-0000-4000-8000-000000000101', v_area_id, 'Lisboa Centro',    'LIS-CTR'),
    ('b0000000-0000-4000-8000-000000000102', v_area_id, 'Porto Norte',      'PTO-NOR'),
    ('b0000000-0000-4000-8000-000000000103', v_area_id, 'Algarve',          'ALG'),
    ('b0000000-0000-4000-8000-000000000104', v_area_id, 'Backoffice RQS',   'BO-RQS');

  INSERT INTO public.regras_fila (area_id, versao, config)
  VALUES (v_area_id, 1, '{"mvp": true, "tiers_completos": false}'::jsonb);

  -- Auth + utilizadores (pré-provisionados — gestão; login Google MS-07)
  -- Developer
  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, email_change,
    email_change_token_new, recovery_token, is_anonymous
  ) VALUES (
    v_instance, 'c0000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated',
    'developer@smartqueue-poc.demo', '', NOW(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"nome":"Developer POC"}'::jsonb,
    NOW(), NOW(), '', '', '', '', false
  );

  INSERT INTO public.utilizadores (id, area_id, equipa_id, email, nome, role, perfil_id, presenca)
  VALUES (
    'c0000000-0000-4000-8000-000000000001', v_area_id,
    'b0000000-0000-4000-8000-000000000104',
    'developer@smartqueue-poc.demo', 'Developer POC', 'developer',
    'a0000000-0000-4000-8000-000000000005', 'offline'
  );

  -- Supervisores
  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, email_change,
    email_change_token_new, recovery_token, is_anonymous
  ) VALUES
    (v_instance, 'c0000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated',
     'supervisor1@smartqueue-poc.demo', '', NOW(),
     '{"provider":"email","providers":["email"]}'::jsonb, '{"nome":"Ana Supervisor"}'::jsonb,
     NOW(), NOW(), '', '', '', '', false),
    (v_instance, 'c0000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated',
     'supervisor2@smartqueue-poc.demo', '', NOW(),
     '{"provider":"email","providers":["email"]}'::jsonb, '{"nome":"Carlos Coordenador"}'::jsonb,
     NOW(), NOW(), '', '', '', '', false);

  INSERT INTO public.utilizadores (id, area_id, equipa_id, email, nome, role, perfil_id, presenca) VALUES
    ('c0000000-0000-4000-8000-000000000002', v_area_id, 'b0000000-0000-4000-8000-000000000101',
     'supervisor1@smartqueue-poc.demo', 'Ana Supervisor', 'supervisor',
     'a0000000-0000-4000-8000-000000000002', 'offline'),
    ('c0000000-0000-4000-8000-000000000003', v_area_id, 'b0000000-0000-4000-8000-000000000102',
     'supervisor2@smartqueue-poc.demo', 'Carlos Coordenador', 'supervisor',
     'a0000000-0000-4000-8000-000000000003', 'offline');

  -- Colaboradores (5)
  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, email_change,
    email_change_token_new, recovery_token, is_anonymous
  ) VALUES
    (v_instance, 'c0000000-0000-4000-8000-000000000004', 'authenticated', 'authenticated',
     'colab1@smartqueue-poc.demo', '', NOW(), '{"provider":"email","providers":["email"]}'::jsonb,
     '{"nome":"Maria Silva"}'::jsonb, NOW(), NOW(), '', '', '', '', false),
    (v_instance, 'c0000000-0000-4000-8000-000000000005', 'authenticated', 'authenticated',
     'colab2@smartqueue-poc.demo', '', NOW(), '{"provider":"email","providers":["email"]}'::jsonb,
     '{"nome":"João Santos"}'::jsonb, NOW(), NOW(), '', '', '', '', false),
    (v_instance, 'c0000000-0000-4000-8000-000000000006', 'authenticated', 'authenticated',
     'colab3@smartqueue-poc.demo', '', NOW(), '{"provider":"email","providers":["email"]}'::jsonb,
     '{"nome":"Sofia Costa"}'::jsonb, NOW(), NOW(), '', '', '', '', false),
    (v_instance, 'c0000000-0000-4000-8000-000000000007', 'authenticated', 'authenticated',
     'colab4@smartqueue-poc.demo', '', NOW(), '{"provider":"email","providers":["email"]}'::jsonb,
     '{"nome":"Pedro Alves"}'::jsonb, NOW(), NOW(), '', '', '', '', false),
    (v_instance, 'c0000000-0000-4000-8000-000000000008', 'authenticated', 'authenticated',
     'colab5@smartqueue-poc.demo', '', NOW(), '{"provider":"email","providers":["email"]}'::jsonb,
     '{"nome":"Inês Ferreira"}'::jsonb, NOW(), NOW(), '', '', '', '', false);

  INSERT INTO public.utilizadores (id, area_id, equipa_id, email, nome, role, perfil_id, presenca) VALUES
    ('c0000000-0000-4000-8000-000000000004', v_area_id, 'b0000000-0000-4000-8000-000000000101',
     'colab1@smartqueue-poc.demo', 'Maria Silva', 'colaborador',
     'a0000000-0000-4000-8000-000000000001', 'offline'),
    ('c0000000-0000-4000-8000-000000000005', v_area_id, 'b0000000-0000-4000-8000-000000000102',
     'colab2@smartqueue-poc.demo', 'João Santos', 'colaborador',
     'a0000000-0000-4000-8000-000000000001', 'offline'),
    ('c0000000-0000-4000-8000-000000000006', v_area_id, 'b0000000-0000-4000-8000-000000000103',
     'colab3@smartqueue-poc.demo', 'Sofia Costa', 'colaborador',
     'a0000000-0000-4000-8000-000000000001', 'offline'),
    ('c0000000-0000-4000-8000-000000000007', v_area_id, 'b0000000-0000-4000-8000-000000000101',
     'colab4@smartqueue-poc.demo', 'Pedro Alves', 'colaborador',
     'a0000000-0000-4000-8000-000000000001', 'offline'),
    ('c0000000-0000-4000-8000-000000000008', v_area_id, 'b0000000-0000-4000-8000-000000000102',
     'colab5@smartqueue-poc.demo', 'Inês Ferreira', 'colaborador',
     'a0000000-0000-4000-8000-000000000001', 'offline');

  -- 200 casos sintéticos
  INSERT INTO public.casos (
    area_id, equipa_id, colaborador_id, id_externo, status,
    prioridade_flash, canal, pn, tipo_caso, notas,
    data_rqs, data_agendamento, inicio_tratamento, distribuido_em, criado_em
  )
  SELECT
    v_area_id,
    (ARRAY[
      'b0000000-0000-4000-8000-000000000101'::uuid,
      'b0000000-0000-4000-8000-000000000102'::uuid,
      'b0000000-0000-4000-8000-000000000103'::uuid,
      'b0000000-0000-4000-8000-000000000104'::uuid
    ])[1 + (g % 4)],
    CASE
      WHEN g BETWEEN 121 AND 140 THEN (ARRAY[
        'c0000000-0000-4000-8000-000000000004'::uuid,
        'c0000000-0000-4000-8000-000000000005'::uuid,
        'c0000000-0000-4000-8000-000000000006'::uuid,
        'c0000000-0000-4000-8000-000000000007'::uuid,
        'c0000000-0000-4000-8000-000000000008'::uuid
      ])[1 + ((g - 121) % 5)]
      WHEN g BETWEEN 141 AND 160 THEN (ARRAY[
        'c0000000-0000-4000-8000-000000000004'::uuid,
        'c0000000-0000-4000-8000-000000000005'::uuid,
        'c0000000-0000-4000-8000-000000000006'::uuid,
        'c0000000-0000-4000-8000-000000000007'::uuid,
        'c0000000-0000-4000-8000-000000000008'::uuid
      ])[1 + ((g - 141) % 5)]
      WHEN g BETWEEN 161 AND 175 THEN (ARRAY[
        'c0000000-0000-4000-8000-000000000004'::uuid,
        'c0000000-0000-4000-8000-000000000005'::uuid,
        'c0000000-0000-4000-8000-000000000006'::uuid
      ])[1 + ((g - 161) % 3)]
      ELSE NULL
    END,
    'SU-26-' || lpad(g::text, 5, '0'),
    CASE
      WHEN g <= 100 THEN 'livre'::public.caso_status
      WHEN g <= 120 THEN 'por_tratar'::public.caso_status
      WHEN g <= 140 THEN 'em_tratamento'::public.caso_status
      WHEN g <= 160 THEN 'agendado'::public.caso_status
      WHEN g <= 175 THEN 'suspenso'::public.caso_status
      WHEN g <= 190 THEN 'concluido'::public.caso_status
      ELSE 'pendente'::public.caso_status
    END,
    (g % 10 = 0),
    (ARRAY['Telefone', 'Email', 'Loja', 'Chat'])[1 + (g % 4)],
    'PN' || lpad((1000 + g)::text, 6, '0'),
    (ARRAY['Reclamação', 'Informação', 'Avaria', 'Contrato'])[1 + (g % 4)],
    CASE WHEN g % 7 = 0 THEN 'Nota demo caso ' || g ELSE NULL END,
    NOW() - ((g % 14) || ' days')::interval + ((g % 8) || ' hours')::interval,
    CASE
      WHEN g BETWEEN 141 AND 175 THEN NOW() + ((g % 5) || ' days')::interval
      ELSE NULL
    END,
    CASE WHEN g BETWEEN 121 AND 140 THEN NOW() - ((g % 3) || ' hours')::interval ELSE NULL END,
    CASE WHEN g BETWEEN 121 AND 120 THEN NOW() ELSE NULL END,
    NOW() - ((g % 30) || ' days')::interval
  FROM generate_series(1, 200) AS g;

  RAISE NOTICE 'MS-06: seed demo SU Eletricidade aplicado (200 casos, 8 utilizadores).';
END;
$$;
