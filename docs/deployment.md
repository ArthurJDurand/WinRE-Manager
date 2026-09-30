# Deployment

How to run WinRE Manager on a single machine or across a managed fleet.

## How to deploy

There are two ways to deploy WinRE Manager. Pick the one that matches your situation.

### Single machine, one-off repair

For a single broken machine, run the production script once from an **elevated** PowerShell prompt. It inspects the machine, repairs the recovery environment, writes a state file, and exits. There is no installer, no service, and no configuration file to maintain.

```powershell
# Elevated PowerShell (Run as Administrator)
.\scripts\WinRE.ps1 -DryRun   # walk the flow, log every decision, change nothing
.\scripts\WinRE.ps1           # actually deploy
```

If you want to inspect the machine first, run the read-only harness (`Test-WinRE.ps1`). It requires no elevation and modifies nothing. See the [README](../README.md) for the harness menu options.

For a single-machine deployment, the rest of this document is reference material — the exit-code table, the Audit Mode precondition, and the Device Encryption policy all apply to a one-off run exactly as they apply to a fleet run. You can skip the scheduled-task sections.

### Managed fleet, continuous

For a managed fleet, deploy the script as a scheduled task running as `NT AUTHORITY\SYSTEM`, triggered **at boot** and **weekly**. This is the recommended model. Every machine keeps its recovery environment healthy on its own; healthy machines exit in under a second, and a full repair runs only when something has changed.

The sections below this point cover the fleet deployment in detail: how to create the task, where to put the script, how to handle the Audit Mode precondition, how to interpret the exit codes, and how to roll out in rings.

## Recommended model

Run `WinRE.ps1` as `NT AUTHORITY\SYSTEM` from a scheduled task, triggered **at boot** and **weekly**. The script is fully idempotent; running it on a healthy machine costs a few seconds and a read-only scan.

Do **not** run it from a user logon script. It modifies partition tables and the BitLocker state of the target recovery partition; those operations require SYSTEM.

## Preconditions

Before the first run on any machine, confirm:

- **Windows build**: 19041+ for Windows 10, 22000+ for Windows 11.
- **7-Zip** present at `C:\Program Files\7-Zip\7z.exe`, or `winget` available so the script can install it.
- **Internet access** to the driver manifest, the three OEM maps, and the base WIM repository for the first deployment on a fresh machine. On a machine whose state file is present and its local safety checks pass, a network outage does not prevent the run — see the "Offline behavior" section below. The four endpoints are: `gist.github.com`, `api.github.com`, `downloads.dell.com`, `ftp.ext.hp.com`, and the vendor-specific Lenovo endpoints (`download.lenovo.com`, `support.lenovo.com` — the latter is only reached by the map builder, not by production).
- **Windows is in a normal-running state.** The script refuses to run before any state-modifying action when the machine has not yet completed OOBE. This is the v43 patch 5 (further revision) Audit Mode guard and it matters for freshly imaged machines. See the "Audit Mode and OOBE" section below.

There is **no BitLocker precondition on the OS volume**. The v43 patch 5 (further revision 5) policy is target-volume-based: the enable-only and dedicated-partition paths do not depend on C:'s BitLocker state at all. If the target recovery partition is encrypted, the script decrypts it in place via `Set-RecoveryPartitionReadyForWinRE` before calling reagentc. The only route that depends on C:'s BitLocker state is the OS-fallback route, because on that route the target volume *is* C:. The destructive partition path does not depend on C:'s state either — as of v44 patch 6 it does not consult C: at all. Neither the OS-fallback gate nor the destructive path modifies C:'s BitLocker state. See the "Device Encryption" section below.

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
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
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

- `MultipleInstancesPolicy = IgnoreNew` prevents two **scheduled** runs from overlapping. A long `defrag /x` on a nearly-full volume can take 30+ minutes. It has no effect on processes launched outside the scheduled task — see "One instance per machine" below for how the script defends itself against manual invocations.
- `ExecutionTimeLimit = PT6H` gives the run enough headroom; the script's own internal timeouts (300-second BitLocker polling, 5-second sleeps, 15-second network timeout) are the effective limit inside that.
- `RunOnlyIfNetworkAvailable = false` is deliberate as of v44 patch 5. The script now has an offline fallback: when the manifest fetch fails, it trusts the state file's stored `DesiredStateId` and takes the fast path if the local safety checks pass. With `true`, the task would not fire when the network is down, so the fallback would only help manual invocations — not the scheduled path where the machine actually needs it. The offline fallback is self-limiting (`EXIT_WARNING` when a full update is needed, never a silent partial deployment) and safe on a machine whose state file is valid. A first deployment on a machine with no state file will still exit `EXIT_FATAL` when offline, which is correct: the live manifest is required to compute the initial `DesiredStateId`. See the "Offline behavior" section below.
- `StartWhenAvailable = true` handles missed triggers after a cold boot.

## One instance per machine

`WinRE.ps1` assumes exclusive access to `C:\Temp\WinREWork` and to the recovery partition it is operating on. As of **v44 patch 4**, the script enforces this with a startup file lock.

### How the lock works

Before any state-modifying action, and immediately after the startup banner, `WinRE.ps1` opens `C:\ProgramData\OEM\Logs\WinREManager.lock` with an exclusive handle:

```powershell
$Script:ProgramLockStream = [System.IO.File]::Open(
    $lockPath,
    [System.IO.FileMode]::OpenOrCreate,
    [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::None
)
```

`FileShare.None` is enforced by the Windows kernel. Cross-session and cross-privilege exclusion are guaranteed by the OS, not by a security descriptor the script would have to configure. The handle is released automatically when the process exits, cleanly or after a crash — there is no stale-lock recovery logic to get wrong.

The lock is **not** acquired under `-DryRun`. A dry run is read-only and safe to run concurrently with a live deployment, so an operator can inspect a machine with `WinRE.ps1 -DryRun` or `scripts\Test-WinRE.ps1` while a scheduled run is in progress.

The lock is released **last** in the `finally` block, after the WIM-mount discard and after every temporary drive letter has been cleaned up. This ensures the lock is held until all cleanup is complete, so a waiting second instance cannot begin work while the first is still releasing resources.

### What a second instance sees

A second `WinRE.ps1` process launched while another instance holds the lock fails fast. The log records:

```
[WARN] Another WinRE Manager instance is already running (program lock file is exclusively held). Exiting without making any changes. This is not a deployment failure - the other instance is doing the work and will complete on its own. …
```

The second instance exits with **`EXIT_WARNING` (code 2)** within seconds, before the Audit Mode guard, before the hardware check, and before any state-modifying action. It has consumed no state, written no state file, and left no checkpoint.

This is a change from the pre-patch-4 behavior. Before the lock, a concurrent instance would reach Step 2 and fail with `FATAL ERROR: Cannot rename because item at 'C:\Temp\WinREWork\winre.wim' does not exist.`, which the orchestration layer saw as `EXIT_FATAL` (code 3). As of patch 4, the same scenario produces a clean `EXIT_WARNING` from the second instance.

### The lock file persists on disk

`C:\ProgramData\OEM\Logs\WinREManager.lock` remains on disk between runs. It is not deleted on release, and it is empty by design — nothing is ever written to it. **Its existence does not indicate a running instance.** Only an active exclusive handle on the file blocks a second instance. Operators inspecting the log directory should not mistake the file's presence for a stuck process.

### What the scheduled task protects against, and what it does not

**What it protects against.** The `MultipleInstancesPolicy = IgnoreNew` setting on the scheduled task prevents two **scheduled** runs from overlapping. Windows will refuse to start a second instance of the task while the first is still running.

**What it does not protect against.** A **manual** invocation — from an interactive PowerShell session, an RMM tool's "run now" button, an Intune remediation script, or anything else that launches `WinRE.ps1` outside the scheduled task — can overlap with a scheduled run. `IgnoreNew` is a property of the task, not of the script, so it has no effect on processes launched any other way. The v44 patch 4 file lock closes this gap for every launch path: the manual invocation and the scheduled run cannot both hold the lock.

### If you need to run `WinRE.ps1` manually on a machine that has the scheduled task installed

The lock makes manual invocations safe, but a manual run that coincides with a scheduled run will still find itself on one side or the other of the lock:

- **If the scheduled task is running when you launch manually**, your manual invocation exits with `EXIT_WARNING` and the "Another WinRE Manager instance is already running" message. This is not a failure. Wait for the scheduled run to complete and try again.
- **If the scheduled task is not running when you launch manually**, your invocation acquires the lock and proceeds normally. The next scheduled trigger will find the lock held if it fires while you are still running, and it will exit with `EXIT_WARNING` on its own side.
- **If you want to guarantee your manual invocation takes priority**, temporarily disable the scheduled task before the run and re-enable it afterwards: `schtasks /Change /TN "WinRE Manager" /DISABLE` (and the same for the Weekly task) before, `/ENABLE` afterwards.
- **If you are diagnosing rather than repairing**, use the read-only harness instead. `scripts\Test-WinRE.ps1` does not acquire the lock, does not touch `WorkDir`, does not modify partitions, and is safe to run at any time, alongside any number of other processes.

### Non-contention lock failures

If the lock cannot be acquired for a reason other than contention — a permission error on `C:\ProgramData\OEM\Logs\`, a missing `Logs` directory that could not be created, or a transient filesystem issue — the script logs:

```
[WARN] Could not set up program lock at C:\ProgramData\OEM\Logs\WinREManager.lock : <error> - proceeding without single-instance protection; concurrent runs may collide
```

and continues without the lock. This is deliberate: the lock is defensive, and a broken lock must not prevent a legitimate deployment. The run is then vulnerable to the pre-patch-4 rename error for its entire duration. If you see this line, investigate why the lock could not be acquired and fix the underlying condition — otherwise the machine is one concurrent invocation away from the pre-patch-4 failure mode.

## Where to put the script

Place `WinRE.ps1` in a directory that:

1. **`SYSTEM` can read.** `C:\ProgramData\OEM\` is the standard choice.
2. **Cannot be modified by non-admin users.** A scheduled task running as SYSTEM must not execute a script that a standard user can overwrite. `C:\ProgramData\OEM\` with default ACLs is safe; do not use `C:\Temp\`.

The script writes to `C:\ProgramData\OEM\Logs\` for the log, checkpoint file, and lock file. `SYSTEM` can write there by default.

## Audit Mode and OOBE

The Audit Mode guard is the highest-priority startup check in the script, after the program lock. It runs before the hardware detection, before the manifest fetch, before the OEM pack resolution, before the `DesiredStateId` computation, before the pending-reboot block, and before the classifier. It reads a single registry value:

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
- **The OS volume's BitLocker state is consulted only on the OS-fallback route.** On that route the target volume *is* C:, and reagentc refuses to enable WinRE on an encrypted OS volume. The gate checks C:'s `VolumeStatus` before deploying and defers unless it is `FullyDecrypted`. The script never modifies C:'s state. As of v44 patch 6, the destructive partition path does not consult C:'s state either — the dedicated-partition path's success or failure depends on the partition geometry, not on C:'s encryption state, and the safety property is preserved by the OS-fallback gate alone.
- **New partitions are created with the recovery type GUID applied at `New-Partition` time.** This closes the window between partition creation and `Set-RecoveryPartitionAttributes` during which a plain Basic Data partition could be claimed by the Device Encryption service.
- **No BitLocker suspension.** The v43 patch 5 function `Suspend-BitLockerForWinRE` was deleted. Suspension does not prevent Device Encryption from claiming new partitions — proven in the field — and it is useless for OS-fallback, where reagentc refuses regardless.

### Why the earlier further-revision policy was replaced

The v43 patch 5 (further revision) design gated on **C:'s** BitLocker state at startup. It deferred any run where C: was not `FullyDecrypted` with `Protection On`. That design was correct in the sense that it prevented the Dell Latitude 3550 / HP ProBook 450 G10 failure mode, but it was over-broad: it deferred on the `FullyEncrypted + Protection Off` state, which is the normal state of every fresh Win11 local-account machine before a Microsoft account sign-in. The startup gate was deferring on the majority of the fleet.

The change was driven by a same-machine test on 2026-09-29. With C: in the `FullyEncrypted + Protection Off` state, `reagentc /enable` against a dedicated recovery partition succeeded while `reagentc /enable` against the OS volume failed on the same machine in the same session. That established that reagentc's check is on the **target** volume. The policy was inverted accordingly: prepare the target; do not gate on C: except on the OS-fallback route, where the target *is* C:.

### What this means for you

The scheduled task does not need to be aware of the machine's encryption state. The script handles it. But three deployment-time facts are worth knowing:

- **On a dedicated-partition machine, the first run may take up to 5 minutes longer than usual if the target recovery partition is encrypted.** The helper will spend up to 300 seconds decrypting it. A 1 GB recovery partition decrypts in well under a minute on NVMe, so the timeout is generous; but if you are benchmarking or scheduling tightly, expect the possibility.
- **On a machine that falls back to OS-fallback, the run defers if C: is not `FullyDecrypted`.** The log names the C: state and tells the operator what to do: complete decryption of C: (`manage-bde -off C:`) or wait for an in-progress decryption to finish. Actions that complete encryption, add a protector, or enable protection do **not** resolve the state — they make C: more protected, not less. This deferral does not consume the enable-failure counter.
- **On a machine whose destructive attempt fails at the shrink step, the run falls through to OS-fallback.** No C: pre-check runs on this path. If the OS-fallback route is then blocked because C: is encrypted, the OS-fallback gate defers cleanly with a message naming C:'s state. The machine is left exactly as it was found.

If you are deploying to a fresh fleet and want the first run to succeed rather than defer on the OS-fallback route, wait until `manage-bde -status C:` shows `Fully Decrypted` before pushing the task. On a modern SSD, decrypting C: from a mid-encryption state typically takes 30–90 minutes.

## VMD fail-closed guard (v44 patch 6)

The VMD hardware presence check determines which driver set the script selects. As of v44 patch 6 the check is fail-closed: if the PnP enumeration reports an error during the query, the run treats VMD presence as **indeterminate** rather than as absent, and defers with `EXIT_WARNING` before committing any state.

The reasoning: guessing "absent" on a machine that genuinely has VMD hardware would select a driver set that omits the VMD package, and the deployed WinRE would not be able to see the OS disk. An empty device list from an errored enumeration is not evidence of absence. The cost of a deferral is one pipeline run; the cost of guessing wrong is a machine with a non-functional recovery environment.

A run that defers this way leaves the machine unchanged: no WIM deployed, no partition touched, no `reagentc` call made. The next scheduled run retries the enumeration; a transient PnP service issue is the most likely cause. If the deferral fires repeatedly, resolve the underlying PnP service issue — the deferral is a protective stop, not a degraded-success.

## Offline behavior (v44 patch 5)

The script's network calls — the driver manifest fetch, the OEM map fetches, and the base WIM download — all default to a 15-second timeout. Before v44 patch 5, an offline machine would hang for over 10 minutes across the aggregate of the default 100-second timeouts before failing. That is now capped at roughly 90 seconds in the fully-offline case, dominated by the fixed sleeps in the retry loops rather than by the network timeouts.

More importantly, v44 patch 5 adds an **offline fallback** for the manifest fetch. The behavior depends on the state file's contents:

### Case 1 — state file present, its fast-path checks pass

The script reads the state file at `C:\Recovery\OEM\winre_state.json` and trusts its stored `DesiredStateId` directly. It does **not** recompute the ID from cached inputs — recomputing would require the OEM pack version, which is resolved from the OEM map, another gist on the same unavailable network.

The local safety checks remain fully enforced and do not depend on the manifest:

- WinRE is `Enabled`
- Exactly one recovery partition exists on the OS disk
- The deployed WIM hash matches the state file's stored hash

If all three pass, the script takes the fast path, logs `Offline fallback: using state file's stored DesiredStateId <id>`, verifies the machine is healthy, and exits `EXIT_WARNING` (code 2) because `$Script:offlineFallback = $true` is set. The exit code is a degraded-success signal, not a failure. The machine is unchanged. Total runtime is under 90 seconds.

**On the next scheduled run with network**, the script performs a full manifest fetch, detects any hardware drift that occurred while offline (a CPU swap, a BIOS update that flipped VMD, a motherboard replacement), and either takes the fast path (if no drift) or forces a rebuild (if drift). The residual risk is that a machine whose hardware changed while offline could take the fast path with a stale DSI; the next successful manifest fetch corrects it. A `LocalInputsId` field in the state file would close this residual risk; it is planned as its own version boundary.

### Case 2 — state file present, its fast-path checks fail

If the state file indicates a full update is needed (WIM hash mismatch, force-upgrade, driver version drift, or a locally-detected input change), the script cannot proceed offline — a full update requires the live manifest to resolve the driver set. It logs:

```
Offline fallback: the machine requires a full update (state file is stale or unhealthy), but the driver manifest is unavailable. Cannot proceed without a live manifest. Will retry on the next scheduled run when the network is available.
```

and exits `EXIT_WARNING`. No WIM is deployed, no partition is touched, WinRE is not disabled, no state file is written or modified. The next scheduled run with network completes the work.

### Case 3 — no state file at all

A first deployment on a fresh machine requires the live manifest to compute the initial `DesiredStateId`. The script logs:

```
Driver manifest unavailable and no state file exists - a live manifest is required for the first deployment on this machine.
```

and throws. The outer `catch` logs `FATAL ERROR: …` and exits `EXIT_FATAL` (code 3). The machine retries on the next scheduled run when the network is available. No state-modifying action is attempted before the throw.

### What this means for the scheduled task

Because the offline fallback makes an offline scheduled run useful, the recommended task XML sets `RunOnlyIfNetworkAvailable = false` (see the XML above). With `true`, the task would not fire when the network is down, so the fallback would only help manual invocations — not the scheduled path where the machine actually needs it.

The scheduled task's `StartWhenAvailable = true` continues to handle missed triggers after a cold boot. Combined with the offline fallback, a machine that reboots offline and misses its weekly window will still take a fast-path validation run on the next opportunity and exit `EXIT_WARNING`, then complete normally on the next run with network.

See [exit-codes.md](exit-codes.md) and [troubleshooting.md](troubleshooting.md) for the full offline exit-code discussion.

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

## Later v44 patches

The subsequent v44 patches do **not** bump `ScriptVersion` and do **not** change the `DesiredStateId`. They apply to every subsequent run without a state-file action. A machine that is already healthy continues to take the fast path. A machine that was mid-deployment when the patch rolled out continues from where it was — the checkpoint and state-file schemas are unchanged.

- **v44 patch 2** adds `dism /cleanup-image /StartComponentCleanup /ResetBase` to the full-update pipeline; the size reduction materialises on the next natural rebuild, not immediately.
- **v44 patch 3** adds the destructive-path C: encryption guard inside `Ensure-AdequateRecoveryPartition` (removed in v44 patch 6) and a `base.wim` cleanup on the injection-failure abort branch (retained).
- **v44 patch 4** adds the program lock at `C:\ProgramData\OEM\Logs\WinREManager.lock`, so a second concurrent instance fails fast with `EXIT_WARNING` instead of colliding at Step 2.
- **v44 patch 5** adds the offline fallback for the driver manifest fetch and a 15-second timeout on every network call.
- **v44 patch 6** removes the v44 patch 3 destructive-path C: guard; makes Lenovo OEM-pack resolution distinguish five states; makes VMD hardware detection fail-closed; adds the Step 2 stale-file cleanup on the normal path; and corrects the OS-fallback remediation wording.

Because none of these patches changes `ScriptVersion` or the `DesiredStateId`, an already-completed machine will not rerun automatically; the deployment mechanism must invoke the script explicitly to pick the fixes up. The next natural rebuild (manifest bump, OEM pack version change, Windows build change, or CPU/VMD presence change) picks them up regardless.

For the **v44 patch 3 rollout caveat specifically**: the C: guard it introduced was removed in patch 6, so the guard itself is not part of the current code. The `base.wim` cleanup on the injection-failure abort branch is the surviving fix. To exercise it on a chosen ring, delete the state file on one machine and let the next run take the full-update path:

```powershell
Remove-Item "$env:SystemDrive\Recovery\OEM\winre_state.json" -Force
```

For **v44 patch 4**, watch for the new `EXIT_WARNING` from concurrent invocations in your orchestration logs. A cluster of these on a machine usually means an RMM tool or a manual operation overlapped with the scheduled task; it is a signal about the operator side, not a script defect.

For **v44 patch 5**, the first observable change is faster failure on machines with network issues. Machines that previously exited `EXIT_FATAL` after ~100-second timeouts now exit `EXIT_WARNING` after ~15-second timeouts, and healthy machines take the fast path offline instead of failing. Confirm on a canary that an offline run exits 2 with the `Offline fallback: using state file's stored DesiredStateId …` line rather than 3.

For **v44 patch 6**, the observable changes are the corrected OS-fallback remediation message (names `manage-bde -off C:` instead of "complete encryption"), the new Lenovo five-state resolution (visible in the log when the map has a malformed entry), the new VMD fail-closed deferral, and the Step 2 stale-file cleanup lines (`Removing stale extracted WIM before extraction`, `Removing stale base.wim before rename`) when the GitHub download path is used.

### Rollback for the later v44 patches

- **Patch 2**: remove the `dism /cleanup-image /StartComponentCleanup /ResetBase` invocation from Step 3.
- **Patch 3**: the C: guard is already removed; the `base.wim` cleanup on the abort branch is retained and does not need rollback.
- **Patch 4**: remove the lock acquisition block at the top of the main `try` block and the corresponding release in the `finally` block.
- **Patch 5**: remove the offline fallback branch and revert `$NetworkTimeoutSeconds` to its absence on each call.
- **Patch 6**: restore the v44 patch 3 destructive-path C: guard inside `Ensure-AdequateRecoveryPartition`; revert `Get-LenovoWinPEPack` to a two-state return; revert the VMD presence check to treat enumeration errors as absent; remove the Step 2 stale-file cleanup; restore the earlier OS-fallback remediation wording.

None of these rollbacks affects the state-file schema or the `DesiredStateId`.

## Exit code handling

The script's exit codes carry meaning. See [exit-codes.md](exit-codes.md) for the full matrix.

For MDM / orchestration:

| Exit code | Recommended action |
|---|---|
| 0 | None. Record success. |
| 1 | Reboot the machine at the next convenient window. The script will finish on the next boot. |
| 2 | Investigate. WinRE is functional but degraded, or the script deferred work, or the enable step failed and the counter incremented. Collect the log and check the state file's `LastUpdated` timestamp and `LastEnableResult` field. Eight distinct cases are documented in [exit-codes.md](exit-codes.md): OS-fallback, Step 3 → Step 4 pipeline gate, Audit Mode deferral, VMD-query-indeterminate deferral, OS-fallback BitLocker deferral, enable-only failure, concurrent-instance deferral (v44 patch 4), and offline-fallback deferral (v44 patch 5). The concurrent-instance case is **not a failure** — the other instance is doing the work. The offline-fallback fast-path case is a **degraded-success** — the machine is healthy and unchanged. The VMD-query-indeterminate case is a **protective deferral** — no state was committed. |
| 3 | Investigate. The run failed and did not write state, or the enable-failure loop-breaker fired. Collect the log. Do not retry automatically. |

Do **not** treat exit code 2 as success. A machine in OS-fallback is intentionally reported as a warning; it will be treated as a healthy machine by the fast path only if the state file records `UsedOSFallback = true` for the current `DesiredStateId`. A machine on which the Audit Mode guard deferred will have an unchanged (or absent) state file and a single deferral line in the log. See [exit-codes.md](exit-codes.md) for how to distinguish the eight cases.

Do **not** configure retry loops that ignore the exit code and re-run unconditionally. Deferrals are not improved by retrying — the same gate will fire on the next run. Enable failures are handled by the counter; after three consecutive failures the loop-breaker fires and requires manual intervention. The concurrent-instance deferral is not a failure at all; retrying while the other instance is still running will simply produce another `EXIT_WARNING`. The VMD-query-indeterminate deferral is not improved by retrying — the underlying PnP service issue must be resolved. Resolve the underlying condition, then re-run.

## MDM / Intune

Deploy via a Win32 app or a PowerShell script platform script. The Intune "Scripts and remediations" feature is well-suited:

- **Detection rule:** `Test-Path C:\ProgramData\OEM\Logs\WinRE-Manager.log` and `reagentc /info` reports `Enabled`.
- **Remediation script:** `WinRE.ps1` invoked as SYSTEM.
- **Run in 64-bit PowerShell on the system:** required.

For a curated deployment, package the script as an Intune Win32 app with a detection rule on the log file and `reagentc` state. Run once, then allow the built-in weekly scheduled task to keep the state fresh.

When using Intune to push a remediation, be aware that the remediation script may run outside the scheduled task's `IgnoreNew` gate. As of v44 patch 4, the program lock handles this: if the weekly task happens to be running at the same moment, the remediation exits with `EXIT_WARNING` (code 2) and the message `Another WinRE Manager instance is already running (program lock file is exclusively held)`. This is not a failure. The remediation will succeed on the next cycle, or you can wait for the scheduled task to complete and re-run the remediation manually.

**Do not disable the lock to "fix" the remediation.** Before patch 4, the same collision caused an `EXIT_FATAL` (code 3) with a rename error. Some Intune remediation pipelines treated that as a hard failure and retried aggressively, which could produce a cascade of colliding runs. The lock converts the collision into a clean, self-limiting `EXIT_WARNING`. If your Intune pipeline retries on any non-zero exit, adjust it to treat code 2 as a soft failure (route to a queue) and code 3 as a hard failure (investigate). See [exit-codes.md](exit-codes.md) for the recommended orchestration policy.

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

1. **Canary ring.** One or two machines, GPT, no BitLocker on the OS volume. Suspended BitLocker on C: is acceptable on a healthy canary machine — under the target-volume policy it only affects the OS-fallback route, which a healthy machine will not take. Run `Test-WinRE.ps1` first, then `WinRE.ps1 -DryRun`, then `WinRE.ps1`. Verify exit code 0. A transient exit code 2 from a concurrent scheduled task that happened to be running is not a failure — see "One instance per machine" above.
2. **Early ring.** ~5% of the fleet. Mix of vendors and partition styles.
3. **Broad ring.** The rest.

If you are rolling out **v44 patch 1 specifically**, add a step 0 before the canary ring: run the current script on one machine and confirm the full-update pass completes and the state file is rewritten under the new `DesiredStateId`. Then roll out normally. The `Migration note` in `CHANGELOG.md` and the "v44 patch 1 migration" section above describe the expected behaviour.

If you are rolling out **v44 patch 3 specifically**, no state-file action is needed on healthy machines — the surviving part of the fix (the `base.wim` cleanup) is exercised on the next full-update pass, and the guard portion is removed by v44 patch 6 anyway. See the "Later v44 patches" section above.

If you are rolling out **v44 patch 4 specifically**, watch for the new `EXIT_WARNING` from concurrent invocations in your orchestration logs. A cluster of these on a machine usually means an RMM tool or a manual operation overlapped with the scheduled task; it is a signal about the operator side, not a script defect.

If you are rolling out **v44 patch 5 specifically**, the first observable change is faster failure on machines with network issues. Machines that previously exited `EXIT_FATAL` after ~100-second timeouts now exit `EXIT_WARNING` after ~15-second timeouts, and healthy machines take the fast path offline instead of failing. Confirm on a canary that an offline run exits 2 with the `Offline fallback: using state file's stored DesiredStateId …` line rather than 3.

If you are rolling out **v44 patch 6 specifically**, watch for:

- The new VMD fail-closed deferral on machines with an unhealthy PnP service. These exit 2 with the `VMD hardware detection was indeterminate` message.
- The corrected OS-fallback remediation message naming `manage-bde -off C:` instead of the earlier (wrong) "complete encryption" guidance.
- The new Lenovo five-state resolution log lines when the map has a malformed entry.

Watch for:

- **Exit code 2 with `UsedOSFallback = true` in the state file and a state file `LastUpdated` timestamp newer than the run's start time** — the machine cannot shrink the OS and deliberately ended in OS-fallback. The log will show the `Dedicated recovery partition creation failed after all attempts.` banner.
- **Exit code 2 with `Setup\State\ImageState=…` in the log and the state file absent or unchanged** — the Audit Mode / OOBE guard fired. The machine has not finished OOBE. This is expected on freshly imaged machines that are still pre-first-sign-in; wait for the machine to reach a normal desktop and re-run on the next scheduled trigger.
- **Exit code 2 with `VMD hardware detection was indeterminate; deferring because the driver set cannot be safely determined.` in the log and the state file unchanged (or the state file absent)** — the VMD hardware presence check could not complete because of a PnP enumeration error. No WIM was deployed, no partition was touched, no `reagentc` call was made. Resolve the PnP service issue and re-run. Do not retry immediately; the same check will fire.
- **Exit code 2 with `OS-fallback deferred: C: could not be confirmed fully decrypted (Test-VolumeEncrypted=…)` in the log and the state file's `LastUpdated` timestamp unchanged (or the state file absent)** — the machine cannot shrink the OS, and the OS-fallback target (C:) is not confirmed fully decrypted. No WIM was deployed and no `reagentc` call was made. Wait for C: to reach `FullyDecrypted`, or complete decryption of C: with `manage-bde -off C:`, then re-run on the next scheduled trigger. Do not retry immediately.
- **Exit code 2 with `Image injection did not complete. Stopping before Step 4 and before any deployment.` in the log** — OEM or VMD injection failed and the pipeline gate stopped the run before deployment. The WIM was not deployed, the partition was not touched, and WinRE was not disabled. The checkpoint was set back to 2. The next run retries from step 2. Investigate the injection failure (OEM pack download, extraction, INF validation, or VMD driver download).
- **Exit code 2 with `Enable-only /enable failed (attempt N of 3)` or `Enable-only /enable refused with the BitLocker error after the target partition was confirmed unencrypted (attempt N of 3)` in the log and a non-`"ok"` `LastEnableResult` in the state file** — the enable step failed on a machine whose deployment is current. The counter incremented. Investigate the enable failure itself (ReAgent.xml corruption, missing registration, a Windows component problem, an antivirus product holding a file). The next run retries enable-only. If the counter reaches 3, the loop-breaker fires on the following run and the exit code becomes 3.
- **Exit code 2 with `Another WinRE Manager instance is already running (program lock file is exclusively held)` in the log** — a concurrent instance holds the lock. This is not a failure. It appears when a manual invocation overlaps with a scheduled run, or when an Intune remediation fires while the scheduled task is running. No action required; the other instance is completing the work.
- **Exit code 2 with `Offline fallback: the machine requires a full update (state file is stale or unhealthy), but the driver manifest is unavailable` in the log** — the machine is offline and the state file indicates a full update is needed. No operator action; the next scheduled run with network completes the work. **If the log instead shows `Offline fallback: using state file's stored DesiredStateId …`**, the fast path fired and the exit is a degraded-success, not a deferral — the machine is healthy and unchanged.
- **Exit code 3 with `Cannot rename because item at 'C:\Temp\WinREWork\winre.wim' does not exist`** — this is now only reachable if the lock could not be acquired for a non-contention reason. Check the log for `Could not set up program lock at …` earlier in the run. Investigate permissions on `C:\ProgramData\OEM\Logs\`, whether the directory exists, and whether a filesystem issue is affecting the log path.
- **Exit code 3 with `dism /Export-Image failed` in the log** — 7-Zip or DISM problem.
- **Exit code 3 with `cannot deploy a new WinRE image while WinRE is still Enabled`** — `reagentc /disable` returned nonzero. Investigate before retrying.
- **Exit code 3 with `FATAL: WinRE is not enabled at exit`** — the machine lost its recovery partition. This is the pre-patch-5 Device Encryption failure mode. Follow the recovery procedure in [troubleshooting.md](troubleshooting.md).
- **Exit code 3 with `Refusing to retry reagentc /enable`** — the enable-failure loop-breaker fired. Do not retry automatically; the same guard will fire because the state file still records the counter. Resolve the underlying enable failure (see `troubleshooting.md`), delete `C:\Recovery\OEM\winre_state.json`, then re-run.
- **Exit code 3 with `Driver manifest unavailable and no state file exists`** — the machine is offline and has no state file. A first deployment requires a live manifest. Retry when the network is available.

## Rolling back

The script does not have an uninstall path. To disable it:

```powershell
schtasks /Delete /TN "WinRE Manager" /F
schtasks /Delete /TN "WinRE Manager Weekly" /F
```

The state file, log, lock file, and any deployed recovery partition remain. The machine is in a healthy end state and Windows Update will continue to service the recovery image normally. The lock file at `C:\ProgramData\OEM\Logs\WinREManager.lock` is inert once the scheduled task is removed; it can be deleted manually if desired, and it will be recreated if the script is ever run again.

If you need to revert a machine to its pre-WinRE-Manager state, restore the partition layout from a backup. The script does not create one.

To revert the `DesiredStateId` change specifically, see the "Rollback" subsection under "v44 patch 1 migration" above. To revert the later v44 patch code, see the "Rollback for the later v44 patches" subsection above.

## Related documents

- [exit-codes.md](exit-codes.md) — how to interpret the exit codes.
- [state-and-idempotency.md](state-and-idempotency.md) — what the state file records and how it interacts with the scheduled task, plus the offline fallback's residual risk.
- [troubleshooting.md](troubleshooting.md) — when the run fails.
