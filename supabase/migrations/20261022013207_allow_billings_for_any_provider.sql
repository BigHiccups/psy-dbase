CREATE OR REPLACE FUNCTION public.set_provider_billing(
  p_billing_id uuid,
  p_provider_id uuid,
  p_description text,
  p_amount_cents int,
  p_due_day int,
  p_frequency text,
  p_starts_on date,
  p_due_month int default null
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_provider public.providers;
  v_billing_id uuid;
begin
  select * into v_provider from public.providers where id = p_provider_id;
  if not found then raise exception 'Prestador não encontrado.'; end if;
  if v_provider.user_id <> auth.uid() then raise exception 'Sem permissão.'; end if;
  
  -- AQUI: Removemos a trava `if v_provider.kind <> 'company'`

  if p_description is null or trim(p_description) = '' then raise exception 'Descrição é obrigatória.'; end if;
  if p_amount_cents is null or p_amount_cents < 0 then raise exception 'Valor inválido.'; end if;
  if p_due_day is null or p_due_day < 1 or p_due_day > 31 then raise exception 'Dia de vencimento deve ser entre 1 e 31.'; end if;
  if p_frequency not in ('monthly', 'bimonthly', 'semiannual', 'yearly', 'once') then raise exception 'Frequência inválida.'; end if;

  if p_billing_id is null then
    insert into public.provider_billings (user_id, provider_id, description, amount_cents, due_day, due_month, frequency, starts_on)
    values (auth.uid(), p_provider_id, trim(p_description), p_amount_cents, p_due_day, p_due_month, p_frequency, p_starts_on)
    returning id into v_billing_id;
  else
    update public.provider_billings set
      description = trim(p_description), amount_cents = p_amount_cents, due_day = p_due_day,
      due_month = p_due_month, frequency = p_frequency, starts_on = p_starts_on
    where id = p_billing_id and user_id = auth.uid() returning id into v_billing_id;
    if v_billing_id is null then raise exception 'Vencimento não encontrado ou sem permissão.'; end if;
  end if;
  return v_billing_id;
end;
$$;