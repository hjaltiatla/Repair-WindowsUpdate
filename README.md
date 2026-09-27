# Repair-WindowsUpdate

Repair the Windows Update client **without removing its update policies**. The script rebuilds update caches, runs DISM/SFC and checks whether an update search works. It never requests update installation or an automatic reboot.

**Start with a preview, test on a non-production server, and use a maintenance window.** Services are interrupted and cache rebuilding can take time. Pause other servicing/deployment jobs first. Existing scheduled updates can resume when services recover.

## Quick start

Open **Windows PowerShell 5.1 as Administrator (64-bit)** in the script folder. Follow your organization's signing and execution policy; do not disable it just to run this script.

```powershell
# Preview: no changes, scans, log files or backups
.\Repair-WindowsUpdate.ps1 -WhatIf

# Normal repair: keep WSUS settings, update policies, identity and BITS queues
.\Repair-WindowsUpdate.ps1

# Faster repair: skip only DISM and SFC; still rebuild caches and search
.\Repair-WindowsUpdate.ps1 -SkipDeepRepair
```

The script asks for confirmation before each major operation. Review the log in `%ProgramData%\WURepair` afterward. **A normal run that includes SFC returns exit code 1 until you manually review its results**; this does not automatically mean the repair failed.

## What a normal run does

1. Checks elevation, Windows PowerShell version, Windows build and required tools.
2. Records the current update-service states, including dependent services, then stops and checks them.
3. Renames `SoftwareDistribution` and `catroot2` to unique `.bak_<timestamp>_<id>` folders. Existing backups stay intact.
4. Attempts to restore the original service states, even if repair fails.
5. Runs DISM RestoreHealth with `/NoRestart`, then SFC `/scannow`.
6. Searches the configured update source and reports the scan result separately from the repair result.

By default, it preserves **all update policies, WSUS client identity and BITS queue files**. It does not change service startup types. A failed prerequisite or service recovery blocks later steps. Earlier changes may remain if a later step fails; this is not an all-or-nothing transaction.

DISM uses the configured repair source. A failed DISM blocks SFC; exit 3010 means a manual reboot is needed and SFC is skipped. Service states are also captured/restored around servicing and the scan. Recovery attempts continue if one service fails to recover.

## Optional operations

Use these only when the operation matches the problem you are fixing. Each command still performs the normal repair workflow.

| Option | What it changes |
|---|---|
| `-RemoveWsusConfiguration` | Backs up and removes selected local WSUS routing settings. See below. |
| `-ResetWsusClientIdentity` | Backs up and removes `SusClientId` and `SusClientIdValidation`. Later registration can create a new WSUS reporting record. |
| `-ClearBitsQueue` | Permanently deletes legacy `qmgr*.dat` files from `%ProgramData%\Microsoft\Network\Downloader`. Can lose transfers for **all users and applications**. No queue backup; modern BITS database formats are not reset. |
| `-ResetWinsock` | Runs `netsh winsock reset` and checks its exit code. A successful reset requires a manual reboot and may affect networking software. No built-in rollback. |
| `-SkipDeepRepair` | Skips **only DISM/SFC**. Cache repair, selected options and the online search still run. |
| `-LogDir` | Changes the log/registry-backup directory from `%ProgramData%\WURepair`. Use a secured local folder with enough space. |
| `-WhatIf` | Runs read-only preflight and displays planned operations. No local logs, backups, external commands, service/registry/cache changes or scans. |
| `-Confirm` | Prompts for the cache/configuration operation, then selected Winsock, DISM/SFC and search steps. Recovery does not prompt again. |

```powershell
# Preview leaving WSUS
.\Repair-WindowsUpdate.ps1 -RemoveWsusConfiguration -WhatIf

# Explicitly remove local WSUS routing settings and repair
.\Repair-WindowsUpdate.ps1 -RemoveWsusConfiguration

# Other options, only when needed
.\Repair-WindowsUpdate.ps1 -ResetWsusClientIdentity
.\Repair-WindowsUpdate.ps1 -ClearBitsQueue
.\Repair-WindowsUpdate.ps1 -ResetWinsock -LogDir 'D:\Logs\WURepair'

# Suppress prompts only after reviewing the preview and impacts
.\Repair-WindowsUpdate.ps1 -SkipDeepRepair -Confirm:$false
```

Preflight also applies to preview. Normal runs create logs before confirmation prompts. Declining the cache operation stops dependent work; declining any requested operation returns 1.

## Leaving WSUS is separate from repairing Windows Update

**You do not need to leave WSUS to repair the client or use Azure Update Manager.** Azure Update Manager supports the machine's configured update source, including WSUS. Coordinate a source change with the team that owns your update policies.

Domain/local GPO, MDM or Configuration Manager can reapply settings. This script does not edit domain GPOs, local policy stores, OU links or inheritance. Preserved policies can still prevent a public-source scan.

The scan uses the configured default source. **Windows Update** supplies Windows updates; **Microsoft Update** also supplies supported Microsoft product updates. This script does not register or enable Microsoft Update.

<details>
<summary>Exactly which settings does -RemoveWsusConfiguration remove?</summary>

After a successful export of `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate`:

- In that key: `WUServer`, `WUStatusServer`, `UpdateServiceUrlAlternate`.
- In its `AU` subkey: `UseWUServer`.
- In the parent key, only when set to **1**: `DoNotConnectToWindowsUpdateInternetLocations`, `SetPolicyDrivenUpdateSourceForDriverUpdates`, `SetPolicyDrivenUpdateSourceForFeatureUpdates`, `SetPolicyDrivenUpdateSourceForQualityUpdates`, `SetPolicyDrivenUpdateSourceForOtherUpdates`. Explicit public-source selections (0) remain.

The keys and unrelated scheduling, reboot, pause and deferral values remain. So do `UseUpdateClassPolicySource`, `DisableDualScan`, access/UI restrictions and PolicyManager/MDM state. The existence of a WindowsUpdate policy key alone is not treated as evidence of WSUS. The script checks for targeted values remaining/reappearing, but cannot prove every effective source or future policy persistence.

</details>

## Read the result

The final summary separates **repair steps** from **Windows Update search**. A completed repair with a failed search means the client still needs investigation. Search ResultCode 2 is success; 3 is partial and incomplete; other codes/exceptions are unsuccessful. Service-recovery errors also count as failures, even if the search succeeded.

| Exit code | Meaning |
|---|---|
| `0` | Requested automated steps completed, or a valid preview. Not a guarantee that every update problem is fixed. |
| `1` | An operation failed/was incomplete or declined, a manual reboot is needed, or results need review. |
| `2` | Preflight or log initialization failed; repair did not start. |

**SFC needs manual review even when its native exit code is 0.** The script does not assume `1 = repaired`. Read its console/log result and the current run's `[SR]` entries in `%windir%\Logs\CBS\CBS.log`. DISM details are in `%windir%\Logs\DISM\dism.log`. Embedded NUL artifacts in captured SFC text are removed for readability; this does not interpret the result or guarantee every localized character was decoded correctly.

Failures before the script starts, such as an execution-policy block, use PowerShell's own exit behavior.

## If the scan still fails

Repeated cache resets are unlikely to fix a certificate or network problem. Keep the run log and investigate the reported error before repeating repair.

| Error/evidence | Next checks |
|---|---|
| `0x80072F8F` | Secure-connection validation failed. Check server time/time synchronization, certificate trust and proxy/TLS inspection. This code alone does **not** prove a revocation failure. |
| `0x80092013` in the exception or supporting diagnostics | Revocation status could not be checked. Inspect CAPI2 events, certificate-chain details and CRL/OCSP retrieval/cache state. It does **not** by itself prove a firewall block. |
| Partial search or other errors | Review the configured source, effective policies and Windows Update logs. A successful DISM/SFC run does not establish that scanning works. |

Useful first checks (run separately; not added to the repair workflow):

```powershell
Get-Date
w32tm.exe /query /status
netsh.exe winhttp show proxy
```

For certificate failures, capture `Microsoft-Windows-CAPI2/Operational` events during the failing scan and correlate timestamps with Windows Update logs. If you temporarily enable logging, restore its prior state afterward. A download or browser test under your account may behave differently from the update service.

The script reports guidance from the search exception and inner exceptions; it does not automatically collect CAPI2 logs or infer unseen errors. It **does not import certificates, reset trust caches or bypass certificate/revocation validation**. Review logs for hostnames and other configuration before sharing them publicly.

## Backups and recovery

Keep the run log, `services_*.xml`, registry exports and matching cache folders until the client is verified working. Filenames use a timestamp and unique run ID; old backups are not automatically deleted.

| Change | Backup and recovery |
|---|---|
| WSUS routing or identity values | A fresh parent-key `.reg` export is required before deletion. `reg.exe` must return 0 and create a nonempty file. Failed backup stops deletion. Review the export and restore only the intended values where possible. |
| Update caches | Original folders stay beside their replacements as `.bak_*`. Stop and verify the same services/dependents, preserve the new folders under different names, then rename the selected backups back. Restore service states using the XML/log. Never overwrite live caches or mix runs. |
| Service states | Recorded before cache repair. Recovery is best effort: permissions, trigger starts, concurrent activity or termination can prevent exact restoration. Address recovery errors immediately. Missing, paused or transitional services block initial cache shutdown. |
| BITS, DISM/SFC or Winsock | No built-in undo. Recreate BITS transfers through their owning applications. Registry/cache backups do not reverse servicing or Winsock changes. |

For a reviewed registry export, use an elevated maintenance session:

```powershell
reg.exe import 'D:\Logs\WURepair\selected-backup.reg'
$LASTEXITCODE  # Must be 0
```

Import merges the **whole exported tree** and can overwrite newer settings; coordinate with the policy owner. Exports do not back up ACLs or authoritative GPO/MDM configuration. Restoring an old WSUS identity can reintroduce duplicate-client problems.

**Cache backups are not a system backup.** Rebuilding SoftwareDistribution can lose displayed local update history/download state, but does not uninstall installed updates. Later servicing may make old caches unsuitable for recovery. Use your normal system recovery process when needed.

## Compatibility and validation

Intended for Windows Server 2016/2019/2022/2025. Windows 10/11 may meet the checks, but this is not a verified OS matrix. Requires elevated **64-bit Windows PowerShell 5.1**, Windows build 14393+ and the required services/native tools; PowerShell 7 is not supported.

Limited Server 2019 field evidence showed cache repair and DISM/SFC completing while the scan failed certificate revocation validation. This is not proof of a successful end-to-end repair or validation of optional operations. The latest diagnostic/logging changes still need real-server testing, including localized SFC output.

Developer validation uses PowerShell 5.1 parsing, PSScriptAnalyzer and mocked Pester tests; **no repair operations are run on the development machine**. With Pester 5.7.1+ and PSScriptAnalyzer 1.24.0+ installed:

```powershell
.\tests\Invoke-Validation.ps1
```

The runner disables Pester's optional registry sandbox. Tests cover failed backups, policy preservation, service shutdown/recovery, preview safeguards, result handling and diagnostic messages. Real-server testing remains necessary for protected services, trigger-start races, cache rollback, policy reapplication, source access and localized output.

## Microsoft references

- [Update source policies](https://learn.microsoft.com/en-us/windows/deployment/update/wufb-wsus) and [Azure Update Manager support](https://learn.microsoft.com/en-us/azure/update-manager/support-matrix).
- [DISM repair sources](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/repair-a-windows-image), [SFC](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/sfc) and [CBS log interpretation](https://learn.microsoft.com/en-us/troubleshoot/windows-client/installing-updates-features-roles/analyze-sfc-program-log-file-entries).
- [WUA result codes](https://learn.microsoft.com/en-us/windows/win32/api/wuapi/ne-wuapi-operationresultcode), [WinHTTP errors](https://learn.microsoft.com/en-us/windows/win32/winhttp/error-messages) and [certificate error codes](https://learn.microsoft.com/en-us/windows/win32/com/com-error-codes-4).
- [Registry export](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/reg-export) and [service dependencies](https://learn.microsoft.com/en-us/powershell/scripting/samples/managing-services).

## License

MIT. Provided as-is, without warranty.
