<#
.SYNOPSIS
  One-shot provisioning for DEMO 2 - the Network pillar (VNet / subnet injection).

.DESCRIPTION
  Adds the NETWORK layer on top of the shared base created by Provision-Demo1-Identity.ps1,
  and wires the Demo 2 (Network) environment:

    1. Setup-FunctionPrivateEndpoint.ps1  -> shared private Function App (B1, .NET 10, code deployed,
                                             publicNetworkAccess=Disabled) + VNet + private endpoint
                                             + private DNS, in the shared RG
    2. Setup-AzureResources.ps1           -> Demo 2 MI + FIC (so the MI token works) and RBAC on the
                                             SAME shared Key Vault (idempotent: the vault already exists)
    3. Provision-ManagedIdentityDataverseRecord.ps1 -> managedidentity row in the Demo 2 env
    4. Setup-PowerPlatformEnterprisePolicy.ps1 -> subnet injection enterprise policy linked to Demo 2
       (the environment must already be a Managed Environment)
    5. One NSG PER REGION on the injected subnets: allow VirtualNetwork, deny Internet outbound. This
       is what blocks the Key Vault for Demo 2 - NOT the vault firewall (the vault stays public so
       Demo 1 keeps working). A drop/blackhole means the read hangs until the client timeout (~10 s),
       then the plug-in surfaces the "Key Vault is outside the VNet" message. An NSG can only be
       attached to a subnet in its own region, hence one NSG per injection VNet.
    6. Peering between the Function VNet and each injection VNet (both directions) + link of the
       privatelink.azurewebsites.net zone to each injection VNet. Without these the injected
       environment can neither resolve nor reach the private endpoint.
    7. Print the Function hostname for Test-Connectivity.ps1

  ONE shared Key Vault and ONE shared private Function App serve both demos; the two environments
  point their Environment Variables at the SAME URLs. Only the network posture differs:

    - Demo 1 is NOT injected: public Key Vault reachable (success), private Function unreachable (fail).
    - Demo 2 IS injected (this script): private Function reachable through the injected subnet
      (success), Key Vault blocked by the NSG drop rule on that subnet (fail).

  WHY we still provision a WORKING MI + FIC + managedidentity record here:
    so the MI token acquisition SUCCEEDS and the Key Vault failure is purely a NETWORK failure
    ("the vault is outside the VNet"), not an "identity not configured" error.

  We deliberately do NOT run Configure-FunctionAuth.ps1 - the boundary demonstrated in Demo 2 is the
  network (private endpoint), so a simple demo bearer token is enough. Enabling Entra platform auth
  would 401 the demo token and turn the success cell into a misleading failure.

  Idempotent - safe to re-run. Run Provision-Demo1-Identity.ps1 first (it creates the shared RG + KV
  + secret), then this. Pre-provision BEFORE the live demo - subnet injection needs time to
  propagate, so validate with Test-Connectivity.ps1 ahead of time, not live.

.PARAMETER TenantId            Entra tenant ID (GUID).
.PARAMETER SubscriptionId      Azure subscription ID.
.PARAMETER EnvironmentId       Dataverse environment ID of the Demo 2 environment (GUID).
.PARAMETER DataverseUrl        Demo 2 Dataverse org URL, e.g. https://demo2.crm.dynamics.com
.PARAMETER ManagedIdentityApplicationId      Optional. App/client ID of the Demo 2 MI. Resolved from the
                                             MI created in step 2 when omitted.
.PARAMETER DataverseRecordManagedIdentityId  Fixed managedidentity GUID (same value across envs).
.PARAMETER CertificatePath     Path to the code-signing .pfx/.cer (used for the FIC subject).
.PARAMETER CertificatePassword Password for the .pfx (omit for .cer).
.PARAMETER ResourceGroupName   Shared RG for both demos (default: rg-secure-outbound-demo).
.PARAMETER Location            Azure region (default: westeurope).
.PARAMETER FunctionVnetName    VNet holding the Function private endpoint (matches Setup-FunctionPrivateEndpoint).
.PARAMETER FunctionAppName     Shared private Function App name (default: func-secure-outbound-demo).
.PARAMETER KeyVaultName        Name of the SHARED Key Vault (default: kv-secure-outbound-demo).
.PARAMETER ManagedIdentityName Name of the Demo 2 User-Assigned MI (default: mi-secure-outbound-demo2).
.PARAMETER SecretName          Secret name (must match Demo 1; default: AccountSecret).
.PARAMETER SecretValue         Secret value (must match Demo 1 - same shared vault).
.PARAMETER InjectionVnetPrimary    Primary injection VNet name (matches Setup-PowerPlatformEnterprisePolicy).
.PARAMETER InjectionVnetSecondary  Secondary injection VNet name (matches Setup-PowerPlatformEnterprisePolicy).
.PARAMETER InjectionSubnetName      Injected subnet name (matches Setup-PowerPlatformEnterprisePolicy).

.EXAMPLE
  ./scripts/Provision-Demo2-Network.ps1 `
    -TenantId       "<tenant-guid>" `
    -SubscriptionId "<sub-guid>" `
    -EnvironmentId  "<demo2-env-guid>" `
    -DataverseUrl   "https://secure-outbound-demo2.crm4.dynamics.com" `
    -DataverseRecordManagedIdentityId "<fixed-mi-guid>" `
    -CertificatePath "codesign.pfx" -CertificatePassword "P@ss"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TenantId,
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [Parameter(Mandatory = $true)][string]$EnvironmentId,
    [Parameter(Mandatory = $true)][string]$DataverseUrl,
    [string]$ManagedIdentityApplicationId,
    [Parameter(Mandatory = $true)][string]$DataverseRecordManagedIdentityId,
    [Parameter(Mandatory = $true)][string]$CertificatePath,
    [string]$CertificatePassword,

    [string]$ResourceGroupName   = "rg-secure-outbound-demo",
    [string]$Location            = "westeurope",
    [string]$FunctionVnetName    = "vnet-secureoutbound-vnet-dev",
    [string]$FunctionAppName     = "func-secure-outbound-demo",
    [string]$KeyVaultName        = "kv-secure-outbound-demo",
    [string]$ManagedIdentityName = "mi-secure-outbound-demo2",
    [string]$SecretName          = "AccountSecret",
    [string]$SecretValue         = "Hello-From-KeyVault-2026",

    # Injection VNet/subnet names - keep in sync with Setup-PowerPlatformEnterprisePolicy.ps1.
    [string]$InjectionVnetPrimary   = "vnet-ppinject-we-dev",
    [string]$InjectionVnetSecondary = "vnet-ppinject-ne-dev",
    [string]$InjectionSubnetName    = "snet-ppinject"
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot

function Write-Banner($text) {
    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host "==================================================================" -ForegroundColor Cyan
}

Write-Banner "DEMO 2 - NETWORK PILLAR (VNet / subnet injection)"
Write-Host "Resource group : $ResourceGroupName (shared with Demo 1)"
Write-Host "Function App   : $FunctionAppName (shared, private, publicNetworkAccess=Disabled)"
Write-Host "Key Vault      : $KeyVaultName (shared, public; blocked here by an NSG on the injected subnet)"
Write-Host "Managed Id     : $ManagedIdentityName (Demo 2 env)"
Write-Host "Dataverse env  : $DataverseUrl"

# 1. Shared private Function App + VNet -----------------------------------------------
Write-Banner "1/7  Shared private Function App + VNet"
& "$scriptRoot/vnet/Setup-FunctionPrivateEndpoint.ps1" `
    -SubscriptionId             $SubscriptionId `
    -TenantId                   $TenantId `
    -ResourceGroupName          $ResourceGroupName `
    -Location                   $Location `
    -FunctionAppName            $FunctionAppName `
    -VirtualNetworkName         $FunctionVnetName `
    -DisablePublicNetworkAccess $true

# 2. Demo 2 identity: MI + FIC + RBAC on the SHARED Key Vault (so the MI token succeeds) -
Write-Banner "2/7  Azure resources (Demo 2 MI + FIC + RBAC on shared Key Vault)"
& "$scriptRoot/Setup-AzureResources.ps1" `
    -TenantId            $TenantId `
    -SubscriptionId      $SubscriptionId `
    -EnvironmentId       $EnvironmentId `
    -CertificatePath     $CertificatePath `
    -CertificatePassword $CertificatePassword `
    -ResourceGroupName   $ResourceGroupName `
    -Location            $Location `
    -KeyVaultName        $KeyVaultName `
    -ManagedIdentityName $ManagedIdentityName

# The MI is created by step 2, so its client ID is only known now.
if ([string]::IsNullOrWhiteSpace($ManagedIdentityApplicationId)) {
    $ManagedIdentityApplicationId = az identity show --name $ManagedIdentityName --resource-group $ResourceGroupName --query clientId -o tsv
    if ([string]::IsNullOrWhiteSpace($ManagedIdentityApplicationId)) { throw "Could not resolve the client ID of '$ManagedIdentityName'." }
}
Write-Host "MI client ID   : $ManagedIdentityApplicationId (set it as MANAGED_IDENTITY_APPLICATION_ID on the GitHub Environment)"

# 3. Dataverse managedidentity record -------------------------------------------------
Write-Banner "3/7  Dataverse managedidentity record (Demo 2 env)"
& "$scriptRoot/managed-identity/Provision-ManagedIdentityDataverseRecord.ps1" `
    -DataverseUrl                     $DataverseUrl `
    -ApplicationId                    $ManagedIdentityApplicationId `
    -TenantId                         $TenantId `
    -DataverseRecordManagedIdentityId $DataverseRecordManagedIdentityId

# 4. Subnet injection enterprise policy linked to the Demo 2 env ----------------------
# Requires the environment to be a Managed Environment, e.g.:
#   pac admin set-governance-config --environment <env-id> --protection-level Standard --solution-checker-mode none
Write-Banner "4/7  Power Platform subnet injection (enterprise policy)"
& "$scriptRoot/vnet/Setup-PowerPlatformEnterprisePolicy.ps1" `
    -EnvironmentId     $EnvironmentId `
    -SubscriptionId    $SubscriptionId `
    -TenantId          $TenantId `
    -ResourceGroupName $ResourceGroupName `
    -PrimaryVnetName   $InjectionVnetPrimary `
    -SecondaryVnetName $InjectionVnetSecondary `
    -PrimarySubnetName $InjectionSubnetName `
    -SecondarySubnetName $InjectionSubnetName

# 5. NSG on the injected subnets: lock egress to the VNet, DENY the public Internet ---
# The shared vault stays public (Demo 1 needs it). What makes the Network env fail is a locked-down
# egress on the INJECTED subnets: ALLOW VirtualNetwork, DENY Internet. The private Function App is
# reached through its private endpoint (a VirtualNetwork address) -> allowed. The Key Vault is a
# PUBLIC endpoint (Internet) -> blackholed, so the read times out -> the "vault is outside the VNet"
# punchline. An NSG can only be attached to a subnet in its OWN region, so each injection VNet
# (West + North Europe) gets its own NSG with the same two rules.
Write-Banner "5/7  NSG per injected subnet (allow VirtualNetwork, deny Internet)"
foreach ($vnetName in @($InjectionVnetPrimary, $InjectionVnetSecondary)) {
    $vnet = az network vnet show --resource-group $ResourceGroupName --name $vnetName 2>$null | ConvertFrom-Json
    if ($null -eq $vnet) { Write-Warning "Injection VNet '$vnetName' not found - skipping."; continue }

    $nsgName = if ($vnetName -eq $InjectionVnetPrimary) { "nsg-ppinject" } else { "nsg-ppinject-ne" }
    $nsg = az network nsg show --resource-group $ResourceGroupName --name $nsgName 2>$null | ConvertFrom-Json
    if ($null -eq $nsg) {
        az network nsg create --resource-group $ResourceGroupName --name $nsgName --location $vnet.location | Out-Null
        Write-Host "Created NSG '$nsgName' ($($vnet.location))."
    } else {
        Write-Host "NSG '$nsgName' already exists."
    }

    # Allow VNet-internal egress first (private endpoints), then deny everything Internet-bound.
    az network nsg rule create `
        --resource-group $ResourceGroupName `
        --nsg-name $nsgName `
        --name "AllowVnetOutbound" `
        --priority 100 `
        --direction Outbound `
        --access Allow `
        --protocol "*" `
        --source-address-prefixes "VirtualNetwork" `
        --source-port-ranges "*" `
        --destination-address-prefixes "VirtualNetwork" `
        --destination-port-ranges "*" 2>$null | Out-Null

    az network nsg rule create `
        --resource-group $ResourceGroupName `
        --nsg-name $nsgName `
        --name "DenyInternetOutbound" `
        --priority 200 `
        --direction Outbound `
        --access Deny `
        --protocol "*" `
        --source-address-prefixes "*" `
        --source-port-ranges "*" `
        --destination-address-prefixes "Internet" `
        --destination-port-ranges "*" 2>$null | Out-Null

    az network vnet subnet update `
        --resource-group $ResourceGroupName `
        --vnet-name $vnetName `
        --name $InjectionSubnetName `
        --network-security-group $nsgName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to attach '$nsgName' to $vnetName/$InjectionSubnetName." }
    Write-Host "  '$nsgName' (AllowVnetOutbound 100 + DenyInternetOutbound 200) attached to $vnetName/$InjectionSubnetName" -ForegroundColor Green
}

# 6. Peering + private DNS: let the injected subnets resolve and reach the private endpoint --
# The Function's private endpoint lives in its own VNet; the injected env egresses from the
# injection VNets. They must be peered (both directions) and the privatelink zone must be linked
# to the injection VNets, otherwise the Function hostname resolves to nothing from Dataverse.
Write-Banner "6/7  VNet peering + private DNS links to the injection VNets"
$zoneName = "privatelink.azurewebsites.net"
foreach ($vnetName in @($InjectionVnetPrimary, $InjectionVnetSecondary)) {
    $vnet = az network vnet show --resource-group $ResourceGroupName --name $vnetName 2>$null | ConvertFrom-Json
    if ($null -eq $vnet) { Write-Warning "Injection VNet '$vnetName' not found - skipping."; continue }

    foreach ($pair in @(
        @{ from = $FunctionVnetName; to = $vnetName;         name = "peer-func-to-$vnetName" },
        @{ from = $vnetName;         to = $FunctionVnetName; name = "peer-$vnetName-to-func" }
    )) {
        $peering = az network vnet peering show --resource-group $ResourceGroupName --vnet-name $pair.from --name $pair.name 2>$null | ConvertFrom-Json
        if ($null -eq $peering) {
            az network vnet peering create `
                --resource-group $ResourceGroupName `
                --vnet-name $pair.from `
                --name $pair.name `
                --remote-vnet $pair.to `
                --allow-vnet-access | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Failed to create peering $($pair.from) -> $($pair.to)." }
            Write-Host "  peering $($pair.from) -> $($pair.to) created" -ForegroundColor Green
        } else {
            Write-Host "  peering $($pair.from) -> $($pair.to) already exists"
        }
    }

    $linkName = "link-$vnetName"
    $link = az network private-dns link vnet show --resource-group $ResourceGroupName --zone-name $zoneName --name $linkName 2>$null | ConvertFrom-Json
    if ($null -eq $link) {
        az network private-dns link vnet create `
            --resource-group $ResourceGroupName `
            --zone-name $zoneName `
            --name $linkName `
            --virtual-network $vnet.id `
            --registration-enabled false | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to link $zoneName to $vnetName." }
        Write-Host "  DNS zone linked to $vnetName" -ForegroundColor Green
    } else {
        Write-Host "  DNS zone already linked to $vnetName"
    }
}

# 7. Function hostname for connectivity testing --------------------------------------
Write-Banner "7/7  Function hostname"
$funcHost = "$FunctionAppName.azurewebsites.net"
Write-Host "Function hostname: $funcHost" -ForegroundColor Green

Write-Banner "DEMO 2 READY"
Write-Host "Set these Environment Variables in the Demo 2 Dataverse environment:" -ForegroundColor Yellow
Write-Host "  adc_KeyVaultUrl                = https://$KeyVaultName.vault.azure.net/  (NSG-blocked here -> FAIL)"
Write-Host "  adc_KeyVaultAccountSecretName  = $SecretName"
Write-Host "  adc_ErpApiUrl                  = https://$funcHost/api/erp/account-sync  (reachable via VNet -> SUCCESS)"
Write-Host ""
Write-Host "(Same values as Demo 1 - only the network posture differs.)"
Write-Host ""
Write-Host "Validate connectivity AHEAD of the demo (subnet injection takes time to propagate):" -ForegroundColor Yellow
Write-Host "  ./scripts/vnet/Test-Connectivity.ps1 -EnvironmentId $EnvironmentId -HostName $funcHost -Destination $funcHost -Port 443"
Write-Host ""
Write-Host "Live check:" -ForegroundColor Yellow
Write-Host "  tick adc_usefunction  -> adc_result shows ERP number (SUCCESS via private endpoint)"
Write-Host "  tick adc_usekeyvault  -> Plugin Trace Log shows 'Key Vault ... outside the VNet' (expected FAIL)"
