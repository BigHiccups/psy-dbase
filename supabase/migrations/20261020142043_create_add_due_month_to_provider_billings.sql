-- ============================================================
-- add_due_month_to_provider_billings
-- ============================================================
-- Adiciona due_month (1..12) para vencimentos anuais.
-- Em 'yearly', o mês do vencimento passa a ser explícito
-- (due_month + due_day). Nas demais frequências, due_month = NULL.
--
-- Também recria set_provider_billing com p_due_month.
-- A versão antiga (7 args) é dropada para evitar overload ambíguo
-- no PostgREST ("Could not choose the best candidate function").
-- ============================================================

-- 1) Coluna
alter table public.provider_billings
  add column if not exists due_month int;

comment on column public.provider_billings.due_month is
  'Mês do vencimento (1-12). Obrigatório quando frequency = ''yearly''; NULL nas demais.';

-- 2) Backfill dos yearly existentes a partir de starts_on
--    (não dá pra adivinhar o mês original; starts_on é a melhor aproximação)
update public.provider_billings
set due_month = extract(month from starts_on)::int
where frequency = 'yearly'
  and due_month is null;

-- 3) Constraints
alter table public.provider_billings
  drop constraint if exists provider_billings_due_month_range_check;
alter table public.provider_billings
  add constraint provider_billings_due_month_range_check
  check (due_month is null or (due_month >= 1 and due_month <= 12));

alter table public.provider_billings
  drop constraint if exists provider_billings_due_month_coherence_check;
alter table public.provider_billings
  add constraint provider_billings_due_month_coherence_check
  check (
    (frequency = 'yearly' and due_month is not null)
    or (frequency <> 'yearly' and due_month is null)
  );

-- 4) RPC: dropa a versão antiga (7 args) e cria a nova (8 args)
drop function if exists public.set_provider_billing(
  uuid, uuid, text, int, int, text, date
);

create or replace function public.set_provider_billing(
  p_billing_id uuid,
  p_provider_id uuid,
  p_description text,
  p_amount_cents int,
  p_due_day int,
  p_frequency text,
  p_starts_on date,
  p_due_month int default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_provider public.providers;
  v_billing_id uuid;
begin
  select * into v_provider from public.providers where id = p_provider_id;
  if not found then raise exception 'Prestador não encontrado.'; end if;
  if v_provider.user_id <> auth.uid() then raise exception 'Sem permissão.'; end if;
  if v_provider.kind <> 'company' then
    raise exception 'Apenas empresas têm vencimentos.';
  end if;

  if p_description is null or trim(p_description) = '' then
    raise exception 'Descrição é obrigatória.';
  end if;
  if p_amount_cents is null or p_amount_cents < 0 then
    raise exception 'Valor inválido.';
  end if;
  if p_due_day is null or p_due_day < 1 or p_due_day > 31 then
    raise exception 'Dia de vencimento deve ser entre 1 e 31.';
  end if;
  if p_frequency not in ('monthly', 'bimonthly', 'semiannual', 'yearly', 'once') then
    raise exception 'Frequência inválida.';
  end if;
  if p_starts_on is null then
    raise exception 'Data de início é obrigatória.';
  end if;

  -- Coerência do due_month
  if p_frequency = 'yearly' then
    if p_due_month is null then
      raise exception 'Mês do vencimento é obrigatório para frequência anual.';
    end if;
    if p_due_month < 1 or p_due_month > 12 then
      raise exception 'Mês do vencimento deve estar entre 1 e 12.';
    end if;
  else
    if p_due_month is not null then
      raise exception 'Mês do vencimento só é permitido para frequência anual.';
    end if;
  end if;

  if p_billing_id is null then
    insert into public.provider_billings (
      user_id, provider_id, description, amount_cents,
      due_day, due_month, frequency, starts_on
    ) values (
      auth.uid(), p_provider_id, trim(p_description), p_amount_cents,
      p_due_day, p_due_month, p_frequency, p_starts_on
    ) returning id into v_billing_id;
  else
    update public.provider_billings set
      description = trim(p_description),
      amount_cents = p_amount_cents,
      due_day = p_due_day,
      due_month = p_due_month,
      frequency = p_frequency,
      starts_on = p_starts_on
    where id = p_billing_id and user_id = auth.uid()
    returning id into v_billing_id;

    if v_billing_id is null then
      raise exception 'Vencimento não encontrado ou sem permissão.';
    end if;
  end if;

  return v_billing_id;
end;
$$;

alter function public.set_provider_billing(uuid, uuid, text, int, int, text, date, int)
  owner to postgres;

grant execute on function public.set_provider_billing(uuid, uuid, text, int, int, text, date, int)
  to authenticated;