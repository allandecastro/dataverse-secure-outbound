[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$NuGetExe,

    [Parameter(Mandatory = $true)]
    [string]$PackagePath,

    [Parameter(Mandatory = $true)]
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

if (-not (Test-Path $NuGetExe)) {
    $nugetCommand = Get-Command $NuGetExe -ErrorAction SilentlyContinue
    if (-not $nugetCommand) {
        throw "nuget.exe not found: $NuGetExe"
    }
    $NuGetExe = $nugetCommand.Source
}

if (-not (Test-Path $PackagePath)) {
    throw "NuGet package not found: $PackagePath"
}

if (-not (Test-Path $PfxPath)) {
    throw "PFX file not found: $PfxPath"
}

if (-not $PfxPassword -and $PfxCredentialTarget) {
    $PfxPassword = Get-CredentialPasswordFromWindowsStore -Target $PfxCredentialTarget
    if (-not $PfxPassword) {
        throw "Credential '$PfxCredentialTarget' not found in Windows Credential Manager, or password is empty."
    }
}

if (-not $PfxPassword) {
    throw "Provide PfxPassword or PfxCredentialTarget."
}

Write-Host "Signing NuGet package '$PackagePath'..."
& $NuGetExe sign $PackagePath `
    -CertificatePath $PfxPath `
    -CertificatePassword $PfxPassword `
    -Timestamper $TimestampUrl

if ($LASTEXITCODE -ne 0) {
    throw "nuget sign failed (exit $LASTEXITCODE)."
}

Write-Host "Signed package: $PackagePath"
