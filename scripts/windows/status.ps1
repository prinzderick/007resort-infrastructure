<#
.SYNOPSIS
    Health of every part of the LOCAL NODE: services, ports, scheduled tasks, HTTP health, node heartbeat, backups, disk.

.DESCRIPTION
    Exit code 0 = everything healthy, 1 = at least one check failed (usable from monitoring / Task Scheduler).
    Heartbeat/sync details come from GET /api/v1/system/info (the API reports its own node role, version and sync
    state there; see architecture/sync/heartbeat-and-node-health.md). Nothing secret is printed.

.EXAMPLE
    .\status.ps1
.EXAMPLE
    .\status.ps1 -Json | ConvertFrom-Json
#>
[CmdletBinding()]
param(
    [string] $BaseUrl = 'http://127.0.0.1',
    [int] $MaxBackupAgeHours = 26,
    [switch] $Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\R007.Common.ps1')
Initialize-R007

$paths = Get-R007Paths
$state = Get-R007State
$results = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param([string] $Area, [string] $Name, [bool] $Ok, [string] $Detail = '', [switch] $WarnOnly)
    $results.Add([pscustomobject]@{ Area = $Area; Check = $Name; Ok = $Ok; Warn = ($WarnOnly -and -not $Ok); Detail = $Detail })
}

# ---- Services -------------------------------------------------------------------------------------------
$svcList = @($state.MySqlService, 'W3SVC') + @(Get-R007ServiceDefinitions -State $state | ForEach-Object { $_.Name })
if ($state.RedisProvider -ne 'External' -and $state.RedisProvider -ne 'Skip') { $svcList += $state.RedisService }
foreach ($n in $svcList) {
    $s = Get-R007Service -Name $n
    if (-not $s) { Add-Check 'service' $n $false 'not installed'; continue }
    $start = (Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue).StartMode
    Add-Check 'service' $n ($s.Status -eq 'Running') "$($s.Status), start=$start"
}

# ---- Scheduled tasks ---------------------------------------------------------------------------------------
foreach ($t in @('R007 Scheduler', 'R007 Nightly Backup', 'R007 Log Cleanup')) {
    $task = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    if (-not $task) { Add-Check 'task' $t $false 'not registered'; continue }
    $info = Get-ScheduledTaskInfo -TaskName $t
    $okRes = ($info.LastTaskResult -eq 0 -or $info.LastTaskResult -eq 267009 -or $info.LastTaskResult -eq 267011)   # OK / running / never run
    $limit = if ($t -eq 'R007 Scheduler') { (Get-Date).AddMinutes(-5) } else { (Get-Date).AddDays(-2) }
    Add-Check 'task' $t ($task.State -ne 'Disabled' -and $okRes -and $info.LastRunTime -gt $limit) "state=$($task.State) last=$($info.LastRunTime) result=$($info.LastTaskResult)"
}

# ---- Ports: MySQL/Redis must be loopback only; app ports must answer -----------------------------------------
$listen = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)
foreach ($p in @(3306, 6379)) {
    $wide = @($listen | Where-Object { $_.LocalPort -eq $p -and $_.LocalAddress -notin @('127.0.0.1', '::1') })
    Add-Check 'network' "tcp/$p loopback-only" ($wide.Count -eq 0) $(if ($wide.Count) { "listening on $($wide.LocalAddress -join ',')" } else { 'ok' })
}
Add-Check 'network' "http :$($state.HttpPort)" (Test-R007TcpPort -Port $state.HttpPort) ''
Add-Check 'network' "reverb :$($state.ReverbPort)" (Test-R007TcpPort -Port $state.ReverbPort) ''
$mysqlOk = Test-R007TcpPort -Port 3306
Add-Check 'database' 'mysql answers' $mysqlOk ''
if ($state.RedisProvider -ne 'Skip') {
    $rp = Get-R007EnvValue $paths.EnvFile 'REDIS_PASSWORD'
    Add-Check 'redis' 'PING' (Test-R007RedisPing -Password $rp) ''
}

# ---- HTTP + heartbeat ------------------------------------------------------------------------------------------
$up = Invoke-R007Http -Url "$BaseUrl/up"
Add-Check 'http' '/up' $up.Ok "status=$($up.Status)"
$info = Invoke-R007Http -Url "$BaseUrl/api/v1/system/info"
if ($info.Ok) {
    $detail = $info.Body
    try {
        $j = $info.Body | ConvertFrom-Json
        $data = if ($j.PSObject.Properties.Name -contains 'data') { $j.data } else { $j }
        $pieces = foreach ($name in @('node', 'appNode', 'version', 'appVersion', 'lastHeartbeatAt', 'lastSyncAt', 'syncStatus', 'outboxDepth', 'queueDepth', 'cloudReachable')) {
            if ($data.PSObject.Properties.Name -contains $name) { "$name=$($data.$name)" }
        }
        if ($pieces) { $detail = $pieces -join ' ' }
    }
    catch { $detail = 'response is not JSON' }
    Add-Check 'http' '/api/v1/system/info' $true $detail
    $nodeOk = ($info.Body -match '"(node|appNode)"\s*:\s*"local"')
    Add-Check 'node' 'reports APP_NODE=local' $nodeOk '' -WarnOnly
}
else { Add-Check 'http' '/api/v1/system/info' $false "status=$($info.Status)" }
Add-Check 'node' 'current release' ([bool] (Get-R007CurrentRelease)) (Get-R007CurrentRelease)

# ---- Backups + disk -----------------------------------------------------------------------------------------------
$full = Join-Path $state.BackupRoot 'full'
$last = if (Test-Path -LiteralPath $full) { Get-ChildItem -LiteralPath $full -Filter 'r007-*.sql.gz' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 } else { $null }
if ($last) { Add-Check 'backup' 'latest local backup' ($last.LastWriteTime -gt (Get-Date).AddHours(-$MaxBackupAgeHours)) "$($last.Name) at $($last.LastWriteTime)" }
else { Add-Check 'backup' 'latest local backup' $false 'none found' }
if ($state.NasPath) {
    $nasFull = Join-Path $state.NasPath 'full'
    $reach = Test-Path -LiteralPath $nasFull -ErrorAction SilentlyContinue
    Add-Check 'backup' 'NAS reachable' $reach $state.NasPath -WarnOnly
}
foreach ($drv in @(Get-PSDrive -PSProvider FileSystem | Where-Object { $null -ne $_.Free -and ($_.Used + $_.Free) -gt 0 })) {
    $pct = [math]::Round(100 * $drv.Free / ($drv.Used + $drv.Free))
    Add-Check 'disk' "$($drv.Name): free" ($pct -ge 15) "$pct% free" -WarnOnly
}

# ---- Output ---------------------------------------------------------------------------------------------------------
$failed = @($results | Where-Object { -not $_.Ok -and -not $_.Warn })
if ($Json) { $results | ConvertTo-Json -Depth 3 }
else {
    foreach ($r in $results) {
        $mark = if ($r.Ok) { 'OK  ' } elseif ($r.Warn) { 'WARN' } else { 'FAIL' }
        Write-Information ('{0} {1,-9} {2,-32} {3}' -f $mark, $r.Area, $r.Check, $r.Detail) -InformationAction Continue
    }
    Write-Information ("`n{0} check(s) failed, {1} warning(s)." -f $failed.Count, @($results | Where-Object { $_.Warn }).Count) -InformationAction Continue
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
