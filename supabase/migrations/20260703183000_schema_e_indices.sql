-- Smart Queue v2 — Sprint 1: schema base + índices (sem RLS; ver migration 002)

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

CREATE TYPE public.caso_status AS ENUM (
  'livre',
  'em_tratamento',
  'pendente',
  'suspenso',
  'agendado',
  'por_tratar',
  'outro',
  'concluido',
  'cancelado'
);

CREATE TYPE public.user_role AS ENUM (
  'developer',
  'supervisor',
  'colaborador'
);

CREATE TYPE public.presenca_status AS ENUM (
  'disponivel',
  'pausa',
  'offline'
);

-- ---------------------------------------------------------------------------
-- Áreas (tenants lógicos)
-- ---------------------------------------------------------------------------

CREATE TABLE public.areas (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nome       TEXT NOT NULL,
  slug       TEXT NOT NULL UNIQUE,
  ativo      BOOLEAN NOT NULL DEFAULT true,
  timezone   TEXT NOT NULL DEFAULT 'Europe/Lisbon',
  criado_em  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Equipas (skills / lojas dentro de uma área)
-- ---------------------------------------------------------------------------

CREATE TABLE public.equipas (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  area_id    UUID NOT NULL REFERENCES public.areas (id) ON DELETE CASCADE,
  nome       TEXT NOT NULL,
  codigo     TEXT NOT NULL,
  ativo      BOOLEAN NOT NULL DEFAULT true,
  criado_em  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (area_id, codigo)
);

CREATE INDEX idx_equipas_area ON public.equipas (area_id);

-- ---------------------------------------------------------------------------
-- Utilizadores (id = auth.users.id)
-- ---------------------------------------------------------------------------

CREATE TABLE public.utilizadores (
  id           UUID PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  area_id      UUID NOT NULL REFERENCES public.areas (id) ON DELETE RESTRICT,
  equipa_id    UUID NOT NULL REFERENCES public.equipas (id) ON DELETE RESTRICT,
  email        TEXT NOT NULL UNIQUE,
  nome         TEXT NOT NULL,
  role         public.user_role NOT NULL DEFAULT 'colaborador',
  presenca     public.presenca_status NOT NULL DEFAULT 'offline',
  ultimo_ping  TIMESTAMPTZ,
  criado_em    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_utilizadores_area ON public.utilizadores (area_id);
CREATE INDEX idx_utilizadores_equipa ON public.utilizadores (equipa_id);

-- ---------------------------------------------------------------------------
-- Regras de fila configuráveis por área
-- ---------------------------------------------------------------------------

CREATE TABLE public.regras_fila (
  area_id  UUID PRIMARY KEY REFERENCES public.areas (id) ON DELETE CASCADE,
  versao   INT NOT NULL DEFAULT 1,
  config   JSONB NOT NULL DEFAULT '{}'::jsonb,
  atualizado_em TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Casos (fila central — mapeamento 16 cols GAS)
-- ---------------------------------------------------------------------------

CREATE TABLE public.casos (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  area_id             UUID NOT NULL REFERENCES public.areas (id) ON DELETE CASCADE,
  equipa_id           UUID NOT NULL REFERENCES public.equipas (id) ON DELETE RESTRICT,
  colaborador_id      UUID REFERENCES public.utilizadores (id) ON DELETE SET NULL,
  id_externo          TEXT NOT NULL,
  status              public.caso_status NOT NULL DEFAULT 'livre',
  prioridade_flash    BOOLEAN NOT NULL DEFAULT false,
  canal               TEXT,
  email_contacto      TEXT,
  pn                  TEXT,
  tipo_caso           TEXT,
  notas               TEXT,
  notas_supervisor    TEXT,
  intercalar_em       TIMESTAMPTZ,
  data_rqs            TIMESTAMPTZ,
  data_agendamento    TIMESTAMPTZ,
  inicio_tratamento   TIMESTAMPTZ,
  distribuido_em      TIMESTAMPTZ,
  criado_em           TIMESTAMPTZ NOT NULL DEFAULT now(),
  versao              INT NOT NULL DEFAULT 1,
  atualizado_em       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (area_id, id_externo)
);

-- Dashboard supervisor
CREATE INDEX idx_casos_dashboard
  ON public.casos (area_id, equipa_id, status);

-- Motor de fila MVP
CREATE INDEX idx_casos_fila
  ON public.casos (area_id, equipa_id, prioridade_flash DESC, data_rqs ASC NULLS LAST, criado_em ASC)
  WHERE status IN ('livre', 'por_tratar');

-- Filtros RQS
CREATE INDEX idx_casos_rqs
  ON public.casos (area_id, tipo_caso, data_rqs)
  WHERE status = 'livre';

-- Casos por colaborador
CREATE INDEX idx_casos_colaborador
  ON public.casos (colaborador_id, status)
  WHERE colaborador_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Notificações (nudges supervisor → colaborador)
-- ---------------------------------------------------------------------------

CREATE TABLE public.notificacoes (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  area_id          UUID NOT NULL REFERENCES public.areas (id) ON DELETE CASCADE,
  destinatario_id  UUID NOT NULL REFERENCES public.utilizadores (id) ON DELETE CASCADE,
  remetente_id     UUID NOT NULL REFERENCES public.utilizadores (id) ON DELETE CASCADE,
  caso_id          UUID REFERENCES public.casos (id) ON DELETE SET NULL,
  mensagem         TEXT NOT NULL,
  lida             BOOLEAN NOT NULL DEFAULT false,
  criado_em        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_notificacoes_dest
  ON public.notificacoes (destinatario_id, lida)
  WHERE lida = false;

CREATE INDEX idx_notificacoes_area ON public.notificacoes (area_id);

-- ---------------------------------------------------------------------------
-- Audit log (eventos de caso)
-- ---------------------------------------------------------------------------

CREATE TABLE public.eventos_caso (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  caso_id     UUID NOT NULL REFERENCES public.casos (id) ON DELETE CASCADE,
  area_id     UUID NOT NULL REFERENCES public.areas (id) ON DELETE CASCADE,
  actor_id    UUID REFERENCES public.utilizadores (id) ON DELETE SET NULL,
  acao        TEXT NOT NULL,
  detalhes    JSONB,
  criado_em   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_eventos_caso ON public.eventos_caso (caso_id, criado_em DESC);

-- ---------------------------------------------------------------------------
-- Trigger: atualizado_em em casos
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_atualizado_em()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.atualizado_em = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_casos_atualizado_em
  BEFORE UPDATE ON public.casos
  FOR EACH ROW
  EXECUTE FUNCTION public.set_atualizado_em();
