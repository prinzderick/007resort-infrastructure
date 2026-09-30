<#
.SYNOPSIS
    Install the admin portal (007resort-admin-web) as its own IIS site on the LOCAL NODE (idempotent).

.DESCRIPTION
    Run this once, by hand, any time after install.ps1 has set up PHP/IIS/Composer. Node.js (LTS) must already
    be on PATH (choco install nodejs-lts). Clones the public admin-web repo, builds it (composer + npm), points
    it at this box's own API (127.0.0.1), and serves it on its own IIS site/port, firewalled the same way as
    everything else - property/office subnets only, never the internet.

.EXAMPLE
    .\install-admin.ps1 -AllowedSubnets '192.168.1.0/24'
#>
[CmdletBinding()]
param(
    [int] $Port = 8090,
    [string] $GitUrl = 'https://github.com/prinzderick/007resort-admin-web.git',
    [string] $Ref = 'main',
    [string[]] $AllowedSubnets = @('10.10.10.0/24', '10.10.20.0/24', '10.10.40.0/24'),
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\R007.Common.ps1')
Initialize-R007 -DryRun:$DryRun
Assert-R007Administrator

$paths = Get-R007Paths
$root = 'C:\R007-Admin'
$current = Join-Path $root 'current'
$phpExe = $paths.Tools + '\php\php.exe'
$composer = Join-Path $paths.Tools 'composer\composer.bat'

Write-R007Log '== Admin portal' 'STEP'
if ($DryRun) { Write-R007Log "[dry-run] git clone $GitUrl -> $current; composer install; npm build; IIS site 'R007-Admin' :$Port"; return }

if (-not (Test-Path -LiteralPath $phpExe)) { throw "$phpExe not found - run install.ps1 first." }
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw "node not found on PATH - run: choco install nodejs-lts -y, then open a fresh shell." }

New-R007Directory $root

$fresh = Join-Path $root ("checkout-" + (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))
# git clone over both HTTPS and SSH stalled indefinitely on this box the first two times this ran (git's own smart-http/
# SSH transport, specifically - every plain Invoke-WebRequest download tonight, including much larger ones, worked fine).
# Download a zip archive instead - ordinary HTTPS GET, same mechanism already proven reliable for every other download.
$owner = 'prinzderick'; $repoName = ($GitUrl -replace '.*/([^/]+?)(\.git)?$', '$1')
$zipUrl = "https://github.com/$owner/$repoName/archive/refs/heads/$Ref.zip"
$zipPath = Join-Path $paths.Downloads "$repoName-$Ref.zip"
Write-R007Log "downloading $zipUrl -> $fresh"
Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
$extractTmp = Join-Path $paths.Downloads "$repoName-extract"
if (Test-Path $extractTmp) { Remove-Item $extractTmp -Recurse -Force }
Expand-Archive -LiteralPath $zipPath -DestinationPath $extractTmp -Force
$inner = Get-ChildItem -LiteralPath $extractTmp -Directory | Select-Object -First 1
Move-Item -LiteralPath $inner.FullName -Destination $fresh
Remove-Item -LiteralPath $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

Write-R007Log 'composer install --no-dev'
Push-Location $fresh
try { Invoke-R007Native $composer @('install', '--no-dev', '--optimize-autoloader', '--no-interaction', '--prefer-dist') | Out-Null }
finally { Pop-Location }

Write-R007Log 'npm ci && npm run build'
Push-Location $fresh
try {
    Invoke-R007Native 'cmd.exe' @('/c', 'npm', 'ci', '--no-progress') | Out-Null
    Invoke-R007Native 'cmd.exe' @('/c', 'npm', 'run', 'build') | Out-Null
}
finally { Pop-Location }

# .env: created once, then left alone on future re-runs (same convention as the API's shared\.env)
$envFile = Join-Path $root 'shared.env'
if (-not (Test-Path -LiteralPath $envFile)) {
    New-R007Directory (Split-Path -Parent $envFile)
    $tpl = Get-Content -LiteralPath (Join-Path $fresh '.env.example') -Raw
    Set-Content -LiteralPath $envFile -Value $tpl -Encoding UTF8
    Set-R007EnvValue $envFile 'APP_ENV' 'production'
    Set-R007EnvValue $envFile 'APP_DEBUG' 'false'
    Set-R007EnvValue $envFile 'APP_URL' "http://192.168.1.212:$Port"
    Set-R007EnvValue $envFile 'R007_API_BASE_URL' 'http://127.0.0.1'
}
Copy-Item -LiteralPath $envFile -Destination (Join-Path $fresh '.env') -Force

$key = Get-R007EnvValue $envFile 'APP_KEY'
if ([string]::IsNullOrWhiteSpace($key)) {
    $newKey = (& $phpExe (Join-Path $fresh 'artisan') key:generate --show).Trim()
    Set-R007EnvValue $envFile 'APP_KEY' $newKey
    Copy-Item -LiteralPath $envFile -Destination (Join-Path $fresh '.env') -Force
}

foreach ($c in @('config:cache', 'route:cache', 'view:cache')) {
    Push-Location $fresh
    try { & $phpExe artisan $c } finally { Pop-Location }
}
if (-not (Test-Path -LiteralPath (Join-Path $fresh 'public\storage'))) {
    Push-Location $fresh
    try { & $phpExe artisan storage:link } finally { Pop-Location }
}

# 007resort-admin-web ships no public/web.config of its own (unlike the API repo, which gets one via
# update.ps1's web.config.template) - without the Laravel front-controller rewrite rule, IIS's default-document
# handoff still serves "/" (200) but any pretty route like "/login" 404s, since there's no physical file at
# that path and nothing tells IIS to hand it to index.php. Same content as the API's web.config.template.
$webConfigContent = @'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Managed by 007resort-infrastructure (scripts/windows/install-admin.ps1 writes this into each release's public/). -->
<configuration>
  <system.webServer>
    <!-- The PHP-FastCGI handler is registered once, globally, by install.ps1 (system.webServer/handlers is
         locked at the parent level by default in a stock IIS install, so declaring it again per-release here
         fails with "This configuration section cannot be used at this path", IIS error 500.19). -->
    <defaultDocument>
      <files>
        <clear />
        <add value="index.php" />
      </files>
    </defaultDocument>
    <rewrite>
      <rules>
        <rule name="Laravel front controller" stopProcessing="true">
          <match url="^" ignoreCase="false" />
          <conditions logicalGrouping="MatchAll">
            <add input="{REQUEST_FILENAME}" matchType="IsFile" negate="true" />
            <add input="{REQUEST_FILENAME}" matchType="IsDirectory" negate="true" />
          </conditions>
          <action type="Rewrite" url="index.php" />
        </rule>
      </rules>
    </rewrite>
    <security>
      <requestFiltering allowDoubleEscaping="false">
        <requestLimits maxAllowedContentLength="20971520" />
        <hiddenSegments>
          <add segment=".git" />
          <add segment=".env" />
        </hiddenSegments>
        <fileExtensions>
          <add fileExtension=".env" allowed="false" />
          <add fileExtension=".log" allowed="false" />
        </fileExtensions>
      </requestFiltering>
    </security>
    <httpProtocol>
      <customHeaders>
        <remove name="X-Powered-By" />
        <add name="X-Content-Type-Options" value="nosniff" />
        <add name="X-Frame-Options" value="SAMEORIGIN" />
        <add name="Referrer-Policy" value="strict-origin-when-cross-origin" />
      </customHeaders>
    </httpProtocol>
    <httpErrors errorMode="DetailedLocalOnly" existingResponse="PassThrough" />
  </system.webServer>
</configuration>
'@
Set-Content -LiteralPath (Join-Path $fresh 'public\web.config') -Value $webConfigContent -Encoding UTF8

Set-R007Junction $current $fresh

# IIS site + own app pool, same pattern proven out for phpMyAdmin
Import-Module WebAdministration
$pool = 'R007-Admin'
if (-not (Test-Path "IIS:\AppPools\$pool")) { New-WebAppPool -Name $pool | Out-Null }
Set-ItemProperty "IIS:\AppPools\$pool" -Name managedRuntimeVersion -Value ''
Set-ItemProperty "IIS:\AppPools\$pool" -Name startMode -Value 'AlwaysRunning'
Set-ItemProperty "IIS:\AppPools\$pool" -Name processModel.identityType -Value 'ApplicationPoolIdentity'

$site = 'R007-Admin'
$phys = Join-Path $current 'public'
if (-not (Get-Website -Name $site -ErrorAction SilentlyContinue)) {
    New-Website -Name $site -PhysicalPath $phys -ApplicationPool $pool -Port $Port -Force | Out-Null
} else {
    Set-ItemProperty "IIS:\Sites\$site" -Name physicalPath -Value $phys
}
Start-Website -Name $site -ErrorAction SilentlyContinue

$vsa = "IIS AppPool\$pool"
Set-R007Acl -Path $root -Grants @{ $vsa = 'ReadAndExecute' } -Inherit
Set-R007Acl -Path (Join-Path $fresh 'storage') -Grants @{ $vsa = 'Modify' } -Inherit
Set-R007Acl -Path (Join-Path $fresh 'bootstrap\cache') -Grants @{ $vsa = 'Modify' } -Inherit
Set-R007Acl -Path $envFile -Grants @{ $vsa = 'Read' }

# clean up older checkouts, keep the current one + 1 previous
Get-ChildItem -LiteralPath $root -Directory -Filter 'checkout-*' | Sort-Object Name -Descending | Select-Object -Skip 2 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# firewall: same AllowedSubnets pattern as the main site
$ruleName = 'R007 Admin (property VLANs)'
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $Port -RemoteAddress @($AllowedSubnets) -Action Allow | Out-Null
} else {
    Set-NetFirewallRule -DisplayName $ruleName -RemoteAddress @($AllowedSubnets) | Out-Null
}

Write-R007Log "admin portal ready: http://<this server>:$Port/" 'OK'
