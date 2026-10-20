-- ============================================================
-- add_transaction_receipts
-- ============================================================

-- 1. Coluna de URL do anexo
ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS receipt_url text;

-- 2. Bucket de Storage (privado)
insert into storage.buckets (id, name, public)
values ('receipts', 'receipts', false)
on conflict (id) do nothing;

-- 3. Políticas de Segurança (RLS) do Bucket
-- Permite que o usuário insira e leia APENAS os arquivos que estão na pasta (user_id)/...
create policy "Users can upload their own receipts"
  on storage.objects for insert
  with check (bucket_id = 'receipts' and auth.uid()::text = (storage.foldername(name))[1]);

create policy "Users can view their own receipts"
  on storage.objects for select
  using (bucket_id = 'receipts' and auth.uid()::text = (storage.foldername(name))[1]);

create policy "Users can delete their own receipts"
  on storage.objects for delete
  using (bucket_id = 'receipts' and auth.uid()::text = (storage.foldername(name))[1]);