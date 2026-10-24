---
title: "Recovery partition lifecycle — WinRE Manager"
description: "Recovery partition sizing, the single-boundary geometry model, the Int32-safe partition-plan arithmetic, the shrink-first destructive pipeline, and every deferral reason in WinRE Manager."
---

# Recovery partition lifecycle

This document covers how WinRE Manager decides what size a recovery partition should be, how it replaces one that is inadequate, and how it recovers if the destructive operations fail. The current design is the v45 patch 1 shrink-first pipeline, with the v46 patch 1 disk-end clamp applied to the geometry plan, the v46 patch 2 pre-deletion resolver guard and extension-fallback bucket cap applied to the destructive sequence, the v47 patch 1 three-source base-WIM selection and third-party driver strip stage applied to the image preparation that precedes the destructive work, the v48 patch 1 intervening-anchor handling and transactional WIM replacement applied to the destructive sequence and the deploy step respectively, the v49 source-ownership classification and native-boot VHDX fail-closed gate applied to the image preparation and the entry to the destructive sequence respectively, the v50 patch 2 non-OS-disk sweep suppression boundary applied to the Step 7 stray-recovery cleanup, and the v50 patch 3 positive post-deletion verification on the same Step 7 sweep.

## The invariant

**The OS disk should have one adequate type-coded recovery partition.** The non-OS sweep is separately scoped and can intentionally leave protected recovery partitions on other disks.

The type code is the partition's identity: GPT GUID `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}` or MBR type code `0x27`. A partition detected only by its `Recovery` or `WINRE` volume label is not a recovery partition for any decision the script makes — the label is a hint, not an identity.

The script enforces this on:

- The idempotent fast path (read-only scan for strays, and type-coded count for the "exactly one" condition).
- The enable-only path (before the success or reboot-required exit).
- The pending-reboot repair success exit.
- The pending-reboot reboot-required exit.
- Step 7 of the full-update path.

Eligible type-coded recovery partitions on non-OS internal disks are candidates for the scoped stray sweep. USB/unsupported buses, mounted VHD/VHDX disks, VM/indeterminate topologies and partitions above the 2 GiB ceiling retain their existing protections. A partition on a non-OS disk that carries a `Recovery` or `WINRE` label but no type code is logged and skipped — a label-only match on a secondary disk is not sufficient authority to delete.

The same rule applies symmetrically on the OS disk, and the OS-disk side is the one that matters for convergence. A partition on the OS disk that carries a `Recovery` or `WINRE` label but no type code is:

- **Not counted** by the fast path's "exactly one recovery partition on the OS disk" condition.
- **Not reused** by `Find-SuitableRecoveryPartition`.
- **Not deleted** by the destructive path in `Ensure-AdequateRecoveryPartition` — a label alone never authorizes deletion.
- **Not classified as DEDICATED** by the active-location classifier or the final-verification classifier.

The last two were always true; the first two were made true in v44 patch 7. Before patch 7, the fast-path count and the active-location classifier accepted a label-only match as evidence of a recovery partition, while the destructive path correctly refused to delete one. The asymmetry meant a Basic Data partition labelled "Recovery" on the OS disk would be counted by the fast path (so the "exactly one recovery partition" condition could never be satisfied) while being preserved by the destructive path (so it was never removed). The machine cycled through rebuilds indefinitely without converging. Patch 7 unified the authority rule: type code everywhere, label nowhere.

The cleanup policy responds to reported recovery problems on machines with multiple recovery partitions. Their presence alone does not establish that BCD is redirected or that Startup Repair must fail. The scope and exceptions above are deliberate; a volume label alone does not authorize deletion or count toward the manager's dedicated-partition invariant.

## The sizing policy

### Where the source WIM size comes from

The sizing rules use the actual WIM selected for deployment, in MiB. Patch 5 separates that choice from recovery-layout repair:

- **Serviced image:** Step 4 exports the candidate as `winre_optimized.wim`; use the exported size after stripping, injection and ResetBase.
- **Preserved foreign image:** use the unchanged, hash-verified source size. Classification or never-downgrade preservation dismounts any candidate with `-Discard`; it does not export or service the preserved source.
- **Current manager-owned image needing only layout repair:** use the unchanged source size. Relocation does not itself require another strip/inject/export pass.

Normal servicing selects the currently registered WIM, unless a hash-validated manager LKG is provably newer by compatible servicing metadata; the GitHub base-WIM repository is the cold-start fallback when neither local source is usable. A pending deployment instead pins its independently verified `%ProgramData%\OEM\WinRE-Manager\PendingDeployment\pending.wim` to the expected hash. It must not silently substitute another source.

The ownership classes remain `Manager-Owned`, `Manager-Lineage`, `Foreign-No-Drivers` and `Foreign-With-Drivers`. They decide whether servicing is permitted; they do not exempt an image from the dedicated-partition capacity requirement. Acceptance of a foreign hash is separate from ownership, and relocation must never copy that hash into `CurrentImageHash`.

Recovery-target selection uses a terminating OS-disk partition inventory. An unreadable or partially failed query is a refusal, not evidence that no reusable partition exists; partition creation is not attempted on that basis.

An adequately sized dedicated layout is assessed before fast-path and enable-only exits. An undersized dedicated partition or a WIM on the OS partition requires layout remediation even if the image bytes need no update. The healthy-layout check also requires a confirmed unencrypted target: an encrypted or indeterminate dedicated volume is not convergence. A partition that meets the reuse rule can still be prepared and decrypted in place; encryption alone does not require repartitioning or driver servicing. A foreign image already on an adequate, confirmed unencrypted dedicated partition avoids unnecessary partition work.

### Two thresholds

The script uses two separate free-space thresholds, and it is important not to confuse them.

**Existing-partition acceptance.** An existing recovery partition is accepted only if all of the following hold:

- **It is type-coded** — GPT recovery GUID `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}` or MBR type `0x27`. A partition detected only by a `Recovery`/`WINRE` volume label is not a candidate for reuse. See "The invariant" above for the reasoning and the v44 patch 7 non-convergence loop this closes.
- Its total size is at least the deployment WIM size plus 250 MiB, and does not exceed the 2048 MiB managed-recovery ceiling.
- Its measured effective free space is sufficient:

```
(partition.SizeRemaining + existingWinreWimSize) >= (sourceWimSize + 250 MiB)
```

The 250 MiB is Microsoft's documented WinRE servicing margin (KB5028997). It is the same threshold the OS's own pre-update WinRE check uses. There is no tolerance: 195 MiB is not accepted, and neither is any lower value.

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

**The ceiling is also preserved by the extension-failure fallback (v46 patch 2; ceiling-fill in v47 patch 2).** When the post-delete C: extension fails, the fallback path sizes the replacement partition to `min(AvailableSize, 2 GiB)` — the full available extent, capped at the 2 GiB managed-recovery ceiling — see step 5 below. Before v46 patch 2, the fallback assigned the entire remaining extent to the replacement partition, which on a layout that reclaimed multiple recovery partitions whose combined size exceeded the bucket could produce a partition larger than 2 GiB. v46 patch 2 introduced the ceiling but sized the partition to the plan's bucket, leaving the surplus as a trailing unallocated extent on every fallback. v47 patch 2 keeps the ceiling but fills up to it: the cap is what matters, not the bucket. The ceiling is now enforced on the fallback path exactly as the plan enforces it everywhere else.

Operators deploying to machines they did not image themselves should still run the harness Option 1 diagnostic and inspect the "Recovery partitions" section before proceeding. A recovery-typed partition larger than 2 GiB will now be preserved rather than acted on, but it is still worth knowing it is there — it may indicate an OEM factory recovery volume the operator wants to keep, or a layout that warrants manual review.

### Worked examples

| WIM size | Needed (WIM + 280) | Rounded up | Final |
|---|---|---|---|
| 757 MiB | 1037 MiB | 1100 MiB | 1100 MiB |
| 500 MiB | 780 MiB | 800 MiB | 1000 MiB (min) |
| 950 MiB | 1230 MiB | 1300 MiB | 1300 MiB |

The 1000 MiB minimum exists because smaller partitions cause problems on OEM hardware that ships with larger WinRE images after an OEM servicing pass. The minimum was chosen to match the most common OEM default.

### Why the 250 MiB target matters

The ASUS 11th-gen case is the canonical example. That machine had a 757 MiB WIM and a 999 MiB recovery partition. After replacing the WIM, the partition had ~197 MiB free (the raw arithmetic 999 minus 757 is 242 MiB; the difference is NTFS filesystem metadata and reserved space, which is why the effective-free check uses `SizeRemaining + existingWinreWimSize` rather than simple subtraction) — below 250.

The previous script policy accepted that partition with a 195 MiB tolerance (200 minus 5). The current policy does not. On that machine, the creation calculation calls for 1100 MiB, because WIM + 250 + 30 = 1037 rounds up to 1100. If the OS partition cannot be shrunk enough to make room, the script defers with the old route preserved. Patch 5 permits OS-fallback only after actual dedicated creation failure and the separately verified last-resort conditions; a plan or pre-shrink refusal does not authorize it.

A recovery partition below the servicing margin can fail a later Windows recovery update. It does not meet the healthy-layout requirement even if its current WIM remains readable.

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

**Int32-safe size arithmetic (v50 patch 4).** The plan's shrink and extend deltas must never be computed with `[Math]::Max(0, $delta)`. PowerShell binds the literal `0` in that expression as `Int32` and selects the `Max(Int32, Int32)` overload, then converts the second argument to `Int32` for the `val2` parameter — which throws before `Max` can run when the delta falls outside the `Int32` range (about ±2.1 GB in either direction). The field failure: a Surface Pro 3, 2026-10-16, with three type-coded recovery partitions on disk 0 and a ~4.9 GB extend delta, crashed with `Cannot convert argument "val2", with value "-5262802944", for "Max" to type "System.Int32"`. Every subsequent invocation crashed identically, defeating the self-healing resume task the crash was supposed to trigger. The fix in `Get-PartitionPlan` replaces the vulnerable form with explicit `-gt` comparisons on `[int64]` operands — `if ($x -gt $y) { [int64]($x - $y) } else { [int64]0 }` — for both `ShrinkBytes` and `ExtendBytes`. The harness guards the fix at two levels: check 21 is a source-pattern assertion that the Int64-safe comparison form is present and the `[Math]::Max(0, ...)` form is absent, and check 22 is a behavioral Int64 regression that reproduces both forms with a 3,000,000,000-byte delta, confirming the safe form returns the correct value while the vulnerable form throws. The fix has not been field-verified against a machine with a genuine >2 GiB delta; that would require reproducing the Surface Pro 3's layout.

**Intervening-anchor plan fields (v48 patch 1).** When the plan detects an intervening-anchor layout, four additional fields are populated. `InterveningAnchor` holds the anchor partition object (or `$null` when no anchor applies). `PlannedAnchorPartitionSize` is the anchor's post-shrink size. `AnchorShrinkBytes` is the amount the anchor must shrink from the right to seat the recovery partition at the disk tail; `AnchorExtendBytes` is always `0` — the v48 scope does not extend the anchor. In the non-intervening case these fields are `$null`/`0`/`0`, and the plan has exactly the v47 shape.

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

The clamp is stated in [architecture.md](architecture.md) invariant 18 and its reasoning is documented as the "ninth direction" of the wrong-question pattern in the same document.

## The OS partition resize sequence (v45 patch 1)

The sequence below is the shrink-first pipeline. It replaces the v44 pipeline (in v44: disable, then delete → extend → shrink → create; the CHANGELOG's compact list shows only the destructive portion) with (plan → shrink → disable → delete → extend → create). What changed is **when** each step runs and **what happens if it fails**.

**A note on numbering.** The substeps below (0 through 11) are the internal stages of `Ensure-AdequateRecoveryPartition`. They are not the same as the "eight steps" of the full-update pipeline described in [architecture.md](architecture.md); the eight-step pipeline is the top-level flow (Wipe WorkDir, Obtain base WIM, Mount and inject, Optimize, Ensure a suitable recovery partition, Deploy the WIM, Enforce the single-recovery-partition invariant, Final verification), and this document expands Step 5 into the substeps below.

### 0. Startup guards

Two read-only startup checks run before any of the steps below.

**Audit Mode guard.** It reads `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` → `ImageState` and defers with `EXIT_WARNING` when the value is present and is not `IMAGE_STATE_COMPLETE`. During Audit Mode, OOBE, sysprep generalize, and sysprep specialize, `reagentc /enable` is blocked by the OS with `ERROR_CANCELLED` (`0x4c7`, 1223) regardless of the correctness of the deployed WIM. The script defers before touching any partition. This guard runs before the hardware check, manifest fetch and deployment planning, after the elevation guard and program-lock setup. Under `-DryRun` the guard logs `Would defer …` and continues.

**Native-boot VHDX fail-closed gate (v49).** The manager refuses to run destructive operations when the OS disk's bus type is `File Backed Virtual` **and** at least one other disk is on a physical bus — the native-boot VHD/VHDX topology, where the running OS disk is a VHD/VHDX stored on a host physical disk and the host disk appears to the running OS as a non-OS disk subject to the stray-recovery cleanup. A hypervisor guest whose entire storage stack is virtual (every other disk on `Virtual` or `File Backed Virtual`) is not refused. The existing refusal protects a file-backed OS disk with visible nonvirtual disks. It is not a blanket refusal of ordinary Hyper-V or VirtualBox guests, whose virtual disks commonly report a virtual controller bus. The gate exits `EXIT_WARNING` before any partition or WinRE change; the machine's state file is unchanged. The refusal is a stable deferral, not a transient failure: a genuinely VHDX-boot machine will continue to exit 2 on every run until the topology is supported or the machine is converted. The gate has no `-DryRun` carve-out — the topology is a property of the machine, not of the run mode.

Under the v43 patch 5 (further revision 5) policy there is **no startup BitLocker gate**. The BitLocker decision is made where the action is taken, not at startup: the target volume is not known until the classifier has resolved the reagentc-registered location, and the OS volume's BitLocker state is irrelevant to the enable-only and dedicated-partition paths.

The live resize sequence is entered only when setup state and storage topology pass their guards. An ordinary guest's host-side virtual-disk file format does not by itself block OS-disk recovery repair.

**As of v44 patch 6, the destructive partition path does not *gate* on C:'s BitLocker state.** When the destructive sequence will remove the current WinRE route (WinRE `Enabled` or a non-empty deletable set), the script calls `Test-VolumeEncrypted -MountPoint "C:"` and logs the result — the log line names C:'s measured state and explicitly records that C: encryption is not a veto for the dedicated-target path. No gate refuses the destructive sequence on C: encryption. If dedicated creation actually fails, last-resort OS-fallback additionally requires verified geometry, fully decrypted C: and no acceptable route to retain. Losing the active route without an acceptable fallback is fatal; capacity/preflight deferral does not authorize fallback.

### 1. Read-only geometry plan

Before any state-modifying action, the script calls `Get-PartitionPlan` with the OS disk, the OS partition, the full partition inventory on that disk, the supported-size minimum, and the bucket size. The plan validates the layout and computes the target boundary, the shrink or extend amount, and the recovery partition's placement. It never touches the disk.

The plan rejects a layout when any of the following holds:

- The partition inventory contains entries from another disk.
- Another partition overlaps the OS partition geometry.
- The OS partition's supported-size bounds are unavailable.
- The requested bucket size is invalid.
- The requested bucket size exceeds the 2 GiB ceiling.
- The OS partition geometry is inconsistent with the disk size.
- A type-coded recovery partition exceeds the 2 GiB ceiling.
- A type-coded recovery partition overlaps the OS partition geometry.
- A type-coded recovery partition precedes the OS partition.
- Partition extents overlap or are not ordered consistently.
- A type-coded recovery partition is separated from C: by a non-recovery partition.
- The planned OS partition size would be zero or negative.
- The aligned managed extent end precedes the OS partition start.
- **Intervening-anchor path only (v48 patch 1).** The anchor is an EFI System Partition, a Microsoft Reserved Partition, or a system/boot partition; the anchor has no readable volume; the anchor filesystem is not NTFS; the anchor has no drive letter; the anchor's encryption state is indeterminate; the anchor is BitLocker-locked; the anchor's supported-size query failed; the planned anchor size is zero or negative; or the planned anchor size is below the anchor's supported minimum.
- **Intervening-anchor surplus rejection (v48 patch 1).** When the recovery partition being reclaimed is larger than the new bucket size, the anchor's current end is farther from the disk tail than the plan needs to seat the recovery partition at the aligned boundary. The plan rejects with the named surplus reason (`intervening anchor is N MiB smaller than the plan requires to seat the recovery partition at the disk tail`); the v48 scope does not extend the anchor because a BitLocker-encrypted anchor is not safely growable via `Resize-Partition` alone.

Any of those conditions produces `Deferred` with the corresponding `Reason`, and no partition or WinRE change is made. `RetrySuppressible` is not set for plan rejections — the layout requires operator review, and retrying would produce the same rejection. Since v47 patch 3, the seven partition-identity rejection reasons (cross-disk inventory, overlap with C:, oversized recovery-typed partition, recovery-typed overlap with C:, recovery-typed precedes C:, extent overlap / ordering, and separated-from-C:) name the offending partition(s) — disk number, partition number, size, volume label, and type code — so the log identifies the layout the operator needs to resolve without requiring a separate harness run.

If the plan is valid, the script logs a summary line:

```
Partition plan: recovery reclaim N MiB, contiguous free M MiB, shrink S MiB, extend E MiB, bucket B MiB, planned offset O MiB, alignment reserve A KiB
```

The plan is the contract for the rest of the sequence. Every subsequent step compares its result against the plan.

### 2. Pre-shrink in the reversible window

If the plan requires a resize — C: on the non-intervening path (`ShrinkBytes > 0`), the anchor on the intervening-anchor path (`AnchorShrinkBytes > 0`) — the script performs the resize now, before `reagentc /disable`, before any partition is deleted, and before any other state-modifying action. This is the v45 patch 1 reorder; v48 patch 1 extended it to the intervening-anchor path.

Two pre-shrink gates run first:

**Fail-closed free-space check.** The script reads the resize target's current free space and computes the projected free space after the planned shrink. Two deferral cases:

- If the resize target's volume cannot be read (`Get-Volume -Partition $resizeTarget` returns nothing), the script defers with `Reason = "<resize-target label> volume could not be read for free-space check"` and `RetrySuppressible = $false`. The read failure may be transient, so the deferral is not retry-suppressed — the next run tries the read again. The label is `OS partition (C:)` on the non-intervening path and `anchor partition (disk X part Y)` on the intervening-anchor path.
- If the projected free space after the shrink would fall below the 3 GiB reserve (`$MinFreeSpaceGB`), the script defers with `Reason = "post-shrink free space below minimum on <resize-target label>"` and `RetrySuppressible = $true`. Free space on the resize target and re-run.

**Shrink execution.** `Invoke-OSPartitionShrink` runs with three attempts:

- Attempt 1 — immediate `Resize-Partition` to the planned OS partition size.
- Attempt 2 — after a 10-second sleep, re-query `SizeMin`, log the delta, retry.
- Attempt 3 — after `defrag <target> /x` with no timeout, sleep 5 seconds, re-query `SizeMin`, log the delta, retry. As of v48 patch 1, the `defrag` target is parameterized via `-DefragTarget`; on the intervening-anchor path it is the anchor's drive letter instead of `C:`. When the parameter is omitted, the function defaults to `$env:SystemDrive`, preserving the v47 behavior for the OS-partition call site.

Every attempt logs the pre-shrink size and target size. Every attempt is followed by `Assert-PartitionSizeAfterResize`, which confirms the partition landed at the target size within 1 MiB.

If all three attempts fail, the script calls `Restore-OSPartitionSize -TargetSizeBytes $resizeTargetInitialSize -DiskNumber $resizeTarget.DiskNumber -PartitionNumber $resizeTarget.PartitionNumber` to restore the resize target to its pre-attempt size, and returns `Deferred` with `Reason = "pre-shrink failed"` and `RetrySuppressible = $true`. **The old recovery route is intact** — no partition was deleted and WinRE was never disabled. The machine is left exactly as it was found.

If the shrink succeeds but the post-resize verification fails, the same restoration runs and the script returns `Deferred` with `Reason = "pre-shrink verification failed"` and `RetrySuppressible = $true`.

If the shrink succeeds and verification passes, the script re-reads the resize target's actual end and recomputes the aligned partition start and size as described under "The single-boundary geometry model" above. If the actual geometry leaves less than the plan's bucket size, the script restores the resize target and returns `Deferred` with `Reason = "resize rounding reduced planned extent"` and `RetrySuppressible = $true`.

### 3. Disable WinRE

Patch 5's `-PrepareBeforeDisable` mode defers this action when the active route is outside the deletion set. In that case the caller can prepare and hash-verify the dedicated target before switching registration. Replacement of the active recovery partition still needs the independent source and durable journal before mutation.

If WinRE is currently `Enabled`, `reagentc /disable` runs. The script then verifies via `Get-WinREState` that the status is `Disabled`.

This step runs **after** the pre-shrink, in the reversible window's tail. If the disable fails, the script restores the resize target to its original size and calls `Restore-PreviousWinRERoute -PreviousState $stateBefore`. If the previous route is confirmed restored, the function returns `Deferred` with `Reason = "WinRE disable failed before deletion"` or `Reason = "WinRE disable verification failed before deletion"`. Otherwise it returns `$null` and the pending-deployment caller verifies the remaining route and retains recovery material. Neither deferral is retry-suppressed — the failure indicates a storage-level or OS-level condition, not a transient constraint.

**Pre-`/disable` race detector (v47 patch 1).** Immediately before this `/disable` call — and before whichever other `/disable` site the execution reaches first — the race detector re-reads the registered WinRE's `Location`, `Version`, and WIM SHA256, and compares them against values captured at the start of the rebuild (`Get-RegisteredWinREFingerprint`). Any change — location, version, or hash — aborts before the disable.

At this site the abort must first restore the resize target to its captured size, because the pre-shrink has already run. No partitions have been deleted yet and the old WinRE route is still intact, so no route restoration is needed. After the size restore, the script resets the checkpoint to Step 2, removes `base.wim` and any stale `winre_optimized.wim`, and returns `Deferred` with `Reason = "registered source changed before disable"`. The deferral is not retry-suppressed — the drift is a Windows-Update-driven transient, and the next run re-evaluates source selection.

This is a **race detector, not a lock**. Microsoft does not document `reagentc /disable` as atomic with respect to Windows Update, so the microseconds between the re-read and the disable returning cannot be eliminated without moving work into the disable→enable window (which would violate Rule 3). The detector narrows the window from minutes to that residual. See [architecture.md](architecture.md) for the full rationale and [state-and-idempotency.md](state-and-idempotency.md) for the two capture states and their handling.

### Pre-deletion resolver guard (v46 patch 2; v48 patch 1 moved this guard ahead of the pre-shrink — it fires between steps 1 and 2, and is presented here for continuity)

Immediately after `$stateBefore` is captured, and before the pre-shrink and before `reagentc /disable`, the script resolves the previously-active WinRE location to a partition. If WinRE was `Enabled` before the disable and the location cannot be resolved, the function returns `Deferred` with `Reason = "active WinRE location could not be resolved"`. As of v48 patch 1, the same fail-closed treatment applies when reagentc reports **no registered location at all** (empty `Location`): the function returns `Deferred` with `Reason = "active WinRE location is empty"`. Both cases refuse to begin the destructive sequence rather than proceed with an unprotected active route; both fire ahead of the pre-shrink and ahead of `reagentc /disable`, so the machine is left with WinRE still `Enabled` and the old recovery partition intact.

The guard exists because both the delete-last ordering (step 4) and `Restore-PreviousWinRERoute` depend on knowing which partition is active. Without it, no partition is protected by delete-last ordering, and if a later deletion fails there is no target to re-enable — the machine could be left with no working recovery route. The guard is fail-closed: it refuses to begin the destructive sequence rather than proceed with an unprotected active route.

The guard fires ahead of the pre-shrink and ahead of `reagentc /disable`, so a machine that reaches this deferral is left with WinRE still `Enabled` and the old recovery partition intact. This is the same class of deferral as the other pre-shrink deferrals: the old route is preserved and no partition was touched. A subsequent run re-evaluates the layout from the top. See [troubleshooting.md](troubleshooting.md) for the re-registration recovery procedure.

`RetrySuppressible` is not set for this deferral — the condition requires operator action to resolve, and retrying would produce the same rejection.

**Field status.** This guard is a v46 patch 2 code-review hardening. It has not been exercised in the field.

### 4. Delete existing recovery partitions (active last)

For each type-coded recovery partition the plan marked as deletable — GPT GUID `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}` or MBR type `0x27` — `Remove-Partition`. If that fails, retry with `diskpart delete partition override`.

**Delete-active-last ordering.** The currently active recovery partition — the one `$stateBefore.Location` resolves to — is moved to the end of the deletion list. If a mid-loop failure occurs, the active partition is still present and `Restore-PreviousWinRERoute` can try to re-enable it. This ordering depends on the pre-deletion resolver guard having successfully identified the active partition; the guard exists precisely to ensure that ordering is meaningful.

A partition on the OS disk that carries a `Recovery` or `WINRE` label but no type code is **not** in this loop. The type-code gate is applied in `Get-PartitionPlan`, which builds the `$reclaimable` list from type-coded partitions only; `Ensure-AdequateRecoveryPartition` iterates over `$plan.DeletableRecoveryPartitions`, so a label-only match is filtered out before the deletion list is built and never reaches the loop. The equivalent log line exists on the non-OS-disk path — `Remove-StrayRecoveryPartitions` logs `Stray-recovery cleanup: skipping non-OS-disk partition <disk>/<part> - label matches recovery but type code does not` — but the OS-disk destructive path has no equivalent because the type-code gate has already filtered label-only matches out.

If a deletion fails, the script calls `Restore-OSPartitionSize -TargetSizeBytes $resizeTargetInitialSize -DiskNumber $resizeTarget.DiskNumber -PartitionNumber $resizeTarget.PartitionNumber` and then `Restore-PreviousWinRERoute -PreviousState $stateBefore`, capturing both results separately (v46 patch 2). Three return shapes are possible:

- **Both restores succeed** — `Deferred` with `Reason = "recovery partition deletion failed; previous route restored"`.
- **Route restored, resize-target geometry restore unverified** — `Deferred` with `Reason = "recovery partition deletion failed; previous route restored but <resize-target label> geometry restore unverified"` (the label is `OS partition (C:)` on the non-intervening path and `anchor partition (disk X part Y)` on the intervening-anchor path; v48 patch 1), and `$Script:GeometryRestoreFailed` is set. The state file is invalidated so the next run retries from clean. This is a partial rollback and is reported honestly rather than being flattened into the success case.
- **Route not restored** — `$null`, and the pending-deployment caller verifies the remaining route and retains recovery material. This is the post-deletion residual corner.

None of the deletion-failure deferrals is retry-suppressed.

### 5. Post-delete extension

If `ExtendBytes > 0`, the script now extends C: into the space the deleted recovery partitions occupied. `Invoke-OSPartitionExtend` runs three attempts with 5-second spacing between them.

**Extension-failure safe fallback (v45 patch 1; bucket cap in v46 patch 2; ceiling-fill in v47 patch 2).** If all three attempts fail, the script does not fall through to OS-fallback. It re-queries C:'s actual end and computes:

```
FallbackStart = ceil(ActualOSEnd / 1 MiB) × 1 MiB
FallbackEnd   = AlignedManagedExtentEnd
AvailableSize = FallbackEnd - FallbackStart
```

If `AvailableSize >= Plan.PlannedPartitionSize`, the script places the recovery partition at `FallbackStart` with size `min(AvailableSize, 2 GiB)` — the full available extent, capped at the 2 GiB managed-recovery ceiling — sets `$Script:nonFatalWarning = $true`, and continues. Sizing to `min(AvailableSize, 2 GiB)` fills the available extent up to the ceiling, which eliminates the trailing unallocated extent in the common case; the surplus after a failed extension is typically a few hundred MiB, well under the ceiling. Only when `AvailableSize` exceeds 2 GiB does a trailing unallocated extent remain, and it is logged explicitly.

Before v46 patch 2 the fallback assigned the entire `AvailableSize` to the replacement partition without any ceiling. v46 patch 2 introduced the 2 GiB cap but sized the partition to the plan's bucket — the smallest the fallback could produce — leaving the surplus as a trailing unallocated extent on every fallback. v47 patch 2 keeps the ceiling but fills up to it: the cap is what matters, not the bucket.

If `AvailableSize < Plan.PlannedPartitionSize`, the script restores C: to its original size and returns `$null`, and the pending-deployment caller verifies the remaining route and retains recovery material.

**The whole-layout assertion reflects the fallback geometry.** The assertion is called with `-ExpectedEndBytes $plannedEnd`, the current plan's own end. On the normal path `$plannedEnd` equals `$plan.AlignedManagedExtentEnd`; when the fallback ran, `$plannedEnd` reflects the fallback geometry. Before v47 patch 2 the assertion was called with `$plan.AlignedManagedExtentEnd`, which the fallback block did not update; any fallback case where the trailing extent exceeded the assertion's 1 MiB tolerance — i.e., any case where the fallback was actually needed — failed the assertion, removed the newly created partition via `Remove-OrphanPartition`, and fell through to the OS-fallback route the fallback existed to avoid.

The fallback exists because exact geometry is a goal, not a reason to leave WinRE disabled. A machine with a working dedicated recovery partition that starts at a slightly different offset and carries a trailing unallocated extent is in a better state than a machine in OS-fallback, and it converges on the next full-update pass.

### 6. Create the new partition at the aligned boundary

The new partition is created at `Plan.PlannedPartitionStart` with size `Plan.PlannedPartitionSize` — the exact values the plan computed and, where the pre-shrink ran, the values recomputed from the actual post-resize geometry. Where the extension-failure fallback ran, `PlannedPartitionStart` is the fallback start and `PlannedPartitionSize` remains the plan's bucket size. No rounding at creation time; the plan already aligned to 1 MiB.

`New-Partition` is called with the recovery type code applied at creation: `-GptType {de94bba4-06d1-4d40-a16a-bfd50179d6ac}` (GPT) or `-MbrType 0x27` (MBR). Before v43 patch 5, the partition was created as a Basic Data partition and its type was changed minutes later by `Set-RecoveryPartitionAttributes`. On a machine with Device Encryption actively encrypting, the encryption service could claim that Basic Data partition during the window and start encrypting it. Applying the recovery type at creation makes that window zero-width.

`New-Partition` is retried up to 3 times with a fresh overlap check between attempts. If it fails after 3 attempts, the script restores C: to its original size and returns `$null`, and the pending-deployment caller verifies the remaining route and retains recovery material.

### 7. Whole-layout assertion

`New-Partition` returning success does not by itself prove the partition landed at the planned offset and size, or that C: ends where the plan expected. The script calls `Assert-RecoveryPartitionLayout` immediately after creation. The assertion re-queries the partition and confirms:

- **Identity** — disk number and partition number match the values `New-Partition` returned.
- **Exact offset** — the partition's `Offset` equals `Plan.PlannedPartitionStart` to the byte.
- **Size within tolerance** — the partition's `Size` is within one alignment block (1 MiB) of `Plan.PlannedPartitionSize`.
- **No overlap with the boundary partition** — the boundary partition's end is at or before the new partition's start.
- **Boundary-to-recovery gap within tolerance** — the gap between the boundary partition's end and the new partition's start is within one alignment block. A gap within tolerance is logged; a gap beyond tolerance is a fatal geometry mismatch.
- **End at the current plan's own end (`$plannedEnd`)** — the partition's end is within one alignment block of the current plan's end. On the normal path `$plannedEnd` equals `$plan.AlignedManagedExtentEnd`; when the extension-failure fallback ran, `$plannedEnd` reflects the fallback geometry (step 5). The same log-or-fail policy applies.

**Fail-closed on an unresolvable boundary partition (v46 patch 2; generalized for the intervening anchor in v48 patch 1).** Before the adjacency checks, the assertion resolves the boundary partition — the caller-supplied `-BoundaryPartition` when present, otherwise the OS partition via `Get-OSPartition`. If neither resolves, the assertion returns `$false` rather than skipping the adjacency check. The layout cannot be verified against a boundary, so it is not accepted. This is the last check before `Format-Volume`; failing closed here prevents a partition that cannot be validated against a boundary from being formatted and registered.

**Boundary-partition parameter (v48 patch 1).** The assertion accepts an optional `-BoundaryPartition`. When omitted, the boundary defaults to the OS partition, preserving the v47 behavior; the v47 call sites are unchanged. On the intervening-anchor path the caller passes the shrunk anchor, so the overlap and gap checks measure against the anchor rather than C:. Without the parameter the >700 GiB C:-to-recovery gap on the motivating layout would exceed the 1 MiB alignment tolerance and the assertion would reject every valid intervening plan. The v48 field run on the AMD Ryzen 7 5825U confirmed the parameter fires correctly on the exact layout that motivated the feature.

On success, the script logs:

```
Verified recovery partition layout: disk N partition M, offset O MiB, size S MiB
```

On failure, the script calls `Remove-OrphanPartition` to clean up the partition it just created, then restores the resize target and returns `$null`. The pending-deployment caller verifies the remaining route and retains recovery material. A helper failure does not authorize an unverified fallback. This matches the existing `Format-Volume`-failure recovery shape.

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

**Letter availability is checked against three sources.** Before a candidate letter is tried, `Test-DriveLetterInUse` returns `$true` if any of the following holds:

- `Get-Volume -DriveLetter <letter>` returns a local volume.
- The Mount Manager's DOS Devices registry key (`HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\DOS Devices`) has an entry for `<letter>:`. Mapped network drives (`net use Z: \\server\share`) and `subst` reservations live in this key and do not appear in `Get-Volume`. Without this check, a mapped `Z:` was silently selected as "free"; all three assignment methods failed; and the old `Test-Path "Z:\"` check succeeded because the share resolved, so the function returned `Z` as "assigned" and the WIM was written to the network share instead of the recovery partition.
- `Test-Path "<letter>:\"` returns `$true` (final safety net).

Candidates in use are skipped, unless the letter is already owned by the target partition (the preferred-letter case below).

**Each assignment method is verified against the target partition.** After `Set-Partition`, `Add-PartitionAccessPath`, or `diskpart assign letter=X`, the function re-queries the specific disk and partition and requires its `DriveLetter` to equal the letter just assigned. A bare `Test-Path "X:\"` is not sufficient: a mapped network drive at X: would resolve to the share and read as a successful assignment even though the target partition never received a letter.

**Bail-outs.** At the top of each candidate iteration, the function emits a single ERROR-level log line and returns `$null` if the target partition no longer exists, or if its disk is offline or not `Online`. Both cases would fail identically for every candidate letter and produce one WARN line per candidate attempted; the bail-out returns `$null` immediately, and the caller handles it the same way as a genuine exhaustion.

**Per-method error capture.** When all three methods fail for a given letter, the function logs the error from the last method: the exception message from the cmdlet, or a "returned but the letter did not resolve" note if the API succeeded without effect, or diskpart's stdout. The final log line reads `All three methods failed for <letter>: - <diagnostic>`, so an operator sees why the search is exhausting candidates rather than a bare "failed".

**Preferred letter reuse.** If the current run has already held a drive letter on a recovery partition earlier in this run (tracked in `$Script:tempDriveLetters`), the caller selects that letter as the preferred letter; the helper tries it first, before falling back to a fresh one from `Get-AvailableDriveLetter`. Windows caches letter-to-volume mappings in `MountedDevices`; reusing a letter the script held earlier is more likely to succeed cleanly than picking a fresh one, and it avoids the assign-remove-reassign churn that can leave stale entries. The fallback chain is unchanged: if the preferred letter fails, the helper moves on.

If no drive letter can be assigned — all 23 candidates fail, or the function bailed out early — the script calls `Remove-OrphanPartition` on the new partition and returns `$null`. The pending-deployment caller verifies the remaining route and retains recovery material. A helper failure does not authorize an unverified fallback.

### 10. Verify encryption state (early check)

After assignment, `Test-VolumeEncrypted` verifies the new partition is not encrypted.

- If it **is** encrypted (`$true`), the script calls `Set-RecoveryPartitionReadyForWinRE` on the partition, which decrypts it in place with `manage-bde -off` and polls for completion, up to a 300-second timeout. If the helper succeeds, the partition is now unencrypted and usable; the run continues. If the helper fails (timeout or unrecoverable error), `Remove-OrphanPartition` deletes the partition and the function returns `$null`; the pending-deployment caller verifies the remaining route and retains recovery material.
- If the state is **unknown** (`$null`), the script proceeds with a warning and lets the deploy step's `Set-RecoveryPartitionReadyForWinRE` call surface any issue.
- If it is **confirmed unencrypted** (`$false`), nothing further is needed.

This early check is defensive: the deploy step (Step 5 in the main flow) calls `Set-RecoveryPartitionReadyForWinRE` on the recovery partition again regardless, so this is not the last opportunity to prepare the partition. It exists so that a newly created partition claimed by the Device Encryption service is cleaned up before the function returns, rather than leaving the caller with a partition that will fail later.

**The delete-and-recreate retry is gone.** Under the pre-v43-patch-5-further-revision-5 policy, if the new partition was encrypted the script suspended BitLocker, deleted the partition, and recreated it. That approach was correct in isolation but was based on the wrong premise — suspension does not prevent the encryption service from claiming the new partition, and deletion is unnecessary when the partition can be decrypted in place. The 2026-09-29 field test confirmed that a partition claimed by Device Encryption does not re-encrypt after `manage-bde -off` completes, which makes decrypt-in-place safe and simpler.

### 11. Success

`New-DirectoryIfNotExists "${assignedLetter}:\Recovery\WindowsRE"`.

Return `@{ DriveLetter = $assignedLetter; DiskNumber = $osDisk.Number; PartitionNumber = $newPart.PartitionNumber }`.

The function adds the assigned drive letter to `$Script:tempDriveLetters` before returning, so the caller can remove it at exit.

## The pre-shrink deferral and the retry-suppressing marker

`C:\Recovery\OEM\winre_partition_deferred.json` records a refused attempt separately from the deployment state and durable pending-operation record. Patch 5's version 2 marker records `DesiredStateId`, `Since`, `Category`, `Reason` and `RetryAfterUtc`.

A capacity refusal is evaluated against actual available space, the required shrink and the free-space reserve on a subsequent run. Free space is not rounded into a coarse retry bucket. A DSI match does not freeze the refusal after the machine's conditions change. Execution/verification failures use a bounded one-hour retry delay rather than indefinite suppression; legacy markers without the new fields do not suppress fresh assessment.

The distinction matters: `post-shrink free space below minimum` is a capacity refusal, while a failed shrink command or unexpected post-resize geometry is an execution/verification outcome. Plan/provider/route-integrity refusals are reported by their actual phase rather than described as proof that space is insufficient.

A currently blocked operation retains its verified candidate and pending record. An adequate dedicated route can make an obsolete marker unnecessary. An OS-fallback route or undersized dedicated partition is not converged merely because it was previously accepted.

A verified last-resort OS-fallback is available only after actual dedicated creation failure, with verified geometry and fully decrypted C:, when an acceptable previous or readable enabled route cannot be retained. Its location, expected bytes and saved state are checked; it still retains the journal, candidate and resume task and reports warning rather than convergence. A preflight `Deferred` does not trigger this fallback.

Forcing a retry by deleting deployment state is no longer the normal response to freeing space. Read the current refusal, resolve it and re-run Repair. Do not delete `pending-deployment.json` or its protected candidate to clear a retry marker; those artifacts may be the only independent recovery material after partition mutations. See [state and idempotency](state-and-idempotency.md#partition-deferral-sidecar).

## Restoring the previous route on deletion failure

When a recovery partition deletion fails after WinRE has already been disabled, the previous route's target is the only one that can be re-enabled. Three mechanisms protect that outcome:

**Pre-deletion resolver guard (v46 patch 2).** Before any deletion begins, the script resolves the active WinRE location to a partition. If it cannot, the destructive sequence is refused — see the pre-deletion resolver guard section above. Without the guard, the deletion loop would treat every deletable partition as non-active and could destroy the only partition the previous route could be re-enabled on.

**Delete-active-last ordering.** The active partition — resolved from `$stateBefore.Location` — is moved to the end of the deletion loop. If a mid-loop failure occurs, the active partition is still present.

**`Restore-PreviousWinRERoute`.** On any deletion failure, the script calls `Restore-PreviousWinRERoute -PreviousState $stateBefore`. The function:

1. Checks the previous state first: if `$PreviousState.Status -ne 'Enabled'`, there is nothing to restore and the function returns `$false`. It then reads the current WinRE state; if already `Enabled` and the current location matches the previous location, it returns `$true` immediately.
2. Resolves the previous location to a partition. If unresolvable, it returns `$false`.
3. If the previous target is the OS partition (OS-fallback state), it checks C:'s BitLocker state. If C: is not confirmed fully decrypted, it returns `$false`. Otherwise it re-enables via the OS-fallback path.
4. If the previous target is a recovery partition, it calls `Set-RecoveryPartitionReadyForWinRE` to prepare the target. If preparation fails, it returns `$false`. Otherwise it re-enables via the dedicated-partition path.
5. Confirms the now-Enabled WinRE location matches the previous location via `Test-WinRELocationMatches`.

The deletion-failure branch captures the size-restore result and the route-restore result separately (v46 patch 2). The three return shapes are:

- **Both restores succeed** — `Deferred` with `Reason = "recovery partition deletion failed; previous route restored"`. The machine is left in a functional state — WinRE is `Enabled` on the same partition it was registered to before the run started, and the resize target is at its original size.
- **Route restored, resize-target geometry restore unverified** — `Deferred` with `Reason = "recovery partition deletion failed; previous route restored but <resize-target label> geometry restore unverified"`, and `$Script:GeometryRestoreFailed` is set. The state file is invalidated so the next run retries from clean. The partial rollback is reported as such; the previous code could report "previous route restored" while the resize target remained shrunken.
- **Route not restored** — `$null` with an ERROR log stating that the route could not be restored. The machine ends without a working recovery route, and manual intervention is required.

**`Test-WinRELocationMatches`.** reagentc locations can identify a volume by drive letter, GLOBALROOT (`\\?\GLOBALROOT\device\harddiskN\partitionM\`) or volume GUID (`\\?\Volume{guid}\`), followed by the registered folder. The volume spelling can change across a disable/enable cycle. Patch 5 preserves that folder through parsing and checks both **resolved partition identity and normalized relative folder** when comparing different spellings. Two different folders on one partition are different recovery routes.

`Resolve-WinRELocationToPartition` identifies the partition independently of its registered folder. Deployment must resolve an enabled active route before classifying the chosen target as active or independent; failure to resolve it refuses target preparation or copying. This prevents a drive-letter location from being mistaken for an inactive target that is safe to overwrite before WinRE is disabled.

If reagentc reports `Enabled` with an empty or absent location field, registry data cannot establish the active route and is not substituted. The route remains unresolved, so existing preparation guards refuse mutation. Registry fallback remains available when WinRE is disabled. This is a defensive contract; an actual Windows instance producing the inconsistent Enabled-without-location state has not been demonstrated in the supplied logs.

A volume-root location denotes that root literally; it does not imply `Recovery\WindowsRE`. Ambiguous aliases through a reparse point, mounted directory or substituted drive are refused when the backing volume and full directory cannot be proven.

A machine whose WinRE is `Enabled` but registered to a different folder or partition is not treated as "restored". Route restoration checks the full location and the previous image's own expected bytes, not just status or shared partition identity.

## Where the target partition is prepared for reagentc

The destructive sequence above is only one of the paths that reaches `reagentc /enable`. The full-update path with an existing recovery partition, the enable-only path, the pending-reboot repair path, and the v49 `-Action Restore` path also call reagentc. Under the v43 patch 5 (further revision 5) policy, all of them prepare the target partition through the same helper: `Set-RecoveryPartitionReadyForWinRE`.

The helper is called at these sites:

- The enable-only path, on the target recovery partition resolved from the reagentc location.
- The full-update path, on the recovery partition returned by `Find-SuitableRecoveryPartition` or `Ensure-AdequateRecoveryPartition`.
- The pending-reboot repair path, on the partition recorded in the state file's `DeployedDiskNumber` / `DeployedPartitionNumber`.
- Inside `Ensure-AdequateRecoveryPartition`, as a defensive early check described in step 10 above.
- Inside `Restore-PreviousWinRERoute`, on the previous route's target partition, before the function re-registers and re-enables the route.
- The v49 `-Action Restore` path, on the target recovery partition resolved from the current registered location, before the WIM is replaced. (Not applicable on the OS-fallback branch, where the target is C: and the OS-fallback gate applies instead.)

Each call is the same: if the target is unencrypted, return immediately; otherwise run `manage-bde -off` against the target and poll for completion, up to 300 seconds.

**The helper targets the recovery partition, not C:.** This is the v43 patch 5 (further revision 5) change. reagentc's BitLocker check is on the volume it is being asked to enable WinRE on, and that volume is the recovery partition on the dedicated-partition path and on the enable-only path. The script therefore prepares the recovery partition.

**The OS-fallback route is different.** On the OS-fallback route, the target volume *is* C:, and the script does not prepare C: — it never runs `manage-bde -off` against the OS volume. Instead, the OS-fallback gate checks C:'s `VolumeStatus` and defers unless it is `FullyDecrypted`. C:'s BitLocker state is the operator's responsibility: complete decryption of C: (`manage-bde -off C:`) or wait for an in-progress decryption to finish.

See [architecture.md](architecture.md) for the full policy and [deployment.md](deployment.md) for the operator-facing preconditions.

## `Restore-OSPartitionSize`

The helper that restores a partition when a post-shrink step fails. As of v45 patch 1 it accepts a `-TargetSizeBytes` parameter:

```
Restore-OSPartitionSize -Reason "<description>" -TargetSizeBytes <bytes>
```

When `-TargetSizeBytes` is provided, the helper resizes the target partition to exactly that size. The recovery path always passes `-TargetSizeBytes $resizeTargetInitialSize` — the pre-attempt size captured at the top of `Ensure-AdequateRecoveryPartition` — so a failed destructive attempt restores the resize target to the geometry it had before the run started. The parameterless call falls back to `SizeMax` and is retained only for legacy call sites.

As of v48 patch 1, the helper also accepts optional `-DiskNumber` and `-PartitionNumber` parameters. Both must be supplied together or neither; a partial supply logs an internal-error WARN and returns `$false`. When supplied, the helper operates on the identified partition instead of C:, and the log label reflects the actual target. The intervening-anchor path uses these parameters to restore the shrunk anchor after a failed shrink or a failed destructive attempt; the OS-partition call sites are unchanged and continue to omit them. Any failure sets `nonFatalWarning` and `GeometryRestoreFailed` on the anchor path as well as the C: path, so the state file is invalidated and the next run retries from clean rather than taking the fast path over an unexpectedly-shrunken anchor.

The helper checks the current size first. If the target is already at the target size, it returns `$true` without resizing. Otherwise it resizes, sleeps 3 seconds, and verifies via `Assert-PartitionSizeAfterResize`.

Every failure path sets:

- `$Script:nonFatalWarning = $true` (so the exit code becomes 2).
- `$Script:GeometryRestoreFailed = $true` (so the state file is deleted).

The four failure paths are: target partition not found, resize threw an exception, post-resize verification failed, and (for the parameterless legacy call) `Get-PartitionSupportedSize` failed.

The v46 patch 2 deletion-failure branch captures the helper's return value explicitly and propagates it into the deferral reason when the restore did not verify. A failed resize-target geometry restore after a deletion failure no longer reports as "previous route restored" while leaving the resize target shrunken; the state file is invalidated and the next run retries from clean.

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

The `GeometryRestoreFailed` flag is important: an orphan partition between the resize target and the disk end prevents the freed space from being reabsorbed, and without the flag the state file would record the resulting layout as valid. With the flag, the state file is deleted and the next run retries.

If the partition is removed successfully, the function calls `Restore-OSPartitionSize -Reason "after orphan removal" -TargetSizeBytes $TargetOSPartitionSizeBytes` to restore the resize target to its pre-attempt size.

As of v48 patch 1, the function also accepts `-AnchorDiskNumber` and `-AnchorPartitionNumber`. Both default to the OS partition, so the v47 call sites are unchanged. On the intervening-anchor path the caller passes the anchor's identity, and the post-orphan `Restore-OSPartitionSize` call restores the shrunk anchor instead of C:. Any failure sets the geometry-failure flags, exactly as on the C: path — if the anchor is left shrunken after a failed rollback, the state file must not remain valid or the next run may take the fast path over an unexpectedly-shrunken anchor.

## Step 7 — stray recovery partition cleanup

Step 7 runs the scoped non-OS recovery-partition sweep. It does not delete from every attached disk.

```
Remove-StrayRecoveryPartitions -OSDiskNumber <n>
```

Detected or indeterminate guests skip the sweep. Otherwise it preserves non-OS `File Backed Virtual` disks and unsupported buses, including USB, SD/MMC, iSCSI and Fibre Channel. On the remaining internal disks it queries `Get-RecoveryPartitions`; for each partition found:

- If it is type-coded (GPT `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}` or MBR `0x27`) **and** at most 2 GiB, delete it.
- If it is not type-coded (label-only match), log and skip.
- If it is larger than 2 GiB, preserve it, log a warning, and set `$Script:nonFatalWarning = $true` for operator review.

A deletion failure sets `$Script:nonFatalWarning = $true` and returns `$false`.

As of v50 patch 1, the function also emits one aggregate summary line per run in both DryRun and live, enumerating what was or would be deleted, preserved-oversized, skipped-non-typed, or failed. The per-partition lines remain; the summary lets an operator see the total stray-partition impact of a run at a glance.

As of v50 patch 2, the function first calls `Test-RunningInVirtualMachine`, which matches `Win32_ComputerSystem`'s Manufacturer and Model against a list of hypervisor signatures. When the helper returns `$true` (a known hypervisor signature matched) or `$null` (the query failed, returned nothing, or returned empty/whitespace-only metadata — fail closed), the entire sweep is suppressed and any recovery partitions on non-OS disks are preserved. Suppression is the safe direction: a host physical disk exposed to a guest via passthrough (Hyper-V) or raw disk access (VirtualBox) is indistinguishable from a genuine secondary internal disk by `BusType` alone. When the sweep runs on a physical machine, any non-OS disk whose `BusType` is `File Backed Virtual` is preserved individually — a mounted VHD/VHDX may contain another installation's recovery environment — and its disk number is added to the aggregate summary line's `preserved virtual:` field. The OS-disk repair path is unaffected by either suppression: it operates only on the OS disk, which is the guest's own.

As of v50 patch 3, each deletion the sweep performs is positively verified. After `Remove-Partition` returns, the function re-queries the target disk with a terminating `Get-Partition -DiskNumber $disk.Number -ErrorAction Stop` and confirms the target partition is absent from the results before recording the deletion as confirmed. A query failure is treated as not-confirmed-deleted (fail closed): the partition is added to the `failedToDelete` list, `$Script:nonFatalWarning` is set, and the function returns `$false`. The deletion outcome is unconfirmed; inspect the actual inventory before relying on the partition's presence or absence. The aggregate summary line's `failed:` field names it. This closes the same class of fail-open the v49 patch 2 changes closed on the main destructive deletion loop, extended to the non-OS sweep.

The function is called from the fast path, the enable-only path, both pending-reboot exits, and Step 7 of the full-update path. In every case the call is the same; the read-only scan cost when there are no strays is a single `Get-Disk` and a few `Get-Partition` calls per non-OS disk.

**The `Get-RecoveryPartitions` reads are guarded against empty-disk errors (v46 patch 2).** Both `Get-Partition -DiskNumber $diskNum` calls carry `-ErrorAction SilentlyContinue`. On a machine with a disk that exposes no partitions — an SD/MMC card reader, an empty USB enclosure, a disk with no recognized partition table — the call would otherwise throw `CmdletizationQuery_NotFound_DiskNumber`. The error is non-terminating at the current call sites but pollutes the log on every run and would abort a caller wrapped in `-ErrorAction Stop`. The broad discovery helper suppresses those query errors; this alone does not distinguish an empty disk from a provider failure. Destructive OS-target selection separately uses a terminating inventory and refuses on failure.

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

**v47 patch 1 coverage.** The v47 patch 1 non-destructive paths are field-verified on an ASUS PRIME H510M-D (2026-10-03). The v47-specific destructive-adjacent paths that remain unexercised on any storage are:

- **The destructive partition paths under v47.** Pre-shrink, partition delete, `New-Partition`, the whole-layout assertion, and the post-delete extension fallback were not reached — the existing recovery partition was reusable.
- **The v47 pre-`/disable` race-detector abort at the `Ensure-AdequateRecoveryPartition` site.** No drift occurred during candidate preparation, so the abort branch — with its resize-target size restoration — has not fired in the field.
- **The strip stage against a non-empty third-party driver set.** The ASUS run's strip was a no-op. The strip-and-reinject loop has not run against a non-empty set inside a v47 production run.
- **The three-source selection via the LKG or GitHub branches.** The ASUS run took the "registered" branch through its "no hash-validated LKG present" sub-path.

The v45 destructive-path VM test remains the recommended next step before broad rollout under v47, followed by a canary on a machine with an OEM driver pack so the strip-and-reinject loop runs against a non-empty set. See [testing.md](testing.md) for the test plan.

**v48 patch 1 coverage.** The intervening-anchor happy path is field-verified on the AMD Ryzen 7 5825U machine that motivated it (2026-10-06), on the exact `C: | D: | Recovery` layout. The anchor shrank by 200 MiB, the recovery partition was recreated at the planned offset, and the whole-layout assertion passed against the shrunk anchor. The v48-specific destructive-adjacent paths that remain unexercised on any storage are: the intervening-anchor post-deletion failure behaviour (the same class of residual documented for the non-intervening path); the v48 multi-intervening rejection; the v48 surplus rejection; the transactional WIM replacement's rollback branch; and the architecture gate on ARM64 hardware. The remaining v47 gaps also stand, per the list above.

**v49 coverage.** The v49 release adds four pipeline refinements — a startup refusal and three pre-deployment gates — but does not change the destructive resize sequence itself. The source-ownership classification's `Foreign-No-Drivers` and `Foreign-With-Drivers` branches have been exercised on physical hardware (see below); the never-downgrade storage-driver check and the pre-deployment storage-applicability gate have not fired in the field, and the native-boot VHDX gate has not been exercised on VHDX-boot hardware.

- **The native-boot VHDX fail-closed gate.** Unexercised on VHDX-boot hardware. The gate is a startup refusal that fires before any partition or WinRE change. A live run on a VHDX-boot host should exit `EXIT_WARNING` with the topology-named refusal; a live run on a physical or pass-through volume should proceed unchanged. The gate has no `-DryRun` carve-out.
- **The source-ownership classification.** Exercised on physical hardware in its `Foreign-No-Drivers` branch (repeatedly, across the v49 development cycle) and in its `Foreign-With-Drivers` preserve branch on a real machine carrying a third-party driver (ASUS Zenbook 14 UX3405MA, 2026-10-09 — the machine preserved the source, recorded `ForeignSourceAcceptedHash`, and took the fast path on the subsequent run). The classification runs before the strip stage; its decision determines whether the strip-and-reinject pipeline runs at all. The full four-class test plan is documented in [testing.md](testing.md): prepare four VMs, one for each ownership class, and confirm the classification decision matches the expected class. A `Foreign-With-Drivers` source is preserved as-is: the mounted image is dismounted with `-Discard`, no WIM is exported or deployed, the state file records `ForeignSourceAcceptedHash`, and the run exits `EXIT_WARNING`.
- **The never-downgrade storage-driver check.** Unexercised in the field. The check runs after injection is confirmed complete, before ResetBase and before the applicability gate. The test shape: a VM whose registered WinRE carries a version N storage driver, and a candidate package that resolves to version N-1 of the same driver. Confirm the whole candidate is discarded — dismounted with `-Discard`, the source preserved, the state file records `ForeignSourceAcceptedHash`, and the run exits `EXIT_WARNING`.
- **The pre-deployment storage-applicability gate.** Unexercised in the field — it has never fired. The gate runs inside Step 3, after injection is confirmed complete and after the never-downgrade check, before ResetBase and before the dismount. It is the last refusal before the candidate is committed by the dismount and the pipeline advances to the deploy stage. The test shape is documented in [testing.md](testing.md). A machine on which any one present SCSIAdapter-class device has no INF in the candidate that matches its `HardwareID` or `CompatibleID` has the mounted image dismounted with `-Discard` and defers with `EXIT_WARNING` rather than deploying an unusable image.

The destructive resize sequence itself — the geometry plan, the pre-shrink, the deletion loop, the extension fallback, the whole-layout assertion, and the delete-active-last ordering — is unchanged by v49. The v45/v46/v47/v48 coverage gaps listed above continue to apply to the v49 pipeline.

## Related documents

- [architecture.md](architecture.md) — where the partition lifecycle fits in the pipeline, the invariants list, and the wrong-question narrative.
- [state-and-idempotency.md](state-and-idempotency.md) — how `GeometryRestoreFailed` and the deferral marker interact with the state file, and the v49 recipe refinements that the `ScriptVersion` bump converges the fleet onto.
- [troubleshooting.md](troubleshooting.md) — the recovery procedure if the partition is lost, the reason-by-reason resolution for each pre-shrink deferral, and the v49 gate refusals.
- [driver-injection.md](driver-injection.md) — what happens before the partition work, including the v47 patch 1 strip stage, the three-source base-WIM selection, and the v49 source-ownership classification, never-downgrade check, and pre-deployment storage-applicability gate.
- [exit-codes.md](exit-codes.md) — the full list of exit paths, including the v45 pre-shrink deferral and its sub-reasons, the v47 patch 1 race-detector abort, and the v49 startup refusal for the native-boot VHDX topology.
