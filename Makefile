# =============================================================================
# Retail Inventory & Waste Reduction Analytics -- task runner
# =============================================================================
# Quick start:
#     make up          # start PostgreSQL 15 (schema + seed + triggers applied)
#     make generate    # build 60 days of synthetic operations data
#     make run-etl     # load CSV -> PostgreSQL with the quality gate
#     make run-queries # execute the 4 analytical queries
#
# Or everything at once:  make all
#
# Windows without make: use the PowerShell equivalent, scripts/run_project.ps1
# =============================================================================

# --- Configuration (override on the command line: make run-etl DB_PORT=5555) --
COMPOSE        ?= docker compose
SERVICE        ?= postgres
DB_USER        ?= retail_admin
DB_PASSWORD    ?= retail_secret
DB_NAME        ?= retail_inventory_db
DB_HOST        ?= localhost
DB_PORT        ?= 5433
PYTHON         ?= python
SIM_DAYS       ?= 60
SIM_SEED       ?= 20261012

DSN            := postgresql+psycopg2://$(DB_USER):$(DB_PASSWORD)@$(DB_HOST):$(DB_PORT)/$(DB_NAME)
PSQL           := $(COMPOSE) exec -T -e PGPASSWORD=$(DB_PASSWORD) $(SERVICE) \
                  psql -v ON_ERROR_STOP=1 -U $(DB_USER) -d $(DB_NAME)

.DEFAULT_GOAL  := help
.PHONY: help all up down destroy init-db wait-db generate run-etl validate \
        run-queries refresh-datamart test psql logs status clean-data deps

# -----------------------------------------------------------------------------
help: ## Show this help
	@echo "Retail Inventory & Waste Reduction Analytics -- available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Database: $(DB_USER)@$(DB_HOST):$(DB_PORT)/$(DB_NAME)"

all: init-db generate run-etl run-queries ## Full pipeline: infra -> data -> ETL -> analytics

# --- Infrastructure ----------------------------------------------------------
up: ## Start PostgreSQL (applies DDL + seed + triggers on first boot)
	$(COMPOSE) up -d $(SERVICE)

down: ## Stop containers, keep the data volume
	$(COMPOSE) down

destroy: ## Stop containers AND delete the data volume (irreversible)
	$(COMPOSE) down -v

wait-db: ## Block until the database reports healthy
	@echo "Waiting for PostgreSQL to accept connections..."
	@for i in $$(seq 1 40); do \
	  if $(COMPOSE) exec -T $(SERVICE) pg_isready -U $(DB_USER) -d $(DB_NAME) >/dev/null 2>&1; then \
	    echo "PostgreSQL is ready."; exit 0; \
	  fi; \
	  sleep 2; \
	done; \
	echo "ERROR: PostgreSQL did not become ready in time." >&2; exit 1

init-db: up wait-db ## Start the database and confirm the schema is in place
	@echo "--- Objects created ---"
	@$(PSQL) -c "\dt"
	@$(PSQL) -c "SELECT routine_name, routine_type FROM information_schema.routines WHERE routine_schema = 'public' ORDER BY routine_name;"
	@$(PSQL) -c "SELECT tgname AS trigger_name, relname AS table_name FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid WHERE NOT t.tgisinternal;"

# --- Data --------------------------------------------------------------------
deps: ## Install the Python dependencies
	$(PYTHON) -m pip install -r requirements.txt

generate: ## Generate the synthetic CSV datasets into data/raw/
	$(PYTHON) src/data_generator.py --days $(SIM_DAYS) --seed $(SIM_SEED)

validate: ## Run the quality gate only -- no database needed
	$(PYTHON) src/etl_pipeline.py --dry-run

run-etl: ## Extract -> validate -> load the CSV datasets into PostgreSQL
	$(PYTHON) src/etl_pipeline.py --dsn "$(DSN)"

# --- Analytics ---------------------------------------------------------------
run-queries: ## Execute the 4 advanced analytical queries
	@$(PSQL) -f /sql/03_analytical_queries.sql

refresh-datamart: ## Refresh the Power BI materialized view concurrently
	@$(PSQL) -c "SELECT fn_refresh_waste_datamart(TRUE);"

# --- Verification ------------------------------------------------------------
test: ## Run the SQL regression suite against the live database
	@$(PSQL) -f /sql/05_tests_business_logic.sql

# --- Utilities ---------------------------------------------------------------
psql: ## Open an interactive psql shell
	$(COMPOSE) exec -e PGPASSWORD=$(DB_PASSWORD) $(SERVICE) \
	  psql -U $(DB_USER) -d $(DB_NAME)

logs: ## Tail the database logs
	$(COMPOSE) logs -f $(SERVICE)

status: ## Show container and row-count status
	@$(COMPOSE) ps
	@$(PSQL) -c "SELECT 'stores' AS table, COUNT(*) FROM stores \
	  UNION ALL SELECT 'products', COUNT(*) FROM products \
	  UNION ALL SELECT 'goods_receipt_headers', COUNT(*) FROM goods_receipt_headers \
	  UNION ALL SELECT 'goods_receipt_items', COUNT(*) FROM goods_receipt_items \
	  UNION ALL SELECT 'inventory_batches', COUNT(*) FROM inventory_batches \
	  UNION ALL SELECT 'waste_log', COUNT(*) FROM waste_log \
	  UNION ALL SELECT 'daily_sales', COUNT(*) FROM daily_sales;"

clean-data: ## Delete generated CSVs, quarantine files and the ETL log
	rm -rf data/raw/*.csv data/quarantine/*.csv docs/etl_execution.log
	@echo "Generated artifacts removed."
