import { google } from "googleapis";
import { supabaseAdmin } from "../../lib/supabase.js";
import { env } from "../../config/env.js";

// Cria o cliente OAuth2 configurado com nossas credenciais
function createOAuthClient() {
  return new google.auth.OAuth2(
    env.googleClientId,
    env.googleClientSecret,
    env.googleRedirectUri
  );
}

// Gera a URL de autorização do Google
// O usuário acessa essa URL, autoriza, e o Google chama nosso callback
export function getAuthUrl(userId: string): string {
  const oauth2Client = createOAuthClient();

  return oauth2Client.generateAuthUrl({
    access_type: "offline",              // garante refresh_token
    prompt: "consent select_account",    // força consentimento + escolha de conta
    scope: [
      "https://www.googleapis.com/auth/calendar",
    ],
    // Passa o userId no state para recuperar no callback
    state: userId,
  });
}

// Troca o code pelo refresh_token e salva no banco
export async function handleCallback(code: string, userId: string) {
  const oauth2Client = createOAuthClient();

  const { tokens } = await oauth2Client.getToken(code);

  if (!tokens.refresh_token) {
    throw new Error(
      "O Google não retornou refresh_token. " +
      "Remova o acesso do app em myaccount.google.com/permissions e tente novamente."
    );
  }

  // Log temporário: confirma qual conta autorizou
  // (remover depois que validar)
  try {
    const clientForInfo = createOAuthClient();
    clientForInfo.setCredentials(tokens);
    const oauth2 = google.oauth2({ version: "v2", auth: clientForInfo });
    const userInfo = await oauth2.userinfo.get();
  } catch (err) {
    console.warn("[calendar] falha ao consultar e-mail autorizado:", err);
  }

  const { error } = await supabaseAdmin
    .from("google_credentials")
    .upsert({
      user_id: userId,
      refresh_token: tokens.refresh_token,
      access_token: tokens.access_token ?? null,
      expires_at: tokens.expiry_date
        ? new Date(tokens.expiry_date).toISOString()
        : null,
      scope: tokens.scope ?? "https://www.googleapis.com/auth/calendar",
      updated_at: new Date().toISOString(),
    });

  if (error) {
    throw new Error("Falha ao salvar credenciais do Google: " + error.message);
  }
}

// Verifica se o usuário já conectou o Google Calendar
export async function getConnectionStatus(userId: string) {
  const { data, error } = await supabaseAdmin
    .from("google_credentials")
    .select("user_id, scope, created_at, updated_at")
    .eq("user_id", userId)
    .maybeSingle();

  if (error) {
    throw new Error("Falha ao consultar credenciais: " + error.message);
  }

  return {
    connected: !!data,
    scope: data?.scope ?? null,
    connectedAt: data?.created_at ?? null,
  };
}

// Cria um cliente autenticado para chamar a API do Calendar
// (renova o access token automaticamente se estiver expirado)
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

// Desconecta (remove credenciais)
export async function disconnect(userId: string) {
  const { error } = await supabaseAdmin
    .from("google_credentials")
    .delete()
    .eq("user_id", userId);

  if (error) {
    throw new Error("Falha ao desconectar: " + error.message);
  }
}

// =========================================================
// Google Calendar API
// =========================================================

// Lista eventos de um período
// Retorna eventos expandidos (recorrência materializada)
export async function listEvents(
  userId: string,
  timeMin: string,
  timeMax: string
) {
  const auth = await getAuthorizedClient(userId);
  const calendar = google.calendar({ version: "v3", auth });

  const res = await calendar.events.list({
    calendarId: "primary",
    timeMin,
    timeMax,
    singleEvents: true,       // expande eventos recorrentes em ocorrências
    orderBy: "startTime",
    maxResults: 2500,
  });

  return res.data.items ?? [];
}

// =========================================================
// Importação da agenda do Google
// =========================================================

type ImportResult = {
  importedEvents: number;
  importedAppointments: number;
  importedPatients: number;
  skipped: number;
  patients: { id: string; full_name: string }[];
};

// Cria a agenda recorrente no psy-dbase a partir dos eventos do Google
// - Cria um patient provisório (status='prospect') para cada recorrência
// - Cria N appointments (um por ocorrência no período)
// - Idempotência em duas camadas:
//   1) Por recorrência (google_imported_recurrences) — evita recriar
//      pacientes/providers que já foram processados, mesmo que tenham sido
//      convertidos para outro tipo depois
//   2) Por ocorrência (appointments.google_event_id) — evita duplicar slots
export async function importCalendarEvents(
  userId: string,
  daysAhead = 90
): Promise<ImportResult> {
  const now = new Date();
  const end = new Date();
  end.setDate(end.getDate() + daysAhead);

  const events = await listEvents(
    userId,
    now.toISOString(),
    end.toISOString()
  );

  // Agrupa por recurringEventId (eventos avulsos viram seu próprio grupo)
  const groups = new Map<string, typeof events>();
  for (const ev of events) {
    const key = ev.recurringEventId ?? ev.id ?? "";
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

  for (const [, group] of groups) {
    const first = group[0];

    if (!first.start?.dateTime || !first.end?.dateTime) continue;

    const start = new Date(first.start.dateTime);
    const endDt = new Date(first.end.dateTime);

    const weekday = start.getDay();
    const startTime = `${String(start.getHours()).padStart(2, "0")}:${String(
      start.getMinutes()
    ).padStart(2, "0")}`;
    const durationMin = Math.round(
      (endDt.getTime() - start.getTime()) / 60000
    );

    const rawName = first.summary ?? "Sem nome";
    const recurringId = first.recurringEventId ?? first.id ?? null;

    // =====================================================
    // Idempotência por recorrência
    // =====================================================
    let patientId: string | null = null;
    let alreadyImportedAsProvider = false;

    if (recurringId) {
      const { data: existingImports, error: importLookupError } =
        await supabaseAdmin
          .from("google_imported_recurrences")
          .select("user_id, target_type, target_id")
          .eq("user_id", userId)
          .eq("google_recurring_event_id", recurringId);

      // Se houver duplicata, prioriza provider (estado "final" esperado)
      const existingImport =
        existingImports?.find((x) => x.target_type === "provider") ??
        existingImports?.[0];

      if (existingImport) {
        if (existingImport.target_type === "patient") {
          patientId = existingImport.target_id;
        } else {
          alreadyImportedAsProvider = true;
        }
      }
    }

    // Se é provider, pula (não cria appointment do tipo session)
    if (alreadyImportedAsProvider) {
      result.skipped += group.length;
      continue;
    }

    // =====================================================
    // Fallback: procura em patients por nome
    // =====================================================
    if (!patientId) {
      const { data: existingByName } = await supabaseAdmin
        .from("patients")
        .select("id")
        .eq("user_id", userId)
        .eq("full_name", rawName)
        .maybeSingle();

      if (existingByName) {
        patientId = existingByName.id;

        // Backfill: registra a recorrência para os próximos imports
        if (recurringId) {
          await supabaseAdmin
            .from("google_imported_recurrences")
            .insert({
              user_id: userId,
              google_recurring_event_id: recurringId,
              target_type: "patient",
              target_id: existingByName.id,
            });
        }
      }
    }

    // =====================================================
    // Se ainda não achou, cria um provisório novo
    // =====================================================
    if (!patientId) {
      const { data: patient, error: patientError } = await supabaseAdmin
        .from("patients")
        .insert({
          user_id: userId,
          full_name: rawName,
          status: "prospect",
          google_recurring_event_id: recurringId,
        })
        .select()
        .single();

      if (patientError || !patient) {
        console.warn(
          "[calendar.import] falha ao criar paciente:",
          patientError?.message
        );
        continue;
      }

      patientId = patient.id;
      result.importedPatients++;
      result.patients.push({ id: patient.id, full_name: rawName });

      // Registra a recorrência
      if (recurringId) {
        await supabaseAdmin
          .from("google_imported_recurrences")
          .insert({
            user_id: userId,
            google_recurring_event_id: recurringId,
            target_type: "patient",
            target_id: patient.id,
          });
      }
    }

    // =====================================================
    // Cria os appointments (um por ocorrência)
    // =====================================================
    const rows = group
      .filter((ev) => ev.id && ev.start?.dateTime && ev.end?.dateTime)
      .map((ev) => {
        const occStart = new Date(ev.start!.dateTime!);
        const occDate = `${occStart.getFullYear()}-${String(
          occStart.getMonth() + 1
        ).padStart(2, "0")}-${String(occStart.getDate()).padStart(2, "0")}`;

        return {
          user_id: userId,
          patient_id: patientId,
          type: "session" as const,
          weekday,
          start_time: startTime,
          duration_min: durationMin,
          starts_on: occDate,
          ends_on: occDate,
          is_recurring: true,
          status: "active" as const,
          google_event_id: ev.id!,
        };
      });

    // Idempotência dos appointments por google_event_id
    const existingIds = rows.map((r) => r.google_event_id);
    const { data: existing } = await supabaseAdmin
      .from("appointments")
      .select("google_event_id")
      .in("google_event_id", existingIds);

    const existingSet = new Set(
      (existing ?? []).map((e) => e.google_event_id)
    );

    const newRows = rows.filter((r) => !existingSet.has(r.google_event_id));

    result.skipped += rows.length - newRows.length;

    if (newRows.length === 0) continue;

    const { error: apptError, count } = await supabaseAdmin
      .from("appointments")
      .insert(newRows, { count: "exact" });

    if (apptError) {
      console.warn(
        "[calendar.import] falha ao criar appointments:",
        apptError.message
      );
      continue;
    }

    result.importedAppointments += count ?? newRows.length;
  }

  return result;
}