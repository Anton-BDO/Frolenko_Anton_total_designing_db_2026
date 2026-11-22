-- ============================================================================
-- 005_functions.sql — get_statistic() (FOOD-106, BR-11.8).
--
-- Статистика по ресторанам, только доставленные заказы, одна строка на
-- ресторан (включая рестораны без заказов — тогда агрегаты 0, а
-- best_product_name/best_user = NULL).
--
-- Оптимизация (BR-11.8): таблица "order" сканируется один раз (CTE
-- delivered, материализуется один раз на три ссылки), order_structure —
-- один раз; топ-блюдо и топ-клиент — через DISTINCT ON (без оконных
-- функций там, где достаточно агрегации, без коррелированных подзапросов
-- в SELECT). Имена колонок — контракт с бэкендом (BR-13.2).
--
-- best_user = client.login: ФИО в схеме хранится только у курьеров,
-- клиент идентифицируется по логину (BR-2.6) — осознанное решение бизнеса
-- (FOOD-106 AC).
-- ============================================================================
SET search_path TO frolenko_food, exts;

DROP FUNCTION IF EXISTS get_statistic();

CREATE OR REPLACE FUNCTION get_statistic()
RETURNS TABLE (
    restaurant_name   varchar,   -- BR-13.2 (контракт имён)
    best_product_name varchar,
    total_amount      numeric,
    avg_amount        numeric,
    best_user         varchar
)
LANGUAGE sql
AS $f$
WITH delivered AS (                       -- единственный скан "order" (BR-11.8)
    SELECT o.order_id, o.restaurant_id, o.client_id, o.total_amount
    FROM "order" o
    WHERE o.status = 'доставлен'
),
rest_agg AS (                             -- total/avg по ресторану
    SELECT d.restaurant_id,
           sum(d.total_amount) AS total_amount,
           avg(d.total_amount) AS avg_amount
    FROM delivered d
    GROUP BY d.restaurant_id
),
prod_qty AS (                             -- суммарное количество по блюдам ресторана
    SELECT d.restaurant_id, os.product_id, sum(os.quantity) AS qty
    FROM delivered d
    JOIN order_structure os ON os.order_id = d.order_id
    GROUP BY d.restaurant_id, os.product_id
),
best_prod AS (                            -- топ-блюдо по SUM(quantity); при равенстве — по имени (детерминированно)
    SELECT DISTINCT ON (pq.restaurant_id)
           pq.restaurant_id, pr.product_name
    FROM prod_qty pq
    JOIN product pr ON pr.product_id = pq.product_id
    ORDER BY pq.restaurant_id, pq.qty DESC, pr.product_name
),
user_cnt AS (                             -- число доставленных заказов по клиентам ресторана
    SELECT d.restaurant_id, d.client_id, count(*) AS cnt
    FROM delivered d
    GROUP BY d.restaurant_id, d.client_id
),
best_usr AS (                             -- топ-клиент; при равенстве — по логину (детерминированно)
    SELECT DISTINCT ON (uc.restaurant_id)
           uc.restaurant_id, cl.login
    FROM user_cnt uc
    JOIN client cl ON cl.client_id = uc.client_id
    ORDER BY uc.restaurant_id, uc.cnt DESC, cl.login
)
SELECT r.restaurant_name,
       bp.product_name  AS best_product_name,
       coalesce(ra.total_amount, 0) AS total_amount,
       coalesce(ra.avg_amount, 0)   AS avg_amount,
       bu.login         AS best_user
FROM restaurant r
LEFT JOIN rest_agg ra ON ra.restaurant_id = r.restaurant_id
LEFT JOIN best_prod bp ON bp.restaurant_id = r.restaurant_id
LEFT JOIN best_usr  bu ON bu.restaurant_id  = r.restaurant_id;
$f$;
