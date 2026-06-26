<#
.SYNOPSIS
  One-shot provisioning for DEMO 1 — the Identity pillar (Managed Identity, NO VNet).

.DESCRIPTION
  Stands up the SHARED Azure base used by BOTH demos, plus the Identity-environment wiring:

    1. Setup-AzureResources.ps1  -> shared RG + User-Assigned MI (Demo 1) + shared Key Vault
                                    (firewall = Allow / public) + FIC (Demo 1 env) + RBAC
    2. Seed the demo secret in the shared Key Vault
    3. Make sure the Key Vault firewall stays Allow (public — the NSG, not the vault firewall,
       is what blocks the Network env later)
    4. Provision-ManagedIdentityDataverseRecord.ps1 -> the managedidentity row in the Demo 1 env

  ONE shared Key Vault and ONE shared private Function App serve both demos. The two demos point
  their Environment Variables at the SAME URLs; only the NETWORK posture differs:

    - Demo 1 (this env) is NOT injected into the VNet, so its egress is normal Power Platform
      egress: the public Key Vault is reachable (success) and the PRIVATE Function App is not
      (failure — the demo punchline).
    - Demo 2 IS injected into the VNet (Provision-Demo2-Network.ps1): the private Function becomes
      reachable (success) and the Key Vault is blocked by an NSG drop rule on the injected subnet
      (failure).

  WHY a Key Vault is created here and not in Demo 2: it is the SAME shared vault. Run this script
  first (it creates the shared RG + KV + secret); Demo 2 reuses them idempotently. Each demo env
  gets its OWN managed identity (the Dataverse FIC subject is environment-scoped), but both MIs are
  granted Key Vault Secrets User on the one shared vault.

  Result in Demo 1 (no VNet):
    - tick adc_usekeyvault  -> SUCCESS: secret read from the shared Key Vault via Managed Identity.
    - tick adc_usefunction  -> FAILS:  the private Function App is not reachable from this
                                        environment's egress (no VNet). Clear message in the Trace Log.

  Idempotent — safe to re-run. Pre-provision BEFORE the live demo.

.PARAMETER TenantId            Entra tenant ID (GUID).
.PARAMETER SubscriptionId      Azure subscription ID.
.PARAMETER EnvironmentId       Dataverse environment ID of the Demo 1 environment (GUID).
.PARAMETER DataverseUrl        Demo 1 Dataverse org URL, e.g. https://demo1.crm.dynamics.com
.PARAMETER ManagedIdentityApplicationId   App/client ID of the MI for the Demo 1 environment.
.PARAMETER DataverseRecordManagedIdentityId  Fixed managedidentity GUID (same value across envs).
.PARAMETER CertificatePath     Path to the code-signing .pfx/.cer (used for the FIC subject).
.PARAMETER CertificatePassword Password for the .pfx (omit for .cer).
.PARAMETER ResourceGroupName   Shared RG for both demos (default: rg-secure-outbound-demo).
.PARAMETER Location            Azure region (default: northeurope).
.PARAMETER KeyVaultName        Name of the SHARED Key Vault (default: kv-secure-outbound-demo).
.PARAMETER ManagedIdentityName Name of the Demo 1 User-Assigned MI (default: mi-secure-outbound-demo1).
.PARAMETER SecretName          Secret name to seed (default: AccountSecret).
.PARAMETER SecretValue         Secret value to seed (shared by both demos).

.EXAMPLE
  ./scripts/Provision-Demo1-Identity.ps1 `
    -TenantId       "<tenant-guid>" `
    -SubscriptionId "<sub-guid>" `
    -EnvironmentId  "<demo1-env-guid>" `
    -DataverseUrl   "https://secure-outbound-demo1.crm4.dynamics.com" `
    -ManagedIdentityApplicationId "<mi-app-id-demo1>" `
    -DataverseRecordManagedIdentityId "<fixed-mi-guid>" `
    -CertificatePath "codesign.pfx" -CertificatePassword "P@ss"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TenantId,
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [Parameter(Mandatory = $true)][string]$EnvironmentId,
    [Parameter(Mandatory = $true)][string]$DataverseUrl,
    [Parameter(Mandatory = $true)][string]$ManagedIdentityApplicationId,
    [Parameter(Mandatory = $true)][string]$DataverseRecordManagedIdentityId,
    [Parameter(Mandatory = $true)][string]$CertificatePath,
    [string]$CertificatePassword,

    [string]$ResourceGroupName   = "rg-secure-outbound-demo",
    [string]$Location            = "northeurope",
    [string]$KeyVaultName        = "kv-secure-outbound-demo",
    [string]$ManagedIdentityName = "mi-secure-outbound-demo1",
    [string]$SecretName          = "AccountSecret",
    [string]$SecretValue         = "Hello-From-KeyVault-2026"
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot

function Write-Banner($text) {
    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host "==================================================================" -ForegroundColor Cyan
}

Write-Banner "DEMO 1 — IDENTITY PILLAR (Managed Identity, no VNet)"
Write-Host "Resource group : $ResourceGroupName (shared with Demo 2)"
Write-Host "Key Vault      : $KeyVaultName (shared, firewall = Allow / reachable)"
Write-Host "Managed Id     : $ManagedIdentityName (Demo 1 env)"
Write-Host "Dataverse env  : $DataverseUrl"

# 1. Shared base: RG + MI (Demo 1) + shared KV + FIC + RBAC ----------------------------
Write-Banner "1/4  Azure resources (MI + shared Key Vault + FIC)"
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

# 2. Seed the demo secret (shared vault) ----------------------------------------------
Write-Banner "2/4  Seed secret '$SecretName' in $KeyVaultName"
az keyvault secret set --vault-name $KeyVaultName --name $SecretName --value $SecretValue | Out-Null
Write-Host "Secret '$SecretName' set." -ForegroundColor Green

# 3. Key Vault stays reachable (Allow). The NSG on Demo 2's injected subnet — NOT the --
#    vault firewall — is what blocks the Network env, so the same vault serves both demos.
Write-Banner "3/4  Key Vault firewall = Allow (public; blocked for Demo 2 by NSG, not here)"
az keyvault update --name $KeyVaultName --public-network-access Enabled --default-action Allow | Out-Null
Write-Host "Key Vault network: public access Enabled, default-action Allow." -ForegroundColor Green

# 4. Dataverse managedidentity record -------------------------------------------------
Write-Banner "4/4  Dataverse managedidentity record (Demo 1 env)"
& "$scriptRoot/managed-identity/Provision-ManagedIdentityDataverseRecord.ps1" `
    -DataverseUrl                     $DataverseUrl `
    -ApplicationId                    $ManagedIdentityApplicationId `
    -TenantId                         $TenantId `
    -DataverseRecordManagedIdentityId $DataverseRecordManagedIdentityId

Write-Banner "DEMO 1 READY"
Write-Host "Set these Environment Variables in the Demo 1 Dataverse environment:" -ForegroundColor Yellow
Write-Host "  adc_KeyVaultUrl                = https://$KeyVaultName.vault.azure.net/"
Write-Host "  adc_KeyVaultAccountSecretName  = $SecretName"
Write-Host "  adc_ErpApiUrl                  = https://func-secure-outbound-demo.azurewebsites.net/api/erp/account-sync  (unreachable here — no VNet)"
Write-Host ""
Write-Host "(Same values as Demo 2 — only the network posture differs. Run Provision-Demo2-Network.ps1 next.)"
Write-Host ""
Write-Host "Live check:" -ForegroundColor Yellow
Write-Host "  tick adc_usekeyvault  -> adc_result shows the secret (SUCCESS)"
Write-Host "  tick adc_usefunction  -> Plugin Trace Log shows 'Function App ... not reachable' (expected FAIL)"
