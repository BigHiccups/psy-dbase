-- ============================================================
-- create_provider_billings
-- ============================================================
-- Cria a tabela de vencimentos de prestadores `company`.
-- Representa cobranças recorrentes (aluguel, curso, etc).
-- ============================================================

-- 1. Tabela
create table if not exists public.provider_billings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  provider_id uuid not null references public.providers(id) on delete cascade,
  
  description text not null,
  amount_cents int not null check (amount_cents >= 0),
  
  due_day int not null check (due_day >= 1 and due_day <= 31),
  
  frequency text not null check (
    frequency in ('monthly', 'bimonthly', 'semiannual', 'yearly', 'once')
  ),
  
  starts_on date not null default current_date,
  status text not null default 'active' check (status in ('active', 'archived')),
  
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 2. Índices e Constraints
create index if not exists idx_provider_billings_user on public.provider_billings(user_id);
create index if not exists idx_provider_billings_provider on public.provider_billings(provider_id);

-- 3. RLS e GRANTs
alter table public.provider_billings enable row level security;

create policy "Users can view own provider_billings"
  on public.provider_billings for select
  using (auth.uid() = user_id);

create policy "Users can insert own provider_billings"
  on public.provider_billings for insert
  with check (auth.uid() = user_id);

create policy "Users can update own provider_billings"
  on public.provider_billings for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "Users can delete own provider_billings"
  on public.provider_billings for delete
  using (auth.uid() = user_id);

grant all on public.provider_billings to authenticated;

-- 4. Trigger para updated_at
create or replace function public.set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists set_provider_billings_updated_at on public.provider_billings;
create trigger set_provider_billings_updated_at
  before update on public.provider_billings
  for each row
  execute function public.set_updated_at();

-- ============================================================
-- 5. RPC: set_provider_billing
-- ============================================================
-- Cria ou edita um vencimento.
-- ============================================================
create or replace function public.set_provider_billing(
  p_billing_id uuid, -- se null, cria novo
  p_provider_id uuid,
  p_description text,
  p_amount_cents int,
  p_due_day int,
  p_frequency text,
  p_starts_on date
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
  -- Validação do provider
  select * into v_provider from public.providers where id = p_provider_id;
  if not found then raise exception 'Prestador não encontrado.'; end if;
  if v_provider.user_id <> auth.uid() then raise exception 'Sem permissão.'; end if;
  if v_provider.kind <> 'company' then raise exception 'Apenas empresas têm vencimentos.'; end if;

  -- Validações básicas
  if p_description is null or trim(p_description) = '' then
    raise exception 'Descrição é obrigatória.';
  end if;
  if p_amount_cents < 0 then
    raise exception 'Valor inválido.';
  end if;
  if p_due_day < 1 or p_due_day > 31 then
    raise exception 'Dia de vencimento deve ser entre 1 e 31.';
  end if;
  if p_frequency not in ('monthly', 'bimonthly', 'semiannual', 'yearly', 'once') then
    raise exception 'Frequência inválida.';
  end if;

  if p_billing_id is null then
    -- INSERT
    insert into public.provider_billings (
      user_id, provider_id, description, amount_cents, due_day, frequency, starts_on
    ) values (
      auth.uid(), p_provider_id, trim(p_description), p_amount_cents, p_due_day, p_frequency, p_starts_on
    ) returning id into v_billing_id;
  else
    -- UPDATE
    update public.provider_billings set
      description = trim(p_description),
      amount_cents = p_amount_cents,
      due_day = p_due_day,
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

grant execute on function public.set_provider_billing(uuid, uuid, text, int, int, text, date) to authenticated;

-- ============================================================
-- 6. RPC: archive_provider_billing
-- ============================================================
-- Encerra um vencimento (soft delete). Ele deixa de aparecer na agenda.
-- ============================================================
create or replace function public.archive_provider_billing(p_billing_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.provider_billings
  set status = 'archived'
  where id = p_billing_id and user_id = auth.uid();

  if not found then
    raise exception 'Vencimento não encontrado ou sem permissão.';
  end if;
end;
$$;

grant execute on function public.archive_provider_billing(uuid) to authenticated;

-- ============================================================
-- 7. RPC: delete_provider_billing
-- ============================================================
-- Deleta definitivamente (hard delete).
-- ============================================================
create or replace function public.delete_provider_billing(p_billing_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.provider_billings
  where id = p_billing_id and user_id = auth.uid();

  if not found then
    raise exception 'Vencimento não encontrado ou sem permissão.';
  end if;
end;
$$;

grant execute on function public.delete_provider_billing(uuid) to authenticated;