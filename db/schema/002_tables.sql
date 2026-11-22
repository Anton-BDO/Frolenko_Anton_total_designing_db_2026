-- ============================================================================
-- 002_tables.sql — 12 таблиц схемы frolenko_food (FOOD-101).
-- Источник контракта: docs/erd.md (концептуальная модель) + company-rules.md.
-- Все PK — uuid с DEFAULT exts.uuid_generate_v4() (BR-11.1).
-- Все FK — ON DELETE RESTRICT: история заказов сохраняется, адреса и
-- справочники не удаляются каскадно (BR-3.5).
-- ============================================================================
SET search_path TO frolenko_food, exts;

-- Идемпотентность: пересоздаём таблицы в порядке, обратном зависимостям FK.
DROP TABLE IF EXISTS review           CASCADE;
DROP TABLE IF EXISTS order_structure  CASCADE;
DROP TABLE IF EXISTS payment          CASCADE;
DROP TABLE IF EXISTS "order"          CASCADE;
DROP TABLE IF EXISTS product          CASCADE;
DROP TABLE IF EXISTS courier_pay      CASCADE;
DROP TABLE IF EXISTS restaurant       CASCADE;
DROP TABLE IF EXISTS client_address   CASCADE;
DROP TABLE IF EXISTS product_category CASCADE;
DROP TABLE IF EXISTS courier          CASCADE;
DROP TABLE IF EXISTS client           CASCADE;
DROP TABLE IF EXISTS address          CASCADE;

-- ---------------------------------------------------------------------------
-- Справочники без FK
-- ---------------------------------------------------------------------------

-- Клиент: логин/телефон уникальны (BR-2.2), пароль — MD5 32 символа (BR-2.3),
-- ФИО не хранится (BR-2.6). Телефон varchar(12): '+7' + 10 цифр — char(11) не
-- вместил бы '+7' (ловушка 6 из samples/all_examples.sql).
CREATE TABLE client (
    client_id    uuid DEFAULT exts.uuid_generate_v4() PRIMARY KEY,  -- BR-11.1
    login        varchar(50)  NOT NULL UNIQUE,                      -- BR-2.2
    password     varchar(32)  NOT NULL,                             -- BR-2.3 (MD5)
    phone_number varchar(12)  NOT NULL UNIQUE                       -- BR-2.2
);

-- Физический адрес (BR-3.1). Квартира/офис необязательна (BR-3.2).
CREATE TABLE address (
    address_id       uuid DEFAULT exts.uuid_generate_v4() PRIMARY KEY,  -- BR-11.1
    street           varchar(100) NOT NULL,                             -- BR-3.1
    house_number     varchar(10)  NOT NULL,                             -- BR-3.1
    apartment_office varchar(20)  NULL                                  -- BR-3.2 (необязательна)
);

-- Курьер (BR-6.1). Телефон без UNIQUE: BR не требует уникальности телефона
-- курьера (в отличие от клиента, BR-2.2).
CREATE TABLE courier (
    courier_id     uuid DEFAULT exts.uuid_generate_v4() PRIMARY KEY,   -- BR-11.1
    fio            varchar(150)  NOT NULL,                             -- BR-6.1 (ФИО обязательно)
    phone_number   varchar(12)   NOT NULL,                             -- BR-6.1 (формат +7XXXXXXXXXX)
    status         courier_status NOT NULL DEFAULT 'свободен',         -- BR-6.2
    hire_date      date          NOT NULL,                             -- BR-6.1
    dismissal_date date          NULL,                                 -- BR-6.3 (у работающего может не быть)
    coefficient    numeric(2,1)  NOT NULL DEFAULT 0.1
        CONSTRAINT courier_coefficient_check CHECK (coefficient BETWEEN 0.1 AND 0.5),  -- BR-6.4, BR-6.5
    CONSTRAINT courier_dismissal_flag_check
        CHECK ((status = 'уволен') = (dismissal_date IS NOT NULL)),    -- BR-6.3
    CONSTRAINT courier_dismissal_date_check
        CHECK (dismissal_date IS NULL OR dismissal_date >= hire_date)  -- BR-6.3
);

-- Категория блюда — справочник (BR-5.7)
CREATE TABLE product_category (
    product_category_id   uuid DEFAULT exts.uuid_generate_v4() PRIMARY KEY,  -- BR-11.1
    product_category_name varchar(100) NOT NULL                              -- BR-5.7
);

-- ---------------------------------------------------------------------------
-- Справочники с FK
-- ---------------------------------------------------------------------------

-- M:N клиент↔адрес: один адрес у клиента один раз (BR-2.5, составной PK).
CREATE TABLE client_address (
    client_id  uuid NOT NULL REFERENCES client  (client_id)  ON DELETE RESTRICT,
    address_id uuid NOT NULL REFERENCES address (address_id) ON DELETE RESTRICT,  -- BR-3.5
    PRIMARY KEY (client_id, address_id)                                            -- BR-2.5
);

-- Ресторан (BR-4.1). Ровно один адрес, адрес не делится (BR-3.3).
CREATE TABLE restaurant (
    restaurant_id  uuid DEFAULT exts.uuid_generate_v4() PRIMARY KEY,   -- BR-11.1
    restaurant_name varchar(100) NOT NULL,                             -- BR-4.1
    address_id     uuid NOT NULL UNIQUE REFERENCES address (address_id) ON DELETE RESTRICT,  -- BR-3.3
    description    text NOT NULL,                                      -- BR-4.1
    work_start     time NOT NULL,                                      -- BR-4.4
    work_end       time NOT NULL,                                      -- BR-4.4
    company_details text NOT NULL,                                     -- BR-4.5
    rating         numeric(3,2) NULL
        CONSTRAINT restaurant_rating_check CHECK (rating BETWEEN 0 AND 5),  -- BR-4.2; NULL, пока нет отзывов (BR-9.7). Точность (3,2): хранит ROUND(AVG,2) без квантования (проверка D.14)
    status         restaurant_status NOT NULL DEFAULT 'активен',        -- BR-4.3
    CONSTRAINT restaurant_work_time_check CHECK (work_end > work_start) -- BR-4.4
);

-- Блюдо (BR-5.1–BR-5.6)
CREATE TABLE product (
    product_id          uuid DEFAULT exts.uuid_generate_v4() PRIMARY KEY,  -- BR-11.1
    product_name        varchar(100) NOT NULL,                             -- BR-5.2
    product_category_id uuid NOT NULL REFERENCES product_category (product_category_id) ON DELETE RESTRICT,  -- BR-5.1
    price               numeric(10,2) NOT NULL
        CONSTRAINT product_price_check CHECK (price >= 0),                 -- BR-5.3
    restaurant_id       uuid NOT NULL REFERENCES restaurant (restaurant_id) ON DELETE RESTRICT,              -- BR-5.1
    photo_url           text NULL,                                         -- BR-5.6 (необязательна)
    rating              numeric(3,2) NULL
        CONSTRAINT product_rating_check CHECK (rating BETWEEN 0 AND 5),    -- BR-5.4; NULL, пока нет отзывов (BR-9.7). Точность (3,2): хранит ROUND(AVG,2) без квантования (проверка D.14)
    status              product_status NOT NULL DEFAULT 'доступно',        -- BR-5.5
    description         text NOT NULL                                      -- BR-5.2
);

-- ---------------------------------------------------------------------------
-- Транзакционные таблицы
-- ---------------------------------------------------------------------------

-- Заказ. Имя "order" — в кавычках: зарезервированное слово (BR-13.1);
-- осознанно не переименовываем — контракт erd.md и чек-лист аудитора
-- обращаются к "order". Обоснование — в constraints.md.
CREATE TABLE "order" (
    order_id          uuid DEFAULT exts.uuid_generate_v4() PRIMARY KEY,  -- BR-11.1
    courier_id        uuid NOT NULL REFERENCES courier (courier_id) ON DELETE RESTRICT,      -- BR-7.5
    client_id         uuid NOT NULL REFERENCES client  (client_id)  ON DELETE RESTRICT,      -- BR-7.2
    address_id        uuid NOT NULL REFERENCES address (address_id) ON DELETE RESTRICT,      -- BR-7.4, BR-3.5
    restaurant_id     uuid NOT NULL REFERENCES restaurant (restaurant_id) ON DELETE RESTRICT, -- BR-7.2
    order_timestamp   timestamp NOT NULL DEFAULT localtimestamp,         -- BR-7.1, BR-11.2
    delivery_timestamp timestamp NULL,                                   -- BR-7.12 (пока не доставлен — NULL)
    order_amount      numeric(12,2) NOT NULL
        CONSTRAINT order_amount_check CHECK (order_amount >= 0),         -- BR-7.10
    commission        numeric(12,2) GENERATED ALWAYS AS (round(order_amount * 0.10, 2)) STORED,              -- BR-1.4
    total_amount      numeric(12,2) GENERATED ALWAYS AS (order_amount + round(order_amount * 0.10, 2)) STORED, -- BR-7.10
    status            order_status NOT NULL DEFAULT 'создан',            -- BR-7.6, BR-7.7
    pay_status        order_pay_status NOT NULL DEFAULT 'ожидает',       -- BR-7.8, BR-7.9
    description       text NOT NULL,
    -- Минимальная сумма заказа (BR-1.8, BR-7.11). total_amount — generated,
    -- CHECK по нему срабатывает на вставке order_amount.
    CONSTRAINT order_total_min_check CHECK (total_amount >= 1000),
    -- Время окончания доставки не раньше времени создания (BR-7.13)
    CONSTRAINT order_delivery_time_check
        CHECK (delivery_timestamp IS NULL OR delivery_timestamp >= order_timestamp),
    -- Ловушка 2 (BR-7.4): адрес доставки — один из адресов клиента.
    -- Составной FK гарантирует принадлежность декларативно: пара
    -- (client_id, address_id) должна существовать в client_address.
    CONSTRAINT order_client_address_fk
        FOREIGN KEY (client_id, address_id) REFERENCES client_address (client_id, address_id),
    -- BR-7.12: доставленный заказ обязан иметь время окончания доставки
    CONSTRAINT order_delivered_ts_check
        CHECK (status <> 'доставлен' OR delivery_timestamp IS NOT NULL)
);

-- Попытка оплаты заказа. В ERD только (payment_id, order_id) — дополнено
-- по BR-8.2 (см. ловушку 1 в constraints.md).
CREATE TABLE payment (
    payment_id        uuid DEFAULT exts.uuid_generate_v4() PRIMARY KEY,  -- BR-11.1
    order_id          uuid NOT NULL REFERENCES "order" (order_id) ON DELETE RESTRICT,  -- BR-8.1
    payment_type      payment_type NOT NULL,                             -- BR-8.2, BR-8.6
    amount            numeric(12,2) NOT NULL,                            -- BR-8.2; = total_amount заказа (BR-8.4, триггер)
    transaction_id    uuid NOT NULL UNIQUE,                            -- BR-8.3 (внешний идентификатор уникален)
    payment_timestamp timestamp NOT NULL,                                -- BR-8.2
    status            payment_status NOT NULL                            -- BR-8.2
);

-- BR-8.1: ровно одна успешная попытка на заказ. Декларативно — только
-- частичным уникальным индексом: обычный UNIQUE не подходит (неуспешных
-- попыток может быть много).
CREATE UNIQUE INDEX payment_one_success_uq
    ON payment (order_id)
    WHERE status = 'успех';

-- Позиция заказа (BR-7.14–BR-7.16). Одно блюдо не повторяется в заказе —
-- составной PK (BR-7.16).
CREATE TABLE order_structure (
    order_id      uuid NOT NULL REFERENCES "order" (order_id) ON DELETE RESTRICT,   -- BR-7.14
    product_id    uuid NOT NULL REFERENCES product (product_id) ON DELETE RESTRICT, -- BR-7.14
    quantity      numeric(8,3) NOT NULL
        CONSTRAINT order_structure_quantity_check CHECK (quantity > 0),  -- BR-7.15
    PRIMARY KEY (order_id, product_id)                                   -- BR-7.16
    -- Ловушка 3 (BR-7.3, блюда только из ресторана заказа) решается триггером
    -- order_structure_restaurant_check (004_triggers.sql). Колонка-«якорь»
    -- restaurant_id здесь создавала бы частичную зависимость неключевого
    -- атрибута от частей составного PK — то есть нарушение 2НФ.
);

-- Отзыв (BR-9.1–BR-9.5). entity_id — полиморфная ссылка: одним FK нельзя
-- сослаться на три таблицы (см. ловушку 4 в constraints.md); валидность
-- обеспечивает триггер review_entity_check (004_triggers.sql).
CREATE TABLE review (
    review_id        uuid DEFAULT exts.uuid_generate_v4() PRIMARY KEY,   -- BR-11.1
    client_id        uuid NOT NULL REFERENCES client (client_id) ON DELETE RESTRICT,  -- BR-9.2
    review_timestamp timestamp NOT NULL DEFAULT localtimestamp,          -- BR-9.3
    entity_id        uuid NOT NULL,                                      -- BR-9.1 (полиморфная ссылка, FK нет)
    entity_type      review_entity_type NOT NULL,                        -- BR-9.1
    order_id         uuid NOT NULL REFERENCES "order" (order_id) ON DELETE RESTRICT,    -- BR-9.2
    description      text NOT NULL,                                      -- BR-9.3
    photo_url        text NULL,                                          -- BR-9.3 (необязательна)
    rating           numeric(2,1) NOT NULL
        CONSTRAINT review_rating_check CHECK (rating BETWEEN 1 AND 5),   -- BR-9.4
    -- BR-9.5: не более одного отзыва на объект в рамках заказа
    CONSTRAINT review_one_per_entity_uq UNIQUE (order_id, entity_type, entity_id)
);

-- Ежемесячная выплата курьеру (BR-10.1–BR-10.4)
CREATE TABLE courier_pay (
    year            int  NOT NULL,
    month           int  NOT NULL
        CONSTRAINT courier_pay_month_check CHECK (month BETWEEN 1 AND 12),
    courier_id      uuid NOT NULL REFERENCES courier (courier_id) ON DELETE RESTRICT,   -- BR-10.1
    amount          numeric(12,2) NOT NULL DEFAULT 0
        CONSTRAINT courier_pay_amount_check CHECK (amount >= 0),         -- BR-10.4
    coefficient_used numeric(2,1) NOT NULL
        CONSTRAINT courier_pay_coefficient_check CHECK (coefficient_used BETWEEN 0.1 AND 0.5),
    PRIMARY KEY (year, month, courier_id)                                -- BR-10.3: одна запись в месяц
);
