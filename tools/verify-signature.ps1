<#
.SYNOPSIS
    Verifies that patch.ps1.sig is a valid signature over patch.ps1.
.DESCRIPTION
    Loads the public key embedded in install.ps1 (single source of truth),
    reads patch.ps1 as raw bytes, decodes patch.ps1.sig (base64), and verifies
    the RSA-PKCS1-SHA256 signature.

    Used by:
      - the maintainer's pre-commit hook (blocks commits with mismatched sig)
      - anyone who wants to manually audit a release without running it
.OUTPUTS
    Exit 0 on success. Exit 1 on any failure (missing file, bad parse, sig
    mismatch). Status is printed to host.
#>
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$patchPath   = Join-Path $repoRoot 'patch.ps1'
$sigPath     = Join-Path $repoRoot 'patch.ps1.sig'
$installPath = Join-Path $repoRoot 'install.ps1'

foreach ($p in @($patchPath, $sigPath, $installPath)) {
    if (-not (Test-Path $p)) {
        Write-Host "Missing required file: $p" -ForegroundColor Red
        exit 1
    }
}

# Extract the embedded public key from install.ps1. Single source of truth.
$installContent = Get-Content $installPath -Raw
if ($installContent -notmatch "ExpectedPubKey\s*=\s*'([A-Za-z0-9+/=]+)'") {
    Write-Host "Could not locate ExpectedPubKey in install.ps1." -ForegroundColor Red
    Write-Host "install.ps1 must contain a line like:" -ForegroundColor Yellow
    Write-Host "  `$ExpectedPubKey = '<base64-encoded JSON pubkey>'" -ForegroundColor Yellow
    exit 1
}
$pubEmbed = $matches[1]

# Decode public key.
try {
    $pubJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pubEmbed))
    $pubObj  = $pubJson | ConvertFrom-Json
} catch {
    Write-Host "Failed to decode public key from install.ps1: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$params = New-Object System.Security.Cryptography.RSAParameters
$params.Modulus  = [Convert]::FromBase64String($pubObj.Modulus)
$params.Exponent = [Convert]::FromBase64String($pubObj.Exponent)

$rsa = [System.Security.Cryptography.RSA]::Create()
$rsa.ImportParameters($params)

# Read patch.ps1 + signature. Normalize CRLF -> LF in memory: the signature is
# always computed over LF bytes (see sign-release.ps1), and .gitattributes pins
# the repo to LF, but a non-default git config or an editor that auto-converts
# could leave a local working copy with CRLF. Normalizing here makes the local
# audit match what raw.githubusercontent.com serves.
$raw = [IO.File]::ReadAllBytes($patchPath)
$norm = New-Object System.Collections.Generic.List[byte]
for ($i = 0; $i -lt $raw.Length; $i++) {
    if ($raw[$i] -eq 0x0D -and ($i + 1) -lt $raw.Length -and $raw[$i+1] -eq 0x0A) { continue }
    $norm.Add($raw[$i])
}
$patchBytes = $norm.ToArray()
$sigB64     = (Get-Content $sigPath -Raw).Trim()
try {
    $sigBytes = [Convert]::FromBase64String($sigB64)
} catch {
    Write-Host "patch.ps1.sig is not valid base64: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$valid = $rsa.VerifyData(
    $patchBytes, $sigBytes,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
)

if (-not $valid) {
    Write-Host ""
    Write-Host "patch.ps1.sig does NOT match patch.ps1." -ForegroundColor Red
    Write-Host "Cause: patch.ps1 was modified after signing, or the public key in" -ForegroundColor Yellow
    Write-Host "install.ps1 was changed without re-signing patch.ps1." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Fix: run .\tools\sign-release.ps1 then 'git add patch.ps1.sig'." -ForegroundColor Cyan
    exit 1
}

Write-Host "Signature OK ($($patchBytes.Length) LF-normalized bytes of patch.ps1 verified)." -ForegroundColor Green
exit 0
