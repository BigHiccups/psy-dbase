-- ============================================================
-- add_session_ledger_and_payment_configs
-- ============================================================

-- 1) Novas colunas em patients e providers
ALTER TABLE public.patients
  ADD COLUMN IF NOT EXISTS payment_format text DEFAULT 'avulso'
    CHECK (payment_format IN ('vencimento', 'antecipado', 'avulso')),
  ADD COLUMN IF NOT EXISTS default_payment_method text,
  ADD COLUMN IF NOT EXISTS session_number_start int DEFAULT 0;

ALTER TABLE public.providers
  ADD COLUMN IF NOT EXISTS payment_format text DEFAULT 'avulso'
    CHECK (payment_format IN ('vencimento', 'antecipado', 'avulso')),
  ADD COLUMN IF NOT EXISTS default_payment_method text,
  ADD COLUMN IF NOT EXISTS session_number_start int DEFAULT 0;

-- 2) Vínculo da transação com o agendamento específico
ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS appointment_id uuid REFERENCES public.appointments(id) ON DELETE SET NULL;

-- 3) Novos status de agendamento
ALTER TABLE public.appointments
  DROP CONSTRAINT IF EXISTS appointments_status_check;
  
ALTER TABLE public.appointments
  ADD CONSTRAINT appointments_status_check
  CHECK (status IN (
    'active',              -- pendente/agendada
    'completed',           -- realizada
    'cancelled',           -- cancelada
    'no_show_justified',   -- não realizada - justificada
    'no_show_unjustified'  -- não realizada - não justificada
  ));

-- 4) Atualizar a RPC de sugestões para incluir os novos status de no-show
CREATE OR REPLACE FUNCTION public.bulk_approve_suggestions(
  p_appointment_ids uuid[] DEFAULT '{}',
  p_billing_ids     uuid[] DEFAULT '{}',
  p_personal_ids    uuid[] DEFAULT '{}'
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count       int := 0;
  v_appt        record;
  v_bill        record;
  v_pers        record;
  v_patient     public.patients;
  v_provider    public.providers;
  v_amount      int;
  v_occurred    date;
  v_month_start date := date_trunc('month', current_date)::date;
  v_month_end   date := (date_trunc('month', current_date) + interval '1 month')::date;
  v_last_day    int;
  v_due_day     int;
BEGIN
  -- Sessões (Aceita active antigo, completed e no_shows)
  IF array_length(p_appointment_ids, 1) > 0 THEN
    FOR v_appt IN
      SELECT a.* FROM public.appointments a
      WHERE a.id = ANY(p_appointment_ids)
        AND a.user_id = auth.uid()
        AND a.status IN ('completed', 'active', 'no_show_justified', 'no_show_unjustified')
        AND a.type = 'session'
        AND a.patient_id IS NOT NULL
    LOOP
      SELECT * INTO v_patient FROM public.patients WHERE id = v_appt.patient_id;
      v_amount := v_patient.session_price_cents;
      IF v_amount IS NULL OR v_amount <= 0 THEN CONTINUE; END IF;

      IF NOT EXISTS (
        SELECT 1 FROM public.transactions t
        WHERE t.appointment_id = v_appt.id OR (t.patient_id = v_appt.patient_id AND t.occurred_on = v_appt.starts_on AND t.type = 'income')
      ) THEN
        INSERT INTO public.transactions (
          user_id, type, amount_cents, description, category,
          occurred_on, paid_on, patient_id, appointment_id, notes
        ) VALUES (
          auth.uid(), 'income', v_amount,
          'Sessão ' || to_char(v_appt.starts_on, 'DD/MM/YYYY'),
          'session',
          v_appt.starts_on, NULL, v_appt.patient_id, v_appt.id,
          'Aprovado a partir de sugestão'
        );
        v_count := v_count + 1;
      END IF;
    END LOOP;
  END IF;

  -- Billings (mantido igual)
  IF array_length(p_billing_ids, 1) > 0 THEN
    FOR v_bill IN
      SELECT b.* FROM public.provider_billings b
      WHERE b.id = ANY(p_billing_ids) AND b.user_id = auth.uid() AND b.status = 'active'
    LOOP
      IF NOT EXISTS (
        SELECT 1 FROM public.transactions t
        WHERE t.billing_id = v_bill.id AND t.type = 'expense'
          AND t.occurred_on >= v_month_start AND t.occurred_on < v_month_end
      ) THEN
        v_last_day := extract(day from (v_month_start + interval '1 month' - interval '1 day'))::int;
        v_due_day  := LEAST(v_bill.due_day, v_last_day);
        v_occurred := v_month_start + (v_due_day - 1);

        INSERT INTO public.transactions (
          user_id, type, amount_cents, description, category,
          occurred_on, paid_on, billing_id, notes
        ) VALUES (
          auth.uid(), 'expense', v_bill.amount_cents,
          v_bill.description || ' · ' || to_char(v_month_start, 'MM/YYYY'),
          'billing', v_occurred, NULL, v_bill.id, 'Aprovado a partir de sugestão'
        );
        v_count := v_count + 1;
      END IF;
    END LOOP;
  END IF;

  -- Personal (Aceita active antigo, completed e no_shows)
  IF array_length(p_personal_ids, 1) > 0 THEN
    FOR v_pers IN
      SELECT a.* FROM public.appointments a
      WHERE a.id = ANY(p_personal_ids)
        AND a.user_id = auth.uid()
        AND a.status IN ('completed', 'active', 'no_show_justified', 'no_show_unjustified')
        AND a.type = 'personal'
        AND a.provider_id IS NOT NULL
    LOOP
      SELECT * INTO v_provider FROM public.providers WHERE id = v_pers.provider_id;
      v_amount := v_provider.session_price_cents;
      IF v_amount IS NULL OR v_amount <= 0 THEN CONTINUE; END IF;

      IF NOT EXISTS (
        SELECT 1 FROM public.transactions t
        WHERE t.appointment_id = v_pers.id OR (t.provider_id = v_pers.provider_id AND t.occurred_on = v_pers.starts_on AND t.type = 'expense')
      ) THEN
        INSERT INTO public.transactions (
          user_id, type, amount_cents, description, category,
          occurred_on, paid_on, provider_id, appointment_id, notes
        ) VALUES (
          auth.uid(), 'expense', v_amount,
          v_provider.display_name || ' · ' || to_char(v_pers.starts_on, 'DD/MM/YYYY'),
          'supervision', v_pers.starts_on, NULL, v_pers.provider_id, v_pers.id, 'Aprovado a partir de sugestão'
        );
        v_count := v_count + 1;
      END IF;
    END LOOP;
  END IF;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.bulk_approve_suggestions(uuid[], uuid[], uuid[]) TO authenticated;

NOTIFY pgrst, 'reload schema';