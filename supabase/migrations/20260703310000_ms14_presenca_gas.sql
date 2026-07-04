-- MS-14 (parte 1): novos valores enum presenca_status
-- Funções/RPCs na migration seguinte (PG exige commit antes de usar novos enum values)

ALTER TYPE public.presenca_status ADD VALUE IF NOT EXISTS 'atendimento_loja';
ALTER TYPE public.presenca_status ADD VALUE IF NOT EXISTS 'refeicao';
ALTER TYPE public.presenca_status ADD VALUE IF NOT EXISTS 'reuniao';
ALTER TYPE public.presenca_status ADD VALUE IF NOT EXISTS 'trabalho_manual';
ALTER TYPE public.presenca_status ADD VALUE IF NOT EXISTS 'atendimento_cc';
ALTER TYPE public.presenca_status ADD VALUE IF NOT EXISTS 'formacao';
ALTER TYPE public.presenca_status ADD VALUE IF NOT EXISTS 'trabalhos_spv';
