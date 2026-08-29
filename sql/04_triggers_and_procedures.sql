-- ============================================================================
-- STORED PROCEDURES, TRIGGERS & MATERIALIZED VIEWS
-- Author: Odar Javier Alcocer Vásquez (Information Systems Engineering - UPC)
-- Engine: PostgreSQL 15+
-- Purpose: Transactional business logic layer on top of the 3NF schema:
--            (1) FEFO/FIFO batch consumption procedure
--            (2) Anti-fraud control trigger over waste declarations
--            (3) Pre-aggregated monthly waste datamart for Power BI
-- Dependencies: sql/01_schema_ddl_3nf.sql must be executed first.
-- ============================================================================

-- Idempotent teardown so the script can be re-applied safely in CI / Docker init.
DROP MATERIALIZED VIEW IF EXISTS mv_store_category_waste_summary CASCADE;
DROP TRIGGER  IF EXISTS trg_audit_high_waste_alert ON waste_log;
DROP FUNCTION IF EXISTS fn_audit_high_waste_alert() CASCADE;
DROP PROCEDURE IF EXISTS sp_process_fefo_sale(INTEGER, INTEGER, NUMERIC, DATE, VARCHAR, BOOLEAN);
DROP PROCEDURE IF EXISTS sp_expire_overdue_batches(DATE, VARCHAR);
DROP FUNCTION IF EXISTS fn_refresh_waste_datamart(BOOLEAN) CASCADE;

-- ============================================================================
-- SECTION 1: FEFO / FIFO SALE PROCESSING PROCEDURE
-- ============================================================================
-- Business rule: perishable retail inventory must always be depleted following
-- FEFO (First-Expired, First-Out). The procedure walks the ACTIVE batches of a
-- (store, product) pair ordered by expiration_date ASC and consumes them lot by
-- lot until the sold quantity is fully served.
--
-- Concurrency: rows are locked with FOR UPDATE so two concurrent POS terminals
-- cannot oversell the same batch (prevents negative stock race conditions).
--
-- Atomicity: the body runs inside the caller transaction. Any RAISE EXCEPTION
-- rolls back every partial batch decrement already applied.
-- ============================================================================
CREATE OR REPLACE PROCEDURE sp_process_fefo_sale(
    p_store_id       INTEGER,
    p_product_id     INTEGER,
    p_qty_sold       NUMERIC(10, 2),
    p_sale_date      DATE    DEFAULT CURRENT_DATE,
    p_pos_user       VARCHAR DEFAULT 'POS_TERMINAL',
    p_register_sale  BOOLEAN DEFAULT TRUE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_remaining_qty    NUMERIC(10, 2) := p_qty_sold;
    v_available_qty    NUMERIC(10, 2);
    v_taken_qty        NUMERIC(10, 2);
    v_batches_touched  INTEGER := 0;
    v_batches_depleted INTEGER := 0;
    v_cogs             NUMERIC(14, 4) := 0;
    v_retail_price     NUMERIC(10, 2);
    v_product_name     VARCHAR(150);
    v_store_code       VARCHAR(20);
    v_batch            RECORD;
BEGIN
    -- ----------------------------------------------------------------------
    -- 1.1 Input validation (fail fast, before touching any row)
    -- ----------------------------------------------------------------------
    IF p_qty_sold IS NULL OR p_qty_sold <= 0 THEN
        RAISE EXCEPTION
            'Invalid Sale Quantity: p_qty_sold must be strictly positive (received: %).', p_qty_sold
            USING ERRCODE = '22023',
                  HINT    = 'Pass a positive NUMERIC quantity of units sold.';
    END IF;

    SELECT s.store_code INTO v_store_code
      FROM stores s
     WHERE s.store_id = p_store_id AND s.is_active;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown or inactive store_id=%.', p_store_id
            USING ERRCODE = '23503';
    END IF;

    SELECT p.product_name, p.retail_price INTO v_product_name, v_retail_price
      FROM products p
     WHERE p.product_id = p_product_id AND p.is_active;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown or inactive product_id=%.', p_product_id
            USING ERRCODE = '23503';
    END IF;

    -- ----------------------------------------------------------------------
    -- 1.2 Stockout guard: verify global availability BEFORE consuming lots.
    --     Already-expired lots are excluded on purpose: legally unsellable.
    -- ----------------------------------------------------------------------
    SELECT COALESCE(SUM(b.current_qty), 0) INTO v_available_qty
      FROM inventory_batches b
     WHERE b.store_id        = p_store_id
       AND b.product_id      = p_product_id
       AND b.batch_status    = 'ACTIVE'
       AND b.expiration_date >= p_sale_date;

    IF v_available_qty < p_qty_sold THEN
        RAISE EXCEPTION
            'Stockout / Insufficient Inventory -> store % (id=%), SKU "%" (id=%): requested % units but only % sellable units remain in ACTIVE batches.',
            v_store_code, p_store_id, v_product_name, p_product_id, p_qty_sold, v_available_qty
            USING ERRCODE = 'P0002',
                  HINT    = 'Trigger an emergency replenishment order or an inter-store transfer before re-running the sale.',
                  DETAIL  = 'FEFO consumption aborted; no batch was modified (transaction rolled back).';
    END IF;

    -- ----------------------------------------------------------------------
    -- 1.3 FEFO consumption loop (strictly ordered by nearest expiration).
    --     batch_id is the deterministic tie-breaker => FIFO within same date.
    -- ----------------------------------------------------------------------
    FOR v_batch IN
        SELECT b.batch_id,
               b.batch_code,
               b.current_qty,
               b.expiration_date,
               COALESCE(gi.unit_purchase_cost, pr.unit_cost) AS effective_unit_cost
          FROM inventory_batches b
          JOIN products pr                 ON pr.product_id  = b.product_id
          LEFT JOIN goods_receipt_items gi  ON gi.grn_item_id = b.grn_item_id
         WHERE b.store_id        = p_store_id
           AND b.product_id      = p_product_id
           AND b.batch_status    = 'ACTIVE'
           AND b.current_qty     > 0
           AND b.expiration_date >= p_sale_date
         ORDER BY b.expiration_date ASC, b.batch_id ASC
           FOR UPDATE OF b
    LOOP
        EXIT WHEN v_remaining_qty <= 0;

        -- Consume as much as this lot can serve.
        v_taken_qty := LEAST(v_batch.current_qty, v_remaining_qty);

        UPDATE inventory_batches
           SET current_qty  = current_qty - v_taken_qty,
               -- Auto-transition to DEPLETED the moment the lot hits zero.
               batch_status = CASE
                                  WHEN current_qty - v_taken_qty = 0 THEN 'DEPLETED'
                                  ELSE batch_status
                              END
         WHERE batch_id = v_batch.batch_id;

        v_remaining_qty   := v_remaining_qty - v_taken_qty;
        v_cogs            := v_cogs + (v_taken_qty * v_batch.effective_unit_cost);
        v_batches_touched := v_batches_touched + 1;

        IF v_batch.current_qty - v_taken_qty = 0 THEN
            v_batches_depleted := v_batches_depleted + 1;
            RAISE NOTICE 'FEFO: batch % (exp. %) fully consumed -> status DEPLETED.',
                v_batch.batch_code, v_batch.expiration_date;
        ELSE
            RAISE NOTICE 'FEFO: batch % (exp. %) partially consumed: % units taken, % remaining.',
                v_batch.batch_code, v_batch.expiration_date, v_taken_qty,
                v_batch.current_qty - v_taken_qty;
        END IF;
    END LOOP;

    -- ----------------------------------------------------------------------
    -- 1.4 Defensive post-condition. Only reachable if a concurrent session
    --     depleted stock between the guard and the locking loop.
    -- ----------------------------------------------------------------------
    IF v_remaining_qty > 0 THEN
        RAISE EXCEPTION
            'Stockout / Insufficient Inventory -> concurrent depletion detected for store %, SKU "%": % units could not be served.',
            v_store_code, v_product_name, v_remaining_qty
            USING ERRCODE = 'P0002',
                  DETAIL  = 'Availability changed between the pre-check and the FEFO loop; transaction rolled back.';
    END IF;

    -- ----------------------------------------------------------------------
    -- 1.5 Post the movement to the POS aggregation table (idempotent upsert).
    --     COGS is the real weighted cost of the specific lots consumed, not a
    --     catalog average: that is what makes margin reporting trustworthy.
    -- ----------------------------------------------------------------------
    IF p_register_sale THEN
        INSERT INTO daily_sales (store_id, product_id, sale_date, units_sold,
                                 gross_revenue, cost_of_goods_sold)
        VALUES (p_store_id, p_product_id, p_sale_date, p_qty_sold,
                ROUND(p_qty_sold * v_retail_price, 2), ROUND(v_cogs, 2))
        ON CONFLICT (store_id, product_id, sale_date) DO UPDATE
           SET units_sold         = daily_sales.units_sold         + EXCLUDED.units_sold,
               gross_revenue      = daily_sales.gross_revenue      + EXCLUDED.gross_revenue,
               cost_of_goods_sold = daily_sales.cost_of_goods_sold + EXCLUDED.cost_of_goods_sold;
    END IF;

    RAISE NOTICE
        'FEFO SALE OK | store=% | sku="%" | units=% | lots_used=% | lots_depleted=% | COGS=S/ % | margin=S/ % | by=%',
        v_store_code, v_product_name, p_qty_sold, v_batches_touched, v_batches_depleted,
        ROUND(v_cogs, 2), ROUND((p_qty_sold * v_retail_price) - v_cogs, 2), p_pos_user;
END;
$$;

COMMENT ON PROCEDURE sp_process_fefo_sale(INTEGER, INTEGER, NUMERIC, DATE, VARCHAR, BOOLEAN) IS
'Consumes inventory_batches under strict FEFO (First-Expired, First-Out) rotation, auto-flags depleted lots as DEPLETED, upserts the movement into daily_sales with true lot-level COGS, and raises a Stockout exception (SQLSTATE P0002) when sellable stock is insufficient.';


-- ============================================================================
-- SECTION 2: HOUSEKEEPING PROCEDURE -- EXPIRE OVERDUE BATCHES
-- ============================================================================
-- Nightly job: any ACTIVE lot past its expiration_date is legally unsellable.
-- It is flipped to EXPIRED and its residual stock is written off to waste_log
-- under the EXPIRATION classification -- exactly the loss that strict FEFO
-- rotation exists to minimise.
-- ============================================================================
CREATE OR REPLACE PROCEDURE sp_expire_overdue_batches(
    p_as_of_date   DATE    DEFAULT CURRENT_DATE,
    p_authorizer   VARCHAR DEFAULT 'SYSTEM_NIGHTLY_JOB'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_reason_id   INTEGER;
    v_written_off INTEGER := 0;
    v_total_loss  NUMERIC(14, 2) := 0;
    v_batch       RECORD;
BEGIN
    SELECT waste_reason_id INTO v_reason_id
      FROM waste_reasons
     WHERE loss_classification = 'EXPIRATION'
     ORDER BY waste_reason_id
     LIMIT 1;

    IF v_reason_id IS NULL THEN
        RAISE EXCEPTION 'Configuration error: no waste_reasons row classified as EXPIRATION.'
            USING ERRCODE = 'P0003';
    END IF;

    FOR v_batch IN
        SELECT b.batch_id, b.batch_code, b.store_id, b.product_id, b.current_qty,
               COALESCE(gi.unit_purchase_cost, pr.unit_cost) AS effective_unit_cost
          FROM inventory_batches b
          JOIN products pr                 ON pr.product_id  = b.product_id
          LEFT JOIN goods_receipt_items gi  ON gi.grn_item_id = b.grn_item_id
         WHERE b.batch_status    = 'ACTIVE'
           AND b.expiration_date < p_as_of_date
         ORDER BY b.batch_id
           FOR UPDATE OF b
    LOOP
        IF v_batch.current_qty > 0 THEN
            INSERT INTO waste_log (waste_code, store_id, product_id, batch_id,
                                   waste_reason_id, qty_discarded, unit_cost_at_loss,
                                   logged_timestamp, logged_by_user, authorized_by, notes)
            VALUES (
                'WASTE-EXP-' || v_batch.batch_id || '-' || TO_CHAR(p_as_of_date, 'YYYYMMDD'),
                v_batch.store_id, v_batch.product_id, v_batch.batch_id,
                v_reason_id, v_batch.current_qty, v_batch.effective_unit_cost,
                p_as_of_date::TIMESTAMPTZ, 'SYSTEM', p_authorizer,
                'Automatic write-off: batch ' || v_batch.batch_code || ' expired before rotation.'
            )
            ON CONFLICT (waste_code) DO NOTHING;

            v_total_loss := v_total_loss + (v_batch.current_qty * v_batch.effective_unit_cost);
        END IF;

        UPDATE inventory_batches
           SET batch_status = 'EXPIRED',
               current_qty  = 0
         WHERE batch_id = v_batch.batch_id;

        v_written_off := v_written_off + 1;
    END LOOP;

    RAISE NOTICE 'EXPIRY SWEEP (as of %): % batches flagged EXPIRED | written-off value S/ %',
        p_as_of_date, v_written_off, ROUND(v_total_loss, 2);
END;
$$;

COMMENT ON PROCEDURE sp_expire_overdue_batches(DATE, VARCHAR) IS
'Nightly housekeeping: flags past-expiration ACTIVE batches as EXPIRED and writes their residual stock off to waste_log under the EXPIRATION classification.';


-- ============================================================================
-- SECTION 3: ANTI-FRAUD TRIGGER OVER WASTE DECLARATIONS
-- ============================================================================
-- Control objective (SOX-style segregation of duties): a store operator must
-- never be able to declare a high-value shrinkage on their own. Any waste
-- declaration above the materiality threshold requires a named authorizer
-- (supervisor / zonal manager) distinct from the operator who logged it.
--
-- IMPLEMENTATION NOTE: waste_log.total_loss_amount is a GENERATED column, and
-- PostgreSQL evaluates generated columns AFTER BEFORE-row triggers -- so
-- NEW.total_loss_amount is still NULL at this point. The amount is therefore
-- recomputed here from its base columns. This is intentional, not redundant.
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_audit_high_waste_alert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    -- Materiality threshold for mandatory dual authorization (PEN).
    c_threshold_amount CONSTANT NUMERIC(12, 2) := 50.00;
    v_loss_amount      NUMERIC(14, 2);
    v_batch_initial    NUMERIC(10, 2);
BEGIN
    v_loss_amount := ROUND(NEW.qty_discarded * NEW.unit_cost_at_loss, 2);

    -- Control 1: a high-value loss without a named authorizer is rejected.
    IF v_loss_amount > c_threshold_amount
       AND (NEW.authorized_by IS NULL OR BTRIM(NEW.authorized_by) = '') THEN
        RAISE EXCEPTION
            'WASTE AUTHORIZATION REQUIRED: declared loss of S/ % exceeds the S/ % materiality threshold and cannot be posted without a named authorizer (waste_code=%, logged_by=%).',
            v_loss_amount, c_threshold_amount, NEW.waste_code, NEW.logged_by_user
            USING ERRCODE = 'P0004',
                  HINT    = 'Populate waste_log.authorized_by with the supervisor validating the physical discard.',
                  DETAIL  = 'Anti-fraud control: segregation of duties over high-value shrinkage declarations.';
    END IF;

    -- Control 2: segregation of duties -- the operator cannot self-authorize.
    IF v_loss_amount > c_threshold_amount
       AND LOWER(BTRIM(NEW.authorized_by)) = LOWER(BTRIM(NEW.logged_by_user)) THEN
        RAISE EXCEPTION
            'SEGREGATION OF DUTIES VIOLATION: user "%" cannot authorize their own high-value waste declaration of S/ % (waste_code=%).',
            NEW.logged_by_user, v_loss_amount, NEW.waste_code
            USING ERRCODE = 'P0004',
                  HINT    = 'A second, distinct user must authorize losses above the materiality threshold.';
    END IF;

    -- Control 3: a write-off can never exceed the stock the batch ever held.
    IF NEW.batch_id IS NOT NULL THEN
        SELECT b.initial_qty INTO v_batch_initial
          FROM inventory_batches b
         WHERE b.batch_id = NEW.batch_id;

        IF v_batch_initial IS NOT NULL AND NEW.qty_discarded > v_batch_initial THEN
            RAISE EXCEPTION
                'INVALID WASTE QUANTITY: % units declared for batch_id=% exceeds the % units ever received in that batch.',
                NEW.qty_discarded, NEW.batch_id, v_batch_initial
                USING ERRCODE = 'P0004',
                      HINT    = 'Split the declaration across the batches that physically held the stock.';
        END IF;
    END IF;

    -- Control 4: non-blocking observability for material-but-authorized losses.
    IF v_loss_amount > c_threshold_amount THEN
        RAISE NOTICE
            'HIGH-WASTE ALERT [authorized]: S/ % written off at store % | waste_code=% | logged_by=% | authorized_by=%',
            v_loss_amount, NEW.store_id, NEW.waste_code, NEW.logged_by_user, NEW.authorized_by;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_high_waste_alert
    BEFORE INSERT OR UPDATE OF qty_discarded, unit_cost_at_loss, authorized_by
    ON waste_log
    FOR EACH ROW
    EXECUTE FUNCTION fn_audit_high_waste_alert();

COMMENT ON FUNCTION fn_audit_high_waste_alert() IS
'Anti-fraud control over waste_log: blocks any declaration above the S/ 50.00 materiality threshold that lacks a named authorizer or is self-authorized by the logging operator, and rejects quantities larger than the batch ever held.';


-- ============================================================================
-- SECTION 4: MATERIALIZED VIEW -- MONTHLY WASTE DATAMART FOR POWER BI
-- ============================================================================
-- Pre-aggregates the expensive waste-vs-sales join into a single flat grain
-- (store x category x month) so Power BI / Metabase dashboards hit a small
-- indexed relation instead of scanning the transactional tables.
-- ============================================================================
CREATE MATERIALIZED VIEW mv_store_category_waste_summary AS
WITH calendar_grain AS (
    -- Every (store, category, month) combination that saw either waste or sales.
    SELECT DISTINCT store_id, category_id, month_start
      FROM (
            SELECT w.store_id,
                   p.category_id,
                   DATE_TRUNC('month', w.logged_timestamp)::DATE AS month_start
              FROM waste_log w
              JOIN products p ON p.product_id = w.product_id
            UNION ALL
            SELECT ds.store_id,
                   p.category_id,
                   DATE_TRUNC('month', ds.sale_date)::DATE AS month_start
              FROM daily_sales ds
              JOIN products p ON p.product_id = ds.product_id
           ) AS grain
),
waste_metrics AS (
    SELECT w.store_id,
           p.category_id,
           DATE_TRUNC('month', w.logged_timestamp)::DATE AS month_start,
           COUNT(*)                                      AS waste_events,
           SUM(w.qty_discarded)                          AS units_discarded,
           SUM(w.total_loss_amount)                      AS total_waste_cost,
           SUM(CASE WHEN wr.loss_classification = 'EXPIRATION'      THEN w.total_loss_amount ELSE 0 END) AS loss_expiration,
           SUM(CASE WHEN wr.loss_classification = 'DAMAGE'          THEN w.total_loss_amount ELSE 0 END) AS loss_damage,
           SUM(CASE WHEN wr.loss_classification = 'COLD_CHAIN_FAIL' THEN w.total_loss_amount ELSE 0 END) AS loss_cold_chain,
           SUM(CASE WHEN wr.loss_classification = 'THEFT_SHRINKAGE' THEN w.total_loss_amount ELSE 0 END) AS loss_shrinkage,
           COUNT(*) FILTER (WHERE w.authorized_by IS NULL)                                              AS unauthorized_events
      FROM waste_log w
      JOIN products      p  ON p.product_id       = w.product_id
      JOIN waste_reasons wr ON wr.waste_reason_id = w.waste_reason_id
     GROUP BY 1, 2, 3
),
sales_metrics AS (
    SELECT ds.store_id,
           p.category_id,
           DATE_TRUNC('month', ds.sale_date)::DATE AS month_start,
           SUM(ds.units_sold)                      AS units_sold,
           SUM(ds.gross_revenue)                   AS gross_revenue,
           SUM(ds.cost_of_goods_sold)              AS cost_of_goods_sold
      FROM daily_sales ds
      JOIN products p ON p.product_id = ds.product_id
     GROUP BY 1, 2, 3
)
SELECT
    g.month_start,
    TO_CHAR(g.month_start, 'YYYY-MM')                                  AS period_label,
    g.store_id,
    s.store_code,
    s.store_name,
    s.district,
    s.store_format,
    g.category_id,
    c.category_name,
    c.storage_temp_type,
    COALESCE(sm.units_sold, 0)                                         AS units_sold,
    COALESCE(sm.gross_revenue, 0)                                      AS gross_revenue,
    COALESCE(sm.cost_of_goods_sold, 0)                                 AS cost_of_goods_sold,
    COALESCE(sm.gross_revenue, 0) - COALESCE(sm.cost_of_goods_sold, 0) AS gross_margin,
    COALESCE(wm.waste_events, 0)                                       AS waste_events,
    COALESCE(wm.units_discarded, 0)                                    AS units_discarded,
    COALESCE(wm.total_waste_cost, 0)                                   AS total_waste_cost,
    COALESCE(wm.loss_expiration, 0)                                    AS loss_expiration,
    COALESCE(wm.loss_damage, 0)                                        AS loss_damage,
    COALESCE(wm.loss_cold_chain, 0)                                    AS loss_cold_chain,
    COALESCE(wm.loss_shrinkage, 0)                                     AS loss_shrinkage,
    COALESCE(wm.unauthorized_events, 0)                                AS unauthorized_events,
    -- Waste Intensity %: monetary loss as a share of gross revenue.
    ROUND(100.0 * COALESCE(wm.total_waste_cost, 0)
                / NULLIF(COALESCE(sm.gross_revenue, 0), 0), 2)         AS waste_intensity_pct,
    -- Unit shrinkage %: discarded units over total units handled.
    ROUND(100.0 * COALESCE(wm.units_discarded, 0)
                / NULLIF(COALESCE(sm.units_sold, 0) + COALESCE(wm.units_discarded, 0), 0), 2)
                                                                       AS unit_shrinkage_pct,
    -- Share of the loss that strict FEFO rotation could have prevented.
    ROUND(100.0 * COALESCE(wm.loss_expiration, 0)
                / NULLIF(COALESCE(wm.total_waste_cost, 0), 0), 2)      AS fefo_addressable_pct,
    CURRENT_TIMESTAMP                                                  AS refreshed_at
  FROM calendar_grain g
  JOIN stores             s ON s.store_id     = g.store_id
  JOIN product_categories c ON c.category_id  = g.category_id
  LEFT JOIN waste_metrics wm ON wm.store_id    = g.store_id
                            AND wm.category_id = g.category_id
                            AND wm.month_start = g.month_start
  LEFT JOIN sales_metrics sm ON sm.store_id    = g.store_id
                            AND sm.category_id = g.category_id
                            AND sm.month_start = g.month_start
 WITH DATA;

-- REFRESH ... CONCURRENTLY mandates a UNIQUE index covering the full grain.
CREATE UNIQUE INDEX uq_mv_waste_summary_grain
    ON mv_store_category_waste_summary (month_start, store_id, category_id);

-- Supporting indexes for the usual dashboard slicers.
CREATE INDEX idx_mv_waste_summary_period ON mv_store_category_waste_summary (period_label);
CREATE INDEX idx_mv_waste_summary_store  ON mv_store_category_waste_summary (store_code);

COMMENT ON MATERIALIZED VIEW mv_store_category_waste_summary IS
'Monthly datamart at (store x category x month) grain: sales, margin, waste cost split by loss classification, waste intensity % and FEFO-addressable share. Refresh with SELECT fn_refresh_waste_datamart();';


-- ============================================================================
-- SECTION 5: CONCURRENT REFRESH HELPER
-- ============================================================================
-- CONCURRENTLY keeps the datamart readable for BI sessions during the rebuild
-- (no ACCESS EXCLUSIVE lock), at the cost of requiring the unique index above.
-- It cannot run inside an explicit transaction block, hence the AUTOCOMMIT note.
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_refresh_waste_datamart(p_concurrently BOOLEAN DEFAULT TRUE)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_started_at TIMESTAMPTZ := CLOCK_TIMESTAMP();
    v_mode       TEXT        := 'BLOCKING';
    v_rows       BIGINT;
BEGIN
    IF p_concurrently THEN
        -- A CONCURRENTLY refresh is rejected when the matview has never been
        -- populated, and some deployments additionally restrict it outside a
        -- top-level statement. Falling back to the blocking refresh keeps the
        -- datamart correct in every one of those cases instead of failing the
        -- caller -- the only cost is a brief ACCESS EXCLUSIVE lock.
        BEGIN
            REFRESH MATERIALIZED VIEW CONCURRENTLY mv_store_category_waste_summary;
            v_mode := 'CONCURRENTLY';
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE
                'CONCURRENTLY refresh unavailable (%); falling back to a blocking refresh.',
                SQLERRM;
            REFRESH MATERIALIZED VIEW mv_store_category_waste_summary;
            v_mode := 'BLOCKING (fallback)';
        END;
    ELSE
        REFRESH MATERIALIZED VIEW mv_store_category_waste_summary;
    END IF;

    SELECT COUNT(*) INTO v_rows FROM mv_store_category_waste_summary;

    RETURN FORMAT('mv_store_category_waste_summary refreshed (%s): %s rows in %s ms.',
                  v_mode, v_rows,
                  ROUND(EXTRACT(MILLISECONDS FROM CLOCK_TIMESTAMP() - v_started_at)::NUMERIC, 1));
END;
$$;

COMMENT ON FUNCTION fn_refresh_waste_datamart(BOOLEAN) IS
'Refreshes the monthly waste datamart. Defaults to CONCURRENTLY so Power BI keeps reading during the rebuild; must be called with AUTOCOMMIT on (outside an explicit transaction block).';

-- Populate the datamart right after deployment. The first refresh must be the
-- blocking variant: CONCURRENTLY is rejected on a matview never yet populated.
SELECT fn_refresh_waste_datamart(FALSE);


-- ============================================================================
-- USAGE EXAMPLES (documentation only -- safe to copy into psql)
-- ============================================================================
-- Nominal FEFO sale:
--   CALL sp_process_fefo_sale(1, 1, 5);
-- Expected stockout exception (SQLSTATE P0002):
--   CALL sp_process_fefo_sale(1, 1, 999999);
-- Expected anti-fraud rejection (SQLSTATE P0004):
--   INSERT INTO waste_log (waste_code, store_id, product_id, waste_reason_id,
--                          qty_discarded, unit_cost_at_loss, logged_by_user)
--   VALUES ('WASTE-TEST-FRAUD', 1, 1, 1, 40, 4.20, 'operator.test');
-- Nightly expiry sweep:
--   CALL sp_expire_overdue_batches();
-- Concurrent datamart refresh (AUTOCOMMIT):
--   SELECT fn_refresh_waste_datamart();
-- ============================================================================
