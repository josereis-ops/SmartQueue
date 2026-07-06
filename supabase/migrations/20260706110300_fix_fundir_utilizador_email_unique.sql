-- Corrige fusão OAuth: email UNIQUE + FK utilizadores → auth.users

CREATE OR REPLACE FUNCTION public._fundir_utilizador_auth_id(
  p_old_id UUID,
  p_new_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old public.utilizadores%ROWTYPE;
BEGIN
  IF p_old_id IS NULL OR p_new_id IS NULL OR p_old_id = p_new_id THEN
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.utilizadores u WHERE u.id = p_old_id) THEN
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p_new_id) THEN
    RETURN;
  END IF;

  IF EXISTS (SELECT 1 FROM public.utilizadores u WHERE u.id = p_new_id) THEN
    UPDATE public.casos SET colaborador_id = p_new_id WHERE colaborador_id = p_old_id;
    UPDATE public.notificacoes SET destinatario_id = p_new_id WHERE destinatario_id = p_old_id;
    UPDATE public.notificacoes SET remetente_id = p_new_id WHERE remetente_id = p_old_id;
    UPDATE public.eventos_caso SET actor_id = p_new_id WHERE actor_id = p_old_id;
    DELETE FROM public.utilizador_equipas WHERE utilizador_id = p_old_id;
    DELETE FROM public.utilizadores WHERE id = p_old_id;
    DELETE FROM auth.users WHERE id = p_old_id AND id <> p_new_id;
    RETURN;
  END IF;

  SELECT * INTO v_old FROM public.utilizadores u WHERE u.id = p_old_id;

  CREATE TEMP TABLE IF NOT EXISTS _sq_equipas_tmp (
    equipa_id UUID NOT NULL
  ) ON COMMIT DROP;

  DELETE FROM _sq_equipas_tmp;
  INSERT INTO _sq_equipas_tmp (equipa_id)
  SELECT ue.equipa_id
  FROM public.utilizador_equipas ue
  WHERE ue.utilizador_id = p_old_id;

  IF NOT EXISTS (SELECT 1 FROM _sq_equipas_tmp WHERE equipa_id = v_old.equipa_id) THEN
    INSERT INTO _sq_equipas_tmp (equipa_id) VALUES (v_old.equipa_id);
  END IF;

  UPDATE public.casos SET colaborador_id = p_new_id WHERE colaborador_id = p_old_id;
  UPDATE public.notificacoes SET destinatario_id = p_new_id WHERE destinatario_id = p_old_id;
  UPDATE public.notificacoes SET remetente_id = p_new_id WHERE remetente_id = p_old_id;
  UPDATE public.eventos_caso SET actor_id = p_new_id WHERE actor_id = p_old_id;

  DELETE FROM public.utilizador_equipas WHERE utilizador_id = p_old_id;
  DELETE FROM public.utilizadores WHERE id = p_old_id;

  INSERT INTO public.utilizadores (
    id, area_id, equipa_id, ponto_atendimento_id, email, nome, role, perfil_id, presenca, ultimo_ping, criado_em
  ) VALUES (
    p_new_id, v_old.area_id, v_old.equipa_id, v_old.ponto_atendimento_id, v_old.email, v_old.nome,
    v_old.role, v_old.perfil_id, v_old.presenca, v_old.ultimo_ping, v_old.criado_em
  );

  INSERT INTO public.utilizador_equipas (utilizador_id, equipa_id)
  SELECT p_new_id, t.equipa_id
  FROM _sq_equipas_tmp t
  ON CONFLICT (utilizador_id, equipa_id) DO NOTHING;

  DELETE FROM auth.users WHERE id = p_old_id AND id <> p_new_id;
END;
$$;

DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT u.id AS old_id, au.id AS new_id
    FROM public.utilizadores u
    JOIN auth.users au ON lower(trim(au.email)) = lower(trim(u.email))
    WHERE u.id <> au.id
  LOOP
    PERFORM public._fundir_utilizador_auth_id(r.old_id, r.new_id);
    RAISE NOTICE 'Fundido utilizador % -> %', r.old_id, r.new_id;
  END LOOP;
END;
$$;

DELETE FROM auth.users au
WHERE au.email IS NOT NULL
  AND trim(au.email) <> ''
  AND NOT EXISTS (SELECT 1 FROM public.utilizadores u WHERE u.id = au.id)
  AND EXISTS (
    SELECT 1 FROM auth.users au2
    WHERE lower(trim(au2.email)) = lower(trim(au.email))
      AND au2.id <> au.id
      AND EXISTS (SELECT 1 FROM public.utilizadores u2 WHERE u2.id = au2.id)
  );
