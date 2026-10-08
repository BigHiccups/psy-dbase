import { env } from "../config/env.js";

// Gera URL curta via API oficial do TinyURL (com autenticação)
// Envia User-Agent e Bearer token para evitar interstitials e bloqueios
export async function shortenUrl(longUrl: string): Promise<string> {
  const endpoint = "https://api.tinyurl.com/create";

  try {
    const res = await fetch(endpoint, {
      method: "POST",
      headers: {
        "User-Agent": "psy-dbase/1.0",
        "Authorization": `Bearer ${env.tinyurlApiToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ url: longUrl }),
    });

    if (!res.ok) {
      console.warn("[tinyurl] resposta não-ok:", res.status);
      return longUrl; // fallback: devolve a URL original
    }

    const data = await res.json();
    const short = data.data?.tiny_url;

    // Valida se a resposta tem o formato esperado
    if (typeof short !== "string" || !short.startsWith("http")) {
      console.warn("[tinyurl] resposta inesperada:", data);
      return longUrl; // fallback
    }

    return short;
  } catch (err) {
    console.warn("[tinyurl] erro na chamada:", err);
    return longUrl; // fallback: devolve a URL original
  }
}