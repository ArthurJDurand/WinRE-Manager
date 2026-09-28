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
Via XML (preferred for MDM)
Save as WinRE-Manager.xml and register with schtasks /Create /XML WinRE-Manager.xml /TN "WinRE Manager":

xml
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
Notes on the settings:

MultipleInstancesPolicy = IgnoreNew prevents overlapping runs. A long defrag /x on a nearly-full volume can take 30+ minutes.

ExecutionTimeLimit = PT6H gives the run enough headroom; the script's own internal timeouts (60s BitLocker polling, 5s sleeps) are the effective limit inside that.

RunOnlyIfNetworkAvailable = true because the script cannot download anything without it. The script tolerates a missing network gracefully (state file check fails, fast path skipped, run exits without doing damage) but there is no point running it offline.

StartWhenAvailable = true handles missed triggers after a cold boot.

Where to put the script
Place WinRE.ps1 in a directory that:

SYSTEM can read. C:\ProgramData\OEM\ is the standard choice.

Cannot be modified by non-admin users. A scheduled task running as SYSTEM must not execute a script that a standard user can overwrite. C:\ProgramData\OEM\ with default ACLs is safe; do not use C:\Temp\.

The script writes to C:\ProgramData\OEM\Logs\ for the log and checkpoint file. SYSTEM can write there by default.

Exit code handling
The script's exit codes carry meaning. See exit-codes.md for the full matrix.

For MDM / orchestration:

Exit code	Recommended action
0	None. Record success.
1	Reboot the machine at the next convenient window. The script will finish on the next boot.
2	Investigate. WinRE is functional but degraded. Collect the log. Do not reboot blindly.
3	Investigate. The run failed and did not write state. Collect the log.
Do not treat exit code 2 as success. A machine in OS-fallback is intentionally reported as a warning; it will be treated as a healthy machine by the fast path only if the state file records UsedOSFallback = true for the current DesiredStateId.

MDM / Intune
Deploy via a Win32 app or a PowerShell script platform script. The Intune "Scripts and remediations" feature is well-suited:

Detection rule: Test-Path C:\ProgramData\OEM\Logs\WinRE-Manager.log and reagentc /info reports Enabled.

Remediation script: WinRE.ps1 invoked as SYSTEM.

Run in 64-bit PowerShell on the system: required.

For a curated deployment, package the script as an Intune Win32 app with a detection rule on the log file and reagentc state. Run once, then allow the built-in weekly scheduled task to keep the state fresh.

Hosting your own maps
The default configuration points at the maintainer's public gists:

$DriverManifestUrl = "https://gist.github.com/52250179/..."

$DellWinPEMapUrl = "https://gist.github.com/52250179/..."

$HPWinPEMapUrl = "https://gist.github.com/52250179/..."

$LenovoWinPEMapUrl = "https://gist.github.com/52250179/..."

The maintainer accepts no responsibility for their accuracy or availability. For a production fleet:

Fork the three map builders and the manifest.

Rebuild the maps on your own cadence (weekly is plenty — Dell, HP, and Lenovo do not update their WinPE driver packs more often than that in practice).

Host the JSON files somewhere you control (an internal HTTPS endpoint, an Azure Blob Storage static website, S3, or your own Gist).

Edit the four URLs near the top of scripts/WinRE.ps1 and scripts/Test-WinRE.ps1.

Sign the resulting JSON with a code-signing key if you want to defend against a compromise of the hosting endpoint.

The map builders themselves are documented in the individual .SYNOPSIS blocks. The Dell builder downloads and extracts DriverPackCatalog.cab; the HP builder scrapes the HP WinPE driver page; the Lenovo builder downloads recipecard.json, resolves DS IDs by scraping the Lenovo support site (with curl-impersonate because the site blocks the PowerShell User-Agent), and emits the final map.

Rebuilding the maps on a schedule
powershell
# Weekly refresh, run from a machine that has 7-Zip and internet access.
.\scripts\Build-DellWinPEMap.ps1
.\scripts\Build-HPWinPEMap.ps1
.\scripts\Build-LenovoWinPEMap.ps1
# Then upload the three JSON files to your hosting endpoint.
The Lenovo builder is the slow one — it makes one HTTPS request per unique DS ID with a 2-second delay between requests. On a fresh run with 200 DS IDs that is ~7 minutes.

Log collection
The log at C:\ProgramData\OEM\Logs\WinRE-Manager.log is append-only and grows unbounded. Rotate it via your existing log-collection pipeline:

Windows Event Log forwarding. WinRE.ps1 does not write to the Event Log; add a wrapper script that reads the last N lines of the log and writes them as an event after each run.

SCCM / Intune. Use a file-based collection rule on C:\ProgramData\OEM\Logs\WinRE-Manager.log.

Syslog / Splunk. Use the Windows agent's file-tailing feature.

At ~100 log lines per healthy run, an unmanaged machine generates ~5 MB per year. Rotation is not urgent but is worth having.

Canary and ring deployment
The script is destructive on the recovery partition and non-destructive on the OS partition, but it does modify the OS partition geometry on the shrink path. Roll out in rings:

Canary ring. One or two machines, GPT, no BitLocker or suspended BitLocker. Run Test-WinRE.ps1 first, then WinRE.ps1 -DryRun, then WinRE.ps1. Verify exit code 0.

Early ring. ~5% of the fleet. Mix of vendors and partition styles.

Broad ring. The rest.

Watch for:

Exit code 2 with UsedOSFallback = true in the state file — the machine cannot shrink. Re-check on your next deployment cycle, not immediately.

Exit code 3 with dism /Export-Image failed in the log — 7-Zip or DISM problem.

Exit code 3 with cannot deploy a new WinRE image while WinRE is still Enabled — reagentc /disable returned nonzero. Investigate before retrying.

Rolling back
The script does not have an uninstall path. To disable it:

powershell
schtasks /Delete /TN "WinRE Manager" /F
schtasks /Delete /TN "WinRE Manager Weekly" /F
The state file, log, and any deployed recovery partition remain. The machine is in a healthy end state and Windows Update will continue to service the recovery image normally.

If you need to revert a machine to its pre-WinRE-Manager state, restore the partition layout from a backup. The script does not create one.

Related documents
exit-codes.md — how to interpret the exit codes.

state-and-idempotency.md — what the state file records and how it interacts with the scheduled task.

troubleshooting.md — when the run fails.

text

---

## `docs/exit-codes.md`

```markdown
# Exit codes

WinRE Manager returns one of four exit codes. Orchestration should treat them as distinct outcomes, not as success/failure booleans.

## The four codes

| Code | Name | Meaning |
|---|---|---|
| `0` | `EXIT_SUCCESS` | WinRE enabled, dedicated recovery partition healthy, state file written or already current. |
| `1` | `EXIT_REBOOT_REQUIRED` | Deployment succeeded; a reboot is required to complete WinRE registration. |
| `2` | `EXIT_WARNING` | WinRE functional but degraded. Details in the log. |
| `3` | `EXIT_FATAL` | Deployment aborted. No state written or state file deleted. Investigate the log. |

## Priority

When a run's outcome satisfies more than one condition, the priority order is:
EXIT_FATAL > EXIT_REBOOT_REQUIRED > EXIT_WARNING > EXIT_SUCCESS

text

`EXIT_FATAL` always wins. Between `EXIT_REBOOT_REQUIRED` and `EXIT_WARNING`, reboot-required wins — the machine needs to reboot either way.

In practice only two combinations are reachable:

- **Reboot-required + warning.** A reboot is needed and a cleanup step failed. Returns `1`.
- **Warning + success.** A non-fatal warning was raised (BitLocker resume failed, fallback copy denied) but the run succeeded. Returns `2`.

## When each code is returned

### `EXIT_SUCCESS` (0)

The fast path found nothing to do and exited cleanly. Or the full-update path completed, WinRE reports `Enabled`, the state file was written, and no warning flags were set.

Also returned by `-DryRun` when the dry run completes without errors. Dry runs do not write a state file; they exit `0` from the deployment step.

### `EXIT_REBOOT_REQUIRED` (1)

`reagentc /enable` returned exit 0 but `reagentc /info` did not immediately report `Enabled`. This is a common result after a fresh registration: Windows schedules the registration to complete on the next reboot.

The script writes the state file with `PendingReboot = true`, records the deployed partition number and disk number so the next run knows where the WIM is, and exits with code 1.

Also returned by the pending-reboot path when the retry `reagentc /enable` still returns reboot-required, and by the enable-only path when `reagentc /enable` returns reboot-required.

### `EXIT_WARNING` (2)

Reached when any of the following is true at exit time:

- **OS-fallback.** The dedicated recovery partition could not be created and WinRE is deployed to `C:\Recovery\WindowsRE`.
- **`$Script:nonFatalWarning = $true`.** Set by: BitLocker suspension failure, BitLocker resume failure, cleanup failure in `Remove-StrayRecoveryPartitions`, fallback copy denial (ACL), recovery-attribute application failure, and OEM map resolution failure for a supported vendor.
- **`$Script:UsedOSFallback = $true`.** Distinct from `nonFatalWarning`; can be true without any warning-level event, and is the deliberate outcome of the shrink-fails path.

The warning code is returned on the fast path, the enable-only path, the pending-reboot success path, and the full-update path — anywhere a warning flag can be set. In every case the state file is still written (or left in place) if the run reached a state-write point.

### `EXIT_FATAL` (3)

Reached when any of the following occurs:

- **Base WIM could not be obtained.** GitHub download failed, or the existing WIM at the reagentc-registered location is unusable and no fallback exists.
- **`dism /Export-Image` failed.** Non-zero exit from DISM or missing output file.
- **`reagentc /disable` failed at Step 5.** WinRE is enabled and the script could not disable it, so the deployment cannot proceed.
- **`reagentc /setreimage` failed at Step 6.** Registration failed; the WIM was copied but the registry is inconsistent.
- **WIM deployment failed.** The copy or hash verification failed.
- **WinRE location cannot be resolved to a partition after enable.** The registration is inconsistent; the script would need manual intervention.
- **WinRE reports `Enabled` but the location is empty.** Same class.
- **WinRE is on an unexpected partition.** Not the OS disk's recovery partition, not the OS partition. This is a state the script cannot reconcile.
- **RepairAttempts > 3.** The pending-reboot path has been retried 4 times without resolving. Manual intervention is required.
- **An unhandled exception was thrown.** The top-level `catch` block logs and exits 3.

Fatal exits do not write a state file. If a state file was written earlier in the run and the fatal exit occurs after that point, the state file is left as-is; on the next run, the fast path may fire if the state is now healthy, or the full-update path may re-run if it is not.

## What the codes do not tell you

- **Which recovery partition was used.** The log records the disk and partition number.
- **Whether the run was a fast path or a full update.** The log records the control-flow path.
- **Whether BitLocker was suspended and successfully resumed.** The log records both.
- **How long the run took.** The log lines have timestamps; the first and last line bound the duration.

For any of those details, read the log. See [troubleshooting.md](troubleshooting.md).

## Exit codes on the pending-reboot path

The pending-reboot path has its own exit logic. In order:

1. If the retry `reagentc /enable` succeeded and WinRE reports `Enabled`:
   - If `UsedOSFallback` was carried over from the state file → `EXIT_WARNING`.
   - Else if `nonFatalWarning` was set → `EXIT_WARNING`.
   - Else → `EXIT_SUCCESS`.
2. If the retry still reports reboot-required → `EXIT_REBOOT_REQUIRED`.
3. If `RepairAttempts > 3` → `EXIT_FATAL`.

Note that `PendingReboot` and `RepairAttempts` are recorded in the state file before the exit, so a machine that exits with code 3 due to too many repair attempts still has a state file reflecting the current repair count.

## Exit codes and orchestration

Recommended orchestration policy:

| Code | Action |
|---|---|
| 0 | Record success. No further action. |
| 1 | Schedule a reboot at the next maintenance window. The next run will finish the registration. |
| 2 | Do not retry. Investigate the log. Common causes: OS-fallback (acceptable on some hardware), cleanup failure (transient), BitLocker suspension failure (needs investigation). |
| 3 | Do not retry automatically. Investigate the log immediately. A failed WIM deployment or partition operation can leave the machine in a state that requires manual intervention. |

Do **not** use exit code 0 as the sole health signal. A machine that reached OS-fallback exits with 2, which is a legitimate "the machine is functional but the design goal was not achieved" signal. If your deployment policy requires dedicated recovery partitions, treat 2 as a soft failure and route it to a queue.

## Related documents

- [architecture.md](architecture.md) — the pipeline and the four control-flow paths.
- [troubleshooting.md](troubleshooting.md) — how to investigate each code.
