-- =====================================================================
-- Iarla Ingrid · pedidos pelo site + alerta + impressão automática
-- Rodar UMA vez no Supabase: SQL Editor > New query > colar > Run
-- Pode rodar de novo sem problema (não duplica nada).
-- =====================================================================

-- 1) Marca de "comanda impressa" em cada pedido
alter table public.pedidos add column if not exists impresso_em timestamptz;

-- Os pedidos que já existem contam como impressos (para não imprimir tudo de uma vez)
update public.pedidos set impresso_em = now() where impresso_em is null;

-- 2) Aviso em tempo real: o painel fica sabendo do pedido novo na hora
do $$
begin
  alter publication supabase_realtime add table public.pedidos;
exception
  when duplicate_object then null;
  when undefined_object then null;
end $$;

-- 3) Trava contra pedidos em sequência (brincadeira ou robô enchendo a impressora)
create or replace function public.limitar_pedidos()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
  fone text := regexp_replace(coalesce(new.cliente_whatsapp, ''), '\D', '', 'g');
begin
  -- mesmo WhatsApp: no máximo 3 pedidos em 15 minutos
  select count(*) into n
    from public.pedidos
   where regexp_replace(coalesce(cliente_whatsapp, ''), '\D', '', 'g') = fone
     and criado_em > now() - interval '15 minutes';
  if n >= 3 then
    raise exception 'Recebemos vários pedidos seguidos deste número. Aguarde alguns minutos ou fale com a loja pelo WhatsApp.'
      using errcode = 'P0001';
  end if;

  -- a loja toda: no máximo 25 pedidos em 10 minutos
  select count(*) into n
    from public.pedidos
   where criado_em > now() - interval '10 minutes';
  if n >= 25 then
    raise exception 'Estamos recebendo muitos pedidos agora. Tente de novo em alguns minutos ou fale com a loja pelo WhatsApp.'
      using errcode = 'P0001';
  end if;

  return new;
end $$;

drop trigger if exists trg_limitar_pedidos on public.pedidos;
create trigger trg_limitar_pedidos
  before insert on public.pedidos
  for each row execute function public.limitar_pedidos();

-- Conferência: deve mostrar a coluna nova e a trava
select
  (select count(*) from information_schema.columns
    where table_schema = 'public' and table_name = 'pedidos' and column_name = 'impresso_em') as coluna_impresso_em,
  (select count(*) from pg_trigger where tgname = 'trg_limitar_pedidos') as trava_pedidos,
  (select count(*) from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'pedidos') as tempo_real;
