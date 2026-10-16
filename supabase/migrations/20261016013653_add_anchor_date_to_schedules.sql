-- ============================================================
-- add_anchor_date_to_schedules
-- ============================================================
-- Adiciona anchor_date (data da primeira ocorrência) em
-- patient_schedules e provider_schedules, e corrige o cálculo de
-- 'monthly' pra respeitar o dia do mês da âncora.
--
-- Motivo: 'monthly' precisa saber QUAL dia do mês (ex: dia 17),
-- não só "+1 month" genérico. E 'once' precisa de uma data exata
-- (ex: 10/11/2026) em vez de "próximo weekday".
--
-- Também reescreve promote_prospect_to_active pra aceitar
-- recurrence_type/recurrence_days/anchor_date e chamar a versão
-- nova de set_patient_schedules (5 args).
-- ============================================================


-- ============================================================
-- 1) Coluna anchor_date em patient_schedules e provider_schedules
-- ============================================================
-- Nullable no banco (linhas antigas ficam null e o cálculo cai
-- no comportamento de weekday como antes). A RPC nova sempre
-- preenche.
alter table public.patient_schedules
  add column if not exists anchor_date date;

alter table public.provider_schedules
  add column if not exists anchor_date date;


-- ============================================================
-- 2) compute_next_occurrence (nova assinatura, com anchor_date)
-- ============================================================
-- DROP primeiro porque a assinatura mudou (adiciona 4º parâmetro).
drop function if exists public.compute_next_occurrence(date, text, int);

create or replace function public.compute_next_occurrence(
  p_current date,
  p_recurrence_type text,
  p_recurrence_days int default null,
  p_anchor_date date default null
)
returns date
language plpgsql
immutable
as $$
declare
  v_next_month_start date;
  v_last_day_of_next_month int;
  v_anchor_day int;
begin
  case p_recurrence_type
    when 'once' then
      return null;

    when 'weekly' then
      return p_current + interval '7 days';

    when 'biweekly' then
      return p_current + interval '14 days';

    when 'every_30_days' then
      return p_current + interval '30 days';

    when 'monthly' then
      if p_anchor_date is null then
        raise exception 'anchor_date é obrigatório para monthly';
      end if;

      v_anchor_day := extract(day from p_anchor_date)::int;
      v_next_month_start :=
        date_trunc('month', p_current)::date + interval '1 month';

      -- último dia do próximo mês
      v_last_day_of_next_month :=
        extract(
          day from (
            (date_trunc('month', p_current)::date + interval '2 months')
            - interval '1 day'
          )
        )::int;

      return make_date(
        extract(year from v_next_month_start)::int,
        extract(month from v_next_month_start)::int,
        least(v_anchor_day, v_last_day_of_next_month)
      );

    when 'custom_days' then
      if p_recurrence_days is null then
        raise exception 'recurrence_days é obrigatório para custom_days';
      end if;
      return p_current + (p_recurrence_days || ' days')::interval;

    else
      raise exception 'recurrence_type inválido: %', p_recurrence_type;
  end case;
end;
$$;

comment on function public.compute_next_occurrence(date, text, int, date) is
  'Calcula próxima data de uma série. NULL em ''once''. anchor_date preserva o dia do mês em ''monthly''.';


-- ============================================================
-- 3) set_patient_schedules (recriada, agora com anchor_date)
-- ============================================================
drop function if exists public.set_patient_schedules(uuid, jsonb, text, int, int);

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
  v_duration int;
  v_start_min int;
  v_end_min int;
  v_anchor_date date;
  v_today date := current_date;
  v_horizon_end date := current_date + (p_horizon_days || ' days')::interval;
  v_occurrence_date date;
  v_conflict_label text;
  v_first_date date;
begin
  select * into v_patient from public.patients where id = p_patient_id for update;
  if not found then raise exception 'Paciente não encontrado.'; end if;
  if v_patient.user_id <> auth.uid() then raise exception 'Sem permissão.'; end if;
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

  -- ============================================================
  -- Validação de conflito + leitura dos campos
  -- ============================================================
  for v_schedule in select * from jsonb_array_elements(p_schedules)
  loop
    -- anchorDate vem do front (YYYY-MM-DD). Se não vier, calcula a
    -- partir do weekday (compat).
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
    where a.user_id = v_patient.user_id
      and a.weekday = extract(dow from v_anchor_date)::int
      and a.status = 'active'
      and a.starts_on >= v_today
      and (a.patient_id is null or a.patient_id <> p_patient_id)
      and (extract(hour from a.start_time) * 60 + extract(minute from a.start_time)) < v_end_min
      and v_start_min < (extract(hour from a.start_time) * 60 + extract(minute from a.start_time) + a.duration_min)
    limit 1;

    if v_conflict_label is not null then
      raise exception 'O horário de % às % conflita com %.',
        to_char(v_anchor_date, 'DD/MM/YYYY'), v_start_time, v_conflict_label;
    end if;
  end loop;

  -- ============================================================
  -- Limpa e recria
  -- ============================================================
  delete from public.appointments
    where patient_id = p_patient_id and starts_on >= v_today;
  delete from public.patient_schedules where patient_id = p_patient_id;

  for v_schedule in select * from jsonb_array_elements(p_schedules)
  loop
    -- Recalcula anchor_date (mesmo cálculo de cima)
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

    insert into public.patient_schedules (
      user_id, patient_id, weekday, start_time, duration_min,
      recurrence_type, recurrence_days, anchor_date
    ) values (
      v_patient.user_id, p_patient_id, v_weekday, v_start_time, v_duration,
      p_recurrence_type, p_recurrence_days, v_anchor_date
    );

    v_occurrence_date := v_anchor_date;

    while v_occurrence_date <= v_horizon_end loop
      insert into public.appointments (
        user_id, patient_id, type, weekday, start_time, duration_min,
        starts_on, ends_on, is_recurring, status
      ) values (
        v_patient.user_id, p_patient_id, 'session',
        extract(dow from v_occurrence_date)::int,
        v_start_time, v_duration,
        v_occurrence_date, v_occurrence_date, true, 'active'
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
$$;

alter function public.set_patient_schedules(uuid, jsonb, text, int, int)
  owner to postgres;

grant execute on function public.set_patient_schedules(uuid, jsonb, text, int, int)
  to authenticated;


-- ============================================================
-- 4) set_provider_schedules (recriada, agora com anchor_date)
-- ============================================================
drop function if exists public.set_provider_schedules(uuid, jsonb, text, int, int);

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
$$;

alter function public.set_provider_schedules(uuid, jsonb, text, int, int)
  owner to postgres;

grant execute on function public.set_provider_schedules(uuid, jsonb, text, int, int)
  to authenticated;


-- ============================================================
-- 5) cancel_appointment_series (recriada, usa anchor_date em suspend/renew)
-- ============================================================
drop function if exists public.cancel_appointment_series(uuid, text, date, date, int);

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
  v_occurrence_date date;
  v_horizon_end date;
  v_last_active date;
  v_renew_horizon int := coalesce(p_renew_days, 90);
  v_anchor date;
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
        select weekday, start_time, duration_min, recurrence_type, recurrence_days, anchor_date
        from public.patient_schedules where patient_id = p_patient_id
      loop
        v_anchor := coalesce(v_schedule.anchor_date, p_to_date);

        -- Primeira ocorrência após p_to_date
        v_occurrence_date := p_to_date + interval '1 day';

        while v_occurrence_date <= v_horizon_end loop
          insert into public.appointments (
            user_id, patient_id, type, weekday, start_time, duration_min,
            starts_on, ends_on, is_recurring, status
          ) values (
            v_patient.user_id, p_patient_id, 'session',
            extract(dow from v_occurrence_date)::int,
            v_schedule.start_time, v_schedule.duration_min,
            v_occurrence_date, v_occurrence_date, true, 'active'
          ) on conflict do nothing;

          if v_schedule.recurrence_type = 'once' then exit; end if;

          v_occurrence_date := public.compute_next_occurrence(
            v_occurrence_date, v_schedule.recurrence_type,
            v_schedule.recurrence_days, v_anchor
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
      select weekday, start_time, duration_min, recurrence_type, recurrence_days, anchor_date
      from public.patient_schedules where patient_id = p_patient_id
    loop
      v_anchor := coalesce(v_schedule.anchor_date, v_last_active);

      v_occurrence_date := public.compute_next_occurrence(
        v_last_active, v_schedule.recurrence_type,
        v_schedule.recurrence_days, v_anchor
      );
      if v_occurrence_date is null then continue; end if;

      while v_occurrence_date <= v_horizon_end loop
        insert into public.appointments (
          user_id, patient_id, type, weekday, start_time, duration_min,
          starts_on, ends_on, is_recurring, status
        ) values (
          v_patient.user_id, p_patient_id, 'session',
          extract(dow from v_occurrence_date)::int,
          v_schedule.start_time, v_schedule.duration_min,
          v_occurrence_date, v_occurrence_date, true, 'active'
        ) on conflict do nothing;

        if v_schedule.recurrence_type = 'once' then exit; end if;

        v_occurrence_date := public.compute_next_occurrence(
          v_occurrence_date, v_schedule.recurrence_type,
          v_schedule.recurrence_days, v_anchor
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
-- 6) cancel_provider_appointment_series (idem)
-- ============================================================
drop function if exists public.cancel_provider_appointment_series(uuid, text, date, date, int);

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
  v_occurrence_date date;
  v_horizon_end date;
  v_last_active date;
  v_renew_horizon int := coalesce(p_renew_days, 90);
  v_anchor date;
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
        select weekday, start_time, duration_min, recurrence_type, recurrence_days, anchor_date
        from public.provider_schedules where provider_id = p_provider_id
      loop
        v_anchor := coalesce(v_schedule.anchor_date, p_to_date);
        v_occurrence_date := p_to_date + interval '1 day';

        while v_occurrence_date <= v_horizon_end loop
          insert into public.appointments (
            user_id, provider_id, type, weekday, start_time, duration_min,
            starts_on, ends_on, is_recurring, status, linked_expense
          ) values (
            v_provider.user_id, p_provider_id, 'personal',
            extract(dow from v_occurrence_date)::int,
            v_schedule.start_time, v_schedule.duration_min,
            v_occurrence_date, v_occurrence_date, true, 'active', true
          ) on conflict do nothing;

          if v_schedule.recurrence_type = 'once' then exit; end if;

          v_occurrence_date := public.compute_next_occurrence(
            v_occurrence_date, v_schedule.recurrence_type,
            v_schedule.recurrence_days, v_anchor
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
      select weekday, start_time, duration_min, recurrence_type, recurrence_days, anchor_date
      from public.provider_schedules where provider_id = p_provider_id
    loop
      v_anchor := coalesce(v_schedule.anchor_date, v_last_active);

      v_occurrence_date := public.compute_next_occurrence(
        v_last_active, v_schedule.recurrence_type,
        v_schedule.recurrence_days, v_anchor
      );
      if v_occurrence_date is null then continue; end if;

      while v_occurrence_date <= v_horizon_end loop
        insert into public.appointments (
          user_id, provider_id, type, weekday, start_time, duration_min,
          starts_on, ends_on, is_recurring, status, linked_expense
        ) values (
          v_provider.user_id, p_provider_id, 'personal',
          extract(dow from v_occurrence_date)::int,
          v_schedule.start_time, v_schedule.duration_min,
          v_occurrence_date, v_occurrence_date, true, 'active', true
        ) on conflict do nothing;

        if v_schedule.recurrence_type = 'once' then exit; end if;

        v_occurrence_date := public.compute_next_occurrence(
          v_occurrence_date, v_schedule.recurrence_type,
          v_schedule.recurrence_days, v_anchor
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


-- ============================================================
-- 7) promote_prospect_to_active (reescrita com recorrência)
-- ============================================================
-- A versão antiga chamava set_patient_schedules(uuid, jsonb). Agora
-- ela precisa passar recurrence_type/recurrence_days/anchor_date.
--
-- Como o PatientReview ainda não está atualizado pra enviar isso,
-- aceitamos parâmetros opcionais com default 'weekly'.
-- ============================================================
drop function if exists public.promote_prospect_to_active(uuid, jsonb);

create or replace function public.promote_prospect_to_active(
  p_patient_id uuid,
  p_schedules jsonb,
  p_recurrence_type text default 'weekly',
  p_recurrence_days int default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.patients
    set status = 'active', updated_at = now()
  where id = p_patient_id and user_id = auth.uid();

  if not found then
    raise exception 'Paciente não encontrado ou sem permissão.';
  end if;

  if p_schedules is not null and jsonb_array_length(p_schedules) > 0 then
    perform public.set_patient_schedules(
      p_patient_id,
      p_schedules,
      p_recurrence_type,
      p_recurrence_days
    );
  end if;
end;
$$;

alter function public.promote_prospect_to_active(uuid, jsonb, text, int)
  owner to postgres;

grant execute on function public.promote_prospect_to_active(uuid, jsonb, text, int)
  to authenticated;