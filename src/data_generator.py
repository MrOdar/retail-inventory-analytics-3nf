#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Synthetic retail operations data generator (hyper-realistic, reproducible).

Simulates 60 continuous days of operations for a 4-store convenience network in
Lima, Peru, and exports clean CSV datasets into ``data/raw/``.

What makes the output realistic rather than random
--------------------------------------------------
1. **Demand seasonality.** Daily demand per SKU is the product of a base
   run-rate and multiplicative factors: day-of-week, store footprint, ambient
   temperature, Peruvian payday cycles (15th and month-end) and a lognormal
   noise term. Hot ready-to-eat food and beer peak on Fri/Sat/Sun; beverages
   scale with temperature; dairy is comparatively flat.
2. **A real inventory engine.** Stock is not invented per day: every store holds
   actual batches. Replenishment follows each supplier's lead time and a
   delivery calendar whose frequency is driven by shelf life (2-day empanadas
   are delivered daily, 21-day dairy every other day, ambient goods weekly).
   Sales consume batches under strict **FEFO** rotation, exactly like
   ``sp_process_fefo_sale`` does in the database.
3. **Waste emerges from the simulation.** Expiry waste is whatever FEFO failed
   to rotate in time -- it is never hard-coded. Damage, cold-chain failures and
   unknown shrinkage are injected as low-probability operational events.
4. **Stockouts are recorded.** Demand that cannot be served is lost revenue, so
   ``daily_sales`` reflects served units, not demand.

Deliberate data-quality anomalies
---------------------------------
With ``--inject-anomalies`` (default: on) a handful of rows are corrupted on
purpose -- impossible expiry dates, negative received quantities, dispatch-vs-
count discrepancies, unauthorized high-value waste. They exist so the ETL
quality gate in ``src/etl_pipeline.py`` has something real to catch, and the
exact number injected is printed in the run summary.

Usage
-----
    python src/data_generator.py
    python src/data_generator.py --days 90 --seed 7 --out data/raw
    python src/data_generator.py --no-inject-anomalies

Dependencies: Python 3.9+ standard library only (no third-party packages).
Author: Odar Javier Alcocer Vásquez (Information Systems Engineering - UPC)
"""

from __future__ import annotations

import argparse
import csv
import math
import random
import sys
import zlib
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_DAYS = 60
DEFAULT_SEED = 20261012
PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT_DIR = PROJECT_ROOT / "data" / "raw"

#: ISO weekday numbers (Mon=1 ... Sun=7) considered weekend in retail terms.
WEEKEND_ISO_DAYS = (5, 6, 7)  # Friday, Saturday, Sunday

#: Store staff used as ``logged_by_user`` / ``received_by_user``.
STORE_OPERATORS = {
    "TB-101": ["Odar Alcocer", "Mariana Ruiz", "Kevin Zárate"],
    "TB-102": ["Luis Andía", "Carla Benites"],
    "TB-103": ["Jhon Quispe", "Rosa Camargo"],
    "TB-104": ["Diego Ramos", "Silvia Paredes"],
}
STORE_AUTHORIZERS = {
    "TB-101": "Admin Tienda Miraflores",
    "TB-102": "Admin Tienda San Isidro",
    "TB-103": "Supervisor Zonal Sur",
    "TB-104": "Supervisor Zonal Oeste",
}


# ---------------------------------------------------------------------------
# Master data definitions
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Store:
    store_code: str
    store_name: str
    store_format: str
    district: str
    square_meters: float
    #: Multiplies every SKU's base demand (footfall / catchment proxy).
    traffic_index: float
    city: str = "Lima"
    is_active: bool = True


@dataclass(frozen=True)
class Category:
    category_code: str
    category_name: str
    storage_temp_type: str
    parent_category_code: Optional[str] = None


@dataclass(frozen=True)
class Supplier:
    supplier_code: str
    tax_id_ruc: str
    company_name: str
    contact_email: str
    contact_phone: str
    payment_terms_days: int
    lead_time_days: int
    is_active: bool = True


@dataclass(frozen=True)
class Product:
    sku_code: str
    barcode_ean13: str
    product_name: str
    category_code: str
    supplier_code: str
    unit_cost: float
    retail_price: float
    shelf_life_days: int
    is_perishable: bool
    min_safety_stock: int
    reorder_point: int
    #: Mean units sold per day in a store with traffic_index == 1.0.
    base_daily_demand: float
    #: Extra demand multiplier applied on Fri/Sat/Sun.
    weekend_uplift: float = 1.0
    #: Sensitivity to ambient temperature, per degree above the 20C baseline.
    temperature_elasticity: float = 0.0
    #: Probability (per store-day) of a physical damage event on this SKU.
    damage_rate: float = 0.004
    unit_of_measure: str = "UNIT"
    is_active: bool = True

    @property
    def delivery_interval_days(self) -> int:
        """Replenishment cadence derived from shelf life (shorter life = more often)."""
        if self.shelf_life_days <= 3:
            return 1
        if self.shelf_life_days <= 21:
            return 2
        if self.shelf_life_days <= 60:
            return 4
        return 7


@dataclass(frozen=True)
class WasteReason:
    reason_code: str
    reason_description: str
    loss_classification: str


STORES: Tuple[Store, ...] = (
    Store("TB-101", "Tambo Miraflores Shell", "FLAGSHIP", "Miraflores", 110.00, 1.35),
    Store("TB-102", "Tambo San Isidro Corp", "EXPRESS", "San Isidro", 65.00, 1.10),
    Store("TB-103", "Tambo Surco Primavera", "CONVENIENCE", "Santiago de Surco", 85.00, 0.95),
    Store("TB-104", "Tambo San Miguel Plaza", "CONVENIENCE", "San Miguel", 92.00, 0.85),
)

CATEGORIES: Tuple[Category, ...] = (
    Category("CAT-DAIRY", "Lácteos & Derivados", "REFRIGERATED"),
    Category("CAT-BAKERY", "Panadería & Embutidos", "AMBIENT"),
    Category("CAT-RTE", "Comidas Listas / Calientes", "HOT_HOLDING"),
    Category("CAT-BEV", "Bebidas & Gaseosas", "AMBIENT"),
    Category("CAT-BEER", "Cervezas & Licores", "AMBIENT"),
    Category("CAT-SNACK", "Snacks & Golosinas", "AMBIENT"),
)

SUPPLIERS: Tuple[Supplier, ...] = (
    Supplier("SUP-001", "20100017491", "Gloria S.A.",
             "pedidos@gloria.com.pe", "+51 1 470-5000", 45, 1),
    Supplier("SUP-002", "20100055237", "Alicorp S.A.A.",
             "distribucion@alicorp.com.pe", "+51 1 315-0800", 30, 2),
    Supplier("SUP-003", "20100108888", "San Fernando S.A.",
             "institucional@san-fernando.com.pe", "+51 1 213-5000", 30, 1),
    Supplier("SUP-004", "20255998711", "Bimbo del Perú S.A.",
             "preventa@bimbo.com.pe", "+51 1 219-0400", 30, 2),
    Supplier("SUP-005", "20100113610", "Corporación Lindley S.A.",
             "ventas@lindley.pe", "+51 1 411-2000", 30, 2),
    Supplier("SUP-006", "20332073093", "Backus & Johnston S.A.A.",
             "distribuidores@backus.pe", "+51 1 311-3000", 21, 2),
)

PRODUCTS: Tuple[Product, ...] = (
    # --- Dairy: medium shelf life, flat demand, cold-chain exposed -----------
    Product("SKU-1001", "7750100001011", "Yogurt Fresa 1L Gloria", "CAT-DAIRY",
            "SUP-001", 4.2000, 6.90, 21, True, 15, 35,
            base_daily_demand=9.0, weekend_uplift=1.10, damage_rate=0.005),
    Product("SKU-1002", "7750100001028", "Leche Fresca UHT 1L Gloria", "CAT-DAIRY",
            "SUP-001", 3.8000, 5.50, 45, True, 20, 50,
            base_daily_demand=14.0, weekend_uplift=1.05, damage_rate=0.004),
    Product("SKU-1003", "7750100001035", "Queso Fresco 500g Bonlé", "CAT-DAIRY",
            "SUP-001", 9.5000, 14.50, 21, True, 8, 20,
            base_daily_demand=5.0, weekend_uplift=1.25, damage_rate=0.006),
    # --- Bakery: short life, strong weekend/breakfast pattern ---------------
    Product("SKU-2001", "7750200002015", "Pan de Molde Blanco Bimbo 480g", "CAT-BAKERY",
            "SUP-004", 5.1000, 7.80, 14, True, 12, 30,
            base_daily_demand=8.0, weekend_uplift=1.15, damage_rate=0.007),
    Product("SKU-2004", "7750200002046", "Jamonada Inglesa 200g San Fernando", "CAT-BAKERY",
            "SUP-003", 6.4000, 9.90, 18, True, 10, 24,
            base_daily_demand=6.0, weekend_uplift=1.20, damage_rate=0.005),
    # --- Ready-to-eat: 2-day life, hot holding, heavy weekend uplift --------
    Product("SKU-2002", "7750200002022", "Empanada de Carne Tradicional", "CAT-RTE",
            "SUP-003", 2.3000, 4.90, 2, True, 25, 60,
            base_daily_demand=26.0, weekend_uplift=1.70, damage_rate=0.010),
    Product("SKU-2003", "7750200002039", "Sandwich Mixto Caliente", "CAT-RTE",
            "SUP-003", 2.8000, 5.50, 2, True, 20, 50,
            base_daily_demand=21.0, weekend_uplift=1.65, damage_rate=0.010),
    Product("SKU-2005", "7750200002053", "Pollo Broaster Porción", "CAT-RTE",
            "SUP-003", 6.9000, 12.90, 2, True, 15, 40,
            base_daily_demand=13.0, weekend_uplift=1.85, damage_rate=0.012),
    # --- Beverages: temperature-elastic ------------------------------------
    Product("SKU-3001", "7750300003019", "Gaseosa Inca Kola 500ml", "CAT-BEV",
            "SUP-005", 1.9000, 3.50, 180, False, 40, 100,
            base_daily_demand=34.0, weekend_uplift=1.25,
            temperature_elasticity=0.045, damage_rate=0.003),
    Product("SKU-3002", "7750300003026", "Jugo de Naranja 300ml Pulp", "CAT-BEV",
            "SUP-002", 1.7000, 2.90, 60, True, 15, 40,
            base_daily_demand=12.0, weekend_uplift=1.10,
            temperature_elasticity=0.035, damage_rate=0.004),
    Product("SKU-3003", "7750300003033", "Agua San Mateo 625ml", "CAT-BEV",
            "SUP-005", 1.2000, 2.50, 365, False, 50, 120,
            base_daily_demand=29.0, weekend_uplift=1.15,
            temperature_elasticity=0.055, damage_rate=0.002),
    # --- Beer: the sharpest weekend seasonality in the catalog -------------
    Product("SKU-4001", "7750400004016", "Cerveza Pilsen Callao 650ml", "CAT-BEER",
            "SUP-006", 4.5000, 7.50, 270, False, 36, 90,
            base_daily_demand=18.0, weekend_uplift=2.15,
            temperature_elasticity=0.050, damage_rate=0.004),
    Product("SKU-4002", "7750400004023", "Cerveza Cusqueña Trigo 330ml", "CAT-BEER",
            "SUP-006", 3.9000, 6.90, 270, False, 24, 60,
            base_daily_demand=11.0, weekend_uplift=2.05,
            temperature_elasticity=0.045, damage_rate=0.004),
    # --- Snacks: stable ambient baseline -----------------------------------
    Product("SKU-5001", "7750500005013", "Papas Lays Clásicas 145g", "CAT-SNACK",
            "SUP-002", 3.4000, 5.90, 120, False, 20, 50,
            base_daily_demand=15.0, weekend_uplift=1.30, damage_rate=0.006),
    Product("SKU-5002", "7750500005020", "Galleta Soda San Jorge 6pack", "CAT-SNACK",
            "SUP-002", 2.1000, 3.80, 150, False, 18, 45,
            base_daily_demand=10.0, weekend_uplift=1.05, damage_rate=0.004),
)

WASTE_REASONS: Tuple[WasteReason, ...] = (
    WasteReason("WR-EXP", "Vencimiento de fecha límite de consumo", "EXPIRATION"),
    WasteReason("WR-DMG", "Daño físico / rotura de empaque en manipulación", "DAMAGE"),
    WasteReason("WR-COLD", "Ruptura de cadena de frío en exhibidor", "COLD_CHAIN_FAIL"),
    WasteReason("WR-SHR", "Merma desconocida / Descuadre en conteo físico", "THEFT_SHRINKAGE"),
)

PRODUCTS_BY_SKU: Dict[str, Product] = {p.sku_code: p for p in PRODUCTS}
CATEGORIES_BY_CODE: Dict[str, Category] = {c.category_code: c for c in CATEGORIES}
SUPPLIERS_BY_CODE: Dict[str, Supplier] = {s.supplier_code: s for s in SUPPLIERS}


# ---------------------------------------------------------------------------
# Mutable simulation state
# ---------------------------------------------------------------------------

@dataclass
class Batch:
    """A physical lot of one SKU sitting in one store."""

    batch_code: str
    store_code: str
    sku_code: str
    grn_number: str
    initial_qty: float
    current_qty: float
    manufacturing_date: date
    expiration_date: date
    batch_status: str = "ACTIVE"
    unit_cost: float = 0.0


@dataclass
class ReceiptLine:
    grn_number: str
    store_code: str
    supplier_code: str
    dispatch_guide_ref: str
    received_timestamp: datetime
    received_by_user: str
    status: str
    sku_code: str
    qty_dispatched: float
    qty_accepted: float
    unit_purchase_cost: float
    temperature_celsius: float
    notes: str = ""


@dataclass
class WasteEvent:
    waste_code: str
    store_code: str
    sku_code: str
    batch_code: str
    reason_code: str
    qty_discarded: float
    unit_cost_at_loss: float
    logged_timestamp: datetime
    logged_by_user: str
    authorized_by: str
    notes: str


@dataclass
class SalesRow:
    store_code: str
    sku_code: str
    sale_date: date
    units_sold: float
    gross_revenue: float
    cost_of_goods_sold: float


@dataclass
class SimulationResult:
    receipts: List[ReceiptLine] = field(default_factory=list)
    batches: List[Batch] = field(default_factory=list)
    waste: List[WasteEvent] = field(default_factory=list)
    sales: List[SalesRow] = field(default_factory=list)
    stockout_units: float = 0.0
    stockout_events: int = 0
    lost_revenue: float = 0.0
    anomalies_injected: Dict[str, int] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Seasonality model
# ---------------------------------------------------------------------------

def stable_hash(*parts: str) -> int:
    """Deterministic cross-process hash.

    ``hash()`` on str is salted per interpreter process (PYTHONHASHSEED), which
    would silently break the reproducibility guarantee of a fixed ``--seed``.
    CRC32 is stable across runs, platforms and Python versions.
    """
    return zlib.crc32("|".join(parts).encode("utf-8"))


def ambient_temperature(day: date, rng: random.Random) -> float:
    """Simulate Lima's daily mean temperature (deg C).

    Lima's coastal climate oscillates between roughly 15C (August) and 27C
    (February). A sine wave peaking in mid-February reproduces that annual
    curve; a small Gaussian term adds day-to-day weather noise.
    """
    day_of_year = day.timetuple().tm_yday
    annual_mean = 20.0
    amplitude = 5.5
    # Peak around 15 February (day 46 of the year).
    phase = 2.0 * math.pi * (day_of_year - 46) / 365.0
    return round(annual_mean + amplitude * math.cos(phase) + rng.gauss(0.0, 1.1), 1)


def payday_factor(day: date) -> float:
    """Peruvian retail payday cycle: wages land mid-month and at month-end."""
    month_length = (date(day.year + (day.month // 12), (day.month % 12) + 1, 1)
                    - timedelta(days=1)).day
    if day.day in (15, 16, 17):
        return 1.18
    if day.day >= month_length - 1 or day.day <= 2:
        return 1.22
    # Pre-payday squeeze: the last stretch before wages arrive is the weakest.
    if 10 <= day.day <= 14 or 25 <= day.day <= month_length - 2:
        return 0.93
    return 1.0


def demand_for(product: Product, store: Store, day: date,
               temperature: float, rng: random.Random) -> int:
    """Expected units demanded for one (store, SKU, day), as an integer count.

    Multiplicative model:
        demand = base x traffic x weekday x payday x temperature x noise
    """
    iso_weekday = day.isoweekday()

    # Day-of-week shape. Fridays and Saturdays are the network's peak.
    weekday_shape = {
        1: 0.88,  # Monday
        2: 0.90,
        3: 0.95,
        4: 1.00,
        5: 1.22,  # Friday
        6: 1.30,  # Saturday
        7: 1.05,  # Sunday
    }[iso_weekday]

    factor = product.base_daily_demand * store.traffic_index * weekday_shape
    factor *= payday_factor(day)

    if iso_weekday in WEEKEND_ISO_DAYS:
        factor *= product.weekend_uplift

    if product.temperature_elasticity:
        factor *= 1.0 + product.temperature_elasticity * (temperature - 20.0)

    # Lognormal noise keeps demand positive and right-skewed, like real POS data.
    factor *= math.exp(rng.gauss(0.0, 0.22))

    return max(0, int(round(factor)))


# ---------------------------------------------------------------------------
# Inventory simulation engine
# ---------------------------------------------------------------------------

class RetailSimulator:
    """Runs the day-by-day store operations simulation."""

    def __init__(self, start_date: date, end_date: date, seed: int,
                 inject_anomalies: bool) -> None:
        self.start_date = start_date
        self.end_date = end_date
        self.rng = random.Random(seed)
        self.inject_anomalies = inject_anomalies

        self.result = SimulationResult()
        #: (store_code, sku_code) -> list of batches, kept FEFO-sorted.
        self.stock: Dict[Tuple[str, str], List[Batch]] = {}
        self._grn_seq = 0
        self._batch_seq = 0
        self._waste_seq = 0
        self._anomaly_budget = {
            "expiry_before_manufacturing": 2,
            "negative_received_qty": 2,
            "guide_vs_count_discrepancy": 6,
            "unauthorized_high_waste": 3,
        } if inject_anomalies else {k: 0 for k in (
            "expiry_before_manufacturing", "negative_received_qty",
            "guide_vs_count_discrepancy", "unauthorized_high_waste")}

    # -- identifier helpers -------------------------------------------------

    def _next_grn(self, day: date) -> str:
        self._grn_seq += 1
        return f"GRN-{day.year}-{self._grn_seq:05d}"

    def _next_batch_code(self, sku_code: str, day: date) -> str:
        self._batch_seq += 1
        return f"LOT-{sku_code.split('-')[1]}-{day:%y%m%d}-{self._batch_seq:05d}"

    def _next_waste_code(self, day: date) -> str:
        self._waste_seq += 1
        return f"WASTE-{day.year}-{self._waste_seq:05d}"

    def _spend_anomaly(self, kind: str) -> bool:
        """Consume one unit of an anomaly budget; False once exhausted."""
        if self._anomaly_budget.get(kind, 0) <= 0:
            return False
        self._anomaly_budget[kind] -= 1
        self.result.anomalies_injected[kind] = \
            self.result.anomalies_injected.get(kind, 0) + 1
        return True

    # -- main loop ----------------------------------------------------------

    def run(self) -> SimulationResult:
        self._seed_opening_inventory()

        day = self.start_date
        while day <= self.end_date:
            temperature = ambient_temperature(day, self.rng)
            self._receive_deliveries(day, temperature)
            self._sell_day(day, temperature)
            self._register_operational_waste(day, temperature)
            self._expire_batches(day)
            day += timedelta(days=1)

        self.result.batches = [b for batches in self.stock.values() for b in batches]
        self.result.batches.sort(key=lambda b: (b.store_code, b.sku_code, b.expiration_date))
        return self.result

    # -- opening inventory --------------------------------------------------

    def _seed_opening_inventory(self) -> None:
        """Day-zero stock so the first simulated days are not artificial stockouts.

        Opening lots carry no GRN: they are the physical count taken when the
        system went live, which is exactly how a real go-live looks.
        """
        for store in STORES:
            for product in PRODUCTS:
                target = self._target_stock(product, store)
                qty = max(1.0, round(target * self.rng.uniform(0.55, 0.95)))
                age = self.rng.randint(0, max(0, min(3, product.shelf_life_days - 1)))
                manufacturing = self.start_date - timedelta(days=age)
                expiration = manufacturing + timedelta(days=product.shelf_life_days)
                batch = Batch(
                    batch_code=self._next_batch_code(product.sku_code, self.start_date),
                    store_code=store.store_code,
                    sku_code=product.sku_code,
                    grn_number="",  # opening balance, no supplier document
                    initial_qty=qty,
                    current_qty=qty,
                    manufacturing_date=manufacturing,
                    expiration_date=expiration,
                    unit_cost=product.unit_cost,
                )
                self.stock.setdefault((store.store_code, product.sku_code), []).append(batch)

    def _target_stock(self, product: Product, store: Store) -> float:
        """Replenishment target: cover the delivery cycle plus safety stock."""
        expected_daily = product.base_daily_demand * store.traffic_index
        cover_days = product.delivery_interval_days + 1
        return expected_daily * cover_days + product.min_safety_stock

    # -- inbound logistics --------------------------------------------------

    def _receive_deliveries(self, day: date, temperature: float) -> None:
        """Group the day's replenishment into one GRN per (store, supplier)."""
        day_index = (day - self.start_date).days

        for store in STORES:
            # supplier_code -> list of (product, order_qty)
            orders: Dict[str, List[Tuple[Product, float]]] = {}

            for product in PRODUCTS:
                # Each (store, SKU) has a stable offset so deliveries spread out
                # across the week instead of all landing on the same day.
                offset = stable_hash(store.store_code, product.sku_code) \
                    % product.delivery_interval_days
                if day_index % product.delivery_interval_days != offset:
                    continue

                on_hand = self._on_hand(store.store_code, product.sku_code, day)
                target = self._target_stock(product, store)
                if on_hand >= target * 0.92:
                    continue  # no need to order yet

                order_qty = max(1.0, round(target - on_hand))
                orders.setdefault(product.supplier_code, []).append((product, order_qty))

            for supplier_code, lines in orders.items():
                self._post_receipt(store, SUPPLIERS_BY_CODE[supplier_code],
                                   lines, day, temperature)

    def _post_receipt(self, store: Store, supplier: Supplier,
                      lines: List[Tuple[Product, float]], day: date,
                      temperature: float) -> None:
        """Create one GRN header + lines and the resulting inventory batches."""
        grn_number = self._next_grn(day)
        operator = self.rng.choice(STORE_OPERATORS[store.store_code])
        # Deliveries arrive in the early morning logistics window.
        received_at = datetime.combine(
            day, datetime.min.time()) + timedelta(
            hours=self.rng.randint(5, 9), minutes=self.rng.randint(0, 59))
        guide_ref = (f"GR-{supplier.supplier_code.split('-')[1]}-"
                     f"{self.rng.randint(10000, 99999)}")

        header_status = "AUDITED" if self.rng.random() < 0.85 else "RECEIVED"
        # Lines are buffered because the header status is only final once every
        # line has been evaluated (a single short line flags the whole GRN).
        buffered: List[ReceiptLine] = []

        for product, order_qty in lines:
            qty_dispatched = order_qty
            qty_accepted = order_qty
            line_note = ""

            # -- Supplier fill-rate reality: short or damaged deliveries -----
            roll = self.rng.random()
            if roll < 0.06:
                # Partial rejection on arrival (damaged packaging / bad temp).
                rejected = max(1.0, round(qty_dispatched * self.rng.uniform(0.04, 0.18)))
                qty_accepted = max(0.0, qty_dispatched - rejected)
                line_note = f"{rejected:.0f} unidades rechazadas por daño en transporte"
                header_status = "DISCREPANT"
            elif roll < 0.10 and self._spend_anomaly("guide_vs_count_discrepancy"):
                # ANOMALY: physical count below the dispatch note without a
                # documented rejection -> hidden supplier shrinkage.
                missing = max(1.0, round(qty_dispatched * self.rng.uniform(0.05, 0.12)))
                qty_accepted = max(0.0, qty_dispatched - missing)
                line_note = "Descuadre no documentado entre guía de remisión y conteo físico"
                header_status = "DISCREPANT"

            # -- ANOMALY: negative quantity typed at the terminal ------------
            if self.rng.random() < 0.004 and self._spend_anomaly("negative_received_qty"):
                qty_accepted = -abs(qty_accepted) if qty_accepted else -1.0
                line_note = "Cantidad capturada con signo invertido en el terminal"

            # Cold-chain reading: refrigerated/hot-holding goods are measured.
            storage = CATEGORIES_BY_CODE[product.category_code].storage_temp_type
            if storage == "REFRIGERATED":
                reading = round(self.rng.gauss(4.5, 1.4), 1)
            elif storage == "FROZEN":
                reading = round(self.rng.gauss(-18.0, 1.5), 1)
            elif storage == "HOT_HOLDING":
                reading = round(self.rng.gauss(66.0, 4.0), 1)
            else:
                reading = round(temperature + self.rng.gauss(0.0, 1.0), 1)

            # Purchase cost drifts slightly around the catalog cost.
            unit_purchase_cost = round(
                product.unit_cost * self.rng.uniform(0.97, 1.05), 4)

            buffered.append(ReceiptLine(
                grn_number=grn_number,
                store_code=store.store_code,
                supplier_code=supplier.supplier_code,
                dispatch_guide_ref=guide_ref,
                received_timestamp=received_at,
                received_by_user=operator,
                status=header_status,
                sku_code=product.sku_code,
                qty_dispatched=round(qty_dispatched, 2),
                qty_accepted=round(qty_accepted, 2),
                unit_purchase_cost=unit_purchase_cost,
                temperature_celsius=reading,
                notes=line_note,
            ))

            # Only physically accepted goods become sellable stock.
            if qty_accepted > 0:
                self._create_batch(store, product, grn_number, qty_accepted,
                                   day, unit_purchase_cost)

        # The GRN header is one logical document: replicate its final status on
        # every denormalized line so the ETL can rebuild header + items safely.
        for line in buffered:
            line.status = header_status
        self.result.receipts.extend(buffered)

    def _create_batch(self, store: Store, product: Product, grn_number: str,
                      qty: float, day: date, unit_cost: float) -> None:
        """Materialize a received line as a FEFO-trackable lot."""
        # Suppliers deliver goods already a fraction of their life old.
        max_age = max(0, int(product.shelf_life_days * 0.25))
        age = self.rng.randint(0, max_age) if max_age else 0
        manufacturing = day - timedelta(days=age)
        expiration = manufacturing + timedelta(days=product.shelf_life_days)

        # -- ANOMALY: expiry printed before the manufacturing date -----------
        if self.rng.random() < 0.003 and self._spend_anomaly("expiry_before_manufacturing"):
            expiration = manufacturing - timedelta(days=self.rng.randint(1, 5))

        batch = Batch(
            batch_code=self._next_batch_code(product.sku_code, day),
            store_code=store.store_code,
            sku_code=product.sku_code,
            grn_number=grn_number,
            initial_qty=round(qty, 2),
            current_qty=round(qty, 2),
            manufacturing_date=manufacturing,
            expiration_date=expiration,
            unit_cost=unit_cost,
        )
        self.stock.setdefault((store.store_code, product.sku_code), []).append(batch)

    # -- stock helpers ------------------------------------------------------

    def _sellable_batches(self, store_code: str, sku_code: str,
                          day: date) -> List[Batch]:
        """ACTIVE, non-expired lots sorted FEFO (nearest expiry first)."""
        batches = [
            b for b in self.stock.get((store_code, sku_code), [])
            if b.batch_status == "ACTIVE" and b.current_qty > 0
            and b.expiration_date >= day
        ]
        batches.sort(key=lambda b: (b.expiration_date, b.batch_code))
        return batches

    def _on_hand(self, store_code: str, sku_code: str, day: date) -> float:
        return sum(b.current_qty for b in self._sellable_batches(store_code, sku_code, day))

    # -- outbound: sales ----------------------------------------------------

    def _sell_day(self, day: date, temperature: float) -> None:
        """Serve the day's demand out of stock under strict FEFO rotation."""
        for store in STORES:
            for product in PRODUCTS:
                demanded = demand_for(product, store, day, temperature, self.rng)
                if demanded <= 0:
                    continue

                remaining = float(demanded)
                units_served = 0.0
                cogs = 0.0

                for batch in self._sellable_batches(store.store_code,
                                                    product.sku_code, day):
                    if remaining <= 0:
                        break
                    taken = min(batch.current_qty, remaining)
                    batch.current_qty = round(batch.current_qty - taken, 2)
                    if batch.current_qty <= 0:
                        batch.batch_status = "DEPLETED"
                    remaining -= taken
                    units_served += taken
                    cogs += taken * batch.unit_cost

                if remaining > 0:
                    # Unserved demand is lost revenue, not a negative stock.
                    self.result.stockout_events += 1
                    self.result.stockout_units += remaining
                    self.result.lost_revenue += remaining * product.retail_price

                if units_served > 0:
                    self.result.sales.append(SalesRow(
                        store_code=store.store_code,
                        sku_code=product.sku_code,
                        sale_date=day,
                        units_sold=round(units_served, 2),
                        gross_revenue=round(units_served * product.retail_price, 2),
                        cost_of_goods_sold=round(cogs, 2),
                    ))

    # -- outbound: operational waste ---------------------------------------

    def _register_operational_waste(self, day: date, temperature: float) -> None:
        """Damage, cold-chain failures and unknown shrinkage (non-expiry waste)."""
        for store in STORES:
            for product in PRODUCTS:
                batches = self._sellable_batches(store.store_code, product.sku_code, day)
                if not batches:
                    continue

                storage = CATEGORIES_BY_CODE[product.category_code].storage_temp_type

                # 1) Physical damage / breakage in the aisle.
                if self.rng.random() < product.damage_rate:
                    self._discard(store, product, batches[-1], "WR-DMG", day,
                                  qty=self.rng.randint(1, 3),
                                  note="Rotura de empaque durante reposición en góndola.")

                # 2) Cold-chain failure: only on temperature-controlled goods,
                #    and markedly more likely on hot days.
                if storage in ("REFRIGERATED", "HOT_HOLDING", "FROZEN"):
                    heat_stress = max(0.0, (temperature - 22.0) / 10.0)
                    if self.rng.random() < 0.004 + 0.012 * heat_stress:
                        affected = batches[0]
                        self._discard(
                            store, product, affected, "WR-COLD", day,
                            qty=max(1, int(affected.current_qty *
                                           self.rng.uniform(0.15, 0.45))),
                            note=(f"Falla de equipo de frío/calor; lectura ambiente "
                                  f"{temperature:.1f} C."))

                # 3) Unknown shrinkage, reconciled at the weekly physical count.
                if day.isoweekday() == 7 and self.rng.random() < 0.05:
                    self._discard(store, product, batches[-1], "WR-SHR", day,
                                  qty=self.rng.randint(1, 4),
                                  note="Descuadre detectado en inventario cíclico semanal.")

    def _expire_batches(self, day: date) -> None:
        """End-of-day sweep: whatever FEFO failed to rotate becomes expiry waste."""
        for (store_code, sku_code), batches in self.stock.items():
            store = next(s for s in STORES if s.store_code == store_code)
            product = PRODUCTS_BY_SKU[sku_code]
            for batch in batches:
                if batch.batch_status != "ACTIVE" or batch.expiration_date > day:
                    continue
                if batch.current_qty > 0:
                    self._discard(
                        store, product, batch, "WR-EXP", day,
                        qty=batch.current_qty,
                        note=(f"Vencimiento el {batch.expiration_date:%Y-%m-%d}; "
                              f"lote no rotado a tiempo."),
                        force_full=True)
                batch.batch_status = "EXPIRED"
                batch.current_qty = 0.0

    def _discard(self, store: Store, product: Product, batch: Batch,
                 reason_code: str, day: date, qty: float, note: str,
                 force_full: bool = False) -> None:
        """Write a waste event off against a specific batch."""
        qty = min(float(qty), batch.current_qty) if not force_full else float(qty)
        if qty <= 0:
            return

        batch.current_qty = round(batch.current_qty - qty, 2)
        if batch.current_qty <= 0 and batch.batch_status == "ACTIVE":
            batch.batch_status = "DEPLETED"

        operator = self.rng.choice(STORE_OPERATORS[store.store_code])
        loss_amount = qty * batch.unit_cost

        # Losses above the S/ 50 materiality threshold need a named authorizer
        # (enforced in the database by trg_audit_high_waste_alert).
        if loss_amount > 50.0:
            authorizer = STORE_AUTHORIZERS[store.store_code]
            # -- ANOMALY: material loss posted without authorization ---------
            if self.rng.random() < 0.08 and self._spend_anomaly("unauthorized_high_waste"):
                authorizer = ""
        else:
            authorizer = (STORE_AUTHORIZERS[store.store_code]
                          if self.rng.random() < 0.6 else "")

        logged_at = datetime.combine(day, datetime.min.time()) + timedelta(
            hours=self.rng.randint(20, 23), minutes=self.rng.randint(0, 59))

        self.result.waste.append(WasteEvent(
            waste_code=self._next_waste_code(day),
            store_code=store.store_code,
            sku_code=product.sku_code,
            batch_code=batch.batch_code,
            reason_code=reason_code,
            qty_discarded=round(qty, 2),
            unit_cost_at_loss=round(batch.unit_cost, 4),
            logged_timestamp=logged_at,
            logged_by_user=operator,
            authorized_by=authorizer,
            notes=note,
        ))


# ---------------------------------------------------------------------------
# CSV export
# ---------------------------------------------------------------------------

def _write_csv(path: Path, header: Iterable[str], rows: Iterable[Iterable]) -> int:
    """Write a UTF-8 CSV with a header row; returns the number of data rows."""
    path.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(list(header))
        for row in rows:
            writer.writerow(list(row))
            count += 1
    return count


def export_datasets(result: SimulationResult, out_dir: Path) -> Dict[str, int]:
    """Export every dataset to ``out_dir`` and return {filename: row_count}."""
    counts: Dict[str, int] = {}

    # --- Reference / master data -------------------------------------------
    counts["stores.csv"] = _write_csv(
        out_dir / "stores.csv",
        ["store_code", "store_name", "store_format", "district", "city",
         "square_meters", "is_active"],
        ([s.store_code, s.store_name, s.store_format, s.district, s.city,
          f"{s.square_meters:.2f}", str(s.is_active).lower()] for s in STORES))

    counts["product_categories.csv"] = _write_csv(
        out_dir / "product_categories.csv",
        ["category_code", "category_name", "parent_category_code",
         "storage_temp_type"],
        ([c.category_code, c.category_name, c.parent_category_code or "",
          c.storage_temp_type] for c in CATEGORIES))

    counts["suppliers.csv"] = _write_csv(
        out_dir / "suppliers.csv",
        ["supplier_code", "tax_id_ruc", "company_name", "contact_email",
         "contact_phone", "payment_terms_days", "lead_time_days", "is_active"],
        ([s.supplier_code, s.tax_id_ruc, s.company_name, s.contact_email,
          s.contact_phone, s.payment_terms_days, s.lead_time_days,
          str(s.is_active).lower()] for s in SUPPLIERS))

    counts["products.csv"] = _write_csv(
        out_dir / "products.csv",
        ["sku_code", "barcode_ean13", "product_name", "category_code",
         "supplier_code", "unit_of_measure", "unit_cost", "retail_price",
         "shelf_life_days", "is_perishable", "min_safety_stock",
         "reorder_point", "is_active"],
        ([p.sku_code, p.barcode_ean13, p.product_name, p.category_code,
          p.supplier_code, p.unit_of_measure, f"{p.unit_cost:.4f}",
          f"{p.retail_price:.2f}", p.shelf_life_days,
          str(p.is_perishable).lower(), p.min_safety_stock, p.reorder_point,
          str(p.is_active).lower()] for p in PRODUCTS))

    counts["waste_reasons.csv"] = _write_csv(
        out_dir / "waste_reasons.csv",
        ["reason_code", "reason_description", "loss_classification"],
        ([w.reason_code, w.reason_description, w.loss_classification]
         for w in WASTE_REASONS))

    # --- Transactional data ------------------------------------------------
    counts["goods_receipts.csv"] = _write_csv(
        out_dir / "goods_receipts.csv",
        ["grn_number", "store_code", "supplier_code", "dispatch_guide_ref",
         "received_timestamp", "received_by_user", "status", "sku_code",
         "qty_dispatched", "qty_accepted", "unit_purchase_cost",
         "temperature_celsius", "notes"],
        ([r.grn_number, r.store_code, r.supplier_code, r.dispatch_guide_ref,
          r.received_timestamp.isoformat(sep=" "), r.received_by_user, r.status,
          r.sku_code, f"{r.qty_dispatched:.2f}", f"{r.qty_accepted:.2f}",
          f"{r.unit_purchase_cost:.4f}", f"{r.temperature_celsius:.1f}",
          r.notes] for r in result.receipts))

    counts["batches.csv"] = _write_csv(
        out_dir / "batches.csv",
        ["batch_code", "store_code", "sku_code", "grn_number", "initial_qty",
         "current_qty", "manufacturing_date", "expiration_date", "batch_status"],
        ([b.batch_code, b.store_code, b.sku_code, b.grn_number,
          f"{b.initial_qty:.2f}", f"{b.current_qty:.2f}",
          b.manufacturing_date.isoformat(), b.expiration_date.isoformat(),
          b.batch_status] for b in result.batches))

    counts["waste_log.csv"] = _write_csv(
        out_dir / "waste_log.csv",
        ["waste_code", "store_code", "sku_code", "batch_code", "reason_code",
         "qty_discarded", "unit_cost_at_loss", "logged_timestamp",
         "logged_by_user", "authorized_by", "notes"],
        ([w.waste_code, w.store_code, w.sku_code, w.batch_code, w.reason_code,
          f"{w.qty_discarded:.2f}", f"{w.unit_cost_at_loss:.4f}",
          w.logged_timestamp.isoformat(sep=" "), w.logged_by_user,
          w.authorized_by, w.notes] for w in result.waste))

    sales_sorted = sorted(result.sales, key=lambda s: (s.sale_date, s.store_code, s.sku_code))
    counts["daily_sales.csv"] = _write_csv(
        out_dir / "daily_sales.csv",
        ["store_code", "sku_code", "sale_date", "units_sold", "gross_revenue",
         "cost_of_goods_sold"],
        ([s.store_code, s.sku_code, s.sale_date.isoformat(),
          f"{s.units_sold:.2f}", f"{s.gross_revenue:.2f}",
          f"{s.cost_of_goods_sold:.2f}"] for s in sales_sorted))

    return counts


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def print_summary(result: SimulationResult, counts: Dict[str, int],
                  start_date: date, end_date: date, out_dir: Path) -> None:
    revenue = sum(s.gross_revenue for s in result.sales)
    cogs = sum(s.cost_of_goods_sold for s in result.sales)
    waste_cost = sum(w.qty_discarded * w.unit_cost_at_loss for w in result.waste)
    expiry_cost = sum(w.qty_discarded * w.unit_cost_at_loss
                      for w in result.waste if w.reason_code == "WR-EXP")

    print("=" * 74)
    print(" SYNTHETIC RETAIL DATASET GENERATED")
    print("=" * 74)
    print(f" Period            : {start_date} -> {end_date} "
          f"({(end_date - start_date).days + 1} days)")
    print(f" Network           : {len(STORES)} stores | {len(PRODUCTS)} SKUs | "
          f"{len(SUPPLIERS)} suppliers")
    print(f" Output directory  : {out_dir}")
    print("-" * 74)
    print(" FILES WRITTEN")
    for filename in sorted(counts):
        print(f"   {filename:<26} {counts[filename]:>8,} rows")
    def pct(numerator: float, denominator: float) -> str:
        """Format a percentage, degrading gracefully on a zero denominator."""
        return f"{100.0 * numerator / denominator:.2f}%" if denominator else "n/a"

    print("-" * 74)
    print(" SIMULATED BUSINESS OUTCOME")
    print(f"   Gross revenue            S/ {revenue:>12,.2f}")
    print(f"   Cost of goods sold       S/ {cogs:>12,.2f}")
    print(f"   Gross margin             S/ {revenue - cogs:>12,.2f}"
          f"   ({pct(revenue - cogs, revenue)} of revenue)")
    print(f"   Total waste cost         S/ {waste_cost:>12,.2f}"
          f"   ({pct(waste_cost, revenue)} of revenue)")
    print(f"   ... of which expiry      S/ {expiry_cost:>12,.2f}"
          f"   ({pct(expiry_cost, waste_cost)} of waste)")
    print(f"   Lost sales (stockouts)   S/ {result.lost_revenue:>12,.2f}"
          f"   ({result.stockout_units:,.0f} units across "
          f"{result.stockout_events:,} store-SKU-days)")
    if result.anomalies_injected:
        print("-" * 74)
        print(" DATA-QUALITY ANOMALIES INJECTED (for the ETL audit gate)")
        for kind in sorted(result.anomalies_injected):
            print(f"   {kind:<34} {result.anomalies_injected[kind]:>4}")
    print("=" * 74)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate a hyper-realistic synthetic retail operations dataset.")
    parser.add_argument("--days", type=int, default=DEFAULT_DAYS,
                        help=f"Number of simulated days (default: {DEFAULT_DAYS}).")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED,
                        help=f"PRNG seed for reproducibility (default: {DEFAULT_SEED}).")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT_DIR,
                        help="Output directory for the CSV datasets.")
    parser.add_argument("--end-date", type=str, default=None,
                        help="Last simulated day as YYYY-MM-DD (default: yesterday).")
    parser.add_argument("--no-inject-anomalies", dest="inject_anomalies",
                        action="store_false",
                        help="Generate a pristine dataset with no seeded data-quality defects.")
    parser.set_defaults(inject_anomalies=True)
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)

    if args.days < 1:
        print("ERROR: --days must be >= 1", file=sys.stderr)
        return 2

    if args.end_date:
        try:
            end_date = datetime.strptime(args.end_date, "%Y-%m-%d").date()
        except ValueError:
            print("ERROR: --end-date must be formatted as YYYY-MM-DD", file=sys.stderr)
            return 2
    else:
        end_date = date.today() - timedelta(days=1)

    start_date = end_date - timedelta(days=args.days - 1)

    simulator = RetailSimulator(start_date, end_date, args.seed, args.inject_anomalies)
    result = simulator.run()
    counts = export_datasets(result, args.out)
    print_summary(result, counts, start_date, end_date, args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
