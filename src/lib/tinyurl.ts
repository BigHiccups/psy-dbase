export async function shortenUrl(longUrl: string): Promise<string> {
  const endpoint = `https://tinyurl.com/api-create.php?url=${encodeURIComponent(longUrl)}`;

  try {
    const res = await fetch(endpoint, {
      headers: {
        "User-Agent": "psy-dbase/1.0",
        Accept: "text/plain",
      },
    });

    const body = await res.text();
    console.log("[tinyurl] status:", res.status);
    console.log("[tinyurl] body:", body.slice(0, 120));

    if (!res.ok || !body.startsWith("http")) {
      return longUrl;
    }

    return body.trim();
  } catch (err) {
    console.warn("[tinyurl] erro:", err);
    return longUrl;
  }
}