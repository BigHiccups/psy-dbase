// Gera URL curta via API pública do TinyURL (sem chave)
export async function shortenUrl(longUrl: string): Promise<string> {
  const endpoint = `https://tinyurl.com/api-create.php?url=${encodeURIComponent(longUrl)}`;
  const res = await fetch(endpoint);
  if (!res.ok) throw new Error("Falha ao gerar URL curta.");
  return (await res.text()).trim();
}