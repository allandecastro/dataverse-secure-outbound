<#
.SYNOPSIS
  Runs Enterprise Policies diagnostics for Power Platform VNet scenarios.

.DESCRIPTION
  Uses Microsoft.PowerPlatform.EnterprisePolicies cmdlets to validate DNS/network/TLS
  from a Dataverse environment context.

.PARAMETER EnvironmentId
  Dataverse environment ID (GUID).

.PARAMETER HostName
  Hostname to resolve/test (for example: <func>.azurewebsites.net).

.PARAMETER Destination
  Destination host for TCP/TLS tests.

.PARAMETER Port
  Destination port (default 443).

.PARAMETER Region
  Optional Azure region hint (for environments with multi-region geography).

.EXAMPLE
  ./scripts/vnet/Test-Connectivity.ps1 `
    -EnvironmentId "<env-guid>" `
    -HostName "func-secureoutbound-vnet-dev.azurewebsites.net" `
    -Destination "func-secureoutbound-vnet-dev.azurewebsites.net" `
    -Port 443
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EnvironmentId,

    [Parameter(Mandatory = $true)]
    [string]$HostName,

    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [int]$Port = 443,
    [string]$Region
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Off

# Workaround for Microsoft.PowerPlatform.EnterprisePolicies module globals under strict mode.
$Global:InPesterExecution = $false
$Global:PrereqsChecked = $false

if (-not (Get-Module -ListAvailable -Name Microsoft.PowerPlatform.EnterprisePolicies)) {
    Write-Host "Installing Microsoft.PowerPlatform.EnterprisePolicies module..."
    Install-Module -Name Microsoft.PowerPlatform.EnterprisePolicies -Scope CurrentUser -Force
}

Import-Module Microsoft.PowerPlatform.EnterprisePolicies -ErrorAction Stop

Write-Host "=== Environment region ===" -ForegroundColor Cyan
Get-EnvironmentRegion -EnvironmentId $EnvironmentId

$common = @{
    EnvironmentId = $EnvironmentId
}
if (-not [string]::IsNullOrWhiteSpace($Region)) {
    $common.Region = $Region
}

Write-Host "`n=== DNS resolution ===" -ForegroundColor Cyan
Test-DnsResolution @common -HostName $HostName

Write-Host "`n=== Network connectivity ===" -ForegroundColor Cyan
Test-NetworkConnectivity @common -Destination $Destination -Port $Port

Write-Host "`n=== TLS handshake ===" -ForegroundColor Cyan
Test-TLSHandshake @common -Destination $Destination -Port $Port
