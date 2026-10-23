set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.set_provider_schedules(p_provider_id uuid, p_schedules jsonb, p_recurrence_type text, p_recurrence_days integer, p_horizon_days integer DEFAULT 90)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_provider public.providers;
  v_schedule jsonb;
  v_weekday int;
  v_start_time time;
  v_duration int;
  v_start_min int;
  v_end_min int;
  v_anchor_date date;
  v_today date := current_date;
  v_horizon_end date := current_date + (p_horizon_days || ' days')::interval;
  v_occurrence_date date;
  v_conflict_label text;
begin
  select * into v_provider from public.providers where id = p_provider_id for update;
  if not found then raise exception 'Prestador não encontrado.'; end if;
  if v_provider.user_id <> auth.uid() then raise exception 'Sem permissão.'; end if;
  if p_schedules is null or jsonb_array_length(p_schedules) = 0 then
    raise exception 'Informe pelo menos um horário.';
  end if;

  if p_recurrence_type not in (
    'once', 'weekly', 'biweekly', 'monthly', 'every_30_days', 'custom_days'
  ) then
    raise exception 'recurrence_type inválido: %', p_recurrence_type;
  end if;

  if p_recurrence_type = 'custom_days' and p_recurrence_days is null then
    raise exception 'recurrence_days é obrigatório para custom_days.';
  end if;
  if p_recurrence_type <> 'custom_days' and p_recurrence_days is not null then
    raise exception 'recurrence_days só é permitido para custom_days.';
  end if;
  if p_recurrence_days is not null and (p_recurrence_days < 1 or p_recurrence_days > 365) then
    raise exception 'recurrence_days deve estar entre 1 e 365.';
  end if;

  for v_schedule in select * from jsonb_array_elements(p_schedules)
  loop
    if v_schedule ? 'anchorDate' and (v_schedule->>'anchorDate') is not null then
      v_anchor_date := (v_schedule->>'anchorDate')::date;
    else
      v_weekday := (v_schedule->>'weekday')::int;
      v_anchor_date := v_today + ((v_weekday - extract(dow from v_today)::int + 7) % 7);
    end if;

    if v_anchor_date < v_today then
      raise exception 'A data de início não pode ser no passado.';
    end if;

    v_start_time := (v_schedule->>'startTime')::time;
    v_duration := coalesce((v_schedule->>'durationMin')::int, 50);
    v_start_min := extract(hour from v_start_time) * 60 + extract(minute from v_start_time);
    v_end_min := v_start_min + v_duration;

    select coalesce(p.full_name, pr.display_name, 'compromisso pessoal')
      into v_conflict_label
    from public.appointments a
    left join public.patients p on p.id = a.patient_id
    left join public.providers pr on pr.id = a.provider_id
    where a.user_id = v_provider.user_id
      and a.weekday = extract(dow from v_anchor_date)::int
      and a.status = 'active'
      and a.starts_on >= v_today
      and (a.provider_id is null or a.provider_id <> p_provider_id)
      and (extract(hour from a.start_time) * 60 + extract(minute from a.start_time)) < v_end_min
      and v_start_min < (extract(hour from a.start_time) * 60 + extract(minute from a.start_time) + a.duration_min)
    limit 1;

    if v_conflict_label is not null then
      raise exception 'O horário de % às % conflita com %.',
        to_char(v_anchor_date, 'DD/MM/YYYY'), v_start_time, v_conflict_label;
    end if;
  end loop;

  delete from public.appointments
    where provider_id = p_provider_id and starts_on >= v_today;
  delete from public.provider_schedules where provider_id = p_provider_id;

  for v_schedule in select * from jsonb_array_elements(p_schedules)
  loop
    if v_schedule ? 'anchorDate' and (v_schedule->>'anchorDate') is not null then
      v_anchor_date := (v_schedule->>'anchorDate')::date;
    else
      v_weekday := (v_schedule->>'weekday')::int;
      v_anchor_date := v_today + ((v_weekday - extract(dow from v_today)::int + 7) % 7);
    end if;

    v_weekday := extract(dow from v_anchor_date)::int;
    v_start_time := (v_schedule->>'startTime')::time;
    v_duration := coalesce((v_schedule->>'durationMin')::int, 50);

    if v_duration < 15 or v_duration > 240 then
      raise exception 'Duração inválida: %', v_duration;
    end if;

    insert into public.provider_schedules (
      user_id, provider_id, weekday, start_time, duration_min,
      recurrence_type, recurrence_days, anchor_date
    ) values (
      v_provider.user_id, p_provider_id, v_weekday, v_start_time, v_duration,
      p_recurrence_type, p_recurrence_days, v_anchor_date
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

      if p_recurrence_type = 'once' then exit; end if;

      v_occurrence_date := public.compute_next_occurrence(
        v_occurrence_date, p_recurrence_type, p_recurrence_days, v_anchor_date
      );

      if v_occurrence_date is null then exit; end if;
    end loop;
  end loop;
end;
$function$
;


