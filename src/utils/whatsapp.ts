// Monta link wa.me com mensagem pré-preenchida
export function buildWhatsAppLink(phoneE164: string, message: string): string {
  return `https://wa.me/${phoneE164}?text=${encodeURIComponent(message)}`;
}