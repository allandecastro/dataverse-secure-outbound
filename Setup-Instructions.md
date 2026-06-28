# Setup Instructions - Secure Outbound Plugin (Identity + Network)

This guide deploys and demos **SecureOutboundPlugin**, a synchronous Dynamics 365 (Dataverse)
cloud plug-in that demonstrates the **two pillars of a secure outbound channel**: **Identity**
(Managed Identity → Key Vault) and **Network** (VNet / private endpoint → Function App).

The plug-in is driven by **two boolean fields** on the Account and writes its output to **one
result field**:

1. Fires on **Account → Update → Post-Operation (Sync)** when either boolean is set to `true`.
2. Reads three Dataverse **Environment Variables** (`adc_KeyVaultUrl`,
   `adc_KeyVaultAccountSecretName`, `adc_ErpApiUrl`).
3. **`adc_usekeyvault = true`** → authenticates to **Azure Key Vault** with **Managed Identity**
   (`IManagedIdentityService`), reads the secret, writes it to `adc_result`. *(Identity pillar)*
4. **`adc_usefunction = true`** → calls the **Function App** and writes the returned number to
   `adc_result`. *(Network pillar)* - fully decoupled from Key Vault (demo bearer token).
5. Logs every step to the **Plugin Trace Log**; failures carry a clear, demo-ready message.

### The 2×2 demo matrix

Same code, same managed solution in both environments - only the **Environment Variable values**
and the **Azure/network setup** differ.

|                                   | ☑️ `adc_usekeyvault`                       | ☑️ `adc_usefunction`                          |
|-----------------------------------|--------------------------------------------|-----------------------------------------------|
| **Demo 1 - Identity (no VNet)**   | ✅ secret read via Managed Identity        | ❌ exception: private Function not reachable  |
| **Demo 2 - Network (VNet)**       | ❌ exception: Key Vault is outside the VNet | ✅ Function reached through the injected subnet |

> **Naming convention** (publisher prefix **`adc_`** on all custom components):
> - **Solution:** `SecureOutboundIntegration` - the container; no `Plugin` suffix.
> - **Project / assembly:** `SecureOutboundPlugin` - this one *is* the plugin, so the suffix fits.
> - **Plugin class:** `Dataverse.SecureOutbound.AccountPlugin` (registered against the Account table).
>
> **Result field:** the code writes both the Key Vault secret and the Function response to the
> single Account column `adc_result` (constant `ResultField` in `AccountPlugin.cs`).

---

## Prerequisites

- **Two** Dynamics 365 / Power Platform environments where you are **System Administrator**
  (one per demo - the VNet / subnet-injection enterprise policy is bound to an *environment*).
- An **Azure subscription** with rights to create a resource group, a Key Vault, a VNet + private
  Function App, an NSG, a Power Platform enterprise policy, and to assign RBAC.

> **One shared Azure footprint, two outcomes.** Both demos share **one resource group**
> (`rg-secure-outbound-demo`), **one Key Vault** (`kv-secure-outbound-demo`, kept public), and **one
> private Function App** (`func-secure-outbound-demo`). Each environment has its **own** Managed
> Identity (`mi-secure-outbound-demo1` / `mi-secure-outbound-demo2`) because the Dataverse federated
> credential is environment-scoped. The only thing that differs between the two cells is the
> **network posture**: Demo 2's environment is injected into the VNet and an **NSG drop rule** on
> that injected subnet blocks the Key Vault, while Demo 1's environment is not injected so it reaches
> the Key Vault but not the private Function. The Environment Variable values are **identical** in
> both environments.
- **Plug-in Registration Tool** (from the `Microsoft.CrmSdk.XrmTooling.PluginRegistrationTool`
  NuGet package).
- **Visual Studio 2019/2022** with the **.NET Framework 4.6.2** developer pack.
- A strong-name key file `SecureOutboundPlugin.snk` (generate with `sn -k SecureOutboundPlugin.snk`).

> **Managed Identity note:** Managed Identity for Dataverse plug-ins must be enabled and federated
> for **both** environments/tenant. `IManagedIdentityService` resolves to that identity. Demo 2
> also needs a working MI so the Key Vault failure is purely a *network* failure, not "identity not
> configured".

---

## Step 1 - Build the assembly

1. Open `src/SecureOutboundPlugin/SecureOutboundPlugin.csproj` in **Visual Studio**.
2. Set the configuration to **Release** and choose **Build → Rebuild Solution**. Visual Studio
   restores the `packages.config` NuGet dependencies automatically.

Output: `src/SecureOutboundPlugin/bin\Release\SecureOutboundPlugin.dll` (strong-name signed,
net462), with the Azure dependency DLLs alongside it.

> Because the plug-in depends on `Azure.Identity` / `Azure.Security.KeyVault.Secrets`, deploy it
> **as a Plug-in Package** (Step 5) so the platform loads those dependencies alongside your DLL.
> No ILMerge needed - the `.nupkg` carries the dependency tree and Dataverse resolves it at runtime.

### Automatic Authenticode signing on local builds

So a developer can build on their laptop and push a DLL signed exactly like CI produces,
**Release builds sign the assembly automatically** - using the same `.pfx` CI uses (locally as a
file, in CI as the base64 `CODE_SIGN_PFX_BASE64` secret). Nothing secret is committed:

1. Create + export the self-signed cert once (PowerShell):
   ```powershell
   $cert = New-SelfSignedCertificate -Type CodeSigningCert `
             -Subject "CN=SecureOutbound Dev Signing" -CertStoreLocation Cert:\CurrentUser\My
   $pwd = ConvertTo-SecureString "<password>" -AsPlainText -Force
   Export-PfxCertificate -Cert $cert -FilePath codesign.pfx -Password $pwd
   ```
2. In `src/SecureOutboundPlugin/`, copy **`signing.local.props.example`** to
   **`signing.local.props`** and set `<CodeSignPfxPath>` / `<CodeSignPfxPassword>`.
   (`signing.local.props` and all `*.pfx` are gitignored.)
3. For CI, base64-encode that **same** `.pfx` into the `CODE_SIGN_PFX_BASE64` secret.
4. Build in **Debug** or **Release**. Local MSBuild targets sign both:
   - the DLL (`AuthenticodeSignLocal` via `scripts/Sign-Assembly.ps1`)
   - the `.nupkg` (`SignPluginPackageLocal` via `scripts/Sign-NuGetPackage.ps1`)

If `signing.local.props` is absent, the target is inert - so CI (which does its own `signtool`
step) and any unconfigured machine build normally. Strong-name signing (`.snk`) is separate and
always happens via the committed key; Authenticode is the *extra* publisher signature.

---

## Step 2 - Provision Azure (one orchestrator per demo)

Pre-provision **everything before the live demo**. Two orchestrator scripts wrap the granular
building blocks. **Run Demo 1 first** - it creates the **shared** resource group, Key Vault and
secret; Demo 2 then **reuses** them idempotently and adds the network layer.

```powershell
az login

# Demo 1 - Identity pillar. Creates the SHARED base: rg-secure-outbound-demo + the public
# Key Vault kv-secure-outbound-demo (+ secret) + the Demo 1 Managed Identity. NO VNet.
./scripts/Provision-Demo1-Identity.ps1 `
  -TenantId "<tenant>" -SubscriptionId "<sub>" `
  -EnvironmentId "<demo1-env-guid>" -DataverseUrl "https://secure-outbound-demo1.crm4.dynamics.com" `
  -ManagedIdentityApplicationId "<mi-app-id-demo1>" -DataverseRecordManagedIdentityId "<fixed-mi-guid>" `
  -CertificatePath "codesign.pfx" -CertificatePassword "<pwd>"

# Demo 2 - Network pillar. Reuses the SHARED rg/Key Vault, adds the private Function App
# func-secure-outbound-demo, the Demo 2 Managed Identity, the subnet-injection enterprise policy,
# and an NSG drop rule to AzureKeyVault on the injected subnet (that NSG - not the vault firewall -
# is what blocks the Key Vault for this environment).
./scripts/Provision-Demo2-Network.ps1 `
  -TenantId "<tenant>" -SubscriptionId "<sub>" `
  -EnvironmentId "<demo2-env-guid>" -DataverseUrl "https://secure-outbound-demo2.crm4.dynamics.com" `
  -ManagedIdentityApplicationId "<mi-app-id-demo2>" -DataverseRecordManagedIdentityId "<fixed-mi-guid>" `
  -CertificatePath "codesign.pfx" -CertificatePassword "<pwd>"
```

> The Key Vault is **shared and stays public**. Demo 1 can read it (its environment is not
> injected). For Demo 2, the injected subnet carries an **NSG that allows `VirtualNetwork` egress
> but denies `Internet`**: the private Function App (reached via its private endpoint, a VNet
> address) goes through, while the **public** Key Vault (an Internet endpoint) is blackholed - so the
> read hangs until the SDK timeout (~10 s) and the plug-in surfaces the "Key Vault is outside the
> VNet" message. No vault firewall change (which would also break Demo 1). The Managed Identity still
> resolves a token, so the failure is purely *network*, not *identity*.

Each script prints the exact Environment Variable values to set (Step 3) and, for Demo 2, the
Function hostname to validate with `scripts/vnet/Test-Connectivity.ps1` **ahead of time** (subnet
injection takes a while to propagate - don't test it live).

> We deliberately **do not** run `scripts/vnet/Configure-FunctionAuth.ps1`. The boundary shown in
> Demo 2 is the **network** (private endpoint); a simple demo bearer token is enough. Enabling
> Entra platform auth would 401 the demo token and turn the success cell into a misleading failure.

---

## Step 3 - Create the Environment Variables (per environment)

In the **Power Apps maker portal** open the unmanaged solution **`SecureOutboundIntegration`**
(publisher prefix `adc_`), then **+ New → More → Environment variable**. The schema names **and the
values are identical in both environments** - they point at the **same** shared Key Vault and the
**same** shared Function App. What changes the outcome is the *network* (Demo 2's environment is
injected into the VNet; Demo 1's is not), not the configuration.

| Display Name              | Schema Name (must match code)   | Data Type | Value (identical in Demo 1 **and** Demo 2)                                  |
|---------------------------|---------------------------------|-----------|----------------------------------------------------------------------------|
| Key Vault URL             | `adc_KeyVaultUrl`               | Text      | `https://kv-secure-outbound-demo.vault.azure.net/`                         |
| Key Vault Account Secret  | `adc_KeyVaultAccountSecretName` | Text      | `AccountSecret`                                                             |
| Function / ERP API URL    | `adc_ErpApiUrl`                 | Text      | `https://func-secure-outbound-demo.azurewebsites.net/api/erp/account-sync` |

Why the same values produce opposite results per environment:

| Toggle                | Demo 1 - Identity (not injected)                          | Demo 2 - Network (VNet injected)                              |
|-----------------------|-----------------------------------------------------------|--------------------------------------------------------------|
| ☑️ `adc_usekeyvault`  | ✅ reaches the public Key Vault via Managed Identity      | ❌ NSG drop rule on the injected subnet blocks the Key Vault |
| ☑️ `adc_usefunction`  | ❌ private Function not reachable (no VNet egress)        | ✅ reaches the private Function through the injected subnet  |

> The plug-in matches by **schema name**. If your publisher prefix differs, update the constants in
> `AccountPlugin.cs` and rebuild.

---

## Step 4 - Create the Account fields

Three custom fields are required on the Account table (in the `SecureOutboundIntegration` solution).
**Schema names cannot be renamed** later, so create them fresh:

| Display Name      | Schema Name        | Type                  | Notes |
|-------------------|--------------------|-----------------------|-------|
| Use Key Vault     | `adc_usekeyvault`  | Two Options (boolean) | Default **No**. Tick → run the Identity path. |
| Use Function App  | `adc_usefunction`  | Two Options (boolean) | Default **No**. Tick → run the Network path. |
| Result            | `adc_result`       | Single line of text   | Max length 850. Receives the secret value **or** the Function response. |

Add all three (plus the existing `adc_crmnumber`) to the Account main form so the audience sees the
checkboxes and the result update live. **Delete** the old `adc_secretvalue` / `adc_erpsyncstatuscode`
fields and the `adc_erpsyncstatus` option set (no longer used).

---

## Step 5 - Register the plugin (Plug-in Package)

Because the plug-in pulls in the Azure SDK, deploy it as a **Plug-in Package** so the dependencies
travel with it. (No ILMerge - the package carries the full dependency tree.)

1. In **Visual Studio**, build the project in **Release**. `bin\Release\` contains your
   `SecureOutboundPlugin.dll` next to `Azure.Identity.dll`, `Azure.Core.dll`,
   `Azure.Security.KeyVault.Secrets.dll`, etc.
2. Open the **Plug-in Registration Tool** and **Create New Connection** to your environment.
3. **Register → Register New Package**, then point it at the folder containing the DLL and its
   dependencies (or the generated `.nupkg`).

### Register the step

1. Right-click the **AccountPlugin** type → **Register New Step**.
2. Configure exactly:
   - **Message:** `Update`
   - **Primary Entity:** `account`
   - **Event Pipeline Stage:** `Post Operation`
   - **Execution Mode:** `Synchronous`
   - **Filtering Attributes:** `adc_usekeyvault,adc_usefunction` - **required**. The plug-in only
     wakes up when one of the toggles changes, not on every Account save.
3. Register a **Post Image** (e.g. named `PostImage`) including at least `accountid`, `name`,
   `adc_crmnumber` - the Function payload needs them.

---

## Step 5b - Create & link the Managed Identity record (stable GUID)

Run in **every** environment **after** the solution import (the package→identity link is not
exported in the solution). The orchestrators in Step 2 already call this; run it standalone if you
deploy the solution separately:

```powershell
az login   # as a Dataverse System Administrator, or pass -AccessToken explicitly

scripts/managed-identity/Provision-ManagedIdentityDataverseRecord.ps1 `
  -DataverseUrl https://secure-outbound-demo1.crm4.dynamics.com `
  -ApplicationId "<mi-app-id>" -TenantId "<tenant>" `
  -DataverseRecordManagedIdentityId "<fixed-mi-guid>"
```

Idempotent: creates the `managedidentity` row at the **fixed GUID** (if missing) and links the
plugin package. The fixed GUID makes that operation identical in every environment.

> Full details (config file, the fixed-GUID rationale, the CD automation) are in the README:
> **[Managed Identity (ALM)](README.md#managed-identity-alm)**.

---

## Step 6 - The live demo runbook (2×2)

> Make sure **Plug-in and custom workflow activity tracing** is set to **All** in **both**
> environments (**System Settings → Customization**), and that each environment has an Account
> with `adc_crmnumber` populated.

For each cell: open the Account → tick **one** checkbox → **Save** → open the Plugin Trace Log
(**Settings → Plug-in Trace Log**) and read the newest entry.

### Demo 1 - Identity environment

| Action                     | Expected result |
|----------------------------|-----------------|
| Tick **Use Key Vault**, Save | ✅ `adc_result` shows the secret value. Trace: *"Secret … retrieved (length N)"*. |
| Tick **Use Function App**, Save | ❌ Save error. Trace: *"Function App call FAILED: the private Function endpoint is not reachable … Expected in the Identity (Demo 1) environment."* (may take up to 30 s - the HTTP timeout). |

### Demo 2 - Network environment

| Action                     | Expected result |
|----------------------------|-----------------|
| Tick **Use Function App**, Save | ✅ `adc_result` shows `ERPyyyyMMdd-xxxxxxxx`. Trace: *"response HTTP 200"*. |
| Tick **Use Key Vault**, Save | ❌ Save error (after ~10 s - the NSG drops the packets, so the read times out). Trace: *"Key Vault call FAILED … the vault is 'outside' the VNet … Expected in the Network (Demo 2) environment."* |

> **Re-toggle each time.** The step only fires when a boolean is in the `Target` (i.e. its value
> changes on that save). If you re-save without changing a checkbox, nothing runs - untick then
> re-tick to trigger another run.

---

## Troubleshooting

| Symptom                                              | Likely cause / fix                                                                 |
|------------------------------------------------------|------------------------------------------------------------------------------------|
| Nothing happens on Save                              | The boolean wasn't in the Target - untick/re-tick the checkbox and save again.      |
| Trace: *"Environment Variable ... missing or empty"* | Schema-name mismatch or the variable isn't set in this environment - set the value. |
| Trace: *"IManagedIdentityService returned an empty token"* | Plug-in Managed Identity not enabled/federated, or identity not yet provisioned. |
| Trace: *"Key Vault call FAILED (HTTP 403)"*          | **Demo 2 expected.** Otherwise: MI missing **Key Vault Secrets User**, or firewall. |
| Trace: *"Key Vault call FAILED (HTTP 404)"*          | Secret name wrong - check `adc_KeyVaultAccountSecretName` vs. the vault secret.     |
| Trace: *"Function App call FAILED / TIMED OUT"*      | **Demo 1 expected** (no VNet path). In Demo 2: check the private endpoint / subnet injection with `Test-Connectivity.ps1`. |
| Assembly fails to load on registration               | Dependencies missing - deploy as a **Plug-in Package** (`.nupkg`), not a bare DLL. |
| `adc_result` doesn't update but trace shows success  | Field not on the form, or refresh needed.                                          |

---

## Automated build & deploy (CI/CD)

This guide is the manual demo path. For the GitHub Actions **CI** (build + strong-name + optional
Authenticode signing) and **CD** (build/sign DLL + `.nupkg` → inject package into
`solutions/SecureOutboundIntegration_managed` → pack/import solution → link Managed Identity), see
the **CI/CD** section of the [README](README.md#cicd).

---

## Security note (for the architecture session)

The plug-in **never logs the secret value** - only its length - to avoid leaking secret material
into the Plugin Trace Log. The two pillars are independent: **Identity** answers *who* can call
(Managed Identity, no stored credentials), **Network** answers *from where* (private endpoint /
VNet). A real production design layers **both**.
