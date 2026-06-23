<#
.SYNOPSIS
    Signs patch.ps1 with the maintainer's offline RSA private key.
.DESCRIPTION
    Reads patch.ps1 as raw bytes, signs with RSA-PKCS1-SHA256, writes patch.ps1.sig
    (base64). Run this every time patch.ps1 changes, BEFORE 'git add'.

    The private key is stored at $HOME\.claude-rtl-signing.key by default. It
    NEVER appears in the repository. Back it up to an encrypted USB / password
    manager -- losing it means you can never ship a verified update again.
.NOTES
    Maintainer-only tool. Not shipped to end users.
#>
param(
    [string]$KeyPath = (Join-Path $HOME ".claude-rtl-signing.key"),
    [string]$Target  = $null
)

$ErrorActionPreference = 'Stop'

# Resolve repo root: parent of the directory this script lives in.
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Target) { $Target = Join-Path $repoRoot 'patch.ps1' }

if (-not (Test-Path $KeyPath)) {
    Write-Host "Private key not found at: $KeyPath" -ForegroundColor Red
    Write-Host "Generate one first (see README 'Verification' section)." -ForegroundColor Yellow
    exit 1
}
if (-not (Test-Path $Target)) {
    Write-Host "Target file not found: $Target" -ForegroundColor Red
    exit 1
}

# Load private key (custom JSON bundle; see README for the rationale -- PS 5.1
# lacks ExportRSAPrivateKey so we use a hand-rolled portable format).
$privObj = Get-Content $KeyPath -Raw | ConvertFrom-Json
$params = New-Object System.Security.Cryptography.RSAParameters
$params.Modulus  = [Convert]::FromBase64String($privObj.Modulus)
$params.Exponent = [Convert]::FromBase64String($privObj.Exponent)
$params.D        = [Convert]::FromBase64String($privObj.D)
$params.P        = [Convert]::FromBase64String($privObj.P)
$params.Q        = [Convert]::FromBase64String($privObj.Q)
$params.DP       = [Convert]::FromBase64String($privObj.DP)
$params.DQ       = [Convert]::FromBase64String($privObj.DQ)
$params.InverseQ = [Convert]::FromBase64String($privObj.InverseQ)

$rsa = [System.Security.Cryptography.RSA]::Create()
$rsa.ImportParameters($params)

# Normalize CRLF -> LF before signing. .gitattributes enforces eol=lf in the repo,
# so raw.githubusercontent.com always serves LF. If we signed CRLF bytes from a
# Windows working copy, end-user verification would fail. Rewrite the file in place
# so the maintainer's working copy stays consistent with what gets committed.
$bytes = [IO.File]::ReadAllBytes($Target)
$normalized = New-Object System.Collections.Generic.List[byte]
for ($i = 0; $i -lt $bytes.Length; $i++) {
    if ($bytes[$i] -eq 0x0D -and ($i + 1) -lt $bytes.Length -and $bytes[$i+1] -eq 0x0A) { continue }
    $normalized.Add($bytes[$i])
}
$normBytes = $normalized.ToArray()
if ($normBytes.Length -ne $bytes.Length) {
    [IO.File]::WriteAllBytes($Target, $normBytes)
    Write-Host "Normalized $(Split-Path $Target -Leaf) to LF ($($bytes.Length) -> $($normBytes.Length) bytes)" -ForegroundColor Cyan
}

# Sign the (now LF-normalized) bytes.
$sig = $rsa.SignData(
    $normBytes,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
)

$sigPath = "$Target.sig"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[IO.File]::WriteAllText($sigPath, [Convert]::ToBase64String($sig), $utf8NoBom)

Write-Host "Signed: $Target" -ForegroundColor Green
Write-Host "Sig:    $sigPath ($([IO.File]::ReadAllText($sigPath).Length) chars base64)" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  git add $(Split-Path $Target -Leaf) $(Split-Path $sigPath -Leaf)"
Write-Host "  git commit ..."
