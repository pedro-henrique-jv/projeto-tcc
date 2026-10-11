-- =====================================================================
-- Censo da Educação Superior (INEP) - Banco normalizado
-- TCC - Pedro Henrique / Orientador: Henry Emanuel Leal Cagnini
-- MariaDB 10.11+
--
-- Fontes: MICRODADOS_CADASTRO_IES_<ano>.CSV, MICRODADOS_CADASTRO_CURSOS_<ano>.CSV
-- Dicionário: dicionário_dados_educação_superior.xlsx (INEP)
--
-- NOTA DE MODELAGEM (importante para quem for gerar SQL, inclusive LLMs):
-- Cursos EAD são reportados pelo INEP em múltiplas linhas por ano:
--   - uma linha por MUNICÍPIO-POLO (TP_DIMENSAO = 2)
--   - uma linha de TOTAL BRASIL (TP_DIMENSAO = 3)
-- Cursos presenciais têm apenas 1 linha (TP_DIMENSAO = 1).
--
-- ATENÇÃO - a regra de deduplicação DEPENDE DA MÉTRICA (descoberto ao
-- validar o banco com perguntas de teste; não é intuitivo):
--   - qt_vg_total / qt_inscrito_total: só vêm preenchidos na linha de
--     TOTAL BRASIL (tp_dimensao=3) para cursos EAD; as linhas de polo
--     (tp_dimensao=2) vêm com esses campos zerados. Use tp_dimensao
--     IN (1,3) para esses campos.
--   - qt_ing / qt_mat / qt_conc (e as variações por sexo/turno/faixa
--     etária/cor-raça): é o OPOSTO - só vêm preenchidos nas linhas de
--     POLO (tp_dimensao=2, precisa somar todos os polos do curso); a
--     linha de total Brasil (tp_dimensao=3) vem zerada nesses campos.
--     Use tp_dimensao IN (1,2) para esses campos.
-- Validado com dados reais de 2024: o total de matrículas calculado
-- com a regra correta bate EXATAMENTE com o número oficial publicado
-- pelo INEP (10.227.266). Confirmado que TP_DIMENSAO em si (nome da
-- coluna) não foi renomeada nem teve a semântica alterada entre 2010
-- e 2024.
--
-- ATENÇÃO 2 - nome de IES NÃO é identificador único: grandes redes
-- privadas (ex: Anhanguera) registram múltiplas unidades/campi com
-- nome idêntico ou quase idêntico e co_ies diferentes. Sempre
-- filtrar/agrupar por co_ies, nunca assumir que um nome mapeia para
-- uma única instituição. Ver comentário na coluna ies_historico.no_ies.
--
-- HISTÓRICO DE REVISÕES DE MODELAGEM (feedback do orientador):
--   v1 -> v2: removida a tabela ano_censo (era uma dimensão "vazia",
--     só o ano como PK sem nenhum atributo próprio - não se justificava
--     como tabela; virou coluna SMALLINT direta com CHECK de validação).
--   v1 -> v2: hierarquia geográfica foi normalizada em cadeia própria
--     (regiao -> uf -> mesorregiao -> microrregiao -> municipio) em vez
--     de nomes/códigos de UF/região/mesorregião/microrregião duplicados
--     como colunas soltas dentro de municipio (violava 3FN: no_uf,
--     no_regiao etc. dependiam transitivamente de co_uf/co_regiao, não
--     diretamente da chave de municipio).
--   v1 -> v2: ies_historico e curso_historico passaram a usar chave
--     primária composta natural (co_ies+ano_censo / co_curso+ano_censo)
--     em vez de um "id" substituto artificial, já que a chave natural
--     já era única, obrigatória (NOT NULL) e estável - manter os dois
--     (id E a chave natural) era redundância sem propósito.
--   curso_estatisticas MANTÉM chave substituta "id": é a única tabela
--     onde isso é tecnicamente necessário, porque parte da chave
--     natural (co_municipio) é NULL para linhas de total Brasil de
--     EAD, e uma PRIMARY KEY não pode conter coluna NULL em SQL. Ver
--     comentário na própria coluna id de curso_estatisticas.
-- =====================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

CREATE DATABASE IF NOT EXISTS censo_educacao_superior
    CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE censo_educacao_superior;

-- ---------------------------------------------------------------------
-- REGIAO: nível mais alto da hierarquia territorial do IBGE.
-- ---------------------------------------------------------------------
CREATE TABLE regiao (
    co_regiao   TINYINT UNSIGNED NOT NULL COMMENT 'Código IBGE da grande região (1=Norte 2=Nordeste 3=Sudeste 4=Sul 5=Centro-Oeste).',
    no_regiao   VARCHAR(20) NULL COMMENT 'Nome da grande região. Nullable: visto em 2022 uma linha com CO_REGIAO preenchido mas nome ausente, mesmo padrão de inconsistência já visto em município.',
    PRIMARY KEY (co_regiao)
) ENGINE=InnoDB
  COMMENT='Grandes regiões geográficas do Brasil.';

-- ---------------------------------------------------------------------
-- UF: estados + Distrito Federal.
-- ---------------------------------------------------------------------
CREATE TABLE uf (
    co_uf       TINYINT UNSIGNED NOT NULL COMMENT 'Código IBGE da Unidade da Federação.',
    sg_uf       CHAR(2)      NULL COMMENT 'Sigla da UF. Nullable por segurança - mesmo padrão de dado incompleto já visto em outros campos geográficos do INEP.',
    no_uf       VARCHAR(50)  NULL COMMENT 'Nome da UF. Nullable pelo mesmo motivo.',
    co_regiao   TINYINT UNSIGNED NOT NULL COMMENT 'FK para regiao.co_regiao - região a que a UF pertence.',
    PRIMARY KEY (co_uf),
    UNIQUE KEY uq_uf_sigla (sg_uf),
    CONSTRAINT fk_uf_regiao FOREIGN KEY (co_regiao) REFERENCES regiao (co_regiao)
) ENGINE=InnoDB
  COMMENT='Unidades da Federação.';

-- ---------------------------------------------------------------------
-- MESORREGIAO: agrupamento de microrregiões dentro de uma UF.
-- ---------------------------------------------------------------------
CREATE TABLE mesorregiao (
    co_mesorregiao  INT UNSIGNED NOT NULL COMMENT 'Código IBGE da mesorregião.',
    no_mesorregiao  VARCHAR(100) NULL COMMENT 'Nome da mesorregião. Nullable por segurança - mesmo padrão de dado incompleto visto em outros campos geográficos.',
    co_uf           TINYINT UNSIGNED NOT NULL COMMENT 'FK para uf.co_uf.',
    PRIMARY KEY (co_mesorregiao),
    KEY idx_meso_uf (co_uf),
    CONSTRAINT fk_meso_uf FOREIGN KEY (co_uf) REFERENCES uf (co_uf)
) ENGINE=InnoDB
  COMMENT='Mesorregiões do IBGE.';

-- ---------------------------------------------------------------------
-- MICRORREGIAO: nível mais granular da hierarquia territorial usado
-- neste banco (abaixo dela viria o município).
-- ---------------------------------------------------------------------
CREATE TABLE microrregiao (
    co_microrregiao  INT UNSIGNED NOT NULL COMMENT 'Código IBGE da microrregião.',
    no_microrregiao  VARCHAR(100) NULL COMMENT 'Nome da microrregião. Nullable pelo mesmo motivo.',
    co_mesorregiao   INT UNSIGNED NOT NULL COMMENT 'FK para mesorregiao.co_mesorregiao.',
    PRIMARY KEY (co_microrregiao),
    KEY idx_micro_meso (co_mesorregiao),
    CONSTRAINT fk_micro_meso FOREIGN KEY (co_mesorregiao) REFERENCES mesorregiao (co_mesorregiao)
) ENGINE=InnoDB
  COMMENT='Microrregiões do IBGE.';

-- ---------------------------------------------------------------------
-- MUNICIPIO: base da hierarquia territorial. Praticamente estática -
-- não é versionada por ano (a divisão municipal do IBGE muda muito
-- raramente). Alimentada tanto pelo arquivo de IES quanto pelo de
-- cursos (municípios que só aparecem como polo EAD não têm sede de
-- nenhuma IES, mas ainda assim precisam existir aqui).
-- ---------------------------------------------------------------------
CREATE TABLE municipio (
    co_municipio     INT UNSIGNED NOT NULL COMMENT 'Código IBGE do município (7 dígitos).',
    no_municipio     VARCHAR(150) NULL COMMENT 'Nome do município. Nullable: alguns anos do INEP têm linhas com CO_MUNICIPIO preenchido mas nome ausente (visto em 2022).',
    in_capital       TINYINT(1)   NULL COMMENT '1 se o município é capital de UF, 0 caso contrário.',
    co_uf            TINYINT UNSIGNED NULL COMMENT 'FK para uf.co_uf. Link direto (não apenas via microrregiao) porque a sigla/código de UF vem preenchida na quase totalidade dos registros do INEP, mesmo quando meso/microrregião não vêm (comum em municípios que só aparecem como polo EAD, já que o arquivo de cursos não traz esses dois campos). co_microrregiao abaixo dá o encadeamento hierárquico completo quando disponível.',
    co_microrregiao  INT UNSIGNED NULL COMMENT 'FK para microrregiao.co_microrregiao. Nullable: nem sempre disponível (municípios que só aparecem em polos EAD costumam não ter esse dado, pois o arquivo MICRODADOS_CADASTRO_CURSOS não inclui colunas de meso/microrregião - só o de IES inclui).',
    PRIMARY KEY (co_municipio),
    KEY idx_municipio_uf (co_uf),
    KEY idx_municipio_microrregiao (co_microrregiao),
    CONSTRAINT fk_municipio_uf FOREIGN KEY (co_uf) REFERENCES uf (co_uf),
    CONSTRAINT fk_municipio_microrregiao FOREIGN KEY (co_microrregiao) REFERENCES microrregiao (co_microrregiao)
) ENGINE=InnoDB
  COMMENT='Municípios (código IBGE) onde IES têm sede ou cursos são ofertados/possuem polo EAD.';

-- ---------------------------------------------------------------------
-- CINE_AREA_GERAL / CINE_AREA_ESPECIFICA / CINE_AREA_DETALHADA /
-- CINE_AREA_ROTULO: os 4 níveis da classificação internacional
-- CINE/UNESCO de área de curso, todos extraídos para tabela própria
-- (dependência funcional código->nome). Ver nota detalhada abaixo
-- sobre o trade-off assumido nos níveis 3 e 4 (2 códigos, de centenas,
-- com grafia diferente entre anos - resolvido por "o ano mais recente
-- vence").
-- ---------------------------------------------------------------------
CREATE TABLE cine_area_geral (
    co_cine_area_geral  TINYINT UNSIGNED NOT NULL COMMENT 'Código da área geral da classificação CINE/UNESCO.',
    no_cine_area_geral  VARCHAR(120) NOT NULL COMMENT 'Nome da área geral CINE/UNESCO.',
    PRIMARY KEY (co_cine_area_geral)
) ENGINE=InnoDB
  COMMENT='Nível mais amplo da classificação CINE/UNESCO de área de curso (ex: Educação, Saúde e Bem-Estar).';

CREATE TABLE cine_area_especifica (
    co_cine_area_especifica  SMALLINT UNSIGNED NOT NULL COMMENT 'Código da área específica CINE/UNESCO.',
    no_cine_area_especifica  VARCHAR(150) NOT NULL COMMENT 'Nome da área específica CINE/UNESCO.',
    co_cine_area_geral       TINYINT UNSIGNED NOT NULL COMMENT 'FK para cine_area_geral - área geral a que esta área específica pertence.',
    PRIMARY KEY (co_cine_area_especifica),
    KEY idx_especifica_geral (co_cine_area_geral),
    CONSTRAINT fk_especifica_geral FOREIGN KEY (co_cine_area_geral) REFERENCES cine_area_geral (co_cine_area_geral)
) ENGINE=InnoDB
  COMMENT='Nível intermediário da classificação CINE/UNESCO de área de curso.';

-- ---------------------------------------------------------------------
-- CINE_AREA_DETALHADA / CINE_AREA_ROTULO: os dois níveis mais
-- granulares da classificação CINE. Inicialmente mantidos como
-- colunas soltas (não normalizados) porque a dependência funcional
-- código->nome tinha 2 exceções confirmadas (o INEP mudou o texto
-- para o MESMO código entre anos). Após medir o tamanho real do
-- problema, a decisão foi normalizar mesmo assim:
--
--   Nível 3 (detalhada): 93 códigos distintos, 1 com exceção (~1%).
--   Nível 4 (rótulo):   373 códigos distintos, 1 com exceção (~0,3%).
--
-- TRADE-OFF DOCUMENTADO (explicar ao orientador se perguntado): como
-- o ETL carrega os anos em ordem crescente e o upsert usa "o valor
-- mais novo vence", o nome que fica registrado na tabela de lookup é
-- sempre o da carga MAIS RECENTE daquele código. Exemplo real:
-- co_cine_area_rotulo='0714E04' tinha "Engenharia de computação
-- (DCN Engenharia)" em 2010 e "Engenharia de computação" em 2024;
-- após normalizar, uma consulta que junta um curso_historico DE 2010
-- com essa tabela mostra o texto de 2024, não o texto que o INEP
-- realmente publicou em 2010. O CÓDIGO em si (co_cine_area_detalhada
-- / co_cine_area_rotulo) nunca muda - só o texto legível de anos
-- antigos, e só nesses 2 códigos específicos. Perda de fidelidade
-- histórica textual mínima e aceita conscientemente, em troca de
-- eliminar a redundância nos ~99% dos códigos que não têm esse
-- problema.
-- ---------------------------------------------------------------------
CREATE TABLE cine_area_detalhada (
    co_cine_area_detalhada  SMALLINT UNSIGNED NOT NULL COMMENT 'Código da área detalhada CINE/UNESCO.',
    no_cine_area_detalhada  VARCHAR(150) NOT NULL COMMENT 'Nome da área detalhada CINE/UNESCO. Ver nota acima sobre 1 código (de 93) com grafia diferente entre anos - fica registrada a versão do ano carregado mais recentemente.',
    co_cine_area_especifica SMALLINT UNSIGNED NOT NULL COMMENT 'FK para cine_area_especifica - completa a cadeia hierárquica (confirmado empiricamente: cada nível 3 pertence sempre ao mesmo nível 2, sem exceção).',
    PRIMARY KEY (co_cine_area_detalhada),
    KEY idx_detalhada_especifica (co_cine_area_especifica),
    CONSTRAINT fk_detalhada_especifica FOREIGN KEY (co_cine_area_especifica) REFERENCES cine_area_especifica (co_cine_area_especifica)
) ENGINE=InnoDB
  COMMENT='Nível 3 (detalhado) da classificação CINE/UNESCO de área de curso.';

CREATE TABLE cine_area_rotulo (
    co_cine_area_rotulo    VARCHAR(7)   NOT NULL COMMENT 'Código CINE/UNESCO do curso (rótulo detalhado, nível mais granular).',
    no_cine_area_rotulo    VARCHAR(180) NOT NULL COMMENT 'Nome do curso padronizado pela classificação CINE/UNESCO. Ver nota acima sobre 1 código (de 373) com grafia diferente entre anos - fica registrada a versão do ano carregado mais recentemente.',
    co_cine_area_detalhada SMALLINT UNSIGNED NOT NULL COMMENT 'FK para cine_area_detalhada - completa a cadeia hierárquica (confirmado empiricamente: cada nível 4 pertence sempre ao mesmo nível 3, sem exceção).',
    PRIMARY KEY (co_cine_area_rotulo),
    KEY idx_rotulo_detalhada (co_cine_area_detalhada),
    CONSTRAINT fk_rotulo_detalhada FOREIGN KEY (co_cine_area_detalhada) REFERENCES cine_area_detalhada (co_cine_area_detalhada)
) ENGINE=InnoDB
  COMMENT='Nível 4 (rótulo) da classificação CINE/UNESCO de área de curso - o mais granular.';

-- ---------------------------------------------------------------------
-- TABELAS DE DOMÍNIO: valores fixos e universais dos campos TP_* do
-- INEP, extraídos do dicionário oficial (dicionário_dados_educação_
-- superior.xlsx). Diferente das dimensões carregadas pelo ETL, estas
-- são "seed data" - dados de referência fixos, não vêm dos CSVs.
--
-- Por que virar tabela em vez de ficar só documentado em COMMENT:
-- permite ao LLM (ou qualquer usuário) fazer JOIN e ver o nome direto
-- no resultado da consulta, sem precisar "decorar" o significado do
-- código - alinhado com o propósito do banco.
-- ---------------------------------------------------------------------
CREATE TABLE organizacao_academica (
    co_organizacao_academica  TINYINT UNSIGNED NOT NULL COMMENT 'Corresponde a TP_ORGANIZACAO_ACADEMICA no INEP.',
    no_organizacao_academica  VARCHAR(100) NOT NULL COMMENT 'Nome da organização acadêmica.',
    PRIMARY KEY (co_organizacao_academica)
) ENGINE=InnoDB COMMENT='Domínio de TP_ORGANIZACAO_ACADEMICA. Nota do dicionário INEP: em 2009 não existe a opção 5.';

INSERT INTO organizacao_academica (co_organizacao_academica, no_organizacao_academica) VALUES
    (1, 'Universidade'),
    (2, 'Centro Universitário'),
    (3, 'Faculdade'),
    (4, 'Instituto Federal de Educação, Ciência e Tecnologia'),
    (5, 'Centro Federal de Educação Tecnológica');

CREATE TABLE categoria_administrativa (
    co_categoria_administrativa  TINYINT UNSIGNED NOT NULL COMMENT 'Corresponde a TP_CATEGORIA_ADMINISTRATIVA no INEP.',
    no_categoria_administrativa  VARCHAR(100) NOT NULL COMMENT 'Nome da categoria administrativa.',
    PRIMARY KEY (co_categoria_administrativa)
) ENGINE=InnoDB COMMENT='Domínio de TP_CATEGORIA_ADMINISTRATIVA. Nota do dicionário INEP: categorias 6, 8 e 9 existiram somente em 2009; categoria 7 (Especial) foi criada em 2012.';

INSERT INTO categoria_administrativa (co_categoria_administrativa, no_categoria_administrativa) VALUES
    (1, 'Pública Federal'),
    (2, 'Pública Estadual'),
    (3, 'Pública Municipal'),
    (4, 'Privada com fins lucrativos'),
    (5, 'Privada sem fins lucrativos'),
    (6, 'Privada - Particular em sentido estrito'),
    (7, 'Especial'),
    (8, 'Privada comunitária'),
    (9, 'Privada confessional');

CREATE TABLE rede (
    co_rede  TINYINT UNSIGNED NOT NULL COMMENT 'Corresponde a TP_REDE no INEP. Usada tanto por ies_historico quanto por curso_historico.',
    no_rede  VARCHAR(20) NOT NULL COMMENT 'Nome da rede (Pública ou Privada).',
    PRIMARY KEY (co_rede)
) ENGINE=InnoDB COMMENT='Domínio de TP_REDE.';

INSERT INTO rede (co_rede, no_rede) VALUES (1, 'Pública'), (2, 'Privada');

CREATE TABLE grau_academico (
    co_grau_academico  TINYINT UNSIGNED NOT NULL COMMENT 'Corresponde a TP_GRAU_ACADEMICO no INEP.',
    no_grau_academico  VARCHAR(50) NOT NULL COMMENT 'Nome do grau acadêmico.',
    PRIMARY KEY (co_grau_academico)
) ENGINE=InnoDB COMMENT='Domínio de TP_GRAU_ACADEMICO. O dicionário INEP também documenta valor "." (não aplicável) para cursos sequenciais/área básica - tratado como NULL neste banco (ver clean_value() no ETL). ACHADO NÃO DOCUMENTADO: em 2022, ~0.25% das linhas trazem valor "0" (fora do dicionário oficial, que só prevê 1-4 e "."), majoritariamente em cursos de Graduação normal - não bate com a exceção de "não aplicável" para sequenciais. Também tratado como NULL, por segurança (ver load_cursos() no ETL).';

INSERT INTO grau_academico (co_grau_academico, no_grau_academico) VALUES
    (1, 'Bacharelado'),
    (2, 'Licenciatura'),
    (3, 'Tecnológico'),
    (4, 'Bacharelado e Licenciatura');

CREATE TABLE modalidade_ensino (
    co_modalidade_ensino  TINYINT UNSIGNED NOT NULL COMMENT 'Corresponde a TP_MODALIDADE_ENSINO no INEP.',
    no_modalidade_ensino  VARCHAR(30) NOT NULL COMMENT 'Nome da modalidade de ensino.',
    PRIMARY KEY (co_modalidade_ensino)
) ENGINE=InnoDB COMMENT='Domínio de TP_MODALIDADE_ENSINO.';

INSERT INTO modalidade_ensino (co_modalidade_ensino, no_modalidade_ensino) VALUES
    (1, 'Presencial'),
    (2, 'Curso a distância');

CREATE TABLE nivel_academico (
    co_nivel_academico  TINYINT UNSIGNED NOT NULL COMMENT 'Corresponde a TP_NIVEL_ACADEMICO no INEP.',
    no_nivel_academico  VARCHAR(50) NOT NULL COMMENT 'Nome do nível acadêmico.',
    PRIMARY KEY (co_nivel_academico)
) ENGINE=InnoDB COMMENT='Domínio de TP_NIVEL_ACADEMICO.';

INSERT INTO nivel_academico (co_nivel_academico, no_nivel_academico) VALUES
    (1, 'Graduação'),
    (2, 'Sequencial de Formação Específica');

CREATE TABLE dimensao (
    co_dimensao  TINYINT UNSIGNED NOT NULL COMMENT 'Corresponde a TP_DIMENSAO no INEP. Achado da revisão de normalização: era o único campo TP_* do banco sem tabela de domínio própria até esta correção.',
    no_dimensao  VARCHAR(100) NOT NULL COMMENT 'Nome da dimensão geográfica de oferta do curso.',
    PRIMARY KEY (co_dimensao)
) ENGINE=InnoDB COMMENT='Domínio de TP_DIMENSAO. Nota do dicionário INEP: "Em virtude da estrutura da base da Educação Superior, para os cursos a distância não é possível quantificar o número de cursos, vagas e inscritos por Regiões Geográficas, Unidades da Federação e Municípios" - é essa a razão estrutural da regra de agregação dependente de métrica documentada em curso_estatisticas.tp_dimensao.';

INSERT INTO dimensao (co_dimensao, no_dimensao) VALUES
    (1, 'Cursos presenciais ofertados no Brasil'),
    (2, 'Cursos a distância ofertados no Brasil'),
    (3, 'Cursos a distância com dimensão de dados somente a nível Brasil'),
    (4, 'Cursos a distância ofertados por instituições brasileiras no exterior');

-- ---------------------------------------------------------------------
-- MANTENEDORA: entidade mantenedora da IES. Atributos são "a última
-- versão conhecida"; o vínculo IES->mantenedora POR ANO fica em
-- ies_historico, então o histórico da relação não se perde mesmo sem
-- versionar a mantenedora em si.
-- ---------------------------------------------------------------------
CREATE TABLE mantenedora (
    co_mantenedora  INT UNSIGNED NOT NULL COMMENT 'Código INEP único da mantenedora.',
    no_mantenedora  VARCHAR(150) NULL COMMENT 'Nome da mantenedora (última versão observada nos dados). Nullable por segurança - dados do INEP às vezes vêm incompletos.',
    PRIMARY KEY (co_mantenedora)
) ENGINE=InnoDB
  COMMENT='Entidades mantenedoras de Instituições de Ensino Superior.';

-- ---------------------------------------------------------------------
-- IES: identidade lógica da instituição, estável entre os anos.
-- ---------------------------------------------------------------------
CREATE TABLE ies (
    co_ies          INT UNSIGNED NOT NULL COMMENT 'Código INEP único e estável da IES ao longo dos anos.',
    primeiro_ano    SMALLINT UNSIGNED NULL COMMENT 'Primeiro ano em que a IES aparece no banco (preenchido pelo ETL).',
    ultimo_ano      SMALLINT UNSIGNED NULL COMMENT 'Último ano em que a IES aparece no banco (preenchido pelo ETL).',
    PRIMARY KEY (co_ies)
) ENGINE=InnoDB
  COMMENT='Instituições de Ensino Superior - chave lógica estável entre censos.';

-- ---------------------------------------------------------------------
-- CURSO: identidade lógica do curso, estável entre os anos.
-- ---------------------------------------------------------------------
CREATE TABLE curso (
    co_curso        INT UNSIGNED NOT NULL COMMENT 'Código INEP único e estável do curso ao longo dos anos.',
    primeiro_ano    SMALLINT UNSIGNED NULL COMMENT 'Primeiro ano em que o curso aparece no banco (preenchido pelo ETL).',
    ultimo_ano      SMALLINT UNSIGNED NULL COMMENT 'Último ano em que o curso aparece no banco (preenchido pelo ETL).',
    PRIMARY KEY (co_curso)
) ENGINE=InnoDB
  COMMENT='Cursos de graduação - chave lógica estável entre censos.';

-- ---------------------------------------------------------------------
-- IES_HISTORICO: atributos da IES que variam ano a ano (organização
-- acadêmica, categoria administrativa, mantenedora, endereço, corpo
-- docente/técnico do ano).
--
-- CHAVE PRIMÁRIA COMPOSTA (co_ies, ano_censo): não há coluna "id"
-- substituta separada. A combinação (co_ies, ano_censo) já é NOT NULL,
-- única por natureza (1 IES só tem 1 snapshot por ano) e é o
-- identificador que qualquer pessoa/LLM gerando SQL vai procurar
-- primeiro - um "id" artificial ao lado dela seria redundante.
-- ---------------------------------------------------------------------
CREATE TABLE ies_historico (
    co_ies                          INT UNSIGNED NOT NULL COMMENT 'FK lógica para ies.co_ies - código estável da IES entre anos. Parte da chave primária composta desta tabela.',
    ano_censo                       SMALLINT UNSIGNED NOT NULL COMMENT 'Ano do Censo da Educação Superior a que este snapshot se refere (2009 em diante). Parte da chave primária composta. Sem tabela dimensão própria - é um valor escalar simples, validado por CHECK.',
    co_mantenedora                  INT UNSIGNED NULL COMMENT 'FK para mantenedora.co_mantenedora - qual mantenedora era responsável pela IES naquele ano.',
    co_municipio                    INT UNSIGNED NULL COMMENT 'Município da sede/reitoria da IES naquele ano.',

    no_ies                          VARCHAR(200) NULL COMMENT 'Nome da IES naquele ano. Nullable por segurança - dados do INEP às vezes vêm incompletos. ATENÇÃO: nome NÃO é identificador único - grandes redes privadas (ex: Anhanguera) registram múltiplas unidades/campi com nome idêntico ou quase idêntico e co_ies diferentes (ex: "CENTRO UNIVERSITÁRIO ANHANGUERA" existe em Santo André/SP E em Leme/SP, com co_ies distintos). Sempre filtrar/agrupar por co_ies, nunca assumir que um nome mapeia para uma única instituição. Também há variação de grafia entre anos (acentuação, reforma ortográfica) para a MESMA instituição.',
    sg_ies                          VARCHAR(30)  NULL COMMENT 'Sigla da IES naquele ano.',
    tp_organizacao_academica        TINYINT UNSIGNED NULL COMMENT 'FK para organizacao_academica. Corresponde a TP_ORGANIZACAO_ACADEMICA no INEP.',
    tp_categoria_administrativa     TINYINT UNSIGNED NULL COMMENT 'FK para categoria_administrativa. Corresponde a TP_CATEGORIA_ADMINISTRATIVA no INEP. A partir de determinado ano o INEP passou a reportar comunitária/confessional como flags separadas (ver in_comunitaria/in_confessional) em vez de valores 6/8/9 aqui.',
    tp_rede                         TINYINT UNSIGNED NULL COMMENT 'FK para rede. Coluna presente no arquivo de IES a partir de determinado ano (ausente em 2010, presente em 2024); nesses casos fica NULL.',
    in_comunitaria                  TINYINT(1)   NULL COMMENT '1=IES comunitária. Coluna nova a partir de determinado ano; NULL em anos anteriores.',
    in_confessional                 TINYINT(1)   NULL COMMENT '1=IES confessional. Coluna nova a partir de determinado ano; NULL em anos anteriores.',

    ds_endereco_ies                 VARCHAR(255) NULL COMMENT 'Logradouro do endereço da sede/reitoria da IES.',
    ds_numero_endereco_ies          VARCHAR(20)  NULL COMMENT 'Número do endereço da IES.',
    ds_complemento_endereco_ies     VARCHAR(150) NULL COMMENT 'Tamanho ampliado a partir do observado em 2024 (até 85 chars, dicionário INEP indicava só 20).',
    no_bairro_ies                   VARCHAR(80)  NULL COMMENT 'Bairro do endereço da IES.',
    nu_cep_ies                      CHAR(8)      NULL COMMENT 'CEP do endereço da IES (sem hífen).',

    -- Corpo docente (núcleo + demografia)
    qt_doc_total                    INT UNSIGNED NULL COMMENT 'Docentes totais (em exercício e afastados).',
    qt_doc_exe                      INT UNSIGNED NULL COMMENT 'Docentes EM EXERCÍCIO (isto é, efetivamente atuando - não confundir com "executivo"). Corresponde a QT_DOC_EXE no INEP: subconjunto de qt_doc_total que exclui docentes afastados. É a população-base dos recortes qt_doc_ex_* abaixo (sexo, escolaridade, regime de trabalho, cor/raça somam de volta para este valor).',
    qt_doc_ex_femi                  INT UNSIGNED NULL COMMENT 'Docentes em exercício do sexo feminino.',
    qt_doc_ex_masc                  INT UNSIGNED NULL COMMENT 'Docentes em exercício do sexo masculino.',
    qt_doc_ex_grad                  INT UNSIGNED NULL COMMENT 'Docentes em exercício apenas com graduação.',
    qt_doc_ex_esp                   INT UNSIGNED NULL COMMENT 'Docentes em exercício com especialização.',
    qt_doc_ex_mest                  INT UNSIGNED NULL COMMENT 'Docentes em exercício com mestrado.',
    qt_doc_ex_dout                  INT UNSIGNED NULL COMMENT 'Docentes em exercício com doutorado.',
    qt_doc_ex_int_de                INT UNSIGNED NULL COMMENT 'Docentes em exercício, tempo integral com dedicação exclusiva.',
    qt_doc_ex_int_sem_de            INT UNSIGNED NULL COMMENT 'Docentes em exercício, tempo integral sem dedicação exclusiva.',
    qt_doc_ex_parc                  INT UNSIGNED NULL COMMENT 'Docentes em exercício, tempo parcial.',
    qt_doc_ex_hor                   INT UNSIGNED NULL COMMENT 'Docentes em exercício, horistas.',
    qt_doc_ex_branca                INT UNSIGNED NULL COMMENT 'Docentes em exercício de cor/raça branca.',
    qt_doc_ex_preta                 INT UNSIGNED NULL COMMENT 'Docentes em exercício de cor/raça preta.',
    qt_doc_ex_parda                 INT UNSIGNED NULL COMMENT 'Docentes em exercício de cor/raça parda.',
    qt_doc_ex_amarela               INT UNSIGNED NULL COMMENT 'Docentes em exercício de cor/raça amarela.',
    qt_doc_ex_indigena              INT UNSIGNED NULL COMMENT 'Docentes em exercício de cor/raça indígena.',
    qt_doc_ex_cor_nd                INT UNSIGNED NULL COMMENT 'Cor/raça não declarada.',

    -- Corpo técnico-administrativo
    qt_tec_total                    INT UNSIGNED NULL COMMENT 'Total de técnicos administrativos da IES no ano (sem quebra por sexo/cor-raça neste schema).',

    PRIMARY KEY (co_ies, ano_censo),
    CONSTRAINT chk_ies_hist_ano CHECK (ano_censo >= 2009),
    KEY idx_ies_hist_mantenedora (co_mantenedora),
    KEY idx_ies_hist_municipio (co_municipio),
    CONSTRAINT fk_ies_hist_ies        FOREIGN KEY (co_ies)         REFERENCES ies (co_ies),
    CONSTRAINT fk_ies_hist_mantenedora FOREIGN KEY (co_mantenedora) REFERENCES mantenedora (co_mantenedora),
    CONSTRAINT fk_ies_hist_municipio  FOREIGN KEY (co_municipio)   REFERENCES municipio (co_municipio),
    CONSTRAINT fk_ies_hist_organizacao FOREIGN KEY (tp_organizacao_academica) REFERENCES organizacao_academica (co_organizacao_academica),
    CONSTRAINT fk_ies_hist_categoria   FOREIGN KEY (tp_categoria_administrativa) REFERENCES categoria_administrativa (co_categoria_administrativa),
    CONSTRAINT fk_ies_hist_rede        FOREIGN KEY (tp_rede)        REFERENCES rede (co_rede)
) ENGINE=InnoDB
  COMMENT='Snapshot anual dos atributos de cada IES (1 linha por IES por ano).';

-- ---------------------------------------------------------------------
-- CURSO_HISTORICO: atributos do curso que variam ano a ano.
-- Grão: 1 linha por curso por ano (mesmo cursos EAD com múltiplos
-- polos têm 1 única linha aqui; a granularidade por polo fica em
-- curso_estatisticas).
--
-- CHAVE PRIMÁRIA COMPOSTA (co_curso, ano_censo) - mesmo raciocínio de
-- ies_historico: a chave natural já é NOT NULL e única, um "id"
-- substituto ao lado seria redundante.
-- ---------------------------------------------------------------------
CREATE TABLE curso_historico (
    co_curso                    INT UNSIGNED NOT NULL COMMENT 'FK lógica para curso.co_curso - código estável do curso entre anos. Parte da chave primária composta.',
    ano_censo                   SMALLINT UNSIGNED NOT NULL COMMENT 'Ano do Censo a que este snapshot se refere. Parte da chave primária composta.',
    co_ies                      INT UNSIGNED NOT NULL COMMENT 'IES (naquele ano) que oferece o curso. Junto com ano_censo, referencia ies_historico(co_ies, ano_censo) - FK composta, não um id substituto.',

    no_curso                    VARCHAR(250) NULL COMMENT 'Nome do curso conforme registrado pela IES. Tamanho ampliado a partir do observado em 2024 (até 158 chars).',
    co_cine_area_rotulo       VARCHAR(7)   NULL COMMENT 'FK para cine_area_rotulo. Único ponto de entrada na cadeia CINE - os níveis 1/2/3 são obtidos via JOIN em cadeia (cine_area_rotulo -> cine_area_detalhada -> cine_area_especifica -> cine_area_geral), não guardados aqui redundantemente. Confirmado empiricamente: as 75.985 linhas com classificação CINE têm os 4 níveis sempre presentes juntos, sem exceção - a cadeia nunca "quebra" no meio.',

    tp_grau_academico           TINYINT UNSIGNED NULL COMMENT 'FK para grau_academico. Corresponde a TP_GRAU_ACADEMICO no INEP.',
    tp_modalidade_ensino        TINYINT UNSIGNED NULL COMMENT 'FK para modalidade_ensino. Corresponde a TP_MODALIDADE_ENSINO no INEP.',
    tp_nivel_academico          TINYINT UNSIGNED NULL COMMENT 'FK para nivel_academico. Corresponde a TP_NIVEL_ACADEMICO no INEP.',
    tp_rede                     TINYINT UNSIGNED NULL COMMENT 'FK para rede. Corresponde a TP_REDE no INEP.',
    in_gratuito                 TINYINT(1)   NULL COMMENT '1=Sim 0=Não.',

    PRIMARY KEY (co_curso, ano_censo),
    CONSTRAINT chk_curso_hist_ano CHECK (ano_censo >= 2009),
    KEY idx_curso_hist_ies (co_ies, ano_censo),
    KEY idx_curso_hist_cine_rotulo (co_cine_area_rotulo),
    CONSTRAINT fk_curso_hist_curso FOREIGN KEY (co_curso)         REFERENCES curso (co_curso),
    CONSTRAINT fk_curso_hist_ies   FOREIGN KEY (co_ies, ano_censo) REFERENCES ies_historico (co_ies, ano_censo),
    CONSTRAINT fk_curso_hist_cine_rotulo FOREIGN KEY (co_cine_area_rotulo) REFERENCES cine_area_rotulo (co_cine_area_rotulo),
    CONSTRAINT fk_curso_hist_grau FOREIGN KEY (tp_grau_academico) REFERENCES grau_academico (co_grau_academico),
    CONSTRAINT fk_curso_hist_modalidade FOREIGN KEY (tp_modalidade_ensino) REFERENCES modalidade_ensino (co_modalidade_ensino),
    CONSTRAINT fk_curso_hist_nivel FOREIGN KEY (tp_nivel_academico) REFERENCES nivel_academico (co_nivel_academico),
    CONSTRAINT fk_curso_hist_rede FOREIGN KEY (tp_rede) REFERENCES rede (co_rede)
) ENGINE=InnoDB
  COMMENT='Snapshot anual dos atributos descritivos de cada curso (1 linha por curso por ano).';

-- ---------------------------------------------------------------------
-- CURSO_ESTATISTICAS: métricas quantitativas do curso no ano.
-- Grão: 1 linha por curso + ano + tp_dimensao (+ município, no caso de
-- polos EAD). Ver nota de modelagem no topo do arquivo sobre como
-- somar sem duplicar (regra depende da métrica).
-- ---------------------------------------------------------------------
CREATE TABLE curso_estatisticas (
    id                      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Chave substituta (surrogate key). Necessária APENAS nesta tabela (diferente de ies_historico/curso_historico, que usam chave composta natural): a chave natural completa desta tabela seria (co_curso, ano_censo, tp_dimensao, co_municipio), mas co_municipio é NULL para as linhas de total Brasil de EAD - e uma PRIMARY KEY não pode conter coluna com valor NULL em SQL. A unicidade real do grão é garantida pela UNIQUE KEY uq_estat_grao abaixo, que trata NULL corretamente (MariaDB permite múltiplos NULLs distintos em UNIQUE KEY).',
    co_curso                INT UNSIGNED NOT NULL COMMENT 'Junto com ano_censo, referencia curso_historico(co_curso, ano_censo) - FK composta.',
    ano_censo                SMALLINT UNSIGNED NOT NULL COMMENT 'Ano do Censo.',
    tp_dimensao             TINYINT UNSIGNED NOT NULL COMMENT 'FK para dimensao. Corresponde a TP_DIMENSAO no INEP. IMPORTANTE - regra de agregação depende da métrica: para qt_vg_total/qt_inscrito_total use tp_dimensao IN (1,3); para qt_ing/qt_mat/qt_conc (e variações) use tp_dimensao IN (1,2), somando todos os polos. Ver nota de modelagem no topo do arquivo.',
    co_municipio            INT UNSIGNED NULL COMMENT 'Município de oferta (obrigatório se tp_dimensao IN (1,2); nulo para o total Brasil de EAD).',

    -- Vagas / inscritos
    qt_vg_total              INT UNSIGNED NULL COMMENT 'Vagas totais ofertadas no curso no ano. Para EAD, só vem preenchido na linha tp_dimensao=3 (total Brasil) - ver nota de modelagem no topo do arquivo.',
    qt_vg_total_diurno       INT UNSIGNED NULL COMMENT 'Vagas ofertadas no turno diurno (subconjunto de qt_vg_total).',
    qt_vg_total_noturno      INT UNSIGNED NULL COMMENT 'Vagas ofertadas no turno noturno (subconjunto de qt_vg_total).',
    qt_vg_total_ead          INT UNSIGNED NULL COMMENT 'Vagas ofertadas na modalidade EAD (subconjunto de qt_vg_total).',
    qt_inscrito_total        INT UNSIGNED NULL COMMENT 'Total de inscritos no processo seletivo do curso no ano. Para EAD, mesma regra de qt_vg_total (só tp_dimensao=3).',

    -- Ingressantes
    qt_ing                   INT UNSIGNED NULL COMMENT 'Total de ingressantes no curso no ano. Para EAD, só vem preenchido nas linhas tp_dimensao=2 (por polo) - some todos os polos do curso; a linha tp_dimensao=3 vem zerada neste campo. Ver nota de modelagem no topo do arquivo.',
    qt_ing_fem                INT UNSIGNED NULL COMMENT 'Ingressantes do sexo feminino.',
    qt_ing_masc               INT UNSIGNED NULL COMMENT 'Ingressantes do sexo masculino.',
    qt_ing_diurno             INT UNSIGNED NULL COMMENT 'Ingressantes no turno diurno.',
    qt_ing_noturno            INT UNSIGNED NULL COMMENT 'Ingressantes no turno noturno.',
    qt_ing_0_17               INT UNSIGNED NULL COMMENT 'Ingressantes com até 17 anos.',
    qt_ing_18_24              INT UNSIGNED NULL COMMENT 'Ingressantes de 18 a 24 anos.',
    qt_ing_25_29              INT UNSIGNED NULL COMMENT 'Ingressantes de 25 a 29 anos.',
    qt_ing_30_34              INT UNSIGNED NULL COMMENT 'Ingressantes de 30 a 34 anos.',
    qt_ing_35_39              INT UNSIGNED NULL COMMENT 'Ingressantes de 35 a 39 anos.',
    qt_ing_40_49              INT UNSIGNED NULL COMMENT 'Ingressantes de 40 a 49 anos.',
    qt_ing_50_59              INT UNSIGNED NULL COMMENT 'Ingressantes de 50 a 59 anos.',
    qt_ing_60_mais            INT UNSIGNED NULL COMMENT 'Ingressantes com 60 anos ou mais.',
    qt_ing_branca             INT UNSIGNED NULL COMMENT 'Ingressantes de cor/raça branca.',
    qt_ing_preta              INT UNSIGNED NULL COMMENT 'Ingressantes de cor/raça preta.',
    qt_ing_parda              INT UNSIGNED NULL COMMENT 'Ingressantes de cor/raça parda.',
    qt_ing_amarela            INT UNSIGNED NULL COMMENT 'Ingressantes de cor/raça amarela.',
    qt_ing_indigena           INT UNSIGNED NULL COMMENT 'Ingressantes de cor/raça indígena.',
    qt_ing_cornd              INT UNSIGNED NULL COMMENT 'Ingressantes com cor/raça não declarada.',

    -- Matrículas
    qt_mat                   INT UNSIGNED NULL COMMENT 'Total de matriculados no curso no ano. Para EAD, só vem preenchido nas linhas tp_dimensao=2 (por polo) - some todos os polos do curso; a linha tp_dimensao=3 vem zerada neste campo. Ver nota de modelagem no topo do arquivo.',
    qt_mat_fem                INT UNSIGNED NULL COMMENT 'Matriculados do sexo feminino.',
    qt_mat_masc               INT UNSIGNED NULL COMMENT 'Matriculados do sexo masculino.',
    qt_mat_diurno             INT UNSIGNED NULL COMMENT 'Matriculados no turno diurno.',
    qt_mat_noturno            INT UNSIGNED NULL COMMENT 'Matriculados no turno noturno.',
    qt_mat_0_17               INT UNSIGNED NULL COMMENT 'Matriculados com até 17 anos.',
    qt_mat_18_24              INT UNSIGNED NULL COMMENT 'Matriculados de 18 a 24 anos.',
    qt_mat_25_29              INT UNSIGNED NULL COMMENT 'Matriculados de 25 a 29 anos.',
    qt_mat_30_34              INT UNSIGNED NULL COMMENT 'Matriculados de 30 a 34 anos.',
    qt_mat_35_39              INT UNSIGNED NULL COMMENT 'Matriculados de 35 a 39 anos.',
    qt_mat_40_49              INT UNSIGNED NULL COMMENT 'Matriculados de 40 a 49 anos.',
    qt_mat_50_59              INT UNSIGNED NULL COMMENT 'Matriculados de 50 a 59 anos.',
    qt_mat_60_mais            INT UNSIGNED NULL COMMENT 'Matriculados com 60 anos ou mais.',
    qt_mat_branca             INT UNSIGNED NULL COMMENT 'Matriculados de cor/raça branca.',
    qt_mat_preta              INT UNSIGNED NULL COMMENT 'Matriculados de cor/raça preta.',
    qt_mat_parda              INT UNSIGNED NULL COMMENT 'Matriculados de cor/raça parda.',
    qt_mat_amarela            INT UNSIGNED NULL COMMENT 'Matriculados de cor/raça amarela.',
    qt_mat_indigena           INT UNSIGNED NULL COMMENT 'Matriculados de cor/raça indígena.',
    qt_mat_cornd              INT UNSIGNED NULL COMMENT 'Matriculados com cor/raça não declarada.',

    -- Concluintes
    qt_conc                  INT UNSIGNED NULL COMMENT 'Total de concluintes no curso no ano. Para EAD, só vem preenchido nas linhas tp_dimensao=2 (por polo) - some todos os polos do curso; a linha tp_dimensao=3 vem zerada neste campo. Ver nota de modelagem no topo do arquivo.',
    qt_conc_fem                INT UNSIGNED NULL COMMENT 'Concluintes do sexo feminino.',
    qt_conc_masc               INT UNSIGNED NULL COMMENT 'Concluintes do sexo masculino.',
    qt_conc_diurno             INT UNSIGNED NULL COMMENT 'Concluintes no turno diurno.',
    qt_conc_noturno            INT UNSIGNED NULL COMMENT 'Concluintes no turno noturno.',
    qt_conc_0_17               INT UNSIGNED NULL COMMENT 'Concluintes com até 17 anos.',
    qt_conc_18_24              INT UNSIGNED NULL COMMENT 'Concluintes de 18 a 24 anos.',
    qt_conc_25_29              INT UNSIGNED NULL COMMENT 'Concluintes de 25 a 29 anos.',
    qt_conc_30_34              INT UNSIGNED NULL COMMENT 'Concluintes de 30 a 34 anos.',
    qt_conc_35_39              INT UNSIGNED NULL COMMENT 'Concluintes de 35 a 39 anos.',
    qt_conc_40_49              INT UNSIGNED NULL COMMENT 'Concluintes de 40 a 49 anos.',
    qt_conc_50_59              INT UNSIGNED NULL COMMENT 'Concluintes de 50 a 59 anos.',
    qt_conc_60_mais            INT UNSIGNED NULL COMMENT 'Concluintes com 60 anos ou mais.',
    qt_conc_branca             INT UNSIGNED NULL COMMENT 'Concluintes de cor/raça branca.',
    qt_conc_preta              INT UNSIGNED NULL COMMENT 'Concluintes de cor/raça preta.',
    qt_conc_parda              INT UNSIGNED NULL COMMENT 'Concluintes de cor/raça parda.',
    qt_conc_amarela            INT UNSIGNED NULL COMMENT 'Concluintes de cor/raça amarela.',
    qt_conc_indigena           INT UNSIGNED NULL COMMENT 'Concluintes de cor/raça indígena.',
    qt_conc_cornd              INT UNSIGNED NULL COMMENT 'Concluintes com cor/raça não declarada.',

    PRIMARY KEY (id),
    UNIQUE KEY uq_estat_grao (co_curso, ano_censo, tp_dimensao, co_municipio),
    CONSTRAINT chk_estat_ano CHECK (ano_censo >= 2009),
    KEY idx_estat_municipio (co_municipio),
    CONSTRAINT fk_estat_curso_hist FOREIGN KEY (co_curso, ano_censo) REFERENCES curso_historico (co_curso, ano_censo),
    CONSTRAINT fk_estat_municipio  FOREIGN KEY (co_municipio)       REFERENCES municipio (co_municipio),
    CONSTRAINT fk_estat_dimensao   FOREIGN KEY (tp_dimensao)        REFERENCES dimensao (co_dimensao)
) ENGINE=InnoDB
  COMMENT='Métricas quantitativas anuais de cada curso (vagas, ingressantes, matrículas, concluintes), com recorte de sexo, turno, faixa etária e cor/raça.';

SET FOREIGN_KEY_CHECKS = 1;
