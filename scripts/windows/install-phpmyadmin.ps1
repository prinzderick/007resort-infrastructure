<#
.SYNOPSIS
    Optional: install phpMyAdmin for the LOCAL NODE's MySQL, reachable on the property/office network (idempotent).

.DESCRIPTION
    Run this once, by hand, AFTER install.ps1 has completed successfully (it needs the root credentials
    install.ps1 writes to C:\R007\secrets\mysql-admin.cnf). Not part of the default install: MySQL itself stays
    bound to 127.0.0.1 and untouched by this script; only a browser-based admin UI is added, on its own IIS site
    and its own port, firewalled the same way as the main app (AllowedSubnets only - never the internet).

    - Downloads the official phpMyAdmin release (English-only build), extracts it under C:\R007\tools\phpmyadmin.
    - Creates a dedicated MySQL account for it, 'r007_dba'@'127.0.0.1' (NOT root), full privileges, its own
      generated password saved to C:\R007\secrets\mysql-dba.cnf (Admins/SYSTEM only) - use that account to log
      in, not root, so the daily-use login isn't the one credential that unlocks everything else on the box.
    - phpMyAdmin's own config.inc.php uses cookie auth (no username/password baked in): it always shows its own
      login form, so the person opening the URL still has to authenticate with real MySQL credentials.
    - New IIS site 'R007-PhpMyAdmin' on -Port (default 8082), own app pool, reusing the PHP FastCGI registration
      install.ps1 already set up. New firewall rule scoped to -AllowedSubnets, same pattern as the main site.

.EXAMPLE
    .\install-phpmyadmin.ps1 -DryRun
.EXAMPLE
    .\install-phpmyadmin.ps1 -AllowedSubnets '192.168.1.0/24','10.10.10.0/24','10.10.20.0/24','10.10.40.0/24'
#>
[CmdletBinding()]
param(
    [int] $Port = 8082,
    [string] $Version = '5.2.2',
    [string] $Sha256,
    [string[]] $AllowedSubnets = @('10.10.10.0/24', '10.10.20.0/24', '10.10.40.0/24'),
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\R007.Common.ps1')
Initialize-R007 -DryRun:$DryRun
Assert-R007Administrator

$paths = Get-R007Paths
$adminCnf = Join-Path $paths.Secrets 'mysql-admin.cnf'
if (-not (Test-Path -LiteralPath $adminCnf)) {
    throw "C:\R007\secrets\mysql-admin.cnf not found - run install.ps1 first and let it finish the MySQL step."
}

$name = "phpMyAdmin-$Version-english"
$zipName = "$name.zip"
$dest = Join-Path $paths.Tools 'phpmyadmin'

Write-R007Log '== phpMyAdmin' 'STEP'
if ($DryRun) {
    Write-R007Log "[dry-run] download phpMyAdmin $Version; create MySQL user r007_dba@127.0.0.1; config.inc.php; IIS site 'R007-PhpMyAdmin' :$Port; firewall rule for $($AllowedSubnets -join ', ')"
    return
}

# ---- download + extract (same junction pattern as the MySQL step in install.ps1) --------------------------------
if (-not (Test-Path -LiteralPath (Join-Path $dest 'index.php'))) {
    $zip = Join-Path $paths.Downloads $zipName
    $url = "https://files.phpmyadmin.net/phpMyAdmin/$Version/$zipName"
    Write-R007Log "downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    if ($Sha256) {
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash -ne $Sha256.ToUpperInvariant()) { throw 'phpMyAdmin ZIP SHA256 mismatch.' }
    } else {
        Write-R007Log 'No -Sha256 given: compare the ZIP against the checksum published on phpmyadmin.net before trusting it.' 'WARN'
    }
    $tmp = Join-Path $paths.Downloads 'phpmyadmin-extract'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $inner = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Move-Item -LiteralPath $inner.FullName -Destination $dest
    # ship no sample config / setup script / docs on a real box
    foreach ($f in @('config.sample.inc.php', 'setup', 'doc', 'examples', 'test', 'ChangeLog', 'composer.json', 'composer.lock')) {
        $p = Join-Path $dest $f
        if (Test-Path $p) { Remove-Item $p -Recurse -Force }
    }
}

# ---- dedicated MySQL account (not root) ---------------------------------------------------------------------
$mysql = Join-Path $paths.Tools 'mysql\bin\mysql.exe'
$dbaCnf = Join-Path $paths.Secrets 'mysql-dba.cnf'
$dbaPw = $null
if (Test-Path -LiteralPath $dbaCnf) {
    $existing = Get-Content -LiteralPath $dbaCnf | Where-Object { $_ -match '^password=' } | Select-Object -First 1
    if ($existing) { $dbaPw = $existing -replace '^password=', '' }
}
if (-not $dbaPw) { $dbaPw = New-R007Secret 32 }
$sql = @"
CREATE USER IF NOT EXISTS 'r007_dba'@'127.0.0.1' IDENTIFIED BY '$dbaPw';
ALTER USER 'r007_dba'@'127.0.0.1' IDENTIFIED BY '$dbaPw';
GRANT ALL PRIVILEGES ON *.* TO 'r007_dba'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
"@
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$sql | & $mysql "--defaults-extra-file=$adminCnf" 2>$null
$ErrorActionPreference = $prevEap
if ($LASTEXITCODE -ne 0) { throw 'Could not create the r007_dba MySQL account.' }
Set-Content -LiteralPath $dbaCnf -Value "[client]`r`nuser=r007_dba`r`npassword=$dbaPw`r`nhost=127.0.0.1`r`nport=3306" -Encoding ASCII
Set-R007Acl -Path $dbaCnf
Write-R007Log "MySQL account r007_dba ready (password in $dbaCnf - use this to log in, not root)" 'OK'

# ---- config.inc.php (cookie auth: always shows phpMyAdmin's own login form) ----------------------------------
$blowfish = New-R007Secret 32
$config = @"
<?php
`$cfg['blowfish_secret'] = '$blowfish';
`$i = 1;
`$cfg['Servers'][`$i]['auth_type'] = 'cookie';
`$cfg['Servers'][`$i]['host'] = '127.0.0.1';
`$cfg['Servers'][`$i]['port'] = 3306;
`$cfg['Servers'][`$i]['AllowNoPassword'] = false;
`$cfg['UploadDir'] = '';
`$cfg['SaveDir'] = '';
`$cfg['LoginCookieValidity'] = 1800;
"@
$configPath = Join-Path $dest 'config.inc.php'
Set-Content -LiteralPath $configPath -Value $config -Encoding ASCII

# ---- IIS site, own app pool, reuse the existing PHP FastCGI registration -------------------------------------
Import-Module WebAdministration
$pool = 'R007-PhpMyAdmin'
if (-not (Test-Path "IIS:\AppPools\$pool")) { New-WebAppPool -Name $pool | Out-Null }
Set-ItemProperty "IIS:\AppPools\$pool" -Name managedRuntimeVersion -Value ''
Set-ItemProperty "IIS:\AppPools\$pool" -Name startMode -Value 'AlwaysRunning'
Set-ItemProperty "IIS:\AppPools\$pool" -Name processModel.identityType -Value 'ApplicationPoolIdentity'

$site = 'R007-PhpMyAdmin'
if (-not (Get-Website -Name $site -ErrorAction SilentlyContinue)) {
    New-Website -Name $site -PhysicalPath $dest -ApplicationPool $pool -Port $Port -Force | Out-Null
} else {
    Set-ItemProperty "IIS:\Sites\$site" -Name physicalPath -Value $dest
}
Start-Website -Name $site -ErrorAction SilentlyContinue
# No web.config for this site (it ships its own, and phpMyAdmin doesn't need our template), so IIS's
# server-wide default document list applies - which does not include index.php, giving a 403 on '/'.
Add-WebConfiguration -PSPath "IIS:\Sites\$site" -Filter 'system.webServer/defaultDocument/files' -Value @{ value = 'index.php' } -ErrorAction SilentlyContinue

# the app pool identity needs read on config.inc.php (it carries the blowfish secret - keep it tight)
Set-R007Acl -Path $configPath -Grants @{ "IIS AppPool\$pool" = 'Read' }
Set-R007Acl -Path $dest -Grants @{ "IIS AppPool\$pool" = 'ReadAndExecute' } -Inherit

# ---- firewall: same AllowedSubnets pattern as the main site, this port only -----------------------------------
$ruleName = 'R007 phpMyAdmin (property VLANs)'
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $Port -RemoteAddress @($AllowedSubnets) -Action Allow | Out-Null
} else {
    Set-NetFirewallRule -DisplayName $ruleName -RemoteAddress @($AllowedSubnets) | Out-Null
}

Write-R007Log "phpMyAdmin ready: http://<this server>:$Port/  (log in as r007_dba - password in $dbaCnf)" 'OK'
