-- ============================================================================
-- 004_triggers.sql — триггеры схемы frolenko_food.
--   1) rating_change + review_rating_change — пересчёт агрегированного
--      рейтинга блюда/ресторана (FOOD-105, BR-9.6, BR-9.7).
--   2) review_entity_check_trg — валидность полиморфной ссылки review
--      (ловушка 4, BR-9.1) И принадлежность отзыва заказу клиента (BR-9.2).
--   3) payment_amount_check_trg — сумма попытки оплаты равна total_amount
--      заказа (BR-8.4): декларативно невыразимо (нужна другая строка).
--   4) payment_pay_status_change_trg — пересчёт агрегированного статуса
--      оплаты заказа при любых изменениях попыток (BR-8.7).
--   5) order_amount_freeze_trg — запрет менять сумму заказа, когда по нему
--      уже есть попытки оплаты (иначе нарушится BR-8.4).
--   6) order_structure_restaurant_trg — все блюда позиции — из ресторана
--      заказа (ловушка 3, BR-7.3). Декларативная альтернатива (составные FK
--      через колонку-«якорь» restaurant_id) отвергнута: она ломала 2НФ.
--   7) order_restaurant_freeze_trg / product_restaurant_freeze_trg — запрет
--      менять restaurant_id у заказа/блюда, уже имеющего позиции (иначе
--      существующие позиции нарушили бы BR-7.3 задним числом).
-- ============================================================================
SET search_path TO frolenko_food, exts;

DROP TRIGGER IF EXISTS review_rating_change            ON review;
DROP TRIGGER IF EXISTS review_entity_check_trg         ON review;
DROP TRIGGER IF EXISTS payment_amount_check_trg        ON payment;
DROP TRIGGER IF EXISTS payment_pay_status_change_trg   ON payment;
DROP TRIGGER IF EXISTS order_amount_freeze_trg         ON "order";
DROP TRIGGER IF EXISTS order_structure_restaurant_trg  ON order_structure;
DROP TRIGGER IF EXISTS order_restaurant_freeze_trg     ON "order";
DROP TRIGGER IF EXISTS product_restaurant_freeze_trg   ON product;

DROP FUNCTION IF EXISTS rating_change();
DROP FUNCTION IF EXISTS review_entity_check();
DROP FUNCTION IF EXISTS payment_amount_check();
DROP FUNCTION IF EXISTS payment_pay_status_change();
DROP FUNCTION IF EXISTS order_amount_freeze();
DROP FUNCTION IF EXISTS order_structure_restaurant_check();
DROP FUNCTION IF EXISTS order_restaurant_freeze();
DROP FUNCTION IF EXISTS product_restaurant_freeze();

-- ---------------------------------------------------------------------------
-- FOOD-105: пересчёт рейтинга при INSERT/UPDATE/DELETE отзыва.
-- 'блюдо'   → product.rating  = AVG(review.rating) по отзывам на блюдо;
-- 'ресторан'→ restaurant.rating аналогично;
-- 'заказ'   → агрегата нет, ничего не делаем (BR-9.6).
-- Отзывов не осталось → AVG = NULL → rating = NULL (BR-9.7).
-- Рекурсии нет: триггер пишет в product/restaurant, а не в review.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rating_change() RETURNS trigger
LANGUAGE plpgsql
AS $f$
BEGIN
    -- Старая сущность (UPDATE/DELETE): пересчитать по оставшимся отзывам
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        IF OLD.entity_type = 'блюдо' THEN
            UPDATE product
            SET rating = (SELECT round(avg(r.rating), 2) FROM review r
                          WHERE r.entity_type = 'блюдо' AND r.entity_id = OLD.entity_id)
            WHERE product_id = OLD.entity_id;
        ELSIF OLD.entity_type = 'ресторан' THEN
            UPDATE restaurant
            SET rating = (SELECT round(avg(r.rating), 2) FROM review r
                          WHERE r.entity_type = 'ресторан' AND r.entity_id = OLD.entity_id)
            WHERE restaurant_id = OLD.entity_id;
        END IF;
    END IF;

    -- Новая сущность (INSERT/UPDATE). Если сущность не изменилась
    -- (менялся только текст/рейтинг в пределах той же пары type+id),
    -- пересчёт уже сделан блоком выше — не дублируем.
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        IF NEW.entity_type = 'блюдо'
           AND (TG_OP = 'INSERT'
                OR OLD.entity_type IS DISTINCT FROM NEW.entity_type
                OR OLD.entity_id   IS DISTINCT FROM NEW.entity_id) THEN
            UPDATE product
            SET rating = (SELECT round(avg(r.rating), 2) FROM review r
                          WHERE r.entity_type = 'блюдо' AND r.entity_id = NEW.entity_id)
            WHERE product_id = NEW.entity_id;
        ELSIF NEW.entity_type = 'ресторан'
           AND (TG_OP = 'INSERT'
                OR OLD.entity_type IS DISTINCT FROM NEW.entity_type
                OR OLD.entity_id   IS DISTINCT FROM NEW.entity_id) THEN
            UPDATE restaurant
            SET rating = (SELECT round(avg(r.rating), 2) FROM review r
                          WHERE r.entity_type = 'ресторан' AND r.entity_id = NEW.entity_id)
            WHERE restaurant_id = NEW.entity_id;
        END IF;
    END IF;

    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$f$;

CREATE TRIGGER review_rating_change
    AFTER INSERT OR UPDATE OR DELETE ON review
    FOR EACH ROW EXECUTE FUNCTION rating_change();

-- ---------------------------------------------------------------------------
-- Ловушка 4 (BR-9.1) + BR-9.2: entity_id — полиморфная ссылка на product/
-- restaurant/"order". Один FK не может ссылаться на три таблицы, поэтому
-- валидность обеспечивает этот триггер. Дополнительно к существованию
-- сущности проверяется, что отзыв относится к заказу самого клиента
-- (BR-9.2: клиент может оставить отзыв только на то, что он заказал):
--   'блюдо'    — блюдо входит в позиции этого заказа;
--   'ресторан' — это ресторан этого заказа;
--   'заказ'    — entity_id совпадает с order_id отзыва;
--   всегда    — review.client_id = order.client_id.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION review_entity_check() RETURNS trigger
LANGUAGE plpgsql
AS $f$
DECLARE
    v_order_client     uuid;
    v_order_restaurant uuid;
BEGIN
    SELECT o.client_id, o.restaurant_id
      INTO v_order_client, v_order_restaurant
    FROM "order" o
    WHERE o.order_id = NEW.order_id;

    -- BR-9.2: отзыв оставляет клиент, оформивший этот заказ
    IF v_order_client IS DISTINCT FROM NEW.client_id THEN
        RAISE EXCEPTION 'review: клиент % не является автором заказа % (BR-9.2)',
            NEW.client_id, NEW.order_id;
    END IF;

    IF NEW.entity_type = 'блюдо' THEN
        -- BR-9.2: отзыв только на блюдо из этого заказа
        IF NOT EXISTS (SELECT 1 FROM order_structure os
                       WHERE os.order_id = NEW.order_id
                         AND os.product_id = NEW.entity_id) THEN
            RAISE EXCEPTION 'review: блюдо % не входит в заказ % (BR-9.2)',
                NEW.entity_id, NEW.order_id;
        END IF;
    ELSIF NEW.entity_type = 'ресторан' THEN
        -- BR-9.2: отзыв на ресторан этого заказа
        IF NEW.entity_id IS DISTINCT FROM v_order_restaurant THEN
            RAISE EXCEPTION 'review: ресторан % не является рестораном заказа % (BR-9.2)',
                NEW.entity_id, NEW.order_id;
        END IF;
    ELSIF NEW.entity_type = 'заказ' THEN
        -- BR-9.2: для отзыва на заказ entity_id = order_id
        IF NEW.entity_id IS DISTINCT FROM NEW.order_id THEN
            RAISE EXCEPTION 'review: для отзыва на заказ entity_id % должен совпадать с order_id % (BR-9.2)',
                NEW.entity_id, NEW.order_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$f$;

CREATE TRIGGER review_entity_check_trg
    BEFORE INSERT OR UPDATE ON review
    FOR EACH ROW EXECUTE FUNCTION review_entity_check();

-- ---------------------------------------------------------------------------
-- BR-8.4: сумма каждой попытки оплаты равна общей сумме заказа.
-- Декларативно невыразимо (сравнение с полем другой таблицы-строки).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION payment_amount_check() RETURNS trigger
LANGUAGE plpgsql
AS $f$
DECLARE
    v_total numeric;
BEGIN
    SELECT total_amount INTO v_total FROM "order" WHERE order_id = NEW.order_id;
    IF v_total IS NULL THEN
        RAISE EXCEPTION 'payment: заказ % не существует', NEW.order_id;
    END IF;
    IF NEW.amount != v_total THEN
        RAISE EXCEPTION 'payment: сумма попытки % != total_amount заказа % (BR-8.4)', NEW.amount, v_total;
    END IF;
    RETURN NEW;
END;
$f$;

CREATE TRIGGER payment_amount_check_trg
    BEFORE INSERT OR UPDATE ON payment
    FOR EACH ROW EXECUTE FUNCTION payment_amount_check();

-- ---------------------------------------------------------------------------
-- BR-8.7: агрегированный статус оплаты заказа пересчитывается при любом
-- изменении попыток (INSERT/UPDATE/DELETE payment):
--   'оплачен' — есть успешная попытка;
--   'ошибка'  — все попытки завершились ошибкой (и попытки есть);
--   'ожидает' — попыток нет или есть попытки в обработке, успешных нет.
-- Рекурсии нет: триггер пишет в "order", а не в payment.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION payment_pay_status_change() RETURNS trigger
LANGUAGE plpgsql
AS $f$
DECLARE
    v_order uuid;
BEGIN
    v_order := COALESCE(NEW.order_id, OLD.order_id);
    UPDATE "order" o
    SET pay_status = (
        CASE
            WHEN EXISTS (SELECT 1 FROM payment p
                         WHERE p.order_id = v_order AND p.status = 'успех')
                THEN 'оплачен'
            WHEN NOT EXISTS (SELECT 1 FROM payment p WHERE p.order_id = v_order)
                THEN 'ожидает'
            WHEN EXISTS (SELECT 1 FROM payment p
                         WHERE p.order_id = v_order AND p.status = 'в_обработке')
                THEN 'ожидает'
            ELSE 'ошибка'
        END)::order_pay_status
    WHERE o.order_id = v_order;

    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$f$;

CREATE TRIGGER payment_pay_status_change_trg
    AFTER INSERT OR UPDATE OR DELETE ON payment
    FOR EACH ROW EXECUTE FUNCTION payment_pay_status_change();

-- ---------------------------------------------------------------------------
-- BR-8.4 (симметричная сторона): нельзя изменить сумму заказа, по которому
-- уже есть попытки оплаты, — иначе суммы попыток перестанут равняться
-- total_amount. Доставленным/оплаченным заказам сумма не меняется никогда.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION order_amount_freeze() RETURNS trigger
LANGUAGE plpgsql
AS $f$
BEGIN
    IF NEW.order_amount IS DISTINCT FROM OLD.order_amount
       AND EXISTS (SELECT 1 FROM payment p WHERE p.order_id = OLD.order_id) THEN
        RAISE EXCEPTION 'order: нельзя менять order_amount заказа %, по нему уже есть попытки оплаты (BR-8.4)', OLD.order_id;
    END IF;
    RETURN NEW;
END;
$f$;

CREATE TRIGGER order_amount_freeze_trg
    BEFORE UPDATE OF order_amount ON "order"
    FOR EACH ROW EXECUTE FUNCTION order_amount_freeze();

-- ---------------------------------------------------------------------------
-- Ловушка 3 (BR-7.3): все блюда в заказе — из ресторана заказа.
-- Декларативная альтернатива (составные FK через колонку restaurant_id
-- в order_structure) отвергнута: такая колонка функционально определяется
-- order_id (и product_id) по отдельности — частичная зависимость от частей
-- составного PK, нарушение 2НФ. Поэтому проверка — триггером.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION order_structure_restaurant_check() RETURNS trigger
LANGUAGE plpgsql
AS $f$
DECLARE
    v_order_rest   uuid;
    v_product_rest uuid;
BEGIN
    SELECT o.restaurant_id INTO v_order_rest FROM "order" o WHERE o.order_id = NEW.order_id;
    SELECT p.restaurant_id INTO v_product_rest FROM product p WHERE p.product_id = NEW.product_id;
    IF v_order_rest IS NULL THEN
        RAISE EXCEPTION 'order_structure: заказ % не существует', NEW.order_id;
    END IF;
    IF v_product_rest IS NULL THEN
        RAISE EXCEPTION 'order_structure: блюдо % не существует', NEW.product_id;
    END IF;
    IF v_product_rest IS DISTINCT FROM v_order_rest THEN
        RAISE EXCEPTION 'order_structure: блюдо % не из ресторана заказа % (BR-7.3)',
            NEW.product_id, NEW.order_id;
    END IF;
    RETURN NEW;
END;
$f$;

CREATE TRIGGER order_structure_restaurant_trg
    BEFORE INSERT OR UPDATE ON order_structure
    FOR EACH ROW EXECUTE FUNCTION order_structure_restaurant_check();

-- ---------------------------------------------------------------------------
-- Защита BR-7.3 «задним числом»: нельзя поменять ресторан у заказа или
-- блюда, по которым уже есть позиции в order_structure.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION order_restaurant_freeze() RETURNS trigger
LANGUAGE plpgsql
AS $f$
BEGIN
    IF NEW.restaurant_id IS DISTINCT FROM OLD.restaurant_id
       AND EXISTS (SELECT 1 FROM order_structure os WHERE os.order_id = OLD.order_id) THEN
        RAISE EXCEPTION 'order: нельзя менять ресторан заказа %, в нём уже есть позиции (BR-7.3)', OLD.order_id;
    END IF;
    RETURN NEW;
END;
$f$;

CREATE TRIGGER order_restaurant_freeze_trg
    BEFORE UPDATE OF restaurant_id ON "order"
    FOR EACH ROW EXECUTE FUNCTION order_restaurant_freeze();

CREATE OR REPLACE FUNCTION product_restaurant_freeze() RETURNS trigger
LANGUAGE plpgsql
AS $f$
BEGIN
    IF NEW.restaurant_id IS DISTINCT FROM OLD.restaurant_id
       AND EXISTS (SELECT 1 FROM order_structure os WHERE os.product_id = OLD.product_id) THEN
        RAISE EXCEPTION 'product: нельзя менять ресторан блюда %, оно уже есть в позициях заказов (BR-7.3)', OLD.product_id;
    END IF;
    RETURN NEW;
END;
$f$;

CREATE TRIGGER product_restaurant_freeze_trg
    BEFORE UPDATE OF restaurant_id ON product
    FOR EACH ROW EXECUTE FUNCTION product_restaurant_freeze();
