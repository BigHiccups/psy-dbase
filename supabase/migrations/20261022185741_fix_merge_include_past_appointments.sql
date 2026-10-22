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
  v_schedule record;
  v_occurrence_date date;
  v_horizon_end date := current_date + interval '90 days';
  v_anchor date;
BEGIN
  SELECT * INTO v_prospect FROM public.patients WHERE id = p_prospect_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Prospect não encontrado.'; END IF;
  IF v_prospect.user_id <> auth.uid() THEN RAISE EXCEPTION 'Sem permissão.'; END IF;
  IF v_prospect.status <> 'prospect' THEN RAISE EXCEPTION 'Apenas prospects podem ser mesclados.'; END IF;

  IF NOT EXISTS (SELECT 1 FROM public.patients WHERE id = p_existing_patient_id AND user_id = auth.uid()) THEN
    RAISE EXCEPTION 'Paciente de destino não encontrado.';
  END IF;

  -- 1. Move os horários salvos
  UPDATE public.patient_schedules
  SET patient_id = p_existing_patient_id
  WHERE patient_id = p_prospect_id;

  -- 2. Gera os agendamentos (incluindo a data exata da âncora, que pode ser no passado)
  FOR v_schedule IN 
    SELECT * FROM public.patient_schedules WHERE patient_id = p_existing_patient_id
  LOOP
    v_anchor := coalesce(v_schedule.anchor_date, current_date);
    v_occurrence_date := v_anchor; -- Começa EXATAMENTE na data do evento original

    WHILE v_occurrence_date <= v_horizon_end LOOP
      INSERT INTO public.appointments (
        user_id, patient_id, type, weekday, start_time, duration_min,
        starts_on, ends_on, is_recurring, status
      ) VALUES (
        v_prospect.user_id, p_existing_patient_id, 'session',
        v_schedule.weekday, v_schedule.start_time, v_schedule.duration_min,
        v_occurrence_date, v_occurrence_date, true, 'active'
      ) ON CONFLICT DO NOTHING;

      IF v_schedule.recurrence_type = 'once' THEN EXIT; END IF;

      v_occurrence_date := public.compute_next_occurrence(
        v_occurrence_date, v_schedule.recurrence_type, v_schedule.recurrence_days, v_anchor
      );
      IF v_occurrence_date IS NULL THEN EXIT; END IF;
    END LOOP;
  END LOOP;

  -- 3. Move eventuais agendamentos avulsos antigos
  UPDATE public.appointments
  SET patient_id = p_existing_patient_id
  WHERE patient_id = p_prospect_id;

  -- 4. Atualiza o rastreio do Google
  UPDATE public.google_imported_recurrences
  SET target_id = p_existing_patient_id
  WHERE target_type = 'patient' AND target_id = p_prospect_id;

  -- 5. Apaga o provisório
  DELETE FROM public.patients WHERE id = p_prospect_id;
END;
$$;