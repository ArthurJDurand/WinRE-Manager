# State and idempotency

WinRE Manager is idempotent via a single hash called `DesiredStateId`. Everything else — the state file, the checkpoint file, the fast path — exists to make that hash work.

## `DesiredStateId`

A SHA256 computed deterministically from five fields:
HW=<Manufacturer>|<Model>|<MachineType>
OS=<Build>
MANIFEST=<manifest.version>
OEMPACK=<OEM pack version, or NONE>
SCRIPT=<ScriptVersion>

text

The five fields are joined with `;;`, encoded as UTF-8, and hashed. The result is a 64-character hex string.

### What each field means

- **`HW`** — vendor, model, and (for Lenovo) machine type. A Lenovo ThinkPad 21L1 and a Lenovo 21L2 have different IDs. Two machines of the same model have the same ID.
- **`OS`** — the Windows build number. A machine that upgrades from 26100 to 26200 gets a new ID and rebuilds.
- **`MANIFEST`** — the version field of the driver manifest JSON. The manifest author bumps it when driver URLs change.
- **`OEMPACK`** — the resolved OEM pack version for this machine's vendor. For Dell it is the `dellVersion`; for HP the SoftPaq `version`; for Lenovo the `dsId`. If the vendor is unsupported or the map failed to resolve, this is `NONE`.
- **`SCRIPT`** — the production script's `ScriptVersion` constant.

### When the ID changes

Any of the following cause the ID to change, which forces a full rebuild on the next run:

- A new `ScriptVersion`.
- A new Windows build.
- A new manifest `version`.
- A new OEM pack version for the machine's vendor.
- A hardware change (motherboard swap that changes `Manufacturer`/`Model`/`MachineType`).

### When it does not change

- Any cosmetic or logging fix shipped without bumping `ScriptVersion`.
- Any patch generation shipped under the same `ScriptVersion` — v43 patch 2, 3, and 4 all ship under v43, so the ID is unchanged and healthy machines do not rebuild.
- A new WIM hash at the registered location. That is a separate check (see below), not part of the ID.
- A Windows Update that changes the WIM inside the recovery partition without changing the OS build.

This is deliberate. `ScriptVersion` bumps are expensive: they force every healthy machine to rebuild. The project's policy is to bump only when the deployed WIM or the partition layout changes. Bug fixes to the main flow — including v43 patch 4's checkpoint/state interaction fix — ship under the same version and correct the affected machines on their next run without disturbing the rest.

## The state file

Path: `C:\Recovery\OEM\winre_state.json`.

### Schema

```json
{
    "DesiredStateId":           "<64-char hex>",
    "CurrentImageHash":         "<SHA256 hex of the deployed winre.wim>",
    "InjectedDriverSetVersion": "<manifest.version at deploy time>",
    "LastUpdated":              "yyyy-MM-dd HH:mm:ss",
    "PendingReboot":            false,
    "UsedOSFallback":           false,
    "RepairAttempts":           0,
    "DeployedDiskNumber":       4,
    "DeployedPartitionNumber":  4
}
DeployedDiskNumber and DeployedPartitionNumber are present only when the deployment reached a dedicated recovery partition or the OS-fallback path. They are used by the pending-reboot path to re-point reagentc /setreimage at the correct location after a reboot.

Read semantics
Read-WinREState is called once, near the top of the main flow, with the current DesiredStateId.

If the file does not exist → return all-$null / all-$false defaults, treated as "no state."

If the file exists and DesiredStateId matches → return the parsed state. Log "State file accepted."

If the file exists and DesiredStateId does not match → return defaults, log "State file DesiredStateId mismatch - stale." The file is not deleted; the next write overwrites it.

If the file exists but cannot be parsed → return defaults, log "Failed to parse state file."

Note: the stale file is left in place. If the next run also fails to reach a state-write point, the stale file stays. The next successful run overwrites it.

Write semantics
Write-WinREState is called from:

The fast path when PendingReboot or RepairAttempts was carried in from a previous run and needs clearing.

The enable-only path, to record the registration result.

The pending-reboot path, to update the PendingReboot and RepairAttempts flags.

The full-update path, after step 6 succeeds.

Before writing, the function checks $Script:GeometryRestoreFailed. If that flag is set — meaning a post-shrink failure left C: shrunken and Restore-OSPartitionSize could not verify the geometry was restored — the function deletes the state file (if it exists) and returns without writing.

The deletion is deliberate. Skipping the write would not be enough: if the previous state file's DesiredStateId matched the current one, the next run's Read-WinREState would accept it, the count=0 exemption would fire, and C: would stay shrunken indefinitely. Deleting the file forces the next run to treat the state as absent, set needInject = $true, and re-run the full-update path, which re-extends C: as part of the destructive attempt.

If the deletion itself fails, the failure is logged as an error. Manual intervention is then required to force a retry.

Idempotency via the state file
The fast path fires when:

WinRE is enabled, AND

The state file's DesiredStateId matches the current one, AND

Exactly one recovery partition exists on the OS disk, AND

The currently-registered partition is on the OS disk and is a recovery partition, AND

The deployed WIM hash at the registered location matches CurrentImageHash.

If all five conditions hold, the machine is in the correct end state. The fast path runs Remove-StrayRecoveryPartitions (a read-only scan when there are no strays), optionally clears stale PendingReboot/RepairAttempts flags, and exits with EXIT_SUCCESS.

If any condition fails, the script forces a full rebuild. The conditions above are also the fast-path elseif branches — the log records which one failed.

The checkpoint file
Path: C:\ProgramData\OEM\Logs\winre_checkpoint.txt.

Format: Step|DesiredStateId, one line, e.g. 3|a1b2c3....

Purpose
The checkpoint file exists to make a partially-completed full-update run resumable. If a run completes step 2 and then the machine is rebooted or the task is killed, the next run can resume from step 3 instead of redoing step 2. This saves time on slow machines and on slow networks.

Steps
Step	Meaning
0	No checkpoint. Start at step 1.
1	Step 1 (WorkDir wipe) complete. Resume at step 2.
2	Step 2 (base WIM) complete. Resume at step 3.
3	Step 3 (mount/inject) complete. Resume at step 4.
4	Step 4 (optimize) complete. Resume at step 5.
6	Full-update path complete. The checkpoint is about to be deleted.
Step 5 is not checkpointed. It is the partition-and-deploy step, and resuming in the middle of it would leave the machine in an unrecoverable state.

Guards on resume
After Get-Checkpoint, the main flow applies two guards:

powershell
if ($step -ge 2 -and -not (Test-Path "$WorkDir\base.wim")) { $step = 1 }
if ($step -ge 4 -and -not (Test-Path "$WorkDir\winre_optimized.wim")) { $step = 4 }
If the checkpoint says step ≥ 2 but base.wim is missing (WorkDir was wiped manually, or the machine was rebooted into a clean state), reset to step 1. Same for winre_optimized.wim and step 4.

The v43 patch 4 migration guard
A separate guard runs after $needInject has been fully determined:

powershell
if ($step -ge 4 -and $needInject) {
    $step = 2
}
This handles the case where a prior run failed injection and left a checkpoint at step ≥ 4 with a valid (but stale) state file. Without the guard, the new run would skip step 3 ($step -le 3 is false for $step >= 4), initialize a fresh $Script:ImageInjectionComplete = $true, deploy the un-injected WIM, and commit state for it.

The placement matters: the guard runs after $needInject is decided, so it catches both the "no state file" case and the "valid-but-stale state file" case. An earlier placement (immediately after the state read) would only catch the former.

Checkpoint advance gating (v43 patch 4)
The three checkpoint writes at steps 3, 4, and 6 are now conditional on $Script:ImageInjectionComplete:

powershell
if ($Script:ImageInjectionComplete) {
    Set-Checkpoint -CheckpointFile $CheckpointFile -Step N -DesiredStateId $DesiredStateId
} else {
    Write-Log "Checkpoint NOT advanced to step N - image injection did not complete; next run will retry step 3" -Level WARN
}
On a healthy run the gate is a pass-through. When injection failed, the checkpoint stays at 2 and the next run re-enters step 3 and retries.

This closes an interaction that was invisible to either mechanism in isolation: the checkpoint's job is "resume an interrupted attempt at the same target"; the state file's job is "record whether that target was actually reached." An unconditional checkpoint advance let a run's checkpoint say "past step 3" while its state file correctly said "not done," with no code path checking both at once. The gate aligns the two.

Checkpoint cleanup
The checkpoint file is deleted:

After the fast path completes.

After the enable-only path completes (any outcome).

After the pending-reboot path completes.

After the full-update path reaches step 6.

If a run is interrupted between Set-Checkpoint -Step 6 and Remove-ItemIfExist $CheckpointFile, the checkpoint file persists. The migration guard handles this on the next run.

Crash consistency
The two files have independent lifecycles, and their interaction is what the guards above are protecting.

State file	Checkpoint file	Meaning	Next run behaviour
Absent	Absent	Fresh machine, never run.	Full update from step 1.
Absent	Present, step < 3	Interrupted run before injection.	Full update from step 1 or 2.
Absent	Present, step ≥ 4	Interrupted failed-injection run, or GeometryRestoreFailed deleted the state file.	Migration guard resets $step to 2. Full update from step 2.
Present, matching	Absent	Healthy, complete run.	Fast path.
Present, matching	Present, step < 3	Interrupted run that matched the state file. Unusual.	Full update from step 1 or 2.
Present, matching	Present, step ≥ 4	Interrupted failed-injection run with a stale-but-valid state file.	Migration guard resets $step to 2 (because $needInject will be true). Full update from step 2.
Present, stale	Any	The machine's DesiredStateId has changed.	Full update from step 1.
The two files are written atomically (Write-FileAtomically uses a temp file + Move-Item with retries), so neither can be partially written even on power loss.

Why not file locks or a database?
Two constraints made a simpler design the right one:

The script runs as SYSTEM from a scheduled task that uses IgnoreNew for overlapping instances. Two runs cannot overlap by construction; a file lock would be redundant.

The state file is small, JSON, and human-readable on purpose. When a field engineer opens C:\Recovery\OEM\winre_state.json, they should see something they understand. A SQLite database or a binary blob would not serve that requirement.

The trade-off is that the script does not defend against an operator manually editing the state file. That is not a scenario the design needs to support; if you edit the state file, you own the consequences.

Related documents
architecture.md — the pipeline and how the state fits into it.

recovery-partition.md — what the GeometryRestoreFailed flag protects against.

exit-codes.md — the exit code each state leads to.

text

---

## `docs/recovery-partition.md`

```markdown
# Recovery partition lifecycle

This document covers how WinRE Manager decides what size a recovery partition should be, what it does when the current one is inadequate, and how it recovers if the destructive operations fail.

## The invariant

**Exactly one recovery partition exists, on the OS disk, correctly type-coded.**

The script enforces this on:

- The idempotent fast path (read-only scan for strays).
- The enable-only path (before the success or reboot-required exit).
- The pending-reboot repair success exit.
- The pending-reboot reboot-required exit.
- Step 7 of the full-update path.

Any type-coded recovery partition (GPT GUID `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}` or MBR type `0x27`) on any non-OS disk is deleted. A partition on a non-OS disk that carries a `Recovery` or `WINRE` label but no type code is logged and skipped — a label-only match on a secondary disk is not sufficient authority to delete.

The invariant exists because Windows Setup and Startup Repair scan all attached volumes for WinRE-capable partitions. A stray recovery partition on a secondary or USB-attached disk can cause the BCD to be pointed at the wrong WinRE image during repair, which fails the repair.

## The sizing policy

### Two thresholds

The script uses two separate free-space thresholds, and it is important not to confuse them.

**Existing-partition acceptance.** An existing recovery partition is accepted only if:
(partition.SizeRemaining + existingWinreWimSize) >= (sourceWimSize + 250 MiB)

text

The 250 MiB is Microsoft's documented WinRE servicing margin (KB5028997). It is the same threshold the OS's own pre-update WinRE check uses. There is no tolerance: 195 MiB is not accepted, and neither is any lower value. The v36 change that introduced a 5 MiB tolerance was reverted in v37 as undocumented and inconsistent with servicing requirements.

**New-partition sizing.** When the script creates a new recovery partition, the size is:
bucketSizeMiB = ceil((wimSizeMiB + 250 + 30) / 100) * 100
bucketSizeMiB = max(bucketSizeMiB, 1000)

text

The 30 MiB is the project's own allowance for NTFS filesystem overhead on a freshly-formatted volume. It is a sizing prediction, not an acceptance tolerance — it is not added to the 250 MiB target, it is added on top of it so that after deployment the partition still has 250 MiB free.

The result is rounded **up** to the next 100 MiB boundary, then clamped to a 1000 MiB minimum. Rounding is always up — never to nearest — so the bucket can only be larger than required, never smaller.

### Worked examples

| WIM size | Needed (WIM + 280) | Rounded up | Final |
|---|---|---|---|
| 757 MiB | 1037 MiB | 1100 MiB | 1100 MiB |
| 500 MiB | 780 MiB | 800 MiB | 1000 MiB (min) |
| 950 MiB | 1230 MiB | 1300 MiB | 1300 MiB |

The 1000 MiB minimum exists because smaller partitions cause problems on OEM hardware that ships with larger WinRE images after an OEM servicing pass. The minimum was chosen to match the most common OEM default.

### Why the 250 MiB target matters

The ASUS 11th-gen case is the canonical example. That machine had a 757 MiB WIM and a 999 MiB recovery partition. After replacing the WIM, the partition had ~197 MiB free — below 250.

The previous script policy accepted that partition with a 195 MiB tolerance (200 minus 5). The current policy does not. On that machine, the script now deletes the 999 MiB partition and creates a properly sized replacement (a 1100 MiB partition, because WIM + 250 + 30 = 1037 rounds up to 1100). If the OS partition cannot be shrunk enough to make room, the script falls back to OS-fallback with exit code 2.

This is the honest outcome. A recovery partition that cannot meet the servicing margin is a recovery partition that will fail at the next Windows Update. Accepting it would be worse than reporting the degraded state.

## The OS partition resize sequence

When the script needs to create a new partition, it performs this sequence:

### 1. Pre-checks

Read the current OS partition size `S`, the required bucket size `B`, and the OS partition's `SizeMin` `M`. Compute the reclaimable recovery space `R`.

Two arithmetic checks are logged:

- **Safe path**: `S - B >= M`. The OS partition can shrink by the bucket size without reclaiming any recovery space.
- **Fatal-warning path**: `S + R - B < M`. Even after deleting all recovery partitions and reclaiming their space, the OS partition might not be able to shrink enough.

Since v38, the pre-check is **advisory**. The script proceeds with the destructive repartitioning attempt regardless of the arithmetic. Rationale: `SizeMin` is a conservative hint and can be wrong; `defrag /x` may free enough space. The trade is: try hard for the dedicated partition, fall back honestly if the attempt fails.

### 2. Disable WinRE

`reagentc /disable`. If it returns non-zero, abort the destructive attempt (return `$null` from `Ensure-AdequateRecoveryPartition`). The main flow then falls through to OS-fallback.

### 3. Suspend BitLocker

`Suspend-BitLockerForWinRE -MountPoint "C:"`. If suspension fails and BitLocker is not confirmed off, abort the destructive attempt.

### 4. Delete existing recovery partitions

For each recovery partition on the OS disk, `Remove-Partition`. If that fails, retry with `diskpart delete partition override`. If the partition survives both attempts, abort with `FATAL`.

**Note: this is a point of no return.** The script logs this explicitly before the first delete. If a subsequent step fails and the script falls back to OS-fallback, the deleted partitions are gone. The script does not attempt to restore them; the OS-fallback path deploys the WIM to `C:\Recovery\WindowsRE` instead.

### 5. Extend the OS partition

Read `SizeMax` for the OS partition. If it is larger than the current size, resize to `SizeMax`. This absorbs any unallocated space that was between the OS partition and the last recovery partition.

### 6. Shrink the OS partition

This is the critical step. The script attempts the shrink in three stages:

**Attempt 1 — immediate.** `Resize-Partition -Size $expectedAfterShrink` where `$expectedAfterShrink = $initialOSSize - (($bucketSizeMiB + 1) * 1MB)`.

The `+ 1 MiB` is alignment slack. The new partition's offset is rounded UP to the next 1 MiB boundary; without the slack the rounding could consume part of the bucket and leave the tail too short. This was the HP ProBook 445 G10 failure (1499.34 MiB available for a 1500 MiB bucket).

**Attempt 2 — after 10-second sleep.** If attempt 1 failed, sleep 10 seconds, re-query `SizeMin`, log the delta, and retry.

**Attempt 3 — after `defrag C: /x`.** If attempt 2 failed, run `defrag C: /x` with no timeout, sleep 5 seconds, re-query `SizeMin`, log the delta, and retry.

The SizeMin is logged before attempt 1, after the sleep, and after the defrag, so that field data can establish empirically which step (if either) is what makes the shrink succeed. See the v39 changelog entry for the measurement rationale.

### 7. Handle shrink failure

If all three attempts fail, the script:

1. Logs `OS partition shrink failed after all three attempts. Recovery partitions have already been deleted.`
2. Calls `Restore-OSPartitionSize` to re-extend C: to `SizeMax`.
3. Logs `Returning null - main flow will attempt OS-partition fallback`.
4. Returns `$null` from `Ensure-AdequateRecoveryPartition`.

The main flow then sets `$Script:UsedOSFallback = $true` and `$Script:nonFatalWarning = $true`, and proceeds with the OS-fallback deployment. The run exits with code 2.

If `Restore-OSPartitionSize` itself fails (either the resize or the post-resize verification), `$Script:GeometryRestoreFailed = $true` is set. That has two effects:

- `Write-WinREState` will **delete** the state file rather than write it, forcing the next run to treat the state as absent.
- The next run's `$needInject` computation will be `$true` because there is no valid state, which forces a full rebuild. The rebuild re-attempts the destructive repartitioning.

### 8. Create the new partition

The new partition is created at an offset rounded up from the (new) OS partition end to the next 1 MiB boundary. Size is `bucketSizeMiB * 1MB`. If there is not enough space at that offset, restore the OS partition and abort.

The partition is created with `New-Partition`, retried up to 3 times with offset recalculation between attempts.

### 9. Format and attribute

`Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Recovery'`.

Immediately after format, `Set-RecoveryPartitionAttributes` applies:

- **GPT**: `set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac` and `gpt attributes=0x8000000000000001`.
- **MBR**: `set id=27`.

**Attributes are set before drive-letter assignment.** This is critical. A freshly-formatted NTFS partition with a normal data type GUID and a drive letter is a candidate for BitLocker Device Encryption auto-encryption on Windows 11 24H2+. Setting the recovery type GUID and the PLATFORM_REQUIRED + NO_DRIVE_LETTER attribute first tells BitLocker the partition is not a data volume. Confirmed by diagnostic: a recovery-typed partition with these attributes reports "The volume could not be opened by BitLocker" and has no `Win32_EncryptableVolume` entry, while still accepting a temporary drive letter for deployment.

### 10. Drive letter and encryption verification

A drive letter is assigned via `Invoke-DriveLetterAssignment`, which tries the preferred letter, then every other candidate, using three methods per letter (`Set-Partition`, `Add-PartitionAccessPath`, `diskpart assign`).

After assignment, `Test-VolumeEncrypted` verifies the new partition is not encrypted.

If it **is** encrypted (state `$true`), the script:

1. Calls `Suspend-BitLockerForWinRE -MountPoint "C:"` again.
2. Deletes the encrypted partition.
3. Recreates it with a fresh offset (geometry may have changed).
4. Re-formats and re-applies attributes.
5. Re-verifies.

If it is **still** encrypted after the retry, `Remove-OrphanPartition` deletes it and the function returns `$null`. The main flow falls through to OS-fallback.

If the state is **unknown** (`$null`), the script proceeds with a warning and lets `reagentc /enable` surface any issue.

### 11. Success

`New-DirectoryIfNotExists "${assignedLetter}:\Recovery\WindowsRE"`.

Return `@{ DriveLetter = $assignedLetter; DiskNumber = $osDisk.Number; PartitionNumber = $newPart.PartitionNumber }`.

The main flow adds the assigned drive letter to `$Script:tempDriveLetters` so it can be removed at exit.

## `Restore-OSPartitionSize`

The helper that re-extends C: when a post-shrink step fails.
Restore-OSPartitionSize -Reason "<description>"

text

Re-queries `SizeMax` for the OS partition. If the current size is already at or above `SizeMax`, returns `$true` without resizing. Otherwise resizes to `SizeMax`, sleeps 3 seconds, and verifies via `Assert-PartitionSizeAfterResize`.

Every failure path sets:

- `$Script:nonFatalWarning = $true` (so the exit code becomes 2).
- `$Script:GeometryRestoreFailed = $true` (so the state file is deleted).

The three failure paths are: OS partition not found, post-resize verification failed, resize threw an exception.

## `Remove-OrphanPartition`

A helper that deletes a partition the script created but could not complete. Used when `Format-Volume` fails, when drive-letter assignment fails after creating a partition, and when a partition survives a delete-and-recreate.
Remove-OrphanPartition -DiskNumber <n> -PartitionNumber <m> -Reason "<description>"

text

Attempts `Remove-Partition`, then falls back to `diskpart delete partition override`. Waits 2 seconds, then verifies the partition is gone.

If the partition survives, the function:

- Logs a warning naming the partition and the reason.
- Sets `$Script:nonFatalWarning = $true`.
- Sets `$Script:GeometryRestoreFailed = $true`.

The `GeometryRestoreFailed` flag is important: an orphan partition between the OS partition and the disk end prevents the freed space from being reabsorbed, and without the flag the state file would record the resulting layout as valid. With the flag, the state file is deleted and the next run retries.

If the partition is removed successfully, the function calls `Restore-OSPartitionSize -Reason "after orphan removal"` to re-extend C: into the freed space.

## Step 7 — stray recovery partition cleanup

After deployment, Step 7 removes every type-coded recovery partition on non-OS disks.
Remove-StrayRecoveryPartitions -OSDiskNumber <n>

text

For each disk whose number is not the OS disk, query `Get-RecoveryPartitions`. For each partition found:

- If it is type-coded (GPT `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}` or MBR `0x27`), delete it.
- If it is not type-coded (label-only match), log and skip.

A deletion failure sets `$Script:nonFatalWarning = $true` and returns `$false`.

The function is called from the fast path, the enable-only path, both pending-reboot exits, and Step 7 of the full-update path. In every case the call is the same; the read-only scan cost when there are no strays is a single `Get-Disk` and a few `Get-Partition` calls per non-OS disk.

## GPT vs MBR

The script handles both partition styles.

**GPT:**
- Recovery type: `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}`.
- Attributes: `0x8000000000000001` (`GPT_ATTRIBUTE_PLATFORM_REQUIRED` + `GPT_ATTRIBUTE_NO_DRIVE_LETTER`).
- Detection during `Get-RecoveryPartitions`: match on `GptType`.

**MBR:**
- Recovery type: `0x27` (`PARTITION_IFS` with the recovery flag).
- Detection during `Get-RecoveryPartitions`: match on `MbrType`.

The script determines the style from `Get-OSDisk`'s `PartitionStyle` property and passes the appropriate value to `Set-RecoveryPartitionAttributes`.

## Related documents

- [architecture.md](architecture.md) — where the partition lifecycle fits in the pipeline.
- [state-and-idempotency.md](state-and-idempotency.md) — how `GeometryRestoreFailed` interacts with the state file.
- [driver-injection.md](driver-injection.md) — what happens before the partition work.
