-- ============================================================
-- add_pending_suggestions
-- ============================================================
-- 1) Tabela dismissed_suggestions: registra que o usuário
--    descartou uma sugestão (sessão concluída sem receita OU
--    vencimento do mês sem despesa). Não toca em provider_billings
--    para não perder o histórico recorrente.
-- 2) RPC dismiss_suggestion
-- 3) RPC bulk_approve_suggestions (cria transações em lote)
-- ============================================================

-- ============================================================
-- 1) Tabela dismissed_suggestions
-- ============================================================
CREATE TABLE IF NOT EXISTS public.dismissed_suggestions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  target_type    text NOT NULL CHECK (target_type IN ('appointment', 'billing')),
  target_id      uuid NOT NULL,
  reference_date date NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, target_type, target_id, reference_date)
);

CREATE INDEX IF NOT EXISTS idx_dismissed_suggestions_user
  ON public.dismissed_suggestions (user_id, target_type);

COMMENT ON TABLE public.dismissed_suggestions IS
  'Sugestões de lançamento financeiro que o usuário decidiu não aprovar. reference_date: starts_on para appointment, primeiro dia do mês para billing.';

ALTER TABLE public.dismissed_suggestions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS dismissed_select_own ON public.dismissed_suggestions;
CREATE POLICY dismissed_select_own ON public.dismissed_suggestions FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS dismissed_insert_own ON public.dismissed_suggestions;
CREATE POLICY dismissed_insert_own ON public.dismissed_suggestions FOR INSERT
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS dismissed_delete_own ON public.dismissed_suggestions;
CREATE POLICY dismissed_delete_own ON public.dismissed_suggestions FOR DELETE
  USING (auth.uid() = user_id);

GRANT ALL ON public.dismissed_suggestions TO authenticated;
GRANT ALL ON public.dismissed_suggestions TO service_role;

-- ============================================================
-- 2) RPC dismiss_suggestion
-- ============================================================
CREATE OR REPLACE FUNCTION public.dismiss_suggestion(
  p_target_type    text,
  p_target_id      uuid,
  p_reference_date date DEFAULT current_date
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_target_type NOT IN ('appointment', 'billing') THEN
    RAISE EXCEPTION 'Tipo inválido: %', p_target_type;
  END IF;

  IF p_target_type = 'appointment' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.appointments
      WHERE id = p_target_id AND user_id = auth.uid()
    ) THEN
      RAISE EXCEPTION 'Agendamento não encontrado.';
    END IF;
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM public.provider_billings
      WHERE id = p_target_id AND user_id = auth.uid()
    ) THEN
      RAISE EXCEPTION 'Vencimento não encontrado.';
    END IF;
  END IF;

  INSERT INTO public.dismissed_suggestions (user_id, target_type, target_id, reference_date)
  VALUES (auth.uid(), p_target_type, p_target_id, p_reference_date)
  ON CONFLICT (user_id, target_type, target_id, reference_date) DO NOTHING;
END;
$$;

GRANT EXECUTE ON FUNCTION public.dismiss_suggestion(text, uuid, date) TO authenticated;

-- ============================================================
-- 3) RPC bulk_approve_suggestions
-- ============================================================
CREATE OR REPLACE FUNCTION public.bulk_approve_suggestions(
  p_appointment_ids uuid[] DEFAULT '{}',
  p_billing_ids     uuid[] DEFAULT '{}'
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
  v_patient     public.patients;
  v_amount      int;
  v_occurred    date;
  v_month_start date := date_trunc('month', current_date)::date;
  v_month_end   date := (date_trunc('month', current_date) + interval '1 month')::date;
  v_last_day    int;
  v_due_day     int;
BEGIN
  -- ----------------------------------------
  -- Sessões concluídas sem receita
  -- ----------------------------------------
  IF array_length(p_appointment_ids, 1) > 0 THEN
    FOR v_appt IN
      SELECT a.* FROM public.appointments a
      WHERE a.id = ANY(p_appointment_ids)
        AND a.user_id = auth.uid()
        AND a.status = 'completed'
        AND a.type = 'session'
        AND a.patient_id IS NOT NULL
    LOOP
      SELECT * INTO v_patient FROM public.patients WHERE id = v_appt.patient_id;
      v_amount := v_patient.session_price_cents;

      -- Sem valor no paciente: pula (usuário deve definir antes)
      IF v_amount IS NULL OR v_amount <= 0 THEN
        CONTINUE;
      END IF;

      -- Já existe receita para essa sessão?
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

  -- ----------------------------------------
  -- Billings do mês atual sem despesa
  -- ----------------------------------------
  IF array_length(p_billing_ids, 1) > 0 THEN
    FOR v_bill IN
      SELECT b.* FROM public.provider_billings b
      WHERE b.id = ANY(p_billing_ids)
        AND b.user_id = auth.uid()
        AND b.status = 'active'
    LOOP
      -- Já existe despesa para esse billing no mês atual?
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

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.bulk_approve_suggestions(uuid[], uuid[]) TO authenticated;

-- ============================================================
-- 4) Reload do PostgREST
-- ============================================================
NOTIFY pgrst, 'reload schema';