# Changelog

All notable user-facing changes to WinRE Manager are documented here.

This file is the authoritative user-facing record of what changed and when. The production script's `.NOTES` block records the current design invariants and the CRITICAL LESSONS LEARNED list; it is not a history. Together the two are the complete record. The current state of the project — shipping versions and open limitations — is summarized at the top; the release entries below are the historical record.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to a `ScriptVersion` + patch-generation scheme rather than strict SemVer — see [docs/state-and-idempotency.md](docs/state-and-idempotency.md) for why.

## Current status

**Production:** `WinRE.ps1` **v46 patch 2** (`ScriptVersion = 46`).
**Harness:** `Test-WinRE.ps1` **v22**.

The harness has no `ScriptVersion` and no `DesiredStateId` of its own; its version is its own marker. Production and harness are deliberately decoupled: a harness move never forces a managed-machine rebuild.

### Current known limitations

These are the limitations that are still live in the shipping code. Each is documented in full in the release entry that introduced it; the entry is linked.

1. **Post-deletion create/format failure on encrypted C:.** On a machine whose C: is encrypted, a failure of `New-Partition` or `Format-Volume` **after** the old recovery partition has been deleted, with no successful retry, can leave the machine with neither a dedicated recovery partition nor OS-fallback. The correct fix is a post-failure check in the post-deletion segment of `Ensure-AdequateRecoveryPartition`; it is gated on the deliberate post-deletion failure test documented in `docs/testing.md`. See [v45 patch 1](#v45-patch-1--2026-10-01), and the narrowing that superseded the original scope in [v44 patch 7](#v44-patch-7--2026-10-01).

2. **Offline-fallback DSI trust.** When the driver manifest fetch fails after its retry budget, the script trusts the state file's stored `DesiredStateId` without recomputing it from the machine's current hardware. A machine whose hardware changed while offline could take the fast path with a stale DSI. A `LocalInputsId` field would close this and is planned as its own version boundary. See [v44 patch 5](#v44-patch-5--2026-09-30).

3. **Unverified v45 failure paths.** The v45 destructive path's happy case (plan → pre-shrink → delete → create → layout assertion → deploy → enable) is verified end-to-end on a VM and on physical hardware. The whole-layout assertion path has now been exercised in the field — see [v46 patch 1](#v46-patch-1--2026-10-02) — and it correctly caught the plan-clamp bug that this cycle fixes. The remaining failure branches (extension fallback, deferral returns, the fail-closed C: read refuse branch, shrink retries 2–3, the MBR destructive path, and the post-deletion corner above) remain covered only by parser and mocked-geometry tests. See [v45 patch 1](#v45-patch-1--2026-10-01).

### Resolved limitations

These limitations were documented in a release entry and have since been closed. Each entry retains its original "Known limitations" paragraph, annotated with a resolution tag, for historical accuracy.

| Limitation | Documented | Resolved |
|---|---|---|
| Shrink-failure-then-OS-fallback on encrypted C: | [v44 patch 7](#v44-patch-7--2026-10-01) | [v45 patch 1](#v45-patch-1--2026-10-01) — shrink-first reorder |
| 2 GiB recovery-partition ceiling not enforced | [v44 patch 2](#v44-patch-2--2026-09-30) | [v45 patch 1](#v45-patch-1--2026-10-01) — `$MaxManagedRecoveryPartitionMiB = 2048` gates all three functions |
| Label-only recovery partitions misclassified | [v44 patch 7](#v44-patch-7--2026-10-01) | [v44 patch 7](#v44-patch-7--2026-10-01) — type-coded authority rule |
| Concurrent-instance race on `C:\Temp\WinREWork` | [v44 patch 4](#v44-patch-4--2026-09-30) | [v44 patch 4](#v44-patch-4--2026-09-30) — program lock |

### Active gates

- **Post-deletion segment of `Ensure-AdequateRecoveryPartition`.** Changes to the `New-Partition`, `Format-Volume`, `Set-RecoveryPartitionAttributes`, and drive-letter-assignment steps and their failure paths are gated on the deliberate post-deletion failure test running and its result being recorded. See [CONTRIBUTING.md](CONTRIBUTING.md) for the scope of the gate.
- **Pre-shrink segment (plan, pre-shrink, verification, deferral) is not gated.** The v45 reorder placed the risky step in the reversible window, which closes the v44 residual for the shrink case.

---

## [v46 patch 2] — 2026-10-02

Build-drift observability, a read guard in `Get-RecoveryPartitions`, and four post-review hardenings of `Ensure-AdequateRecoveryPartition`. `ScriptVersion` remains 46; `ScriptPatchLevel` moves from 1 to 2. No `DesiredStateId` change; no fleet-wide rebuild is forced.

The change adds three log lines that together record the build numbers of the recovery image the machine is running, the source WIM the plan is about to work against, and the WIM that was actually deployed. The purpose is empirical, not behavioural: over time the fleet logs answer whether Windows Update is updating the registered WinRE between our runs, and whether our rebuilds ever replace a newer registered image with an older one. No gate reads these values.

### Fixed

- **Extension-failure fallback is capped at the bucket size.** When C: extension fails after the old recovery partitions have been deleted, the safe fallback now creates only the planned bucket size at the current aligned C: end and logs the residual space between the new partition's end and the aligned managed-extent end as an intentional trailing unallocated extent. The previous code assigned the entire remaining extent — from the current C: end to the aligned managed-extent end — to the replacement partition, which on a layout with a large surplus could exceed the 2 GiB managed-recovery ceiling. The cap enforces the same policy the rest of the script follows. Exact-fit geometry remains the goal when the extension succeeds.
- **`Assert-RecoveryPartitionLayout` fails closed when the OS partition cannot be resolved.** The C: adjacency check previously skipped silently when its own `Get-OSPartition` query returned nothing. The assertion is the last check before `Format-Volume`; a layout that cannot be verified against C: is now rejected rather than accepted.
- **The destructive sequence fails closed before deletion when the active WinRE route cannot be resolved.** `Ensure-AdequateRecoveryPartition` now returns `Deferred` with `Reason = "active WinRE location could not be resolved"` when `$stateBefore.Status -eq "Enabled"` but `Resolve-WinRELocationToPartition` returns nothing for the registered location. Delete-last ordering and route restoration both depend on knowing which partition is active; without it, the deletion loop would place every deletable partition in the early-deletion list and a mid-loop failure could leave the machine with no working recovery route.
- **Deletion-failure rollback reports partial outcomes honestly.** The recovery-partition deletion-failure branch now captures the `Restore-OSPartitionSize` result and the `Restore-PreviousWinRERoute` result separately. When the route is restored but C: could not be verified at its original size, the function returns `Deferred` with the distinct reason `"recovery partition deletion failed; previous route restored but C: geometry restore unverified"` and sets `$Script:GeometryRestoreFailed`, so the state file is invalidated and the next run retries from clean. The previous code discarded the size-restoration result and could report "previous route restored" while C: remained shrunken.

### Changed

- **Registered WinRE version logged at startup.** `Get-WinREState` now extracts `Windows RE Version` from `reagentc /info` and returns it as `Version`. The startup line reads `WinRE status: <status>, Location: <location>, Version: <version>`. The version line is absent when WinRE is Disabled or reagentc suppresses it; the log shows `unknown` in that case. Informational only — the value does not enter `DesiredStateId` and no gate reads it.
- **Source WIM build logged during force-upgrade detection.** When a candidate WIM is evaluated, its build is logged as `Source WIM build: <build> (path: <path>)`. If `Get-WimBuild` cannot read the image, the line reads `Source WIM build: unknown (path: <path>)` at WARN. This runs on every pass — full-update and fast-path — so every run records the WIM it considered.
- **Post-deploy WIM build logged before the state write.** After a successful deployment and before the state file is written, the build of the deployed WIM is logged as `Post-deploy WIM build: <build> (source: <path>)`. Combined with the startup line, this records both sides of any build drift on the same run.
- **`.NOTES` design invariants updated.** The design-invariants block now carries:
  - *"Build-drift observability: every run logs the registered WinRE version (pre-touch, from reagentc), the source WIM build, and the post-deploy WIM build. Logged for evidence only; no gate reads these values and none enters DesiredStateId."*
  - The 2 GiB ceiling bullet now records that the post-delete extension-failure fallback preserves the ceiling by sizing the replacement partition to the planned bucket rather than to the full remaining extent, and logs any trailing unallocated extent explicitly.
  - *"The destructive sequence fails closed before deletion if the active WinRE route is Enabled but its registered location cannot be resolved to a partition. Delete-last ordering and route restoration both depend on identifying the active target; without it, no partition is protected and a mid-loop failure could leave the machine with no working recovery route."*
  - *"The whole-layout assertion fails closed when the OS partition cannot be resolved, rather than skipping the C: adjacency check. A layout that cannot be verified against C: is not accepted; the assertion is the last check before Format-Volume."*
- **`Get-RecoveryPartitions` guards against empty-disk reads.** Both `Get-Partition -DiskNumber $diskNum` calls now carry `-ErrorAction SilentlyContinue`. On a machine with a disk that exposes no partitions — an SD/MMC card reader, an empty USB enclosure, a disk with no recognised partition table — `Get-Partition -DiskNumber N` throws `CmdletizationQuery_NotFound_DiskNumber`. The error is non-terminating at the current call sites but pollutes the log on every full update and would abort a caller wrapped in `-ErrorAction Stop`. Guarded in both `WinRE.ps1` and `Test-WinRE.ps1`.

### Changed (harness)

- **`Test-WinRE.ps1` moved to v22.** Three changes, all downstream of this cycle.

  - **Mirror of production's `Get-WinREState` version parsing.** The harness's parsed-state block now reports `Version` alongside `Status` and `Location`, and the Option 1 diagnostic renders a new "Build numbers" section showing registered WinRE, active WIM build, and (when present) the `C:\Recovery\WindowsRE\winre.wim` backup build.
  - **New parser self-test check for the version regex.** `Parser: reagentc version` reports `[OK]` when the version line matches, `[FAIL]` when WinRE is Enabled and the line is missing, and `[SKIP]` when WinRE is Disabled or reagentc suppressed the line. The self-test total moves from 15 to 16.
  - **`$ProductionScriptVersion` default bumped 45 → 46.** The harness's `Get-DesiredStateId` mirror carries this default to track production's `$ScriptVersion`. Left at 45 it would report a false `DSI MISMATCH` for every state file v46 production writes, exactly the drift v21 corrected the 44 → 45 case for.

### Migration Note

`ScriptVersion` is unchanged at 46, so the `SCRIPT` component of `DesiredStateId` is unchanged and no machine rebuilds on this patch. `ScriptPatchLevel` moves from 1 to 2, visible in the startup banner (`WinRE Manager Started (v46 patch 2)`) and in the harness menu (`WinRE Manager Test Harness (v22)`). A machine already on v46 patch 1 continues on the fast path; the only behavioural change is the three new log lines and the guarded read in `Get-RecoveryPartitions`.

### Field verification

- **HP EliteBook 8 G1i 16 inch Notebook AI PC (MT SBKP, Core Ultra 5 235U, Win 11 26300, 237 GiB C:), 2026-10-02 15:22–15:26.** First v46 patch 2 run on physical hardware, and the machine whose SD/MMC card reader surfaced the `CmdletizationQuery_NotFound_DiskNumber` read error under the pre-fix build. Two-run sequence: full update at 15:22 (DSI `20DF9C9A…`, `WinRE ... Version: 10.0.26100.9545`, `Source WIM build: 26100`, old 1000 MiB recovery partition short of the 1191 MiB required, plan `recovery reclaim 1000 MiB, shrink 201 MiB, bucket 1200 MiB, planned offset 242997 MiB`, shrink 242809 → 242608 MiB verified, `New-Partition` and `Assert-RecoveryPartitionLayout` both passed with the partition end exactly 1 MiB inside the disk end, 911.95 MiB WIM deployed with SHA256 verified, `reagentc /setreimage` and `/enable` both exit 0, `Post-deploy WIM build: 26100`, `Operating mode: DEDICATED`), then fast path at 15:26 (state file accepted, no rebuild, `Operating mode: DEDICATED`). All three build-logging lines fired on the full-update run; the two upstream lines fired on the fast-path run as well. The SD/MMC card reader (disk 1, no MSFT_Partition objects) was present and `Get-RecoveryPartitions` completed without a throw. The corresponding harness v22 diagnostics on the same machine returned `Passed 16, failed 0, skipped 0 (of 16)` before and after the production run; the "Build numbers" section correctly showed the backup WIM as absent before the run and `26100` after.

### Known limitations

The three live limitations carried by the project are unchanged in this patch:

- **Post-deletion create/format failure on encrypted C: (still open).** A `New-Partition` or `Format-Volume` failure **after** the old recovery partition has been deleted, on encrypted C:, with no successful retry. Gated on the deliberate post-deletion failure test in `docs/testing.md`. Full text under [Current known limitations](#current-known-limitations) item 1.
- **Offline-fallback DSI trust (still open).** When the manifest fetch fails after its retry budget, the script trusts the state file's stored `DesiredStateId` without recomputing it. A `LocalInputsId` field would close the residual hardware-drift risk and is planned as its own version boundary. Full text under [Current known limitations](#current-known-limitations) item 2.
- **Unverified v45 failure paths (still open).** The whole-layout assertion path is now field-verified; the remaining failure branches (extension fallback, deferral returns, the fail-closed C: read refuse branch, shrink retries 2–3, the MBR destructive path, and the post-deletion corner above) are covered only by parser and mocked-geometry tests. Full text under [Current known limitations](#current-known-limitations) item 3.

### Unchanged

`ScriptVersion` remains 46. `DesiredStateId` is unchanged. No fleet-wide rebuild is forced. Healthy machines continue to take the fast path. No change to the deployed WIM, the driver-selection inputs, or the OEM-provider resolution. The partition-plan geometry on the successful path is unchanged; the four `Fixed` entries above tighten behaviour in the extension-failure fallback, the whole-layout assertion, the pre-deletion guard, and the deletion-failure rollback. None of those paths is exercised on a healthy machine.

### Field-testing status of the v46 patch 2 fixes

The build-drift log lines and the `Get-RecoveryPartitions` read guard are field-verified on the HP EliteBook 8 G1i 16" run recorded above. The four `Fixed` entries are code-review hardenings, not field-exercised changes: they apply to the extension-failure fallback, the whole-layout assertion's fail-closed path, the pre-deletion resolver-guard, and the deletion-failure rollback, none of which was reached on that run. They are covered by inspection and by the mocked-geometry test plan in `docs/testing.md`, and remain gated on the same tests that gate the post-deletion segment.

---

## [v46 patch 1] — 2026-10-02

Plan-clamp fix in `Get-PartitionPlan`. `ScriptVersion` moves from 45 to 46; every managed machine performs one full-update pass on its next scheduled run, then returns to the fast path.

The change was driven by the first v45 destructive-path failure on physical hardware — a Lenovo IdeaPad 3 15IAU7 whose factory layout placed a partition exactly 1 MiB past the disk-end reserve. The plan's `tailEnd` was not clamped against the reserve before aligning, so the aligned managed extent end landed 1 MiB past the reserve, the post-delete geometry check correctly rejected the plan, and the machine fell into OS-fallback with a matching `DesiredStateId` — and stayed there until an operator manually deleted the state file. The fix clamps `tailEnd` to `diskSize − 1 MiB` before aligning, on both branches of the plan.

### Fixed

- **`Get-PartitionPlan` clamps `tailEnd` to `diskSize − 1 MiB` before aligning, on both branches.** `$usableEnd` is `$diskSize − 1 MiB`. The blocking-partition branch now takes `[Math]::Min([int64]$blockingPartition.Offset, $usableEnd)` instead of the partition's offset alone; the no-blocking-partition branch takes `$usableEnd` directly. The clamp runs before `$alignedManagedExtentEnd = Floor($tailEnd / 1 MiB) × 1 MiB`, so no partition — blocking or reclaimable — can push the aligned boundary past the reserve. A factory partition ending exactly 1 MiB past the reserve no longer produces a plan the post-delete geometry check always rejects.

### Changed

- **`.NOTES` design invariant updated.** The geometry-planning bullet now carries: *"The plan clamps the usable extent end to diskSize − 1 MiB before aligning, so no partition (blocking or reclaimable) can push the aligned boundary past the disk-end reserve."*
- **`.NOTES` critical lesson updated.** The recovery-offsets-round-up bullet now names the clamp explicitly: *"Clamp the usable extent to diskSize − 1 MiB before aligning: a factory partition that ends 1 MiB past the reserve would otherwise push the aligned boundary past the reserve and the post-delete geometry check would reject the plan."*

### Migration Note

`ScriptVersion` moves from 45 to 46, so the `SCRIPT` component of `DesiredStateId` changes. Every managed machine performs one full-update pass on its next scheduled run, then returns to the fast path. No driver-manifest, OEM-map, or driver-selection inputs changed. The DSI bump is intentional: it is the version boundary that clears the OS-fallback state on machines that v45 patch 1 left in the failing branch. A machine whose state file records `OS-fallback` under a v45 `DesiredStateId` sees the state file rejected as stale on its next run, takes the full-update path, and rebuilds — the tailEnd clamp makes the plan valid on the same layout v45 rejected. A machine already on a healthy dedicated-partition route under v45 patch 1 rebuilds once and converges normally.

### Field verification

- **Lenovo IdeaPad 3 15IAU7 (MT 82RK, Win 11 build 26200, Samsung SSD 980 500GB, GPT), 2026-10-02.** The motivating failure under v45 patch 1. A factory-provided partition ended exactly 1 MiB past the disk-end reserve. `Get-PartitionPlan` computed `tailEnd` from that partition's offset without clamping to the reserve; `$alignedManagedExtentEnd` landed 1 MiB past `$diskSizeNow − 1 MiB`; the post-delete geometry check (`$plannedEnd -gt ($diskSizeNow - 1MB)`) correctly rejected the plan. The machine fell into OS-fallback with a state file that matched the failing `DesiredStateId`, so subsequent scheduled runs accepted the state and did not retry — the machine stayed in OS-fallback until an operator manually deleted the state file. Under v46 patch 1, the clamp makes the plan valid on the same layout; the second full-update run (after the manual state-file reset) took the dedicated-partition path and reached `Operating mode: DEDICATED`. This is the first v45 destructive-path failure on physical hardware.
- **Dell Latitude 3540 (Win 11 build 26300, PM9B1 NVMe, GPT), 2026-10-02 14:48–14:53.** Clean-path verification of v46 patch 1 on Dell hardware. Two-run sequence: full update at 14:48 (DSI `4D89C1FD…`, old 1000 MiB recovery partition short of the 1039 MiB required, plan `recovery reclaim 1000 MiB, shrink 101 MiB, bucket 1100 MiB, planned offset 487285 MiB, alignment reserve 344 KiB`, shrink 486997 → 486896 MiB verified, `New-Partition` and `Assert-RecoveryPartitionLayout` both passed, 789.4 MiB WIM deployed with SHA256 verified, `reagentc /setreimage` and `/enable` both exit 0, `Operating mode: DEDICATED`), then fast path at 14:53 (same DSI, state file accepted, no rebuild). `Add-WindowsDriver`'s return-shape filter returned 0 added drivers while the delta/matched-INF gate correctly judged success (64 delta, 49 of 49 INF matches). C: was `EncryptionInProgress` at 90% with `ProtectionStatus=Off`; the dedicated path proceeded, confirming again that C: encryption is not a veto for that path.
- **HP EliteBook 6 G1i 16 inch Notebook AI PC (MT SBKP, Core Ultra 7 255U, Win 11 26300, GPT), 2026-10-02 14:57–15:01.** Second clean-path verification of v46 patch 1 on a different vendor. Two-run sequence: full update at 14:57 (DSI `4EDB8635…`, WIM grew from 763.2 MiB pre-injection to 911.3 MiB post-injection, bucket 1200 MiB, plan `recovery reclaim 1000 MiB, shrink 201 MiB, planned offset 487185 MiB`, shrink 486997 → 486796 MiB verified, `Assert-RecoveryPartitionLayout` passed with the partition end exactly 1 MiB inside the disk end, `Operating mode: DEDICATED`), then fast path at 15:00. Incidental confirmations: the HP SoftPaq extractor returned exit code 1168 but produced 195 INFs — the INF-count gate correctly treated the extraction as a success; the Core Ultra 7 255U parsed to Intel generation 15 via the seriesMap branch, first field exercise of that branch; HP machine type `SBKP` was extracted from `Product Version`.

### Known limitations

**Post-deletion create/format failure on encrypted C: (still open).** The v45 patch 1 residual corner — a `New-Partition` or `Format-Volume` failure **after** the old recovery partition has been deleted, on encrypted C:, with no successful retry — is not touched by this patch. It remains gated on the deliberate post-deletion failure test in `docs/testing.md`. See [v45 patch 1](#v45-patch-1--2026-10-01) for the current scope and the narrowing that superseded the v44 residual.

### Unchanged

No change to the deployed WIM, the driver-selection inputs, the OEM-provider resolution, the workspace selection policy, or the post-deletion segment of `Ensure-AdequateRecoveryPartition`. The clamp is confined to `Get-PartitionPlan`.

---

## [v45 patch 1] — 2026-10-01

Shrink-first redesign of `Ensure-AdequateRecoveryPartition` with a read-only geometry plan, single-boundary exact partition placement, capacity-aware internal workspace selection, a deferral sidecar that suppresses identical retries only while the previous route is verified functional, and a post-creation whole-layout assertion. `ScriptVersion` moves from 44 to 45; every managed machine performs one full-update pass on its next scheduled run, then returns to the fast path.

The change was driven by the v44 patch 7 residual: a shrink failure after the old recovery partition had already been deleted, on an encrypted-C: machine, left the machine with neither a dedicated recovery partition nor OS-fallback. The v44 pipeline did the destructive part (delete → extend → shrink → create) in the wrong order; a failed shrink left the old recovery partition already gone, and OS-fallback is unavailable on encrypted C:. The v45 pipeline runs the risky step (the shrink) in the reversible window, before any partition is destroyed. A failed pre-shrink leaves the machine untouched; the old route remains registered and functional, and a sidecar marker suppresses identical retries until the underlying constraint is resolved.

### Changed

- **Shrink-first replacement (the headline).** The pre-shrink now runs in the reversible window, before `reagentc /disable` and before any partition deletion. A failed pre-shrink returns `Deferred` with the old route intact. This closes the v44 residual for the shrink case.
- **Single-boundary exact geometry.** `Get-PartitionPlan` computes a target boundary rather than a shrink amount. The aligned managed extent end is `floor(tailEnd / 1 MiB) × 1 MiB`; the recovery partition occupies the last `bucketSize` bytes up to that boundary; C: is resized so it ends exactly where the recovery partition begins. The trailing gap left by the previous deficit-plus-slack model is eliminated. Bytes between the raw extent end and the aligned end are logged explicitly as an alignment reserve, not treated as a defect.
- **Post-delete extension when the plan calls for it.** When the plan requires C: to grow into space the old recovery partitions occupied, `Invoke-OSPartitionExtend` runs **after** the deletions, with 3 retries at 5-second intervals. On failure, the safe fallback places the recovery partition at the current (un-extended) C: end, filling to `AlignedManagedExtentEnd`; a non-fatal warning is set and the run continues with WinRE deployable. Exact geometry is a goal, not a reason to leave WinRE disabled.
- **Post-creation whole-layout assertion.** `Assert-RecoveryPartitionLayout` re-queries the newly created partition immediately after `New-Partition` and confirms identity, exact offset, size within one alignment block of the plan, no overlap with the OS partition, the C:-to-recovery gap within one alignment block, and the partition end at `AlignedManagedExtentEnd`. On failure the script calls `Remove-OrphanPartition` and returns `$null`, matching the existing `Format-Volume`-failure recovery shape.
- **Fail-closed pre-shrink C: free-space check.** The pre-shrink free-space verification refuses to shrink C: when `Get-Volume -DriveLetter C` returns nothing, deferring with a distinct reason (`"C: volume could not be read for free-space check"`) and `RetrySuppressible = $false`. The measured "post-shrink free space below minimum" case remains `RetrySuppressible = $true`; only the volume-read-failure case is not retry-suppressed, because an indeterminate read may clear on its own.
- **Route restoration on deletion failure.** When a recovery-partition deletion fails after WinRE has already been disabled, the script attempts `Restore-PreviousWinRERoute` before returning. If the previous route is restored, the run returns a `Deferred` result; if not, `$null` as before.
- **Delete-active-last ordering.** The currently active recovery partition (resolved from `$stateBefore.Location`) is deleted last, so a mid-loop failure leaves the previous route's target available for restoration.
- **Route-identity check in `Restore-PreviousWinRERoute`.** The function now confirms the now-Enabled WinRE `Location` matches the previous route before reporting success, using a string comparison with a disk/partition identity fallback for the GLOBALROOT-vs-Volume-GUID form reagentc may report after a disable/enable cycle. A machine whose WinRE is Enabled but registered to a different location is not treated as "restored".
- **Plan-before-change contract.** The destructive pipeline is gated behind a read-only plan that validates: no cross-disk entries, no OS-partition overlap, no recovery-typed partitions exceeding the 2 GiB ceiling, no recovery-typed partitions preceding C:, non-contiguous recovery partitions, and insufficient contiguous space after the planned resize. An invalid plan returns `Deferred` with no partition or WinRE change.
- **Capacity-aware internal workspace.** `Get-WorkDirCandidates` restricts to fixed NTFS volumes on an allowlisted set of internal/virtual buses (ATA, SATA, NVMe, RAID, SAS, Spaces, Virtual, File Backed Virtual, SCM). USB, SD/MMC, network, FireWire, Fibre Channel, unknown buses, and reparse-point workspace paths are excluded. Fresh runs prefer the non-OS volume with the most space. Admission is `$MinFreeSpaceGB` (3 GiB) for a fresh service, or `$WorkDirResumeMinFreeMB` (200 MiB) when a verified `WIM_READY` checkpoint exists in the recorded workspace.
- **Checkpoint format extension with `WIM_READY`.** The checkpoint format is `Step|DesiredStateId|WorkDir|WIM_READY`. The flag is set at Step 4 after a verified `dism /Export-Image`. `base.wim` is deleted at that point to reclaim workspace capacity before partition planning. Legacy two- and three-field checkpoints remain readable; a Step 4 checkpoint without the ready flag conservatively reruns injection.
- **Workspace and checkpoint preservation on the retry-suppressed skip path.** The sidecar deferral does not clean up the staged workspace or checkpoint. If the machine's inputs have not changed and the previous route is still functional, the staged optimized WIM remains available for the eventual successful run. The marker alone suppresses identical retries.
- **Marker obsolescence on fast-path convergence.** The deferral-skip path computes `$fastPathWillFire` before deciding whether to honor the marker. If the machine has converged on its own — one type-coded recovery partition on the OS disk, no rebuild required, WinRE Enabled — the marker is cleared and the run falls through to the fast path, exiting `EXIT_SUCCESS` rather than being pinned at `EXIT_WARNING`.
- **2 GiB recovery-partition ceiling implemented.** `$MaxManagedRecoveryPartitionMiB = 2048` is now enforced in `Find-SuitableRecoveryPartition`, `Remove-StrayRecoveryPartitions`, and `Get-PartitionPlan`. This closes the v44 "Known gaps" entries from [v44 patch 2](#v44-patch-2--2026-09-30), [v44 patch 3](#v44-patch-3--2026-09-30), and [v44 patch 6](#v44-patch-6--2026-09-30).
- **`Restore-OSPartitionSize` accepts `-TargetSizeBytes`.** The old "extend to `SizeMax`" behavior is gone for recovery calls; the exact pre-attempt C: size is restored on failure. The parameterless call falls back to `SizeMax` only for legacy call sites.

### Migration Note

`ScriptVersion` moves from 44 to 45, so the `SCRIPT` component of `DesiredStateId` changes. Every managed machine performs one full-update pass on its next scheduled run, then returns to the fast path. No driver-manifest, OEM-map, or driver-selection inputs changed. The DSI bump is intentional: it is the version boundary that ensures the new shrink-first code path is exercised on every machine. Rollback by redeploying v44 causes another DSI mismatch and one full update under the older behavior; do not manually edit the stored `DesiredStateId`.

A machine with a deferral marker written by a v45 run is unaffected by the DSI change: the marker is keyed to the same `DesiredStateId` the current run computes, so it is honored on subsequent v45 runs and cleared automatically if the machine has converged. A machine with a marker written by a v44 run under the same `DesiredStateId` (which cannot happen because the DSI includes `SCRIPT`) would be cleared on first read.

### Field verification

- **ASUS PRIME H510M-D (i5-11400, Win 11), 2026-10-01 23:48–23:51.** Clean v45 patch 1 run on the full-update path, followed by a fast-path run three minutes later. Workspace selection chose a non-OS internal volume with 134.53 GiB free. The existing 1000 MiB recovery partition was reused (`effective free 1082.2 MiB vs 1007 MiB required`); no destructive work. WIM serviced (Steps 2–3), ResetBase ran (~28s), optimized WIM 756.72 MiB. `WIM_READY` checkpointed; `base.wim` removed after verified export. State file written with `UsedOSFallback = $false`; `Operating mode: DEDICATED`. Second run took the fast path.
- **ASUS PRIME H510M-D (i5-11400, Win 11), 2026-10-02 08:50.** Two consecutive fast-path runs on the same machine. Both runs: state file accepted (`DesiredStateId` match), `Operating mode: DEDICATED`, no machine changes, no leaked drive letters. Confirms the machine has converged on the v45 state and the fast path remains stable across consecutive invocations.
- **Hyper-V VM (Windows 11 Pro, build 26300, i5-11400, GPT), 2026-10-02 08:56–08:58.** First exercise of the v45 destructive path end-to-end. The machine was provisioned with a 896 MiB unlabeled recovery-typed partition, below the 1006 MiB required for the 756.07 MiB optimized WIM, forcing the rebuild path. `Find-SuitableRecoveryPartition` correctly rejected the undersized candidate. `Get-PartitionPlan` logged `recovery reclaim 896 MiB, contiguous free 1 MiB, shrink 203 MiB, extend 0 MiB, bucket 1100 MiB, planned offset 128947 MiB, alignment reserve 0 KiB`. The pre-shrink free-space check passed (96.53 GiB free, projected 96.33 GiB, minimum 3 GiB). `Invoke-OSPartitionShrink` succeeded on attempt 1 (128761 MiB → 128558 MiB); `Assert-PartitionSizeAfterResize` verified. `reagentc /disable` exited 0 and verified. The active partition was deferred to last in the delete loop. `New-Partition` succeeded with the recovery GUID applied at creation; `Assert-RecoveryPartitionLayout` passed exactly (`disk 0 partition 4, offset 128947 MiB, size 1100 MiB`). The new partition was confirmed not encrypted; the WIM copy verified SHA256; `reagentc /setreimage` and `/enable` both exited 0 on the first attempt; `Operating mode: DEDICATED`. A second run at 08:58 took the fast path. This run exercised the pre-shrink pass path, shrink attempt 1, delete-active-last ordering (trivially, one deletable partition), the whole-layout assertion, and create-with-type-at-creation.
- **Hyper-V VM (Windows 10 Pro, build 19045, i5-11400, MBR), 2026-10-02 09:41–09:43.** First MBR machine and first Win10 field data for v45. The machine was provisioned with a 1000 MiB type-coded recovery partition carrying sufficient effective free space, so the run took the reuse path: `Find-SuitableRecoveryPartition` accepted candidate 3 (980.1 MiB effective free against 744 MiB required). `Set-RecoveryPartitionAttributes` applied `set id=27` on the existing MBR partition. `reagentc /setreimage` and `/enable` both exited 0 on the first attempt; `Operating mode: DEDICATED`. A second run at 09:43 took the fast path. The MBR destructive path (`New-Partition -MbrType 0x27`) did not run, because the reuse path was taken.
- **Hyper-V VM (Windows 10 Pro, build 19045, i5-11400, MBR), 2026-10-02 09:47 — concurrent-instance test.** A second interactive invocation of `WinRE.ps1` was started while a first instance was mid-flight. The second instance logged `Another WinRE Manager instance is already running (program lock file is exclusively held)` and exited within seconds without performing any work; the first instance completed its fast-path run normally and released the program lock at 09:47:35. First field exercise of the [v44 patch 4](#v44-patch-4--2026-09-30) program-lock contention path.

### Field gap (code paths not yet exercised)

The 2026-10-02 VM runs exercised the happy path of the destructive sequence end-to-end (plan → pre-shrink → delete → create → layout assertion → deploy → enable) and the MBR attribute-application path. The following code paths remain unexercised on any storage — physical or virtual:

- **The pre-shrink free-space refuse branch.** The pass path ran on the Win11 VM; the fail-closed `Get-Volume -DriveLetter C` failure branch and the projected-free-below-minimum branch did not.
- **`Invoke-OSPartitionShrink` attempts 2 and 3.** Attempt 1 succeeded on the Win11 VM; the sleep retry and the defrag retry were not reached.
- **`Invoke-OSPartitionExtend` and its safe fallback.** The plan computed `ExtendBytes = 0` on both VM runs, so the post-delete extension step did not execute.
- **The `Deferred` return paths from `Ensure-AdequateRecoveryPartition`.** No deferral occurred in either VM run.
- **Partition deferral marker write / skip / clear.** The marker was never written; the `Clear-PartitionDeferral` call on the success path is a no-op.
- **`Restore-PreviousWinRERoute` and `Test-WinRELocationMatches`.** Neither ran, because neither VM run had a failure to recover from.
- **The delete-active-last ordering against a multi-partition deletable set.** The Win11 VM had one deletable partition, so the ordering was satisfied trivially.
- **The MBR destructive path.** `New-Partition -MbrType 0x27` at a planned offset did not run — the Win10 MBR VM took the reuse path. The MBR attribute branch (`set id=27` on an existing partition) did run.
- **The program-lock crash-recovery path.** Contention was exercised on the Win10 MBR VM; a process killed mid-flight followed by a fresh run acquiring the lock immediately was not.

These are covered by parser and mocked-geometry tests. The VM test plan in [docs/testing.md](docs/testing.md) covers them; the deliberate post-deletion failure test is documented there and gates future changes to the post-deletion segment per [CONTRIBUTING.md](CONTRIBUTING.md).

### Known limitations

**Post-deletion create/format failure on encrypted C: (still open).** The v44 residual — a shrink failure after deletion on an encrypted-C: machine — is closed by the shrink-first reorder. The remaining corner is narrower: a failure of `New-Partition` or `Format-Volume` **after** the old recovery partition has been deleted, on encrypted C:, with no successful retry. The correct fix is a post-failure check in the **post-deletion segment** of `Ensure-AdequateRecoveryPartition` (the `New-Partition`, `Format-Volume`, `Set-RecoveryPartitionAttributes`, and drive-letter-assignment steps and their failure paths), not in the shrink-failure branch — the shrink is no longer inside the destructive window. The fix is tracked for a future patch and gated on the deliberate post-deletion failure test in `docs/testing.md`.

---

## [harness v21] — 2026-10-02

One correctness fix and one display addition in the read-only harness. Production `WinRE.ps1` is unaffected; this entry is the harness's own version marker.

### Fixed

- **DSI drift in `Get-DesiredStateId` produced false Option-S mismatches.** The harness's `Get-DesiredStateId` mirror carried `[int]$ProductionScriptVersion = 44`, while production v45 patch 1 ships `$ScriptVersion = 45`. Because the harness computes the same seven-field recipe production does, its default was one version behind, and every comparison against a v45-written state file returned `DSI MISMATCH — production will treat the state file as stale` for a state file that production would actually accept. The default is now `45`, and the parameter-header comment names the version boundary explicitly: this default must be bumped whenever production's `$ScriptVersion` is bumped, or every Option-S run against a freshly-updated machine reports a false mismatch. The harness's own parser self-test (Check 15) still deliberately passes 44 and 43 to prove version-sensitivity; those values are unchanged.

### Changed

- **`Show-StateFileParity` displays the state file's `RepairAttempts` field.** The v44 patch 6 state file carries `RepairAttempts` alongside `PendingReboot`, `LastEnableResult`, and `EnableFailureAttempts`; the harness's parity display previously listed the other three but not this one. Purely additive; no existing display line changed.

### Notes

- The harness's `[harness v19]` and `[harness v21]` entries exist because each was a standalone harness correction not tied to a production release. Harness v18 was folded into [v44 patch 6](#v44-patch-6--2026-09-30) and v20 into [v44 patch 7](#v44-patch-7--2026-10-01), because in both cases the harness move shipped in the same window as a production patch and the substantive change was a mirror of that patch's production behavior.

---

## [v44 patch 8] — 2026-10-01

### Changed

- **Workspace initialization follows route classification.** Healthy fast-path runs, enable-only repairs, and offline deferrals no longer validate checkpoints, wipe stale image scratch files, or create `WorkDir`. Full-update checkpoint and resume behavior was otherwise unchanged in this patch. `ScriptVersion` and `DesiredStateId` remained unchanged.

---

## [v44 patch 7] — 2026-10-01

Six patches closing a non-convergence loop in the recovery-partition classifier, a VMD extraction-directory cleanup, and a diagnostic-only logging change on the destructive path. `ScriptVersion` remains 44; `DesiredStateId` is unchanged; no fleet-wide rebuild is forced.

The change was driven by a review of the v44 patch 6 code in which ChatGPT identified a real non-convergence defect in the classifier and Claude identified a related narrowing of the destructive-path safety envelope. Both reviewers agreed the trade should not be resolved by reinstating the removed v44 patch 3 C: guard, and that the narrowed safety envelope needed to be documented honestly rather than papered over. The six patches reflect that conclusion.

### Fixed

- **Partition-classifier consistency (patches 1–4).** Only a **type-coded** recovery partition on the OS disk is now authoritative for reuse, fast-path counting, active-location classification, and final verification. A partition detected only by its Recovery/WINRE volume label is not promoted to DEDICATED, is not counted by the fast path, and is not reused by `Find-SuitableRecoveryPartition`.

  Closes a non-convergence loop. `Get-RecoveryPartitions` broad-matches by volume label **or** type code. `Ensure-AdequateRecoveryPartition` already filtered to type code before deleting — a label-only match is never authorized for deletion and the code comment said so — but the fast-path count and the reuse classifier still used the broad result. A Basic Data partition labelled "Recovery" was therefore counted by the fast path (`$existingRecoveryParts.Count` included it, so the "exactly one recovery partition on the OS disk" condition could never be satisfied) while being preserved by the destructive path (which correctly refused to delete it, because the label alone is not sufficient authority). The machine cycled through rebuilds indefinitely without converging.

  The four patches:

  1. **`Find-SuitableRecoveryPartition`** — filter candidates to type-coded recovery partitions only (`GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'` or `MbrType -eq 0x27`), before the size and free-space checks.
  2. **Main-flow `$existingRecoveryParts`** — count only type-coded recovery partitions on the OS disk, so the fast-path count agrees with what the destructive path is authorized to remove.
  3. **Active-location classifier** — do not promote a label-only match to DEDICATED. The classifier now distinguishes `$isTypedRecovery` from `$isLabelRecovery`; a label-only match on the OS disk logs a WARN and does not set `$activeOnRecovery`, so the natural rebuild path fires instead of the fast path accepting a route production will not maintain.
  4. **Final-verification classifier** — require type-coded **and** on-OS-disk for the DEDICATED verdict. A label-only match now falls through to the FATAL "unexpected partition" branch instead of being silently accepted as a healthy end state.

- **VMD extraction directory cleanup (patch 5).** Before each `7z x` invocation in the VMD driver injection loop, the extraction directory is now cleared and recreated (`Remove-ItemIfExist` followed by `New-DirectoryIfNotExists`). Closes a class of failure in which a stale INF from an earlier run could satisfy the INF-basename cross-reference or the third-party-driver-count delta and make a failed extraction look like a success. The Lenovo vendor-extractor path had a similar hazard, but the INF-count branch there is only reached after the extractor itself exits non-zero, which does not occur on the VMD `.7z` path.

### Changed

- **Destructive-replacement logging now reports C:'s actual encryption state (patch 6).** When the destructive path is about to run and the current WinRE route will be destroyed (`$stateBefore.Status -eq "Enabled"` or `$deletableParts.Count -gt 0`), the WARN now includes C:'s measured encryption state:
  - `Test-VolumeEncrypted -MountPoint "C:"` returns `$false` → INFO: `C: is confirmed fully decrypted; proceeding.`
  - returns `$true` → WARN: `C: encryption state=True; proceeding because C: encryption is not a veto for the dedicated-target path. The OS-fallback path retains its separate C: BitLocker gate.`
  - returns `$null` → WARN with `C: encryption state=unknown;` and the same rationale text.

  **Diagnostic only.** The decision to proceed is unchanged; no gate was reinstated. The purpose is to make the narrowed safety envelope visible in the log so an operator can recognize the residual failure mode described below.

### Changed (harness)

- **`Test-WinRE.ps1` moved to v20.** Two changes.

  The active-location classifier in `Show-SystemDiagnostic` now requires a **type-coded** recovery partition on the OS disk to reach the DEDICATED verdict, mirroring production's active-location classifier change (patch 3 of the v44 patch 7 cycle). The previous logic computed a single `$isRec` flag and fell back to a `Get-Volume -Partition` label check that promoted a label-only match to `$isRec = $true`. The classifier now computes `$isTypedRecovery` and `$isLabelRecovery` separately, and the branches report:
  - `OS-FALLBACK` — the WinRE location resolves to the OS partition.
  - `DEDICATED` — the location is both type-coded and on the OS disk.
  - `RECOVERY-ON-SECONDARY` — type-coded but on a non-OS disk (production forces a full rebuild).
  - `LABEL-ONLY` — on the OS disk with a Recovery/WINRE label but not type-coded (production does **not** treat as DEDICATED).
  - `UNEXPECTED` — otherwise.

  This closes a false-positive that could have misled an operator: pre-v20, a machine whose reagentc-registered WinRE location was a Basic Data partition labelled "Recovery" would have been reported as `DEDICATED` by the harness, while production would have taken the full-update path. Production's final-verification classifier (patch 4 of the v44 patch 7 cycle) has no direct harness equivalent and is not claimed; the harness classifies the reagentc-registered location, which is the active-location decision point, not the post-deploy verification decision point.

  The menu box alignment is also fixed. The menu's top border is 66 columns wide interior (plus the two `╔`/`╗` characters and two leading spaces). The title row was padded to 33 columns, the working-directory row to a length-relative value, and the detected row to 64 — none of which equals the interior width minus the leading space. All three rows now pad their content to exactly 65 columns with the working-directory and detected rows truncating at 65 with an ellipsis if content overflows. Purely cosmetic; no functional change.

### Changed (docs)

- **`docs/architecture.md`** — added Invariant 16 (only a type-coded recovery partition on the OS disk is authoritative). The Step 5 discussion now names the safety property's two ordinary cases (the destructive attempt succeeds, or it fails before deletion) and the one narrow corner where it does not hold, with a cross-reference to this entry and to `docs/testing.md`. The "shared shape" narrative adds the classifier as a sixth instance of the same wrong-question pattern. The fast-path and full-update entry conditions and the Step 5 acceptance criteria are qualified with the type-coded rule.
- **`docs/recovery-partition.md`** — the invariant now says "exactly one **type-coded** recovery partition, on the OS disk" and lists the four places a label-only partition is rejected. The existing-partition acceptance criteria adds "It is type-coded" as a prerequisite. The pre-check `R` computation and the delete loop now count type-coded partitions only. The OS-shrink failure section names the failure-then-fallback corner explicitly, with a cross-reference to `docs/architecture.md` Step 5 and to this entry.
- **`docs/state-and-idempotency.md`** — the fast-path conditions and the offline-fallback local safety check now say "type-coded" for the recovery-partition-count and registered-partition conditions. The "when the ID does not change" list adds v44 patch 7 to the same-version roll call, and the harness-move list extends through v19 and v20.
- **`docs/testing.md`** — added a "v20 changes" subsection and a "v19 changes" subsection above the existing v18 subsection. Option 1's classifier verdict list now includes `LABEL-ONLY`. Added a new top-level section on the encrypted-C: failure-then-fallback test: the four preconditions, how to run it, what to record, and the gating requirement on future destructive-path changes.
- **`docs/troubleshooting.md`** — added a new section on the label-only non-convergence loop, with the classifier WARN as the diagnostic and the two convergence outcomes. The OS-fallback BitLocker section adds the compound log signature (`Pre-deletion inventory:` followed in the same run by `OS-fallback deferred: C: could not be confirmed fully decrypted`) for the failure-then-fallback corner. The bug-report guidance adds that compound signature to the list of data to include.
- **`docs/index.md`** — the "If something is broken" section converted to a bullet list and extended with the label-only non-convergence loop and the compound-signature corner. The reference-table descriptions for `architecture.md` and `recovery-partition.md` name the type-coded authority rule and the residual corner respectively. Versioning updated to production v44 patch 7 and harness v20.
- **`docs/deployment.md`** — the "Later v44 patches" list, the "Rollback for the later v44 patches" list, and the "Canary and ring deployment" guidance are extended to cover patch 7. The canary section describes the convergence change for machines whose only recovery-looking partition was label-only.
- **`docs/driver-injection.md`** — the extraction section documents the v44 patch 7 VMD extraction-directory cleanup alongside the existing OEM cleanup. The "Why this matters" discussion of the INF-basename cross-reference explains why the extraction directory must be fresh. A "Related to the VMD extraction cleanup (v44 patch 7)" paragraph sits in the pipeline-gate discussion.
- **`README.md`** — production marker bumped to v44 patch 7, harness to v20. The "What it does, in order" step 8 and step 10 name the type-coded qualification. A new "Known limitation" block under "Before you run this" documents the failure-then-fallback corner with the combined log signature. Field-tested hardware table adds the ASUS v44 patch 7 run, the Lenovo V15 G5 IRL, and the Dell Vostro 16 5640. Version section extended through patch 7 and the harness move list extended through v20.
- **`.github/ISSUE_TEMPLATE/bug_report.md`** — the example version string updated from v44 patch 6 to v44 patch 7.

`docs/exit-codes.md`, `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, and the remaining `.github/` files (PULL_REQUEST_TEMPLATE, FUNDING, feature_request, config) were reviewed and required no changes for patch 7.

### Known limitations

**Failure-then-fallback corner on encrypted C: (resolved by [v45 patch 1](#v45-patch-1--2026-10-01)).** Removing the v44 patch 3 pre-destructive C: guard in v44 patch 6 narrowed the safety envelope in one specific corner. On a machine where **all four** of the following held:

1. C: is encrypted (common on Win11 24H2+ with Device Encryption).
2. Destructive replacement of the existing recovery partition is required — natural on any rebuild: a `DesiredStateId` change, a manifest bump, a partition-size shortfall, or a CPU/VMD presence change.
3. The destructive attempt fails **after** the existing recovery partition has already been deleted — e.g. `New-Partition` failing, the shrink not fitting even after the defrag retry, or `Format-Volume` failing.
4. No successful retry occurs before the machine is needed.

...the machine ended up with neither a dedicated recovery partition nor OS-fallback, because the OS-fallback gate also refuses on an encrypted C: (reagentc refuses to enable WinRE on an encrypted OS volume regardless of protector state). Under the pre-v44-patch-6 guard, the same machine deferred **before** touching the current route, leaving the existing route intact.

Preconditions 1 and 2 were common. Preconditions 3 and 4 were the narrow part. On a machine with reasonable free space, the destructive path succeeds and the corner does not fire. The failure mode was real but it was a corner, not the main path.

**The correct response was not to reinstate the guard.** The guard's predicate — "is C: encrypted?" — cannot distinguish a destructive attempt that will succeed from one that will fail, and the field evidence below shows the destructive path succeeding cleanly on multiple encrypted-C: machines. A pre-destructive guard on C: encryption defers every destructive replacement on every encrypted-C: machine, including the ones that would have succeeded. That is the over-deferral the v43 patch 5 (further revision 5) target-volume finding already corrected, in exchange for suppressing a double failure (the destructive attempt fails **and** the OS-fallback gate refuses) that only manifests after the first failure has already occurred.

**How the corner was actually closed (by v45 patch 1).** Not by reinstating the pre-destructive veto, but by moving the risky step — the shrink — into the reversible window. In v44 the sequence was delete → extend → shrink → create, and a shrink failure left the old partition gone. In v45 the sequence is plan → shrink → disable → delete → extend → create, so a shrink failure now leaves the old route intact and returns `Deferred` without touching a partition. The residual in v45 is narrower still (a post-deletion `New-Partition` or `Format-Volume` failure); see [v45 patch 1](#v45-patch-1--2026-10-01).

**Log signature.** An operator can recognize the corner from the log: a `Pre-deletion inventory:` block followed in the same run by `OS-fallback deferred: C: could not be confirmed fully decrypted`. `docs/troubleshooting.md` carries the combined signature and its interpretation.

### Field verification

- **Dell Vostro 16 5640 (Core 7 150U, Win 11 26200), 2026-10-01 12:22–12:30.** v44 patch 6. C: was `ProtectionStatus=Off`, `VolumeStatus=EncryptionInProgress` at 96.6%, no key protectors. The destructive path entered, WinRE was disabled, the existing 1000 MiB recovery partition was deleted, the OS partition was extended, the shrink succeeded on attempt 1 with no defrag retry, `New-Partition` succeeded with the recovery GUID applied at creation, the new partition was verified not encrypted, the WIM was deployed, and `reagentc /enable` returned exit 0 with status Enabled. The second run at 12:30:47 took the fast path — state file accepted, `Operating mode: DEDICATED`, no repeated work. This was the earliest of the eight clean destructive runs on encrypted C: now on record; see the eight-machine summary at the end of this section.
- **Lenovo V15 G5 IRL (i5-13420H, MT=83GW, Win 11 26200), 2026-10-01 13:11–13:15.** v44 patch 6. C: was `ProtectionStatus=Off`, `VolumeStatus=EncryptionInProgress` at 92.7%, no key protectors. Same clean destructive sequence: delete, extend, shrink attempt 1, `New-Partition` with the recovery GUID at creation, WIM deployed, `reagentc /enable` exit 0. The second run took the fast path. This run also exercised the v44 patch 6 Lenovo five-state resolution: the machine type 83GW has no published WinPE pack, the map resolution correctly produced `no-entry`, and the run was recorded as complete with `OEMPACK=NONE` rather than being marked incomplete.
- **ASUS desktop (PRIME H510M-D, i5-11400, Win 11 26300), 2026-10-01 14:02–14:04.** v44 patch 7. The first run took the **reuse** path: `Find-SuitableRecoveryPartition: candidate 4 on disk 4 is suitable (letter Z:)`. The existing 1100 MiB recovery partition was correctly identified as type-coded and adequate — 1082.2 MiB effective free against 1007 MiB required — and the deploy went into it with no delete, no extend, no shrink, and no recreate. This is the concrete demonstration that patch 1 does what it was designed to do: reuse an adequate recovery partition rather than churn the disk. The second run took the fast path.
- **Dell Vostro 16 5640 (Core 7 150U, Win 11 26300), 2026-10-01 14:28–14:32.** v44 patch 7. Second run on this physical machine, now on build 26300. C: was `ProtectionStatus=Off`, `VolumeStatus=EncryptionInProgress` at 94.9%. The `DesiredStateId` changed (build component), so the machine correctly rebuilt and re-converged rather than taking the fast path: clean destructive sequence — delete, extend, shrink attempt 1, `New-Partition` with the recovery GUID applied at creation, new partition verified not encrypted, WIM deployed, `reagentc /enable` exit 0 with status Enabled, `Operating mode: DEDICATED`. The second run at 14:32:38 took the fast path.
- **Dell Latitude 5530 (i5-1245U, 12th Gen, Win 11 26300), 2026-10-01 15:08–15:13.** v44 patch 7. C: was `ProtectionStatus=Off`, `VolumeStatus=EncryptionInProgress` at 78.5%. Same clean destructive sequence — delete, extend, shrink attempt 1, `New-Partition` with the recovery GUID applied at creation, new partition verified not encrypted, WIM deployed, `reagentc /enable` exit 0 with status Enabled, `Operating mode: DEDICATED`. Fast path at 15:14:39. This unit is **distinct from** the i7-1265U Latitude 5530 that motivated the v43 patch 5 (further revision) Audit Mode guard — the two are different machines and must not be conflated.
- **ASUS Vivobook X1504VA (i3-1315U, 13th Gen, Win 11 26300), 2026-10-01 15:12–15:14.** v44 patch 7. C: was `ProtectionStatus=Off`, `VolumeStatus=EncryptionInProgress` at 90.6%. Clean destructive rebuild — delete, extend, shrink attempt 1, `New-Partition` with the recovery GUID applied at creation, new partition verified not encrypted, WIM deployed, `reagentc /enable` exit 0 with status Enabled, `Operating mode: DEDICATED`. Fast path on the second run at 15:15:08. This run also exercised the v44 patch 7 diagnostic WARN reporting C:'s encryption state before proceeding.
- **Lenovo ThinkPad P16s Gen 2 (Core i7-1370P, MT=21HL, Win 11 26300), 2026-10-01 18:09–18:12.** v44 patch 7. C: was `ProtectionStatus=Off`, `VolumeStatus=EncryptionInProgress` at 94.4%. Lenovo OEM-pack resolution produced **`resolved`** for machine type 21HL — this is the first `resolved` Lenovo state in the v44 patch 7 field data, in contrast to the `no-entry` state exercised by the V15 G5 IRL. The resolved pack is `tp_t14-p14s-gen4-t16-p16s-gen2_w10w11_winpe_202305.exe`, a 1.37 MiB SCCM Package bundle dated May 2023; extraction produced 5 INFs, all 5 matched in the injected image, contributing a delta of 5 new third-party drivers. Clean destructive sequence — delete, extend, shrink attempt 1, `New-Partition` with the recovery GUID applied at creation, new partition verified not encrypted, WIM deployed, `reagentc /enable` exit 0 with status Enabled, `Operating mode: DEDICATED`. Fast path on the second run at 18:13:21.
- **Dell Pro 16 PC16250 (Core Ultra 7 255U, Win 11 26300), 2026-10-01 18:38–18:42.** v44 patch 7. C: was `ProtectionStatus=Off`, `VolumeStatus=EncryptionInProgress` at 89.2%. First Intel 15th-generation machine in the field data — the Core Ultra 7 255U parses to `Intel generation 15` via the `seriesMap` branch of `Get-IntelProcessorGeneration`, and `CPU=Intel|15` entered the `DesiredStateId` as designed. Dell WinPE map resolved `WinPE11 -> A10` (`WinPE11.0-Drivers-A10-XCXDW.cab`, 31.86 MiB, 70 INFs, delta of 64 new third-party drivers). Clean destructive sequence as above; fast path at 18:42:30.
- **HP ProBook 450 15.6 inch G9 (i5-1235U, Win 11 26300), 2026-10-01 19:25–19:30.** v44 patch 7. C: was `ProtectionStatus=Off`, `VolumeStatus=EncryptionInProgress` at 90.1%. First HP ProBook 450 G9 in the field data — distinct from the HP ProBook 450 G10 (i7-1355U) that hit the pre-v43-patch-5 Device Encryption race. First 1200 MiB bucket in the field data: the HP WinPE pack (`sp173204 v3.40`, 88.68 MiB) produced a 912 MiB WIM, requiring a 1192 MiB partition, which rounds up to 1200 MiB. The HP SoftPaq extractor returned exit code 1168 but produced 195 INFs; the `Invoke-VendorExtraction` "non-zero exit but INFs present" branch correctly treated the extraction as a success, and the fresh-extraction-directory guard ensured the 195 INFs were genuine output, not stale artifacts from a prior run. Delta of 190 new third-party drivers (153 of 153 package INFs matched). Clean destructive sequence as above; fast path at 19:32:15.
- **HP Laptop 15-fc0xxx (AMD Ryzen 5 7520U, Win 11 26300), 2026-10-01 19:42–19:48.** v44 patch 7. C: was `ProtectionStatus=Off`, `VolumeStatus=EncryptionInProgress` at 90.4%. **First AMD CPU in the v44 patch 7 field data.** The AMD Ryzen 5 7520U parses to `Intel generation N/A`, so `CPU=AMD|N` enters the `DesiredStateId` as designed; the VMD driver-resolution branch is skipped by both the `$Hardware.CPUVendor -eq "Intel"` gate and the VMD-presence check, and the machine correctly installs no VMD drivers. Same HP WinPE pack as the ProBook 450 G9 (`sp173204 v3.40`), same extractor exit code 1168, same 195 INFs → success, same 1200 MiB bucket, same delta of 190 new third-party drivers. Clean destructive sequence as above; fast path at 19:48:54, and a second fast path at 19:50:39 (three total runs, all clean, identical `DesiredStateId` across all three).
- **Dell Latitude 3550 (Core Ultra 5 125U, Win 11 26200), 2026-09-28, v43.** C: was `ProtectionStatus=Off`, `VolumeStatus=EncryptionInProgress` at 94.2%, no key protectors. Across four logged runs on that date, the destructive path completed delete, OS extend, OS shrink (attempt 1, no defrag), `New-Partition`, and `Set-PartitionAttributes`. The failure was isolated to the newly created partition being auto-encrypted by Device Encryption — the problem v43 patch 5 subsequently addressed by applying the recovery GUID at creation. This is the field evidence that the destructive path reaches and completes every pre-create step on an encrypted-C: machine; the create-step failure was a separate problem, not a consequence of C:'s state.
- **Dell Pro 14 PC14250 (Core 5 120U) and Dell 15 DC15250 (i7-1355U), 2026-09-30, v44 patch 5.** Both machines had encrypted C: (94% and 90% `EncryptionInProgress` at time of diagnostic). Both deferred under the pre-v44-patch-6 guard with the log line `Destructive recovery-partition replacement would remove the current WinRE route, and C: is not confirmed fully decrypted (Test-VolumeEncrypted=True). Deferring to preserve the current recovery environment.` These are the machines the guard removal unblocks: on the next rebuild they will attempt the destructive path instead of deferring.

**Eight distinct machines now confirm the guard-free destructive path succeeds on encrypted C:** the Dell Vostro 16 5640 (on both 26200 and 26300), the Dell Latitude 5530 (i5-1245U), the Dell Pro 16 PC16250 (Core Ultra 7 255U), the Lenovo V15 G5 IRL (MT 83GW, `no-entry` Lenovo OEM state), the Lenovo ThinkPad P16s Gen 2 (MT 21HL, `resolved` Lenovo OEM state), the ASUS Vivobook X1504VA (i3-1315U), the HP ProBook 450 G9 (i5-1235U), and the HP Laptop 15-fc0xxx (AMD Ryzen 5 7520U). All eight entered the destructive path with C: mid-encryption (`EncryptionInProgress` at 78.5%–96.6%), completed delete/extend/shrink/`New-Partition`/format/attribute, verified the new partition not encrypted, deployed the WIM, and reached `reagentc /enable` exit 0 with status `Enabled`. The v44 patch 7 diagnostic WARN correctly reported C:'s encryption state in each destructive run. The set spans Intel 12th, 13th, and 15th generation, Intel Core (non-generation-string), and AMD CPUs; Dell, HP, Lenovo, and ASUS chassis; both 1100 MiB and 1200 MiB bucket sizes; and both Lenovo OEM-pack resolution states (`no-entry` and `resolved`). This is the field evidence supporting the v44 patch 6 decision not to reinstate the pre-destructive C: guard. The failure-then-fallback corner is now closed by the [v45 patch 1](#v45-patch-1--2026-10-01) shrink-first reorder.

### Pending test (gating future destructive-path changes)

**Superseded by [v45 patch 1](#v45-patch-1--2026-10-01).** The pre-v45 gating language required a deliberate shrink-failure test on an encrypted-C: machine before any further changes to the destructive path. The v45 reorder moved the shrink out of the destructive window, which closed the shrink-trigger case; a shrink-failure VM exercise is now a regression test for the reorder rather than a release gate for changes that do not touch the post-deletion segment. The still-gated scope is narrower: the post-deletion segment of `Ensure-AdequateRecoveryPartition`. See [CONTRIBUTING.md](CONTRIBUTING.md) for the current gate and `docs/testing.md` for the post-deletion failure test.

### Unchanged

`ScriptVersion` remains 44. `DesiredStateId` is unchanged. No fleet-wide rebuild is forced. Healthy machines continue to take the fast path. A machine that is already healthy will not rerun automatically; the deployment mechanism must invoke the script explicitly to pick up the patch-7 changes. A machine whose next natural rebuild is already due (manifest bump, OEM pack version change, Windows build change, or CPU/VMD presence change) picks up the patch-7 changes on that rebuild.

### Notes

- **Label-only recovery partitions on the OS disk are no longer reused but also not deleted.** A label alone is not sufficient authority for deletion — consistent with the existing policy in `Remove-StrayRecoveryPartitions` and `Ensure-AdequateRecoveryPartition`. Label-only partitions may therefore persist across runs as clutter on the OS disk. This is intentional design, not an oversight: the alternative (deleting them) would require relaxing the type-code gate that every deletion decision in the script depends on.
- **`Test-WinRE.ps1` moves from v19 to v20** in the same window. The classifier mirror is the substantive change; the menu-box alignment is cosmetic.

---

## [harness v19] — 2026-09-30

Two Option S corrections in the read-only harness. Production `WinRE.ps1` is unaffected; this entry is the harness's own version marker.

### Fixed

- **Option S reports SKIP (not PASS) when the state file is absent and the VMD query is indeterminate.** Before v19, `Show-StateFileParity` checked for the state file's existence before consulting the VMD query result, and returned `PASS` with detail `no state file (rebuild expected)` whenever the file was missing. That was correct when VMD presence was determinable, but wrong when the VMD query had failed: production defers the entire run with `EXIT_WARNING` in that case rather than taking the full-update path, and the harness's `PASS` disagreed with what a live run would do. The missing-state-file branch now checks `$vmdQueryOk` and records `SKIP` with detail `No state file; VMD query indeterminate`, printing a short explanation that production would defer rather than start the update. The existing `INDETERMINATE`/`SKIP` handling for the state-file-present case is unchanged.
- **Option S wording clarified.** The header now reads "does the stored DesiredStateId match current inputs? This is not a full-flow simulation." The DSI MATCH verdict now reads "the stored deployment ID matches current inputs" followed by a note that production separately evaluates WinRE state/location, recovery-partition count, active WIM hash, pending-reboot/repair state, BitLocker, and other startup/flow gates before deciding what to do. The prior wording — "production will accept the state file" — implied that DSI equality alone was sufficient, which overstated what the check proves.

### Changed (docs)

- **`docs/testing.md`** — added a v19 version-history entry and a "v19 changes" subsection describing both Option S corrections; updated the Option S section heading and body to reflect the new no-state-file SKIP verdict and the clarified scope paragraph; updated the "Output style" heading to note that v19 did not change the output format; updated the parser self-test heading to note that v19 did not change the check count; added the Option S VMD-query-indeterminate case to the "What a SKIP means" list; added a clarifying parenthetical to the "Result states" section about Option S recording a result for the parity check itself; extended the fifth "differences from production" bullet to cover the v19 refinement.
- **`docs/index.md`** — updated the harness version to v19 in the Versioning section and in the "two scripts" harness bullet; added the v18→v19 move to the sequence of harness moves; added a note that v19 corrected Option S; corrected the production-script bullet to lead with the operations ("Runs elevated on a single machine, or as `SYSTEM` under a scheduled task on a managed fleet") rather than presenting SYSTEM as definitional.
- **`README.md`** — updated the "See it in action" banner to v19; updated the harness version to v19 in the Version section; added a note that the v19 change is confined to Option S and no managed machine rebuilds; clarified the ASUS field-verification row to note that v19 changes Option S only.
- **`SECURITY.md`** — corrected the opening line and the privilege bullet to describe both execution modes (elevated for single-machine repair, `SYSTEM` for fleet deployment) rather than presenting SYSTEM as definitional.
- **`CONTRIBUTING.md`** — corrected the opening line to say "runs with administrative privilege and modifies partition tables" rather than naming only the SYSTEM deployment mode.

### Unchanged

The harness's extraction cleanup, user-supplied `TestDir` protection, VMD-indeterminate reporting for the state-file-present case, Lenovo five-state resolution mirror, and parser self-test are unchanged. `Test-WinRE.ps1` remains read-only, requires no elevation, and modifies nothing. Production `WinRE.ps1` v44 patch 6 is unaffected.

---

## [v44 patch 6] — 2026-09-30

> **Correction.** The claim in this entry that "the safety property — never leave a machine with no working recovery route — is preserved end-to-end without the guard" was found to be inaccurate on review. Removing the guard narrowed the safety envelope in a specific corner: C: encrypted, destructive replacement needed, destructive attempt fails after deletion, no successful retry. The correct response was eventually a reorder of the destructive sequence, not a reinstatement of the guard; that reorder shipped in [v45 patch 1](#v45-patch-1--2026-10-01). See [v44 patch 7](#v44-patch-7--2026-10-01) for the corrected statement, the field evidence, and the residual failure mode as it then stood.

Removes the v44 patch 3 destructive-path C: guard, makes Lenovo OEM-pack resolution distinguish five states, makes VMD hardware detection fail-closed, closes a Step 2 wedge left by interrupted runs, corrects the OS-fallback remediation wording, and mirrors the production changes into the harness as v18.

The change was driven by a review of the v44 patch 3 guard in light of the v43 patch 5 (further revision 5) target-volume policy that the guard was built on top of. The guard was correct in spirit — prevent the destructive path from leaving a machine with no working recovery route — but it applied an OS-fallback precondition to the dedicated-partition path. The dedicated-partition path does not depend on C:'s BitLocker state at all; reagentc's check is on the **target** volume, and on the dedicated-partition path the target is the recovery partition. The guard was deferring runs that would have succeeded.

### Changed

- **C:'s encryption state is no longer a veto for the dedicated-recovery-partition path.** The v44 patch 3 destructive-path C: guard inside `Ensure-AdequateRecoveryPartition` has been removed. When the destructive path is about to run and the run will destroy the current recovery route (WinRE `Enabled` or a non-empty deletable-part set), the function still logs the `Destructive recovery-partition replacement will remove the current WinRE route` WARN, but it no longer calls `Test-VolumeEncrypted -MountPoint "C:"`, no longer returns `$null` on a non-`FullyDecrypted` result, and no longer defers via the OS-fallback machinery. The destructive sequence proceeds.

  **Why the guard was removed.** The v44 patch 3 guard was added preemptively on the reasoning that the destructive path could disable WinRE and delete a recovery partition on a machine whose C: was not in a state where the OS-fallback route — the path the destructive attempt falls through to on shrink failure — could itself complete. That reasoning over-applied the OS-fallback precondition to the dedicated-partition path. The dedicated-partition path's objective is to **create** a dedicated partition; it succeeds or fails on the partition geometry, not on C:'s BitLocker state. If the dedicated-partition path succeeds, C:'s state never matters. If it fails at the shrink step, the run falls through to OS-fallback, and *there* the OS-fallback gate checks C: and defers as designed.

  The only place C:'s BitLocker state is now consulted is the OS-fallback route: the fast-path OS-fallback re-verification, the full-update deploy step's OS-fallback branch, and the pending-reboot OS-fallback branch. All three exist because on the OS-fallback route the target volume *is* the OS volume, and reagentc refuses to enable WinRE on an encrypted OS volume. The dedicated-partition path — including the destructive sequence — does not consult C:'s state at any point.

- **Lenovo OEM-pack resolution now distinguishes five states.** `Get-LenovoWinPEPack` sets `$Script:LenovoPackResolution` to one of `unknown-mt`, `map-unavailable`, `no-entry`, `malformed-entry`, or `resolved`. The caller uses the state to distinguish "this Lenovo model has no published WinPE driver pack" (normal, expected, run recorded as complete with `OEMPACK=NONE`) from "the map entry exists but is missing its `winpe.url`" (configuration failure, run marked incomplete). Before patch 6, the caller could distinguish a map-fetch failure from a no-pack answer, but could not distinguish a malformed map entry from a legitimate no-pack case; both produced the same `$null` return and the same handling, and the machine would silently complete without OEM driver injection even though the map itself was broken.

  Lenovo does not publish WinPE driver packs for every model in their catalog. `unknown-mt` and `no-entry` are the two states that represent that fact, and both correctly let the run proceed with `OEMPACK=NONE`. `map-unavailable` (transient network failure fetching the map gist) and `malformed-entry` (map entry present but missing `winpe.url`) both mark the run with `$Script:ImageInjectionComplete = $false` and `$Script:nonFatalWarning = $true`; the pipeline gate then aborts before Step 4 and the next run retries. A malformed map entry is a configuration failure of the map itself, not a legitimate "no pack available" answer.

- **VMD hardware detection is now fail-closed.** The VMD presence query wraps `Get-PnpDevice -PresentOnly` in `-ErrorVariable vmdErr` and treats any enumeration error as an indeterminate result, not as "VMD hardware absent". Previously, an enumeration error would produce an empty device list, `$vmdPresent` would be set to `$false`, and the run would proceed to select a driver set that omits the VMD package on a machine that may well have VMD hardware. On a VMD-based machine whose deployed WinRE lacks the VMD driver, the recovery environment cannot see the OS disk — this is the failure mode the v44 patch 1 `DesiredStateId` change was designed to prevent, and patch 6 closes the remaining path by which it could still occur.

  On an indeterminate VMD query the run logs the enumeration error, sets `$Script:nonFatalWarning = $true`, removes the checkpoint file, and exits with `EXIT_WARNING` **before** committing any state. No WIM is deployed, no partition is touched, no `reagentc` call is made. The next run retries the enumeration; a transient PnP service issue is the most likely cause.

- **Step 2 removes stale `winre.wim` and `base.wim` before extraction and rename.** When the base WIM is obtained from the GitHub repository — the path reached only when no usable WIM exists at the reagentc-registered location or via fallback — Step 2 now:
  1. Removes any stale `winre.wim` at `$WorkDir\winre.wim` before invoking 7-Zip, in case an interrupted previous run left the extraction output partially written.
  2. Verifies that 7-Zip produced `winre.wim` after extraction.
  3. Removes any stale `base.wim` at `$WorkDir\base.wim` before the `Rename-Item "$WorkDir\winre.wim" "base.wim"` call.

  Before patch 6, an interrupted previous run could leave a `base.wim` in place at the moment the next run reached the rename. The rename would fail, and the machine would not progress past Step 2 until an operator deleted `WorkDir` by hand. The v44 patch 3 fix added the same `base.wim` cleanup to the **injection-failure abort branch**; patch 6 adds it to the **normal Step 2 path** so the wedge is closed whether the previous run failed in injection or in the download-and-rename step itself.

- **OS-fallback remediation wording corrected.** The log message the OS-fallback gate emits when it defers has been rewritten. The previous message told the operator that the machine could be made ready for OS-fallback by "completing encryption, adding a protector, or enabling protection." That was wrong: those actions make C: *more* encrypted, not less, and reagentc refuses to enable WinRE on an encrypted OS volume regardless of which protector is present or whether protection is armed.

  The corrected message tells the operator what actually resolves the state — complete decryption of C: (`manage-bde -off C:`) or waiting for an in-progress decryption to finish — and states explicitly that the OS-fallback route requires C: to be `FullyDecrypted`. The corrected message also points at the dedicated-partition path as the alternative when decryption of C: is not an option, because the dedicated-partition path does not depend on C:'s BitLocker state.

- **The 2 GiB sanity ceiling note now names three functions consistently.** The `.NOTES` block in `scripts/WinRE.ps1` names three functions that the future ceiling must gate: `Ensure-AdequateRecoveryPartition`, `Find-SuitableRecoveryPartition`, and `Remove-StrayRecoveryPartitions`. The README, the `[v44 patch 2]` and `[v44 patch 3]` CHANGELOG entries, and `docs/recovery-partition.md` previously named two, omitting `Remove-StrayRecoveryPartitions`. That function deletes any type-coded recovery partition on a non-OS disk without checking size — the same class of hazard the ceiling is designed to guard against, and one that is reached by a different code path than the other two. All four references now name three.

### Changed (harness)

- **`Test-WinRE.ps1` moved to v18.** Six behavior changes, five new future-proofing checks, and three cosmetic fixes.

  Mirror drift from production patch 6:

  1. **VMD query-failure handling.** Options 1 and S now treat a PnP enumeration error as an indeterminate result rather than absence. Option 1's VMD hardware presence section reports `INDETERMINATE` with the enumeration error message. Option S records `SKIP` in the results with reason `VMD query indeterminate` and prints an `INDETERMINATE` verdict instead of a DSI MATCH or DSI MISMATCH. Before v18, the harness could produce a "definitive" DSI that disagreed with what a live production run would compute, which is the opposite of what Option S is for.
  2. **Lenovo map resolution status machine.** `Get-LenovoWinPEPack` in the harness now sets `$Script:LenovoPackResolution` to the same five states as production. `Test-OemMaps` distinguishes `malformed-entry` (red, marks the test failed) from `no-entry` (gray, informational), and treats `map-unavailable` (yellow, marks the test failed) separately from both.

  Harness-specific bugs:

  3. **`Get-DriverManifest` extracted as a shared helper.** Options 2, 9, and S now all use the same two-attempt / 2-second-sleep / WARN-log retry policy that production uses. Previously each option had its own fetch code, and they had drifted from each other and from production.
  4. **Cleanup footgun closed.** The harness refuses to delete `$TestDir` on exit when the directory pre-existed the run and already contained entries. The pre-existing state is captured before any directory work. This prevents `Remove-Item $TestDir -Recurse -Force` from wiping a user-supplied path like `C:\Users\Me\Desktop`.
  5. **Stale extraction destinations are cleared before each extraction.** Applies to `Invoke-VendorExtraction`, `Invoke-CabExtraction`, and the GitHub base-WIM test's working directory. Before v18, a stale INF file left by an earlier run could satisfy a failed extraction's INF-count success check. The Lenovo "non-zero exit but INFs present" branch was the sharpest case: it treats an INF-count greater than zero as success regardless of the extractor's exit code, so a stale INF could mask a genuine extraction failure.
  6. **`Test-VmdDrivers` records SKIP (not PASS) when the Intel CPU generation cannot be parsed.** Driver applicability was not evaluated in that case, so a PASS would misrepresent what the harness actually checked. The raw CPU string is logged so the parser can be extended. The result detail reads `Intel CPU generation could not be parsed`.

  Future-proofing checks added to the parser self-test (production dependency verification):

  7. **DISM cmdlet availability.** Verifies `Mount-WindowsImage`, `Dismount-WindowsImage`, `Get-WindowsImage`, `Add-WindowsDriver`, and `Get-WindowsDriver` are all present. Production hard-depends on all five; a missing cmdlet would only be discovered at injection time.
  8. **`Get-Disk` shape.** Verifies `Number`, `FriendlyName`, `PartitionStyle`, `Size`, `BootFromDisk`, `IsSystem`, and `IsBoot` are present.
  9. **`Get-Volume` shape.** Verifies `DriveLetter`, `FileSystemLabel`, `FileSystem`, `Size`, `SizeRemaining`, `DriveType`, `HealthStatus`, and `UniqueId` are present.
  10. **CPU-generation parser regression table.** Fourteen cases spanning 11th, 12th, 13th Gen, Core, Core Ultra, AMD, Celeron, Pentium, Xeon, and Atom CPU strings. Catches a Windows update or firmware rename that changes `Win32_Processor.Name` in a way that would silently desynchronise `DesiredStateId`.
  11. **`DesiredStateId` determinism and input sensitivity.** Same inputs must hash identically; flipping VMD presence must change the hash; flipping `ProductionScriptVersion` must change the hash; the output must be 64 hex characters. A silent change to the DSI recipe would be caught before it desynchronised every deployed state file.

  Cosmetic fixes:

  12. **`Write-KV` overflow handling.** A key at or past `$KeyWidth` now gets a separating space before its value. Previously, `Manifest VMD device IDs` (23 chars, one over the 22-char key column) rendered flush against the value.
  13. **`Test-WinRE.ps1`'s `.NOTES` block count.** The v18 future-proofing regression check count was corrected from "Four" to "Five" to match the number of bullets listed.
  14. **`Test-WinRE.ps1`'s `.NOTES` block wording.** For the `Test-VmdDrivers` SKIP path, the phrase "in the detail" was corrected to "in the log line" (the raw CPU string is logged via `Say`, not recorded in `Record -Detail`).

### Changed (docs)

- **`docs/troubleshooting.md`** — the "v44 patch 3 — the destructive-path guard" section is removed. The OS-fallback deferral section is unchanged except for the deletion of the sub-variant A/B discriminator, which referred to the removed guard.
- **`docs/exit-codes.md`** — the sub-variant A/B breakdown of the OS-fallback BitLocker deferral is removed. The `Pre-deletion inventory:` discriminator no longer applies; the guard's deferral line is no longer logged.
- **`docs/architecture.md`** — Invariant 13 (destructive-path C: guard) is removed. The "same shape" narrative in the closing section no longer uses the guard as an example of preemptive correctness.
- **`docs/deployment.md`** — the "v44 patch 3" section is reduced to the `base.wim` cleanup only; the C: guard discussion is removed.
- **`docs/recovery-partition.md`** — section 2 is simplified to "disable WinRE" with no C: check.
- **`docs/state-and-idempotency.md`** — the paragraph describing the destructive-path C: guard's effect on the state file is removed.
- **`docs/driver-injection.md`** — a new section documents the Lenovo five-state resolution and why `unknown-mt` and `no-entry` are legitimate "no pack" answers while `map-unavailable` and `malformed-entry` are not.
- **`.github/ISSUE_TEMPLATE/bug_report.md`** — the sub-variant A/B discriminator field is removed; the OS-fallback deferral log-string example is corrected from `C: VolumeStatus=…` to `Test-VolumeEncrypted=…`.
- **`SECURITY.md`** — a new bullet under "Known limitations (not vulnerabilities)" documents the offline-fallback trust model, names the residual hardware-drift risk, and clarifies that the state file's editability is a documented correctness limitation rather than a privilege boundary crossing.

### Removed

- **The v44 patch 3 destructive-path C: guard.** `Ensure-AdequateRecoveryPartition` no longer calls `Test-VolumeEncrypted -MountPoint "C:"`, no longer returns `$null` on a non-`FullyDecrypted` result, and no longer defers via the OS-fallback machinery when C: is encrypted. The `Destructive recovery-partition replacement would remove the current WinRE route, and C: is not confirmed fully decrypted` deferral line is no longer logged. When the destructive path is about to run, the function logs `Destructive recovery-partition replacement will remove the current WinRE route. … C:'s BitLocker state is not a veto for the dedicated-target path. The OS-fallback route retains its separate C: BitLocker gate.` and continues.

### Known limitations

**2 GiB ceiling not yet enforced (resolved by [v45 patch 1](#v45-patch-1--2026-10-01)).** As of this release, the destructive path (`Ensure-AdequateRecoveryPartition`) deletes every partition on the OS disk carrying the standard recovery GPT type GUID or MBR type code without checking its size, the reuse path (`Find-SuitableRecoveryPartition`) accepts an oversized recovery-typed partition without checking an upper bound, and the stray-cleanup path (`Remove-StrayRecoveryPartitions`) deletes type-coded recovery partitions on non-OS disks without checking size. OEM factory recovery volumes (7–20 GiB) can carry the same type code as Windows Setup recovery partitions (<1.5 GiB), which is the hazard this limitation names. The `$MaxManagedRecoveryPartitionMiB = 2048` ceiling that gates all three functions shipped in [v45 patch 1](#v45-patch-1--2026-10-01).

### Unchanged

`ScriptVersion` remains 44. `DesiredStateId` is unchanged. No fleet-wide rebuild is forced. Healthy machines continue to take the fast path. A machine that is already healthy will not rerun automatically; the deployment mechanism must invoke the script explicitly to pick up the patch-6 changes. A machine whose next natural rebuild is already due (manifest bump, OEM pack version change, Windows build change, or CPU/VMD presence change) picks up the patch-6 changes on that rebuild.

### Field verification

- **Harness v18 on ASUS desktop (PRIME H510M-D, i5-11400, Win11 26200), 2026-09-30.** Option 1 diagnostic completed. All fifteen parser self-test checks PASS: reagentc status and location regexes, both `manage-bde` regexes, `Get-BitLockerVolume` shape, OS resolution, `Get-Partition` shape, WinRE location resolution, `Get-RecoveryPartitions`, `Get-PartitionSupportedSize`, the five v18 additions (DISM cmdlets, `Get-Disk` shape, `Get-Volume` shape, CPU-generation regression table, `DesiredStateId` determinism). 15 passed, 0 failed, 0 skipped. The `Write-KV` overflow fix was verified visually: `Manifest VMD device IDs PCI\VEN_8086&DEV_9A0B, …` renders with the separating space.
- **Production v44 patch 6.** The destructive runs on the Dell Vostro 16 5640 (26200) and Lenovo V15 G5 IRL that exercised patch 6 code are recorded in the [v44 patch 7](#v44-patch-7--2026-10-01) Field verification section. They were not separately logged here at the time the entry was written and are not re-duplicated.

---

## [v44 patch 5] — 2026-09-30

Offline fallback for the driver manifest fetch, network timeouts on every call, and two harness refinements.

The change was driven by a 2026-09-30 field observation on a healthy ASUS desktop: the manifest fetch failed with `FATAL ERROR: The remote name could not be resolved: 'gist.github.com'` on a machine whose state file was still valid. The manifest fetch runs before the fast-path decision, so a DNS failure took a healthy machine down to `EXIT_FATAL` without any local state being wrong. The run had done nothing to warrant a fatal exit; it simply could not reach the network to prove what the state file already recorded.

### Added

- **Offline fallback for the manifest fetch.** When the driver manifest fetch fails after its retry budget, the script now reads the state file at `C:\Recovery\OEM\winre_state.json` and trusts its stored `DesiredStateId` directly. It does **not** attempt to recompute the ID from cached inputs — recomputing would require the OEM pack version, which is resolved from the OEM map, another gist on the same unavailable network. The local safety checks (WinRE `Enabled`, exactly one recovery partition on the OS disk, deployed WIM hash matches the stored hash) remain fully enforced and do not depend on the manifest. If the fast path does not fire under the offline fallback, the run exits `EXIT_WARNING` before the full-update pipeline and the machine retries on its next scheduled run when the network is available. The residual risk is named below.
- **`$NetworkTimeoutSeconds = 15` on every network call.** Previously, `Invoke-RestMethod` and `Invoke-WebRequest` defaulted to roughly 100 seconds each. On a fully offline machine with a stale cache, the aggregate worst-case runtime was over 10 minutes before the offline fallback could engage. All eight network calls in `WinRE.ps1` now carry `-TimeoutSec $NetworkTimeoutSeconds`. The fully offline worst-case runtime dropped to roughly 90 seconds, dominated by the fixed sleeps in the retry loops rather than by the network timeouts. The last of the eight calls — the GitHub API listing reached only in the full-update path when no local WIM is available — was applied in a follow-up edit within the same patch.

### Changed

- **`Test-WinRE.ps1` moved to v17.** Three changes. `$NetworkTimeoutSeconds = 15` was added and applied to every network call, matching production. `Invoke-OemPackDownload`'s zero-byte check was moved back above the `$hasHash` computation so that a zero-byte download with an expected hash logs `file is empty` rather than `SHA256 mismatch`. A note was added to `Test-VmdDrivers` stating that the harness intentionally exercises every OS/CPU-eligible driver to validate the download path, whereas production additionally filters on VMD hardware presence. The harness output format is unchanged from v16.
- **`docs/troubleshooting.md`, `docs/exit-codes.md`, and `docs/deployment.md`** gained an offline-deferral section. See the individual documents.

### Known limitations

**Offline fallback trusts the stored `DesiredStateId` (still open).** The offline fallback trusts the state file's stored `DesiredStateId` without verifying that the machine's local hardware still matches the inputs that produced it. On a machine whose hardware changed while offline — a CPU swap, a BIOS update that flipped VMD, or a motherboard replacement that changed `Manufacturer` / `Model` / `MachineType` — the offline run could take the fast path with a stale DSI and exit `EXIT_WARNING` on a machine that would have rebuilt under the live manifest. The next successful manifest fetch detects the drift and forces a rebuild. A `LocalInputsId` field in the state file would close this; it is planned as its own version boundary and is documented in [docs/state-and-idempotency.md](docs/state-and-idempotency.md) and [SECURITY.md](SECURITY.md).

### Unchanged

`ScriptVersion` remains 44. `DesiredStateId` is unchanged. No fleet-wide rebuild is forced. Healthy machines continue to take the fast path.

### Field verification

- **ASUS desktop (PRIME H510M-D, i5-11400, Win11 26200), 2026-09-30 13:22.** The motivating observation: the pre-release version of patch 5 exited `FATAL ERROR: The remote name could not be resolved: 'gist.github.com'` on a healthy machine. The initial implementation was wrong in a way that the offline case exposed — it recomputed the DSI from cached inputs, which fails on a fully offline machine because the OEM map fetch (a different gist) also fails, producing `OEMPACK=NONE` in the candidate DSI versus the state file's `OEMPACK=A10`. The corrected implementation trusts the state file directly.
- **ASUS desktop, 2026-09-30 15:08:36 and 15:08:57.** Two consecutive v44 patch 5 fast-path runs. Both runs: banner `(v44 patch 5)`, `Acquired program lock at C:\ProgramData\OEM\Logs\WinREManager.lock`, manifest fetch succeeded, DSI `62DE5C7D…` matched the on-disk state file, `Assigned temporary drive letter Z:` followed by `Removing temporary drive letter Z:`, `Operating mode: DEDICATED`, `Released program lock`. Both runs exited 0. No contention, no warnings, no leaked drive letters. This is the healthy online path.
- **Offline verification.** Pending. The intended coverage is a hosts-file block on the ASUS (`0.0.0.0 gist.github.com` and `0.0.0.0 api.github.com`) followed by a run of `WinRE.ps1`, expecting: two `Driver manifest fetch attempt N failed` lines, the offline-fallback engage line with a `state file LastUpdated=…` suffix, four `Offline fallback: skipping …` lines, `Checkpoint step: 0`, `State file accepted (DesiredStateId match)`, `Operating mode: DEDICATED`, `Released program lock`, exit code 2, total runtime under 90 seconds.

---

## [v44 patch 4] — 2026-09-30

Single-instance guarantee via an exclusive file lock, closing the concurrent-instance defect first observed on the Dell Latitude 3550.

The change was driven by a 2026-09-30 field observation on the Dell Latitude 3550 (12:29–12:40). Two `WinRE.ps1` processes ran simultaneously on the same machine, one of them exiting on `Cannot rename because item at 'C:\Temp\WinREWork\winre.wim' does not exist.` The script assumed exclusive access to `C:\Temp\WinREWork` but had no startup lock. The scheduled task's `MultipleInstancesPolicy = IgnoreNew` prevents scheduled-vs-scheduled overlap but does nothing about manual invocations (interactive shells, RMM "run now" buttons, Intune remediation scripts).

### Added

- **Program lock via an exclusive file handle.** Before any state-modifying action, `WinRE.ps1` opens `C:\ProgramData\OEM\Logs\WinREManager.lock` with `FileShare.None` via `[System.IO.File]::Open($path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)`. The Windows kernel enforces the exclusive handle: cross-session, cross-privilege exclusion is guaranteed by the OS, not by a security descriptor the script would have to configure. The handle is released automatically when the process exits, cleanly or after a crash — there is no stale-lock recovery logic to get wrong. The lock file is not deleted on release; its existence is not the lock, the open handle is.

  **The lock is deliberately not acquired under `-DryRun`.** A dry run is read-only and safe to run concurrently with a live deployment, so an operator can inspect a machine with `WinRE.ps1 -DryRun` or `scripts\Test-WinRE.ps1` while a scheduled run is in progress.

  **Failure to open the lock file for any reason other than contention is non-fatal.** A permission error, a missing `Logs` directory, or a transient filesystem issue causes the script to log a WARN and proceed without single-instance protection. The lock is defensive: a broken lock must not prevent a legitimate deployment.

  **The lock is released last.** In the `finally` block, after the WIM-mount discard and after every temporary drive letter has been cleaned up. This ensures the lock is held until all cleanup is complete, so a waiting second instance cannot begin work while the first is still releasing resources.

### Changed

- **`docs/deployment.md` — "One instance per machine" section** rewritten. The section previously stated that the script had no lock and that exclusive operation was the operator's responsibility. It now leads with the file lock and describes the failure mode of a second instance: it fails fast with `Another WinRE Manager instance is already running (program lock file is exclusively held)` and exits `EXIT_WARNING` (code 2), not `EXIT_FATAL` (code 3). The mitigations for manual invocations (wait for the scheduled task, temporarily disable it, use the harness) remain as secondary guidance. A new note clarifies that the lock file persists on disk between runs and that its presence does not indicate a running instance.
- **`docs/troubleshooting.md` — "The script exited with a rename error (concurrent instance)" section** rewritten. The rename error is now reachable only if the lock acquisition fails for a permission reason and the run proceeds unprotected. The primary concurrent-instance failure shape is now a fast exit with `EXIT_WARNING` and the `Another WinRE Manager instance is already running` log line. A new log-string reference for the lock-acquisition failure sub-case (`Could not set up program lock at … : … - proceeding without single-instance protection`) is included.
- **`docs/deployment.md` — Intune/MDM section.** The prediction that a remediation that coincides with a scheduled run would exit `EXIT_FATAL` was corrected to `EXIT_WARNING`.

### Field verification

- **Dell Latitude 3550, 2026-09-30 12:29–12:40.** The concurrent-instance defect that motivated this patch. Two processes running, one exiting on the rename error. Post-patch, this run shape produces one successful run and one fast-fail exit with `EXIT_WARNING`.
- **ASUS desktop, 2026-09-30 14:04:37.** First successful field run of the file lock. Log shows `Acquired program lock at C:\ProgramData\OEM\Logs\WinREManager.lock` early in the run and `Released program lock` at the end. Only one instance was running, so the concurrent-failure path was not exercised; the mechanism itself was confirmed.
- **ASUS desktop, 2026-09-30 15:08:36 and 15:08:57.** Two consecutive v44 patch 5 runs (which inherit patch 4). Both runs show the acquired/released lock pair, confirming the lock release is not blocking subsequent runs even when the runs are seconds apart.
- **Concurrent-instance test — resolved by [v45 patch 1](#v45-patch-1--2026-10-01) field verification.** A second interactive invocation of `WinRE.ps1` while a first was mid-flight was eventually exercised on a Win10 MBR VM on 2026-10-02 09:47: the second instance logged `Another WinRE Manager instance is already running (program lock file is exclusively held)` and exited within seconds, and the first instance completed its run normally. See [v45 patch 1](#v45-patch-1--2026-10-01) Field verification.
- **Crash-recovery test.** Pending. The intended coverage is a PowerShell process killed mid-flight followed by a fresh run, expecting the fresh run to acquire the lock immediately with no stale-lock loop. The design guarantees this — the kernel releases the handle on process termination — but it has not been exercised.

### Unchanged

`ScriptVersion` remains 44. `DesiredStateId` is unchanged. No fleet-wide rebuild is forced. The lock acquisition is transparent to all downstream logic; no existing behavior depends on whether the lock is held.

---

## [v44 patch 3] — 2026-09-30

> **Correction.** The destructive-path C: guard described in this entry was removed in [v44 patch 6](#v44-patch-6--2026-09-30). The `base.wim` cleanup on the injection-failure abort branch remains, and its description below is still accurate. See the patch 6 entry for the reasoning behind the reversal.

Two targeted correctness fixes from the v44 patch 2 peer-review round, a harness beautification (v16), and an extension of the documented 2 GiB ceiling known gap to name both affected code paths.

Both fixes are small and scoped. Neither changes `ScriptVersion`, neither changes the `DesiredStateId`, and neither forces a rebuild on any machine. Already-completed machines will not rerun automatically; the deployment mechanism must invoke the script explicitly to pick the fixes up.

### Fixed

- **Destructive-path C: encryption guard in `Ensure-AdequateRecoveryPartition`.** Before the `reagentc /disable` call, if the path is about to destroy the current recovery route — either WinRE is `Enabled` or `$deletableParts.Count -gt 0` — the function now checks C: via `Test-VolumeEncrypted -MountPoint "C:"`. If the result is not exactly `$false` (confirmed fully decrypted), it logs the reason, sets `$nonFatalWarning`, and returns `$null` without touching WinRE registration, partitions, or drive letters. The `$null` return propagates to the OS-fallback machinery, which then defers. This closes the gap ChatGPT identified in the v44 patch 2 round: the destructive path could disable WinRE and delete a recovery partition on a machine whose C: was not in a state where the OS-fallback route could complete, leaving the machine without a working recovery route. The guard is scoped to the destructive path only. It is **not** a reinstatement of the global C: startup gate, which the 2026-09-29 same-machine differential test disproved. The code comment names the reason, per the standing rule that any new C: check must be scoped and justified. **(Removed in [v44 patch 6](#v44-patch-6--2026-09-30).)**
- **`Remove-ItemIfExist "$WorkDir\base.wim"` in the failed-injection abort branch.** The abort branch already removed `winre_optimized.wim`; it did not remove `base.wim`. Without the extra line, the next run's Step 2 failed at `Rename-Item "$WorkDir\winre.wim" "base.wim"` because the destination file existed. The machine never progressed past Step 2 until an operator deleted `WorkDir` by hand. This is a genuine defect on the injection-failure path, not a hypothetical.

### Changed

- **`Test-WinRE.ps1` moved to v16.** The harness is colour-coded. Disks, partitions, volumes, recovery partitions, and the parser self-test are rendered as tables. Free-space values are colour-coded against explicit thresholds: Red below 5% **or** below 3 GB; Yellow below 15% **or** below 20 GB; Green otherwise. The colour rules apply to Fixed volumes only; CD-ROM and Removable volumes keep neutral colours because their free space is not a deployment constraint. A boxed warning banner is drawn when the OS volume's free space is critical. Diagnostic output uses `Write-Diag` and `Write-KV` instead of `Say` so key/value pairs align and values render with the correct colour. The harness remains read-only, and its menu structure, parser self-test, download test, and extraction test are unchanged. See the `.NOTES` block in `scripts/Test-WinRE.ps1` for the full v16 change list.

### Known limitations

**2 GiB ceiling not yet enforced (resolved by [v45 patch 1](#v45-patch-1--2026-10-01)).** The v44 patch 2 entry documented the destructive path in `Ensure-AdequateRecoveryPartition` as the exposure for the planned 2 GiB sanity ceiling. Claude identified in the v44 patch 2 peer-review round that the reuse path in `Find-SuitableRecoveryPartition` is also exposed: an oversized recovery-typed partition can be **accepted** for reuse by that function and then re-registered against, which is a different failure shape from deletion but draws on the same missing size check. The Known gap was therefore extended to name both functions. [v44 patch 6](#v44-patch-6--2026-09-30) subsequently added the third function, `Remove-StrayRecoveryPartitions`. The ceiling that gates all three shipped in [v45 patch 1](#v45-patch-1--2026-10-01).

### Field verification

- **Dell Latitude 3550 (Intel Core Ultra 5 125U, Win11 26200), 2026-09-30 12:29–12:47.** The machine that motivated the entire v43 patch 5 investigation now runs cleanly under v44. The run produced a clean partition recreate: `Component cleanup and ResetBase completed successfully`, `Pre-deletion inventory:` followed by partition deletion and recreation, `Target partition 0/4 (Z:) is already unencrypted - reagentc /enable can proceed`, `reagentc /enable (exit 0): … Operation Successful.`, `Operating mode: DEDICATED`. The old v43 failure mode (`delete-and-recreate` retry, OS-fallback, `FATAL: WinRE is not enabled at exit`) is gone. This confirms the destructive-path C: guard and the target-volume policy work on the machine that broke the previous design. (The guard itself was subsequently removed in [v44 patch 6](#v44-patch-6--2026-09-30), and the machine continued to run cleanly.)
- **ASUS desktop (PRIME H510M-D, i5-11400, Win11 26200), 2026-09-30 12:02.** Fast path with the v44 patch 3 code. State file accepted (DSI match), `Operating mode: DEDICATED`, no machine changes. Confirms no regression on the healthy path.

The v44 patch 2 field verification below remains the latest confirmed data for the ResetBase change specifically.

### Unchanged

`ScriptVersion` remains 44. `DesiredStateId` is unchanged. No fleet-wide rebuild is forced. Healthy machines continue to take the fast path. A machine whose next natural rebuild is already due (manifest bump, OEM pack version change, Windows build change, or CPU/VMD presence change) picks up the v44 patch 3 fixes on that rebuild. A machine that is already in a completed state and whose inputs have not changed will not see the fixes until the deployment mechanism invokes the script with intent to rerun, for example by deleting the state file or forcing a full-update pass.

---

## [v44 patch 2] — 2026-09-30

### Changed

- **`dism /cleanup-image /StartComponentCleanup /ResetBase` now runs on the mounted image after driver injection completes and before the dismount, on the full-update path only.** The size reduction is materialised by the existing Step 4 `dism /Export-Image /Compress:max`, which writes a smaller `winre_optimized.wim`. The technique was adopted from Microsoft's KB5028997 remediation scripts (`WinREPathScriptSamples`), which use the same pair of operations to make `winre.wim` fit an existing recovery partition.

  ResetBase makes the image unserviceable for rollback (updates present when it ran can no longer be uninstalled). This is acceptable for a recovery image, which is rebuilt from source whenever the `DesiredStateId` changes and is never rolled back in place.

  ResetBase failure is non-fatal: the log records a WARN with the DISM exit code, the pipeline continues, and the Step 4 export writes whatever size the image currently is. The Step 5 partition acceptance check decides whether the result fits. ResetBase runs only when `$Script:ImageInjectionComplete` is `$true`; if injection failed, the pipeline aborts before Step 4 and the reset would waste CPU.

  **Field-observed size reduction.** The first v44 patch 2 run on a machine with a base WinRE image that had not accumulated update history produced 0.26 MiB of savings (756.36 MiB → 756.1 MiB). This is expected: the WinRE WinSxS store is only a few hundred MB to begin with, and on a fresh image most of that is the current baseline with nothing to reset. The savings will be material only on a machine whose WinRE image has accumulated multiple cumulative updates. The runtime cost is roughly 2 seconds on a fresh image and longer on one with more superseded state.

  `ScriptVersion` remains 44. `DesiredStateId` is unchanged. No fleet-wide rebuild is forced: healthy machines continue to take the fast path with their current WIM, and only receive the ResetBase'd WIM on their next natural rebuild (manifest bump, OEM pack version change, Windows build change, or CPU/VMD presence change). The behavioural change is a slower full-update pass and a smaller exported WIM.

### Known limitations

**2 GiB ceiling not yet enforced (resolved by [v45 patch 1](#v45-patch-1--2026-10-01)).** As of this release, the destructive path in `Ensure-AdequateRecoveryPartition` deletes every partition on the OS disk that carries the standard recovery GPT type GUID or MBR type code, without checking its size or contents. Windows Setup and in-place upgrade recovery partitions are under 1.5 GiB; OEM factory recovery volumes can be 7–20 GiB and may carry the same type code. A 2 GiB sanity ceiling that WARNs and skips oversized candidates was planned. [v44 patch 3](#v44-patch-3--2026-09-30) extended the known-gap list to also name `Find-SuitableRecoveryPartition`; [v44 patch 6](#v44-patch-6--2026-09-30) added `Remove-StrayRecoveryPartitions`. The ceiling that gates all three functions shipped in [v45 patch 1](#v45-patch-1--2026-10-01).

### Field verification

- **ASUS desktop (PRIME H510M-D, i5-11400, Win11 26200), 2026-09-30 02:06.** State file deleted manually to force a full-update pass. ResetBase ran on the mounted image, took ~2 seconds, exited 0, and logged `Component cleanup and ResetBase completed successfully`. The exported WIM was 756.1 MiB, versus 756.36 MiB on the pre-ResetBase run. The run completed normally with `Operating mode: DEDICATED`; the second run at 02:08 took the fast path.

---

## [v44 patch 1] — 2026-09-30

This revision bumps `ScriptVersion` from 43 to 44 and changes the `DesiredStateId` inputs. Every managed machine performs one full-update pass on its next scheduled run to rebuild the WIM against the new ID, then returns to the fast path. The revision also carries six patches that were applied on disk during the [v43 patch 5 (further revision 5)] session but never documented, and two correctness fixes for edge cases identified during review.

The `DesiredStateId` change closes a gap in which a BIOS or firmware update that flipped VMD on or off — or a CPU or motherboard swap on the same chassis — could leave a machine taking the fast path with a driver set that no longer matched its hardware. In that scenario the deployed WinRE cannot see the OS disk on a VMD-based system, and Startup Repair fails. The ID is now a deployment-input fingerprint rather than a hardware fingerprint.

### Changed

- **`DesiredStateId` inputs now include CPU vendor/generation and VMD presence.** Previous inputs were `HW`, `OS`, `MANIFEST`, `OEMPACK`, `SCRIPT`. New inputs are `HW`, `OS`, `CPU`, `VMD`, `MANIFEST`, `OEMPACK`, `SCRIPT`. The CPU component is `vendor|generation`, with the literal string `N` used when the generation cannot be parsed (AMD, Intel Celeron/Pentium/Atom/Xeon, N/J-series). The VMD component is `present` or `absent`. VMD presence is a deployment input because it determines whether the VMD driver package is selected for injection. Full rationale is in [docs/state-and-idempotency.md](docs/state-and-idempotency.md).
- **`ScriptVersion` = 44.** Changed because the `DesiredStateId` format changed. This is the version boundary that explains the fleet-wide rebuild; `ScriptVersion` is not bumped for changes that do not affect the deployed WIM or the partition layout.
- **The read-only harness `Test-WinRE.ps1` was updated to v15.** The harness's hardware-profile helper is now aligned with production's manufacturer normalization (LENOVO uppercase, HP canonicalization, raw fallback for unrecognised manufacturers), and it returns the same fields production's `Get-HardwareObject` produces — including `Model`, which is part of the `HW` component of the new ID. A new `Get-DesiredStateId` mirror and a new `Show-StateFileParity` diagnostic (menu option `S`) recompute the ID from the same inputs production uses and compare it to the on-disk state file, so a field engineer can check "would production take the fast path on this machine right now?" without running the production script. The `Test-OemMaps` Lenovo null-return handling now mirrors production's caller: the two permanent-skip cases (`MT=UNKN`, and map loaded with no entry for this MT) are logged at `INFO` and counted as a pass, and only a failed map load is counted as a failure. See the `.NOTES` block in `scripts/Test-WinRE.ps1` for the full v15 change list.

### Fixed

Six patches applied during the [v43 patch 5 (further revision 5)] session but never documented. All ship in v44 patch 1.

- **Step 3 → Step 4 pipeline gate.** When OEM or VMD injection failed (`$Script:ImageInjectionComplete = $false`), the pipeline was continuing to Step 4 (`dism /Export-Image`), Step 5 (deploy), and `reagentc`. The state-write gate prevented the state file from recording the run, but did not prevent the deployment. On a VMD-based system the resulting WinRE cannot see the OS disk. The pipeline now exits with `EXIT_WARNING` immediately after Step 3, removes any stale `winre_optimized.wim`, and resets the checkpoint to step 2 so the next run re-acquires the base WIM from source and re-runs injection against a clean image.
- **OS-fallback BitLocker gate, full-update path, fail-closed.** The gate previously called `Get-BitLockerVolume -MountPoint C:` directly and passed silently when the cmdlet returned `$null`: `$osFallbackVs` became `""`, the `-and` short-circuited, and the gate passed. Replaced with `Test-VolumeEncrypted -MountPoint "C:"` requiring exactly `$false` (confirmed fully decrypted) to proceed. `Test-VolumeEncrypted` also brings the `manage-bde` text-parsing fallback for machines whose BitLocker module is unavailable.
- **OS-fallback BitLocker gate, pending-reboot path.** Same fail-open pattern, same fix.
- **Hashless download length check.** In `Invoke-OemPackDownload`, the no-hash path accepted a file on clean HTTP completion without checking its length. HP is the vendor that reaches this path. An explicit `if ($fileSize -le 0)` check now runs before the hashless acceptance branch.
- **Audit Mode comment correction.** The comment claimed the guard "runs before any state-modifying action", which is literally false — `New-DirectoryIfNotExists $LogDir` and `Write-Log` run before the guard. Narrowed to "runs before any WinRE registration, partition, image, checkpoint, or recovery-state modification", with a note that log directory creation is not deployment state.
- **Two `-DryRun` structural cleanups.** `Write-WinREState` moved the `if ($Script:DryRun)` check above the `$Script:GeometryRestoreFailed` branch. `Invoke-ReAgentRegistrationRepair` added an internal `-DryRun` guard at the top of the function. Neither closes an active bug; both make the `-DryRun` contract self-upholding rather than caller-dependent.

Two correctness fixes identified during v44 review:

- **Lenovo machines whose machine type cannot be resolved no longer loop on `EXIT_WARNING`.** When `Get-LenovoWinPEPack` could not determine the machine type, it returned early before loading the Lenovo WinPE map. The caller's "map loaded, no entry for this MT" detection therefore failed (`$Script:LenovoWinPEMap` was null), and the transient-failure branch fired: `ImageInjectionComplete` was set to false, no state file was written, and every subsequent run repeated the same path. The machine never progressed. The caller now treats an unresolvable machine type the same as "map loaded, no entry": the run is recorded as complete with `OEMPACK=NONE`, the state file is written, and the fast path fires on subsequent runs. If the machine type is later resolved — or a pack is published — the `DesiredStateId` changes and the machine rebuilds automatically.
- **`DeployedDiskNumber` and `DeployedPartitionNumber` are no longer written as `0` for OS-fallback states.** The `Write-WinREState` parameters were typed `[int]`, so a `$null` argument (from `$state.DeployedDiskNumber` on an OS-fallback state file that never set the field) was coerced to `0` and written into the state file as `"DeployedDiskNumber": 0`. Latent today because no consumer trusts those fields in the OS-fallback branch, but a correctness bug the moment a future consumer does. The parameters are now `[object]` typed, and the conditional that populates them checks `$null -ne` before the integer comparison.

### Migration Note

Every managed machine performs one full-update pass on its next scheduled run. Healthy NVMe laptops take roughly 3–5 minutes of I/O and CPU. Machines with a suitable existing recovery partition re-use it; no partition work occurs on healthy machines. After the first full-update pass per machine, the state file records the new `DesiredStateId` and the fast path resumes permanently.

Machines whose state file recorded `PendingReboot = true` are treated as stale before the pending-reboot repair block runs, so the ID change triggers the full-update path instead. No machines are lost. Machines stuck in the enable-failure loop-breaker (`EnableFailureAttempts >= 3`) receive one fresh attempt under the new ID before the loop-breaker can fire again.

Rollback: change `$ScriptVersion` back to 43, revert the `Get-DesiredStateId` `$parts` array, and restore the previous `Get-HardwareObject` if the manufacturer normalisation differed. No data is lost; another fleet-wide rebuild occurs on the next run.

The read-only harness `Test-WinRE.ps1` moves from v14 to v15 in the same window. The harness has no `ScriptVersion` and no `DesiredStateId` of its own; its version is its own marker. A v14 harness run still reads the machine's state correctly, but its `Get-ThisMachineProfile` would compute a different `DesiredStateId` than production for a Lenovo or an unrecognised-OEM machine — that is the drift v15 closes.

### Field verification

- **Hyper-V VM, Win11 26200, 2026-09-30 00:29.** First run after the v44 patch: `DesiredStateId` mismatch on the state file written by v43 patch 5 (further revision 5) → full-update path. VMD hardware present = False, so `VMD=False` and `CPU=Intel|11` entered the new ID stably. WIM copied from the reagentc-registered recovery partition, mounted, dismounted, optimized (713.3 MiB), target partition accepted on size (980.1 MiB effective free, 963 MiB required), deployed, `reagentc /enable` succeeded, DEDICATED, state file written. Second run at 00:32: `DesiredStateId` match → fast path, drive letter removed, DEDICATED. No drive-letter leaks, no checkpoint residue.
- **ASUS desktop, Win11 26200, 2026-09-30 00:29.** Same sequence. Target partition accepted on size (1082.2 MiB effective free, 1006 MiB required). DEDICATED, state file written. Second run at 00:32: fast path, drive letter removed, DEDICATED.

---

## [v43 patch 5 (further revision 5)] — 2026-09-29

This revision inverts the BitLocker policy. It is the largest single change in the v43 patch 5 generation, and it supersedes the BitLocker portions of the [v43 patch 5 (further revision)] entry below. Everything else in that entry — the Audit Mode guard and the enable-failure counter — remains accurate.

The change was driven by a same-machine test on 2026-09-29 that disproved the policy the earlier revisions had been built on.

### Changed

- **The BitLocker policy is now target-volume-based, not OS-volume-based.** reagentc's BitLocker check is on the volume it is being asked to enable WinRE on, not on the OS volume. Proven by a same-machine test: with C: in the `FullyEncrypted`/no-protectors state (the *Waiting for Activation* state of Device Encryption), `reagentc /enable` against a dedicated recovery partition succeeded while `reagentc /enable` against the OS volume failed with *"Windows RE cannot be enabled on a volume with BitLocker Drive Encryption enabled."* The policy was therefore inverted: prepare the **target** volume before calling reagentc, and do not gate on C:'s state except for the OS-fallback path, where the target volume *is* the OS volume. Full rationale and the field evidence are in [docs/architecture.md](docs/architecture.md) and [docs/deployment.md](docs/deployment.md).
- **A partition claimed by Device Encryption does not re-encrypt after `manage-bde -off` completes.** Confirmed by the same test: a newly created partition (labelled `R:` in the test) that the Device Encryption service had claimed, then explicitly decrypted with `manage-bde -off`, stayed unmanaged. `reagentc /enable` against it then succeeded. This makes decrypt-in-place safe and replaces the delete-and-recreate retry that had never worked on the Dell Latitude 3550 case.
- **The read-only harness `Test-WinRE.ps1` was updated to v14 in lockstep with the production policy change.** The BitLocker diagnostic's hazard and ambiguity warnings no longer say that production "will refuse destructive partition work" in those states — that language described the removed OS-volume gate and would have told a field engineer to defer a run that production would actually succeed on. The warnings now name which production path is affected by which state: the OS-fallback path is the only one that depends on C:'s `VolumeStatus`, and the enable-only and dedicated-partition paths proceed regardless of C:'s state because they target the recovery partition. A new diagnostic block reports the BitLocker state of the partition reagentc is registered to — the target that `Set-RecoveryPartitionReadyForWinRE` will prepare — and states plainly whether the next production run will need to spend up to 300 seconds decrypting it in place. The harness remains read-only; its scope, menu structure, parser self-test, and download and extraction tests are unchanged. See the `.NOTES` block in `scripts/Test-WinRE.ps1` for the full v14 change list.

### Added

- **`Set-RecoveryPartitionReadyForWinRE`.** A new helper that prepares a target recovery partition for `reagentc /enable`. If the partition is already unencrypted, it returns immediately. If it is encrypted or actively encrypting, it runs `manage-bde -off` against the partition and polls `Test-VolumeEncrypted` at 5-second intervals up to a 300-second timeout, until the volume reports confirmed-unencrypted (`FullyDecrypted`, or the `could not be opened by BitLocker` classification from `manage-bde`). Returns `$true` on success and `$false` on timeout or unrecoverable failure. Under `-DryRun` it logs the intent and returns `$true` without touching the volume. Called at four sites: the enable-only path, the full-update path with an existing recovery partition, the full-update path with a newly created partition, and the pending-reboot repair path.
- **OS-fallback gate.** reagentc refuses to enable WinRE on an encrypted OS volume, always. The OS-fallback path now checks C:'s `VolumeStatus` before deploying the WIM and defers with `EXIT_WARNING` unless it is `FullyDecrypted`. The script never modifies C:'s BitLocker state — decrypting the OS volume is hours of I/O, changes the recovery key relationship, and the OS volume is the user's data. When the OS-fallback gate defers, the operator message tells them what to do: sign in with a Microsoft account to complete Device Encryption activation, or add a key protector manually (`Add-BitLockerKeyProtector -MountPoint C: -RecoveryPasswordProtector`) and enable protection, or wait for decryption to finish.
- **Structural `-DryRun` choke point for the full-update pipeline.** The pipeline (copy or download base WIM, mount, inject drivers, dismount, `dism /Export-Image`) performs file I/O in `WorkDir` and invokes `dism` and 7-Zip. None of that should run under `-DryRun`. A single early return at the top of the full-update path logs the plan for Steps 1 through 7 and exits cleanly. The downstream plan-only functions (`Find-SuitableRecoveryPartition`, `Ensure-AdequateRecoveryPartition`, `Invoke-ReagentcEnable`, `Remove-StrayRecoveryPartitions`) have their own `-DryRun` guards, but are not reached from this path — the guard is single and structural.

### Removed

- **The startup BitLocker gate.** The earlier further revision installed a startup gate that deferred on any `ProtectionStatus=Off` with a non-`FullyDecrypted` `VolumeStatus`. That included the `FullyEncrypted`/no-protectors state, which is the normal state of every fresh Win11 local-account machine before a Microsoft-account sign-in. The gate was deferring on the majority of the fleet. It has been removed entirely. The Audit Mode guard that ran before it is unchanged.
- **`Suspend-BitLockerForWinRE` and `Test-BitLockerSuspended`.** Deleted. Suspension does not prevent Device Encryption from claiming newly created partitions — proven by the Dell Latitude 3550 pre-patch-5 log, where the new partition was auto-encrypted despite protection being `Off`, and by the 2026-09-29 test, where the new partition was auto-encrypted with C: in the state suspension produces. Suspension is also useless for OS-fallback, where reagentc refuses regardless.
- **The internal BitLocker check in `Invoke-ReagentcEnable` and its `"blunsafe"` return value.** Callers are now responsible for making the target unencrypted via `Set-RecoveryPartitionReadyForWinRE` before calling `Invoke-ReagentcEnable`. The four `"blunsafe"` handlers (enable-only, pending-reboot, full-update post-enable, final verification) are gone.
- **The encrypted-partition delete-and-recreate retry in `Ensure-AdequateRecoveryPartition`.** It never worked on the Dell and is redundant given that a claimed partition can be decrypted in place without re-encrypting.
- **The `"bitlocker"` suspend + delete + recreate recovery in the full-update path.** Replaced by a short handler that logs, sets the warning flag, and lets the state-file counter and the loop-breaker do their work.
- **`Test-BitLockerProtected` and `Test-RecoveryPartitionEncrypted`.** Deleted. `Test-VolumeEncrypted` is the sole BitLocker classifier in the script.
- **Dead script state.** `$Script:BitLockerSuspended` and `$Script:BitLockerGuardDeferred` were removed along with the functions that set them.

### Fixed

- **The enable-failure counter now counts terminal `"bitlocker"` results and decryption timeouts alongside `"failed"`.** The loop-breaker predicate was widened to `LastEnableResult -in @("failed","bitlocker")`, and the counter is incremented on `"bitlocker"` in both the enable-only path and the full-update state write, so a machine that keeps failing the enable step on the BitLocker error no longer loops silently.
- **`Find-SuitableRecoveryPartition` no longer rejects encrypted existing partitions.** The target-volume policy means the script will decrypt the target in place before `reagentc /enable` rather than destroy and recreate it. An existing encrypted recovery partition is therefore usable.
- **Preferred drive-letter reuse.** When `Ensure-AdequateRecoveryPartition` creates a new recovery partition after deleting the old one, it now prefers a letter that was already used earlier in this run over a fresh one from `Get-AvailableDriveLetter`. Windows caches letter-to-volume mappings in `MountedDevices`; reusing a letter the script held earlier is more likely to succeed cleanly than picking a fresh one, and it avoids the assign-remove-reassign churn that can leave stale entries. The fallback chain in `Invoke-DriveLetterAssignment` is unchanged.

### Migration Note

A machine running [v43 patch 5 (further revision)] will not rebuild on this revision: `ScriptVersion` is unchanged and the `DesiredStateId` is unchanged. A machine whose previous run deferred at the startup BitLocker gate will, on the next run, proceed normally if the target partition can be prepared. A machine whose previous run took the OS-fallback path on an encrypted C: will defer at the OS-fallback gate with a clear operator message.

The read-only harness `Test-WinRE.ps1` moves from v13 to v14 in the same window. The harness has no `ScriptVersion` and no `DesiredStateId`; the version is its own marker. A v13 harness run still reads the machine's BitLocker state correctly — only the warning text and the new target-partition block differ.

### Field evidence

- **VM test, 2026-09-29.** C: was `ProtectionStatus=Off`, `VolumeStatus=FullyEncrypted`, `KeyProtector: {}`. `reagentc /enable` against partition 4 (a dedicated recovery partition) succeeded. `reagentc /enable` against partition 3 (the OS volume), on the same machine in the same session, failed with *"Windows RE cannot be enabled on a volume with BitLocker Drive Encryption enabled."* This is the test that established the target-volume nature of reagentc's check.
- **VM test, 2026-09-29 (continued).** A newly created recovery partition (`R:`) was claimed by the Device Encryption service (`VolumeStatus=EncryptionInProgress` at 97.6%, no key protectors). `manage-bde -off R:` was run. After the `-off` completed, `manage-bde -status R:` reported `The volume R: could not be opened by BitLocker` — the definitive signal of a clean, BitLocker-unmanaged recovery partition — and R: stayed unmanaged. `reagentc /enable` then succeeded. This is the test that established that decrypt-in-place is safe.
- **Dell Latitude 3550 (Intel Core Ultra 5 125U, Windows 11 build 26200), pre-patch-5 log.** The script created a new partition on a machine mid-Device-Encryption, the Device Encryption service auto-encrypted it before the recovery type GUID could take effect, the delete-and-recreate retry hit the same problem, the script fell back to OS-fallback, and `reagentc /enable` refused on the encrypted OS volume. This is the failure the new policy is designed to prevent, and the log is the basis for the OS-fallback gate.

### Unchanged

`ScriptVersion` remains 43. `DesiredStateId` is unchanged. Healthy machines do not rebuild. (The `DesiredStateId` was subsequently changed in [v44 patch 1](#v44-patch-1--2026-09-30).)

---

## [v43 patch 5 (further revision)] — 2026-09-29

> **Correction.** The BitLocker policy described in this entry was superseded on the same day by [v43 patch 5 (further revision 5)](#v43-patch-5-further-revision-5--2026-09-29). The Audit Mode guard and the enable-failure counter introduced in this entry remain current. Read this entry as history for the BitLocker portions; read the newer entry for the current behaviour.

### Fixed

- **Audit Mode / OOBE / sysprep guard.** The script now refuses to run before any state-modifying action when Windows is not in a normal-running state. During Audit Mode, OOBE, and the sysprep generalize/specialize phases, `reagentc /enable` fails with `ERROR_CANCELLED` (`0x4c7`, 1223) regardless of the correctness of the deployed WIM or the state of the recovery partition. The previous code deployed successfully, failed at `/enable`, wrote a state file recording the deployment as complete, and then looped on every subsequent run — the state file matched, no rebuild was triggered, and the enable-only path retried `/enable` forever. The guard reads `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` → `ImageState` at startup, immediately after the log directory is ensured and before the hardware check. It proceeds only when `ImageState` is absent (some SKUs omit the key) or exactly `IMAGE_STATE_COMPLETE`; any other value defers with `EXIT_WARNING`, logs a clear message, and makes no WinRE or partition changes. Runs under `-DryRun` in the same read-only form (logs `Would defer` and continues). Field case: Dell Latitude 5530 (12th Gen Intel i7-1265U, Windows 11 build 26200) — the machine was in Audit Mode when the script first ran, `/enable` failed with `0x4c7` on two consecutive runs, and after the user completed OOBE and ran `reagentc /enable` manually it succeeded on the first attempt with the same WIM.
- **Enable-failure counter and loop-breaker.** The state file now records `LastEnableResult` (string) and `EnableFailureAttempts` (integer). Previously, a failed `reagentc /enable` did not affect the state-write gate: the run continued through Step 6 and Step 7, wrote the state file as if the deployment had completed, and exited `EXIT_FATAL` at the final-verification block. The next run accepted the state file, took the fast or enable-only path, and failed the same way — a permanent loop for any cause of `/enable` failure, not just Audit Mode. Three changes close this:
  - **The enable-only path no longer falls through to full update on `"failed"`.** A failed enable on the enable-only path increments the counter, writes the state file with the new counter value, and exits `EXIT_WARNING`. The deployment is already current; rebuilding it would not change the outcome. (Under the original further revision, `"bitlocker"` still fell through to the suspend + delete + recreate recovery path; that path was removed in further revision 5, and the counter now includes `"bitlocker"`.)
  - **A loop-breaker exits `EXIT_FATAL` after 3 consecutive failed enables.** When the state file records `EnableFailureAttempts >= 3`, a terminal `LastEnableResult`, and WinRE is still `Disabled`, the script logs a clear "manual intervention required" message, names the state file path, and exits without attempting anything else. The operator resolves the underlying cause and deletes the state file to reset the counter.
  - **The fast path clears stale counters.** When the idempotent fast path fires on a machine whose state file carries a non-zero `EnableFailureAttempts` or a `LastEnableResult` other than `"ok"`, the state file is rewritten with the counters reset. A healthy machine's counters are cleared on the first fast-path run after the underlying cause is resolved.

  Both new fields default to `"ok"` / `0` when read from state files written by earlier versions, so no rebuild is triggered by adding them.

### Changed

- **BitLocker state checks now consider `VolumeStatus`, not just `ProtectionStatus`.** (Superseded by further revision 5: the check now targets the recovery partition, not C:.)
- **`FullyEncrypted` with `ProtectionStatus=Off` was treated as ambiguous, not safe.** (Superseded by further revision 5. Under the newer policy, this state is no longer relevant to the enable-only or full-update paths, because those now target the recovery partition, not C:. It is still relevant to the OS-fallback gate, where the target *is* C:.)
- **Startup BitLocker gate.** (Removed in further revision 5.)
- **Checkpoint file is preserved on deferral.** The deferral blocks no longer remove the checkpoint file. Deferring on BitLocker state does not invalidate any resumable step; steps 1–4 do not depend on BitLocker and the existing step guards handle resumption once the state is safe.
- **`-DryRun` no longer modifies WinRE registration.** Two code paths could modify state despite the "dry run modifies nothing" contract. First, `Ensure-AdequateRecoveryPartition`'s `reagentc /disable` call was not guarded. Second, `Invoke-ReagentcEnable` ran `reagentc /enable` unconditionally; the enable-only caller was guarded, but the pending-reboot path was not. Both are now closed with structural, not per-step, guards.
- **Lenovo machines with no published WinPE pack no longer re-run the full pipeline forever.** The v42 rule marked every supported-vendor run with no resolved OEM pack as incomplete and refused to write a state file. That was correct for Dell and HP (their maps are single-pack) and for a Lenovo map that failed to download. It was wrong for the common Lenovo case where the map loads successfully and simply has no entry for this machine type. The fix distinguishes "map loaded, no entry for this model" (expected and permanent) from "map failed to load" (transient).
- **New partitions are created with the recovery type GUID already applied.** `New-Partition` now passes `-GptType {de94bba4-06d1-4d40-a16a-bfd50179d6ac}` (GPT) or `-MbrType 0x27` (MBR) at creation. This closes the window between `New-Partition` and `Set-RecoveryPartitionAttributes` during which a plain Basic Data partition could be claimed by the Device Encryption service.

### Field reports

**Dell Latitude 5530** (12th Gen Intel i7-1265U, Windows 11 build 26200). Machine was in Audit Mode when `WinRE.ps1` was first run. The deployment completed successfully through Step 5, `reagentc /enable` failed with `0x4c7` on two consecutive runs, and the state file recorded the deployment as complete. After the user completed OOBE and ran `reagentc /enable` manually it succeeded on the first attempt with the same WIM. This is the case that motivated the Audit Mode guard.

### Unchanged

`ScriptVersion` remains 43. `DesiredStateId` is unchanged. Healthy machines do not rebuild.

---

## [v43 patch 5] — 2026-09-28

### Fixed

- **BitLocker protection-state checks now consider `VolumeStatus`, not just `ProtectionStatus`.** On Windows 11 24H2+ with Device Encryption, a volume can be actively encrypting (`VolumeStatus=EncryptionInProgress`) while `ProtectionStatus` reads `Off`. In that state, the previous code logged *"already Off - no suspension needed"* and proceeded with the destructive partition path. The Device Encryption service then auto-encrypted any new partition before its recovery type GUID could be applied, and `reagentc /enable` refused with *"Windows RE cannot be enabled on a volume with BitLocker Drive Encryption enabled."* `Test-BitLockerProtected` now returns `$null` (unknown) and `Suspend-BitLockerForWinRE` returns `$false` immediately — without falling through to the generic `manage-bde` fallback — for any hazardous `VolumeStatus`. Both refuse to treat the volume as unprotected, and the destructive partition paths abort.
- **`FullyEncrypted` with `ProtectionStatus=Off` is treated as ambiguous, not safe.** This state is the standard suspended-BitLocker state, but it is also indistinguishable from a Device Encryption volume in the *Waiting for Activation* state, where the volume has been encrypted with a clear key but protection has not been armed because the recovery key has not yet been escrowed. The two-field local view cannot tell the two apart. Both `Test-BitLockerProtected` and `Suspend-BitLockerForWinRE` now return `$null` / `$false` for this combination, and the destructive partition paths defer with `EXIT_WARNING`. (Superseded by further revision 5.)
- **Ownership guard on `Suspend-BitLockerForWinRE`.** (Superseded by further revision 5: the function was removed.)
- **Startup BitLocker gate.** (Removed in further revision 5.)
- **Startup gate handles an unknown BitLocker state.** (Removed with the gate in further revision 5.)
- **Startup gate runs under `-DryRun`.** (Removed with the gate in further revision 5.)
- **Checkpoint file is preserved on BitLocker deferral.** (Retained as a general principle in further revision 5.)
- **`-DryRun` no longer modifies WinRE registration.** Two code paths could modify state despite the "dry run modifies nothing" contract: `Ensure-AdequateRecoveryPartition`'s `reagentc /disable` call, and `Invoke-ReagentcEnable` on the pending-reboot path. Both closed with structural guards. (Retained and extended to the full-update pipeline in further revision 5.)
- **Lenovo machines with no published WinPE pack no longer re-run the full pipeline forever.** The v42 rule marked every supported-vendor run with no resolved OEM pack as incomplete. The fix distinguishes "map loaded, no entry for this model" (expected and permanent) from "map failed to load" (transient).
- **The BitLocker safety check in `Ensure-AdequateRecoveryPartition` runs before `reagentc /disable`.** The initial patch placed the check after the WinRE disable, so a refusal left the machine with WinRE disabled and no way to re-enable it until encryption finished — the exact damaged state the patch was written to prevent.
- **Step 5 performs the same BitLocker safety check before disabling WinRE.**
- **Fail-closed on BitLocker state in `Invoke-ReagentcEnable`.** `Invoke-ReagentcEnable` returned a distinct result `"blunsafe"` when BitLocker on C: was not confirmed unprotected. All three call sites aborted with `EXIT_WARNING`. (Removed in further revision 5.)
- **Stronger `manage-bde` fallback.** When `Get-BitLockerVolume` is unavailable and the fallback parses `manage-bde -status` text, `Protection Off` alone is no longer sufficient evidence of safety. Only a confirmed `Conversion Status: Fully Decrypted` makes the fallback return confirmed-unprotected.
- **`-DryRun` evaluates the BitLocker safety check.** (Superseded by further revision 5: the function was removed and the equivalent check lives in `Set-RecoveryPartitionReadyForWinRE`.)
- **New partitions are created with the recovery type GUID already applied.** `New-Partition` now passes `-GptType {de94bba4-06d1-4d40-a16a-bfd50179d6ac}` (GPT) or `-MbrType 0x27` (MBR) at creation.

### Field reports

Two machines hit this bug in the same 24-hour window, both on Windows 11 build 26200 mid-Device-Encryption:

- **Dell Latitude 3550** (Intel Core Ultra 5 125U) — `VolumeStatus=EncryptionInProgress` at 73.6% when the script ran.
- **HP ProBook 450 15.6 inch G10** (Intel Core i7-1355U) — same state, same failure sequence.

Both machines lost their dedicated recovery partition and had WinRE disabled by the pre-patch-5 code. Recovery procedure: see [docs/troubleshooting.md](docs/troubleshooting.md).

Two further Dell machines (a Pro Slim QCS1250 and a Vostro 16 5640) ran against a mid-encryption state after the further revision landed. The startup gate fired correctly on both: no partition was touched, no state file was written, and both runs exited with `EXIT_WARNING`. Both machines will complete the dedicated-partition deployment automatically on the next run after their encryption state stabilises.

### Unchanged

`ScriptVersion` remains 43. `DesiredStateId` is unchanged. Healthy machines do not rebuild.

---

## [v43 patch 4] — 2026-09-27

### Fixed

- **Checkpoint writes are now gated on injection success.** Previously the step 3, 4 and 6 checkpoint files advanced even when OEM or VMD injection failed. If a run was interrupted before its cleanup step, the next run would resume past step 3, deploy the un-injected WIM, and commit state for it — silently marking a broken deployment as healthy and disabling all future retries. The three writes are now conditional on `$Script:ImageInjectionComplete`. On a healthy run the behaviour is unchanged.
- **Migration guard for already-affected machines.** A machine already sitting on an orphaned step-4 or step-6 checkpoint from a pre-patch-4 run will have its `$step` reset to 2 whenever the current run also determines that a rebuild is required, forcing step 3 to re-run and injection to be retried. The guard runs after `$needInject` has been fully evaluated, so it catches both the "no state file at all" case and the "valid-but-stale state file" case.

`ScriptVersion` unchanged at 43. `DesiredStateId` unchanged. Healthy machines do not rebuild.

---

## [v43 patch 3] — 2026-09-27

### Fixed

- `Remove-OrphanPartition` now sets `GeometryRestoreFailed` when the newly created partition cannot be removed after a failure. The state file is then deleted on the write gate, forcing a full retry on the next run instead of preserving a shrunken OS partition indefinitely.
- The enable-only path and both pending-reboot exits now enforce the "no type-coded recovery partition on any non-OS disk" invariant, matching the fast path and Step 7. Previously a stray secondary-disk recovery partition could survive indefinitely on a machine whose WinRE was simply re-enabled.
- The pending-reboot success exit now honours `$Script:nonFatalWarning` before returning `EXIT_SUCCESS`.

---

## [v43 patch 2] — 2026-09-27

### Fixed

- The classifier now requires the reagentc-registered recovery partition to be on the **OS disk**. Previously a machine registered to a secondary-disk recovery partition could take the idempotent fast path and then have the fast-path cleanup delete the very partition reagentc was pointing at.
- `ActiveLocationWimPresent` now requires a successful WIM hash, not just a successful `Test-Path`. A file that exists but cannot be read no longer counts as evidence that the registered location is healthy.
- Post-shrink rollback gap closed. If all three shrink attempts fail, `Restore-OSPartitionSize` now runs before the fallback path so C: is not left shrunken.
- `Restore-OSPartitionSize` sets `GeometryRestoreFailed` on every failure path. `Write-WinREState` deletes the state file when that flag is set, forcing a fresh full-update run on the next invocation.
- The count=0 OS-fallback exemption additionally requires that the active WinRE location is on the OS partition.

---

## [v43 patch] — 2026-09-27

### Fixed

- Step 7's stray-partition cleanup extracted to `Remove-StrayRecoveryPartitions` and called from the idempotent fast path. Previously the fast path exited before Step 7, so a stray recovery partition on a non-OS disk survived indefinitely on machines whose state stayed idempotent.
- Fast-path exit now honours `$Script:nonFatalWarning`.

---

## [v43] — 2026-09-27

### Fixed

- Fallback copy no longer deletes its own source when `$SourceWim` and the fallback target resolve to the same file.
- Full update now forces a rebuild when no WIM is available at either the reagentc-registered location or the fallback search.

---

## [v42] — 2026-09-27

### Fixed

- Post-shrink failure cleanup. Every failure path in `Ensure-AdequateRecoveryPartition` after the OS partition has been shrunk now either removes the orphan partition or restores the OS partition size. No failure leaves C: permanently shrunken.
- Idempotency no longer accepts a fallback WIM as evidence that a dedicated WinRE location is healthy.
- `BootFromDisk` lookups replaced with `Get-OSDisk` (OS partition's disk number) throughout.
- Step 7 secondary-disk deletion now requires a recovery partition type code; label-only matches on non-OS disks are logged and skipped.
- `dism /Export-Image` exit code is checked before checkpointing step 4.
- `reagentc /disable` failure at step 5 now aborts instead of continuing.
- OEM map resolution failure for a supported vendor now marks the run incomplete.
- Step 7 cleanup failures now set `$Script:nonFatalWarning`.

---

## [v41] — 2026-09-27

### Changed

- `Remove-OrphanPartition` re-extends the OS partition to `SizeMax` after successfully deleting an orphan. (Superseded in [v45 patch 1](#v45-patch-1--2026-10-01): the parameterless call now falls back to `SizeMax` only for legacy call sites, and recovery calls pass `-TargetSizeBytes` to restore the exact pre-attempt size.)
- The idempotent-run check examines the count of recovery partitions on the boot disk. Anything other than exactly one forces a full-update run.
- The "zero recovery partitions + OS-fallback state file" case is exempted from the rebuild policy.

---

## Earlier versions

v27 through v40 introduced: the download exception-on-success fix, vendor-native extraction (Lenovo Inno Setup, HP SoftPaq), the Add-WindowsDriver return-shape workaround, recovery-partition attributes before drive-letter assignment, the 250 MiB free-space policy, `defrag /x` retry on shrink failure, and the tri-state BitLocker contract. Full engineering changelog is in the `.NOTES` block at the top of `scripts/WinRE.ps1`.
