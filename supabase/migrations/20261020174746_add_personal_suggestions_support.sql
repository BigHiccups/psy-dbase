-- ============================================================
-- add_personal_suggestions_support
-- ============================================================
-- 1) bulk_approve_suggestions ganha 3º parâmetro p_personal_ids
--    para appointments do tipo 'personal' (provider pessoa física).
-- 2) Sessões (income) e personal (expense) passam a aceitar
--    status IN ('active', 'completed') — antes só completed,
--    o que bloqueava o fluxo sem UI de "marcar como realizado".
-- ============================================================

DROP FUNCTION IF EXISTS public.bulk_approve_suggestions(uuid[], uuid[]);

CREATE OR REPLACE FUNCTION public.bulk_approve_suggestions(
  p_appointment_ids uuid[] DEFAULT '{}',  -- sessões (income / paciente)
  p_billing_ids     uuid[] DEFAULT '{}',  -- billings (expense / company)
  p_personal_ids    uuid[] DEFAULT '{}'   -- personal (expense / provider person)
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
  -- ========================================
  -- 1) Sessions (income para paciente)
  -- ========================================
  IF array_length(p_appointment_ids, 1) > 0 THEN
    FOR v_appt IN
      SELECT a.* FROM public.appointments a
      WHERE a.id = ANY(p_appointment_ids)
        AND a.user_id = auth.uid()
        AND a.status IN ('completed', 'active')
        AND a.type = 'session'
        AND a.patient_id IS NOT NULL
    LOOP
      SELECT * INTO v_patient FROM public.patients WHERE id = v_appt.patient_id;
      v_amount := v_patient.session_price_cents;
      IF v_amount IS NULL OR v_amount <= 0 THEN CONTINUE; END IF;

      IF NOT EXISTS (
        SELECT 1 FROM public.transactions t
        WHERE t.patient_id = v_appt.patient_id
          AND t.occurred_on = v_appt.starts_on
          AND t.type = 'income'
      ) THEN
        INSERT INTO public.transactions (
          user_id, type, amount_cents, description, category,
          occurred_on, paid_on, patient_id, notes
        ) VALUES (
          auth.uid(), 'income', v_amount,
          'Sessão ' || to_char(v_appt.starts_on, 'DD/MM/YYYY'),
          'session',
          v_appt.starts_on, NULL, v_appt.patient_id,
          'Aprovado a partir de sugestão'
        );
        v_count := v_count + 1;
      END IF;
    END LOOP;
  END IF;

  -- ========================================
  -- 2) Billings (expense para empresa)
  -- ========================================
  IF array_length(p_billing_ids, 1) > 0 THEN
    FOR v_bill IN
      SELECT b.* FROM public.provider_billings b
      WHERE b.id = ANY(p_billing_ids)
        AND b.user_id = auth.uid()
        AND b.status = 'active'
    LOOP
      IF NOT EXISTS (
        SELECT 1 FROM public.transactions t
        WHERE t.billing_id = v_bill.id
          AND t.type = 'expense'
          AND t.occurred_on >= v_month_start
          AND t.occurred_on < v_month_end
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
          'billing',
          v_occurred, NULL, v_bill.id,
          'Aprovado a partir de sugestão'
        );
        v_count := v_count + 1;
      END IF;
    END LOOP;
  END IF;

  -- ========================================
  -- 3) Personal (expense para provider person)
  -- ========================================
  IF array_length(p_personal_ids, 1) > 0 THEN
    FOR v_pers IN
      SELECT a.* FROM public.appointments a
      WHERE a.id = ANY(p_personal_ids)
        AND a.user_id = auth.uid()
        AND a.status IN ('completed', 'active')
        AND a.type = 'personal'
        AND a.provider_id IS NOT NULL
    LOOP
      SELECT * INTO v_provider FROM public.providers WHERE id = v_pers.provider_id;
      v_amount := v_provider.session_price_cents;
      IF v_amount IS NULL OR v_amount <= 0 THEN CONTINUE; END IF;

      IF NOT EXISTS (
        SELECT 1 FROM public.transactions t
        WHERE t.provider_id = v_pers.provider_id
          AND t.occurred_on = v_pers.starts_on
          AND t.type = 'expense'
      ) THEN
        INSERT INTO public.transactions (
          user_id, type, amount_cents, description, category,
          occurred_on, paid_on, provider_id, notes
        ) VALUES (
          auth.uid(), 'expense', v_amount,
          v_provider.display_name || ' · ' || to_char(v_pers.starts_on, 'DD/MM/YYYY'),
          'supervision',
          v_pers.starts_on, NULL, v_pers.provider_id,
          'Aprovado a partir de sugestão'
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