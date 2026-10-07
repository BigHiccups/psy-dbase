# CONTEXT.md — psy-dbase (backend)

> **Leia isto antes de tocar no código.**
> Este documento é a fonte de verdade para qualquer IA ou dev que entre no projeto.
> Ele registra **decisões já tomadas** para evitar retrabalho e perguntas repetidas.

---

## 1. O que é este projeto

Backend do **psy-dbase**, sistema de gestão para psicólogo autônomo.

Responsável por tudo que exige **segredos** ou **integrações externas**:

- Validação de JWT do Supabase
- Geração de convites de paciente com encurtamento de URL (TinyURL)
- Montagem de link do WhatsApp (`wa.me`) com mensagem pré-preenchida
- Google Calendar + Meet (Fase 3)
- Envio de WhatsApp / e-mail (Fase 6)
- Geração de PDF de recibo (Fase 5)
- Transcrição de áudio (Fase 4, provedor a decidir)

**Repositório irmão:** `psy-dbase-front` (React + Tailwind + Vite).
**Um psicólogo por conta.** Não é multi-tenant compartilhado.

---

## 2. Stack e versões

| Camada        | Tecnologia                                   | Versão       |
|---------------|----------------------------------------------|--------------|
| Runtime       | Node                                         | 20.x         |
| Framework     | Express                                      | 5.x          |
| Linguagem     | TypeScript                                   | 5.9.x        |
| Execução dev  | tsx                                          | última       |
| SDK Supabase  | `@supabase/supabase-js`                      | 2.x          |
| WebSocket     | `ws` (+ `@types/ws`)                         | última       |
| Encurtador    | TinyURL (API pública)                        | —            |
| Gerenciador   | npm                                          | —            |
| Deploy        | a definir (Render / Railway / Fly.io)        | —            |

**Node 20 é obrigatório** — o projeto foi desenvolvido e testado nele. Se subir
para Node 22, o `ws` pode ser removido, mas **não fazer isso sem testar**.

---

## 3. Estrutura de pastas

```
src/
├── config/
│   └── env.ts                 # valida e exporta variáveis de ambiente
├── lib/
│   ├── supabase.ts            # cliente admin (service_role) + ws
│   └── tinyurl.ts             # encurtador com fallback
├── middlewares/
│   ├── auth.ts                # valida JWT, injeta req.userId
│   └── errorHandler.ts        # tratamento centralizado de erros
├── modules/
│   └── invites/
│       ├── invites.controller.ts
│       ├── invites.service.ts
│       └── invites.routes.ts
├── utils/
│   ├── phone.ts               # normaliza para E.164 (55…)
│   └── whatsapp.ts            # monta link wa.me
├── app.ts                     # configura Express (CORS, rotas, error handler)
└── server.ts                  # sobe o servidor
```

**Padrão de módulo:** cada feature tem `controller` (HTTP), `service` (regra de
negócio) e `routes` (mapeamento de rotas). Features futuras (calendar,
notifications, receipts) seguem o mesmo padrão.

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
obrigatório — mas fica no SQL que o frontend/backend roda na Fase correspondente.

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

### 4.6 TinyURL com fallback silencioso

O `shortenUrl` tenta encurtar, mas **nunca quebra o fluxo** se falhar. Se o
TinyURL retornar erro ou timeout, devolve a URL original.

Motivo: o convite **precisa** ser gerado. Link longo é aceitável; convite
quebrado não é.

Também envia `User-Agent: psy-dbase/1.0` porque o TinyURL bloqueia requisições
sem identificação.

### 4.7 WhatsApp via `wa.me` (sem API oficial ainda)

O link é montado como `https://wa.me/<phone>?text=<mensagem-urlencoded>`. Não
usa API oficial da Meta ainda — isso entra na Fase 6.

**Formato do telefone:** sempre E.164 sem `+` (`5511999999999`). A normalização
em `src/utils/phone.ts` assume **Brasil** (prefixa `55` se ausente).

### 4.8 CORS configurável via lista

`CORS_ORIGINS` aceita múltiplas origens separadas por vírgula:

```env
CORS_ORIGINS=http://localhost:5173,https://seu-app.vercel.app
```

`FRONTEND_URL` é **outra variável** — usada só para montar a URL do formulário
público. **Não confundir** as duas.

Erro já cometido: colocar lista de origens em `FRONTEND_URL`, o que gerou URLs
malformadas como `http://localhost:5173,https://seu-app.vercel.app/form/uuid`.

---

## 5. Fluxos implementados

### 5.1 `POST /invites`

**Autenticado.** Cria convite, encurta URL, monta link do WhatsApp.

1. `requireAuth` valida o JWT e injeta `req.userId`
2. `invites.controller` extrai `patientNameHint` e `phone` do body
3. `invites.service`:
   - Normaliza o telefone para E.164 (`normalizePhoneBR`)
   - Insere em `patient_invites` com token UUID gerado pelo banco
   - Monta `publicUrl = <FRONTEND_URL>/form/<token>`
   - Tenta encurtar via `shortenUrl` (com fallback)
   - Monta mensagem fixa: `"Oi, gostaria que fizesse seu cadastro, segue o link: <shortUrl>"`
   - Monta `whatsappUrl` via `buildWhatsAppLink`
4. Devolve `{ inviteId, token, publicUrl, shortUrl, whatsappUrl, phone }`

O frontend abre `whatsappUrl` em nova aba. O psicólogo confere e envia.

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
| `Node.js 20 detected without native WebSocket support`        | `@supabase/supabase-js` inicializa Realtime sem `ws`        | `realtime: { transport: ws as any }` no `createClient`        |
| `Variável de ambiente ausente: SUPABASE_URL`                  | `.env` não existe na raiz, ou `npm run dev` rodado de outra pasta | Criar `.env` na raiz e rodar de dentro do repo              |
| `permission denied for table` mesmo com `service_role`        | GRANT não existe na tabela                                  | `grant … to service_role` no SQL Editor                       |
| `permission denied` no backend                                | `.env` com `anon` em vez de `service_role`                  | Decodificar o JWT e conferir `payload.role === "service_role"` |
| `Token inválido` no curl                                      | Colou a `service_role` no lugar do `access_token`           | Usar token do usuário (payload `"role":"authenticated"`)      |
| `ERROR: Unexpected "==="` no `tsx`                            | Comentário `// ====` perdeu o `//` na cópia                 | Garantir que todo comentário começa com `//`                  |
| `ERR_MODULE_NOT_FOUND` para pacote local                      | Import sem `.js` no final                                   | Adicionar `.js` (ESM)                                         |
| `Falha ao gerar URL curta`                                    | TinyURL bloqueou requisição sem `User-Agent`                | Enviar `User-Agent` + fallback silencioso                     |
| URL malformada no convite                                     | Lista de CORS em `FRONTEND_URL`                             | Separar `FRONTEND_URL` e `CORS_ORIGINS`                       |
| GitHub `remote: Internal Server Error` no push                | Instabilidade do GitHub                                     | Aguardar e tentar de novo; não é problema de permissão        |

---

## 8. Segurança

- **`service_role`:** só existe aqui. Nunca no frontend, nunca em log, nunca em
  chat. Se vazar, **rotacionar imediatamente** em Supabase → Settings → API →
  Reset.
- **Validação de JWT:** sempre via `supabaseAdmin.auth.getUser(token)`.
  **Nunca** decodificar o JWT manualmente para confiar no payload.
- **Filtro por `user_id`:** toda query com `service_role` precisa filtrar
  explicitamente. RLS não ajuda aqui.
- **`.env`:** não commitar. Se commitou uma vez, rotacionar tudo.
- **CORS:** lista explícita, sem `*`.

---

## 9. O que está fora do escopo deste repositório

- Renderização de UI → **frontend `psy-dbase-front`**
- Migrations SQL → **rodadas manualmente no SQL Editor do Supabase** por
  enquanto (a decidir se vale versionar em `supabase/migrations`)
- Autenticação OAuth → **Supabase Auth** (o backend só valida o token)
- Deploy do frontend → **Vercel**

---

## 10. Estado atual (última atualização)

- ✅ Estrutura Express + TypeScript + ESM configurada
- ✅ `env.ts` com validação
- ✅ `supabaseAdmin` com `ws` para Node 20
- ✅ `requireAuth` validando JWT
- ✅ `errorHandler` centralizado
- ✅ `POST /invites` funcionando (cria convite, encurta, monta WhatsApp)
- ✅ `GET /health`
- ⏳ Pendente: deploy do backend (host a definir)
- ⏳ Pendente: `POST /invites` aceitar `schedules` (horários obrigatórios)
- ⏳ Fase 3+: Calendar, WhatsApp API, PDF, transcrição

**Branches ativas:**
- Backend: `feature/form-creation`
- Frontend: `feat/design-imp`

**Endpoints em produção:** nenhum (só local).

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
`CORS_ORIGINS`, senão o navegador bloqueia antes de chegar no backend.

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