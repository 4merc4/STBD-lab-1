-- =====================================================================
--  Файл 07: демонстраційні дані (заповнення виконується викликом
--  збережених процедур, тож усі тригери та правила працюють як у проді)
-- =====================================================================
SET search_path TO shop, public;

INSERT INTO roles (name, description) VALUES
    ('admin',       'Адміністратор платформи'),
    ('store_owner', 'Власник магазину'),
    ('store_staff', 'Працівник магазину'),
    ('customer',    'Покупець');

DO $$
DECLARE
    -- користувачі
    v_admin bigint; v_owner1 bigint; v_owner2 bigint; v_staff bigint;
    v_c1 bigint; v_c2 bigint; v_c3 bigint;
    -- магазини
    v_tech bigint; v_books bigint; v_style bigint;
    -- каталог
    v_cat_el bigint; v_cat_phone bigint; v_cat_laptop bigint; v_cat_book bigint; v_cat_cloth bigint;
    v_b_samsung bigint; v_b_lenovo bigint; v_b_nike bigint; v_b_ranok bigint;
    v_p_phone bigint; v_p_laptop bigint; v_p_buds bigint; v_p_book1 bigint; v_p_book2 bigint;
    v_p_shoes bigint; v_p_hoodie bigint;
    -- пропозиції
    v_sp_phone bigint; v_sp_laptop bigint; v_sp_buds bigint; v_sp_book1 bigint; v_sp_book2 bigint;
    v_sp_shoes bigint; v_sp_hoodie bigint; v_sp_book1_tech bigint;
    -- допоміжні
    v_ship_tech bigint; v_ship_tech2 bigint; v_ship_books bigint; v_ship_style bigint;
    v_a1 bigint; v_a2 bigint; v_a3 bigint;
    v_total numeric; v_coupon bigint; v_cart bigint; v_ord bigint; v_pay bigint; v_shp bigint; v_rev bigint;
BEGIN
    -- ---- користувачі ---------------------------------------------------
    CALL sp_user_register('admin@shop.ua',    '$2a$11$seedhash.admin',  'Андрій',  'Адміненко', '+380501110001', v_admin);
    CALL sp_set_actor(v_admin);                                    -- далі всі зміни "від імені" адміна
    CALL sp_user_assign_role(v_admin, 'admin');
    CALL sp_user_register('owner.tech@shop.ua',  '$2a$11$seedhash.o1',  'Олексій', 'Шевчук',    '+380501110002', v_owner1);
    CALL sp_user_register('owner.books@shop.ua', '$2a$11$seedhash.o2',  'Марія',   'Коваленко', '+380501110003', v_owner2);
    CALL sp_user_register('staff@shop.ua',       '$2a$11$seedhash.st',  'Ігор',    'Бойко',     '+380501110004', v_staff);
    CALL sp_user_register('olena@example.com',   '$2a$11$seedhash.c1',  'Олена',   'Мельник',   '+380671110005', v_c1);
    CALL sp_user_register('taras@example.com',   '$2a$11$seedhash.c2',  'Тарас',   'Гринюк',    '+380671110006', v_c2);
    CALL sp_user_register('iryna@example.com',   '$2a$11$seedhash.c3',  'Ірина',   'Савчук',    NULL,            v_c3);

    -- ---- магазини ------------------------------------------------------
    CALL sp_store_create(v_owner1, 'TechHub',   'techhub',   'Електроніка та гаджети',   'info@techhub.ua',   'UAH', v_tech);
    CALL sp_store_create(v_owner2, 'BookWorld', 'bookworld', 'Книгарня',                 'info@bookworld.ua', 'UAH', v_books);
    CALL sp_store_create(v_owner1, 'StyleLab',  'stylelab',  'Одяг та взуття',           'info@stylelab.ua',  'UAH', v_style);
    CALL sp_store_staff_add(v_tech, v_staff, 'sales manager');

    CALL sp_shipping_method_create(v_tech,  'Нова Пошта (відділення)', 80,  2, v_ship_tech);
    CALL sp_shipping_method_create(v_tech,  'Кур''єр',                 150, 1, v_ship_tech2);
    CALL sp_shipping_method_create(v_books, 'Укрпошта',                50,  5, v_ship_books);
    CALL sp_shipping_method_create(v_style, 'Нова Пошта (відділення)', 80,  3, v_ship_style);

    CALL sp_coupon_create(NULL,   'WELCOME10', 'percent', 10, 500, NULL, 365, v_coupon);   -- глобальний
    CALL sp_coupon_create(v_tech, 'TECH500',   'fixed',  500, 5000, 100, 30,  v_coupon);   -- лише TechHub

    -- ---- категорії та бренди ------------------------------------------
    CALL sp_category_create('Електроніка',  'electronics', NULL,      v_cat_el);
    CALL sp_category_create('Смартфони',    'smartphones', v_cat_el,  v_cat_phone);
    CALL sp_category_create('Ноутбуки',     'laptops',     v_cat_el,  v_cat_laptop);
    CALL sp_category_create('Книги',        'books',       NULL,      v_cat_book);
    CALL sp_category_create('Одяг',         'clothing',    NULL,      v_cat_cloth);

    CALL sp_brand_create('Samsung', 'Південна Корея', v_b_samsung);
    CALL sp_brand_create('Lenovo',  'Китай',          v_b_lenovo);
    CALL sp_brand_create('Nike',    'США',            v_b_nike);
    CALL sp_brand_create('Рідна мова', 'Україна',     v_b_ranok);

    -- ---- товари (глобальний каталог) ----------------------------------
    CALL sp_product_create(v_cat_phone,  v_b_samsung, 'SM-S24-128', 'Смартфон Samsung Galaxy S24 128GB',
                           'Флагманський смартфон з AMOLED екраном та NFC', '{"color":"black","storage_gb":128}', v_p_phone);
    CALL sp_product_create(v_cat_laptop, v_b_lenovo,  'LN-IPS3-15', 'Ноутбук Lenovo IdeaPad Slim 3 15"',
                           'Ноутбук для навчання та роботи, 16 GB RAM', '{"ram_gb":16,"ssd_gb":512}', v_p_laptop);
    CALL sp_product_create(v_cat_el,     v_b_samsung, 'SM-BUDS-2', 'Бездротові навушники Samsung Buds2',
                           'Навушники з активним шумозаглушенням', '{"color":"white"}', v_p_buds);
    CALL sp_product_create(v_cat_book,   v_b_ranok,   'BK-0001', 'Книга "Кобзар"',
                           'Збірка поезій Тараса Шевченка, подарункове видання', '{"pages":480}', v_p_book1);
    CALL sp_product_create(v_cat_book,   v_b_ranok,   'BK-0002', 'Книга "Тіні забутих предків"',
                           'Повість Михайла Коцюбинського', '{"pages":160}', v_p_book2);
    CALL sp_product_create(v_cat_cloth,  v_b_nike,    'NK-AIR-42', 'Кросівки Nike Air Max 42',
                           'Чоловічі кросівки для щоденного носіння', '{"size":42}', v_p_shoes);
    CALL sp_product_create(v_cat_cloth,  NULL,        'HD-GRY-L', 'Худі сіре L',
                           'Тепле худі з капюшоном', '{"size":"L","color":"grey"}', v_p_hoodie);

    -- ---- пропозиції магазинів (ціна + залишок) ------------------------
    CALL sp_store_product_set(v_tech,  v_p_phone,  32999, 10, v_sp_phone);
    CALL sp_store_product_set(v_tech,  v_p_laptop, 24999,  5, v_sp_laptop);
    CALL sp_store_product_set(v_tech,  v_p_buds,    3999,  3, v_sp_buds);
    CALL sp_store_product_set(v_books, v_p_book1,    650, 40, v_sp_book1);
    CALL sp_store_product_set(v_books, v_p_book2,    280, 25, v_sp_book2);
    CALL sp_store_product_set(v_tech,  v_p_book1,    700,  2, v_sp_book1_tech);   -- той самий товар у двох магазинах
    CALL sp_store_product_set(v_style, v_p_shoes,   4800,  8, v_sp_shoes);
    CALL sp_store_product_set(v_style, v_p_hoodie,  1400, 15, v_sp_hoodie);

    -- ---- адреси покупців ----------------------------------------------
    CALL sp_address_add(v_c1, 'Дім',  'Україна', 'Київ',    'вул. Хрещатик, 1, кв. 5',   '01001', true, v_a1);
    CALL sp_address_add(v_c2, 'Дім',  'Україна', 'Львів',   'пл. Ринок, 10',             '79000', true, v_a2);
    CALL sp_address_add(v_c3, 'Робота','Україна', 'Одеса',   'вул. Дерибасівська, 12',    '65000', true, v_a3);

    -- ---- замовлення 1: Олена купує в TechHub, повний цикл --------------
    CALL sp_set_actor(v_c1);
    CALL sp_cart_add_item(v_c1, v_sp_phone, 1, v_cart);
    CALL sp_cart_add_item(v_c1, v_sp_buds,  2, v_cart);
    CALL sp_order_place(v_c1, v_tech, v_a1, v_ship_tech, 'WELCOME10', 'Подарунок', v_ord);
    SELECT total_amount INTO v_total FROM orders WHERE id = v_ord;
    CALL sp_payment_register(v_ord, 'card', v_total, 'TX-SEED-0001', v_pay);
    CALL sp_set_actor(v_staff);
    CALL sp_shipment_create(v_ord, 'Нова Пошта', '59000111222333', v_shp);
    CALL sp_shipment_mark_delivered(v_ord);
    CALL sp_set_actor(v_c1);
    CALL sp_review_add(v_c1, v_p_phone, 5, 'Чудовий смартфон', 'Швидкий, камера супер.', v_rev);
    CALL sp_review_add(v_c1, v_p_buds,  4, 'Добре, але дорого', NULL, v_rev);

    -- ---- замовлення 2: Тарас купує книги, оплачено, ще не відправлено --
    CALL sp_set_actor(v_c2);
    CALL sp_cart_add_item(v_c2, v_sp_book1, 2, v_cart);
    CALL sp_cart_add_item(v_c2, v_sp_book2, 1, v_cart);
    CALL sp_order_place(v_c2, v_books, v_a2, v_ship_books, NULL, NULL, v_ord);
    SELECT total_amount INTO v_total FROM orders WHERE id = v_ord;
    CALL sp_payment_register(v_ord, 'paypal', v_total, 'TX-SEED-0002', v_pay);

    -- ---- замовлення 3: Ірина створює і скасовує замовлення (повернення на склад)
    CALL sp_set_actor(v_c3);
    CALL sp_cart_add_item(v_c3, v_sp_shoes, 1, v_cart);
    CALL sp_order_place(v_c3, v_style, v_a3, v_ship_style, NULL, NULL, v_ord);
    CALL sp_order_change_status(v_ord, 'cancelled');

    -- ---- замовлення 4: Ірина має очікуючий платіж у TechHub ------------
    CALL sp_cart_add_item(v_c3, v_sp_laptop, 1, v_cart);
    CALL sp_order_place(v_c3, v_tech, v_a3, v_ship_tech2, 'TECH500', 'Подзвонити перед доставкою', v_ord);

    CALL sp_set_actor(NULL);
END;
$$;

ANALYZE;
