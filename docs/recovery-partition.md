# Recovery partition lifecycle

This document covers how WinRE Manager decides what size a recovery partition should be, how it replaces one that is inadequate, and how it recovers if the destructive operations fail. The current design is the v45 patch 1 shrink-first pipeline, with the v46 patch 1 disk-end clamp applied to the geometry plan and the v46 patch 2 pre-deletion resolver guard and extension-fallback bucket cap applied to the destructive sequence.

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

### The 2 GiB sanity ceiling (implemented in v45 patch 1)

The bucket size has an upper bound, `$MaxManagedRecoveryPartitionMiB = 2048`. The ceiling is enforced in three places, and all three are needed because they are reached by different code paths:

- **The destructive path — `Get-PartitionPlan`.** The plan rejects a layout where any type-coded recovery partition on the OS disk is larger than 2 GiB, or where the bucket size itself exceeds 2 GiB. Rejection produces `Deferred` with no partition or WinRE change.
- **The reuse path — `Find-SuitableRecoveryPartition`.** A candidate whose total size exceeds 2 GiB is preserved for operator review. The function logs a WARN naming the partition and the ceiling, and continues to the next candidate. The candidate is not reused.
- **The stray-cleanup path — `Remove-StrayRecoveryPartitions`.** A type-coded recovery partition on a non-OS disk that exceeds 2 GiB is preserved for operator review. The function logs a WARN, sets `$Script:nonFatalWarning = $true`, and continues. The partition is not deleted.

The ceiling exists because Windows Setup and Windows in-place upgrade create recovery partitions under 1.5 GiB, while OEM factory recovery volumes — the Dell / HP / Lenovo image-restore volumes that hold the OEM's factory Windows image and utilities — can be 7–20 GiB and may carry the same recovery type code. Without the ceiling, the destructive path would delete an OEM volume, the reuse path would re-register WinRE against one, and the stray-cleanup path would delete one on a secondary disk.

Until v45 patch 1, none of the three functions checked size. The `.NOTES` block in `scripts/WinRE.ps1` named all three in its "Known gaps" section. The v45 patch 1 implementation closes that gap.

**The ceiling is also preserved by the extension-failure fallback (v46 patch 2).** When the post-delete C: extension fails, the fallback path sizes the replacement partition to the plan's bucket rather than to the full remaining extent — see step 5 below. Before v46 patch 2, the fallback assigned the entire remaining extent to the replacement partition, which on a layout that reclaimed multiple recovery partitions whose combined size exceeded the bucket could produce a partition larger than 2 GiB. The cap enforces the same ceiling on the fallback path that the plan already enforces everywhere else.

Operators deploying to machines they did not image themselves should still run the harness Option 1 diagnostic and inspect the "Recovery partitions" section before proceeding. A recovery-typed partition larger than 2 GiB will now be preserved rather than acted on, but it is still worth knowing it is there — it may indicate an OEM factory recovery volume the operator wants to keep, or a layout that warrants manual review.

### Worked examples

| WIM size | Needed (WIM + 280) | Rounded up | Final |
|---|---|---|---|
| 757 MiB | 1037 MiB | 1100 MiB | 1100 MiB |
| 500 MiB | 780 MiB | 800 MiB | 1000 MiB (min) |
| 950 MiB | 1230 MiB | 1300 MiB | 1300 MiB |

The 1000 MiB minimum exists because smaller partitions cause problems on OEM hardware that ships with larger WinRE images after an OEM servicing pass. The minimum was chosen to match the most common OEM default.

### Why the 250 MiB target matters

The ASUS 11th-gen case is the canonical example. That machine had a 757 MiB WIM and a 999 MiB recovery partition. After replacing the WIM, the partition had ~197 MiB free — below 250.

The previous script policy accepted that partition with a 195 MiB tolerance (200 minus 5). The current policy does not. On that machine, the script now replaces the 999 MiB partition with a properly sized one (a 1100 MiB partition, because WIM + 250 + 30 = 1037 rounds up to 1100). If the OS partition cannot be shrunk enough to make room, the script defers with the old route preserved (v45 patch 1) or falls back to OS-fallback with exit code 2 (in the limited cases where the plan called for it).

A recovery partition that cannot meet the servicing margin is a recovery partition that will fail at the next Windows Update. Accepting it would be worse than reporting the degraded state.

## The single-boundary geometry model (v45 patch 1)

Before v45 patch 1, the script computed a **shrink amount** and left the recovery partition's placement to `New-Partition`'s rounding. That left a trailing gap between the end of the recovery partition and the end of the disk, because the OS shrink used a "deficit plus alignment slack" formula and the new partition was created at whatever offset the shrink happened to leave free. The gap was sometimes several MiB and was not accounted for anywhere.

The v45 patch 1 model computes a **target boundary** instead. The plan derives:

```
AlignedManagedExtentEnd = floor(tailEnd / 1 MiB) × 1 MiB
TargetRecoveryStart     = AlignedManagedExtentEnd - BucketSizeBytes
```

where `tailEnd` is `min(blockingPartition.Offset, diskSize − 1 MiB)` when a blocking non-recovery partition exists after C:, or `diskSize − 1 MiB` when none does. The `diskSize − 1 MiB` clamp is a v46 patch 1 addition: the disk-end reserve is a fixed Windows convention, and the v45 planner could exceed it on a factory layout whose last partition ended at `diskSize` (equivalently, 1 MiB past the usable end). Without the clamp, `AlignedManagedExtentEnd` landed 1 MiB past the reserve and the post-delete geometry check rejected the plan. See "The v46 patch 1 plan clamp" below. C: is resized so it ends exactly at `TargetRecoveryStart`; the recovery partition of size exactly `BucketSizeBytes` fills the space up to `AlignedManagedExtentEnd`.

Bytes between the raw extent end and the aligned end are the **alignment reserve**. They are logged, not treated as a defect. In the common case the reserve is zero and the recovery partition ends exactly at `diskSize − 1 MiB`.

The plan produces two resizing outputs and exactly one of them is non-zero:

- `ShrinkBytes` — the amount C: must shrink to land at `TargetRecoveryStart`. Non-zero when C: currently extends past the target boundary.
- `ExtendBytes` — the amount C: must extend into the space the old recovery partitions occupied. Non-zero when the old recovery partitions extended past the target boundary and their deletion left free space that C: must absorb.

If neither is non-zero, C: is already at the boundary and no resize is needed.

After the pre-shrink runs, the script re-reads the actual C: end and recomputes the aligned partition start from the **actual** geometry, not the planned geometry:

```
ActualPartitionStart = ceil(ActualOSEnd / 1 MiB) × 1 MiB
ActualPartitionEnd   = AlignedManagedExtentEnd
ActualPartitionSize  = ActualPartitionEnd - ActualPartitionStart
```

If the actual post-resize geometry leaves less space than the plan's bucket size (`ActualPartitionSize < PlannedPartitionSize`), the script restores C: to its original size and defers. This protects against a resize that rounded in the wrong direction by more than an alignment block.

In the common case, the actual geometry matches the plan exactly and the recovery partition is exactly `BucketSizeBytes` with no trailing gap.

### The v46 patch 1 plan clamp

The v45 planner computed `tailEnd` from the last relevant partition's end, or from `diskSize` when no blocking partition existed, and then aligned down to 1 MiB — without first clamping to `diskSize − 1 MiB`. On a machine whose last partition ended at `diskSize` (equivalently, 1 MiB past the usable end), `AlignedManagedExtentEnd` landed 1 MiB past the reserve, and the post-delete geometry check in `Ensure-AdequateRecoveryPartition` (`$plannedEnd -gt ($diskSizeNow - 1MB)`) always rejected the plan.

The bug was first seen on physical hardware: a Lenovo IdeaPad 3 15IAU7 (MT 82RK) whose factory layout placed a partition exactly 1 MiB past the reserve. The plan was rejected, and the machine fell into OS-fallback with a matching `DesiredStateId`, so subsequent scheduled runs accepted the state file and did not retry — the machine stayed in OS-fallback until an operator manually deleted the state file.

The v46 patch 1 fix clamps `tailEnd` to `diskSize − 1 MiB` before aligning, on both branches of the plan (blocking partition and no blocking partition). The same layout that v45 rejected now produces a valid plan; the post-delete geometry check passes with the partition end exactly 1 MiB inside the disk end. This is a `ScriptVersion` bump (45 → 46), so every managed machine performs one full update on its next scheduled run.

The clamp is stated in [architecture.md](architecture.md) invariant 18 and its reasoning is documented as the "eighth direction" of the wrong-question pattern in the same document.

## The OS partition resize sequence (v45 patch 1)

The sequence below is the shrink-first pipeline. It replaces the v44 pipeline (disable → delete → extend → shrink → create) with (plan → shrink → disable → delete → extend → create). What changed is **when** each step runs and **what happens if it fails**.

### 0. Audit Mode startup guard

One read-only startup check runs before any of the steps below: the Audit Mode guard. It reads `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` → `ImageState` and defers with `EXIT_WARNING` when the value is present and is not `IMAGE_STATE_COMPLETE`. During Audit Mode, OOBE, sysprep generalize, and sysprep specialize, `reagentc /enable` is blocked by the OS with `ERROR_CANCELLED` (`0x4c7`, 1223) regardless of the correctness of the deployed WIM. The script defers before touching any partition. This guard runs before the hardware check, the manifest fetch, the OEM pack resolution, the `DesiredStateId` computation, and any other gate or operation. Under `-DryRun` the guard logs `Would defer …` and continues.

Under the v43 patch 5 (further revision 5) policy there is **no startup BitLocker gate**. The BitLocker decision is made where the action is taken, not at startup: the target volume is not known until the classifier has resolved the reagentc-registered location, and the OS volume's BitLocker state is irrelevant to the enable-only and dedicated-partition paths.

The consequence for this document is that the resize sequence below is only entered on machines whose `ImageState` is `IMAGE_STATE_COMPLETE` (or absent).

**As of v44 patch 6, the destructive partition path does not consult C:'s BitLocker state.** No C: check runs before the destructive sequence begins. If the destructive sequence fails at any point and the run falls through to OS-fallback, the OS-fallback gate checks C: at that point and defers as designed.

### 1. Read-only geometry plan

Before any state-modifying action, the script calls `Get-PartitionPlan` with the OS disk, the OS partition, the full partition inventory on that disk, the supported-size minimum, and the bucket size. The plan validates the layout and computes the target boundary, the shrink or extend amount, and the recovery partition's placement. It never touches the disk.

The plan rejects a layout when any of the following holds:

- The partition inventory contains entries from another disk.
- Another partition overlaps the OS partition geometry.
- The OS partition's supported-size bounds are unavailable.
- The requested bucket size is invalid or exceeds the 2 GiB ceiling.
- The OS partition geometry is inconsistent with the disk size.
- A type-coded recovery partition exceeds the 2 GiB ceiling.
- A type-coded recovery partition overlaps the OS partition geometry.
- A type-coded recovery partition precedes the OS partition.
- Partition extents overlap or are not ordered consistently.
- A type-coded recovery partition is separated from C: by a non-recovery partition.
- The planned OS partition size would be zero or negative.
- The aligned managed extent end precedes the OS partition start.

Any of those conditions produces `Deferred` with the corresponding `Reason`, and no partition or WinRE change is made. `RetrySuppressible` is not set for plan rejections — the layout requires operator review, and retrying would produce the same rejection.

If the plan is valid, the script logs a summary line:

```
Partition plan: recovery reclaim N MiB, contiguous free M MiB, shrink S MiB, extend E MiB, bucket B MiB, planned offset O MiB, alignment reserve A KiB
```

The plan is the contract for the rest of the sequence. Every subsequent step compares its result against the plan.

### 2. Pre-shrink in the reversible window

If `ShrinkBytes > 0`, the script performs the C: shrink now — **before** `reagentc /disable`, before any partition is deleted, and before any other state-modifying action. This is the v45 patch 1 reorder.

Two pre-shrink gates run first:

**Fail-closed free-space check.** The script reads C:'s current free space and computes the projected free space after the planned shrink. Two deferral cases:

- If C:'s volume cannot be read (`Get-Volume -DriveLetter C` returns nothing), the script defers with `Reason = "C: volume could not be read for free-space check"` and `RetrySuppressible = $false`. The read failure may be transient, so the deferral is not retry-suppressed — the next run tries the read again.
- If the projected free space after the shrink would fall below the 3 GiB reserve (`$MinFreeSpaceGB`), the script defers with `Reason = "post-shrink free space below minimum"` and `RetrySuppressible = $true`. Free space on C: and re-run.

**Shrink execution.** `Invoke-OSPartitionShrink` runs with three attempts:

- Attempt 1 — immediate `Resize-Partition` to the planned OS partition size.
- Attempt 2 — after a 10-second sleep, re-query `SizeMin`, log the delta, retry.
- Attempt 3 — after `defrag C: /x` with no timeout, sleep 5 seconds, re-query `SizeMin`, log the delta, retry.

Every attempt logs the pre-shrink size and target size. Every attempt is followed by `Assert-PartitionSizeAfterResize`, which confirms the partition landed at the target size within 1 MiB.

If all three attempts fail, the script calls `Restore-OSPartitionSize -TargetSizeBytes $initialOSSize` to restore C: to its pre-attempt size, and returns `Deferred` with `Reason = "pre-shrink failed"` and `RetrySuppressible = $true`. **The old recovery route is intact** — no partition was deleted and WinRE was never disabled. The machine is left exactly as it was found.

If the shrink succeeds but the post-resize verification fails, the same restoration runs and the script returns `Deferred` with `Reason = "pre-shrink verification failed"` and `RetrySuppressible = $true`.

If the shrink succeeds and verification passes, the script re-reads C:'s actual end and recomputes the aligned partition start and size as described under "The single-boundary geometry model" above. If the actual geometry leaves less than the plan's bucket size, the script restores C: and returns `Deferred` with `Reason = "resize rounding reduced planned extent"` and `RetrySuppressible = $true`.

### 3. Disable WinRE

If WinRE is currently `Enabled`, `reagentc /disable` runs. The script then verifies via `Get-WinREState` that the status is `Disabled`.

This step runs **after** the pre-shrink, in the reversible window's tail. If the disable fails, the script restores C: to its original size and calls `Restore-PreviousWinRERoute -PreviousState $stateBefore`. If the previous route is confirmed restored, the function returns `Deferred` with `Reason = "WinRE disable failed before deletion"` or `Reason = "WinRE disable verification failed before deletion"`. Otherwise it returns `$null` and the main flow falls through to OS-fallback. Neither deferral is retry-suppressed — the failure indicates a storage-level or OS-level condition, not a transient constraint.

### 3a. Pre-deletion resolver guard (v46 patch 2)

Immediately after the disable block and before the pre-deletion inventory, the script resolves the previously-active WinRE location to a partition. If WinRE was `Enabled` before the disable and the location cannot be resolved, the function returns `Deferred` with `Reason = "active WinRE location could not be resolved"`.

The guard exists because both the delete-last ordering (step 4) and `Restore-PreviousWinRERoute` depend on knowing which partition is active. Without it, no partition is protected by delete-last ordering, and if a later deletion fails there is no target to re-enable — the machine could be left with no working recovery route. The guard is fail-closed: it refuses to begin the destructive sequence rather than proceed with an unprotected active route.

The guard fires **after** `reagentc /disable` has already run, so a machine that reaches this deferral is left with WinRE `Disabled` and the old recovery partition intact. This is narrower than the pre-shrink deferrals, which leave the old route `Enabled`. A subsequent run sees WinRE `Disabled` and either re-registers the existing partition or — if the resolver still cannot map the location — hits the same guard. See [troubleshooting.md](troubleshooting.md) for the re-registration recovery procedure.

`RetrySuppressible` is not set for this deferral — the condition requires operator action to resolve, and retrying would produce the same rejection.

**Field status.** This guard is a v46 patch 2 code-review hardening. It has not been exercised in the field.

### 4. Delete existing recovery partitions (active last)

For each type-coded recovery partition the plan marked as deletable — GPT GUID `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}` or MBR type `0x27` — `Remove-Partition`. If that fails, retry with `diskpart delete partition override`.

**Delete-active-last ordering.** The currently active recovery partition — the one `$stateBefore.Location` resolves to — is moved to the end of the deletion list. If a mid-loop failure occurs, the active partition is still present and `Restore-PreviousWinRERoute` can try to re-enable it. This ordering depends on the pre-deletion resolver guard (step 3a) having successfully identified the active partition; the guard exists precisely to ensure that ordering is meaningful.

A partition on the OS disk that carries a `Recovery` or `WINRE` label but no type code is **not** in this loop. The type-code gate is applied before the loop and again inside it, as a redundant check. A label-only match is logged with the message "Skipping label-only recovery match on disk N partition M: recovery label alone does not authorize deletion." and the loop continues.

If a deletion fails, the script calls `Restore-OSPartitionSize -TargetSizeBytes $initialOSSize` and then `Restore-PreviousWinRERoute -PreviousState $stateBefore`, capturing both results separately (v46 patch 2). Three return shapes are possible:

- **Both restores succeed** — `Deferred` with `Reason = "recovery partition deletion failed; previous route restored"`.
- **Route restored, C: geometry restore unverified** — `Deferred` with `Reason = "recovery partition deletion failed; previous route restored but C: geometry restore unverified"`, and `$Script:GeometryRestoreFailed` is set. The state file is invalidated so the next run retries from clean. This is a partial rollback and is reported honestly rather than being flattened into the success case.
- **Route not restored** — `$null`, and the main flow falls through to OS-fallback. This is the post-deletion residual corner.

None of the deletion-failure deferrals is retry-suppressed.

### 5. Post-delete extension

If `ExtendBytes > 0`, the script now extends C: into the space the deleted recovery partitions occupied. `Invoke-OSPartitionExtend` runs three attempts with 5-second spacing between them.

**Extension-failure safe fallback (v45 patch 1; capped at bucket size in v46 patch 2).** If all three attempts fail, the script does not fall through to OS-fallback. It re-queries C:'s actual end and computes:

```
FallbackStart = ceil(ActualOSEnd / 1 MiB) × 1 MiB
FallbackEnd   = AlignedManagedExtentEnd
AvailableSize = FallbackEnd - FallbackStart
```

If `AvailableSize >= Plan.PlannedPartitionSize`, the script places the recovery partition at `FallbackStart` with size `Plan.PlannedPartitionSize` — **the plan's bucket size, not `AvailableSize`** — sets `$Script:nonFatalWarning = $true`, and continues. The space between the new partition's end and `FallbackEnd` remains an intentional trailing unallocated extent, logged explicitly.

Before v46 patch 2 the fallback assigned the entire `AvailableSize` to the replacement partition, filling from `FallbackStart` to `FallbackEnd`. On a layout that reclaimed multiple recovery partitions whose combined size exceeded the bucket, that could produce a partition larger than the 2 GiB managed-recovery ceiling. The v46 patch 2 cap sizes the replacement partition to the plan's bucket and logs the residual as the trailing unallocated extent. The cap enforces the same ceiling on the fallback path that the plan already enforces everywhere else, at the cost of a slightly larger unallocated gap on the disk.

If `AvailableSize < Plan.PlannedPartitionSize`, the script restores C: to its original size and returns `$null`, and the main flow falls through to OS-fallback.

The fallback exists because exact geometry is a goal, not a reason to leave WinRE disabled. A machine with a working dedicated recovery partition that starts at a slightly different offset and carries a trailing unallocated extent is in a better state than a machine in OS-fallback, and it converges on the next full-update pass.

### 6. Create the new partition at the aligned boundary

The new partition is created at `Plan.PlannedPartitionStart` with size `Plan.PlannedPartitionSize` — the exact values the plan computed and, where the pre-shrink ran, the values recomputed from the actual post-resize geometry. Where the extension-failure fallback ran, `PlannedPartitionStart` is the fallback start and `PlannedPartitionSize` remains the plan's bucket size. No rounding at creation time; the plan already aligned to 1 MiB.

`New-Partition` is called with the recovery type code applied at creation: `-GptType {de94bba4-06d1-4d40-a16a-bfd50179d6ac}` (GPT) or `-MbrType 0x27` (MBR). Before v43 patch 5, the partition was created as a Basic Data partition and its type was changed minutes later by `Set-RecoveryPartitionAttributes`. On a machine with Device Encryption actively encrypting, the encryption service could claim that Basic Data partition during the window and start encrypting it. Applying the recovery type at creation makes that window zero-width.

`New-Partition` is retried up to 3 times with a fresh overlap check between attempts. If it fails after 3 attempts, the script restores C: to its original size and returns `$null`, and the main flow falls through to OS-fallback.

### 7. Whole-layout assertion

`New-Partition` returning success does not by itself prove the partition landed at the planned offset and size, or that C: ends where the plan expected. The script calls `Assert-RecoveryPartitionLayout` immediately after creation. The assertion re-queries the partition and confirms:

- **Identity** — disk number and partition number match the values `New-Partition` returned.
- **Exact offset** — the partition's `Offset` equals `Plan.PlannedPartitionStart` to the byte.
- **Size within tolerance** — the partition's `Size` is within one alignment block (1 MiB) of `Plan.PlannedPartitionSize`.
- **No overlap with C:** — C:'s end is at or before the partition's start.
- **C:-to-recovery gap within tolerance** — the gap between C:'s end and the partition's start is within one alignment block. A gap within tolerance is logged; a gap beyond tolerance is a fatal geometry mismatch.
- **End at `AlignedManagedExtentEnd`** — the partition's end is within one alignment block of the aligned managed extent end. The same log-or-fail policy applies.

**Fail-closed on an unresolvable OS partition (v46 patch 2).** Before the C:-adjacency checks, the assertion re-resolves the OS partition via `Get-OSPartition`. If that returns nothing, the assertion returns `$false` rather than skipping the adjacency check. The layout cannot be verified against C:, so it is not accepted. This is the last check before `Format-Volume`; failing closed here prevents a partition that cannot be validated against C: from being formatted and registered.

On success, the script logs:

```
Verified recovery partition layout: disk N partition M, offset O MiB, size S MiB
```

On failure, the script calls `Remove-OrphanPartition` to clean up the partition it just created, then restores C: and returns `$null`. The main flow falls through to OS-fallback. This matches the existing `Format-Volume`-failure recovery shape.

### 8. Format and attribute

`Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Recovery'`.

Immediately after format, `Set-RecoveryPartitionAttributes` runs. It applies:

- **GPT**: `set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac` (idempotent with the type GUID already set at creation) and `gpt attributes=0x8000000000000001`.
- **MBR**: `set id=27` (idempotent with the type code already set at creation).

The type code is idempotent on this call; the attribute step is what actually adds new state here. **Attributes are set before drive-letter assignment.** A freshly-formatted NTFS partition with a drive letter is a candidate for BitLocker Device Encryption auto-encryption on Windows 11 24H2+. Setting the recovery type GUID and the PLATFORM_REQUIRED + NO_DRIVE_LETTER attribute first tells BitLocker the partition is not a data volume. Confirmed by diagnostic: a recovery-typed partition with these attributes reports "The volume could not be opened by BitLocker" and has no `Win32_EncryptableVolume` entry, while still accepting a temporary drive letter for deployment.

The v35 change introduced the attribute-before-letter ordering. The v43 patch 5 change introduced type-GUID-at-creation. Together they close the auto-encryption window from both sides: the type GUID is present from the moment the partition exists, and the attributes are present before any drive letter is assigned.

If `Set-RecoveryPartitionAttributes` returns `$false`, the script logs a WARN and sets `$Script:nonFatalWarning = $true`, and continues. WinRE is still functional; the partition may not be correctly marked.

### 9. Drive letter assignment

A drive letter is assigned via `Invoke-DriveLetterAssignment`, which tries the preferred letter, then every other candidate, using three methods per letter (`Set-Partition`, `Add-PartitionAccessPath`, `diskpart assign`).

**Preferred letter reuse.** If the current run has already held a drive letter on a recovery partition earlier in this run (tracked in `$Script:tempDriveLetters`), the helper prefers that letter over a fresh one from `Get-AvailableDriveLetter`. Windows caches letter-to-volume mappings in `MountedDevices`; reusing a letter the script held earlier is more likely to succeed cleanly than picking a fresh one, and it avoids the assign-remove-reassign churn that can leave stale entries. The fallback chain is unchanged: if the preferred letter fails, the helper moves on.

If no drive letter can be assigned — all 26 candidates fail — the script calls `Remove-OrphanPartition` on the new partition and returns `$null`. The main flow falls through to OS-fallback.

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

## The pre-shrink deferral and the retry-suppressing marker

When the pre-shrink sequence (or the pre-flight geometry plan) returns `Deferred` with `RetrySuppressible = $true`, the main flow writes a marker at `C:\Recovery\OEM\winre_partition_deferred.json`. The marker contains the current `DesiredStateId` and a `Since` timestamp.

The marker's purpose is to suppress identical retries. A machine whose destructive replacement deferred because C: has insufficient free space will defer again the next run if the constraint has not been resolved. The marker records that fact so the next run can skip the same retries and exit cleanly with `EXIT_WARNING` rather than spending a full-update pass on a plan that will fail the same way.

The marker is written only for `RetrySuppressible = $true` deferrals. The v46 patch 2 pre-deletion resolver deferral (`active WinRE location could not be resolved`) is not retry-suppressed: the condition requires operator action to resolve, and the machine is in a state (WinRE `Disabled` with the old partition intact) where the next run must re-evaluate the registration rather than skip. The same applies to the `WinRE disable failed before deletion` and `recovery partition deletion failed` deferrals.

On each subsequent run, the marker is honored only when both of the following hold:

- **The old route is verified functional.** `Test-DeferredWinRERouteFunctional` checks that WinRE is `Enabled`, the registered WIM is readable, and the active location is either a type-coded recovery partition on the OS disk or OS-fallback on a `FullyDecrypted` C:. If any of those conditions is not met, the marker is not honored.
- **The fast path would not fire.** The run computes `$fastPathWillFire` from the current state: exactly one type-coded recovery partition on the OS disk, no rebuild needed, WinRE `Enabled`. If the fast path would fire, the marker's purpose is obsolete — the machine has converged on its own — and the marker is not honored.

There are three ways the marker is **cleared**:

1. **DSI mismatch on read.** The marker was written under a different `DesiredStateId` — a script version bump, a manifest change, a CPU swap, a VMD flip, or a Windows build change. `Read-PartitionDeferral` logs `Partition deferral marker is stale for the current DesiredStateId; clearing it` and removes the file. This is the common case after a version boundary: the previous deferral no longer applies to the current deployment.

2. **Old route no longer functional.** `Test-DeferredWinRERouteFunctional` returns `$false`. The marker is cleared in the marker-check block and normal repair evaluation continues. The old route may have been corrupted by an external event, or an intervening run may have changed the state.

3. **Fast path would fire.** The machine has converged — one type-coded recovery partition on the OS disk, no rebuild needed, WinRE `Enabled`. The marker is cleared and the run falls through to the fast path, exiting `EXIT_SUCCESS` rather than being pinned at `EXIT_WARNING` by an obsolete marker.

A marker that is honored causes the run to exit `EXIT_WARNING` without repeating the pre-shrink retries. The staged workspace and checkpoint are preserved — if the machine's inputs have not changed and the previous route is still functional, the staged optimized WIM remains available for the eventual successful run.

To force a retry when the marker is present, delete both the marker and the state file:

```powershell
Remove-Item "$env:SystemDrive\Recovery\OEM\winre_partition_deferred.json" -Force
Remove-Item "$env:SystemDrive\Recovery\OEM\winre_state.json" -Force
```

The marker deletion clears the suppression record; the state-file deletion clears the recorded deployment identity, which forces a rebuild. If you want to force a retry without losing the recorded state, delete only the marker file — the next run re-attempts the pre-shrink, and if it fails again the marker is re-written with a fresh `Since` timestamp.

## Restoring the previous route on deletion failure

When a recovery partition deletion fails after WinRE has already been disabled, the previous route's target is the only one that can be re-enabled. Three mechanisms protect that outcome:

**Pre-deletion resolver guard (v46 patch 2).** Before any deletion begins, the script resolves the active WinRE location to a partition. If it cannot, the destructive sequence is refused — see step 3a above. Without the guard, the deletion loop would treat every deletable partition as non-active and could destroy the only partition the previous route could be re-enabled on.

**Delete-active-last ordering.** The active partition — resolved from `$stateBefore.Location` — is moved to the end of the deletion loop. If a mid-loop failure occurs, the active partition is still present.

**`Restore-PreviousWinRERoute`.** On any deletion failure, the script calls `Restore-PreviousWinRERoute -PreviousState $stateBefore`. The function:

1. Checks the current WinRE state. If already `Enabled` and the current location matches the previous location, it returns `$true` immediately.
2. Resolves the previous location to a partition. If unresolvable, it returns `$false`.
3. If the previous target is the OS partition (OS-fallback state), it checks C:'s BitLocker state. If C: is not confirmed fully decrypted, it returns `$false`. Otherwise it re-enables via the OS-fallback path.
4. If the previous target is a recovery partition, it calls `Set-RecoveryPartitionReadyForWinRE` to prepare the target. If preparation fails, it returns `$false`. Otherwise it re-enables via the dedicated-partition path.
5. Confirms the now-Enabled WinRE location matches the previous location via `Test-WinRELocationMatches`.

The deletion-failure branch captures the size-restore result and the route-restore result separately (v46 patch 2). The three return shapes are:

- **Both restores succeed** — `Deferred` with `Reason = "recovery partition deletion failed; previous route restored"`. The machine is left in a functional state — WinRE is `Enabled` on the same partition it was registered to before the run started, and C: is at its original size.
- **Route restored, C: geometry restore unverified** — `Deferred` with `Reason = "recovery partition deletion failed; previous route restored but C: geometry restore unverified"`, and `$Script:GeometryRestoreFailed` is set. The state file is invalidated so the next run retries from clean. The partial rollback is reported as such; the previous code could report "previous route restored" while C: remained shrunken.
- **Route not restored** — `$null` with an ERROR log stating that the route could not be restored. The machine ends without a working recovery route, and manual intervention is required.

**`Test-WinRELocationMatches`.** reagentc may report the same volume in either the GLOBALROOT form (`\\?\GLOBALROOT\device\harddiskN\partitionM\`) or the Volume-GUID form (`\\?\Volume{guid}\`), and the form can change across a disable/enable cycle. The function compares the two locations by:

1. **String equality** on the normalized strings (trailing backslashes trimmed).
2. If that fails, **disk/partition identity** — resolving each location via `Resolve-WinRELocationToPartition` and comparing the resulting disk number and partition number.

A machine whose WinRE is `Enabled` but registered to a different location is not treated as "restored". The route restoration must confirm the location, not just the status.

## Where the target partition is prepared for reagentc

The destructive sequence above is only one of the paths that reaches `reagentc /enable`. The full-update path with an existing recovery partition, the enable-only path, and the pending-reboot repair path also call reagentc. Under the v43 patch 5 (further revision 5) policy, all of them prepare the target partition through the same helper: `Set-RecoveryPartitionReadyForWinRE`.

The helper is called at these sites:

- The enable-only path, on the target recovery partition resolved from the reagentc location.
- The full-update path, on the recovery partition returned by `Find-SuitableRecoveryPartition` or `Ensure-AdequateRecoveryPartition`.
- The pending-reboot repair path, on the partition recorded in the state file's `DeployedDiskNumber` / `DeployedPartitionNumber`.
- Inside `Ensure-AdequateRecoveryPartition`, as a defensive early check described in step 10 above.

Each call is the same: if the target is unencrypted, return immediately; otherwise run `manage-bde -off` against the target and poll for completion, up to 300 seconds.

**The helper targets the recovery partition, not C:.** This is the v43 patch 5 (further revision 5) change. reagentc's BitLocker check is on the volume it is being asked to enable WinRE on, and that volume is the recovery partition on the dedicated-partition path and on the enable-only path. The script therefore prepares the recovery partition.

**The OS-fallback route is different.** On the OS-fallback route, the target volume *is* C:, and the script does not prepare C: — it never runs `manage-bde -off` against the OS volume. Instead, the OS-fallback gate checks C:'s `VolumeStatus` and defers unless it is `FullyDecrypted`. C:'s BitLocker state is the operator's responsibility: complete decryption of C: (`manage-bde -off C:`) or wait for an in-progress decryption to finish.

See [architecture.md](architecture.md) for the full policy and [deployment.md](deployment.md) for the operator-facing preconditions.

## `Restore-OSPartitionSize`

The helper that restores C: when a post-shrink step fails. As of v45 patch 1 it accepts a `-TargetSizeBytes` parameter:

```
Restore-OSPartitionSize -Reason "<description>" -TargetSizeBytes <bytes>
```

When `-TargetSizeBytes` is provided, the helper resizes C: to exactly that size. The recovery path always passes `-TargetSizeBytes $initialOSSize` — the pre-attempt size captured at the top of `Ensure-AdequateRecoveryPartition` — so a failed destructive attempt restores C: to the geometry it had before the run started. The parameterless call falls back to `SizeMax` and is retained only for legacy call sites.

The helper checks the current size first. If C: is already at the target size, it returns `$true` without resizing. Otherwise it resizes, sleeps 3 seconds, and verifies via `Assert-PartitionSizeAfterResize`.

Every failure path sets:

- `$Script:nonFatalWarning = $true` (so the exit code becomes 2).
- `$Script:GeometryRestoreFailed = $true` (so the state file is deleted).

The four failure paths are: OS partition not found, resize threw an exception, post-resize verification failed, and (for the parameterless legacy call) `Get-PartitionSupportedSize` failed.

The v46 patch 2 deletion-failure branch captures the helper's return value explicitly and propagates it into the deferral reason when the restore did not verify. A failed C: geometry restore after a deletion failure no longer reports as "previous route restored" while leaving C: shrunken; the state file is invalidated and the next run retries from clean.

## `Remove-OrphanPartition`

A helper that deletes a partition the script created but could not complete. Used when `Format-Volume` fails, when drive-letter assignment fails after creating a partition, when the helper could not make a newly created partition unencrypted, and when `Assert-RecoveryPartitionLayout` fails.

```
Remove-OrphanPartition -DiskNumber <n> -PartitionNumber <m> -Reason "<description>" -TargetOSPartitionSizeBytes <bytes>
```

Attempts `Remove-Partition`, then falls back to `diskpart delete partition override`. Waits 2 seconds, then verifies the partition is gone.

If the partition survives, the function:

- Logs a warning naming the partition and the reason.
- Sets `$Script:nonFatalWarning = $true`.
- Sets `$Script:GeometryRestoreFailed = $true`.

The `GeometryRestoreFailed` flag is important: an orphan partition between the OS partition and the disk end prevents the freed space from being reabsorbed, and without the flag the state file would record the resulting layout as valid. With the flag, the state file is deleted and the next run retries.

If the partition is removed successfully, the function calls `Restore-OSPartitionSize -Reason "after orphan removal" -TargetSizeBytes $TargetOSPartitionSizeBytes` to restore C: to its pre-attempt size.

## Step 7 — stray recovery partition cleanup

After deployment, Step 7 removes every type-coded recovery partition on non-OS disks.

```
Remove-StrayRecoveryPartitions -OSDiskNumber <n>
```

For each disk whose number is not the OS disk, query `Get-RecoveryPartitions`. For each partition found:

- If it is type-coded (GPT `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}` or MBR `0x27`) **and** at most 2 GiB, delete it.
- If it is not type-coded (label-only match), log and skip.
- If it is larger than 2 GiB, preserve it, log a warning, and set `$Script:nonFatalWarning = $true` for operator review.

A deletion failure sets `$Script:nonFatalWarning = $true` and returns `$false`.

The function is called from the fast path, the enable-only path, both pending-reboot exits, and Step 7 of the full-update path. In every case the call is the same; the read-only scan cost when there are no strays is a single `Get-Disk` and a few `Get-Partition` calls per non-OS disk.

**The `Get-RecoveryPartitions` reads are guarded against empty-disk errors (v46 patch 2).** Both `Get-Partition -DiskNumber $diskNum` calls carry `-ErrorAction SilentlyContinue`. On a machine with a disk that exposes no partitions — an SD/MMC card reader, an empty USB enclosure, a disk with no recognized partition table — the call would otherwise throw `CmdletizationQuery_NotFound_DiskNumber`. The error is non-terminating at the current call sites but pollutes the log on every run and would abort a caller wrapped in `-ErrorAction Stop`. The guard silences the throw only for disks that expose no partitions; behaviour on disks that do expose partitions is unchanged.

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

**Field coverage.** The v45 patch 1 GPT destructive path was exercised end-to-end on a disposable Hyper-V VM on 2026-10-02 08:56. The MBR attribute-application path (`set id=27` on an existing MBR partition) was exercised on a Win10 MBR VM on 2026-10-02 09:41. The MBR destructive path (`New-Partition -MbrType 0x27` at a planned offset) has not yet been exercised on any storage — the Win10 MBR VM run took the reuse path.

The v46 patch 1 plan clamp has been exercised on physical hardware in both directions: the Lenovo IdeaPad 3 15IAU7 that motivated the fix (plan rejected pre-clamp, accepted post-clamp, reached DEDICATED after a state-file reset), and clean-path verification on a Dell Latitude 3540 and an HP EliteBook 6 G1i 16" whose layouts took the no-blocking-partition branch without triggering the clamp.

The v46 patch 2 pre-deletion resolver guard and the extension-fallback bucket cap are code-review hardenings. Neither has been exercised in the field. They remain gated on the same tests that gate the rest of the post-deletion segment, per [CONTRIBUTING.md](../CONTRIBUTING.md).

## Related documents

- [architecture.md](architecture.md) — where the partition lifecycle fits in the pipeline, the invariants list, and the wrong-question narrative.
- [state-and-idempotency.md](state-and-idempotency.md) — how `GeometryRestoreFailed` and the deferral marker interact with the state file.
- [troubleshooting.md](troubleshooting.md) — the recovery procedure if the partition is lost, and the reason-by-reason resolution for each pre-shrink deferral.
- [driver-injection.md](driver-injection.md) — what happens before the partition work.
- [exit-codes.md](exit-codes.md) — the full list of exit paths, including the v45 pre-shrink deferral and its sub-reasons.
