# psy-dbase

Backend do **psy-dbase** — sistema de gestão para psicólogo autônomo.

Responsável por tudo que exige **segredos** ou **integrações externas**:
autenticação administrativa, geração de convites com encurtamento de URL,
integração com Google Calendar + Meet, envio de WhatsApp/e-mail, geração de
PDF de recibo e transcrição de áudio.

> **Repositório irmão:** `psy-dbase-front` (React + Tailwind)

## Stack

| Camada        | Tecnologia                                  |
|---------------|---------------------------------------------|
| Runtime       | Node 20.x                                   |
| Framework     | Express 5                                   |
| Linguagem     | TypeScript 5.9                              |
| Execução dev  | tsx watch                                   |
| Banco / Auth  | Supabase (Postgres + Auth + Storage)        |
| SDK Supabase  | `@supabase/supabase-js` (com `service_role`)|
| WebSocket     | `ws` (Node 20 não tem nativo; ver seção)    |
| Encurtador    | TinyURL (API pública, sem chave)            |
| Deploy        | a definir (Render / Railway / Fly.io)       |
| Gerenciador   | npm                                         |

> **Idioma do código:** variáveis, funções, tipos e nomes de arquivo em inglês.
> Comentários em português.

## Arquitetura

```
[Frontend React]
       │  (JWT do usuário no header Authorization)
       ▼
[API Node / Express]  ──→  [Supabase Admin (service_role)]
       │                        (ignora RLS, escreve em qualquer tabela)
       │
       ├──→  [Google Calendar / Meet]      (Fase 3)
       ├──→  [WhatsApp / E-mail]           (Fase 6)
       ├──→  [Geração de PDF de recibo]    (Fase 5)
       └──→  [Transcrição de áudio]        (Fase 4, provedor a decidir)
```

- **Multi-tenant:** um psicólogo por conta. `auth.uid()` do JWT é a chave de
  isolamento.
- **`service_role`** só existe aqui. Nunca vai para o frontend.
- **RLS:** o backend ignora via `service_role`, mas ainda assim **toda tabela
  precisa de GRANT** para `service_role` funcionar (ver armadilhas no
  `CONTEXT.md`).

## Estrutura de pastas

```
src/
├── config/
│   └── env.ts                 # valida e exporta variáveis de ambiente
├── lib/
│   ├── supabase.ts            # cliente admin (service_role)
│   └── tinyurl.ts             # encurtador com fallback
├── middlewares/
│   ├── auth.ts                # valida JWT do Supabase, injeta req.userId
│   └── errorHandler.ts        # tratamento centralizado de erros
├── modules/
│   └── invites/
│       ├── invites.controller.ts
│       ├── invites.service.ts
│       └── invites.routes.ts
├── utils/
│   ├── phone.ts               # normaliza para formato internacional (55…)
│   └── whatsapp.ts            # monta link wa.me com mensagem
├── app.ts                     # configura Express
└── server.ts                  # sobe o servidor
```

## Rodando localmente

### 1. Pré-requisitos

- Node 20.x
- npm 10+
- Projeto Supabase configurado (mesmo do frontend)

### 2. Instalar

```bash
npm install
```

### 3. Variáveis de ambiente

Crie `.env` na raiz com:

```env
PORT=3333
SUPABASE_URL=https://SEU-PROJETO.supabase.co
SUPABASE_SERVICE_ROLE_KEY=eyJ...service_role_key
FRONTEND_URL=http://localhost:5173
CORS_ORIGINS=http://localhost:5173,https://seu-app.vercel.app
```

| Variável                     | Onde encontrar                                        |
|------------------------------|-------------------------------------------------------|
| `SUPABASE_URL`               | Supabase → Settings → API → Project URL               |
| `SUPABASE_SERVICE_ROLE_KEY`  | Supabase → Settings → API → `service_role` **secret** |
| `FRONTEND_URL`               | URL pública do frontend (usada para montar links)     |
| `CORS_ORIGINS`               | Lista separada por vírgula; origens permitidas        |

> ⚠️ **`service_role` ignora RLS e GRANT.** Ela só existe aqui. Nunca no
> frontend, nunca em log, nunca em chat. Se vazar, rotacione imediatamente em
> Supabase → Settings → API → Reset.

### 4. Rodar

```bash
npm run dev
```

Servidor sobe em `http://localhost:3333`.

### 5. Testar

```bash
curl http://localhost:3333/health
# {"ok":true}
```

## Scripts

| Comando         | O que faz                          |
|-----------------|------------------------------------|
| `npm run dev`   | Dev server com hot reload (`tsx`)  |
| `npm run build` | Compila TypeScript para `dist/`    |
| `npm start`     | Roda o build (`node dist/server.js`) |

## Endpoints

### `GET /health`

Health check. Sem autenticação.

```bash
curl http://localhost:3333/health
# {"ok":true}
```

### `POST /invites`

Cria um convite de paciente, gera URL curta e devolve o link do WhatsApp
pronto. Requer autenticação (JWT do Supabase).

**Headers:**
```
Authorization: Bearer <access_token_do_usuario>
Content-Type: application/json
```

**Body:**
```json
{
  "patientNameHint": "Maria Silva",
  "phone": "(11) 99999-9999"
}
```

- `patientNameHint` — opcional, aparece no formulário público
- `phone` — obrigatório, aceita vários formatos; normalizado para E.164 (`55…`)

**Resposta 201:**
```json
{
  "inviteId": "uuid",
  "token": "uuid",
  "publicUrl": "http://localhost:5173/form/uuid",
  "shortUrl": "https://tinyurl.com/xxxxx",
  "whatsappUrl": "https://wa.me/5511999999999?text=...",
  "phone": "5511999999999"
}
```

**Erros:**

| Status | Motivo                                    |
|--------|-------------------------------------------|
| 400    | Telefone ausente ou inválido              |
| 401    | Token ausente ou inválido                 |
| 400    | Falha ao criar convite (erro do Supabase) |

## Autenticação

- O backend **valida** o JWT do Supabase em `requireAuth`.
- Não gera token — quem gera é o Supabase Auth (login Google no frontend).
- Usa `supabaseAdmin.auth.getUser(token)` para validar.
- Injeta `req.userId` com o `id` do usuário autenticado.

## Node 20 e WebSocket

O `@supabase/supabase-js` v2 inicializa o cliente Realtime (WebSocket) por
padrão. Node 20 **não tem WebSocket nativo** (só Node 22+). Por isso o pacote
`ws` está instalado e é passado via `transport`:

```ts
import ws from "ws";
createClient(url, key, {
  realtime: { transport: ws as any },
});
```

Sem isso, o servidor quebra ao subir com:
`Error: Node.js 20 detected without native WebSocket support.`

## CORS

Aceita múltiplas origens via `CORS_ORIGINS` (separadas por vírgula). O
`FRONTEND_URL` é usado **apenas** para montar a URL do formulário público —
não confundir com CORS.

## Deploy

A definir (Render / Railway / Fly.io). Após o deploy:

1. Adicionar o domínio do backend em `CORS_ORIGINS` no `.env`
2. Adicionar o domínio do backend em `FRONTEND_URL` no `.env` do frontend
3. Garantir que as variáveis de ambiente estão configuradas no painel do host

## Conformidade

- **LGPD:** dado sensível de saúde. O backend apenas processa o que o frontend
  e o Supabase já isolam via RLS.
- **`service_role`:** ignora RLS, então **toda query precisa filtrar por
  `user_id`** manualmente. Nunca confie que o RLS vai proteger uma query feita
  com `service_role`.

## Documentos relacionados

- [`TODO.md`](./TODO.md) — tarefas pendentes por fase
- [`CONTEXT.md`](./CONTEXT.md) — contexto para IA: arquitetura, decisões, padrões
- [`../psy-dbase-front/CONTEXT.md`](../psy-dbase-front/CONTEXT.md) — contexto do frontend

## Licença

A definir.