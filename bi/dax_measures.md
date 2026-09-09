# Especificación de Métricas DAX para Power BI (Esquema en Estrella)

Este documento contiene las fórmulas analíticas en DAX modeladas para el **Tablero Ejecutivo de Gestión de Inventarios y Reducción de Mermas en Retail**.

---

## 1. Arquitectura Dimensional (Esquema en Estrella)
* **Tablas de Hechos (Fact Tables):**
  - `Fact_WasteLog`: Registros de mermas operativas, lotes vencidos y costos asociados dados de baja.
  - `Fact_DailySales`: Transacciones históricas del sistema POS a nivel de tienda y costo de ventas (COGS).
  - `Fact_InventoryBatches`: Existencias activas por lote, recepción inicial y fechas de caducidad.
* **Tablas de Dimensión (Dimension Tables):**
  - `Dim_Date`: Tabla de calendario estándar con día, mes, año, trimestre e indicador de fin de semana.
  - `Dim_Product`: Maestro de SKUs, categorías, costo unitario, precio de venta e indicador de perecibilidad.
  - `Dim_Store`: Código de tienda, formato (Convenience, Express, Flagship), distrito y estado operativo.
  - `Dim_WasteReason`: Clasificación de pérdida (Vencimiento, Daño Físico, Ruptura de Cadena de Frío, Pérdida Desconocida).

---

## 2. Métricas DAX Financieras y de Volumen

### Ventas Brutas Totales (PEN)
```dax
Total Revenue = 
SUM(Fact_DailySales[gross_revenue])
```

### Costo Total de Pérdidas por Merma (PEN)
```dax
Total Waste Cost = 
SUM(Fact_WasteLog[total_loss_amount])
```

### Ratio de Intensidad de Merma (%)
Calcula el porcentaje de merma operativa respecto al volumen de ventas brutas. KPI crítico para gerentes de tienda.
```dax
Waste Intensity % = 
DIVIDE(
    [Total Waste Cost], 
    [Total Revenue], 
    0
)
```

---

## 3. Salud del Inventario y Riesgo de Vencimiento

### Existencias Activas en Mano (Unidades)
```dax
Stock On Hand = 
CALCULATE(
    SUM(Fact_InventoryBatches[current_qty]),
    Fact_InventoryBatches[batch_status] = "ACTIVE"
)
```

### Exposición Financiera en Riesgo (S/ en Riesgo de Vencimiento)
Valorización monetaria del inventario comprometido en lotes que vencerán en los próximos 5 días.
```dax
Expiring Stock Cost (Next 5 Days) = 
CALCULATE(
    SUMX(
        Fact_InventoryBatches, 
        Fact_InventoryBatches[current_qty] * RELATED(Dim_Product[unit_cost])
    ),
    Fact_InventoryBatches[batch_status] = "ACTIVE",
    Fact_InventoryBatches[expiration_date] <= TODAY() + 5,
    Fact_InventoryBatches[expiration_date] >= TODAY()
)
```

### Días de Venta de Inventario (DSI - Days Sales of Inventory)
Estima los días de cobertura antes de agotar stock en función del promedio móvil de ventas de los últimos 14 días.
```dax
Average Daily Sales Units = 
CALCULATE(
    DIVIDE(SUM(Fact_DailySales[units_sold]), 14, 0),
    DATESINPERIOD(Dim_Date[Date], TODAY(), -14, DAY)
)

Days Sales of Inventory (DSI) = 
DIVIDE(
    [Stock On Hand],
    [Average Daily Sales Units],
    999
)
```

---

## 4. Auditoría de Proveedores y Nivel de Cumplimiento

### Nivel de Cumplimiento de Entrega (Supplier Fill Rate %)
Compara el conteo físico recibido contra la guía de remisión despachada por el proveedor.
```dax
Supplier Fill Rate % = 
DIVIDE(
    SUM(goods_receipt_items[qty_accepted]),
    SUM(goods_receipt_items[qty_dispatched]),
    0
)
```
