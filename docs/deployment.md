# Deployment

How to run WinRE Manager in a managed fleet.

## Recommended model

Run `WinRE.ps1` as `NT AUTHORITY\SYSTEM` from a scheduled task, triggered **at boot** and **weekly**. The script is fully idempotent; running it on a healthy machine costs a few seconds and a read-only scan.

Do **not** run it from a user logon script. It modifies partition tables and BitLocker state; those operations require SYSTEM.

## Scheduled task

Create the task with `schtasks.exe`, or as an XML payload via Group Policy / Intune.

### Via `schtasks.exe`

```cmd
schtasks /Create /TN "WinRE Manager" ^
  /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\OEM\WinRE.ps1" ^
  /SC ONSTART /RU SYSTEM /RL HIGHEST /F

schtasks /Create /TN "WinRE Manager Weekly" ^
  /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\OEM\WinRE.ps1" ^
  /SC WEEKLY /D SUN /ST 03:00 /RU SYSTEM /RL HIGHEST /F
```

### Via XML (preferred for MDM)

Save as `WinRE-Manager.xml` and register with `schtasks /Create /XML WinRE-Manager.xml /TN "WinRE Manager"`:

```xml
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Self-healing Windows Recovery Environment manager.</Description>
    <URI>\WinRE Manager</URI>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
      <Delay>PT2M</Delay>
    </BootTrigger>
    <CalendarTrigger>
      <StartBoundary>2026-01-04T03:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByWeek>
        <DaysOfWeek><Sunday /></DaysOfWeek>
        <WeeksInterval>1</WeeksInterval>
      </ScheduleByWeek>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT6H</ExecutionTimeLimit>
    <Priority>4</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\OEM\WinRE.ps1</Arguments>
    </Exec>
  </Actions>
</Task>
```

Notes on the settings:

- `MultipleInstancesPolicy = IgnoreNew` prevents overlapping runs. A long `defrag /x` on a nearly-full volume can take 30+ minutes.
- `ExecutionTimeLimit = PT6H` gives the run enough headroom; the script's own internal timeouts (60s BitLocker polling, 5s sleeps) are the effective limit inside that.
- `RunOnlyIfNetworkAvailable = true` because the script cannot download anything without it. The script tolerates a missing network gracefully (state file check fails, fast path skipped, run exits without doing damage) but there is no point running it offline.
- `StartWhenAvailable = true` handles missed triggers after a cold boot.

## Where to put the script

Place `WinRE.ps1` in a directory that:

1. **`SYSTEM` can read.** `C:\ProgramData\OEM\` is the standard choice.
2. **Cannot be modified by non-admin users.** A scheduled task running as SYSTEM must not execute a script that a standard user can overwrite. `C:\ProgramData\OEM\` with default ACLs is safe; do not use `C:\Temp\`.

The script writes to `C:\ProgramData\OEM\Logs\` for the log and checkpoint file. `SYSTEM` can write there by default.

## Exit code handling

The script's exit codes carry meaning. See [exit-codes.md](exit-codes.md) for the full matrix.

For MDM / orchestration:

| Exit code | Recommended action |
|---|---|
| 0 | None. Record success. |
| 1 | Reboot the machine at the next convenient window. The script will finish on the next boot. |
| 2 | Investigate. WinRE is functional but degraded. Collect the log. Do not reboot blindly. |
| 3 | Investigate. The run failed and did not write state. Collect the log. |

Do **not** treat exit code 2 as success. A machine in OS-fallback is intentionally reported as a warning; it will be treated as a healthy machine by the fast path only if the state file records `UsedOSFallback = true` for the current `DesiredStateId`.

## MDM / Intune

Deploy via a Win32 app or a PowerShell script platform script. The Intune "Scripts and remediations" feature is well-suited:

- **Detection rule:** `Test-Path C:\ProgramData\OEM\Logs\WinRE-Manager.log` and `reagentc /info` reports `Enabled`.
- **Remediation script:** `WinRE.ps1` invoked as SYSTEM.
- **Run in 64-bit PowerShell on the system:** required.

For a curated deployment, package the script as an Intune Win32 app with a detection rule on the log file and `reagentc` state. Run once, then allow the built-in weekly scheduled task to keep the state fresh.

## Hosting your own maps

The default configuration points at the maintainer's public gists:

- `$DriverManifestUrl = "https://gist.github.com/52250179/..."`
- `$DellWinPEMapUrl   = "https://gist.github.com/52250179/..."`
- `$HPWinPEMapUrl     = "https://gist.github.com/52250179/..."`
- `$LenovoWinPEMapUrl = "https://gist.github.com/52250179/..."`

The maintainer accepts no responsibility for their accuracy or availability. For a production fleet:

1. Fork the three map builders and the manifest.
2. Rebuild the maps on your own cadence (weekly is plenty — Dell, HP, and Lenovo do not update their WinPE driver packs more often than that in practice).
3. Host the JSON files somewhere you control (an internal HTTPS endpoint, an Azure Blob Storage static website, S3, or your own Gist).
4. Edit the four URLs near the top of `scripts/WinRE.ps1` and `scripts/Test-WinRE.ps1`.
5. Sign the resulting JSON with a code-signing key if you want to defend against a compromise of the hosting endpoint.

The map builders themselves are documented in the individual `.SYNOPSIS` blocks. The Dell builder downloads and extracts `DriverPackCatalog.cab`; the HP builder scrapes the HP WinPE driver page; the Lenovo builder downloads `recipecard.json`, resolves DS IDs by scraping the Lenovo support site (with `curl-impersonate` because the site blocks the PowerShell User-Agent), and emits the final map.

### Rebuilding the maps on a schedule

```powershell
# Weekly refresh, run from a machine that has 7-Zip and internet access.
.\scripts\Build-DellWinPEMap.ps1
.\scripts\Build-HPWinPEMap.ps1
.\scripts\Build-LenovoWinPEMap.ps1
# Then upload the three JSON files to your hosting endpoint.
```

The Lenovo builder is the slow one — it makes one HTTPS request per unique DS ID with a 2-second delay between requests. On a fresh run with 200 DS IDs that is ~7 minutes.

## Log collection

The log at `C:\ProgramData\OEM\Logs\WinRE-Manager.log` is append-only and grows unbounded. Rotate it via your existing log-collection pipeline:

- **Windows Event Log forwarding.** `WinRE.ps1` does not write to the Event Log; add a wrapper script that reads the last N lines of the log and writes them as an event after each run.
- **SCCM / Intune.** Use a file-based collection rule on `C:\ProgramData\OEM\Logs\WinRE-Manager.log`.
- **Syslog / Splunk.** Use the Windows agent's file-tailing feature.

At ~100 log lines per healthy run, an unmanaged machine generates ~5 MB per year. Rotation is not urgent but is worth having.

## Canary and ring deployment

The script is destructive on the recovery partition and non-destructive on the OS partition, but it does modify the OS partition geometry on the shrink path. Roll out in rings:

1. **Canary ring.** One or two machines, GPT, no BitLocker or suspended BitLocker. Run `Test-WinRE.ps1` first, then `WinRE.ps1 -DryRun`, then `WinRE.ps1`. Verify exit code 0.
2. **Early ring.** ~5% of the fleet. Mix of vendors and partition styles.
3. **Broad ring.** The rest.

Watch for:

- Exit code 2 with `UsedOSFallback = true` in the state file — the machine cannot shrink. Re-check on your next deployment cycle, not immediately.
- Exit code 3 with `dism /Export-Image failed` in the log — 7-Zip or DISM problem.
- Exit code 3 with `cannot deploy a new WinRE image while WinRE is still Enabled` — `reagentc /disable` returned nonzero. Investigate before retrying.

## Rolling back

The script does not have an uninstall path. To disable it:

```powershell
schtasks /Delete /TN "WinRE Manager" /F
schtasks /Delete /TN "WinRE Manager Weekly" /F
```

The state file, log, and any deployed recovery partition remain. The machine is in a healthy end state and Windows Update will continue to service the recovery image normally.

If you need to revert a machine to its pre-WinRE-Manager state, restore the partition layout from a backup. The script does not create one.

## Related documents

- [exit-codes.md](exit-codes.md) — how to interpret the exit codes.
- [state-and-idempotency.md](state-and-idempotency.md) — what the state file records and how it interacts with the scheduled task.
- [troubleshooting.md](troubleshooting.md) — when the run fails.
