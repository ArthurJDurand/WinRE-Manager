# Changelog

All notable user-facing changes to WinRE Manager are documented here.

The production script's `.NOTES` block contains the complete engineering changelog including patch generations that ship under the same `ScriptVersion`. This file is the shorter, user-facing summary.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to a `ScriptVersion` + patch-generation scheme rather than strict SemVer — see [docs/state-and-idempotency.md](docs/state-and-idempotency.md) for why.

## [v43 patch 5] — 2026-09-28

### Fixed

- **BitLocker protection-state checks now consider `VolumeStatus`, not just `ProtectionStatus`.** On Windows 11 24H2+ with Device Encryption, a volume can be actively encrypting (`VolumeStatus=EncryptionInProgress`) while `ProtectionStatus` reads `Off`. In that state, the previous code logged *"already Off - no suspension needed"* and proceeded with the destructive partition path. The Device Encryption service then auto-encrypted any new partition before its recovery type GUID could be applied, and `reagentc /enable` refused with *"Windows RE cannot be enabled on a volume with BitLocker Drive Encryption enabled."* `Test-BitLockerProtected` and `Suspend-BitLockerForWinRE` now treat any `VolumeStatus` other than `FullyDecrypted` (or an empty value) as unknown, so the destructive paths refuse to run.
- **New partitions are created with the recovery type GUID already applied.** `New-Partition` now passes `-GptType {de94bba4-06d1-4d40-a16a-bfd50179d6ac}` (GPT) or `-MbrType 0x27` (MBR) at creation. This closes the window between `New-Partition` and `Set-RecoveryPartitionAttributes` during which a plain Basic Data partition could be claimed by the Device Encryption service.

### Field reports

Two machines hit this bug in the same 24-hour window, both on Windows 11 build 26200 mid-Device-Encryption:

- **Dell Latitude 3550** (Intel Core Ultra 5 125U) — `VolumeStatus=EncryptionInProgress` at 73.6% when the script ran.
- **HP ProBook 450 15.6 inch G10** (Intel Core i7-1355U) — same state, same failure sequence.

Both machines lost their dedicated recovery partition and had WinRE disabled by the pre-patch-5 code. Recovery procedure: see [docs/troubleshooting.md](docs/troubleshooting.md).

### Unchanged

`ScriptVersion` remains 43. `DesiredStateId` is unchanged. Healthy machines do not rebuild.

## [v43 patch 4] — 2026-09-27

### Fixed

- **Checkpoint writes are now gated on injection success.** Previously the step 3, 4 and 6 checkpoint files advanced even when OEM or VMD injection failed. If a run was interrupted before its cleanup step, the next run would resume past step 3, deploy the un-injected WIM, and commit state for it — silently marking a broken deployment as healthy and disabling all future retries. The three writes are now conditional on `$Script:ImageInjectionComplete`. On a healthy run the behaviour is unchanged.
- **Migration guard for already-affected machines.** A machine already sitting on an orphaned step-4 or step-6 checkpoint from a pre-patch-4 run will have its `$step` reset to 2 whenever the current run also determines that a rebuild is required, forcing step 3 to re-run and injection to be retried. The guard runs after `$needInject` has been fully evaluated, so it catches both the "no state file at all" case and the "valid-but-stale state file" case.

`ScriptVersion` unchanged at 43. `DesiredStateId` unchanged. Healthy machines do not rebuild.

## [v43 patch 3] — 2026-09-27

### Fixed

- `Remove-OrphanPartition` now sets `GeometryRestoreFailed` when the newly created partition cannot be removed after a failure. The state file is then deleted on the write gate, forcing a full retry on the next run instead of preserving a shrunken OS partition indefinitely.
- The enable-only path and both pending-reboot exits now enforce the "no type-coded recovery partition on any non-OS disk" invariant, matching the fast path and Step 7. Previously a stray secondary-disk recovery partition could survive indefinitely on a machine whose WinRE was simply re-enabled.
- The pending-reboot success exit now honours `$Script:nonFatalWarning` before returning `EXIT_SUCCESS`.

## [v43 patch 2] — 2026-09-27

### Fixed

- The classifier now requires the reagentc-registered recovery partition to be on the **OS disk**. Previously a machine registered to a secondary-disk recovery partition could take the idempotent fast path and then have the fast-path cleanup delete the very partition reagentc was pointing at.
- `ActiveLocationWimPresent` now requires a successful WIM hash, not just a successful `Test-Path`. A file that exists but cannot be read no longer counts as evidence that the registered location is healthy.
- Post-shrink rollback gap closed. If all three shrink attempts fail, `Restore-OSPartitionSize` now runs before the fallback path so C: is not left shrunken.
- `Restore-OSPartitionSize` sets `GeometryRestoreFailed` on every failure path. `Write-WinREState` deletes the state file when that flag is set, forcing a fresh full-update run on the next invocation.
- The count=0 OS-fallback exemption additionally requires that the active WinRE location is on the OS partition.

## [v43 patch] — 2026-09-27

### Fixed

- Step 7's stray-partition cleanup extracted to `Remove-StrayRecoveryPartitions` and called from the idempotent fast path. Previously the fast path exited before Step 7, so a stray recovery partition on a non-OS disk survived indefinitely on machines whose state stayed idempotent.
- Fast-path exit now honours `$Script:nonFatalWarning`.

## [v43] — 2026-09-27

### Fixed

- Fallback copy no longer deletes its own source when `$SourceWim` and the fallback target resolve to the same file.
- Full update now forces a rebuild when no WIM is available at either the reagentc-registered location or the fallback search.

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

## [v41] — 2026-09-27

- `Remove-OrphanPartition` re-extends the OS partition to `SizeMax` after successfully deleting an orphan.
- The idempotent-run check examines the count of recovery partitions on the boot disk. Anything other than exactly one forces a full-update run.
- The "zero recovery partitions + OS-fallback state file" case is exempted from the rebuild policy.

## Earlier versions

v27 through v40 introduced: the download exception-on-success fix, vendor-native extraction (Lenovo Inno Setup, HP SoftPaq), Add-WindowsDriver return-shape workaround, recovery-partition attributes before drive-letter assignment, the 250 MiB free-space policy, `defrag /x` retry on shrink failure, and the tri-state BitLocker contract. Full engineering changelog in `scripts/WinRE.ps1`.
