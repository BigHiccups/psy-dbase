-- ============================================================
-- add_recurrence_fields
-- ============================================================
-- Adiciona suporte a frequência configurável nas séries recorrentes.
-- Esta migration SÓ adiciona colunas e a função auxiliar. Não toca
-- nas RPCs existentes — elas continuam funcionando com 'weekly' fixo.
--
-- Tipos suportados:
--   once           → só a primeira ocorrência
--   weekly         → a cada 7 dias (comportamento atual, vira default)
--   biweekly       → a cada 14 dias
--   monthly        → mesmo dia do mês (+1 month, Postgres ajusta pro
--                    último dia do mês quando não existe)
--   every_30_days  → a cada 30 dias
--   custom_days    → a cada N dias (N = recurrence_days, 1..365)
-- ============================================================


-- ============================================================
-- 1) Colunas em patient_schedules
-- ============================================================
alter table public.patient_schedules
  add column if not exists recurrence_type text not null default 'weekly';

alter table public.patient_schedules
  add column if not exists recurrence_days int;

-- CHECK do enum de tipos
alter table public.patient_schedules
  drop constraint if exists patient_schedules_recurrence_type_check;
alter table public.patient_schedules
  add constraint patient_schedules_recurrence_type_check
  check (recurrence_type in (
    'once', 'weekly', 'biweekly', 'monthly', 'every_30_days', 'custom_days'
  ));

-- CHECK do range de recurrence_days
alter table public.patient_schedules
  drop constraint if exists patient_schedules_recurrence_days_range_check;
alter table public.patient_schedules
  add constraint patient_schedules_recurrence_days_range_check
  check (recurrence_days is null or (recurrence_days >= 1 and recurrence_days <= 365));

-- CHECK de coerência: custom_days exige days, outros proíbem
alter table public.patient_schedules
  drop constraint if exists patient_schedules_recurrence_coherence_check;
alter table public.patient_schedules
  add constraint patient_schedules_recurrence_coherence_check
  check (
    (recurrence_type = 'custom_days' and recurrence_days is not null)
    or (recurrence_type <> 'custom_days' and recurrence_days is null)
  );


-- ============================================================
-- 2) Colunas em provider_schedules
-- ============================================================
alter table public.provider_schedules
  add column if not exists recurrence_type text not null default 'weekly';

alter table public.provider_schedules
  add column if not exists recurrence_days int;

alter table public.provider_schedules
  drop constraint if exists provider_schedules_recurrence_type_check;
alter table public.provider_schedules
  add constraint provider_schedules_recurrence_type_check
  check (recurrence_type in (
    'once', 'weekly', 'biweekly', 'monthly', 'every_30_days', 'custom_days'
  ));

alter table public.provider_schedules
  drop constraint if exists provider_schedules_recurrence_days_range_check;
alter table public.provider_schedules
  add constraint provider_schedules_recurrence_days_range_check
  check (recurrence_days is null or (recurrence_days >= 1 and recurrence_days <= 365));

alter table public.provider_schedules
  drop constraint if exists provider_schedules_recurrence_coherence_check;
alter table public.provider_schedules
  add constraint provider_schedules_recurrence_coherence_check
  check (
    (recurrence_type = 'custom_days' and recurrence_days is not null)
    or (recurrence_type <> 'custom_days' and recurrence_days is null)
  );


-- ============================================================
-- 3) Função auxiliar: compute_next_occurrence
-- ============================================================
-- Recebe a data atual da ocorrência, o tipo de recorrência e os dias
-- (só pra custom_days) e devolve a próxima data. Retorna null em 'once'.
-- IMMUTABLE: sempre dá o mesmo resultado pra mesma entrada.
-- ============================================================
create or replace function public.compute_next_occurrence(
  p_current date,
  p_recurrence_type text,
  p_recurrence_days int default null
)
returns date
language plpgsql
immutable
as $$
begin
  case p_recurrence_type
    when 'once'          then return null;
    when 'weekly'        then return p_current + interval '7 days';
    when 'biweekly'      then return p_current + interval '14 days';
    when 'every_30_days' then return p_current + interval '30 days';
    when 'monthly'       then return p_current + interval '1 month';
    when 'custom_days'   then
      if p_recurrence_days is null then
        raise exception 'recurrence_days é obrigatório para custom_days';
      end if;
      return p_current + (p_recurrence_days || ' days')::interval;
    else
      raise exception 'recurrence_type inválido: %', p_recurrence_type;
  end case;
end;
$$;

comment on function public.compute_next_occurrence(date, text, int) is
  'Calcula a próxima data de uma série recorrente. Retorna NULL em ''once''.';