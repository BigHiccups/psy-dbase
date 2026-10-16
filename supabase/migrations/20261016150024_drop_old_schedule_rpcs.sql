-- ============================================================
-- drop_old_schedule_rpcs
-- ============================================================
-- Dropa as versões antigas (3/4 args) das RPCs de schedule.
-- A migração da Frequência Configurável criou versões novas
-- (5 args) que coexistem com as antigas. Agora que o frontend
-- já usa as novas em produção, as antigas podem sair.
--
-- RPCs que ficam:
--   set_patient_schedules(uuid, jsonb, text, int, int)
--   set_provider_schedules(uuid, jsonb, text, int, int)
--   cancel_appointment_series(uuid, text, date, date, int)
--   cancel_provider_appointment_series(uuid, text, date, date, int)
--   compute_next_occurrence(date, text, int, date)
--   promote_prospect_to_active(uuid, jsonb, text, int)
--
-- RPCs que saem:
--   set_patient_schedules(uuid, jsonb, int)
--   set_provider_schedules(uuid, jsonb, int)
--   cancel_appointment_series(uuid, text, date, date)
--   cancel_provider_appointment_series(uuid, text, date, date)
-- ============================================================

-- ============================================================
-- 1) set_patient_schedules (versão antiga)
-- ============================================================
drop function if exists public.set_patient_schedules(uuid, jsonb, int);

-- ============================================================
-- 2) set_provider_schedules (versão antiga)
-- ============================================================
drop function if exists public.set_provider_schedules(uuid, jsonb, int);

-- ============================================================
-- 3) cancel_appointment_series (versão antiga)
-- ============================================================
drop function if exists public.cancel_appointment_series(uuid, text, date, date);

-- ============================================================
-- 4) cancel_provider_appointment_series (versão antiga)
-- ============================================================
drop function if exists public.cancel_provider_appointment_series(uuid, text, date, date);