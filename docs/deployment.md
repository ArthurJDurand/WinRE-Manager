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
- **Windows is in a normal-running state.** The script refuses to run before any state-modifying action when the machine has not yet completed OOBE. This is the v43 patch 5 (further revision) Audit Mode guard and it matters for freshly imaged machines. See the "Audit Mode and OOBE" section below.
- **BitLocker state is confirmed safe.** This is the v43 patch 5 precondition and it matters. Run `manage-bde -status C:` and read both the `Protection Status:` and `Conversion Status:` lines. The state is safe only if **either**:
  - `Protection Status: Protection On` (any conversion status), **or**
  - `Protection Status: Protection Off` with `Conversion Status: Fully Decrypted` (never encrypted, or decryption finished).

  Any other combination is deferred. That includes:
  - The four mid-operation states (`Encryption In Progress`, `Decryption In Progress`, `Encryption Paused`, `Decryption Paused`), where Device Encryption is actively encrypting or decrypting the volume.
  - `Protection Status: Protection Off` with `Conversion Status: Fully Encrypted`. This is the standard suspended-BitLocker state after a legitimate `Suspend-BitLocker` or a Windows Update suspension that has not yet been lifted, but it is also indistinguishable from a Device Encryption volume in the *Waiting for Activation* state (volume encrypted with a clear key, recovery key not yet escrowed). The two-field local view cannot tell them apart, so the script treats both as ambiguous.

  See the Device Encryption section below for the full explanation.

The harness's System Diagnostic (`scripts\Test-WinRE.ps1` Option 1) reports `ImageState`, `ProtectionStatus`, and `VolumeStatus`, and warns explicitly when a hazardous or ambiguous state is detected. Run it on a representative machine before pushing the task to a fleet.

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

## Audit Mode and OOBE (v43 patch 5, further revision)

The Audit Mode guard is the highest-priority startup check in the script. It runs before the hardware detection, before the manifest fetch, before the OEM pack resolution, before the `DesiredStateId` computation, before the BitLocker gate, before the pending-reboot block, and before the classifier. It reads a single registry value:

```
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State
  → ImageState (string)
```

If the value is absent, or if it is exactly `IMAGE_STATE_COMPLETE`, the guard passes and the script proceeds normally. Any other value causes a deferral.

### Why the guard exists

During Audit Mode, OOBE, the sysprep generalize phase, and the sysprep specialize phase, Windows blocks `reagentc /enable` with `ERROR_CANCELLED` (`0x4c7`, 1223). This is not a bug in the script, and it is not related to the correctness of the deployed WIM or the state of the recovery partition. The OS refuses the call by design until the machine has reached a normal desktop.

The destructive partition work the script would otherwise perform on such a machine accomplishes nothing — the partition will be re-created on the next run anyway — and leaves a state file recording the deployment as complete. On the next run, the enable-only path fires because the state file matches and WinRE is still disabled, and it fails the same way. Without the guard, the machine loops forever, and the operator sees a fleet of machines that "deployed successfully" but never enabled WinRE.

Two additional defenses exist for the enable failure itself, in case the Audit Mode guard is somehow bypassed or the failure comes from a different source:

- **The enable-failure counter.** When the enable-only path fails with a generic `"failed"` result, it increments `EnableFailureAttempts` in the state file and exits `EXIT_WARNING`. It does **not** fall through to full update — the deployment is current and a rebuild would not change the outcome.
- **The loop-breaker.** After three consecutive failed enables, the loop-breaker exits `EXIT_FATAL` with an actionable message. The state file is left in place; the operator resolves the underlying cause and deletes `C:\Recovery\OEM\winre_state.json` to reset the counter.

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

## Device Encryption (v43 patch 5)

Windows 11 24H2+ enables Device Encryption by default on hardware meeting TPM 2.0 and Secure Boot requirements. A freshly imaged machine will be in one of these encryption states when the scheduled task first fires:

| `manage-bde -status C:` shows | Meaning | Is it safe to run? |
|---|---|---|
| `Protection Off` + `Fully Decrypted` | BitLocker never activated, or was turned off | Yes |
| `Protection On` + `Fully Encrypted` | Encryption complete, key escrowed | Yes |
| `Protection Off` + `Fully Encrypted` | Suspended BitLocker (post-`Suspend-BitLocker`, or a Windows Update suspension not yet lifted) **OR** Device Encryption *Waiting for Activation* (recovery key not yet escrowed). The two-field local view cannot distinguish them. | **Defer** (ambiguous) |
| `Protection Off` + `Encryption In Progress` | Device Encryption is actively working | **Defer** (hazardous) |
| `Protection Off` + `Encryption Paused` | Device Encryption was paused mid-work | **Defer** (hazardous) |
| `Protection Off` + `Decryption In Progress` | Decryption is actively working | **Defer** (hazardous) |
| `Protection Off` + `Decryption Paused` | Decryption was paused mid-work | **Defer** (hazardous) |

Two categories of deferral, both reported as `EXIT_WARNING`:

**Hazardous** (the four mid-operation states). Before v43 patch 5, the script treated `Protection Off` as sufficient evidence that BitLocker was not a factor. On a machine in the `Encryption In Progress` state, the Device Encryption service claims any new partition the script creates — the partition is briefly a Basic Data partition, the encryption service sees it, and starts encrypting it before the script can apply the recovery type GUID. The subsequent delete-and-recreate retry hits the same problem, and the machine ends up with no recovery partition and WinRE disabled. Two machines failed this way on the same day before patch 5 shipped.

**Ambiguous** (`Protection Off` + `Fully Encrypted`). This is the state every machine enters after a legitimate `Suspend-BitLocker` or a Windows Update suspension that has not yet been lifted — safe, in that sense. But it is also indistinguishable from a Device Encryption volume in the *Waiting for Activation* state, where the volume has been encrypted with a clear key but protection has not yet been armed because the recovery key has not been escrowed. The two-field local view (`ProtectionStatus` + `VolumeStatus`) cannot tell the two apart. The script defers both. An extra pipeline run later is cheaper than an unrepairable machine — on a *Waiting for Activation* volume, servicing WinRE risks a recovery prompt on the next boot with no escrowed key to satisfy it.

The initial v43 patch 5 implementation whitelisted `Fully Encrypted + Protection Off` as safe, based on the standard post-`Suspend-BitLocker` semantics. That was correct in the narrow case and wrong in the *Waiting for Activation* case. The further revision treats it as ambiguous. `Protection Off + Fully Decrypted` remains the only `Protection Off` state that is confirmed-safe.

**v43 patch 5 (further revision) behaviour.** The script refuses to run the destructive partition path whenever the BitLocker state cannot be confirmed safe. Three layers of defence, all fail-closed:

1. **Startup BitLocker gate.** Immediately after `Get-WinREState` and before the pending-reboot block or any state-modifying action, the script queries `Get-BitLockerVolume` on C:. If the cmdlet returns null, the gate falls back to `Test-BitLockerProtected` (which itself falls back to `manage-bde -status` text parsing) and defers on an unknown result; the fallback is skipped entirely when `manage-bde.exe` is absent, so a machine without the BitLocker feature is not falsely deferred. When the cmdlet returns a value, the gate defers if the volume is `ProtectionStatus=Off` with a `VolumeStatus` other than `FullyDecrypted`, or if `ProtectionStatus` is neither `On` nor `Off`. On deferral the run logs the reason and exits with `EXIT_WARNING`; no partition is touched, no state file is written, `reagentc` state is unchanged, and the checkpoint file is left in place. Under `-DryRun` the gate performs the same read-only classification and logs "Would defer WinRE Manager: …" without exiting, so a preflight of an unsafe machine reports the state a live run would defer on. This is the primary defence: most mid-encryption and ambiguous-state machines never reach the destructive paths at all.
2. **Mid-run guards.** For the narrow window where the machine's BitLocker state changes between the startup query and the destructive work, two additional guards fire: one in `Ensure-AdequateRecoveryPartition` before `reagentc /disable`, and one in Step 5 before the deployment-path `reagentc /disable`. Both refuse with `EXIT_WARNING` and a single deferral line.
3. **Fail-closed on `reagentc /enable`.** `Invoke-ReagentcEnable` returns a distinct result `"blunsafe"` when BitLocker on C: is not confirmed unprotected, instead of warning and continuing into `reagentc /enable`. All three callers — the enable-only path, the pending-reboot path, and the full-update post-deploy path — abort with `EXIT_WARNING`, remove the checkpoint file, and leave any state file untouched.

**Ownership guard.** Because the ambiguous `Protection Off + Fully Encrypted` state is now refused, the script has to distinguish "state observed at startup" from "state produced by this run." After the script suspends BitLocker on a healthy machine (`Protection On` → `Suspend-BitLocker` → `Protection Off + Fully Encrypted`), a later call to `Suspend-BitLockerForWinRE` in the same run sees that state. Without a guard, it would classify it as ambiguous and refuse — causing Step 5's pre-deploy gate to skip deployment on a machine the script was already committed to modifying. `Suspend-BitLockerForWinRE` short-circuits with `return $true` when `$Script:BitLockerSuspended` is set, so the ownership of a legitimate suspension is honoured. The ambiguous classification therefore applies only to states observed at the start of the run.

**Stronger `manage-bde` fallback.** When `Get-BitLockerVolume` is unavailable and the fallback parses `manage-bde -status` text, `Protection Off` alone is no longer sufficient evidence of safety. Only a confirmed `Conversion Status: Fully Decrypted` makes the fallback return confirmed-unprotected; anything else returns unknown. The fail-closed policy holds even when the primary API is unavailable.

**When a gate refuses, the run exits with `EXIT_WARNING` immediately** — it logs the guard message and a single deferral line, does not log a partition-creation failure, does not set `UsedOSFallback`, does not disable WinRE, does not fall through to OS-fallback, and does not write a state file. In all cases the machine's WinRE registration, recovery partition, and state file are left untouched.

**What this means for you.** The scheduled task does not need to be aware of the encryption state. The script handles it. But if you are deploying to a fresh fleet and want the first run to succeed rather than defer, wait until `manage-bde -status C:` shows either `Protection On` (any conversion status) or `Protection Off` with `Fully Decrypted` before pushing the task. On a modern SSD that is typically 30–90 minutes after OOBE. If the machine sits at `Protection Off + Fully Encrypted` — the ambiguous state — wait for it to resolve to either `Protection On` (protection re-armed, key escrowed) or `Fully Decrypted`, which will happen naturally once Device Encryption completes its activation.

**If you are already on v43 patch 4 or earlier**, update before deploying to a fleet that contains any Windows 11 24H2+ machine. The pre-patch-5 code has a real, demonstrated failure mode. The v43 patch 5 further revision adds the Audit Mode guard, the startup gate, the ownership guard, the enable-failure counter, the loop-breaker, and the fail-closed `reagentc /enable` handling on top of the original patch-5 fixes; all of it is in the same `ScriptVersion = 43` build, so an update is a file replacement. See the recovery procedure in [troubleshooting.md](troubleshooting.md) if a machine has already been damaged.

## Exit code handling

The script's exit codes carry meaning. See [exit-codes.md](exit-codes.md) for the full matrix.

For MDM / orchestration:

| Exit code | Recommended action |
|---|---|
| 0 | None. Record success. |
| 1 | Reboot the machine at the next convenient window. The script will finish on the next boot. |
| 2 | Investigate. WinRE is functional but degraded, or the script deferred work, or the enable step failed and the counter incremented. Collect the log and check the state file's `LastUpdated` timestamp and `LastEnableResult` field. Five distinct cases, distinguished by the log: OS-fallback (state file updated with `UsedOSFallback = true`), Audit Mode deferral (state file unchanged, `Setup\State\ImageState=…`), hazardous BitLocker deferral (state file unchanged, `VolumeStatus=EncryptionInProgress` or one of the other three hazardous values), ambiguous BitLocker deferral (state file unchanged, `VolumeStatus=FullyEncrypted`), enable-only failure (state file updated with `LastEnableResult = "failed"` and incremented `EnableFailureAttempts`). See [exit-codes.md](exit-codes.md) for the full decision table. |
| 3 | Investigate. The run failed and did not write state, or the enable-failure loop-breaker fired. Collect the log. Do not retry automatically. |

Do **not** treat exit code 2 as success. A machine in OS-fallback is intentionally reported as a warning; it will be treated as a healthy machine by the fast path only if the state file records `UsedOSFallback = true` for the current `DesiredStateId`. A machine on which a startup gate deferred the work will have an unchanged (or absent) state file and a single deferral line in the log; see [exit-codes.md](exit-codes.md) for how to distinguish the cases.

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

Watch for:

- **Exit code 2 with `UsedOSFallback = true` in the state file and a state file `LastUpdated` timestamp newer than the run's start time** — the machine cannot shrink the OS and deliberately ended in OS-fallback. The log will show the `Dedicated recovery partition creation failed after all attempts.` banner.
- **Exit code 2 with `Setup\State\ImageState=…` in the log and the state file absent or unchanged** — the Audit Mode / OOBE guard fired. The machine has not finished OOBE. This is expected on freshly imaged machines that are still pre-first-sign-in; wait for the machine to reach a normal desktop and re-run on the next scheduled trigger.
- **Exit code 2 with the log showing either BitLocker guard message and a single deferral line, and the state file's `LastUpdated` timestamp unchanged (or the state file absent)** — the BitLocker gate deferred the work. Two cases:
  - **Hazardous deferral.** The log shows `ProtectionStatus=Off but VolumeStatus=EncryptionInProgress` (or `DecryptionInProgress`, `EncryptionPaused`, `DecryptionPaused`) followed by a single deferral line. The machine was mid-encryption; no partition work was attempted. Re-check on your next deployment cycle once `manage-bde -status C:` shows `Protection On` or `Protection Off + Fully Decrypted`; do not retry immediately.
  - **Ambiguous deferral.** The log shows `ProtectionStatus=Off with VolumeStatus=FullyEncrypted - this state is ambiguous` followed by a single deferral line. The machine is in a suspended-BitLocker or Waiting-for-Activation state. Wait for the state to resolve to either `Protection On` (activation completed) or `Fully Decrypted` before retrying.
  
  Both cases leave the machine unchanged. The distinguishing detail is the guard message itself and the `VolumeStatus` value it names.
- **Exit code 2 with `Enable-only /enable failed (attempt N of 3)` in the log and `LastEnableResult = "failed"` in the state file** — the enable step failed on a machine whose deployment is current. The counter incremented. Investigate the enable failure itself (ReAgent.xml corruption, missing registration, a Windows component problem, an antivirus product holding a file). The next run retries enable-only. If the counter reaches 3, the loop-breaker fires on the following run and the exit code becomes 3.
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

## Related documents

- [exit-codes.md](exit-codes.md) — how to interpret the exit codes.
- [state-and-idempotency.md](state-and-idempotency.md) — what the state file records and how it interacts with the scheduled task.
- [troubleshooting.md](troubleshooting.md) — when the run fails.
