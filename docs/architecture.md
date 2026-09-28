# Architecture

WinRE Manager is a single-file production script plus a read-only harness and three map builders. This document explains the design.

## What problem it solves

Windows' recovery environment is fragile. The four common failure modes are:

1. **Partition too small.** A Windows Update replaces `winre.wim` with a newer, larger one; the recovery partition no longer has room for it plus the Microsoft-documented servicing margin.
2. **BitLocker auto-encryption.** On Windows 11 24H2+ with TPM 2.0 and Secure Boot, `Device Encryption` auto-encrypts newly created partitions, including recovery partitions. `reagentc /enable` then refuses with *"Windows RE cannot be enabled on a volume with BitLocker Drive Encryption enabled."*
3. **Missing storage drivers.** OEM WinPE driver packs and Intel VMD storage drivers are required for the recovery image to see the storage controller. Without them, recovery cannot find the OS.
4. **Stale registration.** A disk migration, clone, or manual `reagentc` operation leaves the registration pointing at a partition that no longer exists. Windows might silently fall back to `C:\Recovery\WindowsRE` (OS-fallback) — a functional but degraded state.

WinRE Manager addresses all four idempotently. The two hard requirements are:

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

2. If no candidate passes, `Ensure-AdequateRecoveryPartition` performs the destructive path: disable WinRE, suspend BitLocker, delete every recovery partition on the OS disk, extend the OS partition to its `SizeMax`, shrink it by `(bucketSizeMiB + 1) MiB`, create a new partition at the aligned offset, format as NTFS with label `Recovery`, set the recovery type GUID and GPT attributes **before** assigning a drive letter, verify no auto-encryption occurred, and return.

   If the shrink fails after three attempts (immediate, after 10s sleep, after `defrag C: /x`), the OS partition size is restored via `Restore-OSPartitionSize`, the destructive attempt is abandoned, and the script falls through to OS-fallback — WinRE deployed to `C:\Recovery\WindowsRE` instead of a dedicated partition, with exit code 2.

**Step 6 — Deploy the WIM.**
Copy the source WIM to the target directory. Verify SHA256. Set the file hidden + system. Call `reagentc /setreimage /path \\?\GLOBALROOT\device\harddiskX\partitionY\Recovery\WindowsRE`, then `reagentc /enable`. Write the state file with the deployed WIM hash. Clear the checkpoint.

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
