# claude-removal-diag.ps1  --  READ-ONLY. Investigates WHO silently removed the
# Claude Desktop app after the RTL patch (Windows MSIX integrity remediation vs.
# Windows Defender / third-party AV vs. a Claude updater vs. policy/MDM).
#
# Changes NOTHING on your system. Collects everything potentially relevant in a
# SINGLE run so no follow-up runs are needed. Each section degrades gracefully.
#
# Runs as a normal user, but a few event-log channels are admin-only -- for the
# most complete report, right-click PowerShell -> "Run as administrator".

$ErrorActionPreference = 'Continue'
$out = Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-removal-diag.txt'
$sb  = New-Object System.Text.StringBuilder

function L($msg)     { [void]$sb.AppendLine([string]$msg); Write-Host $msg }
function Section($t) { L ""; L "==================== $t ====================" }
function Safe($block) { try { & $block } catch { L "  [error] $($_.Exception.Message)" } }

# Dump event-log entries from $LogName within the last $Days, keeping only those
# whose message matches any keyword in $Match. Read-only; never throws to caller.
function Dump-Events {
    param(
        [Parameter(Mandatory)][string]$LogName,
        [string[]]$Match = @(),
        [int]$Days = 30,
        [int]$MaxScan = 5000,
        [int]$Show = 80
    )
    $events = $null
    try {
        $start  = (Get-Date).AddDays(-$Days)
        $events = Get-WinEvent -FilterHashtable @{ LogName = $LogName; StartTime = $start } -MaxEvents $MaxScan -ErrorAction Stop
    } catch {
        if ($_.Exception.Message -match 'No events were found') {
            L "  (no events in '$LogName' within $Days days)"
        } else {
            L "  (log '$LogName' unavailable: $($_.Exception.Message))"
        }
        return
    }
    if (-not $events) { L "  (no events in '$LogName' within $Days days)"; return }
    if ($Match.Count -gt 0) {
        $rx   = ($Match -join '|')
        $hits = $events | Where-Object { $_.Message -match $rx }
        if (-not $hits) { L "  ($($events.Count) events scanned in '$LogName'; none matched /$rx/)"; return }
    } else {
        $hits = $events
    }
    L "  $(@($hits).Count) matching event(s) in '$LogName' (showing up to $Show):"
    @($hits) | Select-Object -First $Show | ForEach-Object {
        $msg = ($_.Message -replace '\s+', ' ').Trim()
        if ($msg.Length -gt 500) { $msg = $msg.Substring(0, 500) + '...' }
        L ("    [{0:yyyy-MM-dd HH:mm:ss}] Id={1} Lvl={2} Src={3}" -f $_.TimeCreated, $_.Id, $_.LevelDisplayName, $_.ProviderName)
        L ("        $msg")
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

L "Claude removal diagnostic - $(Get-Date -Format o)  (read-only)"
L "Running elevated: $isAdmin  $(if (-not $isAdmin) { '(some event logs may be skipped - re-run as admin for full coverage)' })"

# -----------------------------------------------------------------------------
Section "1. SYSTEM"
Safe {
    $os = Get-CimInstance Win32_OperatingSystem
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    L "OS           : $($os.Caption)  (EditionID=$($cv.EditionID))"
    L "Build        : $([Environment]::OSVersion.Version).$($cv.UBR)  (DisplayVersion=$($cv.DisplayVersion))"
    if ("$($cv.DisplayVersion)" -match '25H2' -or [int]$cv.CurrentBuildNumber -ge 26100) {
        L "  NOTE: recent Win11 servicing build -- MSIX tamper remediation is more aggressive here."
    }
    L "Architecture : $env:PROCESSOR_ARCHITECTURE"
    L "OS installed : $($os.InstallDate)"
    L "Last boot    : $($os.LastBootUpTime)"
    L "System locale: $((Get-Culture).Name) / UI $((Get-UICulture).Name)  (RTL UI: $(([System.Globalization.CultureInfo](Get-UICulture)).TextInfo.IsRightToLeft))"
    L "PowerShell   : $($PSVersionTable.PSVersion)"
}
Safe {
    $c = Get-PSDrive C -ErrorAction Stop
    L "Disk C: free : $([math]::Round($c.Free/1GB,1)) GB free of $([math]::Round(($c.Used+$c.Free)/1GB,1)) GB"
}

# -----------------------------------------------------------------------------
Section "2. CLAUDE INSTALL KIND (MSIX vs Squirrel vs gone)"
Safe {
    $appx = Get-AppxPackage *Claude*
    if ($appx) {
        foreach ($p in $appx) {
            L ""
            L "MSIX package : $($p.Name)  v$($p.Version)  [$($p.Architecture)]"
            L "  PackageFullName   = $($p.PackageFullName)"
            L "  PackageFamilyName = $($p.PackageFamilyName)"
            L "  SignatureKind     = $($p.SignatureKind)   Status = $($p.Status)   IsBundle = $($p.IsBundle)"
            L "  InstallLocation   = $($p.InstallLocation)"
            L "  InstallLocation exists on disk: $(if ($p.InstallLocation) { Test-Path $p.InstallLocation } else { '<null>' })"
            try { L "  InstallTime       = $($p.InstallTime)" } catch {}
            try {
                $ui = $p | Get-AppxPackageManifest -ErrorAction SilentlyContinue
                if ($ui) { L "  Manifest read OK (package metadata present)." }
            } catch {}
        }
    } else {
        L "No MSIX *Claude* package registered for the current user."
        L "  (If the app was silently removed, this is expected -- check sections 3-5 for who removed it.)"
    }
}
Safe {
    if ($isAdmin) {
        $prov = Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -match 'Claude' -or $_.PackageName -match 'Claude' }
        if ($prov) { foreach ($pp in $prov) { L "Provisioned  : $($pp.PackageName)  v$($pp.Version)" } }
        else { L "No provisioned (system-wide) Claude package." }
    } else {
        L "Provisioned-package check skipped (needs admin)."
    }
}
Safe {
    $root = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
    if (Test-Path $root) {
        L "Squirrel install present at: $root"
        Get-ChildItem $root -Force -ErrorAction SilentlyContinue | ForEach-Object { L "    $($_.Mode)  $($_.Name)" }
    } else {
        L "No Squirrel install at $root."
    }
}

# -----------------------------------------------------------------------------
Section "3. RELIABILITY MONITOR (records app install/uninstall with timestamps)"
Safe {
    $rel = Get-CimInstance Win32_ReliabilityRecords -ErrorAction Stop
    $claude = $rel | Where-Object { "$($_.ProductName) $($_.SourceName) $($_.Message)" -match 'Claude|Anthropic' }
    if ($claude) {
        L "Claude/Anthropic-related reliability records:"
        $claude | Sort-Object TimeGenerated -Descending | Select-Object -First 40 | ForEach-Object {
            L ("  [{0:yyyy-MM-dd HH:mm:ss}] Src={1} Prod={2}" -f $_.TimeGenerated, $_.SourceName, $_.ProductName)
            if ($_.Message) { L ("      $(($_.Message -replace '\s+',' ').Trim())") }
        }
    } else {
        L "No Claude/Anthropic reliability records found."
    }
    L ""
    $installRecs = $rel | Where-Object { $_.SourceName -match 'install|uninstall|MsiInstaller|Appx' } | Sort-Object TimeGenerated -Descending | Select-Object -First 25
    if ($installRecs) {
        L "Recent install/uninstall reliability records (all apps, newest first):"
        $installRecs | ForEach-Object {
            L ("  [{0:yyyy-MM-dd HH:mm:ss}] Src={1} : {2}" -f $_.TimeGenerated, $_.SourceName, (($_.ProductName, $_.Message | Where-Object { $_ }) -join ' - '))
        }
    }
}

# -----------------------------------------------------------------------------
Section "4. APPX DEPLOYMENT / PACKAGING EVENT LOGS (did Windows remove the package?)"
# Match the package name only -- any Claude install/update/remove/repair event
# carries "Claude" (PackageFullName/Family), so this catches removals without the
# noise of every other app's staging/removal churn.
$claudeMatch = @('Claude','AnthropicClaude')
Dump-Events -LogName 'Microsoft-Windows-AppXDeploymentServer/Operational' -Match $claudeMatch -Days 45 -Show 120
Dump-Events -LogName 'Microsoft-Windows-AppXDeployment/Operational'       -Match $claudeMatch -Days 45 -Show 120
Dump-Events -LogName 'Microsoft-Windows-AppxPackagingOM/Operational'      -Match $claudeMatch -Days 45 -Show 120
# State-repository activity sometimes records the removal generically.
Dump-Events -LogName 'Microsoft-Windows-StateRepository/Operational'      -Match $claudeMatch -Days 45 -Show 40

# -----------------------------------------------------------------------------
Section "5. WINDOWS DEFENDER (did AV quarantine/remove the patched binary?)"
Safe {
    $st = Get-MpComputerStatus -ErrorAction Stop
    L "RealTimeProtection : $($st.RealTimeProtectionEnabled)   AntivirusEnabled : $($st.AntivirusEnabled)"
    L "Engine/Defs version: $($st.AMEngineVersion) / $($st.AntivirusSignatureVersion)  ($($st.AntivirusSignatureLastUpdated))"
}
Safe {
    $pref = Get-MpPreference -ErrorAction Stop
    L "PUAProtection      : $($pref.PUAProtection)   MAPSReporting : $($pref.MAPSReporting)   SubmitSamplesConsent : $($pref.SubmitSamplesConsent)"
    L "Exclusion paths    : $(@($pref.ExclusionPath) -join '; ')"
    L "Exclusion processes: $(@($pref.ExclusionProcess) -join '; ')"
    if (@($pref.ExclusionPath) -match 'Claude|WindowsApps|AnthropicClaude') { L "  -> A Claude-related path IS excluded (would explain why it does NOT trigger here)." }
}
Safe {
    $det = Get-MpThreatDetection -ErrorAction Stop
    if ($det) {
        L "Threat detections (newest first):"
        $det | Sort-Object InitialDetectionTime -Descending | Select-Object -First 30 | ForEach-Object {
            L ("  [{0}] ThreatID={1} Action={2} Resources={3}" -f $_.InitialDetectionTime, $_.ThreatID, $_.ActionSuccess, (@($_.Resources) -join ', '))
        }
    } else { L "No threat detections recorded." }
}
Safe {
    $thr = Get-MpThreat -ErrorAction Stop
    if ($thr) { L "Known threats: $((@($thr | ForEach-Object { $_.ThreatName })) -join '; ')" }
    else { L "No known-threat history." }
}
Dump-Events -LogName 'Microsoft-Windows-Windows Defender/Operational' -Match @('Claude','AnthropicClaude','cowork','Goptaju') -Days 45

# -----------------------------------------------------------------------------
Section "6. THIRD-PARTY AV / SECURITY CENTER"
Safe {
    $av = Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop
    if ($av) { foreach ($a in $av) { L "  AV: $($a.displayName)   path=$($a.pathToSignedProductExe)" } }
    else { L "  SecurityCenter2 reports no registered AV products." }
}

# -----------------------------------------------------------------------------
Section "7. POLICY / MANAGEMENT THAT CAN REMOVE APPS"
Safe {
    $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
    L "WDAC/CodeIntegrity CodeIntegrityPolicyEnforcementStatus = $($dg.CodeIntegrityPolicyEnforcementStatus) (0=off,1=audit,2=enforced)"
}
Safe {
    $appLocker = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2'
    L "AppLocker policy present: $(Test-Path $appLocker)"
}
Safe {
    $enroll = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    $mdm = $false
    if (Test-Path $enroll) {
        $mdm = (Get-ChildItem $enroll -ErrorAction SilentlyContinue | Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).EnrollmentState -eq 1 }).Count -gt 0
    }
    L "MDM/Intune enrolled (heuristic): $mdm"
}
Safe {
    $sm = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
    if (-not ($sm.PSObject.Properties.Name -contains 'PendingFileRenameOperations') -or -not $sm.PendingFileRenameOperations) {
        L "No PendingFileRenameOperations queued (no reboot-time deletes pending)."
        return
    }
    $pending = @($sm.PendingFileRenameOperations) | Where-Object { $_ -match 'Claude|WindowsApps|AnthropicClaude' }
    if ($pending) {
        L "PendingFileRenameOperations targeting Claude (scheduled deletes on reboot!):"
        $pending | ForEach-Object { L "    $_" }
    } else {
        L "PendingFileRenameOperations exist but none target Claude."
    }
}

# -----------------------------------------------------------------------------
Section "8. RTL-PATCH STATE & LOGS"
$stateDir = Join-Path $env:ProgramData 'ClaudeRtlPatch'
Safe {
    if (-not (Test-Path $stateDir)) { L "State dir $stateDir does NOT exist (patch never recorded state, or it was cleaned)."; return }
    L "State dir: $stateDir"
    Get-ChildItem $stateDir -Force -ErrorAction SilentlyContinue | ForEach-Object { L ("  {0,12}  {1}" -f $_.Length, $_.Name) }

    $stateJson = Join-Path $stateDir 'state.json'
    if (Test-Path $stateJson) { L ""; L "state.json:"; (Get-Content $stateJson -Raw) -split "`n" | ForEach-Object { L "  $_" } }

    $pin = Join-Path $stateDir 'trusted-pubkey.b64'
    L ""; L "trusted-pubkey.b64 present: $(Test-Path $pin)"

    foreach ($logName in 'patch.log','watcher.log','watcher.log.old','last-action.txt') {
        $lf = Join-Path $stateDir $logName
        if (Test-Path $lf) {
            L ""; L "--- tail of $logName (last 60 lines) ---"
            Get-Content $lf -Tail 60 -ErrorAction SilentlyContinue | ForEach-Object { L "  $_" }
        }
    }
}

# -----------------------------------------------------------------------------
Section "9. WATCHER SCHEDULED TASK"
Safe {
    $t = Get-ScheduledTask -TaskName 'ClaudeRtlPatchWatcher' -ErrorAction Stop
    L "Task state: $($t.State)"
    $info = $t | Get-ScheduledTaskInfo
    L "  LastRunTime=$($info.LastRunTime)  LastTaskResult=$($info.LastTaskResult)  NextRunTime=$($info.NextRunTime)"
}
Dump-Events -LogName 'Microsoft-Windows-TaskScheduler/Operational' -Match @('ClaudeRtlPatchWatcher') -Days 45 -Show 40

# -----------------------------------------------------------------------------
Section "10. SELF-SIGNED CERT (added by the patch)"
Safe {
    foreach ($store in 'Root','My') {
        $certs = @(Get-ChildItem "Cert:\LocalMachine\$store" -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -eq 'Claude_RTL_SelfSigned' -or $_.Subject -match 'Claude-RTL-Patcher|Anthropic, PBC' })
        if ($certs.Count -eq 0) { L "  LocalMachine\$store : no patch-related cert."; continue }
        L "  LocalMachine\$store : $($certs.Count) patch/Anthropic-subject cert(s)."
        if ($store -eq 'Root' -and $certs.Count -gt 1) {
            L "    >> NOTE: more than one self-signed cert accumulated in the trusted ROOT store."
            L "    >> Each re-patch adds a new one without removing the old -- store pollution + a plausible AV trigger."
        }
        foreach ($c in $certs) { L "    Subject=$($c.Subject)  Thumb=$($c.Thumbprint)  NotAfter=$($c.NotAfter)" }
    }
}

# -----------------------------------------------------------------------------
Section "11. ADDITIONAL CONTEXT (uninstall entries / protocol / shortcuts / processes)"
Safe {
    foreach ($hive in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                      'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                      'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        Get-ItemProperty $hive -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Claude' } | ForEach-Object {
            L "  Uninstall entry: $($_.DisplayName)  v$($_.DisplayVersion)  Publisher=$($_.Publisher)"
            L "    UninstallString=$($_.UninstallString)"
        }
    }
}
Safe {
    foreach ($k in 'HKCU:\Software\Classes\claude\shell\open\command','HKLM:\Software\Classes\claude\shell\open\command') {
        if (Test-Path $k) { L "  claude:// -> $((Get-ItemProperty $k).'(default)')" }
    }
}
Safe {
    foreach ($base in (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
                      (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')) {
        Get-ChildItem $base -Recurse -Filter '*Claude*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
            $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($_.FullName)
            L "  Shortcut: $($_.Name) -> $($lnk.TargetPath) $($lnk.Arguments)"
        }
    }
}
Safe {
    $procs = Get-Process -Name claude,cowork-svc -ErrorAction SilentlyContinue
    if ($procs) { foreach ($p in $procs) { L "  Running: $($p.ProcessName) PID=$($p.Id) Path=$($p.Path)" } }
    else { L "  No claude/cowork-svc processes currently running." }
}
Safe {
    $store = Get-AppxPackage Microsoft.WindowsStore -ErrorAction SilentlyContinue
    if ($store) { L "  Microsoft Store version: $($store.Version)" }
}

# -----------------------------------------------------------------------------
[System.IO.File]::WriteAllText($out, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "Done. Log saved to: $out" -ForegroundColor Green
Write-Host "Please attach that file to the GitHub issue." -ForegroundColor Green
Write-Host "(Paths contain your Windows username but no passwords/secrets - redact if you wish.)" -ForegroundColor Gray
if (-not $isAdmin) {
    Write-Host "TIP: for the most complete report, re-run this in an elevated PowerShell (Run as administrator)." -ForegroundColor Yellow
}
