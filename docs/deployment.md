# Deployment

How to run WinRE Manager in a managed fleet.

## Recommended model

Run `WinRE.ps1` as `NT AUTHORITY\SYSTEM` from a scheduled task, triggered **at boot** and **weekly**. The script is fully idempotent; running it on a healthy machine costs a few seconds and a read-only scan.

Do **not** run it from a user logon script. It modifies partition tables and BitLocker state; those operations require SYSTEM.

## Preconditions

Before the first run on any machine, confirm:

- **Windows build**: 19041+ for Windows 10, 22000+ for Windows 11.
- **7-Zip** present at `C:\Program Files\7-Zip\7z.exe`, or `winget` available so the script can install it.
- **Internet access** to the driver manifest, the three OEM maps, and the base WIM repository. The script tolerates a missing network gracefully, but the first run on a fresh machine needs it.
- **BitLocker state is stable.** This is the v43 patch 5 precondition and it matters. Run `manage-bde -status C:` and read the `Conversion Status:` line. It must read either `Fully Decrypted` or `Fully Encrypted`. Any state that contains the word `In Progress` or `Paused` is a hazard: on Windows 11 24H2+ with Device Encryption, a volume mid-encryption will auto-encrypt any new partition the script creates, defeating the deployment. See the Device Encryption section below for the full explanation.

The harness's System Diagnostic (`scripts\Test-WinRE.ps1` Option 1) reports both `ProtectionStatus` and `VolumeStatus` and warns explicitly when the hazard state is detected.

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

## Device Encryption (v43 patch 5)

Windows 11 24H2+ enables Device Encryption by default on hardware meeting TPM 2.0 and Secure Boot requirements. A freshly imaged machine will be in one of these encryption states when the scheduled task first fires:

| `manage-bde -status C:` shows | Meaning | Is it safe to run? |
|---|---|---|
| `Fully Decrypted` + `Protection Off` | BitLocker never activated, or was turned off | Yes |
| `Fully Encrypted` + `Protection On` | Encryption complete, key escrowed | Yes |
| `Fully Encrypted` + `Protection Off` | BitLocker suspended (post-`Suspend-BitLocker`, or a Windows Update suspension not yet lifted) | Yes |
| `Encryption In Progress` + `Protection Off` | Device Encryption is actively working | **No** |
| `Encryption Paused` + `Protection Off` | Device Encryption was paused mid-work | **No** |
| `Decryption In Progress` + `Protection Off` | Decryption is actively working | **No** |

The last three rows are the hazard. Before v43 patch 5, the script treated `Protection Off` as sufficient evidence that BitLocker was not a factor. On a machine in the `Encryption In Progress` state, the Device Encryption service claims any new partition the script creates — the partition is briefly a Basic Data partition, the encryption service sees it, and starts encrypting it before the script can apply the recovery type GUID. The subsequent delete-and-recreate retry hits the same problem, and the machine ends up with no recovery partition and WinRE disabled. Two machines failed this way on the same day before patch 5 shipped.

The `Fully Encrypted` + `Protection Off` row is worth calling out separately. It is what every machine enters after `Suspend-BitLocker` or a Windows Update suspension that has not yet been lifted, and it is safe — the volume is fully encrypted but protection is currently off, so the Device Encryption service is not claiming new partitions. The initial patch 5 implementation incorrectly rejected this state as hazardous, which would have refused the destructive path on any suspended machine; the revised patch 5 whitelists it.

**v43 patch 5 (revised) behaviour.** The script refuses to run the destructive partition path when it sees `ProtectionStatus=Off` with a `VolumeStatus` of `EncryptionInProgress`, `DecryptionInProgress`, `EncryptionPaused`, or `DecryptionPaused`. The guard is evaluated at two points — inside `Ensure-AdequateRecoveryPartition`, before `reagentc /disable`; and in Step 5, before the deployment-path `reagentc /disable`.

When the first gate refuses, the main flow exits with `EXIT_WARNING` **immediately** — it logs the guard message and a single deferral line, does not log a partition-creation failure, does not set `UsedOSFallback`, does not disable WinRE, does not fall through to OS-fallback, and does not write a state file. The Step 5 gate exists for the routes that do not reach `Ensure-AdequateRecoveryPartition` directly (a machine whose existing recovery partition was already insufficient on this pass, or an enable-only escalation); that gate exits the same way. In all cases the machine's WinRE registration, recovery partition, and state file are left untouched.

**What this means for you.** The scheduled task does not need to be aware of the encryption state. The script handles it. But if you are deploying to a fresh fleet and want the first run to succeed rather than defer, wait until `manage-bde -status C:` shows `Fully Encrypted` (with `Protection On` or `Protection Off`) or `Fully Decrypted` before pushing the task. On a modern SSD that is typically 30–90 minutes after OOBE.

**If you are already on v43 patch 4 or earlier**, update before deploying to a fleet that contains any Windows 11 24H2+ machine. The pre-patch-5 code has a real, demonstrated failure mode. See the recovery procedure in [troubleshooting.md](troubleshooting.md) if a machine has already been damaged.

## Exit code handling

The script's exit codes carry meaning. See [exit-codes.md](exit-codes.md) for the full matrix.

For MDM / orchestration:

| Exit code | Recommended action |
|---|---|
| 0 | None. Record success. |
| 1 | Reboot the machine at the next convenient window. The script will finish on the next boot. |
| 2 | Investigate. WinRE is functional but degraded, or the script deferred work. Collect the log and check the state file's `LastUpdated` timestamp. |
| 3 | Investigate. The run failed and did not write state. Collect the log. |

Do **not** treat exit code 2 as success. A machine in OS-fallback is intentionally reported as a warning; it will be treated as a healthy machine by the fast path only if the state file records `UsedOSFallback = true` for the current `DesiredStateId`. A machine on which the Device Encryption guard deferred the work will have an unchanged (or absent) state file and a single deferral line in the log; see [exit-codes.md](exit-codes.md) for how to distinguish the two cases.

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

- **Exit code 2 with `UsedOSFallback = true` in the state file and a state file `LastUpdated` timestamp newer than the run's start time** — the machine cannot shrink the OS and deliberately ended in OS-fallback. The log will show the `Dedicated recovery partition creation failed after all attempts.` banner.
- **Exit code 2 with the log showing the guard message `ProtectionStatus=Off but VolumeStatus=... Refusing to treat as unprotected` followed by a single deferral line, and the state file's `LastUpdated` timestamp unchanged (or the state file absent)** — the Device Encryption guard deferred the work. The machine was mid-encryption and no partition work was attempted; the machine is unchanged. Re-check on your next deployment cycle once `manage-bde -status C:` shows `Fully Decrypted` or `Fully Encrypted`; do not retry immediately.
- **Exit code 3 with `dism /Export-Image failed` in the log** — 7-Zip or DISM problem.
- **Exit code 3 with `cannot deploy a new WinRE image while WinRE is still Enabled`** — `reagentc /disable` returned nonzero. Investigate before retrying.
- **Exit code 3 with `FATAL: WinRE is not enabled at exit`** — the machine lost its recovery partition. This is the pre-patch-5 Device Encryption failure mode. Follow the recovery procedure in [troubleshooting.md](troubleshooting.md).

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
