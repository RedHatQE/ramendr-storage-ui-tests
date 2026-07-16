# Install SQL Server Express + HammerDB TPC-C workload on a Windows DR edge VM.
# Intended to run via SSH from install-hammerdb-incluster.sh (payload staged by in-cluster Job).
$ErrorActionPreference = 'Stop'

$RepoRoot = if ($env:REPO_ROOT) { $env:REPO_ROOT } else { 'C:\Temp\ramendr-dr-validation-install' }
$DataRoot = 'C:\ProgramData\ramendr-dr-validation'
$BinDir = Join-Path $DataRoot 'bin'
$LibDir = Join-Path $DataRoot 'lib\ramendr_dr_validation'
$PyLibDir = Join-Path $DataRoot 'lib'
$EnvDir = $DataRoot
$EnvFile = Join-Path $EnvDir 'db.env'
$HammerVersion = if ($env:HAMMERDB_VERSION) { $env:HAMMERDB_VERSION } else { '5.0' }
$HammerRoot = 'C:\HammerDB'
$HammerHome = Join-Path $HammerRoot 'current'
$Instance = if ($env:DR_VALIDATION_MSSQL_INSTANCE) { $env:DR_VALIDATION_MSSQL_INSTANCE } else { 'SQLEXPRESS' }
$Database = if ($env:DR_VALIDATION_MSSQL_DATABASE) { $env:DR_VALIDATION_MSSQL_DATABASE } else { 'tpcc' }
$Warehouses = if ($env:DR_VALIDATION_HAMMERDB_WAREHOUSES) { $env:DR_VALIDATION_HAMMERDB_WAREHOUSES } else { '1' }
$DataDiskDrive = if ($env:DR_VALIDATION_DATA_DISK_DRIVE) { $env:DR_VALIDATION_DATA_DISK_DRIVE.TrimEnd(':') } else { 'D' }
$DataDiskRoot = "${DataDiskDrive}:\MSSQL"
$OsDbDir = Join-Path $DataRoot 'mssql'

function Ensure-DataDisk {
    param([string]$DriveLetter = $DataDiskDrive)
    $volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
    if ($volume -and $volume.FileSystem -eq 'NTFS') {
        Write-Host "Data disk already available as ${DriveLetter}:"
        return
    }

    $osDisk = Get-Disk | Where-Object { $_.IsBoot -or $_.IsSystem } | Select-Object -First 1
    if (-not $osDisk) {
        throw 'DR validation OS disk not found (expected a boot or system disk).'
    }
    $dataDisk = Get-Disk | Where-Object {
        $_.Number -ne $osDisk.Number -and $_.OperationalStatus -in @('Online', 'Offline')
    } | Sort-Object Number | Select-Object -First 1
    if (-not $dataDisk) {
        throw 'DR validation data disk not found (expected a second disk besides the OS disk).'
    }

    if ($dataDisk.OperationalStatus -eq 'Offline') {
        if ($dataDisk.IsReadOnly) {
            Set-Disk -Number $dataDisk.Number -IsReadOnly $false -ErrorAction Stop
        }
        Set-Disk -Number $dataDisk.Number -IsOffline $false -ErrorAction Stop
        $dataDisk = Get-Disk -Number $dataDisk.Number
    }

    if ($dataDisk.PartitionStyle -eq 'RAW') {
        Initialize-Disk -Number $dataDisk.Number -PartitionStyle GPT -ErrorAction Stop
    }

    $partition = Get-Partition -DiskNumber $dataDisk.Number -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter -eq $DriveLetter } |
        Select-Object -First 1
    if (-not $partition) {
        $partition = New-Partition -DiskNumber $dataDisk.Number -UseMaximumSize -DriveLetter $DriveLetter -ErrorAction Stop
    }

    $volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
    if (-not $volume -or $volume.FileSystem -ne 'NTFS') {
        Format-Volume -DriveLetter $DriveLetter -FileSystem NTFS -NewFileSystemLabel 'RAMENDR-DATA' -Confirm:$false -ErrorAction Stop | Out-Null
    }
    Write-Host "HammerDB data disk ready on ${DriveLetter}: (disk $($dataDisk.Number))"
}

function Test-MssqlIdentifier {
    param(
        [string]$Name,
        [string]$Kind
    )
    if ($Name -notmatch '^[a-zA-Z_][a-zA-Z0-9_]*$') {
        throw "Invalid MSSQL $Kind identifier: $Name"
    }
}

function Format-SqlIdentifier {
    param([string]$Name)
    return "[$($Name.Replace(']', ']]'))]"
}

function Format-SqlStringLiteral {
    param([string]$Value)
    return "N'$($Value.Replace("'", "''"))'"
}

function Escape-TclBracedString {
    param([string]$Value)
    $escaped = $Value -replace '\}', '\}'
    return "{$escaped}"
}

function Protect-SecretFile {
    param([string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRule($rule)
    }
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $adminSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $systemSid, 'FullControl', 'Allow')))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $adminSid, 'FullControl', 'Allow')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Test-StagedExecutable {
    param(
        [string]$Path,
        [string]$Label,
        [int]$MinBytes = 1000000
    )
    if (-not (Test-Path $Path)) {
        throw "$Label missing at $Path (expected from in-cluster staging)."
    }
    $info = Get-Item $Path
    if ($info.Length -lt $MinBytes) {
        throw "$Label at $Path is too small ($($info.Length) bytes); expected a binary payload."
    }
    $header = [byte[]](Get-Content -Path $Path -Encoding Byte -TotalCount 512)
    if ($header.Length -lt 2) {
        throw "$Label at $Path is unreadable or truncated."
    }
    $textPrefix = [System.Text.Encoding]::ASCII.GetString(
        $header[0..([Math]::Min(63, $header.Length - 1))]
    ).TrimStart()
    if ($textPrefix -match '^(?:<!DOCTYPE|<html\b|<HTML\b)') {
        throw "$Label at $Path looks like HTML, not an executable (check download URL / proxy)."
    }
    if ($header[0] -ne 0x4D -or $header[1] -ne 0x5A) {
        throw "$Label at $Path is not a Windows PE executable (missing MZ header)."
    }
    $hash = Get-FileHash -Algorithm SHA256 -Path $Path
    Write-Host "Validated $Label at $Path ($($info.Length) bytes, SHA256=$($hash.Hash))"
}

function Import-InstallCredentials {
    $credentialFile = 'C:\Temp\mssql-install.env'
    if (-not (Test-Path $credentialFile)) { return }
    try {
        Get-Content $credentialFile | ForEach-Object {
            if ($_ -match '^\s*([^#=]+)=(.*)$') {
                $name = $matches[1].Trim()
                $value = $matches[2].Trim().Trim('"')
                Set-Item -Path "env:$name" -Value $value
            }
        }
    } finally {
        Remove-Item -LiteralPath $credentialFile -Force -ErrorAction SilentlyContinue
    }
}

function Require-EnvVar {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required environment variable $Name is not set."
    }
    return $value
}

Import-InstallCredentials
$SaPassword = Require-EnvVar 'DR_VALIDATION_MSSQL_SA_PASSWORD'
$User = Require-EnvVar 'DR_VALIDATION_MSSQL_USER'
$Password = Require-EnvVar 'DR_VALIDATION_MSSQL_PASSWORD'
Test-MssqlIdentifier -Name $Database -Kind 'database'
Test-MssqlIdentifier -Name $User -Kind 'user'
Test-MssqlIdentifier -Name $Instance -Kind 'instance'

Write-Host '=== RamenDR HammerDB install (SQL Server / Windows) ==='

Ensure-DataDisk
New-Item -ItemType Directory -Force -Path $DataRoot, $BinDir, $LibDir, (Join-Path $LibDir 'backends'), $OsDbDir, "$DataDiskRoot\DATA", "$DataDiskRoot\LOG" | Out-Null

function Test-NetFx35Installed {
    $feature = Get-WindowsFeature -Name NET-Framework-Core -ErrorAction SilentlyContinue
    return [bool]($feature -and $feature.InstallState -eq 'Installed')
}

function Enable-SqlPrerequisites {
    # SQL Server Express requires .NET Framework 3.5 (NET-Framework-Core / NetFx3).
    # On Server 2025 this often times out when Install-WindowsFeature must pull
    # payloads from Windows Update (slow/blocked egress). Prefer baking the
    # feature into the golden image; otherwise retry Install-WindowsFeature and
    # fall back to DISM. Optional offline source:
    #   $env:DR_VALIDATION_NETFX35_SOURCE = path to SxS / feature cab directory
    if (Test-NetFx35Installed) {
        Write-Host '.NET Framework 3.5 already installed.'
        return
    }

    $source = $env:DR_VALIDATION_NETFX35_SOURCE
    if ($source) {
        $source = $source.Trim().TrimEnd('\')
    }
    $maxAttempts = 5
    $lastError = $null

    Write-Host 'Enabling .NET Framework 3.5 (SQL Server prerequisite)...'
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if (Test-NetFx35Installed) {
            Write-Host ".NET Framework 3.5 installed (attempt $attempt)."
            return
        }

        Write-Host "  Install-WindowsFeature NET-Framework-Core (attempt $attempt/$maxAttempts)..."
        try {
            $installArgs = @{
                Name             = 'NET-Framework-Core'
                ErrorAction      = 'Stop'
                WarningAction    = 'SilentlyContinue'
            }
            if ($source -and (Test-Path -LiteralPath $source)) {
                $installArgs['Source'] = $source
            }
            $result = Install-WindowsFeature @installArgs
            if ($result.Success -and (Test-NetFx35Installed)) {
                if ($result.RestartNeeded -eq 'Yes') {
                    Write-Host 'Warning: .NET Framework 3.5 install requested a reboot before SQL Server setup.'
                }
                return
            }
            $lastError = (
                "Install-WindowsFeature Success=$($result.Success) " +
                "ExitCode=$($result.ExitCode) RestartNeeded=$($result.RestartNeeded)"
            )
        } catch {
            $lastError = "$_"
            Write-Host "  Install-WindowsFeature failed: $lastError"
        }

        Write-Host "  DISM NetFx3 fallback (attempt $attempt/$maxAttempts)..."
        $dismArgs = @(
            '/Online',
            '/Enable-Feature',
            '/FeatureName:NetFx3',
            '/All',
            '/NoRestart'
        )
        if ($source -and (Test-Path -LiteralPath $source)) {
            $dismArgs += "/Source:$source"
            $dismArgs += '/LimitAccess'
        }
        & dism.exe @dismArgs
        $dismRc = $LASTEXITCODE
        if (($dismRc -eq 0 -or $dismRc -eq 3010) -and (Test-NetFx35Installed)) {
            if ($dismRc -eq 3010) {
                Write-Host 'Warning: DISM NetFx3 requested a reboot before SQL Server setup.'
            }
            return
        }
        $lastError = "DISM NetFx3 exit code $dismRc; $($lastError)"
        if ($attempt -lt $maxAttempts) {
            Start-Sleep -Seconds ([Math]::Min(30 * $attempt, 120))
        }
    }

    throw (
        ".NET Framework 3.5 (NET-Framework-Core / NetFx3) is not installed after " +
        "$maxAttempts attempts. Last error: $lastError. " +
        "Bake NetFx3 into the windows2k25 golden image, or set " +
        "DR_VALIDATION_NETFX35_SOURCE to an offline SxS/cab path."
    )
}

function Grant-SqlDataDiskAccess {
    $svcName = "MSSQL`$$Instance"
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) {
        throw "SQL Server service $svcName not found; cannot grant data-disk ACLs."
    }
    $sqlAccount = "NT SERVICE\$svcName"
    foreach ($path in @("$DataDiskRoot\DATA", "$DataDiskRoot\LOG")) {
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Force -Path $path | Out-Null
        }
        $acl = Get-Acl -LiteralPath $path
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sqlAccount,
            'FullControl',
            'ContainerInherit,ObjectInherit',
            'None',
            'Allow'
        )
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $path -AclObject $acl
    }
    Write-Host "Granted $sqlAccount access to ${DataDiskRoot}\DATA and ${DataDiskRoot}\LOG"
}

function Get-DatabasePrimaryFilePath {
    param([string]$DbName)
    $dbLiteral = Format-SqlStringLiteral $DbName
    $sqlcmd = Get-SqlCmdPath
    if (-not $sqlcmd) { return $null }
    $out = & $sqlcmd -S "(local)\$Instance" -U sa -P $SaPassword -d master -h -1 -W -b -Q @"
SELECT TOP 1 mf.physical_name
FROM sys.master_files mf
INNER JOIN sys.databases d ON d.database_id = mf.database_id
WHERE d.name = $dbLiteral AND mf.type = 0
"@ 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($out | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1).Trim()
}

function Get-RunningSqlInstanceName {
    $running = Get-Service -Name 'MSSQL*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Running' } |
        Select-Object -First 1
    if ($running) {
        return ($running.Name -replace '^MSSQL\$', '')
    }
    return $null
}

function Wait-SqlService {
    param([string]$Name, [int]$MaxSeconds = 300)
    $deadline = (Get-Date).AddSeconds($MaxSeconds)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service -Name "MSSQL`$$Name" -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Start-Sleep -Seconds 10
            return
        }
        Start-Sleep -Seconds 10
    }
    throw "Timed out waiting for SQL Server instance $Name to start."
}

function Ensure-SqlExpress {
    Enable-SqlPrerequisites

    $existing = Get-RunningSqlInstanceName
    if ($existing) {
        $script:Instance = $existing
        Write-Host "Using existing SQL Server instance $Instance."
        return
    }

    $stagedSsei = 'C:\Temp\SQL2022-SSEI-Expr.exe'
    Test-StagedExecutable -Path $stagedSsei -Label 'SQL Server SSEI bootstrapper'

    $mediaPath = 'C:\Temp\sqlserver-media'
    if (Test-Path $mediaPath) {
        Remove-Item -Recurse -Force $mediaPath
    }
    New-Item -ItemType Directory -Force -Path $mediaPath | Out-Null

    Write-Host 'Downloading SQL Server 2022 Express media via SSEI bootstrapper...'
    $download = Start-Process -FilePath $stagedSsei -ArgumentList @(
        '/ACTION=Download',
        "/MEDIAPATH=$mediaPath",
        '/MEDIATYPE=Core',
        '/QUIET'
    ) -Wait -PassThru
    if ($download.ExitCode -ne 0 -and $download.ExitCode -ne 3010) {
        throw "SQL Server media download failed with exit code $($download.ExitCode)"
    }

    Write-Host 'SQL Server media layout:'
    Get-ChildItem -Path $mediaPath -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "  $($_.FullName)"
    }

    $setup = Get-ChildItem -Path $mediaPath -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ieq 'SETUP.EXE' } |
        Select-Object -First 1
    if (-not $setup) {
        $sqlexpr = Get-ChildItem -Path $mediaPath -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'SQLEXPR*.exe' -or $_.Name -like 'SQLServer*.exe' } |
            Select-Object -First 1
        if ($sqlexpr) {
            $extractPath = Join-Path $mediaPath 'extracted'
            New-Item -ItemType Directory -Force -Path $extractPath | Out-Null
            Write-Host "Extracting SQL Server setup from $($sqlexpr.Name)..."
            $extract = Start-Process -FilePath $sqlexpr.FullName -ArgumentList @('/q', "/x:$extractPath") -Wait -PassThru
            if ($extract.ExitCode -ne 0 -and $extract.ExitCode -ne 3010) {
                throw "SQL Server setup extract failed with exit code $($extract.ExitCode)"
            }
            $setup = Get-ChildItem -Path $extractPath -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ieq 'SETUP.EXE' } |
                Select-Object -First 1
        }
    }
    if (-not $setup) {
        throw 'SETUP.EXE not found after SQL Server media download/extract.'
    }

    Write-Host "Installing SQL Server Express from $($setup.FullName)..."
    $setupDir = $setup.DirectoryName
    Push-Location $setupDir
    try {
        $install = Start-Process -FilePath $setup.FullName -ArgumentList @(
            '/Q',
            '/ACTION=Install',
            '/FEATURES=SQLENGINE',
            "/INSTANCENAME=$Instance",
            '/SECURITYMODE=SQL',
            "/SAPWD=$SaPassword",
            '/SQLSYSADMINACCOUNTS=BUILTIN\Administrators',
            '/TCPENABLED=1',
            '/UpdateEnabled=False',
            '/IACCEPTSQLSERVERLICENSETERMS'
        ) -Wait -PassThru -WorkingDirectory $setupDir
    } finally {
        Pop-Location
    }
    if ($install.ExitCode -ne 0 -and $install.ExitCode -ne 3010) {
        $logRoot = Join-Path ${env:ProgramFiles} 'Microsoft SQL Server\160\Setup Bootstrap\Log'
        if (-not (Test-Path $logRoot)) {
            $logRoot = Join-Path ${env:ProgramFiles(x86)} 'Microsoft SQL Server\160\Setup Bootstrap\Log'
        }
        if (Test-Path $logRoot) {
            $latest = Get-ChildItem $logRoot -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latest) {
                Write-Host "SQL setup log folder: $($latest.FullName)"
                Get-ChildItem $latest.FullName -Filter '*.txt' -ErrorAction SilentlyContinue | ForEach-Object {
                    Write-Host "--- $($_.Name) ---"
                    Get-Content $_.FullName -Tail 20 -ErrorAction SilentlyContinue
                }
            }
        }
        throw "SQL Server Express install failed with exit code $($install.ExitCode)"
    }
    Wait-SqlService -Name $Instance -MaxSeconds 600
}

function Ensure-HammerDb {
    if (Test-Path (Join-Path $HammerHome 'hammerdbcli.exe')) {
        return
    }
    $archiveName = "HammerDB-$HammerVersion-Prod-Win.tar.gz"
    $stagedArchive = Join-Path 'C:\Temp' $archiveName
    $archivePath = Join-Path $env:TEMP $archiveName
    if (Test-Path $stagedArchive) {
        Copy-Item -Force $stagedArchive $archivePath
    }
    if (-not (Test-Path $archivePath)) {
        Write-Host "Downloading HammerDB $HammerVersion for Windows..."
        $url = "https://github.com/TPC-Council/HammerDB/releases/download/v$HammerVersion/$archiveName"
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -fL -o $archivePath $url
        } else {
            Invoke-WebRequest -Uri $url -OutFile $archivePath -UseBasicParsing
        }
    }
    if (-not (Test-Path $archivePath)) {
        throw "HammerDB archive not found: $archiveName"
    }
    if (Test-Path $HammerRoot) {
        Remove-Item -Recurse -Force $HammerRoot
    }
    New-Item -ItemType Directory -Force -Path $HammerRoot | Out-Null
    tar -xzf $archivePath -C $HammerRoot
    $extracted = Get-ChildItem -Path $HammerRoot -Directory | Where-Object { $_.Name -like 'HammerDB-*' } | Select-Object -First 1
    if (-not $extracted) { throw 'HammerDB extract directory not found' }
    New-Item -ItemType Junction -Path $HammerHome -Target $extracted.FullName -Force | Out-Null
}

function Ensure-Python {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) { return $python.Source }

    $staged = 'C:\Temp\python-amd64.exe'
    if (Test-Path $staged) {
        Write-Host 'Installing Python from staged installer...'
        $proc = Start-Process -FilePath $staged -ArgumentList @(
            '/quiet',
            'InstallAllUsers=1',
            'PrependPath=1',
            'Include_pip=1',
            'Include_test=0'
        ) -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            throw "Python installer failed with exit code $($proc.ExitCode)"
        }
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
        $python = Get-Command python -ErrorAction SilentlyContinue
        if ($python) { return $python.Source }
    }

    throw 'Python not found and no staged installer at C:\Temp\python-amd64.exe'
}

function Get-SqlCmdPath {
    foreach ($candidate in @(
        "${env:ProgramFiles}\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\SQLCMD.EXE",
        "${env:ProgramFiles}\Microsoft SQL Server\160\Tools\Binn\sqlcmd.exe",
        "${env:ProgramFiles(x86)}\Microsoft SQL Server\160\Tools\Binn\sqlcmd.exe"
    )) {
        if (Test-Path $candidate) { return $candidate }
    }
    return (Get-Command sqlcmd -ErrorAction SilentlyContinue).Source
}

function Get-TpccCoreTableCount {
    $sqlcmd = Get-SqlCmdPath
    if (-not $sqlcmd) { return 0 }
    $query = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME IN ('customer','orders','warehouse')"
    $out = & $sqlcmd -S "(local)\$Instance" -U $User -P $Password -d $Database -h -1 -W -b -Q $query 2>$null
    if ($LASTEXITCODE -ne 0) { return 0 }
    return [int]($out | Select-Object -First 1)
}

function Get-AuditRowCount {
    $sqlcmd = Get-SqlCmdPath
    if (-not $sqlcmd) { return 0 }
    $out = & $sqlcmd -S "(local)\$Instance" -U $User -P $Password -d $Database -h -1 -W -b -Q 'SELECT COUNT(*) FROM dr_validation_audit' 2>$null
    if ($LASTEXITCODE -ne 0) { return 0 }
    return [int]($out | Select-Object -First 1)
}

function Invoke-SqlCmd {
    param(
        [string]$Query,
        [string]$Database = 'master'
    )
    $sqlcmd = Get-SqlCmdPath
    if (-not $sqlcmd) { throw 'sqlcmd not found after SQL Server install' }

    & $sqlcmd -S "(local)\$Instance" -U sa -P $SaPassword -d $Database -b -Q $Query
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed: $Query" }
}

function Ensure-OdbcDriver {
    $driverName = 'ODBC Driver 17 for SQL Server'
    if (Get-OdbcDriver -Platform '64-bit' -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $driverName }) {
        return
    }
    $installer = 'C:\Temp\msodbcsql17.exe'
    if (-not (Test-Path $installer)) {
        Write-Host 'Downloading Microsoft ODBC Driver 17 for SQL Server...'
        $url = 'https://go.microsoft.com/fwlink/?linkid=2361646'
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -fL -o $installer $url
        } else {
            Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
        }
    }
    Test-StagedExecutable -Path $installer -Label 'ODBC Driver 17 installer'
    Write-Host 'Installing ODBC Driver 17 for SQL Server...'
    $proc = Start-Process -FilePath $installer -ArgumentList @('/quiet', 'IACCEPTMSODBCSQLLICENSETERMS=YES') -Wait -PassThru
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        throw "ODBC Driver 17 install failed with exit code $($proc.ExitCode)"
    }
}

Ensure-SqlExpress
Ensure-OdbcDriver
Ensure-HammerDb
Grant-SqlDataDiskAccess

Write-Host 'Configuring SQL Server database and login...'
$dbLiteral = Format-SqlStringLiteral $Database
$dbIdent = Format-SqlIdentifier $Database
$userLiteral = Format-SqlStringLiteral $User
$userIdent = Format-SqlIdentifier $User
$passLiteral = Format-SqlStringLiteral $Password
$dataMdf = "$DataDiskRoot\DATA\tpcc.mdf"
$dataLog = "$DataDiskRoot\LOG\tpcc_log.ldf"
$osNdf = Join-Path $OsDbDir 'tpcc_os.ndf'
$dataMdfLiteral = Format-SqlStringLiteral $dataMdf
$dataLogLiteral = Format-SqlStringLiteral $dataLog
$osNdfLiteral = Format-SqlStringLiteral $osNdf
$existingPrimary = Get-DatabasePrimaryFilePath -DbName $Database
$skipDatabaseRebuild = $false
if ($existingPrimary -and ($existingPrimary -ieq $dataMdf)) {
    Write-Host "Database $Database already uses primary data file $dataMdf; preserving existing database."
    $skipDatabaseRebuild = $true
}
if (-not $skipDatabaseRebuild) {
    Stop-ScheduledTask -TaskName 'ramendr-dr-hammerdb' -ErrorAction SilentlyContinue
    Stop-ScheduledTask -TaskName 'ramendr-dr-db-audit' -ErrorAction SilentlyContinue
    Invoke-SqlCmd @"
USE master;
IF DB_ID($dbLiteral) IS NOT NULL
BEGIN
    BEGIN TRY
        ALTER DATABASE $dbIdent SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    END TRY
    BEGIN CATCH
        ALTER DATABASE $dbIdent SET EMERGENCY;
        ALTER DATABASE $dbIdent SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    END CATCH
    DROP DATABASE $dbIdent;
END
"@
    foreach ($stale in @($dataMdf, $dataLog, $osNdf)) {
        if (Test-Path $stale) { Remove-Item -Force $stale -ErrorAction SilentlyContinue }
    }
    Invoke-SqlCmd @"
CREATE DATABASE $dbIdent
ON PRIMARY (
    NAME = N'tpcc_primary',
    FILENAME = $dataMdfLiteral,
    SIZE = 64MB,
    FILEGROWTH = 64MB
),
FILEGROUP [ramendr_os] (
    NAME = N'tpcc_os',
    FILENAME = $osNdfLiteral,
    SIZE = 32MB,
    FILEGROWTH = 32MB
)
LOG ON (
    NAME = N'tpcc_log',
    FILENAME = $dataLogLiteral,
    SIZE = 32MB,
    FILEGROWTH = 32MB
);
"@
}
Invoke-SqlCmd @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = $userLiteral)
    CREATE LOGIN $userIdent WITH PASSWORD = $passLiteral, CHECK_POLICY = OFF, DEFAULT_DATABASE=$dbIdent;
USE $dbIdent;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = $userLiteral)
    CREATE USER $userIdent FOR LOGIN $userIdent;
ALTER ROLE db_owner ADD MEMBER $userIdent;
"@

$python = Ensure-Python
& $python -m pip install --upgrade pip pymssql 2>$null
if ($LASTEXITCODE -ne 0) {
    & $python -m ensurepip --default-pip
    & $python -m pip install pymssql
}

Copy-Item -Force (Join-Path $RepoRoot 'ramendr_dr_validation\db_audit_mssql.py') (Join-Path $LibDir 'db_audit_mssql.py')
Copy-Item -Force (Join-Path $RepoRoot 'ramendr_dr_validation\db_snapshot_common.py') (Join-Path $LibDir 'db_snapshot_common.py')
Copy-Item -Force (Join-Path $RepoRoot 'ramendr_dr_validation\db_snapshot_mssql.py') (Join-Path $LibDir 'db_snapshot_mssql.py')
Copy-Item -Force (Join-Path $RepoRoot 'ramendr_dr_validation\tpcc_schema.py') (Join-Path $LibDir 'tpcc_schema.py')
Copy-Item -Force (Join-Path $RepoRoot 'ramendr_dr_validation\backends\mssql.py') (Join-Path $LibDir 'backends\mssql.py')
Copy-Item -Force (Join-Path $RepoRoot 'ramendr_dr_validation\backends\__init__.py') (Join-Path $LibDir 'backends\__init__.py')
New-Item -ItemType File -Force -Path (Join-Path $LibDir '__init__.py') | Out-Null

@"
DR_VALIDATION_DB_BACKEND=mssql
DR_VALIDATION_MSSQL_HOST=(local)
DR_VALIDATION_MSSQL_PORT=1433
DR_VALIDATION_MSSQL_DATABASE=$Database
DR_VALIDATION_MSSQL_USER=$User
DR_VALIDATION_MSSQL_PASSWORD=$Password
DR_VALIDATION_MSSQL_INSTANCE=$Instance
DR_VALIDATION_DATA_DISK_DRIVE=$DataDiskDrive
DR_VALIDATION_MSSQL_DATA_ROOT=$DataDiskRoot
DR_VALIDATION_HAMMERDB_WAREHOUSES=$Warehouses
DR_VALIDATION_HAMMERDB_HOME=$HammerHome
"@ | Set-Content -Encoding ASCII $EnvFile
Protect-SecretFile -Path $EnvFile

function Register-LongRunningTask {
    param(
        [string]$Name,
        [string]$ScriptPath
    )
    Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5))
    )
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest
    Register-ScheduledTask -TaskName $Name -Action $action -Trigger $triggers `
        -Settings $settings -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $Name
}

$logDir = Join-Path $DataRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$auditScript = @"
`$ErrorActionPreference = 'Stop'
`$log = '$logDir\audit-task.log'
function Write-AuditLog([string]`$Message) {
    "`$(Get-Date -Format o) `$Message" | Add-Content -Path `$log
}
try {
    Write-AuditLog 'starting audit writer'
    `$env:PYTHONPATH = '$PyLibDir'
    `$env:DR_VALIDATION_DB_ENV_FILE = '$EnvFile'
    & '$python' -u '$LibDir\db_audit_mssql.py'
} catch {
    Write-AuditLog "audit writer failed: `$_"
    throw
}
"@
$auditScript | Set-Content -Encoding ASCII (Join-Path $BinDir 'ramendr-dr-db-audit.ps1')

$snapshotScript = @"
`$env:PYTHONPATH = '$PyLibDir'
`$env:DR_VALIDATION_DB_ENV_FILE = '$EnvFile'
& '$python' '$LibDir\db_snapshot_mssql.py' @args
"@
$snapshotScript | Set-Content -Encoding ASCII (Join-Path $BinDir 'ramendr-dr-db-snapshot.ps1')

Copy-Item -Force (Join-Path $RepoRoot 'hammerdb\run-autopilot-mssql.ps1') (Join-Path $BinDir 'run-autopilot-mssql.ps1')

$stateDir = Join-Path $DataRoot 'hammerdb'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$schemaFlag = Join-Path $stateDir 'schema-built'
$server = "(local)\$Instance"
$serverTcl = Escape-TclBracedString $server
$odbcDriverTcl = Escape-TclBracedString 'ODBC Driver 17 for SQL Server'
$buildVus = [Math]::Min([int]$Warehouses, 2)
$env:DR_VALIDATION_MSSQL_USER = $User
$env:DR_VALIDATION_MSSQL_PASSWORD = $Password
$env:DR_VALIDATION_MSSQL_DATABASE = $Database

if ((Get-TpccCoreTableCount) -lt 3) {
    Stop-ScheduledTask -TaskName 'ramendr-dr-hammerdb' -ErrorAction SilentlyContinue
    Remove-Item -Force $schemaFlag -ErrorAction SilentlyContinue
    Write-Host "Building HammerDB TPC-C schema ($Warehouses warehouse(s))..."
    $buildTcl = @"
dbset db mssqls
dbset bm TPC-C
diset connection mssqls_server $serverTcl
diset connection mssqls_authentication sql
diset connection mssqls_uid `$::env(DR_VALIDATION_MSSQL_USER)
diset connection mssqls_pass `$::env(DR_VALIDATION_MSSQL_PASSWORD)
diset connection mssqls_odbc_driver $odbcDriverTcl
diset connection mssqls_encrypt_connection false
diset connection mssqls_trust_server_cert true
diset tpcc mssqls_dbase `$::env(DR_VALIDATION_MSSQL_DATABASE)
diset tpcc mssqls_count_ware $Warehouses
diset tpcc mssqls_num_vu $buildVus
puts "SCHEMA BUILD START"
buildschema
puts "SCHEMA BUILD DONE"
"@
    Push-Location $HammerHome
    try {
        $buildTcl | Set-Content -Encoding ASCII (Join-Path $stateDir 'buildschema.tcl')
        & .\hammerdbcli.exe tcl auto (Join-Path $stateDir 'buildschema.tcl')
        if ($LASTEXITCODE -ne 0) { throw 'HammerDB buildschema failed' }
        if ((Get-TpccCoreTableCount) -lt 3) { throw 'HammerDB buildschema finished without core TPC-C tables' }
        New-Item -ItemType File -Force -Path $schemaFlag | Out-Null
    } finally {
        Pop-Location
    }
}

Invoke-SqlCmd -Database $Database -Query (Get-Content (Join-Path $RepoRoot 'hammerdb\sql\init-audit-mssql.sql') -Raw)

Write-Host 'Seeding audit writer...'
$env:PYTHONPATH = $PyLibDir
$env:DR_VALIDATION_DB_ENV_FILE = $EnvFile
& $python (Join-Path $LibDir 'db_audit_mssql.py') --max-records 2 --interval 1
if ($LASTEXITCODE -ne 0) { throw 'Initial audit writer failed' }

Register-LongRunningTask -Name 'ramendr-dr-hammerdb' -ScriptPath (Join-Path $BinDir 'run-autopilot-mssql.ps1')
Register-LongRunningTask -Name 'ramendr-dr-db-audit' -ScriptPath (Join-Path $BinDir 'ramendr-dr-db-audit.ps1')

if ((Get-TpccCoreTableCount) -lt 3) { throw 'HammerDB TPC-C schema not ready on SQL Server' }

Write-Host 'Waiting for continuous audit writer (up to 3 min)...'
$baselineAudit = Get-AuditRowCount
$auditCount = $baselineAudit
for ($i = 0; $i -lt 36; $i++) {
    Start-Sleep -Seconds 5
    $auditCount = Get-AuditRowCount
    if ($auditCount -gt $baselineAudit) { break }
}
if ($auditCount -le $baselineAudit) { throw 'Continuous audit writer did not append rows after scheduled task start' }

Write-Host "HammerDB install OK: audit_rows=$auditCount backend=mssql instance=$Instance"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $BinDir 'ramendr-dr-db-snapshot.ps1') | Select-Object -First 20
