CREATE OR REPLACE FUNCTION public.convert_prospect_to_provider(
  p_patient_id uuid,
  p_kind text DEFAULT 'person'::text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
declare
  v_patient public.patients;
  v_provider_id uuid;
  v_recurring_id text;
begin
  if p_kind not in ('person', 'company') then
    raise exception 'kind inválido. Use person ou company.';
  end if;

  select * into v_patient
  from public.patients
  where id = p_patient_id
  for update;

  if not found then
    raise exception 'Paciente não encontrado.';
  end if;

  if v_patient.user_id <> auth.uid() then
    raise exception 'Sem permissão.';
  end if;

  if v_patient.status <> 'prospect' then
    raise exception 'Só é possível converter pacientes em revisão (prospect).';
  end if;

  insert into public.providers (user_id, kind, display_name)
  values (v_patient.user_id, p_kind, v_patient.full_name)
  returning id into v_provider_id;

  v_recurring_id := v_patient.google_recurring_event_id;

  -- NÃO ATUALIZAMOS MAIS appointments AQUI (eles não existem ainda)
  
  -- COPIA OS HORÁRIOS PARA O PRESTADOR
  INSERT INTO public.provider_schedules (
    user_id, provider_id, weekday, start_time, duration_min, recurrence_type, recurrence_days, anchor_date
  )
  SELECT 
    user_id, v_provider_id, weekday, start_time, duration_min, recurrence_type, recurrence_days, anchor_date
  FROM public.patient_schedules
  WHERE patient_id = p_patient_id;

  if v_recurring_id is not null then
    update public.google_imported_recurrences
    set
      target_type = 'provider',
      target_id = v_provider_id
    where user_id = v_patient.user_id
      and google_recurring_event_id = v_recurring_id;
  end if;

  delete from public.patients where id = p_patient_id;

  return v_provider_id;
end;
$$;

GRANT EXECUTE ON FUNCTION public.convert_prospect_to_provider(uuid, text) TO authenticated;