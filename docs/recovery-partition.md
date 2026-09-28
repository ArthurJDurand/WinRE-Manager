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

```
(partition.SizeRemaining + existingWinreWimSize) >= (sourceWimSize + 250 MiB)
```

The 250 MiB is Microsoft's documented WinRE servicing margin (KB5028997). It is the same threshold the OS's own pre-update WinRE check uses. There is no tolerance: 195 MiB is not accepted, and neither is any lower value. The v36 change that introduced a 5 MiB tolerance was reverted in v37 as undocumented and inconsistent with servicing requirements.

**New-partition sizing.** When the script creates a new recovery partition, the size is:

```
bucketSizeMiB = ceil((wimSizeMiB + 250 + 30) / 100) * 100
bucketSizeMiB = max(bucketSizeMiB, 1000)
```

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

```
Restore-OSPartitionSize -Reason "<description>"
```

Re-queries `SizeMax` for the OS partition. If the current size is already at or above `SizeMax`, returns `$true` without resizing. Otherwise resizes to `SizeMax`, sleeps 3 seconds, and verifies via `Assert-PartitionSizeAfterResize`.

Every failure path sets:

- `$Script:nonFatalWarning = $true` (so the exit code becomes 2).
- `$Script:GeometryRestoreFailed = $true` (so the state file is deleted).

The three failure paths are: OS partition not found, post-resize verification failed, resize threw an exception.

## `Remove-OrphanPartition`

A helper that deletes a partition the script created but could not complete. Used when `Format-Volume` fails, when drive-letter assignment fails after creating a partition, and when a partition survives a delete-and-recreate.

```
Remove-OrphanPartition -DiskNumber <n> -PartitionNumber <m> -Reason "<description>"
```

Attempts `Remove-Partition`, then falls back to `diskpart delete partition override`. Waits 2 seconds, then verifies the partition is gone.

If the partition survives, the function:

- Logs a warning naming the partition and the reason.
- Sets `$Script:nonFatalWarning = $true`.
- Sets `$Script:GeometryRestoreFailed = $true`.

The `GeometryRestoreFailed` flag is important: an orphan partition between the OS partition and the disk end prevents the freed space from being reabsorbed, and without the flag the state file would record the resulting layout as valid. With the flag, the state file is deleted and the next run retries.

If the partition is removed successfully, the function calls `Restore-OSPartitionSize -Reason "after orphan removal"` to re-extend C: into the freed space.

## Step 7 — stray recovery partition cleanup

After deployment, Step 7 removes every type-coded recovery partition on non-OS disks.

```
Remove-StrayRecoveryPartitions -OSDiskNumber <n>
```

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
