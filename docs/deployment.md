# Deployment

How to run WinRE Manager in a managed fleet.

## Recommended model

Run `WinRE.ps1` as `NT AUTHORITY\SYSTEM` from a scheduled task, triggered **at boot** and **weekly**. The script is fully idempotent; running it on a healthy machine costs a few seconds and a read-only scan.

Do **not** run it from a user logon script. It modifies partition tables and the BitLocker state of the target recovery partition; those operations require SYSTEM.

## Preconditions

Before the first run on any machine, confirm:

- **Windows build**: 19041+ for Windows 10, 22000+ for Windows 11.
- **7-Zip** present at `C:\Program Files\7-Zip\7z.exe`, or `winget` available so the script can install it.
- **Internet access** to the driver manifest, the three OEM maps, and the base WIM repository. The script tolerates a missing network gracefully, but the first run on a fresh machine needs it.
- **Windows is in a normal-running state.** The script refuses to run before any state-modifying action when the machine has not yet completed OOBE. This is the v43 patch 5 (further revision) Audit Mode guard and it matters for freshly imaged machines. See the "Audit Mode and OOBE" section below.

There is **no BitLocker precondition on the OS volume**. The v43 patch 5 (further revision 5) policy is target-volume-based: the enable-only and dedicated-partition paths do not depend on C:'s BitLocker state at all. If the target recovery partition is encrypted, the script decrypts it in place via `Set-RecoveryPartitionReadyForWinRE` before calling reagentc. The only path that checks C:'s state is the OS-fallback route, and only because in that case the target volume *is* C:. See the "Device Encryption" section below.

The harness's System Diagnostic (`scripts\Test-WinRE.ps1` Option 1) reports `ImageState`, C:'s BitLocker state, and the target recovery partition's BitLocker state, and warns explicitly when a state on the target will require decryption. Run it on a representative machine before pushing the task to a fleet.

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

## Audit Mode and OOBE

The Audit Mode guard is the highest-priority startup check in the script. It runs before the hardware detection, before the manifest fetch, before the OEM pack resolution, before the `DesiredStateId` computation, before the pending-reboot block, and before the classifier. It reads a single registry value:

```
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State
  → ImageState (string)
```

If the value is absent, or if it is exactly `IMAGE_STATE_COMPLETE`, the guard passes and the script proceeds normally. Any other value causes a deferral.

### Why the guard exists

During Audit Mode, OOBE, the sysprep generalize phase, and the sysprep specialize phase, Windows blocks `reagentc /enable` with `ERROR_CANCELLED` (`0x4c7`, 1223). This is not a bug in the script, and it is not related to the correctness of the deployed WIM or the state of the recovery partition. The OS refuses the call by design until the machine has reached a normal desktop.

The destructive partition work the script would otherwise perform on such a machine accomplishes nothing — the partition will be re-created on the next run anyway — and leaves a state file recording the deployment as complete. On the next run, the enable-only path fires because the state file matches and WinRE is still disabled, and it fails the same way. Without the guard, the machine loops forever, and the operator sees a fleet of machines that "deployed successfully" but never enabled WinRE.

Two additional defenses exist for the enable failure itself, in case the Audit Mode guard is somehow bypassed or the failure comes from a different source:

- **The enable-failure counter.** When the enable-only path fails with a generic `"failed"` result or a `"bitlocker"` result — or when the target partition could not be prepared — it increments `EnableFailureAttempts` in the state file and exits `EXIT_WARNING`. It does **not** fall through to full update; the deployment is current and a rebuild would not change the outcome.
- **The loop-breaker.** After three consecutive terminal failures, the loop-breaker exits `EXIT_FATAL` with an actionable message. The state file is left in place; the operator resolves the underlying cause and deletes `C:\Recovery\OEM\winre_state.json` to reset the counter.

See [exit-codes.md](exit-codes.md) and [troubleshooting.md](troubleshooting.md) for the full description.

### What this means for you

The scheduled task does not need to be aware of the machine's `ImageState`. The script handles it. But if you are deploying to a fleet of freshly imaged machines, be aware of the timing:

- **OOBE completes when the first user signs in.** Until then, the machine is in a transitional state and the script will defer. If your task triggers on `BootTrigger` with a `PT2M` delay, a machine that reboots out of image but does not sign in for a day will exit `EXIT_WARNING` on every boot until a user reaches the desktop.
- **Audit Mode** is a state a machine is deliberately placed in for OEM preinstallation. It is not reached by accident. If your imaging pipeline boots into Audit Mode, the script will defer until the machine is sysprepped out and OOBE completes. The `EXIT_WARNING` exits are cosmetic in this case; they will not loop, and they will not consume the enable-failure counter (the Audit Mode gate runs before the state file is even read).

If you want to confirm the machine is ready to run before pushing the task, check `ImageState` on a representative image:

```powershell
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State" -Name ImageState -ErrorAction SilentlyContinue).ImageState
```

A machine ready for deployment returns `IMAGE_STATE_COMPLETE`, or the command returns nothing because the SKU omits the key. Both are safe.

If the command returns any other value, the machine has not finished OOBE. Wait for a user to sign in, then let the scheduled task fire on the next weekly or boot trigger (or run the script manually).

## Device Encryption (v43 patch 5, further revision 5)

Windows 11 24H2+ enables Device Encryption by default on hardware meeting TPM 2.0 and Secure Boot requirements. The relevant fact about Device Encryption for this project is that it can encrypt a **newly created partition on the same disk**, including a freshly created recovery partition, before the recovery type GUID and attributes can be applied to it. The partition then carries the default Basic Data type for a short window and can be claimed by the encryption service during it.

The v43 patch 5 (further revision 5) policy addresses this by acting on the volume reagentc will enable, not on the OS volume. Concretely:

- **The target recovery partition must be unencrypted before `reagentc /enable` is called.** `Set-RecoveryPartitionReadyForWinRE` prepares it: if the partition is already clean it returns immediately, otherwise it runs `manage-bde -off` against the partition and polls for completion at 5-second intervals up to a 300-second timeout. This is called on the enable-only path, the full-update path with an existing recovery partition, the full-update path with a newly created partition, and the pending-reboot repair path.
- **The OS volume's BitLocker state is not consulted** except on the OS-fallback route. On that route, the target volume is C:, and reagentc refuses to enable WinRE on an encrypted OS volume. The gate checks C:'s `VolumeStatus` before deploying and defers unless it is `FullyDecrypted`. The script never modifies C:'s state.
- **New partitions are created with the recovery type GUID applied at `New-Partition` time.** This closes the window between partition creation and `Set-RecoveryPartitionAttributes` during which a plain Basic Data partition could be claimed by the Device Encryption service.
- **No BitLocker suspension.** The v43 patch 5 function `Suspend-BitLockerForWinRE` was deleted. Suspension does not prevent Device Encryption from claiming new partitions — proven in the field — and it is useless for OS-fallback, where reagentc refuses regardless.

### Why the earlier further-revision policy was replaced

The v43 patch 5 (further revision) design gated on **C:'s** BitLocker state at startup. It deferred any run where C: was not `FullyDecrypted` with `Protection On`. That design was correct in the sense that it prevented the Dell Latitude 3550 / HP ProBook 450 G10 failure mode, but it was over-broad: it deferred on the `FullyEncrypted + Protection Off` state, which is the normal state of every fresh Win11 local-account machine before a Microsoft account sign-in. The startup gate was deferring on the majority of the fleet.

The change was driven by a same-machine test on 2026-09-29. With C: in the `FullyEncrypted + Protection Off` state, `reagentc /enable` against a dedicated recovery partition succeeded while `reagentc /enable` against the OS volume failed on the same machine in the same session. That established that reagentc's check is on the **target** volume. The policy was inverted accordingly: prepare the target; do not gate on C:.

### What this means for you

The scheduled task does not need to be aware of the machine's encryption state. The script handles it. But two deployment-time facts are worth knowing:

- **On a dedicated-partition machine, the first run may take up to 5 minutes longer than usual if the target recovery partition is encrypted.** The helper will spend up to 300 seconds decrypting it. A 1 GB recovery partition decrypts in well under a minute on NVMe, so the timeout is generous; but if you are benchmarking or scheduling tightly, expect the possibility.
- **On a machine that falls back to OS-fallback, the run defers if C: is not `FullyDecrypted`.** The log names the C: state and tells the operator what to do (sign in with a Microsoft account, add a key protector manually, or wait for decryption). This deferral does not consume the enable-failure counter.

If you are deploying to a fresh fleet and want the first run to succeed rather than defer on the OS-fallback route, wait until `manage-bde -status C:` shows either `Protection On` (any conversion status) or `Protection Off` with `Fully Decrypted` before pushing the task. On a modern SSD that is typically 30–90 minutes after OOBE.

## v44 patch 1 migration

The v44 patch 1 revision changes the `DesiredStateId` inputs (adding CPU vendor/generation and VMD presence) and therefore bumps `ScriptVersion` from 43 to 44. The effect on a managed fleet is a one-time full-update pass per machine on the next scheduled run.

Concretely, on the first run after the update, every machine will:

1. Compute the new `DesiredStateId`.
2. Compare it to the state file written by v43 patch 5 (further revision 5).
3. Find a mismatch, set `needInject = $true`, and take the full-update path.
4. Rebuild the WIM, deploy it, and write a state file under the new ID.
5. Return to the fast path on the second run.

On a healthy NVMe laptop this is roughly 3–5 minutes of I/O and CPU. Machines with a suitable existing recovery partition re-use it; no partition work occurs on healthy machines. This is the intended behaviour and the reason the `Migration note` in `CHANGELOG.md` is present.

Two cases that are handled cleanly without operator attention:

- **Machines with `PendingReboot = true`.** The DSI mismatch is detected before the pending-reboot block runs, so the full-update path executes rather than the pending-reboot repair path. No machine is lost.
- **Machines stuck in the enable-failure loop-breaker (`EnableFailureAttempts >= 3`).** The DSI mismatch makes the state file stale before the loop-breaker check runs, so those machines get one fresh attempt under the new ID. If the underlying cause is resolved, they recover; if not, they re-enter the loop-breaker on the fourth fresh attempt.

Plan for the v44 patch 1 rollout the same way you would plan for a manifest-version bump: brief the operator community, expect the first run after the update to be slower than usual, and check the log on a canary machine to confirm the full-update path executed and the state file was rewritten under the new ID.

### Rollback

Change `$ScriptVersion` back to 43, revert the `Get-DesiredStateId` `$parts` array, and restore the previous `Get-HardwareObject` if the manufacturer normalisation differed. No data is lost; another fleet-wide rebuild occurs on the next run.

## Exit code handling

The script's exit codes carry meaning. See [exit-codes.md](exit-codes.md) for the full matrix.

For MDM / orchestration:

| Exit code | Recommended action |
|---|---|
| 0 | None. Record success. |
| 1 | Reboot the machine at the next convenient window. The script will finish on the next boot. |
| 2 | Investigate. WinRE is functional but degraded, or the script deferred work, or the enable step failed and the counter incremented. Collect the log and check the state file's `LastUpdated` timestamp and `LastEnableResult` field. Four distinct cases, distinguished by the log: OS-fallback (state file updated with `UsedOSFallback = true`), Audit Mode deferral (state file unchanged, `Setup\State\ImageState=…`), OS-fallback BitLocker deferral (state file unchanged, `OS-fallback deferred: C: VolumeStatus=…`), enable-only failure (state file updated with a non-`"ok"` `LastEnableResult` and incremented `EnableFailureAttempts`). See [exit-codes.md](exit-codes.md) for the full decision table. |
| 3 | Investigate. The run failed and did not write state, or the enable-failure loop-breaker fired. Collect the log. Do not retry automatically. |

Do **not** treat exit code 2 as success. A machine in OS-fallback is intentionally reported as a warning; it will be treated as a healthy machine by the fast path only if the state file records `UsedOSFallback = true` for the current `DesiredStateId`. A machine on which the Audit Mode guard deferred will have an unchanged (or absent) state file and a single deferral line in the log; see [exit-codes.md](exit-codes.md) for how to distinguish the cases.

Do **not** configure retry loops that ignore the exit code and re-run unconditionally. Deferrals are not improved by retrying — the same gate will fire on the next run. Enable failures are handled by the counter; after three consecutive failures the loop-breaker fires and requires manual intervention. Resolve the underlying condition, then re-run.

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

If you are rolling out **v44 patch 1 specifically**, add a step 0 before the canary ring: run the current script on one machine and confirm the full-update pass completes and the state file is rewritten under the new `DesiredStateId`. Then roll out normally. The `Migration note` in `CHANGELOG.md` and the "v44 patch 1 migration" section above describe the expected behaviour.

Watch for:

- **Exit code 2 with `UsedOSFallback = true` in the state file and a state file `LastUpdated` timestamp newer than the run's start time** — the machine cannot shrink the OS and deliberately ended in OS-fallback. The log will show the `Dedicated recovery partition creation failed after all attempts.` banner.
- **Exit code 2 with `Setup\State\ImageState=…` in the log and the state file absent or unchanged** — the Audit Mode / OOBE guard fired. The machine has not finished OOBE. This is expected on freshly imaged machines that are still pre-first-sign-in; wait for the machine to reach a normal desktop and re-run on the next scheduled trigger.
- **Exit code 2 with `OS-fallback deferred: C: VolumeStatus=…` in the log and the state file's `LastUpdated` timestamp unchanged (or the state file absent)** — the machine cannot shrink the OS, and the OS-fallback target (C:) is encrypted. No WIM was deployed and no `reagentc` call was made. Wait for C: to reach `FullyDecrypted`, or complete Device Encryption activation by signing in with a Microsoft account, then re-run on the next scheduled trigger. Do not retry immediately.
- **Exit code 2 with `Image injection did not complete. Stopping before Step 4 and before any deployment.` in the log** — OEM or VMD injection failed and the pipeline gate stopped the run before deployment. The WIM was not deployed, the partition was not touched, and WinRE was not disabled. The checkpoint was set back to 2. The next run retries from step 2. Investigate the injection failure (OEM pack download, extraction, INF validation, or VMD driver download).
- **Exit code 2 with `Enable-only /enable failed (attempt N of 3)` or `Enable-only /enable refused with the BitLocker error after the target partition was confirmed unencrypted (attempt N of 3)` in the log and a non-`"ok"` `LastEnableResult` in the state file** — the enable step failed on a machine whose deployment is current. The counter incremented. Investigate the enable failure itself (ReAgent.xml corruption, missing registration, a Windows component problem, an antivirus product holding a file). The next run retries enable-only. If the counter reaches 3, the loop-breaker fires on the following run and the exit code becomes 3.
- **Exit code 3 with `dism /Export-Image failed` in the log** — 7-Zip or DISM problem.
- **Exit code 3 with `cannot deploy a new WinRE image while WinRE is still Enabled`** — `reagentc /disable` returned nonzero. Investigate before retrying.
- **Exit code 3 with `FATAL: WinRE is not enabled at exit`** — the machine lost its recovery partition. This is the pre-patch-5 Device Encryption failure mode. Follow the recovery procedure in [troubleshooting.md](troubleshooting.md).
- **Exit code 3 with `Refusing to retry reagentc /enable`** — the enable-failure loop-breaker fired. Do not retry automatically; the same guard will fire because the state file still records the counter. Resolve the underlying enable failure (see `troubleshooting.md`), delete `C:\Recovery\OEM\winre_state.json`, then re-run.

## Rolling back

The script does not have an uninstall path. To disable it:

```powershell
schtasks /Delete /TN "WinRE Manager" /F
schtasks /Delete /TN "WinRE Manager Weekly" /F
```

The state file, log, and any deployed recovery partition remain. The machine is in a healthy end state and Windows Update will continue to service the recovery image normally.

If you need to revert a machine to its pre-WinRE-Manager state, restore the partition layout from a backup. The script does not create one.

To revert the `DesiredStateId` change specifically, see the "Rollback" subsection under "v44 patch 1 migration" above.

## Related documents

- [exit-codes.md](exit-codes.md) — how to interpret the exit codes.
- [state-and-idempotency.md](state-and-idempotency.md) — what the state file records and how it interacts with the scheduled task.
- [troubleshooting.md](troubleshooting.md) — when the run fails.
