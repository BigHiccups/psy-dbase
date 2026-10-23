revoke delete on table "public"."dismissed_suggestions" from "anon";

revoke insert on table "public"."dismissed_suggestions" from "anon";

revoke select on table "public"."dismissed_suggestions" from "anon";

revoke update on table "public"."dismissed_suggestions" from "anon";

revoke delete on table "public"."provider_billings" from "anon";

revoke insert on table "public"."provider_billings" from "anon";

revoke select on table "public"."provider_billings" from "anon";

revoke update on table "public"."provider_billings" from "anon";

revoke delete on table "public"."provider_billings" from "service_role";

revoke insert on table "public"."provider_billings" from "service_role";

revoke select on table "public"."provider_billings" from "service_role";

revoke update on table "public"."provider_billings" from "service_role";

revoke delete on table "public"."transactions" from "anon";

revoke insert on table "public"."transactions" from "anon";

revoke select on table "public"."transactions" from "anon";

revoke update on table "public"."transactions" from "anon";

alter table "public"."appointments" drop constraint "appointments_cancelled_by_block_id_fkey";

alter table "public"."appointments" drop constraint "appointments_duration_min_check";

alter table "public"."patient_schedules" drop constraint "patient_schedules_recurrence_type_check";

drop function if exists "public"."bulk_import_google_calendar"(p_events jsonb);

alter table "public"."appointments" alter column "duration_min" set not null;

alter table "public"."appointments" alter column "start_time" set not null;

alter table "public"."appointments" add constraint "appointments_duration_min_check" CHECK ((((type = 'blocked'::text) AND (duration_min >= 1)) OR ((type <> 'blocked'::text) AND (duration_min >= 15) AND (duration_min <= 240)))) not valid;

alter table "public"."appointments" validate constraint "appointments_duration_min_check";

alter table "public"."patient_schedules" add constraint "patient_schedules_recurrence_type_check" CHECK ((recurrence_type = ANY (ARRAY['once'::text, 'weekly'::text, 'biweekly'::text, 'monthly'::text, 'every_30_days'::text, 'custom_days'::text]))) not valid;

alter table "public"."patient_schedules" validate constraint "patient_schedules_recurrence_type_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.bulk_import_google_calendar(p_user_id uuid, p_events jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_event jsonb;
  v_patient_id uuid;
  v_recurring_id text;
  v_raw_name text;
  v_start_time time;
  v_weekday int;
  v_anchor_date date;
  v_duration int;
  v_inserted_count int := 0;
BEGIN
  FOR v_event IN SELECT * FROM jsonb_array_elements(p_events)
  LOOP
    v_recurring_id := v_event->>'recurringId';
    v_raw_name := v_event->>'rawName';
    v_start_time := (v_event->>'startTime')::time;
    v_weekday := (v_event->>'weekday')::int;
    v_anchor_date := (v_event->>'anchorDate')::date;
    v_duration := (v_event->>'durationMin')::int;

    -- 1. Tenta achar o paciente pelo ID da recorrência ou pelo nome
    SELECT id INTO v_patient_id 
    FROM public.patients 
    WHERE user_id = p_user_id 
      AND (
        (google_recurring_event_id = v_recurring_id AND v_recurring_id IS NOT NULL)
        OR 
        (full_name = v_raw_name)
      )
    LIMIT 1;

    -- 2. Se não achar, cria o paciente como PROSPECT
    IF v_patient_id IS NULL THEN
      INSERT INTO public.patients (user_id, full_name, status, google_recurring_event_id)
      VALUES (p_user_id, v_raw_name, 'prospect', v_recurring_id)
      RETURNING id INTO v_patient_id;
      
      -- Salva a memória do Google
      IF v_recurring_id IS NOT NULL THEN
        INSERT INTO public.google_imported_recurrences (user_id, google_recurring_event_id, target_type, target_id)
        VALUES (p_user_id, v_recurring_id, 'patient', v_patient_id)
        ON CONFLICT (user_id, google_recurring_event_id) DO UPDATE SET target_id = EXCLUDED.target_id;
      END IF;
    END IF;

    -- 3. Salva o horário no Schedule do paciente (sem criar agenda)
    IF v_patient_id IS NOT NULL THEN
      INSERT INTO public.patient_schedules (
        user_id, patient_id, weekday, start_time, duration_min, recurrence_type, anchor_date
      ) VALUES (
        p_user_id, v_patient_id, v_weekday, v_start_time, v_duration, 'weekly', v_anchor_date
      ) 
      ON CONFLICT (patient_id, weekday, start_time) DO NOTHING;
      
      v_inserted_count := v_inserted_count + 1;
    END IF;
  END LOOP;

  RETURN v_inserted_count;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.compute_next_occurrence(p_current date, p_recurrence_type text, p_recurrence_days integer DEFAULT NULL::integer, p_anchor_date date DEFAULT NULL::date)
 RETURNS date
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.merge_prospect_into_patient(p_prospect_id uuid, p_existing_patient_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_prospect public.patients;
  v_occurrence_date date;
  v_horizon_end date := current_date + interval '90 days';
  v_anchor date;
  v_weekday int;
BEGIN
  SELECT * INTO v_prospect FROM public.patients WHERE id = p_prospect_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Prospect não encontrado.'; END IF;
  IF v_prospect.user_id <> auth.uid() THEN RAISE EXCEPTION 'Sem permissão.'; END IF;

  -- Move os horários
  UPDATE public.patient_schedules SET patient_id = p_existing_patient_id WHERE patient_id = p_prospect_id;

  -- Gera a agenda forçadamente (sem olhar o frontend)
  SELECT public.set_patient_schedules(
    p_existing_patient_id,
    (SELECT jsonb_agg(jsonb_build_object(
      'weekday', weekday, 
      'startTime', to_char(start_time, 'HH24:MI'), 
      'durationMin', duration_min,
      'anchorDate', coalesce(anchor_date, current_date)
    )) FROM public.patient_schedules WHERE patient_id = p_existing_patient_id),
    'weekly',
    null
  );

  -- Move eventuais agendamentos e apaga o provisório
  UPDATE public.appointments SET patient_id = p_existing_patient_id WHERE patient_id = p_prospect_id;
  UPDATE public.google_imported_recurrences SET target_id = p_existing_patient_id WHERE target_type = 'patient' AND target_id = p_prospect_id;
  DELETE FROM public.patients WHERE id = p_prospect_id;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.promote_prospect_to_active(p_patient_id uuid, p_schedules jsonb DEFAULT NULL::jsonb, p_recurrence_type text DEFAULT 'weekly'::text, p_recurrence_days integer DEFAULT NULL::integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_has_saved_schedules boolean;
BEGIN
  -- Muda o status para ativo
  UPDATE public.patients
    SET status = 'active', updated_at = now()
  WHERE id = p_patient_id AND user_id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Paciente não encontrado ou sem permissão.';
  END IF;

  -- Se o frontend mandou horários, usa eles
  IF p_schedules IS NOT NULL AND jsonb_array_length(p_schedules) > 0 THEN
    PERFORM public.set_patient_schedules(
      p_patient_id, p_schedules, p_recurrence_type, p_recurrence_days
    );
  ELSE
    -- SE O FRONTEND MANDOU VAZIO, O BANCO LÊ O QUE FOI IMPORTADO
    SELECT EXISTS(SELECT 1 FROM public.patient_schedules WHERE patient_id = p_patient_id) INTO v_has_saved_schedules;
    
    IF v_has_saved_schedules THEN
      PERFORM public.set_patient_schedules(
        p_patient_id,
        (SELECT jsonb_agg(jsonb_build_object(
          'weekday', weekday, 
          'startTime', to_char(start_time, 'HH24:MI'), 
          'durationMin', duration_min,
          'anchorDate', coalesce(anchor_date, current_date)
        )) FROM public.patient_schedules WHERE patient_id = p_patient_id),
        'weekly',
        null
      );
    END IF;
  END IF;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.set_patient_schedules(p_patient_id uuid, p_schedules jsonb, p_recurrence_type text, p_recurrence_days integer, p_horizon_days integer DEFAULT 90)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
begin
  select * into v_patient from public.patients where id = p_patient_id for update;
  if not found then raise exception 'Paciente não encontrado.'; end if;
  if v_patient.user_id <> auth.uid() then raise exception 'Sem permissão.'; end if;
  if p_schedules is null or jsonb_array_length(p_schedules) = 0 then raise exception 'Informe pelo menos um horário.'; end if;

  for v_schedule in select * from jsonb_array_elements(p_schedules) loop
    if v_schedule ? 'anchorDate' and (v_schedule->>'anchorDate') is not null then
      v_anchor_date := (v_schedule->>'anchorDate')::date;
    else
      v_weekday := (v_schedule->>'weekday')::int;
      v_anchor_date := v_today + ((v_weekday - extract(dow from v_today)::int + 7) % 7);
    end if;

    -- AQUI: NÃO TEM MAIS A TRAVA DE DATA PASSADA!

    v_start_time := (v_schedule->>'startTime')::time;
    v_duration := coalesce((v_schedule->>'durationMin')::int, 50);
    v_start_min := extract(hour from v_start_time) * 60 + extract(minute from v_start_time);
    v_end_min := v_start_min + v_duration;

    select coalesce(p.full_name, pr.display_name, 'compromisso pessoal') into v_conflict_label
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
      raise exception 'O horário de % às % conflita com %.', to_char(v_anchor_date, 'DD/MM/YYYY'), v_start_time, v_conflict_label;
    end if;
  end loop;

  -- Limpa e recria
  delete from public.appointments where patient_id = p_patient_id and starts_on >= v_today;
  delete from public.patient_schedules where patient_id = p_patient_id;

  for v_schedule in select * from jsonb_array_elements(p_schedules) loop
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
$function$
;


