# claude-squirrel-diag.ps1  --  READ-ONLY. Collects the structure of a
# Squirrel-based Claude Desktop install so RTL-patch support can be added.
# Changes NOTHING on your system. No administrator rights required.

$ErrorActionPreference = 'Continue'
$out = Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-squirrel-diag.txt'
$sb  = New-Object System.Text.StringBuilder
function L($msg)     { [void]$sb.AppendLine([string]$msg); Write-Host $msg }
function Section($t) { L ""; L "==================== $t ====================" }

L "Claude Squirrel diagnostic - $(Get-Date -Format o)  (read-only)"

Section "1. SYSTEM"
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
L "OS           : $((Get-CimInstance Win32_OperatingSystem).Caption)"
L "Build        : $([Environment]::OSVersion.Version).$($cv.UBR)  ($($cv.DisplayVersion))"
L "Architecture : $env:PROCESSOR_ARCHITECTURE"
L "PowerShell   : $($PSVersionTable.PSVersion)"

Section "2. MSIX PACKAGE (is the modern build also present?)"
$appx = Get-AppxPackage *Claude*
if ($appx) { foreach ($p in $appx) {
    L "Name=$($p.Name)  Version=$($p.Version)  Arch=$($p.Architecture)"
    L "  InstallLocation=$($p.InstallLocation)"
} } else { L "No MSIX *Claude* package registered." }

Section "3. SQUIRREL ROOT TREE"
$root = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
if (Test-Path $root) {
    L "Root: $root"
    L "-- top level --"
    Get-ChildItem $root -Force | ForEach-Object { L ("{0,-10} {1,12}  {2}" -f $_.Mode,$_.Length,$_.Name) }
    $upd = Join-Path $root 'Update.exe'
    if (Test-Path $upd) { $ui=(Get-Item $upd).VersionInfo; L "Update.exe: present  FileVersion=$($ui.FileVersion)" }
    else { L "Update.exe: ABSENT (important - this is how Squirrel launches the app)" }
    foreach ($n in 'RELEASES','packages','.dead') {
        $pth = Join-Path $root $n
        L "$n : $(if (Test-Path $pth) { 'present' } else { 'absent' })"
    }
} else { L "No Squirrel install at $root  (you may be MSIX-only; this script is not relevant then)." }

Section "4. app-<version> FOLDERS + claude.exe + app.asar"
if (Test-Path $root) {
    $appDirs = Get-ChildItem $root -Directory -Filter 'app-*' -ErrorAction SilentlyContinue
    if (-not $appDirs) { $appDirs = Get-ChildItem $root -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'claude.exe') } }
    foreach ($d in $appDirs) {
        L ""; L "Folder: $($d.Name)"
        $exe = Join-Path $d.FullName 'claude.exe'
        if (Test-Path $exe) {
            $vi=(Get-Item $exe).VersionInfo
            L "  claude.exe: present ($((Get-Item $exe).Length) bytes)  FileVersion=$($vi.FileVersion)  ProductVersion=$($vi.ProductVersion)"
            $sig = Get-AuthenticodeSignature $exe
            L "  Signature: $($sig.Status)"
            if ($sig.SignerCertificate) { L "    Subject=$($sig.SignerCertificate.Subject)"; L "    Issuer =$($sig.SignerCertificate.Issuer)" }
        } else { L "  claude.exe: MISSING" }
        $res  = Join-Path $d.FullName 'resources'
        $asar = Join-Path $res 'app.asar'
        L "  resources\app.asar         : $(if (Test-Path $asar) { "present ($((Get-Item $asar).Length) bytes)" } else { 'MISSING' })"
        L "  resources\app.asar.unpacked: $(if (Test-Path (Join-Path $res 'app.asar.unpacked')) { 'present' } else { 'absent' })"
        if (Test-Path $res) { L "  resources\ contents:"; Get-ChildItem $res -Force | ForEach-Object { L "      $($_.Name)" } }
    }
}

Section "5. REGISTRY - Uninstall entries (the locator relies on these)"
foreach ($hive in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                  'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                  'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
    Get-ItemProperty $hive -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Claude' } | ForEach-Object {
        L ""; L "  DisplayName=$($_.DisplayName)  DisplayVersion=$($_.DisplayVersion)"
        L "    Publisher=$($_.Publisher)"
        L "    InstallLocation=$($_.InstallLocation)"
        L "    UninstallString=$($_.UninstallString)"
    }
}

Section "6. cowork-svc SERVICE (patch stops/starts this)"
$svc = Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'cowork|Claude' }
if ($svc) { foreach ($s in $svc) { L "  Name=$($s.Name)  State=$($s.State)  StartMode=$($s.StartMode)"; L "    PathName=$($s.PathName)" } }
else { L "  No Claude/cowork-svc service found (tells us if Squirrel even registers it)." }

Section "7. RUNNING PROCESSES"
$procs = Get-Process -Name claude,cowork-svc -ErrorAction SilentlyContinue
if ($procs) { foreach ($p in $procs) { L "  $($p.ProcessName)  PID=$($p.Id)  Path=$($p.Path)" } } else { L "  none running." }

Section "8. claude:// PROTOCOL HANDLER (launch + conflict source)"
foreach ($k in 'HKCU:\Software\Classes\claude\shell\open\command','HKLM:\Software\Classes\claude\shell\open\command') {
    if (Test-Path $k) { L "  $k"; L "    => $((Get-ItemProperty $k).'(default)')" }
}

Section "9. START MENU SHORTCUTS (reveals the real launch command)"
foreach ($base in (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
                  (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')) {
    Get-ChildItem $base -Recurse -Filter '*Claude*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
        $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($_.FullName)
        L "  $($_.Name)  ->  $($lnk.TargetPath)  $($lnk.Arguments)"
    }
}

Section "10. ELECTRON ASAR-INTEGRITY FUSE (optional; needs Node/npx)"
if (Get-Command npx -ErrorAction SilentlyContinue) {
    try {
        $exe = if (Test-Path $root) { Get-ChildItem $root -Recurse -Filter claude.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
        if ($exe) {
            L "  Probing fuses of: $exe  (npx may download @electron/fuses on first run)"
            $env:NODE_NO_WARNINGS='1'
            (cmd.exe /c "npx --yes @electron/fuses read --app `"$exe`" 2>&1" | Out-String).Split("`n") | ForEach-Object { if ($_.Trim()) { L "    $($_.TrimEnd())" } }
        }
    } catch { L "  Fuse read failed: $($_.Exception.Message)" }
} else { L "  npx not found - skipped (optional)." }

[System.IO.File]::WriteAllText($out, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "Done. Log saved to: $out" -ForegroundColor Green
Write-Host "Please attach that file to the GitHub issue." -ForegroundColor Green
Write-Host "(Paths contain your Windows username but no passwords/secrets - redact if you wish.)" -ForegroundColor Gray
