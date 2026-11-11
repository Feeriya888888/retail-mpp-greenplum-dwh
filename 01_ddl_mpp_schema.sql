-- ============================================================================
-- 01_ddl_mpp_schema.sql
-- Проектирование физической схемы MPP-хранилища в Greenplum
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS dds;
CREATE SCHEMA IF NOT EXISTS dm;

-- ----------------------------------------------------------------------------
-- 1. СЛОЙ ВНЕШНИХ ТАБЛИЦ (PXF / S3) И STAGING
-- ----------------------------------------------------------------------------

-- Пример внешней таблицы для параллельного чтения Parquet из S3 через PXF
-- (Закомментировано для локального запуска без S3, но готово для продакшена)
/*
CREATE EXTERNAL TABLE stg.ext_s3_receipt_items (
    receipt_id BIGINT,
    sale_date DATE,
    store_id INT,
    product_id INT,
    customer_id BIGINT,
    quantity NUMERIC(10,3),
    price NUMERIC(12,2),
    discount NUMERIC(12,2)
)
LOCATION ('pxf://retail-lake/sales/receipts/?PROFILE=s3:parquet&SERVER=default')
FORMAT 'CUSTOM' (FORMATTER='pxfwritable_import');
*/

-- Staging-таблица: быстрая вставка (Heap), случайное распределение (DISTRIBUTED RANDOMLY)
-- для равномерного приёма сырого потока без накладных расходов на хеширование
DROP TABLE IF EXISTS stg.sales_raw_batch;
CREATE TABLE stg.sales_raw_batch (
    receipt_id BIGINT,
    sale_date DATE,
    store_id INT,
    product_id INT,
    customer_id BIGINT,
    quantity NUMERIC(10,3),
    price NUMERIC(12,2),
    discount NUMERIC(12,2),
    loaded_at TIMESTAMP DEFAULT now()
)
WITH (appendoptimized=false)
DISTRIBUTED RANDOMLY;

-- ----------------------------------------------------------------------------
-- 2. CORE LAYER (DDS): ИЗМЕРЕНИЯ И ФАКТЫ
-- ----------------------------------------------------------------------------

-- Справочник магазинов: небольшой размер -> DISTRIBUTED REPLICATED
-- Полная копия таблицы хранится на каждом сегменте -> исключает Broadcast Motion
DROP TABLE IF EXISTS dds.dim_stores;
CREATE TABLE dds.dim_stores (
    store_id INT PRIMARY KEY,
    store_name VARCHAR(100),
    region_name VARCHAR(100),
    city_name VARCHAR(100),
    format_type VARCHAR(30) -- Hypermarket, Supermarket, Express
)
WITH (appendoptimized=false)
DISTRIBUTED REPLICATED;

-- Справочник товаров: DISTRIBUTED REPLICATED для быстрых джойнов с фактами
DROP TABLE IF EXISTS dds.dim_products;
CREATE TABLE dds.dim_products (
    product_id INT PRIMARY KEY,
    sku_code VARCHAR(32),
    product_name VARCHAR(200),
    category_l1 VARCHAR(100),
    category_l2 VARCHAR(100),
    brand_name VARCHAR(100),
    is_private_label BOOLEAN
)
WITH (appendoptimized=false)
DISTRIBUTED REPLICATED;

-- Таблица заголовков чеков: DISTRIBUTED BY (receipt_id)
DROP TABLE IF EXISTS dds.fct_receipts;
CREATE TABLE dds.fct_receipts (
    receipt_id BIGINT NOT NULL,
    sale_date DATE NOT NULL,
    store_id INT NOT NULL,
    customer_id BIGINT,
    total_amount NUMERIC(14,2),
    total_discount NUMERIC(14,2),
    items_count INT
)
WITH (
    appendoptimized=true,
    orientation=column,
    compresstype=zstd,
    compresslevel=5
)
DISTRIBUTED BY (receipt_id)
PARTITION BY RANGE (sale_date) (
    START (DATE '2026-01-01') INCLUSIVE
    END (DATE '2026-05-01') EXCLUSIVE
    EVERY (INTERVAL '1 month'),
    DEFAULT PARTITION p_default
);

-- Главная таблица фактов (строки чеков):
-- 1) Колоночное хранение (orientation=column) + сжатие ZSTD (экономия места ~5x)
-- 2) DISTRIBUTED BY (receipt_id) -> Co-located Join с dds.fct_receipts без Redistribute!
-- 3) Партиционирование по месяцам для Partition Pruning и Partition Exchange
DROP TABLE IF EXISTS dds.fct_receipt_items;
CREATE TABLE dds.fct_receipt_items (
    receipt_id BIGINT NOT NULL,
    sale_date DATE NOT NULL,
    store_id INT NOT NULL,
    product_id INT NOT NULL,
    customer_id BIGINT,
    quantity NUMERIC(10,3) NOT NULL,
    price NUMERIC(12,2) NOT NULL,
    discount NUMERIC(12,2) DEFAULT 0,
    net_revenue NUMERIC(14,2) NOT NULL
)
WITH (
    appendoptimized=true,
    orientation=column,
    compresstype=zstd,
    compresslevel=5
)
DISTRIBUTED BY (receipt_id)
PARTITION BY RANGE (sale_date) (
    START (DATE '2026-01-01') INCLUSIVE
    END (DATE '2026-05-01') EXCLUSIVE
    EVERY (INTERVAL '1 month'),
    DEFAULT PARTITION p_default
);

-- ----------------------------------------------------------------------------
-- 3. DATA MARTS LAYER (ВИТРИНЫ ДАННЫХ)
-- ----------------------------------------------------------------------------

-- Витрина эффективности категорий по регионам
DROP TABLE IF EXISTS dm.category_regional_performance;
CREATE TABLE dm.category_regional_performance (
    report_month DATE NOT NULL,
    region_name VARCHAR(100) NOT NULL,
    category_l1 VARCHAR(100) NOT NULL,
    receipts_count BIGINT,
    unique_customers BIGINT,
    total_quantity NUMERIC(16,3),
    gross_revenue NUMERIC(18,2),
    net_revenue NUMERIC(18,2),
    avg_ticket NUMERIC(12,2),
    private_label_share_pct NUMERIC(5,2)
)
WITH (appendoptimized=true, orientation=column, compresstype=zstd, compresslevel=3)
DISTRIBUTED BY (region_name, category_l1);
