<#
.SYNOPSIS
    Install and configure the 007 Resort & Spa LOCAL NODE on Windows Server (idempotent).

.DESCRIPTION
    Installs / configures, in order (each step can be run alone with -Steps):
      Preflight, Directories, Env, Packages, Php, MySql, Redis, Iis, Services, Scheduler, Firewall, Backup, Acl

      Packages  Chocolatey: php (NTS 8.4.x), nssm, vcredist, urlrewrite, memurai-developer
      Php       php.ini, extensions (+ phpredis), FastCGI registration in IIS, Composer (signature-checked)
      MySql     MySQL 8.4 from the official ZIP (or -MySqlZip), own my.ini, service R007MySQL, localhost only
      Redis     Memurai (Redis-compatible Windows service), bound to 127.0.0.1 with a password
      Iis       IIS + CGI + URL Rewrite, app pool R007, site R007 -> C:\R007\current\public
      Services  NSSM services: R007-Queue, R007-Sync, R007-Reverb (auto start, restart on failure, log rotation)
      Scheduler Task "R007 Scheduler": php artisan schedule:run every minute
      Firewall  Inbound only from the property subnets (never from the internet)
      Backup    Nightly mysqldump task (NAS copy + retention) + log-cleanup task
      Acl       Locks down .env / secrets / storage

    Secrets: nothing is stored in this script. Database, Redis and Reverb secrets are GENERATED and written to the
    protected C:\R007\shared\.env (ACL: Administrators, SYSTEM, the services). The node credential is typed at a secure
    prompt (or supplied in a pre-made -EnvFile). MySQL admin/backup credentials live in C:\R007\secrets (Admins/SYSTEM only).

    Redis licence note: memurai-developer is the free DEVELOPER edition. For production buy a Memurai licence
    (pass -MemuraiPackage with your licensed package) or run Redis-compatible software yourself and use
    -RedisProvider External (e.g. Garnet, or Redis inside WSL2 bound to 127.0.0.1). See runbooks/server-installation.md.

    After install, deploy the application: C:\R007\scripts\update.ps1 -Package <r007-xxxx.zip>

.PARAMETER DryRun
    Print every action, change nothing (works on any OS with PowerShell 7 for a syntax/flow check).

.EXAMPLE
    .\install.ps1 -DryRun
.EXAMPLE
    .\install.ps1 -NasPath '\\nas.site.local\r007-backups' -AppUrl 'http://r007-api.site.local' -NodeSiteId 'SITE-001'
#>
[CmdletBinding()]
param(
    [string] $EnvFile,
    [string] $AppUrl,
    [string] $NodeSiteId,
    [string] $SyncPeerUrl,
    [string] $PhpVersionPrefix = '8.4.',
    [string] $PhpRedisVersion = '6.2.0',
    [string] $MySqlVersion = '8.4.6',
    [string] $MySqlZip,
    [string] $MySqlZipSha256,
    [string] $MySqlDataDir,
    [string] $BackupRoot,
    [string] $NasPath = '',
    [string[]] $AllowedSubnets = @('10.10.10.0/24', '10.10.20.0/24', '10.10.40.0/24'),
    [switch] $AllowPublicSubnets,
    [string] $CertThumbprint,
    [ValidateSet('Memurai', 'External', 'Skip')][string] $RedisProvider = 'Memurai',
    [string] $MemuraiPackage = 'memurai-developer',
    [ValidateSet('Preflight', 'Directories', 'Env', 'Packages', 'Php', 'MySql', 'Redis', 'Iis', 'Services', 'Scheduler', 'Firewall', 'Backup', 'Acl')]
    [string[]] $Steps = @('Preflight', 'Directories', 'Env', 'Packages', 'Php', 'MySql', 'Redis', 'Iis', 'Services', 'Scheduler', 'Firewall', 'Backup', 'Acl'),
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\R007.Common.ps1')
Initialize-R007 -DryRun:$DryRun

$paths = Get-R007Paths
$localSvc = 'NT AUTHORITY\LOCAL SERVICE'
$poolAccount = 'IIS AppPool\R007'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # <repo>\scripts\windows -> <repo>
$templateDir = Join-Path $PSScriptRoot 'templates'

if (-not $MySqlDataDir) { $MySqlDataDir = if (Test-Path 'D:\') { 'D:\MySQL\data' } else { Join-Path $paths.Root 'mysql-data' } }
if (-not $BackupRoot) { $BackupRoot = if (Test-Path 'D:\') { 'D:\R007Backups' } else { Join-Path $paths.Root 'backups' } }

$state = @{
    PhpExe = Join-Path $paths.Tools 'php\php.exe'; PhpCgi = Join-Path $paths.Tools 'php\php-cgi.exe'
    MySqlBin = Join-Path $paths.Tools 'mysql\bin'; MySqlData = $MySqlDataDir; BackupRoot = $BackupRoot; NasPath = $NasPath
    Subnets = $AllowedSubnets; HttpPort = 80; ReverbPort = 8085; SiteName = 'R007'; AppPool = 'R007'; Database = 'r007'
    MySqlService = 'R007MySQL'; RedisService = 'Memurai'; RedisProvider = $RedisProvider
}

function Test-Step { param([string] $Name) return ($Steps -contains $Name) }

# ------------------------------------------------------------------------------------------------
function Invoke-Preflight {
    Write-R007Log '== Preflight' 'STEP'
    Assert-R007Administrator
    if (Test-R007Windows) {
        $os = (Get-CimInstance Win32_OperatingSystem).Caption
        Write-R007Log "OS: $os"
        if ($os -notmatch 'Server') { Write-R007Log 'Not Windows Server - fine for a demo box, not for the property.' 'WARN' }
    }
    foreach ($s in $AllowedSubnets) {
        if ($s -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') { throw "Invalid subnet '$s' (use CIDR, e.g. 10.10.20.0/24)." }
        $private = ($s -match '^10\.') -or ($s -match '^192\.168\.') -or ($s -match '^172\.(1[6-9]|2\d|3[01])\.')
        if (-not $private -and -not $AllowPublicSubnets) { throw "Subnet '$s' is not private (RFC1918). The Local node must never accept traffic from the internet." }
        if ($s -match '^0\.0\.0\.0') { throw "Subnet '$s' would open the server to everyone." }
    }
    if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue) -and (Test-Step 'Packages') -and -not $DryRun) {
        throw 'Chocolatey is required (install it once from https://chocolatey.org/install, run by an administrator, then re-run).'
    }
}

function Initialize-Directories {
    Write-R007Log '== Directories' 'STEP'
    foreach ($d in @($paths.Root, $paths.Releases, $paths.Shared, $paths.Storage, $paths.Logs, $paths.Secrets, $paths.Tools, $paths.Scripts, $paths.Downloads, $BackupRoot, $MySqlDataDir)) {
        New-R007Directory $d
    }
    foreach ($sub in @('app\public', 'framework\cache\data', 'framework\sessions', 'framework\views', 'logs')) { New-R007Directory (Join-Path $paths.Storage $sub) }
    # Self-contained copies so scheduled tasks and update.ps1 do not depend on this checkout.
    $sameDir = ((Resolve-Path -LiteralPath $PSScriptRoot).Path.TrimEnd('\') -eq $paths.Scripts.TrimEnd('\'))
    if (-not $sameDir) { Invoke-R007Step "copy scripts to $($paths.Scripts)" {
        Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination $paths.Scripts -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $repoRoot 'env\local.env.example') -Destination (Join-Path $paths.Scripts 'templates\local.env.example') -Force
    } }
    Save-R007State $state
}

function Initialize-EnvFile {
    Write-R007Log '== Environment file (.env)' 'STEP'
    $envPath = $paths.EnvFile
    if ($EnvFile) {
        Invoke-R007Step "install supplied env file -> $envPath" { Copy-Item -LiteralPath $EnvFile -Destination $envPath -Force }
    }
    elseif (-not (Test-Path -LiteralPath $envPath)) {
        Invoke-R007Step "create $envPath from env/local.env.example" { Copy-Item -LiteralPath (Join-Path $repoRoot 'env\local.env.example') -Destination $envPath }
        if (-not $DryRun) {
            foreach ($k in @('DB_PASSWORD', 'DB_MIGRATOR_PASSWORD', 'REDIS_PASSWORD', 'REVERB_APP_SECRET')) { Set-R007EnvValue $envPath $k (New-R007Secret 32) }
            Set-R007EnvValue $envPath 'REVERB_APP_ID' (New-R007Secret 8)
            Set-R007EnvValue $envPath 'REVERB_APP_KEY' (New-R007Secret 20)
        }
    }
    if ($DryRun) { Write-R007Log '[dry-run] fill generated secrets, prompt for node values'; return }
    if ($AppUrl) { Set-R007EnvValue $envPath 'APP_URL' $AppUrl; Set-R007EnvValue $envPath 'REVERB_HOST' ([uri] $AppUrl).Host }
    if ($NodeSiteId) { Set-R007EnvValue $envPath 'NODE_SITE_ID' $NodeSiteId }
    if ($SyncPeerUrl) { Set-R007EnvValue $envPath 'SYNC_PEER_URL' $SyncPeerUrl }
    if ((Get-R007EnvValue $envPath 'SYNC_NODE_CREDENTIAL') -eq '<secret>') {
        $cred = Read-R007SecretPrompt 'Node credential issued by the Cloud node (SYNC_NODE_CREDENTIAL) - leave empty to fill in later'
        if ($cred) { Set-R007EnvValue $envPath 'SYNC_NODE_CREDENTIAL' $cred }
    }
    $left = Get-R007EnvPlaceholders $envPath
    if ($left.Count -gt 0) { Write-R007Log ("Still to fill in $envPath before the first deploy: " + ($left -join ', ')) 'WARN' }
    if ($NasPath) { Set-R007EnvValue $envPath 'R007_BACKUP_NAS_PATH' $NasPath }
}

function Resolve-ChocoVersion {
    param([string] $Id, [string] $Prefix)
    $lines = & choco.exe search $Id --exact --all-versions --limit-output 2>$null
    $vers = foreach ($l in $lines) { $p = $l -split '\|'; if ($p.Count -ge 2 -and $p[1].StartsWith($Prefix)) { [version] $p[1] } }
    if (-not $vers) { throw "No Chocolatey version of '$Id' starting with '$Prefix' found." }
    return (($vers | Sort-Object -Descending | Select-Object -First 1).ToString())
}

function Install-Packages {
    Write-R007Log '== Packages (Chocolatey)' 'STEP'
    if ($DryRun) {
        Write-R007Log "[dry-run] choco install vcredist140 urlrewrite nssm; php $PhpVersionPrefix* -> $(Join-Path $paths.Tools 'php'); $MemuraiPackage"
        return
    }
    foreach ($p in @('vcredist140', 'urlrewrite', 'nssm')) { Invoke-R007Native 'choco.exe' @('upgrade', $p, '-y', '--no-progress') | Out-Null }
    $phpVer = Resolve-ChocoVersion 'php' $PhpVersionPrefix
    $phpDir = Join-Path $paths.Tools 'php'
    Write-R007Log "PHP $phpVer -> $phpDir"
    Invoke-R007Native 'choco.exe' @('upgrade', 'php', "--version=$phpVer", '-y', '--no-progress', "--params=`"/InstallDir:$phpDir /DontAddToPath`"") | Out-Null
    if ($RedisProvider -eq 'Memurai') { Invoke-R007Native 'choco.exe' @('upgrade', $MemuraiPackage, '-y', '--no-progress') | Out-Null }
}

function Set-IniValue {
    param([string] $File, [string] $Key, [string] $Value)
    $lines = @(Get-Content -LiteralPath $File)
    $pattern = '^\s*;?\s*' + [regex]::Escape($Key) + '\s*='
    $done = $false
    $out = foreach ($l in $lines) {
        if (-not $done -and $l -match $pattern) { "$Key = $Value"; $done = $true } else { $l }
    }
    if (-not $done) { $out = @($out) + "$Key = $Value" }
    Set-Content -LiteralPath $File -Value $out -Encoding ASCII
}

function Initialize-Php {
    Write-R007Log '== PHP configuration + Composer' 'STEP'
    if ($DryRun) { Write-R007Log '[dry-run] php.ini, extensions, phpredis, IIS FastCGI, composer'; return }
    $phpDir = Split-Path -Parent $state.PhpExe
    if (-not (Test-Path -LiteralPath $state.PhpExe)) { throw "php.exe not found at $($state.PhpExe) - run the Packages step." }
    $ini = Join-Path $phpDir 'php.ini'
    if (-not (Test-Path -LiteralPath $ini)) { Copy-Item (Join-Path $phpDir 'php.ini-production') $ini }
    Set-IniValue $ini 'extension_dir' '"ext"'
    # Rewrite the extension block explicitly (idempotent: previous 007 lines are dropped first).
    $content = @(Get-Content -LiteralPath $ini | Where-Object { $_ -notmatch '^\s*extension\s*=' -and $_ -notmatch '^\s*zend_extension\s*=\s*opcache' })
    $content = @($content | Where-Object { $_ -notmatch '^; --- 007 Resort & Spa \(install\.ps1\)' -and $_ -ne 'extension=redis' })
    $content += '; --- 007 Resort & Spa (install.ps1) ---'
    foreach ($e in @('curl', 'fileinfo', 'intl', 'mbstring', 'openssl', 'pdo_mysql', 'mysqli', 'zip', 'bcmath', 'sodium', 'gd', 'exif', 'sockets')) { $content += "extension=$e" }
    $content += 'zend_extension=opcache'
    Set-Content -LiteralPath $ini -Value $content -Encoding ASCII
    $settings = [ordered]@{
        'memory_limit' = '512M'; 'upload_max_filesize' = '20M'; 'post_max_size' = '25M'; 'max_execution_time' = '60'
        'date.timezone' = 'UTC'; 'expose_php' = 'Off'; 'display_errors' = 'Off'; 'log_errors' = 'On'
        'error_log' = (Join-Path $paths.Logs 'php_errors.log'); 'cgi.force_redirect' = '0'; 'cgi.fix_pathinfo' = '1'
        'fastcgi.impersonate' = '1'; 'realpath_cache_size' = '4096K'; 'realpath_cache_ttl' = '600'
        'opcache.enable' = '1'; 'opcache.enable_cli' = '0'; 'opcache.memory_consumption' = '192'
        'opcache.max_accelerated_files' = '20000'; 'opcache.validate_timestamps' = '0'
    }
    foreach ($k in $settings.Keys) { Set-IniValue $ini $k $settings[$k] }

    # phpredis is not bundled for Windows: fetch the matching NTS build.
    $redisDll = Join-Path $phpDir 'ext\php_redis.dll'
    if (-not (Test-Path -LiteralPath $redisDll)) {
        try {
            $phpMinor = (& $state.PhpExe -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
            $zipName = "php_redis-$PhpRedisVersion-$phpMinor-nts-vs17-x64.zip"
            $url = "https://downloads.php.net/~windows/pecl/releases/redis/$PhpRedisVersion/$zipName"
            $zip = Join-Path $paths.Downloads $zipName
            Write-R007Log "downloading phpredis: $url"
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
            $tmp = Join-Path $paths.Downloads 'phpredis'
            Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
            Copy-Item (Join-Path $tmp 'php_redis.dll') $redisDll -Force
        }
        catch { Write-R007Log "phpredis download failed ($($_.Exception.Message)). Place php_redis.dll in $phpDir\ext manually, or set REDIS_CLIENT=predis if the API ships predis/predis." 'WARN' }
    }
    if (Test-Path -LiteralPath $redisDll) { Add-Content -LiteralPath $ini -Value 'extension=redis' }

    $modules = (& $state.PhpExe -m) -join ' '
    foreach ($need in @('mbstring', 'openssl', 'pdo_mysql', 'intl', 'curl', 'zip', 'sodium', 'bcmath', 'fileinfo')) {
        if ($modules -notmatch "(?im)^$need\b|\b$need\b") { throw "PHP module '$need' is not loaded - check $ini" }
    }
    if ((& $state.PhpExe -i) -match 'Thread Safety => enabled') { Write-R007Log 'PHP is a thread-safe build; use the NTS build for IIS FastCGI.' 'WARN' }
    Write-R007Log ("PHP: " + ((& $state.PhpExe -v) | Select-Object -First 1))

    # Composer: official installer, signature-checked, no Chocolatey package (which needs a system PHP on PATH).
    $composerDir = Join-Path $paths.Tools 'composer'
    if (-not (Test-Path -LiteralPath (Join-Path $composerDir 'composer.phar'))) {
        New-R007Directory $composerDir
        $sig = (Invoke-WebRequest -Uri 'https://composer.github.io/installer.sig' -UseBasicParsing).Content.Trim()
        $setup = Join-Path $paths.Downloads 'composer-setup.php'
        Invoke-WebRequest -Uri 'https://getcomposer.org/installer' -OutFile $setup -UseBasicParsing
        $hash = (Get-FileHash -Algorithm SHA384 -LiteralPath $setup).Hash
        if ($hash -ne $sig.ToUpperInvariant() -and $hash.ToLowerInvariant() -ne $sig.ToLowerInvariant()) { Remove-Item $setup; throw 'Composer installer signature mismatch - aborting.' }
        Invoke-R007Native $state.PhpExe @($setup, "--install-dir=$composerDir", '--filename=composer.phar', '--quiet') | Out-Null
        Remove-Item -LiteralPath $setup -Force
        Set-Content -LiteralPath (Join-Path $composerDir 'composer.bat') -Value "@echo off`r`n`"$($state.PhpExe)`" `"%~dp0composer.phar`" %*" -Encoding ASCII
    }
}

function Install-MySql {
    Write-R007Log '== MySQL 8.4' 'STEP'
    $base = Join-Path $paths.Tools 'mysql'
    $bin = $state.MySqlBin
    $myIni = Join-Path $base 'my.ini'
    $svcName = $state.MySqlService
    if ($DryRun) {
        Write-R007Log "[dry-run] MySQL $MySqlVersion ZIP -> $base; my.ini; initialize datadir $MySqlDataDir; service $svcName; users r007_app/r007_migrator/r007_backup"
        return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $bin 'mysqld.exe'))) {
        $zip = $MySqlZip
        if (-not $zip) {
            $name = "mysql-$MySqlVersion-winx64.zip"
            $zip = Join-Path $paths.Downloads $name
            $url = "https://cdn.mysql.com/Downloads/MySQL-8.4/$name"
            Write-R007Log "downloading $url (or download it yourself and pass -MySqlZip)"
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        }
        if ($MySqlZipSha256) {
            if ((Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash -ne $MySqlZipSha256.ToUpperInvariant()) { throw 'MySQL ZIP SHA256 mismatch.' }
        }
        else { Write-R007Log 'No -MySqlZipSha256 given: compare the ZIP against the checksum published on dev.mysql.com before trusting it.' 'WARN' }
        $tmp = Join-Path $paths.Downloads 'mysql-extract'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $inner = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
        $dest = Join-Path $paths.Tools $inner.Name
        if (-not (Test-Path $dest)) { Move-Item -LiteralPath $inner.FullName -Destination $dest }
        Set-R007Junction $base $dest
        if (-not (Test-Path -LiteralPath (Join-Path $bin 'mysqld.exe'))) { throw 'mysqld.exe not found after extraction.' }
    }
    $ver = (& (Join-Path $bin 'mysqld.exe') --version)
    if ($ver -notmatch 'Ver 8\.4\.') { throw "Expected MySQL 8.4.x, found: $ver" }

    $ramMb = [int] ((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
    $pool = [math]::Max(512, [int] ($ramMb * 0.4))
    $tpl = Get-Content -LiteralPath (Join-Path $templateDir 'my.ini.template') -Raw
    $tpl = $tpl.Replace('@@BASEDIR@@', ($base -replace '\\', '/')).Replace('@@DATADIR@@', ($MySqlDataDir -replace '\\', '/')).Replace('@@LOGDIR@@', ($paths.Logs -replace '\\', '/')).Replace('@@BUFFERPOOL@@', "${pool}M")
    Set-Content -LiteralPath $myIni -Value $tpl -Encoding ASCII

    if (-not (Test-Path (Join-Path $MySqlDataDir 'mysql'))) {
        Write-R007Log 'initializing data directory'
        Invoke-R007Native (Join-Path $bin 'mysqld.exe') @("--defaults-file=$myIni", '--initialize-insecure', '--console') | Out-Null
    }
    if (-not (Get-R007Service -Name $svcName)) {
        Invoke-R007Native (Join-Path $bin 'mysqld.exe') @('--install', $svcName, "--defaults-file=$myIni") | Out-Null
    }
    Invoke-R007Native 'sc.exe' @('config', $svcName, 'obj=', "NT SERVICE\$svcName", 'start=', 'auto') -AllowFailure | Out-Null
    Invoke-R007Native 'sc.exe' @('failure', $svcName, 'reset=', '86400', 'actions=', 'restart/5000/restart/5000/restart/60000') | Out-Null
    $vsa = "NT SERVICE\$svcName"
    Set-R007Acl -Path $MySqlDataDir -Grants @{ $vsa = 'Modify' } -Inherit:$false
    Set-R007Acl -Path $base -Grants @{ $vsa = 'ReadAndExecute' } -Inherit
    Set-R007Acl -Path $paths.Logs -Grants @{ $vsa = 'Modify'; $localSvc = 'Modify' } -Inherit:$false
    Start-R007Services @($svcName)
    for ($i = 0; $i -lt 30 -and -not (Test-R007TcpPort -Port 3306); $i++) { Start-Sleep -Seconds 1 }
    if (-not (Test-R007TcpPort -Port 3306)) { throw 'MySQL did not start; see logs\mysql-error.log' }

    $mysql = Join-Path $bin 'mysql.exe'
    $adminCnf = Join-Path $paths.Secrets 'mysql-admin.cnf'
    if (-not (Test-Path -LiteralPath $adminCnf)) {
        $rootPw = New-R007Secret 32
        "ALTER USER 'root'@'localhost' IDENTIFIED BY '$rootPw'; FLUSH PRIVILEGES;" | & $mysql -u root --skip-password
        if ($LASTEXITCODE -ne 0) { throw 'Could not set the MySQL root password (was it already set? Create secrets\mysql-admin.cnf by hand).' }
        Set-Content -LiteralPath $adminCnf -Value "[client]`r`nuser=root`r`npassword=$rootPw`r`nhost=127.0.0.1`r`nport=3306" -Encoding ASCII
        Set-R007Acl -Path $adminCnf
    }
    $env = $paths.EnvFile
    $db = Get-R007EnvValue $env 'DB_DATABASE'; $appU = Get-R007EnvValue $env 'DB_USERNAME'; $migU = Get-R007EnvValue $env 'DB_MIGRATOR_USERNAME'
    $appP = Get-R007EnvValue $env 'DB_PASSWORD'; $migP = Get-R007EnvValue $env 'DB_MIGRATOR_PASSWORD'
    foreach ($n in @($db, $appU, $migU)) { if ($n -notmatch '^[A-Za-z0-9_]+$') { throw "Invalid DB/user name in .env: '$n'" } }
    if ((Test-R007Placeholder $appP) -or (Test-R007Placeholder $migP)) { throw 'DB passwords in .env are still placeholders - run the Env step first.' }
    $state.Database = $db
    $backupCnf = Join-Path $paths.Secrets 'mysql-backup.cnf'
    $backupPw = ''
    if (-not (Test-Path -LiteralPath $backupCnf)) { $backupPw = New-R007Secret 32 }
    $sql = @"
CREATE DATABASE IF NOT EXISTS ``$db`` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE USER IF NOT EXISTS '$appU'@'localhost' IDENTIFIED BY '$appP';
CREATE USER IF NOT EXISTS '$appU'@'127.0.0.1' IDENTIFIED BY '$appP';
ALTER USER '$appU'@'localhost' IDENTIFIED BY '$appP';
ALTER USER '$appU'@'127.0.0.1' IDENTIFIED BY '$appP';
GRANT SELECT, INSERT, UPDATE, DELETE ON ``$db``.* TO '$appU'@'localhost', '$appU'@'127.0.0.1';
CREATE USER IF NOT EXISTS '$migU'@'localhost' IDENTIFIED BY '$migP';
CREATE USER IF NOT EXISTS '$migU'@'127.0.0.1' IDENTIFIED BY '$migP';
ALTER USER '$migU'@'localhost' IDENTIFIED BY '$migP';
ALTER USER '$migU'@'127.0.0.1' IDENTIFIED BY '$migP';
GRANT ALL PRIVILEGES ON ``$db``.* TO '$migU'@'localhost', '$migU'@'127.0.0.1';
"@
    if ($backupPw) {
        $sql += @"

CREATE USER IF NOT EXISTS 'r007_backup'@'localhost' IDENTIFIED BY '$backupPw';
ALTER USER 'r007_backup'@'localhost' IDENTIFIED BY '$backupPw';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES ON ``$db``.* TO 'r007_backup'@'localhost';
GRANT RELOAD, PROCESS, REPLICATION CLIENT ON *.* TO 'r007_backup'@'localhost';
"@
    }
    $sql += "`r`nFLUSH PRIVILEGES;`r`n"
    $sql | & $mysql "--defaults-extra-file=$adminCnf"
    if ($LASTEXITCODE -ne 0) { throw 'Creating the database/users failed.' }
    if ($backupPw) {
        Set-Content -LiteralPath $backupCnf -Value "[client]`r`nuser=r007_backup`r`npassword=$backupPw`r`nhost=127.0.0.1`r`nport=3306" -Encoding ASCII
        Set-R007Acl -Path $backupCnf
    }
    Save-R007State @{ Database = $db }
    Write-R007Log 'MySQL ready (localhost only).' 'OK'
}

function Install-Redis {
    Write-R007Log "== Redis ($RedisProvider)" 'STEP'
    if ($RedisProvider -eq 'Skip') { Write-R007Log 'Skipped. QUEUE/CACHE/BROADCAST need a Redis-compatible server on 127.0.0.1:6379.' 'WARN'; return }
    if ($DryRun) { Write-R007Log '[dry-run] configure memurai.conf: bind 127.0.0.1, requirepass <hidden>, appendonly yes, noeviction; restart service'; return }
    $pw = Get-R007EnvValue $paths.EnvFile 'REDIS_PASSWORD'
    if (Test-R007Placeholder $pw) { throw 'REDIS_PASSWORD in .env is a placeholder - run the Env step first.' }
    if ($RedisProvider -eq 'Memurai') {
        $conf = 'C:\Program Files\Memurai\memurai.conf'
        if (-not (Test-Path -LiteralPath $conf)) { throw "memurai.conf not found at $conf" }
        $lines = @(Get-Content -LiteralPath $conf | Where-Object { $_ -notmatch '^\s*(bind|requirepass|appendonly|maxmemory-policy|protected-mode)\s' })
        $lines += '# --- 007 Resort & Spa (install.ps1) ---', 'bind 127.0.0.1', 'protected-mode yes', "requirepass $pw", 'appendonly yes', 'maxmemory-policy noeviction'
        Set-Content -LiteralPath $conf -Value $lines -Encoding ASCII
        Set-R007Acl -Path $conf -Grants @{ 'NT AUTHORITY\NETWORK SERVICE' = 'Read'; 'NT AUTHORITY\LOCAL SERVICE' = 'Read' } -Inherit
        Restart-Service -Name $state.RedisService -Force
    }
    for ($i = 0; $i -lt 20 -and -not (Test-R007RedisPing -Password $pw); $i++) { Start-Sleep -Seconds 1 }
    if (-not (Test-R007RedisPing -Password $pw)) { throw 'Redis did not answer PING with the configured password.' }
    Write-R007Log 'Redis ready (localhost only, password set, noeviction).' 'OK'
}

function Initialize-Iis {
    Write-R007Log '== IIS + PHP FastCGI' 'STEP'
    if ($DryRun) { Write-R007Log "[dry-run] enable IIS features; register $($state.PhpCgi) with FastCGI; app pool R007; site R007 :80 -> $($paths.Current)\public"; return }
    $features = @('Web-Server', 'Web-CGI', 'Web-Filtering', 'Web-Http-Logging', 'Web-Stat-Compression', 'Web-Mgmt-Console', 'Web-Scripting-Tools')
    if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) { Install-WindowsFeature -Name $features | Out-Null }
    else { Write-R007Log 'Install-WindowsFeature not available (client Windows?). Enable IIS + CGI manually.' 'WARN' }
    Import-Module WebAdministration
    $cgi = $state.PhpCgi
    $apphost = 'MACHINE/WEBROOT/APPHOST'
    if (-not (Get-WebConfiguration -PSPath $apphost -Filter "/system.webServer/fastCgi/application[@fullPath='$cgi']")) {
        Add-WebConfiguration -PSPath $apphost -Filter '/system.webServer/fastCgi' -Value @{ fullPath = $cgi; maxInstances = 8; instanceMaxRequests = 500; activityTimeout = 120; requestTimeout = 90 }
        Add-WebConfiguration -PSPath $apphost -Filter "/system.webServer/fastCgi/application[@fullPath='$cgi']/environmentVariables" -Value @{ name = 'PHP_FCGI_MAX_REQUESTS'; value = '500' }
    }
    $pool = $state.AppPool
    if (-not (Test-Path "IIS:\AppPools\$pool")) { New-WebAppPool -Name $pool | Out-Null }
    Set-ItemProperty "IIS:\AppPools\$pool" -Name managedRuntimeVersion -Value ''
    Set-ItemProperty "IIS:\AppPools\$pool" -Name startMode -Value 'AlwaysRunning'
    Set-ItemProperty "IIS:\AppPools\$pool" -Name processModel.idleTimeout -Value ([TimeSpan]::Zero)
    Set-ItemProperty "IIS:\AppPools\$pool" -Name processModel.identityType -Value 'ApplicationPoolIdentity'
    $default = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
    if ($default -and $default.physicalPath -like '*inetpub*wwwroot*') { Stop-Website -Name 'Default Web Site'; Remove-Website -Name 'Default Web Site' }
    $site = $state.SiteName
    $phys = Join-Path $paths.Current 'public'
    if (-not (Get-Website -Name $site -ErrorAction SilentlyContinue)) {
        New-Website -Name $site -PhysicalPath $paths.Root -ApplicationPool $pool -Port $state.HttpPort -Force | Out-Null
    }
    Set-ItemProperty "IIS:\Sites\$site" -Name physicalPath -Value $phys
    if ($CertThumbprint -and -not (Get-WebBinding -Name $site -Protocol https -ErrorAction SilentlyContinue)) {
        New-WebBinding -Name $site -Protocol https -Port 443
        (Get-WebBinding -Name $site -Protocol https).AddSslCertificate($CertThumbprint, 'My')
    }
    Start-Website -Name $site -ErrorAction SilentlyContinue
    Write-R007Log "IIS site '$site' -> $phys (deployed by update.ps1)" 'OK'
}

function Install-Services {
    Write-R007Log '== Windows Services (NSSM)' 'STEP'
    $php = $state.PhpExe
    $deps = @($state.MySqlService)
    if ($RedisProvider -eq 'Memurai') { $deps += $state.RedisService }
    foreach ($d in Get-R007ServiceDefinitions -State ([pscustomobject] $state)) {
        Set-R007NssmService -Name $d.Name -Display $d.Display -Application $php -Arguments $d.Args -WorkingDirectory $paths.Current -LogDirectory $paths.Logs -DependsOn $deps
    }
    Write-R007Log 'Services are installed but start after the first deploy (update.ps1).' 'INFO'
}

function Register-R007Task {
    param([string] $Name, [string] $Description, $Action, $Trigger, $Principal, $Settings)
    Invoke-R007Step "register scheduled task '$Name'" {
        Register-ScheduledTask -TaskName $Name -Description $Description -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null
    }
}

function Register-Scheduler {
    Write-R007Log '== Scheduled tasks: Laravel scheduler' 'STEP'
    if ($DryRun) { Write-R007Log "[dry-run] task 'R007 Scheduler': $($state.PhpExe) artisan schedule:run every minute as LocalService"; return }
    $action = New-ScheduledTaskAction -Execute $state.PhpExe -Argument 'artisan schedule:run' -WorkingDirectory $paths.Current
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
    $principal = New-ScheduledTaskPrincipal -UserId $localSvc -LogonType ServiceAccount -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-R007Task 'R007 Scheduler' '007 Resort & Spa: php artisan schedule:run every minute (managed by install.ps1).' $action $trigger $principal $settings
}

function Register-Firewall {
    Write-R007Log '== Windows Firewall (property VLANs only)' 'STEP'
    $rules = @(
        @{ Name = 'R007 HTTP (property VLANs)'; Port = [string] $state.HttpPort },
        @{ Name = 'R007 Reverb WebSocket (property VLANs)'; Port = [string] $state.ReverbPort }
    )
    if ($CertThumbprint) { $rules += @{ Name = 'R007 HTTPS (property VLANs)'; Port = '443' } }
    if ($DryRun) { foreach ($r in $rules) { Write-R007Log "[dry-run] allow inbound tcp/$($r.Port) from $($AllowedSubnets -join ', ') as '$($r.Name)'" }; return }
    Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True -DefaultInboundAction Block
    foreach ($r in $rules) {
        Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -DisplayName $r.Name -Group 'R007' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $r.Port -RemoteAddress $AllowedSubnets -Profile Any | Out-Null
    }
    foreach ($bad in @(3306, 6379)) {
        $open = Get-NetFirewallPortFilter -Protocol TCP | Where-Object { $_.LocalPort -eq "$bad" } | Get-NetFirewallRule | Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' }
        if ($open) { Write-R007Log "An inbound ALLOW rule for tcp/$bad exists ($($open.DisplayName -join ', ')). MySQL/Redis must stay localhost-only: remove it." 'WARN' }
    }
    Write-R007Log "Inbound limited to: $($AllowedSubnets -join ', ')" 'OK'
}

function Register-BackupTasks {
    Write-R007Log '== Scheduled tasks: nightly backup + log cleanup' 'STEP'
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if ($DryRun) { Write-R007Log "[dry-run] tasks 'R007 Nightly Backup' 02:30 (SYSTEM) and 'R007 Log Cleanup' 03:30"; return }
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 15)
    $bk = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$($paths.Scripts)\backup-mysql.ps1`""
    Register-R007Task 'R007 Nightly Backup' 'mysqldump + binlogs to local disk and NAS, with retention (managed by install.ps1).' $bk (New-ScheduledTaskTrigger -Daily -At '02:30') $principal $settings
    $lg = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$($paths.Scripts)\cleanup-logs.ps1`""
    Register-R007Task 'R007 Log Cleanup' 'Delete old service/IIS/PHP logs (managed by install.ps1).' $lg (New-ScheduledTaskTrigger -Daily -At '03:30') $principal $settings
    if (-not $NasPath) { Write-R007Log 'No -NasPath given: backups stay on the local backup disk only. Set the NAS path in install-state.json (NasPath) or re-run with -NasPath.' 'WARN' }
}

function Set-R007Permissions {
    Write-R007Log '== Permissions (ACL)' 'STEP'
    if ($DryRun) { Write-R007Log '[dry-run] ACLs: secrets=Admins/SYSTEM only; .env read for services + app pool; storage/logs modify'; return }
    Set-R007Acl -Path $paths.Secrets
    if (Test-Path $paths.EnvFile) { Set-R007Acl -Path $paths.EnvFile -Grants @{ $localSvc = 'Read'; $poolAccount = 'Read' } }
    Set-R007Acl -Path $paths.Storage -Grants @{ $localSvc = 'Modify'; $poolAccount = 'Modify' }
    Set-R007Acl -Path $paths.Logs -Grants @{ $localSvc = 'Modify'; $poolAccount = 'Modify'; "NT SERVICE\$($state.MySqlService)" = 'Modify' }
    Set-R007Acl -Path $paths.Releases -Grants @{ $localSvc = 'ReadAndExecute'; $poolAccount = 'ReadAndExecute' }
    Set-R007Acl -Path (Join-Path $paths.Tools 'php') -Grants @{ $localSvc = 'ReadAndExecute'; $poolAccount = 'ReadAndExecute' } -Inherit
    Set-R007Acl -Path $BackupRoot
}

# ------------------------------------------------------------------------------------------------
$map = [ordered]@{
    Preflight = { Invoke-Preflight }; Directories = { Initialize-Directories }; Env = { Initialize-EnvFile }
    Packages = { Install-Packages }; Php = { Initialize-Php }; MySql = { Install-MySql }; Redis = { Install-Redis }
    Iis = { Initialize-Iis }; Services = { Install-Services }; Scheduler = { Register-Scheduler }
    Firewall = { Register-Firewall }; Backup = { Register-BackupTasks }; Acl = { Set-R007Permissions }
}
foreach ($k in $map.Keys) { if (Test-Step $k) { & $map[$k] } }

Write-R007Log 'Install finished. Next: (1) fill any <secret> values in C:\R007\shared\.env, (2) C:\R007\scripts\update.ps1 -Package <r007-xxxx.zip>, (3) C:\R007\scripts\status.ps1' 'OK'
