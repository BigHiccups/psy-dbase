import { google } from "googleapis";
import { supabaseAdmin } from "../../lib/supabase.js";
import { env } from "../../config/env.js";

function createOAuthClient() {
  return new google.auth.OAuth2(
    env.googleClientId,
    env.googleClientSecret,
    env.googleRedirectUri
  );
}

export function getAuthUrl(userId: string): string {
  const oauth2Client = createOAuthClient();
  return oauth2Client.generateAuthUrl({
    access_type: "offline",
    prompt: "consent select_account",
    scope: ["https://www.googleapis.com/auth/calendar"],
    state: userId,
  });
}

export async function handleCallback(code: string, userId: string) {
  const oauth2Client = createOAuthClient();
  const { tokens } = await oauth2Client.getToken(code);

  if (!tokens.refresh_token) {
    throw new Error("O Google não retornou refresh_token.");
  }

  const { error } = await supabaseAdmin
    .from("google_credentials")
    .upsert({
      user_id: userId,
      refresh_token: tokens.refresh_token,
      access_token: tokens.access_token ?? null,
      expires_at: tokens.expiry_date ? new Date(tokens.expiry_date).toISOString() : null,
      scope: tokens.scope ?? "https://www.googleapis.com/auth/calendar",
      updated_at: new Date().toISOString(),
    });

  if (error) throw new Error("Falha ao salvar credenciais: " + error.message);
}

export async function getConnectionStatus(userId: string) {
  const { data, error } = await supabaseAdmin
    .from("google_credentials")
    .select("user_id, scope, created_at, updated_at")
    .eq("user_id", userId)
    .maybeSingle();

  if (error) throw new Error("Falha ao consultar credenciais: " + error.message);

  return {
    connected: !!data,
    scope: data?.scope ?? null,
    connectedAt: data?.created_at ?? null,
  };
}

export async function getAuthorizedClient(userId: string) {
  const { data, error } = await supabaseAdmin
    .from("google_credentials")
    .select("refresh_token")
    .eq("user_id", userId)
    .maybeSingle();

  if (error || !data?.refresh_token) {
    throw new Error("Usuário não conectou o Google Calendar.");
  }

  const oauth2Client = createOAuthClient();
  oauth2Client.setCredentials({ refresh_token: data.refresh_token });
  return oauth2Client;
}

export async function disconnect(userId: string) {
  const { error } = await supabaseAdmin
    .from("google_credentials")
    .delete()
    .eq("user_id", userId);

  if (error) throw new Error("Falha ao desconectar: " + error.message);
}

export async function listEvents(userId: string, timeMin: string, timeMax: string) {
  const auth = await getAuthorizedClient(userId);
  const calendar = google.calendar({ version: "v3", auth });

  const res = await calendar.events.list({
    calendarId: "primary",
    timeMin,
    timeMax,
    singleEvents: true,
    orderBy: "startTime",
    maxResults: 2500,
  });

  return res.data.items ?? [];
}

type ImportResult = {
  importedEvents: number;
  importedAppointments: number;
  importedPatients: number;
  skipped: number;
  patients: { id: string; full_name: string }[];
};

export async function importCalendarEvents(
  userId: string,
  daysAhead = 90
): Promise<ImportResult> {
  const now = new Date();
  const end = new Date();

  now.setDate(now.getDate() - 60); // 60 dias para trás
  end.setDate(end.getDate() + daysAhead);

  const events = await listEvents(userId, now.toISOString(), end.toISOString());

  const groups = new Map<string, typeof events>();
  for (const ev of events) {
    // Se for uma exceção (remarcação), tratamos como um grupo independente
    const isException = !!ev.originalStartTime;
    const key = (ev.recurringEventId && !isException) ? ev.recurringEventId : ev.id;
    
    if (!key) continue;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key)!.push(ev);
  }

  const result: ImportResult = {
    importedEvents: events.length,
    importedAppointments: 0,
    importedPatients: 0,
    skipped: 0,
    patients: [],
  };

  const timeFormatter = new Intl.DateTimeFormat("pt-BR", {
    timeZone: "America/Sao_Paulo", hour: "2-digit", minute: "2-digit", hour12: false,
  });
  const weekdayFormatter = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Sao_Paulo", weekday: "short",
  });
  const isoDateFormatter = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Sao_Paulo", year: "numeric", month: "2-digit", day: "2-digit",
  });
  const weekdayMap: Record<string, number> = {
    "Sun": 0, "Mon": 1, "Tue": 2, "Wed": 3, "Thu": 4, "Fri": 5, "Sat": 6,
  };

  // Listas para inserir em lote no final
  const patientsToInsert: any[] = [];
  const schedulesToInsert: any[] = [];
  const appointmentsToInsert: any[] = [];
  const recurrencesToInsert: any[] = [];

  // 1. Processa tudo em memória (MUITO RÁPIDO)
  for (const [, group] of groups) {
    let earliestEvent = group[0];
    let earliestTime = Infinity;

    for (const ev of group) {
      let dtStr = ev.start?.dateTime || (ev.start?.date ? `${ev.start.date}T08:00:00` : "");
      if (dtStr) {
        const time = new Date(dtStr).getTime();
        if (time < earliestTime) {
          earliestTime = time;
          earliestEvent = ev;
        }
      }
    }

    const first = earliestEvent;
    let startDateTimeStr = first.start?.dateTime || (first.start?.date ? `${first.start.date}T08:00:00` : "");
    if (!startDateTimeStr) continue;

    const start = new Date(startDateTimeStr);
    let startTime = timeFormatter.format(start);
    if (startTime === "24:00") startTime = "00:00";

    const weekday = weekdayMap[weekdayFormatter.format(start)] ?? 1;
    const anchorDate = isoDateFormatter.format(start);

    let durationMin = 60;
    if (first.end?.dateTime && first.start?.dateTime) {
      const endDt = new Date(first.end.dateTime);
      durationMin = Math.round((endDt.getTime() - start.getTime()) / 60000);
      if (durationMin < 15) durationMin = 50;
      if (durationMin > 240) durationMin = 240;
    }

    const rawName = first.summary ?? "Sem nome";
    const recurringId = first.recurringEventId ?? first.id ?? null;

    // Verifica se o paciente já existe (MOCK - Para simplificar, vamos salvar todos e o banco lida com duplicados via ID)
    // Como não podemos gerar IDs antes de inserir pacientes, vamos inserir os pacientes primeiro.
    
    // Para evitar N+1, geramos um ID provisório para o paciente se ele não existir
    const existingPatientId = null; // O ideal seria um bulk upsert, mas vamos usar o fluxo atual simplificado

    // Como o Supabase não permite relacionar IDs gerados aleatoriamente em lote sem upsert complexo,
    // Vamos manter a criação do paciente individual, mas otimizar o resto.
    
    let patientId: string | null = null;
    if (recurringId) {
      const { data: existingImport } = await supabaseAdmin
        .from("google_imported_recurrences")
        .select("target_id")
        .eq("user_id", userId)
        .eq("google_recurring_event_id", recurringId)
        .maybeSingle();
      if (existingImport) patientId = existingImport.target_id;
    }

    if (!patientId) {
      const { data: existingByName } = await supabaseAdmin
        .from("patients")
        .select("id")
        .eq("user_id", userId)
        .eq("full_name", rawName)
        .maybeSingle();
      if (existingByName) patientId = existingByName.id;
    }

    if (!patientId) {
      const { data: patient } = await supabaseAdmin
        .from("patients")
        .insert({
          user_id: userId,
          full_name: rawName,
          status: "prospect",
          google_recurring_event_id: recurringId,
        })
        .select("id")
        .single();

      if (patient) {
        patientId = patient.id;
        result.importedPatients++;
        result.patients.push({ id: patient.id, full_name: rawName });
      }
    }

    if (!patientId) continue;

    if (recurringId) {
      recurrencesToInsert.push({
        user_id: userId,
        google_recurring_event_id: recurringId,
        target_type: "patient",
        target_id: patientId,
      });
    }

    const isRecurring = recurringId !== null && first.recurringEventId !== undefined && !first.originalStartTime;

    if (isRecurring) {
      schedulesToInsert.push({
        user_id: userId,
        patient_id: patientId,
        weekday: weekday,
        start_time: startTime,
        duration_min: durationMin,
        recurrence_type: "weekly",
        anchor_date: anchorDate,
      });
    } else {
      appointmentsToInsert.push({
        user_id: userId,
        patient_id: patientId,
        type: "session",
        weekday: weekday,
        start_time: startTime,
        duration_min: durationMin,
        starts_on: anchorDate,
        ends_on: anchorDate,
        is_recurring: false,
        status: "active",
        google_event_id: first.id,
      });
    }
  }

  // 2. INSERÇÃO EM LOTE (O Segredo da Velocidade)
  if (recurrencesToInsert.length > 0) {
    await supabaseAdmin.from("google_imported_recurrences").upsert(recurrencesToInsert, { onConflict: "user_id,google_recurring_event_id" });
  }

  if (schedulesToInsert.length > 0) {
    await supabaseAdmin.from("patient_schedules").insert(schedulesToInsert);
    result.importedAppointments += schedulesToInsert.length;
  }

  if (appointmentsToInsert.length > 0) {
    // Ignora duplicados de google_event_id se já existirem
    await supabaseAdmin.from("appointments").upsert(appointmentsToInsert, { onConflict: "google_event_id" });
    result.importedAppointments += appointmentsToInsert.length;
  }

  return result;
}