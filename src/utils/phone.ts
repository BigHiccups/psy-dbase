// Normaliza telefone brasileiro para formato internacional (5511999999999)
// Aceita: "(11) 99999-9999", "11999999999", "+55 11 99999-9999", etc.
export function normalizePhoneBR(input: string): string {
  const digits = input.replace(/\D/g, "");

  // Se já vem com 55 e tamanho de 12 ou 13, mantém
  if ((digits.length === 12 || digits.length === 13) && digits.startsWith("55")) {
    return digits;
  }

  // Se tem 10 ou 11 dígitos, prefixa 55
  if (digits.length === 10 || digits.length === 11) {
    return `55${digits}`;
  }

  throw new Error("Telefone inválido.");
}