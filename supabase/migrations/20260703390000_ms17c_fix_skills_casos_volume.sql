-- MS-17c: casos volume MS-17b (SU-26-00201+) → skills Producao / Consumo (como utilizadores demo)

DO $$
DECLARE
  v_area_id  UUID := 'b0000000-0000-4000-8000-000000000001';
  v_s_prod   UUID;
  v_s_cons   UUID;
  v_updated  INT;
BEGIN
  SELECT e.id INTO v_s_prod
  FROM public.equipas e
  WHERE e.area_id = v_area_id AND e.nome = 'Producao' AND e.ativo = true
  LIMIT 1;

  SELECT e.id INTO v_s_cons
  FROM public.equipas e
  WHERE e.area_id = v_area_id AND e.nome = 'Consumo' AND e.ativo = true
  LIMIT 1;

  IF v_s_prod IS NULL OR v_s_cons IS NULL THEN
    RAISE NOTICE 'MS-17c: skills Producao/Consumo não encontradas — skip.';
    RETURN;
  END IF;

  UPDATE public.casos c
  SET
    equipa_id = CASE
      WHEN abs(hashtext(c.id_externo)) % 2 = 0 THEN v_s_prod
      ELSE v_s_cons
    END,
    versao = c.versao + 1
  WHERE c.area_id = v_area_id
    AND c.id_externo ~ '^SU-26-[0-9]+$'
    AND (regexp_match(c.id_externo, '^SU-26-([0-9]+)$'))[1]::int >= 201
    AND c.equipa_id IS DISTINCT FROM CASE
      WHEN abs(hashtext(c.id_externo)) % 2 = 0 THEN v_s_prod
      ELSE v_s_cons
    END;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RAISE NOTICE 'MS-17c: % casos volume actualizados para Producao/Consumo.', v_updated;
END;
$$;
