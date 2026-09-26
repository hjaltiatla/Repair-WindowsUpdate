#Requires -Version 5.1
<#
.SYNOPSIS
    Repairs the Windows Update client; preserves update policies by default.
.DESCRIPTION
    Stops update services, preserves timestamped cache folders, restores service
    states, optionally runs DISM/SFC, and searches the configured update source.
    Never installs updates or reboots. See README.md for recovery limitations.
.PARAMETER RemoveWsusConfiguration
    Back up and remove only the documented WSUS routing values listed in README.
.PARAMETER ClearBitsQueue
    Delete legacy qmgr*.dat files; affects BITS jobs for all applications/users.
.PARAMETER ResetWsusClientIdentity
    Back up and delete SusClientId and SusClientIdValidation.
.PARAMETER SkipDeepRepair
    Skip only DISM and SFC; cache repair and the online search still run.
.PARAMETER ResetWinsock
    Run netsh winsock reset. A manual reboot is required after success.
.PARAMETER LogDir
    Local directory for unique run logs and registry exports; default ProgramData\WURepair.
    WhatIf creates no logs, directories or backups.
.EXAMPLE
    .\Repair-WindowsUpdate.ps1 -WhatIf
.EXAMPLE
    .\Repair-WindowsUpdate.ps1 -RemoveWsusConfiguration -SkipDeepRepair
.NOTES
    Requires elevated, 64-bit Windows PowerShell 5.1 on Windows build 14393+.
    Exit: 0 completed/preview; 1 failed, declined or needs review; 2 fatal preflight.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal helpers run only inside the script-level ShouldProcess transaction; recovery must not prompt again.')]
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$SkipDeepRepair,
    [switch]$ResetWinsock,
    [string]$LogDir = "$env:ProgramData\WURepair",
    [switch]$RemoveWsusConfiguration,
    [switch]$ClearBitsQueue,
    [switch]$ResetWsusClientIdentity
)

$ErrorActionPreference = 'Stop'
$script:ErrorCount = 0
$script:Warnings = 0
$script:NeedsReview = $false
$script:LogFile = $null
$script:stamp = (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N')
$WuPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$AuPolicyKey = "$WuPolicyKey\AU"
$idKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate'

# ---------------------------------------------------------------- logging ----
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO')
    if ($Level -eq 'ERROR') { $script:ErrorCount++ }
    if ($Level -eq 'WARN') { $script:Warnings++ }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Information $line -InformationAction Continue
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop }
        catch {
            # Logging must never interrupt the remaining service recovery attempts.
            $script:ErrorCount++
            Write-Warning "Log write failed: $($_.Exception.Message)"
        }
    }
}
function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    Write-Log "--- $Name ---"
    try { & $Action }
    catch { Write-Log "$Name : FAILED - $($_.Exception.Message)" 'ERROR' }
}
function Invoke-Native {
    param([string]$File, [string[]]$Arguments)
    & (Join-Path "$env:SystemRoot\System32" $File) @Arguments 2>&1 | ForEach-Object { Write-Log "$_" }
    $code = $LASTEXITCODE
    Write-Log "$File exit code: $code"
    return $code
}
function Assert-Requirement {
    if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSEdition -ne 'Desktop' -or
        $PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess) {
        throw 'Use 64-bit Windows PowerShell 5.1 on Windows.'
    }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run from an elevated Administrator prompt.'
    }
    $os = Get-CimInstance Win32_OperatingSystem
    if ([int]$os.BuildNumber -lt 14393) { throw 'Requires Windows build 14393 or newer.' }
    foreach ($file in @('reg.exe','netsh.exe','dism.exe','sfc.exe')) {
        if (-not (Test-Path -LiteralPath "$env:SystemRoot\System32\$file")) { throw "Missing $file" }
    }
    Write-Log "Host: $env:COMPUTERNAME; $($os.Caption); build $($os.BuildNumber)"
}

# ------------------------------------------- 1/2. selective WSUS configuration --
function Get-WsusValue {
    $names = @('WUServer','WUStatusServer','UpdateServiceUrlAlternate','DoNotConnectToWindowsUpdateInternetLocations',
        'SetPolicyDrivenUpdateSourceForDriverUpdates','SetPolicyDrivenUpdateSourceForFeatureUpdates',
        'SetPolicyDrivenUpdateSourceForQualityUpdates','SetPolicyDrivenUpdateSourceForOtherUpdates')
    foreach ($path in @($WuPolicyKey, $AuPolicyKey)) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-ItemProperty -LiteralPath $path
            $selected = $names
            if ($path -eq $AuPolicyKey) { $selected = @('UseWUServer') }
            foreach ($name in $selected) {
                $property = $item.PSObject.Properties[$name]
                if ($null -ne $property) {
                    # Preserve explicit Windows Update source selections and disabled restrictions.
                    if (($name -like 'SetPolicyDriven*' -or $name -eq 'DoNotConnectToWindowsUpdateInternetLocations') -and
                        $property.Value -ne 1) { continue }
                    [pscustomobject]@{ Path = $path; Name = $name; Value = $property.Value }
                }
            }
        }
    }
}
function Backup-Registry {
    param([string]$Path, [string]$Label)
    $file = Join-Path $LogDir "$($Label)_$script:stamp.reg"
    if (Test-Path -LiteralPath $file) { throw "Backup already exists: $file" }
    $code = Invoke-Native 'reg.exe' @('export', ($Path -replace '^HKLM:', 'HKLM'), $file)
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Registry export failed ($code): $Path. No registry changes authorized."
    }
    if ((Get-Item -LiteralPath $file).Length -eq 0) { throw "Empty registry backup: $file" }
    Write-Log "Registry backup: $file"
}
function Remove-WsusValue {
    $values = @(Get-WsusValue)
    if ($values.Count -eq 0) { Write-Log 'No targeted WSUS routing values found.'; return }
    Backup-Registry $WuPolicyKey 'WUPolicy_backup'
    foreach ($value in $values) {
        Remove-ItemProperty -LiteralPath $value.Path -Name $value.Name -ErrorAction Stop -Confirm:$false
        Write-Log "Removed $($value.Path)\$($value.Name) (was $($value.Value))"
    }
}
function Reset-ClientIdentity {
    if (-not (Test-Path -LiteralPath $idKey)) { return }
    $item = Get-ItemProperty -LiteralPath $idKey
    $names = @('SusClientId','SusClientIdValidation') | Where-Object { $null -ne $item.PSObject.Properties[$_] }
    if ($names) {
        Backup-Registry $idKey 'WUIdentity_backup'
        foreach ($name in $names) { Remove-ItemProperty -LiteralPath $idKey -Name $name -Confirm:$false -ErrorAction Stop }
    }
}

# ------------------------------------------------------ 3/8. service recovery --
function Get-ServiceSnapshot {
    param([string[]]$Names)
    $seen = @{}
    $ordered = New-Object System.Collections.ArrayList
    function Add-ServiceTree {
        param([string]$Name)
        if ($seen.ContainsKey($Name)) { return }
        $seen[$Name] = $true
        $svc = Get-Service -Name $Name -ErrorAction Stop
        if ([string]$svc.Status -notin @('Running','Stopped')) { throw "Service $Name is $($svc.Status); resolve before repair." }
        # Parent first; dependencies stopped by -Force are captured recursively.
        [void]$ordered.Add([pscustomobject]@{ Name = $Name; Status = [string]$svc.Status })
        foreach ($dependent in $svc.DependentServices) { Add-ServiceTree $dependent.Name }
    }
    foreach ($name in $Names) { Add-ServiceTree $name }
    return $ordered.ToArray()
}
function Wait-ServiceState {
    param([string]$Name, [string]$State)
    $svc = Get-Service -Name $Name -ErrorAction Stop
    $svc.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]$State, [TimeSpan]::FromSeconds(30))
    $svc.Refresh()
    if ([string]$svc.Status -ne $State) { throw "$Name did not reach $State" }
}
function Stop-RepairService {
    param([object[]]$Snapshot)
    foreach ($entry in $Snapshot) {
        Stop-Service -Name $entry.Name -Force -ErrorAction Stop -Confirm:$false
        Wait-ServiceState $entry.Name 'Stopped'
    }
    Assert-ServicesStopped $Snapshot
}
function Assert-ServicesStopped {
    param([object[]]$Snapshot)
    foreach ($entry in $Snapshot) {
        if ((Get-Service -Name $entry.Name -ErrorAction Stop).Status -ne 'Stopped') {
            throw "Service $($entry.Name) is not stopped; dependent mutations blocked."
        }
    }
}
function Restore-ServiceSnapshot {
    param([object[]]$Snapshot)
    # Stop originally stopped services without Force: never silently stop new dependents.
    for ($i = $Snapshot.Count - 1; $i -ge 0; $i--) {
        $entry = $Snapshot[$i]
        if ($entry.Status -eq 'Stopped') {
            try {
                Stop-Service -Name $entry.Name -ErrorAction Stop -Confirm:$false
                Wait-ServiceState $entry.Name 'Stopped'
            } catch { Write-Log "Restore $($entry.Name): $($_.Exception.Message)" 'ERROR' }
        }
    }
    foreach ($entry in $Snapshot) {
        if ($entry.Status -eq 'Running') {
            try {
                Start-Service -Name $entry.Name -ErrorAction Stop -Confirm:$false
                Wait-ServiceState $entry.Name 'Running'
            } catch { Write-Log "Restore $($entry.Name): $($_.Exception.Message)" 'ERROR' }
        }
    }
}

# ------------------------------------------------ 4/5. queue and cache repair --
function Clear-LegacyBitsQueue {
    $qmgr = Join-Path $env:ProgramData 'Microsoft\Network\Downloader'
    if (Test-Path -LiteralPath $qmgr) {
        Get-ChildItem -LiteralPath $qmgr -Filter 'qmgr*.dat' -File |
            Remove-Item -Force -Confirm:$false -ErrorAction Stop
    }
    Write-Log 'Legacy BITS queue files deleted; modern BITS database formats are not reset.'
}
function Rename-UpdateCache {
    param([object[]]$Snapshot)
    foreach ($path in @("$env:SystemRoot\SoftwareDistribution", "$env:SystemRoot\System32\catroot2")) {
        Assert-ServicesStopped $Snapshot
        if (Test-Path -LiteralPath $path) {
            $new = (Split-Path $path -Leaf) + ".bak_$script:stamp"
            Rename-Item -LiteralPath $path -NewName $new -Confirm:$false -ErrorAction Stop
            Write-Log "Cache backup: $path -> $new"
        }
    }
}
function Invoke-CacheRepair {
    $snapshot = @(Get-ServiceSnapshot @('wuauserv','bits','cryptsvc','UsoSvc'))
    $snapshot | Export-Clixml -LiteralPath (Join-Path $LogDir "services_$script:stamp.xml") -Confirm:$false
    try {
        Stop-RepairService $snapshot
        if ($RemoveWsusConfiguration) { Remove-WsusValue }
        if ($ResetWsusClientIdentity) { Assert-ServicesStopped $snapshot; Reset-ClientIdentity }
        if ($ClearBitsQueue) { Assert-ServicesStopped $snapshot; Clear-LegacyBitsQueue }
        Rename-UpdateCache $snapshot
    } finally { Restore-ServiceSnapshot $snapshot }
}

# --------------------------------------------------------- 9. DISM and SFC --
function Invoke-DeepRepair {
    $code = Invoke-Native 'dism.exe' @('/Online','/Cleanup-Image','/RestoreHealth','/NoRestart')
    if ($code -notin @(0,3010)) { throw "DISM failed ($code); SFC skipped. See $env:SystemRoot\Logs\DISM\dism.log" }
    if ($code -eq 3010) { $script:NeedsReview = $true; Write-Log 'DISM requires a manual reboot.' 'WARN'; return }
    $code = Invoke-Native 'sfc.exe' @('/scannow')
    # Microsoft documents console messages and CBS [SR] entries, not a reliable
    # 0=clean / 1=repaired contract. Even exit 0 requires human result review.
    $script:NeedsReview = $true
    Write-Log "SFC returned $code; result unverified. Review console output and this run's [SR] entries in $env:SystemRoot\Logs\CBS\CBS.log." 'WARN'
    if ($code -ne 0) { throw "SFC returned nonzero ($code); not interpreted as repaired." }
}

# ----------------------------------------------- 10. verify + trigger scan --
function Invoke-UpdateSearch {
    $session = $null
    $searcher = $null
    $result = $null
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $searcher.Online = $true
        $searcher.ServerSelection = 0 # ssDefault: honors configured update source.
        $result = $searcher.Search('IsInstalled=0 and IsHidden=0')
        $code = [int]$result.ResultCode
        if ($code -eq 3) { throw 'Update search partially succeeded; results may be incomplete (ResultCode 3).' }
        if ($code -ne 2) { throw "Update search failed/incomplete (ResultCode $code)." }
        Write-Log "Search succeeded: $($result.Updates.Count) applicable update(s). No download/install requested." 'OK'
    } finally {
        foreach ($com in @($result,$searcher,$session)) {
            if ($null -ne $com -and [Runtime.InteropServices.Marshal]::IsComObject($com)) {
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($com)
            }
        }
    }
}

# ---------------------------------------------------------------- workflow --
try {
    Assert-Requirement
    if (-not $WhatIfPreference) {
        $null = New-Item -ItemType Directory -Path $LogDir -Force -Confirm:$false
        $script:LogFile = Join-Path $LogDir "WURepair_$($env:COMPUTERNAME)_$script:stamp.log"
        New-Item -ItemType File -Path $script:LogFile -ErrorAction Stop -Confirm:$false | Out-Null
    }
} catch { Write-Log "Preflight failed: $($_.Exception.Message)" 'ERROR'; exit 2 }
Write-Log "Options: RemoveWsusConfiguration=$RemoveWsusConfiguration ClearBitsQueue=$ClearBitsQueue ResetWsusClientIdentity=$ResetWsusClientIdentity SkipDeepRepair=$SkipDeepRepair ResetWinsock=$ResetWinsock"
if ($WhatIfPreference) { Write-Log 'Preview only: no logs, backups, scans, commands or changes are made.' }
if ($RemoveWsusConfiguration) {
    Write-Log 'Managed GPO/MDM/Configuration Manager settings can reapply. Change only the relevant source policies through their owner; this script never edits domain GPOs or MDM.' 'WARN'
}
$description = 'Stop update services and dependents, rename update caches, then restore original service states'
if ($RemoveWsusConfiguration) { $description += '; back up and remove targeted WSUS routing values' }
if ($ClearBitsQueue) { $description += '; permanently delete legacy BITS queues for all users' }
if ($ResetWsusClientIdentity) { $description += '; back up and reset WSUS client identity' }
if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, $description)) {
    Invoke-Step 'Steps 1-8: Cache repair and requested configuration changes' { Invoke-CacheRepair }
} elseif (-not $WhatIfPreference) { Write-Log 'Repair declined; dependent operations skipped.' 'WARN'; exit 1 }

# No further repair or scan after a failed prerequisite/recovery.
if ($script:ErrorCount -eq 0) {
    if ($ResetWinsock -and $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Reset Winsock catalog (manual reboot required)')) {
        Invoke-Step 'Step 7: Winsock reset' {
            $code = Invoke-Native 'netsh.exe' @('winsock','reset')
            if ($code -ne 0) { throw "netsh failed ($code)" }
            $script:NeedsReview = $true
            Write-Log 'Winsock reset succeeded; manual reboot required.' 'WARN'
        }
    } elseif ($ResetWinsock -and -not $WhatIfPreference) { $script:NeedsReview = $true }
    if (-not $SkipDeepRepair -and $script:ErrorCount -eq 0) {
        if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Run DISM RestoreHealth /NoRestart and SFC scannow')) {
            Invoke-Step 'Step 9: DISM/SFC' {
                $deepSnapshot = @(Get-ServiceSnapshot @('wuauserv','bits','cryptsvc','UsoSvc'))
                try { Invoke-DeepRepair } finally { Restore-ServiceSnapshot $deepSnapshot }
            }
        } elseif (-not $WhatIfPreference) { $script:NeedsReview = $true }
    }
    if ($script:ErrorCount -eq 0 -and $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Online Windows Update search using configured source')) {
        Invoke-Step 'Step 10: Verify configuration and search' {
            if ($RemoveWsusConfiguration -and @(Get-WsusValue).Count -gt 0) {
                $script:NeedsReview = $true
                Write-Log 'Targeted WSUS values remain/reappeared; review effective managed policies.' 'WARN'
            }
            # Search/servicing can trigger services. Restore those states as well.
            $scanSnapshot = @(Get-ServiceSnapshot @('wuauserv','bits','cryptsvc','UsoSvc'))
            try { Invoke-UpdateSearch } finally { Restore-ServiceSnapshot $scanSnapshot }
        }
    } elseif (-not $WhatIfPreference) { $script:NeedsReview = $true }
}
Write-Log "=== Finished: errors=$script:ErrorCount warnings=$script:Warnings reviewRequired=$script:NeedsReview ==="
if ($script:ErrorCount -gt 0 -or $script:NeedsReview) { exit 1 }
exit 0
