-- ============================================================================
-- 003_procedures.sql — генератор и очистка тестовых данных (FOOD-102, FOOD-103).
--
-- insert_test_data(value int):
--   Распределение строк — по BR-11.7. Процедура вызывается многократно БЕЗ
--   очистки: все вставки — чистые (новые UUID), уникальность строковых
--   полей обеспечивается суффиксом-счётчиком «база + i», где база — текущее
--   число строк таблицы на момент вызова. Другие процедуры/функции схемы
--   (courier_salary, add_product, rating_change) НЕ вызываются (samples, §10):
--   courier_pay считается прямыми INSERT-ами по формуле BR-10.2, рейтинги
--   блюд/ресторанов пересчитываются триггером rating_change при вставке
--   отзывов, в генераторе руками не заполняются (samples, §19).
--
-- erase_test_data():
--   TRUNCATE всех 12 таблиц одной командой (порядок не важен: TRUNCATE
--   обрабатывает список атомарно; CASCADE не используем намеренно — список
--   явный, чтобы случайно не задеть чужие объекты). Типы, функции, триггеры
--   и представления не трогает. Повторный вызов не падает.
-- ============================================================================
SET search_path TO frolenko_food, exts;

DROP PROCEDURE IF EXISTS insert_test_data(value int);
DROP PROCEDURE IF EXISTS erase_test_data();

-- ---------------------------------------------------------------------------
-- Генератор тестовых данных
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE insert_test_data(value int)
LANGUAGE plpgsql
AS $proc$
DECLARE
    -- смещения счётчиков для гарантированно уникальных строк (BR-2.2 и пр.)
    v_base_client  int;
    v_base_courier int;
    v_base_cat     int;
    v_base_rest    int;
    v_base_addr    int;
    v_base_product int;
    -- массивы ID вставленных строк (связность, samples §7)
    v_cat_ids     uuid[];
    v_courier_ids uuid[];
    v_fired       boolean[];
    v_coeffs      numeric[];
    v_client_ids  uuid[];
    v_addr_rest   uuid[];
    v_addr_client uuid[];
    v_rest_ids    uuid[];
    v_product_ids uuid[];
    v_order_ids   uuid[];
    v_months      timestamp[];
    -- временные переменные
    v_id        uuid;
    v_oid       uuid;
    v_i         int;
    v_j         int;
    v_k         int;
    v_m         int;
    v_ci        int;          -- индекс клиента
    v_ri        int;          -- индекс ресторана
    v_idx       int;
    v_start     int;
    v_len       int;
    v_fired_flag boolean;
    v_hire      date;
    v_dismiss   date;
    v_ws        time;
    v_we        time;
    v_order_ts  timestamp;
    v_deliv_ts  timestamp;
    v_amount    numeric;
    v_comm_sum  numeric;
    v_cnt       int;
    v_ca        uuid[];
    v_cand      uuid[];
    v_prods     uuid[];
    v_total     numeric;
    v_y         int;
    v_mnth      int;
    v_status    order_status;
    v_coeff     numeric;
    -- массивы значений enum-типов: значения берутся строго через
    -- enum_range() (FOOD-102 AC), веса распределений задаются индексами
    v_courier_statuses   courier_status[];
    v_rest_statuses      restaurant_status[];
    v_prod_statuses      product_status[];
    v_order_statuses     order_status[];
    v_pay_statuses       payment_status[];
    v_order_pay_statuses order_pay_status[];
    v_review_types       review_entity_type[];
    -- периоды работы курьеров: заказ датируется только внутри периода работы
    -- назначенного курьера (hire_date .. dismissal_date/сегодня)
    v_hire_dates    date[];
    v_dismiss_dates date[];
BEGIN
    IF value IS NULL OR value < 1 THEN
        RAISE EXCEPTION 'insert_test_data: value должно быть >= 1, получено %', value;
    END IF;

    -- Значения enum-типов — только через enum_range() (FOOD-102 AC).
    -- Порядок индексов = порядок объявления значений в 001_types.sql:
    --   courier:   1 свободен, 2 занят, 3 на_доставке, 4 уволен
    --   restaurant:1 активен, 2 неактивен
    --   product:   1 доступно, 2 нет_в_наличии, 3 архив
    --   order:     1 создан, 2 готовится, 3 в_доставке, 4 доставлен, 5 отменён
    --   payment:   1 успех, 2 ошибка, 3 в_обработке
    --   order_pay: 1 ожидает, 2 оплачен, 3 ошибка
    v_courier_statuses   := enum_range(NULL::courier_status);
    v_rest_statuses      := enum_range(NULL::restaurant_status);
    v_prod_statuses      := enum_range(NULL::product_status);
    v_order_statuses     := enum_range(NULL::order_status);
    v_pay_statuses       := enum_range(NULL::payment_status);
    v_order_pay_statuses := enum_range(NULL::order_pay_status);
    --   review:    1 блюдо, 2 ресторан, 3 заказ
    v_review_types       := enum_range(NULL::review_entity_type);

    -- Базы счётчиков: сколько строк уже есть (генератор работает без очистки)
    SELECT count(*) INTO v_base_client  FROM client;
    SELECT count(*) INTO v_base_courier FROM courier;
    SELECT count(*) INTO v_base_cat     FROM product_category;
    SELECT count(*) INTO v_base_rest    FROM restaurant;
    SELECT count(*) INTO v_base_addr    FROM address;
    SELECT count(*) INTO v_base_product FROM product;

    -- Временная таблица связи клиент↔адрес для order.address_id (BR-7.4)
    CREATE TEMP TABLE IF NOT EXISTS tmp_fx_client_addr (
        client_id  uuid,
        address_id uuid
    ) ON COMMIT PRESERVE ROWS;
    DELETE FROM tmp_fx_client_addr;

    -- ========================================================================
    -- 1) Справочники без FK (samples §11)
    -- ========================================================================

    -- product_category: value строк (BR-11.7)
    FOR v_i IN 1..value LOOP
        INSERT INTO product_category (product_category_name)
        VALUES ('Категория ' || (v_base_cat + v_i))
        RETURNING product_category_id INTO v_id;
        v_cat_ids := v_cat_ids || v_id;
    END LOOP;

    -- courier: value строк (BR-11.7). Коэффициент на старте 0.1 (BR-6.5),
    -- итоговый пересчитается после courier_pay (BR-10.2). Первый курьер —
    -- всегда работающий (BR-6.6).
    FOR v_i IN 1..value LOOP
        v_fired_flag := (v_i > 1) AND (random() < 0.2);
        v_hire := current_date - (random() * 180)::int;
        IF v_fired_flag THEN
            v_dismiss := LEAST(v_hire + (1 + (random() * 150)::int), current_date);
            INSERT INTO courier (fio, phone_number, status, hire_date, dismissal_date, coefficient)
            VALUES (
                (ARRAY['Иванов','Петров','Сидоров','Кузнецов','Смирнов','Попов','Волков','Соколов'])[1 + floor(random() * 8)::int]
                    || ' ' || (ARRAY['Иван','Петр','Сидор','Алексей','Дмитрий','Сергей'])[1 + floor(random() * 6)::int]
                    || ' ' || (ARRAY['Иванович','Петрович','Сидорович','Александрович'])[1 + floor(random() * 4)::int]
                    || ' №' || (v_base_courier + v_i),
                '+7' || lpad((v_base_courier + v_i)::text, 10, '0'),
                v_courier_statuses[4],                       -- 'уволен'
                v_hire,
                v_dismiss,
                0.1)
            RETURNING courier_id INTO v_id;
            v_hire_dates    := v_hire_dates    || v_hire;
            v_dismiss_dates := v_dismiss_dates || v_dismiss;
        ELSE
            INSERT INTO courier (fio, phone_number, status, hire_date, coefficient)
            VALUES (
                (ARRAY['Иванов','Петров','Сидоров','Кузнецов','Смирнов','Попов','Волков','Соколов'])[1 + floor(random() * 8)::int]
                    || ' ' || (ARRAY['Иван','Петр','Сидор','Алексей','Дмитрий','Сергей'])[1 + floor(random() * 6)::int]
                    || ' ' || (ARRAY['Иванович','Петрович','Сидорович','Александрович'])[1 + floor(random() * 4)::int]
                    || ' №' || (v_base_courier + v_i),
                '+7' || lpad((v_base_courier + v_i)::text, 10, '0'),
                v_courier_statuses[1 + floor(random() * 3)::int],  -- свободен/занят/на_доставке
                v_hire,
                0.1)
            RETURNING courier_id INTO v_id;
            v_hire_dates    := v_hire_dates    || v_hire;
            v_dismiss_dates := v_dismiss_dates || NULL::date;
        END IF;
        v_courier_ids := v_courier_ids || v_id;
        v_fired  := v_fired  || v_fired_flag;
        v_coeffs := v_coeffs || 0.1::numeric;
    END LOOP;

    -- address: value * 5 (BR-11.7): первые value — под рестораны,
    -- остальные value * 4 — под клиентов (BR-11.7, ловушка 20)
    FOR v_i IN 1..value * 5 LOOP
        INSERT INTO address (street, house_number, apartment_office)
        VALUES (
            'Улица ' || (v_base_addr + v_i),
            (1 + floor(random() * 200)::int)::text,
            CASE WHEN random() < 0.3 THEN NULL ELSE (1 + floor(random() * 500)::int)::text END)
        RETURNING address_id INTO v_id;
        IF v_i <= value THEN
            v_addr_rest := v_addr_rest || v_id;
        ELSE
            v_addr_client := v_addr_client || v_id;
        END IF;
    END LOOP;

    -- ========================================================================
    -- 2) Справочники с FK
    -- ========================================================================

    -- restaurant: value строк (BR-11.7), адрес 1:1 (BR-3.3)
    FOR v_i IN 1..value LOOP
        v_ws := time '06:00' + (floor(random() * 8 * 3600))::int * interval '1 second';          -- 06:00–13:59:59
        v_we := v_ws + (4 * 3600 + floor(random() * 6 * 3600))::int * interval '1 second';        -- +4–10 ч, всегда < 24:00 (BR-4.4)
        INSERT INTO restaurant (restaurant_name, address_id, description, work_start, work_end, company_details, status)
        VALUES (
            'Ресторан ' || (v_base_rest + v_i),
            v_addr_rest[v_i],
            'Описание ресторана. ' || md5(random()::text) || md5(random()::text),
            v_ws,
            v_we,
            'ИНН ' || lpad((v_base_rest + v_i)::text, 10, '0')
                || ', ОГРН ' || lpad((v_base_rest + v_i)::text, 13, '0')
                || ', р/с ' || lpad((v_base_rest + v_i)::text, 20, '0'),
            CASE WHEN random() < 0.15 THEN v_rest_statuses[2] ELSE v_rest_statuses[1] END)
        RETURNING restaurant_id INTO v_id;
        v_rest_ids := v_rest_ids || v_id;
    END LOOP;

    -- client: value строк (BR-11.7); логин/телефон уникальны (BR-2.2),
    -- пароль — MD5 (BR-2.3)
    FOR v_i IN 1..value LOOP
        INSERT INTO client (login, password, phone_number)
        VALUES (
            'client_' || (v_base_client + v_i),
            md5(random()::text),
            '+7' || lpad((v_base_client + v_i)::text, 10, '0'))
        RETURNING client_id INTO v_id;
        v_client_ids := v_client_ids || v_id;
    END LOOP;

    -- ========================================================================
    -- 3) M:N справочников: client_address (samples §8a)
    -- ========================================================================

    -- Каждому клиенту 1..3 адреса; непрерывный срез массива гарантирует
    -- отсутствие дубликатов (client_id, address_id) в рамках клиента (BR-2.5,
    -- ловушка 9). Один адрес может быть у нескольких клиентов (BR-2.4).
    v_len := array_length(v_addr_client, 1);
    FOR v_i IN 1..value LOOP
        v_k := 1 + floor(random() * 3)::int;                        -- 1..3
        v_start := floor(random() * (v_len - v_k + 1))::int;        -- 0..len-k
        FOR v_j IN 0..v_k - 1 LOOP
            INSERT INTO client_address (client_id, address_id)
            VALUES (v_client_ids[v_i], v_addr_client[v_start + v_j + 1]);
            INSERT INTO tmp_fx_client_addr (client_id, address_id)
            VALUES (v_client_ids[v_i], v_addr_client[v_start + v_j + 1]);
        END LOOP;
    END LOOP;

    -- ========================================================================
    -- 4) Транзакционные: product, "order"
    -- ========================================================================

    -- product: value * 5 (BR-11.7). Ресторан round-robin → у каждого ровно 5
    -- блюд; категория — блоками по 5 (samples §8b: в заказе 1..5 разных блюд
    -- того же ресторана).
    FOR v_i IN 1..value * 5 LOOP
        INSERT INTO product (product_name, product_category_id, price, restaurant_id, photo_url, status, description)
        VALUES (
            'Блюдо ' || (v_base_product + v_i),
            v_cat_ids[1 + ((v_i - 1) / 5)],
            round((100 + random() * 900)::numeric, 2),
            v_rest_ids[1 + (v_i - 1) % value],
            CASE WHEN random() < 0.3 THEN NULL ELSE 'https://cdn.foodexpress.ru/img/' || md5(random()::text) || '.jpg' END,
            CASE
                WHEN random() < 0.08 THEN v_prod_statuses[2]   -- нет_в_наличии
                WHEN random() < 0.12 THEN v_prod_statuses[3]   -- архив
                ELSE v_prod_statuses[1]                        -- доступно
            END,
            'Описание блюда. ' || md5(random()::text) || md5(random()::text))
        RETURNING product_id INTO v_id;
        v_product_ids := v_product_ids || v_id;
    END LOOP;

    -- "order": value * 5 (BR-11.7). Клиент/ресторан/курьер round-robin:
    -- у каждого клиента, ресторана и курьера ровно 5 заказов. Адрес доставки —
    -- только из адресов этого клиента (BR-7.4, ловушка 7). ~60% доставленных
    -- для осмысленной статистики.
    FOR v_i IN 1..value * 5 LOOP
        v_ci := 1 + (v_i - 1) % value;   -- клиент
        v_ri := 1 + (v_i - 1) % value;   -- ресторан
        SELECT array_agg(address_id) INTO v_ca
        FROM tmp_fx_client_addr
        WHERE client_id = v_client_ids[v_ci];
        -- Дата заказа — строго внутри периода работы назначенного курьера
        -- (hire_date .. dismissal_date или сегодня). hire_date сам в пределах
        -- 180 дней, поэтому окно автоматически лежит в последних 6 месяцах.
        v_hire    := v_hire_dates[v_ci];
        v_dismiss := COALESCE(v_dismiss_dates[v_ci], current_date);
        v_order_ts := LEAST(
            v_hire::timestamp
                + floor(random() * (GREATEST(v_dismiss - v_hire, 0) + 1))::int * interval '1 day'
                + floor(random() * 86399)::int * interval '1 second',
            localtimestamp);
        v_status := CASE
            WHEN random() < 0.60 THEN v_order_statuses[4]   -- доставлен
            WHEN random() < 0.70 THEN v_order_statuses[1]   -- создан
            WHEN random() < 0.80 THEN v_order_statuses[2]   -- готовится
            WHEN random() < 0.90 THEN v_order_statuses[3]   -- в_доставке
            ELSE v_order_statuses[5]                        -- отменён
        END;
        IF v_status = 'доставлен' THEN
            v_deliv_ts := v_order_ts + (15 + floor(random() * 75))::int * interval '1 minute';
        ELSE
            v_deliv_ts := NULL;
        END IF;
        -- Временная сумма: итог заказа пересчитывается как SUM(price * quantity)
        -- после вставки позиций (согласованность сумм). 910.00 гарантирует
        -- total >= 1000 (BR-1.8, BR-7.11) на момент вставки заказа.
        v_amount := 910.00;
        INSERT INTO "order" (courier_id, client_id, address_id, restaurant_id, order_timestamp,
                             delivery_timestamp, order_amount, status, description)
        VALUES (
            v_courier_ids[v_ci],
            v_client_ids[v_ci],
            v_ca[1 + floor(random() * array_length(v_ca, 1))::int],
            v_rest_ids[v_ri],
            v_order_ts,
            v_deliv_ts,
            v_amount,
            v_status,
            'Комментарий к заказу. ' || md5(random()::text))
        RETURNING order_id INTO v_oid;
        v_order_ids := v_order_ids || v_oid;
    END LOOP;
    DROP TABLE IF EXISTS tmp_fx_client_addr;

    -- ========================================================================
    -- 5) Дочерние от order: order_structure, payment, review
    -- ========================================================================

    -- order_structure: 1..5 разных блюд ресторана заказа (BR-7.3, BR-7.14,
    -- BR-7.16; ловушки 8, 10). Кандидаты — ровно 5 блюд ресторана.
    FOR v_i IN 1..value * 5 LOOP
        v_ri := 1 + (v_i - 1) % value;
        v_cand := NULL;
        FOR v_m IN 0..4 LOOP
            v_cand := v_cand || v_product_ids[v_ri + v_m * value];
        END LOOP;
        v_k := 1 + floor(random() * array_length(v_cand, 1))::int;  -- 1..5
        FOR v_j IN 1..v_k LOOP
            v_idx := 1 + floor(random() * array_length(v_cand, 1))::int;
            INSERT INTO order_structure (order_id, product_id, quantity)
            VALUES (v_order_ids[v_i], v_cand[v_idx],
                    (1 + floor(random() * 3))::numeric);                -- 1..3, > 0 (BR-7.15)
            -- удалить выбранное блюдо из кандидатов: дубликатов не будет
            v_cand := v_cand[1:v_idx - 1] || v_cand[v_idx + 1:array_length(v_cand, 1)];
        END LOOP;
    END LOOP;

    -- Согласованность сумм: order_amount = SUM(product.price * quantity)
    -- позиций заказа. Количества целые, цены — 2 знака, поэтому SUM точна
    -- до копейки без округлений. Если сумма позиций < 910 (минимум для
    -- total >= 1000, BR-1.8), добиваем количество первой позиции целыми
    -- единицами — сумма остаётся точным SUM. Цель 912 с запасом.
    FOR v_i IN 1..value * 5 LOOP
        SELECT sum(p.price * os.quantity) INTO v_amount
        FROM order_structure os
        JOIN product p ON p.product_id = os.product_id
        WHERE os.order_id = v_order_ids[v_i];
        IF v_amount < 910.00 THEN
            UPDATE order_structure os
            SET quantity = os.quantity + CEIL((912.00 - v_amount) / p.price)
            FROM product p
            WHERE p.product_id = os.product_id
              AND os.order_id = v_order_ids[v_i]
              AND os.product_id = (SELECT os2.product_id FROM order_structure os2
                                   WHERE os2.order_id = v_order_ids[v_i] LIMIT 1);
            SELECT sum(p.price * os.quantity) INTO v_amount
            FROM order_structure os
            JOIN product p ON p.product_id = os.product_id
            WHERE os.order_id = v_order_ids[v_i];
        END IF;
        UPDATE "order" SET order_amount = v_amount WHERE order_id = v_order_ids[v_i];
    END LOOP;

    -- payment: value * 5 (BR-11.7, C.3 чек-листа) — ровно одна успешная
    -- попытка на заказ (BR-8.1, ловушка 11); сумма = total_amount (BR-8.4).
    -- BR-11.7 фиксирует общее число попыток value*5 = числу заказов, поэтому
    -- на заказ приходится ровно 1 попытка (допустимый край диапазона 1..3).
    FOR v_i IN 1..value * 5 LOOP
        SELECT total_amount INTO v_total FROM "order" WHERE order_id = v_order_ids[v_i];
        INSERT INTO payment (order_id, payment_type, amount, transaction_id, payment_timestamp, status)
        VALUES (
            v_order_ids[v_i],
            (enum_range(NULL::payment_type))[1 + floor(random() * cardinality(enum_range(NULL::payment_type)))::int],
            v_total,
            exts.uuid_generate_v4(),                                   -- внешний id, уникален (BR-8.3)
            LEAST((SELECT order_timestamp FROM "order" WHERE order_id = v_order_ids[v_i])
                  + (1 + floor(random() * 30))::int * interval '1 minute', localtimestamp),
            v_pay_statuses[1]);                               -- 'успех'
        -- order.pay_status пересчитывает триггер payment_pay_status_change
        -- (BR-8.7, 004_triggers.sql) — вручную не трогаем.
    END LOOP;

    -- review: value * 5 (BR-11.7) — один отзыв на заказ. Сущность отзыва —
    -- из того же заказа: блюдо из позиций заказа / ресторан заказа / сам
    -- заказ (BR-9.2, ловушка 12). Рейтинг блюда/ресторана пересчитает
    -- триггер rating_change (BR-9.6) — вручную не трогаем (samples §19).
    FOR v_i IN 1..value * 5 LOOP
        v_ri := 1 + (v_i - 1) % value;
        v_j  := floor(random() * 100)::int;
        IF v_j < 50 THEN
            SELECT array_agg(product_id) INTO v_prods
            FROM order_structure
            WHERE order_id = v_order_ids[v_i];
            INSERT INTO review (client_id, review_timestamp, entity_id, entity_type, order_id, description, photo_url, rating)
            VALUES (
                v_client_ids[v_ri],
                LEAST((SELECT order_timestamp FROM "order" WHERE order_id = v_order_ids[v_i])
                      + (1 + floor(random() * 72))::int * interval '1 hour', localtimestamp),
                v_prods[1 + floor(random() * array_length(v_prods, 1))::int],
                v_review_types[1],                             -- 'блюдо'
                v_order_ids[v_i],
                (ARRAY['Всё отлично!', 'Вкусно, но долго.', 'Хорошо.', 'Понравилось.', 'Нормально.'])[1 + floor(random() * 5)::int],
                CASE WHEN random() < 0.5 THEN NULL ELSE 'https://cdn.foodexpress.ru/img/' || md5(random()::text) || '.jpg' END,
                (3 + floor(random() * 3))::numeric);
        ELSIF v_j < 80 THEN
            INSERT INTO review (client_id, review_timestamp, entity_id, entity_type, order_id, description, photo_url, rating)
            VALUES (
                v_client_ids[v_ri],
                LEAST((SELECT order_timestamp FROM "order" WHERE order_id = v_order_ids[v_i])
                      + (1 + floor(random() * 72))::int * interval '1 hour', localtimestamp),
                v_rest_ids[v_ri],
                v_review_types[2],                             -- 'ресторан'
                v_order_ids[v_i],
                (ARRAY['Отличный сервис!', 'Неплохо.', 'Заказали ещё раз.', 'Быстро и вкусно.', 'Так себе.'])[1 + floor(random() * 5)::int],
                CASE WHEN random() < 0.5 THEN NULL ELSE 'https://cdn.foodexpress.ru/img/' || md5(random()::text) || '.jpg' END,
                (3 + floor(random() * 3))::numeric);
        ELSE
            INSERT INTO review (client_id, review_timestamp, entity_id, entity_type, order_id, description, photo_url, rating)
            VALUES (
                v_client_ids[v_ri],
                LEAST((SELECT order_timestamp FROM "order" WHERE order_id = v_order_ids[v_i])
                      + (1 + floor(random() * 72))::int * interval '1 hour', localtimestamp),
                v_order_ids[v_i],
                v_review_types[3],                             -- 'заказ'
                v_order_ids[v_i],
                (ARRAY['Доставили вовремя.', 'Курьер вежливый.', 'Всё холодное.', 'Претензий нет.', 'Спасибо!'])[1 + floor(random() * 5)::int],
                CASE WHEN random() < 0.5 THEN NULL ELSE 'https://cdn.foodexpress.ru/img/' || md5(random()::text) || '.jpg' END,
                (3 + floor(random() * 3))::numeric);
        END IF;
    END LOOP;

    -- ========================================================================
    -- 6) courier_pay: последние 6 месяцев (BR-10.7, samples §9)
    -- ========================================================================

    -- История коэффициентов: старт 0.1 шесть месяцев назад, далее помесячный
    -- пересчёт по числу доставок предыдущего месяца (BR-10.2). coefficient_used
    -- — коэффициент, действовавший в расчётном месяце; amount =
    -- coefficient_used × сумма комиссий доставленных заказов курьера в месяце
    -- (0, если доставок нет — не NULL, ловушка 13). Только 'доставлен' (BR-10.5).
    v_len := 6;
    FOR v_m IN 1..6 LOOP
        v_months[v_m] := date_trunc('month', current_date)::timestamp - (v_len - v_m) * interval '1 month';
    END LOOP;
    FOR v_m IN 1..6 LOOP
        v_y    := extract(year  FROM v_months[v_m])::int;
        v_mnth := extract(month FROM v_months[v_m])::int;
        FOR v_i IN 1..value LOOP
            SELECT COALESCE(sum(commission), 0) INTO v_comm_sum
            FROM "order"
            WHERE courier_id  = v_courier_ids[v_i]
              AND status      = 'доставлен'
              AND order_timestamp >= v_months[v_m]
              AND order_timestamp <  v_months[v_m] + interval '1 month';
            INSERT INTO courier_pay (year, month, courier_id, amount, coefficient_used)
            VALUES (v_y, v_mnth, v_courier_ids[v_i],
                    round(v_coeffs[v_i] * v_comm_sum, 2), v_coeffs[v_i]);
            SELECT count(*) INTO v_cnt
            FROM "order"
            WHERE courier_id  = v_courier_ids[v_i]
              AND status      = 'доставлен'
              AND order_timestamp >= v_months[v_m]
              AND order_timestamp <  v_months[v_m] + interval '1 month';
            v_coeffs[v_i] := CASE
                WHEN v_cnt <= 150 THEN 0.1
                WHEN v_cnt <= 250 THEN 0.2
                WHEN v_cnt <= 500 THEN 0.3
                ELSE 0.5
            END;
        END LOOP;
    END LOOP;

    -- Итоговый coefficient — коэффициент на СЛЕДУЮЩИЙ месяц (по доставкам
    -- текущего месяца), обновляем только у работающих курьеров (BR-10.6)
    FOR v_i IN 1..value LOOP
        IF NOT v_fired[v_i] THEN
            UPDATE courier SET coefficient = v_coeffs[v_i]
            WHERE courier_id = v_courier_ids[v_i];
        END IF;
    END LOOP;

    RAISE NOTICE 'insert_test_data(%) завершено: client=%, courier=%, product_category=%, restaurant=%', value, value, value, value, value;
END;
$proc$;

-- ---------------------------------------------------------------------------
-- Очистка тестовых данных (FOOD-103)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE erase_test_data()
LANGUAGE plpgsql
AS $proc$
BEGIN
    -- TRUNCATE одной командой: в списке явно все 12 таблиц схемы (FK-зависимые
    -- тоже), порядок не важен. RESTART IDENTITY — для полноты (serial-колонок
    -- нет, UUID через DEFAULT). Повторный вызов безопасен. Типы, функции,
    -- процедуры, триггеры и представления не затрагиваются.
    TRUNCATE TABLE
        client_address,
        order_structure,
        payment,
        review,
        courier_pay,
        "order",
        product,
        restaurant,
        product_category,
        courier,
        client,
        address
    RESTART IDENTITY;
END;
$proc$;

-- ---------------------------------------------------------------------------
-- FOOD-104: добавление блюда
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS add_product(uuid, uuid, varchar, numeric, numeric, product_status, text, text);

-- Все атрибуты product кроме product_id (генерируется DEFAULT-ом,
-- BR-11.1). Имена параметров — контракт с проверкой E.1 (named notation).
CREATE OR REPLACE PROCEDURE add_product(
    p_restaurant_id       uuid,
    p_product_category_id uuid,
    p_name                varchar,
    p_price               numeric,
    p_rating              numeric DEFAULT NULL,
    p_status              product_status DEFAULT 'доступно',
    p_description         text DEFAULT NULL,
    p_photo_url           text DEFAULT NULL
)
LANGUAGE plpgsql
AS $proc$
BEGIN
    -- Ссылочная целостность — с внятными сообщениями (FOOD-104)
    IF p_restaurant_id IS NULL OR NOT EXISTS (SELECT 1 FROM restaurant WHERE restaurant_id = p_restaurant_id) THEN
        RAISE EXCEPTION 'add_product: ресторан % не существует', p_restaurant_id;
    END IF;
    IF p_product_category_id IS NULL OR NOT EXISTS (SELECT 1 FROM product_category WHERE product_category_id = p_product_category_id) THEN
        RAISE EXCEPTION 'add_product: категория блюд % не существует', p_product_category_id;
    END IF;
    IF p_name IS NULL OR p_name = '' THEN
        RAISE EXCEPTION 'add_product: название блюда не должно быть пустым';
    END IF;
    IF p_price IS NULL THEN
        RAISE EXCEPTION 'add_product: цена блюда не должна быть NULL';
    END IF;
    -- Нарушения CHECK (BR-5.3, BR-5.4, BR-5.5) перехватываем и пере-подаём
    -- с понятным сообщением вместо сырого текста сервера
    BEGIN
        INSERT INTO product (product_name, product_category_id, price, restaurant_id, rating, status, description, photo_url)
        VALUES (p_name, p_product_category_id, p_price, p_restaurant_id, p_rating, p_status,
                COALESCE(p_description, 'Без описания'), p_photo_url);
    EXCEPTION WHEN check_violation THEN
        RAISE EXCEPTION 'add_product: нарушение CHECK для блюда "%": price >= 0, rating 0..5, статус из enum (BR-5.3, BR-5.4, BR-5.5)', p_name;
    END;
END;
$proc$;

-- ---------------------------------------------------------------------------
-- FOOD-107: расчёт зарплаты курьеров за текущий месяц (BR-10.2)
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS courier_salary();

CREATE OR REPLACE PROCEDURE courier_salary()
LANGUAGE plpgsql
AS $proc$
DECLARE
    v_year    int := extract(year  FROM current_date)::int;
    v_month   int := extract(month FROM current_date)::int;
    v_mstart  timestamp := date_trunc('month', current_date)::timestamp;
    v_mend    timestamp := date_trunc('month', current_date)::timestamp + interval '1 month';
    v_courier record;
    v_sum      numeric;
    v_cnt      int;
    v_newcoef  numeric;
    v_coef_eff numeric;
BEGIN
    FOR v_courier IN SELECT courier_id, coefficient, status FROM courier LOOP
        -- Зарплата = текущий коэффициент × сумма комиссий доставленных
        -- заказов курьера за текущий месяц; нет доставок → 0 (BR-10.2,
        -- BR-10.5)
        SELECT COALESCE(sum(commission), 0) INTO v_sum
        FROM "order"
        WHERE courier_id = v_courier.courier_id
          AND status = 'доставлен'
          AND order_timestamp >= v_mstart
          AND order_timestamp <  v_mend;

        -- Идемпотентность: если запись за этот месяц уже есть (повторный
        -- вызов), сумму пересчитываем по СОХРАНЁННОМУ coefficient_used, а не по
        -- уже обновлённому courier.coefficient — иначе повторный вызов
        -- «переоценивал» бы начисленную зарплату новым коэффициентом.
        SELECT cp.coefficient_used INTO v_coef_eff
        FROM courier_pay cp
        WHERE cp.year = v_year AND cp.month = v_month
          AND cp.courier_id = v_courier.courier_id;
        v_coef_eff := COALESCE(v_coef_eff, v_courier.coefficient);

        -- Одна запись в месяц: повторный вызов обновляет сумму, а не дублирует
        -- запись (BR-10.3); coefficient_used первого расчёта сохраняется.
        INSERT INTO courier_pay (year, month, courier_id, amount, coefficient_used)
        VALUES (v_year, v_month, v_courier.courier_id,
                round(v_coef_eff * v_sum, 2), v_coef_eff)
        ON CONFLICT (year, month, courier_id) DO UPDATE
            SET amount = EXCLUDED.amount;

        -- Новый коэффициент на следующий месяц (BR-10.2) — только у
        -- работающих курьеров (BR-10.6)
        IF v_courier.status != 'уволен' THEN
            SELECT count(*) INTO v_cnt
            FROM "order"
            WHERE courier_id = v_courier.courier_id
              AND status = 'доставлен'
              AND order_timestamp >= v_mstart
              AND order_timestamp <  v_mend;
            v_newcoef := CASE
                WHEN v_cnt <= 150 THEN 0.1
                WHEN v_cnt <= 250 THEN 0.2
                WHEN v_cnt <= 500 THEN 0.3
                ELSE 0.5
            END;
            UPDATE courier SET coefficient = v_newcoef
            WHERE courier_id = v_courier.courier_id;
        END IF;
    END LOOP;
END;
$proc$;
