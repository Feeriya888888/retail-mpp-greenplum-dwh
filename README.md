# Retail Omni-Channel MPP Data Warehouse on Greenplum

Промышленный проект: проектирование распределённого аналитического хранилища (MPP) на базе **Greenplum Database** для крупного омниканального ритейлера (обработка миллиардов чеков, товарных позиций и карт лояльности).

## 1. Архитектура решения и особенности MPP

В отличие от классических одноузловых СУБД (PostgreSQL), **Greenplum** распределяет данные и вычисления по множеству независимых сегментов (Segments). Ключевая задача архитектора — избежать перекоса данных (**Data Skew**) и дорогостоящего сетевого перераспределения (**Redistribute Motion**).

```
[ S3 / PXF External Tables (ext_sales_raw) ]
                     │
                     ▼ (Parallel Load across Segments)
[ Staging Layer (st_sales_batch — Heap, Distributed Randomly) ]
                     │
                     ▼ (ELT / Partition Exchange & Co-located Joins)
[ Core DWH Layer (dds_receipt_items — Append-Optimized, Column-Oriented, ZSTD) ]
                     │
                     ▼ (Distributed Aggregation)
[ Data Marts (dm_category_performance, dm_rfm_loyalty) ]
```

### Применённые инженерные практики Greenplum:
1. **Стратегия распределения (`DISTRIBUTED BY`):**
   * Таблицы фактов (`dds_receipt_items`) и заголовков чеков (`dds_receipts`) распределены по ключу высокой кардинальности **`(receipt_id)`**. Это обеспечивает **Co-located Join** (локальное соединение данных на каждом сегменте без передачи данных по сети между узлами).
   * Небольшие справочники (`dds_stores`, `dds_products`) используют **`DISTRIBUTED REPLICATED`**, что полностью исключает `Broadcast Motion` при джойнах.
2. **Физическое хранение (`AO / Column-Oriented + ZSTD`):**
   * Для исторических фактов используется движок **`appendoptimized=true, orientation=column, compresstype=zstd, compresslevel=5`**, что снижает объём занимаемого места на диске в 4–6 раз и ускоряет сканирование агрегатов (чтение только нужных колонок).
3. **Многоуровневое партиционирование и Partition Exchange:**
   * Таблица фактов разбита на месячные партиции (`PARTITION BY RANGE (sale_date)`). Загрузка новых данных выполняется через паттерн **Partition Exchange** (подмена партиции подготовленной таблицей без блокировок и фрагментации).
4. **Интеграция с внешними хранилищами (`PXF`):**
   * Реализовано чтение сырых Parquet-файлов из S3/MinIO напрямую в сегменты Greenplum через протокол **Greenplum Platform Extension Framework (PXF)**.
5. **Диагностика перекосов (`gp_toolkit`):**
   * Включены скрипты мониторинга распределения данных по сегментам (`gp_skew_coefficients`) и анализа планов выполнения (`EXPLAIN ANALYZE` без `Redistribute Motion`).

## 2. Структура проекта

```text
retail-mpp-greenplum-dwh/
├── README.md                     # Архитектурная документация и обоснование проектных решений
├── docker-compose.yml            # Локальный кластер Greenplum (Master + Segments)
├── 01_ddl_mpp_schema.sql         # DDL слоёв Stage, Core (AO/Columnar, Replicated), Marts и PXF
├── 02_etl_partition_exchange.sql # Пайплайн загрузки с генерацией данных и Partition Exchange
└── 03_skew_and_explain_audit.sql # Скрипты аудита Data Skew, gp_toolkit и аналитические запросы
```

## 3. Пошаговая инструкция запуска

1. **Запустите кластер Greenplum в Docker:**
   ```bash
   docker-compose up -d
   ```
   *(Дождитесь инициализации мастер-ноды и сегментов — обычно занимает 30–45 секунд).*

2. **Создайте схему хранилища (DDL):**
   ```bash
   docker exec -i gp_master psql -U gpadmin -d retail_dwh < 01_ddl_mpp_schema.sql
   ```

3. **Запустите генерацию данных и пайплайн загрузки (Partition Exchange):**
   ```bash
   docker exec -i gp_master psql -U gpadmin -d retail_dwh < 02_etl_partition_exchange.sql
   ```

4. **Выполните аудит перекоса данных (Data Skew) и планов выполнения:**
   ```bash
   docker exec -i gp_master psql -U gpadmin -d retail_dwh < 03_skew_and_explain_audit.sql
   ```
