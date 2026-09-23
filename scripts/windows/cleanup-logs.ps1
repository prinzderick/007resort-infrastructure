<#
.SYNOPSIS
    Delete old logs (services, PHP, MySQL error log, IIS) so the disk never fills. Runs daily as "R007 Log Cleanup".
.DESCRIPTION
    NSSM already rotates service stdout/stderr by size and age; Laravel's daily channel prunes its own files
    (LOG_DAILY_DAYS). This removes what is left behind and IIS logs. Nothing in releases/, shared/.env or backups is touched.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 3650)][int] $KeepDays = 14,
    [ValidateRange(1, 3650)][int] $IisKeepDays = 30,
    [switch] $DryRun
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\R007.Common.ps1')
Initialize-R007 -DryRun:$DryRun
$paths = Get-R007Paths

function Remove-Old {
    param([string] $Dir, [string[]] $Include, [int] $Days)
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    $cut = (Get-Date).AddDays(-$Days)
    Get-ChildItem -LiteralPath $Dir -Recurse -File -Include $Include -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut } | ForEach-Object {
        Invoke-R007Step "delete $($_.FullName)" { Remove-Item -LiteralPath $_.FullName -Force }
    }
}
Remove-Old -Dir $paths.Logs -Include @('*.log', '*.log.*', '*.1', '*.2') -Days $KeepDays
Remove-Old -Dir (Join-Path $paths.Storage 'logs') -Include @('*.log') -Days $KeepDays
Remove-Old -Dir 'C:\inetpub\logs\LogFiles' -Include @('*.log') -Days $IisKeepDays
