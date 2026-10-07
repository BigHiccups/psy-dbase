import { randomUUID } from "node:crypto";
import { supabaseAdmin } from "../../lib/supabase.js";
import { shortenUrl } from "../../lib/tinyurl.js";
import { normalizePhoneBR } from "../../utils/phone.js";
import { buildWhatsAppLink } from "../../utils/whatsapp.js";
import { env } from "../../config/env.js";

type CreateInviteInput = {
  userId: string;
  patientNameHint?: string;
  phone: string;
};

// Cria o convite, gera short link e devolve o link do WhatsApp pronto
export async function createInvite(input: CreateInviteInput) {
  const phone = normalizePhoneBR(input.phone);

  const { data: invite, error } = await supabaseAdmin
    .from("patient_invites")
    .insert({
      user_id: input.userId,
      patient_name_hint: input.patientNameHint ?? null,
      // Armazena o telefone para uso futuro (não obrigatório no schema ainda)
    })
    .select()
    .single();

  if (error || !invite) {
    throw new Error("Falha ao criar convite: " + error?.message);
  }

  const publicUrl = `${env.frontendUrl}/form/${invite.token}`;
  const shortUrl = await shortenUrl(publicUrl);

  const message = `Oi, gostaria que fizesse seu cadastro, segue o link: ${shortUrl}`;
  const whatsappUrl = buildWhatsAppLink(phone, message);

  return {
    inviteId: invite.id,
    token: invite.token,
    publicUrl,
    shortUrl,
    whatsappUrl,
    phone,
  };
}