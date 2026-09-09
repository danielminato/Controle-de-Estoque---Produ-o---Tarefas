# Il Fortunato — Sistema de Gestão (Estoque, Checklists, Produção, Receitas)

## ✅ Bug de contagens resolvido (Set/2026)
Colaboradores enviavam contagens que nunca apareciam do lado do admin, mesmo com o ecrã
mostrando "sucesso". Causa raiz: a coluna `area` da tabela `contagens` nunca tinha sido
efetivamente criada na base de dados real (a migration ficou por correr), por isso todo
insert/update que incluía esse campo falhava — e o código engolia esse erro em silêncio
(`catch(e){}` vazio em `criarLockEmAndamento`), fazendo o ecrã do colaborador mostrar sucesso
mesmo sem nada ter sido gravado.

Corrigido em duas frentes:
1. `alter table contagens add column if not exists area text;` (já devia estar aplicado)
2. O código deixou de engolir erros: `criarLockEmAndamento` agora lança erro se o pedido
   falhar, e `entrarNaContagemDeArea`/`entrarNaContagemMultiplasAreas` mostram um aviso claro
   ao colaborador e voltam ao ecrã de grupos, em vez de seguir em frente como se nada tivesse
   acontecido.

**Lição para o futuro**: sempre que uma tabela ganhar uma coluna nova via migration, testar
uma escrita real (insert/update) contra a base de dados de produção antes de dar como
resolvido — testar só localmente/no código não apanha isto, porque o erro só existe do lado
do servidor.

## O que é
App web único (ficheiro `index.html`, HTML/CSS/JS puro, sem build) para o restaurante Il Fortunato
(Porto). Substitui uma planilha Excel frágil. Liga-se a uma base de dados Supabase real.

## Arquitetura
- **Frontend**: `index.html` — ficheiro único, sem framework, sem build. CDN: Google Fonts
  (Playfair Display + Inter), xlsx-js-style (exportar/importar Excel).
- **Backend**: Supabase (Postgres + Auth), via REST (`fetch` direto, sem SDK), com a chave
  "publishable" embutida no `index.html` (`SUPABASE_URL` / `SUPABASE_KEY` no topo do `<script>`).
- **Hospedagem**: migrámos do Netlify (limite de créditos no plano grátis) para o
  **GitHub Pages** (`danielminato.github.io/Controle-de-Estoque---Produ-o---Tarefas/`),
  sem esse problema de créditos. Publicar = "Add file → Upload files" no repositório GitHub,
  substituindo o `index.html`, com "Commit changes".
- **Fluxo de trabalho**: testar sempre localmente primeiro (abrir o `index.html` direto no
  browser — já liga à base de dados real) e só publicar quando houver várias alterações prontas.
- **Autenticação**: Supabase Auth (email+password). Um único `index.html` serve dois perfis:
  - **Administrador**: email na tabela `admins` → gestão completa.
  - **Colaborador**: qualquer outro utilizador autenticado → só modo operacional
    (Ciao [nome]: Contar estoque / Fazer checklist / Produção).
  - Password inicial `123456` força troca obrigatória no primeiro login.
  - **Reset de password manual** (sem email real dos colaboradores, não dá para usar o
    "esqueci a senha" padrão): correr no SQL Editor —
    `update auth.users set encrypted_password = crypt('123456', gen_salt('bf')) where email = '...';`

## Modelo de dados (Supabase / Postgres)
Ver `schema_completo.sql`. Tabelas principais:

**Estoque**
- `fornecedores` (id, nome, dias_entrega, dias_contagem — csv de strings)
- `areas` (id, nome)
- `produtos` (id, codigo, nome, categoria, tipo ['materia_prima'|'semi_preparado'|'prato_final'],
  area_ids jsonb, precos jsonb [{fornecedorId, preco}], qtd_minima, qtd_atual,
  fornecedor_escolhido_id, nota, embalagem_qtd, embalagem_unidade ['g'|'kg'|'ml'|'l'|'unidade' —
  guardado exatamente como escolhido, NÃO pré-convertido; a normalização para g/ml é feita
  sempre no cálculo, via `embalagemBase(p)`], embalagem_confirmada, densidade)
- `grupos` (id, nome, fornecedor_ids jsonb, dias_contagem)
- `contagens` (id, grupo_id, grupo_nome, area, usuario_email, criado_em,
  itens jsonb [{produto_id, quantidade, observacao?}], status ['em_andamento'|'pendente'|'finalizada'])
  - Cada submissão cobre **um grupo + uma área específica**. Bloqueio "ao vivo" por
    (grupo_id + area): assim que um colaborador entra a contar, cria-se um registo
    `em_andamento` (vazio) que bloqueia outros; ao enviar, devia virar `pendente` com os
    itens — **é exatamente este passo que está com bug, ver topo do documento**.
  - `criarLockEmAndamento(g, area)` cria o sinal; `liberarLocksNovos()` apaga sinais
    abandonados (ao clicar "voltar"/"sair" sem enviar); expira sozinho ao fim de 45 min
    (`LOCK_EXPIRACAO_MIN`) se a pessoa simplesmente fechar o browser.
  - `bloqueioDaArea(grupoId, area)` decide quem está a bloquear uma área (pendente ou
    em_andamento, ignorando locks expirados).

**Utilizadores**
- `admins` (email), `colaboradores` (email, criado_em — registo de quem foi criado pela app)

**Checklists** (abertura/fecho/manutenção/troca de turno)
- `checklist_itens` (area, tipo ['abertura'|'fecho'|'manutencao'|'entrada_turno'|'saida_turno'], texto, ordem)
- `checklist_execucoes` (area, tipo, data, usuario_email, criado_em, itens)
  - Bloqueio por (area+tipo+data). "Troca de turno" pode acontecer várias vezes por dia
    (lista separada no histórico, não a matriz fixa).

**Produção**
- `producao_itens` (categoria ['insumos'|'impasto'], area, nome, ordem, quantidades jsonb
  por dia da semana), `producao_execucoes` — sem bloqueio por área, cada item desaparece
  para todos assim que alguém o marca. Categoria "impasto" ainda vazia (dono vai dar as
  diretrizes/receita).

**Receitas / CMV** (módulo mais recente)
- `receitas` (produto_id, rendimento_g, preco_venda, observacoes)
- `receita_itens` (receita_id, ingrediente_produto_id, quantidade_g, ordem)
- Custo calculado recursivamente em `custoPorGramaProduto()` — um ingrediente pode ser
  ele próprio outro semi-preparado com a sua própria receita (ex: pizza usa molho, molho
  tem ficha técnica própria). `fecharCircularidade()` impede loops (A depende de B que
  depende de A).
- Receitas sempre em **gramas** (mesmo para líquidos) — `densidade` (g/ml) no produto
  converte ml→g quando necessário (`precoPorGrama()`). Água/vinho/Marsala = densidade 1
  (default); azeite ≈0.92; mel ≈1.42.
- Pratos finais têm `preco_venda` → CMV% calculado automaticamente (vermelho se >33%).

## Padrões de código a manter
- Sem build step — ficheiro único aberto direto no browser tem de continuar a funcionar.
- `window.confirm`/`window.alert` nativos **não funcionam** no ambiente de teste do Claude.ai
  — usar sempre `showConfirm()`/`showAlert()` customizados (Promise-based).
- Padrão Supabase: `sbGet(table)`, `sbInsertRow(table, row)`, `sbUpdateRow(table, id, patch)`,
  `sbDeleteRow(table, id)`, `sbReplaceAll(table, rows)` (apaga tudo e reinsere, para tabelas
  pequenas: fornecedores/áreas/produtos/grupos). `sbHeadersFn()` usa o token da sessão
  (`sbAccessToken`) quando existe, senão a chave pública.
- Padrão de ecrãs operacionais: `<div class="oper-screen" id="oper-screen-...">`,
  trocados com `mostrarOperScreen(id)`.
- Dados semente embutidos em `<script type="application/json">`: `#seedData` (147 produtos
  reais) e `#checklistSeedData` (110 tarefas de checklist).
- Embalagem: **nunca pré-converter** kg→g ou l→ml no momento de gravar — guardar exatamente
  o que a pessoa escolheu, e normalizar sempre no cálculo via `embalagemBase(p)`. (Isto foi
  uma correção de bug: converter cedo demais causava valores errados quando os dois campos
  — quantidade e unidade — eram editados em momentos/eventos separados.)

## Pendente / próximos passos
1. **Resolver o bug de contagens não aparecerem** (topo deste documento) — prioridade máxima,
   está a impedir o uso real da funcionalidade principal (contagem de estoque).
2. **Impasto**: `producao_itens` categoria `impasto` vazia, aguarda receita do dono.
3. Continuar a testar/ajustar o módulo de Receitas/CMV (só começou a ser usado agora).
4. Publicar no GitHub Pages sempre que houver acumulado suficiente de mudanças testadas
   localmente.

## Ficheiros deste pacote
- `index.html` — a app completa e atual (com o fix de RLS já aplicado no código, mas o
  bug pode persistir — ver topo do documento)
- `schema_completo.sql` — todas as migrations SQL, na ordem, incluindo o fix mais recente
- Este ficheiro (`CONTEXTO_PROJETO.md`)
