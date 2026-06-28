# power-platform/solutions/

Source-controlled **unpacked Dataverse solution(s)**. The exported solution `.zip` is unpacked
here so it is human-diffable in pull requests - components (the plugin assembly/package registration,
the SDK message step, the environment-variable *definitions*, the `adc_usekeyvault` / `adc_usefunction`
boolean columns and the `adc_result` column, etc.) live as individual XML files instead of an opaque binary.

```
power-platform/solutions/
  SecureOutboundIntegration/          ← unmanaged unpacked tree (maker/source-of-truth)
  SecureOutboundIntegration_managed/  ← managed unpacked tree (CD pack source)
    Other/Solution.xml
    PluginPackages/...    (or PluginAssemblies/... for a bare assembly)
    ...
```

## One-time: get the solution into the repo (from DEV)

1. In DEV, add to the **`SecureOutboundIntegration`** solution: the plugin assembly/package, the SDK step
   (filtered on `adc_usekeyvault,adc_usefunction`), the three env-variable **definitions** (not values),
   and the `adc_usekeyvault` / `adc_usefunction` / `adc_result` columns.
2. Export the **unmanaged** solution → `SecureOutboundIntegration-unmanaged.zip`.
3. Unpack unmanaged:
   ```
   pac solution unpack --zipfile SecureOutboundIntegration-unmanaged.zip --folder power-platform/solutions/SecureOutboundIntegration --packagetype Unmanaged
   ```
4. Export the **managed** solution → `SecureOutboundIntegration-managed.zip`.
5. Unpack managed:
   ```
   pac solution unpack --zipfile SecureOutboundIntegration-managed.zip --folder power-platform/solutions/SecureOutboundIntegration_managed --packagetype Managed
   ```
6. Commit both trees:
   - `power-platform/solutions/SecureOutboundIntegration/`
   - `power-platform/solutions/SecureOutboundIntegration_managed/`

> **No binaries in git.** The freshly built & signed plugin package is injected at *pack* time via
> `build/SolutionPackager.map.xml`, so the binary stored in this tree can stay a placeholder.

## CD

`.github/workflows/cd.yml` packs `power-platform/solutions/SecureOutboundIntegration_managed`, then imports it - see
the CD section in [`../Setup-Instructions.md`](../Setup-Instructions.md). The `managedidentity` record
is provisioned separately (it is not part of the solution); CD runs
`scripts/managed-identity/Provision-ManagedIdentityDataverseRecord.ps1` after import to ensure the
record exists (create if missing) and to link the plugin package.
