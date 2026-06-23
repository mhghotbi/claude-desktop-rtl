# Claude RTL Patch -- verified installer.
#
# Downloads patch.ps1 and patch.ps1.sig from GitHub, verifies the signature
# against an RSA-4096 public key hardcoded below (private key lives offline on
# the maintainer's machine -- see C1 mitigation), then elevates to install.
#
# A compromised GitHub repository alone is NOT enough to ship malicious code to
# users -- the attacker would also need the maintainer's offline private key.
#
# Public-key fingerprint (SHA-256 over the embedded JSON blob below):
#   e5:a8:55:e0:df:e1:24:7e:51:87:21:5f:c4:50:68:64:da:48:24:58:46:b1:1d:02:e4:1f:71:46:aa:df:8a:b3
# Cross-check this at the project README and any out-of-band channel (e.g.
# release notes, social) before trusting a fresh install.
$ExpectedPubKey = 'eyJNb2R1bHVzIjoieGc1QXBuVlA5c21Wd3lqZmFRcUorb1dUV01DZHBoeUo2NXR4cU1iTm5BT1E0WHBLQ3JFY3RHNndrNkJNU000Wm5KUHZTYmlweWNNYnFueCt1S2cvUmY4K1RnS1JPSkljWlFuNlFGQ0pzWCtzQmFUTWlCUE11aFBHZ2lHS1FuSSt0NzJTemE1a1hMMGFUTCtUUUZsMk5ydHJ3RS9kQ0RES0wveEpFcnBCeFBYcVczSGRXK21ZallkRlRkdmlWb3g2eWlLMHhjNldxVmh0dVNCYzBYVjRBakhtSW1qMUUxZm5rOVlCTXBWWlhuTXRTRGd0Ry9YR0JuaFlFd2xybW5vbUhtaDB2eUNvVkhNbTZEbk1SZkdLanFCSzZzdCtmTzF5c3V2NGdqdDZySU0rREIwamZlcFRSdkRzT1F6NEtuM002UHpPdVhCdGp4ZU5XaEpYd3I4QitBUHdQWXdyN2VFaWVNRXFaV2t5OU5NZXdQWlpEMGNWUkhzZEE4aHpERmF3QUZJdjR4K24vbGVrTTc5U0c3anBIeU5RSGRIU2FqaldIMms5VDVmRHZFSFNNMkRMd3QwcGxMWjB1dmlzQzcrblpabVhYcDBUN09VRHdPb1MwZnFWOGtkR2V1Njdxa2IybFFiVGZRTFFxSkd4RHh4VFF4WUo3SWpCYklDZ3VyemhDWXdCOStsT1hQdmdqUGZ1c3pvSTVseko2MDZ4Q0ZWdjdxVXJOR0tVQ2xCdVlJWFZNTnY2eVpxUXpWVHVCTTRaVWNlVTJyWHV4KzNDcnAwcE84UUVrU2REb3Q2Mi9nR2pnd00zWDJncW1jQjBkQ1FXcWJYdENnMzQ3MURTMEN6OHRQSUtNR0RHUVgybS9JMjVHNUVlYkFxYjRiSHdQQ2ttSGpWaWQvZERJZEU9IiwiRXhwb25lbnQiOiJBUUFCIn0='

$RepoBase = 'https://raw.githubusercontent.com/mhghotbi/claude-desktop-rtl-patch/main'
$TmpFile  = Join-Path $env:TEMP 'claude_rtl_patch.ps1'

# PS 5.1 defaults to TLS 1.0; GitHub requires 1.2+.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# Download patch.ps1 as RAW bytes -- Invoke-RestMethod would decode and silently
# normalize the BOM, breaking the signature byte-for-byte. WebClient gives us
# the exact bytes the maintainer signed.
$client = New-Object System.Net.WebClient
try {
    $patchBytes = $client.DownloadData("$RepoBase/patch.ps1")
    $sigB64     = $client.DownloadString("$RepoBase/patch.ps1.sig").Trim()
} catch {
    Write-Host ""
    Write-Host "Network error downloading patch: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Check connectivity and retry." -ForegroundColor Yellow
    return
}

# Decode pubkey (custom JSON format; see tools/sign-release.ps1 for the rationale).
try {
    $pubJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ExpectedPubKey))
    $pubObj  = $pubJson | ConvertFrom-Json
    $params = New-Object System.Security.Cryptography.RSAParameters
    $params.Modulus  = [Convert]::FromBase64String($pubObj.Modulus)
    $params.Exponent = [Convert]::FromBase64String($pubObj.Exponent)
    $rsa = [System.Security.Cryptography.RSA]::Create()
    $rsa.ImportParameters($params)
} catch {
    Write-Host "Internal error: bundled public key is malformed ($($_.Exception.Message))." -ForegroundColor Red
    Write-Host "Do NOT proceed -- this means install.ps1 itself was tampered with." -ForegroundColor Red
    return
}

# Decode signature.
try {
    $sigBytes = [Convert]::FromBase64String($sigB64)
} catch {
    Write-Host ""
    Write-Host "Downloaded signature is not valid base64. Aborting." -ForegroundColor Red
    return
}

# The actual signature check.
$valid = $rsa.VerifyData(
    $patchBytes, $sigBytes,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
)

if (-not $valid) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host "  SIGNATURE VERIFICATION FAILED -- REFUSING TO RUN patch.ps1     " -ForegroundColor Red
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "The downloaded patch does not match the maintainer's signature." -ForegroundColor Yellow
    Write-Host "Possible causes:" -ForegroundColor Yellow
    Write-Host "  * The GitHub repository was compromised." -ForegroundColor Yellow
    Write-Host "  * Your network or proxy is intercepting traffic." -ForegroundColor Yellow
    Write-Host "  * A maintainer pushed patch.ps1 without re-signing." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Cross-check the public-key fingerprint at:" -ForegroundColor Cyan
    Write-Host "  https://github.com/mhghotbi/claude-desktop-rtl-patch#verification" -ForegroundColor Cyan
    return
}

# Decode bytes to string and strip BOM (we'll re-add it on write). PS 5.1 needs
# the file to start with a UTF-8 BOM to parse Unicode/box-drawing characters.
$content = [System.Text.Encoding]::UTF8.GetString($patchBytes)
if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) { $content = $content.Substring(1) }
[System.IO.File]::WriteAllText($TmpFile, $content, [System.Text.UTF8Encoding]::new($true))

Write-Host "Patch verified ($($patchBytes.Length) bytes). Elevating..." -ForegroundColor Green

# Hand the elevated patch.ps1 the pubkey blob we just verified against, as a
# -TrustedPubKey PARAMETER. patch.ps1 uses it to pin the trust anchor for the
# auto-update watcher (see Save-TrustedPubkey in patch.ps1). It MUST be a
# parameter, not an env var: environment variables set here do NOT survive the
# Start-Process -Verb RunAs UAC elevation boundary, so the elevated child would
# never see them. Passing the verified blob (rather than letting patch.ps1
# re-download install.ps1 itself) also avoids a TOCTOU window where the repo
# could change between our verify and patch.ps1's pin.

# Same launch line as the original installer -- nothing user-facing has changed.
# -NoExit keeps the elevated window open so the user can read the patch log.
Start-Process -FilePath PowerShell.exe -Verb RunAs -ArgumentList "-NoProfile -NoExit -ExecutionPolicy Bypass -File `"$TmpFile`" -TrustedPubKey `"$ExpectedPubKey`""
