# Repair-WindowsUpdate

Repairs a Windows Update client while preserving update policies by default. Intended for Windows Server 2016, 2019, 2022 and 2025; Windows 10/11 may also meet the execution checks. This is intended compatibility, not a tested OS matrix. The original script has been used successfully at work; the hardened version still requires real-server validation.

Test on a non-production server first and use a maintenance window. Stop other servicing/deployment jobs before running. Service interruption, cache rebuilding and DISM/SFC can take considerable time. The script never requests update installation or an automatic reboot. Existing scheduled update activity remains governed by your policies and can resume when services recover.

## What it does

1. Checks elevation, 64-bit Windows PowerShell 5.1, Windows build 14393+ and required native tools; creates a unique log.
2. Records the states of wuauserv, BITS, cryptsvc, UsoSvc and their recursive dependent services. Missing services or transitional/paused states abort the cache operation before shutdown.
3. Stops those services and verifies they stopped. Failure blocks registry changes, queue deletion and cache renames.
4. Performs only explicitly requested WSUS removal, identity reset or legacy BITS queue deletion.
5. Renames SoftwareDistribution and catroot2 to unique timestamped `.bak_*` siblings. Existing backups are never overwritten.
6. Attempts service recovery in `finally`, including dependents stopped by `Stop-Service -Force`. Each recovery attempt has its own error handling. Originally stopped services are not deliberately started by cache recovery; startup types are unchanged.
7. Optionally resets Winsock; runs DISM `/Online /Cleanup-Image /RestoreHealth /NoRestart`, then SFC `/scannow` unless `-SkipDeepRepair` is supplied. A failed DISM blocks SFC. DISM uses the configured repair source; WSUS removal does not guarantee access to repair content.
8. Performs an online Windows Update Agent search using the configured default source. Only ResultCode 2 is successful; 3 is partial/incomplete, and all other results are unsuccessful. It does not download or install the found updates.

A failed repair prerequisite or service recovery blocks later repair/search steps. Operations are not transactional: an earlier rename or value deletion may already have succeeded when a later operation fails. Review the log and backups.

## Usage

Run in **elevated 64-bit Windows PowerShell 5.1**. Follow your organization's signing/execution policy.

```powershell
# Preview everything requested: no files, logs, backups, scans or changes
.\Repair-WindowsUpdate.ps1 -WhatIf
.\Repair-WindowsUpdate.ps1 -RemoveWsusConfiguration -ResetWsusClientIdentity -ClearBitsQueue -ResetWinsock -WhatIf

# Normal repair; preserves policies, identity and BITS queue files
.\Repair-WindowsUpdate.ps1

# Skip ONLY DISM/SFC; still repairs caches/services and performs online search
.\Repair-WindowsUpdate.ps1 -SkipDeepRepair

# Explicitly leave WSUS configuration locally, as well as repairing the client
.\Repair-WindowsUpdate.ps1 -RemoveWsusConfiguration

# Individually optional, disruptive operations
.\Repair-WindowsUpdate.ps1 -ResetWsusClientIdentity
.\Repair-WindowsUpdate.ps1 -ClearBitsQueue
.\Repair-WindowsUpdate.ps1 -ResetWinsock -LogDir 'D:\Logs\WURepair'

# Unattended, after reviewing preview and impacts
.\Repair-WindowsUpdate.ps1 -SkipDeepRepair -Confirm:$false
```

## Parameters

| Parameter | Default | Impact |
|---|---|---|
| `-RemoveWsusConfiguration` | off | Exports the policy tree, then removes only the routing values listed below |
| `-ClearBitsQueue` | off | Permanently deletes legacy `qmgr*.dat` from `%ProgramData%\Microsoft\Network\Downloader`; can lose pending BITS transfers for all users/applications, not just Windows Update. No queue backup; modern BITS database formats are not reset |
| `-ResetWsusClientIdentity` | off | Exports the client key, then removes only `SusClientId` and `SusClientIdValidation`; subsequent WSUS registration can create a new identity/reporting record |
| `-SkipDeepRepair` | off | Skips only DISM/SFC; all other selected operations and search remain enabled |
| `-ResetWinsock` | off | Runs `netsh winsock reset`, checks its exit code; successful reset requires a manual reboot and may affect networking software. No automatic rollback |
| `-LogDir` | `%ProgramData%\WURepair` | Directory for unique run log, service-state XML and required `.reg` exports. Choose a secured local directory with adequate free space; logs/exports contain machine configuration |
| `-WhatIf` | off | Read-only preflight plus planned-operation messages; no local preview logs/directories, native tools, service changes, registry edits, cache changes or COM searches |
| `-Confirm` | high-impact prompts | Approves the cache/configuration transaction as a unit, then Winsock, DISM/SFC and search separately. Recovery is part of the approved transaction and is not prompted again. `-Confirm:$false` suppresses prompts |

Preflight also applies to preview. A normal run creates local logs before approval prompts. Declining the cache transaction skips dependent work and returns 1; declining later operations also returns 1.

## Optional WSUS removal

Repair does **not** require leaving WSUS. `-RemoveWsusConfiguration` removes these existing values only:

- Under `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate`: `WUServer`, `WUStatusServer`, `UpdateServiceUrlAlternate`.
- Under its `AU` subkey: `UseWUServer`.
- In the WindowsUpdate key, `DoNotConnectToWindowsUpdateInternetLocations` and `SetPolicyDrivenUpdateSourceForDriverUpdates`, `SetPolicyDrivenUpdateSourceForFeatureUpdates`, `SetPolicyDrivenUpdateSourceForQualityUpdates`, `SetPolicyDrivenUpdateSourceForOtherUpdates` **only when their value is 1** (restriction/WSUS selection). Explicit Windows Update selections (0) remain.

It preserves the keys themselves and all other values, including scheduling, reboot, deferral, pause, `UseUpdateClassPolicySource`, `DisableDualScan`, access/UI restrictions and PolicyManager/MDM state. Conflicting preserved policies or management agents can still prevent public-source scanning; resolve them through their policy owner. A WindowsUpdate key's existence alone is never reported as proof of WSUS. The script checks the targeted values after removal, but cannot prove future policy persistence or every effective MDM source.

Domain/local GPO, MDM and Configuration Manager can reapply settings. Have the policy owner change only the relevant update-source policies before migration. The script does not edit domain GPOs, local policy stores, OU links or inheritance.

The search honors the configured source. **Windows Update** supplies Windows updates; **Microsoft Update** additionally supplies supported Microsoft product updates. This script does not register or enable Microsoft Update. Azure Update Manager honors the machine's update source and supports WSUS; removing WSUS is not inherently required to use it.

## Backups and recovery

- Every registry mutation requires a fresh export of its parent tree. `reg.exe` must return 0 and the export must exist and be nonempty. Failure aborts the affected transaction before deletion; no blanket policy deletion occurs. An export covers values/subkeys, not ACLs or the authoritative GPO/MDM configuration.
- Logs and `.reg`/service XML filenames include a timestamp and unique run identifier. Cache folders use the same suffix. Keep these until the client is verified working; the script never deletes old cache backups.
- To restore registry settings, review the export and current policy first. In an elevated maintenance session, use `reg.exe import "D:\Logs\WURepair\<selected-backup>.reg"` and check `$LASTEXITCODE`. Import merges the **entire exported tree**, potentially overwriting newer values; preferably restore only the intended values from a reviewed copy. Coordinate with the management-policy owner.
- To attempt cache rollback, stop the same services and dependents and verify they stopped. Preserve any newly generated cache directories under different names, rename the selected `.bak_*` directories back, and restore original service states using the XML/log as a reference. Do not overwrite live caches or combine backups from different runs. Partial renames are possible.
- Cache backups are **not a system rollback**: rebuilding SoftwareDistribution can discard displayed local update history and download state; installed updates are not uninstalled. Later servicing can make old cache data unsuitable. Use your normal system backup/recovery procedure if necessary.
- BITS queue deletion has no built-in undo; recreate transfers through their owning applications. Restoring an old WSUS identity can reintroduce duplicate-client problems. DISM/SFC and Winsock changes are not reversed by importing a `.reg` file or restoring caches.
- Recovery is best effort. Service permissions, trigger starts, new dependents, concurrent management activity, process termination or power loss can prevent exact state restoration. Review any recovery errors immediately. No startup types are modified. The update-service states are also captured/restored around DISM/SFC and the search; unrelated servicing services are managed by Windows.

## Results and exit codes

| Code | Meaning |
|---|---|
| 0 | All requested automated steps completed, or valid `-WhatIf` preview; not proof that every Windows Update problem is fixed |
| 1 | Failed/incomplete operation, declined operation, manual reboot needed, or result requiring review |
| 2 | Fatal preflight/log initialization failure; repair did not start |

PowerShell host failures before script execution (for example a parse error, unsupported engine or execution-policy block) have host-defined exit behavior.

Native exit codes are logged. DISM 0 permits SFC; 3010 requests manual reboot and skips SFC; other codes fail. `netsh` must return 0. Microsoft documents SFC console outcomes and CBS `[SR]` entries, **not** a reliable `0 = clean, 1 = repaired` mapping. The script records SFC's actual code, treats nonzero as a problem, and requires review even for 0. Consequently a normal run including SFC returns 1 pending manual review. Review the console/log and this run's timestamps in `%windir%\Logs\CBS\CBS.log`; do not mistake historical entries for this run. See also `%windir%\Logs\DISM\dism.log`.

## Validation and limitations

No repair should be executed on a development workstation. Mocked tests exercise backup failure, preservation of policies, shutdown failure, independent recovery attempts and preview safeguards. Run with Windows PowerShell 5.1 and Pester 5.7.1+ and PSScriptAnalyzer 1.24.0+:

```powershell
Invoke-Pester .\tests\Repair-WindowsUpdate.Tests.ps1
Invoke-ScriptAnalyzer .\Repair-WindowsUpdate.ps1
```

Validation on 2026-09-26: Windows PowerShell 5.1 parsing passed; 21 mocked tests passed with Pester 5.7.1; PSScriptAnalyzer 1.24.0 reported no findings. The one documented analyzer suppression covers internal mutation helpers governed by the script-level confirmation gate. The test runner disables Pester's optional registry sandbox; no repair operations were executed.

Real non-production Windows Server testing remains required for protected services/dependents, trigger-start races, cache locks/rollback, policy reapplication, WSUS versus public-source searches, BITS formats and localized DISM/SFC output. Network access must suit the configured update and repair sources; no source, proxy, firewall or Microsoft Update enrollment is automatically configured. No version is claimed verified by these mocked tests.

## Microsoft references

- [WSUS and Windows Update source selection](https://learn.microsoft.com/en-us/windows/deployment/update/wufb-wsus) and [Windows Update policy settings](https://learn.microsoft.com/en-us/windows/deployment/update/waas-wu-settings).
- [Registry export return values](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/reg-export) and [service dependencies](https://learn.microsoft.com/en-us/powershell/scripting/samples/managing-services).
- [DISM repair sources](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/repair-a-windows-image) and [NoRestart](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-global-options-for-command-line-syntax).
- [SFC command](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/sfc) and [interpreting CBS logs](https://learn.microsoft.com/en-us/troubleshoot/windows-client/installing-updates-features-roles/analyze-sfc-program-log-file-entries).
- [Windows Update Agent result codes](https://learn.microsoft.com/en-us/windows/win32/api/wuapi/ne-wuapi-operationresultcode) and [Azure Update Manager sources / Microsoft application updates](https://learn.microsoft.com/en-us/azure/update-manager/support-matrix).

## License

MIT. Provided as-is, without warranty.
