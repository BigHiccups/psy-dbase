# Psychology Practice Manager

Sistema web de gestão para psicólogo autônomo. Cobre cadastro de pacientes,
agenda integrada ao Google Calendar + Meet, prontuário com evolução SOAP,
financeiro com entradas/saídas categorizadas, recibos e relatórios.

## Stack

| Camada         | Tecnologia                                      |
|----------------|-------------------------------------------------|
| Frontend       | React + Tailwind CSS (deploy: Vercel)           |
| Backend        | Node.js + TypeScript (deploy: a definir)        |
| Banco / Auth   | Supabase (Postgres + Auth + Storage + RLS)      |
| Autenticação   | Supabase Auth com Google OAuth                  |
| Calendário     | Google Calendar API + Google Meet               |
| Notificações   | WhatsApp API + E-mail (a definir provedor)      |
| Repositório    | GitHub                                          |

> **Idioma do código:** nomes de variáveis, funções, tipos e arquivos em
> inglês. Comentários em português.

## Arquitetura

```
[React + Tailwind]  →  [Supabase JS Client]  →  [Supabase Postgres + RLS]
        │
        └──→  [Node API]  →  [Google Calendar / Meet]
                          →  [WhatsApp / E-mail]
                          →  [Storage de áudio / PDFs]
```

- **Leitura e escrita de dados:** o frontend fala **direto** com o Supabase
  (via `@supabase/supabase-js`). RLS garante isolamento por psicólogo.
- **Backend Node:** usado apenas para operações que exigem segredos
  (Google OAuth, criação de eventos, envio de WhatsApp/e-mail, geração de
  recibo em PDF, transcrição de áudio).
- **Multi-tenant:** um psicólogo por conta. `user_id` do Supabase é a chave
  de isolamento em todas as tabelas.

## Conformidade

- **LGPD:** dado sensível de saúde. Consentimento explícito, criptografia em
  repouso e em trânsito, direito ao esquecimento, trilha de auditoria.
- **Sigilo profissional:** acesso ao prontuário apenas por link com hash
  expirável. Sem indexação, sem cache.
- **Auditoria:** toda leitura de prontuário é registrada em `audit_log`.

## Requisitos Funcionais

### RF01 — Cadastro de pacientes
- Formulário público (fora do sistema autenticado), acessível por link.
- **Link único por paciente, com token seguro.**
- Campos: nome, CPF, cidade, nascimento, telefone, contato de urgência.
- Termo de confidencialidade assinado pelo paciente.
- Após envio, registro entra como **pendente** e o psicólogo aprova.

### RF02 — Agenda + Google Calendar + Meet
- Integração **obrigatória** com Google Calendar do psicólogo.
- Integração com agenda do paciente é **opcional**.
- Sessão pode ter N participantes (paciente, acompanhante, co-psicólogo,
  terapia de casal) — **configurável**.
- Sala do Meet sugerida automaticamente quando o atendimento for remoto.
- Se o atendimento for presencial via WhatsApp, o Meet não é gerado.
- Psicólogo e paciente recebem o link do Meet quando aplicável.

### RF03 — Prontuário
- Dados do formulário inicial integrados ao prontuário.
- **Anamnese inicial:** queixa principal, suspeita diagnóstica, histórico de
  saúde, medicações em uso, hábitos de vida.
- **Contato inicial.**
- **Registro de evolução por sessão (SOAP + Atuação):**
  - **S**ubjetivo — relato do paciente.
  - **O**bjetivo — observações e sinais.
  - **A**valiação — análise profissional.
  - **P**lano — próximos passos.
  - **Atuação do psicólogo** — o que foi feito na sessão.
- **Transcrição de áudio da sessão** (integração futura — depende de provedor
  com custo aceitável; Whisper pago está em avaliação).
- **Palavras e sentenças importantes** destacadas.
- **Compartilhamento por link com hash expirável:** ao expirar, o hash fica
  inválido e o registro some da visualização.

### RF04 — Financeiro
- **Entradas** (sessões pagas/recebidas):
  `Data da Sessão | Nº da Sessão | Status da Sessão | Forma de Pagamento |
   Dia do Pagamento | Status do Pagamento | Valor Pago | Atendimentos |
   Total Recebido`
- **Saídas categorizadas** (gastos do consultório):
  `Nome do Serviço | Forma de Pagamento | Dia do Pagamento |
   Status do Pagamento | Valor Pago | Total Gasto`
- **Gastos específicos** (ex.: terapia pessoal do psicólogo):
  `Data da Sessão | Status da Sessão | Forma de Pagamento | Dia do Pagamento |
   Status do Pagamento | Valor Pago | Atendimentos | Total Pago`
- Alertas de vencimento.
- Pagamentos à vista, antecipados, por sessão ou por pacote.
- Emissão de recibo (PDF).

### RF05 — Relatórios
- Entradas x saídas.
- Quantidade de pacientes novos.
- Evoluções registradas.
- Ocupação da agenda.
- Faturamento por período.

### RF06 — Regras configuráveis
- Duração padrão da sessão (default: 50 min).
- Política de remarcação (horas mínimas de antecedência).
- Multa por falta (valor fixo ou percentual).

### RF07 — Notificações
- Lembretes por WhatsApp.
- Lembretes por e-mail.
- A definir provedor de WhatsApp (Cloud API oficial vs. intermediário).

## Requisitos Não Funcionais

- RLS obrigatório em todas as tabelas sensíveis.
- Links de prontuário: hash opaco (UUID v4) + expiração.
- Sem indexação (robots, headers) em páginas de prontuário e formulário.
- Criptografia em repouso (Supabase) e em trânsito (HTTPS).
- Auditoria de acesso ao prontuário.
- Compatível com LGPD.

## Modelo de Dados (esboço)

```
profiles                  — espelha auth.users (psicólogo)
patients
patient_invites           — link único por paciente (token)
patient_form_submissions  — dados do formulário antes da aprovação
consent_terms
anamnesis
appointments              — agenda + google_event_id + meet_link
appointment_attendees     — N participantes por atendimento
sessions                  — sessão realizada
evolutions                — SOAP + atuação
evolution_audio           — transcrição
evolution_keywords
share_links               — hash expirável do prontuário
incomes
expenses
expense_categories
session_payments
personal_therapy          — gastos do psicólogo como paciente
receipts
reminders
audit_log
settings                  — duração padrão, política de remarcação, multa
```

## Fases do Projeto

1. **Fase 1 — Fundação:** Supabase, Auth Google, RLS base, layout React +
   Tailwind, rota protegida.
2. **Fase 2 — Pacientes + Formulário público.**
3. **Fase 3 — Agenda + Google Calendar + Meet.**
4. **Fase 4 — Prontuário + Anamnese + Evolução SOAP + Áudio.**
5. **Fase 5 — Financeiro + Recibos + Relatórios.**
6. **Fase 6 — Notificações + Share links expiráveis.**

## Decisões Pendentes

| # | Ponto | Status |
|---|-------|--------|
| P3 | Definir se "duas pessoas" é configurável por tipo de atendimento | ✅ configurável |
| P4 | Provedor de transcrição de áudio | ❓ Whisper pago em avaliação |
| P5 | Assinatura do termo: canvas ou upload de PDF | ❓ pendente |
| P6 | Layout do recibo em PDF | ❓ pendente |
| P7 | Provedor de WhatsApp (Cloud API oficial vs. intermediário) | ❓ pendente |
| P8 | Quem pode ver o prontuário pelo link — qualquer portador ou e-mail autorizado | ❓ pendente |
| —  | Host do backend Node | ❓ pendente |

## Estrutura do Repositório (proposta)

```
psychology-practice-manager/
├── apps/
│   ├── web/              # React + Tailwind (Vercel)
│   └── api/              # Node + TypeScript (integrações)
├── packages/
│   └── shared/           # tipos e validações compartilhadas
├── supabase/
│   ├── migrations/       # SQL versionado
│   └── seed/
├── docs/
│   ├── README.md
│   ├── TODO.md
│   └── data-model.md
└── package.json
```

## Licença

A definir.