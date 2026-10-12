-- ============================================================================
-- REGRESSION TEST SUITE: FEFO ROTATION & ANTI-FRAUD CONTROLS
-- Author: Odar Javier Alcocer Vásquez (Information Systems Engineering - UPC)
-- Engine: PostgreSQL 15+
-- ============================================================================
-- 19 assertions proving the behaviour the business depends on, without mutating real data:
-- every test runs inside a SAVEPOINT that is rolled back, so the suite is
-- idempotent and safe to run against a populated database.
--
-- Run with:   make test
--             .\scripts\run_project.ps1 test
--             psql -v ON_ERROR_STOP=1 -f sql/05_tests_business_logic.sql
--
-- The suite fails loudly: any unmet assertion raises an exception, which
-- ON_ERROR_STOP turns into a non-zero exit code for CI.
-- ============================================================================

\set ON_ERROR_STOP on
\timing off

BEGIN;

-- ----------------------------------------------------------------------------
-- Test harness: a tiny assertion helper and a results ledger.
-- ----------------------------------------------------------------------------
CREATE TEMPORARY TABLE test_results (
    test_id     TEXT PRIMARY KEY,
    description TEXT NOT NULL,
    outcome     TEXT NOT NULL,
    detail      TEXT
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.assert_true(
    p_test_id     TEXT,
    p_description TEXT,
    p_condition   BOOLEAN,
    p_detail      TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO test_results (test_id, description, outcome, detail)
    VALUES (p_test_id, p_description,
            CASE WHEN COALESCE(p_condition, FALSE) THEN 'PASS' ELSE 'FAIL' END,
            p_detail);

    IF NOT COALESCE(p_condition, FALSE) THEN
        RAISE EXCEPTION 'TEST % FAILED: % | %', p_test_id, p_description,
            COALESCE(p_detail, '(no detail)')
            USING ERRCODE = 'P0001';
    END IF;

    RAISE NOTICE '  PASS  %  %', p_test_id, p_description;
END;
$$;

-- ----------------------------------------------------------------------------
-- Fixture: an isolated store, product and three batches with known expiries.
-- Codes are prefixed TEST- so they can never collide with operational data.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    v_store_id    INTEGER;
    v_category_id INTEGER;
    v_product_id  INTEGER;
BEGIN
    INSERT INTO stores (store_code, store_name, store_format, district,
                        city, square_meters)
    VALUES ('TEST-STORE', 'Fixture Store', 'CONVENIENCE', 'Test District',
            'Lima', 50.00)
    RETURNING store_id INTO v_store_id;

    INSERT INTO product_categories (category_code, category_name, storage_temp_type)
    VALUES ('TEST-CAT', 'Fixture Category', 'AMBIENT')
    RETURNING category_id INTO v_category_id;

    INSERT INTO products (sku_code, product_name, category_id, unit_cost,
                          retail_price, shelf_life_days, is_perishable,
                          min_safety_stock, reorder_point)
    VALUES ('TEST-SKU', 'Fixture Product', v_category_id, 10.0000, 25.00,
            30, TRUE, 5, 10)
    RETURNING product_id INTO v_product_id;

    -- Three lots, deliberately inserted in NON-expiry order so the procedure
    -- has to sort them itself rather than relying on insertion sequence.
    INSERT INTO inventory_batches (batch_code, store_id, product_id,
                                   initial_qty, current_qty,
                                   manufacturing_date, expiration_date,
                                   batch_status)
    VALUES
        ('TEST-LOT-LATE',   v_store_id, v_product_id, 100, 100,
         CURRENT_DATE - 1, CURRENT_DATE + 30, 'ACTIVE'),
        ('TEST-LOT-SOON',   v_store_id, v_product_id,  10,  10,
         CURRENT_DATE - 1, CURRENT_DATE +  2, 'ACTIVE'),
        ('TEST-LOT-MIDDLE', v_store_id, v_product_id,  20,  20,
         CURRENT_DATE - 1, CURRENT_DATE + 10, 'ACTIVE');
END;
$$;


-- ============================================================================
-- TEST GROUP 1 -- FEFO ROTATION ORDER
-- ============================================================================

-- T1.1: a sale smaller than the nearest-expiry lot must consume ONLY that lot.
SAVEPOINT t1_1;
DO $$
DECLARE
    v_store_id   INTEGER := (SELECT store_id   FROM stores   WHERE store_code = 'TEST-STORE');
    v_product_id INTEGER := (SELECT product_id FROM products WHERE sku_code   = 'TEST-SKU');
    v_soon       NUMERIC;
    v_middle     NUMERIC;
    v_late       NUMERIC;
BEGIN
    CALL sp_process_fefo_sale(v_store_id, v_product_id, 4, CURRENT_DATE,
                              'test.runner', FALSE);

    SELECT current_qty INTO v_soon   FROM inventory_batches WHERE batch_code = 'TEST-LOT-SOON';
    SELECT current_qty INTO v_middle FROM inventory_batches WHERE batch_code = 'TEST-LOT-MIDDLE';
    SELECT current_qty INTO v_late   FROM inventory_batches WHERE batch_code = 'TEST-LOT-LATE';

    PERFORM pg_temp.assert_true(
        'T1.1', 'FEFO consumes the nearest-expiry lot first',
        v_soon = 6 AND v_middle = 20 AND v_late = 100,
        FORMAT('soon=%s (expected 6), middle=%s (expected 20), late=%s (expected 100)',
               v_soon, v_middle, v_late));
END;
$$;
ROLLBACK TO SAVEPOINT t1_1;

-- T1.2: a sale spanning several lots must cascade strictly by expiry, and a
--       lot drained to zero must flip to DEPLETED automatically.
SAVEPOINT t1_2;
DO $$
DECLARE
    v_store_id   INTEGER := (SELECT store_id   FROM stores   WHERE store_code = 'TEST-STORE');
    v_product_id INTEGER := (SELECT product_id FROM products WHERE sku_code   = 'TEST-SKU');
    v_soon       RECORD;
    v_middle     RECORD;
    v_late       RECORD;
BEGIN
    -- 25 units = all 10 of SOON (+2d) then 15 of MIDDLE (+10d); LATE untouched.
    CALL sp_process_fefo_sale(v_store_id, v_product_id, 25, CURRENT_DATE,
                              'test.runner', FALSE);

    SELECT current_qty, batch_status INTO v_soon
      FROM inventory_batches WHERE batch_code = 'TEST-LOT-SOON';
    SELECT current_qty, batch_status INTO v_middle
      FROM inventory_batches WHERE batch_code = 'TEST-LOT-MIDDLE';
    SELECT current_qty, batch_status INTO v_late
      FROM inventory_batches WHERE batch_code = 'TEST-LOT-LATE';

    PERFORM pg_temp.assert_true(
        'T1.2a', 'Multi-lot sale cascades in expiry order',
        v_soon.current_qty = 0 AND v_middle.current_qty = 5
            AND v_late.current_qty = 100,
        FORMAT('soon=%s (expected 0), middle=%s (expected 5), late=%s (expected 100)',
               v_soon.current_qty, v_middle.current_qty, v_late.current_qty));

    PERFORM pg_temp.assert_true(
        'T1.2b', 'An emptied lot auto-transitions to DEPLETED',
        v_soon.batch_status = 'DEPLETED' AND v_middle.batch_status = 'ACTIVE',
        FORMAT('soon status=%s (expected DEPLETED), middle status=%s (expected ACTIVE)',
               v_soon.batch_status, v_middle.batch_status));
END;
$$;
ROLLBACK TO SAVEPOINT t1_2;

-- T1.3: an expired lot must never be sold, even while flagged ACTIVE.
SAVEPOINT t1_3;
DO $$
DECLARE
    v_store_id   INTEGER := (SELECT store_id   FROM stores   WHERE store_code = 'TEST-STORE');
    v_product_id INTEGER := (SELECT product_id FROM products WHERE sku_code   = 'TEST-SKU');
    v_expired    NUMERIC;
BEGIN
    INSERT INTO inventory_batches (batch_code, store_id, product_id,
                                   initial_qty, current_qty,
                                   manufacturing_date, expiration_date,
                                   batch_status)
    VALUES ('TEST-LOT-EXPIRED', v_store_id, v_product_id, 50, 50,
            CURRENT_DATE - 40, CURRENT_DATE - 1, 'ACTIVE');

    CALL sp_process_fefo_sale(v_store_id, v_product_id, 5, CURRENT_DATE,
                              'test.runner', FALSE);

    SELECT current_qty INTO v_expired
      FROM inventory_batches WHERE batch_code = 'TEST-LOT-EXPIRED';

    PERFORM pg_temp.assert_true(
        'T1.3', 'An expired lot is excluded from sellable stock',
        v_expired = 50,
        FORMAT('expired lot qty=%s (expected 50, i.e. untouched)', v_expired));
END;
$$;
ROLLBACK TO SAVEPOINT t1_3;


-- ============================================================================
-- TEST GROUP 2 -- STOCKOUT HANDLING
-- ============================================================================

-- T2.1: demand above available stock must raise P0002 and change nothing.
SAVEPOINT t2_1;
DO $$
DECLARE
    v_store_id   INTEGER := (SELECT store_id   FROM stores   WHERE store_code = 'TEST-STORE');
    v_product_id INTEGER := (SELECT product_id FROM products WHERE sku_code   = 'TEST-SKU');
    v_raised     BOOLEAN := FALSE;
    v_message    TEXT;
    v_total      NUMERIC;
BEGIN
    BEGIN
        -- Total sellable stock in the fixture is 130 units.
        CALL sp_process_fefo_sale(v_store_id, v_product_id, 5000, CURRENT_DATE,
                                  'test.runner', FALSE);
    EXCEPTION
        WHEN SQLSTATE 'P0002' THEN
            v_raised := TRUE;
            v_message := SQLERRM;
    END;

    PERFORM pg_temp.assert_true(
        'T2.1a', 'Insufficient stock raises the Stockout exception (P0002)',
        v_raised, 'no P0002 exception was raised');

    PERFORM pg_temp.assert_true(
        'T2.1b', 'The stockout message names the shortfall',
        v_message ILIKE '%Stockout / Insufficient Inventory%',
        FORMAT('message was: %s', COALESCE(v_message, '(none)')));

    -- The exception was caught inside a subtransaction, so the batch
    -- decrements it rolled back must be invisible here.
    SELECT SUM(current_qty) INTO v_total
      FROM inventory_batches
     WHERE batch_code IN ('TEST-LOT-SOON', 'TEST-LOT-MIDDLE', 'TEST-LOT-LATE');

    PERFORM pg_temp.assert_true(
        'T2.1c', 'A failed sale leaves inventory untouched (atomicity)',
        v_total = 130,
        FORMAT('total stock=%s (expected 130)', v_total));
END;
$$;
ROLLBACK TO SAVEPOINT t2_1;

-- T2.2: a non-positive quantity is rejected as invalid input.
SAVEPOINT t2_2;
DO $$
DECLARE
    v_store_id   INTEGER := (SELECT store_id   FROM stores   WHERE store_code = 'TEST-STORE');
    v_product_id INTEGER := (SELECT product_id FROM products WHERE sku_code   = 'TEST-SKU');
    v_raised     BOOLEAN := FALSE;
BEGIN
    BEGIN
        CALL sp_process_fefo_sale(v_store_id, v_product_id, -10, CURRENT_DATE,
                                  'test.runner', FALSE);
    EXCEPTION WHEN OTHERS THEN
        v_raised := TRUE;
    END;

    PERFORM pg_temp.assert_true(
        'T2.2', 'A negative sale quantity is rejected', v_raised,
        'the procedure accepted a negative quantity');
END;
$$;
ROLLBACK TO SAVEPOINT t2_2;

-- T2.3: the sale is posted to daily_sales with true lot-level COGS.
SAVEPOINT t2_3;
DO $$
DECLARE
    v_store_id   INTEGER := (SELECT store_id   FROM stores   WHERE store_code = 'TEST-STORE');
    v_product_id INTEGER := (SELECT product_id FROM products WHERE sku_code   = 'TEST-SKU');
    v_sale       RECORD;
BEGIN
    CALL sp_process_fefo_sale(v_store_id, v_product_id, 8, CURRENT_DATE,
                              'test.runner', TRUE);

    SELECT units_sold, gross_revenue, cost_of_goods_sold INTO v_sale
      FROM daily_sales
     WHERE store_id = v_store_id AND product_id = v_product_id
       AND sale_date = CURRENT_DATE;

    -- 8 units x S/ 25.00 retail = 200.00 ; 8 x S/ 10.00 cost = 80.00
    PERFORM pg_temp.assert_true(
        'T2.3', 'A sale is posted to daily_sales with correct revenue and COGS',
        v_sale.units_sold = 8 AND v_sale.gross_revenue = 200.00
            AND v_sale.cost_of_goods_sold = 80.00,
        FORMAT('units=%s (exp 8), revenue=%s (exp 200.00), cogs=%s (exp 80.00)',
               v_sale.units_sold, v_sale.gross_revenue, v_sale.cost_of_goods_sold));
END;
$$;
ROLLBACK TO SAVEPOINT t2_3;


-- ============================================================================
-- TEST GROUP 3 -- ANTI-FRAUD WASTE TRIGGER
-- ============================================================================

-- T3.1: a material loss with no authorizer must be blocked (P0004).
SAVEPOINT t3_1;
DO $$
DECLARE
    v_store_id   INTEGER := (SELECT store_id   FROM stores   WHERE store_code = 'TEST-STORE');
    v_product_id INTEGER := (SELECT product_id FROM products WHERE sku_code   = 'TEST-SKU');
    v_reason_id  INTEGER := (SELECT waste_reason_id FROM waste_reasons
                              WHERE loss_classification = 'EXPIRATION' LIMIT 1);
    v_raised     BOOLEAN := FALSE;
    v_message    TEXT;
BEGIN
    BEGIN
        -- 10 units x S/ 10.00 = S/ 100.00, well above the S/ 50.00 threshold.
        INSERT INTO waste_log (waste_code, store_id, product_id, waste_reason_id,
                               qty_discarded, unit_cost_at_loss, logged_by_user)
        VALUES ('TEST-WASTE-NOAUTH', v_store_id, v_product_id, v_reason_id,
                10, 10.0000, 'operator.test');
    EXCEPTION WHEN SQLSTATE 'P0004' THEN
        v_raised  := TRUE;
        v_message := SQLERRM;
    END;

    PERFORM pg_temp.assert_true(
        'T3.1a', 'High-value waste without an authorizer is blocked (P0004)',
        v_raised, 'the unauthorized high-value waste row was accepted');

    PERFORM pg_temp.assert_true(
        'T3.1b', 'The rejection message demands an authorizer',
        v_message ILIKE '%WASTE AUTHORIZATION REQUIRED%',
        FORMAT('message was: %s', COALESCE(v_message, '(none)')));
END;
$$;
ROLLBACK TO SAVEPOINT t3_1;

-- T3.2: the same loss WITH a named authorizer must be accepted.
SAVEPOINT t3_2;
DO $$
DECLARE
    v_store_id   INTEGER := (SELECT store_id   FROM stores   WHERE store_code = 'TEST-STORE');
    v_product_id INTEGER := (SELECT product_id FROM products WHERE sku_code   = 'TEST-SKU');
    v_reason_id  INTEGER := (SELECT waste_reason_id FROM waste_reasons
                              WHERE loss_classification = 'EXPIRATION' LIMIT 1);
    v_amount     NUMERIC;
BEGIN
    INSERT INTO waste_log (waste_code, store_id, product_id, waste_reason_id,
                           qty_discarded, unit_cost_at_loss, logged_by_user,
                           authorized_by)
    VALUES ('TEST-WASTE-AUTH', v_store_id, v_product_id, v_reason_id,
            10, 10.0000, 'operator.test', 'supervisor.zonal');

    SELECT total_loss_amount INTO v_amount
      FROM waste_log WHERE waste_code = 'TEST-WASTE-AUTH';

    PERFORM pg_temp.assert_true(
        'T3.2', 'Authorized high-value waste is accepted and priced correctly',
        v_amount = 100.00,
        FORMAT('total_loss_amount=%s (expected 100.00)', v_amount));
END;
$$;
ROLLBACK TO SAVEPOINT t3_2;

-- T3.3: a small loss needs no authorizer (the threshold really is a threshold).
SAVEPOINT t3_3;
DO $$
DECLARE
    v_store_id   INTEGER := (SELECT store_id   FROM stores   WHERE store_code = 'TEST-STORE');
    v_product_id INTEGER := (SELECT product_id FROM products WHERE sku_code   = 'TEST-SKU');
    v_reason_id  INTEGER := (SELECT waste_reason_id FROM waste_reasons
                              WHERE loss_classification = 'DAMAGE' LIMIT 1);
    v_count      INTEGER;
BEGIN
    -- 2 units x S/ 10.00 = S/ 20.00, below the threshold.
    INSERT INTO waste_log (waste_code, store_id, product_id, waste_reason_id,
                           qty_discarded, unit_cost_at_loss, logged_by_user)
    VALUES ('TEST-WASTE-SMALL', v_store_id, v_product_id, v_reason_id,
            2, 10.0000, 'operator.test');

    SELECT COUNT(*) INTO v_count
      FROM waste_log WHERE waste_code = 'TEST-WASTE-SMALL';

    PERFORM pg_temp.assert_true(
        'T3.3', 'Immaterial waste posts without an authorizer',
        v_count = 1, FORMAT('rows inserted=%s (expected 1)', v_count));
END;
$$;
ROLLBACK TO SAVEPOINT t3_3;

-- T3.4: segregation of duties -- self-authorization must be blocked.
SAVEPOINT t3_4;
DO $$
DECLARE
    v_store_id   INTEGER := (SELECT store_id   FROM stores   WHERE store_code = 'TEST-STORE');
    v_product_id INTEGER := (SELECT product_id FROM products WHERE sku_code   = 'TEST-SKU');
    v_reason_id  INTEGER := (SELECT waste_reason_id FROM waste_reasons
                              WHERE loss_classification = 'THEFT_SHRINKAGE' LIMIT 1);
    v_raised     BOOLEAN := FALSE;
BEGIN
    BEGIN
        INSERT INTO waste_log (waste_code, store_id, product_id, waste_reason_id,
                               qty_discarded, unit_cost_at_loss, logged_by_user,
                               authorized_by)
        VALUES ('TEST-WASTE-SELFAUTH', v_store_id, v_product_id, v_reason_id,
                10, 10.0000, 'operator.test', 'Operator.Test');
    EXCEPTION WHEN SQLSTATE 'P0004' THEN
        v_raised := TRUE;
    END;

    PERFORM pg_temp.assert_true(
        'T3.4', 'Self-authorized material waste is blocked (segregation of duties)',
        v_raised, 'the operator was allowed to authorize their own write-off');
END;
$$;
ROLLBACK TO SAVEPOINT t3_4;


-- ============================================================================
-- TEST GROUP 4 -- EXPIRY SWEEP & DATAMART
-- ============================================================================

-- T4.1: the nightly sweep flags overdue lots and writes the residual stock off.
SAVEPOINT t4_1;
DO $$
DECLARE
    v_store_id   INTEGER := (SELECT store_id   FROM stores   WHERE store_code = 'TEST-STORE');
    v_product_id INTEGER := (SELECT product_id FROM products WHERE sku_code   = 'TEST-SKU');
    v_batch_id   INTEGER;
    v_status     TEXT;
    v_qty        NUMERIC;
    v_waste_qty  NUMERIC;
BEGIN
    INSERT INTO inventory_batches (batch_code, store_id, product_id,
                                   initial_qty, current_qty,
                                   manufacturing_date, expiration_date,
                                   batch_status)
    VALUES ('TEST-LOT-SWEEP', v_store_id, v_product_id, 30, 7,
            CURRENT_DATE - 40, CURRENT_DATE - 2, 'ACTIVE')
    RETURNING batch_id INTO v_batch_id;

    CALL sp_expire_overdue_batches(CURRENT_DATE, 'test.supervisor');

    SELECT batch_status, current_qty INTO v_status, v_qty
      FROM inventory_batches WHERE batch_id = v_batch_id;

    PERFORM pg_temp.assert_true(
        'T4.1a', 'The sweep flags an overdue lot EXPIRED and zeroes its stock',
        v_status = 'EXPIRED' AND v_qty = 0,
        FORMAT('status=%s (exp EXPIRED), qty=%s (exp 0)', v_status, v_qty));

    SELECT SUM(qty_discarded) INTO v_waste_qty
      FROM waste_log WHERE batch_id = v_batch_id;

    PERFORM pg_temp.assert_true(
        'T4.1b', 'The residual stock is written off to waste_log',
        v_waste_qty = 7,
        FORMAT('written-off qty=%s (expected 7)', COALESCE(v_waste_qty, 0)));
END;
$$;
ROLLBACK TO SAVEPOINT t4_1;

-- T4.2: the datamart exists, is unique on its grain and refreshes cleanly.
DO $$
DECLARE
    v_relkind  CHAR(1);
    v_has_uq   BOOLEAN;
    v_dupes    INTEGER;
BEGIN
    SELECT relkind INTO v_relkind
      FROM pg_class WHERE relname = 'mv_store_category_waste_summary';

    PERFORM pg_temp.assert_true(
        'T4.2a', 'mv_store_category_waste_summary exists as a materialized view',
        v_relkind = 'm',
        FORMAT('relkind=%s (expected m)', COALESCE(v_relkind, '?')));

    SELECT EXISTS (
        SELECT 1 FROM pg_indexes
         WHERE tablename = 'mv_store_category_waste_summary'
           AND indexname = 'uq_mv_waste_summary_grain') INTO v_has_uq;

    PERFORM pg_temp.assert_true(
        'T4.2b', 'A unique index backs CONCURRENTLY refreshes',
        v_has_uq, 'uq_mv_waste_summary_grain is missing');

    SELECT COUNT(*) INTO v_dupes FROM (
        SELECT month_start, store_id, category_id
          FROM mv_store_category_waste_summary
         GROUP BY 1, 2, 3 HAVING COUNT(*) > 1) AS d;

    PERFORM pg_temp.assert_true(
        'T4.2c', 'The datamart holds exactly one row per store/category/month',
        v_dupes = 0, FORMAT('duplicate grain rows=%s (expected 0)', v_dupes));
END;
$$;


-- ============================================================================
-- RESULTS
-- ============================================================================
\echo ''
\echo '=============================================================='
\echo ' REGRESSION SUITE RESULTS'
\echo '=============================================================='

SELECT test_id, outcome, description FROM test_results ORDER BY test_id;

SELECT COUNT(*) FILTER (WHERE outcome = 'PASS') AS passed,
       COUNT(*) FILTER (WHERE outcome = 'FAIL') AS failed,
       COUNT(*)                                  AS total
  FROM test_results;

-- Every assertion ran inside a SAVEPOINT that was rolled back, and the fixture
-- itself is discarded here: the database ends exactly as it started.
ROLLBACK;

\echo ''
\echo 'Suite complete. All fixtures rolled back; the database is unchanged.'
