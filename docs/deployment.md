---
title: "Deployment — WinRE Manager"
description: "Deploy WinRE Manager on a single machine or a managed fleet: scheduled task XML, Intune, RMM, exit-code handling, and operator guidance."
---

# Deployment

How to run WinRE Manager on a single machine or across a managed fleet.

## How to deploy

There are two ways to deploy WinRE Manager. Pick the one that matches your situation.

### Single machine, one-off repair

For a single broken machine, run the production script once from an **elevated** PowerShell prompt. It inspects the machine, repairs the recovery environment, writes a state file, and exits. There is no installer, no service, and no configuration file to maintain.

As of v48 patch 2, the script refuses to run unelevated in milliseconds. The refusal is a single FATAL log line (`FATAL: WinRE Manager requires an elevated (Administrator) PowerShell session.`) and exit code 3, before the program lock, before hardware probes, and before any network fetch. The guard creates the log directory itself so its FATAL message has somewhere to be written. Before v48 patch 2, an unelevated launch proceeded through hardware detection, manifest fetch, VMD detection, and the multi-minute GitHub base-WIM download before failing at `Mount-WindowsImage` with `The requested operation requires elevation.` — a failure mode that wasted roughly four minutes per run in the 2026-10-05 field log. Both the interactive Administrator session and the SYSTEM context used by the scheduled task pass the guard.

```powershell
# Elevated PowerShell (Run as Administrator)
powershell -ExecutionPolicy Bypass -File .\scripts\WinRE.ps1 -DryRun   # walk the flow, log every decision, change nothing
powershell -ExecutionPolicy Bypass -File .\scripts\WinRE.ps1           # actually deploy
```

The `-ExecutionPolicy Bypass -File` form applies the bypass only to the child process; it does not change the machine's execution policy.

If you want to inspect the machine first, run the read-only harness (`Test-WinRE.ps1`). It requires no elevation and modifies nothing. See the [README](../README.md) for the harness menu options.

**As of v49, the recommended single-machine path is the wrapper.** `scripts\WinRE-Manager.cmd` opens a menu grouped into SAFETY, DIAGNOSTICS, MAINTENANCE, REPAIR, and RECOVERY sections. Backup is the first option an operator sees and Restore is the last of the numbered options; the destructive repair run sits after the preparatory options and before Restore and Quit, so the safe and preparatory options are read first. The wrapper is the recommended entry point for a first-time user; direct script invocation is for scripting, CI, and pinned-version deployments. See the [README's menu table](../README.md#just-want-to-fix-winre-on-your-pc) for the full option list.

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

The v49 release adds three pre-deployment gates that narrow what the pipeline will deploy — a **source-ownership classification** (a foreign WIM that a vendor populated with its own drivers is preserved as-is rather than stripped and re-injected), a **never-downgrade storage-driver check** (a candidate image that would inject a storage driver older than one already present in the mounted image is discarded entirely — the source is preserved and the run defers), and a **pre-deployment storage-applicability gate** (which runs inside Step 3, after injection is confirmed complete, before ResetBase and before the dismount, and is the last refusal before the WIM is written to the active route). Each of these changes the pipeline's deployment decision on at least some machines; the `ScriptVersion` bump from 48 to 49 is what converges the fleet onto the new pipeline. See the "v49 migration" section below for the fleet-level rollout behaviour.

### Rule 2 — never leave a machine without a working recovery route: do not interfere with the recovery window

The one case in which the script cannot guarantee a working recovery route on a single run is the post-deletion residual corner: a failure **after** the old recovery partition has been deleted, on a machine whose C: is encrypted, with no successful retry. The trigger set is wider than the commonly cited `New-Partition` or `Format-Volume` pair: the whole-layout assertion (`Assert-RecoveryPartitionLayout`), drive-letter availability, drive-letter assignment, in-place decryption of the new partition, the post-delete extension fallback, the post-delete geometry verification, the planned-extent-available re-check, and the recovery-partition deletion itself when the previous route cannot be restored, all reach the same corner. The correct operational response is **not to interrupt the script while it is inside the destructive window** — every interruption between the delete and the enable is an opportunity for the machine to land in that corner.

Concretely:

- **Do not kill the `WinRE.ps1` process** if it appears to be slow. A full-update pass on an NVMe machine takes 3–5 minutes of I/O; the destructive window is a small fraction of that. If you kill the process inside the window, the recovery route is not restored by the script and the next run must recover from whatever state the interruption left.
- **Do not delete the state file** while a run is in progress. The state file is what the next run uses to identify the deployment identity and the pending state.
- **Do not delete the deferral marker** while a run is in progress. The marker is what the next run uses to decide whether to suppress a retry of the pre-shrink deferral.
- **Do not use a forced reboot** inside the window. A forced reboot between the delete and the enable leaves WinRE disabled and the recovery partition possibly partial.

The scheduled task's own `ExecutionTimeLimit` (PT6H for the XML template above; 24 hours for the wrapper's install option) and the script's internal timeouts (300-second BitLocker polling, 5-second sleeps, 15-second network timeout) are the effective limits inside that. Nothing outside the script needs to enforce a shorter one.

**If a Repair or Restore run is interrupted**, the v49 temporary resume task registers itself on every Repair or Restore run and fires at boot+1m and one-shot at T+1h. The task is deleted on clean completion and preserved on interruption — including Ctrl+C, a hard kill, a reboot mid-run, an unhandled exception in the outer catch, and the two v49 restore mid-transformation failure paths. The resume run re-invokes the script with its default Repair action, which completes the operation from the checkpoint. **Do not delete the resume task manually** unless you intend to abandon the interrupted operation — see the "Temporary resume task" section below.

**v48 expands the destructive-surface scope.** As of v48 patch 1, the intervening-anchor path extends the destructive window's entry to include a resize of the intervening data partition (typically `D:`) instead of the OS partition. The window's scope is unchanged — the same partition-delete / create / format / deploy / register sequence runs — but the pre-shrink target may be the anchor rather than C:. The operational guidance above applies to the intervening-anchor case without change. The narrow scope means the participating partitions are predictable: one non-recovery data partition immediately preceding the type-coded recovery cluster, on the OS disk, validated before any mutation.

### Rule 3 — minimize the `reagentc /disable` → `reagentc /enable` window: do not schedule around it

The window is the interval during which WinRE is not registered and the recovery partition is in the process of being replaced. On a modern SSD the window is typically **15–45 seconds** for the delete / create / format / deploy / `reagentc /setreimage` / `reagentc /enable` sequence. On a spinning disk or a very large WIM it can be longer.

Rule 3 is enforced by the script's own ordering — every preparatory step that does not require a disabled WinRE runs before the disable. Your scheduling decisions should not undo that.

- **Do not schedule a mandatory reboot** to fire during a run. The scheduled task's boot trigger fires on the machine's own reboots; a fleet-wide reboot campaign that overlaps with a weekly run can terminate the script inside the window.
- **Do not use a "stop task if it runs longer than X" setting** on the scheduled task or in an MDM-side policy that could fire inside the window. The scheduled task's own `ExecutionTimeLimit` is the correct upper bound; a second, shorter policy that runs in parallel can kill the run at the worst possible moment.
- **Do not use an orchestration layer that kills the process after a fixed timeout** shorter than the scheduled task's own limit. An RMM tool or an MDM remediation platform with a 60-second or 120-second timeout will kill the script inside the window on a machine where the destructive sequence actually runs; the same tool on a healthy machine will see the fast path complete in 10–20 seconds and never trigger its timeout.

The single-run recovery story is: `Restore-PreviousWinRERoute` on delete failure, `Remove-OrphanPartition` plus `Restore-OSPartitionSize` on create failure, and the enable-only path on a clean-but-disabled state. These handle every ordinary failure. They do not handle a process kill inside the window — but as of v49 the resume task catches the interruption case and re-invokes the script on the next boot or within the hour.

### Rule 4 — do no work unless needed: trust the fast path; do not force reruns

Rule 4 has four concrete operational consequences.

- **Healthy machines take the fast path.** Runtime is dominated by Windows' own CIM and PnP enumeration and the driver-manifest fetch — typically 10–20 seconds on a modern machine. The script itself makes no state changes. There is no reason to tune the schedule around the cost of a healthy run.
- **Do not force a full update on a healthy machine.** Deleting the state file, bumping the manifest version, or bumping `ScriptVersion` forces one full-update pass per machine. Do it only when there is a reason — the migration sections below describe the six version boundaries that do this deliberately.
- **Do not retry a deferral.** The script's deferrals are protective. An Audit Mode deferral, a VMD-query-indeterminate deferral, an OS-fallback BitLocker deferral, a v45 pre-shrink deferral, a v47 race-detector abort, an offline-fallback deferral, the v48 architecture-gate refusal, the v48 intervening-anchor surplus rejection, the v48 multi-intervening rejection, the v48 offline `LocalInputsId` mismatch, the v49 native-boot VHDX fail-closed gate, and the v49 pre-deployment storage-applicability gate — none is improved by running the script again before the underlying condition changes. The correct response is to resolve the condition, then re-run. **One nuance: the v45 pre-shrink deferral has two classes.** The four `RetrySuppressible = $true` reasons (post-shrink free space below minimum, pre-shrink failed, pre-shrink verification failed, resize rounding reduced planned extent) write a deferral marker and will not re-attempt until the marker is cleared. The other reasons — the `C: volume could not be read for free-space check` failure (which returns `RetrySuppressible = $false`) and the pre-deletion resolver guard (which returns no `RetrySuppressible` field, so the caller does not write a marker) — retry on the next scheduled run without operator intervention. Check the specific reason in the log.
- **The enable-failure counter is a feature, not a bug.** A machine that fails the enable step three times in a row hits the loop-breaker and exits `EXIT_FATAL` with a "manual intervention required" message. Retrying automatically produces the same result. Resolve the underlying enable failure, delete the state file, then re-run.

## Preconditions

Before the first run on any machine, confirm:

- **Windows build**: 19041+ for Windows 10, 22000+ for Windows 11.
- **Architecture**: x64 only (v48 patch 1). The manager refuses to run on ARM64, x86, or any architecture whose token cannot be resolved, exiting with `EXIT_WARNING` before any state mutation. The refusal is a stable, named deferral: a machine in the fleet whose architecture is not `x64` will continue to exit 2 on every run until the manager adds support or the machine is replaced.
- **OS volume topology (v49)**: not a native-boot VHDX. The manager refuses to run destructive operations when the OS disk's bus type is `File Backed Virtual` **and** at least one other disk is on a physical bus — the native-boot VHD/VHDX topology, where the running OS disk is a VHD/VHDX stored on a host physical disk. A hypervisor guest whose entire storage stack is virtual (every other disk on `Virtual` or `File Backed Virtual`) is not refused and runs the full pipeline normally. The gate exits `EXIT_WARNING` before any partition or WinRE change. `Resize-Partition` and `New-Partition` against a VHDX-backed volume have different semantics than against a physical disk; the pipeline has not been validated under that topology. This is a stable deferral, and the gate has no `-DryRun` carve-out — a dry run on a VHDX-boot host also exits `EXIT_WARNING`.
- **7-Zip** present at `C:\Program Files\7-Zip\7z.exe`, or `winget` available so the script can install it.
- **Internet access** to the driver manifest, the three OEM maps, and the base WIM repository for the first deployment on a fresh machine. On a machine whose state file is present and its local safety checks pass, a network outage does not prevent the run — see the "Offline behavior" section below. The endpoints are: `gist.github.com`, `api.github.com`, `downloads.dell.com`, `ftp.ext.hp.com`, and the vendor-specific Lenovo endpoints (`download.lenovo.com`, `support.lenovo.com` — the latter is only reached by the map builder, not by production).
- **Windows is in a normal-running state.** The script refuses to run before any state-modifying action when the machine has not yet completed OOBE. This is the v43 patch 5 (further revision) Audit Mode guard and it matters for freshly imaged machines. See the "Audit Mode and OOBE" section below.
- **At least one eligible internal fixed NTFS volume with 3 GiB free.** The v45 patch 1 workspace selector only accepts fixed NTFS volumes on an allowlisted set of internal/virtual buses. USB, SD/MMC, network, FireWire, Fibre Channel, unknown buses, and reparse-point workspace paths are excluded, even when reported as fixed. A full update defers with `EXIT_WARNING` when no eligible volume has 3 GiB free. See the "Workspace selection" section below.

There is **no BitLocker precondition on the OS volume**. The v43 patch 5 (further revision 5) policy is target-volume-based: the enable-only and dedicated-partition paths do not depend on C:'s BitLocker state at all. If the target recovery partition is encrypted, the script decrypts it in place via `Set-RecoveryPartitionReadyForWinRE` before calling reagentc. The only route that depends on C:'s BitLocker state is the OS-fallback route, because on that route the target volume *is* C:. The destructive partition path does not depend on C:'s state either — as of v44 patch 6 it does not consult C: at all. Neither the OS-fallback gate nor the destructive path modifies C:'s BitLocker state. See the "Device Encryption" section below.

The harness's System diagnostic (`scripts\Test-WinRE.ps1` Option 1) reports `ImageState`, C:'s BitLocker state, and the target recovery partition's BitLocker state. As of harness v28 it also reports the machine's present SCSIAdapter-class storage controllers, which is the input the v49 pre-deployment storage-applicability gate reads. Run it on a representative machine before pushing the task to a fleet.

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
- `ExecutionTimeLimit = PT6H` gives the run enough headroom. No single internal operation can hang indefinitely — the longest is a 300-second BitLocker polling timeout — and the aggregate runtime of a full-update pass is well under an hour on any hardware this project supports. Do not add a shorter limit at the orchestrator level — see Rule 3 above.
- `RunOnlyIfNetworkAvailable = false` is deliberate as of v44 patch 5. The script now has an offline fallback: when the manifest fetch fails, it trusts the state file's stored `DesiredStateId` and takes the fast path if the local safety checks pass. With `true`, the task would not fire when the network is down, so the fallback would only help manual invocations — not the scheduled path where the machine actually needs it. The offline fallback is self-limiting (`EXIT_WARNING` when a full update is needed, never a silent partial deployment) and safe on a machine whose state file is valid. A first deployment on a machine with no state file will still exit `EXIT_FATAL` when offline, which is correct: the live manifest is required to compute the initial `DesiredStateId`. See the "Offline behavior" section below.
- `StartWhenAvailable = true` handles missed triggers after a cold boot.

### The wrapper's stable install location (v49)

The `scripts\WinRE-Manager.cmd` wrapper's install option (menu option **5 — Install automatic maintenance**) does not use the paths in the XML above. It installs a copy of `WinRE.ps1` at:

```
C:\ProgramData\OEM\WinRE-Manager\WinRE.ps1
```

and registers the task against **that** copy. The install step creates the containing directory, copies the operator's local `WinRE.ps1` to the stable path, SHA256-verifies the copy, and refuses to register the task if the copy's hash does not match the source. The task is registered against the installed copy, not the operator's local clone, so the task survives deletion or relocation of the operator's original files.

The wrapper's task uses a profile equivalent to the XML above for the security-relevant settings — SYSTEM account, highest run level, `IgnoreNew`, `StartWhenAvailable`, battery-allowed, no idle requirement, and — deliberately — network **not** required, so the offline fallback fires on scheduled runs. The schedule and time-limit settings differ intentionally: the wrapper uses boot+5m and every-30-days-at-03:00 triggers rather than the XML template's boot+2m and weekly triggers, and a 24-hour execution time limit rather than the XML template's 6 hours. Both trigger schedules and both time limits are well above the effective runtime of any run the script produces, and the differences are not load-bearing.

The wrapper's removal option (menu option **6 — Remove automatic maintenance**) unregisters the task but leaves the installed copy in place, so a subsequent reinstall does not need to re-copy. The removal screen tells the operator how to delete the containing directory manually.

The XML template above is for a fleet operator who wants to hand-author the task. If you use the wrapper's install option instead, the task name, script path, and trigger schedule differ from the XML template's. Both approaches produce equivalent execution on the machine; the choice is which one the operator wants to maintain.

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

The v49 temporary `WinRE Manager - Resume` task does not participate in the program lock directly — it invokes the production script with its default Repair action, which acquires the lock normally. A resume run that coincides with a scheduled run is serialized by the same lock, and whichever side loses the race exits with the same `Another WinRE Manager instance is already running` message.

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

### Temporary resume task (v49)

Every Repair or Restore run registers a scheduled task named `WinRE Manager - Resume`. The task fires at boot+1m and as a one-shot at T+1h; it is deleted on clean completion and preserved on interruption. The persist flag is set in three cases: the outer catch (an unhandled exception), the `CancelKeyPress` handler (Ctrl+C — the load-bearing case, because PowerShell runs `finally` blocks but bypasses `catch` blocks on Ctrl+C), and `Invoke-RestoreAction`'s two mid-transformation failure paths. Two further interruption classes leave the task registered without setting the flag, because the `finally` block never runs to consult it: a hard kill (e.g. `taskkill /F`) and a reboot mid-run (the OS terminates PowerShell).

The task is a per-run safety net, not machine state. Its presence indicates an interrupted Repair or Restore; its absence is the normal state after a clean completion. When present, the resume run re-invokes the production script's default Repair action, which completes the operation from the checkpoint. **Do not delete it manually** unless you intend to abandon the interrupted operation.

**Under `$PSCommandPath`-less invocation** — gist bootstrap via `Invoke-RestMethod | Invoke-Expression`, or paste-into-console — the guard in `Register-ResumeTask` logs at INFO and does not register the task. This is by design: those invocation modes have no `$PSCommandPath`, and the guard skips the registration. A run initiated from such an invocation cannot be resumed by the task; the operator must re-run the script manually after an interruption.

**The task profile** is SYSTEM / highest run level, startup+1m and one-shot T+1h, `StartWhenAvailable`, battery-allowed, no idle requirement, network not required, 24-hour execution limit. The same profile as the primary scheduled task's conservative settings, so a resume run behaves identically to a scheduled run for the purposes of the offline fallback and the fast-path gates.

## Where to put the script

Place `WinRE.ps1` in a directory that:

1. **`SYSTEM` can read.** `C:\ProgramData\OEM\` is the standard choice.
2. **Cannot be modified by non-admin users.** A scheduled task running as SYSTEM must not execute a script that a standard user can overwrite. `C:\ProgramData\OEM\` with default ACLs is safe; do not use `C:\Temp\`.

The script writes to `C:\ProgramData\OEM\Logs\` for the log, checkpoint file, and lock file. `SYSTEM` can write there by default.

**The wrapper's install option uses `C:\ProgramData\OEM\WinRE-Manager\WinRE.ps1` as the stable install location** and registers the task against that copy rather than against the operator's local clone. Both `C:\ProgramData\OEM\` and `C:\ProgramData\OEM\WinRE-Manager\` have the same ACL properties for the purposes of the scheduled task.

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
- **The OS volume's BitLocker state is consulted only on the OS-fallback route.** On that route the target volume *is* C:, and reagentc refuses to enable WinRE on an encrypted OS volume. The gate checks C:'s `VolumeStatus` before deploying and defers unless it is `FullyDecrypted`. The script never modifies C:'s state. As of v44 patch 6, the destructive partition path does not gate on C:'s state — the dedicated-partition path's success or failure depends on the partition geometry, not on C:'s encryption state. The path queries C:'s encryption state only to log it, and the log line explicitly records that C: encryption is not a veto for the dedicated-target path.
- **New partitions are created with the recovery type GUID applied at `New-Partition` time.** This closes the window between partition creation and `Set-RecoveryPartitionAttributes` during which a plain Basic Data partition could be claimed by the Device Encryption service.
- **No BitLocker suspension.** The v43 patch 5 function `Suspend-BitLockerForWinRE` was deleted. Suspension does not prevent Device Encryption from claiming new partitions — proven in the field — and it is useless for OS-fallback, where reagentc refuses regardless.

### Why the earlier further-revision policy was replaced

The v43 patch 5 (further revision) design gated on **C:'s** BitLocker state at startup. It deferred any run where C: was not `FullyDecrypted` with `Protection On`. That design was correct in the sense that it prevented the Dell Latitude 3550 / HP ProBook 450 G10 failure mode, but it was over-broad: it deferred on the `FullyEncrypted + Protection Off` state, which is the normal state of every fresh Win11 local-account machine before a Microsoft account sign-in. The startup gate was deferring on the majority of the fleet.

The change was driven by a same-machine test on 2026-09-29. With C: in the `FullyEncrypted + Protection Off` state, `reagentc /enable` against a dedicated recovery partition succeeded while `reagentc /enable` against the OS volume failed on the same machine in the same session. That established that reagentc's check is on the **target** volume. The policy was inverted accordingly: prepare the target; do not gate on C: except on the OS-fallback route, where the target *is* C:.

### What this means for you

The scheduled task does not need to be aware of the machine's encryption state. The script handles it. But three deployment-time facts are worth knowing:

- **On a dedicated-partition machine, the first run may take up to 5 minutes longer than usual if the target recovery partition is encrypted.** The helper will spend up to 300 seconds decrypting it. A 1 GB recovery partition decrypts in well under a minute on NVMe, so the timeout is generous; but if you are benchmarking or scheduling tightly, expect the possibility.
- **On a machine that falls back to OS-fallback, the run defers if C: is not `FullyDecrypted`.** The log names the C: state and tells the operator what to do: complete decryption of C: (`manage-bde -off C:`) or wait for an in-progress decryption to finish. Actions that complete encryption, add a protector, or enable protection do **not** resolve the state — they make C: more protected, not less. This deferral does not consume the enable-failure counter.
- **On a machine whose destructive attempt fails after the old recovery partition has been deleted** — for example, a `New-Partition` or `Format-Volume` failure — **the run falls through to OS-fallback.** The OS-fallback gate then consults C: and defers cleanly if C: is encrypted. As of v45 patch 1 the shrink is no longer inside the destructive window: a failed pre-shrink returns `Deferred` with the old route preserved and never reaches OS-fallback, so the shrink case no longer produces this fall-through.

If you are deploying to a fresh fleet and want the first run to succeed rather than defer on the OS-fallback route, wait until `manage-bde -status C:` shows `Fully Decrypted` before pushing the task. On a modern SSD, decrypting C: from a mid-encryption state typically takes 30–90 minutes.

## VMD fail-closed guard (v44 patch 6)

The VMD hardware presence check determines which driver set the script selects. As of v44 patch 6 the check is fail-closed: if the PnP enumeration reports an error during the query, the run treats VMD presence as **indeterminate** rather than as absent, and defers with `EXIT_WARNING` before committing any state.

The reasoning: guessing "absent" on a machine that genuinely has VMD hardware would select a driver set that omits the VMD package, and the deployed WinRE would not be able to see the OS disk. An empty device list from an errored enumeration is not evidence of absence. The cost of a deferral is one pipeline run; the cost of guessing wrong is a machine with a non-functional recovery environment.

A run that defers this way leaves the machine unchanged: no WIM deployed, no partition touched, no `reagentc` call made. The next scheduled run retries the enumeration; a transient PnP service issue is the most likely cause. If the deferral fires repeatedly, resolve the underlying PnP service issue — the deferral is a protective stop, not a degraded-success.

## v49 pre-deployment gates

The v49 release adds three gates that narrow what the pipeline will deploy. Each is described in full in [driver-injection.md](driver-injection.md); this section covers the deployment-time implications.

### Source-ownership classification

Every candidate source WIM is classified into one of four ownership classes — `Manager-Owned`, `Manager-Lineage`, `Foreign-No-Drivers`, `Foreign-With-Drivers` — before the strip stage runs. A `Foreign-With-Drivers` source is **preserved as-is**: the strip-and-reinject pipeline is skipped, the mounted image is dismounted with `-Discard`, and no WIM is deployed. The existing WinRE route is left untouched, and the state file records `ForeignSourceAcceptedHash` so subsequent runs recognize the preserved source and take the fast path. The run exits `EXIT_WARNING`. The other three classes proceed through the strip and injection as in v47/v48.

**Operational consequence:** a machine whose registered WinRE was populated by a vendor tool with third-party drivers now deploys with those drivers instead of the manager's recipe. This is the intended v49 behavior; the ASUS-incident field case is the reason it exists. If the operator wants the manager's recipe applied, the source must be replaced with one that classifies as `Manager-Owned`, `Manager-Lineage`, or `Foreign-No-Drivers` — typically by using the LKG copy or the GitHub cold-start source.

The classification is not operator-configurable in v49; it is derived from the source's actual driver set (a third-party driver count of zero vs. non-zero) plus two positive-ownership signals: a staged-source hash exact-match against `state.CurrentImageHash` (Manager-Owned) and a valid provenance marker whose `LineageId` matches the state file's (Manager-Lineage).

### Never-downgrade storage-driver check

After injection completes and before ResetBase, the manager compares each storage-class driver in the final image against the pre-strip inventory, matched by INF basename. If any post-injection driver would be older than the source's version of the same basename, the entire candidate is discarded — not just the offending driver — the mounted image is dismounted with `-Discard`, the source is preserved, the state file records `ForeignSourceAcceptedHash`, and the run exits `EXIT_WARNING`. The whole source is preserved rather than partially normalized.

**Operational consequence:** a machine whose source image would inject a storage driver older than what is already present does not deploy. The existing WinRE route is untouched, and the state file records the preserved-source hash so subsequent runs recognize the accepted source and take the fast path.

The log names each detected downgrade — the driver's INF basename, the source version, and the candidate version.

### Pre-deployment storage-applicability gate

The gate runs inside Step 3, after injection is confirmed complete and after the never-downgrade check, before ResetBase and before the dismount. It is the last refusal before the WIM is written to the active route, but its position is inside Step 3 — the deploy step runs later in the pipeline, and a candidate that fails the gate is dismounted with `-Discard` before the pipeline reaches the deploy stage. The manager verifies that the candidate image contains an INF whose `HardwareID` or `CompatibleID` matches one of the machine's present SCSIAdapter-class devices. A candidate that does not match is refused rather than deployed.

**Operational consequence:** a machine whose candidate image does not contain a driver for its actual storage controller defers with `EXIT_WARNING` rather than receiving a candidate with no driver. The gate is the last refusal before deployment; it was added after the ASUS-incident field case, and **it has never fired in the field**.

If a canary machine exits 2 with the applicability gate's refusal, capture the full log and the harness Option 1 "Storage controllers" block (v28) — the machine's controller IDs are what the maintainer needs to update the manifest's VMD patterns or the OEM pack resolution.

### Self-hosted configurations

A self-hosted manifest whose `requiredDevices` patterns omit a controller present on your fleet, or a self-hosted OEM pack whose INFs do not cover your fleet's controllers, will cause the applicability gate to refuse the candidate on the affected machines. Keep both complete for the hardware you deploy to. The v49 pipeline does not add new external URLs; it only reads the manifest and pack content differently than v47/v48 did.

## Offline behavior (v44 patch 5; fast-path gate updated in v47 patch 1; `LocalInputsId` added in v48 patch 1; v49 gates run offline as well)

The script's network calls — the driver manifest fetch, the OEM map fetches, and the base WIM download — each default to a 15-second per-call timeout. The timeout applies to each individual request, not to the aggregate; the retry loops (2 attempts for the manifest, 3 for the OEM pack download) can multiply it. Before v44 patch 5, an offline machine would hang for over 10 minutes across the aggregate of the default 100-second timeouts before failing. That is now capped at roughly 90 seconds in the fully-offline case, dominated by the fixed sleeps in the retry loops rather than by the network timeouts.

More importantly, v44 patch 5 adds an **offline fallback** for the manifest fetch. The behavior depends on the state file's contents.

### Case 1 — state file present, its fast-path checks pass

The script reads the state file at `C:\Recovery\OEM\winre_state.json` and trusts its stored `DesiredStateId` directly. It does **not** recompute the ID from cached inputs — recomputing would require the OEM pack version, which is resolved from the OEM map, another gist on the same unavailable network.

The local safety checks remain fully enforced and do not depend on the manifest. Under v47, the fast-path conditions the offline path validates are the same as the online path:

- WinRE is `Enabled`.
- The state file's `DesiredStateId` matches the stored value (used directly; the DSI is not recomputed offline).
- The drift detector reports no change: the currently-registered WinRE's DISM servicing metadata (`Version` + `SPBuild`) matches the state file's `DeployedWinREMetadata` anchor, and no force-upgrade, driver-version change, or missing-anchor condition applies.
- The state file's stored `LocalInputsId` matches the current locally-computable inputs (v48 patch 1). A stored value of `$null` (a state file predating v48 patch 1) skips the check with a WARN.
- The recovery-partition layout is one of the healthy shapes: exactly one **type-coded** recovery partition on the OS disk with the active location on it, or no recovery partition with `UsedOSFallback = $true` in the state file and the active location on the OS partition.

The v49 pipeline refinements — source-ownership classification, never-downgrade check, storage-applicability gate — run inside the full-update path, which the offline fallback does not reach. They do not add new offline-path conditions. The native-boot VHDX fail-closed gate runs as a startup refusal on all paths, including offline, and a VHDX-boot machine defers before the offline fallback is engaged.

If all pass, the script takes the fast path, logs `Offline fallback: using state file's stored DesiredStateId <id>`, verifies the machine is healthy, and exits `EXIT_WARNING` (code 2) because `$Script:offlineFallback = $true` is set. The exit code is a degraded-success signal, not a failure. The machine is unchanged. Total runtime is under 90 seconds.

**The v46 → v47 transition on offline machines.** A v46-or-earlier state file lacks `DeployedWinREMetadata`. Its absence forces `$needInject = $true` regardless of network state, and the offline guard then fires: the machine needs a full update, but the live manifest is required for that, so the run exits `EXIT_WARNING` without further work. From the second v47 run onward, the state file has the anchor written by the first successful online run, and the offline fast path can fire normally. The one-time cost of the v47 migration on offline machines is therefore: the first scheduled v47 run must happen while the machine can reach the driver manifest.

**The v48 → v49 transition on offline machines.** The v49 `ScriptVersion` bump changes the `SCRIPT` component of the `DesiredStateId`, but on the offline fallback path the state file's own `DesiredStateId` is used as-is (the DSI is not recomputed offline), so a v48 state file is accepted on the offline path and the fast path can fire. The run exits `EXIT_WARNING` because `$Script:offlineFallback` is set, not because a full update was forced. The v49 pipeline gates (source-ownership classification, never-downgrade check, storage-applicability gate) are not exercised on that first offline run; they are exercised on the next run with network, which recomputes the DSI and forces the v49 full-update pass. This is a deliberate consequence of the offline fallback's "use the stored DSI directly" design: the offline path prioritizes a fast-path validation of a machine whose local state is trusted, and defers the v49 recipe change to the first online run.

**On the next scheduled run with network**, the script performs a full manifest fetch, detects any hardware drift that occurred while offline (a CPU swap, a BIOS update that flipped VMD, a motherboard replacement), and either takes the fast path (if no drift) or forces a rebuild (if drift).

**The v48 patch 1 `LocalInputsId` field closes the offline hardware-drift residual.** The state file now records a hash over the three deployment inputs observable on the local machine without a network fetch: hardware identity (`Manufacturer|Model|MachineType`), OS build, and CPU vendor/generation. VMD presence is deliberately excluded because its detection depends on the manifest's `requiredDevices` patterns, which is precisely the input the offline fallback does not have. On the offline fallback path, the run recomputes the hash from the current machine and compares it against the stored value; a mismatch defers with `EXIT_WARNING` (`Offline fallback: stored LocalInputsId <hash> does not match the current locally-computable inputs <hash>`) rather than trusting a stored `DesiredStateId` that describes a machine whose hardware or OS has since changed. A VMD flip is not caught by `LocalInputsId`: VMD is a BIOS-configurable setting that can be toggled independently of the hardware, so `HW` and `CPU` do not capture it, and the hash deliberately excludes VMD because its detection needs the manifest. A machine whose VMD state changed while offline could take the fast path with a stale `DesiredStateId` — a documented residual of the offline fallback.

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

## Backup and restore (v49)

The v49 release adds two standalone actions to the production script:

- **`-Action Backup -BackupPath <dir>`** — captures a byte-for-byte copy of the currently registered WinRE WIM plus a sidecar `backup.json` recording the source hash, size, and DISM servicing metadata.
- **`-Action Restore -BackupPath <dir>`** — writes a previously captured WIM back to the currently registered route transactionally.

Both actions are exposed by the `WinRE-Manager.cmd` wrapper: menu option **1 — Back up current WinRE** in the SAFETY section, and menu option **8 — Restore WinRE from backup** in the RECOVERY section. The Restore entry and the RECOVERY section header are always present. The recovery row shows a hint that reflects the state of the default backup location: `default backup available` when at least one directory under `C:\Backup\WindowsRE` contains both `winre.wim` and `backup.json`, or `no default backup found` otherwise. The restore screen accepts any directory containing both files — including one on an external disk — so the option is never suppressed; a machine with no default backup can still restore from a backup stored elsewhere.

**Backup is non-destructive.** It does not rebuild, replace, or reconfigure the active WinRE route, and it does not write to the state file. It may temporarily assign a drive letter in order to access a WIM registered through a GLOBALROOT/volume path, and cleans the letter up under the existing temporary-drive-letter machinery. A backup operation exits `EXIT_SUCCESS` when both the WIM copy and the sidecar `backup.json` are written and verified; it exits `EXIT_WARNING` when the WIM copy and hash verification succeed but the sidecar write fails, because the operator needs to know the backup directory is missing its metadata. (The backup WIM itself remains usable for a subsequent restore; the sidecar is metadata only.)

**Restore is transactional.** It validates the backup, resolves the current registered route, handles dedicated and OS-fallback targets, uses the existing deployment machinery, re-registers WinRE, and re-enables it. Restore does not create a new partition or invent a replacement route — a usable current WinRE route must already exist. The operator is required to type `RESTORE` to confirm.

**Restore exits.** A clean restore exits `EXIT_SUCCESS` (or `EXIT_REBOOT_REQUIRED` if `reagentc /enable` schedules the registration for the next reboot). The two mid-transformation failure paths — `/setreimage` failing after the WIM has been replaced, or `/enable` returning failed/bitlocker after the WIM is in place — both preserve the temporary `WinRE Manager - Resume` task so the operation is resumed on the next boot or within the hour. The `/setreimage` failure exits `EXIT_FATAL`; the `/enable` failure exits `EXIT_WARNING`. A WIM-replacement failure that reaches the rollback branch exits `EXIT_FATAL`.

**Fleet operators who use the scheduled task do not normally invoke these actions.** They are exposed by the wrapper for a single-machine operator or a technician doing manual intervention. A fleet operator who needs to run a backup from an orchestration tool can invoke `WinRE.ps1 -Action Backup -BackupPath <dir>` directly; the action is a standalone command, not a pipeline stage.

## Migration sections

The v44 patch 1, v45 patch 1, v46 patch 1, v47 patch 1, v48 patch 1, and v49 revisions each bump `ScriptVersion`, change the `SCRIPT` component of the `DesiredStateId`, and force one full-update pass per managed machine on the next scheduled run. The roll-out behaviour of each is documented below.

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

## v48 patch 1 migration

The v48 patch 1 revision is the largest single architectural change to the manager since v43. It bundles five distinct changes: intervening-partition handling, the architecture gate, the `LocalInputsId` state-file field, LKG-by-hash at any discovered recovery location, and transactional WIM replacement. It bumps `ScriptVersion` from 47 to 48, which changes the `SCRIPT` component of the `DesiredStateId` and forces one full-update pass per managed machine on the next scheduled run — the same shape as the v44 patch 1, v45 patch 1, v46 patch 1, and v47 patch 1 migrations.

The v48 pass is **not materially slower on a healthy machine than any other full-update pass**. On the ordinary non-intervening path, the pre-shrink target is C: and the pipeline is unchanged from v47; the transactional WIM replacement adds one hash of the existing target WIM (roughly 1-3 seconds on an NVMe) before the delete-then-copy sequence. On the intervening-anchor path, the pre-shrink target is the anchor instead of C:, and the anchor resize adds roughly one additional minute of I/O on a 720 GiB data partition.

Concretely, on the first run after the update, every machine will:

1. Compute the new `DesiredStateId` (with `SCRIPT=48`).
2. Compare it to the state file written by v47 (any patch).
3. Find a mismatch, set `needInject = $true`, and take the full-update path.
4. Run the architecture gate (must pass on x64; any other value exits `EXIT_WARNING`).
5. Compute and store the `LocalInputsId` in the state file on the state write at the end of the run.
6. Obtain a base WIM via the v47 three-source preference order (unchanged).
7. Strip and inject as in v47 (unchanged).
8. Plan geometry: on the ordinary layout, C: is the resize target; on an intervening-anchor layout (`C: | D: | Recovery`), D: is the resize target and is validated before any mutation.
9. Deploy transactionally: the existing target WIM is preserved as a rollback copy in the workspace, the target is deleted, the new WIM is copied and hash-verified, and on any copy failure the rollback copy is restored.
10. Write the state file with the new DSI, the `LocalInputsId`, and (as in v47) the `DeployedWinREMetadata` anchor.
11. Return to the fast path on the second run.

Three cases handled without operator attention:

- **Machines with `PendingReboot = true` or `EnableFailureAttempts >= 3`.** The DSI mismatch is detected before the pending-reboot and loop-breaker blocks, so the full-update path executes and the counters are reset.
- **Machines carrying a v47 deferral marker at `C:\Recovery\OEM\winre_partition_deferred.json`.** The marker is keyed by `DesiredStateId`; it is stale under the v48 DSI and is cleared on read by `Read-PartitionDeferral`.
- **Machines with a v47 patch 1 Step 3 or Step 4 checkpoint.** The checkpoint is bound to the v47 source hash; if the source is still available with the same bytes, it is honored; otherwise it is invalidated and the run rebuilds from Step 2. Both outcomes are handled without operator intervention.

Two cases where the v48 pipeline defers where v47 deferred differently:

- **Intervening-anchor surplus case.** A layout where the recovery partition being reclaimed is larger than the new bucket size rejects with the named surplus reason (`intervening anchor is N MiB smaller than the plan requires ...`). Under v47, the same layout would have produced the separation rejection because the intervening partition was in the way. Both reject; the v48 message names a different reason and offers the same deferral outcome. The operator path is unchanged: resolve the layout (extend the anchor, or reduce the desired recovery partition size), then delete the state file and deferral marker to force a retry. See [troubleshooting.md](troubleshooting.md).
- **Multi-intervening layout.** A `C: | D: | E: | Recovery` layout still rejects, as it did under v47. The v48 message names the intervening partitions with `Format-PartitionRef` enrichment.

### Rollback

Change `$ScriptVersion` back to 47 and revert the five bundled changes: the intervening-anchor plan logic, the architecture gate, the `LocalInputsId` computation and its state-file field, the LKG-by-hash discovery scan in `Get-LKGWinREImagePath`, and the transactional WIM replacement. The state file written under the v48 DSI becomes stale, the next run takes the full-update path under v47's behavior, and the `LocalInputsId` field becomes inert. No data is lost; another fleet-wide rebuild occurs on the next run.

## v49 migration

The v49 revision is the largest single release since v48. It bundles four distinct changes to the production pipeline (three inside the full-update path plus one startup refusal), two standalone backup and restore actions, a temporary crash-recovery scheduled task, and a rewritten interactive wrapper:

- **Source-ownership classification.** Every candidate source WIM is classified into one of four ownership classes, and a `Foreign-With-Drivers` source is preserved as-is rather than stripped and re-injected. This narrows the v47 strip-and-reinject policy to sources the manager itself deployed or in-box images with no third-party drivers.
- **Never-downgrade storage-driver check.** A candidate image that would inject a storage driver older than one already present in the mounted image is discarded — the mounted image is dismounted with `-Discard`, the source is preserved, the state file records `ForeignSourceAcceptedHash`, and the run exits `EXIT_WARNING`.
- **Pre-deployment storage-applicability gate.** The gate runs inside Step 3, after injection is confirmed complete, before ResetBase and before the dismount. The manager verifies that the candidate image contains an INF matching one of the machine's present SCSIAdapter-class devices. A candidate that does not match is refused, dismounted with `-Discard`, and deferred.
- **Native-boot VHDX fail-closed gate.** The manager refuses to run destructive operations when the OS disk's bus type is `File Backed Virtual` **and** at least one other disk is on a physical bus — the native-boot VHD/VHDX topology, where the running OS disk is a VHD/VHDX stored on a host physical disk. A hypervisor guest whose entire storage stack is virtual is not refused.
- **Backup and restore actions.** `-Action Backup` and `-Action Restore` are standalone commands that do not participate in the repair pipeline.
- **Temporary crash-recovery scheduled task.** Every Repair or Restore run registers a `WinRE Manager - Resume` task that fires at boot+1m and one-shot at T+1h; deleted on clean completion, preserved on interruption.
- **Rewritten interactive wrapper.** Reordered menu, semantic colours, an always-present restore option with a backup-presence hint, and a stable install location for the permanent maintenance task.

v49 bumps `ScriptVersion` from 48 to 49, which changes the `SCRIPT` component of the `DesiredStateId` and forces one full-update pass per managed machine on the next scheduled run — the same shape as the prior `ScriptVersion`-bump migrations.

The v49 pass is **not materially slower on a healthy machine than any other full-update pass**. The source-ownership classification is a set membership test against the source WIM's driver inventory (already enumerated by the v47 strip stage on the manager-owned path); the never-downgrade check is a version comparison against the same inventory; the applicability gate is a set membership test against the machine's storage controllers. On a machine whose source and manifest are unchanged from v48, the pass produces the same output as v48's pass did; the gates' decisions are the same.

Concretely, on the first run after the update, every machine will:

1. Compute the new `DesiredStateId` (with `SCRIPT=49`).
2. Compare it to the state file written by v48 (any patch).
3. Find a mismatch, set `needInject = $true`, and take the full-update path.
4. Run the startup sequence in code order: elevation guard (v48 patch 2), program lock (v44 patch 4), `-Action Backup` dispatcher, Audit Mode guard (v43 patch 5, further revision), temporary resume-task registration (v49), `-Action Restore` dispatcher, hardware and architecture resolution, architecture gate (v48 patch 1), native-boot VHDX fail-closed gate (v49). On a Repair run the two action dispatchers do not fire and execution continues past them. Of these, the elevation guard, the Audit Mode guard, the architecture gate, and the VHDX gate can exit `EXIT_WARNING` (or `EXIT_FATAL` for the elevation guard) before any further work.
5. Obtain a base WIM via the v47 three-source preference order (unchanged).
6. Classify the source's ownership class.
7. On a non-`Foreign-With-Drivers` source: strip to zero third-party drivers, then inject the current OEM and VMD recipe subject to the never-downgrade check.
   On a `Foreign-With-Drivers` source: skip the strip and injection; the source is preserved as-is.
8. Run the pre-deployment storage-applicability gate, then run ResetBase on the mounted image.
9. Plan geometry and deploy as in v48 (transactional WIM replacement; intervening-anchor handling where applicable).
10. Write the state file with the new DSI, the `LocalInputsId`, and the `DeployedWinREMetadata` anchor.
11. Return to the fast path on the second run.

Three cases handled without operator attention:

- **Machines with `PendingReboot = true` or `EnableFailureAttempts >= 3`.** The DSI mismatch is detected before the pending-reboot and loop-breaker blocks, so the full-update path executes and the counters are reset.
- **Machines carrying a v48 deferral marker at `C:\Recovery\OEM\winre_partition_deferred.json`.** The marker is keyed by `DesiredStateId`; it is stale under the v49 DSI and is cleared on read by `Read-PartitionDeferral`.
- **Machines with a v48 patch 1 Step 3 or Step 4 checkpoint.** The checkpoint is bound to the v48 source hash; if the source is still available with the same bytes, it is honored; otherwise it is invalidated and the run rebuilds from Step 2. The v49 source-ownership classification does not change the checkpoint binding — the checkpoint binds to the source WIM, not to the class the source is later classified into.

One case where the v49 pipeline defers where v48 deferred differently:

- **Pre-deployment storage-applicability gate refusal.** A machine whose candidate image does not contain an INF matching one of its present SCSIAdapter-class devices now defers with `EXIT_WARNING` where v48 would have deployed. **This gate has never fired in the field.** If a canary produces the refusal, capture the full log and the harness Option 1 "Storage controllers" block (v28).

The v49 `ScriptVersion` bump adds two optional fields to the state-file schema: `ForeignSourceAcceptedHash` (set when a `Foreign-With-Drivers` source is preserved, so subsequent runs recognize the accepted foreign source) and `LineageId` (the persistent lineage identifier written into the provenance marker and carried forward across runs). Both are absent on state files written by v48 or earlier; their absence is handled as any other missing field. The fields added by v47 patch 1 (`DeployedWinREMetadata`) and v48 patch 1 (`LocalInputsId`) are unchanged. The backup and restore actions write a `backup.json` sidecar in the operator-supplied backup directory; they do not touch the state file. The temporary resume task is a separate scheduled task, not a state-file field.

### Rollback

Change `$ScriptVersion` back to 48 and revert the v49 changes: the source-ownership classification, the never-downgrade storage-driver check, the pre-deployment storage-applicability gate, the native-boot VHDX fail-closed gate, the backup and restore actions, and the temporary resume task. The rewritten wrapper (`WinRE-Manager.cmd`) is independent of `WinRE.ps1`'s version and can be left in place; the wrapper's install option still registers the task against the stable `C:\ProgramData\OEM\WinRE-Manager\WinRE.ps1` copy. The state file written under the v49 DSI becomes stale, the next run takes the full-update path under v48's behavior, and the fleet converges onto the v48 pipeline. No data is lost; another fleet-wide rebuild occurs on the next run.

## Later patches (no ScriptVersion bump)

The v44 patches 2 through 8, the v46 patch 2 additions, the v47 patches 2 and 3, and the v48 patch 2 do **not** bump `ScriptVersion` and do **not** change the `DesiredStateId`. They apply to every subsequent run without a state-file action. A machine that is already healthy continues to take the fast path. A machine that was mid-deployment when the patch rolled out continues from where it was — the checkpoint and state-file schemas are unchanged.

The **v47 patch 2** revision is also not a fleet-wide rebuild: it does not bump `ScriptVersion`, and its only DSI-value change is a one-time event on a narrow machine class (machines with a padded `Win32_ComputerSystemProduct.Version` field). It is documented under `### v47 patch 2 specifically` below. The **v47 patch 1** revision is not in this list; it bumps `ScriptVersion` and is documented under "v47 patch 1 migration" above.

The **v48 patch 2** revision is also not a fleet-wide rebuild: it does not bump `ScriptVersion` and does not change the `DesiredStateId`. It adds the fail-fast elevation guard, a source-WIM hash cache that closes a pre-existing enable-only fallthrough path, a resize-target resynchronisation fix on the extension-failure fallback path (the D1 fix), and several cosmetic log and comment corrections. On a machine that ran v48 patch 1, the patch 2 build takes the fast path unchanged; the only observable difference is the startup banner and, on an unelevated launch, the millisecond refusal instead of a delayed `Mount-WindowsImage` failure. Documented under `### v48 patch 2 specifically` below.

- **v44 patch 2** adds `dism /cleanup-image /StartComponentCleanup /ResetBase` to the full-update pipeline; the size reduction materialises on the next natural rebuild, not immediately.
- **v44 patch 3** adds the destructive-path C: encryption guard inside `Ensure-AdequateRecoveryPartition` (removed in v44 patch 6) and a `base.wim` cleanup on the injection-failure abort branch (retained).
- **v44 patch 4** adds the program lock at `C:\ProgramData\OEM\Logs\WinREManager.lock`, so a second concurrent instance fails fast with `EXIT_WARNING` instead of colliding at Step 2.
- **v44 patch 5** adds the offline fallback for the driver manifest fetch and a 15-second timeout on every network call.
- **v44 patch 6** removes the v44 patch 3 destructive-path C: guard; makes Lenovo OEM-pack resolution distinguish five states; makes VMD hardware detection fail-closed; adds the Step 2 stale-file cleanup on the normal path; and corrects the OS-fallback remediation wording.
- **v44 patch 7** closes a non-convergence loop by making the type-coded classifier authoritative across every recovery-partition decision — the fast-path count, the active-location classifier, the final-verification classifier, and `Find-SuitableRecoveryPartition`. It also clears the VMD extraction directory before each extraction, and adds C:'s actual encryption state to the destructive-replacement WARN (diagnostic only; the decision to proceed is unchanged).
- **v44 patch 8** reorders workspace initialization so that healthy fast-path runs, enable-only repairs, and offline deferrals no longer validate checkpoints, wipe stale scratch files, or create the workspace. Full-update checkpoint and resume behavior is otherwise unchanged.
- **v46 patch 2** adds three log lines that record the registered WinRE version, the source WIM build, and the post-deploy WIM build on every run, and guards the two `Get-Partition -DiskNumber` calls in `Get-RecoveryPartitions` against the empty-disk read that throws `CmdletizationQuery_NotFound_DiskNumber` on machines with an SD/MMC card reader. It also applies four post-review hardenings of `Ensure-AdequateRecoveryPartition` — the pre-deletion resolver guard, the extension-fallback bucket cap, the layout-assertion fail-closed branch, and the deletion-failure partial-rollback reporting. The build-logging values do not enter the `DesiredStateId`; the read guard silences a cosmetic error; the four hardenings change only the failure behaviour of the destructive sequence.
- **v47 patch 3** adds `Format-PartitionRef` to the seven partition-identity plan-rejection reasons, so each reason now names the offending partition (disk number, partition number, size, label, type code); adds `Remove-WindowsDriver` and `BusType` to the harness parser self-test; makes `-NonInteractive` exit non-zero on any FAIL; guards the Lenovo-pack call on vendor; and adds the `Compare-WimServicingMetadata` harness mirror with an eight-case regression test. It does not change `ScriptVersion` or the `DesiredStateId`.
- **v48 patch 2** adds the fail-fast elevation guard, the source-WIM hash cache, the D1 fix (a resize-target resynchronisation on the extension-failure fallback path), and several cosmetic log and comment corrections. It does not bump `ScriptVersion` and does not change the `DesiredStateId`. The elevation guard refuses an unelevated launch in milliseconds; on an elevated launch the behavior is unchanged. The source-WIM hash cache closes a pre-existing enable-only fallthrough path where the state file would not be written because the source WIM became inaccessible after the temporary drive letter was removed.

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
- **v47 patch 2**: revert the OS-fallback and dedicated missing-WIM guards to their status-gated form; remove the base-WIM copy-integrity check in Step 2; remove the Step 3 checkpoint's `-SourceHash` binding and revert the checkpoint validator to its pre-patch-2 `$candidateHashes` form; remove the `Select-BaseWinRESource` helper and inline its logic back into Step 2 and the checkpoint validator; revert the conservative null-source-hash handling; restore `$ActiveLocationHash` as an unconditional participant in checkpoint validation; revert the `Win32_ComputerSystemProduct.Version` trim; revert the workspace candidate filter to `IsSystem` alone; remove the drive-letter assignment verification (the DOS Devices registry check, the post-assignment re-query, and the loop's target-partition / target-disk bail-out); revert `Get-GitHubBaseWinRE` to throw on extraction failure; revert the extension-failure fallback geometry and sizing to the pre-patch-2 form (including the layout assertion's use of `$plan.AlignedManagedExtentEnd`); revert the duplicate `Verified partition` log line suppression; remove the unrecognized-route guard.
- **v47 patch 3**: remove the final-verification retry; revert the DryRun enable-only escalation to the pre-patch-3 shape; revert `Remove-ItemIfExist` to log unconditionally; revert the enable-only `-not $targetPart` branch to `$needInject = $false`; revert the seven plan-rejection reasons to the unenriched form; revert the race-detector comment to the "microseconds" phrasing.
- **v48 patch 2**: remove the elevation guard from the top of the main `try` block; remove the `$cachedSourceHash` / `$cachedSourceBuild` / `$cachedSourceMetadata` capture and revert the state-write section to re-reading `$SourceWim`; revert the two comment corrections. None of these affect the state-file schema or the `DesiredStateId`.

None of these rollbacks affects the state-file schema or the `DesiredStateId`. (The v47 patch 1 rollback does affect the schema — it introduces the `DeployedWinREMetadata` field — and is documented separately under "v47 patch 1 migration" above.)

## Exit code handling

The script's exit codes carry meaning. See [exit-codes.md](exit-codes.md) for the full matrix.

For MDM / orchestration:

| Exit code | Recommended action |
|---|---|
| 0 | None. Record success. |
| 1 | Reboot the machine at the next convenient window. The script will finish on the next boot. |
| 2 | Investigate. WinRE is functional but degraded, or the script deferred work, or the enable step failed and the counter incremented. Collect the log and check the state file's `LastUpdated` timestamp, its `LastEnableResult` field, whether a deferral marker exists at `C:\Recovery\OEM\winre_partition_deferred.json`, whether a `WinRE Manager - Resume` scheduled task is present, and the state file's `LocalInputsId`. **Twenty-three** distinct cases are documented in [exit-codes.md](exit-codes.md): OS-fallback, **v49 source-ownership driver-enumeration failure**, **v49 `Foreign-With-Drivers` source preserved**, **v49 never-downgrade detection**, **v47 strip-failure abort**, **v49 pre-deployment storage-applicability gate refusal**, **v47 patch 2 base-WIM copy-integrity check**, Step 3 → Step 4 pipeline gate, Audit Mode deferral, VMD-query-indeterminate deferral, OS-fallback BitLocker deferral, **v45 pre-shrink deferral**, **v47 race-detector abort** at the two `/disable` sites, enable-only failure, concurrent-instance deferral (v44 patch 4), **offline-fallback deferral (v44 patch 5)**, **v48 architecture-gate refusal**, **v48 intervening-anchor surplus rejection**, **v48 multi-intervening rejection**, **v48 offline `LocalInputsId` mismatch**, **v49 native-boot VHDX fail-closed gate**, **v49 restore `/enable` failure after WIM replacement**, and **fast path under offline fallback** (the degraded-success case). The concurrent-instance case is **not a failure** — the other instance is doing the work. The offline-fallback fast-path case is a **degraded-success** — the machine is healthy and unchanged. The v49 source-ownership driver-enumeration failure, v47 strip-failure abort, v49 applicability-gate refusal, v47 patch 2 base-WIM copy-integrity check, Step 3 → Step 4 pipeline gate, Audit Mode deferral, VMD-query-indeterminate deferral, OS-fallback BitLocker deferral, v45 pre-shrink deferral, v47 race-detector abort, offline-fallback deferral, v48 architecture-gate refusal, v48 surplus, v48 multi-intervening, v48 `LocalInputsId`, v49 VHDX, and v49 applicability cases are **protective deferrals** — no state was committed. The v49 `Foreign-With-Drivers` preservation and v49 never-downgrade detection **do** write the state file (with `ForeignSourceAcceptedHash` set) but perform no partition work and deploy nothing. The v49 restore `/enable` failure deletes the state file and preserves the resume task. |
| 3 | Investigate. The run failed and did not write state, or the enable-failure loop-breaker fired. Collect the log. Do not retry automatically. Two exceptions: the v48 patch 2 elevation guard exits 3 with `FATAL: WinRE Manager requires an elevated (Administrator) PowerShell session.` — this is expected behavior on an unelevated launch, not a failure; relaunch from an elevated prompt or via `scripts\WinRE-Manager.cmd`. The v49 restore rollback failure (see "Backup and restore" above) exits 3 with `rollback restore hash verification failed` and warrants a bug report; the branch has not been exercised in the field. |

Do **not** treat exit code 2 as success. A machine in OS-fallback is intentionally reported as a warning; it will be treated as a healthy machine by the fast path only if the state file records `UsedOSFallback = true` for the current `DesiredStateId`. A machine on which the Audit Mode guard or a v45 pre-shrink deferral fired will have an unchanged (or absent) state file and a single deferral line in the log. See [exit-codes.md](exit-codes.md) for how to distinguish the twenty-three cases.

Do **not** configure retry loops that ignore the exit code and re-run unconditionally. Deferrals are not improved by retrying — the same gate will fire on the next run (Rule 4). Enable failures are handled by the counter; after three consecutive failures the loop-breaker fires and requires manual intervention. The concurrent-instance deferral is not a failure at all; retrying while the other instance is still running will simply produce another `EXIT_WARNING`. The VMD-query-indeterminate deferral is not improved by retrying — the underlying PnP service issue must be resolved. The v45 pre-shrink deferral is not improved by retrying until the constraint is resolved (free space on C:, disk layout, oversized recovery partition, or shrink failure). The one exception is the transient volume-read failure: it returns `RetrySuppressible = $false` and does not write a deferral marker, so the next scheduled run retries it automatically without operator intervention. The v47 race-detector abort is not improved by retrying immediately — the underlying Windows Update servicing of the registered WinRE is a transient condition, and the next scheduled run (or a manual re-run after the WU settles) is the correct response. The v47 strip-failure abort is not improved by retrying until the specific strip failure has been diagnosed — see [troubleshooting.md](troubleshooting.md) for the specific failure modes. The v48 architecture-gate refusal is a stable deferral: any machine whose architecture is not `x64` will continue to exit 2 on every run until the manager adds support or the machine is replaced. The v48 intervening-anchor surplus and multi-intervening rejections are stable layout deferrals; a retry produces the same rejection until the layout is changed. The v48 offline `LocalInputsId` mismatch resolves on the next run with network, which recomputes the DSI. The v49 native-boot VHDX gate is a stable topology deferral. The v49 applicability gate requires manifest or OEM pack data to be updated — a retry alone will produce the same refusal. Resolve the underlying condition, then re-run.

## MDM / Intune

Deploy via a Win32 app or a PowerShell script platform script. The Intune "Scripts and remediations" feature is well-suited:

- **Detection rule:** `Test-Path C:\ProgramData\OEM\Logs\WinRE-Manager.log` and `reagentc /info` reports `Enabled`.
- **Remediation script:** `WinRE.ps1` invoked as SYSTEM.
- **Run in 64-bit PowerShell on the system:** required.

For a curated deployment, package the script as an Intune Win32 app with a detection rule on the log file and `reagentc` state. Run once, then allow the built-in weekly scheduled task to keep the state fresh.

When using Intune to push a remediation, be aware that the remediation script may run outside the scheduled task's `IgnoreNew` gate. As of v44 patch 4, the program lock handles this: if the weekly task happens to be running at the same moment, the remediation exits with `EXIT_WARNING` (code 2) and the message `Another WinRE Manager instance is already running (program lock file is exclusively held)`. This is not a failure. The remediation will succeed on the next cycle, or you can wait for the scheduled task to complete and re-run the remediation manually.

**Do not disable the lock to "fix" the remediation.** Before patch 4, the same collision caused an `EXIT_FATAL` (code 3) with a rename error. Some Intune remediation pipelines treated that as a hard failure and retried aggressively, which could produce a cascade of colliding runs. The lock converts the collision into a clean, self-limiting `EXIT_WARNING`. If your Intune pipeline retries on any non-zero exit, adjust it to treat code 2 as a soft failure (route to a queue) and code 3 as a hard failure (investigate). See [exit-codes.md](exit-codes.md) for the recommended orchestration policy.

**v49 note.** The wrapper's install option registers a task named `Maintain Windows RE` against the stable `C:\ProgramData\OEM\WinRE-Manager\WinRE.ps1` copy. If your Intune package ships both the wrapper and a scheduled task, decide which one owns the task registration. Registering both produces two distinct scheduled tasks that contend on the same program lock at `C:\ProgramData\OEM\Logs\WinREManager.lock`, because the lock path is fixed and not derived from the script's own path — a run from either task serializes against a run from the other, and the loser exits `EXIT_WARNING` with `Another WinRE Manager instance is already running (program lock file is exclusively held)`. Two differently-named tasks do not collide on each other's `IgnoreNew` policy, since that policy is per-task. The recommended arrangement is: the Intune package ships `WinRE.ps1`, `Test-WinRE.ps1`, and the map builders; the wrapper is for interactive use on a single machine, not for the fleet deployment. Fleet deployments use the task XML template above or an Intune-registered task with the operator's chosen script path.

## Hosting your own maps, manifest, and base WIM repository

By default, WinRE Manager fetches the driver manifest, the three OEM maps, and the base WIM repository from the project maintainer's GitHub account. All five artifacts can be replaced with self-hosted equivalents so your fleet does not depend on those external endpoints.

See [self-hosting.md](self-hosting.md) for the trust model, the exact URLs and variables to change, the map-builder scripts, and the air-gapped deployment procedure. The v49 pre-deployment gates read the same artifacts (the manifest's `requiredDevices` patterns, the OEM pack's INFs) — keep them complete for the hardware you deploy to.

## Log collection

The log at `C:\ProgramData\OEM\Logs\WinRE-Manager.log` is append-only and grows unbounded. Rotate it via your existing log-collection pipeline:

- **Windows Event Log forwarding.** `WinRE.ps1` does not write to the Event Log; add a wrapper script that reads the last N lines of the log and writes them as an event after each run.
- **SCCM / Intune.** Use a file-based collection rule on `C:\ProgramData\OEM\Logs\WinRE-Manager.log`.
- **Syslog / Splunk.** Use the Windows agent's file-tailing feature.

At ~100 log lines per healthy run, an unmanaged machine generates ~5 MB per year. Rotation is not urgent but is worth having.

**v49 note.** The v49 source-ownership classification, the never-downgrade check, and the pre-deployment storage-applicability gate each log their decision on the runs where they fire (the applicability gate has never fired in the field; the other two are new in v49). If you collect logs, watch for those lines as the first data point on the new pipeline's behavior on your hardware.

## Canary and ring deployment

The script is destructive on the recovery partition and non-destructive on the OS partition, but it does modify the OS partition geometry on the shrink path. Roll out in rings:

1. **Canary ring.** One or two machines, GPT. Under the target-volume policy, C:'s BitLocker state may be any of fully decrypted, suspended, or mid-encryption; only the OS-fallback route depends on it, and a healthy canary machine will not take that route. Run `Test-WinRE.ps1` first, then `WinRE.ps1 -DryRun`, then `WinRE.ps1`. Verify exit code 0. A transient exit code 2 from a concurrent scheduled task that happened to be running is not a failure — see "One instance per machine" above.
2. **Early ring.** ~5% of the fleet. Mix of vendors and partition styles.
3. **Broad ring.** The rest.

### v49 specifically

The v49 revision bumps `ScriptVersion` from 48 to 49 and forces one full-update pass per managed machine. The pass is not materially slower than any other full-update pass. The canary is primarily about confirming that the new gates behave as expected on your fleet's hardware and confirming that the wrapper's new menu works as documented.

Watch for:

- **Machines that exit 0 after the first v49 full-update pass.** The normal case. The log should show the source-ownership class the candidate received, the storage-driver injection decisions, the applicability gate's pass decision, and the state write with the v49 DSI. `Operating mode: DEDICATED` confirms the end state. (A never-downgrade detection does not produce this shape — it discards the candidate and exits 2 before the applicability gate runs.)
- **Machines whose log shows a `Foreign-With-Drivers` source preservation.** The v49 pipeline skipped the strip and injection, dismounted with `-Discard`, and exited `EXIT_WARNING` without deploying anything. The existing WinRE route is untouched; the state file records `ForeignSourceAcceptedHash` so subsequent runs recognize the preserved source and take the fast path. This is the intended v49 behavior for a source the manager did not deploy. If your fleet has machines whose registered WinRE was populated by vendor servicing tools, expect this line; if you want the manager's recipe applied, the source must be replaced with a `Manager-Owned`, `Manager-Lineage`, or `Foreign-No-Drivers` source.
- **Machines whose log shows a never-downgrade detection.** A candidate image would inject a storage driver older than one already present in the mounted image. The candidate is discarded — dismounted with `-Discard`, the source preserved, the state file records `ForeignSourceAcceptedHash`, and the run exits 2. The existing WinRE route is untouched. This is the intended v49 behavior for a machine whose source would regress a driver. Watch for repeated detections on the same driver across the fleet — that suggests the manifest or OEM pack is stale for your hardware.
- **Machines whose log shows the pre-deployment storage-applicability gate refusing a candidate.** **This gate has never fired in the field.** If a canary produces the refusal, capture the full log and the harness Option 1 "Storage controllers" block (v28). The machine defers with `EXIT_WARNING`, the WIM is not written to the active route, and the old recovery route is intact.
- **Machines whose log shows the native-boot VHDX fail-closed gate refusing.** A VHDX-boot machine will continue to exit 2 on every run until the topology is supported or the machine is converted. Do not retry expecting a different result.
- **Machines whose log shows a `WinRE Manager - Resume` task after a run.** The v49 temporary resume task is preserved on interruption. Do not delete it manually — the next boot or the T+1h one-shot will complete the operation. If the task keeps reappearing after each attempt, the interrupted operation is failing in the same way every time; read the log around the failing step.
- **Wrapper usability canary.** On a single machine, run `WinRE-Manager.cmd` and confirm the reordered menu appears as documented: SAFETY (backup) at the top, DIAGNOSTICS next, MAINTENANCE next, REPAIR next with the yellow `LIVE` chip on the run-for-real option, RECOVERY last with the restore option always present and a backup-presence hint on the recovery row, and Quit bound to the `Q` key. Confirm the install / remove maintenance options (5 and 6) register and unregister the `Maintain Windows RE` task successfully. Confirm the backup (option 1) and restore (option 8) actions complete against a real backup directory.

- **Backup and restore actions.** Both actions are new in v49. Run a `-Action Backup` on a canary and confirm the `backup.json` sidecar is written alongside the WIM copy. Run a `-Action Restore` against that backup and confirm the WIM is restored, the state file is not modified, and `reagentc /info` reports `Enabled`. The two restore mid-transformation failure paths have not been exercised in the field; if the canary produces either, capture the full log and file a bug — the transactional helper's rollback behaviour on real storage is high-signal.

### v48 patch 2 specifically

The v48 patch 2 revision does not bump `ScriptVersion` and does not change the `DesiredStateId`. It adds the fail-fast elevation guard, a source-WIM hash cache that closes a pre-existing enable-only fallthrough path, a resize-target resynchronisation fix on the extension-failure fallback path (the D1 fix), and several cosmetic log and comment corrections. The canary is primarily observational:

- **Confirm the version banner reads `v48 patch 2`.** The startup line reads `========== WinRE Manager Started (v48 patch 2) ==========`.
- **Confirm the elevation guard fires on an unelevated launch.** From a non-admin PowerShell, running `.\scripts\WinRE.ps1 -DryRun` should produce a single FATAL log line (`FATAL: WinRE Manager requires an elevated (Administrator) PowerShell session.`) and exit code 3 in milliseconds. The only file-system operation on the refusal path is the creation of the log directory that the FATAL line is written into. From an elevated prompt, the same command should proceed as in v48 patch 1.
- **Confirm the elevation guard accepts the SYSTEM context.** The scheduled task runs as SYSTEM; the guard should not fire on scheduled runs. If it does, the SYSTEM token's Administrator role membership is not being recognized and the scheduled task will fail with code 3 on every run — investigate before rolling out.
- **The source-WIM hash cache fix is not observable on a healthy canary.** It closes a path on the enable-only fallthrough when `/setreimage` fails. The change is code-review-only in v48 and has not been exercised in the field.
- **The comment corrections are inert.**

### v48 patch 1 specifically

The v48 patch 1 revision bumps `ScriptVersion` from 47 to 48 and forces one full-update pass per managed machine. The pass is not materially slower than any other full-update pass on the ordinary non-intervening path; the intervening-anchor path adds roughly one additional minute of anchor resize on the anchored machine class.

Watch for:

- **Machines that exit 0 after the first v48 full-update pass.** The normal case. The log should show the architecture gate line (`Architecture gate passed: x64`), the `LocalInputsId: <hash>` line, and — on a machine whose only candidate recovery partition is undersized and whose predecessor on the OS disk is a shrinkable data partition — the `Intervening-anchor plan: anchor is disk N part M; anchor shrink ...` line followed by the anchor shrink, delete, `New-Partition`, layout assertion, and `reagentc /enable` sequence. `Operating mode: DEDICATED` confirms the end state.

- **Machines whose log shows `Intervening-anchor plan: ...` and complete `DEDICATED`.** This is the v48 feature working on the exact layout that motivated it (the AMD Ryzen 7 5825U machine with `C: | D: | Recovery`). The 2026-10-06 field run confirmed this path end-to-end; a canary that produces the same shape is expected.

- **Machines whose log shows `Unsupported OS architecture '<arch>'` and exit 2.** The v48 architecture gate refused. This is expected on ARM64, x86, or machines whose architecture could not be resolved. No state was committed; the machine is unchanged. **This is a stable deferral, not a failure**: any machine in the fleet whose architecture is not `x64` will continue to exit 2 on every run until the manager adds support or the machine is replaced. ARM64 support would be a separate, tested change to the WinRE image pipeline.

- **Machines whose log shows `intervening anchor is N MiB smaller than the plan requires ...` and exit 2.** The v48 surplus-case rejection. The old recovery partition is intact; no partition was touched. Resolve the layout (extend the anchor to close the gap, or reduce the desired recovery partition size) and delete the state file and deferral marker to force a retry. See [troubleshooting.md](troubleshooting.md).

- **Machines whose log shows `recovery-typed partitions exist beyond the intervening anchor's recovery cluster` and exit 2.** The v48 multi-intervening rejection. This is unchanged behaviour from v47 for the multi-intervening case; the message is now enriched with `Format-PartitionRef` entries naming the intervening partitions.

- **Machines whose log shows `Preserving existing target ... as rollback copy at <path>`.** The v48 transactional WIM replacement took the rollback-copy branch, meaning the deployment target was an existing partition with an existing WIM. The subsequent log lines confirm the copy, the hash verification, and the release of the rollback copy after `/setreimage` and `/enable`. The branch is expected on the reuse path and on the OS-fallback path; it is skipped on the create-fresh-partition path, where there is no pre-existing WIM to preserve.

- **Machines whose log shows `Deploy-WimTransactional ... copy failed - restoring rollback copy` and exits code 3 (`EXIT_FATAL`).** The transactional replacement caught a copy failure. The rollback copy was restored and hash-verified by `Deploy-WimTransactional` before it returned failure, so the previous WIM is in place on the active route — but both call sites (`Deploy-WimToPartition` and the OS-fallback deploy branch) treat any `$false` return as fatal and exit before `/setreimage` or `/enable` is attempted. The machine is left with WinRE disabled and the previous WIM in place; the next scheduled run re-attempts deployment. This branch is code-review-only in v48 and has not been exercised in the field. If a canary hits it, capture the full log per the [Reporting a bug](../CONTRIBUTING.md#bug-reports) section.

- **Offline v48 machines.** A machine whose state file was written by v47 and whose next run is offline will have `$needInject = $true` forced by the DSI mismatch and will exit 2 with `Offline fallback: the machine requires a full update`, since a rebuild needs the live manifest. The `LocalInputsId` comparison does not fire on that path; it fires when a full-update-needing machine has a v48 state file and its hardware has drifted. The next online run writes the v48 state file and the anchor.
- **Offline `LocalInputsId` mismatch (v48 patch 1).** A machine whose state file was written by v48 (with a `LocalInputsId`), whose next run is offline, and whose locally-observable deployment inputs have changed (hardware identity, OS build, CPU vendor/generation) will exit 2 with `Offline fallback: stored LocalInputsId <hash> does not match the current locally-computable inputs <hash>`. This is a protective deferral: the stored `DesiredStateId` no longer describes this machine. The machine is unchanged; bring it online so a fresh manifest can be fetched and a new DSI computed. Note that this check fires **before** the offline fast path evaluates the drift detector, so a machine with both a `LocalInputsId` mismatch and a metadata anchor mismatch reports the `LocalInputsId` line first.

### v47 patch 2 specifically

The v47 patch 2 revision does not bump `ScriptVersion`, and on the ordinary machine it does not change the `DesiredStateId`. Two conditional rebuild triggers apply to a narrow machine class:

1. **A machine with a v47 patch 1 Step 3 checkpoint on disk** at the moment of the upgrade has that checkpoint invalidated on its first v47 patch 2 run. Legacy v47 patch 1 Step 3 checkpoints carry no source-content hash, and the new validator requires one; the run rebuilds from Step 2 against the current source. This is the correct convergence for a machine whose checkpoint lineage cannot be proven under the new rules — the alternative (accepting the checkpoint as-is) would leave the exact lineage ambiguity this patch exists to close.

2. **A machine whose `Win32_ComputerSystemProduct.Version` field is padded** with trailing whitespace (observed: ASUS) and whose padded value is at least four characters long while its trimmed value is shorter than four sees a one-time `DesiredStateId` change from the Version-trim fix. The `HW` component changes from the four-character prefix of the padded value to `<vendor>|<model>|UNKN`, because the trimmed value falls below the four-character machine-type length threshold. Those machines rebuild once on the next scheduled run. All other machines continue on the fast path.

Everything else in v47 patch 2 is either a hardening fix on an error path — the OS-fallback missing-WIM guard, the base-WIM copy-integrity check, the workspace candidate filter, the extension-failure fallback geometry and sizing, the unrecognized-route guard, `Get-GitHubBaseWinRE`'s return contract, the Step 3 source-content-hash binding, and the checkpoint validator's use of `Select-BaseWinRESource` — or a comment or log correction. None of these changes the deployed bytes on a healthy machine.

## Rolling back

The script does not have an uninstall path. To disable it:

```powershell
schtasks /Delete /TN "WinRE Manager" /F
schtasks /Delete /TN "WinRE Manager Weekly" /F
```

The two deletions cover the `schtasks.exe` two-task form. The XML form above registers a single task named `WinRE Manager` with both triggers; a deployment that used the XML template needs only the first line. The second line is a no-op on an XML-deployed machine — `schtasks /Delete` will report the task not found — and is harmless.

If the wrapper's install option was used, the task name is `Maintain Windows RE`:

```powershell
schtasks /Delete /TN "Maintain Windows RE" /F
```

The wrapper's removal option (menu option **6 — Remove automatic maintenance**) performs the same unregistration.

The state file, deferral marker, log, lock file, and any deployed recovery partition remain. The machine is in a healthy end state and Windows Update will continue to service the recovery image normally. The lock file at `C:\ProgramData\OEM\Logs\WinREManager.lock` is inert once the scheduled task is removed; it can be deleted manually if desired, and it will be recreated if the script is ever run again. The deferral marker at `C:\Recovery\OEM\winre_partition_deferred.json` is likewise inert; it can be deleted manually.

If the wrapper's install option was used, the installed copy at `C:\ProgramData\OEM\WinRE-Manager\WinRE.ps1` is left in place after removal. Delete the containing directory manually if you want it gone:

```powershell
Remove-Item "C:\ProgramData\OEM\WinRE-Manager" -Recurse -Force
```

If a `WinRE Manager - Resume` scheduled task is present, it indicates an interrupted Repair or Restore; do not delete it manually unless you intend to abandon the interrupted operation. To remove it after resolving the interrupted state:

```powershell
schtasks /Delete /TN "WinRE Manager - Resume" /F
```

If you need to revert a machine to its pre-WinRE-Manager state, restore the partition layout from a backup. The script does not create one.

To revert a `DesiredStateId` change specifically, see the "Rollback" subsections under "v44 patch 1 migration", "v45 patch 1 migration", "v46 patch 1 migration", "v47 patch 1 migration", "v48 patch 1 migration", and "v49 migration" above. To revert code from a patch that does not change the `DesiredStateId`, see the "Rollback for later non-bumping patches" subsection above.

## Related documents

- [architecture.md](architecture.md) — the four design invariants that this document translates into deployment-time guidance, plus the pipeline, the control-flow invariants, the state-carrying artifacts, and the v49 pipeline refinements.
- [self-hosting.md](self-hosting.md) — how to replace the driver manifest, OEM maps, and base WIM repository with your own hosting, including the trust model, the air-gapped deployment procedure, and the v49 pre-deployment gates' implications.
- [exit-codes.md](exit-codes.md) — how to interpret the exit codes, including the twenty-three cases for code 2.
- [state-and-idempotency.md](state-and-idempotency.md) — what the state file records, the deferral marker's relationship to the deployment identity, the offline fallback's residual risk, and the v49 pipeline refinements.
- [recovery-partition.md](recovery-partition.md) — the full partition lifecycle, including the v45 single-boundary geometry, pre-shrink deferral reasons, and the v49 native-boot VHDX fail-closed gate.
- [driver-injection.md](driver-injection.md) — the v47 strip stage, the v49 source-ownership classification, the never-downgrade storage-driver check, and the pre-deployment storage-applicability gate.
- [troubleshooting.md](troubleshooting.md) — when the run fails, including the v49 gate refusals and the resume-task states.
