# Recovery partition lifecycle

This document covers how WinRE Manager decides what size a recovery partition should be, what it does when the current one is inadequate, and how it recovers if the destructive operations fail.

## The invariant

**Exactly one type-coded recovery partition exists, on the OS disk.**

The type code is the partition's identity: GPT GUID `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}` or MBR type code `0x27`. A partition detected only by its `Recovery` or `WINRE` volume label is not a recovery partition for any decision the script makes — the label is a hint, not an identity.

The script enforces this on:

- The idempotent fast path (read-only scan for strays, and type-coded count for the "exactly one" condition).
- The enable-only path (before the success or reboot-required exit).
- The pending-reboot repair success exit.
- The pending-reboot reboot-required exit.
- Step 7 of the full-update path.

Any type-coded recovery partition (GPT GUID `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}` or MBR type `0x27`) on any non-OS disk is deleted. A partition on a non-OS disk that carries a `Recovery` or `WINRE` label but no type code is logged and skipped — a label-only match on a secondary disk is not sufficient authority to delete.

The same rule applies symmetrically on the OS disk, and the OS-disk side is the one that matters for convergence. A partition on the OS disk that carries a `Recovery` or `WINRE` label but no type code is:

- **Not counted** by the fast path's "exactly one recovery partition on the OS disk" condition.
- **Not reused** by `Find-SuitableRecoveryPartition`.
- **Not deleted** by the destructive path in `Ensure-AdequateRecoveryPartition` — a label alone never authorizes deletion.
- **Not classified as DEDICATED** by the active-location classifier or the final-verification classifier.

The last two were always true; the first two were made true in v44 patch 7. Before patch 7, the fast-path count and the active-location classifier accepted a label-only match as evidence of a recovery partition, while the destructive path correctly refused to delete one. The asymmetry meant a Basic Data partition labelled "Recovery" on the OS disk would be counted by the fast path (so the "exactly one recovery partition" condition could never be satisfied) while being preserved by the destructive path (so it was never removed). The machine cycled through rebuilds indefinitely without converging. Patch 7 unified the authority rule: type code everywhere, label nowhere.

The invariant exists because Windows Setup and Startup Repair scan all attached volumes for WinRE-capable partitions. A stray recovery partition on a secondary or USB-attached disk can cause the BCD to be pointed at the wrong WinRE image during repair, which fails the repair. A label-only partition on the OS disk is not a stray in that sense — it never becomes a WinRE target — but it does break the fast path's convergence check, and that is what patch 7 fixes.

## The sizing policy

### Where the source WIM size comes from

The `wimSizeMiB` used in both thresholds below is the size of the WIM the script intends to deploy. On the full-update path this is `winre_optimized.wim`, produced by `dism /Export-Image /Compress:max` in Step 4. The input to that export is `base.wim`, which the pipeline has mounted, injected with OEM and VMD drivers, and — as of v44 patch 2 — reset with `dism /cleanup-image /StartComponentCleanup /ResetBase`. ResetBase removes superseded components from the image's WinSxS store; the export is what materialises the size reduction on disk as a smaller WIM. The sizing decision therefore uses the post-ResetBase size.

On the enable-only path no WIM is rebuilt — the existing deployed WIM's size is used directly.

### Two thresholds

The script uses two separate free-space thresholds, and it is important not to confuse them.

**Existing-partition acceptance.** An existing recovery partition is accepted only if **both** of the following hold:

- **It is type-coded** — GPT recovery GUID `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}` or MBR type `0x27`. A partition detected only by a `Recovery`/`WINRE` volume label is not a candidate for reuse. See "The invariant" above for the reasoning and the v44 patch 7 non-convergence loop this closes.
- Its effective free space is sufficient:

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

### The planned 2 GiB sanity ceiling (not yet implemented)

Both thresholds above are **lower bounds**. Neither places an upper bound on the size of a partition the script will accept or delete. This is a documented gap, not an oversight, and the plan to close it — a 2 GiB sanity ceiling that would WARN and skip oversized candidates — is tracked here so that whoever implements it knows which code paths it must cover.

Three functions are exposed, and the ceiling must gate **all three**:

- **The destructive path — `Ensure-AdequateRecoveryPartition`.** This function deletes every partition on the OS disk that carries the standard recovery GPT type GUID (`{de94bba4-06d1-4d40-a16a-bfd50179d6ac}`) or MBR type code (`0x27`), without checking its size or contents. Windows Setup and Windows in-place upgrade create recovery partitions under 1.5 GiB. **OEM factory recovery volumes** — the Dell / HP / Lenovo image-restore volumes that hold the OEM's factory Windows image and utilities — can be 7–20 GiB and may carry the same recovery type code. On a machine where an OEM factory recovery volume carries the recovery type code, this function will delete it.
- **The reuse path — `Find-SuitableRecoveryPartition`.** This function accepts an existing recovery-typed partition on the OS disk that meets the free-space policy, without checking its size against an upper bound. On the same kind of machine, the reuse path would accept an oversized OEM recovery volume, re-register WinRE against it, and (through the normal flow) leave the partition in a state where the OEM's restore utilities no longer function. The failure shape is different from deletion, but the missing size check is the same.
- **The stray-cleanup path — `Remove-StrayRecoveryPartitions`.** This function deletes any type-coded recovery partition on a non-OS disk, without checking size. A type-coded 7–20 GiB OEM factory recovery volume on a secondary disk would be deleted by this function on the same type-code-equals-deletable logic that the other two use. Reached by a different code path than the destructive or reuse paths.

When the ceiling ships it must apply to **all three** functions. A check in only one or two of them would leave the remaining path(s) exposed, and each is reached by a different code path — a machine can take the reuse path without ever entering `Ensure-AdequateRecoveryPartition`, and a machine with a secondary-disk recovery volume can enter `Remove-StrayRecoveryPartitions` without entering either of the others.

Until the ceiling ships:

- The README carries a "Before you run this" warning at the top of the page. The warning names all three functions and states that the planned ceiling must gate all three.
- The `.NOTES` block in `scripts/WinRE.ps1` carries a "Known gaps" section describing the limitation, again naming all three functions.
- Operators deploying to machines they did not image themselves should run the harness Option 1 diagnostic and inspect the "Recovery partitions" section before proceeding. A recovery-typed partition larger than 2 GiB is a red flag.

The ceiling is planned as its own version boundary and will ship with a fresh CHANGELOG entry and a `ScriptVersion` decision. It is not a v44 patch 7 change; v44 patch 3 extended this section to name the reuse path, and v44 patch 6 extended it again to name the stray-cleanup path. Patch 7 did not change the ceiling's scope — it changed the classifier that decides which partitions are recovery partitions in the first place.

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

When the script needs to create a new partition, it performs this sequence.

### 0. Audit Mode startup guard

One read-only startup check runs before any of the steps below: the Audit Mode guard. It reads `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` → `ImageState` and defers with `EXIT_WARNING` when the value is present and is not `IMAGE_STATE_COMPLETE`. During Audit Mode, OOBE, sysprep generalize, and sysprep specialize, `reagentc /enable` is blocked by the OS with `ERROR_CANCELLED` (`0x4c7`, 1223) regardless of the correctness of the deployed WIM. The script defers before touching any partition. This guard runs before the hardware check, the manifest fetch, the OEM pack resolution, the `DesiredStateId` computation, and any other gate or operation. Under `-DryRun` the guard logs `Would defer …` and continues.

Under the v43 patch 5 (further revision 5) policy there is **no startup BitLocker gate**. The BitLocker decision is made where the action is taken, not at startup: the target volume is not known until the classifier has resolved the reagentc-registered location, and the OS volume's BitLocker state is irrelevant to the enable-only and dedicated-partition paths.

The consequence for this document is that the resize sequence below is only entered on machines whose `ImageState` is `IMAGE_STATE_COMPLETE` (or absent). No other startup check gates the destructive partition path.

**As of v44 patch 6, the destructive partition path does not consult C:'s BitLocker state.** The resize sequence is entered on machines that have passed the Audit Mode guard, and no additional C: check runs before the destructive sequence begins. If the destructive sequence fails at the shrink step and the run falls through to OS-fallback, the OS-fallback gate checks C: at that point and defers as designed. The safety property — never leave a machine with no working recovery route — is preserved by the OS-fallback gate alone in the two ordinary cases (the destructive attempt succeeds, or it fails before deletion). The narrow corner where it is not preserved — a destructive attempt that fails after deletion on an encrypted-C: machine — is documented in [architecture.md](architecture.md) under Step 5 and in the `[v44 patch 7]` CHANGELOG entry.

### 1. Pre-checks

Read the current OS partition size `S`, the required bucket size `B`, and the OS partition's `SizeMin` `M`. Compute the reclaimable recovery space `R` — the sum of the sizes of every **type-coded** recovery partition on the OS disk that the destructive path is authorized to delete. A label-only partition is not counted toward `R` and is not deleted, exactly as in the invariant above.

Two arithmetic checks are logged:

- **Safe path**: `S - B >= M`. The OS partition can shrink by the bucket size without reclaiming any recovery space.
- **Fatal-warning path**: `S + R - B < M`. Even after deleting all type-coded recovery partitions and reclaiming their space, the OS partition might not be able to shrink enough.

Since v38, the pre-check is **advisory**. The script proceeds with the destructive repartitioning attempt regardless of the arithmetic. Rationale: `SizeMin` is a conservative hint and can be wrong; `defrag /x` may free enough space. The trade is: try hard for the dedicated partition, fall back honestly if the attempt fails.

### 2. Disable WinRE

`reagentc /disable` if WinRE is currently enabled. If it returns non-zero, abort the destructive attempt (return `$null` from `Ensure-AdequateRecoveryPartition`) and the main flow falls through to OS-fallback.

This step runs **before** any partition is deleted. If it fails, no partition work is attempted.

### 3. Delete existing recovery partitions

For each **type-coded** recovery partition on the OS disk — GPT GUID `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}` or MBR type `0x27` — `Remove-Partition`. If that fails, retry with `diskpart delete partition override`. If the partition survives both attempts, abort with `FATAL`.

A partition on the OS disk that carries a `Recovery` or `WINRE` label but no type code is **not** in this loop. The type-code gate is applied before the loop and again inside it, as a redundant check. A label-only match is logged with the message "Skipping label-only recovery match on disk N partition M: recovery label alone does not authorize deletion." and the loop continues. A label is never sufficient authority for deletion, on any disk. This is the same rule that governs Step 7's stray cleanup on non-OS disks.

**Note: this is a point of no return.** The script logs this explicitly before the first delete. If a subsequent step fails and the script falls back to OS-fallback, the deleted partitions are gone. The script does not attempt to restore them; the OS-fallback path deploys the WIM to `C:\Recovery\WindowsRE` instead.

### 4. Extend the OS partition

Read `SizeMax` for the OS partition. If it is larger than the current size, resize to `SizeMax`. This absorbs any unallocated space that was between the OS partition and the last recovery partition.

### 5. Shrink the OS partition

This is the critical step. The script attempts the shrink in three stages:

**Attempt 1 — immediate.** `Resize-Partition -Size $expectedAfterShrink` where `$expectedAfterShrink = $initialOSSize - (($bucketSizeMiB + 1) * 1MB)`.

The `+ 1 MiB` is alignment slack. The new partition's offset is rounded UP to the next 1 MiB boundary; without the slack the rounding could consume part of the bucket and leave the tail too short. This was the HP ProBook 445 G10 failure (1499.34 MiB available for a 1500 MiB bucket).

**Attempt 2 — after 10-second sleep.** If attempt 1 failed, sleep 10 seconds, re-query `SizeMin`, log the delta, and retry.

**Attempt 3 — after `defrag C: /x`.** If attempt 2 failed, run `defrag C: /x` with no timeout, sleep 5 seconds, re-query `SizeMin`, log the delta, and retry.

The SizeMin is logged before attempt 1, after the sleep, and after the defrag, so that field data can establish empirically which step (if either) is what makes the shrink succeed. See the v39 changelog entry for the measurement rationale.

### 6. Handle shrink failure

If all three attempts fail, the script:

1. Logs `OS partition shrink failed after all three attempts. Recovery partitions have already been deleted.`
2. Calls `Restore-OSPartitionSize` to re-extend C: to `SizeMax`.
3. Logs `Returning null - main flow will attempt OS-partition fallback`.
4. Returns `$null` from `Ensure-AdequateRecoveryPartition`.

The main flow then sets `$Script:UsedOSFallback = $true` and `$Script:nonFatalWarning = $true`, and proceeds with the OS-fallback deployment. The run exits with code 2.

**This is the point where the safety-property corner is entered on an encrypted-C: machine.** The OS-fallback gate checks C: and defers unless C: is `FullyDecrypted`. If C: is encrypted, the run exits `EXIT_WARNING` with neither a dedicated recovery partition nor OS-fallback, because the type-coded partition was already deleted in step 3 above. See [architecture.md](architecture.md) Step 5 for the full statement and the residual discussion.

If `Restore-OSPartitionSize` itself fails (either the resize or the post-resize verification), `$Script:GeometryRestoreFailed = $true` is set. That has two effects:

- `Write-WinREState` will **delete** the state file rather than write it, forcing the next run to treat the state as absent.
- The next run's `$needInject` computation will be `$true` because there is no valid state, which forces a full rebuild. The rebuild re-attempts the destructive repartitioning.

### 7. Create the new partition

The new partition is created at an offset rounded up from the (new) OS partition end to the next 1 MiB boundary. Size is `bucketSizeMiB * 1MB`. If there is not enough space at that offset, restore the OS partition and abort.

**The recovery type code is applied at creation time.** `New-Partition` is called with `-GptType {de94bba4-06d1-4d40-a16a-bfd50179d6ac}` (GPT) or `-MbrType 0x27` (MBR). Before v43 patch 5, the partition was created as a Basic Data partition and its type was changed minutes later by `Set-RecoveryPartitionAttributes`. On a machine with Device Encryption actively encrypting, the encryption service could claim that Basic Data partition during the window and start encrypting it. Applying the recovery type at creation makes that window zero-width: there is no moment when the partition is a plain data partition.

The `New-Partition` call is retried up to 3 times with offset recalculation between attempts, matching the pre-patch-5 behaviour.

### 8. Format and attribute

`Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Recovery'`.

Immediately after format, `Set-RecoveryPartitionAttributes` runs. It applies:

- **GPT**: `set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac` (idempotent with the type GUID already set at creation) and `gpt attributes=0x8000000000000001`.
- **MBR**: `set id=27` (idempotent with the type code already set at creation).

The type code is idempotent on this call; the attribute step is what actually adds new state here. **Attributes are set before drive-letter assignment.** This is critical. A freshly-formatted NTFS partition with a drive letter is a candidate for BitLocker Device Encryption auto-encryption on Windows 11 24H2+. Setting the recovery type GUID and the PLATFORM_REQUIRED + NO_DRIVE_LETTER attribute first tells BitLocker the partition is not a data volume. Confirmed by diagnostic: a recovery-typed partition with these attributes reports "The volume could not be opened by BitLocker" and has no `Win32_EncryptableVolume` entry, while still accepting a temporary drive letter for deployment.

The v35 change introduced the attribute-before-letter ordering. The v43 patch 5 change introduced type-GUID-at-creation. Together they close the auto-encryption window from both sides: the type GUID is present from the moment the partition exists, and the attributes are present before any drive letter is assigned.

### 9. Drive letter assignment

A drive letter is assigned via `Invoke-DriveLetterAssignment`, which tries the preferred letter, then every other candidate, using three methods per letter (`Set-Partition`, `Add-PartitionAccessPath`, `diskpart assign`).

**Preferred letter reuse.** If the current run has already held a drive letter on a recovery partition earlier in this run (tracked in `$Script:tempDriveLetters`), the helper prefers that letter over a fresh one from `Get-AvailableDriveLetter`. Windows caches letter-to-volume mappings in `MountedDevices`; reusing a letter the script held earlier is more likely to succeed cleanly than picking a fresh one, and it avoids the assign-remove-reassign churn that can leave stale entries. The fallback chain is unchanged: if the preferred letter fails, the helper moves on.

### 10. Verify encryption state (early check)

After assignment, `Test-VolumeEncrypted` verifies the new partition is not encrypted.

- If it **is** encrypted (`$true`), the script calls `Set-RecoveryPartitionReadyForWinRE` on the partition, which decrypts it in place with `manage-bde -off` and polls for completion, up to a 300-second timeout. If the helper succeeds, the partition is now unencrypted and usable; the run continues. If the helper fails (timeout or unrecoverable error), `Remove-OrphanPartition` deletes the partition and the function returns `$null`; the main flow falls through to OS-fallback.
- If the state is **unknown** (`$null`), the script proceeds with a warning and lets the deploy step's `Set-RecoveryPartitionReadyForWinRE` call surface any issue.
- If it is **confirmed unencrypted** (`$false`), nothing further is needed.

This early check is defensive: the deploy step (Step 5 in the main flow) calls `Set-RecoveryPartitionReadyForWinRE` on the recovery partition again regardless, so this is not the last opportunity to prepare the partition. It exists so that a newly created partition claimed by the Device Encryption service is cleaned up before the function returns, rather than leaving the caller with a partition that will fail later.

**The delete-and-recreate retry is gone.** Under the pre-v43-patch-5-further-revision-5 policy, if the new partition was encrypted the script suspended BitLocker, deleted the partition, and recreated it. That approach was correct in isolation but was based on the wrong premise — suspension does not prevent the encryption service from claiming the new partition, and deletion is unnecessary when the partition can be decrypted in place. The 2026-09-29 field test confirmed that a partition claimed by Device Encryption does not re-encrypt after `manage-bde -off` completes, which makes decrypt-in-place safe and simpler.

### 11. Success

`New-DirectoryIfNotExists "${assignedLetter}:\Recovery\WindowsRE"`.

Return `@{ DriveLetter = $assignedLetter; DiskNumber = $osDisk.Number; PartitionNumber = $newPart.PartitionNumber }`.

The main flow adds the assigned drive letter to `$Script:tempDriveLetters` so it can be removed at exit.

## Where the target partition is prepared for reagentc

The destructive sequence above is only one of the paths that reaches `reagentc /enable`. The full-update path with an existing recovery partition, the enable-only path, and the pending-reboot repair path also call reagentc. Under the v43 patch 5 (further revision 5) policy, all of them prepare the target partition through the same helper: `Set-RecoveryPartitionReadyForWinRE`.

The helper is called at these sites:

- The enable-only path, on the target recovery partition resolved from the reagentc location.
- The full-update path, on the recovery partition returned by `Find-SuitableRecoveryPartition` or `Ensure-AdequateRecoveryPartition`.
- The pending-reboot repair path, on the partition recorded in the state file's `DeployedDiskNumber` / `DeployedPartitionNumber`.
- Inside `Ensure-AdequateRecoveryPartition`, as a defensive early check described in section 10 above.

Each call is the same: if the target is unencrypted, return immediately; otherwise run `manage-bde -off` against the target and poll for completion, up to 300 seconds.

**The helper targets the recovery partition, not C:.** This is the v43 patch 5 (further revision 5) change. reagentc's BitLocker check is on the volume it is being asked to enable WinRE on, and that volume is the recovery partition on the dedicated-partition path and on the enable-only path. The script therefore prepares the recovery partition.

**The OS-fallback route is different.** On the OS-fallback route, the target volume *is* C:, and the script does not prepare C: — it never runs `manage-bde -off` against the OS volume. Instead, the OS-fallback gate checks C:'s `VolumeStatus` and defers unless it is `FullyDecrypted`. C:'s BitLocker state is the operator's responsibility: complete decryption of C: (`manage-bde -off C:`) or wait for an in-progress decryption to finish.

See [architecture.md](architecture.md) for the full policy and [deployment.md](deployment.md) for the operator-facing preconditions.

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

A helper that deletes a partition the script created but could not complete. Used when `Format-Volume` fails, when drive-letter assignment fails after creating a partition, when the helper could not make a newly created partition unencrypted, and when a partition survives a delete-and-recreate (no longer occurs on the recovery path but still possible in edge cases).

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
- Type code applied at creation via `New-Partition -GptType` (v43 patch 5).
- Attributes applied after format via `Set-RecoveryPartitionAttributes`.
- Detection during `Get-RecoveryPartitions`: match on `GptType`.

**MBR:**

- Recovery type: `0x27` (`PARTITION_IFS` with the recovery flag).
- Type code applied at creation via `New-Partition -MbrType 0x27` (v43 patch 5).
- Detection during `Get-RecoveryPartitions`: match on `MbrType`.

The script determines the style from `Get-OSDisk`'s `PartitionStyle` property and passes the appropriate value to both `New-Partition` and `Set-RecoveryPartitionAttributes`.

## Related documents

- [architecture.md](architecture.md) — where the partition lifecycle fits in the pipeline.
- [state-and-idempotency.md](state-and-idempotency.md) — how `GeometryRestoreFailed` interacts with the state file.
- [troubleshooting.md](troubleshooting.md) — the recovery procedure if the partition is lost.
- [driver-injection.md](driver-injection.md) — what happens before the partition work.
