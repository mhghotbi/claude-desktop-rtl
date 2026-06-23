# claude-node-diag.ps1  --  READ-ONLY. Diagnoses why the RTL patch reports
# "Node.js (npx) is required" on machines with a Node version manager
# (Volta / nvm / fnm) installed (issue #11).
#
# Changes NOTHING on your system. Collects everything relevant in a SINGLE run:
# how node/npm/npx resolve, the version managers in play, the registry PATH a
# fresh elevated process rebuilds from, and -- most importantly -- the FULL
# output + exit code of the exact npx probe the patch runs.
#
# Run it the SAME way the patch fails for you. If the patch fails elevated,
# right-click PowerShell -> "Run as administrator" and run it there too: the
# elevated PATH differs from your normal shell, and that difference is often the
# whole bug. The script reports which context it ran in.

$ErrorActionPreference = 'Continue'
$out = Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-node-diag.txt'
$sb  = New-Object System.Text.StringBuilder

function L($msg)      { [void]$sb.AppendLine([string]$msg); Write-Host $msg }
function Section($t)  { L ""; L "==================== $t ====================" }
function Safe($block) { try { & $block } catch { L "  [error] $($_.Exception.Message)" } }

# The exact package/version the patch shells out to. Keep in sync with patch.ps1.
$AsarPackage = '@electron/asar@4.2.0'
$SysNodeDir  = Join-Path $env:ProgramFiles 'nodejs'

L "Claude Node/npx diagnostic - $(Get-Date -Format o)  (read-only)"

# --------------------------------------------------------------------------
Section "1. CONTEXT (elevated vs normal -- the patch runs ELEVATED)"
Safe {
    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $adm = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    L "User           : $($id.Name)"
    L "Elevated (admin): $adm   <-- the patch ALWAYS runs as TRUE; match it to reproduce"
    L "OS             : $((Get-CimInstance Win32_OperatingSystem).Caption)"
    L "Architecture   : $env:PROCESSOR_ARCHITECTURE"
    L "PowerShell     : $($PSVersionTable.PSVersion)"
}

# --------------------------------------------------------------------------
Section "2. NODE-RELATED ENVIRONMENT VARIABLES (this process)"
foreach ($n in 'VOLTA_HOME','VOLTA_INSTALL_DIR','NVM_HOME','NVM_SYMLINK','FNM_DIR',
               'NODE','NODE_PATH','NODE_OPTIONS','NPM_CONFIG_PREFIX','npm_config_prefix',
               'npm_config_cache','NPM_CONFIG_CACHE','NPM_CONFIG_REGISTRY','NODE_NO_WARNINGS') {
    $v = [Environment]::GetEnvironmentVariable($n)
    if ($v) { L ("  {0,-20} = {1}" -f $n, $v) }
}
L "  (only set variables are listed)"

# --------------------------------------------------------------------------
Section "3. CURRENT PATH -- per entry, with node/manager annotations"
$entries = $env:PATH -split ';' | Where-Object { $_ -ne '' }
$i = 0
foreach ($e in $entries) {
    $i++
    $tags = @()
    if ($e -match 'Volta')                         { $tags += 'VOLTA' }
    if ($e -match 'nvm')                           { $tags += 'NVM' }
    if ($e -match 'fnm')                           { $tags += 'FNM' }
    if ($e -match 'Program Files\\nodejs')         { $tags += 'SYSTEM-NODE' }
    $has = @()
    # A malformed PATH entry (stray quote, illegal char) must not abort the loop.
    try {
        foreach ($b in 'node.exe','npm.cmd','npx.cmd','npx.exe') {
            if (Test-Path -LiteralPath (Join-Path $e $b) -ErrorAction Stop) { $has += $b }
        }
    } catch { $tags += 'MALFORMED-ENTRY' }
    if ($has) { $tags += "has:$($has -join ',')" }
    $tag = if ($tags) { "   [$($tags -join ' | ')]" } else { "" }
    L ("  {0,2}. {1}{2}" -f $i, $e, $tag)
}

# --------------------------------------------------------------------------
Section "4. REGISTRY PATH (what a fresh ELEVATED process rebuilds from)"
# The patch elevates via Start-Process -Verb RunAs, which spawns a brand-new
# process whose PATH comes from these registry values -- NOT from your shell.
# Any manual PATH edit you made in your own terminal is invisible here.
function Dump-RegPath($hive, $sub, $label) {
    Safe {
        $key = [Microsoft.Win32.Registry]::$hive.OpenSubKey($sub)
        if ($key) {
            $raw = $key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $key.Close()
            L "$label (raw, unexpanded):"
            if ($raw) { ($raw -split ';' | Where-Object { $_ -ne '' }) | ForEach-Object { L "    $_" } }
            else { L "    (empty)" }
        } else { L "$label : key not found" }
    }
}
Dump-RegPath 'LocalMachine' 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment' 'HKLM (machine PATH)'
L ""
Dump-RegPath 'CurrentUser'  'Environment' 'HKCU (user PATH)'

# --------------------------------------------------------------------------
Section "5. HOW node / npm / npx RESOLVE (where.exe + Get-Command)"
foreach ($cmd in 'node','npm','npx') {
    L ""
    L "-- $cmd --"
    Safe {
        $w = cmd.exe /c "where.exe $cmd 2>&1"
        if ($LASTEXITCODE -eq 0) { $w | ForEach-Object { L "  where: $_" } }
        else { L "  where.exe: not found (exit $LASTEXITCODE)" }
    }
    Safe {
        $gc = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($gc) { L "  Get-Command: $($gc.Source)" }
    }
}

# --------------------------------------------------------------------------
Section "6. SYSTEM NODE at C:\Program Files\nodejs (the patch's fallback)"
if (Test-Path $SysNodeDir) {
    L "Directory present: $SysNodeDir"
    foreach ($b in 'node.exe','npm.cmd','npx.cmd','npx.exe') {
        $p = Join-Path $SysNodeDir $b
        L "  $b : $(if (Test-Path $p) { 'present' } else { 'ABSENT' })"
    }
    Safe {
        $nv = & (Join-Path $SysNodeDir 'node.exe') --version 2>&1
        L "  node.exe --version: $nv"
    }
} else {
    L "ABSENT: $SysNodeDir does not exist."
    L "  -> The patch's fallback cannot trigger. Installing Node from https://nodejs.org fixes this."
}
$x86 = Join-Path ${env:ProgramFiles(x86)} 'nodejs'
if ($x86 -and (Test-Path $x86)) { L "  (also found 32-bit: $x86)" }

# --------------------------------------------------------------------------
Section "7. VERSION MANAGERS (Volta / nvm / fnm)"
$voltaHome = if ($env:VOLTA_HOME) { $env:VOLTA_HOME } else { Join-Path $env:LOCALAPPDATA 'Volta' }
if (Test-Path $voltaHome) {
    L "VOLTA present: $voltaHome"
    $vbin = Join-Path $voltaHome 'bin'
    if (Test-Path $vbin) {
        L "  bin\ contents:"
        Get-ChildItem $vbin -Force -ErrorAction SilentlyContinue | ForEach-Object { L "      $($_.Name)" }
    }
    Safe { $vv = cmd.exe /c "volta --version 2>&1"; L "  volta --version: $vv" }
    Safe { L "  volta list all:"; (cmd.exe /c "volta list all 2>&1" | Out-String).Split("`n") | ForEach-Object { if ($_.Trim()) { L "      $($_.TrimEnd())" } } }
    Safe { $wn = cmd.exe /c "volta which node 2>&1"; L "  volta which node: $wn" }
    Safe { $wx = cmd.exe /c "volta which npx 2>&1";  L "  volta which npx : $wx" }
} else { L "Volta: not detected." }
foreach ($m in @{n='nvm';p=$env:NVM_HOME}, @{n='fnm';p=$env:FNM_DIR}) {
    if ($m.p -and (Test-Path $m.p)) { L "$($m.n): present at $($m.p)" }
}

# --------------------------------------------------------------------------
Section "8. npm CONFIG (prefix / cache / registry -- affects npx download)"
Safe { L "  prefix  : $(cmd.exe /c 'npm config get prefix 2>&1')" }
Safe { L "  cache   : $(cmd.exe /c 'npm config get cache 2>&1')" }
Safe { L "  registry: $(cmd.exe /c 'npm config get registry 2>&1')" }
Safe {
    L "  -- npm config list -- "
    (cmd.exe /c "npm config list 2>&1" | Out-String).Split("`n") | ForEach-Object { if ($_.Trim()) { L "    $($_.TrimEnd())" } }
}

# --------------------------------------------------------------------------
Section "9. *** THE ACTUAL PROBE *** (exactly what patch.ps1 runs)"
$env:NODE_NO_WARNINGS = '1'

L "9a. As resolved by your current PATH -- the patch's primary probe:"
L "    cmd /c 'npx --yes $AsarPackage --version'"
Safe {
    $o = cmd.exe /c "npx --yes $AsarPackage --version 2>&1"
    $code = $LASTEXITCODE
    (($o | Out-String).Split("`n")) | ForEach-Object { if ($_.Trim()) { L "    $($_.TrimEnd())" } }
    L "  >> exit code: $code  $(if ($code -eq 0) { '(OK)' } else { '(FAILED - this is the patch error)' })"
}

L ""
L "9b. Forced to SYSTEM Node (patch fallback: prepend $SysNodeDir, retry):"
if (Test-Path (Join-Path $SysNodeDir 'npx.cmd')) {
    Safe {
        $saved = $env:PATH
        $env:PATH = "$SysNodeDir;$env:PATH"
        $o = cmd.exe /c "npx --yes $AsarPackage --version 2>&1"
        $code = $LASTEXITCODE
        $env:PATH = $saved
        (($o | Out-String).Split("`n")) | ForEach-Object { if ($_.Trim()) { L "    $($_.TrimEnd())" } }
        L "  >> exit code: $code  $(if ($code -eq 0) { '(OK - fallback works in THIS context)' } else { '(FAILED even on system Node)' })"
    }
} else { L "  skipped: $SysNodeDir\npx.cmd not present." }

# --------------------------------------------------------------------------
Section "10. REGISTRY connectivity to npm (npx --yes downloads on first use)"
Safe {
    $reg = (cmd.exe /c 'npm config get registry 2>&1').Trim()
    if (-not $reg -or $reg -notmatch '^https?://') { $reg = 'https://registry.npmjs.org/' }
    L "  Testing reachability of: $reg"
    $req = [System.Net.WebRequest]::Create($reg)
    $req.Method = 'HEAD'; $req.Timeout = 8000
    try { $resp = $req.GetResponse(); L "  -> reachable (status $([int]$resp.StatusCode))"; $resp.Close() }
    catch { L "  -> NOT reachable: $($_.Exception.Message)  (proxy/offline can break npx --yes)" }
}

# --------------------------------------------------------------------------
[System.IO.File]::WriteAllText($out, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "Done. Report saved to: $out" -ForegroundColor Green
Write-Host "Please attach that file to GitHub issue #11." -ForegroundColor Green
Write-Host "(Paths contain your Windows username but no passwords/secrets - redact if you wish.)" -ForegroundColor Gray
