-- ============================================================================
-- ADVANCED ANALYTICAL QUERIES: INVENTORY OPTIMIZATION & WASTE MITIGATION
-- Author: Odar Javier Alcocer Vásquez (UPC)
-- Focus: CTEs, Window Functions, Date Intelligence, Shrinkage Auditing
-- ============================================================================

-- ----------------------------------------------------------------------------
-- QUERY 1: FEFO EXPIRATION RISK MATRIX & FINANCIAL EXPOSURE ($)
-- Business Goal: Identify active batches expiring in <= 5 days to trigger 
-- dynamic markdowns or clearance promotions before turning into 100% loss.
-- ----------------------------------------------------------------------------
WITH active_batches_summary AS (
    SELECT 
        b.batch_id,
        b.batch_code,
        s.store_code,
        s.store_name,
        p.sku_code,
        p.product_name,
        c.category_name,
        b.current_qty,
        p.unit_cost,
        p.retail_price,
        b.expiration_date,
        (b.expiration_date - CURRENT_DATE) AS days_until_expiration,
        ROUND((b.current_qty * p.unit_cost)::NUMERIC, 2) AS total_financial_exposure_cost,
        ROUND((b.current_qty * p.retail_price)::NUMERIC, 2) AS potential_retail_revenue
    FROM inventory_batches b
    INNER JOIN products p ON b.product_id = p.product_id
    INNER JOIN product_categories c ON p.category_id = c.category_id
    INNER JOIN stores s ON b.store_id = s.store_id
    WHERE b.batch_status = 'ACTIVE' 
      AND b.current_qty > 0
)
SELECT 
    store_code,
    product_name,
    category_name,
    batch_code,
    current_qty,
    days_until_expiration,
    CASE 
        WHEN days_until_expiration < 0 THEN 'CRITICAL: ALREADY EXPIRED (LOG IMMEDIATE WASTE)'
        WHEN days_until_expiration <= 2 THEN 'HIGH ALERT: EXPIRING IN <= 48H (50% MARKDOWN)'
        WHEN days_until_expiration <= 5 THEN 'MEDIUM ALERT: EXPIRING THIS WEEK (20% PROMO)'
        ELSE 'NORMAL: HEALTHY SHELF LIFE'
    END AS operational_action_plan,
    total_financial_exposure_cost,
    potential_retail_revenue,
    -- Window function: Expiration priority ranking within store and category
    DENSE_RANK() OVER (
        PARTITION BY store_code, category_name 
        ORDER BY days_until_expiration ASC
    ) AS priority_rotation_rank
FROM active_batches_summary
ORDER BY days_until_expiration ASC, total_financial_exposure_cost DESC;


-- ----------------------------------------------------------------------------
-- QUERY 2: GOODS RECEIPT NOTE (GRN) vs. DISPATCH DISCREPANCY AUDIT
-- Business Goal: Detect supplier delivery shrinkage and damaged goods received 
-- at store level to prevent invoice overpayment and supplier compliance breaches.
-- ----------------------------------------------------------------------------
WITH grn_item_discrepancies AS (
    SELECT 
        h.grn_number,
        h.dispatch_guide_ref AS guia_remision,
        sup.company_name AS proveedor,
        s.store_name AS tienda_destino,
        h.received_timestamp::DATE AS fecha_recepcion,
        p.sku_code,
        p.product_name,
        i.qty_dispatched,
        i.qty_accepted,
        i.discrepancy_qty,
        i.unit_purchase_cost,
        ROUND((i.discrepancy_qty * i.unit_purchase_cost)::NUMERIC, 2) AS discrepancy_loss_amount
    FROM goods_receipt_items i
    INNER JOIN goods_receipt_headers h ON i.grn_id = h.grn_id
    INNER JOIN suppliers sup ON h.supplier_id = sup.supplier_id
    INNER JOIN stores s ON h.store_id = s.store_id
    INNER JOIN products p ON i.product_id = p.product_id
)
SELECT 
    proveedor,
    COUNT(DISTINCT grn_number) AS total_recepciones_auditadas,
    SUM(qty_dispatched) AS total_unidades_despachadas,
    SUM(qty_accepted) AS total_unidades_ingresadas_conforme,
    SUM(discrepancy_qty) AS total_unidades_faltantes_o_danadas,
    ROUND(SUM(discrepancy_loss_amount)::NUMERIC, 2) AS impacto_monetario_discrepancias_pen,
    -- Supplier Reliability Fulfillment Rate
    ROUND((SUM(qty_accepted) / NULLIF(SUM(qty_dispatched), 0) * 100)::NUMERIC, 2) AS fill_rate_conforme_pct
FROM grn_item_discrepancies
GROUP BY proveedor
ORDER BY impacto_monetario_discrepancias_pen DESC;


-- ----------------------------------------------------------------------------
-- QUERY 3: WASTE INTENSITY RATIO (% LOSS OVER SALES) BY STORE & CATEGORY
-- Business Goal: Measure operational efficiency by calculating the waste-to-sales 
-- ratio and ranking stores by loss mitigation performance using Window Functions.
-- ----------------------------------------------------------------------------
WITH store_waste_metrics AS (
    SELECT 
        w.store_id,
        p.category_id,
        SUM(w.total_loss_amount) AS total_waste_amount
    FROM waste_log w
    INNER JOIN products p ON w.product_id = p.product_id
    GROUP BY w.store_id, p.category_id
),
store_sales_metrics AS (
    SELECT 
        s.store_id,
        p.category_id,
        SUM(s.gross_revenue) AS total_gross_sales,
        SUM(s.cost_of_goods_sold) AS total_cogs
    FROM daily_sales s
    INNER JOIN products p ON s.product_id = p.product_id
    GROUP BY s.store_id, p.category_id
)
SELECT 
    st.store_code,
    st.store_name,
    cat.category_name,
    COALESCE(sm.total_gross_sales, 0) AS ventas_brutas_pen,
    COALESCE(wm.total_waste_amount, 0) AS merma_total_pen,
    -- Waste to Sales Intensity Ratio
    ROUND(
        (COALESCE(wm.total_waste_amount, 0) / NULLIF(sm.total_gross_sales, 0) * 100)::NUMERIC, 
        2
    ) AS tasa_merma_sobre_ventas_pct,
    -- Category waste percentage relative to the store total
    ROUND(
        (COALESCE(wm.total_waste_amount, 0) / 
         NULLIF(SUM(COALESCE(wm.total_waste_amount, 0)) OVER (PARTITION BY st.store_id), 0) * 100)::NUMERIC,
        2
    ) AS participacion_categoria_en_merma_tienda_pct
FROM stores st
CROSS JOIN product_categories cat
LEFT JOIN store_waste_metrics wm ON st.store_id = wm.store_id AND cat.category_id = wm.category_id
LEFT JOIN store_sales_metrics sm ON st.store_id = sm.store_id AND cat.category_id = sm.category_id
WHERE COALESCE(sm.total_gross_sales, 0) > 0 OR COALESCE(wm.total_waste_amount, 0) > 0
ORDER BY tasa_merma_sobre_ventas_pct DESC;


-- ----------------------------------------------------------------------------
-- QUERY 4: DAYS SALES OF INVENTORY (DSI) & STOCKOUT RISK VELOCITY
-- Business Goal: Compare current stock levels against moving average sales 
-- velocity to detect overstock (spoilage hazard) and understock (stockout hazard).
-- ----------------------------------------------------------------------------
WITH current_active_stock AS (
    SELECT 
        store_id,
        product_id,
        SUM(current_qty) AS stock_on_hand
    FROM inventory_batches
    WHERE batch_status = 'ACTIVE'
    GROUP BY store_id, product_id
),
sales_velocity AS (
    SELECT 
        store_id,
        product_id,
        ROUND(AVG(units_sold)::NUMERIC, 2) AS avg_daily_sales_velocity
    FROM daily_sales
    WHERE sale_date >= CURRENT_DATE - INTERVAL '14 days'
    GROUP BY store_id, product_id
)
SELECT 
    st.store_code,
    p.sku_code,
    p.product_name,
    p.min_safety_stock,
    p.reorder_point,
    COALESCE(cs.stock_on_hand, 0) AS stock_actual_unidades,
    COALESCE(sv.avg_daily_sales_velocity, 0) AS venta_promedio_diaria,
    -- Days of Sales Inventory (DSI)
    CASE 
        WHEN COALESCE(sv.avg_daily_sales_velocity, 0) = 0 THEN 999.00 -- Sin rotación reciente
        ELSE ROUND((COALESCE(cs.stock_on_hand, 0) / sv.avg_daily_sales_velocity)::NUMERIC, 1)
    END AS dias_inventario_disponible,
    -- Stock Health Classification
    CASE 
        WHEN COALESCE(cs.stock_on_hand, 0) <= p.min_safety_stock THEN 'CRITICAL: STOCKOUT DANGER (ORDER NOW)'
        WHEN COALESCE(cs.stock_on_hand, 0) <= p.reorder_point THEN 'REORDER TRIGGER REACHED'
        WHEN (COALESCE(cs.stock_on_hand, 0) / NULLIF(sv.avg_daily_sales_velocity, 0)) > 30 THEN 'OVERSTOCK WARNING (SPOILAGE RISK)'
        ELSE 'BALANCED INVENTORY'
    END AS stock_health_status
FROM products p
CROSS JOIN stores st
LEFT JOIN current_active_stock cs ON p.product_id = cs.product_id AND st.store_id = cs.store_id
LEFT JOIN sales_velocity sv ON p.product_id = sv.product_id AND st.store_id = sv.store_id
WHERE p.is_active = TRUE
ORDER BY dias_inventario_disponible ASC;
