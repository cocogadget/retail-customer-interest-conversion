-- ============================================================
-- RETAIL CUSTOMER INTEREST & CONVERSION ANALYSIS
-- Databricks SQL
-- ============================================================

-- 0. DATA INTERROGATION

-- Confirm customer-table grain.
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT customer_id) AS unique_customers
FROM databricks_simulated_retail_customer_data.v01.customers;

-- Confirm fields available for customer, product, purchase, and region.
SELECT
    c.customer_name,
    c.region,
    s.order_date,
    YEAR(s.order_date) AS year,
    s.product_name,
    s.total_price,
    c.units_purchased
FROM databricks_simulated_retail_customer_data.v01.sales AS s
JOIN databricks_simulated_retail_customer_data.v01.customers AS c
    ON s.customer_id = c.customer_id;

-- Inspect semi-structured click data.
SELECT clicked_items
FROM databricks_simulated_retail_customer_data.v01.sales_orders
LIMIT 10;

-- Inspect product data and embedded product IDs.
SELECT
    product_name,
    product,
    get_json_object(product, '$.id') AS product_id
FROM databricks_simulated_retail_customer_data.v01.sales
LIMIT 20;

DESCRIBE databricks_simulated_retail_customer_data.v01.sales_orders;


-- ============================================================
-- 1. PARSE AND EXPLODE CLICKED PRODUCTS
-- clicked_items STRING -> ARRAY<ARRAY<STRING>> -> product_id
-- ============================================================

WITH parsed_clicks AS (
    SELECT
        from_json(clicked_items, 'ARRAY<ARRAY<STRING>>') AS parsed_clicked_items
    FROM databricks_simulated_retail_customer_data.v01.sales_orders
),
exploded_clicks AS (
    SELECT explode(parsed_clicked_items) AS clicked_item
    FROM parsed_clicks
)
SELECT
    clicked_item[0] AS product_id,
    COUNT(*) AS appearance_frequency
FROM exploded_clicks
GROUP BY clicked_item[0]
ORDER BY appearance_frequency DESC;


-- ============================================================
-- 2. CLICKED PRODUCT IDS WITHOUT A SALES-SIDE PRODUCT MATCH
-- Data-coverage/mapping investigation; not an order-level
-- conversion calculation.
-- ============================================================

WITH orders_with_parsed_clicks AS (
    SELECT
        from_json(clicked_items, 'ARRAY<ARRAY<STRING>>') AS parsed_clicked_items
    FROM databricks_simulated_retail_customer_data.v01.sales_orders
),
one_click_pair_per_row AS (
    SELECT explode(parsed_clicked_items) AS clicked_item
    FROM orders_with_parsed_clicks
),
click_product_ids AS (
    SELECT clicked_item[0] AS product_id
    FROM one_click_pair_per_row
),
purchase_product_ids AS (
    SELECT
        product_name,
        get_json_object(product, '$.id') AS product_id
    FROM databricks_simulated_retail_customer_data.v01.sales
)
SELECT
    c.product_id,
    COUNT(*) AS appearance_frequency
FROM click_product_ids AS c
LEFT JOIN purchase_product_ids AS p
    ON c.product_id = p.product_id
WHERE p.product_name IS NULL
GROUP BY c.product_id
ORDER BY appearance_frequency DESC;


-- ============================================================
-- 3. ABANDONED INTEREST BY PRODUCT
--
-- Business question:
-- Which products are clicked within an order but do not appear
-- among the products ultimately ordered in that same order?
--
-- Operational definition:
-- Abandoned interest = clicked within an order but not ordered
-- within that same order.
--
-- Guardrail:
-- A click does not necessarily represent true purchase intent.
-- This is "clicked but not ordered," not confirmed cart abandonment.
-- ============================================================

SELECT ordered_products
FROM databricks_simulated_retail_customer_data.v01.sales_orders
LIMIT 10;

SELECT clicked_items, ordered_products
FROM databricks_simulated_retail_customer_data.v01.sales_orders
WHERE ordered_products IS NULL
LIMIT 10;

WITH clicked_product_ids AS (
    SELECT
        order_number,
        clicked_item[0] AS clicked_product_id
    FROM databricks_simulated_retail_customer_data.v01.sales_orders
    LATERAL VIEW explode(
        from_json(clicked_items, 'ARRAY<ARRAY<STRING>>')
    ) AS clicked_item
),
ordered_product_records AS (
    SELECT
        order_number,
        explode(
            from_json(ordered_products, 'ARRAY<STRUCT<id: STRING>>')
        ) AS ordered_product_record
    FROM databricks_simulated_retail_customer_data.v01.sales_orders
),
ordered_product_ids AS (
    SELECT
        order_number,
        ordered_product_record.id AS ordered_product_id
    FROM ordered_product_records
),
abandoned_interest AS (
    SELECT
        c.clicked_product_id,
        COUNT(DISTINCT c.order_number) AS abandoned_interest_orders
    FROM clicked_product_ids AS c
    LEFT ANTI JOIN ordered_product_ids AS o
        ON c.order_number = o.order_number
       AND c.clicked_product_id = o.ordered_product_id
    GROUP BY c.clicked_product_id
),
product_lookup AS (
    SELECT
        get_json_object(product, '$.id') AS product_id,
        first(product_name, true) AS product_name
    FROM databricks_simulated_retail_customer_data.v01.sales
    WHERE get_json_object(product, '$.id') IS NOT NULL
    GROUP BY get_json_object(product, '$.id')
)
SELECT
    a.clicked_product_id,
    COALESCE(
        p.product_name,
        CONCAT('Unmapped Product ID: ', a.clicked_product_id)
    ) AS product_display,
    a.abandoned_interest_orders
FROM abandoned_interest AS a
LEFT JOIN product_lookup AS p
    ON a.clicked_product_id = p.product_id
ORDER BY a.abandoned_interest_orders DESC
LIMIT 10;


-- ============================================================
-- 4. CLICK-TO-ORDER CONVERSION KPI
-- Grain: one distinct order_number + clicked_product_id pair.
-- ============================================================

WITH clicked_product_ids AS (
    SELECT DISTINCT
        order_number,
        clicked_item[0] AS clicked_product_id
    FROM databricks_simulated_retail_customer_data.v01.sales_orders
    LATERAL VIEW explode(
        from_json(clicked_items, 'ARRAY<ARRAY<STRING>>')
    ) AS clicked_item
),
ordered_product_records AS (
    SELECT
        order_number,
        explode(
            from_json(ordered_products, 'ARRAY<STRUCT<id: STRING>>')
        ) AS ordered_product_record
    FROM databricks_simulated_retail_customer_data.v01.sales_orders
),
ordered_product_ids AS (
    SELECT DISTINCT
        order_number,
        ordered_product_record.id AS ordered_product_id
    FROM ordered_product_records
),
click_outcomes AS (
    SELECT
        c.order_number,
        c.clicked_product_id,
        CASE
            WHEN o.ordered_product_id IS NOT NULL THEN 1
            ELSE 0
        END AS converted_to_order
    FROM clicked_product_ids AS c
    LEFT JOIN ordered_product_ids AS o
        ON c.order_number = o.order_number
       AND c.clicked_product_id = o.ordered_product_id
)
SELECT
    COUNT(*) AS clicked_product_order_pairs,
    SUM(converted_to_order) AS clicked_and_ordered,
    SUM(CASE WHEN converted_to_order = 0 THEN 1 ELSE 0 END) AS clicked_not_ordered,
    ROUND(100.0 * SUM(converted_to_order) / COUNT(*), 2) AS click_to_order_rate_pct
FROM click_outcomes;

-- Validated dashboard results:
-- clicked_product_order_pairs = 15,619
-- clicked_and_ordered          = 7,887
-- clicked_not_ordered          = 7,732
-- click_to_order_rate_pct      = 50.50
--
-- The available data does not establish WHY a product failed to
-- convert. Non-conversion should not automatically be interpreted
-- as lost revenue.


-- ============================================================
-- 5. CONVERSION OUTCOME DATASET FOR DASHBOARD
-- ============================================================

WITH clicked_product_ids AS (
    SELECT DISTINCT
        order_number,
        clicked_item[0] AS clicked_product_id
    FROM databricks_simulated_retail_customer_data.v01.sales_orders
    LATERAL VIEW explode(
        from_json(clicked_items, 'ARRAY<ARRAY<STRING>>')
    ) AS clicked_item
),
ordered_product_records AS (
    SELECT
        order_number,
        explode(
            from_json(ordered_products, 'ARRAY<STRUCT<id: STRING>>')
        ) AS ordered_product_record
    FROM databricks_simulated_retail_customer_data.v01.sales_orders
),
ordered_product_ids AS (
    SELECT DISTINCT
        order_number,
        ordered_product_record.id AS ordered_product_id
    FROM ordered_product_records
),
click_outcomes AS (
    SELECT
        c.order_number,
        c.clicked_product_id,
        CASE
            WHEN o.ordered_product_id IS NOT NULL THEN 'Clicked + Ordered'
            ELSE 'Clicked, Not Ordered'
        END AS conversion_outcome
    FROM clicked_product_ids AS c
    LEFT JOIN ordered_product_ids AS o
        ON c.order_number = o.order_number
       AND c.clicked_product_id = o.ordered_product_id
)
SELECT
    conversion_outcome,
    COUNT(*) AS product_order_pairs
FROM click_outcomes
GROUP BY conversion_outcome
ORDER BY product_order_pairs DESC;

-- Validated dashboard results:
-- Clicked + Ordered    = 7,887
-- Clicked, Not Ordered = 7,732
