# Електронна комерція з кількома магазинами — база даних (PostgreSQL) + Repository/Unit of Work (C#)

## Склад проєкту

```
docs/
  requirements.md      вимоги -> сутності (п. 3)
  schema.dbml          схема для https://dbdiagram.io (п. 1)
  er_diagram.png/.svg  ER-діаграма (згенерована з реальної БД)
sql/
  01_schema.sql        22 таблиці, типи, обмеження, часткові унікальні індекси
  02_functions.sql     8 користувацьких функцій
  03_triggers.sql      8 тригерних функцій / 24 тригери
  04_views.sql         16 розрізів даних (views)
  05_procedures.sql    34 збережені процедури
  06_indexes.sql       індекси: B-tree, GIN, BRIN, HASH
  07_seed.sql          демо-дані (через виклики процедур)
  08_demo.sql          демонстрація soft delete, аудиту, правил, EXPLAIN
scripts/
  install.sh                   створення БД і запуск усіх скриптів
  generate_er.py               генерація schema.dbml та діаграми з БД
  verify_csharp_bindings.py    звірка C#-викликів з реальною БД
src/EcommerceApp/      C#: Repository + Unit of Work (Npgsql, .NET 8)
```

## Запуск

```bash
# 1. БД (потрібні psql/createdb; підключення через PGHOST, PGPORT, PGUSER, PGPASSWORD)
./scripts/install.sh ecommerce
psql -d ecommerce -f sql/08_demo.sql        # демонстрація (транзакція з ROLLBACK)

# 2. C#-застосунок
export ECOMMERCE_CONNSTR="Host=localhost;Database=ecommerce;Username=postgres;Password=...;Search Path=shop,public"
dotnet run --project src/EcommerceApp
```

Усі об'єкти лежать у схемі `shop`, тому в рядку підключення потрібен `Search Path=shop,public`.

## Відповідність пунктам завдання

| Пункт | Де |
|-------|----|
| 1. Схема з ключами та зв'язками | `docs/schema.dbml` (вставити в dbdiagram.io), `docs/er_diagram.png` |
| 2. ≥ 15 сутностей | 22 таблиці |
| 3. Вимоги, soft delete, аудит | `docs/requirements.md`; **soft delete**: `users, stores, categories, products, store_products, coupons, reviews`; **аудит** (`updated_at`, `updated_by`): ті самі + `orders` |
| 4. Реляційна СУБД | PostgreSQL 14+ (перевірено на 16) |
| 5. Процедури, функції, тригери, views (≥ 10) | 34 процедури, 8 функцій, 24 тригери, 16 views |
| 6. Індекси ≥ 2 типів | B-tree (звичайні, складені, часткові, покривні `INCLUDE`), GIN, BRIN, HASH |
| 7. Repository + Unit of Work | `src/EcommerceApp` |

### Як працюють soft delete та аудит

* Поле `is_deleted` + `deleted_at` + `deleted_by`. Процедури `sp_*_soft_delete` / `sp_*_restore` виставляють їх, а
  **звичайний `DELETE` перехоплює тригер** і замість видалення робить те саме оновлення. Views показують лише «живі» записи
  (`v_products_deleted` — «кошик» для відновлення).
* Транзакція викликає `sp_set_actor(user_id)` (це робить `UnitOfWork.BeginAsync/SetActorAsync`); тригер
  `trg_set_audit_columns` при кожному `UPDATE` ставить `updated_at = now()` та `updated_by = актор`.
  Додатково `audit_log` зберігає старий і новий стан рядка (JSONB) для `users, stores, products, coupons`.

### Repository + Unit of Work

* `UnitOfWork` відкриває одне з'єднання й одну транзакцію PostgreSQL; репозиторії (`Users`, `Stores`, `Products`, `Carts`,
  `Orders`, `Reviews`) створюються ліниво й працюють у цій транзакції. `CommitAsync` фіксує всі зміни разом, `RollbackAsync`
  (або `DisposeAsync` без коміту) скасовує всі.
* Репозиторії **запис виконують тільки через `CALL sp_*`**, **читання — тільки `SELECT` з views** (та табличної функції
  `fn_search_products` для повнотекстового пошуку). Жодного прямого SQL до таблиць.
* `Program.cs` демонструє: замовлення з кількох сутностей в одній транзакції, відкат при помилці, soft delete/restore,
  відправку та відгук, звіти.

## Що було перевірено

* Усі SQL-скрипти виконано на PostgreSQL 16 з нуля; `07_seed.sql` проходить повний цикл (реєстрація → кошик → замовлення →
  оплата → доставка → відгук, скасування з поверненням на склад); `08_demo.sql` підтверджує soft delete, аудит, відхилення
  некоректних операцій та використання індексів (GIN, B-tree) у планах `EXPLAIN`.
* **C#-код у середовищі розробки не компілювався** (немає .NET SDK). Натомість `scripts/verify_csharp_bindings.py` звіряє
  всі 21 виклики процедур (кількість і типи аргументів, INOUT) та 14 запитів до views (назви й типи колонок) з реальною БД.
  Перший `dotnet build` у вас може показати дрібні помилки компіляції.
