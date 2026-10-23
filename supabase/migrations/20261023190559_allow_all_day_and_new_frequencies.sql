-- 1. Permite horário nulo e duração nula (para boletos que valem o dia todo)
ALTER TABLE public.appointments ALTER COLUMN start_time DROP NOT NULL;
ALTER TABLE public.appointments ALTER COLUMN duration_min DROP NOT NULL;
ALTER TABLE public.appointments DROP CONSTRAINT IF EXISTS appointments_duration_min_check;
ALTER TABLE public.appointments ADD CONSTRAINT appointments_duration_min_check CHECK (duration_min IS NULL OR (duration_min >= 15 AND duration_min <= 240));

-- 2. Permite as novas frequências na tabela de horários
ALTER TABLE public.patient_schedules DROP CONSTRAINT IF EXISTS patient_schedules_recurrence_type_check;
ALTER TABLE public.patient_schedules ADD CONSTRAINT patient_schedules_recurrence_type_check CHECK (recurrence_type IN (
  'once', 'weekly', 'biweekly', 'monthly', 'bimonthly', 'quarterly', 'semiannual', 'yearly', 'every_30_days', 'custom_days'
));

-- 3. Atualiza a função de próximo passo para lidar com as novas frequências
CREATE OR REPLACE FUNCTION public.compute_next_occurrence(
  p_current date,
  p_recurrence_type text,
  p_recurrence_days int default null,
  p_anchor_date date default null
)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  CASE p_recurrence_type
    WHEN 'once' THEN RETURN NULL;
    WHEN 'weekly' THEN RETURN p_current + interval '7 days';
    WHEN 'biweekly' THEN RETURN p_current + interval '14 days';
    WHEN 'every_30_days' THEN RETURN p_current + interval '30 days';
    WHEN 'monthly' THEN RETURN p_current + interval '1 month';
    WHEN 'bimonthly' THEN RETURN p_current + interval '2 months';
    WHEN 'quarterly' THEN RETURN p_current + interval '3 months';
    WHEN 'semiannual' THEN RETURN p_current + interval '6 months';
    WHEN 'yearly' THEN RETURN p_current + interval '1 year';
    WHEN 'custom_days' THEN 
      IF p_recurrence_days IS NULL THEN RAISE EXCEPTION 'dias obrigatorios'; END IF;
      RETURN p_current + (p_recurrence_days || ' days')::interval;
    ELSE RAISE EXCEPTION 'Tipo invalido';
  END CASE;
END;
$$;