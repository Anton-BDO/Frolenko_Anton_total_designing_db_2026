-- Регрессионные тесты целостности FoodExpress.
-- Запускать под inspector после восстановления .backup и применения grants.sql:
--   psql -U inspector -d foodexpress_check -f db/regression_tests.sql
-- Каждый блок откатывает свои изменения; сгенерированные данные остаются.

\set ON_ERROR_STOP on
SET search_path TO frolenko_food, exts;

CALL erase_test_data();
CALL insert_test_data(10);

\echo '=== R.1. Перенос оплаты пересчитывает оба заказа ==='
BEGIN;
DO $$
DECLARE
    v_source uuid;
    v_target uuid;
    v_payment uuid;
    v_target_total numeric;
    v_source_status order_pay_status;
    v_target_status order_pay_status;
BEGIN
    SELECT p.order_id, p.payment_id
      INTO v_source, v_payment
    FROM payment p
    WHERE p.status = 'успех'
    ORDER BY p.order_id
    LIMIT 1;

    SELECT o.order_id, o.total_amount
      INTO v_target, v_target_total
    FROM "order" o
    WHERE o.order_id <> v_source
    ORDER BY o.order_id
    LIMIT 1;

    DELETE FROM payment WHERE order_id = v_target;
    UPDATE payment
    SET order_id = v_target, amount = v_target_total
    WHERE payment_id = v_payment;

    SELECT pay_status INTO v_source_status FROM "order" WHERE order_id = v_source;
    SELECT pay_status INTO v_target_status FROM "order" WHERE order_id = v_target;

    IF v_source_status <> 'ожидает' THEN
        RAISE EXCEPTION 'R.1 FAIL: у старого заказа pay_status=%, ожидался ожидает', v_source_status;
    END IF;
    IF v_target_status <> 'оплачен' THEN
        RAISE EXCEPTION 'R.1 FAIL: у нового заказа pay_status=%, ожидался оплачен', v_target_status;
    END IF;
    IF EXISTS (SELECT 1 FROM payment WHERE order_id = v_source) THEN
        RAISE EXCEPTION 'R.1 FAIL: у старого заказа остались попытки оплаты';
    END IF;

    RAISE NOTICE 'R.1 OK: старый заказ=ожидает, новый заказ=оплачен';
END $$;
ROLLBACK;

\echo '=== R.2. Клиент заказа с отзывами нельзя изменить ==='
BEGIN;
DO $$
DECLARE
    v_order uuid;
    v_address uuid;
    v_old_client uuid;
    v_new_client uuid;
    v_rejected boolean := false;
BEGIN
    SELECT r.order_id, o.address_id, r.client_id
      INTO v_order, v_address, v_old_client
    FROM review r JOIN "order" o ON o.order_id = r.order_id
    ORDER BY r.review_id
    LIMIT 1;

    SELECT client_id INTO v_new_client
    FROM client WHERE client_id <> v_old_client
    ORDER BY client_id LIMIT 1;

    -- Даём новому клиенту адрес заказа, чтобы составной FK не мешал
    -- проверить именно защиту существующих отзывов.
    INSERT INTO client_address(client_id, address_id)
    VALUES (v_new_client, v_address)
    ON CONFLICT DO NOTHING;

    BEGIN
        UPDATE "order" SET client_id = v_new_client WHERE order_id = v_order;
    EXCEPTION WHEN OTHERS THEN
        v_rejected := true;
        RAISE NOTICE 'Ожидаемая ошибка: %', SQLERRM;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'R.2 FAIL: клиент заказа с отзывами изменён';
    END IF;
    RAISE NOTICE 'R.2 OK: изменение клиента отклонено';
END $$;
ROLLBACK;

\echo '=== R.3. Позицию с отзывом нельзя удалить или перенести ==='
BEGIN;
DO $$
DECLARE
    v_order uuid;
    v_product uuid;
    v_other_product uuid;
    v_rejected boolean;
BEGIN
    -- Нужен заказ, в ресторане которого есть другое блюдо вне его позиций:
    -- тогда UPDATE пройдёт ресторанную проверку и проверит именно guard отзывов.
    SELECT r.order_id, r.entity_id
      INTO v_order, v_product
    FROM review r
    JOIN "order" o ON o.order_id = r.order_id
    WHERE r.entity_type = 'блюдо'
      AND EXISTS (
          SELECT 1 FROM product p
          WHERE p.restaurant_id = o.restaurant_id
            AND NOT EXISTS (
                SELECT 1 FROM order_structure os
                WHERE os.order_id = r.order_id AND os.product_id = p.product_id))
    ORDER BY r.review_id
    LIMIT 1;

    IF v_order IS NULL THEN
        RAISE EXCEPTION 'R.3 FAIL: не найдены исходные данные для теста';
    END IF;

    v_rejected := false;
    BEGIN
        DELETE FROM order_structure
        WHERE order_id = v_order AND product_id = v_product;
    EXCEPTION WHEN OTHERS THEN
        v_rejected := true;
        RAISE NOTICE 'Ожидаемая ошибка DELETE: %', SQLERRM;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'R.3 FAIL: позиция с отзывом удалена';
    END IF;

    SELECT p.product_id INTO v_other_product
    FROM product p JOIN "order" o ON o.order_id = v_order
    WHERE p.restaurant_id = o.restaurant_id
      AND NOT EXISTS (
          SELECT 1 FROM order_structure os
          WHERE os.order_id = v_order AND os.product_id = p.product_id)
    LIMIT 1;

    v_rejected := false;
    BEGIN
        UPDATE order_structure SET product_id = v_other_product
        WHERE order_id = v_order AND product_id = v_product;
    EXCEPTION WHEN OTHERS THEN
        v_rejected := true;
        RAISE NOTICE 'Ожидаемая ошибка UPDATE: %', SQLERRM;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'R.3 FAIL: позиция с отзывом перенесена на другое блюдо';
    END IF;

    RAISE NOTICE 'R.3 OK: DELETE и UPDATE позиции с отзывом отклонены';
END $$;
ROLLBACK;

\echo '=== Все регрессионные тесты пройдены ==='
SELECT count(*) AS orders_remain FROM "order";
