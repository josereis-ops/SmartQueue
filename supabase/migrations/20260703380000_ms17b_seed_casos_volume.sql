-- MS-17b: volume demo — até 1000 casos na área SU Eletricidade para testar grelha / performance UI
-- Usa equipas reais da área (não UUIDs fixos do seed MS-06).

DO $$
DECLARE
  v_area_id UUID := 'b0000000-0000-4000-8000-000000000001';
  v_max_num   INT;
  v_target    INT := 1000;
  v_added     INT;
  v_equipas   UUID[];
  v_n_equipas INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.areas WHERE id = v_area_id) THEN
    RAISE NOTICE 'MS-17b: área demo não existe — seed ignorado.';
    RETURN;
  END IF;

  SELECT array_agg(e.id ORDER BY e.nome)
  INTO v_equipas
  FROM public.equipas e
  WHERE e.area_id = v_area_id AND e.ativo = true;

  v_n_equipas := COALESCE(array_length(v_equipas, 1), 0);
  IF v_n_equipas = 0 THEN
    RAISE NOTICE 'MS-17b: sem equipas activas na área — seed ignorado.';
    RETURN;
  END IF;

  SELECT COALESCE(MAX(
    (regexp_match(id_externo, '^SU-26-([0-9]+)$'))[1]::int
  ), 0)
  INTO v_max_num
  FROM public.casos
  WHERE area_id = v_area_id;

  IF v_max_num >= v_target THEN
    RAISE NOTICE 'MS-17b: já existem % casos demo (alvo %).', v_max_num, v_target;
    RETURN;
  END IF;

  INSERT INTO public.casos (
    area_id, equipa_id, colaborador_id, id_externo, status,
    prioridade_flash, canal, pn, tipo_caso, notas,
    data_rqs, data_agendamento, inicio_tratamento, distribuido_em, criado_em
  )
  SELECT
    v_area_id,
    v_equipas[1 + (g % v_n_equipas)],
    NULL,
    'SU-26-' || lpad(g::text, 5, '0'),
    CASE
      WHEN g % 10 <= 6 THEN 'livre'::public.caso_status
      WHEN g % 10 <= 8 THEN 'por_tratar'::public.caso_status
      WHEN g % 20 = 9 THEN 'pendente'::public.caso_status
      WHEN g % 20 = 10 THEN 'outro'::public.caso_status
      WHEN g % 20 = 11 THEN 'agendado'::public.caso_status
      WHEN g % 20 = 12 THEN 'suspenso'::public.caso_status
      ELSE 'livre'::public.caso_status
    END,
    (g % 15 = 0),
    (ARRAY['Telefone', 'Email', 'Loja', 'Chat'])[1 + (g % 4)],
    'PN' || lpad((2000 + g)::text, 6, '0'),
    (ARRAY['Reclamação', 'Informação', 'Avaria', 'Contrato', 'Ligação'])[1 + (g % 5)],
    CASE WHEN g % 11 = 0 THEN 'Nota volume MS-17b caso ' || g ELSE NULL END,
    NOW() - ((g % 21) || ' days')::interval + ((g % 8) || ' hours')::interval,
    CASE
      WHEN g % 20 = 11 THEN NOW() + ((g % 7) || ' days')::interval
      ELSE NULL
    END,
    NULL,
    NULL,
    NOW() - ((g % 45) || ' days')::interval
  FROM generate_series(v_max_num + 1, v_target) AS g;

  v_added := v_target - v_max_num;
  RAISE NOTICE 'MS-17b: +% casos demo (total %).', v_added, v_target;
END;
$$;
