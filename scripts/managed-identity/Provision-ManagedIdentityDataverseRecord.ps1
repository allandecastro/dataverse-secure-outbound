<#
.SYNOPSIS
  Ensures the Dataverse Managed Identity record exists at a FIXED GUID.
  Idempotent — safe to re-run in any environment.

.DESCRIPTION
  Idempotent operation against the Dataverse Web API:
    1) GET managedidentity by GUID
    2) if missing, POST it with that explicit GUID

  WHY the fixed GUID still matters:
    Because the managedidentity row is created with the SAME GUID in dev/test/prod, the
    PATCH body ("/managedidentities(<fixed-guid>)") is byte-for-byte identical everywhere.
    Set the GUID once, reuse it forever — no per-environment edits.

  Typical flow (identical in dev/test/prod):
    import solution  ->  run this script

.PARAMETER DataverseUrl
  e.g. https://yourorg.crm.dynamics.com

.PARAMETER AccessToken
  Bearer token for the Dataverse Web API. If omitted, the script tries:
    az account get-access-token --resource <DataverseUrl>
  (requires Azure CLI logged in as a principal that has the System Administrator role).

.PARAMETER ApplicationId
  Managed identity application/client ID.

.PARAMETER TenantId
  Managed identity tenant ID.

.PARAMETER DataverseRecordManagedIdentityId
  Dataverse managedidentity record GUID. Use the same value across environments.

.EXAMPLE
  # Any environment, after solution import: ensure the managedidentity row exists and is up to date
  ./Provision-ManagedIdentityDataverseRecord.ps1 -DataverseUrl https://dev.crm.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DataverseUrl,

    [string]$AccessToken,

    [Parameter(Mandatory = $true)]
    [string]$ApplicationId,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$DataverseRecordManagedIdentityId,

    # When set, also bind the plug-in package (and assembly) to the managedidentity record.
    # Use this AFTER the solution import: a fresh install does not reliably carry the
    # package -> identity association, so we set it explicitly. Idempotent.
    [switch]$AssociatePackage,

    # Name fragment used to locate the plug-in package/assembly to associate.
    [string]$PluginPackageNameContains = "SecureOutbound"
)

$ErrorActionPreference = "Stop"
$DataverseUrl = $DataverseUrl.TrimEnd('/')
$apiBase = "$DataverseUrl/api/data/v9.2"

$miId = $DataverseRecordManagedIdentityId
$applicationId = $ApplicationId
$tenantId = $TenantId
$credSource = 2

foreach ($pair in @{ managedIdentityId = $miId; applicationId = $applicationId; tenantId = $tenantId }.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$pair.Value) -or "$($pair.Value)" -eq "00000000-0000-0000-0000-000000000000") {
        throw "Parameter '$($pair.Key)' is required."
    }
}

# --- Acquire token if not supplied ---------------------------------------------------
if ([string]::IsNullOrWhiteSpace($AccessToken)) {
    Write-Host "No -AccessToken supplied; requesting one via Azure CLI..."
    $AccessToken = (az account get-access-token --resource $DataverseUrl --query accessToken -o tsv)
    if ([string]::IsNullOrWhiteSpace($AccessToken)) { throw "Could not obtain an access token. Pass -AccessToken or run 'az login'." }
}

$headers = @{
    "Authorization"    = "Bearer $AccessToken"
    "OData-MaxVersion" = "4.0"
    "OData-Version"    = "4.0"
    "Accept"           = "application/json"
    "Content-Type"     = "application/json; charset=utf-8"
}

Write-Host "Environment: $DataverseUrl"

# --- Does the managedidentity record exist? ------------------------------------------
Write-Host "Checking for existing managedidentity $miId ..."
$exists = $false
try {
    Invoke-RestMethod -Method Get -Uri "$apiBase/managedidentities($miId)?`$select=managedidentityid" -Headers $headers | Out-Null
    $exists = $true
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 404) { throw }
}

# --- Create the record (fixed GUID) if missing ---------------------------------------
if ($exists) {
    Write-Host "managedidentity $miId already exists — skipping create."
} else {
    Write-Host "Creating managedidentity $miId ..."
    $body = @{
        managedidentityid = $miId          # explicit GUID => same identity in every env
        applicationid     = $applicationId
        tenantid          = $tenantId
        credentialsource  = $credSource
        subjectscope      = 1
        version           = 1
    } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri "$apiBase/managedidentities" -Headers $headers -Body $body | Out-Null
    Write-Host "Created managedidentity $miId."
}

# --- Reconcile fields every run to avoid config drift --------------------------------
Write-Host "Reconciling managedidentity $miId fields (applicationid/tenantid/credentialsource/subjectscope/version) ..."
$patchBody = @{
    applicationid    = $applicationId
    tenantid         = $tenantId
    credentialsource = $credSource
    subjectscope     = 1
    version          = 1
} | ConvertTo-Json

$patchHeaders = $headers.Clone()
$patchHeaders["If-Match"] = "*"

Invoke-RestMethod -Method Patch -Uri "$apiBase/managedidentities($miId)" -Headers $patchHeaders -Body $patchBody | Out-Null
Write-Host "Done. managedidentity $miId is up to date."

# --- Associate the plug-in package (+ assembly) with the managed identity -------------
# Only when -AssociatePackage is set (i.e. AFTER the solution import, when the package
# exists). A fresh solution install does not reliably carry the package -> identity
# binding, so we set it explicitly here. Without it the plug-in fails at runtime with
# "PluginPackage ... is not associated to a Managed identity". Idempotent.
if ($AssociatePackage) {
    Write-Host "Associating plug-in package/assembly (name contains '$PluginPackageNameContains') with managedidentity $miId ..."
    $bindBody = @{ "managedidentityid@odata.bind" = "/managedidentities($miId)" } | ConvertTo-Json
    $bindHeaders = $headers.Clone()
    $bindHeaders["If-Match"] = "*"

    foreach ($set in @(
        @{ entity = "pluginpackages";   key = "pluginpackageid";  label = "package" },
        @{ entity = "pluginassemblies"; key = "pluginassemblyid"; label = "assembly" }
    )) {
        $uri  = "$apiBase/$($set.entity)?`$select=$($set.key)&`$filter=contains(name,'$PluginPackageNameContains')"
        $rows = (Invoke-RestMethod -Method Get -Uri $uri -Headers $headers).value
        if (-not $rows -or $rows.Count -eq 0) {
            Write-Warning "No $($set.label) found with name containing '$PluginPackageNameContains' — skipping."
            continue
        }
        foreach ($row in $rows) {
            $id = $row.($set.key)
            Invoke-RestMethod -Method Patch -Uri "$apiBase/$($set.entity)($id)" -Headers $bindHeaders -Body $bindBody | Out-Null
            Write-Host "  associated $($set.label) $id -> managedidentity $miId"
        }
    }
    Write-Host "Done. Plug-in package association is up to date."
}
