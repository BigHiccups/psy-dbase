-- ============================================================
-- add_recurrence_rpcs
-- ============================================================
-- Cria as 4 RPCs na versão nova (5 args), que respeitam
-- recurrence_type/recurrence_days. As versões antigas (3 e 4 args)
-- continuam existindo — o Postgres aceita overload.
--
-- Frontend ainda chama as antigas até ser atualizado. Nada quebra.
--
-- Depois de validar que o front usa as novas, uma migration futura
-- dropa as antigas.
-- ============================================================


-- ============================================================
-- 1) set_patient_schedules (nova: uuid, jsonb, text, int, int)
-- ============================================================
create or replace function public.set_patient_schedules(
  p_patient_id uuid,
  p_schedules jsonb,
  p_recurrence_type text,
  p_recurrence_days int,
  p_horizon_days int default 90
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_patient public.patients;
  v_schedule jsonb;
  v_weekday int;
  v_start_time time;
  v_start_min int;
  v_end_min int;
  v_duration int;
  v_today date := current_date;
  v_horizon_end date := current_date + (p_horizon_days || ' days')::interval;
  v_occurrence_date date;
  v_weekday_offset int;
  v_conflict_label text;
begin
  -- Validações básicas
  select * into v_patient from public.patients where id = p_patient_id for update;
  if not found then raise exception 'Paciente não encontrado.'; end if;
  if v_patient.user_id <> auth.uid() then raise exception 'Sem permissão.'; end if;
  if p_schedules is null or jsonb_array_length(p_schedules) = 0 then
    raise exception 'Informe pelo menos um horário.';
  end if;

  -- Validação de recurrence_type
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

  -- Validação de conflito (sobreposição de intervalo)
  for v_schedule in select * from jsonb_array_elements(p_schedules)
  loop
    v_weekday := (v_schedule->>'weekday')::int;
    v_start_time := (v_schedule->>'startTime')::time;
    v_duration := coalesce((v_schedule->>'durationMin')::int, 50);
    v_start_min := extract(hour from v_start_time) * 60 + extract(minute from v_start_time);
    v_end_min := v_start_min + v_duration;

    select coalesce(p.full_name, pr.display_name, 'compromisso pessoal')
      into v_conflict_label
    from public.appointments a
    left join public.patients p on p.id = a.patient_id
    left join public.providers pr on pr.id = a.provider_id
    where a.user_id = v_patient.user_id
      and a.weekday = v_weekday
      and a.status = 'active'
      and a.starts_on >= v_today
      and (a.patient_id is null or a.patient_id <> p_patient_id)
      and (extract(hour from a.start_time) * 60 + extract(minute from a.start_time)) < v_end_min
      and v_start_min < (extract(hour from a.start_time) * 60 + extract(minute from a.start_time) + a.duration_min)
    limit 1;

    if v_conflict_label is not null then
      raise exception 'O horário de % às % conflita com %.', v_weekday, v_start_time, v_conflict_label;
    end if;
  end loop;

  -- Limpa e recria
  delete from public.appointments
    where patient_id = p_patient_id and starts_on >= v_today;
  delete from public.patient_schedules where patient_id = p_patient_id;

  for v_schedule in select * from jsonb_array_elements(p_schedules)
  loop
    v_weekday := (v_schedule->>'weekday')::int;
    v_start_time := (v_schedule->>'startTime')::time;
    v_duration := coalesce((v_schedule->>'durationMin')::int, 50);

    if v_weekday < 0 or v_weekday > 6 then raise exception 'Dia inválido: %', v_weekday; end if;
    if v_duration < 15 or v_duration > 240 then raise exception 'Duração inválida: %', v_duration; end if;

    insert into public.patient_schedules (
      user_id, patient_id, weekday, start_time, duration_min,
      recurrence_type, recurrence_days
    ) values (
      v_patient.user_id, p_patient_id, v_weekday, v_start_time, v_duration,
      p_recurrence_type, p_recurrence_days
    );

    v_weekday_offset := (v_weekday - extract(dow from v_today)::int + 7) % 7;
    v_occurrence_date := v_today + v_weekday_offset;

    while v_occurrence_date <= v_horizon_end loop
      insert into public.appointments (
        user_id, patient_id, type, weekday, start_time, duration_min,
        starts_on, ends_on, is_recurring, status
      ) values (
        v_patient.user_id, p_patient_id, 'session', v_weekday, v_start_time,
        v_duration, v_occurrence_date, v_occurrence_date, true, 'active'
      )
      on conflict do nothing;

      if p_recurrence_type = 'once' then exit; end if;

      v_occurrence_date := public.compute_next_occurrence(
        v_occurrence_date, p_recurrence_type, p_recurrence_days
      );

      if v_occurrence_date is null then exit; end if;
    end loop;
  end loop;
end;
$$;

alter function public.set_patient_schedules(uuid, jsonb, text, int, int)
  owner to postgres;

grant execute on function public.set_patient_schedules(uuid, jsonb, text, int, int)
  to authenticated;


-- ============================================================
-- 2) set_provider_schedules (nova: uuid, jsonb, text, int, int)
-- ============================================================
create or replace function public.set_provider_schedules(
  p_provider_id uuid,
  p_schedules jsonb,
  p_recurrence_type text,
  p_recurrence_days int,
  p_horizon_days int default 90
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_provider public.providers;
  v_schedule jsonb;
  v_weekday int;
  v_start_time time;
  v_start_min int;
  v_end_min int;
  v_duration int;
  v_today date := current_date;
  v_horizon_end date := current_date + (p_horizon_days || ' days')::interval;
  v_occurrence_date date;
  v_weekday_offset int;
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
    v_weekday := (v_schedule->>'weekday')::int;
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
      and a.weekday = v_weekday
      and a.status = 'active'
      and a.starts_on >= v_today
      and (a.provider_id is null or a.provider_id <> p_provider_id)
      and (extract(hour from a.start_time) * 60 + extract(minute from a.start_time)) < v_end_min
      and v_start_min < (extract(hour from a.start_time) * 60 + extract(minute from a.start_time) + a.duration_min)
    limit 1;

    if v_conflict_label is not null then
      raise exception 'O horário de % às % conflita com %.', v_weekday, v_start_time, v_conflict_label;
    end if;
  end loop;

  delete from public.appointments
    where provider_id = p_provider_id and starts_on >= v_today;
  delete from public.provider_schedules where provider_id = p_provider_id;

  for v_schedule in select * from jsonb_array_elements(p_schedules)
  loop
    v_weekday := (v_schedule->>'weekday')::int;
    v_start_time := (v_schedule->>'startTime')::time;
    v_duration := coalesce((v_schedule->>'durationMin')::int, 50);

    if v_weekday < 0 or v_weekday > 6 then raise exception 'Dia inválido: %', v_weekday; end if;
    if v_duration < 15 or v_duration > 240 then raise exception 'Duração inválida: %', v_duration; end if;

    insert into public.provider_schedules (
      user_id, provider_id, weekday, start_time, duration_min,
      recurrence_type, recurrence_days
    ) values (
      v_provider.user_id, p_provider_id, v_weekday, v_start_time, v_duration,
      p_recurrence_type, p_recurrence_days
    );

    v_weekday_offset := (v_weekday - extract(dow from v_today)::int + 7) % 7;
    v_occurrence_date := v_today + v_weekday_offset;

    while v_occurrence_date <= v_horizon_end loop
      insert into public.appointments (
        user_id, provider_id, type, weekday, start_time, duration_min,
        starts_on, ends_on, is_recurring, status, linked_expense
      ) values (
        v_provider.user_id, p_provider_id, 'personal', v_weekday, v_start_time,
        v_duration, v_occurrence_date, v_occurrence_date, true, 'active', true
      )
      on conflict do nothing;

      if p_recurrence_type = 'once' then exit; end if;

      v_occurrence_date := public.compute_next_occurrence(
        v_occurrence_date, p_recurrence_type, p_recurrence_days
      );

      if v_occurrence_date is null then exit; end if;
    end loop;
  end loop;
end;
$$;

alter function public.set_provider_schedules(uuid, jsonb, text, int, int)
  owner to postgres;

grant execute on function public.set_provider_schedules(uuid, jsonb, text, int, int)
  to authenticated;


-- ============================================================
-- 3) cancel_appointment_series (nova: uuid, text, date, date, int)
-- ============================================================
-- p_renew_days controla o horizonte do modo 'renew' (default 90).
-- ============================================================
create or replace function public.cancel_appointment_series(
  p_patient_id uuid,
  p_mode text,
  p_from_date date default null,
  p_to_date date default null,
  p_renew_days int default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_patient public.patients;
  v_schedule record;
  v_weekday_offset int;
  v_occurrence_date date;
  v_horizon_end date;
  v_last_active date;
  v_renew_horizon int := coalesce(p_renew_days, 90);
begin
  select * into v_patient from public.patients where id = p_patient_id for update;
  if not found then raise exception 'Paciente não encontrado.'; end if;
  if v_patient.user_id <> auth.uid() then raise exception 'Sem permissão.'; end if;

  if v_renew_horizon < 1 or v_renew_horizon > 365 then
    raise exception 'p_renew_days deve estar entre 1 e 365.';
  end if;

  if p_mode = 'immediate' then
    update public.appointments set status = 'cancelled', updated_at = now()
    where patient_id = p_patient_id and starts_on >= current_date and status = 'active';
    delete from public.patient_schedules where patient_id = p_patient_id;
    return;
  end if;

  if p_mode = 'from_date' then
    if p_from_date is null then raise exception 'Data de início obrigatória.'; end if;
    update public.appointments set status = 'cancelled', updated_at = now()
    where patient_id = p_patient_id and starts_on >= p_from_date and status = 'active';
    -- NÃO deleta patient_schedules: mantém como referência
    return;
  end if;

  if p_mode = 'suspend' then
    if p_from_date is null or p_to_date is null then
      raise exception 'Datas de início e fim obrigatórias.';
    end if;
    if p_to_date < p_from_date then
      raise exception 'Data final deve ser posterior à inicial.';
    end if;

    update public.appointments set status = 'cancelled', updated_at = now()
    where patient_id = p_patient_id
      and starts_on between p_from_date and p_to_date
      and status = 'active';

    if not exists (
      select 1 from public.appointments
      where patient_id = p_patient_id and starts_on > p_to_date and status = 'active'
    ) then
      v_horizon_end := p_to_date + interval '90 days';

      for v_schedule in
        select weekday, start_time, duration_min, recurrence_type, recurrence_days
        from public.patient_schedules where patient_id = p_patient_id
      loop
        v_weekday_offset := (v_schedule.weekday - extract(dow from p_to_date)::int + 7) % 7;
        if v_weekday_offset = 0 then v_weekday_offset := 7; end if;
        v_occurrence_date := p_to_date + v_weekday_offset;

        while v_occurrence_date <= v_horizon_end loop
          insert into public.appointments (
            user_id, patient_id, type, weekday, start_time, duration_min,
            starts_on, ends_on, is_recurring, status
          ) values (
            v_patient.user_id, p_patient_id, 'session',
            v_schedule.weekday, v_schedule.start_time, v_schedule.duration_min,
            v_occurrence_date, v_occurrence_date, true, 'active'
          ) on conflict do nothing;

          if v_schedule.recurrence_type = 'once' then exit; end if;

          v_occurrence_date := public.compute_next_occurrence(
            v_occurrence_date, v_schedule.recurrence_type, v_schedule.recurrence_days
          );
          if v_occurrence_date is null then exit; end if;
        end loop;
      end loop;
    end if;
    return;
  end if;

  if p_mode = 'renew' then
    select max(starts_on) into v_last_active
    from public.appointments where patient_id = p_patient_id and status = 'active';

    if v_last_active is null then raise exception 'Não há série ativa para renovar.'; end if;

    v_horizon_end := v_last_active + (v_renew_horizon || ' days')::interval;

    for v_schedule in
      select weekday, start_time, duration_min, recurrence_type, recurrence_days
      from public.patient_schedules where patient_id = p_patient_id
    loop
      v_occurrence_date := public.compute_next_occurrence(
        v_last_active, v_schedule.recurrence_type, v_schedule.recurrence_days
      );
      if v_occurrence_date is null then continue; end if;

      while v_occurrence_date <= v_horizon_end loop
        insert into public.appointments (
          user_id, patient_id, type, weekday, start_time, duration_min,
          starts_on, ends_on, is_recurring, status
        ) values (
          v_patient.user_id, p_patient_id, 'session',
          v_schedule.weekday, v_schedule.start_time, v_schedule.duration_min,
          v_occurrence_date, v_occurrence_date, true, 'active'
        ) on conflict do nothing;

        if v_schedule.recurrence_type = 'once' then exit; end if;

        v_occurrence_date := public.compute_next_occurrence(
          v_occurrence_date, v_schedule.recurrence_type, v_schedule.recurrence_days
        );
        if v_occurrence_date is null then exit; end if;
      end loop;
    end loop;
    return;
  end if;

  raise exception 'Modo inválido: %', p_mode;
end;
$$;

alter function public.cancel_appointment_series(uuid, text, date, date, int)
  owner to postgres;

grant execute on function public.cancel_appointment_series(uuid, text, date, date, int)
  to authenticated;


-- ============================================================
-- 4) cancel_provider_appointment_series (nova: uuid, text, date, date, int)
-- ============================================================
create or replace function public.cancel_provider_appointment_series(
  p_provider_id uuid,
  p_mode text,
  p_from_date date default null,
  p_to_date date default null,
  p_renew_days int default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_provider public.providers;
  v_schedule record;
  v_weekday_offset int;
  v_occurrence_date date;
  v_horizon_end date;
  v_last_active date;
  v_renew_horizon int := coalesce(p_renew_days, 90);
begin
  select * into v_provider from public.providers where id = p_provider_id for update;
  if not found then raise exception 'Prestador não encontrado.'; end if;
  if v_provider.user_id <> auth.uid() then raise exception 'Sem permissão.'; end if;

  if v_renew_horizon < 1 or v_renew_horizon > 365 then
    raise exception 'p_renew_days deve estar entre 1 e 365.';
  end if;

  if p_mode = 'immediate' then
    update public.appointments set status = 'cancelled', updated_at = now()
    where provider_id = p_provider_id and starts_on >= current_date and status = 'active';
    delete from public.provider_schedules where provider_id = p_provider_id;
    return;
  end if;

  if p_mode = 'from_date' then
    if p_from_date is null then raise exception 'Data de início obrigatória.'; end if;
    update public.appointments set status = 'cancelled', updated_at = now()
    where provider_id = p_provider_id and starts_on >= p_from_date and status = 'active';
    return;
  end if;

  if p_mode = 'suspend' then
    if p_from_date is null or p_to_date is null then
      raise exception 'Datas de início e fim obrigatórias.';
    end if;
    if p_to_date < p_from_date then
      raise exception 'Data final deve ser posterior à inicial.';
    end if;

    update public.appointments set status = 'cancelled', updated_at = now()
    where provider_id = p_provider_id
      and starts_on between p_from_date and p_to_date
      and status = 'active';

    if not exists (
      select 1 from public.appointments
      where provider_id = p_provider_id and starts_on > p_to_date and status = 'active'
    ) then
      v_horizon_end := p_to_date + interval '90 days';

      for v_schedule in
        select weekday, start_time, duration_min, recurrence_type, recurrence_days
        from public.provider_schedules where provider_id = p_provider_id
      loop
        v_weekday_offset := (v_schedule.weekday - extract(dow from p_to_date)::int + 7) % 7;
        if v_weekday_offset = 0 then v_weekday_offset := 7; end if;
        v_occurrence_date := p_to_date + v_weekday_offset;

        while v_occurrence_date <= v_horizon_end loop
          insert into public.appointments (
            user_id, provider_id, type, weekday, start_time, duration_min,
            starts_on, ends_on, is_recurring, status, linked_expense
          ) values (
            v_provider.user_id, p_provider_id, 'personal',
            v_schedule.weekday, v_schedule.start_time, v_schedule.duration_min,
            v_occurrence_date, v_occurrence_date, true, 'active', true
          ) on conflict do nothing;

          if v_schedule.recurrence_type = 'once' then exit; end if;

          v_occurrence_date := public.compute_next_occurrence(
            v_occurrence_date, v_schedule.recurrence_type, v_schedule.recurrence_days
          );
          if v_occurrence_date is null then exit; end if;
        end loop;
      end loop;
    end if;
    return;
  end if;

  if p_mode = 'renew' then
    select max(starts_on) into v_last_active
    from public.appointments where provider_id = p_provider_id and status = 'active';

    if v_last_active is null then raise exception 'Não há série ativa para renovar.'; end if;

    v_horizon_end := v_last_active + (v_renew_horizon || ' days')::interval;

    for v_schedule in
      select weekday, start_time, duration_min, recurrence_type, recurrence_days
      from public.provider_schedules where provider_id = p_provider_id
    loop
      v_occurrence_date := public.compute_next_occurrence(
        v_last_active, v_schedule.recurrence_type, v_schedule.recurrence_days
      );
      if v_occurrence_date is null then continue; end if;

      while v_occurrence_date <= v_horizon_end loop
        insert into public.appointments (
          user_id, provider_id, type, weekday, start_time, duration_min,
          starts_on, ends_on, is_recurring, status, linked_expense
        ) values (
          v_provider.user_id, p_provider_id, 'personal',
          v_schedule.weekday, v_schedule.start_time, v_schedule.duration_min,
          v_occurrence_date, v_occurrence_date, true, 'active', true
        ) on conflict do nothing;

        if v_schedule.recurrence_type = 'once' then exit; end if;

        v_occurrence_date := public.compute_next_occurrence(
          v_occurrence_date, v_schedule.recurrence_type, v_schedule.recurrence_days
        );
        if v_occurrence_date is null then exit; end if;
      end loop;
    end loop;
    return;
  end if;

  raise exception 'Modo inválido: %', p_mode;
end;
$$;

alter function public.cancel_provider_appointment_series(uuid, text, date, date, int)
  owner to postgres;

grant execute on function public.cancel_provider_appointment_series(uuid, text, date, date, int)
  to authenticated;