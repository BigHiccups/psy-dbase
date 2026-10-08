# CONTEXT.md — psy-dbase (backend)

> **Leia isto antes de tocar no código.**
> Este documento é a fonte de verdade para qualquer IA ou dev que entre no projeto.
> Ele registra **decisões já tomadas** para evitar retrabalho e perguntas repetidas.

---

## 1. O que é este projeto

Backend do **psy-dbase**, sistema de gestão para psicólogo autônomo.

Responsável por tudo que exige **segredos** ou **integrações externas**:

- Validação de JWT do Supabase
- Geração de convites com horários + TinyURL + WhatsApp
- **Integração com Google Calendar (OAuth + leitura + importação)**
- Envio de WhatsApp / e-mail (Fase 6)
- Geração de PDF de recibo (Fase 5)
- Transcrição de áudio (Fase 4, provedor a decidir)

**Repositório irmão:** `psy-dbase-front` (React + Tailwind + Vite).
**Um psicólogo por conta.** Não é multi-tenant compartilhado.

**Status:** em produção na Vercel — `https://psy-dbase.vercel.app`

---

## 2. Stack e versões

| Camada        | Tecnologia                                    | Versão       |
|---------------|-----------------------------------------------|--------------|
| Runtime       | Node                                          | 20.x         |
| Framework     | Express                                       | 5.x          |
| Linguagem     | TypeScript                                    | 5.9.x        |
| Execução dev  | tsx                                           | última       |
| SDK Supabase  | `@supabase/supabase-js`                       | 2.x          |
| WebSocket     | `ws` (+ `@types/ws`)                          | última       |
| Google        | `googleapis`                                  | última       |
| Encurtador    | TinyURL API oficial (`api.tinyurl.com`)       | —            |
| Host          | **Vercel** (serverless functions)             | —            |
| Gerenciador   | npm                                           | —            |

**Node 20 é obrigatório localmente** — o `ws` é necessário porque o SDK do
Supabase inicializa o cliente Realtime por padrão.

---

## 3. Estrutura de pastas

```
psy-dbase/
├── src/
│   ├── config/
│   │   └── env.ts             # valida e exporta variáveis de ambiente
│   ├── lib/
│   │   ├── supabase.ts        # cliente admin (service_role) + ws
│   │   └── tinyurl.ts         # API oficial do TinyURL com fallback
│   ├── middlewares/
│   │   ├── auth.ts            # valida JWT, injeta req.userId
│   │   └── errorHandler.ts    # tratamento centralizado de erros
│   ├── modules/
│   │   ├── invites/
│   │   │   ├── invites.controller.ts
│   │   │   ├── invites.service.ts
│   │   │   ├── invites.routes.ts
│   │   │   ├── invites.types.ts
│   │   │   └── invites.validation.ts
│   │   └── calendar/
│   │       ├── calendar.controller.ts
│   │       ├── calendar.service.ts
│   │       └── calendar.routes.ts
│   ├── utils/
│   │   ├── phone.ts           # normaliza para E.164 (55…)
│   │   └── whatsapp.ts        # monta link wa.me
│   ├── app.ts                 # configura Express (CORS, rotas, error handler)
│   └── server.ts              # entrypoint (local + Vercel)
├── vercel.json                # config de deploy serverless
├── .env                       # local (não versionado)
├── .env.example
├── package.json
└── tsconfig.json
```

**Padrão de módulo:** cada feature tem `controller`, `service`, `routes`
(e `types`/`validation` quando aplicável).

---

## 4. Decisões de arquitetura

### 4.1 O backend só faz o que exige segredo

Dados de aplicação são lidos e escritos **direto pelo frontend no Supabase**,
com RLS protegendo. O backend Node **não** é um CRUD — é uma camada de
integrações.

**Regra:** se a operação só precisa de RLS e não usa segredo externo, ela **não
vai para o backend**.

### 4.2 `service_role` é usada no backend

O cliente `supabaseAdmin` (`src/lib/supabase.ts`) usa a `service_role`, que
**ignora RLS e GRANTs**.

Consequências:

- **Toda query precisa filtrar por `user_id` manualmente.** O RLS não protege.
- **Nunca** logar a chave, nunca commitar `.env`.

> A `service_role` foi rotacionada após vazar em chat durante o desenvolvimento.

### 4.3 GRANT explícito em toda tabela nova

Mesmo com `service_role`, o Postgres precisa que o GRANT exista na tabela.
**Sem GRANT, o erro é `permission denied for table`, mesmo com `service_role`.**

Sempre incluir nas migrations:

```sql
grant usage on schema public to service_role;
grant select, insert, update, delete on public.<tabela> to service_role;
```

O GRANT para `authenticated` (usado pelo frontend via RLS) também é obrigatório.

### 4.4 WebSocket via `ws` (Node 20)

`@supabase/supabase-js` inicializa o cliente Realtime por padrão, mesmo que o
backend não use. Node 20 não tem WebSocket nativo.

```ts
import ws from "ws";
export const supabaseAdmin = createClient(url, key, {
  auth: { autoRefreshToken: false, persistSession: false },
  realtime: { transport: ws as any },
});
```

**Não remover** sem subir o Node para 22+.

### 4.5 Validação de JWT via `supabaseAdmin.auth.getUser(token)`

O `requireAuth` valida o token com a `service_role`. Isso é seguro — o Supabase
verifica assinatura e expiração. Retorna `req.userId` (o `sub` do JWT).

### 4.6 TinyURL — API oficial com fallback

O encurtador usa a **API oficial** (`https://api.tinyurl.com/create`), com
autenticação Bearer (`TINYURL_API_TOKEN`). Elimina o interstitial do endpoint
legado.

O `shortenUrl` **nunca quebra o fluxo**. Se falhar, devolve a URL original.

### 4.7 WhatsApp via `wa.me` (sem API oficial ainda)

Link montado como `https://wa.me/<phone>?text=<mensagem-urlencoded>`. A
normalização em `src/utils/phone.ts` assume **Brasil**.

### 4.8 CORS configurável via lista

`CORS_ORIGINS` aceita múltiplas origens separadas por vírgula. `FRONTEND_URL`
é **outra variável** — usada só para montar URLs (formulário público, redirect
do OAuth Google).

### 4.9 Deploy na Vercel — serverless com Express adaptado

A Vercel não roda Express puro. O `src/server.ts` faz:

```ts
const app = createApp();

if (process.env.VERCEL !== "1") {
  app.listen(env.port, () => console.log(`API rodando em http://localhost:${env.port}`));
}

export default app;
```

E o `vercel.json`:

```json
{
  "version": 2,
  "builds": [
    { "src": "src/server.ts", "use": "@vercel/node" }
  ],
  "rewrites": [
    { "source": "/(.*)", "destination": "/src/server.ts" }
  ]
}
```

**Sem o `vercel.json`**, a Vercel retorna 500 em tudo. **Sem a condicional**, o
`app.listen` conflita com o gerenciamento de porta.

### 4.10 Google Calendar — arquitetura da integração

**Decisão estratégica:** o Google Calendar é **ponto de partida**, não fonte
contínua de verdade.

- **Leitura contínua:** o psy-dbase lê o Google para descobrir slots ocupados
  (bloqueio rígido de horário)
- **Escrita unidirecional (psy-dbase → Google):** prevista para depois
- **Importação inicial:** os eventos recorrentes existentes são **materializados**
  em `appointments` (um slot por ocorrência)

**Por que materializar?** Permite cancelar uma sessão específica sem afetar as
outras, e o bloqueio de horário funciona por slot individual.

**Refresh token:** guardado em `google_credentials`, protegido por RLS +
`service_role`. Sem policies para `authenticated` — o frontend **nunca** acessa.

**Conta do Google:** o psicólogo pode autorizar uma conta **diferente** da que
faz login no psy-dbase. O `prompt` do OAuth inclui `select_account` para
forçar a escolha.

### 4.11 Status `prospect` em patients

`patients.status` aceita 4 valores: `prospect`, `active`, `inactive`,
`discharged`.

- **`prospect`** — paciente importado do Google, aguardando revisão
- **`active`** — paciente em tratamento
- **`inactive`** — arquivado (soft delete)
- **`discharged`** — alta

Quando o import cria pacientes, eles entram como `prospect`. A UI de revisão
(no frontend) permite promover para `active` ou converter o agendamento para
`personal`/`blocked`.

### 4.12 `appointments` — modelo de agenda interna

Cada linha = um slot. `is_recurring=true` significa que é uma ocorrência de
uma recorrência semanal (`starts_on`/`ends_on` definem o intervalo).
`is_recurring=false` significa sessão avulsa.

**Constraint crítica:**

```sql
check (type != 'session' or patient_id is not null)
```

Ou seja: `session` **exige** paciente. `personal` e `blocked` podem ter
`patient_id = null`.

### 4.13 Importação idempotente

`importCalendarEvents` pode rodar várias vezes:

- **Appointments:** pula se já existe `appointments.google_event_id` igual
- **Patients:** reutiliza `prospect` existente com o mesmo `full_name` +
  `user_id`, em vez de criar duplicado

Roda com `POST /calendar/import` e `{ "daysAhead": 90 }`.

---

## 5. Fluxos implementados

### 5.1 `POST /invites`

**Autenticado.** Cria convite, encurta URL, monta link do WhatsApp.

1. `requireAuth` valida o JWT e injeta `req.userId`
2. `validateSchedules` valida os horários (obrigatórios, dia 0–6, `HH:MM`,
   duração 15–240)
3. Insere em `patient_invites` + `patient_invite_schedules`
4. TinyURL oficial encurta
5. Monta `wa.me/<phone>?text=...`

### 5.2 Google Calendar — conexão

1. Frontend chama `GET /calendar/connect` (autenticado)
2. Backend gera URL com `access_type=offline`, `prompt="consent select_account"`,
   `state=userId`
3. Frontend abre em nova aba
4. Usuário autoriza, Google chama `GET /calendar/callback?code=...&state=...`
5. Backend troca `code` por `refresh_token`, salva em `google_credentials`
6. Backend redireciona para `<FRONTEND_URL>/settings?google=connected`

### 5.3 Google Calendar — importação

1. Frontend chama `POST /calendar/import` com `{ daysAhead: 90 }`
2. Backend lista eventos (`events.list` com `singleEvents: true`)
3. Agrupa por `recurringEventId`
4. Para cada grupo:
   - Cria (ou reutiliza) um `patients` com `status='prospect'`
   - Cria N `appointments` (um por ocorrência), com `google_event_id`
5. Retorna resumo (`importedEvents`, `importedAppointments`, `importedPatients`,
   `skipped`)

---

## 6. Convenções de código

- **Idioma:** variáveis, funções, tipos, arquivos em **inglês**. Comentários
  em **português**.
- **ESM:** imports **precisam** terminar em `.js` (mesmo em arquivos `.ts`).
- **Erros:** lançar `Error` no service, capturar no `errorHandler` central.
- **Nada de `any`:** exceto em integrações de bibliotecas com tipos divergentes.
- **Nomes de rota:** plural e minúsculo (`/invites`, `/calendar`).

---

## 7. Armadilhas conhecidas

| Sintoma                                                       | Causa                                                       | Solução                                                       |
|---------------------------------------------------------------|-------------------------------------------------------------|---------------------------------------------------------------|
| **500 em tudo na Vercel**                                     | Falta `vercel.json` ou `export default app`                 | Ver seção 4.9                                                 |
| **CORS "No 'Access-Control-Allow-Origin'"**                   | Backend fora do ar (500 no boot)                            | Corrigir o boot primeiro                                      |
| `Node.js 20 detected without native WebSocket support`        | Falta `ws` no `createClient`                                | `realtime: { transport: ws as any }`                          |
| `Variável de ambiente ausente: X`                             | `.env` faltando ou rodado de outra pasta                    | Rodar de dentro do repo                                       |
| `permission denied for table` mesmo com `service_role`        | GRANT não existe                                            | `grant … to service_role`                                     |
| `Token inválido` no curl                                      | Colou `service_role` em vez do `access_token`               | Usar token do usuário (`"role":"authenticated"`)              |
| `ERROR: Unexpected "==="` no `tsx`                            | Comentário `// ====` perdeu o `//`                          | Todo comentário começa com `//`                               |
| `ERR_MODULE_NOT_FOUND`                                        | Import sem `.js`                                            | Adicionar `.js` (ESM)                                         |
| Link do TinyURL cai em página genérica                        | Endpoint legado `api-create.php`                            | Migrar para API oficial                                       |
| URL malformada no convite                                     | Lista de CORS em `FRONTEND_URL`                             | Separar as duas variáveis                                     |
| `Access blocked: app not verified`                            | Conta não está como Test User                               | Adicionar em **Público-alvo** no Google Cloud                 |
| `redirect_uri_mismatch`                                       | Redirect URI do Google Cloud ≠ do `.env`                    | Confirmar `http://localhost:3333/calendar/callback`           |
| `O Google não retornou refresh_token`                         | Usuário já autorizou antes                                  | Revogar em myaccount.google.com/permissions                   |
| `Request is missing required authentication credential`       | Chamada à API do Google sem token                           | Rodar `/calendar/connect` primeiro                            |

---

## 8. Segurança

- **`service_role`:** só existe no backend + painel da Vercel. Se vazar,
  **rotacionar imediatamente**.
- **`google_credentials.refresh_token`:** plain na tabela, sem policies para
  `authenticated`. Só o backend acessa.
- **`GOOGLE_CLIENT_SECRET`:** Secret no painel da Vercel.
- **`GOOGLE_CLIENT_ID`** e **`GOOGLE_REDIRECT_URI`:** Config (públicos).
- **CORS:** lista explícita, sem `*`.
- **Env vars de produção:** no painel da Vercel, não em arquivo versionado.

---

## 9. O que está fora do escopo

- Renderização de UI → **frontend `psy-dbase-front`**
- Migrations SQL → **rodadas manualmente no SQL Editor do Supabase**
- Autenticação OAuth (login) → **Supabase Auth**

---

## 10. Estado atual (última atualização)

**Concluído:**

- ✅ Estrutura Express + TypeScript + ESM
- ✅ `requireAuth` validando JWT
- ✅ `GET /health`
- ✅ `POST /invites` com `schedules` obrigatórios
- ✅ TinyURL API oficial com fallback
- ✅ Deploy em produção na Vercel
- ✅ `vercel.json` + `server.ts` adaptado
- ✅ `service_role` rotacionada
- ✅ **Módulo `calendar` completo:**
  - `GET /calendar/connect` — gera URL de autorização
  - `GET /calendar/callback` — recebe code, salva tokens
  - `GET /calendar/status` — status da conexão
  - `GET /calendar/events` — lista eventos do Google
  - `POST /calendar/import` — importa recorrências para `appointments`
  - `DELETE /calendar/disconnect` — remove credenciais
- ✅ Tabelas `appointments` e `google_credentials`
- ✅ Status `prospect` em `patients`

**Pendente (Fase 3+):**

- ⏳ Escrever eventos no Google (psy-dbase → Calendar)
- ⏳ Sincronização bidirecional
- ⏳ Link do Meet automático ao criar `appointments`
- ⏳ Cron job para estender horizonte de agendamentos
- ⏳ UI de revisão de provisórios (frontend)
- ⏳ Página `/agenda` (frontend)
- ⏳ Bloqueio rígido no `InvitePatientModal` (frontend)
- ⏳ Notificações (WhatsApp API + e-mail)
- ⏳ Recibos em PDF
- ⏳ Transcrição de áudio
- ⏳ Log estruturado / Sentry
- ⏳ Rate limiting
- ⏳ Validação de input com Zod

**Branches ativas:**
- Backend: `main`
- Frontend: `main`

---

## 11. Integração com o frontend

**URLs em produção:**
- Backend: `https://psy-dbase.vercel.app`
- Frontend: `https://psy-dbase-frontend.vercel.app`

**Env vars do backend (painel Vercel):**

| Variável | Tipo |
|---|---|
| `SUPABASE_URL` | Config |
| `SUPABASE_SERVICE_ROLE_KEY` | Secret |
| `FRONTEND_URL` | Config |
| `CORS_ORIGINS` | Config |
| `TINYURL_API_TOKEN` | Secret |
| `GOOGLE_CLIENT_ID` | Config |
| `GOOGLE_CLIENT_SECRET` | Secret |
| `GOOGLE_REDIRECT_URI` | Config |

**Env vars do frontend (painel Vercel):**
- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_ANON_KEY`
- `VITE_API_URL`

---

## 12. Como usar este documento

Ao entrar no projeto, leia na ordem:

1. Este `CONTEXT.md`
2. `README.md`
3. `TODO.md`
4. Código em `src/`

Se algo aqui estiver desatualizado, **atualize antes de codar**.