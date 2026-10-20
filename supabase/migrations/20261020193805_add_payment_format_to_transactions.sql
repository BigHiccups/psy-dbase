ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS payment_format text 
  CHECK (payment_format IN ('vencimento', 'antecipado', 'avulso'));

-- Atualiza as transações antigas para terem o formato padrão (para não ficarem nulas)
UPDATE public.transactions SET payment_format = 'avulso' WHERE payment_format IS NULL;