-- =====================================================================
--  Файл 05: збережені процедури (усі операції запису з застосунку)
--
--  Конвенція: вихідний ідентифікатор повертається через INOUT-параметр
--  (при виклику передається NULL), CALL повертає його одним рядком.
--  Проміжні статуси / дати в процедури передаються текстом або числами,
--  щоб клієнту не потрібне було відображення enum-типів.
-- =====================================================================
SET search_path TO shop, public;

-- ---------------------------------------------------------------------
-- Службові
-- ---------------------------------------------------------------------
-- Запам'ятовує користувача, від імені якого виконуються зміни (до кінця транзакції)
CREATE OR REPLACE PROCEDURE sp_set_actor(p_user_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM set_config('app.current_user_id', COALESCE(p_user_id::text, ''), true);
END;
$$;

-- Універсальний soft delete / restore (тільки для таблиць із is_deleted)
CREATE OR REPLACE PROCEDURE sp_soft_delete(p_table text, p_id bigint)
LANGUAGE plpgsql AS $$
DECLARE
    v_rows integer;
BEGIN
    IF p_table NOT IN ('users', 'stores', 'categories', 'products', 'store_products', 'coupons', 'reviews') THEN
        RAISE EXCEPTION 'Table % does not support soft delete', p_table;
    END IF;

    EXECUTE format(
        'UPDATE %I SET is_deleted = true, deleted_at = now(), deleted_by = $1
          WHERE id = $2 AND NOT is_deleted', p_table)
    USING fn_current_actor(), p_id;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows = 0 THEN
        RAISE EXCEPTION '% #% not found or already deleted', p_table, p_id;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE sp_restore(p_table text, p_id bigint)
LANGUAGE plpgsql AS $$
DECLARE
    v_rows integer;
BEGIN
    IF p_table NOT IN ('users', 'stores', 'categories', 'products', 'store_products', 'coupons', 'reviews') THEN
        RAISE EXCEPTION 'Table % does not support soft delete', p_table;
    END IF;

    EXECUTE format(
        'UPDATE %I SET is_deleted = false, deleted_at = NULL, deleted_by = NULL
          WHERE id = $1 AND is_deleted', p_table)
    USING p_id;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows = 0 THEN
        RAISE EXCEPTION '% #% not found or not deleted', p_table, p_id;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- Користувачі та адреси
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_user_register(
    p_email text, p_password_hash text, p_first_name text, p_last_name text, p_phone text,
    INOUT p_user_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM users WHERE lower(email) = lower(p_email) AND NOT is_deleted) THEN
        RAISE EXCEPTION 'Email % is already registered', p_email;
    END IF;

    INSERT INTO users (email, password_hash, first_name, last_name, phone)
    VALUES (lower(p_email), p_password_hash, p_first_name, p_last_name, p_phone)
    RETURNING id INTO p_user_id;

    INSERT INTO user_roles (user_id, role_id)
    SELECT p_user_id, id FROM roles WHERE name = 'customer';
END;
$$;

CREATE OR REPLACE PROCEDURE sp_user_update(
    p_user_id bigint, p_first_name text, p_last_name text, p_phone text)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE users
       SET first_name = p_first_name, last_name = p_last_name, phone = p_phone
     WHERE id = p_user_id AND NOT is_deleted;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User #% not found', p_user_id;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE sp_user_assign_role(p_user_id bigint, p_role_name text)
LANGUAGE plpgsql AS $$
DECLARE
    v_role_id smallint;
BEGIN
    SELECT id INTO v_role_id FROM roles WHERE name = p_role_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Role "%" does not exist', p_role_name;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id AND NOT is_deleted) THEN
        RAISE EXCEPTION 'User #% not found', p_user_id;
    END IF;
    INSERT INTO user_roles (user_id, role_id) VALUES (p_user_id, v_role_id)
    ON CONFLICT DO NOTHING;
END;
$$;

CREATE OR REPLACE PROCEDURE sp_user_soft_delete(p_user_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    CALL sp_soft_delete('users', p_user_id);
END;
$$;

CREATE OR REPLACE PROCEDURE sp_user_restore(p_user_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    CALL sp_restore('users', p_user_id);
END;
$$;

CREATE OR REPLACE PROCEDURE sp_address_add(
    p_user_id bigint, p_label text, p_country text, p_city text, p_street_line text,
    p_postal_code text, p_is_default boolean,
    INOUT p_address_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id AND NOT is_deleted) THEN
        RAISE EXCEPTION 'User #% not found', p_user_id;
    END IF;
    IF p_is_default THEN
        UPDATE addresses SET is_default = false WHERE user_id = p_user_id AND is_default;
    END IF;
    INSERT INTO addresses (user_id, label, country, city, street_line, postal_code, is_default)
    VALUES (p_user_id, COALESCE(p_label, 'Дім'), p_country, p_city, p_street_line, p_postal_code, p_is_default)
    RETURNING id INTO p_address_id;
END;
$$;

-- ---------------------------------------------------------------------
-- Магазини
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_store_create(
    p_owner_id bigint, p_name text, p_slug text, p_description text,
    p_contact_email text, p_currency text,
    INOUT p_store_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO stores (owner_id, name, slug, description, contact_email, currency)
    VALUES (p_owner_id, p_name, p_slug, p_description, p_contact_email, COALESCE(p_currency, 'UAH'))
    RETURNING id INTO p_store_id;

    INSERT INTO store_staff (store_id, user_id, position) VALUES (p_store_id, p_owner_id, 'owner');
    CALL sp_user_assign_role(p_owner_id, 'store_owner');
END;
$$;

CREATE OR REPLACE PROCEDURE sp_store_update(
    p_store_id bigint, p_name text, p_description text, p_contact_email text, p_is_active boolean)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE stores
       SET name = p_name, description = p_description,
           contact_email = p_contact_email, is_active = p_is_active
     WHERE id = p_store_id AND NOT is_deleted;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Store #% not found', p_store_id;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE sp_store_soft_delete(p_store_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    CALL sp_soft_delete('stores', p_store_id);
END;
$$;

CREATE OR REPLACE PROCEDURE sp_store_restore(p_store_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    CALL sp_restore('stores', p_store_id);
END;
$$;

CREATE OR REPLACE PROCEDURE sp_store_staff_add(p_store_id bigint, p_user_id bigint, p_position text)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO store_staff (store_id, user_id, position)
    VALUES (p_store_id, p_user_id, COALESCE(p_position, 'manager'))
    ON CONFLICT (store_id, user_id) DO UPDATE SET position = EXCLUDED.position;
    CALL sp_user_assign_role(p_user_id, 'store_staff');
END;
$$;

CREATE OR REPLACE PROCEDURE sp_shipping_method_create(
    p_store_id bigint, p_name text, p_base_cost numeric, p_estimated_days integer,
    INOUT p_shipping_method_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO shipping_methods (store_id, name, base_cost, estimated_days)
    VALUES (p_store_id, p_name, p_base_cost, p_estimated_days)
    RETURNING id INTO p_shipping_method_id;
END;
$$;

-- p_valid_days: скільки днів діє промокод від зараз (NULL = безстроково)
CREATE OR REPLACE PROCEDURE sp_coupon_create(
    p_store_id bigint, p_code text, p_discount_type text, p_discount_value numeric,
    p_min_order_amount numeric, p_max_uses integer, p_valid_days integer,
    INOUT p_coupon_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO coupons (store_id, code, discount_type, discount_value, min_order_amount,
                         max_uses, valid_from, valid_to)
    VALUES (p_store_id, p_code, p_discount_type::discount_type, p_discount_value,
            COALESCE(p_min_order_amount, 0), p_max_uses, now(),
            CASE WHEN p_valid_days IS NULL THEN NULL ELSE now() + make_interval(days => p_valid_days) END)
    RETURNING id INTO p_coupon_id;
END;
$$;

-- ---------------------------------------------------------------------
-- Каталог
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_category_create(
    p_name text, p_slug text, p_parent_id bigint,
    INOUT p_category_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO categories (name, slug, parent_id)
    VALUES (p_name, p_slug, p_parent_id)
    RETURNING id INTO p_category_id;
END;
$$;

CREATE OR REPLACE PROCEDURE sp_brand_create(
    p_name text, p_country text,
    INOUT p_brand_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO brands (name, country) VALUES (p_name, p_country)
    ON CONFLICT (name) DO UPDATE SET country = COALESCE(EXCLUDED.country, brands.country)
    RETURNING id INTO p_brand_id;
END;
$$;

-- p_attributes: JSON-рядок, наприклад '{"color":"black"}'
CREATE OR REPLACE PROCEDURE sp_product_create(
    p_category_id bigint, p_brand_id bigint, p_sku text, p_name text,
    p_description text, p_attributes text,
    INOUT p_product_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM categories WHERE id = p_category_id AND NOT is_deleted) THEN
        RAISE EXCEPTION 'Category #% not found', p_category_id;
    END IF;

    INSERT INTO products (category_id, brand_id, sku, name, description, attributes)
    VALUES (p_category_id, p_brand_id, p_sku, p_name, p_description,
            COALESCE(p_attributes::jsonb, '{}'::jsonb))
    RETURNING id INTO p_product_id;
END;
$$;

CREATE OR REPLACE PROCEDURE sp_product_update(
    p_product_id bigint, p_name text, p_description text, p_attributes text, p_category_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE products
       SET name        = p_name,
           description = p_description,
           attributes  = COALESCE(p_attributes::jsonb, attributes),
           category_id = COALESCE(p_category_id, category_id)
     WHERE id = p_product_id AND NOT is_deleted;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Product #% not found', p_product_id;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE sp_product_soft_delete(p_product_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    CALL sp_soft_delete('products', p_product_id);
END;
$$;

CREATE OR REPLACE PROCEDURE sp_product_restore(p_product_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    CALL sp_restore('products', p_product_id);
END;
$$;

-- Поповнення / списання залишку з записом руху на складі
CREATE OR REPLACE PROCEDURE sp_store_product_restock(
    p_store_product_id bigint, p_quantity integer, p_reason text)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_quantity IS NULL OR p_quantity = 0 THEN
        RAISE EXCEPTION 'Quantity must be non-zero';
    END IF;

    UPDATE store_products
       SET stock_qty = stock_qty + p_quantity
     WHERE id = p_store_product_id AND NOT is_deleted;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Store product #% not found', p_store_product_id;
    END IF;

    INSERT INTO inventory_movements (store_product_id, quantity_change, reason, created_by)
    VALUES (p_store_product_id, p_quantity, COALESCE(p_reason, 'restock')::inventory_reason, fn_current_actor());
END;
$$;

-- Виставляє товар у магазині: створює пропозицію, оновлює ціну або відновлює видалену
CREATE OR REPLACE PROCEDURE sp_store_product_set(
    p_store_id bigint, p_product_id bigint, p_price numeric, p_initial_stock integer,
    INOUT p_store_product_id bigint)
LANGUAGE plpgsql AS $$
DECLARE
    v_deleted boolean;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM stores WHERE id = p_store_id AND NOT is_deleted) THEN
        RAISE EXCEPTION 'Store #% not found', p_store_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM products WHERE id = p_product_id AND NOT is_deleted) THEN
        RAISE EXCEPTION 'Product #% not found', p_product_id;
    END IF;

    SELECT id, is_deleted INTO p_store_product_id, v_deleted
      FROM store_products
     WHERE store_id = p_store_id AND product_id = p_product_id
     ORDER BY is_deleted, id DESC
     LIMIT 1;

    IF FOUND THEN
        UPDATE store_products
           SET price = p_price, is_listed = true,
               is_deleted = false, deleted_at = NULL, deleted_by = NULL
         WHERE id = p_store_product_id;
    ELSE
        INSERT INTO store_products (store_id, product_id, price, stock_qty)
        VALUES (p_store_id, p_product_id, p_price, 0)
        RETURNING id INTO p_store_product_id;
    END IF;

    IF COALESCE(p_initial_stock, 0) > 0 THEN
        CALL sp_store_product_restock(p_store_product_id, p_initial_stock, 'restock');
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- Кошик
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_cart_add_item(
    p_user_id bigint, p_store_product_id bigint, p_quantity integer,
    INOUT p_cart_id bigint)
LANGUAGE plpgsql AS $$
DECLARE
    v_store_id bigint;
    v_stock    integer;
    v_in_cart  integer;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id AND NOT is_deleted) THEN
        RAISE EXCEPTION 'User #% not found', p_user_id;
    END IF;

    SELECT sp.store_id, sp.stock_qty INTO v_store_id, v_stock
      FROM store_products sp
      JOIN products p ON p.id = sp.product_id AND NOT p.is_deleted
      JOIN stores s   ON s.id = sp.store_id   AND NOT s.is_deleted AND s.is_active
     WHERE sp.id = p_store_product_id AND NOT sp.is_deleted AND sp.is_listed;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Product offer #% is not available', p_store_product_id;
    END IF;

    SELECT id INTO p_cart_id FROM carts WHERE user_id = p_user_id AND store_id = v_store_id;
    IF NOT FOUND THEN
        INSERT INTO carts (user_id, store_id) VALUES (p_user_id, v_store_id)
        RETURNING id INTO p_cart_id;
    END IF;

    INSERT INTO cart_items (cart_id, store_product_id, quantity)
    VALUES (p_cart_id, p_store_product_id, p_quantity)
    ON CONFLICT (cart_id, store_product_id)
    DO UPDATE SET quantity = cart_items.quantity + EXCLUDED.quantity;

    SELECT quantity INTO v_in_cart
      FROM cart_items WHERE cart_id = p_cart_id AND store_product_id = p_store_product_id;
    IF v_in_cart > v_stock THEN
        RAISE EXCEPTION 'Only % item(s) in stock, requested %', v_stock, v_in_cart;
    END IF;

    UPDATE carts SET updated_at = now() WHERE id = p_cart_id;
END;
$$;

CREATE OR REPLACE PROCEDURE sp_cart_remove_item(p_cart_id bigint, p_store_product_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM cart_items WHERE cart_id = p_cart_id AND store_product_id = p_store_product_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Item not found in cart #%', p_cart_id;
    END IF;
    UPDATE carts SET updated_at = now() WHERE id = p_cart_id;
END;
$$;

CREATE OR REPLACE PROCEDURE sp_cart_clear(p_cart_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM cart_items WHERE cart_id = p_cart_id;
    UPDATE carts SET updated_at = now() WHERE id = p_cart_id;
END;
$$;

-- ---------------------------------------------------------------------
-- Замовлення, оплата, доставка
-- ---------------------------------------------------------------------
-- Оформлення замовлення з кошика: перевірка залишків, списання, знімок цін,
-- промокод - усе атомарно в межах транзакції виклику.
CREATE OR REPLACE PROCEDURE sp_order_place(
    p_user_id bigint, p_store_id bigint, p_address_id bigint, p_shipping_method_id bigint,
    p_coupon_code text, p_note text,
    INOUT p_order_id bigint)
LANGUAGE plpgsql AS $$
DECLARE
    v_cart_id       bigint;
    v_shipping_cost numeric;
    v_coupon_id     bigint;
    v_subtotal      numeric;
    r               record;
BEGIN
    SELECT id INTO v_cart_id FROM carts WHERE user_id = p_user_id AND store_id = p_store_id;
    IF v_cart_id IS NULL OR NOT EXISTS (SELECT 1 FROM cart_items WHERE cart_id = v_cart_id) THEN
        RAISE EXCEPTION 'Cart is empty';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM addresses WHERE id = p_address_id AND user_id = p_user_id) THEN
        RAISE EXCEPTION 'Address #% does not belong to user #%', p_address_id, p_user_id;
    END IF;

    SELECT base_cost INTO v_shipping_cost
      FROM shipping_methods
     WHERE id = p_shipping_method_id AND store_id = p_store_id AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Shipping method #% is not available in this store', p_shipping_method_id;
    END IF;

    v_subtotal := fn_cart_total(v_cart_id);
    IF p_coupon_code IS NOT NULL AND length(trim(p_coupon_code)) > 0 THEN
        v_coupon_id := fn_find_valid_coupon(trim(p_coupon_code), p_store_id, v_subtotal);
    END IF;

    INSERT INTO orders (order_number, user_id, store_id, shipping_address_id, shipping_method_id,
                        coupon_id, shipping_cost, note)
    VALUES (fn_generate_order_number(), p_user_id, p_store_id, p_address_id, p_shipping_method_id,
            v_coupon_id, v_shipping_cost, p_note)
    RETURNING id INTO p_order_id;

    -- блокуємо рядки залишків у стабільному порядку (уникнення deadlock)
    FOR r IN
        SELECT ci.store_product_id, ci.quantity, sp.price, p.name AS product_name
          FROM cart_items ci
          JOIN store_products sp ON sp.id = ci.store_product_id
          JOIN products p        ON p.id = sp.product_id
         WHERE ci.cart_id = v_cart_id
         ORDER BY ci.store_product_id
           FOR UPDATE OF sp
    LOOP
        UPDATE store_products
           SET stock_qty = stock_qty - r.quantity
         WHERE id = r.store_product_id
           AND stock_qty >= r.quantity
           AND NOT is_deleted AND is_listed;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Product "%" is out of stock or unavailable (requested %)', r.product_name, r.quantity;
        END IF;

        INSERT INTO order_items (order_id, store_product_id, product_name, unit_price, quantity)
        VALUES (p_order_id, r.store_product_id, r.product_name, r.price, r.quantity);

        INSERT INTO inventory_movements (store_product_id, quantity_change, reason, order_id, created_by)
        VALUES (r.store_product_id, -r.quantity, 'sale', p_order_id, fn_current_actor());
    END LOOP;

    IF v_coupon_id IS NOT NULL THEN
        UPDATE coupons SET used_count = used_count + 1 WHERE id = v_coupon_id;
    END IF;

    DELETE FROM cart_items WHERE cart_id = v_cart_id;
    UPDATE carts SET updated_at = now() WHERE id = v_cart_id;
END;
$$;

-- Зміна статусу (допустимість переходу перевіряє тригер trg_orders_validate_status;
-- повернення на склад при скасуванні виконує тригер trg_orders_restock_on_cancel)
CREATE OR REPLACE PROCEDURE sp_order_change_status(p_order_id bigint, p_new_status text)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE orders SET status = p_new_status::order_status WHERE id = p_order_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order #% not found', p_order_id;
    END IF;

    IF p_new_status IN ('cancelled', 'refunded') THEN
        UPDATE payments SET status = 'refunded' WHERE order_id = p_order_id AND status = 'completed';
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE sp_payment_register(
    p_order_id bigint, p_method text, p_amount numeric, p_transaction_ref text,
    INOUT p_payment_id bigint)
LANGUAGE plpgsql AS $$
DECLARE
    v_status order_status;
    v_total  numeric;
BEGIN
    SELECT status, total_amount INTO v_status, v_total
      FROM orders WHERE id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order #% not found', p_order_id;
    END IF;
    IF v_status <> 'pending' THEN
        RAISE EXCEPTION 'Order #% is not awaiting payment (status: %)', p_order_id, v_status;
    END IF;
    IF p_amount <> v_total THEN
        RAISE EXCEPTION 'Payment amount % does not match order total %', p_amount, v_total;
    END IF;

    INSERT INTO payments (order_id, amount, method, status, transaction_ref, paid_at)
    VALUES (p_order_id, p_amount, p_method::payment_method, 'completed', p_transaction_ref, now())
    RETURNING id INTO p_payment_id;

    UPDATE orders SET status = 'paid' WHERE id = p_order_id;
END;
$$;

CREATE OR REPLACE PROCEDURE sp_shipment_create(
    p_order_id bigint, p_carrier text, p_tracking_number text,
    INOUT p_shipment_id bigint)
LANGUAGE plpgsql AS $$
DECLARE
    v_status order_status;
BEGIN
    SELECT status INTO v_status FROM orders WHERE id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order #% not found', p_order_id;
    END IF;
    IF v_status NOT IN ('paid', 'processing') THEN
        RAISE EXCEPTION 'Order #% cannot be shipped from status %', p_order_id, v_status;
    END IF;

    IF v_status = 'paid' THEN
        UPDATE orders SET status = 'processing' WHERE id = p_order_id;
    END IF;

    INSERT INTO shipments (order_id, carrier, tracking_number, status, shipped_at)
    VALUES (p_order_id, p_carrier, p_tracking_number, 'in_transit', now())
    RETURNING id INTO p_shipment_id;

    UPDATE orders SET status = 'shipped' WHERE id = p_order_id;
END;
$$;

CREATE OR REPLACE PROCEDURE sp_shipment_mark_delivered(p_order_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE shipments
       SET status = 'delivered', delivered_at = now()
     WHERE order_id = p_order_id AND status = 'in_transit';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No shipment in transit for order #%', p_order_id;
    END IF;
    UPDATE orders SET status = 'delivered' WHERE id = p_order_id;
END;
$$;

-- ---------------------------------------------------------------------
-- Відгуки
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_review_add(
    p_user_id bigint, p_product_id bigint, p_rating integer, p_title text, p_body text,
    INOUT p_review_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO reviews (user_id, product_id, rating, title, body)
    VALUES (p_user_id, p_product_id, p_rating, p_title, p_body)
    RETURNING id INTO p_review_id;
END;
$$;

CREATE OR REPLACE PROCEDURE sp_review_soft_delete(p_review_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    CALL sp_soft_delete('reviews', p_review_id);
END;
$$;
