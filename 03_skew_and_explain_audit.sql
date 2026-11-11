-- ============================================================================
-- 03_skew_and_explain_audit.sql
-- Диагностика перекосов (Data Skew), проверка сжатия и анализ MPP-планов
-- ============================================================================

-- 1. ПРОВЕРКА РАСПРЕДЕЛЕНИЯ ДАННЫХ ПО СЕГМЕНТАМ (DATA SKEW AUDIT)
-- Идеальный баланс: на каждом сегменте (gp_segment_id) должно быть примерно одинаковое число строк
SELECT 
    gp_segment_id,
    COUNT(*) AS rows_on_segment,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM dds.fct_receipt_items
GROUP BY gp_segment_id
ORDER BY gp_segment_id;

-- 2. ПРОВЕРКА КОЭФФИЦИЕНТА СЖАТИЯ (ZSTD + COLUMNAR ORIENTATION)
SELECT 
    'dds.fct_receipt_items_1_prt_2' AS partition_name,
    pg_size_pretty(pg_relation_size('dds.fct_receipt_items_1_prt_2')) AS compressed_size,
    get_ao_compression_ratio('dds.fct_receipt_items_1_prt_2') AS compression_ratio;

-- 3. ПРОВЕРКА КОЭФФИЦИЕНТА ПЕРЕКОСА ЧЕРЕЗ GP_TOOLKIT
SELECT 
    skcname AS table_name,
    skcnamespace AS schema_name,
    skccoeff AS skew_coefficient -- Значение ближе к 0 означает идеальное распределение
FROM gp_toolkit.gp_skew_coefficients
WHERE skcnamespace = 'dds' AND skcname LIKE 'fct_receipt_items%';

-- 4. ПРОВЕРКА ПЛАНА ВЫПОЛНЕНИЯ (EXPLAIN) ДЛЯ CO-LOCATED JOIN И PARTITION PRUNING
-- В плане должны отсутствовать:
--   - Seq Scan на партициях за другие месяцы (работает Partition Pruning)
--   - Redistribute Motion / Broadcast Motion при джойне с dim_stores и dim_products
EXPLAIN
SELECT 
    s.region_name,
    p.category_l1,
    SUM(f.net_revenue) AS revenue
FROM dds.fct_receipt_items f
JOIN dds.dim_stores s ON f.store_id = s.store_id
JOIN dds.dim_products p ON f.product_id = p.product_id
WHERE f.sale_date BETWEEN DATE '2026-03-01' AND DATE '2026-03-15'
GROUP BY 1, 2;

-- 5. ИТОГОВЫЙ БИЗНЕС-ОТЧЁТ ИЗ ВИТРИНЫ (TOP КАТЕГОРИЙ ПО РЕГИОНАМ)
SELECT 
    region_name,
    category_l1,
    receipts_count,
    net_revenue,
    avg_ticket,
    private_label_share_pct,
    RANK() OVER (PARTITION BY region_name ORDER BY net_revenue DESC) AS rank_in_region
FROM dm.category_regional_performance
WHERE report_month = DATE '2026-03-01'
ORDER BY region_name, rank_in_region;
