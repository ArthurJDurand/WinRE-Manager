# Deployment

How to run WinRE Manager on a single machine or across a managed fleet.

## How to deploy

There are two ways to deploy WinRE Manager. Pick the one that matches your situation.

### Single machine, one-off repair

For a single broken machine, run the production script once from an **elevated** PowerShell prompt. It inspects the machine, repairs the recovery environment, writes a state file, and exits. There is no installer, no service, and no configuration file to maintain.

```powershell
# Elevated PowerShell (Run as Administrator)
powershell -ExecutionPolicy Bypass -File .\scripts\WinRE.ps1 -DryRun   # walk the flow, log every decision, change nothing
powershell -ExecutionPolicy Bypass -File .\scripts\WinRE.ps1           # actually deploy
```

The `-ExecutionPolicy Bypass -File` form applies the bypass only to the child process; it does not change the machine's execution policy.

If you want to inspect the machine first, run the read-only harness (`Test-WinRE.ps1`). It requires no elevation and modifies nothing. See the [README](../README.md) for the harness menu options.

For a single-machine deployment, the rest of this document is reference material — the exit-code table, the Audit Mode precondition, and the Device Encryption policy all apply to a one-off run exactly as they apply to a fleet run. You can skip the scheduled-task sections.

### Managed fleet, continuous

For a managed fleet, deploy the script as a scheduled task running as `NT AUTHORITY\SYSTEM`, triggered **at boot** and **weekly**. This is the recommended model. Every machine keeps its recovery environment healthy on its own; a healthy machine's fast path is dominated by Windows' own CIM and PnP enumeration (typically 10–20 seconds), and a full repair runs only when something has changed.

The sections below this point cover the fleet deployment in detail: how to create the task, where to put the script, how to handle the Audit Mode precondition, how to interpret the exit codes, and how to roll out in rings.

## Recommended model

Run `WinRE.ps1` as `NT AUTHORITY\SYSTEM` from a scheduled task, triggered **at boot** and **weekly**. The script is fully idempotent; running it on a healthy machine costs a few seconds of CIM and PnP enumeration and a read-only scan.

Do **not** run it from a user logon script. It modifies partition tables and the BitLocker state of the target recovery partition; those operations require SYSTEM.

## Design invariants at deployment time

The script's design is organized around four rules, in this order — see [`docs/architecture.md`](architecture.md) for the full hierarchy.

1. **Never break Windows RE.**
2. **Never leave a machine without a working recovery route** — to the extent the machine, its OS, and its storage stack allow.
3. **Minimize the `reagentc /disable` → `reagentc /enable` window.**
4. **Do no work unless needed. When work is needed, prepare everything before touching anything.**

Rules 1–3 are invariants: no deployment scenario should weaken them. Rule 4 is the working rule: the discipline that makes the fast path and the enable-only path free of side effects, and that makes the destructive path fail safe.

Each rule has a direct operational translation for a fleet operator.

### Rule 1 — never break Windows RE: canary, do not bulk-push

The script's destructive sequence is protected by a read-only plan, a fail-closed layout assertion, and a reversible shrink window. It does not need to be bullet-proof to be deployed; it needs to be **canaried** so that any regression is caught on one machine, not a thousand.

Before pushing to a fleet, run on one machine end-to-end:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Test-WinRE.ps1            # read-only, no elevation
powershell -ExecutionPolicy Bypass -File .\scripts\WinRE.ps1 -DryRun          # walk the flow, log every decision, change nothing
powershell -ExecutionPolicy Bypass -File .\scripts\WinRE.ps1                  # actually deploy
```

Confirm exit 0 and `Operating mode: DEDICATED` in the log. Only then expand the ring.

### Rule 2 — never leave a machine without a working recovery route: do not interfere with the recovery window

The one case in which the script cannot guarantee a working recovery route on a single run is the post-deletion residual corner: a failure **after** the old recovery partition has been deleted, on a machine whose C: is encrypted, with no successful retry. The trigger set is wider than the commonly cited `New-Partition` or `Format-Volume` pair: the whole-layout assertion (`Assert-RecoveryPartitionLayout`), drive-letter availability, drive-letter assignment, in-place decryption of the new partition, the post-delete extension fallback, the post-delete geometry verification, the planned-extent-available re-check, and the recovery-partition deletion itself when the previous route cannot be restored, all reach the same corner. The correct operational response is **not to interrupt the script while it is inside the destructive window** — every interruption between the delete and the enable is an opportunity for the machine to land in that corner.

Concretely:

- **Do not kill the `WinRE.ps1` process** if it appears to be slow. A full-update pass on an NVMe machine takes 3–5 minutes of I/O; the destructive window is a small fraction of that. If you kill the process inside the window, the recovery route is not restored by the script and the next run must recover from whatever state the interruption left.
- **Do not delete the state file** while a run is in progress. The state file is what the next run uses to identify the deployment identity and the pending state.
- **Do not delete the deferral marker** while a run is in progress. The marker is what the next run uses to decide whether to suppress a retry of the pre-shrink deferral.
- **Do not use a forced reboot** inside the window. A forced reboot between the delete and the enable leaves WinRE disabled and the recovery partition possibly partial.

The scheduled task's own `ExecutionTimeLimit = PT6H` and the script's internal timeouts (300-second BitLocker polling, 5-second sleeps, 15-second network timeout) are the effective limits inside that. Nothing outside the script needs to enforce a shorter one.

### Rule 3 — minimize the `reagentc /disable` → `reagentc /enable` window: do not schedule around it

The window is the interval during which WinRE is not registered and the recovery partition is in the process of being replaced. On a modern SSD the window is typically **15–45 seconds** for the delete / create / format / deploy / `reagentc /setreimage` / `reagentc /enable` sequence. On a spinning disk or a very large WIM it can be longer.

Rule 3 is enforced by the script's own ordering — every preparatory step that does not require a disabled WinRE runs before the disable. Your scheduling decisions should not undo that.

- **Do not schedule a mandatory reboot** to fire during a run. The scheduled task's boot trigger fires on the machine's own reboots; a fleet-wide reboot campaign that overlaps with a weekly run can terminate the script inside the window.
- **Do not use a "stop task if it runs longer than X" setting** on the scheduled task or in an MDM-side policy that could fire inside the window. The scheduled task's own `ExecutionTimeLimit` is the correct upper bound; a second, shorter policy that runs in parallel can kill the run at the worst possible moment.
- **Do not use an orchestration layer that kills the process after a fixed timeout** shorter than the scheduled task's own limit. An RMM tool or an MDM remediation platform with a 60-second or 120-second timeout will kill the script inside the window on a machine where the destructive sequence actually runs; the same tool on a healthy machine will see the fast path complete in 10–20 seconds and never trigger its timeout.

The single-run recovery story is: `Restore-PreviousWinRERoute` on delete failure, `Remove-OrphanPartition` plus `Restore-OSPartitionSize` on create failure, and the enable-only path on a clean-but-disabled state. These handle every ordinary failure. They do not handle a process kill inside the window.

### Rule 4 — do no work unless needed: trust the fast path; do not force reruns

Rule 4 has four concrete operational consequences.

- **Healthy machines take the fast path.** Runtime is dominated by Windows' own CIM and PnP enumeration and the driver-manifest fetch — typically 10–20 seconds on a modern machine. The script itself makes no state changes. There is no reason to tune the schedule around the cost of a healthy run.
- **Do not force a full update on a healthy machine.** Deleting the state file, bumping the manifest version, or bumping `ScriptVersion` forces one full-update pass per machine. Do it only when there is a reason — the migration sections below describe the four version boundaries that do this deliberately.
- **Do not retry a deferral.** The script's deferrals are protective. An Audit Mode deferral, a VMD-query-indeterminate deferral, an OS-fallback BitLocker deferral, a v45 pre-shrink deferral, a v47 race-detector abort, an offline-fallback deferral — none is improved by running the script again before the underlying condition changes. The correct response is to resolve the condition, then re-run.
- **The enable-failure counter is a feature, not a bug.** A machine that fails the enable step three times in a row hits the loop-breaker and exits `EXIT_FATAL` with a "manual intervention required" message. Retrying automatically produces the same result. Resolve the underlying enable failure, delete the state file, then re-run.

## Preconditions

Before the first run on any machine, confirm:

- **Windows build**: 19041+ for Windows 10, 22000+ for Windows 11.
- **7-Zip** present at `C:\Program Files\7-Zip\7z.exe`, or `winget` available so the script can install it.
- **Internet access** to the driver manifest, the three OEM maps, and the base WIM repository for the first deployment on a fresh machine. On a machine whose state file is present and its local safety checks pass, a network outage does not prevent the run — see the "Offline behavior" section below. The endpoints are: `gist.github.com`, `api.github.com`, `downloads.dell.com`, `ftp.ext.hp.com`, and the vendor-specific Lenovo endpoints (`download.lenovo.com`, `support.lenovo.com` — the latter is only reached by the map builder, not by production).
- **Windows is in a normal-running state.** The script refuses to run before any state-modifying action when the machine has not yet completed OOBE. This is the v43 patch 5 (further revision) Audit Mode guard and it matters for freshly imaged machines. See the "Audit Mode and OOBE" section below.
- **At least one eligible internal fixed NTFS volume with 3 GiB free.** The v45 patch 1 workspace selector only accepts fixed NTFS volumes on an allowlisted set of internal/virtual buses. USB, SD/MMC, network, FireWire, Fibre Channel, unknown buses, and reparse-point workspace paths are excluded, even when reported as fixed. A full update defers with `EXIT_WARNING` when no eligible volume has 3 GiB free. See the "Workspace selection" section below.

There is **no BitLocker precondition on the OS volume**. The v43 patch 5 (further revision 5) policy is target-volume-based: the enable-only and dedicated-partition paths do not depend on C:'s BitLocker state at all. If the target recovery partition is encrypted, the script decrypts it in place via `Set-RecoveryPartitionReadyForWinRE` before calling reagentc. The only route that depends on C:'s BitLocker state is the OS-fallback route, because on that route the target volume *is* C:. The destructive partition path does not depend on C:'s state either — as of v44 patch 6 it does not consult C: at all. Neither the OS-fallback gate nor the destructive path modifies C:'s BitLocker state. See the "Device Encryption" section below.

The harness's System diagnostic (`scripts\Test-WinRE.ps1` Option 1) reports `ImageState`, C:'s BitLocker state, the target recovery partition's BitLocker state, and the workspace-selection eligibility. Run it on a representative machine before pushing the task to a fleet.

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
- `ExecutionTimeLimit = PT6H` gives the run enough headroom; the script's own internal timeouts (300-second BitLocker polling, 5-second sleeps, 15-second network timeout) are the effective limit inside that. Do not add a shorter limit at the orchestrator level — see Rule 3 above.
- `RunOnlyIfNetworkAvailable = false` is deliberate as of v44 patch 5. The script now has an offline fallback: when the manifest fetch fails, it trusts the state file's stored `DesiredStateId` and takes the fast path if the local safety checks pass. With `true`, the task would not fire when the network is down, so the fallback would only help manual invocations — not the scheduled path where the machine actually needs it. The offline fallback is self-limiting (`EXIT_WARNING` when a full update is needed, never a silent partial deployment) and safe on a machine whose state file is valid. A first deployment on a machine with no state file will still exit `EXIT_FATAL` when offline, which is correct: the live manifest is required to compute the initial `DesiredStateId`. See the "Offline behavior" section below.
- `StartWhenAvailable = true` handles missed triggers after a cold boot.

## One instance per machine

`WinRE.ps1` assumes exclusive access to its selected image workspace and to the recovery partition it is operating on. Full updates select an eligible fixed NTFS volume and store the selection in the checkpoint for resume. As of **v44 patch 4**, the script enforces single-instance execution with a startup file lock.

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

This is a change from the pre-patch-4 behavior. Before the lock, a concurrent instance would reach Step 2 and fail with `FATAL ERROR: Cannot rename because item at '<workspace>\winre.wim' does not exist.`, which the orchestration layer saw as `EXIT_FATAL` (code 3). As of patch 4, the same scenario produces a clean `EXIT_WARNING` from the second instance.

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
- **If you are diagnosing rather than repairing**, use the read-only harness instead. `scripts\Test-WinRE.ps1` does not acquire the lock, does not touch the workspace, does not modify partitions, and is safe to run at any time, alongside any number of other processes.

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

## Workspace selection (v45 patch 1)

The image workspace is where the script mounts, injects into, and exports the WinRE image during a full update. As of v45 patch 1, the workspace is chosen at run time from a set of eligible volumes rather than assumed to be `C:\Temp\WinREWork`.

### Eligibility rules

The selector accepts only volumes that are:

- **DriveType=Fixed** and **FileSystem=NTFS**.
- On a disk whose **BusType** is in the internal/virtual allowlist: `ATA`, `SATA`, `NVMe`, `RAID`, `SAS`, `Spaces`, `Virtual`, `File Backed Virtual`, `SCM`.
- Not the OS system partition and not a type-coded recovery partition.
- Not labelled `Recovery` or `WINRE`.
- Not reached through a reparse point at `<volume>:\Temp` or `<volume>:\Temp\WinREWork`.

USB, SD/MMC, network, FireWire, Fibre Channel, unknown-bus disks, and reparse-point workspace paths are excluded even when Windows reports them as fixed.

### Selection order

1. **The recorded workspace** from the checkpoint, if it is still eligible and above the free-space floor.
2. **The eligible non-OS volume with the most free space** (fresh-run preference).
3. **The OS volume itself**, only if no eligible non-OS volume is available.

### Free-space floors

- **3 GiB** for a fresh service (mount, inject, export). This is `$MinFreeSpaceGB`.
- **200 MiB** when a verified `WIM_READY` checkpoint exists in the recorded workspace. The `WIM_READY` flag is set at Step 4 after a verified `dism /Export-Image`. `base.wim` is deleted at that point to reclaim workspace capacity before partition planning.

A run that cannot find any eligible volume above the floor defers with `EXIT_WARNING` before touching the machine. Free space on any eligible volume and re-run.

### What this means for you

- **A machine whose only fixed NTFS volume is the OS volume can still take a full update** — the OS volume is used as the last resort. But the v45 pipeline will not proceed if C: has less than 3 GiB free.
- **A machine whose only fixed NTFS volume is on a USB-attached drive defers.** The script will not use a USB hard drive as its workspace, even if Windows reports it as fixed, because a full-update pass can take 3–5 minutes of I/O and the drive could be removed.
- **Stale workspaces are cleaned automatically when no valid checkpoint exists.** The script removes only canonical `X:\Temp\WinREWork` directories on eligible internal volumes. It never touches user files or arbitrary temporary directories elsewhere.

The harness Option 1 diagnostic reports the eligible workspace candidates and their free space.

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
- **The OS volume's BitLocker state is consulted only on the OS-fallback route.** On that route the target volume *is* C:, and reagentc refuses to enable WinRE on an encrypted OS volume. The gate checks C:'s `VolumeStatus` before deploying and defers unless it is `FullyDecrypted`. The script never modifies C:'s state. As of v44 patch 6, the destructive partition path does not consult C:'s state either — the dedicated-partition path's success or failure depends on the partition geometry, not on C:'s encryption state.
- **New partitions are created with the recovery type GUID applied at `New-Partition` time.** This closes the window between partition creation and `Set-RecoveryPartitionAttributes` during which a plain Basic Data partition could be claimed by the Device Encryption service.
- **No BitLocker suspension.** The v43 patch 5 function `Suspend-BitLockerForWinRE` was deleted. Suspension does not prevent Device Encryption from claiming new partitions — proven in the field — and it is useless for OS-fallback, where reagentc refuses regardless.

### Why the earlier further-revision policy was replaced

The v43 patch 5 (further revision) design gated on **C:'s** BitLocker state at startup. It deferred any run where C: was not `FullyDecrypted` with `Protection On`. That design was correct in the sense that it prevented the Dell Latitude 3550 / HP ProBook 450 G10 failure mode, but it was over-broad: it deferred on the `FullyEncrypted + Protection Off` state, which is the normal state of every fresh Win11 local-account machine before a Microsoft account sign-in. The startup gate was deferring on the majority of the fleet.

The change was driven by a same-machine test on 2026-09-29. With C: in the `FullyEncrypted + Protection Off` state, `reagentc /enable` against a dedicated recovery partition succeeded while `reagentc /enable` against the OS volume failed on the same machine in the same session. That established that reagentc's check is on the **target** volume. The policy was inverted accordingly: prepare the target; do not gate on C: except on the OS-fallback route, where the target *is* C:.

### What this means for you

The scheduled task does not need to be aware of the machine's encryption state. The script handles it. But three deployment-time facts are worth knowing:

- **On a dedicated-partition machine, the first run may take up to 5 minutes longer than usual if the target recovery partition is encrypted.** The helper will spend up to 300 seconds decrypting it. A 1 GB recovery partition decrypts in well under a minute on NVMe, so the timeout is generous; but if you are benchmarking or scheduling tightly, expect the possibility.
- **On a machine that falls back to OS-fallback, the run defers if C: is not `FullyDecrypted`.** The log names the C: state and tells the operator what to do: complete decryption of C: (`manage-bde -off C:`) or wait for an in-progress decryption to finish. Actions that complete encryption, add a protector, or enable protection do **not** resolve the state — they make C: more protected, not less. This deferral does not consume the enable-failure counter.
- **On a machine whose destructive attempt fails after the old recovery partition has been deleted** — specifically a `New-Partition` or `Format-Volume` failure — **the run falls through to OS-fallback.** The OS-fallback gate then consults C: and defers cleanly if C: is encrypted. As of v45 patch 1 the shrink is no longer inside the destructive window: a failed pre-shrink returns `Deferred` with the old route preserved and never reaches OS-fallback, so the shrink case no longer produces this fall-through.

If you are deploying to a fresh fleet and want the first run to succeed rather than defer on the OS-fallback route, wait until `manage-bde -status C:` shows `Fully Decrypted` before pushing the task. On a modern SSD, decrypting C: from a mid-encryption state typically takes 30–90 minutes.

## VMD fail-closed guard (v44 patch 6)

The VMD hardware presence check determines which driver set the script selects. As of v44 patch 6 the check is fail-closed: if the PnP enumeration reports an error during the query, the run treats VMD presence as **indeterminate** rather than as absent, and defers with `EXIT_WARNING` before committing any state.

The reasoning: guessing "absent" on a machine that genuinely has VMD hardware would select a driver set that omits the VMD package, and the deployed WinRE would not be able to see the OS disk. An empty device list from an errored enumeration is not evidence of absence. The cost of a deferral is one pipeline run; the cost of guessing wrong is a machine with a non-functional recovery environment.

A run that defers this way leaves the machine unchanged: no WIM deployed, no partition touched, no `reagentc` call made. The next scheduled run retries the enumeration; a transient PnP service issue is the most likely cause. If the deferral fires repeatedly, resolve the underlying PnP service issue — the deferral is a protective stop, not a degraded-success.

## Offline behavior (v44 patch 5; fast-path gate updated in v47 patch 1)

The script's network calls — the driver manifest fetch, the OEM map fetches, and the base WIM download — each default to a 15-second per-call timeout. The timeout applies to each individual request, not to the aggregate; the retry loops (2 attempts for the manifest, 3 for the OEM pack download) can multiply it. Before v44 patch 5, an offline machine would hang for over 10 minutes across the aggregate of the default 100-second timeouts before failing. That is now capped at roughly 90 seconds in the fully-offline case, dominated by the fixed sleeps in the retry loops rather than by the network timeouts.

More importantly, v44 patch 5 adds an **offline fallback** for the manifest fetch. The behavior depends on the state file's contents.

### Case 1 — state file present, its fast-path checks pass

The script reads the state file at `C:\Recovery\OEM\winre_state.json` and trusts its stored `DesiredStateId` directly. It does **not** recompute the ID from cached inputs — recomputing would require the OEM pack version, which is resolved from the OEM map, another gist on the same unavailable network.

The local safety checks remain fully enforced and do not depend on the manifest. Under v47, the fast-path conditions the offline path validates are the same as the online path:

- WinRE is `Enabled`.
- The state file's `DesiredStateId` matches the stored value (used directly; the DSI is not recomputed offline).
- The drift detector reports no change: the currently-registered WinRE's DISM servicing metadata (`Version` + `SPBuild`) matches the state file's `DeployedWinREMetadata` anchor, and no force-upgrade, driver-version change, or missing-anchor condition applies.
- The recovery-partition layout is one of the healthy shapes: exactly one **type-coded** recovery partition on the OS disk with the active location on it, or no recovery partition with `UsedOSFallback = $true` in the state file and the active location on the OS partition.

If all pass, the script takes the fast path, logs `Offline fallback: using state file's stored DesiredStateId <id>`, verifies the machine is healthy, and exits `EXIT_WARNING` (code 2) because `$Script:offlineFallback = $true` is set. The exit code is a degraded-success signal, not a failure. The machine is unchanged. Total runtime is under 90 seconds.

**The v46 → v47 transition on offline machines.** A v46-or-earlier state file lacks `DeployedWinREMetadata`. Its absence forces `$needInject = $true` regardless of network state, and the offline guard then fires: the machine needs a full update, but the live manifest is required for that, so the run exits `EXIT_WARNING` without further work. From the second v47 run onward, the state file has the anchor written by the first successful online run, and the offline fast path can fire normally. The one-time cost of the v47 migration on offline machines is therefore: the first scheduled v47 run must happen while the machine can reach the driver manifest.

**On the next scheduled run with network**, the script performs a full manifest fetch, detects any hardware drift that occurred while offline (a CPU swap, a BIOS update that flipped VMD, a motherboard replacement), and either takes the fast path (if no drift) or forces a rebuild (if drift). The residual risk is that a machine whose hardware changed while offline could take the fast path with a stale DSI; the next successful manifest fetch corrects it. A `LocalInputsId` field in the state file would close this residual risk; it is planned as its own version boundary.

### Case 2 — state file present, its fast-path checks fail

If the state file indicates a full update is needed (metadata drift, force-upgrade, driver version drift, or a locally-detected input change), the script cannot proceed offline — a full update requires the live manifest to resolve the driver set. It logs:

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

On a healthy NVMe laptop this is roughly 3–5 minutes of I/O and CPU. Machines with a suitable existing recovery partition re-use it; no partition work occurs on healthy machines. This is the intended behaviour and the reason the `Migration Note` in `CHANGELOG.md` is present.

Two cases that are handled cleanly without operator attention:

- **Machines with `PendingReboot = true`.** The DSI mismatch is detected before the pending-reboot block runs, so the full-update path executes rather than the pending-reboot repair path. No machine is lost.
- **Machines stuck in the enable-failure loop-breaker (`EnableFailureAttempts >= 3`).** The DSI mismatch makes the state file stale before the loop-breaker check runs, so those machines get one fresh attempt under the new ID. If the underlying cause is resolved, they recover; if not, they re-enter the loop-breaker on the fourth fresh attempt.

Plan for the v44 patch 1 rollout the same way you would plan for a manifest-version bump: brief the operator community, expect the first run after the update to be slower than usual, and check the log on a canary machine to confirm the full-update path executed and the state file was rewritten under the new ID.

### Rollback

Change `$ScriptVersion` back to 43, revert the `Get-DesiredStateId` `$parts` array, and restore the previous `Get-HardwareObject` if the manufacturer normalisation differed. No data is lost; another fleet-wide rebuild occurs on the next run.

## v45 patch 1 migration

The v45 patch 1 revision is the shrink-first redesign of the destructive partition path. It bumps `ScriptVersion` from 44 to 45, which changes the `SCRIPT` component of the `DesiredStateId` and forces one full-update pass per managed machine on the next scheduled run — exactly the same shape as the v44 patch 1 migration, and for the same reason: the DSI is the deployment-identity fingerprint, and any change to the inputs that determine the deployed artifact is a version boundary.

The v45 pass is **not** slower on a healthy machine than any other full-update pass. The reorder moves the shrink into the reversible window; the total work is the same. Machines with a suitable existing recovery partition reuse it and perform no destructive work.

Concretely, on the first run after the update, every machine will:

1. Compute the new `DesiredStateId` (with `SCRIPT=45`).
2. Compare it to the state file written by v44 (any patch).
3. Find a mismatch, set `needInject = $true`, and take the full-update path.
4. Rebuild the WIM, deploy it, and write a state file under the new ID.
5. Return to the fast path on the second run.

Two cases handled without operator attention:

- **Machines carrying a deferral marker at `C:\Recovery\OEM\winre_partition_deferred.json`.** The marker was introduced in v45 patch 1 and is keyed by `DesiredStateId`; it is honored only when the current run computes the same DSI. No operator action is needed on the v44→v45 transition, because no v44-era marker can exist.
- **Machines with `PendingReboot = true` or `EnableFailureAttempts >= 3`.** Handled the same way as in the v44 patch 1 migration: the DSI mismatch is detected before the pending-reboot and loop-breaker blocks.

### Rollback

Change `$ScriptVersion` back to 44. The state file written under the v45 DSI becomes stale, the next run takes the full-update path under the older behavior, and the pipeline falls back to the pre-v45 destructive sequence. No data is lost; another fleet-wide rebuild occurs on the next run.

## v46 patch 1 migration

The v46 patch 1 revision clamps `tailEnd` to `diskSize − 1 MiB` before aligning in `Get-PartitionPlan`. It bumps `ScriptVersion` from 45 to 46, which changes the `SCRIPT` component of the `DesiredStateId` and forces one full-update pass per managed machine on the next scheduled run — the same shape as the v44 patch 1 and v45 patch 1 migrations.

The v46 pass is **not** slower on a healthy machine than any other full-update pass. The clamp changes the plan computation only when the last partition on the disk ends at `diskSize` (equivalently, at the disk-end reserve boundary); on every other layout, the plan is identical to v45's. Machines with a suitable existing recovery partition reuse it and perform no destructive work.

The distinguishing behaviour of this migration is what happens to machines that v45 patch 1 left in OS-fallback because of the plan-clamp bug. Under v45, the plan was rejected after the old recovery partition had already been deleted, and the machine fell back to OS-fallback. The state file recorded the failing `DesiredStateId` and was accepted on every subsequent run, so the machine stayed in OS-fallback and did not retry. The v46 patch 1 `ScriptVersion` bump clears that state automatically: the state file is stale under the new DSI, the next run takes the full-update path, and the plan-clamp fix makes the plan valid on the same layout v45 rejected. The machine reaches `DEDICATED` on the first full-update pass.

Concretely, on the first run after the update, every machine will:

1. Compute the new `DesiredStateId` (with `SCRIPT=46`).
2. Compare it to the state file written by v45 patch 1.
3. Find a mismatch, set `needInject = $true`, and take the full-update path.
4. Rebuild the WIM, deploy it, and write a state file under the new ID.
5. Return to the fast path on the second run.

Two cases handled without operator attention:

- **Machines in OS-fallback from the v45 plan-rejection corner.** As above, the DSI mismatch invalidates the state file, the plan is re-evaluated under the clamp, and the machine converges.
- **Machines carrying a v45 deferral marker at `C:\Recovery\OEM\winre_partition_deferred.json`.** The marker is keyed by `DesiredStateId`; it is stale under the v46 DSI and is cleared on read by `Read-PartitionDeferral`. No operator action is needed.

### Rollback

Change `$ScriptVersion` back to 45. The state file written under the v46 DSI becomes stale, the next run takes the full-update path under v45's behavior, and the pipeline is once again vulnerable to the plan-clamp bug on machines whose last partition ends at `diskSize`. No data is lost; another fleet-wide rebuild occurs on the next run.

## v47 patch 1 migration

The v47 patch 1 revision introduces the third-party driver strip stage and rewrites several other rebuild-path elements. It bumps `ScriptVersion` from 46 to 47, which changes the `SCRIPT` component of the `DesiredStateId` and forces one full-update pass per managed machine on the next scheduled run — the same shape as the v44 patch 1, v45 patch 1, and v46 patch 1 migrations.

The v47 release is architecturally different from the earlier `ScriptVersion` bumps. v44 added DSI fields; v45 and v46 patch 1 each corrected a specific bug that had left machines stuck. v47 patch 1 changes **what a rebuild produces**, not just how a rebuild is triggered: the mounted image is stripped to zero third-party drivers, proven by re-enumeration, and only then is the current driver recipe injected. The deployed WIM bytes therefore differ from v46's on the same inputs. The version bump is the mechanism by which the fleet converges on the strip-normalized driver set.

The v47 pass is **not materially slower on a healthy machine than any other full-update pass**. The strip stage on an already-clean image is a no-op — the ASUS field run logged `Strip: image already has zero third-party drivers` in under a second. On a machine whose registered image carries the OEM/VMD drivers from an earlier WinRE Manager cycle, the strip removes them and the current recipe is injected; the total time depends on the driver set size, not on the strip itself.

The distinguishing property of this migration is the metadata anchor. Every machine's first v47 run writes a `DeployedWinREMetadata` field to the state file — the DISM servicing metadata (`Version` + `SPBuild`) of the WIM that was actually deployed. The field is the anchor the v47 drift detector compares against on every subsequent run. A machine whose state file lacks the anchor (all v46-or-earlier state files) forces a rebuild regardless of whether any other input changed; a machine whose state file has the anchor is evaluated against it.

Concretely, on the first run after the update, every machine will:

1. Compute the new `DesiredStateId` (with `SCRIPT=47`).
2. Compare it to the state file written by v46 (any patch).
3. Find a mismatch, set `needInject = $true`, and take the full-update path.
4. Obtain a base WIM via the v47 three-source preference order (registered image → hash-validated LKG → GitHub).
5. Strip the mounted image to zero third-party drivers, proving zero by re-enumeration.
6. Inject the current OEM and VMD recipe, run ResetBase, export the optimized WIM.
7. Deploy, register, and write the state file with the new DSI and the `DeployedWinREMetadata` anchor.
8. Return to the fast path on the second run.

Three cases handled without operator attention:

- **Machines with `PendingReboot = true` or `EnableFailureAttempts >= 3`.** As in every prior migration: the DSI mismatch is detected before the pending-reboot and loop-breaker blocks, so the full-update path executes and the counters are reset.
- **Machines carrying a v46 deferral marker at `C:\Recovery\OEM\winre_partition_deferred.json`.** The marker is keyed by `DesiredStateId`; it is stale under the v47 DSI and is cleared on read by `Read-PartitionDeferral`.
- **Machines whose registered WinRE has been serviced by Windows Update in a way that changed its `Version` or `SPBuild`.** The metadata comparison would fire on the second v47 run, but is subsumed by the DSI mismatch on the first — the rebuild happens regardless.

The offline-migration case is one step longer. On a machine whose first v47 run is offline, the state file lacks the anchor, `$needInject` is forced to `$true`, and the offline guard fires — the run exits `EXIT_WARNING` without a rebuild. The first successful online run writes the anchor; from the second v47 run onward, the offline fast path works normally. If a machine in your fleet runs offline for an extended period, expect its first online v47 run to be the one that writes the anchor.

### Rollback

Change `$ScriptVersion` back to 46 and revert the strip stage, the three-source selection logic, the race detector, and the metadata-drift changes. The state file written under the v47 DSI becomes stale, the next run takes the full-update path under v46's behavior, and the strip-normalized image is replaced with a lineage-seeded one. The `DeployedWinREMetadata` field becomes inert on rollback — it is read only by the v47 drift detector. No data is lost; another fleet-wide rebuild occurs on the next run.

## Later patches (no ScriptVersion bump)

The v44 patches 2 through 8 and the v46 patch 2 additions do **not** bump `ScriptVersion` and do **not** change the `DesiredStateId`. They apply to every subsequent run without a state-file action. A machine that is already healthy continues to take the fast path. A machine that was mid-deployment when the patch rolled out continues from where it was — the checkpoint and state-file schemas are unchanged.

The **v47 patch 2** revision is also not a fleet-wide rebuild: it does not bump `ScriptVersion`, and its only DSI-value change is a one-time event on a narrow machine class (machines with a padded `Win32_ComputerSystemProduct.Version` field). It is documented under `### v47 patch 2 specifically` above. The **v47 patch 1** revision is not in this list; it bumps `ScriptVersion` and is documented under "v47 patch 1 migration" above.

- **v44 patch 2** adds `dism /cleanup-image /StartComponentCleanup /ResetBase` to the full-update pipeline; the size reduction materialises on the next natural rebuild, not immediately.
- **v44 patch 3** adds the destructive-path C: encryption guard inside `Ensure-AdequateRecoveryPartition` (removed in v44 patch 6) and a `base.wim` cleanup on the injection-failure abort branch (retained).
- **v44 patch 4** adds the program lock at `C:\ProgramData\OEM\Logs\WinREManager.lock`, so a second concurrent instance fails fast with `EXIT_WARNING` instead of colliding at Step 2.
- **v44 patch 5** adds the offline fallback for the driver manifest fetch and a 15-second timeout on every network call.
- **v44 patch 6** removes the v44 patch 3 destructive-path C: guard; makes Lenovo OEM-pack resolution distinguish five states; makes VMD hardware detection fail-closed; adds the Step 2 stale-file cleanup on the normal path; and corrects the OS-fallback remediation wording.
- **v44 patch 7** closes a non-convergence loop by making the type-coded classifier authoritative across every recovery-partition decision — the fast-path count, the active-location classifier, the final-verification classifier, and `Find-SuitableRecoveryPartition`. It also clears the VMD extraction directory before each extraction, and adds C:'s actual encryption state to the destructive-replacement WARN (diagnostic only; the decision to proceed is unchanged).
- **v44 patch 8** reorders workspace initialization so that healthy fast-path runs, enable-only repairs, and offline deferrals no longer validate checkpoints, wipe stale scratch files, or create the workspace. Full-update checkpoint and resume behavior is otherwise unchanged.
- **v46 patch 2** adds three log lines that record the registered WinRE version, the source WIM build, and the post-deploy WIM build on every run, and guards the two `Get-Partition -DiskNumber` calls in `Get-RecoveryPartitions` against the empty-disk read that throws `CmdletizationQuery_NotFound_DiskNumber` on machines with an SD/MMC card reader. It also applies four post-review hardenings of `Ensure-AdequateRecoveryPartition` — the pre-deletion resolver guard, the extension-fallback bucket cap, the layout-assertion fail-closed branch, and the deletion-failure partial-rollback reporting. The build-logging values do not enter the `DesiredStateId`; the read guard silences a cosmetic error; the four hardenings change only the failure behaviour of the destructive sequence.

Because none of these patches changes `ScriptVersion` or the `DesiredStateId`, an already-completed machine will not rerun automatically; the deployment mechanism must invoke the script explicitly to pick the fixes up. The next natural rebuild (manifest bump, OEM pack version change, Windows build change, or CPU/VMD presence change) picks them up regardless.

### Rollback for later non-bumping patches

- **v44 patch 2**: remove the `dism /cleanup-image /StartComponentCleanup /ResetBase` invocation from Step 3.
- **v44 patch 3**: the C: guard is already removed; the `base.wim` cleanup on the abort branch is retained and does not need rollback.
- **v44 patch 4**: remove the lock acquisition block at the top of the main `try` block and the corresponding release in the `finally` block.
- **v44 patch 5**: remove the offline fallback branch and revert `$NetworkTimeoutSeconds` to its absence on each call.
- **v44 patch 6**: restore the v44 patch 3 destructive-path C: guard inside `Ensure-AdequateRecoveryPartition`; revert `Get-LenovoWinPEPack` to a two-state return; revert the VMD presence check to treat enumeration errors as absent; remove the Step 2 stale-file cleanup; restore the earlier OS-fallback remediation wording.
- **v44 patch 7**: revert the classifier changes — `Find-SuitableRecoveryPartition` and the main-flow `$existingRecoveryParts` back to accepting label-OR-type; the active-location classifier and the final-verification classifier back to promoting a label-only match to DEDICATED — remove the VMD extraction directory cleanup, and remove the C: encryption-state lookup from the destructive-replacement WARN.
- **v44 patch 8**: restore the pre-patch-8 workspace-initialization ordering.
- **v46 patch 2**: remove the three build-drift log lines (`WinRE status: ..., Version: ...`, `Source WIM build: ...`, `Post-deploy WIM build: ...`) from the startup, force-upgrade, and post-deploy paths; remove the `Version` extraction from `Get-WinREState`; remove the `-ErrorAction SilentlyContinue` guard from the two `Get-Partition -DiskNumber` calls in `Get-RecoveryPartitions`; revert the four `Ensure-AdequateRecoveryPartition` hardenings to their pre-v46-patch-2 form.

None of these rollbacks affects the state-file schema or the `DesiredStateId`. (The v47 patch 1 rollback does affect the schema — it introduces the `DeployedWinREMetadata` field — and is documented separately under "v47 patch 1 migration" above.)

## Exit code handling

The script's exit codes carry meaning. See [exit-codes.md](exit-codes.md) for the full matrix.

For MDM / orchestration:

| Exit code | Recommended action |
|---|---|
| 0 | None. Record success. |
| 1 | Reboot the machine at the next convenient window. The script will finish on the next boot. |
| 2 | Investigate. WinRE is functional but degraded, or the script deferred work, or the enable step failed and the counter incremented. Collect the log and check the state file's `LastUpdated` timestamp, its `LastEnableResult` field, and whether a deferral marker exists at `C:\Recovery\OEM\winre_partition_deferred.json`. **Eleven** distinct cases are documented in [exit-codes.md](exit-codes.md): OS-fallback, **v47 strip-failure abort**, Step 3 → Step 4 pipeline gate, Audit Mode deferral, VMD-query-indeterminate deferral, OS-fallback BitLocker deferral, **v45 pre-shrink deferral**, enable-only failure, concurrent-instance deferral (v44 patch 4), offline-fallback deferral (v44 patch 5), and **v47 race-detector abort** at the two `/disable` sites. The concurrent-instance case is **not a failure** — the other instance is doing the work. The offline-fallback fast-path case is a **degraded-success** — the machine is healthy and unchanged. The VMD-query-indeterminate, v45 pre-shrink, and v47 race-detector cases are **protective deferrals** — no state was committed. |
| 3 | Investigate. The run failed and did not write state, or the enable-failure loop-breaker fired. Collect the log. Do not retry automatically. |

Do **not** treat exit code 2 as success. A machine in OS-fallback is intentionally reported as a warning; it will be treated as a healthy machine by the fast path only if the state file records `UsedOSFallback = true` for the current `DesiredStateId`. A machine on which the Audit Mode guard or a v45 pre-shrink deferral fired will have an unchanged (or absent) state file and a single deferral line in the log. See [exit-codes.md](exit-codes.md) for how to distinguish the eleven cases.

Do **not** configure retry loops that ignore the exit code and re-run unconditionally. Deferrals are not improved by retrying — the same gate will fire on the next run (Rule 4). Enable failures are handled by the counter; after three consecutive failures the loop-breaker fires and requires manual intervention. The concurrent-instance deferral is not a failure at all; retrying while the other instance is still running will simply produce another `EXIT_WARNING`. The VMD-query-indeterminate deferral is not improved by retrying — the underlying PnP service issue must be resolved. The v45 pre-shrink deferral is not improved by retrying until the constraint is resolved (free space on C:, disk layout, oversized recovery partition, transient volume read, or shrink failure). The v47 race-detector abort is not improved by retrying immediately — the underlying Windows Update servicing of the registered WinRE is a transient condition, and the next scheduled run (or a manual re-run after the WU settles) is the correct response. The v47 strip-failure abort is not improved by retrying until the specific strip failure has been diagnosed — see [troubleshooting.md](troubleshooting.md) for the specific failure modes. Resolve the underlying condition, then re-run.

## MDM / Intune

Deploy via a Win32 app or a PowerShell script platform script. The Intune "Scripts and remediations" feature is well-suited:

- **Detection rule:** `Test-Path C:\ProgramData\OEM\Logs\WinRE-Manager.log` and `reagentc /info` reports `Enabled`.
- **Remediation script:** `WinRE.ps1` invoked as SYSTEM.
- **Run in 64-bit PowerShell on the system:** required.

For a curated deployment, package the script as an Intune Win32 app with a detection rule on the log file and `reagentc` state. Run once, then allow the built-in weekly scheduled task to keep the state fresh.

When using Intune to push a remediation, be aware that the remediation script may run outside the scheduled task's `IgnoreNew` gate. As of v44 patch 4, the program lock handles this: if the weekly task happens to be running at the same moment, the remediation exits with `EXIT_WARNING` (code 2) and the message `Another WinRE Manager instance is already running (program lock file is exclusively held)`. This is not a failure. The remediation will succeed on the next cycle, or you can wait for the scheduled task to complete and re-run the remediation manually.

**Do not disable the lock to "fix" the remediation.** Before patch 4, the same collision caused an `EXIT_FATAL` (code 3) with a rename error. Some Intune remediation pipelines treated that as a hard failure and retried aggressively, which could produce a cascade of colliding runs. The lock converts the collision into a clean, self-limiting `EXIT_WARNING`. If your Intune pipeline retries on any non-zero exit, adjust it to treat code 2 as a soft failure (route to a queue) and code 3 as a hard failure (investigate). See [exit-codes.md](exit-codes.md) for the recommended orchestration policy.

## Hosting your own maps, manifest, and base WIM repository

By default, WinRE Manager fetches the driver manifest, the three OEM maps, and the base WIM repository from the project maintainer's GitHub account. All five artifacts can be replaced with self-hosted equivalents so your fleet does not depend on those external endpoints.

See [self-hosting.md](self-hosting.md) for the trust model, the exact URLs and variables to change, the map-builder scripts, and the air-gapped deployment procedure.

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

### v44 patch 1 specifically

Add a step 0 before the canary ring: run the current script on one machine and confirm the full-update pass completes and the state file is rewritten under the new `DesiredStateId`. Then roll out normally. The `Migration Note` in `CHANGELOG.md` and the "v44 patch 1 migration" section above describe the expected behaviour.

### v44 patch 3 specifically

No state-file action is needed on healthy machines — the surviving part of the fix (the `base.wim` cleanup) is exercised on the next full-update pass, and the guard portion is removed by v44 patch 6 anyway. See the "Later v44 patches" section above.

### v44 patch 4 specifically

Watch for the new `EXIT_WARNING` from concurrent invocations in your orchestration logs. A cluster of these on a machine usually means an RMM tool or a manual operation overlapped with the scheduled task; it is a signal about the operator side, not a script defect.

### v44 patch 5 specifically

The first observable change is faster failure on machines with network issues. Machines that previously exited `EXIT_FATAL` after ~100-second timeouts now exit `EXIT_WARNING` after ~15-second timeouts, and healthy machines take the fast path offline instead of failing. Confirm on a canary that an offline run exits 2 with the `Offline fallback: using state file's stored DesiredStateId …` line rather than 3.

### v44 patch 6 specifically

Watch for:

- The new VMD fail-closed deferral on machines with an unhealthy PnP service. These exit 2 with the `VMD hardware detection was indeterminate` message.
- The corrected OS-fallback remediation message naming `manage-bde -off C:` instead of the earlier (wrong) "complete encryption" guidance.
- The new Lenovo five-state resolution log lines when the map has a malformed entry.

### v44 patch 7 specifically

Watch for machines that exit 0 after one full-update pass where they previously cycled through rebuilds. Before patch 7, a machine with a Basic Data partition labelled "Recovery" on the OS disk never converged: the fast-path count included the label-only partition, so the "exactly one recovery partition on the OS disk" condition was never satisfied, while the destructive path correctly refused to delete it. After patch 7 the classifier, count, and destructive path all agree on the type-code rule, so the machine converges — either to a proper `DEDICATED` state (if the OS-shrink succeeds) or stably to OS-fallback (if it does not).

### v44 patch 8 specifically

No state-file action and no observable orchestration change. The reorder is an internal cost reduction for healthy paths. Confirm on a canary that a fast-path run still exits 0 with the same log shape as before.

### v45 patch 1 specifically

The v45 revision bumps `ScriptVersion` and forces one full-update pass per managed machine. The pass itself is not slower than a normal full-update pass. Watch for:

- **Machines that exit 0 after the first full-update pass.** The normal case; the machine converged to `DEDICATED` (via the reuse path, or via a successful destructive replacement). Returned to the fast path on the second run.
- **Machines that exit 2 with `Dedicated replacement deferred before partition deletion (<Reason>)` in the log.** The v45 pre-shrink deferral fired; the old recovery partition is preserved and the machine is unchanged. Investigate the `<Reason>`. Common causes: insufficient free space on C:, blocking layout, oversized recovery-typed partition, transient volume read, or shrink failure. Resolve the constraint and delete `C:\Recovery\OEM\winre_partition_deferred.json` to force a retry.
- **Machines that exit 2 with the compound signature `Pre-deletion inventory:` followed in the same run by `OS-fallback deferred: C: could not be confirmed fully decrypted`.** This is the post-deletion residual corner the `[v45 patch 1]` CHANGELOG entry documents. The v45 reorder narrowed it: only `New-Partition` or `Format-Volume` failures after deletion, on an encrypted C:, now reach the corner (the shrink case is closed). **Capture the full log and file a bug** — the project wants field data on this corner.
- **Machines with an extension-failure fallback log line.** If the log shows `Extension-failure fallback: creating recovery partition`, the run continued with a slightly different geometry than the plan and exited 2. This is expected. If the log shows `Extension-failure fallback unavailable`, the machine fell through to the OS-fallback decision. Check the machine's end state with the harness.

Watch for:

- **Exit code 2 with `UsedOSFallback = true` in the state file and a state file `LastUpdated` timestamp newer than the run's start time** — the post-delete partition creation could not complete and the run deliberately ended in OS-fallback. (As of v45 patch 1, a shrink failure no longer reaches this path — the pre-shrink runs in the reversible window and defers with the old route preserved.) The log will show the `Dedicated recovery partition creation failed after all attempts.` banner.
- **Exit code 2 with `Setup\State\ImageState=…` in the log and the state file absent or unchanged** — the Audit Mode / OOBE guard fired. The machine has not finished OOBE. This is expected on freshly imaged machines that are still pre-first-sign-in; wait for the machine to reach a normal desktop and re-run on the next scheduled trigger.
- **Exit code 2 with `VMD hardware detection was indeterminate; deferring because the driver set cannot be safely determined.` in the log and the state file unchanged (or the state file absent)** — the VMD hardware presence check could not complete because of a PnP enumeration error. No WIM was deployed, no partition was touched, no `reagentc` call was made. Resolve the PnP service issue and re-run. Do not retry immediately; the same check will fire.
- **Exit code 2 with `OS-fallback deferred: C: could not be confirmed fully decrypted (Test-VolumeEncrypted=…)` in the log and the state file's `LastUpdated` timestamp unchanged (or the state file absent)** — the dedicated replacement could not complete and the run fell through to the OS-fallback route, whose target (C:) is not confirmed fully decrypted. No WIM was deployed and no `reagentc` call was made. Wait for C: to reach `FullyDecrypted`, or complete decryption of C: with `manage-bde -off C:`, then re-run on the next scheduled trigger. Do not retry immediately.
- **Exit code 2 with `Dedicated replacement deferred before partition deletion (<Reason>)` in the log and the state file unchanged** — the v45 pre-shrink deferral fired. The old recovery partition is still present and WinRE is still registered to it. Free space on C:, correct the disk layout, address the oversized partition, retry a transient volume read, or investigate the shrink or route-restore failure as appropriate, then delete `C:\Recovery\OEM\winre_partition_deferred.json` (and, if you also want to clear the deployment identity, `C:\Recovery\OEM\winre_state.json`) to force a retry.
- **Exit code 2 with `Image injection did not complete. Stopping before Step 4 and before any deployment.` in the log** — OEM or VMD injection failed and the pipeline gate stopped the run before deployment. The WIM was not deployed, the partition was not touched, and WinRE was not disabled. The checkpoint was set back to 2. The next run retries from step 2. Investigate the injection failure (OEM pack download, extraction, INF validation, or VMD driver download).
- **Exit code 2 with `Enable-only /enable failed (attempt N of 3)` or `Enable-only /enable refused with the BitLocker error after the target partition was confirmed unencrypted (attempt N of 3)` in the log and a non-`"ok"` `LastEnableResult` in the state file** — the enable step failed on a machine whose deployment is current. The counter incremented. Investigate the enable failure itself (ReAgent.xml corruption, missing registration, a Windows component problem, an antivirus product holding a file). The next run retries enable-only. If the counter reaches 3, the loop-breaker fires on the following run and the exit code becomes 3.
- **Exit code 2 with `Another WinRE Manager instance is already running (program lock file is exclusively held)` in the log** — a concurrent instance holds the lock. This is not a failure. It appears when a manual invocation overlaps with a scheduled run, or when an Intune remediation fires while the scheduled task is running. No action required; the other instance is completing the work.
- **Exit code 2 with `Offline fallback: the machine requires a full update (state file is stale or unhealthy), but the driver manifest is unavailable` in the log** — the machine is offline and the state file indicates a full update is needed. No operator action; the next scheduled run with network completes the work. **If the log instead shows `Offline fallback: using state file's stored DesiredStateId …`**, the fast path fired and the exit is a degraded-success, not a deferral — the machine is healthy and unchanged.
- **Exit code 2 with the compound signature `Pre-deletion inventory:` followed in the same run by `OS-fallback deferred: C: could not be confirmed fully decrypted`** — the post-deletion residual corner that the `[v45 patch 1]` CHANGELOG entry documents. The existing type-coded recovery partition was deleted and a post-deletion `New-Partition` or `Format-Volume` failure occurred, and the OS-fallback gate deferred because C: is encrypted. The machine ends with neither a dedicated recovery partition nor OS-fallback. **Capture the full log and file a bug** — the project wants field data on this corner. See [troubleshooting.md](troubleshooting.md) for the operator-facing procedure.
- **Exit code 3 with `Cannot rename because item at '<workspace>\winre.wim' does not exist`** — this is now only reachable if the lock could not be acquired for a non-contention reason. Check the log for `Could not set up program lock at …` earlier in the run. Investigate permissions on `C:\ProgramData\OEM\Logs\`, whether the directory exists, and whether a filesystem issue is affecting the log path.
- **Exit code 3 with `dism /Export-Image failed` in the log** — 7-Zip or DISM problem.
- **Exit code 3 with `cannot deploy a new WinRE image while WinRE is still Enabled`** — `reagentc /disable` returned nonzero. Investigate before retrying.
- **Exit code 3 with `FATAL: WinRE is not enabled at exit`** — the machine lost its recovery partition. This is the pre-patch-5 Device Encryption failure mode. Follow the recovery procedure in [troubleshooting.md](troubleshooting.md).
- **Exit code 3 with `Refusing to retry reagentc /enable`** — the enable-failure loop-breaker fired. Do not retry automatically; the same guard will fire because the state file still records the counter. Resolve the underlying enable failure (see `troubleshooting.md`), delete `C:\Recovery\OEM\winre_state.json`, then re-run.
- **Exit code 3 with `Driver manifest unavailable and no state file exists`** — the machine is offline and has no state file. A first deployment requires a live manifest. Retry when the network is available.

### v46 patch 1 specifically

The v46 patch 1 revision clamps `tailEnd` to `diskSize − 1 MiB` before aligning in `Get-PartitionPlan`, and bumps `ScriptVersion` from 45 to 46. It forces one full-update pass per managed machine on the next scheduled run — the same shape as the v44 patch 1 and v45 patch 1 migrations. The pass itself is not slower than a normal full-update pass.

The v46 patch 1 canary is primarily about confirming that machines the v45 plan-clamp bug left in OS-fallback recover. Watch for:

- **Machines that exit 0 after the first full-update pass.** The normal case. The machine may be recovering from a v45 OS-fallback state (the DSI mismatch invalidates the old state file and the plan-clamp fix makes the plan valid), or it may be a healthy machine taking the standard migration pass. Either way, `Operating mode: DEDICATED` in the log is the confirmation.
- **Machines that stay in OS-fallback after the first v46 pass.** This should not happen on any layout the v45 plan-clamp bug could produce; if it does, the machine has a different post-delete failure. Capture the log and check the plan summary line for the `alignment reserve` value and the post-delete check for `overlapCount=0`. See [troubleshooting.md](troubleshooting.md) for the plan-rejection corner and its fall-through conditions.
- **Machines that exit 2 with `Dedicated replacement deferred before partition deletion (<Reason>)`.** A pre-shrink deferral fired during the v46 migration pass. The old recovery partition is preserved and the machine is unchanged. Investigate the `<Reason>`, resolve the constraint, and delete `C:\Recovery\OEM\winre_partition_deferred.json` to force a retry.
- **Machines that exit 2 with a `Source WIM build` line and no `Post-deploy WIM build` line.** The full-update pass ran but the post-deploy line did not fire. This is a signal that the run aborted between force-upgrade detection and the state write; investigate the log for the earlier error.

### v46 patch 2 specifically

The v46 patch 2 revision does not bump `ScriptVersion` and does not change the `DesiredStateId`. It adds three build-drift log lines, a small read guard in `Get-RecoveryPartitions`, and four post-review hardenings of `Ensure-AdequateRecoveryPartition`. The canary is primarily observational:

- **Confirm the three new log lines appear on a canary full-update pass.** The startup line reads `WinRE status: ..., Location: ..., Version: <version>`; the force-upgrade detection line reads `Source WIM build: <build> (path: <path>)`; the post-deploy line reads `Post-deploy WIM build: <build> (source: <path>)`. On a fast-path run, the first two lines appear and the third does not — that is expected, because the fast path does not deploy a WIM.
- **Confirm the `CmdletizationQuery_NotFound_DiskNumber` error is silent on machines with an SD/MMC card reader or an empty USB enclosure.** Before v46 patch 2, such a machine produced three copies of the error in the harness diagnostic and one per `Get-RecoveryPartitions` invocation in the production log. After v46 patch 2, the same machine produces no such error. If it still appears, the log's version banner will tell you whether the machine is running the patched build.
- **Do not expect any change to the fast-path behaviour or the state-file schema.** v46 patch 2 is observational only, except for the four hardenings, which change only the failure behaviour of the destructive sequence.
- **If a canary machine exits 2 with `Dedicated replacement deferred before partition deletion (active WinRE location could not be resolved)`.** The v46 patch 2 pre-deletion resolver guard fired. The old recovery partition is intact but WinRE is left `Disabled` — the guard fires after `reagentc /disable` has already run. This is a code-review hardening that has not been exercised in the field; if you see it, please capture the full log and file a bug per the [Reporting a bug](../CONTRIBUTING.md#bug-reports) section. See [troubleshooting.md](troubleshooting.md) for the re-registration procedure.

### v47 patch 1 specifically

The v47 patch 1 revision introduces the third-party driver strip stage and bumps `ScriptVersion` from 46 to 47. It forces one full-update pass per managed machine on the next scheduled run — the same shape as the earlier `ScriptVersion`-bump migrations. The pass itself is not materially slower than a normal full-update pass; on an already-clean image, the strip stage is a no-op.

Watch for:

- **Machines that exit 0 after the first v47 full-update pass.** The normal case. The log should show the strip stage running (`Strip: pre-strip third-party inventory: N package(s)` and, if N was zero, `Strip: image already has zero third-party drivers`), a source-selection line naming the branch taken, ResetBase, the export, and `Deployed WinRE metadata: <Version>|<SPBuild>` immediately before the state write. `Operating mode: DEDICATED` confirms the end state.
- **Machines whose log shows `Strip: removed <OEM#.inf>` lines.** The strip stage actually ran against a non-empty third-party driver set — this is the case the field data does not yet cover. If any of these lines appear on the canary, the canary has exercised the strip-and-reinject loop against a non-empty set, which is exactly the case the project wants more field data on. Capture the full log and report it.
- **Machines whose log shows `Strip: initial Get-WindowsDriver enumeration failed` or `Strip: Remove-WindowsDriver failed for <OEM#.inf>`** — the strip stage rejected the candidate. The checkpoint was rolled back to Step 2, `base.wim` and any stale `winre_optimized.wim` were removed, and the run exited `EXIT_WARNING`. The old recovery route is intact. Capture the full log and file a bug — the strip-failure path has not been exercised in the field either.
- **Machines whose log shows `Registered-source recheck at Step 5 deployment : CHANGED` or `Registered-source recheck at Ensure-AdequateRecoveryPartition : CHANGED`** — the v47 race detector fired. The abort happened before the `/disable` call; the machine's registered WinRE drifted during candidate preparation. On a machine whose WU is currently servicing WinRE, this is expected; the abort is protective. On a machine with no plausible WU activity, investigate. Both abort sites return `EXIT_WARNING` with the machine unchanged.
- **Machines whose log shows `State has no DeployedWinREMetadata anchor (previous deployment could not record it) - rebuilding`** — this is the expected message for the first v47 run on a machine whose state file was written by v46 or earlier. The machine will rebuild on this run and the anchor will be written by the end. Any subsequent run should log `Registered WinRE metadata: <ver>|<sp>; last deployed: <ver>|<sp>` and take the fast path.
- **Machines whose log shows `Registered WinRE metadata could not be read - forcing rebuild so the repair path can replace the image`** — the registered image's DISM metadata is unreadable. The rebuild proceeds and the repair path replaces the image. If this fires repeatedly across runs, the registered image is persistently unreadable and the machine is not converging — investigate the registered recovery partition's storage state.
- **Machines whose log shows `Pre-injection third-party driver count: N` with N > 0 after the strip stage** — the filterless and filtered DISM queries disagreed. The strip stage remains authoritative (the filterless form is the documented third-party inventory), but the discrepancy was flagged with a non-fatal warning. Capture the log; this is the observability cross-check working as designed, but the project wants field data on when it fires.
- **Machines that exit 2 with `Checkpoint WIM_READY has no recorded source identity` or `Checkpoint WIM_READY source identity <hash> no longer matches any available source`** — the v47 source-hash binding invalidated a stale checkpoint on resume. The run restarts from Step 0 and rebuilds from the current source. This is a protective invalidation, not a failure. If it fires on a machine whose checkpoint was from a same-source run, the source actually changed during the interval, which the invalidator correctly caught.

Also check the ASUS PRIME H510M-D v47 field-verification transcript in `CHANGELOG.md` for the expected shape of a healthy migration run — the log lines the canary should produce are the same ones.

### v47 patch 2 specifically

The v47 patch 2 revision does not bump `ScriptVersion` and does not change the `DesiredStateId` on any machine whose `Win32_ComputerSystemProduct.Version` field is not padded. It ships six hardening fixes on top of v47 patch 1: the OS-fallback missing-WIM guard without a status restriction; the base-WIM copy-integrity check; the machine-type fallback trim; the workspace candidate filter `IsSystem -and -not IsBoot`; the GitHub base-WIM extraction contract change (`return $false` instead of throw); and the `-SuppressSuccessLog` switch on the duplicate `Verified partition` log line. The canary is primarily observational:

- **Confirm the version banner reads `v47 patch 2`.** The startup line reads `========== WinRE Manager Started (v47 patch 2) ==========`.
- **Confirm the new log signatures are absent on a healthy canary.** A canary that takes the fast path will not emit any of the v47 patch 2 signatures. A canary that runs a full update will show `Copied base WIM from <path>; copy hash verified` after the base-WIM copy. The mismatch branch (`Base WIM copy hash mismatch: source=..., copied=... - rejecting candidate`) is not expected on a healthy canary.
- **On a machine with a padded `Version` field** (observed: some ASUS), expect a one-time `DesiredStateId` change from the trim fix and one full-update pass. All other machines continue on the fast path.
- **On a machine with a v47 patch 1 Step 3 checkpoint on disk**, expect that checkpoint to be invalidated on the first v47 patch 2 run and the run to rebuild from Step 2.
- **The six hardenings are code-review fixes**, not field-verified changes. They are covered by inspection and by the harness parser self-tests, not by the four v47 patch 2 field runs. If a canary hits any of them, capture the full log per the [Reporting a bug](../CONTRIBUTING.md#bug-reports) section.

## Rolling back

The script does not have an uninstall path. To disable it:

```powershell
schtasks /Delete /TN "WinRE Manager" /F
schtasks /Delete /TN "WinRE Manager Weekly" /F
```

The state file, deferral marker, log, lock file, and any deployed recovery partition remain. The machine is in a healthy end state and Windows Update will continue to service the recovery image normally. The lock file at `C:\ProgramData\OEM\Logs\WinREManager.lock` is inert once the scheduled task is removed; it can be deleted manually if desired, and it will be recreated if the script is ever run again. The deferral marker at `C:\Recovery\OEM\winre_partition_deferred.json` is likewise inert; it can be deleted manually.

If you need to revert a machine to its pre-WinRE-Manager state, restore the partition layout from a backup. The script does not create one.

To revert a `DesiredStateId` change specifically, see the "Rollback" subsections under "v44 patch 1 migration", "v45 patch 1 migration", "v46 patch 1 migration", and "v47 patch 1 migration" above. To revert code from a patch that does not change the `DesiredStateId`, see the "Rollback for later non-bumping patches" subsection above.

## Related documents

- [architecture.md](architecture.md) — the four design invariants that this document translates into deployment-time guidance, plus the pipeline, the control-flow invariants, and the state-carrying artifacts.
- [self-hosting.md](self-hosting.md) — how to replace the driver manifest, OEM maps, and base WIM repository with your own hosting, including the trust model and the air-gapped deployment procedure.
- [exit-codes.md](exit-codes.md) — how to interpret the exit codes, including the eleven cases for code 2.
- [state-and-idempotency.md](state-and-idempotency.md) — what the state file records, the deferral marker's relationship to the deployment identity, and the offline fallback's residual risk.
- [recovery-partition.md](recovery-partition.md) — the full partition lifecycle, including the v45 single-boundary geometry and pre-shrink deferral reasons.
- [troubleshooting.md](troubleshooting.md) — when the run fails.
