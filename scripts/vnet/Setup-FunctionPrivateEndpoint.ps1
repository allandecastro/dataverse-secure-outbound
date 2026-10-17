<#
.SYNOPSIS
  Provisions DEV Azure infrastructure for a private Function App endpoint.

.DESCRIPTION
  Creates (or reuses) a dedicated resource group, VNet/subnet, storage account,
  App Service plan (Basic B1, Linux), Function App (.NET 10 isolated, Always On), deploys the
  ErpMockFunction package, then adds the Private Endpoint and Private DNS plumbing for
  `privatelink.azurewebsites.net` and finally disables public access.

  Why B1 and not Elastic Premium: a private endpoint only needs a dedicated (Basic+) or Premium
  plan. B1 is ~12 EUR/month vs ~150 EUR/month for EP1 and stays warm with Always On.

  The code is deployed BEFORE public access is disabled: once the site is private, a zip deploy
  from outside the VNet is rejected.

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

.PARAMETER FunctionPlanSku
  App Service plan SKU (default: B1).

.PARAMETER PackagePath
  Zip package of the Function to deploy (default: src/ErpMockFunction/publish.zip).
  Pass an empty string to skip the deployment.

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
    [string]$FunctionPlanName = "asp-secure-outbound-demo-b1",
    [string]$FunctionPlanSku = "B1",
    [string]$FunctionAppName = "func-secureoutbound-vnet-dev",
    [string]$StorageAccountName,
    [string]$ApplicationInsightsName = "appi-secureoutbound-vnet-dev",
    [string]$PrivateEndpointName = "pep-secureoutbound-func-dev",
    [string]$PrivateDnsZoneName = "privatelink.azurewebsites.net",
    [string]$PackagePath = (Join-Path $PSScriptRoot "../../src/ErpMockFunction/publish.zip"),
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
    # Reuse the storage account of an existing Function App so re-runs stay idempotent.
    $existingStorage = az functionapp config appsettings list --resource-group $ResourceGroupName --name $FunctionAppName --query "[?name=='AzureWebJobsStorage'].value | [0]" -o tsv 2>$null
    if ($existingStorage -match 'AccountName=([^;]+)') { $StorageAccountName = $Matches[1] }
}
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

# 5) App Service plan (dedicated, Linux)
# An existing Function on another plan (e.g. the former EP1) is NOT moved: Azure does not support
# in-place Linux migrations from Elastic Premium to a dedicated plan, and creating the new plan
# anyway would bill both. Stop and let the operator recreate the app explicitly.
$existingPlanId = az functionapp show --resource-group $ResourceGroupName --name $FunctionAppName --query serverFarmId -o tsv 2>$null
if (-not [string]::IsNullOrWhiteSpace($existingPlanId)) {
    $existingPlanName = ($existingPlanId -split '/')[-1]
    if ($existingPlanName -ne $FunctionPlanName) {
        throw ("Function App '$FunctionAppName' runs on plan '$existingPlanName', not '$FunctionPlanName'. " +
               "Linux apps cannot be moved in place: delete the private endpoint '$PrivateEndpointName' and the " +
               "Function App, re-run this script to recreate them on '$FunctionPlanName', then delete the unused " +
               "plan '$existingPlanName'. Or pass -FunctionPlanName '$existingPlanName' to keep the current plan.")
    }
}

Write-Host "`n=== App Service Plan ($FunctionPlanSku) ===" -ForegroundColor Cyan
$plan = Get-AzJson -Command "az appservice plan show --resource-group $ResourceGroupName --name $FunctionPlanName -o json"
if ($null -eq $plan) {
    az appservice plan create `
        --resource-group $ResourceGroupName `
        --name $FunctionPlanName `
        --location $Location `
        --sku $FunctionPlanSku `
        --is-linux | Out-Null
    Write-Host "Created App Service plan '$FunctionPlanName' ($FunctionPlanSku)."
} else {
    Write-Host "App Service plan '$FunctionPlanName' already exists."
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
        --runtime-version 10 `
        --app-insights $ApplicationInsightsName `
        --https-only true | Out-Null
    Write-Host "Created Function App '$FunctionAppName'."
    $func = Get-AzJson -Command "az functionapp show --resource-group $ResourceGroupName --name $FunctionAppName -o json"
} else {
    Write-Host "Function App '$FunctionAppName' already exists."
}

# Pin the runtime to the version the code targets (net10.0). Without an explicit pin Azure picks its
# current default, and a mismatch with the target framework makes the worker fail to start (HTTP 503).
# Keep this in sync with <TargetFramework> in src/ErpMockFunction/ErpMockFunction.csproj.
az functionapp config set `
    --resource-group $ResourceGroupName `
    --name $FunctionAppName `
    --linux-fx-version "DOTNET-ISOLATED|10.0" `
    --always-on true | Out-Null
Write-Host "Runtime pinned to DOTNET-ISOLATED|10.0, Always On enabled."

# 6b) Deploy the code while the site is temporarily publicly reachable. Public access is closed
#     again in 'finally', so a failed or timed-out deployment never leaves the Function exposed
#     (the demo handler only checks for a non-empty bearer token).
if (-not [string]::IsNullOrWhiteSpace($PackagePath)) {
    Write-Host "`n=== Deploy Function package ===" -ForegroundColor Cyan
    if (-not (Test-Path $PackagePath)) { throw "Function package not found: $PackagePath" }
    try {
        az functionapp update `
            --resource-group $ResourceGroupName `
            --name $FunctionAppName `
            --set publicNetworkAccess=Enabled | Out-Null
        az functionapp deployment source config-zip `
            --resource-group $ResourceGroupName `
            --name $FunctionAppName `
            --src (Resolve-Path $PackagePath).Path `
            --timeout 600 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Zip deployment of '$PackagePath' failed." }
        Write-Host "Deployed '$PackagePath'."
    }
    finally {
        if ($DisablePublicNetworkAccess) {
            az functionapp update `
                --resource-group $ResourceGroupName `
                --name $FunctionAppName `
                --set publicNetworkAccess=Disabled | Out-Null
            Write-Host "Public network access disabled again."
        }
    }
}

# 6c) Public network access - closed before the private endpoint/DNS steps, so a later failure
#     there cannot leave the Function exposed (the private endpoint does not need it).
if ($DisablePublicNetworkAccess) {
    Write-Host "`n=== Function public access ===" -ForegroundColor Cyan
    az functionapp update `
        --resource-group $ResourceGroupName `
        --name $FunctionAppName `
        --set publicNetworkAccess=Disabled | Out-Null
    Write-Host "Set Function App publicNetworkAccess=Disabled."
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

# The zone group is what writes the A records (<func> -> private IP) into the zone. It must be
# given the zone's resource ID: with a bare zone name the call fails and the zone stays empty.
$zoneGroup = Get-AzJson -Command "az network private-endpoint dns-zone-group show --resource-group $ResourceGroupName --endpoint-name $PrivateEndpointName --name default -o json"
if ($null -eq $zoneGroup) {
    $zoneId = (az network private-dns zone show --resource-group $ResourceGroupName --name $PrivateDnsZoneName --query id -o tsv)
    az network private-endpoint dns-zone-group create `
        --resource-group $ResourceGroupName `
        --endpoint-name $PrivateEndpointName `
        --name default `
        --private-dns-zone $zoneId `
        --zone-name ($PrivateDnsZoneName -replace '\.', '-') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to create the private endpoint DNS zone group." }
    Write-Host "Created private endpoint DNS zone group."
} else {
    Write-Host "Private endpoint DNS zone group already exists."
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
Write-Host "Note: the demo deliberately does NOT run Configure-FunctionAuth.ps1 (the boundary shown is the network)."
