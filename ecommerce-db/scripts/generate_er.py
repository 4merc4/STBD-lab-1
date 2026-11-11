#!/usr/bin/env python3
"""
Генерує ER-діаграму зі справжньої БД:
  docs/schema.dbml      - вставити на https://dbdiagram.io (Import / редактор) -> інтерактивна діаграма
  docs/er_diagram.dot   - Graphviz
  docs/er_diagram.svg/png (якщо встановлено graphviz `dot`)

Запуск:  PGHOST=... PGPORT=... PGUSER=... python3 scripts/generate_er.py [ім'я_бд]
"""
import subprocess, sys, pathlib, html, shutil

DB = sys.argv[1] if len(sys.argv) > 1 else "ecommerce"
OUT = pathlib.Path(__file__).resolve().parent.parent / "docs"
OUT.mkdir(exist_ok=True)

def q(sql):
    p = subprocess.run(["psql", "-X", "-q", "-At", "-F", "\t", "-d", DB, "-c", sql],
                       capture_output=True, text=True, check=True)
    return [line.split("\t") for line in p.stdout.splitlines() if line]

SOFT = {"is_deleted"}
AUDIT = {"updated_at", "updated_by"}

cols = q("""
SELECT c.relname, a.attnum, a.attname,
       CASE WHEN t.typtype = 'e' THEN t.typname ELSE format_type(a.atttypid, a.atttypmod) END,
       a.attnotnull, a.attidentity <> '', a.attgenerated <> '',
       COALESCE(pg_get_expr(d.adbin, d.adrelid), '')
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_type t ON t.oid = a.atttypid
  LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
 WHERE n.nspname = 'shop' AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped
 ORDER BY c.relname, a.attnum""")
pks = q("""
SELECT c.relname, a.attname
  FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(i.indkey)
 WHERE n.nspname = 'shop' AND i.indisprimary""")
fks = q("""
SELECT c.relname, a.attname, rc.relname, ra.attname
  FROM pg_constraint k
  JOIN pg_class c  ON c.oid = k.conrelid  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_class rc ON rc.oid = k.confrelid
  JOIN pg_attribute a  ON a.attrelid = k.conrelid  AND a.attnum = k.conkey[1]
  JOIN pg_attribute ra ON ra.attrelid = k.confrelid AND ra.attnum = k.confkey[1]
 WHERE n.nspname = 'shop' AND k.contype = 'f'
 ORDER BY 1, 2""")
enums = q("""
SELECT t.typname, string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder)
  FROM pg_type t JOIN pg_enum e ON e.enumtypid = t.oid JOIN pg_namespace n ON n.oid = t.typnamespace
 WHERE n.nspname = 'shop' GROUP BY t.typname ORDER BY 1""")

pk = {(t, c) for t, c in pks}
fk = {(t, c): (rt, rc) for t, c, rt, rc in fks}
tables = {}
for rel, num, name, typ, notnull, ident, gen, default in cols:
    tables.setdefault(rel, []).append((name, typ, notnull == "t", ident == "t", gen == "t", default))

soft_tables = {t for t, cs in tables.items() if any(c[0] in SOFT for c in cs)}
audit_tables = {t for t, cs in tables.items() if any(c[0] in AUDIT for c in cs)}

# ------------------------------------------------------------------ DBML ----
lines = ["// Схема БД: електронна комерція з кількома магазинами",
         "// Вставити на https://dbdiagram.io/d (Import -> DBML або в редактор).",
         "// Позначки: [soft delete] = is_deleted/deleted_at/deleted_by, [audit] = updated_at/updated_by", ""]
for name, labels in enums:
    lines.append(f"Enum {name} {{")
    lines += [f"  {l}" for l in labels.split(",")]
    lines += ["}", ""]
enum_names = {n for n, _ in enums}
for t in sorted(tables):
    notes = [n for n, cond in (("soft delete", t in soft_tables), ("audit: updated_at/updated_by", t in audit_tables)) if cond]
    lines.append(f"Table {t} {{")
    for name, typ, notnull, ident, gen, default in tables[t]:
        typ = typ.replace("character varying", "varchar").replace("timestamp with time zone", "timestamptz") \
                 .replace("character", "char").replace("shop.", "")
        attrs = []
        if (t, name) in pk:
            attrs.append("pk")
        if ident:
            attrs.append("increment")
        if notnull and (t, name) not in pk:
            attrs.append("not null")
        if default and not ident and not gen:
            attrs.append(f"default: `{default.split('::')[0]}`")
        if gen:
            attrs.append("note: 'generated'")
        lines.append(f"  {name} {typ}" + (f" [{', '.join(attrs)}]" if attrs else ""))
    if notes:
        lines += ["", f"  Note: '{'; '.join(notes)}'"]
    lines += ["}", ""]
for t, c, rt, rc in fks:
    lines.append(f"Ref: {t}.{c} > {rt}.{rc}")
(OUT / "schema.dbml").write_text("\n".join(lines) + "\n", encoding="utf-8")

# ------------------------------------------------------------------- DOT ----
def esc(s): return html.escape(s)
dot = ['digraph ER {', '  rankdir=LR; splines=true; overlap=false; nodesep=0.5; ranksep=1.3; bgcolor="white";',
       '  node [shape=plain, fontname="Helvetica", fontsize=10];', '  edge [color="#6b7280", arrowsize=0.7];']
for t in sorted(tables):
    head = "#b45309" if t in soft_tables else "#1d4ed8"
    badge = " ✂" if t in soft_tables else ""
    badge += " ✎" if t in audit_tables else ""
    rows = [f'<TR><TD COLSPAN="2" BGCOLOR="{head}"><FONT COLOR="white"><B>{esc(t)}{badge}</B></FONT></TD></TR>']
    for name, typ, notnull, ident, gen, default in tables[t]:
        mark = "PK" if (t, name) in pk else ("FK" if (t, name) in fk else "")
        short = typ.replace("character varying", "varchar").replace("timestamp with time zone", "timestamptz")
        bg = ' BGCOLOR="#fef3c7"' if name in SOFT | {"deleted_at", "deleted_by"} else (' BGCOLOR="#dbeafe"' if name in AUDIT else "")
        rows.append(f'<TR><TD ALIGN="LEFT"{bg} PORT="{name}">{esc(mark + " " if mark else "")}{esc(name)}</TD>'
                    f'<TD ALIGN="LEFT"{bg}><FONT COLOR="#6b7280">{esc(short)}</FONT></TD></TR>')
    dot.append(f'  {t} [label=<<TABLE BORDER="1" CELLBORDER="0" CELLSPACING="0" CELLPADDING="3">{"".join(rows)}</TABLE>>];')
NOISE = {"updated_by", "deleted_by", "created_by", "changed_by"}   # службові зв'язки з users не малюємо
for t, c, rt, rc in fks:
    if t == rt or c in NOISE:
        continue
    dot.append(f'  {t} -> {rt};')
dot.append('  label=<<FONT POINT-SIZE="12">✂ = soft delete (is_deleted, deleted_at, deleted_by)   ✎ = аудит (updated_at, updated_by)<BR/>Службові зв’язки updated_by / deleted_by / created_by → users на схемі не показано (див. schema.dbml)</FONT>>; labelloc=b;')
dot.append("}")
(OUT / "er_diagram.dot").write_text("\n".join(dot) + "\n", encoding="utf-8")

if shutil.which("dot"):
    for fmt in ("svg", "png"):
        subprocess.run(["dot", f"-T{fmt}", "-Gdpi=110", str(OUT / "er_diagram.dot"), "-o", str(OUT / f"er_diagram.{fmt}")], check=True)
print(f"Таблиць: {len(tables)}, зв'язків (FK): {len(fks)}; з soft delete: {len(soft_tables)}; з аудитом: {len(audit_tables)}")
