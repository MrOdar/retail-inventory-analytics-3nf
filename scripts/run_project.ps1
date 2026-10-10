<#
.SYNOPSIS
    Task runner for the Retail Inventory & Waste Reduction Analytics platform.

.DESCRIPTION
    Windows-native equivalent of the Makefile, for machines without `make`.
    Wraps Docker Compose, the synthetic data generator, the ETL pipeline and the
    analytical SQL scripts behind a single verb.

.PARAMETER Command
    The task to run. Use 'help' to list every available verb.

.EXAMPLE
    .\scripts\run_project.ps1 all
    Runs the full chain: infrastructure -> data -> ETL -> analytics.

.EXAMPLE
    .\scripts\run_project.ps1 init-db
    Starts PostgreSQL 15 and reports the objects created on first boot.

.EXAMPLE
    .\scripts\run_project.ps1 run-etl
    Loads data/raw into PostgreSQL through the data-quality gate.

.NOTES
    Author: Odar Javier Alcocer Vásquez (Information Systems Engineering - UPC)
    Requires: Docker Desktop, Python 3.9+
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'all', 'up', 'down', 'destroy', 'init-db', 'wait-db',
                 'deps', 'generate', 'validate', 'run-etl', 'run-queries',
                 'refresh-datamart', 'test', 'psql', 'logs', 'status',
                 'clean-data')]
    [string]$Command = 'help',

    [int]$Days = 60,
    [int]$Seed = 20261012,
    [string]$DbUser = 'retail_admin',
    [string]$DbPassword = 'retail_secret',
    [string]$DbName = 'retail_inventory_db',
    [string]$DbHost = 'localhost',
    [int]$DbPort = 5433,
    [string]$Service = 'postgres'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Always operate from the repository root, whatever the caller's location.
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

$Dsn = "postgresql+psycopg2://${DbUser}:${DbPassword}@${DbHost}:${DbPort}/${DbName}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host ('=' * 76) -ForegroundColor DarkCyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host ('=' * 76) -ForegroundColor DarkCyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [!!] $Message" -ForegroundColor Red
}

function Resolve-Python {
    <#
        Locate a usable interpreter. 'python' on a stock Windows install is
        often the Microsoft Store stub, which exits without running anything,
        so each candidate is probed for real output.
    #>
    # stderr is DISCARDED rather than merged with 2>&1: in Windows PowerShell
    # 5.1, merging a native command's stderr wraps each line in a
    # NativeCommandError record, which under $ErrorActionPreference='Stop'
    # terminates the probe and masks this function's own diagnostic.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($candidate in @('python', 'py', 'python3')) {
            $resolved = Get-Command $candidate -ErrorAction SilentlyContinue
            if (-not $resolved) { continue }
            $version = & $candidate --version 2>$null
            if ($LASTEXITCODE -eq 0 -and "$version" -match 'Python 3') {
                return $candidate
            }
        }
    }
    finally {
        $ErrorActionPreference = $previous
    }
    throw ("No working Python 3 interpreter found on PATH. " +
           "'python' on a stock Windows install is often the Microsoft Store stub, " +
           "which exits without running anything. Install Python 3.9+ from python.org " +
           "(tick 'Add python.exe to PATH'), then re-run this command.")
}

function Assert-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker was not found on PATH. Install Docker Desktop, or point the scripts at an existing PostgreSQL instance with -DbHost/-DbPort."
    }
    docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker is installed but the daemon is not responding. Start Docker Desktop and retry."
    }
}

function Invoke-Compose {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ComposeArgs)
    Assert-Docker
    & docker compose @ComposeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose $($ComposeArgs -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Invoke-Psql {
    <#
        Run SQL inside the container. -f takes a path under the /sql mount;
        -Sql takes an inline statement.
    #>
    param([string]$Sql, [string]$File)
    Assert-Docker

    $psqlArgs = @('compose', 'exec', '-T', '-e', "PGPASSWORD=$DbPassword", $Service,
                  'psql', '-v', 'ON_ERROR_STOP=1', '-U', $DbUser, '-d', $DbName)
    if ($File) { $psqlArgs += @('-f', $File) }
    if ($Sql)  { $psqlArgs += @('-c', $Sql) }

    & docker @psqlArgs
    if ($LASTEXITCODE -ne 0) {
        throw "psql command failed with exit code $LASTEXITCODE."
    }
}

function Wait-Database {
    param([int]$TimeoutSeconds = 90)
    Write-Step 'Waiting for PostgreSQL to accept connections'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        & docker compose exec -T $Service pg_isready -U $DbUser -d $DbName *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok 'PostgreSQL is ready.'
            return
        }
        Start-Sleep -Seconds 2
    }
    throw "PostgreSQL did not become ready within $TimeoutSeconds seconds. Check: docker compose logs $Service"
}

# ---------------------------------------------------------------------------
# Tasks
# ---------------------------------------------------------------------------

function Show-Help {
    Write-Host ''
    Write-Host 'Retail Inventory & Waste Reduction Analytics -- task runner' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Usage: .\scripts\run_project.ps1 <command> [-Days 60] [-Seed 20261012]'
    Write-Host ''
    $tasks = [ordered]@{
        'all'              = 'Full pipeline: infra -> data -> ETL -> analytics'
        'up'               = 'Start PostgreSQL (DDL + seed + triggers on first boot)'
        'down'             = 'Stop containers, keep the data volume'
        'destroy'          = 'Stop containers AND delete the data volume (irreversible)'
        'init-db'          = 'Start the database and list the objects created'
        'wait-db'          = 'Block until the database reports healthy'
        'deps'             = 'Install the Python dependencies'
        'generate'         = 'Generate the synthetic CSV datasets into data/raw/'
        'validate'         = 'Run the quality gate only -- no database needed'
        'run-etl'          = 'Extract -> validate -> load the CSVs into PostgreSQL'
        'run-queries'      = 'Execute the 4 advanced analytical queries'
        'refresh-datamart' = 'Refresh the Power BI materialized view concurrently'
        'test'             = 'Run the SQL regression suite (FEFO + anti-fraud trigger)'
        'psql'             = 'Open an interactive psql shell'
        'logs'             = 'Tail the database logs'
        'status'           = 'Show container status and row counts'
        'clean-data'       = 'Delete generated CSVs, quarantine files and the ETL log'
    }
    foreach ($key in $tasks.Keys) {
        Write-Host ('    {0,-18} {1}' -f $key, $tasks[$key])
    }
    Write-Host ''
    Write-Host "  Database: ${DbUser}@${DbHost}:${DbPort}/${DbName}" -ForegroundColor DarkGray
    Write-Host ''
}

function Invoke-InitDb {
    Write-Step 'Starting PostgreSQL 15'
    Invoke-Compose up -d $Service
    Wait-Database

    Write-Step 'Objects created in the database'
    Invoke-Psql -Sql '\dt'
    Invoke-Psql -Sql @"
SELECT routine_name, routine_type
  FROM information_schema.routines
 WHERE routine_schema = 'public'
 ORDER BY routine_name;
"@
    Invoke-Psql -Sql @"
SELECT tgname AS trigger_name, relname AS table_name
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
 WHERE NOT t.tgisinternal;
"@
    Write-Ok 'Database initialized: schema, seed data, procedures and triggers are in place.'
}

function Invoke-Generate {
    Write-Step "Generating $Days days of synthetic retail operations data"
    $python = Resolve-Python
    & $python src/data_generator.py --days $Days --seed $Seed
    if ($LASTEXITCODE -ne 0) { throw "Data generation failed with exit code $LASTEXITCODE." }
    Write-Ok 'CSV datasets written to data/raw/.'
}

function Invoke-Validate {
    Write-Step 'Running the data-quality gate (dry run, no database)'
    $python = Resolve-Python
    & $python src/etl_pipeline.py --dry-run
    if ($LASTEXITCODE -ne 0) { throw "Validation failed with exit code $LASTEXITCODE." }
    Write-Ok 'Quality gate finished. Audit trail: docs/etl_execution.log'
}

function Invoke-Etl {
    Write-Step 'Running the ETL pipeline into PostgreSQL'
    $python = Resolve-Python
    & $python src/etl_pipeline.py --dsn $Dsn
    if ($LASTEXITCODE -ne 0) { throw "ETL pipeline failed with exit code $LASTEXITCODE." }
    Write-Ok 'Load complete. Audit trail: docs/etl_execution.log'
}

function Invoke-Status {
    Write-Step 'Platform status'
    Invoke-Compose ps
    Invoke-Psql -Sql @"
  SELECT 'stores' AS table_name, COUNT(*) AS rows FROM stores
UNION ALL SELECT 'products', COUNT(*) FROM products
UNION ALL SELECT 'goods_receipt_headers', COUNT(*) FROM goods_receipt_headers
UNION ALL SELECT 'goods_receipt_items', COUNT(*) FROM goods_receipt_items
UNION ALL SELECT 'inventory_batches', COUNT(*) FROM inventory_batches
UNION ALL SELECT 'waste_log', COUNT(*) FROM waste_log
UNION ALL SELECT 'daily_sales', COUNT(*) FROM daily_sales;
"@
}

function Invoke-CleanData {
    Write-Step 'Removing generated artifacts'
    foreach ($pattern in @('data/raw/*.csv', 'data/quarantine/*.csv')) {
        Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Remove-Item -Force
    }
    if (Test-Path 'docs/etl_execution.log') {
        Remove-Item 'docs/etl_execution.log' -Force
    }
    Write-Ok 'Generated CSVs, quarantine files and the ETL log were removed.'
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

try {
    switch ($Command) {
        'help'    { Show-Help }
        'up'      { Invoke-Compose up -d $Service; Write-Ok 'Container started.' }
        'down'    { Invoke-Compose down; Write-Ok 'Containers stopped (data volume kept).' }
        'destroy' {
            Write-Host '  This deletes the database volume and every row in it.' -ForegroundColor Yellow
            $answer = Read-Host '  Type DESTROY to confirm'
            if ($answer -ceq 'DESTROY') {
                Invoke-Compose down -v
                Write-Ok 'Containers and data volume removed.'
            } else {
                Write-Host '  Cancelled; nothing was deleted.' -ForegroundColor DarkGray
            }
        }
        'wait-db'          { Wait-Database }
        'init-db'          { Invoke-InitDb }
        'deps'             { $p = Resolve-Python; & $p -m pip install -r requirements.txt }
        'generate'         { Invoke-Generate }
        'validate'         { Invoke-Validate }
        'run-etl'          { Invoke-Etl }
        'run-queries'      {
            Write-Step 'Executing the advanced analytical queries'
            Invoke-Psql -File '/sql/03_analytical_queries.sql'
        }
        'refresh-datamart' {
            Write-Step 'Refreshing the Power BI datamart'
            Invoke-Psql -Sql 'SELECT fn_refresh_waste_datamart(TRUE);'
        }
        'test' {
            Write-Step 'Running the SQL regression suite'
            Invoke-Psql -File '/sql/05_tests_business_logic.sql'
        }
        'psql'       { & docker compose exec -e "PGPASSWORD=$DbPassword" $Service psql -U $DbUser -d $DbName }
        'logs'       { & docker compose logs -f $Service }
        'status'     { Invoke-Status }
        'clean-data' { Invoke-CleanData }
        'all' {
            Invoke-InitDb
            Invoke-Generate
            Invoke-Etl
            Write-Step 'Executing the advanced analytical queries'
            Invoke-Psql -File '/sql/03_analytical_queries.sql'
            Write-Step 'Pipeline complete'
            Write-Ok 'Infrastructure, data, ETL and analytics all finished successfully.'
            Write-Host '  Audit trail : docs/etl_execution.log' -ForegroundColor DarkGray
            Write-Host "  Connection  : postgresql://${DbUser}@${DbHost}:${DbPort}/${DbName}" -ForegroundColor DarkGray
        }
    }
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}
