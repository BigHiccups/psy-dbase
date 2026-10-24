Você tem toda a razão. Eu condensei demais e acabei perdendo o detalhamento das regras de negócio, das constraints do banco e dos "porquês" que fazem esse documento ser a fonte da verdade.

Um bom `CONTEXT.md` precisa manter o histórico das decisões (para não voltarmos atrás) e explicar a fundo as tabelas, RPCs e fluxos.

Aqui está o **`CONTEXT.md` do Backend (psy-dbase) completo, detalhado e atualizado**, mesclando toda a base original com as novas funcionalidades (Multi-serviços, Bulk Import, Financeiro).

*(Copie o bloco abaixo e substitua o conteúdo do seu arquivo atual).*

---

```markdown
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

```text
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
```

---

## 4. Decisões de arquitetura

### 4.1 O backend só faz o que exige segredo
Dados de aplicação são lidos e escritos **direto pelo frontend no Supabase**,
com RLS protegendo. O backend Node **não** é um CRUD — é uma camada de
integrações.

**Regra:** se a operação só precisa de RLS e não usa segredo externo, ela **não
vai para o backend**.

### 4.2 `service_role` é usada no backend
O cliente `supabaseAdmin` usa a `service_role`, que **ignora RLS e GRANTs**.
- **Toda query precisa filtrar por `user_id` manualmente.**
- **Nunca** logar a chave, nunca commitar `.env`.
> A `service_role` foi rotacionada após vazar em chat durante o desenvolvimento.

### 4.3 GRANT explícito em toda tabela nova
Mesmo com `service_role`, o Postgres precisa que o GRANT exista na tabela.
Sempre incluir nas migrations:
```sql
grant usage on schema public to service_role;
grant select, insert, update, delete on public.<tabela> to service_role;
```
O GRANT para `authenticated` (usado pelo frontend via RLS) também é obrigatório.

### 4.4 WebSocket via `ws` (Node 20)
`@supabase/supabase-js` inicializa o cliente Realtime por padrão. Node 20 não tem WebSocket nativo.
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

### 4.7 CORS configurável via lista
`CORS_ORIGINS` aceita múltiplas origens separadas por vírgula. `FRONTEND_URL`
é **outra variável** — usada só para montar URLs.

### 4.8 Deploy na Vercel — serverless com Express adaptado
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

### 4.9 Google Calendar — Novo Fluxo (Materialização Adiada)
**Decisão estratégica:** O Google Calendar é **ponto de partida**, não fonte contínua de verdade.

**Nova Arquitetura de Importação:**
1. O backend busca os eventos (`singleEvents: true`).
2. Corrige o fuso horário forçando `America/Sao_Paulo`.
3. Trata eventos de "Dia Inteiro" (assume `08:00`).
4. Separa eventos recorrentes (viram regras fixas) de exceções (remarcações).
5. Cria o `patient` (prospect) e salva em `patient_schedules`.
6. **IMPORTANTE:** A importação **NÃO CRIA MAIS** `appointments` diretamente. A agenda só é populada quando o usuário aprova o prospect no Dashboard (via RPC).

**Otimização contra Timeout:**
A importação não faz loops N+1 no banco. O backend monta um array JSON com todos os dados e envia de uma vez para a RPC `bulk_import_google_calendar`. Isso resolveu o travamento de 10s da Vercel.

### 4.10 Status `prospect` e a tabela `providers`
**`patients.status`:** `prospect` | `active` | `inactive` | `discharged`
- **`prospect`** — aguardando revisão.
- **`active`** — em tratamento.

**Tabela `providers`** separa pacientes de prestadores/instituições:
- `kind = 'person'` → psicólogo, supervisor.
- `kind = 'company'` → curso, aluguel.

### 4.11 Arquitetura Multi-Serviços
Um paciente ou prestador pode ter **múltiplos serviços** (ex: Terapia Individual e Supervisão).
- **`patient_schedules` e `provider_schedules`**: Guardam as regras fixas (`title`, `color`, `session_price_cents`, `payment_format`, `recurrence_type`, `anchor_date`).
- **`appointments`**: Materialização na agenda. Recebe cópia de `title`, `color` e `session_price_cents`.
- **Horários Nulos:** `start_time` e `duration_min` aceitam `NULL` para "Dia Inteiro" (boletos/vencimentos).

### 4.12 `appointments` — Modelo e Tipos
| `type` | `patient_id` | `provider_id` | Ocupa agenda? |
|---|---|---|---|
| `session` | obrigatório | null | sim |
| `personal` | null | obrigatório | sim |
| `blocked` | null | null | sim |
*(O tipo `due` foi descontinuado e substituído pela tabela `provider_billings`).*

### 4.13 Idempotência da importação (2 camadas)
- **Camada 1 (`google_imported_recurrences`):** mapeia `recurringEventId` → `(target_type, target_id)`.
- **Camada 2 (`appointments.google_event_id`):** ID único da ocorrência.

### 4.14 RPCs de Schedule e Conflito
As RPCs `set_patient_schedules` e `set_provider_schedules` foram reescritas para:
1. Aceitar as novas colunas (`title`, `color`, `session_price_cents`).
2. Aceitar horários nulos.
3. Validar conflitos por **Sobreposição de Intervalo** (`a.start < b.end AND b.start < a.end`).
4. Usar `ON CONFLICT DO UPDATE` para atualizar a cor/título de horários existentes sem quebrar o banco.

### 4.15 Vínculo e Revisão de Prospects
- **É paciente:** `promote_prospect_to_active` (cria a agenda).
- **É prestador:** `convert_prospect_to_provider`.
- **Remover:** `discard_prospect`.
- **Vincular a paciente existente:** `merge_prospect_into_patient` (move horários, deleta o prospect e atualiza o histórico).

### 4.16 Módulo Financeiro (`transactions`)
O backend suporta as tabelas financeiras (`transactions`, `provider_billings`), mas o CRUD principal é feito via frontend e RLS. A RPC `create_income_from_appointment` foi atualizada para puxar o valor direto do `appointment.session_price_cents`, em vez de depender apenas do cadastro do paciente.

---

## 5. Fluxos implementados

### 5.1 `POST /invites`
1. `requireAuth` valida o JWT.
2. `validateSchedules` valida os horários.
3. Insere em `patient_invites` + `patient_invite_schedules`.
4. TinyURL oficial encurta.
5. Monta `wa.me/<phone>?text=...`.

### 5.2 Google Calendar — Importação
1. Frontend chama `POST /calendar/import`.
2. Backend busca eventos (últimos 60 dias + 90 futuros).
3. Cria Prospects e salva horários via RPC em lote.
4. O frontend aprova no Dashboard e a agenda é populada.

---

## 6. Convenções de código
- **Idioma:** variáveis/funções/tipos em inglês. Comentários em português.
- **ESM:** imports **precisam** terminar em `.js`.
- **Erros:** lançar `Error` no service, capturar no `errorHandler` central.
- **Nada de `any`:** exceto em integrações com bibliotecas.

---

## 7. Armadilhas conhecidas

| Sintoma | Causa | Solução |
|---|---|---|
| **500 em tudo na Vercel** | Falta `vercel.json` ou `export default app` | Verificar config serverless |
| **Timeout de 10s na importação** | Loops N+1 no banco de dados | Usar a RPC `bulk_import_google_calendar` |
| **Eventos do Google sem horário** | Eventos "Dia Inteiro" no Google | Backend assume `08:00` e duração de 60min |
| **Fuso horário errado na importação** | Vercel roda em UTC | Usar `Intl.DateTimeFormat` com `America/Sao_Paulo` |
| **`duplicate key value violates unique constraint`** | Salvar horário que já existe | RPC de schedule usa `ON CONFLICT DO UPDATE` |
| `permission denied for table` mesmo com `service_role` | GRANT não existe | `grant … to service_role` |
| `ERR_MODULE_NOT_FOUND` | Import sem `.js` | Adicionar `.js` (ESM) |

---

## 8. Segurança
- **`service_role`:** só existe no backend + painel da Vercel. Se vazar, **rotacionar imediatamente**.
- **`google_credentials.refresh_token`:** plain na tabela, sem policies para `authenticated`.
- **CORS:** lista explícita, sem `*`.

---

## 9. Estado atual (última atualização)

**Concluído:**
- ✅ Estrutura Express + TypeScript + ESM
- ✅ `requireAuth` validando JWT
- ✅ `POST /invites` e TinyURL oficial
- ✅ Módulo `calendar` completo (connect / callback / status / import / disconnect).
- ✅ Importação otimizada (Bulk Insert, Fuso Horário, Dia Inteiro).
- ✅ Multi-serviços com suporte a `title`, `color` e `session_price_cents`.
- ✅ RPCs `merge_prospect_into_patient` e `promote_prospect_to_active`.
- ✅ Tabelas do Financeiro (`transactions`, `provider_billings`, `dismissed_suggestions`).
- ✅ Integração do `session_price_cents` do agendamento com a receita.

**Pendente (Próximas Fases):**
- ⏳ Escrita no Google Calendar (psy-dbase → Calendar).
- ⏳ Geração de PDF de Recibos (Fase 5).
- ⏳ Envio de Notificações (WhatsApp / E-mail).
- ⏳ Transcrição de áudio (Fase 4).

**Branches ativas:**
- Backend: `main`
- Frontend: `main`
```

---