-- ============================================
-- 0. 创建并切换至专用数据库
-- ============================================
CREATE DATABASE IF NOT EXISTS olist_analysis;
USE olist_analysis;

-- ============================================
-- 清理旧表（重复执行时防止冲突）
-- ============================================
DROP TABLE IF EXISTS wide_dataset;
DROP TABLE IF EXISTS repeat_rate_overall;
DROP TABLE IF EXISTS retention_cohort;
DROP TABLE IF EXISTS first_order_impact;
DROP TABLE IF EXISTS category_loyalty;

-- ============================================
-- 表1：wide_dataset（宽表，供后续分析使用）
-- ============================================
CREATE TABLE wide_dataset AS
WITH
-- ① 商品级明细拼接
order_items_enriched AS (
    SELECT
        i.ORDER_ID,
        i.PRODUCT_ID,
        i.PRICE,
        i.FREIGHT_VALUE,
        p.PRODUCT_CATEGORY_NAME,
        t.PRODUCT_CATEGORY_NAME_ENGLISH AS CATEGORY_ENGLISH
    FROM olist_order_items_dataset i
    LEFT JOIN olist_products_dataset p ON i.PRODUCT_ID = p.PRODUCT_ID
    LEFT JOIN product_category_name_translation t
        ON p.PRODUCT_CATEGORY_NAME = t.PRODUCT_CATEGORY_NAME
),
-- ② 按订单汇总金额，并取金额最大的品类作为主品类
order_aggregates AS (
    SELECT
        ORDER_ID,
        ROUND(SUM(PRICE), 2) AS total_price,
        ROUND(SUM(FREIGHT_VALUE), 2) AS total_freight,
        ROUND(SUM(PRICE + FREIGHT_VALUE), 2) AS order_total,
        -- 取金额最高的品类（若并列则随机取一个）
        (SELECT CATEGORY_ENGLISH
         FROM order_items_enriched sub
         WHERE sub.ORDER_ID = main.ORDER_ID
         ORDER BY sub.PRICE DESC
         LIMIT 1) AS main_category
    FROM order_items_enriched main
    GROUP BY ORDER_ID
)
-- ③ 关联原订单主表，只保留已送达订单
SELECT
    m.*,
    oa.total_price,
    oa.total_freight,
    oa.order_total,
    oa.main_category
FROM olist_orders_procession m
LEFT JOIN order_aggregates oa ON m.ORDER_ID = oa.ORDER_ID
WHERE m.ORDER_STATUS = 'delivered';

-- ============================================
-- 表2：整体复购率
-- ============================================
CREATE TABLE repeat_rate_overall AS
WITH customer_order_counts AS (
    SELECT
        CUSTOMER_UNIQUE_ID,
        COUNT(DISTINCT ORDER_ID) AS order_count
    FROM olist_orders_procession
    WHERE ORDER_STATUS = 'delivered'
    GROUP BY CUSTOMER_UNIQUE_ID
)
SELECT
    COUNT(*) AS total_customers,
    SUM(CASE WHEN order_count >= 2 THEN 1 ELSE 0 END) AS repeat_customers,
    ROUND(
        100.0 * SUM(CASE WHEN order_count >= 2 THEN 1 ELSE 0 END) / COUNT(*),
        2
    ) AS repeat_rate_percent
FROM customer_order_counts;

-- ============================================
-- 表3：同期群留存分析
-- ============================================
CREATE TABLE retention_cohort AS
WITH customer_orders AS (
    SELECT
        CUSTOMER_UNIQUE_ID,
        ORDER_ID,
        ORDER_PURCHASE_TIMESTAMP
    FROM olist_orders_procession
    WHERE ORDER_STATUS = 'delivered'
),
customer_first_order AS (
    SELECT
        CUSTOMER_UNIQUE_ID,
        DATE_FORMAT(MIN(ORDER_PURCHASE_TIMESTAMP), '%Y-%m-01') AS first_month
    FROM customer_orders
    GROUP BY CUSTOMER_UNIQUE_ID
),
order_cohort AS (
    SELECT
        co.CUSTOMER_UNIQUE_ID,
        DATE_FORMAT(co.ORDER_PURCHASE_TIMESTAMP, '%Y-%m-01') AS order_month,
        cf.first_month,
        TIMESTAMPDIFF(MONTH, cf.first_month, DATE_FORMAT(co.ORDER_PURCHASE_TIMESTAMP, '%Y-%m-01')) AS month_diff
    FROM customer_orders co
    JOIN customer_first_order cf ON co.CUSTOMER_UNIQUE_ID = cf.CUSTOMER_UNIQUE_ID
),
cohort_size AS (
    SELECT first_month, COUNT(DISTINCT CUSTOMER_UNIQUE_ID) AS cohort_count
    FROM customer_first_order
    GROUP BY first_month
)
SELECT
    oc.first_month,
    oc.month_diff,
    COUNT(DISTINCT oc.CUSTOMER_UNIQUE_ID) AS customers,
    cs.cohort_count,
    ROUND(
        100.0 * COUNT(DISTINCT oc.CUSTOMER_UNIQUE_ID) / cs.cohort_count,
        2
    ) AS retention_rate
FROM order_cohort oc
JOIN cohort_size cs ON oc.first_month = cs.first_month
GROUP BY oc.first_month, oc.month_diff, cs.cohort_count
ORDER BY oc.first_month, oc.month_diff;

-- ============================================
-- 表4：配送是否影响复购（首单体验）
-- ============================================
CREATE TABLE first_order_impact AS
WITH customer_first_order AS (
    SELECT
        CUSTOMER_UNIQUE_ID,
        ORDER_ID,
        ORDER_PURCHASE_TIMESTAMP,
        是否延迟,
        ROW_NUMBER() OVER (
            PARTITION BY CUSTOMER_UNIQUE_ID
            ORDER BY ORDER_PURCHASE_TIMESTAMP
        ) AS order_rank
    FROM olist_orders_procession
    WHERE ORDER_STATUS = 'delivered'
      AND 是否延迟 IS NOT NULL
),
first_order_only AS (
    SELECT
        CUSTOMER_UNIQUE_ID,
        是否延迟 AS first_order_late
    FROM customer_first_order
    WHERE order_rank = 1
),
customer_total_orders AS (
    SELECT
        CUSTOMER_UNIQUE_ID,
        COUNT(DISTINCT ORDER_ID) AS total_orders
    FROM olist_orders_procession
    WHERE ORDER_STATUS = 'delivered'
    GROUP BY CUSTOMER_UNIQUE_ID
)
SELECT
    CASE
        WHEN f.first_order_late = '准时' THEN '首单准时'
        WHEN f.first_order_late = '延迟' THEN '首单延迟'
        ELSE '未知'
    END AS first_order_experience,
    COUNT(DISTINCT f.CUSTOMER_UNIQUE_ID) AS customer_count,
    ROUND(AVG(t.total_orders), 2) AS avg_orders_per_customer,
    ROUND(
        100.0 * SUM(CASE WHEN t.total_orders >= 2 THEN 1 ELSE 0 END) / COUNT(DISTINCT f.CUSTOMER_UNIQUE_ID),
        2
    ) AS repeat_rate_percent
FROM first_order_only f
LEFT JOIN customer_total_orders t ON f.CUSTOMER_UNIQUE_ID = t.CUSTOMER_UNIQUE_ID
GROUP BY first_order_late
ORDER BY repeat_rate_percent DESC;

-- ============================================
-- 表5：品类复购率排名 + 忠诚度分类
-- ============================================
CREATE TABLE category_loyalty AS
WITH category_customer AS (
    SELECT
        main_category AS CATEGORY_ENGLISH,
        CUSTOMER_UNIQUE_ID,
        COUNT(DISTINCT ORDER_ID) AS order_count
    FROM wide_dataset
    WHERE main_category IS NOT NULL AND main_category != ''
    GROUP BY main_category, CUSTOMER_UNIQUE_ID
),
category_stats AS (
    SELECT
        CATEGORY_ENGLISH,
        COUNT(*) AS total_customers,
        SUM(CASE WHEN order_count >= 2 THEN 1 ELSE 0 END) AS repeat_customers,
        ROUND(
            100.0 * SUM(CASE WHEN order_count >= 2 THEN 1 ELSE 0 END) / COUNT(*),
            2
        ) AS repeat_rate_percent
    FROM category_customer
    GROUP BY CATEGORY_ENGLISH
)
SELECT
    CATEGORY_ENGLISH,
    total_customers,
    repeat_customers,
    repeat_rate_percent,
    CASE
        WHEN repeat_rate_percent >= 8 THEN '高忠诚品类'
        WHEN repeat_rate_percent >= 5 THEN '中忠诚品类'
        WHEN repeat_rate_percent >= 2 THEN '低忠诚品类'
        ELSE '流失品类'
    END AS loyalty_level
FROM category_stats
WHERE total_customers >= 20
ORDER BY repeat_rate_percent DESC
LIMIT 20;
