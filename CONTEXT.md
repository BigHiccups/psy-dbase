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
- **Integração Google Calendar** (OAuth + leitura + importação idempotente)
- Envio de WhatsApp / e-mail (Fase 6)
- Geração de PDF de recibo (Fase 5)
- Transcrição de áudio (Fase 4, provedor a decidir)

**Repositório irmão:** `psy-dbase-front` (React + Tailwind + Vite).
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

O `requireAuth` valida o token com a `service_role`. Retorna `req.userId`.

### 4.6 TinyURL — API oficial com fallback

O encurtador usa a **API oficial** (`https://api.tinyurl.com/create`), com
autenticação Bearer (`TINYURL_API_TOKEN`). O `shortenUrl` **nunca quebra o
fluxo** — se falhar, devolve a URL original.

### 4.7 WhatsApp via `wa.me`

Link montado como `https://wa.me/<phone>?text=<mensagem-urlencoded>`. A
normalização em `src/utils/phone.ts` assume **Brasil**.

### 4.8 CORS configurável via lista

`CORS_ORIGINS` aceita múltiplas origens separadas por vírgula. `FRONTEND_URL`
é **outra variável** — usada só para montar URLs (formulário público, redirect
do OAuth Google).

### 4.9 Deploy na Vercel — serverless com Express adaptado

`src/server.ts`:

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
  "builds": [{ "src": "src/server.ts", "use": "@vercel/node" }],
  "rewrites": [{ "source": "/(.*)", "destination": "/src/server.ts" }]
}
```

### 4.10 Google Calendar — arquitetura da integração

**Decisão estratégica:** o Google Calendar é **ponto de partida**, não fonte
contínua de verdade.

- **Leitura contínua:** para descobrir slots ocupados (bloqueio rígido)
- **Escrita unidirecional (psy-dbase → Google):** prevista para depois
- **Importação inicial:** os eventos recorrentes existentes são **materializados**
  em `appointments` (um slot por ocorrência)

**Por que materializar?** Permite cancelar uma sessão específica sem afetar as
outras, e o bloqueio de horário funciona por slot individual.

**Conta do Google:** o psicólogo pode autorizar uma conta **diferente** da que
faz login no psy-dbase. O `prompt` do OAuth inclui `select_account`.

### 4.11 Status `prospect` e a tabela `providers`

**`patients.status`:** `prospect` | `active` | `inactive` | `discharged`

- **`prospect`** — paciente importado do Google, aguardando revisão
- **`active`** — paciente em tratamento
- **`inactive`** — arquivado (soft delete)
- **`discharged`** — alta

**Tabela `providers`** separa **pacientes** de **prestadores/instituições**:

- `kind = 'person'` → psicólogo pessoal, supervisor, etc.
- `kind = 'company'` → curso, plataforma, editora, aluguel, etc.

**Por que separar?** `patients` tem campos clínicos (contato de urgência);
`providers` tem campos jurídicos (razão social, CNPJ). O financeiro (Fase 5)
trata entradas × pacientes e saídas × providers.

### 4.12 `appointments` — modelo de agenda

Cada linha = um slot. `type` define o sujeito:

| `type` | `patient_id` | `provider_id` | Ocupa agenda? |
|---|---|---|---|
| `session` | obrigatório | null | sim |
| `personal` | null | obrigatório | sim |
| `blocked` | null | null | sim |
| `due` | null | obrigatório | **não** (marcador de vencimento) |

Constraint:

```sql
check (
  (type = 'session' and patient_id is not null and provider_id is null)
  or (type = 'personal' and patient_id is null and provider_id is not null)
  or (type = 'blocked' and patient_id is null and provider_id is null)
  or (type = 'due' and patient_id is null and provider_id is not null)
)
```

### 4.13 Idempotência da importação (2 camadas)

`importCalendarEvents` pode rodar várias vezes sem duplicar:

**Camada 1 — `google_imported_recurrences`:** tabela de rastreio que mapeia
`recurringEventId` → `(target_type, target_id)`. Se já existe, pula.

**Camada 2 — `appointments.google_event_id`:** cada ocorrência tem ID único.
Se já existe `appointments` com aquele `google_event_id`, pula.

**Por que duas camadas?** A camada 1 evita criar pacientes/providers
duplicados mesmo se o paciente foi renomeado ou convertido em provider. A
camada 2 evita criar slots duplicados.

### 4.14 RPCs de revisão de provisórios

Três RPCs (SQL `security definer`) executadas pelo frontend:

- `convert_prospect_to_provider(p_patient_id, p_kind)` — cria provider,
  converte `appointments` para `personal`, atualiza
  `google_imported_recurrences`, deleta o patient
- `promote_prospect_to_active(p_patient_id)` — muda status para `active`
- `discard_prospect(p_patient_id)` — deleta patient + appointments +
  recorrência

**Por que RPC em vez de update direto?** Atomicidade — todas as operações
acontecem ou nenhuma acontece. Sem risco de estado inconsistente.

---

## 5. Fluxos implementados

### 5.1 `POST /invites`

**Autenticado.** Cria convite, encurta URL, monta link do WhatsApp.

1. `requireAuth` valida o JWT
2. `validateSchedules` valida os horários (obrigatórios, dia 0–6, `HH:MM`,
   duração 15–240)
3. Insere em `patient_invites` + `patient_invite_schedules`
4. TinyURL oficial encurta
5. Monta `wa.me/<phone>?text=...`

### 5.2 Google Calendar — conexão

1. Frontend chama `GET /calendar/connect` (autenticado)
2. Backend gera URL com `access_type=offline`, `prompt="consent select_account"`,
   `state=userId`
3. Frontend abre em **nova aba**
4. Usuário autoriza, Google chama `GET /calendar/callback?code=...&state=...`
5. Backend troca `code` por `refresh_token`, salva em `google_credentials`
6. Backend redireciona para `<FRONTEND_URL>/settings?google=connected`

### 5.3 Google Calendar — importação

1. Frontend chama `POST /calendar/import` com `{ daysAhead: 90 }`
2. Backend lista eventos (`events.list` com `singleEvents: true`)
3. Agrupa por `recurringEventId`
4. Para cada grupo:
   - Checa `google_imported_recurrences`
   - Se não existe, cria `patient` provisório ou reutiliza por nome
   - Cria N `appointments` (um por ocorrência)
   - Registra em `google_imported_recurrences`
5. Retorna resumo

**Idempotente:** rodar várias vezes nunca duplica.

### 5.4 Conversão de provisório

Três caminhos possíveis pelo frontend, via RPC:

- **É paciente** → `promote_prospect_to_active` (após preencher dados)
- **É prestador** → `convert_prospect_to_provider`
- **Remover** → `discard_prospect`

---

## 6. Convenções de código

- **Idioma:** variáveis, funções, tipos, arquivos em **inglês**. Comentários
  em **português**.
- **ESM:** imports **precisam** terminar em `.js` (mesmo em arquivos `.ts`).
- **Erros:** lançar `Error` no service, capturar no `errorHandler` central.
- **Nada de `any`:** exceto em integrações com bibliotecas.
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
| `ERR_MODULE_NOT_FOUND`                                        | Import sem `.js`                                            | Adicionar `.js` (ESM)                                         |
| Link do TinyURL cai em página genérica                        | Endpoint legado `api-create.php`                            | Migrar para API oficial                                       |
| URL malformada no convite                                     | Lista de CORS em `FRONTEND_URL`                             | Separar as duas variáveis                                     |
| `Access blocked: app not verified`                            | Conta não está como Test User no Google Cloud               | Adicionar em **Público-alvo** no Google Cloud                 |
| `redirect_uri_mismatch`                                       | Redirect URI do Google Cloud ≠ do `.env`                    | Confirmar `https://psy-dbase.vercel.app/calendar/callback`    |
| `O Google não retornou refresh_token`                         | Usuário já autorizou antes                                  | Revogar em myaccount.google.com/permissions                   |
| **Importação cria paciente duplicado**                        | Faltava checar `google_imported_recurrences`                | Usar a tabela de rastreio (seção 4.13)                        |
| **`maybeSingle()` retorna null mesmo com linha existente**    | Duplicata na tabela (índice único não ativo)                | Garantir índice único + `select()` em vez de `maybeSingle()`  |

---

## 8. Segurança

- **`service_role`:** só existe no backend + painel da Vercel. Se vazar,
  **rotacionar imediatamente**.
- **`google_credentials.refresh_token`:** plain na tabela, sem policies para
  `authenticated`. Só o backend acessa via `service_role`.
- **`GOOGLE_CLIENT_SECRET`:** Secret no painel da Vercel.
- **`GOOGLE_CLIENT_ID`** e **`GOOGLE_REDIRECT_URI`:** Config (públicos).
- **CORS:** lista explícita, sem `*`.

---

## 9. O que está fora do escopo

- Renderização de UI → **frontend `psy-dbase-front`**
- Migrations SQL → **SQL Editor do Supabase**
- Autenticação OAuth (login) → **Supabase Auth**

---

## 10. Estado atual (última atualização)

**Concluído:**

- ✅ Estrutura Express + TypeScript + ESM
- ✅ `requireAuth` validando JWT
- ✅ `GET /health`
- ✅ `POST /invites` com `schedules` obrigatórios
- ✅ TinyURL oficial com fallback
- ✅ Deploy em produção na Vercel
- ✅ Módulo `calendar` completo (connect / callback / status / events /
  import / disconnect)
- ✅ Tabelas: `appointments`, `google_credentials`, `providers`,
  `google_imported_recurrences`
- ✅ Status `prospect` em `patients`
- ✅ RPCs: `convert_prospect_to_provider`, `promote_prospect_to_active`,
  `discard_prospect`
- ✅ Idempotência em 2 camadas na importação
- ✅ `service_role` rotacionada
- ✅ Logs de debug limpos no `auth.ts`

**Pendente (Fase 3+):**

- ⏳ Escrever eventos no Google (psy-dbase → Calendar)
- ⏳ Link do Meet automático ao criar `appointments`
- ⏳ Cron job para estender horizonte (90 dias → renovar)
- ⏳ Página `/agenda` (frontend)
- ⏳ Bloqueio rígido no `InvitePatientModal` (frontend)
- ⏳ CRUD de `due` (vencimentos de provider)
- ⏳ Notificações (WhatsApp + e-mail)
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