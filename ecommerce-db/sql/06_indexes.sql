-- =====================================================================
--  Файл 06: індекси (унікальні часткові індекси див. наприкінці 01_schema.sql)
--
--  Використані типи:  B-tree (звичайні, складені, часткові, покривні INCLUDE),
--                     GIN (повнотекстовий пошук, JSONB), BRIN, HASH
-- =====================================================================
SET search_path TO shop, public;

-- ---- B-tree: зовнішні ключі та типові фільтри ------------------------
CREATE INDEX ix_orders_user_created      ON orders (user_id, created_at DESC);
CREATE INDEX ix_orders_store_status      ON orders (store_id, status);
CREATE INDEX ix_order_items_order        ON order_items (order_id);
CREATE INDEX ix_order_items_store_prod   ON order_items (store_product_id);
CREATE INDEX ix_cart_items_cart          ON cart_items (cart_id);
CREATE INDEX ix_status_history_order     ON order_status_history (order_id, changed_at);
CREATE INDEX ix_inventory_mov_sp         ON inventory_movements (store_product_id, created_at DESC);
CREATE INDEX ix_addresses_user           ON addresses (user_id);
CREATE INDEX ix_payments_order           ON payments (order_id);

-- ---- B-tree ЧАСТКОВІ: індексуємо лише "живі" рядки (soft delete) ------
CREATE INDEX ix_products_category_active ON products (category_id)  WHERE NOT is_deleted;
CREATE INDEX ix_store_products_product   ON store_products (product_id) WHERE NOT is_deleted;
CREATE INDEX ix_reviews_product_active   ON reviews (product_id)    WHERE NOT is_deleted;
CREATE INDEX ix_orders_pending           ON orders (created_at)     WHERE status = 'pending';

-- ---- B-tree ПОКРИВНИЙ (index-only scan для каталогу магазину) ----------
CREATE INDEX ix_store_products_catalog   ON store_products (store_id, price) INCLUDE (stock_qty, product_id)
    WHERE NOT is_deleted AND is_listed;

-- ---- GIN: повнотекстовий пошук і JSONB-атрибути -----------------------
CREATE INDEX ix_products_search          ON products USING gin (search_vector);
CREATE INDEX ix_products_attributes      ON products USING gin (attributes jsonb_path_ops);

-- ---- BRIN: великі таблиці, дані додаються в порядку часу --------------
CREATE INDEX ix_orders_created_brin      ON orders    USING brin (created_at);
CREATE INDEX ix_audit_log_changed_brin   ON audit_log USING brin (changed_at);

-- ---- HASH: точний пошук за зовнішнім ідентифікатором платежу ----------
CREATE INDEX ix_payments_txref_hash      ON payments USING hash (transaction_ref);

-- ---- B-tree для журналу аудиту ---------------------------------------
CREATE INDEX ix_audit_log_record         ON audit_log (table_name, record_id);

ANALYZE;
