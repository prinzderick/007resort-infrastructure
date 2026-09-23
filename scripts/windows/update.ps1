<#
.SYNOPSIS
    Deploy a new release of the Laravel app to the LOCAL NODE, migrate, restart services, health-check, roll back on failure.

.DESCRIPTION
    Flow (the property keeps serving from the OLD release until the swap; only the workers restart):
      1. unpack the package into C:\R007\releases\<id>  (or git clone + composer install --no-dev)
      2. link shared\.env and shared\storage into the release, add web.config, set ACLs
      3. php artisan migrate --force (DDL account from .env), then config/route/event/view cache
      4. stop R007-* services, swap the C:\R007\current junction, start services, recycle the IIS app pool
      5. health check http://127.0.0.1/up (and /api/v1/system/info); failure => automatic rollback
      6. keep the newest -Keep releases
    Migrations must be backward compatible with the previous release (expand/contract): a rollback swaps
    code, it never reverses the database. Take a manual backup first for risky releases:
    C:\R007\scripts\backup-mysql.ps1

.PARAMETER Package
    Release ZIP built by CI (contains vendor/, no dev dependencies).
.PARAMETER GitUrl
    Alternative to -Package: clone this repo at -Ref and run composer install --no-dev on the server.
.PARAMETER Rollback
    Swap back to the previous release (or -ToRelease <id>) and restart. No migration is reversed.

.EXAMPLE
    .\update.ps1 -Package D:\incoming\r007-3f9c1a2b7d10.zip
.EXAMPLE
    .\update.ps1 -Rollback
.EXAMPLE
    .\update.ps1 -Package .\r007.zip -DryRun
#>
[CmdletBinding()]
param(
    [string] $Package,
    [string] $GitUrl,
    [string] $Ref = 'main',
    [string] $ReleaseId,
    [switch] $Rollback,
    [string] $ToRelease,
    [switch] $NoMigrate,
    [switch] $AllowPlaceholders,
    [ValidateRange(2, 50)][int] $Keep = 5,
    [string] $HealthUrl = 'http://127.0.0.1/up',
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\R007.Common.ps1')
Initialize-R007 -DryRun:$DryRun
Assert-R007Administrator

$paths = Get-R007Paths
$state = Get-R007State
$php = $state.PhpExe
$svcNames = @(Get-R007ServiceDefinitions -State $state | ForEach-Object { $_.Name })
$localSvc = 'NT AUTHORITY\LOCAL SERVICE'
$poolAccount = "IIS AppPool\$($state.AppPool)"

function Test-R007Health {
    param([string] $Url, [int] $Seconds = 45)
    if ($DryRun) { Write-R007Log "[dry-run] health check $Url"; return $true }
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-R007Http -Url $Url
        if ($r.Ok) { Write-R007Log "health OK ($Url -> $($r.Status))" 'OK'; return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Switch-R007Release {
    <# Stop workers, point 'current' at the release, start workers, recycle IIS. #>
    param([string] $Id)
    $target = Join-Path $paths.Releases $Id
    Stop-R007Services $svcNames
    Set-R007Junction $paths.Current $target
    Start-R007Services $svcNames
    Invoke-R007Step "recycle IIS app pool $($state.AppPool)" {
        Import-Module WebAdministration
        Restart-WebAppPool -Name $state.AppPool
    }
}

function Invoke-R007Artisan {
    param([string] $ReleaseDir, [string[]] $Arguments, [hashtable] $ExtraEnv = @{})
    Invoke-R007Step "php artisan $($Arguments -join ' ')" {
        Push-Location $ReleaseDir
        $saved = @{}
        try {
            foreach ($k in $ExtraEnv.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process'); [Environment]::SetEnvironmentVariable($k, $ExtraEnv[$k], 'Process') }
            Invoke-R007Native $php (@('artisan') + $Arguments) | Out-Null
        }
        finally {
            foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
            Pop-Location
        }
    }
}

# ---- Rollback ------------------------------------------------------------------------------------------
if ($Rollback) {
    $lock = Enter-R007Lock 'deploy'
    try {
        $cur = Get-R007CurrentRelease
        $target = $ToRelease
        if (-not $target) {
            $prevFile = Join-Path $paths.Shared '.previous_release'
            if (Test-Path -LiteralPath $prevFile) { $target = (Get-Content -LiteralPath $prevFile -Raw).Trim() }
        }
        if (-not $target -and $DryRun) { $target = '<previous>' }
        if (-not $target) { throw 'No previous release recorded. Use -ToRelease <id> (see: dir C:\R007\releases).' }
        if (-not (Test-Path -LiteralPath (Join-Path $paths.Releases $target)) -and -not $DryRun) { throw "Release not found: $target" }
        Write-R007Log "rolling back: $cur -> $target (database is NOT reverted)" 'WARN'
        Switch-R007Release $target
        if (-not (Test-R007Health $HealthUrl)) { throw 'Health check still failing after rollback - see runbooks/incident-response.md.' }
        Write-R007Log 'rollback complete' 'OK'
    }
    finally { Exit-R007Lock $lock }
    return
}

# ---- Deploy -----------------------------------------------------------------------------------------------
if (-not $Package -and -not $GitUrl) { throw 'Give -Package <zip> or -GitUrl <url> [-Ref <ref>] (or -Rollback).' }
if ($Package -and -not $DryRun -and -not (Test-Path -LiteralPath $Package)) { throw "Package not found: $Package" }
if (-not $DryRun) {
    if (-not (Test-Path -LiteralPath $paths.EnvFile)) { throw "$($paths.EnvFile) missing - run install.ps1 first." }
    if ((Get-R007EnvValue $paths.EnvFile 'APP_NODE') -ne 'local') { throw 'APP_NODE in .env is not "local".' }
    $left = @(Get-R007EnvPlaceholders $paths.EnvFile | Where-Object { $_ -ne 'APP_KEY' })
    if ($left.Count -gt 0 -and -not $AllowPlaceholders) { throw ("shared\.env still has placeholders: " + ($left -join ', ') + ' (fill them, or use -AllowPlaceholders for a demo).') }
}

$sha = ''
if ($Package) { $sha = ([IO.Path]::GetFileNameWithoutExtension($Package) -replace '^r007-', '') }
elseif ($GitUrl) { $sha = ($Ref -replace '[^A-Za-z0-9._-]', '-') }
if (-not $ReleaseId) { $ReleaseId = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss') + $(if ($sha) { "-$sha" } else { '' }) }
$relDir = Join-Path $paths.Releases $ReleaseId
if ((Test-Path -LiteralPath $relDir) -and -not $DryRun) { throw "Release $ReleaseId already exists." }

$lock = Enter-R007Lock 'deploy'
$switched = $false
try {
    $prev = if ($DryRun -and -not (Test-R007Windows)) { '' } else { Get-R007CurrentRelease }
    Write-R007Log "deploying $ReleaseId (previous: $(if ($prev) { $prev } else { 'none' }))"

    if ($Package) {
        Invoke-R007Step "extract $Package -> $relDir" { Expand-Archive -LiteralPath $Package -DestinationPath $relDir -Force }
    }
    else {
        Invoke-R007Step "git clone $GitUrl@$Ref -> $relDir" {
            Invoke-R007Native 'git.exe' @('clone', '--quiet', '--depth', '1', '--branch', $Ref, $GitUrl, $relDir) | Out-Null
            Remove-Item -LiteralPath (Join-Path $relDir '.git') -Recurse -Force
        }
    }
    if (-not $DryRun -and -not (Test-Path -LiteralPath (Join-Path $relDir 'artisan'))) { throw 'No artisan in the release: the package must contain the Laravel app root.' }

    Invoke-R007Step 'link shared storage and .env, add web.config' {
        $storage = Join-Path $relDir 'storage'
        if (Test-Path -LiteralPath $storage) {
            Copy-Item -Path (Join-Path $storage '*') -Destination $paths.Storage -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $storage -Recurse -Force
        }
        New-Item -ItemType Junction -Path $storage -Target $paths.Storage | Out-Null
        try { New-Item -ItemType SymbolicLink -Path (Join-Path $relDir '.env') -Target $paths.EnvFile | Out-Null }
        catch { Copy-Item -LiteralPath $paths.EnvFile -Destination (Join-Path $relDir '.env'); Write-R007Log '.env copied (symlink not permitted); re-run update after editing shared\.env.' 'WARN' }
        $tpl = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'templates\web.config.template') -Raw
        Set-Content -LiteralPath (Join-Path $relDir 'public\web.config') -Value $tpl.Replace('@@PHPCGI@@', $state.PhpCgi) -Encoding UTF8
        foreach ($d in @('bootstrap\cache')) { New-Item -ItemType Directory -Path (Join-Path $relDir $d) -Force | Out-Null }
        icacls.exe $relDir /grant "${localSvc}:(OI)(CI)RX" "${poolAccount}:(OI)(CI)RX" /T /C /Q | Out-Null
        icacls.exe (Join-Path $relDir 'bootstrap\cache') /grant "${localSvc}:(OI)(CI)M" "${poolAccount}:(OI)(CI)M" /T /C /Q | Out-Null
    }

    if ($GitUrl -or -not (Test-Path -LiteralPath (Join-Path $relDir 'vendor\autoload.php'))) {
        Invoke-R007Step 'composer install --no-dev' {
            Push-Location $relDir
            try { Invoke-R007Native (Join-Path $paths.Tools 'composer\composer.bat') @('install', '--no-dev', '--optimize-autoloader', '--no-interaction', '--prefer-dist') | Out-Null }
            finally { Pop-Location }
        }
    }

    if (-not $DryRun) {
        $key = Get-R007EnvValue $paths.EnvFile 'APP_KEY'
        if (Test-R007Placeholder $key) {
            Write-R007Log 'APP_KEY empty: generating (first deploy). Back up shared\.env - losing APP_KEY makes encrypted data unreadable.' 'WARN'
            $newKey = (& $php (Join-Path $relDir 'artisan') key:generate --show).Trim()
            Set-R007EnvValue $paths.EnvFile 'APP_KEY' $newKey
        }
    }

    if (-not $NoMigrate) {
        $mu = if ($DryRun) { '' } else { Get-R007EnvValue $paths.EnvFile 'DB_MIGRATOR_USERNAME' }
        $mp = if ($DryRun) { '' } else { Get-R007EnvValue $paths.EnvFile 'DB_MIGRATOR_PASSWORD' }
        $extra = @{}
        if ($mu -and $mp) { $extra = @{ DB_USERNAME = $mu; DB_PASSWORD = $mp } }
        Invoke-R007Artisan -ReleaseDir $relDir -Arguments @('migrate', '--force') -ExtraEnv $extra
    }
    foreach ($c in @('config:cache', 'route:cache', 'event:cache', 'view:cache')) { Invoke-R007Artisan -ReleaseDir $relDir -Arguments @($c) }

    Switch-R007Release $ReleaseId
    $switched = $true
    if (-not $DryRun) { Set-Content -LiteralPath (Join-Path $paths.Shared '.previous_release') -Value $prev -Encoding ASCII }

    $ok = Test-R007Health $HealthUrl
    if ($ok) { $info = Invoke-R007Http -Url ($HealthUrl -replace '/up$', '/api/v1/system/info'); if ($info.Ok -and -not $DryRun) { Write-R007Log "system/info: $($info.Body)" } }
    if (-not $ok) {
        Write-R007Log "health check FAILED after deploying $ReleaseId" 'ERROR'
        if ($prev) { Write-R007Log "rolling back to $prev" 'WARN'; Switch-R007Release $prev; if (-not (Test-R007Health $HealthUrl)) { Write-R007Log 'still failing after rollback - investigate immediately' 'ERROR' } }
        throw "Deploy of $ReleaseId failed the health check."
    }

    Invoke-R007Step "prune old releases (keep $Keep)" {
        $cur = Get-R007CurrentRelease
        $dirs = Get-ChildItem -LiteralPath $paths.Releases -Directory | Sort-Object Name -Descending
        $i = 0
        foreach ($d in $dirs) {
            $i++
            if ($i -gt $Keep -and $d.Name -ne $cur -and $d.Name -ne $prev) { Remove-R007Release $d.FullName; Write-R007Log "removed release $($d.Name)" }
        }
    }
    Write-R007Log "deploy complete: $ReleaseId" 'OK'
}
catch {
    if (-not $switched -and -not $DryRun -and (Test-Path -LiteralPath $relDir)) {
        Write-R007Log "deploy failed before the switch; removing $relDir (running release untouched)" 'WARN'
        try { Remove-R007Release $relDir } catch { Write-R007Log "cleanup of $relDir failed: $($_.Exception.Message)" 'WARN' }
    }
    throw
}
finally { Exit-R007Lock $lock }
