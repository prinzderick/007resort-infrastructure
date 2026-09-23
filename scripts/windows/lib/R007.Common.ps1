<#
.SYNOPSIS
    Shared helpers for the 007 Resort & Spa Local-node (Windows Server) scripts. Dot-source it:
        . (Join-Path $PSScriptRoot 'lib\R007.Common.ps1')

.DESCRIPTION
    - Every state-changing action goes through Invoke-R007Step so that -DryRun only prints it.
    - No secrets are ever hard-coded or logged. Secrets are generated, read from the protected
      .env / option files, or entered through a secure prompt.
    - Layout on the server (override the root with the R007_ROOT environment variable):
        C:\R007\releases\<id>\   C:\R007\current (junction)   C:\R007\shared\{.env,storage}
        C:\R007\logs   C:\R007\secrets   C:\R007\tools   C:\R007\scripts   C:\R007\install-state.json
#>
Set-StrictMode -Version Latest

$script:R007DryRun = $false

function Initialize-R007 {
    [CmdletBinding()]
    param([switch] $DryRun)
    $script:R007DryRun = [bool] $DryRun
    $ErrorActionPreference = 'Stop'
    if ($DryRun) { Write-R007Log 'DRY RUN: nothing will be changed.' 'WARN' }
}

function Get-R007DryRun { return $script:R007DryRun }

function Write-R007Log {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'STEP', 'OK')][string] $Level = 'INFO')
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $line = "[{0}] {1,-5} {2}" -f $stamp, $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Error -Message $Message -ErrorAction Continue }
        'WARN' { Write-Warning -Message $Message }
        default { Write-Information -MessageData $line -InformationAction Continue }
    }
}

function Invoke-R007Step {
    <# Runs $Action, or only announces it in dry-run mode. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Description, [Parameter(Mandatory)][scriptblock] $Action)
    if ($script:R007DryRun) {
        Write-R007Log "[dry-run] $Description" 'INFO'
        return
    }
    Write-R007Log $Description 'STEP'
    & $Action
}

function Test-R007Windows {
    if (Test-Path variable:IsWindows) { return [bool] $IsWindows }
    return $true   # Windows PowerShell 5.1 has no $IsWindows and only runs on Windows
}

function Assert-R007Administrator {
    if (-not (Test-R007Windows)) {
        if ($script:R007DryRun) { Write-R007Log 'Not Windows: dry-run only, skipping the administrator check.' 'WARN'; return }
        throw 'These scripts run on Windows Server only.'
    }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated (Administrator) PowerShell session.'
    }
}

function Get-R007Root {
    if ($env:R007_ROOT) { return $env:R007_ROOT }
    return 'C:\R007'
}

function Get-R007Paths {
    $root = Get-R007Root
    return [pscustomobject]@{
        Root      = $root
        Releases  = Join-Path $root 'releases'
        Current   = Join-Path $root 'current'
        Shared    = Join-Path $root 'shared'
        Storage   = Join-Path $root 'shared\storage'
        EnvFile   = Join-Path $root 'shared\.env'
        Logs      = Join-Path $root 'logs'
        Secrets   = Join-Path $root 'secrets'
        Tools     = Join-Path $root 'tools'
        Scripts   = Join-Path $root 'scripts'
        Downloads = Join-Path $root 'downloads'
        State     = Join-Path $root 'install-state.json'
    }
}

function Save-R007State {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Values)
    $paths = Get-R007Paths
    $state = @{}
    if (Test-Path -LiteralPath $paths.State) {
        $obj = Get-Content -LiteralPath $paths.State -Raw | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) { $state[$p.Name] = $p.Value }
    }
    foreach ($k in $Values.Keys) { $state[$k] = $Values[$k] }
    if ($script:R007DryRun) { Write-R007Log "[dry-run] save state: $($Values.Keys -join ', ')"; return }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $paths.State -Encoding UTF8
}

function Get-R007State {
    $paths = Get-R007Paths
    $state = @{
        PhpExe      = 'C:\R007\tools\php\php.exe'
        PhpCgi      = 'C:\R007\tools\php\php-cgi.exe'
        MySqlBin    = 'C:\R007\tools\mysql\bin'
        MySqlData   = 'C:\R007\mysql-data'
        BackupRoot  = 'C:\R007\backups'
        NasPath     = ''
        Subnets     = @('10.10.10.0/24', '10.10.20.0/24', '10.10.40.0/24')
        HttpPort    = 80
        ReverbPort  = 8085
        SiteName    = 'R007'
        AppPool     = 'R007'
        Database    = 'r007'
        MySqlService = 'R007MySQL'
        RedisService = 'Memurai'
    }
    if (Test-Path -LiteralPath $paths.State) {
        $obj = Get-Content -LiteralPath $paths.State -Raw | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) { $state[$p.Name] = $p.Value }
    }
    return [pscustomobject] $state
}

function Get-R007Service {
    <# Get-Service that returns $null for unknown services and on non-Windows hosts (dry-run testing). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name)
    if (-not (Test-R007Windows)) { return $null }
    return Get-Service -Name $Name -ErrorAction SilentlyContinue
}

# ---- Service catalogue: everything that must run for the Local node -----------------------------
function Get-R007ServiceDefinitions {
    param([Parameter(Mandatory)][pscustomobject] $State)
    $ns = 'artisan'
    return @(
        [pscustomobject]@{ Name = 'R007-Queue'; Display = '007 Resort queue worker (default)'; Args = "$ns queue:work redis --queue=default --sleep=1 --tries=3 --backoff=5 --max-time=3600 --max-jobs=1000" },
        [pscustomobject]@{ Name = 'R007-Sync'; Display = '007 Resort sync worker (outbox/inbox queue)'; Args = "$ns queue:work redis --queue=sync --sleep=1 --tries=5 --backoff=10 --max-time=3600 --max-jobs=1000" },
        [pscustomobject]@{ Name = 'R007-Reverb'; Display = '007 Resort Reverb WebSocket server'; Args = "$ns reverb:start --host=0.0.0.0 --port=$($State.ReverbPort)" }
    )
}

# ---- Secrets ------------------------------------------------------------------------------------
function New-R007Secret {
    [CmdletBinding()]
    param([ValidateRange(16, 128)][int] $Length = 32)
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
    $bytes = New-Object byte[] ($Length)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) { [void] $sb.Append($chars[$b % $chars.Length]) }
    return $sb.ToString()
}

function Read-R007SecretPrompt {
    <# Secure prompt; returns the plain text only in memory (never logged). Empty input returns ''. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Prompt)
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# ---- .env helpers -------------------------------------------------------------------------------
function Get-R007EnvValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Key)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match "^\s*$([regex]::Escape($Key))=(.*)$") {
            $v = $Matches[1].Trim()
            if ($v.StartsWith('"') -and $v.IndexOf('"', 1) -ge 1) { return $v.Substring(1, $v.IndexOf('"', 1) - 1) }
            $hash = $v.IndexOf(' #')
            if ($hash -ge 0) { $v = $v.Substring(0, $hash).Trim() }
            return $v
        }
    }
    return ''
}

function Set-R007EnvValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Key, [Parameter(Mandatory)][AllowEmptyString()][string] $Value)
    if ($script:R007DryRun) { Write-R007Log "[dry-run] set $Key in $Path (value hidden)"; return }
    $lines = @()
    if (Test-Path -LiteralPath $Path) { $lines = @(Get-Content -LiteralPath $Path) }
    $found = $false
    $out = foreach ($line in $lines) {
        if (-not $found -and $line -match "^\s*$([regex]::Escape($Key))=") { $found = $true; "$Key=$Value" } else { $line }
    }
    if (-not $found) { $out = @($out) + "$Key=$Value" }
    Set-Content -LiteralPath $Path -Value $out -Encoding UTF8
}

function Test-R007Placeholder {
    [CmdletBinding()]
    param([AllowEmptyString()][string] $Value)
    return ($Value -eq '' -or $Value -eq '<generate>' -or $Value -eq '<secret>')
}

function Get-R007EnvPlaceholders {
    <# Returns the keys in the .env that still hold <secret> / <generate> (values are never returned). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)
    $keys = @()
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*([A-Z0-9_]+)=(<secret>|<generate>)\s*(#.*)?$') { $keys += $Matches[1] }
    }
    return $keys
}

# ---- Filesystem / ACL ---------------------------------------------------------------------------
function Set-R007Acl {
    <# Replace the ACL of $Path: Administrators + SYSTEM full control, plus optional extra grants. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [hashtable] $Grants = @{},          # account -> 'Read' | 'ReadAndExecute' | 'Modify'
        [switch] $Inherit                    # keep inheritance (default: break it = private)
    )
    if ($script:R007DryRun) { Write-R007Log "[dry-run] ACL $Path -> Admins/SYSTEM + $($Grants.Keys -join ', ')"; return }
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection(-not $Inherit, $false)
    if (-not $Inherit) { foreach ($r in @($acl.Access)) { [void] $acl.RemoveAccessRule($r) } }
    $isDir = (Get-Item -LiteralPath $Path).PSIsContainer
    $inheritFlags = if ($isDir) { 'ContainerInherit,ObjectInherit' } else { 'None' }
    $all = @{ 'BUILTIN\Administrators' = 'FullControl'; 'NT AUTHORITY\SYSTEM' = 'FullControl' }
    foreach ($k in $Grants.Keys) { $all[$k] = $Grants[$k] }
    foreach ($k in $all.Keys) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($k, $all[$k], $inheritFlags, 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function New-R007Directory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)
    if (Test-Path -LiteralPath $Path) { return }
    Invoke-R007Step "create directory $Path" { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

# ---- Native command helpers ------------------------------------------------------------------------
function Invoke-R007Native {
    <# Run an external program; throw on non-zero exit. Arguments are never logged (may contain paths only). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $FilePath, [string[]] $ArgumentList = @(), [switch] $AllowFailure)
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) { throw "$FilePath exited with code $LASTEXITCODE" }
    return $LASTEXITCODE
}

function Test-R007TcpPort {
    [CmdletBinding()]
    param([string] $HostName = '127.0.0.1', [Parameter(Mandatory)][int] $Port, [int] $TimeoutMs = 2000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($iar)
        return $client.Connected
    }
    catch { return $false }
    finally { $client.Close() }
}

function Test-R007RedisPing {
    <# RESP handshake without redis-cli: AUTH (optional) + PING. Password stays in memory. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Read from the ACL-protected .env at runtime; never logged.')]
    [CmdletBinding()]
    param([string] $HostName = '127.0.0.1', [int] $Port = 6379, [string] $Password = '')
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.ReceiveTimeout = 2000; $client.SendTimeout = 2000
        $client.Connect($HostName, $Port)
        $stream = $client.GetStream()
        $cmds = ''
        if ($Password) { $cmds += "*2`r`n`$4`r`nAUTH`r`n`$$($Password.Length)`r`n$Password`r`n" }
        $cmds += "*1`r`n`$4`r`nPING`r`n"
        $bytes = [Text.Encoding]::ASCII.GetBytes($cmds)
        $stream.Write($bytes, 0, $bytes.Length)
        Start-Sleep -Milliseconds 200
        $buf = New-Object byte[] 256
        $n = $stream.Read($buf, 0, $buf.Length)
        $resp = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
        return ($resp -match '\+PONG')
    }
    catch { return $false }
    finally { $client.Close() }
}

function Invoke-R007Http {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Url, [int] $TimeoutSec = 5)
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec
        return [pscustomobject]@{ Ok = ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300); Status = [int] $r.StatusCode; Body = $r.Content }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Status = 0; Body = $_.Exception.Message }
    }
}

# ---- NSSM ------------------------------------------------------------------------------------------
function Get-R007NssmPath {
    $cmd = Get-Command nssm.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @('C:\ProgramData\chocolatey\bin\nssm.exe', 'C:\Program Files\nssm\win64\nssm.exe')) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    if ($script:R007DryRun) { return 'nssm.exe' }
    throw 'nssm.exe not found (install.ps1 installs it with Chocolatey: choco install nssm).'
}

function Set-R007NssmService {
    <# Idempotently create/update a service that runs php.exe artisan ... under NSSM. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Display,
        [Parameter(Mandatory)][string] $Application,
        [Parameter(Mandatory)][string] $Arguments,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string] $LogDirectory,
        [string[]] $DependsOn = @(),
        [string] $Account = 'NT AUTHORITY\LocalService'
    )
    $nssm = Get-R007NssmPath
    $exists = [bool] (Get-R007Service -Name $Name)
    if (-not $exists) { Invoke-R007Step "nssm install $Name" { Invoke-R007Native $nssm @('install', $Name, $Application) | Out-Null } }
    $settings = @(
        @('Application', $Application),
        @('AppParameters', $Arguments),
        @('AppDirectory', $WorkingDirectory),
        @('DisplayName', $Display),
        @('Description', "007 Resort & Spa Local node - $Display. Managed by scripts/windows/install.ps1."),
        @('Start', 'SERVICE_AUTO_START'),
        @('ObjectName', $Account),
        @('AppStdout', (Join-Path $LogDirectory "$Name.out.log")),
        @('AppStderr', (Join-Path $LogDirectory "$Name.err.log")),
        @('AppRotateFiles', '1'),
        @('AppRotateOnline', '1'),
        @('AppRotateBytes', '10485760'),
        @('AppRotateSeconds', '86400'),
        @('AppExit', 'Default', 'Restart'),
        @('AppExit', '0', 'Restart'),         # workers exit 0 after --max-time / queue:restart: bring them straight back
        @('AppRestartDelay', '5000'),
        @('AppThrottle', '10000'),
        @('AppStopMethodConsole', '30000'),
        @('AppNoConsole', '1')
    )
    foreach ($s in $settings) {
        $a = @('set', $Name) + $s
        Invoke-R007Step "nssm set $Name $($s[0])" { Invoke-R007Native $nssm $a | Out-Null }
    }
    if ($DependsOn.Count -gt 0) {
        $dep = @('set', $Name, 'DependOnService') + $DependsOn
        Invoke-R007Step "nssm set $Name DependOnService $($DependsOn -join ' ')" { Invoke-R007Native $nssm $dep | Out-Null }
    }
    # Belt and braces: SCM-level recovery in case NSSM itself is terminated.
    Invoke-R007Step "sc failure $Name (restart on crash)" {
        Invoke-R007Native 'sc.exe' @('failure', $Name, 'reset=', '86400', 'actions=', 'restart/5000/restart/5000/restart/60000') | Out-Null
    }
}

function Stop-R007Services {
    param([Parameter(Mandatory)][string[]] $Names)
    foreach ($n in $Names) {
        $svc = Get-R007Service -Name $n
        if ($svc -and $svc.Status -ne 'Stopped') {
            Invoke-R007Step "stop service $n" { Stop-Service -Name $n -Force; $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60)) }
        }
    }
}

function Start-R007Services {
    param([Parameter(Mandatory)][string[]] $Names)
    foreach ($n in $Names) {
        $svc = Get-R007Service -Name $n
        if ($svc -and $svc.Status -ne 'Running') {
            Invoke-R007Step "start service $n" { Start-Service -Name $n; $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(60)) }
        }
    }
}

# ---- Junction swap (atomic enough: sub-second) ---------------------------------------------------
function Set-R007Junction {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Link, [Parameter(Mandatory)][string] $Target)
    Invoke-R007Step "junction $Link -> $Target" {
        if (Test-Path -LiteralPath $Link) { [System.IO.Directory]::Delete($Link, $false) }   # removes the junction only, never the target
        New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null
    }
}

function Get-R007CurrentRelease {
    $paths = Get-R007Paths
    if (-not (Test-Path -LiteralPath $paths.Current)) { return '' }
    $item = Get-Item -LiteralPath $paths.Current
    $target = $item.Target
    if ($target -is [array]) { $target = $target[0] }
    if (-not $target) { return '' }
    return Split-Path -Leaf $target
}

function Enter-R007Lock {
    <# Exclusive lock file so two deploys/backups cannot run at once. Returns the open stream. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name)
    $paths = Get-R007Paths
    $lock = Join-Path $paths.Root "$Name.lock"
    if ($script:R007DryRun) { return $null }
    try { return [System.IO.File]::Open($lock, 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw "Another '$Name' operation is already running ($lock)." }
}

function Exit-R007Lock {
    param($Stream)
    if ($Stream) { $Stream.Dispose() }
}

function Remove-R007Release {
    <# Delete a release directory WITHOUT following its storage junction into shared\storage. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)
    $storage = Join-Path $Path 'storage'
    if (Test-Path -LiteralPath $storage) {
        $item = Get-Item -LiteralPath $storage -Force
        if ($item.LinkType) { [System.IO.Directory]::Delete($storage, $false) }
    }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
}
