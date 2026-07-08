# Build HammerDB TPC-C schema once, then run continuous timed OLTP load (SQL Server / Windows).
$ErrorActionPreference = 'Stop'

function Escape-TclBracedString {
    param([string]$Value)
    $escaped = $Value -replace '\\', '\\\\' -replace '\}', '\}'
    return "{$escaped}"
}

$EnvFile = if ($env:DR_VALIDATION_DB_ENV_FILE) { $env:DR_VALIDATION_DB_ENV_FILE } else { 'C:\ProgramData\ramendr-dr-validation\db.env' }
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        if ($_ -match '^\s*([^#=]+)=(.*)$') {
            $name = $matches[1].Trim()
            $value = $matches[2].Trim().Trim('"')
            if (-not (Test-Path "env:$name")) {
                Set-Item -Path "env:$name" -Value $value
            }
        }
    }
}

$HammerHome = if ($env:DR_VALIDATION_HAMMERDB_HOME) { $env:DR_VALIDATION_HAMMERDB_HOME } else { 'C:\HammerDB\current' }
$Warehouses = if ($env:DR_VALIDATION_HAMMERDB_WAREHOUSES) { [int]$env:DR_VALIDATION_HAMMERDB_WAREHOUSES } else { 1 }
$Vus = if ($env:DR_VALIDATION_HAMMERDB_VUS) { [int]$env:DR_VALIDATION_HAMMERDB_VUS } else { 2 }
$BuildVus = [Math]::Min($Warehouses, $Vus)
$Instance = if ($env:DR_VALIDATION_MSSQL_INSTANCE) { $env:DR_VALIDATION_MSSQL_INSTANCE } else { 'SQLEXPRESS' }
$Server = "(local)\$Instance"
$Database = if ($env:DR_VALIDATION_MSSQL_DATABASE) { $env:DR_VALIDATION_MSSQL_DATABASE } else { 'tpcc' }
if ([string]::IsNullOrWhiteSpace($env:DR_VALIDATION_MSSQL_USER)) {
    throw 'DR_VALIDATION_MSSQL_USER is required'
}
if ([string]::IsNullOrWhiteSpace($env:DR_VALIDATION_MSSQL_PASSWORD)) {
    throw 'DR_VALIDATION_MSSQL_PASSWORD is required'
}
$OdbcDriver = if ($env:DR_VALIDATION_MSSQL_ODBC_DRIVER) { $env:DR_VALIDATION_MSSQL_ODBC_DRIVER } else { 'ODBC Driver 17 for SQL Server' }
$ServerTcl = Escape-TclBracedString $Server
$OdbcDriverTcl = Escape-TclBracedString $OdbcDriver
$StateDir = 'C:\ProgramData\ramendr-dr-validation\hammerdb'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

Set-Location $HammerHome

$connectionTcl = @"
diset connection mssqls_server $ServerTcl
diset connection mssqls_authentication sql
diset connection mssqls_uid `$::env(DR_VALIDATION_MSSQL_USER)
diset connection mssqls_pass `$::env(DR_VALIDATION_MSSQL_PASSWORD)
diset connection mssqls_odbc_driver $OdbcDriverTcl
diset connection mssqls_encrypt_connection false
diset connection mssqls_trust_server_cert true
"@

$buildTcl = @"
dbset db mssqls
dbset bm TPC-C
$connectionTcl
diset tpcc mssqls_dbase `$::env(DR_VALIDATION_MSSQL_DATABASE)
diset tpcc mssqls_count_ware $Warehouses
diset tpcc mssqls_num_vu $BuildVus
puts "SCHEMA BUILD START"
buildschema
puts "SCHEMA BUILD DONE"
"@

$runTcl = @"
proc wait_to_complete {} {
  while {![vucomplete]} {
    update
    after 100
  }
}
dbset db mssqls
dbset bm TPC-C
$connectionTcl
diset tpcc mssqls_dbase `$::env(DR_VALIDATION_MSSQL_DATABASE)
diset tpcc mssqls_driver timed
diset tpcc mssqls_total_iterations 10000000
diset tpcc mssqls_rampup 0
diset tpcc mssqls_duration 86400
diset tpcc mssqls_timeprofile true
diset tpcc mssqls_allwarehouse true
while {1} {
  loadscript
  vuset vu $Vus
  vucreate
  tcstart
  vurun
  wait_to_complete
  vudestroy
  tcstop
}
"@

$schemaFlag = Join-Path $StateDir 'schema-built'
if (-not (Test-Path $schemaFlag)) {
    Write-Host "Building HammerDB TPC-C schema ($Warehouses warehouse(s))..."
    $buildTcl | Set-Content -Encoding ASCII (Join-Path $StateDir 'buildschema.tcl')
    & .\hammerdbcli.exe tcl auto (Join-Path $StateDir 'buildschema.tcl')
    if ($LASTEXITCODE -ne 0) { throw 'HammerDB buildschema failed' }
    New-Item -ItemType File -Force -Path $schemaFlag | Out-Null
}

Write-Host 'Starting HammerDB TPC-C workload...'
$runTcl | Set-Content -Encoding ASCII (Join-Path $StateDir 'runload.tcl')
& .\hammerdbcli.exe tcl auto (Join-Path $StateDir 'runload.tcl')
if ($LASTEXITCODE -ne 0) { throw 'HammerDB TPC-C workload failed' }
