-- ============================================================================
-- SEED DATA: REALISTIC RETAIL & CONVENIENCE STORE DATASET
-- Author: Odar Javier Alcocer Vásquez (UPC)
-- Context: Retail convenience store network (Lima, Perú)
-- ============================================================================

-- 1. STORES
INSERT INTO stores (store_code, store_name, store_format, district, city, square_meters) VALUES
('TB-101', 'Tambo Miraflores Shell', 'FLAGSHIP', 'Miraflores', 'Lima', 110.00),
('TB-102', 'Tambo San Isidro Corp', 'EXPRESS', 'San Isidro', 'Lima', 65.00),
('TB-103', 'Tambo Surco Primavera', 'CONVENIENCE', 'Santiago de Surco', 'Lima', 85.00),
('TB-104', 'Tambo San Miguel Plaza', 'CONVENIENCE', 'San Miguel', 'Lima', 92.00);

-- 2. SUPPLIERS
INSERT INTO suppliers (supplier_code, tax_id_ruc, company_name, contact_email, payment_terms_days, lead_time_days) VALUES
('SUP-001', '20100017491', 'Gloria S.A.', 'pedidos@gloria.com.pe', 45, 1),
('SUP-002', '20100055237', 'Alicorp S.A.A.', 'distribucion@alicorp.com.pe', 30, 2),
('SUP-003', '20100108888', 'San Fernando S.A.', 'institucional@san-fernando.com.pe', 30, 1),
('SUP-004', '20255998711', 'Bimbo del Perú S.A.', 'preventa@bimbo.com.pe', 30, 2);

-- 3. PRODUCT CATEGORIES
INSERT INTO product_categories (category_code, category_name, parent_category_id, storage_temp_type) VALUES
('CAT-DAIRY', 'Lácteos & Derivados', NULL, 'REFRIGERATED'),
('CAT-BAKERY', 'Panadería & Embutidos', NULL, 'AMBIENT'),
('CAT-RTE', 'Comidas Listas / Calientes', NULL, 'HOT_HOLDING'),
('CAT-BEV', 'Bebidas & Gaseosas', NULL, 'AMBIENT');

-- 4. PRODUCTS
INSERT INTO products (sku_code, barcode_ean13, product_name, category_id, unit_of_measure, unit_cost, retail_price, shelf_life_days, is_perishable, min_safety_stock, reorder_point) VALUES
('SKU-1001', '7750100001011', 'Yogurt Fresa 1L Gloria', 1, 'UNIT', 4.2000, 6.90, 21, TRUE, 15, 35),
('SKU-1002', '7750100001028', 'Leche Fresca UHT 1L Gloria', 1, 'UNIT', 3.8000, 5.50, 45, TRUE, 20, 50),
('SKU-2001', '7750200002015', 'Pan de Molde Blanco Bimbo 480g', 2, 'UNIT', 5.1000, 7.80, 14, TRUE, 12, 30),
('SKU-2002', '7750200002022', 'Empanada de Carne Tradicional', 3, 'UNIT', 2.3000, 4.90, 2, TRUE, 25, 60),
('SKU-2003', '7750200002039', 'Sandwich Mixto Caliente', 3, 'UNIT', 2.8000, 5.50, 2, TRUE, 20, 50),
('SKU-3001', '7750300003019', 'Gaseosa Inca Kola 500ml', 4, 'UNIT', 1.9000, 3.50, 180, FALSE, 40, 100),
('SKU-3002', '7750300003026', 'Jugo de Naranja 300ml Pulp', 4, 'UNIT', 1.7000, 2.90, 60, TRUE, 15, 40);

-- 5. WASTE REASONS
INSERT INTO waste_reasons (reason_code, reason_description, loss_classification) VALUES
('WR-EXP', 'Vencimiento de fecha límite de consumo', 'EXPIRATION'),
('WR-DMG', 'Daño físico / rotura de empaque en manipulación', 'DAMAGE'),
('WR-COLD', 'Ruptura de cadena de frío en exhibidor', 'COLD_CHAIN_FAIL'),
('WR-SHR', 'Merma desconocida / Descuadre en conteo físico', 'THEFT_SHRINKAGE');

-- 6. GOODS RECEIPT HEADERS & ITEMS
-- Recepción 1: Miraflores - Gloria
INSERT INTO goods_receipt_headers (grn_number, store_id, supplier_id, dispatch_guide_ref, received_timestamp, received_by_user, status) VALUES
('GRN-2026-0001', 1, 1, 'GR-001-98721', CURRENT_TIMESTAMP - INTERVAL '10 days', 'Odar Alcocer', 'AUDITED'),
('GRN-2026-0002', 1, 4, 'GR-004-12455', CURRENT_TIMESTAMP - INTERVAL '8 days', 'Odar Alcocer', 'AUDITED'),
('GRN-2026-0003', 2, 3, 'GR-003-44120', CURRENT_TIMESTAMP - INTERVAL '2 days', 'Luis Andía', 'DISCREPANT');

-- Items de recepción (con discrepancia simulada en GRN 3)
INSERT INTO goods_receipt_items (grn_id, product_id, qty_dispatched, qty_accepted, unit_purchase_cost, temperature_celsius) VALUES
(1, 1, 50.00, 50.00, 4.2000, 4.2),
(1, 2, 60.00, 60.00, 3.8000, 5.1),
(2, 3, 40.00, 40.00, 5.1000, 19.5),
(3, 4, 100.00, 85.00, 2.3000, 68.0); -- 15 unidades rechazadas por daño en transporte

-- 7. INVENTORY BATCHES (Simulando lotes activos, próximos a vencer y vencidos)
INSERT INTO inventory_batches (batch_code, store_id, product_id, grn_item_id, initial_qty, current_qty, manufacturing_date, expiration_date, batch_status) VALUES
-- Lote próximo a vencer en 2 días (Alerta roja)
('LOTE-YOG-01', 1, 1, 1, 50.00, 18.00, CURRENT_DATE - INTERVAL '19 days', CURRENT_DATE + INTERVAL '2 days', 'ACTIVE'),
-- Lote vigente con vencimiento holgado
('LOTE-LECHE-01', 1, 2, 2, 60.00, 42.00, CURRENT_DATE - INTERVAL '10 days', CURRENT_DATE + INTERVAL '35 days', 'ACTIVE'),
-- Lote de pan próximo a vencer en 3 días
('LOTE-PAN-01', 1, 3, 3, 40.00, 12.00, CURRENT_DATE - INTERVAL '11 days', CURRENT_DATE + INTERVAL '3 days', 'ACTIVE'),
-- Lote de empanadas del día de hoy
('LOTE-EMP-01', 2, 4, 4, 85.00, 30.00, CURRENT_DATE, CURRENT_DATE + INTERVAL '1 day', 'ACTIVE'),
-- Lote vencido ayer que no se rotó a tiempo (Generó merma)
('LOTE-SAND-OLD', 1, 5, NULL, 30.00, 0.00, CURRENT_DATE - INTERVAL '3 days', CURRENT_DATE - INTERVAL '1 day', 'EXPIRED');

-- 8. WASTE LOG (Mermas reales registradas)
INSERT INTO waste_log (waste_code, store_id, product_id, batch_id, waste_reason_id, qty_discarded, unit_cost_at_loss, logged_timestamp, logged_by_user, authorized_by, notes) VALUES
('WASTE-2026-001', 1, 5, 5, 1, 8.00, 2.8000, CURRENT_TIMESTAMP - INTERVAL '1 day', 'Odar Alcocer', 'Admin Tienda', 'Vencimiento en vitrina caliente al cierre de turno.'),
('WASTE-2026-002', 1, 1, 1, 2, 2.00, 4.2000, CURRENT_TIMESTAMP - INTERVAL '4 days', 'Odar Alcocer', 'Admin Tienda', 'Rotura de precinto de seguridad en góndola.'),
('WASTE-2026-003', 2, 4, 4, 3, 5.00, 2.3000, CURRENT_TIMESTAMP - INTERVAL '2 days', 'Luis Andía', 'Supervisor Zonal', 'Falla de termostato en exhibidor caliente.');

-- 9. DAILY SALES (Rotación histórica de 7 días para análisis)
INSERT INTO daily_sales (store_id, product_id, sale_date, units_sold, gross_revenue, cost_of_goods_sold) VALUES
(1, 1, CURRENT_DATE - INTERVAL '3 days', 12.00, 82.80, 50.40),
(1, 1, CURRENT_DATE - INTERVAL '2 days', 10.00, 69.00, 42.00),
(1, 1, CURRENT_DATE - INTERVAL '1 day', 10.00, 69.00, 42.00),
(1, 2, CURRENT_DATE - INTERVAL '3 days', 6.00, 33.00, 22.80),
(1, 2, CURRENT_DATE - INTERVAL '2 days', 8.00, 44.00, 30.40),
(1, 2, CURRENT_DATE - INTERVAL '1 day', 4.00, 22.00, 15.20),
(1, 3, CURRENT_DATE - INTERVAL '2 days', 14.00, 109.20, 71.40),
(1, 3, CURRENT_DATE - INTERVAL '1 day', 14.00, 109.20, 71.40),
(2, 4, CURRENT_DATE - INTERVAL '1 day', 55.00, 269.50, 126.50);
