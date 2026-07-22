# Repair-WindowsUpdate

Headless PowerShell script that repairs a broken Windows Update client on **Windows Server 2016 / 2019 / 2022**. No GUI — built for remote sessions, RMM tools, and automation.

Designed for the common migration scenario: servers previously managed by **WSUS** (with GPO-hardcoded registry settings) that need a working native Windows Update client again — for example before onboarding to **Azure Update Manager**.

## What it does

The script runs ten steps in a deliberate order:

1. **Backs up** the current `Policies\Microsoft\Windows\WindowsUpdate` registry key to a `.reg` file and logs every value, so you can see per server what WSUS config existed and restore it if needed.
2. **Removes WSUS policy keys** (`WUServer`, `WUStatusServer`, `UseWUServer`, etc.) so the client scans against Microsoft Update. Also clears any MDM `Pause*` values under PolicyManager.
3. **Stops** the update services: `wuauserv`, `bits`, `cryptsvc`, `UsoSvc`.
4. **Deletes BITS queue files** (`qmgr*.dat`).
5. **Renames** `SoftwareDistribution` and `catroot2` to timestamped `.bak` folders — rename, not delete, so the operation is reversible. Remove the `.bak` folders manually once updates are confirmed working.
6. **Resets the WSUS client identity** (`SusClientId`, `SusClientIdValidation`, `PingID`) — fixes duplicate-client issues on servers cloned from a template.
7. **Winsock reset** — optional, only with `-ResetWinsock`.
8. **Restarts** the update services.
9. **Runs DISM `/RestoreHealth` and `sfc /scannow`** — deliberately *after* WSUS removal, because on WSUS-broken servers DISM fails (0x800f0906) when it tries the dead WSUS as its repair source. Skip with `-SkipDeepRepair`.
10. **Triggers an online update scan** via the Windows Update Agent COM API (reliable across 2016–2022, unlike `USOClient` verbs which differ between versions) and lists the applicable updates found.

Every step is individually try/caught with real error counting — the exit code reflects what actually happened.

## Usage

Run from an **elevated** PowerShell prompt:

```powershell
# Full run including DISM/SFC (15–45 min per server)
.\Repair-WindowsUpdate.ps1

# Fast run — cache/service reset only, skip DISM/SFC
.\Repair-WindowsUpdate.ps1 -SkipDeepRepair

# Include winsock reset (only if scans fail with network errors
# such as 0x8024402c / 0x80072ee2; requires a reboot)
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
| `-SkipDeepRepair` | off | Skip DISM `/RestoreHealth` and `sfc /scannow` |
| `-ResetWinsock` | off | Also run `netsh winsock reset` (requires reboot) |
| `-LogDir` | `C:\ProgramData\WURepair` | Directory for logs and the registry backup |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Completed successfully |
| 1 | Completed with errors — review the log |
| 2 | Fatal error (e.g. not elevated) |

## Output

- Timestamped log: `C:\ProgramData\WURepair\WURepair_<hostname>_<timestamp>.log`
- Registry backup: `C:\ProgramData\WURepair\WUPolicy_backup_<hostname>_<timestamp>.reg`
- Console output is color-coded (errors red, warnings yellow).

## Important: GPO will undo this

If the WSUS GPO is **still linked** in Active Directory, the registry keys return at the next policy refresh (~90 minutes) and the repair will not stick. Before or immediately after running:

- unlink the WSUS GPO from the servers' OU, or
- move the servers to an OU with policy inheritance blocked, or
- edit the GPO to *Not Configured* for the Windows Update settings.

The script detects and warns if the policy key has already repopulated by the time it finishes.

A **reboot is recommended** after running (required if `-ResetWinsock` was used).

## What it deliberately does NOT do

- **No `sc.exe sdset`** — stamping hardcoded service SDDLs across OS versions is riskier than the problem it solves.
- **No `regsvr32` DLL loop** — re-registering XP-era DLLs does nothing useful on Server 2016+.
- **No telemetry or policy changes** beyond removing WSUS/pause settings — it will not modify `AllowTelemetry` or similar org policy values.
- **No automatic reboot** — that decision stays with you.

## Requirements

- Windows Server 2016, 2019, or 2022 (also works on Windows 10/11)
- PowerShell 5.1+
- Administrator privileges
- Internet access to Microsoft Update (for DISM repair source and the update scan)

## Disclaimer

Provided as-is, without warranty. It modifies registry keys, service state, and system folders — test on one server before rolling out, and keep the generated `.reg` backup until you've confirmed updates work.

## License

MIT
