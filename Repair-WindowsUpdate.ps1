#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Repairs a broken Windows Update client on Windows Server 2016 / 2019 / 2022.
    Headless - no GUI. Designed for servers moving off a decommissioned WSUS
    toward Azure Update Manager (native WU client scanning Microsoft Update).

.DESCRIPTION
    Steps (in order - order matters):
      1. Backup + log current WSUS/WU policy registry state to a .reg-style dump
      2. Remove WSUS policy registry keys (WUServer, UseWUServer, etc.)
      3. Stop update services (wuauserv, BITS, cryptsvc, UsoSvc)
      4. Delete BITS queue files (qmgr*.dat)
      5. Rename SoftwareDistribution and catroot2 (rename, not delete - reversible)
      6. Reset WSUS client identity (SusClientId) - fixes cloned-VM duplicates
      7. Restart services
      8. DISM /RestoreHealth + SFC /scannow (runs AFTER WSUS removal so DISM
         can reach Microsoft Update as its repair source)
      9. Trigger an update scan via the WU COM API (works on 2016-2022)
     10. Summary with real error counting and meaningful exit code

    NOT included on purpose:
      - No sc.exe sdset (stamping hardcoded SDDLs across OS versions is riskier
        than the problem it solves)
      - No regsvr32 DLL loop (does nothing useful on Server 2016+)
      - No winsock reset by default (breaks VPN/proxy LSPs; use -ResetWinsock
        only if scans fail with network-side 0x8024402c / 0x80072ee2 errors)

.PARAMETER SkipDeepRepair
    Skip DISM/SFC. Default is to run them (15-45 min per server).

.PARAMETER ResetWinsock
    Also run 'netsh winsock reset'. Requires a reboot to take effect.

.PARAMETER LogDir
    Log directory. Default: C:\ProgramData\WURepair

.EXAMPLE
    .\Repair-WindowsUpdate.ps1
    .\Repair-WindowsUpdate.ps1 -SkipDeepRepair
    .\Repair-WindowsUpdate.ps1 -ResetWinsock

.NOTES
    IMPORTANT - GPO: if the WSUS settings came from a domain GPO that is still
    linked, they will reapply at the next policy refresh (~90 min). Unlink or
    edit the GPO first, or move these servers to an OU with policy inheritance
    blocked. This script detects and warns if the policy key repopulates.

    Exit codes: 0 = success, 1 = completed with errors, 2 = fatal error.
    A reboot after running is recommended (required if -ResetWinsock).
#>
[CmdletBinding()]
param(
    [switch]$SkipDeepRepair,
    [switch]$ResetWinsock,
    [string]$LogDir = 'C:\ProgramData\WURepair'
)

$ErrorActionPreference = 'Stop'
$script:ErrorCount = 0
$script:Warnings   = 0

# ---------------------------------------------------------------- logging ----
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile = Join-Path $LogDir "WURepair_$($env:COMPUTERNAME)_$stamp.log"

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO')
    $line = "{0} [{1,-5}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red;    $script:ErrorCount++ }
        'WARN'  { Write-Host $line -ForegroundColor Yellow; $script:Warnings++ }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    Write-Log "--- $Name ---"
    try { & $Action; Write-Log "$Name : done" 'OK' }
    catch { Write-Log "$Name : FAILED - $($_.Exception.Message)" 'ERROR' }
}

$os = (Get-CimInstance Win32_OperatingSystem).Caption
Write-Log "=== Windows Update repair started on $env:COMPUTERNAME ($os) ==="
Write-Log "Log file: $LogFile"
Write-Log "Options: SkipDeepRepair=$SkipDeepRepair ResetWinsock=$ResetWinsock"

# ------------------------------------------- 1. backup current policy state --
$WuPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$AuPolicyKey = "$WuPolicyKey\AU"
$BackupFile  = Join-Path $LogDir "WUPolicy_backup_$($env:COMPUTERNAME)_$stamp.reg"

Invoke-Step 'Step 1: Backup current WSUS/WU policy registry state' {
    if (Test-Path $WuPolicyKey) {
        $null = reg.exe export 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' $BackupFile /y 2>&1
        Write-Log "  Policy key exported to: $BackupFile"
        # Log the values we're about to remove so the log tells the whole story
        foreach ($k in @($WuPolicyKey, $AuPolicyKey)) {
            if (Test-Path $k) {
                (Get-Item $k).Property | ForEach-Object {
                    $v = (Get-ItemProperty -Path $k -Name $_).$_
                    Write-Log ("  Current: {0}\{1} = {2}" -f $k, $_, $v)
                }
            }
        }
    } else {
        Write-Log '  No WU policy key present - nothing to back up.'
    }
}

# --------------------------------------------- 2. remove WSUS policy config --
Invoke-Step 'Step 2: Remove WSUS policy registry keys' {
    if (Test-Path $WuPolicyKey) {
        Remove-Item -Path $WuPolicyKey -Recurse -Force
        Write-Log "  Deleted: $WuPolicyKey (incl. AU subkey)"
    } else {
        Write-Log '  Policy key not present - already clean.'
    }
    # Clear a paused/deferred state pushed via MDM/PolicyManager, if any
    $pmKey = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update'
    if (Test-Path $pmKey) {
        $pausedProps = (Get-Item $pmKey).Property | Where-Object { $_ -like 'Pause*' }
        foreach ($p in $pausedProps) {
            Remove-ItemProperty -Path $pmKey -Name $p -ErrorAction SilentlyContinue
            Write-Log "  Cleared PolicyManager value: $p"
        }
    }
    Write-Log '  NOTE: if the WSUS GPO is still linked in AD, these keys WILL' 'WARN'
    Write-Log '  come back at the next policy refresh. Unlink the GPO.' 'WARN'
}

# ------------------------------------------------------ 3. stop WU services --
$Services = @('wuauserv','bits','cryptsvc','UsoSvc') |
    Where-Object { Get-Service -Name $_ -ErrorAction SilentlyContinue }

Invoke-Step 'Step 3: Stop update services' {
    foreach ($svc in $Services) {
        Stop-Service -Name $svc -Force -ErrorAction Stop
        Write-Log "  Stopped: $svc"
    }
    # Give handles a moment to release before touching the folders
    Start-Sleep -Seconds 5
}

# ------------------------------------------------- 4. clear BITS queue data --
Invoke-Step 'Step 4: Delete BITS queue files' {
    $qmgr = Join-Path $env:ProgramData 'Microsoft\Network\Downloader'
    if (Test-Path $qmgr) {
        Get-ChildItem -Path $qmgr -Filter 'qmgr*.dat' -ErrorAction SilentlyContinue |
            Remove-Item -Force
        Write-Log "  Cleared qmgr*.dat in $qmgr"
    } else {
        Write-Log '  Downloader folder not found - skipping.'
    }
}

# ------------------------------- 5. rename SoftwareDistribution + catroot2 --
Invoke-Step 'Step 5: Rename SoftwareDistribution and catroot2' {
    $targets = @(
        @{ Path = "$env:SystemRoot\SoftwareDistribution"; New = "SoftwareDistribution.bak_$stamp" },
        @{ Path = "$env:SystemRoot\System32\catroot2";    New = "catroot2.bak_$stamp" }
    )
    foreach ($t in $targets) {
        if (Test-Path $t.Path) {
            Rename-Item -Path $t.Path -NewName $t.New -Force
            Write-Log "  Renamed: $($t.Path) -> $($t.New)"
        } else {
            Write-Log "  Not found (already reset?): $($t.Path)"
        }
    }
    Write-Log '  Old folders kept as .bak - delete them manually once WU is confirmed working.'
}

# ------------------------------------------- 6. reset WSUS client identity --
Invoke-Step 'Step 6: Reset WSUS client identity (SusClientId)' {
    $idKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate'
    foreach ($name in @('SusClientId','SusClientIdValidation','PingID','AccountDomainSid')) {
        if (Get-ItemProperty -Path $idKey -Name $name -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $idKey -Name $name
            Write-Log "  Removed: $name"
        }
    }
}

# ---------------------------------------------------- 7. winsock (optional) --
if ($ResetWinsock) {
    Invoke-Step 'Step 7: Winsock reset (requested)' {
        $out = netsh winsock reset 2>&1
        Write-Log "  $($out -join ' ')"
        Write-Log '  Winsock reset requires a REBOOT to take effect.' 'WARN'
    }
} else {
    Write-Log 'Step 7: Winsock reset - skipped (use -ResetWinsock if scans fail with network errors)'
}

# -------------------------------------------------------- 8. start services --
Invoke-Step 'Step 8: Start update services' {
    foreach ($svc in $Services) {
        Start-Service -Name $svc -ErrorAction Stop
        Write-Log "  Started: $svc"
    }
}

# --------------------------------------------------------- 9. DISM and SFC --
if (-not $SkipDeepRepair) {
    Invoke-Step 'Step 9a: DISM component store repair (can take 15-45 min)' {
        # Runs AFTER WSUS removal + service restart so DISM can pull its
        # repair source from Microsoft Update instead of the dead WSUS.
        $dism = Start-Process -FilePath dism.exe `
            -ArgumentList '/Online','/Cleanup-Image','/RestoreHealth' `
            -Wait -PassThru -NoNewWindow
        if ($dism.ExitCode -ne 0) {
            throw "DISM exited with code $($dism.ExitCode). See C:\Windows\Logs\DISM\dism.log"
        }
        Write-Log '  DISM RestoreHealth completed (exit 0).'
    }
    Invoke-Step 'Step 9b: SFC system file check (can take 10-20 min)' {
        $sfc = Start-Process -FilePath "$env:SystemRoot\System32\sfc.exe" `
            -ArgumentList '/scannow' -Wait -PassThru -NoNewWindow
        # SFC exit codes: 0 = no violations, 1 = repaired, others = problems
        switch ($sfc.ExitCode) {
            0       { Write-Log '  SFC: no integrity violations.' }
            1       { Write-Log '  SFC: violations found and repaired.' }
            default { throw "SFC exited with code $($sfc.ExitCode). See C:\Windows\Logs\CBS\CBS.log" }
        }
    }
} else {
    Write-Log 'Step 9: DISM/SFC - skipped (-SkipDeepRepair)'
}

# ----------------------------------------------- 10. verify + trigger scan --
Invoke-Step 'Step 10: Verify config and trigger update scan' {
    # Confirm the policy key hasn't already been re-stamped by GPO
    if (Test-Path $WuPolicyKey) {
        Write-Log '  WU policy key ALREADY REPOPULATED - a GPO is still applying' 'WARN'
        Write-Log '  WSUS settings. Fix the GPO or this repair will not stick.' 'WARN'
    } else {
        Write-Log '  Policy key clean - client will scan against Microsoft Update.'
    }

    # COM API scan - reliable across Server 2016-2022, unlike USOClient verbs
    Write-Log '  Starting online scan via Windows Update Agent COM API...'
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searcher.Online = $true
    $result = $searcher.Search("IsInstalled=0 and IsHidden=0")
    Write-Log ("  Scan OK - {0} applicable update(s) found." -f $result.Updates.Count)
    for ($i = 0; $i -lt [Math]::Min($result.Updates.Count, 15); $i++) {
        Write-Log ("    - {0}" -f $result.Updates.Item($i).Title)
    }
    if ($result.Updates.Count -gt 15) {
        Write-Log ("    ... and {0} more (see Windows Update in Settings)" -f ($result.Updates.Count - 15))
    }
}

# ------------------------------------------------------------------ summary --
Write-Log '=== Repair finished ==='
Write-Log ("Errors: {0}   Warnings: {1}" -f $script:ErrorCount, $script:Warnings)
Write-Log "Policy backup: $BackupFile"
Write-Log "Full log:      $LogFile"
if ($ResetWinsock) { Write-Log 'REBOOT REQUIRED (winsock reset).' 'WARN' }
else               { Write-Log 'A reboot is recommended before onboarding to Azure Update Manager.' }

if ($script:ErrorCount -gt 0) {
    Write-Log 'Completed WITH ERRORS - review the log before trusting this server.' 'ERROR'
    exit 1
}
Write-Log 'Completed successfully.' 'OK'
exit 0
