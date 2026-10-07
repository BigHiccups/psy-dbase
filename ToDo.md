# TODO — Psychology Practice Manager

Legenda: `[ ]` pendente · `[~]` em andamento · `[x]` concluído · `[!]` bloqueado

---

## Fase 0 — Documentação e decisões

- [x] Consolidar stack (React + Tailwind / Node / Supabase / Vercel)
- [x] Consolidar requisitos funcionais
- [x] Consolidar requisitos não funcionais
- [x] Esboçar modelo de dados
- [x] Escrever README.md
- [x] Escrever TODO.md
- [ ] Definir assinatura do termo (canvas vs. upload de PDF)
- [ ] Definir layout do recibo em PDF
- [ ] Definir provedor de WhatsApp (Cloud API vs. intermediário)
- [ ] Definir regra de acesso ao prontuário por link (portador vs. e-mail autorizado)
- [ ] Definir provedor de transcrição de áudio (avaliar custo do Whisper)
- [ ] Definir host do backend Node (Render / Fly.io / Railway)

---

## Fase 1 — Fundação

### Supabase
- [ ] Criar projeto no Supabase
- [ ] Configurar Auth com Google OAuth
- [ ] Configurar Storage (áudio, PDFs de recibo, termos assinados)
- [ ] Criar tabela `profiles` espelhando `auth.users`
- [ ] Trigger para popular `profiles` no signup
- [ ] Habilitar RLS em todas as tabelas
- [ ] Criar policies base (`auth.uid() = user_id`)

### Frontend (React + Tailwind)
- [ ] Setup Vite + React + TypeScript
- [ ] Configurar Tailwind
- [ ] Configurar ESLint + Prettier
- [ ] Cliente Supabase (`@supabase/supabase-js`)
- [ ] Contexto de autenticação (`AuthProvider`)
- [ ] Rota protegida (`ProtectedRoute`)
- [ ] Tela de login com botão "Entrar com Google"
- [ ] Layout base (sidebar + header)
- [ ] Deploy inicial na Vercel

### Backend (Node + TypeScript)
- [ ] Setup do projeto (Express ou Fastify)
- [ ] Configuração de variáveis de ambiente
- [ ] Middleware de validação de JWT do Supabase
- [ ] Health check (`/health`)
- [ ] Deploy inicial

---

## Fase 2 — Pacientes + Formulário Público

### Banco
- [ ] Tabela `patients`
- [ ] Tabela `patient_invites` (token único por paciente)
- [ ] Tabela `patient_form_submissions`
- [ ] Tabela `consent_terms`
- [ ] Policies RLS para todas as tabelas acima

### Frontend
- [ ] Listagem de pacientes
- [ ] Detalhe do paciente
- [ ] Geração de link único por paciente (token seguro)
- [ ] Página pública do formulário (fora do sistema autenticado)
- [ ] Validação de token expirado/inválido
- [ ] Assinatura do termo de confidencialidade
- [ ] Fluxo de aprovação do cadastro pelo psicólogo
- [ ] Headers `noindex` na página pública

### Backend
- [ ] Endpoint para gerar token seguro
- [ ] Endpoint para receber submissão do formulário
- [ ] Notificação ao psicólogo quando novo cadastro chega

---

## Fase 3 — Agenda + Google Calendar + Meet

### Banco
- [ ] Tabela `appointments`
- [ ] Tabela `appointment_attendees` (N participantes)
- [ ] Policies RLS

### Backend
- [ ] OAuth do Google para o psicólogo (obrigatório)
- [ ] Refresh token armazenado com segurança
- [ ] Criação de evento no Google Calendar
- [ ] Geração de link do Meet (`conferenceData`)
- [ ] Convite opcional para agenda do paciente
- [ ] Suporte a N participantes (acompanhante, co-psicólogo, casal)
- [ ] Cancelamento/remarcação sincronizado com o Calendar

### Frontend
- [ ] Calendário visual (mensal/semanal)
- [ ] Criação de sessão com participantes configuráveis
- [ ] Exibição do link do Meet
- [ ] Configuração de duração padrão (default 50 min)
- [ ] Configuração de política de remarcação e multa
- [ ] Envio de link por WhatsApp quando aplicável

---

## Fase 4 — Prontuário + Anamnese + Evolução SOAP + Áudio

### Banco
- [ ] Tabela `anamnesis`
- [ ] Tabela `sessions`
- [ ] Tabela `evolutions` (SOAP + atuação)
- [ ] Tabela `evolution_audio`
- [ ] Tabela `evolution_keywords`
- [ ] Tabela `share_links` (hash expirável)
- [ ] Tabela `audit_log`
- [ ] Policies RLS

### Frontend
- [ ] Tela de prontuário do paciente
- [ ] Formulário de anamnese inicial
- [ ] Editor de evolução SOAP + campo "Atuação do psicólogo"
- [ ] Upload de áudio da sessão
- [ ] Destaque de palavras/sentenças importantes
- [ ] Geração de link compartilhável com expiração
- [ ] Página pública de visualização via hash
- [ ] Invalidação automática após expirar
- [ ] Headers `noindex` na página de prontuário compartilhado

### Backend
- [ ] Transcrição de áudio (provedor a definir)
- [ ] Extração de palavras-chave
- [ ] Registro de auditoria a cada leitura de prontuário

---

## Fase 5 — Financeiro + Recibos + Relatórios

### Banco
- [ ] Tabela `incomes`
- [ ] Tabela `expenses`
- [ ] Tabela `expense_categories`
- [ ] Tabela `session_payments`
- [ ] Tabela `personal_therapy`
- [ ] Tabela `receipts`
- [ ] Policies RLS

### Frontend
- [ ] Lançamento de entradas (tabela completa conforme RF04)
- [ ] Lançamento de saídas categorizadas
- [ ] Lançamento de gastos específicos (terapia pessoal etc.)
- [ ] Filtros por período, status, forma de pagamento
- [ ] Alertas de vencimento
- [ ] Suporte a pagamento por sessão e por pacote
- [ ] Pagamento à vista e antecipado
- [ ] Geração e download de recibo em PDF
- [ ] Dashboard com entradas x saídas
- [ ] Relatório de pacientes novos
- [ ] Relatório de evoluções
- [ ] Relatório de ocupação da agenda

### Backend
- [ ] Geração de PDF de recibo
- [ ] Job de alertas de vencimento

---

## Fase 6 — Notificações + Share Links

### Notificações
- [ ] Integração com WhatsApp (provedor a definir)
- [ ] Integração com e-mail (Resend ou SES)
- [ ] Template de lembrete de sessão
- [ ] Template de alerta de vencimento
- [ ] Preferências de notificação por paciente

### Segurança e conformidade
- [ ] Política de privacidade
- [ ] Termos de uso
- [ ] Fluxo de consentimento LGPD
- [ ] Direito ao esquecimento (exclusão de dados do paciente)
- [ ] Revisão de policies RLS
- [ ] Testes de isolamento entre contas

---

## Transversal — Qualidade

- [ ] Testes unitários (Vitest)
- [ ] Testes de integração das policies RLS
- [ ] CI/CD no GitHub Actions
- [ ] Monitoramento de erros (Sentry)
- [ ] Logs estruturados no backend
- [ ] Documentação da API (OpenAPI)
- [ ] Seed de dados para desenvolvimento

---

## Ordem sugerida de execução

1. Fase 0 (fechar decisões pendentes)
2. Fase 1 (fundação)
3. Fase 2 (pacientes + formulário)
4. Fase 3 (agenda + Calendar + Meet)
5. Fase 4 (prontuário + SOAP + áudio)
6. Fase 5 (financeiro)
7. Fase 6 (notificações + conformidade)