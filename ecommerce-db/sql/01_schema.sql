-- =====================================================================
--  Електронна комерція з кількома магазинами (multi-store e-commerce)
--  СУБД: PostgreSQL 14+ (перевірено на 16)
--  Файл 01: схема, типи, таблиці, обмеження, унікальні індекси
--
--  Запуск: на порожній БД (скрипт перестворює схему "shop").
-- =====================================================================

DROP SCHEMA IF EXISTS shop CASCADE;
CREATE SCHEMA shop;
SET search_path TO shop, public;

-- ---------------------------------------------------------------------
-- Перелічувані типи
-- ---------------------------------------------------------------------
CREATE TYPE order_status     AS ENUM ('pending', 'paid', 'processing', 'shipped', 'delivered', 'cancelled', 'refunded');
CREATE TYPE payment_status   AS ENUM ('pending', 'completed', 'failed', 'refunded');
CREATE TYPE payment_method   AS ENUM ('card', 'cash_on_delivery', 'bank_transfer', 'paypal');
CREATE TYPE shipment_status  AS ENUM ('preparing', 'in_transit', 'delivered', 'returned');
CREATE TYPE inventory_reason AS ENUM ('restock', 'sale', 'cancellation', 'adjustment', 'return');
CREATE TYPE discount_type    AS ENUM ('percent', 'fixed');

CREATE SEQUENCE order_number_seq START 1000;

-- =====================================================================
--  1-3. Користувачі та ролі
-- =====================================================================
CREATE TABLE roles (
    id          smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        varchar(50) NOT NULL UNIQUE,
    description text
);

-- [SOFT DELETE] + [AUDIT: updated_at / updated_by]
CREATE TABLE users (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email         varchar(255) NOT NULL,
    password_hash varchar(255) NOT NULL,
    first_name    varchar(100) NOT NULL,
    last_name     varchar(100) NOT NULL,
    phone         varchar(30),
    created_at    timestamptz  NOT NULL DEFAULT now(),
    -- audit
    updated_at    timestamptz,
    updated_by    bigint REFERENCES users(id),
    -- soft delete
    is_deleted    boolean      NOT NULL DEFAULT false,
    deleted_at    timestamptz,
    deleted_by    bigint REFERENCES users(id),
    CONSTRAINT ck_users_email   CHECK (position('@' in email) > 1),
    CONSTRAINT ck_users_deleted CHECK (is_deleted = (deleted_at IS NOT NULL))
);

CREATE TABLE user_roles (
    user_id     bigint   NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_id     smallint NOT NULL REFERENCES roles(id),
    assigned_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, role_id)
);

CREATE TABLE addresses (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id     bigint       NOT NULL REFERENCES users(id),
    label       varchar(50)  NOT NULL DEFAULT 'Дім',
    country     varchar(80)  NOT NULL,
    city        varchar(100) NOT NULL,
    street_line varchar(255) NOT NULL,
    postal_code varchar(20),
    is_default  boolean      NOT NULL DEFAULT false,
    created_at  timestamptz  NOT NULL DEFAULT now()
);

-- =====================================================================
--  4-5. Магазини та персонал
-- =====================================================================
-- [SOFT DELETE] + [AUDIT]
CREATE TABLE stores (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_id      bigint       NOT NULL REFERENCES users(id),
    name          varchar(150) NOT NULL,
    slug          varchar(100) NOT NULL,
    description   text,
    contact_email varchar(255),
    currency      char(3)      NOT NULL DEFAULT 'UAH',
    is_active     boolean      NOT NULL DEFAULT true,
    created_at    timestamptz  NOT NULL DEFAULT now(),
    updated_at    timestamptz,
    updated_by    bigint REFERENCES users(id),
    is_deleted    boolean      NOT NULL DEFAULT false,
    deleted_at    timestamptz,
    deleted_by    bigint REFERENCES users(id),
    CONSTRAINT ck_stores_deleted CHECK (is_deleted = (deleted_at IS NOT NULL))
);

CREATE TABLE store_staff (
    store_id  bigint      NOT NULL REFERENCES stores(id),
    user_id   bigint      NOT NULL REFERENCES users(id),
    position  varchar(50) NOT NULL DEFAULT 'manager',
    hired_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (store_id, user_id)
);

-- =====================================================================
--  6-9. Каталог: категорії, бренди, товари, пропозиції магазинів
-- =====================================================================
-- [SOFT DELETE] + [AUDIT]
CREATE TABLE categories (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_id  bigint REFERENCES categories(id),
    name       varchar(120) NOT NULL,
    slug       varchar(120) NOT NULL,
    created_at timestamptz  NOT NULL DEFAULT now(),
    updated_at timestamptz,
    updated_by bigint REFERENCES users(id),
    is_deleted boolean      NOT NULL DEFAULT false,
    deleted_at timestamptz,
    deleted_by bigint REFERENCES users(id),
    CONSTRAINT ck_categories_deleted CHECK (is_deleted = (deleted_at IS NOT NULL))
);

CREATE TABLE brands (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name    varchar(120) NOT NULL UNIQUE,
    country varchar(80)
);

-- Глобальний каталог товарів (спільний для всіх магазинів)
-- [SOFT DELETE] + [AUDIT]
CREATE TABLE products (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_id   bigint       NOT NULL REFERENCES categories(id),
    brand_id      bigint       REFERENCES brands(id),
    sku           varchar(64)  NOT NULL,
    name          varchar(255) NOT NULL,
    description   text,
    attributes    jsonb        NOT NULL DEFAULT '{}'::jsonb,
    -- повнотекстовий пошук (GIN-індекс у 06_indexes.sql)
    search_vector tsvector GENERATED ALWAYS AS (
                      to_tsvector('simple', coalesce(name, '') || ' ' || coalesce(description, ''))
                  ) STORED,
    created_at    timestamptz  NOT NULL DEFAULT now(),
    updated_at    timestamptz,
    updated_by    bigint REFERENCES users(id),
    is_deleted    boolean      NOT NULL DEFAULT false,
    deleted_at    timestamptz,
    deleted_by    bigint REFERENCES users(id),
    CONSTRAINT ck_products_deleted CHECK (is_deleted = (deleted_at IS NOT NULL))
);

-- Пропозиція товару в конкретному магазині: ціна та залишок (зв'язок M:N products <-> stores)
-- [SOFT DELETE] + [AUDIT]
CREATE TABLE store_products (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    store_id   bigint        NOT NULL REFERENCES stores(id),
    product_id bigint        NOT NULL REFERENCES products(id),
    price      numeric(12,2) NOT NULL CHECK (price >= 0),
    stock_qty  integer       NOT NULL DEFAULT 0 CHECK (stock_qty >= 0),
    is_listed  boolean       NOT NULL DEFAULT true,
    created_at timestamptz   NOT NULL DEFAULT now(),
    updated_at timestamptz,
    updated_by bigint REFERENCES users(id),
    is_deleted boolean       NOT NULL DEFAULT false,
    deleted_at timestamptz,
    deleted_by bigint REFERENCES users(id),
    CONSTRAINT ck_store_products_deleted CHECK (is_deleted = (deleted_at IS NOT NULL))
);

-- =====================================================================
--  10-11. Кошик
-- =====================================================================
CREATE TABLE carts (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id    bigint      NOT NULL REFERENCES users(id),
    store_id   bigint      NOT NULL REFERENCES stores(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_carts_user_store UNIQUE (user_id, store_id)   -- один кошик на магазин
);

CREATE TABLE cart_items (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cart_id          bigint  NOT NULL REFERENCES carts(id) ON DELETE CASCADE,
    store_product_id bigint  NOT NULL REFERENCES store_products(id),
    quantity         integer NOT NULL CHECK (quantity > 0),
    added_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_cart_items UNIQUE (cart_id, store_product_id)
);

-- =====================================================================
--  12-13. Промокоди та способи доставки
-- =====================================================================
-- store_id NULL = промокод діє в усіх магазинах
-- [SOFT DELETE] + [AUDIT]
CREATE TABLE coupons (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    store_id         bigint REFERENCES stores(id),
    code             varchar(50)   NOT NULL,
    discount_type    discount_type NOT NULL,
    discount_value   numeric(12,2) NOT NULL CHECK (discount_value > 0),
    min_order_amount numeric(12,2) NOT NULL DEFAULT 0 CHECK (min_order_amount >= 0),
    max_uses         integer CHECK (max_uses IS NULL OR max_uses > 0),
    used_count       integer       NOT NULL DEFAULT 0 CHECK (used_count >= 0),
    valid_from       timestamptz   NOT NULL DEFAULT now(),
    valid_to         timestamptz,
    created_at       timestamptz   NOT NULL DEFAULT now(),
    updated_at       timestamptz,
    updated_by       bigint REFERENCES users(id),
    is_deleted       boolean       NOT NULL DEFAULT false,
    deleted_at       timestamptz,
    deleted_by       bigint REFERENCES users(id),
    CONSTRAINT ck_coupons_percent CHECK (discount_type <> 'percent' OR discount_value <= 100),
    CONSTRAINT ck_coupons_period  CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT ck_coupons_deleted CHECK (is_deleted = (deleted_at IS NOT NULL))
);

CREATE TABLE shipping_methods (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    store_id       bigint        NOT NULL REFERENCES stores(id),
    name           varchar(100)  NOT NULL,
    base_cost      numeric(12,2) NOT NULL CHECK (base_cost >= 0),
    estimated_days integer       NOT NULL DEFAULT 3 CHECK (estimated_days > 0),
    is_active      boolean       NOT NULL DEFAULT true
);

-- =====================================================================
--  14-18. Замовлення, оплата, доставка
-- =====================================================================
-- Замовлення завжди належить одному магазину. [AUDIT]
CREATE TABLE orders (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_number        varchar(30)   NOT NULL UNIQUE,
    user_id             bigint        NOT NULL REFERENCES users(id),
    store_id            bigint        NOT NULL REFERENCES stores(id),
    shipping_address_id bigint        NOT NULL REFERENCES addresses(id),
    shipping_method_id  bigint        NOT NULL REFERENCES shipping_methods(id),
    coupon_id           bigint        REFERENCES coupons(id),
    status              order_status  NOT NULL DEFAULT 'pending',
    subtotal            numeric(12,2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    discount_amount     numeric(12,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    shipping_cost       numeric(12,2) NOT NULL DEFAULT 0 CHECK (shipping_cost >= 0),
    total_amount        numeric(12,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
    note                text,
    created_at          timestamptz   NOT NULL DEFAULT now(),
    updated_at          timestamptz,
    updated_by          bigint REFERENCES users(id)
);

CREATE TABLE order_items (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id         bigint        NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    store_product_id bigint        NOT NULL REFERENCES store_products(id),
    product_name     varchar(255)  NOT NULL,                       -- знімок назви на момент покупки
    unit_price       numeric(12,2) NOT NULL CHECK (unit_price >= 0), -- знімок ціни
    quantity         integer       NOT NULL CHECK (quantity > 0),
    line_total       numeric(12,2) GENERATED ALWAYS AS (unit_price * quantity) STORED,
    CONSTRAINT uq_order_items UNIQUE (order_id, store_product_id)
);

CREATE TABLE order_status_history (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id   bigint       NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    old_status order_status,
    new_status order_status NOT NULL,
    changed_at timestamptz  NOT NULL DEFAULT now(),
    changed_by bigint REFERENCES users(id)
);

CREATE TABLE payments (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id        bigint         NOT NULL REFERENCES orders(id),
    amount          numeric(12,2)  NOT NULL CHECK (amount > 0),
    method          payment_method NOT NULL,
    status          payment_status NOT NULL DEFAULT 'pending',
    transaction_ref varchar(100),
    paid_at         timestamptz,
    created_at      timestamptz    NOT NULL DEFAULT now()
);

CREATE TABLE shipments (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id        bigint          NOT NULL UNIQUE REFERENCES orders(id),
    carrier         varchar(100)    NOT NULL,
    tracking_number varchar(100),
    status          shipment_status NOT NULL DEFAULT 'preparing',
    shipped_at      timestamptz,
    delivered_at    timestamptz
);

-- =====================================================================
--  19. Відгуки
-- =====================================================================
-- [SOFT DELETE] + [AUDIT]
CREATE TABLE reviews (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id bigint   NOT NULL REFERENCES products(id),
    user_id    bigint   NOT NULL REFERENCES users(id),
    rating     smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
    title      varchar(150),
    body       text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz,
    updated_by bigint REFERENCES users(id),
    is_deleted boolean     NOT NULL DEFAULT false,
    deleted_at timestamptz,
    deleted_by bigint REFERENCES users(id),
    CONSTRAINT ck_reviews_deleted CHECK (is_deleted = (deleted_at IS NOT NULL))
);

-- =====================================================================
--  20-21. Склад і журнал аудиту
-- =====================================================================
CREATE TABLE inventory_movements (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    store_product_id bigint           NOT NULL REFERENCES store_products(id),
    quantity_change  integer          NOT NULL CHECK (quantity_change <> 0),
    reason           inventory_reason NOT NULL,
    order_id         bigint REFERENCES orders(id),
    created_at       timestamptz      NOT NULL DEFAULT now(),
    created_by       bigint REFERENCES users(id)
);

CREATE TABLE audit_log (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name text        NOT NULL,
    record_id  bigint      NOT NULL,
    action     text        NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
    old_data   jsonb,
    new_data   jsonb,
    changed_by bigint,                     -- без FK: журнал має пережити видалення користувача
    changed_at timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
--  Унікальність серед "живих" записів (часткові унікальні індекси):
--  після soft delete значення (email, sku, code...) можна використати знову
-- =====================================================================
CREATE UNIQUE INDEX ux_users_email_active          ON users (lower(email))            WHERE NOT is_deleted;
CREATE UNIQUE INDEX ux_stores_slug_active          ON stores (lower(slug))            WHERE NOT is_deleted;
CREATE UNIQUE INDEX ux_categories_slug_active      ON categories (lower(slug))        WHERE NOT is_deleted;
CREATE UNIQUE INDEX ux_products_sku_active         ON products (lower(sku))           WHERE NOT is_deleted;
CREATE UNIQUE INDEX ux_store_products_active       ON store_products (store_id, product_id) WHERE NOT is_deleted;
CREATE UNIQUE INDEX ux_coupons_code_active         ON coupons (lower(code))           WHERE NOT is_deleted;
CREATE UNIQUE INDEX ux_reviews_user_product_active ON reviews (user_id, product_id)   WHERE NOT is_deleted;
