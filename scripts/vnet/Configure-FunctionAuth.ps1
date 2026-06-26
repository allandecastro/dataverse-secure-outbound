<#
.SYNOPSIS
  Configures OAuth2 (Microsoft Entra) authentication for a Function App.

.DESCRIPTION
  Enables App Service authentication and requires Azure AD login.
  Tokens are validated against the provided audience.

  Use this after provisioning the Function App.

.PARAMETER ResourceGroupName
  Resource group containing the Function App.

.PARAMETER FunctionAppName
  Function App name.

.PARAMETER TenantId
  Entra tenant ID (auto-detected when omitted).

.PARAMETER FunctionApiClientId
  Application (client) ID used by the Function App auth provider.
  This is the App Registration that represents your Function API.

.PARAMETER AllowedAudience
  Allowed token audience (for example: api://<FunctionApiClientId>).

.EXAMPLE
  ./scripts/vnet/Configure-FunctionAuth.ps1 `
    -ResourceGroupName rg-secureoutbound-vnet-dev `
    -FunctionAppName func-secureoutbound-vnet-dev `
    -FunctionApiClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -AllowedAudience "api://xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$FunctionAppName,

    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$FunctionApiClientId,

    [Parameter(Mandatory = $true)]
    [string]$AllowedAudience
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($TenantId)) {
    $TenantId = az account show --query tenantId -o tsv
}
if ([string]::IsNullOrWhiteSpace($TenantId)) {
    throw "TenantId could not be resolved. Pass -TenantId explicitly."
}

$issuerUrl = "https://sts.windows.net/$TenantId/"

Write-Host "Configuring auth for Function App '$FunctionAppName' in '$ResourceGroupName'..."
Write-Host "TenantId       : $TenantId"
Write-Host "ClientId       : $FunctionApiClientId"
Write-Host "AllowedAudience: $AllowedAudience"

az webapp auth update `
    --resource-group $ResourceGroupName `
    --name $FunctionAppName `
    --enabled true `
    --action LoginWithAzureActiveDirectory `
    --aad-client-id $FunctionApiClientId `
    --aad-token-issuer-url $issuerUrl `
    --aad-allowed-token-audiences $AllowedAudience | Out-Null

Write-Host ""
Write-Host "Authentication enabled."
Write-Host "Next step: configure plugin token scope to '$AllowedAudience/.default'."
