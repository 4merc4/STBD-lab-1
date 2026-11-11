-- =====================================================================
--  Файл 03: тригери
--   1. trg_set_audit_columns       - updated_at / updated_by (аудит змін)
--   2. trg_prevent_hard_delete     - DELETE -> soft delete
--   3. trg_recalc_order_totals     - перерахунок сум замовлення
--   4. trg_validate_order_status   - контроль переходів статусу
--   5. trg_log_order_status        - історія статусів
--   6. trg_restock_on_cancel       - повернення товару на склад при скасуванні
--   7. trg_review_verified_purchase- відгук лише після отриманого замовлення
--   8. trg_write_audit_log         - журнал змін (JSONB)
-- =====================================================================
SET search_path TO shop, public;

-- ---------------------------------------------------------------------
-- 1. Аудит: дата останньої зміни та користувач, що змінив
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_set_audit_columns() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    NEW.updated_by := COALESCE(fn_current_actor(), NEW.updated_by);
    RETURN NEW;
END;
$$;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['users', 'stores', 'categories', 'products',
                             'store_products', 'coupons', 'reviews', 'orders']
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%1$s_audit BEFORE UPDATE ON %1$I
             FOR EACH ROW EXECUTE FUNCTION trg_set_audit_columns()', t);
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------
-- 2. Фізичне видалення "м'яких" сутностей перетворюється на soft delete
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_prevent_hard_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE format(
        'UPDATE %I SET is_deleted = true, deleted_at = now(), deleted_by = $1
          WHERE id = $2 AND NOT is_deleted', TG_TABLE_NAME)
    USING fn_current_actor(), OLD.id;
    RETURN NULL;   -- рядок фізично не видаляється
END;
$$;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['users', 'stores', 'categories', 'products',
                             'store_products', 'coupons', 'reviews']
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%1$s_soft_delete BEFORE DELETE ON %1$I
             FOR EACH ROW EXECUTE FUNCTION trg_prevent_hard_delete()', t);
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------
-- 3. Суми замовлення завжди відповідають позиціям
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_recalc_order_totals() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_order_id bigint := COALESCE(NEW.order_id, OLD.order_id);
BEGIN
    UPDATE orders o
       SET subtotal        = s.sub,
           discount_amount = fn_calc_discount(o.coupon_id, s.sub),
           total_amount    = GREATEST(s.sub - fn_calc_discount(o.coupon_id, s.sub), 0) + o.shipping_cost
      FROM (SELECT COALESCE(SUM(line_total), 0) AS sub
              FROM order_items WHERE order_id = v_order_id) s
     WHERE o.id = v_order_id;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_order_items_totals
    AFTER INSERT OR UPDATE OR DELETE ON order_items
    FOR EACH ROW EXECUTE FUNCTION trg_recalc_order_totals();

-- ---------------------------------------------------------------------
-- 4. Дозволені переходи статусів
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_validate_order_status() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status
       AND NOT fn_order_transition_allowed(OLD.status, NEW.status) THEN
        RAISE EXCEPTION 'Order status transition % -> % is not allowed', OLD.status, NEW.status;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_orders_validate_status
    BEFORE UPDATE OF status ON orders
    FOR EACH ROW EXECUTE FUNCTION trg_validate_order_status();

-- ---------------------------------------------------------------------
-- 5. Історія змін статусу
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_log_order_status() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO order_status_history (order_id, old_status, new_status, changed_by)
        VALUES (NEW.id, NULL, NEW.status, fn_current_actor());
    ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO order_status_history (order_id, old_status, new_status, changed_by)
        VALUES (NEW.id, OLD.status, NEW.status, fn_current_actor());
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_orders_status_history
    AFTER INSERT OR UPDATE OF status ON orders
    FOR EACH ROW EXECUTE FUNCTION trg_log_order_status();

-- ---------------------------------------------------------------------
-- 6. Скасування замовлення повертає товар на склад
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_restock_on_cancel() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT store_product_id, quantity
               FROM order_items
              WHERE order_id = NEW.id
              ORDER BY store_product_id
    LOOP
        UPDATE store_products SET stock_qty = stock_qty + r.quantity WHERE id = r.store_product_id;
        INSERT INTO inventory_movements (store_product_id, quantity_change, reason, order_id, created_by)
        VALUES (r.store_product_id, r.quantity, 'cancellation', NEW.id, fn_current_actor());
    END LOOP;

    IF NEW.coupon_id IS NOT NULL THEN
        UPDATE coupons SET used_count = GREATEST(used_count - 1, 0) WHERE id = NEW.coupon_id;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_orders_restock_on_cancel
    AFTER UPDATE OF status ON orders
    FOR EACH ROW
    WHEN (NEW.status = 'cancelled' AND OLD.status IS DISTINCT FROM 'cancelled')
    EXECUTE FUNCTION trg_restock_on_cancel();

-- ---------------------------------------------------------------------
-- 7. Відгук може залишити лише той, хто отримав замовлення з цим товаром
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_review_verified_purchase() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM orders o
          JOIN order_items oi ON oi.order_id = o.id
          JOIN store_products sp ON sp.id = oi.store_product_id
         WHERE o.user_id = NEW.user_id
           AND sp.product_id = NEW.product_id
           AND o.status = 'delivered'
    ) THEN
        RAISE EXCEPTION 'User % has no delivered order containing product %', NEW.user_id, NEW.product_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_reviews_verified_purchase
    BEFORE INSERT ON reviews
    FOR EACH ROW EXECUTE FUNCTION trg_review_verified_purchase();

-- ---------------------------------------------------------------------
-- 8. Універсальний журнал змін (старе/нове значення рядка у JSONB)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_write_audit_log() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_old jsonb;
    v_new jsonb;
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN v_old := to_jsonb(OLD) - 'password_hash'; END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN v_new := to_jsonb(NEW) - 'password_hash'; END IF;

    INSERT INTO audit_log (table_name, record_id, action, old_data, new_data, changed_by)
    VALUES (TG_TABLE_NAME,
            COALESCE((v_new ->> 'id')::bigint, (v_old ->> 'id')::bigint),
            TG_OP, v_old, v_new, fn_current_actor());
    RETURN NULL;
END;
$$;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['users', 'stores', 'products', 'coupons']
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%1$s_audit_log AFTER INSERT OR UPDATE OR DELETE ON %1$I
             FOR EACH ROW EXECUTE FUNCTION trg_write_audit_log()', t);
    END LOOP;
END;
$$;
