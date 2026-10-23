-- 1. Adiciona a coluna para intervalos personalizados
ALTER TABLE public.provider_billings 
ADD COLUMN IF NOT EXISTS custom_interval_days int;

-- 2. Atualiza a RPC set_provider_billing para aceitar o novo campo e as novas frequências
DROP FUNCTION IF EXISTS public.set_provider_billing(uuid, uuid, text, int, int, text, date, int);

CREATE OR REPLACE FUNCTION public.set_provider_billing(
  p_billing_id uuid,
  p_provider_id uuid,
  p_description text,
  p_amount_cents int,
  p_due_day int,
  p_frequency text,
  p_starts_on date,
  p_due_month int default null,
  p_custom_interval_days int default null
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_billing_id uuid;
BEGIN
  IF p_frequency NOT IN ('monthly', 'bimonthly', 'semiannual', 'yearly', 'once', 'biweekly', 'custom_days') THEN
    RAISE EXCEPTION 'Frequência inválida.';
  END IF;

  IF p_billing_id IS NULL THEN
    INSERT INTO public.provider_billings (
      user_id, provider_id, description, amount_cents, due_day, due_month, frequency, starts_on, custom_interval_days
    ) VALUES (
      auth.uid(), p_provider_id, p_description, p_amount_cents, p_due_day, p_due_month, p_frequency, p_starts_on, p_custom_interval_days
    ) RETURNING id INTO v_billing_id;
  ELSE
    UPDATE public.provider_billings SET
      description = p_description, amount_cents = p_amount_cents, due_day = p_due_day,
      due_month = p_due_month, frequency = p_frequency, starts_on = p_starts_on,
      custom_interval_days = p_custom_interval_days
    WHERE id = p_billing_id AND user_id = auth.uid() RETURNING id INTO v_billing_id;
  END IF;

  RETURN v_billing_id;
END;
$$;