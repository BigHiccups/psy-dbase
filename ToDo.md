# TODO.md — psy-dbase (backend)

> Tarefas pendentes, organizadas por fase. Espelha a estrutura do `TODO.md` do
> frontend `psy-dbase-front`.

**Legenda:** `[ ]` pendente · `[~]` em andamento · `[x]` concluído · `[!]` bloqueado

**Branches ativas:**
- Backend: `feature/form-creation`
- Frontend: `feat/design-imp`

---

## 🎯 Próximos 3 passos

Ordem sugerida para a próxima sessão de trabalho:

1. **`POST /invites` aceitar `schedules`** — horários das sessões são regra de
   negócio obrigatória no convite
2. **Deploy do backend** — escolher host (Render / Railway / Fly.io) e subir
3. **Atualizar `CORS_ORIGINS` e `FRONTEND_URL`** no `.env` de produção após o
   deploy do frontend e do backend

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

## Fase 2 — Convites de Paciente

### Concluído

- [x] Módulo `invites` (controller / service / routes)
- [x] `POST /invites` autenticado
- [x] Normalização de telefone BR → E.164 (`5511999999999`)
- [x] Encurtamento de URL via TinyURL com fallback silencioso
- [x] `User-Agent` na chamada do TinyURL (evita bloqueio)
- [x] Montagem de link `wa.me` com mensagem pré-formatada
- [x] Criação de registro em `patient_invites` com token UUID

### Pendente — horários das sessões

Regra de negócio: o psicólogo **precisa** definir os horários antes de enviar
o convite. Múltiplos dias por semana, um horário por dia, duração configurável
(default 50 min herdado de `profiles.default_session_duration_minutes`).

- [ ] **SQL:** criar tabela `patient_invite_schedules`
  ```sql
  create table public.patient_invite_schedules (
    id uuid primary key default gen_random_uuid(),
    invite_id uuid not null references public.patient_invites(id) on delete cascade,
    weekday int not null check (weekday between 0 and 6),  -- 0=domingo
    start_time time not null,
    duration_min int not null default 50,
    created_at timestamptz not null default now()
  );
  create index patient_invite_schedules_invite_idx on public.patient_invite_schedules(invite_id);
  alter table public.patient_invite_schedules enable row level security;
  -- Policies: select/insert via invite.user_id = auth.uid()
  grant select, insert, update, delete on public.patient_invite_schedules to authenticated;
  grant select, insert, update, delete on public.patient_invite_schedules to service_role;
  ```
- [ ] **`invites.service.ts`:** aceitar `schedules` no input
- [ ] **Validação:** pelo menos 1 horário obrigatório
- [ ] **Validação:** `weekday` entre 0 e 6; `startTime` em formato `HH:MM`
- [ ] **Validação:** `durationMin` entre 15 e 120 (a definir faixa exata)
- [ ] **Inserir** os horários em transação com o convite
- [ ] **Atualizar RPC `get_invite_by_token`** para também retornar os horários
      (o formulário público exibe em modo leitura)
- [ ] **Atualizar `InviteResponse`** no backend: incluir `schedules` no retorno
      (opcional, o frontend já tem os dados que enviou)
- [ ] **Atualizar `.env.example`** se surgir variável nova (não deve surgir)

### Pendente — integração com o frontend

- [ ] Confirmar que o `InvitePatientModal` do frontend já envia `schedules` no
      body do `POST /invites`
- [ ] Confirmar que o `PublicForm` mostra os horários em modo leitura
- [ ] Confirmar que o `PublicForm` tem checkbox de orientação sobre o local
      ("ambiente tranquilo, silencioso e privado")

### Pendente — robustez

- [ ] Limitar número de convites por usuário (anti-abuso)
- [ ] Rate limiting nas rotas públicas
- [ ] Log estruturado (hoje é `console.log`)

---

## Fase 3 — Google Calendar + Meet

### Backend

- [ ] OAuth do Google para o psicólogo (fluxo separado do login via Supabase)
- [ ] Armazenar `refresh_token` do Google com segurança (tabela
      `google_credentials` ou similar, criptografada)
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
- [ ] Fila de envio (BullMQ, ou similar) para não travar a API
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

### Deploy

- [ ] Escolher host (Render / Railway / Fly.io)
- [ ] Configurar variáveis de ambiente no host
- [ ] Configurar domínio (se houver)
- [ ] Atualizar `CORS_ORIGINS` com a URL do frontend em produção
- [ ] Atualizar `FRONTEND_URL` com a URL do frontend em produção
- [ ] Adicionar URL do backend no `.env` do frontend (`VITE_API_URL`)
- [ ] CI/CD (GitHub Actions) — build automático no push

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
- [ ] Rotacionar `service_role` se houver suspeita de vazamento

### Testes

- [ ] Testes unitários (Vitest)
- [ ] Testes de integração das rotas autenticadas
- [ ] Mock do Supabase nos testes

---

## Decisões pendentes

- [ ] Host do backend (Render / Railway / Fly.io) — **bloqueia deploy**
- [ ] Provedor de WhatsApp (Cloud API vs. intermediário) — afeta Fase 6
- [ ] Provedor de e-mail (Resend / SES / Postmark) — afeta Fase 6
- [ ] Provedor de transcrição de áudio — afeta Fase 4
- [ ] Biblioteca de geração de PDF — afeta Fase 5
- [ ] Layout do recibo — afeta Fase 5
- [ ] Quando versionar migrations SQL (hoje são rodadas manualmente no SQL Editor)
- [ ] Quando subir para Node 22 (permite remover o pacote `ws`)

---

## Concluído (registro histórico)

- **Fase 1 completa:** Express + TS + ESM, `env.ts` validando, `supabaseAdmin`
  com `ws` para Node 20, `requireAuth`, `errorHandler`, CORS configurável
- **Fase 2 parcial:** `POST /invites` cria convite, normaliza telefone,
  encurta URL via TinyURL (com fallback), monta link `wa.me` com mensagem
  pré-formatada
- **Endpoints em produção:** nenhum (só local)