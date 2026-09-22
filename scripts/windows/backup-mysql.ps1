<#
.SYNOPSIS
    Nightly MySQL logical backup for the Otueke site database.

.DESCRIPTION
    DRAFT - pending architecture approval. See runbooks/backup-and-restore.md.

    - Runs mysqldump with --single-transaction (consistent InnoDB snapshot, no locks)
      and records the binlog position (--source-data=2) for point-in-time recovery.
    - Credentials are read from a protected MySQL option file passed via
      --defaults-extra-file. Passwords are NEVER passed on the command line or stored
      in this script. Restrict the option file ACL to the backup account + Administrators.
    - Compresses the dump, verifies completion, copies to the NAS and prunes old files.
    - Offsite (encrypted) upload is a placeholder to be implemented per the approved
      provider.

    Example option file (C:\Otueke\secrets\mysql-backup.cnf):
        [client]
        user=otueke_backup
        password=<stored only in this protected file>
        host=127.0.0.1
        port=3306

.EXAMPLE
    .\backup-mysql.ps1 -OptionFile 'C:\Otueke\secrets\mysql-backup.cnf' -Verbose
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $OptionFile = 'C:\Otueke\secrets\mysql-backup.cnf',

    [string] $Database = 'otueke',

    [string] $MySqlBin = 'C:\Program Files\MySQL\MySQL Server 8.4\bin',

    [string] $BackupRoot = 'D:\OtuekeBackups',

    [string] $NasPath = '',

    [ValidateRange(1, 365)]
    [int] $LocalRetentionDays = 7
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mysqldump = Join-Path $MySqlBin 'mysqldump.exe'
if (-not (Test-Path -LiteralPath $mysqldump)) {
    throw "mysqldump not found at $mysqldump"
}

$fullDir = Join-Path $BackupRoot 'full'
New-Item -ItemType Directory -Path $fullDir -Force | Out-Null

$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$dumpFile = Join-Path $fullDir "$Database-$stamp.sql"
$gzFile = "$dumpFile.gz"

$dumpArgs = @(
    "--defaults-extra-file=$OptionFile"   # must be the FIRST argument
    '--single-transaction'
    '--quick'
    '--routines'
    '--triggers'
    '--events'
    '--source-data=2'
    '--set-gtid-purged=AUTO'
    '--default-character-set=utf8mb4'
    '--hex-blob'
    "--result-file=$dumpFile"
    '--databases', $Database
)

if ($PSCmdlet.ShouldProcess($Database, "mysqldump to $dumpFile")) {
    Write-Verbose "Starting dump of '$Database' to $dumpFile"
    & $mysqldump @dumpArgs
    if ($LASTEXITCODE -ne 0) {
        throw "mysqldump failed with exit code $LASTEXITCODE"
    }

    # A complete dump ends with a "-- Dump completed" comment.
    $tail = Get-Content -LiteralPath $dumpFile -Tail 1
    if ($tail -notmatch 'Dump completed') {
        throw "Dump file $dumpFile appears incomplete."
    }

    # Compress (gzip) and remove the uncompressed file.
    $in = [System.IO.File]::OpenRead($dumpFile)
    try {
        $out = [System.IO.File]::Create($gzFile)
        try {
            $gzip = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionLevel]::Optimal)
            try { $in.CopyTo($gzip) } finally { $gzip.Dispose() }
        }
        finally { $out.Dispose() }
    }
    finally { $in.Dispose() }
    Remove-Item -LiteralPath $dumpFile
    Write-Verbose "Compressed to $gzFile"

    # Rotate the binary log so the current file is closed and can be copied for PITR.
    $mysql = Join-Path $MySqlBin 'mysql.exe'
    & $mysql "--defaults-extra-file=$OptionFile" --execute='FLUSH BINARY LOGS;'
    if ($LASTEXITCODE -ne 0) { Write-Warning 'FLUSH BINARY LOGS failed; binlog copy may lag.' }
}

if ($NasPath -and $PSCmdlet.ShouldProcess($NasPath, "Copy $gzFile")) {
    $nasFull = Join-Path $NasPath 'full'
    New-Item -ItemType Directory -Path $nasFull -Force | Out-Null
    Copy-Item -LiteralPath $gzFile -Destination $nasFull
    Write-Verbose "Copied to NAS: $nasFull"
}

# TODO (approved provider): encrypt and upload $gzFile + binlogs offsite (outbound HTTPS).
# Encryption keys come from the secret store, never from this repository.

$cutoff = (Get-Date).AddDays(-$LocalRetentionDays)
Get-ChildItem -LiteralPath $fullDir -Filter "$Database-*.sql.gz" |
    Where-Object { $_.LastWriteTime -lt $cutoff } |
    ForEach-Object {
        if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove expired local backup')) {
            Remove-Item -LiteralPath $_.FullName
        }
    }

Write-Output "Backup completed: $gzFile"
