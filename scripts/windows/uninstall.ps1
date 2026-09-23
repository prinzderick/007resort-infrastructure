<#
.SYNOPSIS
    Remove the LOCAL NODE components installed by install.ps1. Data is KEPT unless you explicitly ask.

.DESCRIPTION
    Always removes: NSSM services (R007-*), scheduled tasks (R007 *), firewall rules (group R007), IIS site/app pool R007.
    Optional:
      -RemoveMySql     stop and delete the R007MySQL service (the data directory is kept)
      -RemoveData      DELETE C:\R007 (releases, shared\.env, storage, logs, secrets, tools) and, with -RemoveMySql,
                       the MySQL data directory. Backups (BackupRoot / NAS) are NEVER deleted by this script.
                       Requires -Force and typing the word DELETE.
    Chocolatey packages (php, nssm, memurai) are left installed; remove them with choco if you want.

.EXAMPLE
    .\uninstall.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [switch] $RemoveMySql,
    [switch] $RemoveData,
    [switch] $Force,
    [switch] $DryRun
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\R007.Common.ps1')
Initialize-R007 -DryRun:$DryRun
Assert-R007Administrator
$paths = Get-R007Paths
$state = Get-R007State

if ($RemoveData -and -not $DryRun) {
    if (-not $Force) { throw '-RemoveData needs -Force.' }
    $answer = Read-Host 'This permanently deletes the application, .env and secrets under C:\R007. Type DELETE to continue'
    if ($answer -ne 'DELETE') { throw 'Cancelled.' }
}

$svcNames = @(Get-R007ServiceDefinitions -State $state | ForEach-Object { $_.Name })
Stop-R007Services $svcNames
if (Test-R007Windows -or -not $DryRun) {
    foreach ($n in $svcNames) {
        if (Get-R007Service -Name $n) { Invoke-R007Step "remove service $n" { Invoke-R007Native (Get-R007NssmPath) @('remove', $n, 'confirm') | Out-Null } }
    }
    foreach ($t in @('R007 Scheduler', 'R007 Nightly Backup', 'R007 Log Cleanup')) {
        Invoke-R007Step "remove scheduled task $t" { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
    }
    Invoke-R007Step 'remove firewall rules (group R007)' { Get-NetFirewallRule -Group 'R007' -ErrorAction SilentlyContinue | Remove-NetFirewallRule }
    Invoke-R007Step 'remove IIS site and app pool' {
        Import-Module WebAdministration
        if (Get-Website -Name $state.SiteName -ErrorAction SilentlyContinue) { Remove-Website -Name $state.SiteName }
        if (Test-Path "IIS:\AppPools\$($state.AppPool)") { Remove-WebAppPool -Name $state.AppPool }
    }
}
if ($RemoveMySql) {
    Stop-R007Services @($state.MySqlService)
    Invoke-R007Step "remove MySQL service $($state.MySqlService)" {
        $mysqld = Join-Path $state.MySqlBin 'mysqld.exe'
        if (Test-Path -LiteralPath $mysqld) { Invoke-R007Native $mysqld @('--remove', $state.MySqlService) -AllowFailure | Out-Null }
    }
}
if ($RemoveData) {
    if ($RemoveMySql) { Invoke-R007Step "delete MySQL data $($state.MySqlData)" { Remove-Item -LiteralPath $state.MySqlData -Recurse -Force -ErrorAction SilentlyContinue } }
    foreach ($r in @(Get-ChildItem -LiteralPath $paths.Releases -Directory -ErrorAction SilentlyContinue)) { Invoke-R007Step "delete release $($r.Name)" { Remove-R007Release $r.FullName } }
    Invoke-R007Step "delete $($paths.Root)" {
        if (Test-Path -LiteralPath $paths.Current) { [System.IO.Directory]::Delete($paths.Current, $false) }
        Remove-Item -LiteralPath $paths.Root -Recurse -Force
    }
}
Write-R007Log 'Uninstall finished. Backups were not touched.' 'OK'
