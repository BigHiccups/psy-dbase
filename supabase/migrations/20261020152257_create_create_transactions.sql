-- ============================================================
-- create_transactions
-- ============================================================
-- Tabela unificada de entradas e saídas financeiras.
--
-- Modelo: type='income' | 'expense', com vínculo opcional a
-- patient_id, provider_id ou billing_id (no máximo 1).
--
-- paid_on NULL = pendente; paid_on preenchido = pago/recebido.
--
-- Deprecia appointments.type = 'due'. A migration FALHA se
-- houver algum registro desse tipo — migrar manualmente antes.
-- ============================================================

-- ============================================================
-- 0) Sanity check: nenhum appointment pode ter type = 'due'
-- ============================================================
DO $$
DECLARE
  v_count int;
BEGIN
  SELECT count(*) INTO v_count
  FROM public.appointments
  WHERE type = 'due';

  IF v_count > 0 THEN
    RAISE EXCEPTION
      'Existem % appointments do tipo ''due''. Migre-os para provider_billings/transactions antes de aplicar esta migration.',
      v_count;
  END IF;
END $$;

-- ============================================================
-- 1) Tabela transactions
-- ============================================================
CREATE TABLE IF NOT EXISTS public.transactions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  type            text NOT NULL CHECK (type IN ('income', 'expense')),
  amount_cents    int  NOT NULL CHECK (amount_cents > 0),
  description     text NOT NULL,
  category        text NOT NULL DEFAULT 'other',

  occurred_on     date NOT NULL DEFAULT current_date,
  paid_on         date,

  patient_id      uuid REFERENCES public.patients(id)          ON DELETE SET NULL,
  provider_id     uuid REFERENCES public.providers(id)         ON DELETE SET NULL,
  billing_id      uuid REFERENCES public.provider_billings(id) ON DELETE SET NULL,

  payment_method  text CHECK (
    payment_method IS NULL OR
    payment_method IN ('pix', 'cash', 'card', 'transfer', 'other')
  ),
  notes           text,

  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  -- No máximo 1 vínculo entre patient/provider/billing
  CONSTRAINT transactions_single_link_check CHECK (
    (CASE WHEN patient_id  IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN provider_id IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN billing_id  IS NOT NULL THEN 1 ELSE 0 END) <= 1
  )
);

-- ============================================================
-- 2) Índices
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_transactions_user_date
  ON public.transactions (user_id, occurred_on DESC);

CREATE INDEX IF NOT EXISTS idx_transactions_user_type
  ON public.transactions (user_id, type);

CREATE INDEX IF NOT EXISTS idx_transactions_patient
  ON public.transactions (patient_id) WHERE patient_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_transactions_provider
  ON public.transactions (provider_id) WHERE provider_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_transactions_billing
  ON public.transactions (billing_id) WHERE billing_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_transactions_pending
  ON public.transactions (user_id, occurred_on DESC)
  WHERE paid_on IS NULL;

-- ============================================================
-- 3) RLS + GRANTs
-- ============================================================
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS transactions_select_own ON public.transactions;
CREATE POLICY transactions_select_own
  ON public.transactions FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS transactions_insert_own ON public.transactions;
CREATE POLICY transactions_insert_own
  ON public.transactions FOR INSERT
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS transactions_update_own ON public.transactions;
CREATE POLICY transactions_update_own
  ON public.transactions FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS transactions_delete_own ON public.transactions;
CREATE POLICY transactions_delete_own
  ON public.transactions FOR DELETE
  USING (auth.uid() = user_id);

GRANT ALL ON public.transactions TO authenticated;
GRANT ALL ON public.transactions TO service_role;

-- ============================================================
-- 4) Trigger updated_at (reusa set_updated_at criado em provider_billings)
-- ============================================================
DROP TRIGGER IF EXISTS set_transactions_updated_at ON public.transactions;
CREATE TRIGGER set_transactions_updated_at
  BEFORE UPDATE ON public.transactions
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- ============================================================
-- 5) Validação de vínculo (não permite referenciar entidade de outro user)
-- ============================================================
CREATE OR REPLACE FUNCTION public.validate_transaction_links()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.patient_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.patients
    WHERE id = NEW.patient_id AND user_id = NEW.user_id
  ) THEN
    RAISE EXCEPTION 'patient_id não pertence a este usuário.';
  END IF;

  IF NEW.provider_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.providers
    WHERE id = NEW.provider_id AND user_id = NEW.user_id
  ) THEN
    RAISE EXCEPTION 'provider_id não pertence a este usuário.';
  END IF;

  IF NEW.billing_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.provider_billings
    WHERE id = NEW.billing_id AND user_id = NEW.user_id
  ) THEN
    RAISE EXCEPTION 'billing_id não pertence a este usuário.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS validate_transaction_links_trigger ON public.transactions;
CREATE TRIGGER validate_transaction_links_trigger
  BEFORE INSERT OR UPDATE ON public.transactions
  FOR EACH ROW
  EXECUTE FUNCTION public.validate_transaction_links();

-- ============================================================
-- 6) Depreciar appointments.type = 'due'
-- ============================================================
ALTER TABLE public.appointments
  DROP CONSTRAINT IF EXISTS "appointments_subject_check";
ALTER TABLE public.appointments
  ADD CONSTRAINT "appointments_subject_check" CHECK (
    (type = 'session' AND patient_id IS NOT NULL AND provider_id IS NULL) OR
    (type = 'personal' AND patient_id IS NULL AND provider_id IS NOT NULL) OR
    (type = 'blocked' AND patient_id IS NULL AND provider_id IS NULL)
  );

ALTER TABLE public.appointments
  DROP CONSTRAINT IF EXISTS "appointments_type_check";
ALTER TABLE public.appointments
  ADD CONSTRAINT "appointments_type_check" CHECK (
    type IN ('session', 'personal', 'blocked')
  );

-- ============================================================
-- 7) RPC: mark_transaction_as_paid
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_transaction_as_paid(
  p_transaction_id uuid,
  p_paid_on date DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.transactions
  SET paid_on = COALESCE(p_paid_on, current_date),
      updated_at = now()
  WHERE id = p_transaction_id AND user_id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transação não encontrada ou sem permissão.';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.mark_transaction_as_paid(uuid, date)
  TO authenticated;

-- ============================================================
-- 8) RPC: create_income_from_appointment (fluxo híbrido)
-- ============================================================
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
  SELECT * INTO v_appt
  FROM public.appointments
  WHERE id = p_appointment_id AND user_id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Agendamento não encontrado ou sem permissão.';
  END IF;

  IF v_appt.type <> 'session' OR v_appt.patient_id IS NULL THEN
    RAISE EXCEPTION 'Só é possível gerar receita de sessões com paciente.';
  END IF;

  IF v_appt.status = 'cancelled' THEN
    RAISE EXCEPTION 'Não é possível gerar receita de uma sessão cancelada.';
  END IF;

  SELECT * INTO v_patient
  FROM public.patients
  WHERE id = v_appt.patient_id;

  v_amount := COALESCE(p_amount_cents, v_patient.session_price_cents);

  IF v_amount IS NULL OR v_amount <= 0 THEN
    RAISE EXCEPTION
      'Valor inválido. Defina session_price_cents no paciente ou passe p_amount_cents.';
  END IF;

  INSERT INTO public.transactions (
    user_id, type, amount_cents, description, category,
    occurred_on, paid_on, patient_id, payment_method
  ) VALUES (
    auth.uid(), 'income', v_amount,
    'Sessão ' || to_char(v_appt.starts_on, 'DD/MM/YYYY'),
    'session',
    v_appt.starts_on,
    p_paid_on,
    v_appt.patient_id,
    p_payment_method
  )
  RETURNING id INTO v_tx_id;

  RETURN v_tx_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_income_from_appointment(uuid, int, date, text)
  TO authenticated;

-- ============================================================
-- 9) RPC: create_expense_from_billing
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_expense_from_billing(
  p_billing_id     uuid,
  p_amount_cents   int  DEFAULT NULL,
  p_occurred_on    date DEFAULT NULL,
  p_paid_on        date DEFAULT NULL,
  p_payment_method text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_billing public.provider_billings;
  v_amount  int;
  v_tx_id   uuid;
BEGIN
  SELECT * INTO v_billing
  FROM public.provider_billings
  WHERE id = p_billing_id AND user_id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Vencimento não encontrado ou sem permissão.';
  END IF;

  v_amount := COALESCE(p_amount_cents, v_billing.amount_cents);

  IF v_amount IS NULL OR v_amount <= 0 THEN
    RAISE EXCEPTION 'Valor inválido.';
  END IF;

  INSERT INTO public.transactions (
    user_id, type, amount_cents, description, category,
    occurred_on, paid_on, billing_id, payment_method
  ) VALUES (
    auth.uid(), 'expense', v_amount,
    v_billing.description,
    'billing',
    COALESCE(p_occurred_on, current_date),
    p_paid_on,
    p_billing_id,
    p_payment_method
  )
  RETURNING id INTO v_tx_id;

  RETURN v_tx_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_expense_from_billing(uuid, int, date, date, text)
  TO authenticated;