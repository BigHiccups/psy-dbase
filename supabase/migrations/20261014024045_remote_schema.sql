


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."approve_submission"("p_submission_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_sub public.patient_form_submissions;
  v_patient_id uuid;
begin
  select * into v_sub from public.patient_form_submissions
  where id = p_submission_id
  for update;

  if not found then raise exception 'Submissão não encontrada.'; end if;
  if v_sub.user_id <> auth.uid() then raise exception 'Sem permissão.'; end if;
  if v_sub.status <> 'pending' then raise exception 'Submissão já foi revisada.'; end if;

  insert into public.patients (
    user_id, full_name, cpf, city, birth_date, phone,
    emergency_contact_name, emergency_contact_phone,
    status
  ) values (
    v_sub.user_id, v_sub.full_name, v_sub.cpf, v_sub.city, v_sub.birth_date, v_sub.phone,
    v_sub.emergency_contact_name, v_sub.emergency_contact_phone,
    'prospect'
  ) returning id into v_patient_id;

  update public.patient_form_submissions
  set status = 'approved', reviewed_at = now()
  where id = p_submission_id;

  return v_patient_id;
end;
$$;


ALTER FUNCTION "public"."approve_submission"("p_submission_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_appointment_series"("p_patient_id" "uuid", "p_mode" "text", "p_from_date" "date" DEFAULT NULL::"date", "p_to_date" "date" DEFAULT NULL::"date") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_patient public.patients;
  v_schedule record;
  v_weekday_offset int;
  v_occurrence_date date;
  v_horizon_end date;
  v_last_active date;
begin
  select * into v_patient from public.patients where id = p_patient_id for update;
  if not found then raise exception 'Paciente não encontrado.'; end if;
  if v_patient.user_id <> auth.uid() then raise exception 'Sem permissão.'; end if;

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
    where patient_id = p_patient_id and starts_on between p_from_date and p_to_date and status = 'active';

    if not exists (
      select 1 from public.appointments
      where patient_id = p_patient_id and starts_on > p_to_date and status = 'active'
    ) then
      v_horizon_end := p_to_date + interval '90 days';

      for v_schedule in
        select weekday, start_time, duration_min
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

          v_occurrence_date := v_occurrence_date + interval '7 days';
        end loop;
      end loop;
    end if;
    return;
  end if;

  if p_mode = 'renew' then
    select max(starts_on) into v_last_active
    from public.appointments where patient_id = p_patient_id and status = 'active';

    if v_last_active is null then raise exception 'Não há série ativa para renovar.'; end if;
    v_horizon_end := v_last_active + interval '90 days';

    for v_schedule in
      select weekday, start_time, duration_min
      from public.patient_schedules where patient_id = p_patient_id
    loop
      v_occurrence_date := v_last_active + interval '7 days';

      while v_occurrence_date <= v_horizon_end loop
        insert into public.appointments (
          user_id, patient_id, type, weekday, start_time, duration_min,
          starts_on, ends_on, is_recurring, status
        ) values (
          v_patient.user_id, p_patient_id, 'session',
          v_schedule.weekday, v_schedule.start_time, v_schedule.duration_min,
          v_occurrence_date, v_occurrence_date, true, 'active'
        ) on conflict do nothing;

        v_occurrence_date := v_occurrence_date + interval '7 days';
      end loop;
    end loop;
    return;
  end if;

  raise exception 'Modo inválido: %', p_mode;
end;
$$;


ALTER FUNCTION "public"."cancel_appointment_series"("p_patient_id" "uuid", "p_mode" "text", "p_from_date" "date", "p_to_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_future_appointments"("p_patient_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_patient public.patients;
begin
  select * into v_patient
  from public.patients
  where id = p_patient_id;

  if not found then
    raise exception 'Paciente não encontrado.';
  end if;

  if v_patient.user_id <> auth.uid() then
    raise exception 'Sem permissão.';
  end if;

  update public.appointments
  set status = 'cancelled', updated_at = now()
  where patient_id = p_patient_id
    and starts_on >= current_date
    and status = 'active';
end;
$$;


ALTER FUNCTION "public"."cancel_future_appointments"("p_patient_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_provider_appointment_series"("p_provider_id" "uuid", "p_mode" "text", "p_from_date" "date" DEFAULT NULL::"date", "p_to_date" "date" DEFAULT NULL::"date") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_provider public.providers;
  v_schedule record;
  v_weekday_offset int;
  v_occurrence_date date;
  v_horizon_end date;
  v_last_active date;
begin
  select * into v_provider from public.providers where id = p_provider_id for update;
  if not found then raise exception 'Prestador não encontrado.'; end if;
  if v_provider.user_id <> auth.uid() then raise exception 'Sem permissão.'; end if;

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
    -- NÃO deleta provider_schedules: mantém como referência
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
    where provider_id = p_provider_id and starts_on between p_from_date and p_to_date and status = 'active';

    if not exists (
      select 1 from public.appointments
      where provider_id = p_provider_id and starts_on > p_to_date and status = 'active'
    ) then
      v_horizon_end := p_to_date + interval '90 days';

      for v_schedule in
        select weekday, start_time, duration_min
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

          v_occurrence_date := v_occurrence_date + interval '7 days';
        end loop;
      end loop;
    end if;
    return;
  end if;

  if p_mode = 'renew' then
    select max(starts_on) into v_last_active
    from public.appointments where provider_id = p_provider_id and status = 'active';

    if v_last_active is null then raise exception 'Não há série ativa para renovar.'; end if;
    v_horizon_end := v_last_active + interval '90 days';

    for v_schedule in
      select weekday, start_time, duration_min
      from public.provider_schedules where provider_id = p_provider_id
    loop
      v_occurrence_date := v_last_active + interval '7 days';

      while v_occurrence_date <= v_horizon_end loop
        insert into public.appointments (
          user_id, provider_id, type, weekday, start_time, duration_min,
          starts_on, ends_on, is_recurring, status, linked_expense
        ) values (
          v_provider.user_id, p_provider_id, 'personal',
          v_schedule.weekday, v_schedule.start_time, v_schedule.duration_min,
          v_occurrence_date, v_occurrence_date, true, 'active', true
        ) on conflict do nothing;

        v_occurrence_date := v_occurrence_date + interval '7 days';
      end loop;
    end loop;
    return;
  end if;

  raise exception 'Modo inválido: %', p_mode;
end;
$$;


ALTER FUNCTION "public"."cancel_provider_appointment_series"("p_provider_id" "uuid", "p_mode" "text", "p_from_date" "date", "p_to_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_provider_future_appointments"("p_provider_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_provider public.providers;
begin
  select * into v_provider
  from public.providers
  where id = p_provider_id;

  if not found then
    raise exception 'Prestador não encontrado.';
  end if;

  if v_provider.user_id <> auth.uid() then
    raise exception 'Sem permissão.';
  end if;

  update public.appointments
  set status = 'cancelled', updated_at = now()
  where provider_id = p_provider_id
    and starts_on >= current_date
    and status = 'active';
end;
$$;


ALTER FUNCTION "public"."cancel_provider_future_appointments"("p_provider_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."convert_prospect_to_provider"("p_patient_id" "uuid", "p_kind" "text" DEFAULT 'person'::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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

  update public.appointments
  set
    type = 'personal',
    provider_id = v_provider_id,
    patient_id = null,
    linked_expense = true
  where patient_id = p_patient_id;

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


ALTER FUNCTION "public"."convert_prospect_to_provider"("p_patient_id" "uuid", "p_kind" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_cancelled_appointments"("p_date" "date") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_count integer;
begin
  delete from public.appointments
  where user_id = auth.uid()
    and status = 'cancelled'
    and starts_on = p_date;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;


ALTER FUNCTION "public"."delete_cancelled_appointments"("p_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_patient"("p_patient_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_patient public.patients;
begin
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

  -- 1. Deleta appointments
  delete from public.appointments where patient_id = p_patient_id;

  -- 2. Deleta patient_schedules
  delete from public.patient_schedules where patient_id = p_patient_id;

  -- 3. Deleta submissões vinculadas (busca por nome — não temos FK direta)
  -- (opcional; se preferir manter histórico, comenta esta linha)
  -- delete from public.patient_form_submissions
  -- where user_id = v_patient.user_id and full_name = v_patient.full_name;

  -- 4. Deleta o patient
  delete from public.patients where id = p_patient_id;
end;
$$;


ALTER FUNCTION "public"."delete_patient"("p_patient_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_provider"("p_provider_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_provider public.providers;
begin
  select * into v_provider
  from public.providers
  where id = p_provider_id
  for update;

  if not found then
    raise exception 'Prestador não encontrado.';
  end if;

  if v_provider.user_id <> auth.uid() then
    raise exception 'Sem permissão.';
  end if;

  delete from public.appointments where provider_id = p_provider_id;
  delete from public.provider_schedules where provider_id = p_provider_id;

  delete from public.providers where id = p_provider_id;
end;
$$;


ALTER FUNCTION "public"."delete_provider"("p_provider_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."discard_prospect"("p_patient_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_patient public.patients;
begin
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
    raise exception 'Só é possível descartar pacientes em revisão.';
  end if;

  delete from public.appointments where patient_id = p_patient_id;

  if v_patient.google_recurring_event_id is not null then
    delete from public.google_imported_recurrences
    where user_id = v_patient.user_id
      and google_recurring_event_id = v_patient.google_recurring_event_id;
  end if;

  delete from public.patients where id = p_patient_id;
end;
$$;


ALTER FUNCTION "public"."discard_prospect"("p_patient_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_invite_by_token"("p_token" "uuid") RETURNS TABLE("valid" boolean, "reason" "text", "patient_name_hint" "text", "schedules" "jsonb")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_invite public.patient_invites;
  v_schedules jsonb;
begin
  select * into v_invite
  from public.patient_invites
  where token = p_token;

  if not found then
    return query select false, 'Convite inválido.'::text, null::text, '[]'::jsonb;
    return;
  end if;

  if v_invite.used_at is not null then
    return query select false, 'Este convite já foi utilizado.'::text, null::text, '[]'::jsonb;
    return;
  end if;

  if v_invite.expires_at < now() then
    return query select false, 'Este convite expirou.'::text, null::text, '[]'::jsonb;
    return;
  end if;

  -- Agrega os horários em JSON
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'weekday', s.weekday,
      'startTime', to_char(s.start_time, 'HH24:MI'),
      'durationMin', s.duration_min
    ) order by s.weekday, s.start_time
  ), '[]'::jsonb)
  into v_schedules
  from public.patient_invite_schedules s
  where s.invite_id = v_invite.id;

  return query select true, null::text, v_invite.patient_name_hint, v_schedules;
end;
$$;


ALTER FUNCTION "public"."get_invite_by_token"("p_token" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.profiles (id, email, full_name, avatar_url)
  values (
    new.id,
    new.email,
    new.raw_user_meta_data->>'full_name',
    new.raw_user_meta_data->>'avatar_url'
  );
  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."promote_prospect_to_active"("p_patient_id" "uuid", "p_schedules" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_patient public.patients;
begin
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
    raise exception 'Paciente não está em revisão.';
  end if;

  update public.patients
  set status = 'active', updated_at = now()
  where id = p_patient_id;

  -- Se schedules foram passados, cria-os (e gera appointments)
  if p_schedules is not null and jsonb_array_length(p_schedules) > 0 then
    perform public.set_patient_schedules(p_patient_id, p_schedules);
  end if;
end;
$$;


ALTER FUNCTION "public"."promote_prospect_to_active"("p_patient_id" "uuid", "p_schedules" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reactivate_appointment"("p_appointment_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_appt public.appointments;
  v_conflict_label text;
begin
  select * into v_appt
  from public.appointments
  where id = p_appointment_id
  for update;

  if not found then
    raise exception 'Agendamento não encontrado.';
  end if;

  if v_appt.user_id <> auth.uid() then
    raise exception 'Sem permissão.';
  end if;

  if v_appt.status <> 'cancelled' then
    raise exception 'Só é possível reativar agendamentos cancelados.';
  end if;

  -- Verifica se o slot está livre (considerando o próprio appointment)
  select coalesce(p.full_name, pr.display_name, 'compromisso pessoal')
    into v_conflict_label
  from public.appointments a
  left join public.patients p on p.id = a.patient_id
  left join public.providers pr on pr.id = a.provider_id
  where a.user_id = v_appt.user_id
    and a.weekday = v_appt.weekday
    and a.start_time = v_appt.start_time
    and a.starts_on = v_appt.starts_on
    and a.status = 'active'
    and a.id <> p_appointment_id
  limit 1;

  if v_conflict_label is not null then
    raise exception 'O horário de % às % já está ocupado por %.',
      v_appt.weekday, v_appt.start_time, v_conflict_label;
  end if;

  update public.appointments
  set status = 'active', updated_at = now()
  where id = p_appointment_id;
end;
$$;


ALTER FUNCTION "public"."reactivate_appointment"("p_appointment_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_patient_schedules"("p_patient_id" "uuid", "p_schedules" "jsonb", "p_horizon_days" integer DEFAULT 90) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
  select * into v_patient from public.patients where id = p_patient_id for update;
  if not found then raise exception 'Paciente não encontrado.'; end if;
  if v_patient.user_id <> auth.uid() then raise exception 'Sem permissão.'; end if;
  if p_schedules is null or jsonb_array_length(p_schedules) = 0 then
    raise exception 'Informe pelo menos um horário.';
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

  delete from public.appointments where patient_id = p_patient_id and starts_on >= v_today;
  delete from public.patient_schedules where patient_id = p_patient_id;

  for v_schedule in select * from jsonb_array_elements(p_schedules)
  loop
    v_weekday := (v_schedule->>'weekday')::int;
    v_start_time := (v_schedule->>'startTime')::time;
    v_duration := coalesce((v_schedule->>'durationMin')::int, 50);

    if v_weekday < 0 or v_weekday > 6 then raise exception 'Dia inválido: %', v_weekday; end if;
    if v_duration < 15 or v_duration > 240 then raise exception 'Duração inválida: %', v_duration; end if;

    insert into public.patient_schedules (
      user_id, patient_id, weekday, start_time, duration_min
    ) values (
      v_patient.user_id, p_patient_id, v_weekday, v_start_time, v_duration
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

      v_occurrence_date := v_occurrence_date + interval '7 days';
    end loop;
  end loop;
end;
$$;


ALTER FUNCTION "public"."set_patient_schedules"("p_patient_id" "uuid", "p_schedules" "jsonb", "p_horizon_days" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_provider_schedules"("p_provider_id" "uuid", "p_schedules" "jsonb", "p_horizon_days" integer DEFAULT 90) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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

  delete from public.appointments where provider_id = p_provider_id and starts_on >= v_today;
  delete from public.provider_schedules where provider_id = p_provider_id;

  for v_schedule in select * from jsonb_array_elements(p_schedules)
  loop
    v_weekday := (v_schedule->>'weekday')::int;
    v_start_time := (v_schedule->>'startTime')::time;
    v_duration := coalesce((v_schedule->>'durationMin')::int, 50);

    if v_weekday < 0 or v_weekday > 6 then raise exception 'Dia inválido: %', v_weekday; end if;
    if v_duration < 15 or v_duration > 240 then raise exception 'Duração inválida: %', v_duration; end if;

    insert into public.provider_schedules (
      user_id, provider_id, weekday, start_time, duration_min
    ) values (
      v_provider.user_id, p_provider_id, v_weekday, v_start_time, v_duration
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

      v_occurrence_date := v_occurrence_date + interval '7 days';
    end loop;
  end loop;
end;
$$;


ALTER FUNCTION "public"."set_provider_schedules"("p_provider_id" "uuid", "p_schedules" "jsonb", "p_horizon_days" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_patient_form"("p_token" "uuid", "p_full_name" "text", "p_cpf" "text", "p_city" "text", "p_birth_date" "date", "p_phone" "text", "p_emergency_contact_name" "text", "p_emergency_contact_phone" "text", "p_consent_accepted" boolean, "p_place_acknowledged" boolean) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_invite public.patient_invites;
  v_submission_id uuid;
begin
  select * into v_invite from public.patient_invites where token = p_token for update;

  if not found then raise exception 'Convite inválido.'; end if;
  if v_invite.used_at is not null then raise exception 'Este convite já foi utilizado.'; end if;
  if v_invite.expires_at < now() then raise exception 'Este convite expirou.'; end if;

  -- Validações de campos obrigatórios (espelham o frontend)
  if p_full_name is null or trim(p_full_name) = '' then
    raise exception 'Nome completo é obrigatório.';
  end if;
  if p_city is null or trim(p_city) = '' then
    raise exception 'Cidade é obrigatória.';
  end if;
  if p_birth_date is null then
    raise exception 'Data de nascimento é obrigatória.';
  end if;
  if p_phone is null or trim(p_phone) = '' then
    raise exception 'Telefone é obrigatório.';
  end if;

  if not p_consent_accepted then
    raise exception 'O termo de confidencialidade precisa ser aceito.';
  end if;
  if not p_place_acknowledged then
    raise exception 'A orientação sobre o local precisa ser confirmada.';
  end if;

  insert into public.patient_form_submissions (
    invite_id, user_id, full_name, cpf, city, birth_date, phone,
    emergency_contact_name, emergency_contact_phone,
    consent_accepted, consent_accepted_at,
    place_acknowledged, place_acknowledged_at
  ) values (
    v_invite.id, v_invite.user_id, p_full_name, p_cpf, p_city, p_birth_date, p_phone,
    p_emergency_contact_name, p_emergency_contact_phone,
    true, now(),
    true, now()
  ) returning id into v_submission_id;

  update public.patient_invites set used_at = now() where id = v_invite.id;

  return v_submission_id;
end;
$$;


ALTER FUNCTION "public"."submit_patient_form"("p_token" "uuid", "p_full_name" "text", "p_cpf" "text", "p_city" "text", "p_birth_date" "date", "p_phone" "text", "p_emergency_contact_name" "text", "p_emergency_contact_phone" "text", "p_consent_accepted" boolean, "p_place_acknowledged" boolean) OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."appointments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "patient_id" "uuid",
    "type" "text" DEFAULT 'session'::"text" NOT NULL,
    "weekday" integer NOT NULL,
    "start_time" time without time zone NOT NULL,
    "duration_min" integer DEFAULT 50 NOT NULL,
    "starts_on" "date" NOT NULL,
    "ends_on" "date" NOT NULL,
    "is_recurring" boolean DEFAULT true NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "google_event_id" "text",
    "linked_expense" boolean DEFAULT false NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "provider_id" "uuid",
    CONSTRAINT "appointments_duration_min_check" CHECK ((("duration_min" >= 15) AND ("duration_min" <= 240))),
    CONSTRAINT "appointments_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'cancelled'::"text", 'completed'::"text"]))),
    CONSTRAINT "appointments_subject_check" CHECK (((("type" = 'session'::"text") AND ("patient_id" IS NOT NULL) AND ("provider_id" IS NULL)) OR (("type" = 'personal'::"text") AND ("patient_id" IS NULL) AND ("provider_id" IS NOT NULL)) OR (("type" = 'blocked'::"text") AND ("patient_id" IS NULL) AND ("provider_id" IS NULL)) OR (("type" = 'due'::"text") AND ("patient_id" IS NULL) AND ("provider_id" IS NOT NULL)))),
    CONSTRAINT "appointments_type_check" CHECK (("type" = ANY (ARRAY['session'::"text", 'personal'::"text", 'blocked'::"text", 'due'::"text"]))),
    CONSTRAINT "appointments_weekday_check" CHECK ((("weekday" >= 0) AND ("weekday" <= 6)))
);


ALTER TABLE "public"."appointments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."google_credentials" (
    "user_id" "uuid" NOT NULL,
    "refresh_token" "text" NOT NULL,
    "access_token" "text",
    "expires_at" timestamp with time zone,
    "scope" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."google_credentials" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."google_imported_recurrences" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "google_recurring_event_id" "text" NOT NULL,
    "target_type" "text" NOT NULL,
    "target_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "google_imported_recurrences_target_type_check" CHECK (("target_type" = ANY (ARRAY['patient'::"text", 'provider'::"text"])))
);


ALTER TABLE "public"."google_imported_recurrences" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."patient_form_submissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "invite_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "full_name" "text" NOT NULL,
    "cpf" "text",
    "city" "text",
    "birth_date" "date",
    "phone" "text",
    "emergency_contact_name" "text",
    "emergency_contact_phone" "text",
    "consent_accepted" boolean DEFAULT false NOT NULL,
    "consent_accepted_at" timestamp with time zone,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "reviewed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "place_acknowledged" boolean DEFAULT false NOT NULL,
    "place_acknowledged_at" timestamp with time zone,
    CONSTRAINT "patient_form_submissions_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."patient_form_submissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."patient_invite_schedules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "invite_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "weekday" integer NOT NULL,
    "start_time" time without time zone NOT NULL,
    "duration_min" integer DEFAULT 50 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "patient_invite_schedules_duration_min_check" CHECK ((("duration_min" >= 15) AND ("duration_min" <= 240))),
    CONSTRAINT "patient_invite_schedules_weekday_check" CHECK ((("weekday" >= 0) AND ("weekday" <= 6)))
);


ALTER TABLE "public"."patient_invite_schedules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."patient_invites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "token" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "patient_name_hint" "text",
    "phone" "text",
    "email" "text",
    "used_at" timestamp with time zone,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '30 days'::interval) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."patient_invites" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."patient_schedules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "patient_id" "uuid" NOT NULL,
    "weekday" integer NOT NULL,
    "start_time" time without time zone NOT NULL,
    "duration_min" integer DEFAULT 50 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "patient_schedules_duration_min_check" CHECK ((("duration_min" >= 15) AND ("duration_min" <= 240))),
    CONSTRAINT "patient_schedules_weekday_check" CHECK ((("weekday" >= 0) AND ("weekday" <= 6)))
);


ALTER TABLE "public"."patient_schedules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."patients" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "full_name" "text" NOT NULL,
    "cpf" "text",
    "city" "text",
    "birth_date" "date",
    "phone" "text",
    "emergency_contact_name" "text",
    "emergency_contact_phone" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "google_recurring_event_id" "text",
    "session_price_cents" integer,
    CONSTRAINT "patients_session_price_cents_check" CHECK ((("session_price_cents" IS NULL) OR ("session_price_cents" >= 0))),
    CONSTRAINT "patients_status_check" CHECK (("status" = ANY (ARRAY['prospect'::"text", 'active'::"text", 'inactive'::"text", 'discharged'::"text"])))
);


ALTER TABLE "public"."patients" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "full_name" "text",
    "avatar_url" "text",
    "crp" "text",
    "phone" "text",
    "default_session_duration_minutes" integer DEFAULT 50 NOT NULL,
    "reschedule_min_hours" integer DEFAULT 24 NOT NULL,
    "no_show_fee_percent" numeric(5,2) DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."provider_schedules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "provider_id" "uuid" NOT NULL,
    "weekday" integer NOT NULL,
    "start_time" time without time zone NOT NULL,
    "duration_min" integer DEFAULT 50 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "provider_schedules_duration_min_check" CHECK ((("duration_min" >= 15) AND ("duration_min" <= 240))),
    CONSTRAINT "provider_schedules_weekday_check" CHECK ((("weekday" >= 0) AND ("weekday" <= 6)))
);


ALTER TABLE "public"."provider_schedules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."providers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "legal_name" "text",
    "document" "text",
    "email" "text",
    "phone" "text",
    "notes" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "session_price_cents" integer,
    CONSTRAINT "providers_kind_check" CHECK (("kind" = ANY (ARRAY['person'::"text", 'company'::"text"]))),
    CONSTRAINT "providers_session_price_cents_check" CHECK ((("session_price_cents" IS NULL) OR ("session_price_cents" >= 0))),
    CONSTRAINT "providers_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'archived'::"text"])))
);


ALTER TABLE "public"."providers" OWNER TO "postgres";


ALTER TABLE ONLY "public"."appointments"
    ADD CONSTRAINT "appointments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."google_credentials"
    ADD CONSTRAINT "google_credentials_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."google_imported_recurrences"
    ADD CONSTRAINT "google_imported_recurrences_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."patient_form_submissions"
    ADD CONSTRAINT "patient_form_submissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."patient_invite_schedules"
    ADD CONSTRAINT "patient_invite_schedules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."patient_invites"
    ADD CONSTRAINT "patient_invites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."patient_invites"
    ADD CONSTRAINT "patient_invites_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."patient_schedules"
    ADD CONSTRAINT "patient_schedules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."patients"
    ADD CONSTRAINT "patients_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."provider_schedules"
    ADD CONSTRAINT "provider_schedules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."providers"
    ADD CONSTRAINT "providers_pkey" PRIMARY KEY ("id");



CREATE INDEX "appointments_google_idx" ON "public"."appointments" USING "btree" ("google_event_id") WHERE ("google_event_id" IS NOT NULL);



CREATE UNIQUE INDEX "appointments_no_duplicate_idx" ON "public"."appointments" USING "btree" ("patient_id", "starts_on", "start_time") WHERE (("patient_id" IS NOT NULL) AND ("status" <> 'cancelled'::"text"));



CREATE INDEX "appointments_patient_idx" ON "public"."appointments" USING "btree" ("patient_id");



CREATE INDEX "appointments_provider_idx" ON "public"."appointments" USING "btree" ("provider_id");



CREATE INDEX "appointments_slot_idx" ON "public"."appointments" USING "btree" ("user_id", "weekday", "start_time", "status");



CREATE INDEX "appointments_user_idx" ON "public"."appointments" USING "btree" ("user_id");



CREATE INDEX "google_imported_recurrences_target_idx" ON "public"."google_imported_recurrences" USING "btree" ("target_type", "target_id");



CREATE UNIQUE INDEX "google_imported_recurrences_unique_idx" ON "public"."google_imported_recurrences" USING "btree" ("user_id", "google_recurring_event_id");



CREATE INDEX "patient_invite_schedules_invite_idx" ON "public"."patient_invite_schedules" USING "btree" ("invite_id");



CREATE INDEX "patient_invite_schedules_user_id_idx" ON "public"."patient_invite_schedules" USING "btree" ("user_id");



CREATE INDEX "patient_invites_token_idx" ON "public"."patient_invites" USING "btree" ("token");



CREATE INDEX "patient_invites_user_id_idx" ON "public"."patient_invites" USING "btree" ("user_id");



CREATE INDEX "patient_schedules_patient_idx" ON "public"."patient_schedules" USING "btree" ("patient_id");



CREATE UNIQUE INDEX "patient_schedules_unique_idx" ON "public"."patient_schedules" USING "btree" ("patient_id", "weekday", "start_time");



CREATE INDEX "patient_schedules_user_idx" ON "public"."patient_schedules" USING "btree" ("user_id");



CREATE UNIQUE INDEX "patients_google_recurring_idx" ON "public"."patients" USING "btree" ("user_id", "google_recurring_event_id") WHERE ("google_recurring_event_id" IS NOT NULL);



CREATE INDEX "patients_user_id_idx" ON "public"."patients" USING "btree" ("user_id");



CREATE INDEX "provider_schedules_provider_idx" ON "public"."provider_schedules" USING "btree" ("provider_id");



CREATE UNIQUE INDEX "provider_schedules_unique_idx" ON "public"."provider_schedules" USING "btree" ("provider_id", "weekday", "start_time");



CREATE INDEX "provider_schedules_user_idx" ON "public"."provider_schedules" USING "btree" ("user_id");



CREATE INDEX "providers_kind_idx" ON "public"."providers" USING "btree" ("user_id", "kind", "status");



CREATE INDEX "providers_user_idx" ON "public"."providers" USING "btree" ("user_id");



CREATE INDEX "submissions_status_idx" ON "public"."patient_form_submissions" USING "btree" ("status");



CREATE INDEX "submissions_user_id_idx" ON "public"."patient_form_submissions" USING "btree" ("user_id");



ALTER TABLE ONLY "public"."appointments"
    ADD CONSTRAINT "appointments_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."appointments"
    ADD CONSTRAINT "appointments_provider_id_fkey" FOREIGN KEY ("provider_id") REFERENCES "public"."providers"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."appointments"
    ADD CONSTRAINT "appointments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."google_credentials"
    ADD CONSTRAINT "google_credentials_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."google_imported_recurrences"
    ADD CONSTRAINT "google_imported_recurrences_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."patient_form_submissions"
    ADD CONSTRAINT "patient_form_submissions_invite_id_fkey" FOREIGN KEY ("invite_id") REFERENCES "public"."patient_invites"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."patient_form_submissions"
    ADD CONSTRAINT "patient_form_submissions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."patient_invite_schedules"
    ADD CONSTRAINT "patient_invite_schedules_invite_id_fkey" FOREIGN KEY ("invite_id") REFERENCES "public"."patient_invites"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."patient_invite_schedules"
    ADD CONSTRAINT "patient_invite_schedules_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."patient_invites"
    ADD CONSTRAINT "patient_invites_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."patient_schedules"
    ADD CONSTRAINT "patient_schedules_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."patient_schedules"
    ADD CONSTRAINT "patient_schedules_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."patients"
    ADD CONSTRAINT "patients_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."provider_schedules"
    ADD CONSTRAINT "provider_schedules_provider_id_fkey" FOREIGN KEY ("provider_id") REFERENCES "public"."providers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."provider_schedules"
    ADD CONSTRAINT "provider_schedules_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."providers"
    ADD CONSTRAINT "providers_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE "public"."appointments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "appointments_delete_own" ON "public"."appointments" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "appointments_insert_own" ON "public"."appointments" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "appointments_select_own" ON "public"."appointments" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "appointments_update_own" ON "public"."appointments" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "gir_select_own" ON "public"."google_imported_recurrences" FOR SELECT USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."google_credentials" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."google_imported_recurrences" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "invites_delete_own" ON "public"."patient_invites" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "invites_insert_own" ON "public"."patient_invites" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "invites_select_own" ON "public"."patient_invites" FOR SELECT USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."patient_form_submissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."patient_invite_schedules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."patient_invites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."patient_schedules" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "patient_schedules_delete_own" ON "public"."patient_schedules" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "patient_schedules_insert_own" ON "public"."patient_schedules" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "patient_schedules_select_own" ON "public"."patient_schedules" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "patient_schedules_update_own" ON "public"."patient_schedules" FOR UPDATE USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."patients" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "patients_delete_own" ON "public"."patients" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "patients_insert_own" ON "public"."patients" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "patients_select_own" ON "public"."patients" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "patients_update_own" ON "public"."patients" FOR UPDATE USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_insert_own" ON "public"."profiles" FOR INSERT WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "profiles_select_own" ON "public"."profiles" FOR SELECT USING (("auth"."uid"() = "id"));



CREATE POLICY "profiles_update_own" ON "public"."profiles" FOR UPDATE USING (("auth"."uid"() = "id"));



ALTER TABLE "public"."provider_schedules" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "provider_schedules_delete_own" ON "public"."provider_schedules" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "provider_schedules_insert_own" ON "public"."provider_schedules" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "provider_schedules_select_own" ON "public"."provider_schedules" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "provider_schedules_update_own" ON "public"."provider_schedules" FOR UPDATE USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."providers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "providers_delete_own" ON "public"."providers" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "providers_insert_own" ON "public"."providers" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "providers_select_own" ON "public"."providers" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "providers_update_own" ON "public"."providers" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "schedules_delete_own" ON "public"."patient_invite_schedules" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "schedules_insert_own" ON "public"."patient_invite_schedules" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "schedules_select_own" ON "public"."patient_invite_schedules" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "submissions_select_own" ON "public"."patient_form_submissions" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "submissions_update_own" ON "public"."patient_form_submissions" FOR UPDATE USING (("auth"."uid"() = "user_id"));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






















































































































































GRANT ALL ON FUNCTION "public"."approve_submission"("p_submission_id" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."cancel_appointment_series"("p_patient_id" "uuid", "p_mode" "text", "p_from_date" "date", "p_to_date" "date") TO "authenticated";



GRANT ALL ON FUNCTION "public"."cancel_future_appointments"("p_patient_id" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."cancel_provider_appointment_series"("p_provider_id" "uuid", "p_mode" "text", "p_from_date" "date", "p_to_date" "date") TO "authenticated";



GRANT ALL ON FUNCTION "public"."cancel_provider_future_appointments"("p_provider_id" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."convert_prospect_to_provider"("p_patient_id" "uuid", "p_kind" "text") TO "authenticated";



GRANT ALL ON FUNCTION "public"."delete_cancelled_appointments"("p_date" "date") TO "authenticated";



GRANT ALL ON FUNCTION "public"."delete_patient"("p_patient_id" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."delete_provider"("p_provider_id" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."discard_prospect"("p_patient_id" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."get_invite_by_token"("p_token" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_invite_by_token"("p_token" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."promote_prospect_to_active"("p_patient_id" "uuid", "p_schedules" "jsonb") TO "authenticated";



GRANT ALL ON FUNCTION "public"."reactivate_appointment"("p_appointment_id" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."set_patient_schedules"("p_patient_id" "uuid", "p_schedules" "jsonb", "p_horizon_days" integer) TO "authenticated";



GRANT ALL ON FUNCTION "public"."set_provider_schedules"("p_provider_id" "uuid", "p_schedules" "jsonb", "p_horizon_days" integer) TO "authenticated";



GRANT ALL ON FUNCTION "public"."submit_patient_form"("p_token" "uuid", "p_full_name" "text", "p_cpf" "text", "p_city" "text", "p_birth_date" "date", "p_phone" "text", "p_emergency_contact_name" "text", "p_emergency_contact_phone" "text", "p_consent_accepted" boolean, "p_place_acknowledged" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."submit_patient_form"("p_token" "uuid", "p_full_name" "text", "p_cpf" "text", "p_city" "text", "p_birth_date" "date", "p_phone" "text", "p_emergency_contact_name" "text", "p_emergency_contact_phone" "text", "p_consent_accepted" boolean, "p_place_acknowledged" boolean) TO "authenticated";


















GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."appointments" TO "anon";
GRANT ALL ON TABLE "public"."appointments" TO "authenticated";
GRANT ALL ON TABLE "public"."appointments" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."google_credentials" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."google_credentials" TO "authenticated";
GRANT ALL ON TABLE "public"."google_credentials" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."google_imported_recurrences" TO "anon";
GRANT ALL ON TABLE "public"."google_imported_recurrences" TO "authenticated";
GRANT ALL ON TABLE "public"."google_imported_recurrences" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."patient_form_submissions" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."patient_form_submissions" TO "authenticated";
GRANT ALL ON TABLE "public"."patient_form_submissions" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."patient_invite_schedules" TO "anon";
GRANT ALL ON TABLE "public"."patient_invite_schedules" TO "authenticated";
GRANT ALL ON TABLE "public"."patient_invite_schedules" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."patient_invites" TO "anon";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."patient_invites" TO "authenticated";
GRANT ALL ON TABLE "public"."patient_invites" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."patient_schedules" TO "anon";
GRANT ALL ON TABLE "public"."patient_schedules" TO "authenticated";
GRANT ALL ON TABLE "public"."patient_schedules" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."patients" TO "anon";
GRANT ALL ON TABLE "public"."patients" TO "authenticated";
GRANT ALL ON TABLE "public"."patients" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."profiles" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."provider_schedules" TO "anon";
GRANT ALL ON TABLE "public"."provider_schedules" TO "authenticated";
GRANT ALL ON TABLE "public"."provider_schedules" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."providers" TO "anon";
GRANT ALL ON TABLE "public"."providers" TO "authenticated";
GRANT ALL ON TABLE "public"."providers" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "service_role";



































drop extension if exists "pg_net";

revoke delete on table "public"."appointments" from "anon";

revoke insert on table "public"."appointments" from "anon";

revoke select on table "public"."appointments" from "anon";

revoke update on table "public"."appointments" from "anon";

revoke delete on table "public"."google_credentials" from "anon";

revoke insert on table "public"."google_credentials" from "anon";

revoke select on table "public"."google_credentials" from "anon";

revoke update on table "public"."google_credentials" from "anon";

revoke delete on table "public"."google_credentials" from "authenticated";

revoke insert on table "public"."google_credentials" from "authenticated";

revoke select on table "public"."google_credentials" from "authenticated";

revoke update on table "public"."google_credentials" from "authenticated";

revoke delete on table "public"."google_imported_recurrences" from "anon";

revoke insert on table "public"."google_imported_recurrences" from "anon";

revoke select on table "public"."google_imported_recurrences" from "anon";

revoke update on table "public"."google_imported_recurrences" from "anon";

revoke delete on table "public"."patient_form_submissions" from "anon";

revoke insert on table "public"."patient_form_submissions" from "anon";

revoke select on table "public"."patient_form_submissions" from "anon";

revoke update on table "public"."patient_form_submissions" from "anon";

revoke delete on table "public"."patient_form_submissions" from "authenticated";

revoke insert on table "public"."patient_form_submissions" from "authenticated";

revoke delete on table "public"."patient_invite_schedules" from "anon";

revoke insert on table "public"."patient_invite_schedules" from "anon";

revoke select on table "public"."patient_invite_schedules" from "anon";

revoke update on table "public"."patient_invite_schedules" from "anon";

revoke delete on table "public"."patient_invites" from "anon";

revoke insert on table "public"."patient_invites" from "anon";

revoke select on table "public"."patient_invites" from "anon";

revoke update on table "public"."patient_invites" from "anon";

revoke update on table "public"."patient_invites" from "authenticated";

revoke delete on table "public"."patient_schedules" from "anon";

revoke insert on table "public"."patient_schedules" from "anon";

revoke select on table "public"."patient_schedules" from "anon";

revoke update on table "public"."patient_schedules" from "anon";

revoke delete on table "public"."patients" from "anon";

revoke insert on table "public"."patients" from "anon";

revoke select on table "public"."patients" from "anon";

revoke update on table "public"."patients" from "anon";

revoke delete on table "public"."profiles" from "anon";

revoke insert on table "public"."profiles" from "anon";

revoke select on table "public"."profiles" from "anon";

revoke update on table "public"."profiles" from "anon";

revoke delete on table "public"."profiles" from "service_role";

revoke insert on table "public"."profiles" from "service_role";

revoke delete on table "public"."provider_schedules" from "anon";

revoke insert on table "public"."provider_schedules" from "anon";

revoke select on table "public"."provider_schedules" from "anon";

revoke update on table "public"."provider_schedules" from "anon";

revoke delete on table "public"."providers" from "anon";

revoke insert on table "public"."providers" from "anon";

revoke select on table "public"."providers" from "anon";

revoke update on table "public"."providers" from "anon";

CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


