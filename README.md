# Banco de dados do Censo da Educação Superior (INEP) para avaliação de LLMs em Text-to-SQL

Repositório do Trabalho de Conclusão de Curso *Um Benchmark para Avaliação de Desempenho de LLMs em Tarefas Text-to-SQL sobre Dados do Censo da Educação Superior* (Sistemas de Informação, UFSM).

Aqui estão o **schema SQL** e o **script de ETL** que constroem o banco relacional normalizado (MariaDB) usado como base do benchmark, a partir dos microdados do Censo da Educação Superior de 2009 a 2024, divulgados pelo INEP.

## Estrutura

| Pasta / arquivo | Conteúdo |
|---|---|
| `sql/01_schema.sql` | Criação do banco, das tabelas e das tabelas de domínio |
| `etl/etl.py` | Carga dos microdados do INEP no banco |
| `etl/requirements.txt` | Dependências Python do ETL |
| `docker-compose.yml` | Sobe o MariaDB já com o schema aplicado |
| `.env.example` | Modelo das variáveis de ambiente (copie para `.env`) |
| `Template_MDT_UFSM_2026/` | Template LaTeX do documento do TCC |

## Como reproduzir

Pré-requisitos: Docker e Python 3.

**1. Configurar as variáveis de ambiente**

```bash
cp .env.example .env
```

Edite o `.env` e troque as senhas. Se a porta 3306 já estiver em uso no seu computador, mude `DB_PORT` (por exemplo, para 3307).

**2. Subir o banco**

```bash
docker compose up -d
docker compose ps
```

Aguarde o estado `healthy`. O schema (`sql/01_schema.sql`) é aplicado automaticamente na primeira inicialização, apenas quando o volume de dados está vazio. Para recriar o banco do zero: `docker compose down -v`.

**3. Baixar os microdados**

Baixe os arquivos do Censo da Educação Superior no site do INEP: [[https://www.gov.br/inep/pt-br/acesso-a-informacao/dados-abertos/microdados/censo-da-educacao-superior](https://www.gov.br/inep/pt-br/acesso-a-informacao/dados-abertos/microdados/censo-da-educacao-superior)]. Extraia-os em uma pasta `data/` na raiz do repositório. O ETL procura, recursivamente, arquivos como:

- `MICRODADOS_CADASTRO_IES_<ano>.CSV` (ou `MICRODADOS_ED_SUP_IES_<ano>.CSV` em anos recentes)
- `MICRODADOS_CADASTRO_CURSOS_<ano>.CSV`

A pasta `data/` não é versionada.

**4. Executar o ETL**

```bash
pip install -r etl/requirements.txt
python etl/etl.py --data-dir ./data
```

Para carregar apenas um ano: `python etl/etl.py --data-dir ./data --year 2024`.

O ETL lê a conexão das variáveis `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD` e `DB_NAME` (do `.env` ou do ambiente).

## Observações sobre o modelo

Cursos a distância aparecem em várias linhas por ano no arquivo do INEP, e a regra correta para somar métricas depende da coluna (`tp_dimensao`). A explicação completa está no cabeçalho de `sql/01_schema.sql` e nos comentários das colunas de `curso_estatisticas`.

## Licença

MIT (ver `LICENSE`).