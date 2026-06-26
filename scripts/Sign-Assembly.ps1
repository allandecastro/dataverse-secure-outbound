<#
.SYNOPSIS
  Authenticode-signs a built assembly. Shared by the local Visual Studio build
  (via the csproj AfterBuild target) and available for manual use.

.DESCRIPTION
  Resolves the newest signtool.exe from the Windows SDK, then signs the target
  with a SHA-256 digest and an RFC-3161 timestamp (so the signature stays valid
  after the certificate expires).

  Two ways to supply the certificate:
    -Thumbprint   Sign with a cert already imported into the user's certificate
                  store (CurrentUser\My). This is the recommended local-dev path:
                  the dev imports the self-signed .pfx once, no secret on disk.
    -PfxPath      Sign with a .pfx file directly (plus -PfxPassword).

.NOTES
  Dataverse does NOT require this signature (the strong-name .snk is what the
  platform checks). Authenticode is publisher identity + tamper-evidence so the
  package the dev pushes is the same one CI would produce.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AssemblyPath,

    [string]$Thumbprint,

    [string]$PfxPath,

    [string]$PfxPassword,

    [string]$PfxCredentialTarget,

    [string]$TimestampUrl = "http://timestamp.digicert.com"
)

$ErrorActionPreference = "Stop"

function Get-CredentialPasswordFromWindowsStore {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target
    )

    if (-not ("WinCred.NativeMethods" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace WinCred
{
    public static class NativeMethods
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct CREDENTIAL
        {
            public int Flags;
            public int Type;
            public string TargetName;
            public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool CredRead(
            string target,
            int type,
            int reservedFlag,
            out IntPtr credentialPtr);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern void CredFree(IntPtr credentialPtr);
    }
}
"@
    }

    $credentialPtr = [IntPtr]::Zero
    $typeGeneric = 1
    $ok = [WinCred.NativeMethods]::CredRead($Target, $typeGeneric, 0, [ref]$credentialPtr)
    if (-not $ok -or $credentialPtr -eq [IntPtr]::Zero) {
        return $null
    }

    try {
        $credential = [Runtime.InteropServices.Marshal]::PtrToStructure(
            $credentialPtr,
            [type][WinCred.NativeMethods+CREDENTIAL])

        if ($credential.CredentialBlobSize -le 0 -or $credential.CredentialBlob -eq [IntPtr]::Zero) {
            return $null
        }

        return [Runtime.InteropServices.Marshal]::PtrToStringUni(
            $credential.CredentialBlob,
            [int]($credential.CredentialBlobSize / 2))
    }
    finally {
        [WinCred.NativeMethods]::CredFree($credentialPtr)
    }
}

if (-not (Test-Path $AssemblyPath)) {
    throw "Assembly to sign not found: $AssemblyPath"
}

# signtool.exe ships with the Windows SDK; pick the newest x64 copy.
$signtool = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1
if (-not $signtool) {
    throw "signtool.exe not found. Install the Windows 10/11 SDK (it includes signtool)."
}

if ($Thumbprint) {
    Write-Host "Signing '$AssemblyPath' with certificate thumbprint $Thumbprint ..."
    & $signtool.FullName sign `
        /sha1 $Thumbprint `
        /fd SHA256 `
        /tr $TimestampUrl `
        /td SHA256 `
        $AssemblyPath
}
elseif ($PfxPath) {
    if (-not (Test-Path $PfxPath)) { throw "PFX file not found: $PfxPath" }

    if (-not $PfxPassword -and $PfxCredentialTarget) {
        $PfxPassword = Get-CredentialPasswordFromWindowsStore -Target $PfxCredentialTarget
        if (-not $PfxPassword) {
            throw "Credential '$PfxCredentialTarget' not found in Windows Credential Manager, or password is empty."
        }
    }

    if (-not $PfxPassword) {
        throw "When using -PfxPath, provide -PfxPassword or -PfxCredentialTarget."
    }

    Write-Host "Signing '$AssemblyPath' with PFX '$PfxPath' ..."
    & $signtool.FullName sign `
        /f $PfxPath `
        /p $PfxPassword `
        /fd SHA256 `
        /tr $TimestampUrl `
        /td SHA256 `
        $AssemblyPath
}
else {
    throw "Provide either -Thumbprint or -PfxPath."
}

if ($LASTEXITCODE -ne 0) { throw "signtool sign failed (exit $LASTEXITCODE)." }

Write-Host "Signed: $AssemblyPath"
