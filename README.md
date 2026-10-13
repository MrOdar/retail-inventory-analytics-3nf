# Plataforma Analítica de Inventarios Retail y Control de Mermas — Arquitectura de Datos End-to-End

[![PostgreSQL](https://img.shields.io/badge/Base_de_Datos-PostgreSQL_15-336791?style=flat&logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![Docker](https://img.shields.io/badge/Infraestructura-Docker_Compose-2496ED?style=flat&logo=docker&logoColor=white)](docker-compose.yml)
[![Python](https://img.shields.io/badge/ETL-Python_3.9+_·_pandas_·_SQLAlchemy-3776AB?style=flat&logo=python&logoColor=white)](src/etl_pipeline.py)
[![Schema](https://img.shields.io/badge/Arquitectura-3NF_Relacional-orange?style=flat)](#3-arquitectura-relacional-3nf)
[![PL/pgSQL](https://img.shields.io/badge/Lógica_de_Negocio-Stored_Procedures_%26_Triggers-336791?style=flat)](sql/04_triggers_and_procedures.sql)
[![Tests](https://img.shields.io/badge/Pruebas-19_Aserciones_SQL-success?style=flat)](sql/05_tests_business_logic.sql)
[![Power BI](https://img.shields.io/badge/BI-Star_Schema_%26_DAX-F2C811?style=flat&logo=powerbi&logoColor=black)](bi/dax_measures.md)

Una plataforma integral de ingeniería de datos — infraestructura contenerizada, simulación y generación de datos sintéticos, pipeline ETL con compuerta de calidad estricta (quality gate), lógica transaccional de negocio en PostgreSQL 15, consultas SQL analíticas avanzadas y un datamart optimizado para Business Intelligence — diseñada para resolver el problema crítico del vencimiento de perecibles, descuadres de guías de remisión y fallas en la rotación FEFO/PEPS en tiendas de conveniencia y retail de alta frecuencia.

> **Hallazgo principal del dataset simulado de 60 días:** El 75.4% de todas las pérdidas monetarias corresponde a **mermas por vencimiento** — la categoría exacta de pérdida que una regla determinista de rotación FEFO puede mitigar estructuralmente. Análisis completo en [`docs/business_case_study.md`](docs/business_case_study.md).

---

## 1. Ejecutar la Plataforma Completa en un Solo Comando

```bash
docker compose up -d
```

Ese comando inicia PostgreSQL 15 y, en su primer arranque, aplica automáticamente el DDL en 3NF, los datos maestros (seed), los procedimientos almacenados, los triggers antifraude y el datamart materializado — en su estricto orden de dependencias.

Luego, ejecuta las capas de datos mediante el automatizador:

```bash
make all
```

El cual equivale paso a paso a:

```bash
make init-db      # 1. Inicia PostgreSQL y verifica que cada objeto haya sido creado
make generate     # 2. Simula 60 días de operaciones -> data/raw/*.csv
make run-etl      # 3. Extrae -> Valida 22 reglas de calidad -> Upsert en PostgreSQL
make run-queries  # 4. Ejecuta las 4 consultas analíticas avanzadas
```

### En Windows (PowerShell nativo sin `make`)

```powershell
.\scripts\run_project.ps1 all
```

El script de PowerShell expone las mismas acciones (`init-db`, `generate`, `run-etl`, `run-queries`, `validate`, `test`, `status`, `psql`, `logs`, `destroy`). Ejecuta `.\scripts\run_project.ps1 help` para ver la lista completa.

### Requisitos Previos

| Requisito | Necesario para |
|---|---|
| Docker Desktop | Servicio de base de datos PostgreSQL 15 |
| Python 3.9+ | Generador de datos y pipeline ETL |
| `pip install -r requirements.txt` | pandas · SQLAlchemy 2.x · psycopg2-binary |

*Nota: No se requiere base de datos activa para probar el motor de calidad de datos — `make validate` (o `.\scripts\run_project.ps1 validate`) ejecuta la extracción y evalúa las 22 reglas contra los CSVs generando el registro de auditoría sin necesidad de conexión.*

### Parámetros de Conexión

| Parámetro | Valor |
|---|---|
| Host / Puerto | `localhost:5433` (puerto 5433 para evitar colisiones con PostgreSQL local) |
| Base de Datos | `retail_inventory_db` |
| Usuario / Contraseña | `retail_admin` / `retail_secret` |
| DSN | `postgresql+psycopg2://retail_admin:retail_secret@localhost:5433/retail_inventory_db` |

Puedes sobreescribir cualquiera de estos valores con un archivo `.env` (ver [`.env.example`](.env.example)) o directamente desde la consola: `make run-etl DB_PORT=5555`.

---

## 2. Arquitectura del Repositorio

```
retail-inventory-analytics-3nf/
│
├── docker-compose.yml              # PostgreSQL 15 + pgAdmin opcional; scripts de inicio ordenados
├── Makefile                        # Automatizador de tareas: init-db, run-etl, run-queries, test
├── requirements.txt                # pandas, SQLAlchemy 2.x, psycopg2-binary
├── .env.example                    # Plantilla de variables de entorno (credenciales, DSN, parámetros)
│
├── sql/
│   ├── 01_schema_ddl_3nf.sql       # Esquema 3NF de 10 tablas, restricciones CHECK, índices parciales
│   ├── 02_seed_data.sql            # Datos maestros de referencia (tiendas, proveedores, SKUs, mermas)
│   ├── 03_analytical_queries.sql   # 4 consultas analíticas: CTEs + funciones de ventana (Window Functions)
│   ├── 04_triggers_and_procedures.sql  # Procedimiento FEFO, trigger antifraude, datamart materializado
│   └── 05_tests_business_logic.sql # 19 aserciones SQL; aisladas en SAVEPOINT, no destructivas
│
├── src/
│   ├── data_generator.py           # Motor de simulación de inventario -> CSV (solo librería estándar)
│   └── etl_pipeline.py             # Extracción -> 22 reglas de calidad -> UPSERT por bloques -> auditoría
│
├── data/
│   ├── raw/                        # Datasets CSV generados (ignorados en git, reproducibles)
│   └── quarantine/                 # Filas rechazadas por el quality gate, etiquetadas con la regla fallida
│
├── docs/
│   ├── architecture_spec.md        # Especificación técnica del modelo relacional
│   ├── business_case_study.md      # Caso ejecutivo de negocio: KPIs, composición de mermas, modelo de ROI
│   └── etl_execution.log           # Bitácora de auditoría de ejecución ETL (generada automáticamente)
│
├── bi/
│   └── dax_measures.md             # Esquema en estrella y fórmulas de medidas DAX para Power BI
│
└── scripts/
    └── run_project.ps1             # Automatizador nativo para Windows PowerShell (equivalente a Makefile)
```

---

## 3. Arquitectura Relacional (3NF)

El modelo elimina anomalías de inserción, actualización y eliminación, garantizando la integridad de dominio mediante restricciones `CHECK`, columnas calculadas almacenadas (`GENERATED ALWAYS AS`) e índices parciales.

```mermaid
erDiagram
    stores ||--o{ goods_receipt_headers : recibe
    stores ||--o{ inventory_batches : almacena
    stores ||--o{ waste_log : registra_merma
    stores ||--o{ daily_sales : registra_venta

    suppliers ||--o{ goods_receipt_headers : despacha

    product_categories ||--o{ products : categoriza
    product_categories ||--o{ product_categories : categoria_padre

    products ||--o{ goods_receipt_items : contiene
    products ||--o{ inventory_batches : genera_lotes
    products ||--o{ waste_log : genera_desperdicio
    products ||--o{ daily_sales : vende

    goods_receipt_headers ||--|{ goods_receipt_items : lineas_de_guia
    goods_receipt_items ||--o{ inventory_batches : crea_lote

    waste_reasons ||--o{ waste_log : clasifica
    inventory_batches ||--o{ waste_log : audita
```

| Tabla | Rol en el Sistema |
|---|---|
| `stores` | Tiendas multiformato (`CONVENIENCE`, `EXPRESS`, `FLAGSHIP`) |
| `suppliers` | Catálogo de proveedores con condiciones de pago y tiempos de entrega (lead times) |
| `product_categories` | Jerarquía recursiva con clasificación de temperatura de almacenamiento |
| `products` | Maestro de SKUs: costos, precios, vida útil, stock de seguridad y punto de reorden |
| `goods_receipt_headers` / `_items` | Auditoría de dos niveles: guía de remisión del proveedor vs. conteo físico en tienda |
| `inventory_batches` | **El núcleo FEFO** — control de vencimiento y existencias disponibles por lote |
| `waste_log` | Libro de bajas operativas: pérdida monetaria, motivo, operador y autorizador |
| `daily_sales` | Agregados de ventas POS por tienda × SKU × fecha |

### Integridad forzada en el motor de base de datos, no en la aplicación

- `discrepancy_qty` — `GENERATED ALWAYS AS (qty_dispatched - qty_accepted) STORED`: las mermas o faltantes del proveedor se convierten en una columna auditable directa, sin necesidad de conciliación manual.
- `total_loss_amount` — `GENERATED ALWAYS AS (qty_discarded × unit_cost_at_loss) STORED`: el valor de la merma jamás puede desalinearse de sus componentes de cálculo.
- `CHECK (current_qty <= initial_qty)`: hace matemáticamente imposible una violación de balance de masa en un lote.
- `CHECK (retail_price >= unit_cost)`: bloquea la inserción de SKUs con margen comercial negativo desde la base de datos.
- `idx_batches_expiry_status ... WHERE batch_status = 'ACTIVE'`: un **índice parcial** que optimiza la búsqueda FEFO para escanear únicamente inventario disponible para la venta.

---

## 4. Lógica Transaccional de Negocio — `sql/04`

### `sp_process_fefo_sale(store, product, qty, [date], [user], [register_sale])`

Aplica la rotación **FEFO (First-Expired, First-Out / Primero en Vencer, Primero en Salir)** en el único lugar donde no puede ser vulnerada: dentro de la transacción de la base de datos.

```sql
CALL sp_process_fefo_sale(1, 1, 5);
```

- Recorre los lotes en estado `ACTIVE` ordenados por `ORDER BY expiration_date ASC, batch_id ASC` — el vencimiento más próximo primero, utilizando FIFO como criterio de desempate.
- Descuenta existencias lote por lote; si un lote llega a cero, pasa automáticamente a estado `DEPLETED`.
- Bloquea las filas candidatas con `FOR UPDATE`, asegurando que dos terminales POS concurrentes no puedan sobrevender el mismo lote causando stock negativo.
- Excluye lotes vencidos: el inventario legalmente no comercializable no es considerado disponible.
- Genera la excepción **`SQLSTATE P0002` — "Stockout / Insufficient Inventory"** detallando tienda, SKU, cantidad solicitada y cantidad disponible real.
- Actualiza `daily_sales` calculando el **costo de ventas real (COGS)** a nivel de los lotes consumidos, en lugar de un promedio de catálogo — garantizando reportes de margen fidedignos.

### `trg_audit_high_waste_alert` — Control antifraude

Trigger `BEFORE INSERT OR UPDATE` sobre `waste_log`, asegurando segregación de funciones en mermas de alto valor:

| Control | Comportamiento |
|---|---|
| Pérdida > S/ 50 sin `authorized_by` | **Bloqueada** — `SQLSTATE P0004` |
| Pérdida > S/ 50 auto-autorizada por el mismo operador | **Bloqueada** — violaría segregación de funciones |
| `qty_discarded` superior al `initial_qty` del lote | **Bloqueada** — baja de stock físicamente imposible |
| Pérdida > S/ 50 debidamente autorizada | Permitida, emitiendo un aviso formal `HIGH-WASTE ALERT` |

> **Detalle técnico de implementación en PostgreSQL:** `total_loss_amount` es una columna `GENERATED`, y PostgreSQL calcula las columnas generadas *después* de ejecutar los triggers `BEFORE` de fila — por lo que `NEW.total_loss_amount` es `NULL` dentro del trigger. La función recalcula el importe directamente a partir de sus columnas base (`qty_discarded * unit_cost_at_loss`). Este diseño intencional previene errores silenciosos comunes en triggers sobre columnas calculadas.

### `sp_expire_overdue_batches([as_of_date], [authorizer])`

Barrido nocturno automatizado: identifica lotes `ACTIVE` cuya fecha de vencimiento ya pasó, los marca como `EXPIRED` y transfiere automáticamente el saldo restante a `waste_log` bajo el motivo `EXPIRATION` — la merma específica que la disciplina FEFO busca reducir al mínimo.

### `mv_store_category_waste_summary` + `fn_refresh_waste_datamart()`

Datamart materializado a grano de **tienda × categoría × mes**, diseñado para alimentar Power BI: ventas brutas, margen, merma desglosada por clasificación, `waste_intensity_pct`, `unit_shrinkage_pct` y `fefo_addressable_pct`.

```sql
SELECT fn_refresh_waste_datamart();  -- Refresco CONCURRENTLY por defecto
```

Respaldado por el índice único `uq_mv_waste_summary_grain`, requerido para ejecutar `REFRESH MATERIALIZED VIEW CONCURRENTLY` — permitiendo que los reportes y dashboards continúen consultando datos sin bloqueos de lectura (`ACCESS EXCLUSIVE`).

---

## 5. Consultas Analíticas Avanzadas — `sql/03`

```bash
make run-queries
```

| # | Consulta Analítica | Técnica SQL Empleada | Decisión de Negocio que Resuelve |
|---|---|---|---|
| 1 | **Matriz de Riesgo de Vencimiento FEFO** | `DENSE_RANK() OVER (PARTITION BY store, category)` | Qué lotes rematar con descuento *hoy*, priorizados por capital monetario en riesgo |
| 2 | **Auditoría de Descuadres GRN vs. Guía** | Agrupación y conciliación multinivel con CTEs | A qué proveedores emitir notas de crédito por faltantes sistemáticos de entrega |
| 3 | **Ratio de Intensidad de Mermas** | CTEs + ranking analítico de ventanas | Qué tienda está perdiendo más dinero por cada sol vendido |
| 4 | **DSI y Velocidad de Rotación vs. Quiebre** | Promedios móviles con funciones de ventana | Qué SKUs reabastecer de urgencia y cuáles pausar por sobrestock |

La Consulta 1 representa el núcleo operativo: reporta el **capital actualmente en riesgo** en lotes que vencerán en las próximas 48 horas y 5 días — en lugar de limitarse a reportar lo que ya se perdió. Esto transforma la gestión de mermas de una autopsia mensual a una lista de trabajo operativa diaria.

---

## 6. Generador de Datos Sintéticos — `src/data_generator.py`

```bash
python src/data_generator.py --days 60 --seed 20261012
```

Sin dependencias externas — desarrollado exclusivamente con la librería estándar de Python. Características que hacen que la simulación sea realista:

**1. Estacionalidad de demanda multiplicativa:**
`demanda = base × trafico_tienda × dia_semana × quincena × temperatura × ruido_lognormal`
Incrementos medidos en fin de semana (viernes a domingo) en el dataset generado:

| SKU | Promedio Lun–Jue | Promedio Vie–Dom | Incremento (Uplift) |
|---|---:|---:|---:|
| Cerveza Pilsen Callao 650ml | 14.6 unid. | 36.1 unid. | **2.47×** |
| Empanada de Carne (vida útil 2 días) | 27.4 unid. | 57.4 unid. | **2.09×** |
| Leche Fresca UHT 1L | 14.8 unid. | 19.5 unid. | 1.31× |

La curva térmica anual de Lima (15–27 °C) modula la elasticidad de bebidas y la probabilidad de fallas en la cadena de frío. Los ciclos peruanos de pago (quincenas y fin de mes) elevan el ticket promedio de compra.

**2. Motor de inventario real, no números inventados:** Cada tienda mantiene lotes físicos con fecha de caducidad. El reabastecimiento respeta los tiempos de entrega del proveedor según la vida útil del producto (empanadas de 2 días se reciben a diario; lácteos de 21 días interdiario; abarrotes semanalmente). Las ventas consumen inventario bajo **estricto criterio FEFO** — la misma regla que aplica `sp_process_fefo_sale`. La demanda no satisfecha se registra como quiebre de stock, evitando stocks negativos irreales.

**3. Mermas orgánicas derivadas de la simulación:** La merma por vencimiento surge de lo que la rotación FEFO no logró vender a tiempo — nunca de valores fijos arbitrarios. Daños físicos, fallas de frío y pérdidas desconocidas se inyectan como incidentes operativos estocásticos.

**4. Inyección deliberada de anomalías de calidad:** Se incluyen registros anómalos de manera controlada para someter a prueba la compuerta de validación ETL; el recuento exacto se detalla en el reporte final.

| Archivo Generado | Registros (60 días) |
|---|---:|
| `stores.csv`, `suppliers.csv`, `product_categories.csv`, `products.csv`, `waste_reasons.csv` | Catálogos maestros de referencia |
| `goods_receipts.csv` | 1,526 recepciones |
| `batches.csv` | 1,584 lotes |
| `waste_log.csv` | 128 registros de merma |
| `daily_sales.csv` | 3,590 registros de venta |

La reproducibilidad está garantizada: el cálculo de calendarios de despacho utiliza CRC32 en lugar del `hash()` nativo de Python (el cual introduce sales aleatorias por proceso y rompería la consistencia de la semilla).

---

## 7. Pipeline ETL y Auditoría de Calidad — `src/etl_pipeline.py`

```bash
python src/etl_pipeline.py --dry-run                 # Modo validación (quality gate sin BD)
python src/etl_pipeline.py --dsn "postgresql+psycopg2://..."   # Carga completa a base de datos
```

```
data/raw/*.csv
     │
     ▼
[ EXTRACCIÓN ]     Lectura tipada, validación de contrato de esquema y dtypes
     │
     ▼
[ TRANSFORMACIÓN ] Resolución de claves naturales, columnas derivadas, deduplicación
     │
     ▼
[ CALIDAD DE DATOS] 22 reglas × 4 severidades — FATAL aborta, ERROR envía a cuarentena
     │
     ▼
[ CARGA ]          UPSERT por bloques, una transacción por tabla en orden de FKs
     │
     ▼
[ AUDITORÍA ]      docs/etl_execution.log + data/quarantine/*.csv
```

### Batería de 22 Reglas de Calidad

| Regla | Severidad | Validación Realizada |
|---|---|---|
| `G01` | ERROR | Columna obligatoria nula o falla en conversión de tipo de dato |
| `G02` | ERROR | Clave natural duplicada en el archivo fuente |
| `R01`–`R03` | ERROR | Cantidad despachada no positiva, **cantidad recibida negativa**, sobre-recepción |
| `R04` | WARNING | **Descuadre entre guía de remisión y conteo físico** (merma de proveedor) |
| `R05` | WARNING | Temperatura de frío fuera del rango operativo admisible (−25 °C a 85 °C) |
| `B01` | ERROR | **`expiration_date` anterior a `manufacturing_date`** (fecha de caducidad ilógica) |
| `B02`–`B04` | ERROR | `initial_qty` no positivo, existencia negativa, balance de masa inconsistente |
| `B05` | WARNING | Vida útil observada difiere del maestro de SKUs (posible error de rotulado) |
| `B06` | WARNING | Lote en estado `ACTIVE` ya vencido que aún conserva existencias (falla FEFO) |
| `W01`–`W02` | ERROR | Cantidad desechada o costo unitario no positivos |
| `W03` | ERROR | **Merma de alto valor (> S/ 50) sin autorizador** — emula `trg_audit_high_waste_alert` |
| `W04` | ERROR | Merma de alto valor auto-autorizada por el mismo operador que registra |
| `S01`, `S03` | ERROR | Importes de venta negativos; discrepancia entre unidades e ingresos |
| `S02` | WARNING | Ingreso por venta inferior al costo (COGS) — margen negativo |
| `S04` | WARNING | Fecha de venta posterior a la fecha actual — descalibración del reloj POS |
| `F01` | ERROR/WARN | Clave foránea huérfana en referencias cruzadas entre tablas |

### Propiedades de Ingeniería del Pipeline

- **Idempotencia:** Toda carga ejecuta `INSERT ... ON CONFLICT DO UPDATE` sobre la clave natural, permitiendo reejecuciones seguras sin duplicidad de datos.
- **Claves Naturales en lugar de SERIALs:** Los CSVs transportan `store_code`, `sku_code`, `grn_number`; las claves subrogadas se resuelven contra la base de datos viva tras cargar cada nivel de dependencia — asegurando compatibilidad con datos precargados.
- **Cuarentena en lugar de coerción silenciosa:** Ninguna fila que viole una regla de nivel ERROR es forzada o alterada en la base de datos. Se redirige a `data/quarantine/` etiquetada con la regla infringida para su subsanación en origen.
- **Tipado seguro:** La ingesta inicial se realiza como texto (`str`) y se procesa columna por columna con `errors="coerce"`, convirtiendo errores en nulos detectables en lugar de alterar tipos de datos de forma inadvertida.
- **Alineación con triggers:** La regla `W03` intercepta preventivamente lo que `trg_audit_high_waste_alert` rechazaría en base de datos, generando un hallazgo legible en la bitácora en lugar de abortar la carga con una excepción genérica.

### Salida Ejemplo de Auditoría

```
PHASE 2/5 -- TRANSFORM & QUALITY CHECKS
[ERROR  ] R02 | goods_receipts.csv |      2 row(s) | Cantidad recibida negativa: conteo físico imposible
[WARNING] R04 | goods_receipts.csv |    105 row(s) | Descuadre entre guía y conteo físico (483.00 unidades faltantes)
[ERROR  ] B01 | batches.csv        |      2 row(s) | expiration_date es anterior a manufacturing_date
[ERROR  ] W03 | waste_log.csv      |      3 row(s) | Merma superior a S/ 50.00 sin usuario autorizador
[WARNING] F01 | waste_log.csv      |      1 row(s) | Referencia huérfana: batch_code no coincide con ningún lote activo

ETL EXECUTION SUMMARY
  Filas extraídas   : 6,863 a lo largo de 9 datasets
  Filas en cuarentena: 7
  Tasa de aceptación: 99.898%
  Hallazgos         : 0 FATAL | 3 ERROR | 2 WARNING | 0 INFO
```

---

## 8. Suite de Pruebas de Regresión — `sql/05`

```bash
make test
```

19 aserciones SQL que validan el comportamiento crítico de negocio. Cada prueba corre dentro de un bloque `SAVEPOINT` que se revierte (`ROLLBACK TO SAVEPOINT`), haciendo la suite **completamente idempotente y no destructiva** — segura de ejecutar en entornos con datos reales.

| Grupo | Comportamiento Validado |
|---|---|
| **T1 — Rotación FEFO** | El lote más próximo a vencer se consume primero; ventas multi-lote respetan el orden cronológico; lotes en cero pasan a `DEPLETED`; nunca se comercializan lotes vencidos |
| **T2 — Quiebres de Stock** | Existencias insuficientes detonan `P0002`; ventas fallidas dejan el inventario intacto (atomicidad); se rechazan cantidades negativas; `daily_sales` registra ingresos y COGS exactos |
| **T3 — Antifraude** | Se bloquea merma material no autorizada; se acepta y valoriza merma debidamente visada; mermas menores a S/ 50 no exigen firma; se bloquea la auto-autorización |
| **T4 — Barrido y Datamart** | El barrido nocturno reclasifica y da de baja existencias vencidas; la vista materializada existe, tiene clave única y carece de duplicados |

Los fixtures utilizan códigos con prefijo `TEST-` para evitar colisiones con datos operativos, y los lotes de prueba se insertan en **orden cronológico inverso** para forzar a que el procedimiento ordene por FEFO por lógica propia y no por el orden físico de inserción.

---

## 9. Inteligencia de Negocios (Power BI)

El modelo dimensional proyecta las tablas transaccionales hacia un esquema en estrella para reportes ejecutivos. Especificación completa de medidas DAX en [`bi/dax_measures.md`](bi/dax_measures.md).

| KPI | Fórmula / Definición |
|---|---|
| **Intensidad de Merma (%)** | `SUM(total_loss_amount) / SUM(gross_revenue)` |
| **Merma Abordable por FEFO (%)** | `Pérdida por VENCIMIENTO / Pérdida Total por Merma` |
| **Exposición Financiera (S/ en Riesgo)** | `SUM(current_qty × unit_cost)` para lotes que vencen en ≤ 5 días |
| **Cumplimiento de Entrega (Fill Rate %)** | `SUM(qty_accepted) / SUM(qty_dispatched)` |
| **Días de Venta de Inventario (DSI)** | `stock_actual / promedio_diario_ultimos_7_dias` |

Power BI se conecta directamente a `mv_store_category_waste_summary` en lugar de a las tablas transaccionales — garantizando que los tableros consulten una estructura preagregada e indexada en lugar de realizar escaneos masivos en la base de datos de producción.

---

## 10. Impacto y Resultados de Negocio

Resultados medidos sobre el dataset simulado de 60 días para 4 tiendas:

| Métrica de Negocio | Valor Obtenido |
|---|---:|
| Ventas Brutas Totales | S/ 416,525.40 |
| Margen Bruto Comercial | S/ 179,095.70 (43.00%) |
| Costo Total de Mermas | S/ 2,901.27 (0.70% de las ventas) |
| **Participación de Vencimiento en Mermas** | **75.4% — Mitigable vía disciplina FEFO** |
| Nivel de Servicio de Proveedores (Fill Rate) | 99.30% (483 unidades faltantes no entregadas) |
| Ventas Perdidas por Quiebre de Stock | S/ 4,171.60 |
| Dispersión de Intensidad de Merma entre Tiendas | 0.326% → 0.981% (**Variación de 3.0×**) |

**Proyección para un despliegue en cadena de 400 tiendas (escenario base):**
* **Beneficio Anual Estimado:** **S/ 1.68 Millones**
* **Periodo de Recuperación:** **12.8 meses**
* **Retorno sobre la Inversión (ROI a 3 años):** **109%**

Cada cifra cuenta con su etiqueta metodológica (MEDIDO, BENCHMARK o SUPUESTO), acompañada de análisis de sensibilidad y limitaciones en [`docs/business_case_study.md`](docs/business_case_study.md).

---

## 11. Stack Tecnológico

| Capa | Tecnología Empleada |
|---|---|
| **Base de Datos** | PostgreSQL 15 — Modelo 3NF, columnas generadas, índices parciales, vistas materializadas |
| **Lógica Transaccional** | PL/pgSQL — Stored procedures, triggers `BEFORE`, bloqueo concurrente de filas (`FOR UPDATE`) |
| **Generación de Datos** | Python 3.9+ (librería estándar) — Simulación determinista de inventario y demanda retail |
| **Pipeline ETL** | Python · pandas · SQLAlchemy 2.x · psycopg2 |
| **Infraestructura** | Docker Compose — Scripts de inicio ordenados, healthchecks y volúmenes persistentes |
| **Automatización** | GNU Make · PowerShell nativo para Windows |
| **Pruebas y Validación** | Aserciones SQL en transacciones aisladas (`SAVEPOINT`) |
| **Inteligencia de Negocios** | Power BI — Esquema en estrella, modelado dimensional, DAX avanzado |

---

## 12. Autor

**Odar Javier Alcocer Vásquez**  
*Estudiante de Ingeniería de Sistemas de Información — Universidad Peruana de Ciencias Aplicadas (UPC)*  
*AWS Academy Cloud Foundations · Rutgers University Supply Chain Analytics · SCRUMstudy SFC™*  

[LinkedIn](https://linkedin.com/in/odar-alcocer) · [GitHub @MrOdar](https://github.com/MrOdar)
