-- Teste dos perfis master × adm. NÃO altera nada: o bloco termina SEMPRE com um "erro"
-- de propósito, que desfaz tudo o que fez (incluindo os alertas de teste — nenhuma
-- mensagem de Telegram sai). O resultado do teste aparece nesse "erro".
-- Correr no SQL Editor DEPOIS da migração. Simula pedidos feitos com o login de um adm.

do $$
declare
  quem text := (select email from public.admins where nivel = 'admin' limit 1);
  n_forn int; n_nome int; n_qtd int; n_cont int; n_alertas int; v_nivel text;
  linha text := E'\n';
begin
  if quem is null then raise exception 'Não há nenhum adm (não master) em admins para simular.'; end if;

  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'email', quem)::text, true);
  execute 'set local role authenticated';

  v_nivel := public.nivel_atual();
  with x as (delete from public.fornecedores where id = (select id from public.fornecedores limit 1) returning 1)
    select count(*) into n_forn from x;
  with x as (update public.produtos set nome = nome || ' (teste)' where id = (select id from public.produtos limit 1) returning 1)
    select count(*) into n_nome from x;
  with x as (update public.produtos set qtd_atual = coalesce(qtd_atual, 0) + 1 where id = (select id from public.produtos limit 1) returning 1)
    select count(*) into n_qtd from x;
  with x as (delete from public.contagens where id = (select id from public.contagens where status <> 'em_andamento' limit 1) returning 1)
    select count(*) into n_cont from x;

  execute 'reset role';
  select count(*) into n_alertas from public.alertas_seguranca where criado_em >= now();

  raise exception '%', 'RESULTADO DO TESTE (simulando ' || quem || ')' || linha
    || (case when v_nivel = 'admin' then '✅' else '❌' end) || ' nível: ' || v_nivel || ' (esperado admin)' || linha
    || (case when n_forn = 0 then '✅' else '❌' end) || ' apagar fornecedor: ' || n_forn || ' linha(s) (esperado 0)' || linha
    || (case when n_nome = 0 then '✅' else '❌' end) || ' mudar nome de produto: ' || n_nome || ' (esperado 0)' || linha
    || (case when n_qtd  = 1 then '✅' else '❌' end) || ' mudar quantidade em estoque: ' || n_qtd || ' (esperado 1)' || linha
    || (case when n_cont = 0 then '✅' else '❌' end) || ' apagar contagem enviada: ' || n_cont || ' (esperado 0)' || linha
    || (case when n_alertas = 3 then '✅' else '❌' end) || ' alertas registados: ' || n_alertas || ' (esperado 3)' || linha
    || '(tudo desfeito — nada ficou gravado)';
end $$;
