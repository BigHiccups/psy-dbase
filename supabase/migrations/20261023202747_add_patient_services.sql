-- ============================================================
-- 1. Adiciona as colunas de serviço na tabela de horários
-- ============================================================
ALTER TABLE public.patient_schedules
  ADD COLUMN IF NOT EXISTS title text,
  ADD COLUMN IF NOT EXISTS color text,
  ADD COLUMN IF NOT EXISTS session_price_cents int,
  ADD COLUMN IF NOT EXISTS payment_format text,
  ADD COLUMN IF NOT EXISTS default_payment_method text,
  ADD COLUMN IF NOT EXISTS session_number_start int;

-- ============================================================
-- 2. Adiciona o valor no agendamento (para facilitar o financeiro)
-- ============================================================
ALTER TABLE public.appointments
  ADD COLUMN IF NOT EXISTS session_price_cents int;

-- ============================================================
-- 3. Atualiza a RPC set_patient_schedules
-- ============================================================
-- Agora ela lê as configurações individuais de cada bloco de serviço
DROP FUNCTION IF EXISTS public.set_patient_schedules(uuid, jsonb, text, int, int);

CREATE OR REPLACE FUNCTION public.set_patient_schedules(
  p_patient_id uuid,
  p_schedules jsonb,
  p_recurrence_type text DEFAULT 'weekly',
  p_recurrence_days int DEFAULT null,
  p_horizon_days int DEFAULT 90
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_patient public.patients;
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
begin
  select * into v_patient from public.patients where id = p_patient_id for update;
  if not found then raise exception 'Paciente não encontrado.'; end if;
  if v_patient.user_id <> auth.uid() then raise exception 'Sem permissão.'; end if;

  delete from public.appointments where patient_id = p_patient_id and starts_on >= v_today;
  delete from public.patient_schedules where patient_id = p_patient_id;

  for v_schedule in select * from jsonb_array_elements(p_schedules) loop
    -- Lê a recorrência de cada bloco
    v_rec_type := coalesce(v_schedule->>'recurrenceType', p_recurrence_type);
    v_rec_days := coalesce((v_schedule->>'recurrenceDays')::int, p_recurrence_days);

    if v_schedule ? 'anchorDate' and (v_schedule->>'anchorDate') is not null then
      v_anchor_date := (v_schedule->>'anchorDate')::date;
    else
      v_weekday := (v_schedule->>'weekday')::int;
      v_anchor_date := v_today + ((v_weekday - extract(dow from v_today)::int + 7) % 7);
    end if;

    v_weekday := extract(dow from v_anchor_date)::int;
    v_start_time := nullif(v_schedule->>'startTime', '')::time;
    v_duration := nullif(v_schedule->>'durationMin', '')::int;

    -- Insere no patient_schedules com os novos campos
    insert into public.patient_schedules (
      user_id, patient_id, weekday, start_time, duration_min, 
      recurrence_type, recurrence_days, anchor_date,
      title, color, session_price_cents, payment_format, default_payment_method, session_number_start
    ) values (
      v_patient.user_id, p_patient_id, v_weekday, v_start_time, v_duration,
      v_rec_type, v_rec_days, v_anchor_date,
      v_schedule->>'title', v_schedule->>'color', (v_schedule->>'sessionPrice')::int, v_schedule->>'paymentFormat', v_schedule->>'paymentMethod', (v_schedule->>'sessionStart')::int
    );

    v_occurrence_date := v_anchor_date;

    while v_occurrence_date <= v_horizon_end loop
      -- Insere o agendamento copiando o título, cor e valor
      insert into public.appointments (
        user_id, patient_id, type, weekday, start_time, duration_min,
        starts_on, ends_on, is_recurring, status, 
        title, color, session_price_cents
      ) values (
        v_patient.user_id, p_patient_id, 'session',
        extract(dow from v_occurrence_date)::int,
        v_start_time, v_duration,
        v_occurrence_date, v_occurrence_date, true, 'active',
        v_schedule->>'title', v_schedule->>'color', (v_schedule->>'sessionPrice')::int
      ) on conflict do nothing;

      if v_rec_type = 'once' then exit; end if;
      v_occurrence_date := public.compute_next_occurrence(v_occurrence_date, v_rec_type, v_rec_days, v_anchor_date);
      if v_occurrence_date is null then exit; end if;
    end loop;
  end loop;
end;
$$;

-- ============================================================
-- 4. Atualiza a RPC create_income_from_appointment
-- ============================================================
-- Agora ela puxa o valor do próprio agendamento (e não mais do paciente)
CREATE OR REPLACE FUNCTION public.create_income_from_appointment(
  p_appointment_id uuid,
  p_amount_cents   int  DEFAULT NULL,
  p_paid_on        date DEFAULT NULL,
  p_payment_method text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_appt    public.appointments;
  v_patient public.patients;
  v_amount  int;
  v_tx_id   uuid;
BEGIN
  SELECT * INTO v_appt FROM public.appointments WHERE id = p_appointment_id AND user_id = auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION 'Agendamento não encontrado.'; END IF;
  IF v_appt.type <> 'session' OR v_appt.patient_id IS NULL THEN RAISE EXCEPTION 'Só é possível gerar receita de sessões com paciente.'; END IF;

  SELECT * INTO v_patient FROM public.patients WHERE id = v_appt.patient_id;

  -- AQUI: Tenta pegar o valor do agendamento, senão cai pro cadastro antigo do paciente
  v_amount := COALESCE(p_amount_cents, v_appt.session_price_cents, v_patient.session_price_cents);

  IF v_amount IS NULL OR v_amount <= 0 THEN
    RAISE EXCEPTION 'Valor inválido. Defina o valor no serviço ou passe p_amount_cents.';
  END IF;

  INSERT INTO public.transactions (
    user_id, type, amount_cents, description, category,
    occurred_on, paid_on, patient_id, appointment_id, payment_method
  ) VALUES (
    auth.uid(), 'income', v_amount,
    coalesce(v_appt.title, 'Sessão') || ' ' || to_char(v_appt.starts_on, 'DD/MM/YYYY'),
    'session',
    v_appt.starts_on, p_paid_on, v_appt.patient_id, v_appt.id, p_payment_method
  ) RETURNING id INTO v_tx_id;

  RETURN v_tx_id;
END;
$$;