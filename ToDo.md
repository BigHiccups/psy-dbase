# TODO.md — psy-dbase (backend)

> Tarefas pendentes, organizadas por fase.

**Legenda:** `[ ]` pendente · `[~]` em andamento · `[x]` concluído · `[!]` bloqueado

**URL de produção:** `https://psy-dbase.vercel.app`

---

## 🎯 Próximos 3 passos

1. **Escrever no Google Calendar** — ao criar `appointments` no psy-dbase,
   criar evento no Google (`events.insert`); ao cancelar, remover. Fecha o
   ciclo bidirecional.
2. **Link do Meet automático** — gerar `conferenceData` ao criar evento no
   Google, salvar `hangoutLink` no `appointments`.
3. **Cron job para estender horizonte** — renovar `appointments` recorrentes
   quando estiverem a menos de 30 dias do fim.

---

## Fase 1 — Fundação ✅

- [x] Setup Node 20 + Express 5 + TypeScript ESM
- [x] `env.ts` com validação
- [x] `supabaseAdmin` com `service_role` + `ws`
- [x] `requireAuth` validando JWT
- [x] `errorHandler` centralizado
- [x] `GET /health`
- [x] CORS configurável
- [x] `FRONTEND_URL` separado de `CORS_ORIGINS`

---

## Fase 2 — Convites ✅

- [x] Módulo `invites`
- [x] `POST /invites` autenticado
- [x] Normalização de telefone BR → E.164
- [x] TinyURL oficial com fallback
- [x] Link `wa.me`
- [x] `schedules` obrigatórios com validação
- [x] Tabela `patient_invite_schedules`

---

## Fase 3 — Agenda + Google Calendar

### ✅ Concluído — Integração Google (leitura + importação)

- [x] Tabela `appointments`
- [x] Tabela `google_credentials`
- [x] `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_REDIRECT_URI`
- [x] OAuth Client no Google Cloud
- [x] Escopo `.../auth/calendar` no consent screen
- [x] Conta profissional como Test User
- [x] Módulo `calendar`
- [x] `GET /calendar/connect`
- [x] `GET /calendar/callback`
- [x] `GET /calendar/status`
- [x] `GET /calendar/events`
- [x] `POST /calendar/import`
- [x] `DELETE /calendar/disconnect`
- [x] Importação idempotente
- [x] Status `prospect` em `patients`

### ⏳ Pendente — Escrita no Google

- [ ] Criar evento no Google ao criar `appointments`
- [ ] Atualizar evento no Google ao editar `appointments`
- [ ] Remover evento no Google ao cancelar `appointments`
- [ ] Gerar `conferenceData` para link do Meet
- [ ] Salvar `hangoutLink` no `appointments`
- [ ] Convite opcional para o paciente (attendees)

### ⏳ Pendente — Sincronização contínua

- [ ] Webhook do Google (`watch` + `push notifications`) ou polling
- [ ] Resolução de conflitos (psy-dbase vs. Google)
- [ ] Retry em caso de falha
- [ ] Renovação do canal de watch

### ⏳ Pendente — Automação de agendamentos

- [ ] Aprovação de submissão cria `appointments` recorrentes (12 semanas)
- [ ] Arquivar paciente cancela `appointments` futuros
- [ ] Reativar paciente recria `appointments` a partir de `patient_invite_schedules`
- [ ] Botão "Encerrar tratamento" (cancela futuros, mantém histórico)
- [ ] Cron job semanal para estender horizonte (renovar 12 semanas)

---

## Fase 4 — Transcrição de Áudio

- [ ] Avaliar provedor: Whisper, AssemblyAI, Deepgram
- [ ] Endpoint `POST /transcribe`
- [ ] Extração de palavras-chave
- [ ] Supabase Storage para áudio
- [ ] ⚠️ Timeout das funções Vercel (10s no free) — pode exigir host dedicado

---

## Fase 5 — Recibos em PDF

- [ ] Biblioteca de PDF
- [ ] `POST /receipts`
- [ ] Layout do recibo
- [ ] Supabase Storage
- [ ] URL assinada com expiração

---

## Fase 6 — Notificações

### WhatsApp
- [ ] Provedor (Cloud API oficial vs. intermediário)
- [ ] `POST /notifications/whatsapp`
- [ ] Fila de envio

### E-mail
- [ ] Provedor (Resend / SES / Postmark)
- [ ] Templates transacionais
- [ ] `POST /notifications/email`

### Cron
- [ ] Lembrete de sessão (24h antes)
- [ ] Alerta de vencimento
- [ ] Invalidar `share_links` expirados

---

## Transversal — Infra e qualidade

- [ ] Log estruturado (`pino`)
- [ ] Sentry
- [ ] Health check robusto
- [ ] Rate limiting
- [ ] Helmet
- [ ] Validação com Zod
- [ ] Testes unitários (Vitest)
- [ ] CI/CD (GitHub Actions)
- [ ] Node 22 (permite remover `ws`)
- [ ] Rotacionar `service_role` (se necessário)
- [ ] Avaliar host dedicado se Vercel ficar limitante

---

## Decisões pendentes

- [ ] Provedor de WhatsApp
- [ ] Provedor de e-mail
- [ ] Provedor de transcrição
- [ ] Biblioteca de PDF
- [ ] Layout do recibo
- [ ] Quando versionar migrations
- [ ] Quando subir para Node 22
- [ ] Estratégia de sincronização com Google (webhook vs. polling)

---

## Concluído (registro histórico)

- **Fase 1 completa:** Express + TS + ESM, `env.ts`, `supabaseAdmin` com `ws`,
  `requireAuth`, `errorHandler`, CORS
- **Fase 2 completa:** `POST /invites` com `schedules`, TinyURL oficial, `wa.me`
- **Deploy em produção:** Vercel serverless
- **Fase 3 parcial:** integração Google Calendar (OAuth, leitura, importação
  idempotente); tabelas `appointments` + `google_credentials`; status `prospect`
- **Segurança:** `service_role` rotacionada