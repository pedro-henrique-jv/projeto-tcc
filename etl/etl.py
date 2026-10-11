#!/usr/bin/env python3
"""
ETL - Censo da Educação Superior (INEP) -> MariaDB

Uso:
    python etl.py --data-dir ./data --year 2010
    python etl.py --data-dir ./data              # carrega todos os anos encontrados

Espera encontrar em --data-dir arquivos nomeados como:
    MICRODADOS_CADASTRO_IES_<ANO>.CSV  (ou MICRODADOS_ED_SUP_IES_<ANO>.CSV em anos recentes)
    MICRODADOS_CADASTRO_CURSOS_<ANO>.CSV
Busca recursivamente em subpastas (o INEP costuma distribuir 1 pasta por ano).

Variáveis de ambiente (ou .env carregado via python-dotenv, se presente):
    DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME

IMPORTANTE - TP_DIMENSAO / TP_LOC_OFERTA_CURSO:
    Confirmado em 2010 E 2024 (os dois extremos do intervalo 2009-2024)
    que a coluna TP_DIMENSAO existe com os mesmos valores/semântica
    (1=presencial, 2=polo EAD, 3=total Brasil EAD, 4=EAD exterior). O
    fallback para TP_LOC_OFERTA_CURSO abaixo foi mantido por precaução.

IMPORTANTE - regra de agregação de métricas EAD depende da coluna:
    qt_vg_total/qt_inscrito_total -> tp_dimensao IN (1,3)
    qt_ing/qt_mat/qt_conc (e variações) -> tp_dimensao IN (1,2)
    Ver comentário completo em sql/01_schema.sql.

MODELAGEM (v2, após revisão do orientador):
    - Sem tabela ano_censo (era uma dimensão sem atributos próprios).
    - Hierarquia geográfica normalizada em cadeia: regiao -> uf ->
      mesorregiao -> microrregiao -> municipio (antes era tudo achatado
      em municipio, violando 3FN).
    - ies_historico e curso_historico usam chave primária composta
      natural (co_ies+ano_censo / co_curso+ano_censo), sem "id"
      substituto. curso_estatisticas MANTÉM "id" substituto porque parte
      de sua chave natural (co_municipio) pode ser NULL, e uma
      PRIMARY KEY não aceita NULL.
"""
import argparse
import os
import re
import sys

import pandas as pd
import mysql.connector

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

# ---------------------------------------------------------------------
LOC_OFERTA_TO_DIMENSAO = {
    0: 1,   # curso com dado em todas as dimensões geográficas (hipótese)
    1: 3,   # EAD com dados só a nível Brasil
    2: 4,   # EAD ofertado no exterior
}

CORE_CURSO_COLS = [
    "NU_ANO_CENSO", "CO_IES", "CO_CURSO", "CO_MUNICIPIO", "NO_MUNICIPIO",
    "SG_UF", "NO_UF", "CO_UF", "CO_REGIAO", "NO_REGIAO", "IN_CAPITAL",
    "NO_CURSO", "NO_CINE_ROTULO", "CO_CINE_ROTULO",
    "CO_CINE_AREA_GERAL", "NO_CINE_AREA_GERAL",
    "CO_CINE_AREA_ESPECIFICA", "NO_CINE_AREA_ESPECIFICA",
    "CO_CINE_AREA_DETALHADA", "NO_CINE_AREA_DETALHADA",
    "TP_GRAU_ACADEMICO", "TP_MODALIDADE_ENSINO", "TP_NIVEL_ACADEMICO",
    "TP_REDE", "IN_GRATUITO",
    "QT_VG_TOTAL", "QT_VG_TOTAL_DIURNO", "QT_VG_TOTAL_NOTURNO", "QT_VG_TOTAL_EAD",
    "QT_INSCRITO_TOTAL",
    "QT_ING", "QT_ING_FEM", "QT_ING_MASC", "QT_ING_DIURNO", "QT_ING_NOTURNO",
    "QT_ING_0_17", "QT_ING_18_24", "QT_ING_25_29", "QT_ING_30_34", "QT_ING_35_39",
    "QT_ING_40_49", "QT_ING_50_59", "QT_ING_60_MAIS",
    "QT_ING_BRANCA", "QT_ING_PRETA", "QT_ING_PARDA", "QT_ING_AMARELA",
    "QT_ING_INDIGENA", "QT_ING_CORND",
    "QT_MAT", "QT_MAT_FEM", "QT_MAT_MASC", "QT_MAT_DIURNO", "QT_MAT_NOTURNO",
    "QT_MAT_0_17", "QT_MAT_18_24", "QT_MAT_25_29", "QT_MAT_30_34", "QT_MAT_35_39",
    "QT_MAT_40_49", "QT_MAT_50_59", "QT_MAT_60_MAIS",
    "QT_MAT_BRANCA", "QT_MAT_PRETA", "QT_MAT_PARDA", "QT_MAT_AMARELA",
    "QT_MAT_INDIGENA", "QT_MAT_CORND",
    "QT_CONC", "QT_CONC_FEM", "QT_CONC_MASC", "QT_CONC_DIURNO", "QT_CONC_NOTURNO",
    "QT_CONC_0_17", "QT_CONC_18_24", "QT_CONC_25_29", "QT_CONC_30_34", "QT_CONC_35_39",
    "QT_CONC_40_49", "QT_CONC_50_59", "QT_CONC_60_MAIS",
    "QT_CONC_BRANCA", "QT_CONC_PRETA", "QT_CONC_PARDA", "QT_CONC_AMARELA",
    "QT_CONC_INDIGENA", "QT_CONC_CORND",
]

CORE_IES_COLS = [
    "NU_ANO_CENSO", "CO_IES", "NO_IES", "SG_IES",
    "CO_MANTENEDORA", "NO_MANTENEDORA",
    "CO_MUNICIPIO_IES", "NO_MUNICIPIO_IES", "SG_UF_IES", "NO_UF_IES", "CO_UF_IES",
    "CO_REGIAO_IES", "NO_REGIAO_IES", "IN_CAPITAL_IES",
    "NO_MESORREGIAO_IES", "CO_MESORREGIAO_IES", "NO_MICRORREGIAO_IES", "CO_MICRORREGIAO_IES",
    "TP_ORGANIZACAO_ACADEMICA", "TP_CATEGORIA_ADMINISTRATIVA",
    "DS_ENDERECO_IES", "DS_NUMERO_ENDERECO_IES", "DS_COMPLEMENTO_ENDERECO_IES",
    "NO_BAIRRO_IES", "NU_CEP_IES",
    "QT_DOC_TOTAL", "QT_DOC_EXE", "QT_DOC_EX_FEMI", "QT_DOC_EX_MASC",
    "QT_DOC_EX_GRAD", "QT_DOC_EX_ESP", "QT_DOC_EX_MEST", "QT_DOC_EX_DOUT",
    "QT_DOC_EX_INT_DE", "QT_DOC_EX_INT_SEM_DE", "QT_DOC_EX_PARC", "QT_DOC_EX_HOR",
    "QT_DOC_EX_BRANCA", "QT_DOC_EX_PRETA", "QT_DOC_EX_PARDA", "QT_DOC_EX_AMARELA",
    "QT_DOC_EX_INDIGENA", "QT_DOC_EX_COR_ND",
    "QT_TEC_TOTAL",
]

OPTIONAL_IES_COLS = ["TP_REDE", "IN_COMUNITARIA", "IN_CONFESSIONAL"]


def ensure_columns(df: pd.DataFrame, expected_cols, year: int, label: str) -> pd.DataFrame:
    missing = [c for c in expected_cols if c not in df.columns]
    if missing:
        print(f"[{year}] AVISO ({label}): colunas ausentes neste layout, preenchidas com NULL: {missing}")
        for c in missing:
            df[c] = None
    return df


def get_conn():
    return mysql.connector.connect(
        host=os.getenv("DB_HOST", "127.0.0.1"),
        port=int(os.getenv("DB_PORT", "3306")),
        user=os.getenv("DB_USER", "censo_user"),
        password=os.getenv("DB_PASSWORD", ""),
        database=os.getenv("DB_NAME", "censo_educacao_superior"),
        autocommit=False,
    )


def executemany_batched(cur, sql, rows, batch_size=5000):
    for i in range(0, len(rows), batch_size):
        cur.executemany(sql, rows[i:i + batch_size])


def clean_value(v):
    if pd.isna(v):
        return None
    if isinstance(v, str):
        v = v.strip().strip('"')
    if v in ("", ".", ".."):
        return None
    return v


def read_csv_inep(path: str, usecols=None) -> pd.DataFrame:
    df = pd.read_csv(path, sep=";", encoding="latin1", usecols=usecols, dtype=object)
    for col in df.columns:
        df[col] = [clean_value(v) for v in df[col].tolist()]
    return df


def sv(x):
    return None if pd.isna(x) else str(x)


def iv(x):
    if pd.isna(x) or x == "":
        return None
    return int(float(x))


# ---------------------------------------------------------------------
# GEOGRAFIA: regiao -> uf -> mesorregiao -> microrregiao -> municipio
# Função compartilhada por load_ies e load_cursos, já que ambos os
# arquivos trazem (parcialmente) dados geográficos.
# ---------------------------------------------------------------------
def upsert_geografia(cur, df, prefix_municipio, prefix_regiao=None, prefix_meso=None, prefix_micro=None):
    """Faz upsert em regiao/uf/mesorregiao/microrregiao/municipio a
    partir de colunas com um prefixo comum (ex: '' para o arquivo de
    cursos, '' também para IES já que os nomes de coluna já vêm com
    sufixo _IES tratado por quem chama). Colunas de meso/micro são
    opcionais (só existem no arquivo de IES)."""

    cols_regiao = ["CO_REGIAO", "NO_REGIAO"]
    cols_uf = ["CO_UF", "SG_UF", "NO_UF", "CO_REGIAO"]
    cols_mun = ["CO_MUNICIPIO", "NO_MUNICIPIO", "IN_CAPITAL", "CO_UF"]

    def col(name):
        return df[name] if name in df.columns else pd.Series([None] * len(df))

    # --- regiao ---
    reg = df[[c for c in cols_regiao if c in df.columns]].dropna(subset=["CO_REGIAO"]).drop_duplicates(subset=["CO_REGIAO"])
    if len(reg):
        sql = """
            INSERT INTO regiao (co_regiao, no_regiao) VALUES (%s, %s)
            ON DUPLICATE KEY UPDATE no_regiao = COALESCE(VALUES(no_regiao), no_regiao)
        """
        rows = [(iv(r.CO_REGIAO), sv(r.NO_REGIAO)) for r in reg.itertuples() if iv(r.CO_REGIAO) is not None]
        if rows:
            executemany_batched(cur, sql, rows)

    # --- uf ---
    uf_cols_present = [c for c in cols_uf if c in df.columns]
    uf = df[uf_cols_present].dropna(subset=["CO_UF"]).drop_duplicates(subset=["CO_UF"])
    if len(uf):
        sql = """
            INSERT INTO uf (co_uf, sg_uf, no_uf, co_regiao) VALUES (%s, %s, %s, %s)
            ON DUPLICATE KEY UPDATE
                sg_uf = COALESCE(VALUES(sg_uf), sg_uf),
                no_uf = COALESCE(VALUES(no_uf), no_uf),
                co_regiao = COALESCE(VALUES(co_regiao), co_regiao)
        """
        rows = []
        for r in uf.itertuples():
            co_uf = iv(r.CO_UF)
            if co_uf is None:
                continue
            rows.append((co_uf, sv(getattr(r, "SG_UF", None)), sv(getattr(r, "NO_UF", None)), iv(getattr(r, "CO_REGIAO", None))))
        if rows:
            executemany_batched(cur, sql, rows)

    # --- mesorregiao / microrregiao (só existem no arquivo de IES) ---
    # IMPORTANTE: CO_MESORREGIAO/CO_MICRORREGIAO no arquivo do INEP são
    # sequenciais DENTRO DA UF (ex: "mesorregião nº 3 do RS"), não o
    # código IBGE nacional. Usados "crus", colidem entre estados
    # diferentes (mesorregião 3 do RS != mesorregião 3 do Rio de
    # Janeiro, mas ambas virariam co_mesorregiao=3). A fórmula abaixo
    # reconstrói o código oficial do IBGE (confirmado batendo com
    # códigos reais, ex: Metropolitana de SP = 35*100+15 = 3515).
    if "CO_MESORREGIAO" in df.columns:
        meso = df[["CO_MESORREGIAO", "NO_MESORREGIAO", "CO_UF"]].dropna(subset=["CO_MESORREGIAO", "CO_UF"]).drop_duplicates(subset=["CO_MESORREGIAO", "CO_UF"])
        if len(meso):
            sql = """
                INSERT INTO mesorregiao (co_mesorregiao, no_mesorregiao, co_uf) VALUES (%s, %s, %s)
                ON DUPLICATE KEY UPDATE
                    no_mesorregiao = COALESCE(VALUES(no_mesorregiao), no_mesorregiao),
                    co_uf = COALESCE(VALUES(co_uf), co_uf)
            """
            rows = []
            for r in meso.itertuples():
                cm_local = iv(r.CO_MESORREGIAO)
                cuf = iv(r.CO_UF)
                if cm_local is None or cuf is None:
                    continue
                co_mesorregiao_real = cuf * 100 + cm_local
                rows.append((co_mesorregiao_real, sv(r.NO_MESORREGIAO), cuf))
            if rows:
                executemany_batched(cur, sql, rows)

    if "CO_MICRORREGIAO" in df.columns:
        micro = df[["CO_MICRORREGIAO", "NO_MICRORREGIAO", "CO_MESORREGIAO", "CO_UF"]].dropna(subset=["CO_MICRORREGIAO", "CO_MESORREGIAO", "CO_UF"]).drop_duplicates(subset=["CO_MICRORREGIAO", "CO_UF"])
        if len(micro):
            sql = """
                INSERT INTO microrregiao (co_microrregiao, no_microrregiao, co_mesorregiao) VALUES (%s, %s, %s)
                ON DUPLICATE KEY UPDATE
                    no_microrregiao = COALESCE(VALUES(no_microrregiao), no_microrregiao),
                    co_mesorregiao = COALESCE(VALUES(co_mesorregiao), co_mesorregiao)
            """
            rows = []
            for r in micro.itertuples():
                cmi_local = iv(r.CO_MICRORREGIAO)
                cme_local = iv(r.CO_MESORREGIAO)
                cuf = iv(r.CO_UF)
                if cmi_local is None or cme_local is None or cuf is None:
                    continue
                co_microrregiao_real = cuf * 1000 + cmi_local
                co_mesorregiao_real = cuf * 100 + cme_local
                rows.append((co_microrregiao_real, sv(r.NO_MICRORREGIAO), co_mesorregiao_real))
            if rows:
                executemany_batched(cur, sql, rows)

    # --- municipio ---
    mun_cols = [c for c in ["CO_MUNICIPIO", "NO_MUNICIPIO", "IN_CAPITAL", "CO_UF", "CO_MICRORREGIAO"] if c in df.columns]
    mun = df[mun_cols].dropna(subset=["CO_MUNICIPIO"]).drop_duplicates(subset=["CO_MUNICIPIO"])
    if len(mun):
        has_micro = "CO_MICRORREGIAO" in mun.columns
        sql = """
            INSERT INTO municipio (co_municipio, no_municipio, in_capital, co_uf, co_microrregiao)
            VALUES (%s, %s, %s, %s, %s)
            ON DUPLICATE KEY UPDATE
                no_municipio = COALESCE(VALUES(no_municipio), no_municipio),
                in_capital = COALESCE(VALUES(in_capital), in_capital),
                co_uf = COALESCE(VALUES(co_uf), co_uf),
                co_microrregiao = COALESCE(VALUES(co_microrregiao), co_microrregiao)
        """
        rows = []
        for r in mun.itertuples():
            cm = iv(r.CO_MUNICIPIO)
            if cm is None:
                continue
            co_uf_val = iv(getattr(r, "CO_UF", None))
            micro_val = None
            if has_micro and co_uf_val is not None:
                micro_local = iv(getattr(r, "CO_MICRORREGIAO", None))
                if micro_local is not None:
                    micro_val = co_uf_val * 1000 + micro_local  # reconstrói código IBGE real - ver nota em mesorregiao/microrregiao
            rows.append((cm, sv(getattr(r, "NO_MUNICIPIO", None)), iv(getattr(r, "IN_CAPITAL", None)), co_uf_val, micro_val))
        if rows:
            executemany_batched(cur, sql, rows)


# ---------------------------------------------------------------------
# IES
# ---------------------------------------------------------------------
def load_ies(conn, year: int, csv_path: str):
    print(f"[{year}] Lendo {csv_path} ...")
    cols = set(CORE_IES_COLS)
    df = read_csv_inep(csv_path, usecols=lambda c: c in cols)
    df = ensure_columns(df, CORE_IES_COLS, year, "IES")
    print(f"[{year}] {len(df)} linhas de IES")

    all_header = pd.read_csv(csv_path, sep=";", encoding="latin1", nrows=0).columns
    present_optional = [c for c in OPTIONAL_IES_COLS if c in all_header]
    if present_optional:
        df_opt = read_csv_inep(csv_path, usecols=lambda c: c in present_optional)
        for c in present_optional:
            df[c] = df_opt[c].values
    for c in OPTIONAL_IES_COLS:
        if c not in df.columns:
            df[c] = None

    cur = conn.cursor()

    # --- geografia (regiao/uf/mesorregiao/microrregiao/municipio) ---
    geo_df = df.rename(columns={
        "CO_MUNICIPIO_IES": "CO_MUNICIPIO", "NO_MUNICIPIO_IES": "NO_MUNICIPIO",
        "SG_UF_IES": "SG_UF", "NO_UF_IES": "NO_UF", "CO_UF_IES": "CO_UF",
        "CO_REGIAO_IES": "CO_REGIAO", "NO_REGIAO_IES": "NO_REGIAO", "IN_CAPITAL_IES": "IN_CAPITAL",
        "NO_MESORREGIAO_IES": "NO_MESORREGIAO", "CO_MESORREGIAO_IES": "CO_MESORREGIAO",
        "NO_MICRORREGIAO_IES": "NO_MICRORREGIAO", "CO_MICRORREGIAO_IES": "CO_MICRORREGIAO",
    })
    upsert_geografia(cur, geo_df, "municipio")
    conn.commit()

    # --- mantenedora ---
    mant = df[["CO_MANTENEDORA", "NO_MANTENEDORA"]].dropna(subset=["CO_MANTENEDORA"]).drop_duplicates(subset=["CO_MANTENEDORA"])
    sql_mant = """
        INSERT INTO mantenedora (co_mantenedora, no_mantenedora)
        VALUES (%s, %s)
        ON DUPLICATE KEY UPDATE no_mantenedora = COALESCE(VALUES(no_mantenedora), no_mantenedora)
    """
    rows = [(iv(r.CO_MANTENEDORA), sv(r.NO_MANTENEDORA)) for r in mant.itertuples()]
    if rows:
        executemany_batched(cur, sql_mant, rows)

    # --- ies (chave lógica) ---
    ies_ids = df[["CO_IES"]].dropna().drop_duplicates()
    sql_ies = """
        INSERT INTO ies (co_ies, primeiro_ano, ultimo_ano)
        VALUES (%s, %s, %s)
        ON DUPLICATE KEY UPDATE
            primeiro_ano = LEAST(primeiro_ano, VALUES(primeiro_ano)),
            ultimo_ano = GREATEST(ultimo_ano, VALUES(ultimo_ano))
    """
    rows = [(int(r.CO_IES), year, year) for r in ies_ids.itertuples()]
    if rows:
        executemany_batched(cur, sql_ies, rows)

    # --- ies_historico (chave primária composta co_ies+ano_censo) ---
    sql_hist = """
        INSERT INTO ies_historico (
            co_ies, ano_censo, co_mantenedora, co_municipio,
            no_ies, sg_ies, tp_organizacao_academica, tp_categoria_administrativa,
            tp_rede, in_comunitaria, in_confessional,
            ds_endereco_ies, ds_numero_endereco_ies, ds_complemento_endereco_ies,
            no_bairro_ies, nu_cep_ies,
            qt_doc_total, qt_doc_exe, qt_doc_ex_femi, qt_doc_ex_masc,
            qt_doc_ex_grad, qt_doc_ex_esp, qt_doc_ex_mest, qt_doc_ex_dout,
            qt_doc_ex_int_de, qt_doc_ex_int_sem_de, qt_doc_ex_parc, qt_doc_ex_hor,
            qt_doc_ex_branca, qt_doc_ex_preta, qt_doc_ex_parda, qt_doc_ex_amarela,
            qt_doc_ex_indigena, qt_doc_ex_cor_nd, qt_tec_total
        ) VALUES (
            %s,%s,%s,%s, %s,%s,%s,%s, %s,%s,%s, %s,%s,%s, %s,%s,
            %s,%s,%s,%s, %s,%s,%s,%s, %s,%s,%s,%s,
            %s,%s,%s,%s, %s,%s,%s
        )
        ON DUPLICATE KEY UPDATE co_ies = co_ies  -- idempotente: mesmo (co_ies,ano_censo) não é recarregado
    """
    rows = []
    for r in df.itertuples():
        rows.append((
            iv(r.CO_IES), year, iv(r.CO_MANTENEDORA), iv(r.CO_MUNICIPIO_IES),
            sv(r.NO_IES), sv(r.SG_IES), iv(r.TP_ORGANIZACAO_ACADEMICA), iv(r.TP_CATEGORIA_ADMINISTRATIVA),
            iv(r.TP_REDE), iv(r.IN_COMUNITARIA), iv(r.IN_CONFESSIONAL),
            sv(r.DS_ENDERECO_IES), sv(r.DS_NUMERO_ENDERECO_IES), sv(r.DS_COMPLEMENTO_ENDERECO_IES),
            sv(r.NO_BAIRRO_IES), sv(r.NU_CEP_IES),
            iv(r.QT_DOC_TOTAL), iv(r.QT_DOC_EXE), iv(r.QT_DOC_EX_FEMI), iv(r.QT_DOC_EX_MASC),
            iv(r.QT_DOC_EX_GRAD), iv(r.QT_DOC_EX_ESP), iv(r.QT_DOC_EX_MEST), iv(r.QT_DOC_EX_DOUT),
            iv(r.QT_DOC_EX_INT_DE), iv(r.QT_DOC_EX_INT_SEM_DE), iv(r.QT_DOC_EX_PARC), iv(r.QT_DOC_EX_HOR),
            iv(r.QT_DOC_EX_BRANCA), iv(r.QT_DOC_EX_PRETA), iv(r.QT_DOC_EX_PARDA), iv(r.QT_DOC_EX_AMARELA),
            iv(r.QT_DOC_EX_INDIGENA), iv(r.QT_DOC_EX_COR_ND), iv(r.QT_TEC_TOTAL),
        ))
    executemany_batched(cur, sql_hist, rows)
    conn.commit()
    print(f"[{year}] IES carregadas: {len(rows)}")
    cur.close()


# ---------------------------------------------------------------------
# CURSOS
# ---------------------------------------------------------------------
def resolve_dimensao(row) -> int:
    dim = iv(getattr(row, "TP_DIMENSAO", None))
    if dim is not None:
        return dim
    loc = iv(getattr(row, "TP_LOC_OFERTA_CURSO", None))
    if loc is not None:
        return LOC_OFERTA_TO_DIMENSAO.get(loc, 1)
    return 1


def load_cursos(conn, year: int, csv_path: str):
    print(f"[{year}] Lendo {csv_path} ...")
    wanted = set(CORE_CURSO_COLS) | {"TP_DIMENSAO", "TP_LOC_OFERTA_CURSO"}
    df = read_csv_inep(csv_path, usecols=lambda c: c in wanted)
    df = ensure_columns(df, CORE_CURSO_COLS, year, "CURSOS")
    print(f"[{year}] {len(df)} linhas de curso (todas as dimensões)")

    # TP_GRAU_ACADEMICO=0: código não documentado no dicionário oficial do
    # INEP (que só prevê 1-4 e "." para não aplicável). Visto em 2022, em
    # ~0.25% das linhas, majoritariamente em cursos de Graduação normal (não
    # bate com a exceção documentada de "não aplicável" para sequenciais).
    # Tratado como desconhecido (NULL) por segurança, já que não há como
    # confirmar o significado real. NÃO generalizar para outros campos -
    # 0 é um valor válido em colunas booleanas como IN_GRATUITO.
    if "TP_GRAU_ACADEMICO" in df.columns:
        qtd_zero = (df["TP_GRAU_ACADEMICO"] == "0").sum()
        if qtd_zero:
            print(f"[{year}] AVISO: {qtd_zero} linhas com TP_GRAU_ACADEMICO='0' (código não documentado) - tratadas como NULL.")
            df.loc[df["TP_GRAU_ACADEMICO"] == "0", "TP_GRAU_ACADEMICO"] = None

    cur = conn.cursor()

    # --- geografia (o arquivo de cursos cobre polos EAD que não são sede de IES) ---
    upsert_geografia(cur, df, "municipio")
    conn.commit()

    # --- cine_area_geral / cine_area_especifica (dependência funcional
    #     código->nome confirmada empiricamente, sem exceções) ---
    geral = df[["CO_CINE_AREA_GERAL", "NO_CINE_AREA_GERAL"]].dropna(subset=["CO_CINE_AREA_GERAL"]).drop_duplicates(subset=["CO_CINE_AREA_GERAL"])
    if len(geral):
        sql = """
            INSERT INTO cine_area_geral (co_cine_area_geral, no_cine_area_geral) VALUES (%s, %s)
            ON DUPLICATE KEY UPDATE no_cine_area_geral = COALESCE(VALUES(no_cine_area_geral), no_cine_area_geral)
        """
        rows = [(iv(r.CO_CINE_AREA_GERAL), sv(r.NO_CINE_AREA_GERAL)) for r in geral.itertuples() if iv(r.CO_CINE_AREA_GERAL) is not None]
        if rows:
            executemany_batched(cur, sql, rows)

    especifica = df[["CO_CINE_AREA_ESPECIFICA", "NO_CINE_AREA_ESPECIFICA", "CO_CINE_AREA_GERAL"]].dropna(subset=["CO_CINE_AREA_ESPECIFICA", "CO_CINE_AREA_GERAL"]).drop_duplicates(subset=["CO_CINE_AREA_ESPECIFICA"])
    if len(especifica):
        sql = """
            INSERT INTO cine_area_especifica (co_cine_area_especifica, no_cine_area_especifica, co_cine_area_geral) VALUES (%s, %s, %s)
            ON DUPLICATE KEY UPDATE
                no_cine_area_especifica = COALESCE(VALUES(no_cine_area_especifica), no_cine_area_especifica),
                co_cine_area_geral = COALESCE(VALUES(co_cine_area_geral), co_cine_area_geral)
        """
        rows = []
        for r in especifica.itertuples():
            ce = iv(r.CO_CINE_AREA_ESPECIFICA)
            cg = iv(r.CO_CINE_AREA_GERAL)
            if ce is None or cg is None:
                continue
            rows.append((ce, sv(r.NO_CINE_AREA_ESPECIFICA), cg))
        if rows:
            executemany_batched(cur, sql, rows)

    # --- cine_area_detalhada / cine_area_rotulo: normalizados
    #     mesmo com 2 exceções conhecidas na dependência código->nome
    #     (ver nota em sql/01_schema.sql) - "ano mais recente vence",
    #     que já é o comportamento natural deste padrão de upsert.
    #     Cadeia completa: nivel3 aponta pra nivel2, nivel4 aponta pra
    #     nivel3 (confirmado empiricamente: sem exceções).
    detalhada = df[["CO_CINE_AREA_DETALHADA", "NO_CINE_AREA_DETALHADA", "CO_CINE_AREA_ESPECIFICA"]].dropna(subset=["CO_CINE_AREA_DETALHADA", "CO_CINE_AREA_ESPECIFICA"]).drop_duplicates(subset=["CO_CINE_AREA_DETALHADA"])
    if len(detalhada):
        sql = """
            INSERT INTO cine_area_detalhada (co_cine_area_detalhada, no_cine_area_detalhada, co_cine_area_especifica) VALUES (%s, %s, %s)
            ON DUPLICATE KEY UPDATE
                no_cine_area_detalhada = COALESCE(VALUES(no_cine_area_detalhada), no_cine_area_detalhada),
                co_cine_area_especifica = COALESCE(VALUES(co_cine_area_especifica), co_cine_area_especifica)
        """
        rows = []
        for r in detalhada.itertuples():
            cd = iv(r.CO_CINE_AREA_DETALHADA)
            ce = iv(r.CO_CINE_AREA_ESPECIFICA)
            if cd is None or ce is None:
                continue
            rows.append((cd, sv(r.NO_CINE_AREA_DETALHADA), ce))
        if rows:
            executemany_batched(cur, sql, rows)

    rotulo = df[["CO_CINE_ROTULO", "NO_CINE_ROTULO", "CO_CINE_AREA_DETALHADA"]].dropna(subset=["CO_CINE_ROTULO", "CO_CINE_AREA_DETALHADA"]).drop_duplicates(subset=["CO_CINE_ROTULO"])
    if len(rotulo):
        sql = """
            INSERT INTO cine_area_rotulo (co_cine_area_rotulo, no_cine_area_rotulo, co_cine_area_detalhada) VALUES (%s, %s, %s)
            ON DUPLICATE KEY UPDATE
                no_cine_area_rotulo = COALESCE(VALUES(no_cine_area_rotulo), no_cine_area_rotulo),
                co_cine_area_detalhada = COALESCE(VALUES(co_cine_area_detalhada), co_cine_area_detalhada)
        """
        rows = []
        for r in rotulo.itertuples():
            cr = sv(r.CO_CINE_ROTULO)
            cd = iv(r.CO_CINE_AREA_DETALHADA)
            if cr is None or cd is None:
                continue
            rows.append((cr, sv(r.NO_CINE_ROTULO), cd))
        if rows:
            executemany_batched(cur, sql, rows)
    conn.commit()

    # --- curso (chave lógica) ---
    curso_ids = df[["CO_CURSO"]].dropna().drop_duplicates()
    sql_curso = """
        INSERT INTO curso (co_curso, primeiro_ano, ultimo_ano)
        VALUES (%s, %s, %s)
        ON DUPLICATE KEY UPDATE
            primeiro_ano = LEAST(primeiro_ano, VALUES(primeiro_ano)),
            ultimo_ano = GREATEST(ultimo_ano, VALUES(ultimo_ano))
    """
    rows = [(int(r.CO_CURSO), year, year) for r in curso_ids.itertuples()]
    if rows:
        executemany_batched(cur, sql_curso, rows)
    conn.commit()

    # --- quais co_ies existem em ies_historico deste ano? (checagem de
    #     existência antes de inserir curso_historico, já que agora a
    #     FK é composta co_ies+ano_censo direto, sem passar por um
    #     "id" intermediário) ---
    cur.execute("SELECT co_ies FROM ies_historico WHERE ano_censo = %s", (year,))
    ies_existentes = {row[0] for row in cur.fetchall()}

    # --- curso_historico: 1 linha por curso (usa a linha de maior prioridade:
    #     presencial (1) > total Brasil EAD (3) > 1a linha de polo (2) > exterior (4)) ---
    df["dimensao_calc"] = [resolve_dimensao(r) for r in df.itertuples()]
    prioridade = {1: 0, 3: 1, 2: 2, 4: 3}
    df["prioridade_calc"] = df["dimensao_calc"].map(prioridade)
    descritiva = df.sort_values("prioridade_calc").drop_duplicates(subset=["CO_CURSO"], keep="first")

    sql_curso_hist = """
        INSERT INTO curso_historico (
            co_curso, ano_censo, co_ies,
            no_curso, co_cine_area_rotulo,
            tp_grau_academico, tp_modalidade_ensino, tp_nivel_academico,
            tp_rede, in_gratuito
        ) VALUES (%s,%s,%s, %s,%s, %s,%s,%s, %s,%s)
        ON DUPLICATE KEY UPDATE co_curso = co_curso
    """
    curso_hist_rows = []
    cursos_validos = set()
    skipped_no_ies = 0
    for r in descritiva.itertuples():
        co_ies = iv(r.CO_IES)
        if co_ies is None or co_ies not in ies_existentes:
            skipped_no_ies += 1
            continue
        co_curso = iv(r.CO_CURSO)
        cursos_validos.add(co_curso)
        curso_hist_rows.append((
            co_curso, year, co_ies,
            sv(r.NO_CURSO), sv(r.CO_CINE_ROTULO),
            iv(r.TP_GRAU_ACADEMICO), iv(r.TP_MODALIDADE_ENSINO), iv(r.TP_NIVEL_ACADEMICO),
            iv(r.TP_REDE), iv(r.IN_GRATUITO),
        ))
    if curso_hist_rows:
        executemany_batched(cur, sql_curso_hist, curso_hist_rows)
    conn.commit()
    if skipped_no_ies:
        print(f"[{year}] AVISO: {skipped_no_ies} cursos ignorados por IES não encontrada em ies_historico do ano.")

    # --- curso_estatisticas: TODAS as linhas (presencial + polos + total Brasil) ---
    # Estratégia DELETE + INSERT: como curso_estatisticas agora referencia
    # curso_historico via (co_curso, ano_censo) direto, o DELETE nem
    # precisa mais de JOIN - filtra direto por ano_censo.
    cur.execute("DELETE FROM curso_estatisticas WHERE ano_censo = %s", (year,))
    conn.commit()

    qt_cols = [c for c in CORE_CURSO_COLS if c.startswith("QT_")]
    sql_estat = f"""
        INSERT INTO curso_estatisticas (
            co_curso, ano_censo, tp_dimensao, co_municipio, {", ".join(c.lower() for c in qt_cols)}
        ) VALUES (%s,%s,%s,%s, {", ".join(["%s"] * len(qt_cols))})
    """
    estat_rows = []
    skipped_no_curso = 0
    for r in df.itertuples():
        co_curso = iv(r.CO_CURSO)
        if co_curso not in cursos_validos:
            skipped_no_curso += 1
            continue
        dimensao = r.dimensao_calc
        municipio = iv(r.CO_MUNICIPIO) if dimensao in (1, 2) else None
        values = [co_curso, year, dimensao, municipio] + [iv(getattr(r, c)) for c in qt_cols]
        estat_rows.append(tuple(values))
    if estat_rows:
        executemany_batched(cur, sql_estat, estat_rows)
    conn.commit()
    if skipped_no_curso:
        print(f"[{year}] AVISO: {skipped_no_curso} linhas de estatística ignoradas (curso sem curso_historico).")

    print(f"[{year}] curso_historico: {len(curso_hist_rows)} | curso_estatisticas: {len(estat_rows)}")
    cur.close()


def find_year_files(data_dir: str):
    """Retorna dict {ano: {'ies': path, 'cursos': path}}. Busca
    recursivamente (o INEP costuma ter 1 subpasta por ano)."""
    years = {}
    for root, _dirs, files in os.walk(data_dir):
        for fname in files:
            name = fname.upper()
            path = os.path.join(root, fname)
            if re.search(r"CADASTRO_IES_(\d{4})\.CSV$", name) or re.search(r"ED_SUP_IES_(\d{4})\.CSV$", name):
                m = re.search(r"IES_(\d{4})\.CSV$", name)
                years.setdefault(int(m.group(1)), {})["ies"] = path
                continue
            m = re.search(r"CADASTRO_CURSOS_(\d{4})\.CSV$", name)
            if m:
                years.setdefault(int(m.group(1)), {})["cursos"] = path
    return years


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", default="./data")
    ap.add_argument("--year", type=int, default=None, help="Carrega só este ano; por padrão carrega todos encontrados.")
    args = ap.parse_args()

    years = find_year_files(args.data_dir)
    if args.year:
        years = {args.year: years[args.year]} if args.year in years else {}

    if not years:
        print(f"Nenhum par de arquivos MICRODADOS_CADASTRO_IES_<ano>.CSV / "
              f"MICRODADOS_CADASTRO_CURSOS_<ano>.CSV encontrado em {args.data_dir}", file=sys.stderr)
        sys.exit(1)

    conn = get_conn()
    for year in sorted(years):
        files = years[year]
        if "ies" not in files or "cursos" not in files:
            print(f"[{year}] AVISO: par incompleto de arquivos, pulando.", file=sys.stderr)
            continue
        load_ies(conn, year, files["ies"])       # precisa rodar antes (curso_historico referencia ies_historico)
        load_cursos(conn, year, files["cursos"])
    conn.close()
    print("ETL concluído.")


if __name__ == "__main__":
    main()
