-- =====================================================================
--  Файл 08: демонстрація вимог 3, 5, 6 (виконується в транзакції з ROLLBACK,
--  тому дані після запуску не змінюються).
--  Запуск:  psql -d ecommerce -f sql/08_demo.sql
-- =====================================================================
SET search_path TO shop, public;
\set ON_ERROR_STOP on
BEGIN;

-- Ідентифікатори для демонстрації (CALL не приймає підзапити в аргументах)
SELECT (SELECT id FROM users    WHERE email = 'admin@shop.ua') AS admin_id,
       (SELECT id FROM users    WHERE email = 'staff@shop.ua') AS staff_id,
       (SELECT id FROM products WHERE sku   = 'HD-GRY-L')      AS hoodie_id,
       (SELECT id FROM stores   WHERE slug  = 'techhub')       AS tech_id
\gset

-- Усі зміни нижче виконуються "від імені" адміністратора
CALL sp_set_actor(:admin_id);

\echo
\echo '=== 1. SOFT DELETE: процедура ============================================'
CALL sp_product_soft_delete(:hoodie_id);
SELECT 'у каталозі (живі)' AS where_, count(*) FROM v_product_catalog WHERE product_name LIKE 'Худі%'
UNION ALL
SELECT 'у таблиці products', count(*) FROM products WHERE sku = 'HD-GRY-L';
SELECT product_id, sku, product_name, deleted_at IS NOT NULL AS has_deleted_at, deleted_by_name FROM v_products_deleted;

\echo '=== 1b. SOFT DELETE: звичайний DELETE перехоплює тригер ==================='
DELETE FROM reviews WHERE rating = 4;
SELECT id, rating, is_deleted, deleted_by FROM reviews ORDER BY id;
SELECT product_name, avg_rating, reviews_count FROM v_product_catalog WHERE product_name LIKE '%Buds2%';

\echo '=== 1c. Відновлення ======================================================'
CALL sp_product_restore(:hoodie_id);
SELECT count(*) AS худі_знову_в_каталозі FROM v_product_catalog WHERE product_name LIKE 'Худі%';

\echo '=== 1d. Після soft delete SKU/email можна використати знову ================'
CALL sp_user_soft_delete(:staff_id);
DO $$
DECLARE v bigint;
BEGIN
    CALL sp_user_register('staff@shop.ua', 'x', 'Новий', 'Працівник', NULL, v);
    RAISE NOTICE 'Повторна реєстрація email після soft delete: ок, id=%', v;
END $$;

\echo
\echo '=== 2. АУДИТ: updated_at / updated_by + журнал audit_log ==================='
CALL sp_store_update(:tech_id, 'TechHub Ukraine', 'Електроніка та гаджети', 'info@techhub.ua', true);
SELECT name, updated_at IS NOT NULL AS has_updated_at, updated_by FROM v_stores_active WHERE slug = 'techhub';
SELECT table_name, record_id, action, changed_by_name, (new_data::jsonb ->> 'name') AS new_name
  FROM v_audit_log_recent WHERE table_name = 'stores' AND action = 'UPDATE' LIMIT 1;

\echo
\echo '=== 3. ПРАВИЛА ЦІЛІСНОСТІ (кожен виклик має завершитись помилкою) ==========='
DO $$
DECLARE
    v_c1      bigint := (SELECT id FROM users WHERE email = 'olena@example.com');
    v_sp      bigint := (SELECT id FROM store_products WHERE stock_qty = 1 LIMIT 1);   -- навушники, залишок 1
    v_pending bigint := (SELECT id FROM orders WHERE status = 'pending' LIMIT 1);
    v_shoes   bigint := (SELECT id FROM products WHERE sku = 'NK-AIR-42');
    v_cart bigint; v_pay bigint; v_rev bigint; v_id bigint;
BEGIN
    BEGIN CALL sp_cart_add_item(v_c1, v_sp, 5, v_cart);
          RAISE NOTICE 'ПОМИЛКА ТЕСТУ: перевищення залишку не відхилено';
    EXCEPTION WHEN raise_exception THEN RAISE NOTICE '[ok] залишок: %', SQLERRM; END;

    BEGIN CALL sp_order_change_status(v_pending, 'delivered');
          RAISE NOTICE 'ПОМИЛКА ТЕСТУ: недопустимий перехід не відхилено';
    EXCEPTION WHEN raise_exception THEN RAISE NOTICE '[ok] перехід статусу: %', SQLERRM; END;

    BEGIN CALL sp_payment_register(v_pending, 'card', 1, 'TX-BAD', v_pay);
          RAISE NOTICE 'ПОМИЛКА ТЕСТУ: неправильну суму не відхилено';
    EXCEPTION WHEN raise_exception THEN RAISE NOTICE '[ok] сума оплати: %', SQLERRM; END;

    BEGIN CALL sp_review_add(v_c1, v_shoes, 5, 'Не купував', NULL, v_rev);
          RAISE NOTICE 'ПОМИЛКА ТЕСТУ: відгук без покупки не відхилено';
    EXCEPTION WHEN raise_exception THEN RAISE NOTICE '[ok] відгук без покупки: %', SQLERRM; END;

    BEGIN CALL sp_user_register('olena@example.com', 'x', 'Дубль', 'Дублевич', NULL, v_id);
          RAISE NOTICE 'ПОМИЛКА ТЕСТУ: дублікат email не відхилено';
    EXCEPTION WHEN raise_exception THEN RAISE NOTICE '[ok] дубль email: %', SQLERRM; END;

    BEGIN PERFORM fn_find_valid_coupon('NOPE', 1, 1000);
          RAISE NOTICE 'ПОМИЛКА ТЕСТУ: неіснуючий купон не відхилено';
    EXCEPTION WHEN raise_exception THEN RAISE NOTICE '[ok] купон: %', SQLERRM; END;
END $$;

\echo
\echo '=== 4. ФУНКЦІЇ ============================================================='
SELECT fn_calc_discount((SELECT id FROM coupons WHERE code = 'WELCOME10'), 2000) AS discount_10pct_of_2000,
       fn_calc_discount((SELECT id FROM coupons WHERE code = 'TECH500'),   300)  AS fixed_500_capped_to_300,
       fn_product_avg_rating((SELECT id FROM products WHERE sku = 'SM-S24-128')) AS avg_rating;
SELECT product_name, price, stock_qty, round(rank::numeric, 3) AS rank
  FROM fn_search_products((SELECT id FROM stores WHERE slug = 'techhub'), 'смартфон samsung');

ROLLBACK;

-- =====================================================================
--  5. ІНДЕКСИ: порівняння планів на 50 000 згенерованих товарів
--     (дані створюються в транзакції, яка відкочується)
-- =====================================================================
\echo
\echo '=== 5. ІНДЕКСИ (EXPLAIN на 50 000 товарів; транзакція відкочується) ========'
BEGIN;
INSERT INTO products (category_id, brand_id, sku, name, description, attributes)
SELECT (SELECT id FROM categories WHERE slug = 'smartphones'), NULL,
       'GEN-' || g, 'Товар ' || g || ' ' || (ARRAY['червоний','синій','зелений','чорний'])[1 + g % 4],
       'Згенерований опис товару номер ' || g,
       jsonb_build_object('color', (ARRAY['red','blue','green','black'])[1 + g % 4], 'n', g)
  FROM generate_series(1, 50000) g;
ANALYZE products;

\echo '-- GIN: повнотекстовий пошук (ix_products_search)'
EXPLAIN (COSTS OFF) SELECT id FROM products WHERE search_vector @@ plainto_tsquery('simple', 'смартфон');
\echo '-- GIN jsonb_path_ops: фільтр за атрибутом (ix_products_attributes)'
EXPLAIN (COSTS OFF) SELECT id FROM products WHERE attributes @> '{"n": 777}';
\echo '-- B-tree (частковий унікальний ux_products_sku_active): пошук за SKU'
EXPLAIN (COSTS OFF) SELECT id FROM products WHERE lower(sku) = 'gen-12345' AND NOT is_deleted;
ROLLBACK;
