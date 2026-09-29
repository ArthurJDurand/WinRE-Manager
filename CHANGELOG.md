# Changelog

All notable user-facing changes to WinRE Manager are documented here.

This file is the authoritative user-facing record of what changed and when. The production script's `.NOTES` block records the current design invariants and the CRITICAL LESSONS LEARNED list; it is not a history. Together the two are the complete record.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to a `ScriptVersion` + patch-generation scheme rather than strict SemVer — see [docs/state-and-idempotency.md](docs/state-and-idempotency.md) for why.

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

### Field verification

- **Hyper-V VM, Win11 26200, 2026-09-30 00:29.** First run after the v44 patch: `DesiredStateId` mismatch on the state file written by v43 patch 5 (further revision 5) → full-update path. VMD hardware present = False, so `VMD=False` and `CPU=Intel|11` entered the new ID stably. WIM copied from the reagentc-registered recovery partition, mounted, dismounted, optimized (713.3 MiB), target partition accepted on size (980.1 MiB effective free, 963 MiB required), deployed, `reagentc /enable` succeeded, DEDICATED, state file written. Second run at 00:32: `DesiredStateId` match → fast path, drive letter removed, DEDICATED. No drive-letter leaks, no checkpoint residue.
- **ASUS desktop, Win11 26200, 2026-09-30 00:29.** Same sequence. Target partition accepted on size (1082.2 MiB effective free, 1006 MiB required). DEDICATED, state file written. Second run at 00:32: fast path, drive letter removed, DEDICATED.

### Migration note

Every managed machine performs one full-update pass on its next scheduled run. Healthy NVMe laptops take roughly 3–5 minutes of I/O and CPU. Machines with a suitable existing recovery partition re-use it; no partition work occurs on healthy machines. After the first full-update pass per machine, the state file records the new `DesiredStateId` and the fast path resumes permanently.

Machines whose state file recorded `PendingReboot = true` are treated as stale before the pending-reboot repair block runs, so the ID change triggers the full-update path instead. No machines are lost. Machines stuck in the enable-failure loop-breaker (`EnableFailureAttempts >= 3`) receive one fresh attempt under the new ID before the loop-breaker can fire again.

Rollback: change `$ScriptVersion` back to 43, revert the `Get-DesiredStateId` `$parts` array, and restore the previous `Get-HardwareObject` if the manufacturer normalisation differed. No data is lost; another fleet-wide rebuild occurs on the next run.

The read-only harness `Test-WinRE.ps1` moves from v14 to v15 in the same window. The harness has no `ScriptVersion` and no `DesiredStateId` of its own; its version is its own marker. A v14 harness run still reads the machine's state correctly, but its `Get-ThisMachineProfile` would compute a different `DesiredStateId` than production for a Lenovo or an unrecognised-OEM machine — that is the drift v15 closes.

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

### Unchanged

`ScriptVersion` remains 43. `DesiredStateId` is unchanged. Healthy machines do not rebuild. (The `DesiredStateId` was subsequently changed in [v44 patch 1](#v44-patch-1--2026-09-30).)

### Field evidence

- **VM test, 2026-09-29.** C: was `ProtectionStatus=Off`, `VolumeStatus=FullyEncrypted`, `KeyProtector: {}`. `reagentc /enable` against partition 4 (a dedicated recovery partition) succeeded. `reagentc /enable` against partition 3 (the OS volume), on the same machine in the same session, failed with *"Windows RE cannot be enabled on a volume with BitLocker Drive Encryption enabled."* This is the test that established the target-volume nature of reagentc's check.

- **VM test, 2026-09-29 (continued).** A newly created recovery partition (`R:`) was claimed by the Device Encryption service (`VolumeStatus=EncryptionInProgress` at 97.6%, no key protectors). `manage-bde -off R:` was run. After the `-off` completed, `manage-bde -status R:` reported `The volume R: could not be opened by BitLocker` — the definitive signal of a clean, BitLocker-unmanaged recovery partition — and R: stayed unmanaged. `reagentc /enable` then succeeded. This is the test that established that decrypt-in-place is safe.

- **Dell Latitude 3550 (Intel Core Ultra 5 125U, Windows 11 build 26200), pre-patch-5 log.** The script created a new partition on a machine mid-Device-Encryption, the Device Encryption service auto-encrypted it before the recovery type GUID could take effect, the delete-and-recreate retry hit the same problem, the script fell back to OS-fallback, and `reagentc /enable` refused on the encrypted OS volume. This is the failure the new policy is designed to prevent, and the log is the basis for the OS-fallback gate.

### Migration note

A machine running [v43 patch 5 (further revision)] will not rebuild on this revision: `ScriptVersion` is unchanged and the `DesiredStateId` is unchanged. A machine whose previous run deferred at the startup BitLocker gate will, on the next run, proceed normally if the target partition can be prepared. A machine whose previous run took the OS-fallback path on an encrypted C: will defer at the OS-fallback gate with a clear operator message.

The read-only harness `Test-WinRE.ps1` moves from v13 to v14 in the same window. The harness has no `ScriptVersion` and no `DesiredStateId`; the version is its own marker. A v13 harness run still reads the machine's BitLocker state correctly — only the warning text and the new target-partition block differ.

## [v43 patch 5 (further revision)] — 2026-09-29

> **Note.** The BitLocker policy described in this entry was superseded on the same day by [v43 patch 5 (further revision 5)](#v43-patch-5-further-revision-5--2026-09-29). The Audit Mode guard and the enable-failure counter introduced in this entry remain current. Read this entry as history for the BitLocker portions; read the newer entry for the current behaviour.

### Fixed

- **Audit Mode / OOBE / sysprep guard.** The script now refuses to run before any state-modifying action when Windows is not in a normal-running state. During Audit Mode, OOBE, and the sysprep generalize/specialize phases, `reagentc /enable` fails with `ERROR_CANCELLED` (`0x4c7`, 1223) regardless of the correctness of the deployed WIM or the state of the recovery partition. The previous code deployed successfully, failed at `/enable`, wrote a state file recording the deployment as complete, and then looped on every subsequent run — the state file matched, no rebuild was triggered, and the enable-only path retried `/enable` forever. The guard reads `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` → `ImageState` at startup, immediately after the log directory is ensured and before the hardware check. It proceeds only when `ImageState` is absent (some SKUs omit the key) or exactly `IMAGE_STATE_COMPLETE`; any other value defers with `EXIT_WARNING`, logs a clear message, and makes no WinRE or partition changes. Runs under `-DryRun` in the same read-only form (logs `Would defer` and continues). Field case: Dell Latitude 5530 (12th Gen Intel i7-1265U, Windows 11 build 26200) — the machine was in Audit Mode when the script first ran, `/enable` failed with `0x4c7` on two consecutive runs, and after the user completed OOBE and ran `reagentc /enable` manually it succeeded on the first attempt with the same WIM.
- **Enable-failure counter and loop-breaker.** The state file now records `LastEnableResult` (string) and `EnableFailureAttempts` (integer). Previously, a failed `reagentc /enable` did not affect the state-write gate: the run continued through Step 6 and Step 7, wrote the state file as if the deployment had completed, and exited `EXIT_FATAL` at the final-verification block. The next run accepted the state file, took the fast or enable-only path, and failed the same way — a permanent loop for any cause of `/enable` failure, not just Audit Mode. Three changes close this:
  - **The enable-only path no longer falls through to full update on `"failed"`.** A failed enable on the enable-only path increments the counter, writes the state file with the new counter value, and exits `EXIT_WARNING`. The deployment is already current; rebuilding it would not change the outcome. (Under the original further revision, `"bitlocker"` still fell through to the suspend + delete + recreate recovery path; that path was removed in further revision 5, and the counter now includes `"bitlocker"`.)
  - **A loop-breaker exits `EXIT_FATAL` after 3 consecutive failed enables.** When the state file records `EnableFailureAttempts >= 3`, a terminal `LastEnableResult`, and WinRE is still `Disabled`, the script logs a clear "manual intervention required" message, names the state file path, and exits without attempting anything else. The operator resolves the underlying cause and deletes the state file to reset the counter.
  - **The fast path clears stale counters.** When the idempotent fast path fires on a machine whose state file carries a non-zero `EnableFailureAttempts` or a `LastEnableResult` other than `"ok"`, the state file is rewritten with the counters reset. A healthy machine's counters are cleared on the first fast-path run after the underlying cause is resolved.

  Both new fields default to `"ok"` / `0` when read from state files written by earlier versions, so no rebuild is triggered by adding them.

### Changed

- **BitLocker state checks now consider `VolumeStatus`, not just `ProtectionStatus`.** On Windows 11 24H2+ with Device Encryption, a volume can be actively encrypting (`VolumeStatus=EncryptionInProgress`) while `ProtectionStatus` reads `Off`. In that state, the previous code logged *"already Off - no suspension needed"* and proceeded with the destructive partition path. The Device Encryption service then auto-encrypted any new partition before its recovery type GUID could be applied, and `reagentc /enable` refused with *"Windows RE cannot be enabled on a volume with BitLocker Drive Encryption enabled."* (Superseded by further revision 5: the check now targets the recovery partition, not C:.)
- **`FullyEncrypted` with `ProtectionStatus=Off` was treated as ambiguous, not safe.** (Superseded by further revision 5. Under the newer policy, this state is no longer relevant to the enable-only or full-update paths, because those now target the recovery partition, not C:. It is still relevant to the OS-fallback gate, where the target *is* C:.)
- **Startup BitLocker gate.** A read-only BitLocker check ran at startup, immediately after `Get-WinREState` and before the pending-reboot block or any state-modifying action. (Removed in further revision 5.)
- **Checkpoint file is preserved on deferral.** The deferral blocks no longer remove the checkpoint file. Deferring on BitLocker state does not invalidate any resumable step; steps 1–4 do not depend on BitLocker and the existing step guards handle resumption once the state is safe.
- **`-DryRun` no longer modifies WinRE registration.** Two code paths could modify state despite the "dry run modifies nothing" contract. First, `Ensure-AdequateRecoveryPartition`'s `reagentc /disable` call was not guarded. Second, `Invoke-ReagentcEnable` ran `reagentc /enable` unconditionally; the enable-only caller was guarded, but the pending-reboot path was not. Both are now closed with structural, not per-step, guards.
- **Lenovo machines with no published WinPE pack no longer re-run the full pipeline forever.** The v42 rule marked every supported-vendor run with no resolved OEM pack as incomplete and refused to write a state file. That was correct for Dell and HP (their maps are single-pack) and for a Lenovo map that failed to download. It was wrong for the common Lenovo case where the map loads successfully and simply has no entry for this machine type. The fix distinguishes "map loaded, no entry for this model" (expected and permanent) from "map failed to load" (transient).
- **New partitions are created with the recovery type GUID already applied.** `New-Partition` now passes `-GptType {de94bba4-06d1-4d40-a16a-bfd50179d6ac}` (GPT) or `-MbrType 0x27` (MBR) at creation. This closes the window between `New-Partition` and `Set-RecoveryPartitionAttributes` during which a plain Basic Data partition could be claimed by the Device Encryption service.

### Field reports

**Dell Latitude 5530** (12th Gen Intel i7-1265U, Windows 11 build 26200). Machine was in Audit Mode when `WinRE.ps1` was first run. The deployment completed successfully through Step 5, `reagentc /enable` failed with `0x4c7` on two consecutive runs, and the state file recorded the deployment as complete. After the user completed OOBE and ran `reagentc /enable` manually it succeeded on the first attempt with the same WIM. This is the case that motivated the Audit Mode guard.

### Unchanged

`ScriptVersion` remains 43. `DesiredStateId` is unchanged. Healthy machines do not rebuild.

## [v43 patch 5] — 2026-09-28

### Fixed

- **BitLocker protection-state checks now consider `VolumeStatus`, not just `ProtectionStatus`.** On Windows 11 24H2+ with Device Encryption, a volume can be actively encrypting (`VolumeStatus=EncryptionInProgress`) while `ProtectionStatus` reads `Off`. In that state, the previous code logged *"already Off - no suspension needed"* and proceeded with the destructive partition path. The Device Encryption service then auto-encrypted any new partition before its recovery type GUID could be applied, and `reagentc /enable` refused with *"Windows RE cannot be enabled on a volume with BitLocker Drive Encryption enabled."* `Test-BitLockerProtected` now returns `$null` (unknown) and `Suspend-BitLockerForWinRE` returns `$false` immediately — without falling through to the generic `manage-bde` fallback — for any hazardous `VolumeStatus`. Both refuse to treat the volume as unprotected, and the destructive partition paths abort.
- **`FullyEncrypted` with `ProtectionStatus=Off` is treated as ambiguous, not safe.** This state is the standard suspended-BitLocker state, but it is also indistinguishable from a Device Encryption volume in the *Waiting for Activation* state, where the volume has been encrypted with a clear key but protection has not been armed because the recovery key has not yet been escrowed. The two-field local view cannot tell the two apart. Both `Test-BitLockerProtected` and `Suspend-BitLockerForWinRE` now return `$null` / `$false` for this combination, and the destructive partition paths defer with `EXIT_WARNING`. (Superseded by further revision 5.)
- **Ownership guard on `Suspend-BitLockerForWinRE`.** The ambiguous-state classification above would otherwise have broken the healthy path. `Suspend-BitLockerForWinRE` short-circuited with `return $true` when `$Script:BitLockerSuspended` was set, so the ambiguous classification applied only to states observed at the start of the run. (Superseded by further revision 5: the function was removed.)
- **Startup BitLocker gate.** A read-only BitLocker check ran at startup, immediately after `Get-WinREState` and before the pending-reboot block or any state-modifying action. (Removed in further revision 5.)
- **Startup gate handles an unknown BitLocker state.** The gate fell back to `Test-BitLockerProtected` when `Get-BitLockerVolume` returned `$null`, and deferred on an unknown result. On machines where `manage-bde.exe` is absent, the gate was a no-op. (Removed with the gate in further revision 5.)
- **Startup gate runs under `-DryRun`.** (Removed with the gate in further revision 5.)
- **Checkpoint file is preserved on BitLocker deferral.** (Retained as a general principle in further revision 5.)
- **`-DryRun` no longer modifies WinRE registration.** Two code paths could modify state despite the "dry run modifies nothing" contract: `Ensure-AdequateRecoveryPartition`'s `reagentc /disable` call, and `Invoke-ReagentcEnable` on the pending-reboot path. Both closed with structural guards. (Retained and extended to the full-update pipeline in further revision 5.)
- **Lenovo machines with no published WinPE pack no longer re-run the full pipeline forever.** The v42 rule marked every supported-vendor run with no resolved OEM pack as incomplete. The fix distinguishes "map loaded, no entry for this model" (expected and permanent) from "map failed to load" (transient).
- **The BitLocker safety check in `Ensure-AdequateRecoveryPartition` runs before `reagentc /disable`.** The initial patch placed the check after the WinRE disable, so a refusal left the machine with WinRE disabled and no way to re-enable it until encryption finished — the exact damaged state the patch was written to prevent.
- **Step 5 performs the same BitLocker safety check before disabling WinRE.**
- **Fail-closed on BitLocker state in `Invoke-ReagentcEnable`.** `Invoke-ReagentcEnable` returned a distinct result `"blunsafe"` when BitLocker on C: was not confirmed unprotected. All three call sites aborted with `EXIT_WARNING`. (Removed in further revision 5.)
- **Stronger `manage-bde` fallback.** When `Get-BitLockerVolume` is unavailable and the fallback parses `manage-bde -status` text, `Protection Off` alone is no longer sufficient evidence of safety. Only a confirmed `Conversion Status: Fully Decrypted` makes the fallback return confirmed-unprotected.
- **`-DryRun` evaluates the BitLocker safety check.** The DryRun branch of `Suspend-BitLockerForWinRE` now queries `Get-BitLockerVolume` and returns `$false` on the hazardous states, so a dry run of a hazardous machine reports the hazard. (Superseded by further revision 5: the function was removed and the equivalent check lives in `Set-RecoveryPartitionReadyForWinRE`.)
- **New partitions are created with the recovery type GUID already applied.** `New-Partition` now passes `-GptType {de94bba4-06d1-4d40-a16a-bfd50179d6ac}` (GPT) or `-MbrType 0x27` (MBR) at creation.

### Field reports

Two machines hit this bug in the same 24-hour window, both on Windows 11 build 26200 mid-Device-Encryption:

- **Dell Latitude 3550** (Intel Core Ultra 5 125U) — `VolumeStatus=EncryptionInProgress` at 73.6% when the script ran.
- **HP ProBook 450 15.6 inch G10** (Intel Core i7-1355U) — same state, same failure sequence.

Both machines lost their dedicated recovery partition and had WinRE disabled by the pre-patch-5 code. Recovery procedure: see [docs/troubleshooting.md](docs/troubleshooting.md).

Two further Dell machines (a Pro Slim QCS1250 and a Vostro 16 5640) ran against a mid-encryption state after the further revision landed. The startup gate fired correctly on both: no partition was touched, no state file was written, and both runs exited with `EXIT_WARNING`. Both machines will complete the dedicated-partition deployment automatically on the next run after their encryption state stabilises.

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

v27 through v40 introduced: the download exception-on-success fix, vendor-native extraction (Lenovo Inno Setup, HP SoftPaq), Add-WindowsDriver return-shape workaround, recovery-partition attributes before drive-letter assignment, the 250 MiB free-space policy, `defrag /x` retry on shrink failure, and the tri-state BitLocker contract. Full engineering changelog is in the `.NOTES` block at the top of `scripts/WinRE.ps1`.
