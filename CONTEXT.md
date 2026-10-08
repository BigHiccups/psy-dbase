# CONTEXT.md — psy-dbase (backend)

> **Leia isto antes de tocar no código.**
> Este documento é a fonte de verdade para qualquer IA ou dev que entre no projeto.
> Ele registra **decisões já tomadas** para evitar retrabalho e perguntas repetidas.

---

## 1. O que é este projeto

Backend do **psy-dbase**, sistema de gestão para psicólogo autônomo.

Responsável por tudo que exige **segredos** ou **integrações externas**:

- Validação de JWT do Supabase
- Geração de convites de paciente com horários combinados
- Encurtamento de URL via API oficial do TinyURL
- Montagem de link do WhatsApp (`wa.me`) com mensagem pré-preenchida
- Google Calendar + Meet (Fase 3)
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
| Encurtador    | **TinyURL API oficial** (`api.tinyurl.com`)   | —            |
| Host          | **Vercel** (serverless functions)             | —            |
| Gerenciador   | npm                                           | —            |

**Node 20 é obrigatório localmente** — o `ws` é necessário porque o SDK do
Supabase inicializa o cliente Realtime por padrão. Subir para Node 22+ permite
remover o `ws`, mas **não fazer isso sem testar**.

---

## 3. Estrutura de pastas

```
psy-dbase/
├── api/                       # (não existe — o entrypoint é src/server.ts)
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
│   │   └── invites/
│   │       ├── invites.controller.ts
│   │       ├── invites.service.ts
│   │       ├── invites.routes.ts
│   │       ├── invites.types.ts
│   │       └── invites.validation.ts
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

**Padrão de módulo:** cada feature tem `controller`, `service`, `routes`,
`types` e `validation` (quando aplicável). Features futuras seguem o mesmo
padrão.

---

## 4. Decisões de arquitetura

### 4.1 O backend só faz o que exige segredo

Dados de aplicação (pacientes, agenda, prontuário, financeiro) são lidos e
escritos **direto pelo frontend no Supabase**, com RLS protegendo. O backend
Node **não** é um CRUD — é uma camada de integrações.

**Regra:** se a operação só precisa de RLS e não usa segredo externo, ela **não
vai para o backend**. Vai direto do frontend para o Supabase.

### 4.2 `service_role` é usada no backend

O cliente `supabaseAdmin` (`src/lib/supabase.ts`) usa a `service_role`, que
**ignora RLS e GRANTs**.

Consequências:

- **Toda query precisa filtrar por `user_id` manualmente.** O RLS não protege.
- Se uma rota aceita `userId` do frontend sem validar contra o JWT, é uma
  vulnerabilidade grave.
- **Nunca** logar a chave, nunca commitar `.env`.

> A `service_role` foi rotacionada após vazar em chat durante o desenvolvimento.
> A chave atual só existe no painel da Vercel.

### 4.3 GRANT explícito em toda tabela nova

Mesmo com `service_role`, o Postgres precisa que o GRANT exista na tabela.
**Sem GRANT, o erro é `permission denied for table`, mesmo com `service_role`.**

Isso já aconteceu duas vezes (`profiles` e `patient_invites`). Sempre incluir
nas migrations:

```sql
grant usage on schema public to service_role;
grant select, insert, update, delete on public.<tabela> to service_role;
```

O GRANT para `authenticated` (usado pelo frontend via RLS) também é
obrigatório.

### 4.4 WebSocket via `ws` (Node 20)

O `@supabase/supabase-js` inicializa o cliente Realtime por padrão, mesmo que o
backend não use Realtime. Node 20 não tem WebSocket nativo.

Solução aplicada em `src/lib/supabase.ts`:

```ts
import ws from "ws";
export const supabaseAdmin = createClient(url, key, {
  auth: { autoRefreshToken: false, persistSession: false },
  realtime: { transport: ws as any },
});
```

**Não remover** o `transport` sem subir o Node para 22+.

### 4.5 Validação de JWT via `supabaseAdmin.auth.getUser(token)`

O `requireAuth` valida o token do usuário fazendo uma chamada ao Supabase com a
`service_role`. Isso é seguro e confiável — o Supabase verifica assinatura e
expiração.

Retorna `req.userId` (o `sub` do JWT) para uso nas rotas.

### 4.6 TinyURL — API oficial com fallback

O encurtador usa a **API oficial** (`https://api.tinyurl.com/create`), com
autenticação via Bearer token (`TINYURL_API_TOKEN`). Isso elimina a página de
interstitial que o endpoint legado (`api-create.php`) introduzia.

O `shortenUrl` **nunca quebra o fluxo**. Se o TinyURL retornar erro, timeout ou
formato inesperado, devolve a URL original.

Motivo: o convite **precisa** ser gerado. Link longo é aceitável; convite
quebrado não é.

### 4.7 WhatsApp via `wa.me` (sem API oficial ainda)

O link é montado como `https://wa.me/<phone>?text=<mensagem-urlencoded>`. Não
usa API oficial da Meta ainda — isso entra na Fase 6.

**Formato do telefone:** sempre E.164 sem `+` (`5511999999999`). A normalização
em `src/utils/phone.ts` assume **Brasil** (prefixa `55` se ausente).

### 4.8 CORS configurável via lista

`CORS_ORIGINS` aceita múltiplas origens separadas por vírgula:

```env
CORS_ORIGINS=https://psy-dbase-frontend.vercel.app,http://localhost:5173
```

`FRONTEND_URL` é **outra variável** — usada só para montar a URL do formulário
público. **Não confundir** as duas.

Erro já cometido: colocar lista de origens em `FRONTEND_URL`, o que gerou URLs
malformadas como `http://localhost:5173,https://seu-app.vercel.app/form/uuid`.

### 4.9 Deploy na Vercel — serverless com Express adaptado

A Vercel **não roda Express puro**. Ela espera uma função serverless que exporta
um handler. Para conciliar com o desenvolvimento local, o `src/server.ts` faz:

```ts
const app = createApp();

// Em produção na Vercel, o app é exportado como handler serverless.
// Localmente (npm run dev), chamamos listen normalmente.
if (process.env.VERCEL !== "1") {
  app.listen(env.port, () => {
    console.log(`API rodando em http://localhost:${env.port}`);
  });
}

export default app;
```

E o `vercel.json` na raiz:

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

**Sem o `vercel.json`**, a Vercel não sabe como iniciar o Express e retorna 500
em tudo. **Sem a condicional `VERCEL !== "1"`**, o `app.listen` conflita com o
gerenciamento de porta da Vercel.

O mesmo padrão de `vercel.json` com rewrite para `index.html` existe no repo do
frontend (para SPA routing do React Router).

---

## 5. Fluxos implementados

### 5.1 `POST /invites`

**Autenticado.** Cria convite com horários obrigatórios, encurta URL, monta link
do WhatsApp.

1. `requireAuth` valida o JWT e injeta `req.userId`
2. `invites.controller` extrai `patientNameHint`, `phone` e `schedules` do body
3. `validateSchedules` valida:
   - Pelo menos 1 horário
   - `weekday` entre 0 (domingo) e 6 (sábado)
   - `startTime` no formato `HH:MM` (00:00–23:59)
   - `durationMin` entre 15 e 240 (default 50)
   - Sem duplicatas (mesmo dia + mesmo horário)
4. `invites.service`:
   - Normaliza o telefone para E.164 (`normalizePhoneBR`)
   - Insere em `patient_invites` com token UUID gerado pelo banco
   - Insere os horários em `patient_invite_schedules` (com rollback manual se
     falhar)
   - Monta `publicUrl = <FRONTEND_URL>/form/<token>`
   - Encurta via `shortenUrl` (API oficial do TinyURL, com fallback)
   - Monta mensagem: `"Oi, gostaria que fizesse seu cadastro, segue o link: <shortUrl>"`
   - Monta `whatsappUrl` via `buildWhatsAppLink`
5. Devolve `{ inviteId, token, publicUrl, shortUrl, whatsappUrl, phone, schedules }`

O frontend abre `whatsappUrl` em nova aba.

---

## 6. Convenções de código

- **Idioma:** variáveis, funções, tipos, arquivos em **inglês**. Comentários em
  **português**.
- **ESM:** o projeto usa `"type": "module"`. Imports **precisam** terminar em
  `.js` (mesmo em arquivos `.ts`), porque o TypeScript compila para ESM e o
  Node resolve pelo caminho final.
  - ✅ `import { env } from "../config/env.js";`
  - ❌ `import { env } from "../config/env";`
- **Erros:** lançar `Error` no service, capturar no `errorHandler` central.
- **Async/await:** sempre com `try/catch` quando a falha é esperada (ex:
  TinyURL fora do ar).
- **Nada de `any`:** exceto em integrações de bibliotecas com tipos divergentes
  (`transport: ws as any`).
- **Nomes de rota:** plural e minúsculo (`/invites`, não `/invite`).

---

## 7. Armadilhas conhecidas

| Sintoma                                                       | Causa                                                       | Solução                                                       |
|---------------------------------------------------------------|-------------------------------------------------------------|---------------------------------------------------------------|
| **500 em tudo na Vercel (`/health` inclusive)**               | Falta `vercel.json` ou falta `export default app`           | Criar `vercel.json` + condicional `VERCEL !== "1"` no `server.ts` |
| **CORS "No 'Access-Control-Allow-Origin'"**                   | Backend fora do ar (500 no boot)                            | Corrigir o boot primeiro; CORS nem chega a ser avaliado       |
| `Node.js 20 detected without native WebSocket support`        | `@supabase/supabase-js` inicializa Realtime sem `ws`        | `realtime: { transport: ws as any }` no `createClient`        |
| `Variável de ambiente ausente: SUPABASE_URL`                  | `.env` não existe na raiz, ou `npm run dev` rodado de outra pasta | Criar `.env` na raiz e rodar de dentro do repo              |
| `permission denied for table` mesmo com `service_role`        | GRANT não existe na tabela                                  | `grant … to service_role` no SQL Editor                       |
| `permission denied` no backend                                | `.env` com `anon` em vez de `service_role`                  | Decodificar o JWT e conferir `payload.role === "service_role"` |
| `Token inválido` no curl                                      | Colou a `service_role` no lugar do `access_token`           | Usar token do usuário (payload `"role":"authenticated"`)      |
| `ERROR: Unexpected "==="` no `tsx`                            | Comentário `// ====` perdeu o `//` na cópia                 | Garantir que todo comentário começa com `//`                  |
| `ERR_MODULE_NOT_FOUND` para pacote local                      | Import sem `.js` no final                                   | Adicionar `.js` (ESM)                                         |
| `Falha ao gerar URL curta`                                    | TinyURL bloqueou requisição sem `User-Agent`                | Enviar `User-Agent` + fallback silencioso                     |
| Link do TinyURL cai em página genérica do TinyURL             | Endpoint legado `api-create.php` mostra interstitial         | Migrar para API oficial (`api.tinyurl.com/create` com Bearer) |
| URL malformada no convite                                     | Lista de CORS em `FRONTEND_URL`                             | Separar `FRONTEND_URL` e `CORS_ORIGINS`                       |
| GitHub `remote: Internal Server Error` no push                | Instabilidade do GitHub                                     | Aguardar e tentar de novo; não é problema de permissão        |

---

## 8. Segurança

- **`service_role`:** só existe no backend + painel da Vercel. Nunca no
  frontend, nunca em log, nunca em chat. Se vazar, **rotacionar imediatamente**.
- **Validação de JWT:** sempre via `supabaseAdmin.auth.getUser(token)`.
  **Nunca** decodificar o JWT manualmente para confiar no payload.
- **Filtro por `user_id`:** toda query com `service_role` precisa filtrar
  explicitamente. RLS não ajuda aqui.
- **`.env`:** não commitar. Se commitou uma vez, rotacionar tudo.
- **CORS:** lista explícita, sem `*`.
- **Env vars de produção:** ficam no **painel da Vercel**, não em arquivo
  versionado. O `.env` local só existe para desenvolvimento.

---

## 9. O que está fora do escopo deste repositório

- Renderização de UI → **frontend `psy-dbase-front`**
- Migrations SQL → **rodadas manualmente no SQL Editor do Supabase** por
  enquanto (a decidir se vale versionar em `supabase/migrations`)
- Autenticação OAuth → **Supabase Auth** (o backend só valida o token)
- Deploy do frontend → **Vercel** (projeto separado)

---

## 10. Estado atual (última atualização)

**Concluído:**

- ✅ Estrutura Express + TypeScript + ESM
- ✅ `env.ts` com validação
- ✅ `supabaseAdmin` com `ws` para Node 20
- ✅ `requireAuth` validando JWT
- ✅ `errorHandler` centralizado
- ✅ `GET /health`
- ✅ `POST /invites` com `schedules` obrigatórios e validação
- ✅ TinyURL API oficial com fallback
- ✅ **Deploy em produção na Vercel** (`https://psy-dbase.vercel.app`)
- ✅ `vercel.json` com `@vercel/node` + rewrite
- ✅ `server.ts` adaptado (`VERCEL !== "1"` + `export default app`)
- ✅ `service_role` rotacionada

**Pendente (Fase 3+):**

- ⏳ Google Calendar + Meet
- ⏳ Transcrição de áudio
- ⏳ Recibos em PDF
- ⏳ Notificações (WhatsApp API + e-mail)
- ⏳ Log estruturado / Sentry
- ⏳ Rate limiting nas rotas públicas
- ⏳ Validação de input com Zod

**Branches ativas:**
- Backend: `main` (após merges)
- Frontend: `main` (após merges)

---

## 11. Integração com o frontend

O frontend chama o backend via `src/lib/api.ts`, que injeta o JWT automaticamente:

```ts
const { data: { session } } = await supabase.auth.getSession();
fetch(`${API_URL}${path}`, {
  headers: { Authorization: `Bearer ${session.access_token}` },
});
```

**Regra:** o backend sempre espera `Authorization: Bearer <token>` em rotas
autenticadas. Sem isso, `requireAuth` retorna 401.

**CORS:** se o frontend rodar em outra porta ou domínio, precisa estar em
`CORS_ORIGINS` (no painel da Vercel), senão o navegador bloqueia antes de chegar
no backend.

**URL do backend em produção:** `https://psy-dbase.vercel.app`
**URL do frontend em produção:** `https://psy-dbase-frontend.vercel.app`

**Env vars de produção ficam no painel da Vercel**, não no `.env`:

Backend (painel Vercel):
- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `FRONTEND_URL`
- `CORS_ORIGINS`
- `TINYURL_API_TOKEN`

Frontend (painel Vercel):
- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_ANON_KEY`
- `VITE_API_URL`

---

## 12. Como usar este documento

Ao entrar no projeto, leia na ordem:

1. Este `CONTEXT.md` (decisões e armadilhas)
2. `README.md` (como rodar)
3. `TODO.md` (o que falta)
4. Código em `src/`

Se algo aqui estiver desatualizado, **atualize antes de codar**. Contexto
desatualizado é pior que contexto ausente.

Ao adicionar um novo módulo (`src/modules/<nome>/`), registre:

- O endpoint no `README.md`
- A decisão arquitetural relevante no `CONTEXT.md` (se houver)
- A tarefa no `TODO.md` (se ficar pendente)