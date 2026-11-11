-- =====================================================================
--  Файл 04: розрізи даних (views)
--  Застосунок читає дані ЛИШЕ через ці уявлення (та fn_search_products).
--  Уявлення автоматично приховують soft-deleted записи.
-- =====================================================================
SET search_path TO shop, public;

-- 1. Активні користувачі з ролями
CREATE OR REPLACE VIEW v_users_active AS
SELECT u.id,
       u.email,
       u.first_name,
       u.last_name,
       u.first_name || ' ' || u.last_name AS full_name,
       u.phone,
       u.created_at,
       u.updated_at,
       u.updated_by,
       COALESCE(string_agg(r.name, ', ' ORDER BY r.name), '') AS roles
  FROM users u
  LEFT JOIN user_roles ur ON ur.user_id = u.id
  LEFT JOIN roles r       ON r.id = ur.role_id
 WHERE NOT u.is_deleted
 GROUP BY u.id;

-- 2. Активні магазини
CREATE OR REPLACE VIEW v_stores_active AS
SELECT s.id,
       s.name,
       s.slug,
       s.description,
       s.currency,
       s.is_active,
       s.owner_id,
       o.first_name || ' ' || o.last_name AS owner_name,
       s.created_at,
       s.updated_at,
       s.updated_by
  FROM stores s
  JOIN users o ON o.id = s.owner_id
 WHERE NOT s.is_deleted;

-- 3. Категорії з назвою батьківської та кількістю товарів
CREATE OR REPLACE VIEW v_categories_active AS
SELECT c.id,
       c.name,
       c.slug,
       c.parent_id,
       pc.name AS parent_name,
       (SELECT count(*) FROM products p WHERE p.category_id = c.id AND NOT p.is_deleted) AS products_count
  FROM categories c
  LEFT JOIN categories pc ON pc.id = c.parent_id
 WHERE NOT c.is_deleted;

-- 4. Каталог: пропозиції магазинів (ціна, залишок, рейтинг)
CREATE OR REPLACE VIEW v_product_catalog AS
SELECT sp.id                          AS store_product_id,
       s.id                           AS store_id,
       s.name                         AS store_name,
       s.currency,
       p.id                           AS product_id,
       p.sku,
       p.name                         AS product_name,
       p.description,
       p.attributes::text             AS attributes_json,
       c.id                           AS category_id,
       c.name                         AS category_name,
       b.name                         AS brand_name,
       sp.price,
       sp.stock_qty,
       (sp.stock_qty > 0)             AS in_stock,
       fn_product_avg_rating(p.id)    AS avg_rating,
       (SELECT count(*) FROM reviews rv WHERE rv.product_id = p.id AND NOT rv.is_deleted) AS reviews_count,
       sp.updated_at,
       sp.updated_by
  FROM store_products sp
  JOIN stores s     ON s.id = sp.store_id   AND NOT s.is_deleted AND s.is_active
  JOIN products p   ON p.id = sp.product_id AND NOT p.is_deleted
  JOIN categories c ON c.id = p.category_id
  LEFT JOIN brands b ON b.id = p.brand_id
 WHERE NOT sp.is_deleted AND sp.is_listed;

-- 5. Вміст кошиків з підсумком
CREATE OR REPLACE VIEW v_cart_details AS
SELECT c.id                                   AS cart_id,
       c.user_id,
       c.store_id,
       ci.store_product_id,
       p.name                                 AS product_name,
       sp.price                               AS unit_price,
       ci.quantity,
       sp.price * ci.quantity                 AS line_total,
       sp.stock_qty,
       SUM(sp.price * ci.quantity) OVER (PARTITION BY c.id) AS cart_total
  FROM carts c
  JOIN cart_items ci     ON ci.cart_id = c.id
  JOIN store_products sp ON sp.id = ci.store_product_id
  JOIN products p        ON p.id = sp.product_id;

-- 6. Замовлення: коротка картка
CREATE OR REPLACE VIEW v_order_summary AS
SELECT o.id                              AS order_id,
       o.order_number,
       o.user_id,
       u.first_name || ' ' || u.last_name AS customer_name,
       u.email                           AS customer_email,
       o.store_id,
       s.name                            AS store_name,
       o.status::text                    AS status,
       o.subtotal,
       o.discount_amount,
       o.shipping_cost,
       o.total_amount,
       cp.code                           AS coupon_code,
       (SELECT count(*) FROM order_items oi WHERE oi.order_id = o.id) AS items_count,
       (SELECT pm.status::text FROM payments pm WHERE pm.order_id = o.id
         ORDER BY pm.id DESC LIMIT 1)    AS payment_status,
       o.created_at,
       o.updated_at,
       o.updated_by
  FROM orders o
  JOIN users u  ON u.id = o.user_id
  JOIN stores s ON s.id = o.store_id
  LEFT JOIN coupons cp ON cp.id = o.coupon_id;

-- 7. Позиції замовлень
CREATE OR REPLACE VIEW v_order_items_detail AS
SELECT oi.order_id,
       oi.id            AS item_id,
       oi.store_product_id,
       p.sku,
       oi.product_name,
       oi.unit_price,
       oi.quantity,
       oi.line_total
  FROM order_items oi
  JOIN store_products sp ON sp.id = oi.store_product_id
  JOIN products p        ON p.id = sp.product_id;

-- 8. Історія статусів
CREATE OR REPLACE VIEW v_order_history AS
SELECT h.order_id,
       h.old_status::text AS old_status,
       h.new_status::text AS new_status,
       h.changed_at,
       h.changed_by,
       u.first_name || ' ' || u.last_name AS changed_by_name
  FROM order_status_history h
  LEFT JOIN users u ON u.id = h.changed_by;

-- 9. Продажі по магазинах (оплачені / виконувані / доставлені замовлення)
CREATE OR REPLACE VIEW v_store_sales_summary AS
SELECT s.id    AS store_id,
       s.name  AS store_name,
       count(o.id)                                      AS orders_count,
       COALESCE(sum(o.total_amount), 0)::numeric(14,2)  AS revenue,
       COALESCE(round(avg(o.total_amount), 2), 0)       AS avg_order_value
  FROM stores s
  LEFT JOIN orders o ON o.store_id = s.id
                    AND o.status IN ('paid', 'processing', 'shipped', 'delivered')
 WHERE NOT s.is_deleted
 GROUP BY s.id, s.name;

-- 10. Топ товарів у кожному магазині (віконна функція RANK)
CREATE OR REPLACE VIEW v_top_products AS
SELECT t.*,
       rank() OVER (PARTITION BY t.store_id ORDER BY t.units_sold DESC) AS sales_rank
  FROM (SELECT o.store_id,
               s.name           AS store_name,
               p.id             AS product_id,
               p.name           AS product_name,
               sum(oi.quantity) AS units_sold,
               sum(oi.line_total)::numeric(14,2) AS revenue
          FROM order_items oi
          JOIN orders o          ON o.id = oi.order_id
                                AND o.status IN ('paid', 'processing', 'shipped', 'delivered')
          JOIN stores s          ON s.id = o.store_id
          JOIN store_products sp ON sp.id = oi.store_product_id
          JOIN products p        ON p.id = sp.product_id
         GROUP BY o.store_id, s.name, p.id, p.name) t;

-- 11. Товари з малим залишком
CREATE OR REPLACE VIEW v_low_stock AS
SELECT sp.id        AS store_product_id,
       sp.store_id,
       s.name       AS store_name,
       p.sku,
       p.name       AS product_name,
       sp.stock_qty
  FROM store_products sp
  JOIN stores s   ON s.id = sp.store_id AND NOT s.is_deleted
  JOIN products p ON p.id = sp.product_id AND NOT p.is_deleted
 WHERE NOT sp.is_deleted AND sp.stock_qty <= 5;

-- 12. Активні відгуки
CREATE OR REPLACE VIEW v_reviews_active AS
SELECT r.id AS review_id,
       r.product_id,
       p.name AS product_name,
       r.user_id,
       u.first_name || ' ' || u.last_name AS reviewer_name,
       r.rating::integer AS rating,
       r.title,
       r.body,
       r.created_at,
       r.updated_at,
       r.updated_by
  FROM reviews r
  JOIN products p ON p.id = r.product_id
  JOIN users u    ON u.id = r.user_id
 WHERE NOT r.is_deleted;

-- 13. "Кошик" видалених товарів (для відновлення): хто і коли видалив
CREATE OR REPLACE VIEW v_products_deleted AS
SELECT p.id AS product_id,
       p.sku,
       p.name AS product_name,
       p.deleted_at,
       p.deleted_by,
       u.first_name || ' ' || u.last_name AS deleted_by_name
  FROM products p
  LEFT JOIN users u ON u.id = p.deleted_by
 WHERE p.is_deleted;

-- 14. Способи доставки
CREATE OR REPLACE VIEW v_shipping_methods_active AS
SELECT sm.id AS shipping_method_id,
       sm.store_id,
       sm.name,
       sm.base_cost,
       sm.estimated_days
  FROM shipping_methods sm
  JOIN stores s ON s.id = sm.store_id AND NOT s.is_deleted
 WHERE sm.is_active;

-- 15. Адреси користувачів
CREATE OR REPLACE VIEW v_user_addresses AS
SELECT a.id AS address_id,
       a.user_id,
       a.label,
       a.country,
       a.city,
       a.street_line,
       a.postal_code,
       a.is_default
  FROM addresses a;

-- 16. Журнал аудиту з іменем користувача
CREATE OR REPLACE VIEW v_audit_log_recent AS
SELECT al.id,
       al.table_name,
       al.record_id,
       al.action,
       al.changed_at,
       al.changed_by,
       u.first_name || ' ' || u.last_name AS changed_by_name,
       al.old_data::text AS old_data,
       al.new_data::text AS new_data
  FROM audit_log al
  LEFT JOIN users u ON u.id = al.changed_by
 ORDER BY al.changed_at DESC, al.id DESC;
