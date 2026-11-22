-- ============================================================================
-- 004_triggers.sql — триггеры схемы frolenko_food.
--   1) rating_change + review_rating_change — пересчёт агрегированного
--      рейтинга блюда/ресторана (FOOD-105, BR-9.6, BR-9.7).
--   2) review_entity_check_trg — валидность полиморфной ссылки review
--      (ловушка 4, BR-9.1): один FK на три таблицы невозможен, поэтому
--      существование сущности проверяется BEFORE INSERT OR UPDATE.
--   3) payment_amount_check_trg — сумма попытки оплаты равна total_amount
--      заказа (BR-8.4): декларативно невыразимо (нужна другая строка),
--      поэтому триггер BEFORE INSERT OR UPDATE.
-- ============================================================================
SET search_path TO frolenko_food, exts;

DROP TRIGGER IF EXISTS review_rating_change   ON review;
DROP TRIGGER IF EXISTS review_entity_check_trg ON review;
DROP TRIGGER IF EXISTS payment_amount_check_trg ON payment;
DROP FUNCTION IF EXISTS rating_change();
DROP FUNCTION IF EXISTS review_entity_check();
DROP FUNCTION IF EXISTS payment_amount_check();

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
-- Ловушка 4 (BR-9.1): entity_id — полиморфная ссылка на product/restaurant/
-- "order". Один FK не может ссылаться на три таблицы, поэтому валидность
-- обеспечивает этот триггер. Обоснование выбора полиморфизма — constraints.md.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION review_entity_check() RETURNS trigger
LANGUAGE plpgsql
AS $f$
BEGIN
    IF NEW.entity_type = 'блюдо' THEN
        IF NOT EXISTS (SELECT 1 FROM product WHERE product_id = NEW.entity_id) THEN
            RAISE EXCEPTION 'review: блюдо % не существует (BR-9.1)', NEW.entity_id;
        END IF;
    ELSIF NEW.entity_type = 'ресторан' THEN
        IF NOT EXISTS (SELECT 1 FROM restaurant WHERE restaurant_id = NEW.entity_id) THEN
            RAISE EXCEPTION 'review: ресторан % не существует (BR-9.1)', NEW.entity_id;
        END IF;
    ELSIF NEW.entity_type = 'заказ' THEN
        IF NOT EXISTS (SELECT 1 FROM "order" WHERE order_id = NEW.entity_id) THEN
            RAISE EXCEPTION 'review: заказ % не существует (BR-9.1)', NEW.entity_id;
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
