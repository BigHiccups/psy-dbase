# TODO.md — psy-dbase (backend)

> Tarefas pendentes, organizadas por fase.

**Legenda:** `[ ]` pendente · `[~]` em andamento · `[x]` concluído · `[!]` bloqueado

**URL de produção:** `https://psy-dbase.vercel.app`

---

## 🎯 Próximos 3 passos

1. **Fase 5 (Financeiro)** — consumir `session_price_cents` para calcular
   receitas (pacientes) e despesas (providers)
2. **`provider_billings`** — backend pode precisar de endpoints para CRUD
   de vencimentos de empresas (se o frontend não fizer tudo via RLS)
3. **Escrever no Google Calendar** — Fase 6 completa:
   `events.insert` / `events.patch` / `events.delete` + link do Meet
   automático + envio em cadeia para a agenda do paciente
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

## Fase 3 — Google Calendar

### ✅ Concluído — Leitura + Importação + Revisão

- [x] Tabelas `appointments`, `google_credentials`, `providers`,
      `google_imported_recurrences`
- [x] `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_REDIRECT_URI`
- [x] OAuth Client no Google Cloud
- [x] Escopo `.../auth/calendar` no consent screen
- [x] Contas (teste + oficial) como Test User
- [x] Módulo `calendar`
- [x] `GET /calendar/connect`
- [x] `GET /calendar/callback`
- [x] `GET /calendar/status`
- [x] `GET /calendar/events`
- [x] `POST /calendar/import`
- [x] `DELETE /calendar/disconnect`
- [x] Importação idempotente (2 camadas)
- [x] Status `prospect` em `patients`
- [x] `type` em `appointments` com 4 valores (`session`, `personal`,
      `blocked`, `due`)
- [x] Constraint `appointments_subject_check`
- [x] RPCs: `convert_prospect_to_provider`, `promote_prospect_to_active`,
      `discard_prospect`
- [x] `service_role` rotacionada
- [x] Logs de debug do `auth.ts` removidos

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
- [ ] Reativar paciente recria `appointments` a partir de
      `patient_invite_schedules`
- [ ] Botão "Encerrar tratamento" (cancela futuros, mantém histórico)
- [ ] Cron job semanal para estender horizonte (renovar 90 dias)

### ⏳ Pendente — Vencimentos (`due`)

- [ ] Endpoint `POST /providers/:id/due` — cria N `appointments` tipo `due`
      (parcelas mensais, anuais)
- [ ] Endpoint `POST /providers/:id/due/:id/mark-paid` — marca vencimento como
      pago (cria `expense` na Fase 5)
- [ ] UI de vencimentos (frontend)


### `session_price_cents` (concluído no frontend)

- [x] Coluna `patients.session_price_cents` (SQL direto no Supabase)
- [x] Coluna `providers.session_price_cents` (SQL direto no Supabase)
- [x] Frontend lê, exibe e edita (não envolve o backend Node)
- [ ] Backend consome `session_price_cents` no financeiro (Fase 5)
- [ ] Backend consome `session_price_cents` no recibo (Fase 5)

### `provider_billings` (a implementar)

**Contexto:** prestadores `kind='company'` (curso, plataforma, aluguel) não
têm sessão semanal — têm **vencimento** mensal, bimestral, semestral ou anual.

- [ ] Tabela `provider_billings`:
  - `provider_id`, `description`
  - `amount` (em centavos, mesma unidade de `session_price_cents`)
  - `due_day` (1–31)
  - `frequency` (`monthly` | `bimonthly` | `semiannual` | `yearly` | `once`)
  - `installments_total`, `installments_paid`
  - `starts_on`, `ends_on`, `status`
- [ ] RPC `set_provider_billings`
- [ ] RPC `mark_billing_as_paid`
- [ ] RPC `cancel_provider_billings` (4 modos: imediato, a partir de data,
      suspender, **renovar**)
- [ ] Endpoint backend `POST /providers/:id/billings` (se necessário)
- [ ] Geração de `expenses` correspondentes (Fase 5)

---

## Fase 4 — Transcrição de Áudio

- [ ] Avaliar provedor: Whisper, AssemblyAI, Deepgram
- [ ] Endpoint `POST /transcribe`
- [ ] Extração de palavras-chave
- [ ] Supabase Storage para áudio
- [ ] ⚠️ Timeout das funções Vercel (10s no free) — pode exigir host dedicado

---

## Fase 5 — Recibos em PDF

- [ ] Usar `patients.session_price_cents` como valor base do recibo
- [ ] Usar `appointments` (data, tipo) para compor os itens do recibo
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
- [ ] Avaliar host dedicado se Vercel ficar limitante
- [ ] Auditoria periódica de cruzamento: `appointments.user_id != patients.user_id`
- [ ] Migração para versionar migrations no repositório

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
- [ ] Se o import continua sendo manual ou se roda automaticamente

---

## Concluído (registro histórico)

- **Fase 1 completa:** Express + TS + ESM
- **Fase 2 completa:** `POST /invites` com `schedules`, TinyURL oficial
- **Deploy em produção:** Vercel serverless
- **Fase 3 (leitura + importação + revisão) completa:** OAuth Google Calendar,
  importação idempotente, tabela `providers`, RPCs de revisão
- **Segurança:** `service_role` rotacionada