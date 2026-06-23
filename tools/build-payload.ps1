<#
.SYNOPSIS
    Assembles the renderer RTL payload from src/ and injects it into patch.ps1.
.DESCRIPTION
    Single source of truth for the injected JS is src/rtl-core.js (pure, tested)
    plus src/rtl-payload.js (DOM layer / IIFE). This script:
      1. Reads src/rtl-core.js and strips its module.exports guard.
      2. Inlines that core into src/rtl-payload.js at the /*__RTL_CORE__*/ marker.
      3. Base64-encodes fonts/Vazirmatn[wght].woff2 and injects CSS at /*__FONT_CSS__*/.
      4. Validates the assembled blob with `node --check`.
      5. Writes dist/rtl-payload-built.js (read by patch-mac.sh on macOS).
      6. Replaces the region between the CLAUDE RTL PATCH START/END markers inside
         patch.ps1's $RTL_INJECTION_CODE here-string.
      7. Writes patch.ps1 back as UTF-8 (no BOM), LF line endings.

    After running this you MUST re-sign:  tools/sign-release.ps1
    then commit patch.ps1 + patch.ps1.sig together.

    NOTE: keep this script ASCII-only. PowerShell 5.1 reads BOM-less .ps1 files
    using the system ANSI code page; non-ASCII bytes (e.g. an em-dash) corrupt and
    break parsing on Persian/RTL locales.
.NOTES
    Maintainer-only build tool. Run:  npm run build   (or directly).
#>
$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $PSScriptRoot
$corePath   = Join-Path $repoRoot 'src\rtl-core.js'
$payPath    = Join-Path $repoRoot 'src\rtl-payload.js'
$patchPath  = Join-Path $repoRoot 'patch.ps1'
$fontPath   = Join-Path $repoRoot 'fonts\Vazirmatn[wght].woff2'
$distDir    = Join-Path $repoRoot 'dist'
$distPath   = Join-Path $distDir  'rtl-payload-built.js'

foreach ($p in @($corePath, $payPath, $patchPath)) {
    if (-not (Test-Path $p)) { Write-Host "Missing: $p" -ForegroundColor Red; exit 1 }
}
# Test-Path treats [] as wildcards; use -LiteralPath for the font file.
if (-not (Test-Path -LiteralPath $fontPath)) { Write-Host "Missing: $fontPath" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Path $distDir | Out-Null }

# Read sources, normalize to LF.
function Read-Lf([string]$path) {
    return ([IO.File]::ReadAllText($path)) -replace "`r`n", "`n"
}

$core = Read-Lf $corePath
$pay  = Read-Lf $payPath

# Strip the CommonJS export guard from the core (kept only for unit tests).
$guardIdx = $core.IndexOf("if (typeof module !==")
if ($guardIdx -ge 0) { $core = $core.Substring(0, $guardIdx).TrimEnd() + "`n" }

# Inline the core into the payload's placeholder.
$marker = '/*__RTL_CORE__*/'
if ($pay.IndexOf($marker) -lt 0) {
    Write-Host "Placeholder $marker not found in rtl-payload.js" -ForegroundColor Red; exit 1
}
$payInlined = $pay.Replace($marker, $core.TrimEnd("`n"))

# Embed Vazirmatn variable font as base64 data URI (Claude CSP blocks external URLs).
$fontMarker = '/*__FONT_CSS__*/'
if ($payInlined.IndexOf($fontMarker) -lt 0) {
    Write-Host "Placeholder $fontMarker not found in rtl-payload.js" -ForegroundColor Red; exit 1
}
$fontB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $fontPath).Path))
# Build CSS using string concatenation to avoid PowerShell variable/quote ambiguity.
# Single quotes around Vazirmatn are avoided (font name has no spaces; bare name is valid CSS).
# Double quotes in [dir="rtl"] are fine inside a JS single-quoted string literal.
$dq = '"'
$fontCss = '@font-face{font-family:Vazirmatn;src:url(data:font/woff2;base64,' + $fontB64 + ')format(' + $dq + 'woff2' + $dq + ');font-weight:100 900;font-style:normal}' +
           '[dir=' + $dq + 'rtl' + $dq + ']:not(pre):not(code),' +
           '[dir=' + $dq + 'rtl' + $dq + '] *:not(pre):not(code):not(.code-block__code)' +
           '{font-family:Vazirmatn,Arial,sans-serif!important}'
$payInlined = $payInlined.Replace($fontMarker, $fontCss)

# Write the fully-assembled payload for macOS (patch-mac.sh reads this directly).
[IO.File]::WriteAllText($distPath, $payInlined, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Wrote dist/rtl-payload-built.js ($([IO.File]::ReadAllBytes($distPath).Length) bytes)." -ForegroundColor Cyan

# Wrap with the section markers expected inside patch.ps1.
$block = "// --- CLAUDE RTL PATCH START ---`n" + $payInlined.TrimEnd("`n") + "`n// --- CLAUDE RTL PATCH END ---"

# Validate syntax before touching patch.ps1. Keep the temp file inside the repo
# (system TEMP can be sandbox-protected against cleanup).
$tmp = Join-Path $repoRoot '.payload-check.tmp.js'
[IO.File]::WriteAllText($tmp, $payInlined, (New-Object System.Text.UTF8Encoding $false))
& node --check $tmp
$ok = $?
Remove-Item $tmp -Force -ErrorAction SilentlyContinue
if (-not $ok) { Write-Host "node --check failed - aborting, patch.ps1 untouched." -ForegroundColor Red; exit 1 }

# Splice the block into patch.ps1 between the markers (inclusive).
$patch = Read-Lf $patchPath
$pattern = '(?s)// --- CLAUDE RTL PATCH START ---.*?// --- CLAUDE RTL PATCH END ---'
if (-not [regex]::IsMatch($patch, $pattern)) {
    Write-Host "RTL PATCH markers not found in patch.ps1" -ForegroundColor Red; exit 1
}
# Use a MatchEvaluator so '$' in the JS is not interpreted as a replacement token.
$evaluator = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $block }
$updated = [regex]::Replace($patch, $pattern, $evaluator, [System.Text.RegularExpressions.RegexOptions]::Singleline)

# Sanity guard: never write a suspiciously small file (protects against any
# upstream failure that could otherwise truncate patch.ps1).
if ($updated.Length -lt ($patch.Length / 2)) {
    Write-Host "SANITY FAIL: assembled file too short ($($updated.Length) chars) - aborting, file untouched." -ForegroundColor Red
    exit 1
}

if ($updated -eq $patch) {
    Write-Host "Payload unchanged - patch.ps1 already up to date." -ForegroundColor Yellow
} else {
    [IO.File]::WriteAllText($patchPath, $updated, (New-Object System.Text.UTF8Encoding $false))
    $written = [IO.File]::ReadAllBytes($patchPath).Length
    Write-Host "Injected payload into patch.ps1 (block $($block.Length) chars; file now $written bytes)." -ForegroundColor Green
}

Write-Host ""
Write-Host "NEXT: re-sign and commit:" -ForegroundColor Yellow
Write-Host "  tools/sign-release.ps1"
Write-Host "  git add patch.ps1 patch.ps1.sig dist/rtl-payload-built.js"
