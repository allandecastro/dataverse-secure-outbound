<#
.SYNOPSIS
  Provisions all Azure resources required for the SecureOutbound Dataverse plugin:
  Resource Group, Key Vault, User-Assigned Managed Identity, and the Federated
  Identity Credential (FIC) that lets Dataverse authenticate as that identity.

.DESCRIPTION
  Run this ONCE per environment (dev/test/prod). It is idempotent - re-running it
  only creates what is missing.

  After this script completes, you still need to:
    1. Create the test secret in Key Vault (Step 2 in Setup-Instructions.md).
    2. Run scripts/managed-identity/Provision-ManagedIdentityDataverseRecord.ps1
       to create the managedidentity row in Dataverse and link the assembly.

  ┌─────────────────────────────────────────────────────────────────────────┐
  │  HOW THE FIC SUBJECT IS CONSTRUCTED (Microsoft Learn)                   │
  │                                                                          │
  │  Self-signed cert (dev/test):                                            │
  │  /eid1/c/pub/t/{encodedTenantId}/a/qzXoWDkuqUa3l6zM5mM0Rw/n/plugin    │
  │    /e/{environmentId}/h/{sha256OfCert}                                   │
  │                                                                          │
  │  {encodedTenantId}  = Base64URL( GUID bytes ) of the Entra tenant GUID  │
  │  {environmentId}    = Dataverse environment ID (GUID, no braces)         │
  │  {sha256OfCert}     = SHA-256 of the DER-encoded certificate (.cer)      │
  │                                                                          │
  │  Issuer  : https://login.microsoftonline.com/{tenantId}/v2.0             │
  │  Audience: api://AzureADTokenExchange  (case-sensitive)                  │
  └─────────────────────────────────────────────────────────────────────────┘

.PARAMETER TenantId
  Your Entra (Azure AD) tenant ID (GUID).

.PARAMETER SubscriptionId
  Azure subscription ID where resources will be created.

.PARAMETER EnvironmentId
  Dataverse environment ID (GUID). Find it in Power Platform admin center →
  Environments → <your env> → Details → Environment ID.

.PARAMETER CertificatePath
  Path to the .pfx (or .cer) used to sign the plugin assembly. This is the SAME
  certificate whose base64 is stored in the CODE_SIGN_PFX_BASE64 CI secret.
  Used to compute the SHA-256 that goes into the FIC subject.

.PARAMETER CertificatePassword
  Password for the .pfx (omit or leave empty if the file is a .cer).

.PARAMETER ResourceGroupName
  Name of the Azure resource group to create (or reuse).

.PARAMETER Location
  Azure region, e.g. "westeurope". Default: westeurope.

.PARAMETER KeyVaultName
  Name of the Key Vault to create. Must be globally unique (3-24 chars).

.PARAMETER ManagedIdentityName
  Name of the User-Assigned Managed Identity to create.

.EXAMPLE
  ./Setup-AzureResources.ps1 `
    -TenantId        "5f8a1a9f-2e1a-415f-b10c-84c3736a21b9" `
    -SubscriptionId  "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -EnvironmentId   "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" `
    -CertificatePath "codesign.pfx" `
    -CertificatePassword "MyP@ssw0rd" `
    -ResourceGroupName "rg-secureoutbound-dev" `
    -KeyVaultName    "kv-secureoutbound-dev" `
    -ManagedIdentityName "mi-secureoutbound-dev"
#>
[CmdletBinding()]
param(
    [string] $TenantId,
    [string] $SubscriptionId,
    [string] $EnvironmentId,
    [string] $CertificatePath,
    [string] $CertificatePassword,
    [string] $ResourceGroupName,
    [string] $Location = "westeurope",
    [string] $KeyVaultName,
    [string] $ManagedIdentityName
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Read-RequiredValue {
    param(
        [string]$CurrentValue,
        [string]$Prompt
    )
    $value = $CurrentValue
    while ([string]::IsNullOrWhiteSpace($value)) {
        $value = Read-Host $Prompt
    }
    return $value
}

# Prompt interactively when required arguments are not provided.
$TenantId         = Read-RequiredValue -CurrentValue $TenantId -Prompt "Enter Azure Tenant ID"
$SubscriptionId   = Read-RequiredValue -CurrentValue $SubscriptionId -Prompt "Enter Azure Subscription ID"
$EnvironmentId    = Read-RequiredValue -CurrentValue $EnvironmentId -Prompt "Enter Dataverse Environment ID (GUID)"
$ResourceGroupName = Read-RequiredValue -CurrentValue $ResourceGroupName -Prompt "Enter Azure Resource Group name"
$KeyVaultName     = Read-RequiredValue -CurrentValue $KeyVaultName -Prompt "Enter Azure Key Vault name"
$ManagedIdentityName = Read-RequiredValue -CurrentValue $ManagedIdentityName -Prompt "Enter User-Assigned Managed Identity name"

while ([string]::IsNullOrWhiteSpace($CertificatePath) -or -not (Test-Path $CertificatePath)) {
    if (-not [string]::IsNullOrWhiteSpace($CertificatePath) -and -not (Test-Path $CertificatePath)) {
        Write-Host "Certificate file not found: $CertificatePath" -ForegroundColor Yellow
    }
    $CertificatePath = Read-Host "Enter certificate path (.pfx or .cer)"
}

if ($CertificatePath -match '\.pfx$' -and [string]::IsNullOrWhiteSpace($CertificatePassword)) {
    $securePwd = Read-Host "Enter certificate password for the .pfx (leave empty if none)" -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd)
    try {
        $CertificatePassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

# ── 0. Login / set subscription ───────────────────────────────────────────────
Write-Host "`n=== Checking Azure CLI login ===" -ForegroundColor Cyan
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "Not logged in - running 'az login'..."
    az login --tenant $TenantId | Out-Null
}
az account set --subscription $SubscriptionId | Out-Null
Write-Host "Using subscription: $SubscriptionId"

# ── 1. Resource Group ─────────────────────────────────────────────────────────
Write-Host "`n=== Resource Group ===" -ForegroundColor Cyan
$rg = az group show --name $ResourceGroupName 2>$null | ConvertFrom-Json
if ($rg) {
    Write-Host "Resource group '$ResourceGroupName' already exists - skipping."
} else {
    Write-Host "Creating resource group '$ResourceGroupName' in '$Location'..."
    az group create --name $ResourceGroupName --location $Location | Out-Null
    Write-Host "Created."
}

# ── 2. User-Assigned Managed Identity ─────────────────────────────────────────
Write-Host "`n=== Managed Identity ===" -ForegroundColor Cyan
$mi = az identity show --name $ManagedIdentityName --resource-group $ResourceGroupName 2>$null | ConvertFrom-Json
if ($mi) {
    Write-Host "Managed identity '$ManagedIdentityName' already exists - skipping."
} else {
    Write-Host "Creating managed identity '$ManagedIdentityName'..."
    $mi = az identity create `
        --name $ManagedIdentityName `
        --resource-group $ResourceGroupName `
        --location $Location | ConvertFrom-Json
    Write-Host "Created."
}
$miClientId    = $mi.clientId
$miPrincipalId = $mi.principalId
$miResourceId  = $mi.id
Write-Host "  Client ID    : $miClientId"
Write-Host "  Principal ID : $miPrincipalId"

# ── 3. Key Vault ──────────────────────────────────────────────────────────────
Write-Host "`n=== Key Vault ===" -ForegroundColor Cyan
$kv = az keyvault show --name $KeyVaultName --resource-group $ResourceGroupName 2>$null | ConvertFrom-Json
if ($kv) {
    Write-Host "Key Vault '$KeyVaultName' already exists - skipping."
} else {
    Write-Host "Creating Key Vault '$KeyVaultName'..."
    az keyvault create `
        --name $KeyVaultName `
        --resource-group $ResourceGroupName `
        --location $Location `
        --enable-rbac-authorization $true | Out-Null
    Write-Host "Created."
}
$kvUri = "https://$KeyVaultName.vault.azure.net/"
Write-Host "  Vault URI: $kvUri"

# Grant the managed identity 'Key Vault Secrets User' on the vault.
Write-Host "Assigning 'Key Vault Secrets User' to managed identity..."
$kvId = (az keyvault show --name $KeyVaultName --resource-group $ResourceGroupName --query id -o tsv)
$existingCountRaw = az role assignment list `
    --assignee-object-id $miPrincipalId `
    --scope $kvId `
    --query "[?roleDefinitionName=='Key Vault Secrets User'] | length(@)" `
    -o tsv 2>$null

$existingCount = 0
if (-not [string]::IsNullOrWhiteSpace($existingCountRaw)) {
    $existingCount = [int]$existingCountRaw
}

if ($existingCount -gt 0) {
    Write-Host "Role assignment already exists - skipping."
} else {
    az role assignment create `
        --assignee-object-id $miPrincipalId `
        --role "Key Vault Secrets User" `
        --scope $kvId | Out-Null
    Write-Host "Role assigned."
}

# Verify the assignment exists (RBAC propagation can take time).
$verified = $false
for ($i = 1; $i -le 12; $i++) {
    $countRaw = az role assignment list `
        --assignee-object-id $miPrincipalId `
        --scope $kvId `
        --query "[?roleDefinitionName=='Key Vault Secrets User'] | length(@)" `
        -o tsv 2>$null
    $count = 0
    if (-not [string]::IsNullOrWhiteSpace($countRaw)) {
        $count = [int]$countRaw
    }

    if ($count -gt 0) {
        $verified = $true
        break
    }

    Start-Sleep -Seconds 10
}

if (-not $verified) {
    throw "Role assignment 'Key Vault Secrets User' was not visible after waiting. Check RBAC permissions and retry."
}

# ── 4. Compute FIC subject ────────────────────────────────────────────────────
Write-Host "`n=== Computing FIC subject ===" -ForegroundColor Cyan

# 4a. encodedTenantId = Base64URL( GUID bytes ) of the tenant GUID
#     Step 1: GUID → byte array (16 bytes, little-endian as .NET does it)
#     Step 2: byte array → Base64URL (replace +→-, /→_, strip =)
$tenantGuid  = [Guid]::Parse($TenantId)
$tenantBytes = $tenantGuid.ToByteArray()
$encodedTenantId = [Convert]::ToBase64String($tenantBytes) `
    -replace '\+', '-' `
    -replace '/',  '_' `
    -replace '=+$', ''
Write-Host "  encodedTenantId : $encodedTenantId"

# 4b. SHA-256 of the DER-encoded certificate (.cer bytes)
#     If a .pfx was supplied, extract the public certificate bytes from it.
if (-not (Test-Path $CertificatePath)) {
    throw "Certificate not found at: $CertificatePath"
}

if ($CertificatePath -match '\.pfx$') {
    if ([string]::IsNullOrWhiteSpace($CertificatePassword)) {
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            (Resolve-Path $CertificatePath).Path)
    } else {
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            (Resolve-Path $CertificatePath).Path, $CertificatePassword)
    }
    $certDerBytes = $cert.RawData   # DER-encoded public cert
} else {
    # Assume .cer (DER binary)
    $certDerBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $CertificatePath).Path)
}

$sha256      = [System.Security.Cryptography.SHA256]::Create()
$hashBytes   = $sha256.ComputeHash($certDerBytes)
$certHash    = ($hashBytes | ForEach-Object { $_.ToString("x2") }) -join ''
Write-Host "  cert SHA-256    : $certHash"

# 4c. Assemble the subject (self-signed / dev format)
$ficSubject = "/eid1/c/pub/t/$encodedTenantId/a/qzXoWDkuqUa3l6zM5mM0Rw/n/plugin/e/$EnvironmentId/h/$certHash"
Write-Host "  FIC subject     : $ficSubject"

$ficIssuer   = "https://login.microsoftonline.com/$TenantId/v2.0"
$ficAudience = "api://AzureADTokenExchange"

# ── 5. Federated Identity Credential ─────────────────────────────────────────
Write-Host "`n=== Federated Identity Credential ===" -ForegroundColor Cyan
$ficName     = "dataverse-plugin-fic"
$existingFic = az identity federated-credential show `
    --name $ficName `
    --identity-name $ManagedIdentityName `
    --resource-group $ResourceGroupName 2>$null | ConvertFrom-Json

if ($existingFic) {
    Write-Host "FIC '$ficName' already exists - skipping."
    Write-Host "  If you changed the certificate, delete the old FIC and re-run:"
    Write-Host "  az identity federated-credential delete --name $ficName --identity-name $ManagedIdentityName --resource-group $ResourceGroupName"
} else {
    Write-Host "Creating FIC '$ficName'..."
    az identity federated-credential create `
        --name $ficName `
        --identity-name $ManagedIdentityName `
        --resource-group $ResourceGroupName `
        --issuer $ficIssuer `
        --subject $ficSubject `
        --audiences $ficAudience | Out-Null
    Write-Host "Created."
}

# ── 6. Summary ────────────────────────────────────────────────────────────────
Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Azure setup complete." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Resource Group       : $ResourceGroupName"
Write-Host "  Key Vault URI        : $kvUri"
Write-Host "  Managed Identity     : $ManagedIdentityName"
Write-Host "  MI Client ID         : $miClientId"
Write-Host "  MI Principal ID      : $miPrincipalId"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Create your demo secret in Key Vault:"
Write-Host "     az keyvault secret set --vault-name $KeyVaultName --name MyDemoSecret --value 'Hello-From-KeyVault-2026'"
Write-Host ""
Write-Host "  2. Set GitHub Environment variables:"
Write-Host "     MANAGED_IDENTITY_APPLICATION_ID = $miClientId"
Write-Host "     DATAVERSE_MANAGED_IDENTITY_GUID = <same fixed GUID in all environments>"
Write-Host ""
Write-Host "  3. Run the Dataverse provisioning script (after solution is imported):"
Write-Host "     scripts/managed-identity/Provision-ManagedIdentityDataverseRecord.ps1 -DataverseUrl <url>"
Write-Host ""
Write-Host "  4. Set env variables in Dataverse:"
Write-Host "     adc_KeyVaultUrl                = $kvUri"
Write-Host "     adc_KeyVaultAccountSecretName  = MyDemoSecret"
