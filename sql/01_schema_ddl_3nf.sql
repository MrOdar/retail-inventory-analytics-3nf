-- ============================================================================
-- RETAIL INVENTORY & WASTE REDUCTION ANALYTICS (3NF RELATIONAL SCHEMA)
-- Author: Odar Javier Alcocer Vásquez (Information Systems Engineering - UPC)
-- Engine: PostgreSQL 15+ compatible
-- Standard: Third Normal Form (3NF) Architecture with Referential Integrity
-- ============================================================================

-- Clean environment
DROP TABLE IF EXISTS waste_log CASCADE;
DROP TABLE IF EXISTS daily_sales CASCADE;
DROP TABLE IF EXISTS inventory_batches CASCADE;
DROP TABLE IF EXISTS goods_receipt_items CASCADE;
DROP TABLE IF EXISTS goods_receipt_headers CASCADE;
DROP TABLE IF EXISTS waste_reasons CASCADE;
DROP TABLE IF EXISTS products CASCADE;
DROP TABLE IF EXISTS product_categories CASCADE;
DROP TABLE IF EXISTS suppliers CASCADE;
DROP TABLE IF EXISTS stores CASCADE;

-- ----------------------------------------------------------------------------
-- 1. DIMENSIONAL / MASTER TABLES
-- ----------------------------------------------------------------------------

-- Retail stores / convenience branches
CREATE TABLE stores (
    store_id            SERIAL PRIMARY KEY,
    store_code          VARCHAR(20) NOT NULL UNIQUE,
    store_name          VARCHAR(100) NOT NULL,
    store_format        VARCHAR(30) NOT NULL CHECK (store_format IN ('CONVENIENCE', 'EXPRESS', 'FLAGSHIP')),
    district            VARCHAR(50) NOT NULL,
    city                VARCHAR(50) NOT NULL DEFAULT 'Lima',
    square_meters       NUMERIC(6, 2) CHECK (square_meters > 0),
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Suppliers and distributor network
CREATE TABLE suppliers (
    supplier_id         SERIAL PRIMARY KEY,
    supplier_code       VARCHAR(20) NOT NULL UNIQUE,
    tax_id_ruc          VARCHAR(15) NOT NULL UNIQUE,
    company_name        VARCHAR(150) NOT NULL,
    contact_email       VARCHAR(100),
    contact_phone       VARCHAR(30),
    payment_terms_days  INTEGER NOT NULL DEFAULT 30 CHECK (payment_terms_days >= 0),
    lead_time_days      INTEGER NOT NULL DEFAULT 2 CHECK (lead_time_days >= 0),
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Hierarchical product categories
CREATE TABLE product_categories (
    category_id         SERIAL PRIMARY KEY,
    category_code       VARCHAR(20) NOT NULL UNIQUE,
    category_name       VARCHAR(80) NOT NULL,
    parent_category_id  INTEGER REFERENCES product_categories(category_id) ON DELETE SET NULL,
    storage_temp_type   VARCHAR(20) NOT NULL CHECK (storage_temp_type IN ('FROZEN', 'REFRIGERATED', 'AMBIENT', 'HOT_HOLDING'))
);

-- SKU catalog master
CREATE TABLE products (
    product_id          SERIAL PRIMARY KEY,
    sku_code            VARCHAR(30) NOT NULL UNIQUE,
    barcode_ean13       VARCHAR(14) UNIQUE,
    product_name        VARCHAR(150) NOT NULL,
    category_id         INTEGER NOT NULL REFERENCES product_categories(category_id),
    unit_of_measure     VARCHAR(10) NOT NULL DEFAULT 'UNIT' CHECK (unit_of_measure IN ('UNIT', 'KG', 'LITER', 'PACK')),
    unit_cost           NUMERIC(10, 4) NOT NULL CHECK (unit_cost > 0),
    retail_price        NUMERIC(10, 2) NOT NULL CHECK (retail_price >= unit_cost),
    shelf_life_days     INTEGER CHECK (shelf_life_days > 0),
    is_perishable       BOOLEAN NOT NULL DEFAULT TRUE,
    min_safety_stock    INTEGER NOT NULL DEFAULT 10 CHECK (min_safety_stock >= 0),
    reorder_point       INTEGER NOT NULL DEFAULT 25 CHECK (reorder_point >= min_safety_stock),
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Operational waste reasons catalog
CREATE TABLE waste_reasons (
    waste_reason_id     SERIAL PRIMARY KEY,
    reason_code         VARCHAR(20) NOT NULL UNIQUE,
    reason_description  VARCHAR(100) NOT NULL,
    loss_classification VARCHAR(30) NOT NULL CHECK (loss_classification IN ('EXPIRATION', 'DAMAGE', 'COLD_CHAIN_FAIL', 'THEFT_SHRINKAGE'))
);

-- ----------------------------------------------------------------------------
-- 2. OPERATIONAL & TRANSACTIONAL TABLES
-- ----------------------------------------------------------------------------

-- Goods Receipt Note Header (Guías de Remisión de Entrada)
CREATE TABLE goods_receipt_headers (
    grn_id              SERIAL PRIMARY KEY,
    grn_number          VARCHAR(30) NOT NULL UNIQUE,
    store_id            INTEGER NOT NULL REFERENCES stores(store_id),
    supplier_id         INTEGER NOT NULL REFERENCES suppliers(supplier_id),
    dispatch_guide_ref  VARCHAR(50) NOT NULL, -- Número de Guía de Remisión física
    received_timestamp  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    received_by_user    VARCHAR(60) NOT NULL,
    status              VARCHAR(20) NOT NULL DEFAULT 'RECEIVED' CHECK (status IN ('RECEIVED', 'AUDITED', 'DISCREPANT', 'CANCELLED')),
    notes               TEXT
);

-- Goods Receipt Note Line Items
CREATE TABLE goods_receipt_items (
    grn_item_id         SERIAL PRIMARY KEY,
    grn_id              INTEGER NOT NULL REFERENCES goods_receipt_headers(grn_id) ON DELETE CASCADE,
    product_id          INTEGER NOT NULL REFERENCES products(product_id),
    qty_dispatched      NUMERIC(10, 2) NOT NULL CHECK (qty_dispatched > 0),
    qty_accepted        NUMERIC(10, 2) NOT NULL CHECK (qty_accepted >= 0),
    unit_purchase_cost  NUMERIC(10, 4) NOT NULL CHECK (unit_purchase_cost > 0),
    temperature_celsius NUMERIC(4, 1),
    discrepancy_qty     NUMERIC(10, 2) GENERATED ALWAYS AS (qty_dispatched - qty_accepted) STORED
);

-- Inventory Batches (Core FEFO/FIFO tracking)
CREATE TABLE inventory_batches (
    batch_id            SERIAL PRIMARY KEY,
    batch_code          VARCHAR(40) NOT NULL UNIQUE,
    store_id            INTEGER NOT NULL REFERENCES stores(store_id),
    product_id          INTEGER NOT NULL REFERENCES products(product_id),
    grn_item_id         INTEGER REFERENCES goods_receipt_items(grn_item_id),
    initial_qty         NUMERIC(10, 2) NOT NULL CHECK (initial_qty > 0),
    current_qty         NUMERIC(10, 2) NOT NULL CHECK (current_qty >= 0),
    manufacturing_date  DATE,
    expiration_date     DATE NOT NULL,
    batch_status        VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' CHECK (batch_status IN ('ACTIVE', 'DEPLETED', 'EXPIRED', 'QUARANTINE')),
    created_at          TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_batch_qty CHECK (current_qty <= initial_qty)
);

-- Waste Log (Registro sistemático de mermas operativas)
CREATE TABLE waste_log (
    waste_id            SERIAL PRIMARY KEY,
    waste_code          VARCHAR(40) NOT NULL UNIQUE,
    store_id            INTEGER NOT NULL REFERENCES stores(store_id),
    product_id          INTEGER NOT NULL REFERENCES products(product_id),
    batch_id            INTEGER REFERENCES inventory_batches(batch_id),
    waste_reason_id     INTEGER NOT NULL REFERENCES waste_reasons(waste_reason_id),
    qty_discarded       NUMERIC(10, 2) NOT NULL CHECK (qty_discarded > 0),
    unit_cost_at_loss   NUMERIC(10, 4) NOT NULL CHECK (unit_cost_at_loss > 0),
    total_loss_amount   NUMERIC(12, 2) GENERATED ALWAYS AS (qty_discarded * unit_cost_at_loss) STORED,
    logged_timestamp    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    logged_by_user      VARCHAR(60) NOT NULL,
    authorized_by       VARCHAR(60),
    notes               TEXT
);

-- Daily POS Sales Aggregation per Store and SKU
CREATE TABLE daily_sales (
    sale_id             SERIAL PRIMARY KEY,
    store_id            INTEGER NOT NULL REFERENCES stores(store_id),
    product_id          INTEGER NOT NULL REFERENCES products(product_id),
    sale_date           DATE NOT NULL,
    units_sold          NUMERIC(10, 2) NOT NULL CHECK (units_sold >= 0),
    gross_revenue       NUMERIC(12, 2) NOT NULL CHECK (gross_revenue >= 0),
    cost_of_goods_sold  NUMERIC(12, 2) NOT NULL CHECK (cost_of_goods_sold >= 0),
    CONSTRAINT unq_store_product_date UNIQUE (store_id, product_id, sale_date)
);

-- ----------------------------------------------------------------------------
-- 3. INDEX OPTIMIZATION (B-Tree Performance Tuning)
-- ----------------------------------------------------------------------------

-- Accelerate FEFO expiration checks
CREATE INDEX idx_batches_expiry_status ON inventory_batches (expiration_date, batch_status) WHERE batch_status = 'ACTIVE';
CREATE INDEX idx_batches_product_store ON inventory_batches (product_id, store_id);

-- Accelerate Waste Log lookups by store and date
CREATE INDEX idx_waste_store_date ON waste_log (store_id, logged_timestamp);
CREATE INDEX idx_waste_reason ON waste_log (waste_reason_id);

-- Accelerate Sales velocity and time intelligence queries
CREATE INDEX idx_daily_sales_date ON daily_sales (sale_date, store_id, product_id);
