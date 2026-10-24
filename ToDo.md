# TODO.md — psy-dbase (backend)

> Tarefas pendentes, organizadas por fase.

**Legenda:** `[ ]` pendente · `[~]` em andamento · `[x]` concluído · `[!]` bloqueado

**URL de produção:** `https://psy-dbase.vercel.app`

---

## 🎯 Próximos 3 passos

1. **Fase 4 (Prontuário)** — Endpoint de transcrição de áudio (avaliar provedores e timeout da Vercel).
2. **Fase 5b (Recibos)** — Geração de PDF com base nas `transactions` e upload para o Supabase Storage.
3. **Fase 6 (Calendar Escrita)** — Implementar `events.insert` e `events.delete` para sincronizar o psy-dbase de volta com o Google Calendar.

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

## Fase 3 — Google Calendar (Leitura, Importação e Revisão) ✅

### ✅ Concluído — Leitura + Importação Refatorada
- [x] Módulo `calendar` (connect / callback / status / disconnect).
- [x] Tabelas `google_credentials`, `google_imported_recurrences`.
- [x] **Correção de Fuso Horário:** Uso de `Intl.DateTimeFormat` com `America/Sao_Paulo`.
- [x] **Tratamento de Dia Inteiro:** Eventos sem hora assumem `08:00` e duração de 60min.
- [x] **Otimização de Importação (Timeout Vercel):** A importação agora monta um JSON em memória e envia para a RPC `bulk_import_google_calendar` (Bulk Insert). Não há mais loops N+1, resolvendo o erro de 10s.
- [x] **Materialização Adiada:** A importação não cria mais `appointments` direto. Ela cria o `prospect` e salva em `patient_schedules`. A agenda só é gerada quando o usuário aprova no Dashboard.
- [x] Separação de exceções (remarcações avulsas) de eventos recorrentes.
- [x] Status `prospect` em `patients`.
- [x] RPCs de revisão: `convert_prospect_to_provider`, `promote_prospect_to_active`, `discard_prospect`.
- [x] **Vínculo de Existente:** RPC `merge_prospect_into_patient` para unificar importações a pacientes já cadastrados.

### ⏳ Pendente — Escrita no Google (Fase 6)
- [ ] Criar evento no Google ao criar `appointments`.
- [ ] Atualizar evento no Google ao editar `appointments`.
- [ ] Remover evento no Google ao cancelar `appointments`.
- [ ] Gerar `conferenceData` para link do Meet.
- [ ] Salvar `hangoutLink` no `appointments`.
- [ ] Convite opcional para o paciente (attendees).
- [ ] Sincronização contínua (Webhook / Polling).
- [ ] Resolução de conflitos (psy-dbase vs. Google).
- [ ] Cron job semanal para estender horizonte (renovar 90 dias).

---

## Fase 3b — Arquitetura Multi-Serviços e Financeiro ✅

### ✅ Concluído — Schedules, Cores e Multi-Serviços
- [x] **Colunas Adicionadas:** `title`, `color`, `session_price_cents`, `payment_format`, `session_number_start` em `patient_schedules` e `provider_schedules`.
- [x] **Horários Nulos:** `start_time` e `duration_min` em `appointments` e `*_schedules` aceitam `NULL` (para "Boletos/Dia Inteiro").
- [x] **RPCs reescritas:** `set_patient_schedules` e `set_provider_schedules` agora aceitam múltiplos serviços (JSONB) com regras independentes.
- [x] **Prevenção de Erros:** Uso de `ON CONFLICT DO UPDATE` nas RPCs para não quebrar com `duplicate key` ao mudar apenas a cor/título.

### ✅ Concluído — Módulo Financeiro (Tabelas e RPCs)
- [x] Tabela `transactions` (entradas/saídas).
- [x] Tabela `provider_billings` (vencimentos mensais, anuais, etc.) com `custom_interval_days`.
- [x] Tabela `dismissed_suggestions` (ignorar sugestões de lançamento).
- [x] Bucket `receipts` no Storage (para anexar comprovantes).
- [x] RPC `bulk_approve_suggestions` (cria transações em lote).
- [x] RPC `create_income_from_appointment` (puxa o valor direto do `appointment.session_price_cents`).
- [x] RPC `create_expense_from_billing` (cria despesa do vencimento).
- [x] RPCs `set_provider_billing`, `archive_provider_billing`, `delete_provider_billing`.

---

## Fase 4 — Prontuário e Transcrição de Áudio ⏳

- [ ] Avaliar provedor de transcrição: Whisper, AssemblyAI, Deepgram.
- [ ] Endpoint `POST /transcribe`.
- [ ] Extração de palavras-chave (se necessário).
- [ ] Configurar Supabase Storage para áudio.
- [ ] ⚠️ **Atenção:** O timeout das funções Vercel (10s) pode limitar a transcrição. Pode exigir processamento assíncrono (Background Functions) ou host dedicado.

---

## Fase 5b — Recibos em PDF ⏳

- [ ] Usar a tabela `transactions` (que já tem o valor exato pago) como base.
- [ ] Usar `appointments` (data, título) para compor os itens do recibo.
- [ ] Biblioteca de PDF (PDFKit, Puppeteer, etc).
- [ ] Rota `POST /receipts` para geração.
- [ ] Layout do recibo (design).
- [ ] Upload para o Supabase Storage e retorno de URL assinada.

---

## Fase 6 — Notificações ⏳

### WhatsApp
- [ ] Provedor (Cloud API oficial vs. intermediário).
- [ ] `POST /notifications/whatsapp`.
- [ ] Fila de envio (se necessário).

### E-mail
- [ ] Provedor (Resend / SES / Postmark).
- [ ] Templates transacionais.
- [ ] `POST /notifications/email`.

### Cron
- [ ] Lembrete de sessão (24h antes).
- [ ] Alerta de vencimento (provider_billings).
- [ ] Invalidar `share_links` expirados do prontuário.

---

## Transversal — Infra e qualidade ⏳

- [ ] Log estruturado (`pino`).
- [ ] Monitoramento de erros (Sentry).
- [ ] Rate limiting.
- [ ] Helmet (segurança de headers).
- [ ] Validação de input com Zod.
- [ ] Testes unitários (Vitest).
- [ ] CI/CD (GitHub Actions).
- [ ] Migrar para Node 22 (permite remover a dependência `ws`).
- [ ] Avaliar host dedicado se a Vercel ficar limitante (timeout de 10s).
- [ ] Migração para versionar migrations no repositório (hoje usa-se o CLI/SQL Editor).

---

## Decisões pendentes

- [ ] Provedor de WhatsApp.
- [ ] Provedor de e-mail.
- [ ] Provedor de transcrição.
- [ ] Biblioteca de PDF.
- [ ] Layout do recibo.
- [ ] Quando subir para Node 22.
- [ ] Estratégia de sincronização com Google (webhook vs. polling).

---

## Concluído (registro histórico)

- **Fase 1 completa:** Express + TS + ESM.
- **Fase 2 completa:** `POST /invites` com `schedules`, TinyURL oficial.
- **Deploy em produção:** Vercel serverless.
- **Fase 3 (Importação + Revisão) completa:** OAuth Google Calendar, importação idempotente via Bulk Insert, tabela `providers`, RPCs de revisão.
- **Fase 3b (Multi-Serviços + Financeiro) completa:** Cores, Títulos, Faturamentos independentes, tabelas de `transactions` e `provider_billings`, RPCs de aprovação e controle.
- **Segurança:** `service_role` rotacionada.