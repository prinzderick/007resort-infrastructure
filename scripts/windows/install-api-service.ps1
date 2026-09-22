<#
.SYNOPSIS
    Installs (or updates) the Otueke API as a Windows service on the on-site server.

.DESCRIPTION
    DRAFT - pending architecture approval.

    Registers the published ASP.NET Core API executable as a Windows service running
    under a dedicated low-privilege account, with automatic (delayed) start and
    restart-on-failure recovery actions.

    The API reads its configuration from environment variables / appsettings on the
    server (see env/site.env.example). This script never takes or stores secrets other
    than prompting for the service account password via Get-Credential.

.PARAMETER BinaryPath
    Full path to the published API executable, e.g. C:\Otueke\api\1.0.0\Otueke.Api.exe

.PARAMETER ServiceName
    Windows service name. Default: OtuekeApi

.PARAMETER ServiceCredential
    Credential of the account to run the service as (e.g. .\svc-otueke-api or
    DOMAIN\svc-otueke-api). If omitted, you will be prompted with Get-Credential.

.EXAMPLE
    .\install-api-service.ps1 -BinaryPath 'C:\Otueke\api\1.0.0\Otueke.Api.exe' -WhatIf

.NOTES
    Run from an elevated PowerShell session.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $BinaryPath,

    [string] $ServiceName = 'OtuekeApi',

    [string] $DisplayName = 'Otueke API',

    [string] $Description = 'Otueke Integrated Facility Operations Platform - API (site mode)',

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $ServiceCredential = [System.Management.Automation.PSCredential]::Empty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    throw 'This script must be run from an elevated PowerShell session.'
}

if ($ServiceCredential -eq [System.Management.Automation.PSCredential]::Empty) {
    $ServiceCredential = Get-Credential -Message "Service account for $ServiceName (e.g. .\svc-otueke-api)"
}

$resolvedBinary = (Resolve-Path -LiteralPath $BinaryPath).Path
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if ($null -ne $existing) {
    Write-Verbose "Service '$ServiceName' exists; updating binary path."
    if ($PSCmdlet.ShouldProcess($ServiceName, 'Stop service and update binary path')) {
        if ($existing.Status -ne 'Stopped') {
            Stop-Service -Name $ServiceName -Force
            $existing.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
        }
        # sc.exe is used because Set-Service cannot change the binary path on Windows PowerShell 5.1.
        & sc.exe config $ServiceName binPath= "`"$resolvedBinary`"" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "sc.exe config failed with exit code $LASTEXITCODE" }
    }
}
else {
    if ($PSCmdlet.ShouldProcess($ServiceName, "Create service for $resolvedBinary")) {
        New-Service -Name $ServiceName `
            -BinaryPathName "`"$resolvedBinary`"" `
            -DisplayName $DisplayName `
            -Description $Description `
            -StartupType Automatic `
            -Credential $ServiceCredential | Out-Null
    }
}

if ($PSCmdlet.ShouldProcess($ServiceName, 'Configure delayed auto-start and recovery actions')) {
    # Delayed auto start so MySQL is up first.
    & sc.exe config $ServiceName start= delayed-auto | Out-Null
    # Restart after 1 min, 1 min, then 5 min; reset failure count after 1 day.
    & sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/300000 | Out-Null
    & sc.exe failureflag $ServiceName 1 | Out-Null
    # Start only after the MySQL service (adjust the name to the installed MySQL service).
    & sc.exe config $ServiceName depend= MySQL84 | Out-Null
}

if ($PSCmdlet.ShouldProcess($ServiceName, 'Start service')) {
    Start-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
    Write-Output "Service '$ServiceName' is running. Verify: https://localhost:5443/health"
}
