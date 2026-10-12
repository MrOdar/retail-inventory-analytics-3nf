#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Modular ETL pipeline with a blocking data-quality audit gate.

Moves the synthetic CSV datasets in ``data/raw/`` into the PostgreSQL 3NF
schema, enforcing a battery of quality rules between Extract and Load.

Architecture
------------
::

    data/raw/*.csv
         |
         v
    [ EXTRACT ]   typed read via pandas, schema + dtype contract per dataset
         |
         v
    [ TRANSFORM ] natural-key resolution, derived columns, deduplication
         |
         v
    [ QUALITY ]   22 rules across 4 severities; FATAL aborts, ERROR quarantines
         |          the offending rows, WARNING is reported only
         v
    [ LOAD ]      chunked UPSERT (INSERT ... ON CONFLICT) inside one
         |          transaction per table, in foreign-key dependency order
         v
    [ AUDIT ]     docs/etl_execution.log + data/quarantine/*.csv

Design decisions worth noting
-----------------------------
* **Natural keys, not surrogate keys.** The CSVs carry ``store_code``,
  ``sku_code``, ``grn_number`` -- never database SERIALs. The pipeline resolves
  them against the live database after each dependency level loads, so it is
  safe to re-run against a database that already holds the seed data.
* **Idempotency.** Every load is an UPSERT on the table's natural unique key, so
  running the pipeline twice yields the same database state, not duplicates.
* **Quarantine over silent coercion.** A row that violates an ERROR-severity
  rule is never "fixed" into the warehouse. It is written to
  ``data/quarantine/`` with the rule that rejected it, so operations can correct
  the source instead of the analyst inheriting dirty data.
* **The trigger is respected, not bypassed.** Waste rows that
  ``trg_audit_high_waste_alert`` would reject (material loss, no authorizer) are
  caught by rule ``W03`` and quarantined before they ever reach the database.

Usage
-----
    # Validate only -- no database connection required
    python src/etl_pipeline.py --dry-run

    # Full run against the Docker database
    python src/etl_pipeline.py --dsn postgresql+psycopg2://retail_admin:retail_secret@localhost:5433/retail_inventory_db

    # Or configure via environment
    set RETAIL_DB_DSN=postgresql+psycopg2://...
    python src/etl_pipeline.py

Dependencies: pandas, SQLAlchemy 2.x, psycopg2-binary (see requirements.txt).
``--dry-run`` needs pandas only.

Author: Odar Javier Alcocer Vásquez (Information Systems Engineering - UPC)
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

try:
    import pandas as pd
except ImportError:  # pragma: no cover - dependency guidance
    sys.stderr.write(
        "FATAL: pandas is required.\n"
        "       Install the pipeline dependencies with:  pip install -r requirements.txt\n")
    raise SystemExit(3)


# ---------------------------------------------------------------------------
# Paths & configuration
# ---------------------------------------------------------------------------

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RAW_DIR = PROJECT_ROOT / "data" / "raw"
DEFAULT_QUARANTINE_DIR = PROJECT_ROOT / "data" / "quarantine"
DEFAULT_LOG_PATH = PROJECT_ROOT / "docs" / "etl_execution.log"

#: Fallback DSN matching the credentials in docker-compose.yml.
DEFAULT_DSN = ("postgresql+psycopg2://retail_admin:retail_secret"
               "@localhost:5433/retail_inventory_db")

#: Rows per executemany batch on load.
LOAD_CHUNK_SIZE = 1_000

#: Materiality threshold mirrored from trg_audit_high_waste_alert (PEN).
WASTE_AUTHORIZATION_THRESHOLD = 50.00

LOGGER = logging.getLogger("retail.etl")


# ---------------------------------------------------------------------------
# Quality-rule result model
# ---------------------------------------------------------------------------

class Severity:
    """Quality-rule severities and the pipeline's reaction to each."""

    FATAL = "FATAL"      # Structural defect: abort the whole run.
    ERROR = "ERROR"      # Row-level defect: quarantine the offending rows.
    WARNING = "WARNING"  # Suspicious but loadable: report only.
    INFO = "INFO"        # Observation worth recording in the audit trail.


@dataclass
class Finding:
    """One quality-rule outcome against one dataset."""

    rule_id: str
    dataset: str
    severity: str
    description: str
    affected_rows: int
    sample: str = ""

    def __str__(self) -> str:
        line = (f"[{self.severity:<7}] {self.rule_id} | {self.dataset:<22} | "
                f"{self.affected_rows:>6} row(s) | {self.description}")
        if self.sample:
            line += f"\n                    sample: {self.sample}"
        return line


@dataclass
class ETLReport:
    """Aggregated outcome of one pipeline execution."""

    started_at: datetime = field(default_factory=datetime.now)
    finished_at: Optional[datetime] = None
    extracted: Dict[str, int] = field(default_factory=dict)
    quarantined: Dict[str, int] = field(default_factory=dict)
    loaded: Dict[str, int] = field(default_factory=dict)
    findings: List[Finding] = field(default_factory=list)
    aborted_reason: Optional[str] = None

    def add(self, finding: Finding) -> None:
        if finding.affected_rows > 0 or finding.severity == Severity.INFO:
            self.findings.append(finding)
            LOGGER.log(
                {Severity.FATAL: logging.CRITICAL,
                 Severity.ERROR: logging.ERROR,
                 Severity.WARNING: logging.WARNING,
                 Severity.INFO: logging.INFO}[finding.severity],
                str(finding))

    @property
    def counts_by_severity(self) -> Dict[str, int]:
        out: Dict[str, int] = {}
        for f in self.findings:
            out[f.severity] = out.get(f.severity, 0) + 1
        return out

    @property
    def duration_seconds(self) -> float:
        end = self.finished_at or datetime.now()
        return (end - self.started_at).total_seconds()


class FatalDataQualityError(RuntimeError):
    """Raised when a FATAL-severity rule fires; aborts the pipeline."""


# ---------------------------------------------------------------------------
# Dataset contracts
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class DatasetContract:
    """Declarative expectation for one input CSV."""

    filename: str
    required_columns: Tuple[str, ...]
    date_columns: Tuple[str, ...] = ()
    timestamp_columns: Tuple[str, ...] = ()
    numeric_columns: Tuple[str, ...] = ()
    boolean_columns: Tuple[str, ...] = ()
    #: Columns forming the dataset's natural primary key (duplicates rejected).
    natural_key: Tuple[str, ...] = ()
    #: False for optional reference files that may legitimately be absent.
    required: bool = True


CONTRACTS: Tuple[DatasetContract, ...] = (
    DatasetContract(
        filename="stores.csv",
        required_columns=("store_code", "store_name", "store_format",
                          "district", "city", "square_meters"),
        numeric_columns=("square_meters",),
        boolean_columns=("is_active",),
        natural_key=("store_code",),
    ),
    DatasetContract(
        filename="product_categories.csv",
        required_columns=("category_code", "category_name", "storage_temp_type"),
        natural_key=("category_code",),
    ),
    DatasetContract(
        filename="suppliers.csv",
        required_columns=("supplier_code", "tax_id_ruc", "company_name",
                          "payment_terms_days", "lead_time_days"),
        numeric_columns=("payment_terms_days", "lead_time_days"),
        boolean_columns=("is_active",),
        natural_key=("supplier_code",),
    ),
    DatasetContract(
        filename="products.csv",
        required_columns=("sku_code", "product_name", "category_code",
                          "unit_cost", "retail_price"),
        numeric_columns=("unit_cost", "retail_price", "shelf_life_days",
                         "min_safety_stock", "reorder_point"),
        boolean_columns=("is_perishable", "is_active"),
        natural_key=("sku_code",),
    ),
    DatasetContract(
        filename="waste_reasons.csv",
        required_columns=("reason_code", "reason_description",
                          "loss_classification"),
        natural_key=("reason_code",),
    ),
    DatasetContract(
        filename="goods_receipts.csv",
        required_columns=("grn_number", "store_code", "supplier_code",
                          "dispatch_guide_ref", "received_timestamp",
                          "received_by_user", "status", "sku_code",
                          "qty_dispatched", "qty_accepted",
                          "unit_purchase_cost"),
        timestamp_columns=("received_timestamp",),
        numeric_columns=("qty_dispatched", "qty_accepted",
                         "unit_purchase_cost", "temperature_celsius"),
        # One line per SKU per receipt document.
        natural_key=("grn_number", "sku_code"),
    ),
    DatasetContract(
        filename="batches.csv",
        required_columns=("batch_code", "store_code", "sku_code",
                          "initial_qty", "current_qty", "expiration_date",
                          "batch_status"),
        date_columns=("manufacturing_date", "expiration_date"),
        numeric_columns=("initial_qty", "current_qty"),
        natural_key=("batch_code",),
    ),
    DatasetContract(
        filename="waste_log.csv",
        required_columns=("waste_code", "store_code", "sku_code",
                          "reason_code", "qty_discarded", "unit_cost_at_loss",
                          "logged_timestamp", "logged_by_user"),
        timestamp_columns=("logged_timestamp",),
        numeric_columns=("qty_discarded", "unit_cost_at_loss"),
        natural_key=("waste_code",),
    ),
    DatasetContract(
        filename="daily_sales.csv",
        required_columns=("store_code", "sku_code", "sale_date", "units_sold",
                          "gross_revenue", "cost_of_goods_sold"),
        date_columns=("sale_date",),
        numeric_columns=("units_sold", "gross_revenue", "cost_of_goods_sold"),
        natural_key=("store_code", "sku_code", "sale_date"),
    ),
)

CONTRACTS_BY_NAME: Dict[str, DatasetContract] = {c.filename: c for c in CONTRACTS}


# ===========================================================================
# PHASE 1 -- EXTRACT
# ===========================================================================

class Extractor:
    """Reads and type-coerces the raw CSV datasets."""

    def __init__(self, raw_dir: Path, report: ETLReport) -> None:
        self.raw_dir = raw_dir
        self.report = report

    def run(self) -> Dict[str, "pd.DataFrame"]:
        LOGGER.info("PHASE 1/5 -- EXTRACT from %s", self.raw_dir)

        if not self.raw_dir.is_dir():
            raise FatalDataQualityError(
                f"Raw data directory not found: {self.raw_dir}. "
                f"Run 'python src/data_generator.py' first.")

        frames: Dict[str, pd.DataFrame] = {}
        for contract in CONTRACTS:
            path = self.raw_dir / contract.filename
            if not path.is_file():
                if contract.required:
                    raise FatalDataQualityError(
                        f"Required dataset missing: {path}")
                self.report.add(Finding(
                    "E00", contract.filename, Severity.WARNING,
                    "Optional dataset not present; skipped.", 1))
                continue

            frame = self._read_typed(path, contract)
            frames[contract.filename] = frame
            self.report.extracted[contract.filename] = len(frame)
            LOGGER.info("  extracted %-24s %7d rows x %d cols",
                        contract.filename, len(frame), len(frame.columns))

        return frames

    def _read_typed(self, path: Path, contract: DatasetContract) -> "pd.DataFrame":
        """Read one CSV, enforcing the column and dtype contract.

        Everything is read as ``str`` first, then coerced column by column with
        ``errors='coerce'``. That keeps a single malformed cell from silently
        retyping an entire column -- the bad value becomes NaT/NaN and is caught
        by the null-check rules downstream instead of corrupting the load.
        """
        frame = pd.read_csv(path, dtype=str, keep_default_na=True,
                            na_values=["", "NULL", "null", "None", "nan"],
                            encoding="utf-8")

        missing = [c for c in contract.required_columns if c not in frame.columns]
        if missing:
            raise FatalDataQualityError(
                f"{contract.filename}: schema contract violated, missing "
                f"column(s): {', '.join(missing)}")

        for column in contract.numeric_columns:
            if column in frame.columns:
                frame[column] = pd.to_numeric(frame[column], errors="coerce")

        for column in contract.date_columns:
            if column in frame.columns:
                frame[column] = pd.to_datetime(
                    frame[column], errors="coerce", format="%Y-%m-%d").dt.date

        for column in contract.timestamp_columns:
            if column in frame.columns:
                frame[column] = pd.to_datetime(frame[column], errors="coerce")

        for column in contract.boolean_columns:
            if column in frame.columns:
                frame[column] = (frame[column].astype(str).str.strip().str.lower()
                                 .map({"true": True, "t": True, "1": True,
                                       "yes": True, "false": False, "f": False,
                                       "0": False, "no": False})
                                 .fillna(True).astype(bool))

        # Trim stray whitespace on every remaining text column.
        for column in frame.columns:
            if frame[column].dtype == object:
                frame[column] = frame[column].apply(
                    lambda v: v.strip() if isinstance(v, str) else v)

        return frame


# ===========================================================================
# PHASE 2 & 3 -- TRANSFORM + QUALITY GATE
# ===========================================================================

class QualityGate:
    """Applies the quality rule battery and partitions clean vs quarantined rows."""

    def __init__(self, report: ETLReport) -> None:
        self.report = report
        #: filename -> DataFrame of rejected rows (with a _reject_rule column).
        self.quarantine: Dict[str, pd.DataFrame] = {}

    # -- helpers ------------------------------------------------------------

    @staticmethod
    def _sample(frame: "pd.DataFrame", columns: Sequence[str], limit: int = 3) -> str:
        """Render a few offending rows for the audit log."""
        cols = [c for c in columns if c in frame.columns]
        if frame.empty or not cols:
            return ""
        head = frame[cols].head(limit)
        return "; ".join(
            "{" + ", ".join(f"{c}={row[c]!r}" for c in cols) + "}"
            for _, row in head.iterrows())

    def _reject(self, filename: str, frame: "pd.DataFrame",
                mask: "pd.Series", rule_id: str) -> None:
        """Move the rows matching ``mask`` into the quarantine bucket."""
        rejected = frame.loc[mask].copy()
        if rejected.empty:
            return
        rejected["_reject_rule"] = rule_id
        rejected["_rejected_at"] = datetime.now().isoformat(timespec="seconds")
        existing = self.quarantine.get(filename)
        self.quarantine[filename] = (
            pd.concat([existing, rejected], ignore_index=True)
            if existing is not None else rejected)

    def _apply(self, filename: str, frame: "pd.DataFrame", mask: "pd.Series",
               rule_id: str, severity: str, description: str,
               sample_columns: Sequence[str]) -> "pd.DataFrame":
        """Evaluate one rule; quarantine or report according to severity.

        Returns the surviving rows (unchanged for WARNING/INFO severities).
        """
        mask = mask.fillna(False).astype(bool)
        affected = int(mask.sum())

        self.report.add(Finding(
            rule_id=rule_id, dataset=filename, severity=severity,
            description=description, affected_rows=affected,
            sample=self._sample(frame.loc[mask], sample_columns)))

        if affected == 0:
            return frame

        if severity == Severity.FATAL:
            raise FatalDataQualityError(
                f"{filename}: rule {rule_id} -- {description} ({affected} rows)")

        if severity == Severity.ERROR:
            self._reject(filename, frame, mask, rule_id)
            return frame.loc[~mask].copy()

        return frame

    # -- the rule battery ---------------------------------------------------

    def run(self, frames: Dict[str, "pd.DataFrame"]) -> Dict[str, "pd.DataFrame"]:
        LOGGER.info("PHASE 2/5 -- TRANSFORM & QUALITY CHECKS")
        clean: Dict[str, pd.DataFrame] = {}

        for filename, frame in frames.items():
            contract = CONTRACTS_BY_NAME[filename]
            frame = frame.copy()

            # -- G01: mandatory columns must not be null --------------------
            null_mask = frame[list(contract.required_columns)].isna().any(axis=1)
            frame = self._apply(
                filename, frame, null_mask, "G01", Severity.ERROR,
                "Mandatory column is null or failed type coercion.",
                contract.required_columns)

            # -- G02: the natural key must be unique ------------------------
            if contract.natural_key:
                dup_mask = frame.duplicated(subset=list(contract.natural_key),
                                            keep="first")
                frame = self._apply(
                    filename, frame, dup_mask, "G02", Severity.ERROR,
                    f"Duplicate natural key {contract.natural_key}; "
                    f"first occurrence kept.", contract.natural_key)

            clean[filename] = frame

        # -- Dataset-specific rules -----------------------------------------
        if "goods_receipts.csv" in clean:
            clean["goods_receipts.csv"] = self._check_goods_receipts(
                clean["goods_receipts.csv"])
        if "batches.csv" in clean:
            clean["batches.csv"] = self._check_batches(
                clean["batches.csv"], clean.get("products.csv"))
        if "waste_log.csv" in clean:
            clean["waste_log.csv"] = self._check_waste_log(clean["waste_log.csv"])
        if "daily_sales.csv" in clean:
            clean["daily_sales.csv"] = self._check_daily_sales(
                clean["daily_sales.csv"])

        # -- Referential integrity across datasets --------------------------
        clean = self._check_referential_integrity(clean)

        return clean

    def _check_goods_receipts(self, frame: "pd.DataFrame") -> "pd.DataFrame":
        """Rules R01-R04: supplier delivery note vs. physical count."""
        name = "goods_receipts.csv"

        # R01: a dispatched quantity must be strictly positive (DB CHECK).
        frame = self._apply(
            name, frame, frame["qty_dispatched"] <= 0, "R01", Severity.ERROR,
            "qty_dispatched must be strictly positive.",
            ("grn_number", "sku_code", "qty_dispatched"))

        # R02: a received quantity can be zero (full rejection) but never
        #      negative -- that is a terminal capture error, not a business fact.
        frame = self._apply(
            name, frame, frame["qty_accepted"] < 0, "R02", Severity.ERROR,
            "Negative qty_accepted: impossible physical count (capture error).",
            ("grn_number", "sku_code", "qty_accepted"))

        # R03: the store cannot accept more than the supplier dispatched.
        frame = self._apply(
            name, frame, frame["qty_accepted"] > frame["qty_dispatched"],
            "R03", Severity.ERROR,
            "qty_accepted exceeds qty_dispatched: over-receipt against the "
            "delivery note.",
            ("grn_number", "sku_code", "qty_dispatched", "qty_accepted"))

        # R04: dispatch-note vs. physical-count discrepancy. Loadable (the
        #      schema stores it as discrepancy_qty) but it is the single most
        #      important supplier-compliance signal, so it is reported.
        discrepancy = frame["qty_dispatched"] - frame["qty_accepted"]
        self.report.add(Finding(
            "R04", name, Severity.WARNING,
            "Dispatch guide vs. physical count discrepancy detected "
            f"(total short-received units: "
            f"{float(discrepancy[discrepancy > 0].sum()):.2f}).",
            int((discrepancy > 0).sum()),
            self._sample(frame.loc[discrepancy > 0],
                         ("grn_number", "sku_code", "qty_dispatched",
                          "qty_accepted"))))

        # R05: cold-chain reading outside the acceptable intake band.
        if "temperature_celsius" in frame.columns:
            out_of_band = (frame["temperature_celsius"].notna()
                           & ~frame["temperature_celsius"].between(-25.0, 85.0))
            self.report.add(Finding(
                "R05", name, Severity.WARNING,
                "Intake temperature reading outside the plausible -25C..85C band.",
                int(out_of_band.sum()),
                self._sample(frame.loc[out_of_band],
                             ("grn_number", "sku_code", "temperature_celsius"))))

        return frame

    def _check_batches(self, frame: "pd.DataFrame",
                       products: Optional["pd.DataFrame"]) -> "pd.DataFrame":
        """Rules B01-B05: batch lifecycle and shelf-life coherence."""
        name = "batches.csv"

        # B01: THE headline rule -- an expiry date before manufacturing is a
        #      physical impossibility (mislabelled lot or reversed fields).
        has_both = frame["manufacturing_date"].notna() & frame["expiration_date"].notna()
        impossible = has_both & (frame["expiration_date"] < frame["manufacturing_date"])
        frame = self._apply(
            name, frame, impossible, "B01", Severity.ERROR,
            "expiration_date precedes manufacturing_date: impossible shelf life.",
            ("batch_code", "sku_code", "manufacturing_date", "expiration_date"))

        # B02: quantities must be non-negative and current <= initial (DB CHECK).
        frame = self._apply(
            name, frame, frame["initial_qty"] <= 0, "B02", Severity.ERROR,
            "initial_qty must be strictly positive.",
            ("batch_code", "initial_qty"))
        frame = self._apply(
            name, frame, frame["current_qty"] < 0, "B03", Severity.ERROR,
            "Negative current_qty: stock cannot go below zero.",
            ("batch_code", "current_qty"))
        frame = self._apply(
            name, frame, frame["current_qty"] > frame["initial_qty"],
            "B04", Severity.ERROR,
            "current_qty exceeds initial_qty: violates the batch mass balance.",
            ("batch_code", "initial_qty", "current_qty"))

        # B05: observed shelf life should match the SKU master. A mismatch is
        #      usually a supplier mislabelling its production date.
        if products is not None and not products.empty:
            shelf = products.set_index("sku_code")["shelf_life_days"].to_dict()
            expected = frame["sku_code"].map(shelf)
            observed = pd.Series(
                [(e - m).days if (e is not None and m is not None
                                  and pd.notna(e) and pd.notna(m)) else None
                 for m, e in zip(frame["manufacturing_date"],
                                 frame["expiration_date"])],
                index=frame.index, dtype="object")
            mismatch = pd.Series(
                [o is not None and pd.notna(x) and abs(o - float(x)) > 1
                 for o, x in zip(observed, expected)], index=frame.index)
            self.report.add(Finding(
                "B05", name, Severity.WARNING,
                "Observed shelf life differs from the SKU master by more than "
                "1 day (possible supplier mislabelling).",
                int(mismatch.sum()),
                self._sample(frame.loc[mismatch],
                             ("batch_code", "sku_code", "manufacturing_date",
                              "expiration_date"))))

        # B06: an ACTIVE batch already past its expiry date is unsellable stock
        #      sitting on the shelf -- an operational alert, not a data defect.
        today = datetime.now().date()
        stale_active = ((frame["batch_status"] == "ACTIVE")
                        & frame["expiration_date"].notna()
                        & (frame["expiration_date"] < today)
                        & (frame["current_qty"] > 0))
        self.report.add(Finding(
            "B06", name, Severity.WARNING,
            "ACTIVE batch past its expiration date still holding stock: "
            "FEFO rotation failure requiring immediate write-off.",
            int(stale_active.sum()),
            self._sample(frame.loc[stale_active],
                         ("batch_code", "store_code", "expiration_date",
                          "current_qty"))))

        return frame

    def _check_waste_log(self, frame: "pd.DataFrame") -> "pd.DataFrame":
        """Rules W01-W03: waste quantities and the anti-fraud control."""
        name = "waste_log.csv"

        frame = self._apply(
            name, frame, frame["qty_discarded"] <= 0, "W01", Severity.ERROR,
            "qty_discarded must be strictly positive.",
            ("waste_code", "qty_discarded"))
        frame = self._apply(
            name, frame, frame["unit_cost_at_loss"] <= 0, "W02", Severity.ERROR,
            "unit_cost_at_loss must be strictly positive.",
            ("waste_code", "unit_cost_at_loss"))

        # W03: mirror of trg_audit_high_waste_alert. Catching it here produces a
        #      readable audit finding instead of an opaque SQLSTATE P0004 abort
        #      halfway through the load.
        loss_amount = frame["qty_discarded"] * frame["unit_cost_at_loss"]
        unauthorized = ((loss_amount > WASTE_AUTHORIZATION_THRESHOLD)
                        & (frame.get("authorized_by").isna()
                           if "authorized_by" in frame.columns
                           else pd.Series(True, index=frame.index)))
        frame["_loss_amount"] = loss_amount
        frame = self._apply(
            name, frame, unauthorized, "W03", Severity.ERROR,
            f"Waste above the S/ {WASTE_AUTHORIZATION_THRESHOLD:.2f} materiality "
            f"threshold declared without an authorizer (rejected by "
            f"trg_audit_high_waste_alert).",
            ("waste_code", "store_code", "logged_by_user", "_loss_amount"))

        # W04: self-authorization also breaches segregation of duties.
        if "authorized_by" in frame.columns:
            self_auth = ((frame["_loss_amount"] > WASTE_AUTHORIZATION_THRESHOLD)
                         & frame["authorized_by"].notna()
                         & (frame["authorized_by"].astype(str).str.strip().str.lower()
                            == frame["logged_by_user"].astype(str).str.strip().str.lower()))
            frame = self._apply(
                name, frame, self_auth, "W04", Severity.ERROR,
                "Material waste self-authorized by the logging operator "
                "(segregation-of-duties breach).",
                ("waste_code", "logged_by_user", "authorized_by", "_loss_amount"))

        return frame.drop(columns=["_loss_amount"], errors="ignore")

    def _check_daily_sales(self, frame: "pd.DataFrame") -> "pd.DataFrame":
        """Rules S01-S03: POS aggregate coherence."""
        name = "daily_sales.csv"

        frame = self._apply(
            name, frame,
            (frame["units_sold"] < 0) | (frame["gross_revenue"] < 0)
            | (frame["cost_of_goods_sold"] < 0),
            "S01", Severity.ERROR,
            "Negative sales figures: POS aggregates must be non-negative.",
            ("store_code", "sku_code", "sale_date", "units_sold"))

        # S02: selling below cost destroys margin. Legitimate during clearance
        #      markdowns, so it is a warning the category manager should see.
        below_cost = frame["gross_revenue"] < frame["cost_of_goods_sold"]
        self.report.add(Finding(
            "S02", name, Severity.WARNING,
            "Gross revenue below cost of goods sold: negative margin "
            "(clearance markdown or mispriced SKU).",
            int(below_cost.sum()),
            self._sample(frame.loc[below_cost],
                         ("store_code", "sku_code", "sale_date",
                          "gross_revenue", "cost_of_goods_sold"))))

        # S03: revenue without units (or units without revenue) is incoherent.
        incoherent = (((frame["units_sold"] == 0) & (frame["gross_revenue"] > 0))
                      | ((frame["units_sold"] > 0) & (frame["gross_revenue"] == 0)))
        frame = self._apply(
            name, frame, incoherent, "S03", Severity.ERROR,
            "Units and revenue disagree: one is zero while the other is not.",
            ("store_code", "sku_code", "sale_date", "units_sold",
             "gross_revenue"))

        # S04: future-dated sales indicate a POS clock or timezone fault.
        today = datetime.now().date()
        future = frame["sale_date"].notna() & (frame["sale_date"] > today)
        self.report.add(Finding(
            "S04", name, Severity.WARNING,
            "Sale dated in the future: POS clock or timezone misconfiguration.",
            int(future.sum()),
            self._sample(frame.loc[future], ("store_code", "sku_code", "sale_date"))))

        return frame

    def _check_referential_integrity(
            self, clean: Dict[str, "pd.DataFrame"]) -> Dict[str, "pd.DataFrame"]:
        """Rule F01: every foreign natural key must resolve to a parent row."""
        known: Dict[str, set] = {}
        for filename, key in (("stores.csv", "store_code"),
                              ("products.csv", "sku_code"),
                              ("suppliers.csv", "supplier_code"),
                              ("product_categories.csv", "category_code"),
                              ("waste_reasons.csv", "reason_code"),
                              ("batches.csv", "batch_code"),
                              ("goods_receipts.csv", "grn_number")):
            frame = clean.get(filename)
            known[key] = set(frame[key].dropna()) if frame is not None else set()

        # (dataset, column, parent key, severity) -- orphans are unloadable.
        checks: Tuple[Tuple[str, str, str, str], ...] = (
            ("products.csv", "category_code", "category_code", Severity.ERROR),
            ("products.csv", "supplier_code", "supplier_code", Severity.WARNING),
            ("goods_receipts.csv", "store_code", "store_code", Severity.ERROR),
            ("goods_receipts.csv", "supplier_code", "supplier_code", Severity.ERROR),
            ("goods_receipts.csv", "sku_code", "sku_code", Severity.ERROR),
            ("batches.csv", "store_code", "store_code", Severity.ERROR),
            ("batches.csv", "sku_code", "sku_code", Severity.ERROR),
            ("waste_log.csv", "store_code", "store_code", Severity.ERROR),
            ("waste_log.csv", "sku_code", "sku_code", Severity.ERROR),
            ("waste_log.csv", "reason_code", "reason_code", Severity.ERROR),
            ("waste_log.csv", "batch_code", "batch_code", Severity.WARNING),
            ("daily_sales.csv", "store_code", "store_code", Severity.ERROR),
            ("daily_sales.csv", "sku_code", "sku_code", Severity.ERROR),
        )

        for filename, column, parent_key, severity in checks:
            frame = clean.get(filename)
            if frame is None or column not in frame.columns:
                continue
            parents = known.get(parent_key, set())
            if not parents:
                continue
            orphan = frame[column].notna() & ~frame[column].isin(parents)
            clean[filename] = self._apply(
                filename, frame, orphan, "F01", severity,
                f"Orphan reference: {column} has no matching {parent_key} "
                f"in the loaded master data.",
                (column,))

        return clean


# ===========================================================================
# PHASE 4 -- LOAD
# ===========================================================================

#: Load order respects the foreign-key dependency graph of the 3NF schema.
LOAD_ORDER: Tuple[str, ...] = (
    "stores", "suppliers", "product_categories", "products", "waste_reasons",
    "goods_receipt_headers", "goods_receipt_items", "inventory_batches",
    "waste_log", "daily_sales",
)


class Loader:
    """Chunked, idempotent UPSERT loader for the PostgreSQL 3NF schema."""

    def __init__(self, dsn: str, report: ETLReport) -> None:
        self.report = report
        try:
            from sqlalchemy import create_engine, text  # noqa: F401
        except ImportError:  # pragma: no cover - dependency guidance
            raise FatalDataQualityError(
                "SQLAlchemy is required to load. Install with "
                "'pip install -r requirements.txt', or re-run with --dry-run.")
        from sqlalchemy import create_engine
        # future=True keeps 2.x semantics explicit; pre_ping survives a
        # container that was still booting when the pipeline started.
        self.engine = create_engine(dsn, future=True, pool_pre_ping=True)

    # -- key resolution -----------------------------------------------------

    def _lookup(self, connection, table: str, key_column: str,
                id_column: str) -> Dict[str, int]:
        """Build {natural key -> surrogate id} from the live database."""
        from sqlalchemy import text
        rows = connection.execute(
            text(f"SELECT {key_column}, {id_column} FROM {table}")).fetchall()
        return {row[0]: row[1] for row in rows}

    def _upsert(self, connection, table: str, columns: Sequence[str],
                conflict_columns: Sequence[str], rows: List[Dict[str, Any]],
                update_columns: Optional[Sequence[str]] = None) -> int:
        """INSERT ... ON CONFLICT DO UPDATE in chunks; returns rows submitted."""
        from sqlalchemy import text
        if not rows:
            return 0

        update_columns = update_columns if update_columns is not None else [
            c for c in columns if c not in conflict_columns]

        column_list = ", ".join(columns)
        placeholders = ", ".join(f":{c}" for c in columns)
        conflict_list = ", ".join(conflict_columns)

        if update_columns:
            assignments = ", ".join(f"{c} = EXCLUDED.{c}" for c in update_columns)
            action = f"DO UPDATE SET {assignments}"
        else:
            action = "DO NOTHING"

        statement = text(
            f"INSERT INTO {table} ({column_list}) VALUES ({placeholders}) "
            f"ON CONFLICT ({conflict_list}) {action}")

        submitted = 0
        for start in range(0, len(rows), LOAD_CHUNK_SIZE):
            chunk = rows[start:start + LOAD_CHUNK_SIZE]
            connection.execute(statement, chunk)
            submitted += len(chunk)
        return submitted

    @staticmethod
    def _records(frame: "pd.DataFrame", mapping: Dict[str, str]) -> List[Dict[str, Any]]:
        """Project a DataFrame into DB-column-keyed dicts, NaN -> None."""
        subset = frame[[src for src in mapping if src in frame.columns]].copy()
        subset = subset.rename(columns=mapping)
        subset = subset.astype(object).where(pd.notna(subset), None)
        return subset.to_dict(orient="records")

    # -- orchestration ------------------------------------------------------

    def run(self, clean: Dict[str, "pd.DataFrame"]) -> None:
        LOGGER.info("PHASE 3/5 -- LOAD into PostgreSQL")

        with self.engine.begin() as connection:
            self._load_stores(connection, clean.get("stores.csv"))
            self._load_suppliers(connection, clean.get("suppliers.csv"))
            self._load_categories(connection, clean.get("product_categories.csv"))
            self._load_products(connection, clean.get("products.csv"))
            self._load_waste_reasons(connection, clean.get("waste_reasons.csv"))

            store_ids = self._lookup(connection, "stores", "store_code", "store_id")
            supplier_ids = self._lookup(connection, "suppliers", "supplier_code",
                                        "supplier_id")
            product_ids = self._lookup(connection, "products", "sku_code", "product_id")
            reason_ids = self._lookup(connection, "waste_reasons", "reason_code",
                                      "waste_reason_id")

            self._load_receipts(connection, clean.get("goods_receipts.csv"),
                                store_ids, supplier_ids, product_ids)
            self._load_batches(connection, clean.get("batches.csv"),
                               store_ids, product_ids)
            self._load_waste(connection, clean.get("waste_log.csv"),
                             store_ids, product_ids, reason_ids)
            self._load_sales(connection, clean.get("daily_sales.csv"),
                             store_ids, product_ids)

        self._refresh_datamart()

    def _log_loaded(self, table: str, count: int) -> None:
        self.report.loaded[table] = count
        LOGGER.info("  loaded   %-24s %7d rows", table, count)

    # -- master data --------------------------------------------------------

    def _load_stores(self, connection, frame: Optional["pd.DataFrame"]) -> None:
        if frame is None or frame.empty:
            return
        rows = self._records(frame, {
            "store_code": "store_code", "store_name": "store_name",
            "store_format": "store_format", "district": "district",
            "city": "city", "square_meters": "square_meters",
            "is_active": "is_active"})
        columns = list(rows[0].keys())
        self._log_loaded("stores", self._upsert(
            connection, "stores", columns, ["store_code"], rows))

    def _load_suppliers(self, connection, frame: Optional["pd.DataFrame"]) -> None:
        if frame is None or frame.empty:
            return
        rows = self._records(frame, {
            "supplier_code": "supplier_code", "tax_id_ruc": "tax_id_ruc",
            "company_name": "company_name", "contact_email": "contact_email",
            "contact_phone": "contact_phone",
            "payment_terms_days": "payment_terms_days",
            "lead_time_days": "lead_time_days", "is_active": "is_active"})
        columns = list(rows[0].keys())
        self._log_loaded("suppliers", self._upsert(
            connection, "suppliers", columns, ["supplier_code"], rows))

    def _load_categories(self, connection, frame: Optional["pd.DataFrame"]) -> None:
        """Two passes: insert the rows, then wire up the self-referencing parent."""
        if frame is None or frame.empty:
            return
        from sqlalchemy import text

        rows = self._records(frame, {
            "category_code": "category_code", "category_name": "category_name",
            "storage_temp_type": "storage_temp_type"})
        columns = list(rows[0].keys())
        loaded = self._upsert(connection, "product_categories", columns,
                              ["category_code"], rows)

        if "parent_category_code" in frame.columns:
            parent_rows = [
                {"child": child, "parent": parent}
                for child, parent in zip(frame["category_code"],
                                         frame["parent_category_code"])
                if isinstance(parent, str) and parent]
            if parent_rows:
                connection.execute(text(
                    "UPDATE product_categories c "
                    "   SET parent_category_id = p.category_id "
                    "  FROM product_categories p "
                    " WHERE c.category_code = :child "
                    "   AND p.category_code = :parent"), parent_rows)

        self._log_loaded("product_categories", loaded)

    def _load_products(self, connection, frame: Optional["pd.DataFrame"]) -> None:
        if frame is None or frame.empty:
            return
        from sqlalchemy import text

        category_ids = self._lookup(connection, "product_categories",
                                    "category_code", "category_id")
        prepared = frame.copy()
        prepared["category_id"] = prepared["category_code"].map(category_ids)
        prepared = prepared[prepared["category_id"].notna()]
        if prepared.empty:
            return

        rows = self._records(prepared, {
            "sku_code": "sku_code", "barcode_ean13": "barcode_ean13",
            "product_name": "product_name", "category_id": "category_id",
            "unit_of_measure": "unit_of_measure", "unit_cost": "unit_cost",
            "retail_price": "retail_price", "shelf_life_days": "shelf_life_days",
            "is_perishable": "is_perishable",
            "min_safety_stock": "min_safety_stock",
            "reorder_point": "reorder_point", "is_active": "is_active"})
        for row in rows:
            row["category_id"] = int(row["category_id"])
        columns = list(rows[0].keys())
        self._log_loaded("products", self._upsert(
            connection, "products", columns, ["sku_code"], rows))

    def _load_waste_reasons(self, connection, frame: Optional["pd.DataFrame"]) -> None:
        if frame is None or frame.empty:
            return
        rows = self._records(frame, {
            "reason_code": "reason_code",
            "reason_description": "reason_description",
            "loss_classification": "loss_classification"})
        columns = list(rows[0].keys())
        self._log_loaded("waste_reasons", self._upsert(
            connection, "waste_reasons", columns, ["reason_code"], rows))

    # -- transactional data -------------------------------------------------

    def _load_receipts(self, connection, frame: Optional["pd.DataFrame"],
                       store_ids: Dict[str, int], supplier_ids: Dict[str, int],
                       product_ids: Dict[str, int]) -> None:
        """Split the denormalized receipt lines back into header + item tables."""
        if frame is None or frame.empty:
            return
        from sqlalchemy import text

        # --- Headers: one row per GRN document ----------------------------
        headers = (frame.sort_values("grn_number")
                        .drop_duplicates(subset=["grn_number"], keep="first")
                        .copy())
        headers["store_id"] = headers["store_code"].map(store_ids)
        headers["supplier_id"] = headers["supplier_code"].map(supplier_ids)
        headers = headers[headers["store_id"].notna() & headers["supplier_id"].notna()]

        header_rows = self._records(headers, {
            "grn_number": "grn_number", "store_id": "store_id",
            "supplier_id": "supplier_id",
            "dispatch_guide_ref": "dispatch_guide_ref",
            "received_timestamp": "received_timestamp",
            "received_by_user": "received_by_user", "status": "status"})
        for row in header_rows:
            row["store_id"] = int(row["store_id"])
            row["supplier_id"] = int(row["supplier_id"])
        if header_rows:
            self._log_loaded("goods_receipt_headers", self._upsert(
                connection, "goods_receipt_headers", list(header_rows[0].keys()),
                ["grn_number"], header_rows))

        # --- Items: resolve the header surrogate key, then upsert ----------
        grn_ids = self._lookup(connection, "goods_receipt_headers",
                               "grn_number", "grn_id")
        items = frame.copy()
        items["grn_id"] = items["grn_number"].map(grn_ids)
        items["product_id"] = items["sku_code"].map(product_ids)
        items = items[items["grn_id"].notna() & items["product_id"].notna()]
        if items.empty:
            return

        # goods_receipt_items has no natural unique constraint, so a plain
        # INSERT would duplicate lines on a re-run. The (grn_id, product_id)
        # pair is the real business key: delete those lines, then insert.
        connection.execute(text(
            "DELETE FROM goods_receipt_items "
            " WHERE grn_id = :grn_id AND product_id = :product_id"),
            [{"grn_id": int(g), "product_id": int(p)}
             for g, p in zip(items["grn_id"], items["product_id"])])

        item_rows = self._records(items, {
            "grn_id": "grn_id", "product_id": "product_id",
            "qty_dispatched": "qty_dispatched", "qty_accepted": "qty_accepted",
            "unit_purchase_cost": "unit_purchase_cost",
            "temperature_celsius": "temperature_celsius"})
        for row in item_rows:
            row["grn_id"] = int(row["grn_id"])
            row["product_id"] = int(row["product_id"])

        columns = list(item_rows[0].keys())
        statement = text(
            f"INSERT INTO goods_receipt_items ({', '.join(columns)}) "
            f"VALUES ({', '.join(':' + c for c in columns)})")
        for start in range(0, len(item_rows), LOAD_CHUNK_SIZE):
            connection.execute(statement, item_rows[start:start + LOAD_CHUNK_SIZE])
        self._log_loaded("goods_receipt_items", len(item_rows))

    def _load_batches(self, connection, frame: Optional["pd.DataFrame"],
                      store_ids: Dict[str, int],
                      product_ids: Dict[str, int]) -> None:
        if frame is None or frame.empty:
            return
        from sqlalchemy import text

        prepared = frame.copy()
        prepared["store_id"] = prepared["store_code"].map(store_ids)
        prepared["product_id"] = prepared["sku_code"].map(product_ids)
        prepared = prepared[prepared["store_id"].notna()
                            & prepared["product_id"].notna()]
        if prepared.empty:
            return

        # Link each batch to its originating receipt line. The generator emits
        # one receipt line per (grn_number, sku_code), so that pair resolves to
        # exactly one grn_item_id.
        link_rows = connection.execute(text(
            "SELECT h.grn_number, i.product_id, i.grn_item_id "
            "  FROM goods_receipt_items i "
            "  JOIN goods_receipt_headers h ON h.grn_id = i.grn_id")).fetchall()
        item_index = {(row[0], row[1]): row[2] for row in link_rows}

        prepared["grn_item_id"] = [
            item_index.get((grn, int(pid))) if isinstance(grn, str) and grn else None
            for grn, pid in zip(prepared.get("grn_number",
                                             pd.Series("", index=prepared.index)),
                                prepared["product_id"])]

        rows = self._records(prepared, {
            "batch_code": "batch_code", "store_id": "store_id",
            "product_id": "product_id", "grn_item_id": "grn_item_id",
            "initial_qty": "initial_qty", "current_qty": "current_qty",
            "manufacturing_date": "manufacturing_date",
            "expiration_date": "expiration_date",
            "batch_status": "batch_status"})
        for row in rows:
            row["store_id"] = int(row["store_id"])
            row["product_id"] = int(row["product_id"])
            row["grn_item_id"] = (int(row["grn_item_id"])
                                  if row["grn_item_id"] is not None else None)

        columns = list(rows[0].keys())
        self._log_loaded("inventory_batches", self._upsert(
            connection, "inventory_batches", columns, ["batch_code"], rows))

    def _load_waste(self, connection, frame: Optional["pd.DataFrame"],
                    store_ids: Dict[str, int], product_ids: Dict[str, int],
                    reason_ids: Dict[str, int]) -> None:
        if frame is None or frame.empty:
            return

        batch_ids = self._lookup(connection, "inventory_batches",
                                 "batch_code", "batch_id")
        prepared = frame.copy()
        prepared["store_id"] = prepared["store_code"].map(store_ids)
        prepared["product_id"] = prepared["sku_code"].map(product_ids)
        prepared["waste_reason_id"] = prepared["reason_code"].map(reason_ids)
        prepared["batch_id"] = (prepared["batch_code"].map(batch_ids)
                                if "batch_code" in prepared.columns else None)
        prepared = prepared[prepared["store_id"].notna()
                            & prepared["product_id"].notna()
                            & prepared["waste_reason_id"].notna()]
        if prepared.empty:
            return

        rows = self._records(prepared, {
            "waste_code": "waste_code", "store_id": "store_id",
            "product_id": "product_id", "batch_id": "batch_id",
            "waste_reason_id": "waste_reason_id",
            "qty_discarded": "qty_discarded",
            "unit_cost_at_loss": "unit_cost_at_loss",
            "logged_timestamp": "logged_timestamp",
            "logged_by_user": "logged_by_user", "authorized_by": "authorized_by",
            "notes": "notes"})
        for row in rows:
            row["store_id"] = int(row["store_id"])
            row["product_id"] = int(row["product_id"])
            row["waste_reason_id"] = int(row["waste_reason_id"])
            row["batch_id"] = (int(row["batch_id"])
                               if row.get("batch_id") is not None else None)

        columns = list(rows[0].keys())
        self._log_loaded("waste_log", self._upsert(
            connection, "waste_log", columns, ["waste_code"], rows))

    def _load_sales(self, connection, frame: Optional["pd.DataFrame"],
                    store_ids: Dict[str, int],
                    product_ids: Dict[str, int]) -> None:
        if frame is None or frame.empty:
            return

        prepared = frame.copy()
        prepared["store_id"] = prepared["store_code"].map(store_ids)
        prepared["product_id"] = prepared["sku_code"].map(product_ids)
        prepared = prepared[prepared["store_id"].notna()
                            & prepared["product_id"].notna()]
        if prepared.empty:
            return

        rows = self._records(prepared, {
            "store_id": "store_id", "product_id": "product_id",
            "sale_date": "sale_date", "units_sold": "units_sold",
            "gross_revenue": "gross_revenue",
            "cost_of_goods_sold": "cost_of_goods_sold"})
        for row in rows:
            row["store_id"] = int(row["store_id"])
            row["product_id"] = int(row["product_id"])

        columns = list(rows[0].keys())
        self._log_loaded("daily_sales", self._upsert(
            connection, "daily_sales", columns,
            ["store_id", "product_id", "sale_date"], rows))

    def _refresh_datamart(self) -> None:
        """Rebuild the Power BI datamart once the load has committed.

        REFRESH MATERIALIZED VIEW CONCURRENTLY cannot run inside a transaction
        block, so this uses an AUTOCOMMIT connection.
        """
        from sqlalchemy import text
        LOGGER.info("PHASE 4/5 -- REFRESH analytical datamart")
        try:
            with self.engine.connect() as connection:
                autocommit = connection.execution_options(
                    isolation_level="AUTOCOMMIT")
                message = autocommit.execute(
                    text("SELECT fn_refresh_waste_datamart(TRUE)")).scalar()
            LOGGER.info("  %s", message)
        except Exception as exc:  # noqa: BLE001 - never fail a good load on this
            LOGGER.warning(
                "  datamart refresh skipped: %s "
                "(apply sql/04_triggers_and_procedures.sql to enable it)", exc)


# ===========================================================================
# PHASE 5 -- AUDIT TRAIL
# ===========================================================================

def configure_logging(log_path: Path, verbose: bool) -> None:
    """Log to both the console and the append-only audit file."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    LOGGER.setLevel(logging.DEBUG if verbose else logging.INFO)
    LOGGER.handlers.clear()

    file_handler = logging.FileHandler(log_path, mode="a", encoding="utf-8")
    file_handler.setFormatter(logging.Formatter(
        "%(asctime)s | %(levelname)-8s | %(message)s", "%Y-%m-%d %H:%M:%S"))
    LOGGER.addHandler(file_handler)

    console = logging.StreamHandler(sys.stdout)
    console.setFormatter(logging.Formatter("%(levelname)-8s | %(message)s"))
    LOGGER.addHandler(console)


def write_quarantine(quarantine: Dict[str, "pd.DataFrame"],
                     out_dir: Path, report: ETLReport) -> None:
    """Persist rejected rows so operations can correct the source systems."""
    if not quarantine:
        return
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = report.started_at.strftime("%Y%m%d_%H%M%S")
    for filename, frame in quarantine.items():
        target = out_dir / f"{Path(filename).stem}_rejected_{stamp}.csv"
        frame.to_csv(target, index=False, encoding="utf-8")
        report.quarantined[filename] = len(frame)
        LOGGER.warning("  quarantined %-22s %6d row(s) -> %s",
                       filename, len(frame), target.name)


def write_summary(report: ETLReport, dry_run: bool) -> None:
    """Emit the closing audit block that makes the run auditable after the fact."""
    report.finished_at = datetime.now()
    severities = report.counts_by_severity
    total_extracted = sum(report.extracted.values())
    total_quarantined = sum(report.quarantined.values())
    total_loaded = sum(report.loaded.values())

    LOGGER.info("PHASE 5/5 -- AUDIT SUMMARY")
    LOGGER.info("=" * 78)
    LOGGER.info("ETL EXECUTION SUMMARY%s", "  (DRY RUN -- nothing loaded)" if dry_run else "")
    LOGGER.info("  started           : %s",
                report.started_at.strftime("%Y-%m-%d %H:%M:%S"))
    LOGGER.info("  duration          : %.2f s", report.duration_seconds)
    LOGGER.info("  rows extracted    : %d across %d dataset(s)",
                total_extracted, len(report.extracted))
    LOGGER.info("  rows quarantined  : %d", total_quarantined)
    LOGGER.info("  rows loaded       : %d across %d table(s)",
                total_loaded, len(report.loaded))
    LOGGER.info("  acceptance rate   : %s",
                f"{100.0 * (total_extracted - total_quarantined) / total_extracted:.3f}%"
                if total_extracted else "n/a")
    LOGGER.info("  findings          : %d FATAL | %d ERROR | %d WARNING | %d INFO",
                severities.get(Severity.FATAL, 0), severities.get(Severity.ERROR, 0),
                severities.get(Severity.WARNING, 0), severities.get(Severity.INFO, 0))

    if report.extracted:
        LOGGER.info("  -- extracted by dataset --")
        for name in sorted(report.extracted):
            LOGGER.info("     %-26s %8d", name, report.extracted[name])
    if report.loaded:
        LOGGER.info("  -- loaded by table --")
        for name in LOAD_ORDER:
            if name in report.loaded:
                LOGGER.info("     %-26s %8d", name, report.loaded[name])

    anomalies = [f for f in report.findings
                 if f.severity in (Severity.ERROR, Severity.FATAL, Severity.WARNING)]
    if anomalies:
        LOGGER.info("  -- anomalies detected --")
        for finding in anomalies:
            LOGGER.info("     %-7s %-5s %-24s %6d  %s", finding.severity,
                        finding.rule_id, finding.dataset, finding.affected_rows,
                        finding.description)
    elif report.aborted_reason:
        # The run never reached the full rule battery, so "all rules passed"
        # would be an actively misleading thing to write into an audit log.
        LOGGER.info("  quality rules incomplete: the run aborted before finishing.")
    else:
        LOGGER.info("  no anomalies detected: all quality rules passed.")

    if report.aborted_reason:
        LOGGER.critical("  RUN ABORTED: %s", report.aborted_reason)
    LOGGER.info("=" * 78)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="ETL pipeline: data/raw CSV -> PostgreSQL 3NF schema, "
                    "with a blocking data-quality audit gate.")
    parser.add_argument("--raw-dir", type=Path, default=DEFAULT_RAW_DIR,
                        help="Directory holding the input CSV datasets.")
    parser.add_argument("--dsn", type=str,
                        default=os.environ.get("RETAIL_DB_DSN", DEFAULT_DSN),
                        help="SQLAlchemy DSN (or set RETAIL_DB_DSN).")
    parser.add_argument("--log-file", type=Path, default=DEFAULT_LOG_PATH,
                        help="Append-only audit log path.")
    parser.add_argument("--quarantine-dir", type=Path,
                        default=DEFAULT_QUARANTINE_DIR,
                        help="Directory for rejected rows.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Run extract + quality checks only; never connect "
                             "to the database.")
    parser.add_argument("--fail-on-error", action="store_true",
                        help="Exit non-zero if any ERROR-severity rule fired "
                             "(useful as a CI quality gate).")
    parser.add_argument("--verbose", action="store_true",
                        help="Enable DEBUG-level logging.")
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    configure_logging(args.log_file, args.verbose)

    report = ETLReport()
    LOGGER.info("")
    LOGGER.info("#" * 78)
    LOGGER.info("# RETAIL INVENTORY ETL PIPELINE -- run started %s",
                report.started_at.strftime("%Y-%m-%d %H:%M:%S"))
    LOGGER.info("#" * 78)

    gate = QualityGate(report)
    exit_code = 0

    try:
        frames = Extractor(args.raw_dir, report).run()
        clean = gate.run(frames)
        write_quarantine(gate.quarantine, args.quarantine_dir, report)

        if args.dry_run:
            LOGGER.info("PHASE 3/5 -- LOAD skipped (--dry-run)")
        else:
            Loader(args.dsn, report).run(clean)

    except FatalDataQualityError as exc:
        report.aborted_reason = str(exc)
        LOGGER.critical("FATAL: %s", exc)
        exit_code = 1
    except Exception as exc:  # noqa: BLE001 - the audit log must record it
        report.aborted_reason = f"{type(exc).__name__}: {exc}"
        LOGGER.critical("UNHANDLED FAILURE: %s: %s", type(exc).__name__, exc,
                        exc_info=args.verbose)
        exit_code = 1

    write_summary(report, args.dry_run)

    if exit_code == 0 and args.fail_on_error:
        errors = report.counts_by_severity.get(Severity.ERROR, 0)
        if errors:
            LOGGER.error("--fail-on-error: %d ERROR-severity finding(s).", errors)
            exit_code = 1

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
