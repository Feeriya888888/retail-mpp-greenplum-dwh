-- ============================================================================
-- 02_etl_partition_exchange.sql
-- Заполнение справочников, генерация синтетического батча и Partition Exchange
-- ============================================================================

-- 1. Наполнение реплицированных справочников
TRUNCATE TABLE dds.dim_stores;
INSERT INTO dds.dim_stores (store_id, store_name, region_name, city_name, format_type)
SELECT 
    g AS store_id,
    'Store #' || g AS store_name,
    CASE (g % 4)
        WHEN 0 THEN 'Центральный ФО'
        WHEN 1 THEN 'Северо-Западный ФО'
        WHEN 2 THEN 'Приволжский ФО'
        ELSE 'Южный ФО'
    END AS region_name,
    'City_' || (g % 25) AS city_name,
    CASE (g % 3)
        WHEN 0 THEN 'Hypermarket'
        WHEN 1 THEN 'Supermarket'
        ELSE 'Express'
    END AS format_type
FROM generate_series(1, 200) AS g;

TRUNCATE TABLE dds.dim_products;
INSERT INTO dds.dim_products (product_id, sku_code, product_name, category_l1, category_l2, brand_name, is_private_label)
SELECT 
    g AS product_id,
    'SKU-' || LPAD(g::TEXT, 6, '0') AS sku_code,
    'Product Item ' || g AS product_name,
    CASE (g % 5)
        WHEN 0 THEN 'Молочная продукция'
        WHEN 1 THEN 'Бакалея'
        WHEN 2 THEN 'Напитки'
        WHEN 3 THEN 'Мясо и гастрономия'
        ELSE 'Фрукты и овощи'
    END AS category_l1,
    'Subcategory_' || (g % 20) AS category_l2,
    'Brand_' || (g % 50) AS brand_name,
    (g % 4 = 0) AS is_private_label
FROM generate_series(1, 5000) AS g;

ANALYZE dds.dim_stores;
ANALYZE dds.dim_products;

-- 2. Имитация загрузки сырого батча за Март 2026 (500 000 позиций чеков)
TRUNCATE TABLE stg.sales_raw_batch;
INSERT INTO stg.sales_raw_batch (receipt_id, sale_date, store_id, product_id, customer_id, quantity, price, discount)
SELECT 
    (g / 4) + 1000000 AS receipt_id, -- ~4 товара в одном чеке
    DATE '2026-03-01' + (g % 31) AS sale_date,
    (g % 200) + 1 AS store_id,
    (g % 5000) + 1 AS product_id,
    CASE WHEN g % 5 = 0 THEN NULL ELSE (g % 80000) + 1 END AS customer_id,
    ROUND((1 + (random() * 4))::NUMERIC, 2) AS quantity,
    ROUND((50 + (random() * 950))::NUMERIC, 2) AS price,
    ROUND((random() * 30)::NUMERIC, 2) AS discount
FROM generate_series(1, 500000) AS g;

ANALYZE stg.sales_raw_batch;

-- 3. ПАТТЕРН PARTITION EXCHANGE (Атомарная подмена партиции за Март 2026)
-- Шаг 3.1: Создаём временную таблицу с идентичной структурой и DISTRIBUTED BY (receipt_id)
DROP TABLE IF EXISTS stg.tmp_exchange_items_202603;
CREATE TABLE stg.tmp_exchange_items_202603 (LIKE dds.fct_receipt_items)
WITH (
    appendoptimized=true,
    orientation=column,
    compresstype=zstd,
    compresslevel=5
)
DISTRIBUTED BY (receipt_id);

-- Шаг 3.2: Наполняем и очищаем данные за март 2026 параллельно на всех сегментах
INSERT INTO stg.tmp_exchange_items_202603 (
    receipt_id, sale_date, store_id, product_id, customer_id, quantity, price, discount, net_revenue
)
SELECT 
    receipt_id,
    sale_date,
    store_id,
    product_id,
    customer_id,
    quantity,
    price,
    LEAST(discount, price * quantity) AS discount,
    ROUND((price * quantity) - LEAST(discount, price * quantity), 2) AS net_revenue
FROM stg.sales_raw_batch
WHERE sale_date >= DATE '2026-03-01' 
  AND sale_date < DATE '2026-04-01'
  AND price > 0 
  AND quantity > 0;

ANALYZE stg.tmp_exchange_items_202603;

-- Шаг 3.3: Мгновенная подмена партиции в метаданных (без перемещения данных на диске!)
ALTER TABLE dds.fct_receipt_items
EXCHANGE PARTITION FOR (DATE '2026-03-01')
WITH TABLE stg.tmp_exchange_items_202603
WITH VALIDATION;

DROP TABLE IF EXISTS stg.tmp_exchange_items_202603;

-- 4. Обновление витрины данных (Data Mart)
DELETE FROM dm.category_regional_performance WHERE report_month = DATE '2026-03-01';

INSERT INTO dm.category_regional_performance (
    report_month, region_name, category_l1, receipts_count, unique_customers,
    total_quantity, gross_revenue, net_revenue, avg_ticket, private_label_share_pct
)
SELECT 
    DATE_TRUNC('month', f.sale_date)::DATE AS report_month,
    s.region_name,
    p.category_l1,
    COUNT(DISTINCT f.receipt_id) AS receipts_count,
    COUNT(DISTINCT f.customer_id) AS unique_customers,
    SUM(f.quantity) AS total_quantity,
    SUM(f.price * f.quantity) AS gross_revenue,
    SUM(f.net_revenue) AS net_revenue,
    ROUND(SUM(f.net_revenue) / NULLIF(COUNT(DISTINCT f.receipt_id), 0), 2) AS avg_ticket,
    ROUND(
        SUM(CASE WHEN p.is_private_label THEN f.net_revenue ELSE 0 END) 
        / NULLIF(SUM(f.net_revenue), 0) * 100, 
    2) AS private_label_share_pct
FROM dds.fct_receipt_items f
JOIN dds.dim_stores s ON f.store_id = s.store_id       -- Local Join (Replicated)
JOIN dds.dim_products p ON f.product_id = p.product_id -- Local Join (Replicated)
WHERE f.sale_date >= DATE '2026-03-01' AND f.sale_date < DATE '2026-04-01'
GROUP BY 1, 2, 3;

ANALYZE dds.fct_receipt_items;
ANALYZE dm.category_regional_performance;
