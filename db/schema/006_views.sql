-- ============================================================================
-- 006_views.sql — представление how_much_money (FOOD-108, BR-11.9).
--
-- Отчёт «сколько денег» по месяцам: от первого месяца с доставленными
-- заказами до последнего, без пропусков. Непрерывая серия месяцев строится
-- РЕКУРСИВНЫМ CTE (обязательное требование BR-11.9); месяцы без заказов
-- присутствуют с нулевыми суммами.
--
--   commission      = sum_with_commission - sum_no_commission
--   prev_commission = LAG(commission) (NULL в первом месяце)
--   commission_diff = commission - prev_commission
--   courier_pay     = сумма courier_pay.amount за месяц (0, если нет)
--   net_profit      = commission - courier_pay
-- ============================================================================
SET search_path TO frolenko_food, exts;

DROP VIEW IF EXISTS how_much_money;

CREATE OR REPLACE VIEW how_much_money AS
WITH RECURSIVE
-- границы: первый и последний месяц с доставленными заказами
bounds AS (
    SELECT date_trunc('month', min(o.order_timestamp)) AS m_first,
           date_trunc('month', max(o.order_timestamp)) AS m_last
    FROM "order" o
    WHERE o.status = 'доставлен'
),
-- рекурсивная серия месяцев (BR-11.9)
months AS (
    SELECT b.m_first AS m, b.m_last
    FROM bounds b
    WHERE b.m_first IS NOT NULL
    UNION ALL
    SELECT m.m + interval '1 month', m.m_last
    FROM months m
    WHERE m.m < m.m_last
),
-- агрегаты по доставленным заказам за месяц
ord AS (
    SELECT date_trunc('month', o.order_timestamp) AS m,
           sum(o.order_amount) AS sum_no_commission,
           sum(o.total_amount) AS sum_with_commission
    FROM "order" o
    WHERE o.status = 'доставлен'
    GROUP BY 1
),
-- выплаты курьерам за месяц
pay AS (
    SELECT date_trunc('month', make_date(cp.year, cp.month, 1)) AS m,
           sum(cp.amount) AS pay_sum
    FROM courier_pay cp
    GROUP BY 1
),
calc AS (
    SELECT m.m,
           coalesce(o.sum_no_commission, 0)   AS sum_no_commission,
           coalesce(o.sum_with_commission, 0) AS sum_with_commission,
           coalesce(o.sum_with_commission, 0) - coalesce(o.sum_no_commission, 0) AS commission,
           coalesce(p.pay_sum, 0)             AS courier_pay
    FROM months m
    LEFT JOIN ord o ON o.m = m.m
    LEFT JOIN pay p ON p.m = m.m
)
SELECT to_char(c.m, 'YYYY-MM') AS year_month,          -- text, формат YYYY-MM
       c.sum_no_commission,
       c.sum_with_commission,
       c.commission,
       lag(c.commission) OVER w      AS prev_commission,
       c.commission - lag(c.commission) OVER w AS commission_diff,
       c.courier_pay,
       c.commission - c.courier_pay  AS net_profit
FROM calc c
WINDOW w AS (ORDER BY c.m);
