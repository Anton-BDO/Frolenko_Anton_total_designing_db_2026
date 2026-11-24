-- ============================================================================
-- grants.sql — пользователь inspector и выдача прав (FOOD-109).
--
-- Применять ПОСЛЕ восстановления схемы из бэкапа (FOOD-110).
-- Идемпотентен: повторный запуск не падает.
-- USAGE на information_schema и pg_catalog не отозван и так есть у PUBLIC —
-- явно выдавать не требуется (проверяется запросами G.3/G.4).
-- ============================================================================

-- Создание роли, если её ещё нет (DO-блок — аналог CREATE USER IF NOT EXISTS)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'inspector') THEN
        CREATE USER inspector WITH PASSWORD 'NetoSQL2025';
    END IF;
END $$;

-- Пароль — фиксированный контракт FOOD-109; ALTER идемпотентен
ALTER USER inspector WITH PASSWORD 'NetoSQL2025';

-- Полные права на схему проекта
GRANT ALL PRIVILEGES ON SCHEMA frolenko_food TO inspector;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA frolenko_food TO inspector;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA frolenko_food TO inspector;

-- Вызов функций и процедур (INSERT/SELECT/... выше уже выданы на таблицы;
-- CALL требует EXECUTE на процедуру — ALL FUNCTIONS покрывает функции,
-- ALL PROCEDURES добавлен явно для процедур)
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA frolenko_food TO inspector;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA frolenko_food TO inspector;

-- Инфраструктура заказчика: генерация UUID (BR-13.3, BR-11.1)
GRANT USAGE ON SCHEMA exts TO inspector;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA exts TO inspector;

-- Удобство: search_path по умолчанию (проверки A.2/G.5 опираются на него)
ALTER USER inspector SET search_path TO frolenko_food, exts;
