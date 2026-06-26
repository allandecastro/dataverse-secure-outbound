<#
.SYNOPSIS
  Provisions DEV Azure infrastructure for a private Function App endpoint.

.DESCRIPTION
  Creates (or reuses) a dedicated resource group, VNet/subnet, storage account,
  App Service plan (Elastic Premium), Function App, Private Endpoint, and Private DNS
  plumbing for `privatelink.azurewebsites.net`.

  This script is idempotent and supports:
  - auto-detect tenant/subscription from `az account show`
  - explicit override via parameters

  Note:
  OAuth2/Auth settings for Function App are configured separately in
  `Configure-FunctionAuth.ps1`.

.PARAMETER SubscriptionId
  Azure subscription ID (auto-detected when omitted).

.PARAMETER TenantId
  Entra tenant ID (auto-detected when omitted).

.PARAMETER ResourceGroupName
  Target resource group for DEV infra.

.PARAMETER Location
  Azure region.

.PARAMETER DisablePublicNetworkAccess
  When true (default), sets Function App public network access to Disabled.

.EXAMPLE
  ./scripts/vnet/Setup-FunctionPrivateEndpoint.ps1

.EXAMPLE
  ./scripts/vnet/Setup-FunctionPrivateEndpoint.ps1 `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -TenantId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" `
    -FunctionAppName "func-secureoutbound-vnet-dev"
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$ResourceGroupName = "rg-secureoutbound-vnet-dev",
    [string]$Location = "westeurope",
    [string]$VirtualNetworkName = "vnet-secureoutbound-vnet-dev",
    [string]$PrivateEndpointSubnetName = "snet-private-endpoints",
    [string]$PrivateEndpointSubnetPrefix = "10.81.1.0/24",
    [string]$FunctionPlanName = "asp-secureoutbound-vnet-dev",
    [string]$FunctionAppName = "func-secureoutbound-vnet-dev",
    [string]$StorageAccountName,
    [string]$ApplicationInsightsName = "appi-secureoutbound-vnet-dev",
    [string]$PrivateEndpointName = "pep-secureoutbound-func-dev",
    [string]$PrivateDnsZoneName = "privatelink.azurewebsites.net",
    [bool]$DisablePublicNetworkAccess = $true
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-AzJson {
    param(
        [Parameter(Mandatory = $true)][string]$Command
    )

    $raw = Invoke-Expression "$Command 2>`$null"
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    try {
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Ensure-AzLogin {
    $account = Get-AzJson -Command "az account show -o json"
    if ($null -eq $account) {
        Write-Host "Not logged in to Azure CLI. Running 'az login'..."
        az login | Out-Null
        $account = Get-AzJson -Command "az account show -o json"
        if ($null -eq $account) {
            throw "Azure CLI login failed."
        }
    }
    return $account
}

function Resolve-Value {
    param(
        [string]$CurrentValue,
        [string]$FallbackValue,
        [string]$Prompt
    )

    if (-not [string]::IsNullOrWhiteSpace($CurrentValue)) {
        return $CurrentValue
    }
    if (-not [string]::IsNullOrWhiteSpace($FallbackValue)) {
        return $FallbackValue
    }

    $value = $null
    while ([string]::IsNullOrWhiteSpace($value)) {
        $value = Read-Host $Prompt
    }
    return $value
}

function Get-AvailableStorageAccountName {
    param(
        [Parameter(Mandatory = $true)][string]$BaseName
    )

    $candidate = ($BaseName.ToLowerInvariant() -replace "[^a-z0-9]", "")
    if ($candidate.Length -gt 20) {
        $candidate = $candidate.Substring(0, 20)
    }
    if ($candidate.Length -lt 3) {
        $candidate = "stsecureoutbound"
    }

    for ($i = 0; $i -lt 20; $i++) {
        $suffix = -join ((48..57 + 97..122) | Get-Random -Count 4 | ForEach-Object { [char]$_ })
        $name = "$candidate$suffix"
        $available = az storage account check-name --name $name --query nameAvailable -o tsv
        if ($available -eq "true") {
            return $name
        }
    }

    throw "Could not find an available storage account name after multiple attempts."
}

# 0) Resolve tenant/subscription context
$account = Ensure-AzLogin
$TenantId = Resolve-Value -CurrentValue $TenantId -FallbackValue $account.tenantId -Prompt "Enter Azure Tenant ID"
$SubscriptionId = Resolve-Value -CurrentValue $SubscriptionId -FallbackValue $account.id -Prompt "Enter Azure Subscription ID"

az account set --subscription $SubscriptionId | Out-Null
az config set extension.use_dynamic_install=yes_without_prompt | Out-Null

if ([string]::IsNullOrWhiteSpace($StorageAccountName)) {
    $StorageAccountName = Get-AvailableStorageAccountName -BaseName "st$FunctionAppName"
}

Write-Host ""
Write-Host "=== Deployment context ===" -ForegroundColor Cyan
Write-Host "TenantId                  : $TenantId"
Write-Host "SubscriptionId            : $SubscriptionId"
Write-Host "ResourceGroup             : $ResourceGroupName"
Write-Host "Location                  : $Location"
Write-Host "FunctionAppName           : $FunctionAppName"
Write-Host "StorageAccountName        : $StorageAccountName"
Write-Host "DisablePublicNetworkAccess: $DisablePublicNetworkAccess"

# 1) Resource group
Write-Host "`n=== Resource Group ===" -ForegroundColor Cyan
$rg = Get-AzJson -Command "az group show --name $ResourceGroupName -o json"
if ($null -eq $rg) {
    az group create --name $ResourceGroupName --location $Location | Out-Null
    Write-Host "Created resource group '$ResourceGroupName'."
} else {
    Write-Host "Resource group '$ResourceGroupName' already exists."
}

# 2) VNet + subnet for private endpoints
Write-Host "`n=== VNet / Subnet ===" -ForegroundColor Cyan
$vnet = Get-AzJson -Command "az network vnet show --resource-group $ResourceGroupName --name $VirtualNetworkName -o json"
if ($null -eq $vnet) {
    az network vnet create `
        --resource-group $ResourceGroupName `
        --name $VirtualNetworkName `
        --location $Location `
        --address-prefixes "10.81.0.0/16" `
        --subnet-name $PrivateEndpointSubnetName `
        --subnet-prefixes $PrivateEndpointSubnetPrefix | Out-Null
    Write-Host "Created VNet '$VirtualNetworkName' and subnet '$PrivateEndpointSubnetName'."
} else {
    Write-Host "VNet '$VirtualNetworkName' already exists."
    $peSubnet = Get-AzJson -Command "az network vnet subnet show --resource-group $ResourceGroupName --vnet-name $VirtualNetworkName --name $PrivateEndpointSubnetName -o json"
    if ($null -eq $peSubnet) {
        az network vnet subnet create `
            --resource-group $ResourceGroupName `
            --vnet-name $VirtualNetworkName `
            --name $PrivateEndpointSubnetName `
            --address-prefixes $PrivateEndpointSubnetPrefix | Out-Null
        Write-Host "Created subnet '$PrivateEndpointSubnetName'."
    } else {
        Write-Host "Subnet '$PrivateEndpointSubnetName' already exists."
    }
}

# 3) Storage account
Write-Host "`n=== Storage Account ===" -ForegroundColor Cyan
$st = Get-AzJson -Command "az storage account show --resource-group $ResourceGroupName --name $StorageAccountName -o json"
if ($null -eq $st) {
    az storage account create `
        --resource-group $ResourceGroupName `
        --name $StorageAccountName `
        --location $Location `
        --sku Standard_LRS `
        --kind StorageV2 `
        --min-tls-version TLS1_2 | Out-Null
    Write-Host "Created storage account '$StorageAccountName'."
} else {
    Write-Host "Storage account '$StorageAccountName' already exists."
}

# 4) Application Insights
Write-Host "`n=== Application Insights ===" -ForegroundColor Cyan
$appi = Get-AzJson -Command "az monitor app-insights component show --app $ApplicationInsightsName --resource-group $ResourceGroupName -o json"
if ($null -eq $appi) {
    az monitor app-insights component create `
        --app $ApplicationInsightsName `
        --location $Location `
        --resource-group $ResourceGroupName `
        --application-type web | Out-Null
    Write-Host "Created Application Insights '$ApplicationInsightsName'."
} else {
    Write-Host "Application Insights '$ApplicationInsightsName' already exists."
}

# 5) Function plan (Elastic Premium)
Write-Host "`n=== Function Plan (EP1) ===" -ForegroundColor Cyan
$plan = Get-AzJson -Command "az functionapp plan show --resource-group $ResourceGroupName --name $FunctionPlanName -o json"
if ($null -eq $plan) {
    az functionapp plan create `
        --resource-group $ResourceGroupName `
        --name $FunctionPlanName `
        --location $Location `
        --sku EP1 `
        --is-linux | Out-Null
    Write-Host "Created Function plan '$FunctionPlanName' (EP1)."
} else {
    Write-Host "Function plan '$FunctionPlanName' already exists."
}

# 6) Function app
Write-Host "`n=== Function App ===" -ForegroundColor Cyan
$func = Get-AzJson -Command "az functionapp show --resource-group $ResourceGroupName --name $FunctionAppName -o json"
if ($null -eq $func) {
    az functionapp create `
        --resource-group $ResourceGroupName `
        --name $FunctionAppName `
        --storage-account $StorageAccountName `
        --plan $FunctionPlanName `
        --os-type Linux `
        --functions-version 4 `
        --runtime dotnet-isolated `
        --app-insights $ApplicationInsightsName `
        --https-only true | Out-Null
    Write-Host "Created Function App '$FunctionAppName'."
    $func = Get-AzJson -Command "az functionapp show --resource-group $ResourceGroupName --name $FunctionAppName -o json"
} else {
    Write-Host "Function App '$FunctionAppName' already exists."
}

# 7) Private endpoint
Write-Host "`n=== Private Endpoint ===" -ForegroundColor Cyan
$pe = Get-AzJson -Command "az network private-endpoint show --resource-group $ResourceGroupName --name $PrivateEndpointName -o json"
if ($null -eq $pe) {
    az network private-endpoint create `
        --name $PrivateEndpointName `
        --resource-group $ResourceGroupName `
        --vnet-name $VirtualNetworkName `
        --subnet $PrivateEndpointSubnetName `
        --private-connection-resource-id $func.id `
        --group-ids sites `
        --connection-name "pec-$FunctionAppName" | Out-Null
    Write-Host "Created Private Endpoint '$PrivateEndpointName'."
} else {
    Write-Host "Private Endpoint '$PrivateEndpointName' already exists."
}

# 8) Private DNS zone + link + zone group
Write-Host "`n=== Private DNS ===" -ForegroundColor Cyan
$zone = Get-AzJson -Command "az network private-dns zone show --resource-group $ResourceGroupName --name $PrivateDnsZoneName -o json"
if ($null -eq $zone) {
    az network private-dns zone create `
        --resource-group $ResourceGroupName `
        --name $PrivateDnsZoneName | Out-Null
    Write-Host "Created Private DNS zone '$PrivateDnsZoneName'."
} else {
    Write-Host "Private DNS zone '$PrivateDnsZoneName' already exists."
}

$dnsLinkName = "link-$VirtualNetworkName"
$dnsLink = Get-AzJson -Command "az network private-dns link vnet show --resource-group $ResourceGroupName --zone-name $PrivateDnsZoneName --name $dnsLinkName -o json"
if ($null -eq $dnsLink) {
    $vnetId = (az network vnet show --resource-group $ResourceGroupName --name $VirtualNetworkName --query id -o tsv)
    az network private-dns link vnet create `
        --resource-group $ResourceGroupName `
        --zone-name $PrivateDnsZoneName `
        --name $dnsLinkName `
        --virtual-network $vnetId `
        --registration-enabled false | Out-Null
    Write-Host "Created DNS link '$dnsLinkName'."
} else {
    Write-Host "DNS link '$dnsLinkName' already exists."
}

$zoneGroup = Get-AzJson -Command "az network private-endpoint dns-zone-group show --resource-group $ResourceGroupName --endpoint-name $PrivateEndpointName --name default -o json"
if ($null -eq $zoneGroup) {
    az network private-endpoint dns-zone-group create `
        --resource-group $ResourceGroupName `
        --endpoint-name $PrivateEndpointName `
        --name default `
        --private-dns-zone $PrivateDnsZoneName `
        --zone-name $PrivateDnsZoneName | Out-Null
    Write-Host "Created private endpoint DNS zone group."
} else {
    Write-Host "Private endpoint DNS zone group already exists."
}

# 9) Public network access
if ($DisablePublicNetworkAccess) {
    Write-Host "`n=== Function public access ===" -ForegroundColor Cyan
    az functionapp update `
        --resource-group $ResourceGroupName `
        --name $FunctionAppName `
        --set publicNetworkAccess=Disabled | Out-Null
    Write-Host "Set Function App publicNetworkAccess=Disabled."
}

# Summary
$defaultHostname = az functionapp show --resource-group $ResourceGroupName --name $FunctionAppName --query defaultHostName -o tsv
Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Function private endpoint setup complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Resource Group      : $ResourceGroupName"
Write-Host "Function App        : $FunctionAppName"
Write-Host "Function Hostname   : $defaultHostname"
Write-Host "Storage Account     : $StorageAccountName"
Write-Host "VNet/Subnet         : $VirtualNetworkName / $PrivateEndpointSubnetName"
Write-Host "Private Endpoint    : $PrivateEndpointName"
Write-Host "Private DNS Zone    : $PrivateDnsZoneName"
Write-Host ""
Write-Host "Next step:"
Write-Host "  Run scripts/vnet/Configure-FunctionAuth.ps1 to enforce OAuth2 on the Function App."
