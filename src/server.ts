import { createApp } from "./app.js";
import { env } from "./config/env.js";

const app = createApp();

// Em produção na Vercel, o app é exportado como handler serverless.
// Localmente (npm run dev), chamamos listen normalmente.
if (process.env.VERCEL !== "1") {
  app.listen(env.port, () => {
    console.log(`API rodando em http://localhost:${env.port}`);
  });
}

export default app;