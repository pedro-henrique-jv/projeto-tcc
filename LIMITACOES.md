## Versão usada no TCC e limitações conhecidas

Este repositório está preservado como foi usado nas rodadas do benchmark descrito no TCC "Um Benchmark para Avaliação de Desempenho de LLMs em Tarefas Text-to-SQL sobre Dados do Censo da Educação Superior" (UFSM, 2026). Para reproduzir os resultados, use a tag `tcc-2026` deste repositório e a imagem `jovanowichs/censo-educacao-superior:tcc-2026`. O benchmark (pares, protocolo e runner) está em: https://github.com/pedro-henrique-jv/querylab-2/tree/tcc-2026.

Os pontos abaixo foram identificados durante o trabalho e **não foram corrigidos**, para manter o banco idêntico ao usado nas rodadas. Ficam registrados para versões futuras.

### Comentários do schema (`sql/01_schema.sql`)
Os comentários do banco foram usados para gerar o schema enviado aos modelos; por isso não foram alterados.
- Regra de soma (`tp_dimensao`, `qt_vg_total`, `qt_inscrito_total`, `qt_ing`, `qt_mat`, `qt_conc`): os comentários no banco e neste arquivo trazem a regra antiga (`IN (1,3)` e `IN (1,2)`). A regra correta é `TP_DIMENSAO IN (1,2,3)` para vagas e inscritos e `IN (1,2,4)` para ingressantes, matrículas e concluintes. No schema enviado aos modelos, essa regra já foi substituída pela correta (`backend/scripts/introspect-mariadb-schema.ts`, no repositório do benchmark).
- `ies_historico.tp_rede`: diz "ausente em 2010, presente em 2024". O correto: a coluna TP_REDE não existe nos arquivos de IES de 2009 a 2022 (fica nula nesses anos) e existe em 2023 e 2024.
- `cine_area_rotulo`: cita "1 código (de 373)"; hoje são 386 rótulos.
- Cabeçalho: diz "entre 2010 e 2024" (o correto é 2009–2024) e "regra de deduplicação" (não há duplicação; é uma regra de soma: ingressantes, matrículas e concluintes somam as dimensões 1, 2 e 4; vagas e inscritos, as dimensões 1, 2 e 3).
- `curso_estatisticas.co_municipio` e `id`: dizem "nulo para o total Brasil"; o município é nulo nas dimensões 3 e 4.
- Tabela `curso`: diz "Cursos de graduação"; inclui também os sequenciais.
- `curso_historico.co_cine_area_rotulo`: o número "75.985 linhas com classificação CINE" vem de um teste antigo.

### ETL (`etl/etl.py`)
- Comentário do topo desatualizado: a regra de soma descrita (`IN (1,3)` e `IN (1,2)`) não é a usada (ver acima), e "confirmado em 2010 e 2024" deveria ser "TP_DIMENSAO presente nos 16 anos (2009–2024); o fallback para TP_LOC_OFERTA_CURSO nunca é usado".
- **Zeros de 2022:** o arquivo de cursos de 2022 grava 0 (e não vazio) em CO_UF, CO_MUNICIPIO e CO_REGIAO nas linhas sem município (9.603 linhas). O ETL só descarta valores vazios, então foram criados registros inexistentes: UF 0 (sem sigla), região 0 e município 0. Correção futura: tratar 0 como nulo nesses campos e recarregar.
- **CINE de 2020:** no CSV de cursos de 2020 a coluna do rótulo se chama CO_CINE_ROTULO2, e o ETL procura apenas CO_CINE_ROTULO; os 42.233 cursos de 2020 ficaram sem rótulo CINE. Correção futura: aceitar CO_CINE_ROTULO2 e recarregar 2020.

### Usuário somente leitura
O QueryLab acessa o banco com o usuário `querylab_ro`, que tem apenas permissão de `SELECT`. Esse usuário não é criado por nenhum arquivo deste repositório nem pela imagem Docker; foi criado à mão no contêiner, depois de subir a imagem. Para reproduzir:

```bash
docker exec -it censo-db mariadb -uroot -e "
  CREATE USER 'querylab_ro'@'%' IDENTIFIED BY '<SENHA>';
  GRANT SELECT ON censo_educacao_superior.* TO 'querylab_ro'@'%';"
```
