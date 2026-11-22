# Протокол для самопроверки — FoodExpress, схема `frolenko_food`

Прогон выполнен на восстановленной из `db/foodexpress_frolenko.backup` базе `foodexpress_check` (чистая БД + схема `exts` с `uuid-ossp`, затем `db/schema/grants.sql`). Все проверки — под `inspector`.

## Окружение

| Параметр | Значение |
|---|---|
| PostgreSQL version | PostgreSQL 17.11 on x86_64-windows (SELECT version(); ≥ 15 ✓) |
| Дата проверки | 2026-11-22 |
| Схема | `frolenko_food` |
| Роль-аудитор | `inspector` |

Все проверки — под `inspector`, если не указано иное.

---

## A. Подготовка

### A.1. Восстановление бэкапа

Дамп: `pg_dump -U postgres -Fc -x -n frolenko_food -d foodexpress_dev -f db/foodexpress_frolenko.backup` (ключ `-x`/`--no-privileges` намеренно: ACL выдаётся отдельно через `db/schema/grants.sql` после восстановления — иначе бэкап содержал бы `GRANT ... TO inspector` и не восстанавливался бы на чистый кластер без этой роли).

Восстановление: `pg_restore -U postgres -d foodexpress_check --exit-on-error db/foodexpress_frolenko.backup` — без ошибок, код выхода 0.

Факт: восстановлено 12 таблиц (пустых), 16 FK, 8 enum-типов, 4 процедуры + 1 функция + 10 триггер-функций, 11 триггеров, 1 представление; `client` пуста (в бэкапе только структура).
Вердикт: OK

### A.2. Переключение на inspector

```sql
SET ROLE inspector;
SET search_path TO frolenko_food, exts;
SELECT current_user;
```

Факт: `inspector`.
Вердикт: OK

---

## B. FOOD-101: Структура схемы

### B.1. Схема существует

Факт: `frolenko_food` (1 строка).
Вердикт: OK

### B.2. Схема `exts` с `uuid-ossp`

Факт: `uuid-ossp`, схема `exts`.
Вердикт: OK

### B.3. Все 12 исходных таблиц + N после нормализации

Факт: `address`, `client`, `client_address`, `courier`, `courier_pay`, `order`, `order_structure`, `payment`, `product`, `product_category`, `restaurant`, `review` — ровно 12, дополнительных таблиц не потребовалось (нормализация обошлась без новых сущностей; полиморфный отзыв — в той же таблице `review`).
Вердикт: OK

### B.4. Все PK — `uuid`

Факт: пусто (все колонки вида `%_id` имеют тип `uuid`, включая `payment.transaction_id`).
Вердикт: OK

### B.5. Enum-типы

Факт: 8 типов со значениями из constraints.md: `courier_status {свободен,занят,на_доставке,уволен}`, `order_pay_status {ожидает,оплачен,ошибка}`, `order_status {создан,готовится,в_доставке,доставлен,отменён}`, `payment_status {успех,ошибка,в_обработке}`, `payment_type {карта,наличные,безнал}`, `product_status {доступно,нет_в_наличии,архив}`, `restaurant_status {активен,неактивен}`, `review_entity_type {блюдо,ресторан,заказ}`.
Вердикт: OK

### B.6. FK-ограничения

Факт: 16 FK (≥ 15), все связи ERD реализованы, составной FK — один (ловушка 2). Ловушка 3 решена триггером (см. constraints.md): составные FK через техническую колонку `order_structure.restaurant_id` отвергнуты, т.к. нарушали 2НФ.
Вердикт: OK

### B.7. Пароль — MD5

Факт (после C.2, на сгенерированных данных): `len = 32`, hex-строки (`0eafb4f31979cad5bcbba84c43d873bb` и т.п.).
Вердикт: OK

---

## C. FOOD-102: `insert_test_data(value)`

### C.1. Чистая схема

Факт: `CALL erase_test_data();` — без ошибок (на пустой восстановленной схеме).
Вердикт: OK

### C.2. Первый запуск

Факт: `CALL insert_test_data(10);` — без ошибок.
Вердикт: OK

### C.3. Распределение строк (BR-11.7)

Факт:

| tbl | count |
|---|---|
| address | 50 |
| client | 10 |
| courier | 10 |
| order | 50 |
| payment | 50 |
| product | 50 |
| product_category | 10 |
| restaurant | 10 |
| review | 50 |

Вердикт: OK

### C.4. Адреса ресторанов vs клиентов (BR-11.7)

Факт: 10 ресторанных адресов, 50 всего → 40 клиентских.
Вердикт: OK

### C.5. Нет пустых строк (BR-11.3)

Факт: 0 пустых строк в `client`, `address`, `restaurant`, `product`, `courier`, `"order"`, `review`.
Вердикт: OK

### C.6. Нет NULL там, где запрещено (BR-11.3)

Факт: 0 нарушений в `"order"` (client_id, restaurant_id, courier_id, address_id, total_amount), `payment`, `review`, `product`.
Вердикт: OK

### C.7. Минимум один активный курьер (BR-6.6)

Факт: 7 (плюс 3 уволенных с заполненной датой увольнения).
Вердикт: OK

### C.8. `courier_pay` консистентен с правилами (BR-10.2)

Факт: 0 строк, где `amount ≠ round(Σ commission доставленных заказов курьера в месяце × coefficient_used, 2)`; записи за 6 месяцев × все курьеры.
Вердикт: OK

### C.9. Повторный вызов не ломает

Факт: 10 вызовов `insert_test_data(10)` подряд в одной транзакции-цикле — без ошибок; `client` = 110. Решение: чистые вставки новых строк (новые UUID), уникальность логинов/телефонов — счётчик «текущее количество + i» (зафиксировано в constraints.md).
Вердикт: OK

---

## D. Проверки бизнес-правил на сгенерированных данных

| Проверка | Факт | Вердикт |
|---|---|---|
| D.1 все FK валидны (7 связей, включая составную) | все orphans = 0 | OK |
| D.2 `total_amount < 1000` (BR-1.8) | 0 | OK |
| D.3 комиссия = 10% (BR-1.4) | 0 | OK |
| D.4 `total = amount + commission` | 0 | OK |
| D.5 доставка не раньше создания (BR-7.13) | 0 | OK |
| D.6 адрес принадлежит клиенту (BR-7.4) | 0 | OK |
| D.7 блюда из одного ресторана (BR-7.3) | 0 | OK |
| D.8 не более одной успешной оплаты (BR-8.1) | пусто | OK |
| D.9 сумма оплаты = total (BR-8.4) | 0 | OK |
| D.10 дубликаты `client_address` (BR-2.5) | пусто | OK |
| D.11 дубликаты `order_structure` (BR-7.16) | пусто | OK |
| D.12 `work_end > work_start` (BR-4.4) | 0 | OK |
| D.13 `dismissal >= hire` (BR-6.3) | 0 | OK |
| D.14 рейтинг = AVG отзывов (BR-9.6) | mismatch: 0 / 0; с рейтингом: 225 блюд, 93 ресторана | OK |
| D.15 `order_amount = SUM(price × quantity)` по позициям заказа | 0 нарушений | OK |
| D.16 дата заказа в пределах периода работы курьера (hire … dismissal) | 0 нарушений | OK |
| D.17 `pay_status` заказа консистентен с попытками оплаты (BR-8.7) | 0 нарушений | OK |
| D.18 «доставлен» ⇒ `delivery_timestamp IS NOT NULL` (BR-7.12) | 0 нарушений | OK |

---

## E. Функции и процедуры

### E.1. `add_product` — успешный вызов

Факт: `before = 550, after = 551` (вызывался после C.9 — данных много; на свежем `insert_test_data(10)`: 50 → 51).
Вердикт: OK

### E.2. `add_product` — падает на несуществующий ресторан

Факт: `ERROR: add_product: ресторан 00000000-0000-0000-0000-000000000000 не существует`. Аналогично для несуществующей категории, пустого имени и нарушения CHECK (`price = -5` → понятное сообщение о `price >= 0, rating 0..5, статус из enum`).
Вердикт: OK

### E.3. `rating_change` — пересчитывает рейтинг

Факт: 3 отзыва (3, 4, 5) на одно блюдо → `rating = 4.00`.
Вердикт: OK

Примечание: с включённой проверкой BR-9.2 (триггер `review_entity_check`) отзыв нельзя вставить «на первые попавшиеся id» — требуются согласованные данные одного заказа: `client_id` = клиент заказа, для `entity_type = 'блюдо'` блюдо — из состава этого заказа, для `'ресторан'` — ресторан заказа, для `'заказ'` — `entity_id = order_id`. Несогласованная вставка отклоняется с внятной ошибкой (см. E.8). Тест E.3/E.4 выполнялся на согласованных данных.

### E.4. `rating_change` — удаление отзыва

Факт: удаление одного → `4.50`; удаление всех → `NULL`. UPDATE с переносом отзыва на другое блюдо: старое → `NULL`, новое → пересчитано.
Вердикт: OK

### E.5. `get_statistic()`

Факт: колонки `restaurant_name`, `best_product_name`, `total_amount`, `avg_amount`, `best_user`; по одной строке на ресторан (на данных после C.9 — 110 строк); `best_user` = `client.login`; рестораны без доставленных заказов присутствуют с нулями (проверено на dev-данных).
Вердикт: OK

### E.6. `courier_salary()`

Факт: записи за текущий месяц созданы у всех курьеров (в т.ч. уволенных — BR-10.6). Контрольный тест: при установленном `coefficient = 0.3` после вызова у уволенного остался `0.3`, у работающего пересчитан по BR-10.2 (`0.3 → 0.1`, доставок ≤ 150).
Вердикт: OK

### E.7. `courier_salary()` — повторный вызов

Факт: записей за текущий месяц 110 → 110 (UPSERT по PK `(year, month, courier_id)`, BR-10.3). Повторный вызов не пересчитывает коэффициент заново и не перезаписывает `coefficient_used`: берётся сохранённый в записи месяца коэффициент, обновляется только `amount` по той же формуле. Проверено: сравнение `(amount, coefficient_used)` до и после повторного вызова — 0 изменённых строк.
Вердикт: OK

### E.8. `review_entity_check` — негативные тесты BR-9.2

Факт (все 4 случая отклонены с внятными ошибками):

- отзыв от клиента, не оформлявшего заказ → ошибка «отзыв оставляет клиент заказа»;
- `entity_type = 'блюдо'` с блюдом не из состава заказа → ошибка «блюдо не входит в состав заказа»;
- `entity_type = 'ресторан'` с `entity_id` ≠ `restaurant_id` заказа → ошибка о несоответствии ресторана заказу;
- `entity_type = 'заказ'` с `entity_id` ≠ `order_id` отзыва → ошибка о несоответствии заказа.

Вердикт: OK

### E.9. Триггеры целостности оплат и ресторанов — негативные тесты

Факт (все случаи отклонены / пересчитаны корректно):

- удаление единственной успешной попытки оплаты → `pay_status` заказа пересчитан триггером `payment_pay_status_change` в `'ожидает'` (BR-8.7);
- `UPDATE "order" SET order_amount = ...` при существующей попытке оплаты → отклонён триггером `order_amount_freeze` (BR-8.4);
- вставка позиции с блюдом чужого ресторана → отклонена триггером `order_structure_restaurant_check` (BR-7.3);
- `UPDATE "order" SET restaurant_id = ...` у заказа с позициями → отклонён триггером `order_restaurant_freeze`;
- `UPDATE product SET restaurant_id = ...` у блюда, входящего в позиции заказов → отклонён триггером `product_restaurant_freeze`.

Вердикт: OK

### E.10. Регрессионные тесты обратных изменений связей

Воспроизводимый файл: `db/regression_tests.sql`. Запуск под `inspector` после восстановления бэкапа и применения `grants.sql`:

```bash
psql -U inspector -d foodexpress_check -f db/regression_tests.sql
```

Факт (все проверки пройдены, тестовые изменения откачены):

- перенос успешной попытки оплаты через `UPDATE payment.order_id` → прежний заказ получает `pay_status = 'ожидает'`, новый — `'оплачен'`; у прежнего не остаётся попыток;
- `UPDATE "order" SET client_id = ...` при существующих отзывах → отклонён триггером `order_client_review_guard` (BR-9.2);
- `DELETE FROM order_structure` для позиции с отзывом → отклонён триггером `order_structure_review_guard`;
- `UPDATE order_structure SET product_id = ...` для позиции с отзывом → отклонён тем же триггером; обычное изменение `quantity` не блокируется.

Вердикт: OK

---

## F. Представление `how_much_money`

### F.1. Колонки

Факт: `year_month` (text), `sum_no_commission`, `sum_with_commission`, `commission`, `prev_commission`, `commission_diff`, `courier_pay`, `net_profit` (numeric) — 8 колонок.
Вердикт: OK

### F.2. Месяцы покрыты

Факт: серия 2026-05 … 2026-11 (7 месяцев), от первого до последнего месяца с доставленными заказами, ни одного пропуска.
Вердикт: OK

### F.3. Месяцы без заказов присутствуют (BR-11.9)

Факт: в текущем наборе пустых месяцев нет (запрос вернул 0 строк). Покрытие серией гарантировано конструкцией: месяцы генерирует рекурсивный CTE независимо от наличия заказов, к ним LEFT JOIN агрегатов — при пустом месяце суммы будут 0 (проверено на dev: `net_profit` пустого месяца = 0).
Вердикт: OK

### F.4. Корректность сумм

Факт (фрагмент):

| year_month | sum_no_commission | sum_with_commission | commission | prev_commission | commission_diff | courier_pay | net_profit |
|---|---|---|---|---|---|---|---|
| 2026-05 | 45318.00 | 49849.80 | 4531.80 | (null) | (null) | 0 | 4531.80 |
| 2026-06 | 260284.00 | 286312.40 | 26028.40 | 4531.80 | 21496.60 | 2602.84 | 23425.56 |
| 2026-07 | 337708.00 | 371478.80 | 33770.80 | 26028.40 | 7742.40 | 3377.08 | 30393.72 |

Все строки (7/7): `commission = sum_with_commission - sum_no_commission`, `commission_diff = commission - prev_commission` (NULL в первом месяце), `net_profit = commission - courier_pay`. Несоответствий: 0.
Вердикт: OK

---

## G. Права `inspector`

### G.1. Права на схему

Факт: `frolenko_food`, usage = `true`, create = `true`.
Вердикт: OK

### G.2. Права на таблицы

Факт: у всех 13 объектов (12 таблиц + представление) есть полный набор привилегий (`INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER`).
Вердикт: OK

### G.3. `information_schema` читается под `inspector`

Факт: 13 (12 таблиц + представление `how_much_money` — `information_schema.tables` включает представления).
Вердикт: OK

### G.4. `pg_catalog` читается под `inspector`

Факт: 12.
Вердикт: OK

### G.5. Все процедуры/функции работают под `inspector`

Факт: `CALL erase_test_data()`, `CALL insert_test_data(10)`, `CALL courier_salary()`, `SELECT * FROM get_statistic()` (10 строк), `SELECT * FROM how_much_money` — всё без `permission denied`.
Вердикт: OK

---

## H. Оптимизация `get_statistic` (BR-11.8)

### H.1. `EXPLAIN ANALYZE` — паттерн «избыточные подзапросы»

Факт: время 0.434 мс, план — `Seq Scan on courier` + два `SubPlan` (каждый — `Aggregate` + `Seq Scan on "order"`):

```
 Seq Scan on courier c (actual rows=10 loops=1)
   SubPlan 1 -> Aggregate -> Seq Scan on "order" o (loops=10)
   SubPlan 2 -> Aggregate -> Seq Scan on "order" o_1 (loops=10)
```

Вердикт: OK (эталонный «плохой» паттерн подтверждён: два скана `"order"` на курьера)

### H.2. `EXPLAIN ANALYZE` — паттерн «один JOIN»

Факт: время 0.106 мс (< H.1), план — один `HashAggregate` + `Hash Right Join`, единственный скан `"order"`:

```
 HashAggregate (actual rows=10 loops=1)
   -> Hash Right Join (actual rows=34 loops=1)
        -> Seq Scan on "order" o (Filter: status = 'доставлен')
        -> Hash -> Seq Scan on courier c
```

Вердикт: OK

### H.3. Применить к `get_statistic`

Факт: `EXPLAIN ANALYZE SELECT * FROM get_statistic()` — `Function Scan on get_statistic (actual rows=10, Execution Time: 8.060 ms)`. Внутренний план тела функции (SQL-функция, планируется как одна связка): `"order"` сканируется **один раз** (CTE `delivered`, материализуется один раз, далее три CTE Scan), `order_structure` — один раз, `restaurant`/`product`/`client` — по одному разу; без `LATERAL`, без коррелированных подзапросов к одной таблице, без оконных функций (топ-блюдо и топ-клиент — `DISTINCT ON` после агрегации):

```
CTE delivered -> Seq Scan on "order" (Filter: status = 'доставлен')   -- единственный скан "order"
 Hash Left Join x3 (rest_agg / best_prod / best_usr через Hash)
   best_prod: Unique -> Sort -> Hash Join (HashAggregate по prod_qty + Seq Scan order_structure + Seq Scan product)
   best_usr:  Unique -> Sort -> Hash Join (HashAggregate по user_cnt + Seq Scan client)
 Execution Time: 0.804 ms (внутренний запрос)
```

Вердикт: OK

---

## I. Очистка и повторная генерация

### I.1. `erase_test_data` очищает всё

Факт: все 12 таблиц — 0 строк.
Вердикт: OK

### I.2. Повторный `erase_test_data` не падает

Факт: `CALL erase_test_data();` — без ошибок.
Вердикт: OK

### I.3. После очистки `insert_test_data` снова работает

Факт: `CALL insert_test_data(10);` → `count(*) FROM "order"` = 50.
Вердикт: OK
