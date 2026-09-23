<#
.SYNOPSIS
    Nightly MySQL backup for the LOCAL NODE: dump + binlogs -> local disk -> NAS (+ optional off-site) with retention.

.DESCRIPTION
    Runs as the scheduled task "R007 Nightly Backup" (SYSTEM, 02:30 local). Can also be run by hand before a risky
    release. See runbooks/backup-and-restore.md.

    - mysqldump --single-transaction (consistent InnoDB snapshot, no locks), routines/triggers/events, and the binlog
      position (--source-data=2) for point-in-time recovery. Credentials come ONLY from the protected option file
      C:\R007\secrets\mysql-backup.cnf (--defaults-extra-file): never on a command line, never in this script.
    - The dump is streamed through gzip, then verified (gzip integrity + the "Dump completed" trailer) before it is kept.
    - Closed binary logs are copied next to the dump (the active one is skipped).
    - Copy to the NAS (UNC path). If the NAS needs credentials, put "user=..." and "password=..." in
      C:\R007\secrets\nas.cred (Admins/SYSTEM only); on a domain, grant the server's computer account write access instead.
    - Optional off-site copy: set OffsiteRemote (an rclone remote, ideally a crypt remote) and optionally AgeRecipient
      (age public key) in C:\R007\install-state.json; rclone.exe / age.exe must be on PATH.
    - Retention: local LocalRetentionDays (default 7), NAS NasRetentionDays (default 35).
    - Result is written to C:\R007\logs\backup.log and the Windows Application event log (source R007-Backup).
      A backup older than 26 hours is an incident (status.ps1 checks this).

.EXAMPLE
    .\backup-mysql.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string] $OptionFile,
    [string] $Database,
    [string] $BackupRoot,
    [string] $NasPath,
    [ValidateRange(1, 365)][int] $LocalRetentionDays = 7,
    [ValidateRange(1, 3650)][int] $NasRetentionDays = 35,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\R007.Common.ps1')
Initialize-R007 -DryRun:$DryRun

$paths = Get-R007Paths
$state = Get-R007State
if (-not $OptionFile) { $OptionFile = Join-Path $paths.Secrets 'mysql-backup.cnf' }
if (-not $Database) { $Database = $state.Database }
if (-not $BackupRoot) { $BackupRoot = $state.BackupRoot }
if (-not $NasPath) { $NasPath = $state.NasPath }
$offsite = if ($state.PSObject.Properties.Name -contains 'OffsiteRemote') { $state.OffsiteRemote } else { '' }
$ageRecipient = if ($state.PSObject.Properties.Name -contains 'AgeRecipient') { $state.AgeRecipient } else { '' }
if ($Database -notmatch '^[A-Za-z0-9_]+$') { throw "Invalid database name '$Database'." }

$mysqlBin = $state.MySqlBin
$mysqldump = Join-Path $mysqlBin 'mysqldump.exe'
$mysql = Join-Path $mysqlBin 'mysql.exe'
$fullDir = Join-Path $BackupRoot 'full'
$binDir = Join-Path $BackupRoot 'binlog'
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$dumpFile = Join-Path $fullDir "r007-$stamp.sql"
$gzFile = "$dumpFile.gz"
$logFile = Join-Path $paths.Logs 'backup.log'

function Write-BackupLog {
    param([string] $Message, [string] $Level = 'INFO')
    Write-R007Log $Message $Level
    if (-not $DryRun -and (Test-Path -LiteralPath $paths.Logs)) { Add-Content -LiteralPath $logFile -Value ("{0} {1} {2}" -f (Get-Date).ToUniversalTime().ToString('s'), $Level, $Message) }
}

function Write-BackupEvent {
    param([string] $Message, [string] $Type)
    if ($DryRun -or -not (Test-R007Windows)) { return }
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists('R007-Backup')) { New-EventLog -LogName Application -Source 'R007-Backup' }
        Write-EventLog -LogName Application -Source 'R007-Backup' -EntryType $Type -EventId 7000 -Message $Message
    }
    catch { Write-R007Log "could not write event log: $($_.Exception.Message)" 'WARN' }
}

function Mount-NasIfNeeded {
    param([string] $Path)
    $credFile = Join-Path $paths.Secrets 'nas.cred'
    if (-not (Test-Path -LiteralPath $credFile)) { return }
    $u = (Get-Content -LiteralPath $credFile | Where-Object { $_ -like 'user=*' } | Select-Object -First 1) -replace '^user=', ''
    $p = (Get-Content -LiteralPath $credFile | Where-Object { $_ -like 'password=*' } | Select-Object -First 1) -replace '^password=', ''
    if ($u -and $p) {
        $share = ($Path -split '\\' | Where-Object { $_ } | Select-Object -First 2) -join '\'
        New-SmbMapping -RemotePath "\\$share" -UserName $u -Password $p -ErrorAction SilentlyContinue | Out-Null
    }
}

$lock = Enter-R007Lock 'backup'
try {
    if (-not $DryRun) {
        foreach ($f in @($mysqldump, $mysql, $OptionFile)) { if (-not (Test-Path -LiteralPath $f)) { throw "Missing: $f" } }
    }
    foreach ($d in @($fullDir, $binDir)) { New-R007Directory $d }

    Write-BackupLog "dumping '$Database' -> $gzFile"
    Invoke-R007Step 'mysqldump | gzip, verify' {
        $dumpArgs = @("--defaults-extra-file=$OptionFile", '--single-transaction', '--quick', '--routines', '--triggers', '--events',
            '--source-data=2', '--set-gtid-purged=OFF', '--default-character-set=utf8mb4', '--hex-blob', "--result-file=$dumpFile", '--databases', $Database)
        & $mysqldump @dumpArgs
        if ($LASTEXITCODE -ne 0) { throw "mysqldump failed with exit code $LASTEXITCODE" }
        $tail = (Get-Content -LiteralPath $dumpFile -Tail 3) -join "`n"
        if ($tail -notmatch 'Dump completed') { throw "Dump file $dumpFile is incomplete (no trailer)." }
        $in = [System.IO.File]::OpenRead($dumpFile)
        try {
            $out = [System.IO.File]::Create($gzFile)
            try {
                $gz = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionLevel]::Optimal)
                try { $in.CopyTo($gz) } finally { $gz.Dispose() }
            }
            finally { $out.Dispose() }
        }
        finally { $in.Dispose() }
        Remove-Item -LiteralPath $dumpFile
        # Verify the archive by reading it end to end.
        $chk = [System.IO.File]::OpenRead($gzFile)
        try {
            $g = New-Object System.IO.Compression.GZipStream($chk, [System.IO.Compression.CompressionMode]::Decompress)
            try { $g.CopyTo([System.IO.Stream]::Null) } finally { $g.Dispose() }
        }
        finally { $chk.Dispose() }
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $gzFile).Hash
        Set-Content -LiteralPath "$gzFile.sha256" -Value "$hash  $(Split-Path -Leaf $gzFile)" -Encoding ASCII
    }

    Invoke-R007Step 'FLUSH BINARY LOGS and copy closed binlogs' {
        & $mysql "--defaults-extra-file=$OptionFile" --execute='FLUSH BINARY LOGS;'
        if ($LASTEXITCODE -ne 0) { Write-BackupLog 'FLUSH BINARY LOGS failed; binlog copy may lag.' 'WARN' }
        $datadir = $state.MySqlData
        $logs = @(Get-ChildItem -LiteralPath $datadir -Filter 'r007-binlog.0*' -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($logs.Count -gt 1) {
            foreach ($b in $logs[0..($logs.Count - 2)]) {   # skip the active log
                $dest = Join-Path $binDir $b.Name
                if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $b.FullName -Destination $dest }
            }
        }
    }

    if ($NasPath) {
        Invoke-R007Step "copy to NAS $NasPath" {
            Mount-NasIfNeeded $NasPath
            $nasFull = Join-Path $NasPath 'full'; $nasBin = Join-Path $NasPath 'binlog'
            New-Item -ItemType Directory -Path $nasFull, $nasBin -Force | Out-Null
            Copy-Item -LiteralPath $gzFile, "$gzFile.sha256" -Destination $nasFull -Force
            Get-ChildItem -LiteralPath $binDir -File | ForEach-Object { $d = Join-Path $nasBin $_.Name; if (-not (Test-Path -LiteralPath $d)) { Copy-Item -LiteralPath $_.FullName -Destination $d } }
            # Verify what landed on the NAS.
            $remote = Join-Path $nasFull (Split-Path -Leaf $gzFile)
            if ((Get-FileHash -Algorithm SHA256 -LiteralPath $remote).Hash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $gzFile).Hash) { throw 'NAS copy checksum mismatch.' }
            $cut = (Get-Date).AddDays(-$NasRetentionDays)
            Get-ChildItem -LiteralPath $nasFull -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut } | Remove-Item -Force
            Get-ChildItem -LiteralPath $nasBin -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut } | Remove-Item -Force
        }
    }
    else { Write-BackupLog 'No NAS path configured: only a local copy exists.' 'WARN' }

    if ($offsite) {
        Invoke-R007Step "off-site copy via rclone -> $offsite" {
            $src = $gzFile
            if ($ageRecipient) {
                & age.exe -r $ageRecipient -o "$gzFile.age" $gzFile
                if ($LASTEXITCODE -ne 0) { throw 'age encryption failed' }
                $src = "$gzFile.age"
            }
            else { Write-BackupLog 'AgeRecipient not set: off-site copy is only safe with an rclone crypt remote.' 'WARN' }
            & rclone.exe copy --checksum --immutable $src "$offsite/daily/"
            if ($LASTEXITCODE -ne 0) { throw 'rclone upload failed' }
            if ($ageRecipient) { Remove-Item -LiteralPath "$gzFile.age" -Force }
        }
    }

    Invoke-R007Step "prune local backups older than $LocalRetentionDays days" {
        $cut = (Get-Date).AddDays(-$LocalRetentionDays)
        Get-ChildItem -LiteralPath $fullDir -File | Where-Object { $_.LastWriteTime -lt $cut } | Remove-Item -Force
        Get-ChildItem -LiteralPath $binDir -File | Where-Object { $_.LastWriteTime -lt $cut } | Remove-Item -Force
    }

    Write-BackupLog "Backup completed: $gzFile" 'OK'
    Write-BackupEvent "Backup completed: $(Split-Path -Leaf $gzFile)" 'Information'
}
catch {
    Write-BackupLog "Backup FAILED: $($_.Exception.Message)" 'ERROR'
    Write-BackupEvent "Backup FAILED: $($_.Exception.Message)" 'Error'
    if (-not $DryRun) { Remove-Item -LiteralPath $dumpFile -ErrorAction SilentlyContinue }
    exit 1
}
finally { Exit-R007Lock $lock }
