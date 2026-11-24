# FoodExpress — база данных

Решение: схема `frolenko_food` (12 таблиц), генератор тестовых данных, процедуры, триггеры, функции, представление, бэкап — по [бэклогу](docs/backlog.md) FOOD-101…FOOD-110. Требования к сдаче — в [docs/acceptance.md](docs/acceptance.md).

## С чего начать
1. Прочитай [онбординг](docs/onboarding.md).
2. Изучи [бизнес-правила](docs/company-rules.md).

## Запуск
```bash
createdb foodexpress_check
psql -d foodexpress_check -c "CREATE SCHEMA exts; CREATE EXTENSION \"uuid-ossp\" WITH SCHEMA exts;"
pg_restore -d foodexpress_check --no-owner --no-privileges db/foodexpress_frolenko.backup
psql -d foodexpress_check -f db/schema/grants.sql
psql -d foodexpress_check -c "CALL frolenko_food.insert_test_data(10);"
```