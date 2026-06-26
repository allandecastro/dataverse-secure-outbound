<#
.SYNOPSIS
  Creates and links a Power Platform subnet injection enterprise policy (2-region ready).

.DESCRIPTION
  Uses Microsoft.PowerPlatform.EnterprisePolicies cmdlets to:
  1) ensure delegated subnets exist in two Azure regions (for geographies that require pairing),
  2) create/update a NetworkInjection enterprise policy,
  3) link the policy to a Dataverse environment.

  Defaults are tuned for Europe:
  - policy location: europe
  - paired Azure regions: westeurope + northeurope

  The script is idempotent and supports auto-detection for tenant/subscription.

.PARAMETER EnvironmentId
  Dataverse environment ID (GUID).

.PARAMETER SubscriptionId
  Azure subscription ID (auto-detected when omitted).

.PARAMETER TenantId
  Entra tenant ID (auto-detected when omitted).

.EXAMPLE
  ./scripts/vnet/Setup-PowerPlatformEnterprisePolicy.ps1 -EnvironmentId "<env-guid>"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EnvironmentId,

    [string]$SubscriptionId,
    [string]$TenantId,

    [string]$ResourceGroupName = "rg-secureoutbound-vnet-dev",
    [string]$PolicyName = "epp-secureoutbound-vnet-dev",
    [string]$PolicyLocation = "europe",

    [string]$PrimaryRegion = "westeurope",
    [string]$SecondaryRegion = "northeurope",

    [string]$PrimaryVnetName = "vnet-ppinject-we-dev",
    [string]$PrimarySubnetName = "snet-ppinject",
    [string]$PrimaryAddressPrefix = "10.90.0.0/16",
    [string]$PrimarySubnetPrefix = "10.90.1.0/24",

    [string]$SecondaryVnetName = "vnet-ppinject-ne-dev",
    [string]$SecondarySubnetName = "snet-ppinject",
    [string]$SecondaryAddressPrefix = "10.91.0.0/16",
    [string]$SecondarySubnetPrefix = "10.91.1.0/24",

    [switch]$SwapExistingPolicy
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Off

# Workaround: module 0.17.0 reads this global under strict mode during import.
$Global:InPesterExecution = $false
$Global:PrereqsChecked = $false

function Ensure-Module {
    param([string]$Name)

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        Write-Host "Installing PowerShell module '$Name'..."
        Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $Name -ErrorAction Stop
}

function Resolve-Value {
    param(
        [string]$CurrentValue,
        [string]$FallbackValue,
        [string]$Prompt
    )
    if (-not [string]::IsNullOrWhiteSpace($CurrentValue)) { return $CurrentValue }
    if (-not [string]::IsNullOrWhiteSpace($FallbackValue)) { return $FallbackValue }
    $value = $null
    while ([string]::IsNullOrWhiteSpace($value)) {
        $value = Read-Host $Prompt
    }
    return $value
}

# 0) Context
$accountRaw = az account show -o json 2>$null
if ([string]::IsNullOrWhiteSpace($accountRaw)) {
    Write-Host "Not logged in to Azure CLI. Running 'az login'..."
    az login | Out-Null
    $accountRaw = az account show -o json
}
$account = $accountRaw | ConvertFrom-Json

$TenantId = Resolve-Value -CurrentValue $TenantId -FallbackValue $account.tenantId -Prompt "Enter Azure Tenant ID"
$SubscriptionId = Resolve-Value -CurrentValue $SubscriptionId -FallbackValue $account.id -Prompt "Enter Azure Subscription ID"

az account set --subscription $SubscriptionId | Out-Null

Write-Host ""
Write-Host "=== Power Platform policy context ===" -ForegroundColor Cyan
Write-Host "EnvironmentId   : $EnvironmentId"
Write-Host "TenantId        : $TenantId"
Write-Host "SubscriptionId  : $SubscriptionId"
Write-Host "ResourceGroup   : $ResourceGroupName"
Write-Host "PolicyName      : $PolicyName"
Write-Host "PolicyLocation  : $PolicyLocation"
Write-Host "Regions         : $PrimaryRegion + $SecondaryRegion"

# 1) Module
Ensure-Module -Name "Microsoft.PowerPlatform.EnterprisePolicies"

# 2) Ensure delegated VNet/Subnet (primary)
Write-Host "`n=== Ensuring delegated subnet (primary) ===" -ForegroundColor Cyan
$vnetPrimary = New-VnetForSubnetDelegation `
    -SubscriptionId $SubscriptionId `
    -VirtualNetworkName $PrimaryVnetName `
    -SubnetName $PrimarySubnetName `
    -ResourceGroupName $ResourceGroupName `
    -Region $PrimaryRegion `
    -CreateVirtualNetwork `
    -AddressPrefix $PrimaryAddressPrefix `
    -SubnetPrefix $PrimarySubnetPrefix `
    -TenantId $TenantId

if ($null -eq $vnetPrimary -or [string]::IsNullOrWhiteSpace($vnetPrimary.Id)) {
    throw "Primary delegated VNet was not created/resolved."
}

# 3) Ensure delegated VNet/Subnet (secondary)
Write-Host "`n=== Ensuring delegated subnet (secondary) ===" -ForegroundColor Cyan
$vnetSecondary = New-VnetForSubnetDelegation `
    -SubscriptionId $SubscriptionId `
    -VirtualNetworkName $SecondaryVnetName `
    -SubnetName $SecondarySubnetName `
    -ResourceGroupName $ResourceGroupName `
    -Region $SecondaryRegion `
    -CreateVirtualNetwork `
    -AddressPrefix $SecondaryAddressPrefix `
    -SubnetPrefix $SecondarySubnetPrefix `
    -TenantId $TenantId

if ($null -eq $vnetSecondary -or [string]::IsNullOrWhiteSpace($vnetSecondary.Id)) {
    throw "Secondary delegated VNet was not created/resolved."
}

# 4) Create/update enterprise policy
Write-Host "`n=== Creating/updating enterprise policy ===" -ForegroundColor Cyan
$policy = New-SubnetInjectionEnterprisePolicy `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -PolicyName $PolicyName `
    -PolicyLocation $PolicyLocation `
    -VirtualNetworkId $vnetPrimary.Id `
    -SubnetName $PrimarySubnetName `
    -VirtualNetworkId2 $vnetSecondary.Id `
    -SubnetName2 $SecondarySubnetName `
    -TenantId $TenantId

$policyArmId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.PowerPlatform/enterprisePolicies/$PolicyName"
Write-Host "Policy ARM ID: $policyArmId"

# 5) Link policy to environment
Write-Host "`n=== Linking policy to Power Platform environment ===" -ForegroundColor Cyan
if ($SwapExistingPolicy) {
    Enable-SubnetInjection `
        -EnvironmentId $EnvironmentId `
        -PolicyArmId $policyArmId `
        -TenantId $TenantId `
        -Swap
} else {
    Enable-SubnetInjection `
        -EnvironmentId $EnvironmentId `
        -PolicyArmId $policyArmId `
        -TenantId $TenantId
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Power Platform subnet injection is set" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "EnvironmentId : $EnvironmentId"
Write-Host "PolicyArmId   : $policyArmId"
Write-Host "Primary VNet  : $($vnetPrimary.Id)"
Write-Host "Secondary VNet: $($vnetSecondary.Id)"
