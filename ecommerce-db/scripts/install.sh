#!/usr/bin/env bash
# Створює БД і застосовує всі скрипти по черзі.
# Використання:  ./scripts/install.sh [ім'я_бд]          (за замовчуванням: ecommerce)
# Підключення береться зі змінних середовища PGHOST, PGPORT, PGUSER, PGPASSWORD.
set -euo pipefail

DB="${1:-ecommerce}"
DIR="$(cd "$(dirname "$0")/../sql" && pwd)"

dropdb --if-exists "$DB"
createdb "$DB"

for f in 01_schema 02_functions 03_triggers 04_views 05_procedures 06_indexes 07_seed; do
    echo ">> $f.sql"
    psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$DIR/$f.sql"
done
echo "Готово: база '$DB' створена. Демо-запити: psql -d $DB -f sql/08_demo.sql"
