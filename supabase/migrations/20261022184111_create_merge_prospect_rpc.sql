CREATE OR REPLACE FUNCTION public.merge_prospect_into_patient(
  p_prospect_id uuid,
  p_existing_patient_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prospect public.patients;
BEGIN
  -- Verifica o provisório
  SELECT * INTO v_prospect FROM public.patients WHERE id = p_prospect_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Prospect não encontrado.'; END IF;
  IF v_prospect.user_id <> auth.uid() THEN RAISE EXCEPTION 'Sem permissão.'; END IF;
  IF v_prospect.status <> 'prospect' THEN RAISE EXCEPTION 'Apenas prospects podem ser mesclados.'; END IF;

  -- Verifica o paciente destino
  IF NOT EXISTS (SELECT 1 FROM public.patients WHERE id = p_existing_patient_id AND user_id = auth.uid()) THEN
    RAISE EXCEPTION 'Paciente de destino não encontrado.';
  END IF;

  -- 1. Move os horários salvos
  UPDATE public.patient_schedules
  SET patient_id = p_existing_patient_id
  WHERE patient_id = p_prospect_id;

  -- 2. Move os agendamentos (caso existam)
  UPDATE public.appointments
  SET patient_id = p_existing_patient_id
  WHERE patient_id = p_prospect_id;

  -- 3. Atualiza o rastreio do Google para o novo paciente
  UPDATE public.google_imported_recurrences
  SET target_id = p_existing_patient_id
  WHERE target_type = 'patient' AND target_id = p_prospect_id;

  -- 4. Apaga o provisório
  DELETE FROM public.patients WHERE id = p_prospect_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.merge_prospect_into_patient(uuid, uuid) TO authenticated;