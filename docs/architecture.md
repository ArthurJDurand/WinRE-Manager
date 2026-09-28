# Architecture

WinRE Manager is a single-file production script plus a read-only harness and three map builders. This document explains the design.

## What problem it solves

Windows' recovery environment is fragile. The five common failure modes are:

1. **Partition too small.** A Windows Update replaces `winre.wim` with a newer, larger one; the recovery partition no longer has room for it plus the Microsoft-documented servicing margin.
2. **BitLocker auto-encryption.** On Windows 11 24H2+ with TPM 2.0 and Secure Boot, `Device Encryption` auto-encrypts newly created partitions, including recovery partitions. `reagentc /enable` then refuses with *"Windows RE cannot be enabled on a volume with BitLocker Drive Encryption enabled."*
3. **Device Encryption in progress.** A subtler variant of the above. A volume can be actively encrypting (`VolumeStatus=EncryptionInProgress`) while `ProtectionStatus` reads `Off`. In that state the encryption service is running and will claim any new partition created on the disk, before the recovery type GUID can be applied. This is the failure mode fixed in v43 patch 5; it defeated the earlier reactive BitLocker handling because `ProtectionStatus=Off` was treated as sufficient evidence that BitLocker was not a factor.
4. **Missing storage drivers.** OEM WinPE driver packs and Intel VMD storage drivers are required for the recovery image to see the storage controller. Without them, recovery cannot find the OS.
5. **Stale registration.** A disk migration, clone, or manual `reagentc` operation leaves the registration pointing at a partition that no longer exists. Windows might silently fall back to `C:\Recovery\WindowsRE` (OS-fallback) — a functional but degraded state.

WinRE Manager addresses all five idempotently. The two hard requirements are:

- **Correct end state**: a single dedicated recovery partition, on the OS disk, correctly typed, containing the right WIM, with `reagentc` registered to it.
- **Do not disturb a healthy machine.** Running the script on a machine already in the correct end state must be a no-op.

Everything below is designed around those two requirements.

## The pipeline

The production script runs one of four control-flow paths. Three of them are short-circuits; the full-update path is the long one.

### Fast path (idempotent)

Entered when: WinRE is enabled, the state file matches, the currently-registered recovery partition is on the OS disk, exactly one recovery partition exists on the OS disk, and the deployed WIM hash matches the stored hash.

Effect: `Remove-StrayRecoveryPartitions` enforces the "no recovery partition on non-OS disks" invariant, then exits. This is a read-only scan on a healthy machine.

### Enable-only path

Entered when: WinRE is disabled but the current WIM is already correct (the state file matches and the WIM is present at the registered location).

Effect: `reagentc /setreimage` to re-point at the WIM, then `reagentc /enable`. If `reagentc /enable` returns a reboot-required result, the script writes the state file with `PendingReboot = true` and exits with code 1.

### Full-update path

Entered when: anything has changed — new Windows build, new driver manifest version, new OEM pack version, current WIM hash differs from stored, no state, or a classifier-detected problem such as a recovery partition on a secondary disk.

Effect: the eight-step pipeline. This is the long path.

### Pending-reboot path

Entered at the top of the run when the state file says `PendingReboot = true` and the state file's `DesiredStateId` matches the current one.

Effect: re-run `reagentc /enable` against the WIM path recorded in the state file. If it succeeds, clear the flag and exit. If it fails, increment `RepairAttempts` and either retry (up to 3 attempts) or exit fatally.

## The eight steps

The full-update path.

**Step 1 — Wipe WorkDir.**
Delete `C:\Temp\WinREWork\mount` and `C:\Temp\WinREWork\base.wim`. Checkpoint as `Step=1`.

**Step 2 — Obtain base WIM.**
If the current registered WIM is usable (present and readable at the reagentc-registered location, or a fallback), copy it to `WorkDir\base.wim`. Otherwise download from GitHub: fetch `winre.7z.NNN` parts, extract with 7-Zip, rename to `base.wim`. Checkpoint as `Step=2`.

**Step 3 — Mount, inject, dismount.**
Mount `base.wim` with `Mount-WindowsImage`. Capture the pre-injection third-party driver count via `Get-WindowsDriver`. Download the OEM pack (vendor-specific: CAB for Dell, EXE for Lenovo, SoftPaq EXE for HP), extract to a temp dir, `Add-WindowsDriver -Recurse`. Then, if VMD hardware is present and manifest VMD drivers match the CPU generation, download each VMD pack, extract, `Add-WindowsDriver`. Success gate: the package's INF basenames must appear in the mounted image's third-party drivers after injection, OR the pre/post delta must be > 0. See [driver-injection.md](driver-injection.md). Dismount with `-Save`. Checkpoint as `Step=3` **only if** `$Script:ImageInjectionComplete` is `$true` (v43 patch 4).

**Step 4 — Optimize.**
`dism /Export-Image /Compress:max` to `winre_optimized.wim`. The exit code is checked; a non-zero exit is fatal. Checkpoint as `Step=4` **only if** `$Script:ImageInjectionComplete` is `$true`.

**Step 5 — Ensure a suitable recovery partition.**
Two-step decision:

1. `Find-SuitableRecoveryPartition` scans the OS disk for existing recovery partitions. It accepts the candidate only if:
   - There is exactly one.
   - It is not the OS partition.
   - Its total size is at least `WIM + 250 MiB`.
   - Its effective free space (current free + existing WIM size) is at least `WIM + 250 MiB`.
   - Its encryption state is not confirmed encrypted.

2. If no candidate passes, `Ensure-AdequateRecoveryPartition` performs the destructive path: suspend BitLocker (refusing to proceed if the `VolumeStatus` is one of the hazardous mid-operation states — see the v43 patch 5 note below), disable WinRE, delete every recovery partition on the OS disk, extend the OS partition to its `SizeMax`, shrink it by `(bucketSizeMiB + 1) MiB`, create a new partition at the aligned offset with the recovery type GUID or type code already applied, format as NTFS with label `Recovery`, verify no auto-encryption occurred, and return.

   If the shrink fails after three attempts (immediate, after 10s sleep, after `defrag C: /x`), the OS partition size is restored via `Restore-OSPartitionSize`, the destructive attempt is abandoned, and the script falls through to OS-fallback — WinRE deployed to `C:\Recovery\WindowsRE` instead of a dedicated partition, with exit code 2.

**Step 6 — Deploy the WIM.**
Before disabling WinRE, `Suspend-BitLockerForWinRE` runs again as a second safety gate on the deployment path (v43 patch 5, revised). Then: copy the source WIM to the target directory. Verify SHA256. Set the file hidden + system. Call `reagentc /setreimage /path \\?\GLOBALROOT\device\harddiskX\partitionY\Recovery\WindowsRE`, then `reagentc /enable`. Write the state file with the deployed WIM hash. Clear the checkpoint.

**Step 7 — Enforce the single-recovery-partition invariant.**
`Remove-StrayRecoveryPartitions` deletes any type-coded recovery partition (GPT GUID `{de94bba4-...}` or MBR type `0x27`) on any non-OS disk. A partition on a non-OS disk that carries only a `Recovery` *label* but no type code is logged and skipped — label-only matches are not sufficient authority to delete on a secondary disk.

**Step 8 — Final verification.**
Re-read WinRE state. Classify the registered location: `DEDICATED` (recovery partition on OS disk), `OS-FALLBACK` (on the OS partition), or `UNEXPECTED` (neither). If dedicated, remove any temporary drive letter that the script assigned during the pipeline. If OS-fallback, warn that the run is degraded but functional.

## The four state-carrying artifacts

| Artifact | Path | Purpose | Lifetime |
|---|---|---|---|
| **State file** | `C:\Recovery\OEM\winre_state.json` | Records the deployed WIM hash and `DesiredStateId`. | Persists across runs. |
| **Checkpoint file** | `C:\ProgramData\OEM\Logs\winre_checkpoint.txt` | Records the highest completed step of the current pipeline. | Deleted at end of run. |
| **Log file** | `C:\ProgramData\OEM\Logs\WinRE-Manager.log` | Append-only event log. | Rotated by the operator, not by the script. |
| **WorkDir** | `C:\Temp\WinREWork` | Scratch space for mounts, downloads, and intermediate WIMs. | Deleted at Step 6. |

See [state-and-idempotency.md](state-and-idempotency.md) for the schemas and the crash-consistency model.

## The idempotency key

`DesiredStateId` is a SHA256 over a deterministic set of inputs:

```
HW=<Manufacturer>|<Model>|<MachineType>
OS=<Build>
MANIFEST=<manifest.version>
OEMPACK=<resolved OEM pack version or NONE>
SCRIPT=<ScriptVersion>
```

Any change to any of those five fields changes the ID. When the ID differs from the stored state file's ID, the state file is treated as stale and the script rebuilds. When the ID matches, the fast path can fire.

The design deliberately excludes things that change frequently but should not trigger a rebuild: the current date, the current WIM hash at the registered location (that's a separate check), and the machine's serial number.

## Control-flow invariants

These are the invariants the script maintains. Each one has a real field failure behind it; the `.NOTES` block in `scripts/WinRE.ps1` names them as "CRITICAL LESSONS LEARNED."

1. **Exactly one recovery partition exists, on the OS disk, correctly type-coded.** Enforced on the fast path, the enable-only path, both pending-reboot exits, and Step 7 of the full-update path. A type-coded recovery partition on any non-OS disk is deleted unconditionally. The invariant is absolute.
2. **No failure path leaves C: permanently shrunken.** Every post-shrink failure calls either `Remove-OrphanPartition` (which absorbs freed space back) or `Restore-OSPartitionSize`. Every failure of `Restore-OSPartitionSize` sets `$Script:GeometryRestoreFailed` so the state file is deleted and the next run retries from clean.
3. **The state-write gate is never relaxed.** `Write-WinREState` is only called when `$Script:ImageInjectionComplete` is `$true` and a WIM hash was computed. A failed injection never leaves a state file behind. The one exception is the pending-reboot path, which re-writes the existing state file with an updated `PendingReboot` flag but does not update the hash.
4. **BitLocker is never assumed Off.** All protection-state checks are tri-state (`$true` protected, `$false` unprotected, `$null` unknown). Additionally (v43 patch 5, revised), a volume with `ProtectionStatus=Off` is confirmed-safe **only if** `VolumeStatus` is `FullyDecrypted`, `FullyEncrypted`, or empty. `FullyEncrypted` with protection Off is the standard suspended-BitLocker state — what every machine enters after `Suspend-BitLocker` or a Windows Update suspension that has not yet been lifted — and is safe for destructive partition work. Any other `VolumeStatus` — `EncryptionInProgress`, `DecryptionInProgress`, `EncryptionPaused`, `DecryptionPaused` — is treated as unsafe. `Test-BitLockerProtected` returns `$null` (unknown) for that state, and `Suspend-BitLockerForWinRE` returns `$false` immediately without falling through to the generic `manage-bde` fallback. Any code path that would delete, resize, or format a partition refuses to proceed when the state is not confirmed-safe. The reason for this is subtle and was learned from field failure: on Windows 11 24H2+ with Device Encryption, a volume can be actively encrypting while `ProtectionStatus` reads `Off`, and in that state the encryption service claims any new partition before its recovery type GUID can be applied. The original v43 patch 5 implementation of `Suspend-BitLockerForWinRE` set an internal "unknown" sentinel in this branch and let the generic fallback run, which then read `Protection Off` from `manage-bde -status` and returned `$true` — reopening the exact fail-open path the patch was written to close. The branch now returns `$false` before the fallback can run. The guard is evaluated at two points in the pipeline — in `Ensure-AdequateRecoveryPartition`, before `reagentc /disable`; and in Step 5, before the deployment-path disable — and it is also evaluated under `-DryRun` so a pre-flight of a hazardous machine reports the hazard rather than logging destructive actions.
5. **New recovery partitions are created with the recovery type code already applied.** `New-Partition` passes `-GptType {de94bba4-06d1-4d40-a16a-bfd50179d6ac}` (GPT) or `-MbrType 0x27` (MBR) at creation time (v43 patch 5). This closes the window between `New-Partition` and `Set-RecoveryPartitionAttributes` during which the partition is a plain Basic Data partition. `Set-RecoveryPartitionAttributes` still runs after format to apply the GPT attributes (`0x8000000000000001` — PLATFORM_REQUIRED + NO_DRIVE_LETTER); it is idempotent on the type code. The attribute step still runs before any drive letter is assigned.
6. **Self-referential file operations are guarded.** Any block that deletes a file and then writes to the same path (or copies another file onto it) checks first that the source and destination are not the same file (by `[System.IO.Path]::GetFullPath`). This guards against the v42 "fallback copy ate its own source" bug.
7. **Checkpoint advancement requires injection success.** A checkpoint that says "step 3 completed" is only written when image injection actually completed. This is v43 patch 4's fix.

## Where the design choices bite

The two most consequential decisions in the whole script are:

- **Dedicated recovery partition is the primary objective; OS-fallback is the failure outcome.** The script will attempt the destructive repartitioning path even when the pre-check suggests the OS cannot shrink enough. If the attempt fails, the OS is restored and OS-fallback is used with exit code 2. This is a deliberate trade: try hard for the good outcome, fall back honestly when the attempt fails. The alternative — never try if the arithmetic is pessimistic — was tried in v37 and rejected because `SizeMin` is a hint, not a floor.

- **The `DesiredStateId`-scoped retry policy.** A machine in OS-fallback with a matching state file stays in OS-fallback indefinitely, without re-attempting the destructive path. A state change (script version bump, manifest update, hardware change, or a Windows build update changing the OS value) naturally re-arms the retry. This avoids re-shrinking the OS on every run of a machine that cannot shrink.

The v43 patch 5 change adds a third, smaller decision that nonetheless had outsized consequences in the field:

- **The BitLocker safety guard takes priority over the dedicated-partition objective.** When the machine is mid-Device-Encryption, the script refuses to run the destructive partition path even though the dedicated-partition path is the primary objective. This is a deliberate inversion of the primary-objective rule for a specific hazardous state: damaging the machine is worse than deferring the dedicated-partition work to the next run. The guard is evaluated at two points — in `Ensure-AdequateRecoveryPartition` before `reagentc /disable`, and in Step 5 before the deployment-path `reagentc /disable` — and it refuses on the hazardous `VolumeStatus` values, returning early with the machine's WinRE state and recovery partition intact. The main flow exits with `EXIT_WARNING`; no state file is written. The next run, once `VolumeStatus` is `FullyDecrypted` or `FullyEncrypted`, will attempt the dedicated partition. This is the correct trade: an extra pipeline run later is cheaper than an unusable machine now.

## A note on the v43 patch 5 field failures

The v43 patch 5 change was driven by two field failures on the same day, both on Windows 11 build 26200 with Device Encryption mid-encryption:

- **Dell Latitude 3550** (Intel Core Ultra 5 125U) — `VolumeStatus=EncryptionInProgress` at 73.6% when the script ran.
- **HP ProBook 450 15.6 inch G10** (Intel Core i7-1355U) — same state, same failure sequence.

Both machines lost their dedicated recovery partition and had WinRE disabled. The recovery procedure is documented in [troubleshooting.md](troubleshooting.md).

The failure is instructive because it was invisible to each function in isolation. `Test-BitLockerProtected` was correctly implementing the tri-state contract for the state it observed (`ProtectionStatus=Off`). `Suspend-BitLockerForWinRE` was correctly taking the "already off, no suspension needed" branch. `New-Partition` was correctly creating a partition. `Set-RecoveryPartitionAttributes` was correctly applying the recovery type GUID. Each function did exactly what it was written to do. The bug was in the composition: the two BitLocker functions queried a subset of the protection state that was insufficient evidence for the decision the downstream code made with the answer.

This is the class of failure that is hard to find in code review because no single function is wrong. It is found by watching the pipeline do something the operator knows is incorrect and tracing why each step thought it was fine.

## Related documents

- [state-and-idempotency.md](state-and-idempotency.md) — details on the state file, checkpoint file, and how they interact.
- [recovery-partition.md](recovery-partition.md) — the partition lifecycle in depth.
- [driver-injection.md](driver-injection.md) — injection and the success gate.
- [exit-codes.md](exit-codes.md) — every exit path.
