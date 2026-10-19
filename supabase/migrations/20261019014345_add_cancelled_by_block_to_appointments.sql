-- ============================================================
-- add_cancelled_by_block_to_appointments
-- ============================================================
-- Adiciona a coluna cancelled_by_block_id para rastrear quais
-- agendamentos foram cancelados por um bloqueio. Isso permite
-- reativá-los automaticamente se o bloqueio for removido.
-- ============================================================

alter table public.appointments
  add column if not exists cancelled_by_block_id uuid references public.appointments(id) on delete set null;

comment on column public.appointments.cancelled_by_block_id is
  'ID do appointment (type=blocked) que causou o cancelamento. Usado para reativar se o bloqueio for removido.';