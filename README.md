# Repair-WindowsUpdate

PowerShell script that repairs a broken Windows Update client on Windows Server 2016, 2019 and 2022. No GUI, works fine over remote sessions and in RMM tools.

I wrote this for servers that used to be managed by WSUS (with settings hardcoded in the registry via GPO) and need a working Windows Update client again, for example before onboarding to Azure Update Manager.

## What it does

1. Backs up the current `Policies\Microsoft\Windows\WindowsUpdate` registry key to a .reg file and logs every value, so you can see what WSUS config was on each server and restore it if needed.
2. Removes the WSUS policy keys (`WUServer`, `WUStatusServer`, `UseWUServer` and so on) so the client scans against Microsoft Update. Also clears any `Pause*` values under PolicyManager.
3. Stops the update services: wuauserv, bits, cryptsvc, UsoSvc.
4. Deletes the BITS queue files (qmgr*.dat).
5. Renames SoftwareDistribution and catroot2 to timestamped .bak folders. Rename instead of delete, so you can roll back. Delete the .bak folders manually once updates are confirmed working.
6. Resets the WSUS client identity (`SusClientId`, `SusClientIdValidation`, `PingID`). Fixes duplicate client issues on servers cloned from a template.
7. Winsock reset, optional, only with `-ResetWinsock`.
8. Restarts the update services.
9. Runs DISM /RestoreHealth and sfc /scannow. This runs after the WSUS removal on purpose: on WSUS-broken servers DISM fails with 0x800f0906 when it tries the dead WSUS as its repair source. Skip with `-SkipDeepRepair`.
10. Triggers an online update scan through the Windows Update Agent COM API. This works the same on 2016 through 2022, unlike the USOClient verbs which differ between versions. Lists the applicable updates it finds.

Every step is wrapped in try/catch with real error counting, and the exit code reflects what actually happened.

## Usage

Run from an elevated PowerShell prompt:

```powershell
# Full run including DISM/SFC (15-45 min per server)
.\Repair-WindowsUpdate.ps1

# Fast run, cache/service reset only, skip DISM/SFC
.\Repair-WindowsUpdate.ps1 -SkipDeepRepair

# Include winsock reset. Only needed if scans fail with network errors
# like 0x8024402c or 0x80072ee2. Requires a reboot.
.\Repair-WindowsUpdate.ps1 -ResetWinsock

# Custom log location
.\Repair-WindowsUpdate.ps1 -LogDir 'D:\Logs\WURepair'
```

If execution policy blocks the script:

```powershell
PowerShell -NoProfile -ExecutionPolicy Bypass -File .\Repair-WindowsUpdate.ps1
```

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-SkipDeepRepair` | off | Skip DISM /RestoreHealth and sfc /scannow |
| `-ResetWinsock` | off | Also run `netsh winsock reset` (requires reboot) |
| `-LogDir` | `C:\ProgramData\WURepair` | Directory for logs and the registry backup |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Completed successfully |
| 1 | Completed with errors, review the log |
| 2 | Fatal error (e.g. not elevated) |

## Output

- Timestamped log: `C:\ProgramData\WURepair\WURepair_<hostname>_<timestamp>.log`
- Registry backup: `C:\ProgramData\WURepair\WUPolicy_backup_<hostname>_<timestamp>.reg`
- Console output is color coded (errors red, warnings yellow).

## Important: GPO will undo this

If the WSUS GPO is still linked in Active Directory, the registry keys come back at the next policy refresh (about 90 minutes) and the repair will not stick. Before or right after running:

- unlink the WSUS GPO from the servers' OU, or
- move the servers to an OU with policy inheritance blocked, or
- set the Windows Update settings in the GPO to Not Configured.

The script checks at the end and warns if the policy key has already repopulated.

A reboot is recommended after running (required if you used `-ResetWinsock`).

## What it does not do, on purpose

- No `sc.exe sdset`. Stamping hardcoded service SDDLs across OS versions is riskier than the problem it solves.
- No regsvr32 DLL loop. Re-registering XP-era DLLs does nothing useful on Server 2016 and later.
- No telemetry or policy changes beyond removing the WSUS and pause settings. It does not touch `AllowTelemetry` or similar values.
- No automatic reboot. That decision stays with you.

## Requirements

- Windows Server 2016, 2019 or 2022 (also works on Windows 10/11)
- PowerShell 5.1 or later
- Administrator privileges
- Internet access to Microsoft Update (for the DISM repair source and the update scan)

## Disclaimer

Provided as-is, no warranty. The script modifies registry keys, service state and system folders. Test on one server before rolling out, and keep the generated .reg backup until you have confirmed updates work.

## License

MIT
