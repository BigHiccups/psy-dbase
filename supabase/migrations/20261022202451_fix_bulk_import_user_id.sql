-- Remove a versão antiga que não recebia o p_user_id
DROP FUNCTION IF EXISTS public.bulk_import_google_calendar(jsonb);

CREATE OR REPLACE FUNCTION public.bulk_import_google_calendar(
  p_user_id uuid,
  p_events jsonb
) RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event jsonb;
  v_patient_id uuid;
  v_recurring_id text;
  v_raw_name text;
  v_start_time time;
  v_weekday int;
  v_anchor_date date;
  v_duration int;
  v_inserted_count int := 0;
BEGIN
  FOR v_event IN SELECT * FROM jsonb_array_elements(p_events)
  LOOP
    v_recurring_id := v_event->>'recurringId';
    v_raw_name := v_event->>'rawName';
    v_start_time := (v_event->>'startTime')::time;
    v_weekday := (v_event->>'weekday')::int;
    v_anchor_date := (v_event->>'anchorDate')::date;
    v_duration := (v_event->>'durationMin')::int;

    SELECT id INTO v_patient_id 
    FROM public.patients 
    WHERE user_id = p_user_id 
      AND (google_recurring_event_id = v_recurring_id OR full_name = v_raw_name)
    LIMIT 1;

    IF v_patient_id IS NULL THEN
      INSERT INTO public.patients (user_id, full_name, status, google_recurring_event_id)
      VALUES (p_user_id, v_raw_name, 'prospect', v_recurring_id)
      RETURNING id INTO v_patient_id;
      
      INSERT INTO public.google_imported_recurrences (user_id, google_recurring_event_id, target_type, target_id)
      VALUES (p_user_id, v_recurring_id, 'patient', v_patient_id)
      ON CONFLICT DO NOTHING;
    END IF;

    IF v_patient_id IS NOT NULL THEN
      INSERT INTO public.patient_schedules (
        user_id, patient_id, weekday, start_time, duration_min, recurrence_type, anchor_date
      ) VALUES (
        p_user_id, v_patient_id, v_weekday, v_start_time, v_duration, 'weekly', v_anchor_date
      ) ON CONFLICT DO NOTHING;
      
      v_inserted_count := v_inserted_count + 1;
    END IF;
  END LOOP;

  RETURN v_inserted_count;
END;
$$;