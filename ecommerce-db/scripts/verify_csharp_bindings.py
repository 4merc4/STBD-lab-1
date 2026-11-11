#!/usr/bin/env python3
"""
Статична звірка C#-коду з реальною БД (без компіляції .NET).

Перевіряє:
  1. кожен CALL sp_xxx(...) з репозиторіїв: процедура існує, кількість і типи
     аргументів (за сигнатурою методу) підходять, останній параметр - INOUT для CallForIdAsync;
  2. кожен SELECT із розрізів/функцій виконується, а всі колонки, які читає код
     (r.Long("col"), r.Str("col") ...), існують у результаті й мають сумісний тип.

Запуск:  PGHOST=... PGPORT=... PGUSER=... python3 scripts/verify_csharp_bindings.py [ім'я_бд]
"""
import re, subprocess, sys, pathlib

DB = sys.argv[1] if len(sys.argv) > 1 else "ecommerce"
ROOT = pathlib.Path(__file__).resolve().parent.parent / "src" / "EcommerceApp" / "Repositories"

def psql(sql):
    p = subprocess.run(["psql", "-X", "-q", "-At", "-F", "|", "-d", DB, "-c", sql],
                       capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()

CLR_TO_PG = {"long": "bigint", "long?": "bigint", "int": "integer", "int?": "integer",
             "string": "text", "string?": "text", "decimal": "numeric", "bool": "boolean"}
HELPER_TYPES = {"Long": {"int8"}, "LongN": {"int8"}, "Int": {"int4"}, "Str": {"text", "varchar", "bpchar"},
                "StrN": {"text", "varchar", "bpchar"}, "Dec": {"numeric"}, "DecN": {"numeric"},
                "Bool": {"bool"}, "Float": {"float4"}, "Time": {"timestamptz"}, "TimeN": {"timestamptz"}}

errors, checked_calls, checked_queries = [], 0, 0

# ---------------------------------------------------------------- 1. CALL ----
call_re = re.compile(
    r"public\s+(?:async\s+)?Task(?:<[^>]+>)?\s+(\w+)\(([^)]*)\)\s*=>\s*(CallForIdAsync|CallAsync)\(\s*\"(sp_\w+)\"\s*,?([^;]*?)\);",
    re.S)
for f in sorted(ROOT.glob("*Repository.cs")):
    text = f.read_text(encoding="utf-8")
    for m in call_re.finditer(text):
        method, sig, kind, proc, args = m.groups()
        params = {}
        for part in [p.strip() for p in sig.split(",") if p.strip()]:
            tokens = part.split("=")[0].split()
            params[tokens[-1]] = tokens[-2]
        arg_names = [a.strip() for a in args.split(",") if a.strip()]
        pg_types = []
        for a in arg_names:
            clr = params.get(a)
            if clr is None:
                errors.append(f"{f.name}:{method}: аргумент '{a}' не є параметром методу")
                continue
            pg_types.append(CLR_TO_PG[clr])
        literals = [f"NULL::{t}" for t in pg_types]
        if kind == "CallForIdAsync":
            literals.append("NULL::bigint")
        sql = f"SET search_path TO shop, public; CALL {proc}({', '.join(literals)});"
        rc, out, err = psql(sql)
        checked_calls += 1
        if "does not exist" in err and "procedure" in err:
            errors.append(f"{f.name}:{method}: {proc} - не знайдено сигнатуру ({', '.join(literals)})")
        # перевірка режиму останнього параметра
        if kind == "CallForIdAsync":
            _, modes, _ = psql(f"SELECT proargmodes FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace "
                               f"WHERE n.nspname='shop' AND proname='{proc}'")
            if not modes.endswith("b}"):
                errors.append(f"{f.name}:{method}: {proc} - останній параметр не INOUT")

# ------------------------------------------------------------- 2. SELECT -----
def string_literals(text):
    for m in re.finditer(r'@"((?:[^"]|"")*)"|"((?:[^"\\]|\\.)*)"', text):
        yield m.group(1) if m.group(1) is not None else m.group(2)

for f in sorted(ROOT.glob("*Repository.cs")):
    text = f.read_text(encoding="utf-8")
    named_mappers = {m.group(1): m.group(2)
                     for m in re.finditer(r"static \w+ (Map\w+)\(NpgsqlDataReader r\) => new\((.*?)\);", text, re.S)}
    const_selects = {m.group(1): m.group(2)
                     for m in re.finditer(r'const string (\w+) = @"((?:[^"]|"")*)";', text)}
    const_mapper = {"UserSelect": "MapUser", "StoreSelect": "MapStore", "CatalogSelect": "MapCatalog", "OrderSelect": "MapOrder"}

    # (sql, текст мапера)
    units = []
    for name, sql in const_selects.items():
        units.append((name, sql, named_mappers[const_mapper[name]]))
    # inline-запити: літерал із SELECT, за яким іде лямбда r => new Dto(...)
    for m in re.finditer(r'(@"(?:[^"]|"")*"|"[^"\n]*")\s*,\s*(r\s*=>.*?)(?=\)\s*;|\)\s*,\s*\(|\)\)\s*;|;)', text, re.S):
        lit, lam = m.groups()
        sql = lit[2:-1] if lit.startswith('@"') else lit[1:-1]
        if "SELECT" in sql.upper():
            units.append(("inline", sql, lam))

    for name, sql, mapper in units:
        dummy = lambda mm: "'x'" if mm.group(1) in ("email", "slug", "q") else "1"
        sql_exec = re.sub(r"@(\w+)", dummy, sql.replace('""', '"')).strip()
        rc, out, err = psql(f"SET search_path TO shop, public; CREATE TEMP VIEW _chk AS {sql_exec}; "
                            f"SELECT column_name, udt_name FROM information_schema.columns "
                            f"WHERE table_schema LIKE 'pg_temp%' AND table_name='_chk' ORDER BY ordinal_position")
        checked_queries += 1
        if rc != 0:
            errors.append(f"{f.name}: запит не виконується: {err.splitlines()[0] if err else '?'}  ->  {sql_exec[:90]!r}")
            continue
        cols = {}
        for line in out.splitlines():
            if "|" in line:
                c, t = line.split("|")
                cols[c] = t
        for helper, col in re.findall(r'\.(Long|LongN|Int|Str|StrN|Dec|DecN|Bool|Float|Time|TimeN)\("(\w+)"\)', mapper):
            if col not in cols:
                errors.append(f"{f.name}: колонки '{col}' немає в результаті запиту ({', '.join(cols)})")
            elif cols[col] not in HELPER_TYPES[helper]:
                errors.append(f"{f.name}: колонка '{col}' має тип {cols[col]}, а читається як {helper}")

print(f"Перевірено викликів процедур: {checked_calls}, запитів: {checked_queries}")
if errors:
    print("ПРОБЛЕМИ:")
    for e in errors:
        print("  -", e)
    sys.exit(1)
print("OK: усі виклики та колонки узгоджені з БД")
