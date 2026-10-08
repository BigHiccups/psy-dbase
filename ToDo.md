# TODO.md — psy-dbase (backend)

> Tarefas pendentes, organizadas por fase. Espelha a estrutura do `TODO.md` do
> frontend `psy-dbase-front`.

**Legenda:** `[ ]` pendente · `[~]` em andamento · `[x]` concluído · `[!]` bloqueado

**Branches ativas:**
- Backend: `main`
- Frontend: `main`

**URL de produção:** `https://psy-dbase.vercel.app`

---

## 🎯 Próximos 3 passos

Ordem sugerida para a próxima sessão de trabalho:

1. **Log estruturado** — substituir `console.log` por logger com níveis
   (`pino` ou similar), essencial para debugar problemas em produção sem
   depender dos logs brutos da Vercel
2. **Rate limiting nas rotas públicas** — `POST /invites` é autenticado, mas
   `/health` e futuras rotas públicas precisam de proteção contra abuso
3. **Validação de input com Zod** — hoje a validação é manual em
   `invites.validation.ts`; migrar para Zod reduz código e melhora mensagens
   de erro

---

## Fase 1 — Fundação ✅

- [x] Setup Node 20 + Express 5 + TypeScript ESM
- [x] `tsconfig.json` configurado
- [x] `env.ts` com validação de variáveis obrigatórias
- [x] `supabaseAdmin` com `service_role` + `ws` (Node 20)
- [x] `requireAuth` validando JWT do Supabase
- [x] `errorHandler` centralizado
- [x] `GET /health`
- [x] CORS configurável via lista
- [x] `FRONTEND_URL` separado de `CORS_ORIGINS`
- [x] Repositório no GitHub

---

## Fase 2 — Convites de Paciente ✅

- [x] Módulo `invites` (controller / service / routes / types / validation)
- [x] `POST /invites` autenticado
- [x] Normalização de telefone BR → E.164 (`5511999999999`)
- [x] Encurtamento de URL via **API oficial do TinyURL** com fallback
- [x] `User-Agent` na chamada do TinyURL
- [x] Montagem de link `wa.me` com mensagem pré-formatada
- [x] Criação de registro em `patient_invites` com token UUID
- [x] **Tabela `patient_invite_schedules`** com RLS + GRANTs
- [x] **`schedules` obrigatórios** no convite (regra de negócio)
- [x] **`validateSchedules`** — dia 0–6, `HH:MM`, duração 15–240, sem duplicata
- [x] Inserção dos horários em transação com rollback manual
- [x] RPC `get_invite_by_token` retorna `schedules` em JSON
- [x] Migração do TinyURL legado (`api-create.php`) para API oficial

---

## Fase 3 — Google Calendar + Meet

### Backend

- [ ] OAuth do Google para o psicólogo (fluxo separado do login Supabase)
- [ ] Armazenar `refresh_token` do Google com segurança (tabela
      `google_credentials` criptografada)
- [ ] Endpoint `POST /calendar/connect` — inicia o fluxo OAuth
- [ ] Endpoint `GET /calendar/callback` — recebe o `code` e salva credenciais
- [ ] Endpoint `POST /appointments` — cria evento no Calendar do psicólogo
- [ ] Incluir `conferenceData` para gerar link do Meet automaticamente
- [ ] Suporte a N participantes (`attendees`)
- [ ] Endpoint `PATCH /appointments/:id` — atualiza evento
- [ ] Endpoint `DELETE /appointments/:id` — cancela evento
- [ ] Geração de eventos recorrentes a partir de `patient_invite_schedules`
- [ ] Renovação automática de `refresh_token` do Google
- [ ] Tratamento de erro quando o psicólogo revoga acesso

### Banco

- [ ] Tabela `google_credentials` (user_id, refresh_token criptografado, scopes)
- [ ] Tabela `appointments` (sincronizada com o Calendar)
- [ ] Tabela `appointment_attendees`

---

## Fase 4 — Transcrição de Áudio

- [ ] Avaliar provedor: Whisper (OpenAI), AssemblyAI, Deepgram
- [ ] Decidir entre upload manual e gravação no navegador
- [ ] Endpoint `POST /transcribe` — recebe áudio, devolve texto
- [ ] Endpoint para extrair palavras/sentenças-chave
- [ ] Integração com Supabase Storage para guardar o áudio
- [ ] Limite de tamanho de arquivo
- [ ] Custo por minuto de áudio (validar viabilidade)
- [ ] ⚠️ Atenção: funções serverless da Vercel têm timeout (10s no plano
      gratuito) — processar áudio longo pode exigir host diferente ou fila

---

## Fase 5 — Recibos em PDF

- [ ] Biblioteca de geração de PDF (Puppeteer, PDFKit, react-pdf)
- [ ] Endpoint `POST /receipts` — gera PDF a partir dos dados do pagamento
- [ ] Layout do recibo (a decidir com o usuário)
- [ ] Campos obrigatórios: nome do psicólogo, CRP, valor, data, descrição
- [ ] Armazenar PDF no Supabase Storage
- [ ] Devolver URL assinada com expiração
- [ ] Suporte a envio por e-mail (junto com Fase 6)

---

## Fase 6 — Notificações

### WhatsApp

- [ ] Decidir provedor: Cloud API oficial (Meta) vs. intermediário (Z-API,
      Twilio)
- [ ] Configurar credenciais
- [ ] Templates de mensagem aprovados (se for Meta)
- [ ] Endpoint `POST /notifications/whatsapp`
- [ ] Fila de envio (BullMQ ou similar) para não travar a API
- [ ] Retry em caso de falha
- [ ] Log de envios por paciente

### E-mail

- [ ] Decidir provedor: Resend, AWS SES, Postmark
- [ ] Configurar domínio de envio (SPF, DKIM, DMARC)
- [ ] Templates transacionais (lembrete de sessão, alerta de vencimento)
- [ ] Endpoint `POST /notifications/email`

### Agendamento

- [ ] Cron job para lembretes de sessão (24h antes, configurável)
- [ ] Cron job para alertas de vencimento financeiro
- [ ] Cron job para invalidar `share_links` expirados

---

## Transversal — Infra e qualidade

### Observabilidade

- [ ] Log estruturado (hoje é `console.log`)
- [ ] Monitoramento de erros (Sentry)
- [ ] Health check mais completo (verificar Supabase, não só `ok: true`)

### Segurança

- [ ] Rate limiting nas rotas públicas
- [ ] Helmet (headers de segurança)
- [ ] Validação de input com Zod (ou similar)
- [ ] Revisar todas as queries com `service_role` para garantir filtro por
      `user_id`

### Testes

- [ ] Testes unitários (Vitest)
- [ ] Testes de integração das rotas autenticadas
- [ ] Mock do Supabase nos testes

### Deploy

- [ ] CI/CD (GitHub Actions) — build automático no push
- [ ] Avaliar quando migrar para Node 22 (permite remover o pacote `ws`)
- [ ] Avaliar host dedicado se as funções serverless da Vercel ficarem
      limitantes (timeout, cold start, tamanho de payload)

---

## Decisões pendentes

- [ ] Provedor de WhatsApp (Cloud API vs. intermediário) — afeta Fase 6
- [ ] Provedor de e-mail (Resend / SES / Postmark) — afeta Fase 6
- [ ] Provedor de transcrição de áudio — afeta Fase 4
- [ ] Biblioteca de geração de PDF — afeta Fase 5
- [ ] Layout do recibo — afeta Fase 5
- [ ] Quando versionar migrations SQL (hoje são rodadas manualmente no SQL
      Editor)
- [ ] Quando subir para Node 22 (permite remover o pacote `ws`)

---

## Concluído (registro histórico)

- **Fase 1 completa:** Express + TS + ESM, `env.ts` validando, `supabaseAdmin`
  com `ws`, `requireAuth`, `errorHandler`, CORS configurável
- **Fase 2 completa:** `POST /invites` com `schedules` obrigatórios, validação,
  TinyURL API oficial, `wa.me`, tabela `patient_invite_schedules` com RLS +
  GRANTs
- **Deploy em produção:** Vercel, `vercel.json` com `@vercel/node`,
  `server.ts` adaptado para serverless
- **Segurança:** `service_role` rotacionada após vazar em chat