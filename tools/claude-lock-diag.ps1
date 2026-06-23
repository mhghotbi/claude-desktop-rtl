# claude-lock-diag.ps1  --  READ-ONLY. Diagnoses why the RTL patch reports
# "File 'claude.exe' is still locked after 15s" even right after a reboot,
# when no Claude process is running (issue #15).
#
# Changes NOTHING on your install. It only OPENS the Claude binaries for a
# fraction of a second and closes them again -- it never writes, truncates,
# patches or deletes any file under Program Files. The single empirical write
# test (section 6) runs on a throwaway COPY in your TEMP folder, never on the
# real binary.
#
# Run it the SAME way the patch fails for you: the patch ALWAYS runs ELEVATED.
# Right-click PowerShell -> "Run as administrator" and run it there, otherwise
# the ACL/lock picture differs from what the patch sees. The script reports
# which context it ran in.
#
# Why this script exists: patch.ps1's lock probe opens files with
# FileShare.None (exclusive) + ReadWrite, which is STRICTER than the real
# backup (a read) and the real patch write ([IO.File]::WriteAllBytes opens with
# FileShare.Read). A harmless coexisting handle from Defender / the search
# indexer / the MSIX layer can therefore make the probe report "locked" even
# though the actual patch write would have succeeded. This script measures,
# on YOUR machine, exactly which of those is happening.

$ErrorActionPreference = 'Continue'
$out = Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-lock-diag.txt'
$sb  = New-Object System.Text.StringBuilder

function L($msg)      { [void]$sb.AppendLine([string]$msg); Write-Host $msg }
function Section($t)  { L ""; L "==================== $t ====================" }
# PowerShell wraps exceptions from static-method calls in a MethodInvocationException;
# unwrap to the real .NET exception so the log shows IOException / UnauthorizedAccessException.
function ExType($err) { if ($err.Exception.InnerException) { $err.Exception.InnerException.GetType().Name } else { $err.Exception.GetType().Name } }
function ExMsg($err)  { if ($err.Exception.InnerException) { $err.Exception.InnerException.Message }     else { $err.Exception.Message } }
function Safe($block) { try { & $block } catch { L "  [error] $(ExType $_): $(ExMsg $_)" } }

L "Claude file-lock diagnostic - $(Get-Date -Format o)  (read-only)"

# --------------------------------------------------------------------------
Section "1. CONTEXT (elevated vs normal -- the patch runs ELEVATED)"
Safe {
    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $adm = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    L "User            : $($id.Name)"
    L "Elevated (admin): $adm   <-- the patch ALWAYS runs as TRUE; match it to reproduce"
    L "OS              : $((Get-CimInstance Win32_OperatingSystem).Caption)"
    L "OS Build        : $((Get-CimInstance Win32_OperatingSystem).BuildNumber)"
    L "Architecture    : $env:PROCESSOR_ARCHITECTURE"
    L "PowerShell      : $($PSVersionTable.PSVersion)"
    L ".NET (CLR)      : $([System.Environment]::Version)"
}

# --------------------------------------------------------------------------
Section "2. CLAUDE PROCESSES & SERVICE STATE (the patch kills these first)"
Safe {
    foreach ($n in 'claude','cowork-svc') {
        $p = Get-Process -Name $n -ErrorAction SilentlyContinue
        if ($p) { $p | ForEach-Object { L "  RUNNING: $n  PID=$($_.Id)  Path=$($_.Path)" } }
        else    { L "  not running: $n" }
    }
}
Safe {
    $wmiSvc = Get-WmiObject Win32_Service | Where-Object { $_.PathName -match "cowork-svc" }
    if ($wmiSvc) { L "  Service: $($wmiSvc.Name)  State=$($wmiSvc.State)  StartMode=$($wmiSvc.StartMode)`n           Path=$($wmiSvc.PathName)" }
    else         { L "  No cowork-svc Windows service found." }
}

# --------------------------------------------------------------------------
Section "3. CLAUDE INSTALL PATHS (same logic as patch.ps1 Find-ClaudeDir)"
$ClaudeDir = $null
Safe {
    $pkg = Get-AppxPackage | Where-Object { $_.Name -like '*Claude*' -and $_.InstallLocation -like '*WindowsApps*' } | Select-Object -First 1
    if ($pkg) { $script:ClaudeDir = $pkg.InstallLocation }
}
if (-not $ClaudeDir) {
    L "  Claude (WindowsApps/MSIX) install NOT found via Get-AppxPackage."
    $legacy = Join-Path $env:LOCALAPPDATA "AnthropicClaude"
    if (Test-Path $legacy) { L "  Legacy Squirrel install present at: $legacy (NOT supported by the patch)" }
}
$AppDir        = if ($ClaudeDir) { Join-Path $ClaudeDir "app" } else { $null }
$ResourcesDir  = if ($AppDir)    { Join-Path $AppDir "resources" } else { $null }
$ExePath       = if ($AppDir)    { Join-Path $AppDir "claude.exe" } else { $null }
$CoworkSvcPath = if ($ResourcesDir) { Join-Path $ResourcesDir "cowork-svc.exe" } else { $null }
$AsarPath      = if ($ResourcesDir) { Join-Path $ResourcesDir "app.asar" } else { $null }
L "  ClaudeDir     : $ClaudeDir"
L "  AppDir        : $AppDir"
L "  ExePath       : $ExePath"
L "  CoworkSvcPath : $CoworkSvcPath"
L "  AsarPath      : $AsarPath"

$Targets = @()
if ($ExePath)       { $Targets += $ExePath }
if ($CoworkSvcPath) { $Targets += $CoworkSvcPath }
if ($AsarPath)      { $Targets += $AsarPath }

# --------------------------------------------------------------------------
Section "4. FILE ATTRIBUTES, OWNER & ACL"
foreach ($t in $Targets) {
    L ""
    L "-- $(Split-Path $t -Leaf) --"
    if (-not (Test-Path -LiteralPath $t)) { L "  MISSING: $t"; continue }
    Safe {
        $it = Get-Item -LiteralPath $t -Force
        L "  Size       : $($it.Length) bytes"
        L "  Attributes : $($it.Attributes)"
        L "  ReadOnly   : $([bool]($it.Attributes -band [IO.FileAttributes]::ReadOnly))"
    }
    Safe {
        $acl = Get-Acl -LiteralPath $t
        L "  Owner      : $($acl.Owner)"
        L "  Access     :"
        foreach ($ace in $acl.Access) {
            L ("     {0,-32} {1,-10} {2}" -f $ace.IdentityReference, $ace.AccessControlType, $ace.FileSystemRights)
        }
    }
}

# --------------------------------------------------------------------------
Section "5. NON-DESTRUCTIVE OPEN MATRIX (open + immediate close, never write)"
L "  Legend: OK = openable | DENIED = UnauthorizedAccessException (ACL/permissions)"
L "          LOCKED = IOException/sharing violation (a coexisting handle exists)"
L ""
L "  (Open, ReadWrite, None) is EXACTLY patch.ps1's current Test-FileLock probe."
L "  (Open, ReadWrite, Read) matches what [IO.File]::WriteAllBytes requests."
L "  (Open, Read, Read)      matches what the backup read needs."

function Probe-Open($path, [System.IO.FileAccess]$access, [System.IO.FileShare]$share) {
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, $access, $share)
        $fs.Close()
        return "OK"
    } catch [System.UnauthorizedAccessException] {
        return "DENIED  (UnauthorizedAccessException) -> $($_.Exception.Message)"
    } catch [System.IO.IOException] {
        return "LOCKED  (IOException/sharing)        -> $($_.Exception.Message)"
    } catch {
        return "OTHER   ($($_.Exception.GetType().Name)) -> $($_.Exception.Message)"
    }
}

$matrix = @(
    @{ a=[System.IO.FileAccess]::Read;      s=[System.IO.FileShare]::Read; label="(Open, Read,      Read)" }
    @{ a=[System.IO.FileAccess]::ReadWrite; s=[System.IO.FileShare]::Read; label="(Open, ReadWrite, Read)" }
    @{ a=[System.IO.FileAccess]::ReadWrite; s=[System.IO.FileShare]::None; label="(Open, ReadWrite, None)  <-- current probe" }
)
foreach ($t in $Targets) {
    L ""
    L "-- $(Split-Path $t -Leaf) --"
    if (-not (Test-Path -LiteralPath $t)) { L "  MISSING"; continue }
    foreach ($m in $matrix) {
        L ("  {0,-40} : {1}" -f $m.label, (Probe-Open $t $m.a $m.s))
    }
}

# --------------------------------------------------------------------------
Section "6. EMPIRICAL: does WriteAllBytes tolerate a coexisting handle? (TEMP copy)"
L "  Proves on YOUR machine whether [IO.File]::WriteAllBytes uses FileShare.None."
L "  Runs entirely on a throwaway copy in TEMP; the real install is untouched."
if ($ExePath -and (Test-Path -LiteralPath $ExePath)) {
    Safe {
        $tmp = Join-Path $env:TEMP ("claude-lock-diag-" + [System.Guid]::NewGuid().ToString('N') + ".bin")
        Copy-Item -LiteralPath $ExePath -Destination $tmp -Force
        try {
            $bytes = [System.IO.File]::ReadAllBytes($tmp)

            # Scenario A: a Defender-like holder (Read access, shares Read+Write+Delete).
            $shareRW = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            $holdA = [System.IO.File]::Open($tmp, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $shareRW)
            try {
                try { [System.IO.File]::WriteAllBytes($tmp, $bytes); $wa = "SUCCESS -> WriteAllBytes tolerates a coexisting shared handle (it does NOT use FileShare.None)" }
                catch { $wa = "FAILED ($(ExType $_)) -> $(ExMsg $_)" }
                try { $f=[System.IO.File]::Open($tmp,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None); $f.Close(); $pn="SUCCESS (unexpected)" }
                catch { $pn = "FAILED as expected ($(ExType $_)) -> the FileShare.None probe rejects the coexisting handle" }
            } finally { $holdA.Close() }
            L "  [A] Holder shares ReadWrite (Defender-like):"
            L "       WriteAllBytes        : $wa"
            L "       Open(ReadWrite,None) : $pn"

            # Scenario B: a read-only-share holder (shares Read only). Documents the
            # case where a backup read would pass but a patch write would still fail.
            $holdB = [System.IO.File]::Open($tmp, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            try {
                try { [System.IO.File]::WriteAllBytes($tmp, $bytes); $wb = "SUCCESS" }
                catch { $wb = "FAILED ($(ExType $_)) -> a Read-only-share holder DOES block the write" }
            } finally { $holdB.Close() }
            L "  [B] Holder shares Read only:"
            L "       WriteAllBytes        : $wb"
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
} else {
    L "  skipped: claude.exe not found."
}

# --------------------------------------------------------------------------
Section "7. RESTART MANAGER -- which processes actually hold each file open"
$rmOk = $false
Safe {
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class RmLock {
    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }
    const int CCH_RM_MAX_APP_NAME = 255;
    const int CCH_RM_MAX_SVC_NAME = 63;
    enum RM_APP_TYPE { RmUnknownApp=0, RmMainWindow=1, RmOtherWindow=2, RmService=3, RmExplorer=4, RmConsole=5, RmCritical=1000 }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_APP_NAME + 1)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_SVC_NAME + 1)] public string strServiceShortName;
        public RM_APP_TYPE ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);
    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint pSessionHandle);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames, uint nApplications, [In] RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);
    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);
    public static List<string> GetLockers(string path) {
        var result = new List<string>();
        uint handle; string key = Guid.NewGuid().ToString();
        int res = RmStartSession(out handle, 0, key);
        if (res != 0) throw new Exception("RmStartSession failed: " + res);
        try {
            string[] resources = new string[] { path };
            res = RmRegisterResources(handle, (uint)resources.Length, resources, 0, null, 0, null);
            if (res != 0) throw new Exception("RmRegisterResources failed: " + res);
            uint needed = 0, count = 0, reason = 0;
            res = RmGetList(handle, out needed, ref count, null, ref reason);
            if (res == 234 /*ERROR_MORE_DATA*/) {
                var info = new RM_PROCESS_INFO[needed];
                count = needed;
                res = RmGetList(handle, out needed, ref count, info, ref reason);
                if (res != 0) throw new Exception("RmGetList(2) failed: " + res);
                for (int i = 0; i < count; i++)
                    result.Add(info[i].strAppName + " (PID " + info[i].Process.dwProcessId + ", type " + info[i].ApplicationType + ")");
            } else if (res != 0) {
                throw new Exception("RmGetList(1) failed: " + res);
            }
        } finally { RmEndSession(handle); }
        return result;
    }
}
'@
    $script:rmOk = $true
}
if ($rmOk) {
    foreach ($t in $Targets) {
        if (-not (Test-Path -LiteralPath $t)) { continue }
        Safe {
            $lockers = [RmLock]::GetLockers($t)
            if ($lockers.Count -eq 0) { L "  $(Split-Path $t -Leaf): NO process holds this file (per Restart Manager)" }
            else { L "  $(Split-Path $t -Leaf): held by:"; $lockers | ForEach-Object { L "      $_" } }
        }
    }
} else {
    L "  Restart Manager query unavailable in this session."
}

# --------------------------------------------------------------------------
Section "8. WINDOWS DEFENDER / ANTIVIRUS (a common benign handle holder)"
Safe {
    $st = Get-MpComputerStatus -ErrorAction Stop
    L "  RealTimeProtectionEnabled : $($st.RealTimeProtectionEnabled)"
    L "  AntivirusEnabled          : $($st.AntivirusEnabled)"
    L "  AMRunningMode             : $($st.AMRunningMode)"
}
Safe {
    $pref = Get-MpPreference -ErrorAction Stop
    $ex = $pref.ExclusionPath
    if ($ex) { L "  Defender ExclusionPath:"; $ex | ForEach-Object { L "      $_" } }
    else     { L "  Defender ExclusionPath: (none)" }
}
Safe {
    $av = Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop
    if ($av) { L "  Registered AV products:"; $av | ForEach-Object { L "      $($_.displayName)" } }
}

# --------------------------------------------------------------------------
Section "9. APPX PACKAGE INFO"
Safe {
    $pkg = Get-AppxPackage *Claude* | Select-Object -First 1
    if ($pkg) {
        L "  Name            : $($pkg.Name)"
        L "  Version         : $($pkg.Version)"
        L "  PackageFullName : $($pkg.PackageFullName)"
        L "  InstallLocation : $($pkg.InstallLocation)"
        L "  Status          : $($pkg.Status)"
        L "  SignatureKind   : $($pkg.SignatureKind)"
    } else { L "  No *Claude* AppX package found." }
}

# --------------------------------------------------------------------------
[System.IO.File]::WriteAllText($out, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "Done. Report saved to: $out" -ForegroundColor Green
Write-Host "Please attach that file to GitHub issue #15." -ForegroundColor Green
Write-Host "(Paths contain your Windows username but no passwords/secrets - redact if you wish.)" -ForegroundColor Gray
