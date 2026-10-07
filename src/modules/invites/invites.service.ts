import { supabaseAdmin } from "../../lib/supabase.js";
import { shortenUrl } from "../../lib/tinyurl.js";
import { normalizePhoneBR } from "../../utils/phone.js";
import { buildWhatsAppLink } from "../../utils/whatsapp.js";
import { env } from "../../config/env.js";
import type {
  CreateInviteInput,
  CreateInviteResult,
} from "./invites.types.js";

// Cria o convite, os horários e devolve o link do WhatsApp pronto
export async function createInvite(
  input: CreateInviteInput
): Promise<CreateInviteResult> {
  const phone = normalizePhoneBR(input.phone);

  // 1) Insere o convite
  const { data: invite, error: inviteError } = await supabaseAdmin
    .from("patient_invites")
    .insert({
      user_id: input.userId,
      patient_name_hint: input.patientNameHint ?? null,
      phone,
    })
    .select()
    .single();

  if (inviteError || !invite) {
    throw new Error("Falha ao criar convite: " + inviteError?.message);
  }

  // 2) Insere os horários vinculados
  const scheduleRows = input.schedules.map((s) => ({
    invite_id: invite.id,
    user_id: input.userId,
    weekday: s.weekday,
    start_time: s.startTime,
    duration_min: s.durationMin ?? 50,
  }));

  const { error: schedulesError } = await supabaseAdmin
    .from("patient_invite_schedules")
    .insert(scheduleRows);

  if (schedulesError) {
    // Rollback manual: remove o convite para não deixar órfão
    await supabaseAdmin.from("patient_invites").delete().eq("id", invite.id);
    throw new Error("Falha ao salvar horários: " + schedulesError.message);
  }

  // 3) Encurta a URL (com fallback)
  const publicUrl = `${env.frontendUrl}/form/${invite.token}`;
  const shortUrl = await shortenUrl(publicUrl);

  // 4) Monta a mensagem do WhatsApp
  const message = `Oi, gostaria que fizesse seu cadastro, segue o link: ${shortUrl}`;
  const whatsappUrl = buildWhatsAppLink(phone, message);

  return {
    inviteId: invite.id,
    token: invite.token,
    publicUrl,
    shortUrl,
    whatsappUrl,
    phone,
    schedules: input.schedules.map((s) => ({
      weekday: s.weekday,
      startTime: s.startTime,
      durationMin: s.durationMin ?? 50,
    })),
  };
}