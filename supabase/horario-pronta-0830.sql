-- =====================================================================
-- Iarla Ingrid · pronta-entrega das 08:30 às 18:30
-- (ou a partir da abertura da loja, se ela abrir depois das 08:30, ex.: segunda 13h)
-- Rodar no Supabase: SQL Editor > New query > colar > Run. Pode rodar de novo.
-- =====================================================================
create or replace function public.criar_pedido(p jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  cfg        configuracoes;
  agora      timestamp := now() at time zone 'America/Fortaleza';
  hoje       date := (now() at time zone 'America/Fortaleza')::date;
  v_nome     text := left(trim(coalesce(p->>'nome','')), 80);
  v_wa       text := regexp_replace(coalesce(p->>'whatsapp',''), '\D', '', 'g');
  v_modo     text := coalesce(p->>'modo','retirada');
  v_data     date;
  v_hor      text := nullif(left(trim(coalesce(p->>'horario','')), 5), '');
  v_pag      text := coalesce(p->>'pagamento','');
  v_taxa     numeric(10,2) := 0;
  v_bairro   text;
  dia        jsonb;
  it         jsonb;
  prod       produtos;
  v_qtd      int;
  v_idx      int;
  v_preco    numeric(10,2);
  v_unid     int;
  v_nome_it  text;
  v_det      text;
  v_sabor    text;
  v_sub      numeric(10,2) := 0;
  v_ped      pedidos;
  linhas     jsonb := '[]'::jsonb;
  v_tipo     text;          -- 'pronta' ou 'enc'
  v_tipo_it  text;
  v_temfs    boolean;       -- estoque separado por sabor
  v_fs       int;
  pr_de      text := '08:30';
  pr_ate     constant text := '18:30';
begin
  select * into cfg from configuracoes where id = 1;

  -- dados básicos
  if length(v_nome) < 2 then raise exception 'Informe seu nome.'; end if;
  if length(v_wa) < 10 or length(v_wa) > 13 then raise exception 'Informe um WhatsApp válido com DDD.'; end if;
  if v_modo not in ('retirada','entrega') then raise exception 'Escolha retirada ou entrega.'; end if;
  if jsonb_typeof(p->'itens') is distinct from 'array' or jsonb_array_length(p->'itens') = 0 then raise exception 'Seu pedido está vazio.'; end if;
  if jsonb_array_length(p->'itens') > 40 then raise exception 'Pedido com itens demais.'; end if;
  if coalesce((cfg.pagamentos->>v_pag)::boolean, false) is not true then raise exception 'Forma de pagamento indisponível.'; end if;

  -- proteção contra envios repetidos
  if (select count(*) from pedidos where cliente_whatsapp = v_wa and criado_em > now() - interval '10 minutes') >= 3 then
    raise exception 'Você enviou vários pedidos seguidos. Aguarde alguns minutos ou fale com a loja pelo WhatsApp.';
  end if;

  begin v_data := (p->>'data')::date; exception when others then raise exception 'Escolha a data do pedido.'; end;
  if v_data is null then raise exception 'Escolha a data do pedido.'; end if;

  -- entrega
  if v_modo = 'entrega' then
    if not cfg.entrega_ativa then raise exception 'Entregas pausadas no momento. Escolha retirada.'; end if;
    if length(trim(coalesce(p->>'endereco',''))) < 3 then raise exception 'Informe o endereço de entrega.'; end if;
    if nullif(p->>'bairro_id','') is not null then
      select nome, taxa into v_bairro, v_taxa from bairros where id = (p->>'bairro_id')::uuid and ativo;
      if v_bairro is null then raise exception 'Bairro indisponível para entrega.'; end if;
    else
      if cfg.bairro_fora <> 'combinar' then raise exception 'Escolha um bairro da lista.'; end if;
      v_bairro := left(trim(coalesce(p->>'bairro_texto','')), 60);
      if length(v_bairro) < 2 then raise exception 'Informe o bairro.'; end if;
      v_taxa := null;   -- a combinar pelo WhatsApp
    end if;
  end if;

  -- itens: preço vem do banco, estoque é reservado aqui
  for it in select * from jsonb_array_elements(p->'itens') loop
    v_qtd := coalesce((it->>'qtd')::int, 0);
    if v_qtd < 1 or v_qtd > 50 then raise exception 'Quantidade inválida.'; end if;

    select * into prod from produtos where id = (it->>'produto_id')::uuid for update;
    if prod.id is null or not prod.ativo then raise exception 'Um dos produtos não está mais disponível.'; end if;
    if prod.esgotado then raise exception '% está esgotado.', prod.nome; end if;

    v_nome_it := prod.nome; v_det := '';
    if jsonb_array_length(prod.tamanhos) > 0 then
      v_idx := coalesce((it->>'tamanho')::int, -1);
      if v_idx < 0 or v_idx >= jsonb_array_length(prod.tamanhos) then raise exception 'Escolha a quantidade de %.', prod.nome; end if;
      v_preco := (prod.tamanhos->v_idx->>'preco')::numeric;
      v_unid  := v_qtd * (prod.tamanhos->v_idx->>'qtd')::int;
      v_nome_it := prod.nome || ' (' || (prod.tamanhos->v_idx->>'qtd') || ' un.)';
    else
      v_preco := prod.preco;
      v_unid  := v_qtd;
    end if;

    v_sabor := nullif(trim(coalesce(it->>'sabor','')), '');
    if array_length(prod.sabores, 1) > 0 then
      if v_sabor is null or not (v_sabor = any(prod.sabores)) then v_sabor := prod.sabores[1]; end if;
      v_det := v_sabor;
    elsif prod.sabor_a_combinar then
      v_det := 'sabor a combinar';
    end if;
    if prod.porcao <> '' and prod.porcao <> 'Individual' then
      v_det := trim(both ' · ' from lower(prod.porcao) || ' · ' || v_det);
    end if;

    -- tipo do item (com estoque por sabor, vale a quantidade do sabor escolhido)
    v_temfs := prod.estoque_ativo and jsonb_typeof(prod.estoque_sabores) = 'object'
               and coalesce(array_length(prod.sabores, 1), 0) > 1 and v_sabor is not null;
    if v_temfs then
      v_fs := greatest(coalesce((prod.estoque_sabores->>v_sabor)::int, 0), 0);
      if v_fs > 0 then v_tipo_it := 'pronta';
      elsif prod.encomenda_ao_zerar then v_tipo_it := 'enc';
      else raise exception 'O sabor % de % acabou. Escolha outro sabor.', v_sabor, prod.nome;
      end if;
    elsif prod.estoque_ativo and prod.estoque > 0 then
      v_tipo_it := 'pronta';
    elsif prod.estoque_ativo and not prod.encomenda_ao_zerar then
      raise exception '% está esgotado.', prod.nome;
    else
      v_tipo_it := 'enc';
    end if;
    if v_tipo is null then v_tipo := v_tipo_it;
    elsif v_tipo <> v_tipo_it then
      raise exception 'Pronta-entrega e encomenda vão em pedidos separados. Remova um dos tipos para continuar.';
    end if;

    if v_tipo_it = 'pronta' and v_temfs then
      if v_fs < v_unid then
        if prod.encomenda_ao_zerar then
          raise exception 'Só temos % de % (%) a pronta-entrega. Para mais unidades, faça um pedido por encomenda separado.', v_fs, prod.nome, v_sabor;
        end if;
        raise exception 'Estoque insuficiente de % (%): restam %.', prod.nome, v_sabor, v_fs;
      end if;
      update produtos set estoque_sabores = jsonb_set(estoque_sabores, array[v_sabor], to_jsonb(v_fs - v_unid)),
                          estoque = greatest(estoque - v_unid, 0)
       where id = prod.id;
    elsif v_tipo_it = 'pronta' then
      if prod.estoque < v_unid then
        if prod.encomenda_ao_zerar then
          raise exception 'Só temos % de % a pronta-entrega. Para mais unidades, faça um pedido por encomenda separado.', prod.estoque, prod.nome;
        end if;
        raise exception 'Estoque insuficiente de % (restam %).', prod.nome, prod.estoque;
      end if;
      update produtos set estoque = estoque - v_unid where id = prod.id;
    else
      v_unid := 0;
    end if;

    v_sub := v_sub + v_preco * v_qtd;
    linhas := linhas || jsonb_build_object('produto_id', prod.id, 'nome', v_nome_it, 'detalhe', v_det,
                                           'qtd', v_qtd, 'preco', v_preco, 'unid', v_unid,
                                           'sabor', case when v_temfs and v_tipo_it = 'pronta' then v_sabor end);
  end loop;

  -- data e horário (depende do tipo)
  if v_data > hoje + 90 then raise exception 'Escolha uma data mais próxima.'; end if;
  if exists (select 1 from fechamentos where data = v_data) then raise exception 'A loja estará fechada nessa data.'; end if;
  dia := cfg.horarios -> extract(dow from v_data)::int;
  if coalesce((dia->>'aberto')::boolean, false) is not true then raise exception 'A loja não abre nesse dia da semana.'; end if;

  if v_tipo = 'pronta' then
    if dia->>'de' > pr_de then pr_de := dia->>'de'; end if;   -- loja abre depois das 08:30 (ex.: segunda)
    if v_data < hoje then raise exception 'Escolha uma data a partir de hoje.'; end if;
    if v_data = hoje and to_char(agora, 'HH24:MI') >= pr_ate then
      raise exception 'A pronta-entrega de hoje vai até as 18:30. Escolha outro dia.';
    end if;
    if v_hor is not null and (v_hor < pr_de or v_hor > pr_ate) then
      raise exception 'Pronta-entrega: escolha um horário das % às 18:30.', pr_de;
    end if;
  else
    if v_data < hoje + cfg.antecedencia_dias then
      raise exception 'Encomendas precisam de % dia(s) de antecedência.', cfg.antecedencia_dias;
    end if;
    if v_hor is not null and (v_hor < dia->>'de' or v_hor > dia->>'ate') then
      raise exception 'Nesse dia atendemos das % às %.', dia->>'de', dia->>'ate';
    end if;
  end if;

  insert into pedidos (cliente_nome, cliente_whatsapp, modo, endereco, bairro, referencia, taxa,
                       data_desejada, horario, pagamento, troco, observacoes, subtotal, total, tipo)
  values (v_nome, v_wa, v_modo,
          case when v_modo = 'entrega' then left(trim(p->>'endereco'), 150) end,
          v_bairro,
          case when v_modo = 'entrega' then nullif(left(trim(coalesce(p->>'referencia','')), 100), '') end,
          case when v_modo = 'entrega' then v_taxa else 0 end,
          v_data, v_hor, v_pag,
          case when v_pag = 'Dinheiro' then nullif(left(trim(coalesce(p->>'troco','')), 30), '') end,
          nullif(left(trim(coalesce(p->>'obs','')), 500), ''),
          v_sub, v_sub + coalesce(case when v_modo = 'entrega' then v_taxa end, 0),
          v_tipo)
  returning * into v_ped;

  insert into pedido_itens (pedido_id, produto_id, nome, detalhe, qtd, preco_unit, unidades_estoque, sabor_estoque)
  select v_ped.id, (l->>'produto_id')::uuid, l->>'nome', l->>'detalhe', (l->>'qtd')::int, (l->>'preco')::numeric, (l->>'unid')::int, l->>'sabor'
    from jsonb_array_elements(linhas) l;

  return jsonb_build_object('numero', v_ped.numero, 'subtotal', v_ped.subtotal,
                            'taxa', v_ped.taxa, 'total', v_ped.total, 'bairro', v_ped.bairro, 'tipo', v_tipo);
end $function$;

select 'ok' as pronta_entrega_0830;
