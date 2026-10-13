# Especificación de Arquitectura: Plataforma Analítica de Inventarios Retail y Control de Mermas (3NF)

## 1. Resumen Ejecutivo y Propósito
Este proyecto es una solución integral de analítica e ingeniería de datos end-to-end diseñada para resolver desafíos operativos reales en cadenas de tiendas de conveniencia y retail de alta frecuencia (inspirado en entornos reales como Tiendas Tambo y operaciones de comida rápida como Bembos / Intercorp).

Conecta los flujos de trabajo operativos físicos (conteos cíclicos de inventario, conciliación de guías de remisión, rotación FEFO/FIFO, registro y auditoría de mermas) con una arquitectura relacional rigurosa (Esquema PostgreSQL 3NF) y herramientas para la toma de decisiones estratégicas (consultas SQL analíticas y métricas DAX en Power BI bajo esquema en estrella).

---

## 2. Stack Tecnológico
- **Motor de Base de Datos:** PostgreSQL 15+ (con sintaxis estándar compatible con SQL Server / BigQuery)
- **Modelado de Datos:** Tercera Forma Normal (3NF) para rigor transaccional + Esquema en Estrella para analítica de BI
- **Analítica SQL Core:** SQL Avanzado (Funciones de Ventana, Expresiones de Tabla Comunes - CTEs, Consultas Recursivas, Aritmética de Fechas)
- **Inteligencia de Negocios:** Modelado dimensional, esquema en estrella, métricas DAX (Inteligencia de Tiempo, Ratio de Merma, Días de Venta de Inventario - DSI)
- **Automatización y Control de Versiones:** Git, documentación profesional en GitHub con diagramas Mermaid integrados, Docker Compose, GNU Make y scripts PowerShell.

---

## 3. Arquitectura Entidad-Relación (3NF)

### Tablas Maestras:
1. `stores`: Sedes y tiendas físicas (código de tienda, tipo de tienda, distrito, ciudad, metros cuadrados).
2. `suppliers`: Catálogo de proveedores, datos de contacto, condiciones de pago, tiempo de entrega en días (lead time).
3. `product_categories`: Mapeo jerárquico recursivo de categorías (Perecibles, Bebidas, Listos para Comer, Abarrotes).
4. `products`: Catálogo maestro de SKUs (código SKU, código de barras, nombre, category_id, unidad de medida, costo unitario, precio de venta, vida útil en días, indicador de perecibilidad, stock mínimo de seguridad).

### Tablas Operativas y Transaccionales:
5. `goods_receipt_headers`: Recepciones formales de mercadería (GRN / Guías de Remisión) vinculando tienda, proveedor, número de factura/guía, fecha de despacho, fecha/hora de recepción y operador receptor.
6. `goods_receipt_items`: Detalle de líneas recibidas, cantidad despachada, cantidad física aceptada, costo unitario, condición de calidad.
7. `inventory_batches`: Tabla central para el seguimiento FIFO/FEFO. Almacena número de lote, product_id, store_id, grn_item_id, cantidad inicial, cantidad disponible actual, fecha de producción, fecha de vencimiento y estado ('ACTIVE', 'DEPLETED', 'EXPIRED', 'QUARANTINE').
8. `waste_reasons`: Catálogo estándar de motivos de baja operativa (ej. 'EXPIRED', 'DAMAGED_IN_TRANSIT', 'BROKEN_PACKAGING', 'COLD_CHAIN_BREACH').
9. `waste_log`: Bitácora formal de auditoría de cada unidad desechada. Batch_id, store_id, product_id, marca de tiempo, cantidad desechada, costo unitario al momento de la baja, waste_reason_id, usuario autorizador y observaciones.
10. `daily_sales`: Transacciones diarias consolidadas del POS por tienda y SKU para calcular velocidad de rotación, ritmo de ventas y probabilidad de quiebre de stock.

---

## 4. Requerimientos Analíticos (Entregables SQL)
1. **Matriz de Riesgo de Vencimiento FEFO/PEPS:** Identifica lotes activos que vencen en 3, 7 y 14 días, calculando la exposición financiera en riesgo (S/) y sugiriendo rebajas o remates preventivos.
2. **Auditoría de Descuadres entre Guía de Remisión y Conteo Físico:** Compara las cantidades despachadas por el proveedor frente a las aceptadas en tienda para identificar mermas sistemáticas del proveedor y sobrefacturaciones.
3. **Ratio de Intensidad de Mermas por Tienda:** Mide el costo de merma como porcentaje de las ventas brutas ($Merma / Ventas$) particionado por tienda y categoría mediante Funciones de Ventana.
4. **Días de Venta de Inventario (DSI) y Riesgo de Quiebre:** Analiza la velocidad del inventario comparando el stock activo actual contra el promedio móvil de ventas de los últimos 30 días.

---

## 5. Entregables en la Estructura de Directorios
- `sql/01_schema_ddl_3nf.sql`: Script DDL con definición de tablas, Claves Primarias, Claves Foráneas, restricciones CHECK e índices B-Tree optimizados.
- `sql/02_seed_data.sql`: Dataset maestro de datos iniciales con tiendas, proveedores, SKUs perecibles, recepciones de mercadería, lotes, ventas y mermas.
- `sql/03_analytical_queries.sql`: Las 4 consultas analíticas avanzadas de negocio, completamente documentadas con explicación de CTEs y funciones de ventana.
- `sql/04_triggers_and_procedures.sql`: Lógica transaccional con procedimientos FEFO, triggers antifraude y vista materializada.
- `sql/05_tests_business_logic.sql`: Suite de 19 aserciones SQL aisladas en SAVEPOINTs no destructivos.
- `bi/dax_measures.md`: Fórmulas analíticas DAX documentadas para integración con Power BI.
- `README.md`: Documentación principal del repositorio con diagramas de arquitectura, contexto operativo e impacto de negocio.

---

## 6. Capa de Lógica Transaccional (PL/pgSQL)

Las reglas de negocio críticas residen dentro del motor de base de datos, garantizando que no puedan ser vulneradas por aplicaciones cliente. Implementadas en `sql/04_triggers_and_procedures.sql`:

| Objeto | Tipo | Responsabilidad |
|---|---|---|
| `sp_process_fefo_sale` | Procedimiento | Consume `inventory_batches` en estricto orden cronológico `expiration_date ASC`, actualiza lotes agotados a `DEPLETED`, registra ventas en `daily_sales` con el COGS real por lote, y emite `SQLSTATE P0002` ante quiebre de stock. Bloquea filas candidatas con `FOR UPDATE` para evitar sobreventas concurrentes en POS. |
| `sp_expire_overdue_batches` | Procedimiento | Barrido nocturno: identifica lotes `ACTIVE` vencidos, los actualiza a `EXPIRED` y traslada el saldo a `waste_log` bajo el motivo `EXPIRATION`. |
| `trg_audit_high_waste_alert` | Trigger de fila `BEFORE` | Control antifraude en `waste_log`: bloquea bajas superiores a S/ 50.00 que carezcan de autorizador o que sean auto-autorizadas por el operador, y rechaza bajas superiores al `initial_qty` del lote. |
| `mv_store_category_waste_summary` | Vista Materializada | Datamart preagregado a nivel de tienda × categoría × mes para consumo directo desde Power BI. |
| `fn_refresh_waste_datamart` | Función | Refresca el datamart (concurrente por defecto mediante `CONCURRENTLY`), garantizando lecturas ininterrumpidas en tableros de BI. |

**Nota de diseño — columnas calculadas y triggers `BEFORE`:** `waste_log.total_loss_amount` es una columna `GENERATED`, y PostgreSQL procesa las columnas generadas *después* de disparar los triggers `BEFORE` de fila. Por ello, `NEW.total_loss_amount` es `NULL` dentro del trigger `trg_audit_high_waste_alert`, el cual recalcula el valor directamente como `qty_discarded × unit_cost_at_loss`. Esto previene fallas silenciosas documentadas en la evaluación de triggers.

---

## 7. Capa de Generación y Simulación de Datos

`src/data_generator.py` — Desarrollado exclusivamente con la librería estándar de Python 3.9+, sin dependencias externas, determinista mediante `--seed`.

Es un **motor de simulación de inventarios real**, no un simple generador de datos aleatorios. Las tiendas almacenan lotes físicos; el reabastecimiento respeta tiempos de entrega y vida útil; las ventas descuentan stock bajo la misma regla FEFO que aplica la base de datos; la demanda insatisfecha se registra como quiebre de stock; y las mermas son el resultado orgánico de lo que no logró rotar a tiempo.

Modelo de demanda multiplicativo:

```
demanda = tasa_base
        × indice_trafico_tienda
        × curva_dia_semana           (pico viernes y sábado)
        × factor_quincena            (15 y fin de mes, ciclo salarial peruano)
        × incremento_fin_semana      (por SKU: 2.15× cerveza, 1.70× comida lista)
        × elasticidad_temperatura    (curva anual de 15–27 °C de Lima)
        × ruido_lognormal            (positivo, asimétrico hacia la derecha como datos reales de POS)
```

Garantía de reproducibilidad: los desfases del calendario de despacho emplean CRC32 en lugar de la función `hash()` de Python, la cual se aleatoriza por proceso del intérprete.

Salida hacia `data/raw/`: `stores.csv`, `product_categories.csv`, `suppliers.csv`, `products.csv`, `waste_reasons.csv`, `goods_receipts.csv`, `batches.csv`, `waste_log.csv`, `daily_sales.csv`.

---

## 8. Capa de Pipeline ETL y Calidad de Datos

`src/etl_pipeline.py` — pandas, SQLAlchemy 2.x, psycopg2.

```
EXTRACCIÓN → TRANSFORMACIÓN → COMPUERTA DE CALIDAD (22 reglas) → CARGA → AUDITORÍA
```

**Modelo de Severidad:**

| Severidad | Reacción del Pipeline |
|---|---|
| `FATAL` | Aborta la ejecución (defecto estructural grave: dataset o columna faltante) |
| `ERROR` | Envía las filas anómalas a `data/quarantine/`, etiquetadas con la regla incumplida; continúa la ejecución |
| `WARNING` | Registra hallazgo en la bitácora de auditoría; la fila se carga normalmente |
| `INFO` | Registra una observación informativa |

**Propiedades de Carga:**
- Idempotencia: `INSERT ... ON CONFLICT DO UPDATE` sobre la clave natural de cada tabla.
- Claves naturales en los CSVs (`store_code`, `sku_code`, `grn_number`); resolución de claves subrogadas contra la base de datos tras cargar cada nivel jerárquico.
- Inserciones en bloques `executemany` (1,000 filas) dentro de una transacción por tabla, respetando dependencias de claves foráneas.
- Coerción segura de tipos con `errors="coerce"`.

**Trazabilidad y Auditoría:** `docs/etl_execution.log` (registro secuencial) y archivos `data/quarantine/<dataset>_rejected_<timestamp>.csv` por dataset afectado.

---

## 9. Capa de Infraestructura

`docker-compose.yml` — PostgreSQL 15 Alpine con volumen nombrado persistente, verificación de salud (healthcheck) y scripts de inicialización ordenados.

El orden de inicio se asegura mediante los nombres de montaje en el contenedor:

| Nombre de Montaje | Archivo Origen | Propósito |
|---|---|---|
| `01_schema_ddl_3nf.sql` | `sql/01_schema_ddl_3nf.sql` | DDL, restricciones e índices |
| `02_seed_data.sql` | `sql/02_seed_data.sql` | Datos maestros de referencia |
| `03_triggers_and_procedures.sql` | `sql/04_triggers_and_procedures.sql` | Procedimientos, triggers y datamart |

Los procedimientos y triggers se ejecutan deliberadamente **después** de los datos iniciales para asegurar que la vista materializada se cree con datos reales y no se evalúen triggers antes de tiempo.

Servicio opcional de pgAdmin disponible bajo el perfil Compose `tools`.

**Automatizadores de Tareas:** `Makefile` (GNU Make) y `scripts/run_project.ps1` (PowerShell nativo para Windows) ofrecen los mismos comandos: `init-db`, `generate`, `validate`, `run-etl`, `run-queries`, `refresh-datamart`, `test`, `status`, `psql`, `logs`, `destroy`.

---

## 10. Capa de Pruebas y Verificación

`sql/05_tests_business_logic.sql` — 19 aserciones distribuidas en cuatro grupos de negocio: orden de rotación FEFO, manejo de quiebres de stock y atomicidad, trigger antifraude de mermas, y barrido de caducidad e integridad del datamart.

Cada prueba corre dentro de un `SAVEPOINT` que se revierte, y la suite culmina en un `ROLLBACK` global, garantizando que sea 100% idempotente y no altere los datos operativos. Los fixtures utilizan el prefijo `TEST-` y se insertan desordenados cronológicamente para certificar que el procedimiento aplique FEFO por ordenamiento algorítmico real.

Cualquier aserción fallida detona una excepción que, mediante `ON_ERROR_STOP`, devuelve un código de salida distinto de cero para integración continua (CI).
