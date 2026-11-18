-- =====================================================================================
-- Perfis de administrador: MASTER × ADM                                  (18/11/2026)
-- Correr UMA vez, inteiro, no Supabase → SQL Editor. Pode voltar a correr-se sem
-- estragar nada (tudo é "if not exists" / "create or replace").
--
--   master (danielm.eifler@gmail.com): tudo, como hoje.
--   adm    (qualquer outro email em `admins`):
--      • vê tudo;
--      • LANÇA dados (contagens, checklists, produção, IVA, fechamentos, menus…);
--      • CORRIGE lançamentos — cada correção fica em `historico_alteracoes` (antes/depois);
--      • aprova contagens (só a quantidade em estoque dos produtos pode mudar);
--      • NÃO apaga nada e NÃO mexe na estrutura (produtos, fornecedores, áreas, grupos,
--        receitas, itens de checklist/produção, custos fixos, utilizadores e admins).
--   Cada tentativa bloqueada é gravada em `alertas_seguranca` e avisada no Telegram.
--
-- Colaboradores (não-admins) não são afetados: continuam governados pelas regras RLS.
-- O bloqueio é feito na própria base de dados, por isso vale para tudo: a app, scripts,
-- chamadas diretas à API ou um assistente de IA a usar o login de um adm.
--
-- IMPORTANTE: tabelas criadas DEPOIS disto (ex.: módulo financeiro) só ficam protegidas
-- se voltar a correr o bloco "6. Ligar a guarda a todas as tabelas" no fim.
-- =====================================================================================

create extension if not exists pg_net;

-- 1. Nível de cada administrador -----------------------------------------------------
alter table public.admins add column if not exists nivel text not null default 'admin';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'admins_nivel_check') then
    alter table public.admins add constraint admins_nivel_check check (nivel in ('master', 'admin'));
  end if;
end $$;
update public.admins set nivel = 'master' where lower(email) = 'danielm.eifler@gmail.com';

-- Quem está a fazer o pedido: 'master' | 'admin' | 'colaborador' | 'anonimo' | 'sistema'
-- ('sistema' = SQL Editor / chave de serviço: nunca é bloqueado)
create or replace function public.nivel_atual() returns text
language sql stable security definer set search_path = public as $$
  select case
    when coalesce(auth.jwt() ->> 'email', '') = '' then
      case when coalesce(auth.jwt() ->> 'role', '') in ('anon', 'authenticated') then 'anonimo' else 'sistema' end
    else coalesce((select a.nivel from public.admins a
                   where lower(a.email) = lower(auth.jwt() ->> 'email') limit 1), 'colaborador')
  end
$$;
grant execute on function public.nivel_atual() to authenticated;

-- 2. Registos (só o master lê) ---------------------------------------------------------
create table if not exists public.alertas_seguranca (
  id         bigserial primary key,
  criado_em  timestamptz not null default now(),
  email      text,
  tabela     text,
  operacao   text,          -- 'apagar' | 'criar' | 'alterar'
  registo    jsonb,         -- como estava
  tentativa  jsonb,         -- o que se tentou gravar
  visto      boolean not null default false
);
alter table public.alertas_seguranca enable row level security;
drop policy if exists "master le alertas" on public.alertas_seguranca;
create policy "master le alertas" on public.alertas_seguranca for select using (public.nivel_atual() = 'master');
drop policy if exists "master marca alertas" on public.alertas_seguranca;
create policy "master marca alertas" on public.alertas_seguranca for update using (public.nivel_atual() = 'master');
grant select, update on public.alertas_seguranca to authenticated;

create table if not exists public.historico_alteracoes (
  id         bigserial primary key,
  criado_em  timestamptz not null default now(),
  email      text,
  tabela     text,
  registo_id text,
  antes      jsonb,
  depois     jsonb
);
alter table public.historico_alteracoes enable row level security;
drop policy if exists "master le historico" on public.historico_alteracoes;
create policy "master le historico" on public.historico_alteracoes for select using (public.nivel_atual() = 'master');
grant select on public.historico_alteracoes to authenticated;

-- Segredos (token do Telegram). Sem nenhuma regra RLS = ninguém lê pela app/API.
create table if not exists public.config_privada (chave text primary key, valor text);
alter table public.config_privada enable row level security;
revoke all on public.config_privada from anon, authenticated;

-- 3. Aviso no Telegram -------------------------------------------------------------------
create or replace function public.avisar_telegram(msg text) returns void
language plpgsql security definer set search_path = public as $$
declare tok text; chat text;
begin
  select valor into tok  from public.config_privada where chave = 'telegram_token';
  select valor into chat from public.config_privada where chave = 'telegram_chat_id';
  if tok is null or chat is null then return; end if;
  perform net.http_post(
    url  := 'https://api.telegram.org/bot' || tok || '/sendMessage',
    body := jsonb_build_object('chat_id', chat, 'text', msg)
  );
exception when others then null;   -- um aviso falhado nunca pode estragar a operação
end $$;
revoke execute on function public.avisar_telegram(text) from public, anon, authenticated;

-- 4. Registar uma tentativa (com travão: no máx. 1 mensagem por pessoa/tabela/ação a cada 2 min)
create or replace function public.registar_tentativa(quem text, tab text, op text, antes jsonb, depois jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare recente boolean; ref jsonb := coalesce(antes, depois); nome text;
begin
  select exists(select 1 from public.alertas_seguranca
                where email = quem and tabela = tab and operacao = op
                  and criado_em > now() - interval '2 minutes') into recente;
  insert into public.alertas_seguranca(email, tabela, operacao, registo, tentativa)
  values (quem, tab, op, antes, depois);
  if not recente then
    nome := coalesce(ref ->> 'nome', ref ->> 'texto', ref ->> 'chave', ref ->> 'email', ref ->> 'id');
    perform public.avisar_telegram(
      '🔒 Il Fortunato: ' || coalesce(quem, '?') || ' tentou ' || op || ' em «' || tab || '»'
      || coalesce(' (' || nome || ')', '') || '. Bloqueado — nada foi alterado.');
  end if;
end $$;
revoke execute on function public.registar_tentativa(text, text, text, jsonb, jsonb) from public, anon, authenticated;

-- 5. A guarda (corre antes de cada gravação em cada tabela) ------------------------------
-- TG_ARGV[0] = 'estrutura' | 'lancamento';  TG_ARGV[1] = colunas que o adm pode mudar
-- numa tabela de estrutura (separadas por vírgula; ex.: 'qtd_atual' em produtos).
-- Bloquear = devolver NULL: a operação é ignorada sem erro e a tentativa fica registada.
create or replace function public.guarda_perfis() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  tipo   text   := tg_argv[0];
  livres text[] := coalesce(string_to_array(nullif(tg_argv[1], ''), ','), '{}');
  quem   text;
  existe boolean := false;
  a jsonb; d jsonb; k text;
begin
  if public.nivel_atual() <> 'admin' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  quem := auth.jwt() ->> 'email';

  if tg_op = 'DELETE' then
    a := to_jsonb(old);
    -- exceção: o "cadeado" vazio de uma contagem que se abriu e se abandonou sem enviar
    if tg_table_name = 'contagens' and a ->> 'status' = 'em_andamento'
       and coalesce(case when jsonb_typeof(a -> 'itens') = 'array' then jsonb_array_length(a -> 'itens') end, 0) = 0 then
      return old;
    end if;
    perform public.registar_tentativa(quem, tg_table_name, 'apagar', a, null);
    return null;
  end if;

  if tg_op = 'INSERT' then
    if tipo <> 'estrutura' then return new; end if;
    d := to_jsonb(new);
    if d ? 'id' then
      execute format('select exists(select 1 from %I.%I where id = $1)', tg_table_schema, tg_table_name)
        into existe using new.id;
    end if;
    if existe then return new; end if;   -- "upsert" de algo que já existe: decide a guarda do UPDATE
    perform public.registar_tentativa(quem, tg_table_name, 'criar', null, d);
    return null;
  end if;

  -- UPDATE
  a := to_jsonb(old); d := to_jsonb(new);
  if a = d then return new; end if;
  if tipo = 'estrutura' then
    foreach k in array livres loop a := a - k; d := d - k; end loop;
    if a <> d then
      perform public.registar_tentativa(quem, tg_table_name, 'alterar', to_jsonb(old), to_jsonb(new));
      return null;
    end if;
    return new;
  end if;
  -- lançamento corrigido: permitido, com registo de antes/depois
  insert into public.historico_alteracoes(email, tabela, registo_id, antes, depois)
  values (quem, tg_table_name, coalesce(a ->> 'id', a ->> 'chave', a ->> 'email'), a, d);
  return new;
end $$;

-- 6. Ligar a guarda a todas as tabelas -------------------------------------------------
-- Estrutura: lista abaixo. Todas as outras (as que existem hoje e as que vierem a existir,
-- se se voltar a correr este bloco) são tratadas como lançamentos.
do $$
declare
  t record; tipo text; livres text;
  estrutura text[] := array['admins', 'colaboradores', 'areas', 'fornecedores', 'grupos', 'produtos',
                            'receitas', 'receita_itens', 'checklist_itens', 'producao_itens',
                            'custos_fixos', 'impasto_config'];
begin
  -- escala_*: da app fluxos-e-escalas (mesma base), que grava apagando e regravando; fica de
  -- fora até essa app ser adaptada aos perfis, senão o adm deixava de conseguir guardar escalas.
  for t in select tablename from pg_tables
           where schemaname = 'public'
             and tablename not in ('alertas_seguranca', 'historico_alteracoes', 'config_privada')
             and tablename not like 'escala\_%' loop
    tipo   := case when t.tablename = any(estrutura) then 'estrutura' else 'lancamento' end;
    livres := case when t.tablename = 'produtos' then 'qtd_atual' else '' end;
    execute format('drop trigger if exists guarda_perfis on public.%I', t.tablename);
    execute format('create trigger guarda_perfis before insert or update or delete on public.%I '
                   'for each row execute function public.guarda_perfis(%L, %L)', t.tablename, tipo, livres);
  end loop;
end $$;

-- Conferir: deve listar o seu email como master e os outros admins como admin.
select email, nivel from public.admins order by nivel desc, email;
