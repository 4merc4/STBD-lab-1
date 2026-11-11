-- =====================================================================
--  Файл 02: користувацькі функції
--  Актор (хто виконує зміну) передається через налаштування сесії
--  app.current_user_id, яке виставляє процедура sp_set_actor().
-- =====================================================================
SET search_path TO shop, public;

-- Поточний користувач-актор (NULL, якщо не встановлено)
CREATE OR REPLACE FUNCTION fn_current_actor() RETURNS bigint
LANGUAGE sql STABLE AS $$
    SELECT NULLIF(current_setting('app.current_user_id', true), '')::bigint
$$;

-- Номер замовлення виду ORD-20261109-001000
CREATE OR REPLACE FUNCTION fn_generate_order_number() RETURNS varchar
LANGUAGE sql AS $$
    SELECT 'ORD-' || to_char(now(), 'YYYYMMDD') || '-' || lpad(nextval('order_number_seq')::text, 6, '0')
$$;

-- Розмір знижки за промокодом для заданої суми
CREATE OR REPLACE FUNCTION fn_calc_discount(p_coupon_id bigint, p_subtotal numeric) RETURNS numeric
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_coupon coupons%ROWTYPE;
BEGIN
    IF p_coupon_id IS NULL THEN
        RETURN 0;
    END IF;

    SELECT * INTO v_coupon FROM coupons WHERE id = p_coupon_id;
    IF NOT FOUND THEN
        RETURN 0;
    END IF;

    IF v_coupon.discount_type = 'percent' THEN
        RETURN round(p_subtotal * v_coupon.discount_value / 100, 2);
    END IF;
    RETURN LEAST(v_coupon.discount_value, p_subtotal);
END;
$$;

-- Знаходить чинний промокод або кидає зрозумілу помилку
CREATE OR REPLACE FUNCTION fn_find_valid_coupon(p_code text, p_store_id bigint, p_subtotal numeric) RETURNS bigint
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_coupon coupons%ROWTYPE;
BEGIN
    SELECT * INTO v_coupon
      FROM coupons
     WHERE lower(code) = lower(p_code)
       AND NOT is_deleted
       AND (store_id IS NULL OR store_id = p_store_id);

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Coupon "%" does not exist or is not valid for this store', p_code;
    END IF;
    IF v_coupon.valid_from > now() OR (v_coupon.valid_to IS NOT NULL AND v_coupon.valid_to < now()) THEN
        RAISE EXCEPTION 'Coupon "%" is expired or not active yet', p_code;
    END IF;
    IF v_coupon.max_uses IS NOT NULL AND v_coupon.used_count >= v_coupon.max_uses THEN
        RAISE EXCEPTION 'Coupon "%" usage limit reached', p_code;
    END IF;
    IF p_subtotal < v_coupon.min_order_amount THEN
        RAISE EXCEPTION 'Coupon "%" requires a minimum order of %', p_code, v_coupon.min_order_amount;
    END IF;
    RETURN v_coupon.id;
END;
$$;

-- Сума кошика за поточними цінами
CREATE OR REPLACE FUNCTION fn_cart_total(p_cart_id bigint) RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(sp.price * ci.quantity), 0)
      FROM cart_items ci
      JOIN store_products sp ON sp.id = ci.store_product_id
     WHERE ci.cart_id = p_cart_id
$$;

-- Середня оцінка товару за "живими" відгуками
CREATE OR REPLACE FUNCTION fn_product_avg_rating(p_product_id bigint) RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT round(avg(rating)::numeric, 2)
      FROM reviews
     WHERE product_id = p_product_id AND NOT is_deleted
$$;

-- Автомат допустимих переходів статусу замовлення
CREATE OR REPLACE FUNCTION fn_order_transition_allowed(p_old order_status, p_new order_status) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_old
        WHEN 'pending'    THEN p_new IN ('paid', 'cancelled')
        WHEN 'paid'       THEN p_new IN ('processing', 'cancelled', 'refunded')
        WHEN 'processing' THEN p_new IN ('shipped', 'cancelled', 'refunded')
        WHEN 'shipped'    THEN p_new IN ('delivered')
        WHEN 'delivered'  THEN p_new IN ('refunded')
        ELSE false
    END
$$;

-- Повнотекстовий пошук товарів у конкретному магазині (використовує GIN-індекс)
CREATE OR REPLACE FUNCTION fn_search_products(p_store_id bigint, p_query text)
RETURNS TABLE (store_product_id bigint, product_id bigint, sku varchar, product_name varchar,
               price numeric, stock_qty integer, rank real)
LANGUAGE sql STABLE AS $$
    SELECT sp.id, p.id, p.sku, p.name, sp.price, sp.stock_qty, ts_rank(p.search_vector, q.query)
      FROM store_products sp
      JOIN products p ON p.id = sp.product_id
     CROSS JOIN plainto_tsquery('simple', p_query) AS q(query)
     WHERE sp.store_id = p_store_id
       AND NOT sp.is_deleted AND sp.is_listed
       AND NOT p.is_deleted
       AND p.search_vector @@ q.query
     ORDER BY ts_rank(p.search_vector, q.query) DESC, p.name
$$;
