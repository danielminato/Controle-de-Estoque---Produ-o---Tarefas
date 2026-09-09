-- Il Fortunato — estrutura da base de dados no Supabase
-- Cola este script inteiro no SQL Editor do Supabase e clica em "Run"

create table if not exists fornecedores (
  id text primary key,
  nome text not null,
  dia_entrega text
);

create table if not exists areas (
  id text primary key,
  nome text not null
);

create table if not exists produtos (
  id text primary key,
  codigo text,
  nome text not null,
  categoria text,
  tipo text default 'materia_prima',
  area_ids jsonb default '[]'::jsonb,
  precos jsonb default '[]'::jsonb,
  qtd_minima numeric default 0,
  qtd_atual numeric default 0,
  fornecedor_escolhido_id text
);

-- Como só tu (e a pessoa que te ajuda) vão usar isto, desativamos a
-- verificação de utilizador por linha (RLS) para simplificar o acesso.
-- Isto significa que quem tiver o link do app + a chave "anon" consegue
-- ler/escrever os dados — aceitável para uma ferramenta interna pequena,
-- mas não partilhes a chave publicamente.
alter table fornecedores disable row level security;
alter table areas disable row level security;
alter table produtos disable row level security;
-- Il Fortunato — adição: grupos de compra + contagens de colaboradores
-- Cola no SQL Editor do Supabase e clica em "Run"

create table if not exists grupos (
  id text primary key,
  nome text not null,
  fornecedor_ids jsonb default '[]'::jsonb
);

create table if not exists contagens (
  id text primary key,
  grupo_id text not null,
  grupo_nome text,
  usuario_email text,
  criado_em timestamptz default now(),
  itens jsonb default '[]'::jsonb,
  status text default 'pendente'
);

alter table grupos disable row level security;
alter table contagens disable row level security;

grant all on grupos to anon, authenticated;
grant all on contagens to anon, authenticated;
-- Il Fortunato — Nível 2: segurança real por utilizador (RLS)
-- Cola no SQL Editor do Supabase e clica em "Run"

-- 1) Tabela de administradores (quem tem acesso total ao app de gestão)
create table if not exists admins (
  email text primary key
);

-- ⚠️ IMPORTANTE: troca pelos teus emails reais antes de correr este script
insert into admins (email) values
  ('danielm.eifler@gmail.com'),
  ('strajanofernanda@gmail.com')
on conflict do nothing;

alter table admins enable row level security;
create policy "utilizadores autenticados veem a lista de admins" on admins
  for select using (auth.role() = 'authenticated');

-- 2) Ativar segurança nas tabelas principais
alter table fornecedores enable row level security;
alter table areas enable row level security;
alter table produtos enable row level security;
alter table grupos enable row level security;
alter table contagens enable row level security;

-- 3) Leitura: qualquer pessoa com login válido (dono, sócia ou colaborador)
create policy "ler fornecedores" on fornecedores for select using (auth.role() = 'authenticated');
create policy "ler areas" on areas for select using (auth.role() = 'authenticated');
create policy "ler produtos" on produtos for select using (auth.role() = 'authenticated');
create policy "ler grupos" on grupos for select using (auth.role() = 'authenticated');
create policy "ler contagens" on contagens for select using (auth.role() = 'authenticated');

-- 4) Escrita nas tabelas mestras: só administradores (dono + sócia)
create policy "admin cria fornecedores" on fornecedores for insert with check (auth.jwt() ->> 'email' in (select email from admins));
create policy "admin edita fornecedores" on fornecedores for update using (auth.jwt() ->> 'email' in (select email from admins));
create policy "admin apaga fornecedores" on fornecedores for delete using (auth.jwt() ->> 'email' in (select email from admins));

create policy "admin cria areas" on areas for insert with check (auth.jwt() ->> 'email' in (select email from admins));
create policy "admin edita areas" on areas for update using (auth.jwt() ->> 'email' in (select email from admins));
create policy "admin apaga areas" on areas for delete using (auth.jwt() ->> 'email' in (select email from admins));

create policy "admin cria produtos" on produtos for insert with check (auth.jwt() ->> 'email' in (select email from admins));
create policy "admin edita produtos" on produtos for update using (auth.jwt() ->> 'email' in (select email from admins));
create policy "admin apaga produtos" on produtos for delete using (auth.jwt() ->> 'email' in (select email from admins));

create policy "admin cria grupos" on grupos for insert with check (auth.jwt() ->> 'email' in (select email from admins));
create policy "admin edita grupos" on grupos for update using (auth.jwt() ->> 'email' in (select email from admins));
create policy "admin apaga grupos" on grupos for delete using (auth.jwt() ->> 'email' in (select email from admins));

-- 5) Contagens: qualquer colaborador autenticado pode enviar a sua contagem,
--    mas só administradores podem corrigir ou apagar (é a tua proteção pedida)
create policy "colaborador envia contagem" on contagens for insert with check (auth.role() = 'authenticated');
create policy "admin corrige contagem" on contagens for update using (auth.jwt() ->> 'email' in (select email from admins));
create policy "admin apaga contagem" on contagens for delete using (auth.jwt() ->> 'email' in (select email from admins));
-- Il Fortunato — permitir que administradores adicionem/removam outros administradores
-- Cola no SQL Editor do Supabase e clica em "Run"

create policy "admin adiciona administradores" on admins
  for insert with check (auth.jwt() ->> 'email' in (select email from admins));

create policy "admin remove administradores" on admins
  for delete using (auth.jwt() ->> 'email' in (select email from admins));
-- Il Fortunato — colaborador pode corrigir a própria contagem, só enquanto pendente
-- Cola no SQL Editor do Supabase e clica em "Run"

create policy "colaborador corrige a propria contagem pendente" on contagens
  for update
  using (auth.jwt() ->> 'email' = usuario_email and status = 'pendente')
  with check (auth.jwt() ->> 'email' = usuario_email and status = 'pendente');
-- Il Fortunato — registo dos utilizadores criados pelo app (visibilidade para o dono)
create table if not exists colaboradores (
  email text primary key,
  criado_em timestamptz default now()
);

alter table colaboradores enable row level security;

create policy "autenticados veem colaboradores" on colaboradores
  for select using (auth.role() = 'authenticated');

create policy "admin adiciona colaboradores" on colaboradores
  for insert with check (auth.jwt() ->> 'email' in (select email from admins));

create policy "admin remove colaboradores" on colaboradores
  for delete using (auth.jwt() ->> 'email' in (select email from admins));
-- Il Fortunato — adicionar "dia de contagem" aos fornecedores
alter table fornecedores add column if not exists dia_contagem text;
alter table grupos add column if not exists dias_contagem text;
-- Il Fortunato — Checklists de abertura/fecho/manutenção
create table if not exists checklist_itens (
  id text primary key,
  area text not null,
  tipo text not null,
  texto text not null,
  ordem integer default 0
);

create table if not exists checklist_execucoes (
  id text primary key,
  area text not null,
  tipo text not null,
  data date not null,
  usuario_email text,
  criado_em timestamptz default now(),
  itens jsonb default '[]'::jsonb
);

alter table checklist_itens enable row level security;
alter table checklist_execucoes enable row level security;

create policy "ler checklist_itens" on checklist_itens for select using (auth.role() = 'authenticated');
create policy "admin cria checklist_itens" on checklist_itens for insert with check (auth.jwt() ->> 'email' in (select email from admins));
create policy "admin edita checklist_itens" on checklist_itens for update using (auth.jwt() ->> 'email' in (select email from admins));
create policy "admin apaga checklist_itens" on checklist_itens for delete using (auth.jwt() ->> 'email' in (select email from admins));

create policy "ler checklist_execucoes" on checklist_execucoes for select using (auth.role() = 'authenticated');
create policy "colaborador insere checklist_execucoes" on checklist_execucoes for insert with check (auth.role() = 'authenticated');
create policy "admin apaga checklist_execucoes" on checklist_execucoes for delete using (auth.jwt() ->> 'email' in (select email from admins));
-- Il Fortunato — Produção (Insumos e Impasto)
create table if not exists producao_itens (
  id text primary key,
  categoria text not null,        -- 'insumos' | 'impasto'
  area text not null,
  nome text not null,
  ordem integer default 0,
  quantidades jsonb default '{}'::jsonb  -- {"Segunda": 2, "Terça": 1, ...}
);

create table if not exists producao_execucoes (
  id text primary key,
  item_id text,
  categoria text not null,
  area text not null,
  nome text,
  quantidade numeric,
  data date not null,
  usuario_email text,
  criado_em timestamptz default now()
);

alter table producao_itens enable row level security;
alter table producao_execucoes enable row level security;

create policy "ler producao_itens" on producao_itens for select using (auth.role() = 'authenticated');
create policy "admin cria producao_itens" on producao_itens for insert with check (auth.jwt() ->> 'email' in (select email from admins));
create policy "admin edita producao_itens" on producao_itens for update using (auth.jwt() ->> 'email' in (select email from admins));
create policy "admin apaga producao_itens" on producao_itens for delete using (auth.jwt() ->> 'email' in (select email from admins));

create policy "ler producao_execucoes" on producao_execucoes for select using (auth.role() = 'authenticated');
create policy "colaborador insere producao_execucoes" on producao_execucoes for insert with check (auth.role() = 'authenticated');
create policy "admin apaga producao_execucoes" on producao_execucoes for delete using (auth.jwt() ->> 'email' in (select email from admins));
-- Il Fortunato — permitir dividir a contagem de um grupo por área
alter table contagens add column if not exists area text;
alter table produtos add column if not exists embalagem_qtd numeric;
alter table produtos add column if not exists embalagem_unidade text;
alter table produtos add column if not exists embalagem_confirmada boolean default false;
alter table produtos add column if not exists nota text;
-- Densidade (para converter ml em g com precisão nos líquidos)
alter table produtos add column if not exists densidade numeric default 1;

-- Receitas / Fichas técnicas (semi-preparados e pratos finais)
create table if not exists receitas (
  id text primary key,
  produto_id text not null,           -- o produto resultante (ex: "Molho de Tomate" ou "Pizza Margherita")
  rendimento_g numeric default 0,     -- quanto a receita rende, em gramas (ex: 3000 para um molho que rende 3kg)
  preco_venda numeric,                -- só relevante para pratos finais, para calcular CMV%
  observacoes text
);

create table if not exists receita_itens (
  id text primary key,
  receita_id text not null,
  ingrediente_produto_id text not null,  -- outro produto: matéria-prima OU outro semi-preparado com a sua própria receita
  quantidade_g numeric not null,          -- sempre em gramas
  ordem integer default 0
);

alter table receitas enable row level security;
alter table receita_itens enable row level security;

create policy "ler receitas" on receitas for select using (auth.role() = 'authenticated');
create policy "admin cria receitas" on receitas for insert with check (auth.jwt() ->> 'email' in (select email from admins));
create policy "admin edita receitas" on receitas for update using (auth.jwt() ->> 'email' in (select email from admins));
create policy "admin apaga receitas" on receitas for delete using (auth.jwt() ->> 'email' in (select email from admins));

create policy "ler receita_itens" on receita_itens for select using (auth.role() = 'authenticated');
create policy "admin cria receita_itens" on receita_itens for insert with check (auth.jwt() ->> 'email' in (select email from admins));
create policy "admin edita receita_itens" on receita_itens for update using (auth.jwt() ->> 'email' in (select email from admins));
create policy "admin apaga receita_itens" on receita_itens for delete using (auth.jwt() ->> 'email' in (select email from admins));

-- CORREÇÃO (aplicada em Set/2026): a política antiga só deixava o colaborador
-- corrigir contagens já 'pendente' — mas o sinal "em_andamento" (lock ao vivo)
-- nasce com outro status, por isso a conversão final falhava silenciosamente.
drop policy if exists "colaborador corrige a propria contagem pendente" on contagens;

create policy "colaborador atualiza a propria contagem" on contagens
  for update
  using (auth.jwt() ->> 'email' = usuario_email and status in ('pendente', 'em_andamento'))
  with check (auth.jwt() ->> 'email' = usuario_email and status = 'pendente');

delete from contagens where status = 'em_andamento';
