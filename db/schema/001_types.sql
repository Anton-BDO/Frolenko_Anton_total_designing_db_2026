-- ============================================================================
-- 001_types.sql — enum-типы схемы frolenko_food (FOOD-101, BR-11.5).
-- Значения перечислений дословно из бизнес-правил company-rules.md.
-- Схема exts не пересоздаётся (BR-13.3) — используется только для UUID.
-- ============================================================================

-- Рабочая схема проекта (FOOD-101). Идемпотентно.
CREATE SCHEMA IF NOT EXISTS frolenko_food;

SET search_path TO frolenko_food, exts;

-- Идемпотентность: типы пересоздаются с нуля (CASCADE снимет зависимости
-- таблиц; сами таблицы пересоздаются в 002_tables.sql).
DROP TYPE IF EXISTS restaurant_status    CASCADE;
DROP TYPE IF EXISTS product_status       CASCADE;
DROP TYPE IF EXISTS courier_status       CASCADE;
DROP TYPE IF EXISTS order_status         CASCADE;
DROP TYPE IF EXISTS order_pay_status     CASCADE;
DROP TYPE IF EXISTS payment_status       CASCADE;
DROP TYPE IF EXISTS payment_type         CASCADE;
DROP TYPE IF EXISTS review_entity_type   CASCADE;

-- Статус ресторана (BR-4.3)
CREATE TYPE restaurant_status AS ENUM ('активен', 'неактивен');

-- Статус блюда (BR-5.5)
CREATE TYPE product_status AS ENUM ('доступно', 'нет_в_наличии', 'архив');

-- Статус курьера (BR-6.2)
CREATE TYPE courier_status AS ENUM ('свободен', 'занят', 'на_доставке', 'уволен');

-- Статус заказа (BR-7.7)
CREATE TYPE order_status AS ENUM ('создан', 'готовится', 'в_доставке', 'доставлен', 'отменён');

-- Агрегированный статус оплаты заказа (BR-7.9)
CREATE TYPE order_pay_status AS ENUM ('ожидает', 'оплачен', 'ошибка');

-- Статус попытки оплаты (BR-8.2)
CREATE TYPE payment_status AS ENUM ('успех', 'ошибка', 'в_обработке');

-- Тип оплаты попытки (BR-8.2, BR-8.6: тип относится к попытке, не к заказу)
CREATE TYPE payment_type AS ENUM ('карта', 'наличные', 'безнал');

-- Тип сущности отзыва (BR-9.1)
CREATE TYPE review_entity_type AS ENUM ('блюдо', 'ресторан', 'заказ');
