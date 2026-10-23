CREATE OR REPLACE FUNCTION public.set_provider_schedules(
  p_provider_id uuid,
  p_schedules jsonb,
  p_recurrence_type text,
  p_recurrence_days int,
  p_horizon_days int default 90
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_provider public.providers;
  v_schedule jsonb;
  v_weekday int;
  v_start_time time;
  v_duration int;
  v_anchor_date date;
  v_rec_type text;
  v_rec_days int;
  v_today date := current_date;
  v_horizon_end date := current_date + (p_horizon_days || ' days')::interval;
  v_occurrence_date date;
  v_conflict_label text;
begin
  select * into v_provider from public.providers where id = p_provider_id for update;
  if not found then raise exception 'Prestador não encontrado.'; end if;
  if v_provider.user_id <> auth.uid() then raise exception 'Sem permissão.'; end if;
  if p_schedules is null or jsonb_array_length(p_schedules) = 0 then raise exception 'Informe pelo menos um horário.'; end if;

  delete from public.appointments where provider_id = p_provider_id and starts_on >= v_today;
  delete from public.provider_schedules where provider_id = p_provider_id;

  for v_schedule in select * from jsonb_array_elements(p_schedules) loop
    -- AQUI: Lê a frequência individual de cada objeto JSON
    v_rec_type := coalesce(v_schedule->>'recurrenceType', p_recurrence_type);
    v_rec_days := coalesce((v_schedule->>'recurrenceDays')::int, p_recurrence_days);

    if v_schedule ? 'anchorDate' and (v_schedule->>'anchorDate') is not null then
      v_anchor_date := (v_schedule->>'anchorDate')::date;
    else
      v_weekday := (v_schedule->>'weekday')::int;
      v_anchor_date := v_today + ((v_weekday - extract(dow from v_today)::int + 7) % 7);
    end if;

    v_weekday := extract(dow from v_anchor_date)::int;
    v_start_time := (v_schedule->>'startTime')::time;
    v_duration := coalesce((v_schedule->>'durationMin')::int, 50);

    if v_duration < 15 or v_duration > 240 then raise exception 'Duração inválida: %', v_duration; end if;

    insert into public.provider_schedules (
      user_id, provider_id, weekday, start_time, duration_min,
      recurrence_type, recurrence_days, anchor_date
    ) values (
      v_provider.user_id, p_provider_id, v_weekday, v_start_time, v_duration,
      v_rec_type, v_rec_days, v_anchor_date
    );

    v_occurrence_date := v_anchor_date;

    while v_occurrence_date <= v_horizon_end loop
      insert into public.appointments (
        user_id, provider_id, type, weekday, start_time, duration_min,
        starts_on, ends_on, is_recurring, status, linked_expense
      ) values (
        v_provider.user_id, p_provider_id, 'personal',
        extract(dow from v_occurrence_date)::int,
        v_start_time, v_duration,
        v_occurrence_date, v_occurrence_date, true, 'active', true
      )
      on conflict do nothing;

      if v_rec_type = 'once' then exit; end if;

      v_occurrence_date := public.compute_next_occurrence(
        v_occurrence_date, v_rec_type, v_rec_days, v_anchor_date
      );

      if v_occurrence_date is null then exit; end if;
    end loop;
  end loop;
end;
$$;