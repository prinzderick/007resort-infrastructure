<#
.SYNOPSIS
    Restore a LOCAL NODE database backup: verify into a scratch database, or restore over the live database.

.DESCRIPTION
    Three modes (see runbooks/backup-and-restore.md):
      -VerifyOnly            restore into a throwaway database r007_restore_test, check table count and the Laravel
                             migrations table, report duration, drop it. Use this for the QUARTERLY RESTORE TEST.
      -TargetDatabase NAME   restore into another database (e.g. for inspection); never the live one.
      -Live                  disaster recovery: stop the app services, take a safety dump of what is there now,
                             recreate the live database from the backup, start services. Requires
                             -ConfirmDatabaseName <live db name> as a typo guard.
    Point-in-time recovery after -Live (replay binlogs up to just before the bad event) is documented in the runbook;
    the dump header records the binlog position (--source-data=2).
    Credentials: C:\R007\secrets\mysql-admin.cnf (Admins/SYSTEM only). Nothing secret on any command line.

.EXAMPLE
    .\restore-mysql.ps1 -BackupFile D:\R007Backups\full\r007-20260923T013000Z.sql.gz -VerifyOnly
.EXAMPLE
    .\restore-mysql.ps1 -BackupFile \\nas\r007-backups\full\r007-20260923T013000Z.sql.gz -Live -ConfirmDatabaseName r007
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $BackupFile,
    [switch] $VerifyOnly,
    [string] $TargetDatabase,
    [switch] $Live,
    [string] $ConfirmDatabaseName,
    [int] $MinTables = 10,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\R007.Common.ps1')
Initialize-R007 -DryRun:$DryRun
Assert-R007Administrator

$paths = Get-R007Paths
$state = Get-R007State
$adminCnf = Join-Path $paths.Secrets 'mysql-admin.cnf'
$mysql = Join-Path $state.MySqlBin 'mysql.exe'
$mysqldump = Join-Path $state.MySqlBin 'mysqldump.exe'
$liveDb = $state.Database
$modes = @(@($VerifyOnly.IsPresent, [bool] $TargetDatabase, $Live.IsPresent) | Where-Object { $_ })
if ($modes.Count -ne 1) { throw 'Choose exactly one of -VerifyOnly, -TargetDatabase <name>, -Live.' }
if (-not $DryRun -and -not (Test-Path -LiteralPath $BackupFile)) { throw "Backup file not found: $BackupFile" }
if ($Live -and $ConfirmDatabaseName -ne $liveDb) { throw "For -Live pass -ConfirmDatabaseName $liveDb (typo guard)." }
if ($TargetDatabase) {
    if ($TargetDatabase -notmatch '^[A-Za-z0-9_]+$') { throw 'Invalid target database name.' }
    if ($TargetDatabase -eq $liveDb) { throw 'Use -Live to restore over the live database.' }
}
$scratch = if ($VerifyOnly) { 'r007_restore_test' } elseif ($TargetDatabase) { $TargetDatabase } else { $liveDb }

function Invoke-MySqlScript {
    param([string] $Sql)
    $Sql | & $mysql "--defaults-extra-file=$adminCnf"
    if ($LASTEXITCODE -ne 0) { throw 'mysql command failed.' }
}

function Import-DumpGz {
    <# Stream a .sql.gz into mysql.exe (never fully in memory), dropping CREATE DATABASE/USE lines to target $Db. #>
    param([string] $File, [string] $Db)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $mysql
    $psi.Arguments = "--defaults-extra-file=`"$adminCnf`" --default-character-set=utf8mb4 $Db"
    $psi.RedirectStandardInput = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $in = [System.IO.File]::OpenRead($File)
    try {
        $gz = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
        $reader = New-Object System.IO.StreamReader($gz, [System.Text.Encoding]::UTF8)
        $writer = New-Object System.IO.StreamWriter($proc.StandardInput.BaseStream, (New-Object System.Text.UTF8Encoding($false)))
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line -match '^(CREATE DATABASE|USE) ') { continue }
            $writer.WriteLine($line)
        }
        $writer.Flush(); $writer.Dispose()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { throw "mysql import failed (exit $($proc.ExitCode))." }
    }
    finally { $in.Dispose() }
}

$started = Get-Date
$svcNames = @(Get-R007ServiceDefinitions -State $state | ForEach-Object { $_.Name })
try {
    if ($DryRun) {
        Write-R007Log "[dry-run] mode=$(if ($VerifyOnly) {'verify'} elseif ($Live) {'LIVE'} else {'target'}) db=$scratch file=$BackupFile"
        return
    }
    # Integrity first: a corrupt archive must fail before anything is touched.
    $chk = [System.IO.File]::OpenRead($BackupFile)
    try { $g = New-Object System.IO.Compression.GZipStream($chk, [System.IO.Compression.CompressionMode]::Decompress); try { $g.CopyTo([System.IO.Stream]::Null) } finally { $g.Dispose() } } finally { $chk.Dispose() }
    $sumFile = "$BackupFile.sha256"
    if (Test-Path -LiteralPath $sumFile) {
        $want = ((Get-Content -LiteralPath $sumFile -Raw) -split '\s+')[0]
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $BackupFile).Hash -ne $want.ToUpperInvariant()) { throw 'SHA256 mismatch: the backup file is corrupt or was modified.' }
        Write-R007Log 'SHA256 verified' 'OK'
    }

    if ($Live) {
        Write-R007Log "LIVE RESTORE of '$liveDb' from $BackupFile" 'WARN'
        Stop-R007Services $svcNames
        $safety = Join-Path $state.BackupRoot "full\pre-restore-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')).sql"
        Write-R007Log "safety dump of the current database -> $safety"
        & $mysqldump "--defaults-extra-file=$adminCnf" --single-transaction --routines --triggers --events --result-file=$safety --databases $liveDb
        if ($LASTEXITCODE -ne 0) { throw 'Safety dump failed: aborting before touching the live database.' }
        Invoke-MySqlScript "DROP DATABASE IF EXISTS ``$liveDb``; CREATE DATABASE ``$liveDb`` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"
    }
    else {
        Invoke-MySqlScript "DROP DATABASE IF EXISTS ``$scratch``; CREATE DATABASE ``$scratch`` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"
    }

    Import-DumpGz -File $BackupFile -Db $scratch
    $count = ("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$scratch' AND table_type='BASE TABLE';" | & $mysql "--defaults-extra-file=$adminCnf" -N)
    $migs = ("SELECT COUNT(*) FROM ``$scratch``.migrations;" | & $mysql "--defaults-extra-file=$adminCnf" -N 2>$null)
    Write-R007Log "restored: tables=$count migrations=$migs in $([int] ((Get-Date) - $started).TotalSeconds)s" 'OK'
    if ([int] $count -lt $MinTables) { throw "Only $count tables restored (expected >= $MinTables): the backup is not usable." }
    if (-not $migs -or [int] $migs -lt 1) { throw 'Laravel migrations table is empty or missing.' }

    if ($VerifyOnly) {
        Invoke-MySqlScript "DROP DATABASE IF EXISTS ``$scratch``;"
        Write-R007Log "RESTORE TEST PASSED (RTO evidence: $([int] ((Get-Date) - $started).TotalSeconds)s). Record it in the site record." 'OK'
    }
    elseif ($Live) {
        Start-R007Services $svcNames
        Write-R007Log 'Live restore complete. Validate totals with the finance lead before reopening; then follow the runbook for binlog replay if needed and check sync (status.ps1).' 'OK'
    }
}
catch {
    Write-R007Log "RESTORE FAILED: $($_.Exception.Message)" 'ERROR'
    if ($VerifyOnly -and -not $DryRun) { try { Invoke-MySqlScript "DROP DATABASE IF EXISTS ``$scratch``;" } catch { Write-R007Log 'could not drop scratch database' 'WARN' } }
    exit 1
}
