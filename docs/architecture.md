# Architecture

WinRE Manager is a single-file production script plus a read-only harness and three map builders. This document explains the design — why the script makes the choices it does, what invariants it maintains, and what state it carries between runs.

If you are new to the project, start with the [README](../README.md). That page explains what the tool does, who it is for, and how to run it. This document assumes you already know those things and want to understand how the tool works under the hood.

## What problem it solves

Windows' recovery environment is fragile. The seven common failure modes are:

1. **Partition too small.** A Windows Update replaces `winre.wim` with a newer, larger one; the recovery partition no longer has room for it plus the Microsoft-documented servicing margin.
2. **BitLocker auto-encryption.** On Windows 11 24H2+ with TPM 2.0 and Secure Boot, `Device Encryption` auto-encrypts newly created partitions, including recovery partitions. `reagentc /enable` then refuses with *"Windows RE cannot be enabled on a volume with BitLocker Drive Encryption enabled."*
3. **Device Encryption in progress.** A volume can be actively encrypting (`VolumeStatus=EncryptionInProgress`) while `ProtectionStatus` reads `Off`. In that state the encryption service is running and will claim any new partition created on the disk, before the recovery type GUID can be applied. This is the failure mode fixed in v43 patch 5; the pre-patch-5 code treated `ProtectionStatus=Off` as sufficient evidence that BitLocker was not a factor, and two machines were damaged by it on the same day. See [troubleshooting.md](troubleshooting.md) for the recovery procedure.
4. **Missing storage drivers.** OEM WinPE driver packs and Intel VMD storage drivers are required for the recovery image to see the storage controller. Without them, recovery cannot find the OS.
5. **VMD hardware present but not in the deployed driver set.** A BIOS or firmware update can flip VMD on or off, or a CPU or motherboard swap can change the storage configuration, without changing `Manufacturer` / `Model` / `MachineType`. Under the v43 `DesiredStateId`, the machine would take the fast path with a stale driver set. The v44 patch 1 revision adds CPU vendor/generation and VMD presence to the `DesiredStateId` inputs so the machine rebuilds automatically. The v44 patch 6 revision makes the VMD hardware presence check itself fail-closed: if the check cannot be completed, the run defers rather than guessing that VMD is absent.
6. **Stale registration.** A disk migration, clone, or manual `reagentc` operation leaves the registration pointing at a partition that no longer exists. Windows might silently fall back to `C:\Recovery\WindowsRE` (OS-fallback) — a functional but degraded state.
7. **Audit Mode / OOBE / sysprep.** A freshly imaged machine that has not yet reached a normal desktop is in a transitional state where `reagentc /enable` is blocked with `ERROR_CANCELLED` (`0x4c7`, 1223) regardless of the correctness of the deployed WIM. The v43 patch 5 (further revision) startup guard detects this and defers — the script does not repair Audit Mode, it steps back from it. Without the guard, the deployment ran successfully, failed at `/enable`, wrote a state file recording the deployment as complete, and looped on every subsequent run.

WinRE Manager addresses all seven idempotently. The two hard requirements are:

- **Correct end state**: a single dedicated recovery partition, on the OS disk, **type-coded as a recovery partition**, containing the right WIM, with `reagentc` registered to it.
- **Do not disturb a healthy machine.** Running the script on a machine already in the correct end state must be a no-op.

Everything below is designed around those two requirements.

## The pipeline

The production script runs one of four control-flow paths. Three of them are short-circuits; the full-update path is the long one.

Before any of those paths is chosen, three things happen in order: the program lock is acquired, one startup guard runs, and one normalisation step runs. The lock is a mutual-exclusion primitive; the guard is read-only and can terminate the run early; the normalisation step is not a gate and does not defer.

The **program lock** is acquired first, immediately after the startup banner, before the Audit Mode guard and before any state-modifying action. `WinRE.ps1` opens `C:\ProgramData\OEM\Logs\WinREManager.lock` with an exclusive handle via `[System.IO.File]::Open($path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)`. The Windows kernel enforces the exclusive handle, so cross-session and cross-privilege exclusion are guaranteed by the OS. The handle is released automatically when the process exits, cleanly or after a crash — there is no stale-lock recovery logic. The lock is **not** acquired under `-DryRun`, because a dry run is read-only and safe to run concurrently with a live deployment. A second instance that cannot acquire the lock logs `Another WinRE Manager instance is already running (program lock file is exclusively held)` and exits `EXIT_WARNING` (code 2) without touching anything. If the lock cannot be acquired for a non-contention reason — a permission error, a missing `Logs` directory, or a transient filesystem issue — the script logs a WARN and proceeds without protection; the lock is defensive, and a broken lock must not prevent a legitimate deployment. See the "Control-flow invariants" section for the full discussion.

The **Audit Mode / OOBE / sysprep guard** runs second, before the hardware check. It reads `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` → `ImageState` and defers with `EXIT_WARNING` when the value is present and is not `IMAGE_STATE_COMPLETE`. During Audit Mode, OOBE, sysprep generalize, and sysprep specialize, `reagentc /enable` is blocked by the OS regardless of what the script has done; running the destructive partition path in these states accomplishes nothing and leaves a state file that would loop on every subsequent run. The guard is deliberately conservative: any value other than `IMAGE_STATE_COMPLETE` defers, and absence of the key is treated as safe (some SKUs omit it). Under `-DryRun` the guard logs `Would defer …` and continues.

The **drive-letter cleanup** then runs: any volume labelled `Recovery` or `WINRE` whose partition is not the boot or system partition and whose root does not contain a `Windows` directory has its drive letter removed. This is a defensive normalisation — those letters should never be persistent — and it is a no-op on a healthy machine.

BitLocker state is not consulted at startup. The v43 patch 5 (further revision 5) policy is target-volume-based, and the target volume is not known until the classifier has resolved the reagentc-registered location. The BitLocker decision is therefore made where the action is taken, not at startup. This is a deliberate departure from the v43 patch 5 (further revision) design, which had a startup BitLocker gate; that gate deferred on the OS volume state, and the OS volume state is irrelevant to the enable-only and dedicated-partition paths. The only place C:'s state is consulted is the OS-fallback route, because on that route the target volume *is* the OS volume. As of v44 patch 6, the destructive partition path does not consult C:'s state at all: the dedicated-partition path's objective is to create a dedicated partition, and it succeeds or fails on the partition geometry, not on C:'s encryption state. If the destructive attempt fails at the shrink step, the run falls through to OS-fallback, and the OS-fallback gate then checks C: and defers as designed. The residual corner in which this ordering loses the safety property is documented in the Step 5 discussion below.

### Fast path (idempotent)

Entered when: WinRE is enabled, the state file matches, the currently-registered recovery partition is **type-coded and** on the OS disk, exactly one **type-coded** recovery partition exists on the OS disk, and the deployed WIM hash matches the stored hash.

Effect: `Remove-StrayRecoveryPartitions` enforces the "no recovery partition on non-OS disks" invariant, any stale `PendingReboot` / `RepairAttempts` / `EnableFailureAttempts` counters and a stale `LastEnableResult` are cleared by a single state-file rewrite, and the script exits. This is a read-only scan plus, if needed, one small state-file write on a healthy machine.

If the manifest fetch failed and the state file's local safety checks pass, the fast path can also fire under the **offline fallback** (v44 patch 5). The script trusts the state file's stored `DesiredStateId` directly, skips the OEM pack resolution and VMD detection (both require the manifest), and exits `EXIT_WARNING` because `$Script:offlineFallback = $true`. The machine is unchanged; the exit code signals that the fast path was taken without a live manifest fetch. See the "Control-flow invariants" section and [state-and-idempotency.md](state-and-idempotency.md) for the residual risk.

### Enable-only path

Entered when: WinRE is disabled but the current WIM is already correct (the state file matches and the WIM is present at the registered location).

Effect: **prepare the target recovery partition first** via `Set-RecoveryPartitionReadyForWinRE`. This is the v43 patch 5 (further revision 5) change: reagentc's BitLocker check is on the target volume, not on C:, so the target must be unencrypted by the time `/enable` runs. The helper decrypts the target in place with `manage-bde -off` and polls for completion if needed, up to a 300-second timeout. It does not touch C:'s BitLocker state.

If the target cannot be made unencrypted, the enable-only path records the failure, increments the state file's `EnableFailureAttempts` counter, writes `LastEnableResult = "failed"`, removes the checkpoint file, and exits `EXIT_WARNING`. Otherwise it proceeds to `reagentc /setreimage` followed by `reagentc /enable`. Four possible outcomes from that call:

- **`"ok"`** — enable succeeded, no reboot required. Exit `EXIT_SUCCESS` (or `EXIT_WARNING` if a non-fatal warning was set).
- **`"reboot"`** — enable succeeded but requires a reboot. Write the state file with `PendingReboot = true` and exit `EXIT_REBOOT_REQUIRED` (code 1).
- **`"failed"`** — generic hard failure. Increment the state file's `EnableFailureAttempts` counter, write `LastEnableResult = "failed"`, remove the checkpoint file, and exit `EXIT_WARNING` (code 2). **The enable-only path deliberately does not fall through to full update on this outcome.** The deployment is already current; a rebuild would not change the outcome of the enable step. The next run will retry enable-only. After three consecutive failures the loop-breaker fires (see below).
- **`"bitlocker"`** — reagentc refused because the target volume is BitLocker-protected, even after the helper prepared it. Increment the counter with `LastEnableResult = "bitlocker"`, remove the checkpoint file, and exit `EXIT_WARNING`. This is rare under the new policy: it means either the Device Encryption service re-claimed the volume between preparation and `/enable`, or the target reagentc is checking is not the partition the helper prepared. The loop-breaker counts this alongside `"failed"`.

### Full-update path

Entered when: anything has changed — new Windows build, new driver manifest version, new OEM pack version, current WIM hash differs from stored, no state, a change in CPU generation or VMD presence that has moved the `DesiredStateId`, a classifier-detected problem such as a recovery partition on a secondary disk, or a label-only recovery partition on the OS disk that no longer qualifies as DEDICATED.

Effect: the eight-step pipeline. This is the long path. At the end of Step 6 the state file is written with a `LastEnableResult` and `EnableFailureAttempts` that reflect the run's `$enableResult`; on a `"failed"` or `"bitlocker"` outcome the counter is incremented, on any other outcome it resets to 0.

### Pending-reboot path

Entered at the top of the run when the state file says `PendingReboot = true` and the state file's `DesiredStateId` matches the current one.

Effect: prepare the target recovery partition via `Set-RecoveryPartitionReadyForWinRE`, then re-run `reagentc /enable` against the WIM path recorded in the state file. If the target cannot be prepared, defer with `EXIT_WARNING`. If `reagentc /enable` succeeds, clear the flag and exit. If it fails, increment `RepairAttempts` and either retry (up to 3 attempts) or exit fatally. The pending-reboot path resets the enable-failure counter to 0 on every write, because it represents a different failure mode tracked by a separate counter. The two counters are independent.

A **target-preparation failure** on the pending-reboot path does **not** increment `EnableFailureAttempts`. The exclusion is deliberate. Immediately after a reboot, the target partition's encryption state may be transiently indeterminate: the BitLocker service may not have finished enumerating the volume, the Device Encryption service may still be arming protection, or `manage-bde` may not yet report a stable state. A preparation failure that would resolve on its own within one poll cycle must not be counted against the enable-failure threshold, because the loop-breaker's purpose is to catch machines that are stuck on a genuine `/enable` failure, not machines that were polled a moment too early. The pending-reboot path is tracked exclusively by `RepairAttempts`; a preparation failure there defers the run and leaves the state file's enable-failure counter untouched.

### Loop-breaker

A separate check runs after the pending-reboot block and before the classifier. When the state file records `EnableFailureAttempts >= 3` **and** `LastEnableResult` is `"failed"` or `"bitlocker"` **and** WinRE is still `Disabled`, the script logs a "manual intervention required" message, removes the checkpoint file, and exits `EXIT_FATAL` (code 3). The state file is left in place; the log message names it and instructs the operator to delete it to reset the counter, once the underlying cause is resolved.

The predicate is deliberately narrow. `"bitlocker"` is included because a machine that keeps failing the enable step on the BitLocker error — even after the helper prepared the target — is in the same kind of loop as a machine failing generically, and the same manual intervention is required. `"blunsafe"` no longer exists as a return value; the fail-closed check that produced it is now the helper's job, and a failure to prepare the target is recorded as `"failed"`.

Under `-DryRun` the loop-breaker logs `Would refuse to retry …` and continues, matching the pattern used by the Audit Mode guard.

### Offline guard

When the manifest fetch fails after its retry budget, the script engages the **offline fallback** (v44 patch 5). It reads the state file's stored `DesiredStateId`, sets `$Script:offlineFallback = $true`, and skips the OEM pack resolution, the VMD detection, and the required-driver resolution, because all three depend on the manifest.

If the fast path fires under the offline fallback, the machine is validated and the run exits `EXIT_WARNING`. If the fast path does not fire — because the state file indicates a full update is needed — the run exits `EXIT_WARNING` before the full-update pipeline, having done nothing. If there is no state file at all, the run throws and exits `EXIT_FATAL`; a first deployment requires the live manifest.

The offline fallback trusts the state file's stored `DesiredStateId` **without verifying that the machine's local hardware still matches the inputs that produced it.** This is the residual risk. On a machine whose hardware changed while offline — a CPU swap, a BIOS update that flipped VMD, or a motherboard replacement that changed `Manufacturer` / `Model` / `MachineType` — the offline run could take the fast path with a stale DSI. The next successful manifest fetch detects the drift and forces a rebuild. A `LocalInputsId` field in the state file would close this; it is planned as its own version boundary. See [state-and-idempotency.md](state-and-idempotency.md) for the full discussion.

### VMD fail-closed guard (v44 patch 6)

When the manifest is available, the script determines VMD hardware presence by enumerating present PnP devices that match the union of the manifest's `requiredDevices` patterns. As of v44 patch 6 the enumeration is fail-closed: if `Get-PnpDevice` reports an error during the query, the run treats VMD presence as **indeterminate** rather than as absent.

An indeterminate result means the correct driver set cannot be determined. Proceeding on a guess would risk selecting a driver set that omits the VMD package on a machine that has VMD hardware; the resulting WinRE would not be able to see the OS disk, which is exactly the failure mode the v44 patch 1 `DesiredStateId` change was designed to prevent. The run logs the enumeration error, sets `$Script:nonFatalWarning = $true`, removes the checkpoint file, and exits `EXIT_WARNING` **before** committing any state. No WIM is deployed, no partition is touched, no `reagentc` call is made. The next run retries the enumeration.

Under `-DryRun` the check logs the enumeration error and continues; the exit is not predicted. See [troubleshooting.md](troubleshooting.md) for the resolution.

## The eight steps

The full-update path.

**Step 1 — Wipe WorkDir.**
Delete `C:\Temp\WinREWork\mount` and `C:\Temp\WinREWork\base.wim`. Checkpoint as `Step=1`.

**Step 2 — Obtain base WIM.**
If the current registered WIM is usable (present and readable at the reagentc-registered location, or a fallback), copy it to `WorkDir\base.wim`. Otherwise download from GitHub: fetch `winre.7z.NNN` parts, extract with 7-Zip, rename to `base.wim`. Checkpoint as `Step=2`.

As of v44 patch 6, the GitHub download path removes any stale `winre.wim` at `$WorkDir\winre.wim` before invoking 7-Zip, verifies that 7-Zip produced `winre.wim` after extraction, and removes any stale `base.wim` at `$WorkDir\base.wim` before the `Rename-Item` call. Before patch 6, an interrupted previous run could leave a `base.wim` in place at the moment the next run reached the rename; the rename would fail and the machine would not progress past Step 2 until an operator deleted `WorkDir` by hand. The v44 patch 3 fix added the same cleanup to the injection-failure abort branch; patch 6 extends it to the normal Step 2 path.

**Step 3 — Mount, inject, dismount.**
Mount `base.wim` with `Mount-WindowsImage`. Capture the pre-injection third-party driver count via `Get-WindowsDriver`. Download the OEM pack (vendor-specific: CAB for Dell, EXE for Lenovo, SoftPaq EXE for HP), extract to a temp dir, `Add-WindowsDriver -Recurse`. Then, if VMD hardware is present and manifest VMD drivers match the CPU generation, download each VMD pack, extract, `Add-WindowsDriver`. Success gate: the package's INF basenames must appear in the mounted image's third-party drivers after injection, OR the pre/post delta must be > 0. See [driver-injection.md](driver-injection.md).

Lenovo OEM pack resolution distinguishes five states as of v44 patch 6: `unknown-mt`, `map-unavailable`, `no-entry`, `malformed-entry`, and `resolved`. `unknown-mt` and `no-entry` are legitimate "no pack available for this machine" answers and let the run proceed with `OEMPACK=NONE`. `map-unavailable` and `malformed-entry` mark the run with `$Script:ImageInjectionComplete = $false`. The distinction matters because Lenovo does not publish WinPE driver packs for every model; before patch 6 a malformed map entry looked identical to a legitimate no-pack case, and the machine would silently complete without OEM driver injection.

Once injection is confirmed complete (`$Script:ImageInjectionComplete = $true`), run `dism /image:<MountDir> /cleanup-image /StartComponentCleanup /ResetBase` on the mounted image. ResetBase removes superseded components from the WinSxS store inside the image; the size reduction it represents does not appear in the `.wim` file on disk until the image is re-exported in Step 4. ResetBase failure is non-fatal: the log records a WARN with the DISM exit code and the pipeline continues. When injection failed, ResetBase is skipped — the pipeline aborts before Step 4 anyway, so the reset would only waste CPU.

Dismount with `-Save` to commit both the injected drivers and the ResetBase changes to `base.wim`. Checkpoint as `Step=3` **only if** `$Script:ImageInjectionComplete` is `$true` (v43 patch 4). After this block, if `$Script:ImageInjectionComplete` is `$false`, the pipeline exits with `EXIT_WARNING` before Step 4 (the v44 patch 1 pipeline gate), and the abort branch removes both `winre_optimized.wim` (stale from a previous run) and `base.wim` from `WorkDir`. Removing `base.wim` is the v44 patch 3 fix: without it, the next run's Step 2 would fail at `Rename-Item "$WorkDir\winre.wim" "base.wim"` because the destination file still exists, and the machine would not progress past Step 2 until an operator deleted `WorkDir` by hand.

**Step 4 — Optimize.**
`dism /Export-Image /Compress:max` to `winre_optimized.wim`. This is where the ResetBase savings from Step 3 are materialised on disk as a smaller file — ResetBase alone does not shrink the `.wim` because the export writes a fresh WIM from the modified component store. The exit code is checked; a non-zero exit is fatal. Checkpoint as `Step=4` **only if** `$Script:ImageInjectionComplete` is `$true`.

**Step 5 — Ensure a suitable recovery partition.**
Two-step decision:

1. `Find-SuitableRecoveryPartition` scans the OS disk for existing recovery partitions. It accepts the candidate only if:
   - There is exactly one.
   - It is not the OS partition.
   - **It is type-coded** — GPT recovery GUID `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}` or MBR type `0x27`. A partition detected only by a `Recovery` / `WINRE` volume label is not accepted, is not counted toward the "exactly one" condition, and is not reused.
   - Its total size is at least `WIM + 250 MiB`.
   - Its effective free space (current free + existing WIM size) is at least `WIM + 250 MiB`.

   Encryption state is **not** a rejection criterion. The target-volume policy means an existing encrypted recovery partition is usable — `Set-RecoveryPartitionReadyForWinRE` will decrypt it in place before reagentc is called.

2. If no candidate passes, `Ensure-AdequateRecoveryPartition` performs the destructive path. As of v45 patch 1 the pipeline is shrink-first: a read-only geometry plan runs before any state-modifying action; if the plan calls for a C: shrink, the shrink runs **before** `reagentc /disable` and **before** any partition deletion. A shrink failure at that point returns `Deferred` with the old route intact. If the shrink succeeds, the script disables WinRE, deletes every **type-coded** recovery partition on the OS disk (label-only matches are never deleted — the type-code gate is applied both before the loop and inside it, as a redundant check), extends C: into the reclaimed space if the plan called for it, creates a new partition at the aligned boundary with the recovery type GUID or type code already applied, formats as NTFS with label `Recovery`, asserts the whole layout, verifies no auto-encryption occurred, decrypts in place if the Device Encryption service claimed the partition anyway, and returns.

   The plan clamps the usable extent end to `diskSize − 1 MiB` before aligning, on both branches (v46 patch 1), so no partition — blocking or reclaimable — can push the aligned boundary past the disk-end reserve. The whole-layout assertion re-queries the newly created partition and confirms identity, exact offset, size within one alignment block, no overlap with C:, C:-to-recovery gap within one alignment block, and end at the aligned managed extent end. If the assertion fails, `Remove-OrphanPartition` cleans up and the run falls through to OS-fallback.

   C:'s encryption state is **not** consulted. The dedicated-partition path's objective is to create a dedicated partition; it succeeds or fails on the partition geometry, not on C:'s BitLocker state.

   **The safety property** — never leave a machine with no working recovery route — holds in the two ordinary cases:

   - **The destructive attempt succeeds.** The machine ends up with a working dedicated recovery partition; the OS-fallback gate is never reached and C:'s state is irrelevant.
   - **The destructive attempt fails before deletion.** No partition was destroyed; the existing recovery route is intact.

   It does not hold in one narrow corner: **a destructive attempt that fails *after* the existing recovery partition has already been deleted, on a machine whose C: is encrypted.** The v45 shrink-first reorder narrowed the trigger set — a shrink failure no longer reaches this corner because the shrink runs before deletion — but a `New-Partition` failure, a `Format-Volume` failure, a whole-layout assertion failure, a drive-letter assignment failure, or a post-delete extension failure can still reach it. In that corner, `Restore-OSPartitionSize` restores C:'s geometry and `Restore-PreviousWinRERoute` attempts to re-enable the previous route; if the route was restored but C: geometry did not verify, the distinct reason `recovery partition deletion failed; previous route restored but C: geometry restore unverified` is returned and `$Script:GeometryRestoreFailed` is set, so the state file is invalidated and the next run retries from clean (v46 patch 2). If the route could not be restored at all, the run returns `$null` and the main flow falls through to OS-fallback, where the OS-fallback gate checks C:, finds it encrypted, and defers. The machine ends with neither a dedicated recovery partition nor OS-fallback.

   This is a documented residual, not a design intention. The correct fix is a **post-failure** check in the post-deletion failure branches that attempts an immediate `reagentc /enable` against `C:\Recovery\WindowsRE` before exiting — closing the corner and shortening the `disable` → `enable` window in the failure case. That fix is gated on the deliberate post-deletion failure test documented in [testing.md](testing.md). See the `[v44 patch 7]` and `[v45 patch 1]` CHANGELOG entries for the field evidence and the four preconditions.

   As of v46 patch 2, the destructive sequence also fails closed if the active WinRE route cannot be resolved to a partition (pre-deletion resolver guard) or if the OS partition cannot be resolved for the layout assertion (assertion fail-closed branch).

**Step 6 — Deploy the WIM.**
First, prepare the target: `Set-RecoveryPartitionReadyForWinRE` on the recovery partition, or — for the OS-fallback route — a check on C:'s `VolumeStatus` that defers unless it is `FullyDecrypted`. The OS-fallback check exists because reagentc refuses to enable WinRE on an encrypted OS volume, always. The script never modifies C:'s BitLocker state.

Then: copy the source WIM to the target directory. Verify SHA256. Set the file hidden + system. Call `reagentc /setreimage /path \\?\GLOBALROOT\device\harddiskX\partitionY\Recovery\WindowsRE`, then `reagentc /enable`. Write the state file with the deployed WIM hash **and** the enable outcome (`LastEnableResult`, `EnableFailureAttempts`). Clear the checkpoint.

**Step 7 — Enforce the single-recovery-partition invariant.**
`Remove-StrayRecoveryPartitions` deletes any type-coded recovery partition (GPT GUID `{de94bba4-...}` or MBR type `0x27`) on any non-OS disk. A partition on a non-OS disk that carries only a `Recovery` *label* but no type code is logged and skipped — label-only matches are not sufficient authority to delete on a secondary disk. As of v46 patch 2, the `Get-Partition -DiskNumber` calls inside `Get-RecoveryPartitions` carry `-ErrorAction SilentlyContinue`, so a disk that exposes no partitions — an SD/MMC card reader, an empty USB enclosure — does not throw `CmdletizationQuery_NotFound_DiskNumber`.

**Step 8 — Final verification.**
Re-read WinRE state. Classify the registered location: `DEDICATED` (recovery partition on OS disk), `OS-FALLBACK` (on the OS partition), or `UNEXPECTED` (neither). A partition detected only by a `Recovery` / `WINRE` volume label — with no matching type code — does not reach `DEDICATED`; it falls through to `UNEXPECTED`. If dedicated, remove any temporary drive letter that the script assigned during the pipeline. If OS-fallback, warn that the run is degraded but functional.

## The six state-carrying artifacts

| Artifact | Path | Purpose | Lifetime |
|---|---|---|---|
| **State file** | `C:\Recovery\OEM\winre_state.json` | Records the deployed WIM hash, `DesiredStateId`, and the enable outcome (`LastEnableResult`, `EnableFailureAttempts`). | Persists across runs. |
| **Checkpoint file** | `C:\ProgramData\OEM\Logs\winre_checkpoint.txt` | Records the highest completed step of the current pipeline. | Deleted at end of run. |
| **Log file** | `C:\ProgramData\OEM\Logs\WinRE-Manager.log` | Append-only event log. | Rotated by the operator, not by the script. |
| **Program lock file** | `C:\ProgramData\OEM\Logs\WinREManager.lock` | Exclusive-handle target for the single-instance guarantee (v44 patch 4). | Persists across runs; the file's existence is not the lock, the open handle is. |
| **Partition deferral marker** | `C:\Recovery\OEM\winre_partition_deferred.json` | Suppresses identical retries of the pre-shrink deferral while the old route remains verified functional (v45 patch 1). | Persists across runs until cleared; cleared on DSI mismatch, on the route becoming non-functional, or when the fast path would fire. |
| **WorkDir** | `C:\Temp\WinREWork` | Scratch space for mounts, downloads, and intermediate WIMs. | Deleted at Step 6. |

See [state-and-idempotency.md](state-and-idempotency.md) for the schemas and the crash-consistency model.

## The idempotency key

`DesiredStateId` is a SHA256 over a deterministic set of inputs:

```
HW=<Manufacturer>|<Model>|<MachineType>
OS=<Build>
CPU=<vendor>|<generation or N>
VMD=<present|absent>
MANIFEST=<manifest.version>
OEMPACK=<resolved OEM pack version or NONE>
SCRIPT=<ScriptVersion>
```

Any change to any of those seven fields changes the ID. When the ID differs from the stored state file's ID, the state file is treated as stale and the script rebuilds. When the ID matches, the fast path can fire.

The `CPU` and `VMD` inputs were added in v44 patch 1. They capture the two hardware inputs that determine VMD driver selection, which the v43 ID did not cover. The `CPU` field is `vendor|generation`, with the literal string `N` when the generation cannot be parsed (AMD, Intel Celeron/Pentium/Atom/Xeon, N/J-series). The `VMD` field is `present` or `absent`, computed from the union of manifest `requiredDevices` matched against present PnP devices.

The design deliberately excludes things that change frequently but should not trigger a rebuild: the current date, the current WIM hash at the registered location (that's a separate check), and the machine's serial number. It also deliberately does not hash the actual resolved driver list, on the reasoning that the manifest `version` field plays that role and the resolved-inputs approach would be a larger change that deserves its own version boundary.

`LastEnableResult` and `EnableFailureAttempts` are *not* part of the `DesiredStateId` — they are runtime counters that affect the control-flow decision, not the identity of the deployment. A machine with a non-zero counter is still "the current deployment" as far as the state-file comparison is concerned; the counter tracks the *enable* step's history, not the *deploy* step's identity.

The deferral marker (v45 patch 1) is also *not* part of the `DesiredStateId`. Its `DesiredStateId` field records the DSI under which the deferral was written, but the marker's presence does not change the DSI. A machine with a marker written under the current DSI is treated as "the current deployment, but the destructive sequence failed for it" — the marker suppresses retries without redefining the deployment identity.

The offline fallback (v44 patch 5) does **not** recompute the DSI from cached inputs; it trusts the state file's stored value. This is documented in [state-and-idempotency.md](state-and-idempotency.md) as the residual risk that the planned `LocalInputsId` field would close.

## The four design invariants

Every decision in WinRE Manager is subordinate to four rules, in this order.

1. **Never break Windows RE.**
2. **Never leave a machine without a working recovery route** — to the extent the machine, its OS, and its storage stack allow.
3. **Minimize the `reagentc /disable` → `reagentc /enable` window.**
4. **Do no work unless needed. When work is needed, prepare everything before touching anything.**

Rules 1–3 are **invariants**: they hold for every run, and no code change may weaken them. Rule 4 is the **working rule**: it is the discipline by which rules 1–3 are mostly enforced. It is subordinate in authority but not in importance — it is the mechanism.

The control-flow invariants list that follows is the detailed enforcement, one entry per guarantee. The wrong-question narrative at the end of the document is the reasoning behind each of them.

### Rule 1 — never break Windows RE

Every guarantee that a WinRE Manager run cannot make the recovery environment worse than it found it. A read-only plan cannot break anything. A failed pre-shrink in the reversible window cannot break anything. A fail-closed guard cannot break anything. A sequence that requires every preparation to complete before destruction begins never starts a partition operation it cannot finish.

| Guarantee | Enforced by |
|---|---|
| The destructive sequence refuses to begin if the layout cannot be proved safe. | `Get-PartitionPlan` rejection — thirteen refusal conditions, all logged with a reason. |
| A volume label alone never authorizes deletion or reuse. | Type-code gate in the delete loop, in `Find-SuitableRecoveryPartition`, and in `Remove-StrayRecoveryPartitions`. |
| The currently-active recovery partition is deleted last. | Delete ordering in `Ensure-AdequateRecoveryPartition`. |
| The sequence refuses to begin if the active WinRE route cannot be resolved to a partition. | v46 patch 2 pre-deletion resolver guard. |
| The layout assertion fails closed if the OS partition cannot be resolved for the adjacency check. | v46 patch 2 fail-closed branch in `Assert-RecoveryPartitionLayout`. |
| Recovery-typed partitions over 2 GiB are never deleted or reused. | Ceiling enforced in the plan, in `Find-SuitableRecoveryPartition`, and in `Remove-StrayRecoveryPartitions`. |
| The extension-failure fallback never creates a partition larger than the planned bucket. | v46 patch 2 bucket cap in the fallback branch. |
| No failure path leaves C: permanently shrunken. | `Restore-OSPartitionSize` on every post-shrink failure path; `$Script:GeometryRestoreFailed` invalidates the state file. |
| A failed injection never reaches deployment. | Step 3 → Step 4 pipeline gate on `$Script:ImageInjectionComplete`. |
| A newly created partition has no window where it is a plain Basic Data partition. | Recovery type code applied at `New-Partition` time. |
| The target recovery partition is unencrypted before `reagentc /enable` is called. | `Set-RecoveryPartitionReadyForWinRE` before every reagentc invocation. |
| Two runs never collide on the same machine. | `FileShare.None` program lock held for the process lifetime. |

### Rule 2 — never leave a machine without a working recovery route

Rule 1 is about not damaging what is there. Rule 2 is about what happens after a failure: the machine should end in a state that still has a usable recovery environment, or should fail in a way that leaves the previous route intact.

| Guarantee | Enforced by |
|---|---|
| A pre-shrink failure leaves the old recovery route `Enabled` and untouched. | Shrink-first ordering (v45 patch 1); `Restore-OSPartitionSize` restores the pre-attempt C: size. |
| A deletion failure attempts to restore the previous route. | `Restore-PreviousWinRERoute` — restores C:, re-registers the previous partition, verifies the location matches. |
| A deferral marker suppresses identical retries only while the old route is verified functional. | `Test-DeferredWinRERouteFunctional` gate on the marker. |
| When the dedicated-partition route cannot complete, the OS-fallback route is attempted as a last resort. | Main-flow OS-fallback fall-through, guarded by the OS-fallback gate for encrypted C:. |
| The fallback WIM at `C:\Recovery\WindowsRE\winre.wim` is refreshed on every successful deploy. | Deployment-tail copy, guarded against self-reference. |
| The state file is invalidated when C: geometry cannot be verified, forcing a clean retry from scratch. | `$Script:GeometryRestoreFailed` → state-file deletion in `Write-WinREState`. |

**The residual corner, named honestly.** Rule 2 cannot be *guaranteed* in the case where the old recovery partition has already been deleted, a later step fails, and C: is encrypted — the OS-fallback gate refuses on encrypted C:, so the machine ends with neither a dedicated partition nor a working route until the next run. The v45 shrink-first reorder narrowed this corner without closing it: the shrink is no longer the trigger, but a post-deletion create, format, layout-assertion, drive-letter, or extension failure is. The gating post-deletion failure test documented in [testing.md](testing.md) is the mechanism that will close it. See the `[v44 patch 7]` and `[v45 patch 1]` entries in the CHANGELOG for the field evidence and the design reasoning.

### Rule 3 — minimize the `reagentc /disable` → `reagentc /enable` window

For the duration of that window, WinRE is not registered: `reagentc /info` reads `Disabled`, and `reagentc` will refuse to hand off to a recovery image. The script therefore runs **everything that does not strictly require a disabled WinRE before the disable**, and **only the operations that require a disabled WinRE inside the window**.

**Before the window:**

- Manifest fetch, OEM pack resolution and download, VMD package resolution and download, driver extraction and INF validation.
- Base WIM acquisition — registered copy, fallback copy, or GitHub — and verification.
- Image mount, driver injection, ResetBase, export, `WIM_READY` checkpoint, `base.wim` cleanup.
- Read-only geometry plan, free-space check, pre-shrink (with its sleep and defrag retries), post-shrink verification and actual-geometry recomputation.
- Pre-deletion inventory, pre-deletion resolver guard.

**Inside the window:**

- Partition delete.
- Post-delete C: extension.
- `New-Partition`, `Format-Volume`, `Set-RecoveryPartitionAttributes`, drive-letter assignment.
- WIM copy to the new partition, hash verification.
- `reagentc /setreimage` and `reagentc /enable`.

**After the window:**

- Fallback WIM refresh, stray-partition cleanup, final verification, state write.

The longest operation inside the window is the WIM copy — typically 700–1000 MiB onto a freshly created partition. It cannot be moved out: the partition being replaced is the one the WIM is being deployed to. Everything else that can be moved out has been.

**Why this matters operationally.** If the machine loses power, blue-screens, or is forced off inside the window, `reagentc` is left disabled and the recovery partition is in whatever state the interruption left it — either intact (interruption before the delete) or partially created (interruption during the create sequence). The shorter the window, the smaller the exposure. The single-run recovery story is: `Restore-PreviousWinRERoute` on delete failure; `Remove-OrphanPartition` plus `Restore-OSPartitionSize` on create failure; the enable-only path on a clean-but-disabled state. The crash-inside-the-window case is not fully covered today — the same post-deletion failure test that gates the eventual fix for Rule 2's residual also gates the eventual fix for this one.

### Rule 4 — do no work unless needed; prepare everything before touching anything

This is the working rule. It is subordinate to 1–3 in that any conflict resolves in favor of 1–3, but it is the mechanism through which 1–3 are enforced on the fast path and the enable-only path, and through which the destructive path is made to fail safe.

**"Do no work unless needed"** — three tiers:

- **Tier 1 (fast path).** State file matches, image is current, partition is correct. Exit in under a second. No WIM mounted, no partition touched, no `reagentc` call.
- **Tier 2 (enable-only).** Image current, WinRE disabled. Prepare the target partition and call `reagentc /enable`. No partition geometry change, no rebuild, no C: shrink.
- **Tier 3 (full update).** The image is missing, stale, or the partition is wrong-sized. This is the only tier that does destructive work.

**"Prepare everything before touching anything"** — the mandatory ordering inside Tier 3:

1. Resolve the manifest, the OEM pack, the VMD packages. Resolve the base WIM source.
2. Download and verify every external artifact — hash check against the manifest-declared values; INF-count check after extraction.
3. Only when every artifact is verified: mount the base WIM, normalise its third-party driver set, inject the resolved drivers, run ResetBase, export the optimized WIM, checkpoint `WIM_READY`.
4. Only when the image is ready: run the read-only geometry plan.
5. Only when the plan is valid: run the pre-shrink in the reversible window.
6. Only when the pre-shrink has verified: enter the destructive window.

**The failure semantics of Rule 4.** If driver download fails, or OEM pack extraction produces zero INFs, or the VMD package cannot be resolved for the CPU generation, or the base WIM cannot be verified — the script stops before it touches the recovery partition. The old recovery route stays intact. The run exits `EXIT_WARNING` with a named reason in the log. Nothing is destroyed in the service of a rebuild that could not have succeeded anyway.

This is exactly how Rule 4 reinforces Rules 1 and 2: the destructive sequence is only reachable through a chain of successful preparations, so no partition operation is ever performed as preparation for another partition operation that might fail. Every failure point has been moved into the reversible window or excluded from the pipeline entirely.

**"Drivers go into a clean base"** is a corollary of Rule 4 for the image-servicing step. The recovery image on a machine that has ever run the script carries *our* previously injected OEM and VMD drivers. Before new drivers are injected, the image is normalised so the injection targets a clean baseline rather than a stale one with our own prior layers still present. Without that normalisation, the effective driver set is a function of the image's own prior history, and the deployment identity stops being a reliable fingerprint of the image contents. The mechanism by which normalisation is achieved is a separate design decision and is tracked as its own work item; this invariant states the requirement, not the mechanism.

## Control-flow invariants

These are the invariants the script maintains, in the order they are enforced. Each one has a real field failure behind it, except where explicitly noted; the `.NOTES` block in `scripts/WinRE.ps1` names them as "CRITICAL LESSONS LEARNED." They are the detailed enforcement of Rules 1–4 above.

1. **Exactly one type-coded recovery partition exists, on the OS disk.** Enforced on the fast path, the enable-only path, both pending-reboot exits, and Step 7 of the full-update path. A type-coded recovery partition on any non-OS disk is deleted unconditionally. A partition detected only by a Recovery/WINRE volume label is not counted, not reused, and not deleted — a label alone is never sufficient authority for any of those decisions. The invariant is absolute; the type code, not the label, is what identifies a recovery partition for every decision the script makes.

2. **No failure path leaves C: permanently shrunken.** Every post-shrink failure calls either `Remove-OrphanPartition` (which absorbs freed space back) or `Restore-OSPartitionSize`. Every failure of `Restore-OSPartitionSize` sets `$Script:GeometryRestoreFailed` so the state file is deleted and the next run retries from clean.

3. **The state-write gate is never relaxed.** `Write-WinREState` is only called when `$Script:ImageInjectionComplete` is `$true` and a WIM hash was computed. A failed injection never leaves a state file behind. The one exception is the pending-reboot path, which re-writes the existing state file with an updated `PendingReboot` flag but does not update the hash.

4. **The pipeline stops before deployment when injection fails.** If `$Script:ImageInjectionComplete = $false` after Step 3, the script exits with `EXIT_WARNING` before Step 4 (`dism /Export-Image`), before Step 5 (partition work), before Step 6 (deployment), and before any `reagentc` call. The state-write gate alone would prevent the state file from recording the run, but it would not prevent the deployment of a WIM with no OEM or VMD drivers. The explicit pipeline gate closes that gap. This is the v44 patch 1 gate. The abort branch also removes `base.wim` and `winre_optimized.wim` from `WorkDir` so the next run's Step 2 can rename cleanly; this is the v44 patch 3 fix.

5. **Component cleanup runs on the mounted image before export, and is non-fatal.** `dism /cleanup-image /StartComponentCleanup /ResetBase` runs inside Step 3 after successful injection and before the dismount, gated on `$Script:ImageInjectionComplete`. The size benefit is not realised until Step 4's `dism /Export-Image` writes a fresh `.wim`. ResetBase failure is logged and the pipeline continues; the export writes whatever size the image currently is, and the Step 5 partition acceptance check decides whether the result fits. ResetBase makes the image unserviceable for rollback (updates present when it ran can no longer be uninstalled), which is acceptable for a recovery image that is rebuilt from source whenever the `DesiredStateId` changes. This is the v44 patch 2 addition.

6. **BitLocker is never assumed Off, and the target volume is prepared before reagentc is called.** This is the v43 patch 5 (further revision 5) policy. It replaces the OS-volume-gate policy of the earlier further revision, which the 2026-09-29 field test disproved: reagentc's BitLocker check is on the **target** volume, not on C:. The invariant is now:

   - **The target recovery partition must be unencrypted by the time `reagentc /enable` runs.** `Set-RecoveryPartitionReadyForWinRE` enforces this. It queries the target's BitLocker state with `Test-VolumeEncrypted` (the tri-state classifier). If the target is confirmed unencrypted, it returns immediately. If it is encrypted or actively encrypting, it runs `manage-bde -off` against the target and polls at 5-second intervals up to a 300-second timeout, until the volume reports confirmed-unencrypted. It is called at every point where reagentc will be invoked: the enable-only path, the full-update path with an existing recovery partition, the full-update path with a newly created partition, and the pending-reboot repair path.

   - **The OS-fallback path is the only path that depends on C:'s BitLocker state.** In the OS-fallback case the target volume *is* the OS volume, and reagentc will refuse to enable WinRE on an encrypted OS volume. The OS-fallback gate therefore checks C:'s `VolumeStatus` before deploying the WIM and defers with `EXIT_WARNING` unless it is `FullyDecrypted`. It never modifies C:'s state — decrypting the OS volume is hours of I/O, changes the recovery key relationship, and the OS volume is the user's data. The gate uses `Test-VolumeEncrypted` (not `Get-BitLockerVolume` directly) and requires the result to be exactly `$false`, so a machine whose BitLocker module is unavailable is still classified correctly.

   - **Suspension is not used.** The v43 patch 5 function `Suspend-BitLockerForWinRE` was deleted. Suspension does not prevent Device Encryption from claiming a newly created partition — proven by the Dell Latitude 3550 pre-patch-5 log and by the 2026-09-29 test — and it is useless for OS-fallback, where reagentc refuses regardless. Decrypting the target in place is the mechanism the policy uses; the 2026-09-29 test confirmed that a partition claimed by Device Encryption does not re-encrypt after `manage-bde -off` completes.

   - **The target may be an existing encrypted recovery partition.** `Find-SuitableRecoveryPartition` no longer rejects encrypted candidates, because the helper will decrypt them. This preserves partitions that would previously have been destroyed and recreated.

   **Why the policy was inverted.** The earlier further revision gated on C:'s state because the pre-patch-5 failure had the shape "C: was mid-encryption, the script created a new partition, the encryption service claimed it, and reagentc refused." But the 2026-09-29 test showed the same C: state that failed on the OS volume succeeded on a dedicated recovery partition. The failure was not about C: at all. It was about the target volume being encrypted — and the target volume gets encrypted by two paths: the OS-fallback path (where the target *is* C:) and the new-partition path (where the Device Encryption service claims the new partition before the recovery type GUID can take effect). The v43 patch 5 (further revision 5) policy addresses both directly: it prepares whatever target the deploy step intends to use, and the v44 patch 6 follow-up removes C: from the destructive path's decision surface entirely, leaving the type-code-at-creation plus decrypt-in-place mechanism to handle the new-partition claim.

7. **New recovery partitions are created with the recovery type code already applied.** `New-Partition` passes `-GptType {de94bba4-06d1-4d40-a16a-bfd50179d6ac}` (GPT) or `-MbrType 0x27` (MBR) at creation time (v43 patch 5). This closes the window between `New-Partition` and `Set-RecoveryPartitionAttributes` during which the partition is a plain Basic Data partition. `Set-RecoveryPartitionAttributes` still runs after format to apply the GPT attributes (`0x8000000000000001` — PLATFORM_REQUIRED + NO_DRIVE_LETTER); it is idempotent on the type code. The attribute step still runs before any drive letter is assigned.

8. **Self-referential file operations are guarded.** Any block that deletes a file and then writes to the same path (or copies another file onto it) checks first that the source and destination are not the same file (by `[System.IO.Path]::GetFullPath`). This guards against the v42 "fallback copy ate its own source" bug.

9. **Checkpoint advancement requires injection success.** A checkpoint that says "step 3 completed" is only written when image injection actually completed. This is v43 patch 4's fix.

10. **The Audit Mode / OOBE / sysprep guard runs before any state-modifying action.** The guard reads `ImageState` at startup and defers unless the value is absent or `IMAGE_STATE_COMPLETE`. This is the highest-priority guard in the script after the program lock, and it runs before the drive-letter cleanup, the pending-reboot block, the classifier, and any partition work. It exists because on a machine that has not yet reached a normal desktop, `reagentc /enable` is blocked by the OS and the destructive partition work would be wasted while producing a state file that loops.

11. **A `reagentc /enable` failure on the enable-only path does not fall through to full update, and does not loop forever.** When the deployment is current and only the enable step fails — whether with a generic `"failed"` outcome or a `"bitlocker"` outcome after the target was prepared — the enable-only path increments the state-file counter and exits `EXIT_WARNING` without attempting a rebuild. After three consecutive failures the loop-breaker fires and exits `EXIT_FATAL`, requiring manual intervention. This invariant closes the loop that was introduced by the state-file-records-complete behaviour before v43 patch 5's further revision.

12. **The state file never records `DeployedDiskNumber` or `DeployedPartitionNumber` as `0` for OS-fallback states.** An OS-fallback state file does not have those fields, because the fallback target is `C:\Recovery\WindowsRE`, not a partition by number. The `Write-WinREState` parameters are `[object]` typed and the conditional that populates the state file checks `$null -ne` before the integer comparison, so a `$null` argument does not coerce to `0` and write a misleading `"DeployedDiskNumber": 0` into the state file. This is the v44 patch 1 fix.

13. **The script holds an exclusive program lock for its entire duration, from just after the startup banner to the last cleanup step in the `finally` block.** The lock is a `FileShare.None` handle on `C:\ProgramData\OEM\Logs\WinREManager.lock`, enforced by the Windows kernel. Cross-session and cross-privilege exclusion are guaranteed by the OS, not by a security descriptor the script would have to configure. The handle is released automatically when the process exits, cleanly or after a crash — there is no stale-lock recovery logic to get wrong, and no state on disk that a subsequent run has to interpret. **The lock is deliberately not acquired under `-DryRun`**: a dry run is read-only and safe to run concurrently with a live deployment, so an operator can inspect a machine with `WinRE.ps1 -DryRun` or `scripts\Test-WinRE.ps1` while a scheduled run is in progress. **Failure to acquire the lock for any reason other than contention is non-fatal**: a permission error, a missing `Logs` directory, or a transient filesystem issue causes the script to log a WARN and proceed without protection. The lock is defensive: a broken lock must not prevent a legitimate deployment. **The lock is released last in the `finally` block**, after the WIM-mount discard and after every temporary drive letter has been cleaned up, so a waiting second instance cannot begin work while the first is still releasing resources. The pre-patch-4 collision (two instances racing on `C:\Temp\WinREWork`) is closed by this invariant; the primary concurrent-instance failure shape is now a clean `EXIT_WARNING` from the second instance, not a fatal rename error at Step 2. This is the v44 patch 4 addition.

14. **The offline fallback trusts the state file's stored `DesiredStateId` directly, without recomputing it from cached inputs.** When the manifest fetch fails after its retry budget, the script sets `$Script:offlineFallback = $true`, reads the state file's stored `DesiredStateId`, and skips the OEM pack resolution, VMD detection, and required-driver resolution — all three depend on the manifest. The local safety checks (WinRE `Enabled`, exactly one recovery partition on the OS disk, deployed WIM hash matches the stored hash) remain fully enforced and do not depend on the manifest. If the fast path fires, the run exits `EXIT_WARNING`. If the fast path does not fire, the run exits `EXIT_WARNING` before the full-update pipeline. If there is no state file at all, the run throws and exits `EXIT_FATAL`. **The residual risk is that a machine whose hardware changed while offline could take the fast path with a stale DSI**; the next successful manifest fetch detects the drift and forces a rebuild. A `LocalInputsId` field in the state file would close this; it is planned as its own version boundary and is documented in [state-and-idempotency.md](state-and-idempotency.md). This is the v44 patch 5 addition.

15. **VMD hardware presence detection is fail-closed.** When the manifest is available, the script determines VMD hardware presence by enumerating present PnP devices that match the union of the manifest's `requiredDevices` patterns. If `Get-PnpDevice` reports an error during the query, the run treats VMD presence as **indeterminate** rather than as absent, and defers with `EXIT_WARNING` before committing any state. The reasoning: VMD presence determines which driver set the script selects, and a wrong guess on a machine that genuinely has VMD hardware would deploy a WinRE that cannot see the OS disk. The cost of a deferral is one pipeline run; the cost of guessing wrong is a machine with a non-functional recovery environment. This is the v44 patch 6 addition.

16. **Only a type-coded recovery partition on the OS disk is authoritative.** Every decision the script makes about recovery partitions — reuse, fast-path counting, active-location classification, final verification, deletion authorization, stray cleanup — reads from a single rule: the partition must carry the recovery GPT type GUID `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}` or the MBR type code `0x27`. A partition detected only by its `Recovery` or `WINRE` volume label is not promoted to DEDICATED, is not counted by the fast path, is not reused by `Find-SuitableRecoveryPartition`, and is not deleted by any code path. This is the v44 patch 7 addition. Before patch 7, the classifier used by the active-location check and the count used by the fast path both accepted label-only matches; the destructive path, which had always correctly refused to delete label-only matches, was the only consumer that applied the type-code gate. The asymmetry meant a Basic Data partition labelled "Recovery" on the OS disk would be counted by the fast path (so the "exactly one recovery partition on the OS disk" condition could never be satisfied) while being preserved by the destructive path (so it was never removed). The machine cycled through rebuilds indefinitely without converging. Patch 7 enforces the same authority rule everywhere: the type code is the partition's identity, the label is only a hint.

17. **The shrink runs in the reversible window, before route destruction.** The v45 patch 1 reorder moves the pre-shrink (with its sleep and defrag retries) ahead of `reagentc /disable` and ahead of any partition deletion. A shrink failure at this point returns `Deferred` with the old route intact. The pre-shrink free-space check is fail-closed: if C:'s volume cannot be read, the run defers rather than proceeding on the assumption that the partition supported-size preflight is sufficient. The check treats an indeterminate read as a distinct condition from a measured shortfall and does not retry-suppress it, because the read may clear on its own. This invariant closes the v44 patch 7 residual for the shrink failure trigger specifically.

18. **The plan computes a single boundary; the recovery partition fills exactly the space between that boundary and C:'s end.** The usable extent end is `diskSize − 1 MiB`; `tailEnd` is clamped to that value before aligning, on both the blocking-partition and no-blocking-partition branches (v46 patch 1). The planner then derives `AlignedManagedExtentEnd = floor(tailEnd / 1 MiB) × 1 MiB` and `TargetRecoveryStart = AlignedManagedExtentEnd - B`. C: is resized so it ends exactly at `TargetRecoveryStart`, and the recovery partition of size exactly `B` fills the space up to `AlignedManagedExtentEnd`. Bytes between the raw extent end and the aligned end are the alignment reserve and are logged, not treated as a defect. This eliminates the trailing gap left by the previous deficit-plus-slack model. The whole-layout assertion (`Assert-RecoveryPartitionLayout`) re-queries the newly created partition and confirms identity, exact offset, size within one alignment block, no overlap with C:, C:-to-recovery gap within one alignment block, and end at `AlignedManagedExtentEnd`. This is the v45 patch 1 addition.

19. **Post-delete extension has a safe fallback that prioritizes WinRE deployability over exact geometry.** When the plan calls for extending C: into the space the old recovery partitions occupied, the extension runs after deletion. If extension fails, the script re-queries C:'s current end, computes the largest recovery partition that fits between the current C: end and `AlignedManagedExtentEnd`, and — if that is at least the plan's bucket size — places the recovery partition there with a non-fatal warning. Exact geometry is a goal, not a reason to leave WinRE disabled. If the fallback size is too small, the script restores C: to its original size and returns `$null` so the main flow falls through to OS-fallback. The v46 patch 2 addition caps the fallback at the plan's bucket size rather than the full remaining extent, preserving the 2 GiB ceiling. This is the v45 patch 1 and v46 patch 2 addition.

20. **The pre-shrink deferral marker suppresses retries only while the old route is verified functional.** When `Ensure-AdequateRecoveryPartition` returns `Deferred` with `RetrySuppressible = $true`, the main flow writes `C:\Recovery\OEM\winre_partition_deferred.json`. On the next run, the marker is honored only if the old route is verified functional (WinRE `Enabled`, registered WIM readable, and either the active partition is a type-coded recovery partition on the OS disk or the OS-fallback route is on a `FullyDecrypted` C:) and the fast path would not fire. If the fast path would fire — the machine has converged on its own — the marker is cleared and the run exits `EXIT_SUCCESS`. If the old route is not functional, the marker is cleared and normal repair evaluation continues. This is the v45 patch 1 addition.

21. **A deletion failure restores the previous route when possible.** The currently active recovery partition is deleted last, so a mid-loop failure leaves it available. On any deletion failure, the script restores C: to its original size and attempts `Restore-PreviousWinRERoute`. If the previous route is confirmed restored — WinRE `Enabled` and the registered location matches the previous location per `Test-WinRELocationMatches` — the run returns `Deferred`. Otherwise it returns `$null` with an ERROR log stating that the route could not be restored. `Test-WinRELocationMatches` string-compares the locations first, then falls back to disk/partition identity comparison, because reagentc may report the same volume in either the GLOBALROOT or the Volume-GUID form after a disable/enable cycle. As of v46 patch 2, the two restores are reported separately: when the route restored but C: geometry did not verify, the distinct reason `recovery partition deletion failed; previous route restored but C: geometry restore unverified` is returned and `$Script:GeometryRestoreFailed` is set. This is the v45 patch 1 addition, refined by v46 patch 2.

22. **The destructive sequence fails closed if the active WinRE route or the OS partition cannot be resolved.** Two guards, both v46 patch 2. The **pre-deletion resolver guard** runs after `reagentc /disable` and before any partition deletion; if WinRE was `Enabled` and its registered location cannot be resolved to a partition, the sequence is refused with `Reason = "active WinRE location could not be resolved"`. The **layout-assertion fail-closed branch** runs inside `Assert-RecoveryPartitionLayout`; if `Get-OSPartition` returns nothing, the assertion returns `$false` rather than skipping the C: adjacency check. Both are the same corrective pattern: the sequence refuses to proceed when the state it depends on cannot be established, rather than proceeding on the assumption that the missing state is benign. `RetrySuppressible` is not set for the resolver deferral; the machine requires operator action to re-register the route. This is the v46 patch 2 addition.

23. **Build numbers are logged for evidence, not gated on.** Every run logs three values: the registered WinRE version (extracted from `reagentc /info` before any destructive work), the source WIM's build (from `Get-WimBuild` in force-upgrade detection), and the post-deploy WIM build (immediately before the state write). None of the three enters the `DesiredStateId`, and no gate reads any of the three. The purpose is empirical: over time the fleet logs answer whether Windows Update is updating the registered WinRE between runs, and whether any rebuild replaces a newer registered image with an older one. This is the v46 patch 2 addition.

## Where the design choices bite

The fifteen most consequential decisions in the whole script are:

- **Shrink-first replacement (v45 patch 1).** The risky operation — the shrink — runs in the reversible window, before any partition is destroyed. A failed shrink now returns `Deferred` with the old route intact, closing the v44 residual for the shrink trigger. The pipeline reorders the pipeline relative to v44, but the total work is unchanged: the shrink, disable, delete, extend, create, format sequence ends in the same state. What changed is when each step runs and what happens if it fails.

- **Single-boundary geometry with whole-layout assertion (v45 patch 1).** The planner computes a target boundary rather than a shrink amount, and the post-creation assertion re-queries the partition to confirm it landed exactly where the plan intended. The alternative — trust `New-Partition`'s success return and let subsequent failures surface later — was the pre-v45 behaviour and produced at least one class of unverified geometry outcomes.

- **The plan clamps `tailEnd` to the disk-end reserve before aligning (v46 patch 1).** The disk-end reserve is a fixed Windows convention: the last 1 MiB of the disk is not addressable for partition layout. The v45 planner computed `tailEnd` from the last relevant partition's end, or from `diskSize` when no blocking partition existed, and aligned down to 1 MiB — without first clamping to `diskSize − 1 MiB`. On a machine whose last partition ended at `diskSize` (equivalently, 1 MiB past the usable end), the aligned boundary landed 1 MiB past the reserve. The post-delete geometry check correctly rejected the plan, but the machine fell into OS-fallback with a matching `DesiredStateId` and stayed there until an operator manually deleted the state file. The clamp moves the plan to the boundary the post-delete check would accept on the same layout. This is the wrong-question pattern in one more direction: the v45 planner asked "where does the last relevant partition end?" when the downstream alignment step needed the answer to "where does the last relevant partition end, bounded by the disk-end reserve?"

- **Post-delete extension uses a safe fallback (v45 patch 1; capped at bucket size in v46 patch 2).** When the plan calls for extending C: into the space the old recovery partitions occupied, extension runs after deletion. If extension fails, the safe fallback places the recovery partition at the current C: end and continues. Exact geometry is a goal, not a reason to leave WinRE disabled. The trade: on an extension failure, the machine ends with a recovery partition that starts slightly earlier than the plan intended, at the cost of not consuming the surplus space. The alternative — restore C:, return `$null`, fall through to OS-fallback on encrypted C: — leaves the machine degraded when a working dedicated recovery partition was one step away. The v46 patch 2 cap sizes the fallback partition to the plan's bucket rather than to the full remaining extent, preserving the 2 GiB ceiling on the fallback path.

- **Dedicated recovery partition is the primary objective; OS-fallback is the failure outcome.** The script will attempt the destructive repartitioning path even when the pre-check suggests the OS cannot shrink enough. If the attempt fails, the OS is restored and OS-fallback is used with exit code 2. This is a deliberate trade: try hard for the good outcome, fall back honestly when the attempt fails. The alternative — never try if the arithmetic is pessimistic — was tried in v37 and rejected because `SizeMin` is a hint, not a floor.

- **The `DesiredStateId`-scoped retry policy.** A machine in OS-fallback with a matching state file stays in OS-fallback indefinitely, without re-attempting the destructive path. A state change (script version bump, manifest update, hardware change, Windows build update, CPU generation change, or VMD presence change) naturally re-arms the retry. This avoids re-shrinking the OS on every run of a machine that cannot shrink. The v45 patch 1 deferral marker extends the same policy to the pre-shrink deferral: a machine whose destructive sequence has deferred for a fixed reason does not re-attempt it every scheduled run.

- **The BitLocker policy targets the volume reagentc will enable, not the OS volume.** The v43 patch 5 (further revision 5) policy replaces the earlier OS-volume gate. Under the new policy, the enable-only and dedicated-partition paths proceed regardless of C:'s BitLocker state, because reagentc does not care about C: — it cares about the volume it is being asked to enable WinRE on. `Set-RecoveryPartitionReadyForWinRE` prepares that volume: it decrypts it in place with `manage-bde -off` if needed and polls for completion. The only path that gates on C:'s state is the OS-fallback path, and it does so for a specific reason: there the target volume is C:. The gate never modifies C:'s state — the operator resolves the state by completing decryption of C: with `manage-bde -off C:` or waiting for an in-progress decryption to finish. As of v44 patch 6, the destructive partition path no longer consults C:'s state at all. The v45 patch 1 reorder closes the v44 residual for the shrink trigger; the remaining corner is the post-deletion create/format failure.

- **The Audit Mode guard takes priority over everything except the program lock, including the BitLocker decision.** When `ImageState` is not `IMAGE_STATE_COMPLETE`, the script defers before it has fetched the manifest, resolved the OEM pack, computed the `DesiredStateId`, or read the state file. The reasoning is that a machine in Audit Mode is not a machine the script should be modifying at all, and the earlier the guard fires, the less work is wasted and the smaller the surface for accidental state change.

- **The enable-failure counter introduces a bounded retry for the enable failure.** Before v43 patch 5 (further revision), a generic `/enable` failure on the enable-only path fell through to full update and eventually exited `EXIT_FATAL` at the final-verification block, having rewritten the state file at the end of the pipeline as if the deployment had succeeded. The next run took the same path. That is a silent loop. The counter turns it into a bounded retry: three attempts, then a hard stop with an actionable message. The trade-off is that a genuinely transient enable failure now costs one extra pipeline run before it succeeds (the state-file rewrite), but it can no longer fail silently forever. This is the right trade for a fleet deployment where a silent loop is worse than a noisy failure.

- **The `DesiredStateId` is a deployment-input fingerprint, not a hardware fingerprint.** The v44 patch 1 revision takes the position that the ID should change whenever the inputs that determine the deployed WinRE artifact change, and should not change merely because unrelated machine state changes. Adding CPU vendor/generation and VMD presence is the minimal correction that closes the concrete gap — a VMD-flip or CPU swap that would otherwise leave a machine with a stale driver set. The revision deliberately does not hash the resolved driver list, on the reasoning that the manifest `version` field already serves that role under the project's manifest discipline; hashing the resolved inputs would be the cleaner long-term design but deserves its own version boundary and its own field evidence. This is documented in [state-and-idempotency.md](state-and-idempotency.md).

- **Component cleanup is applied to the mounted image, not to the export output.** ResetBase reduces the WinSxS component store inside the mounted image; the existing export is what materialises the savings on disk. Adding ResetBase to the pipeline was preferred over a hypothetical "shrink the exported WIM" step because ResetBase is a standard DISM operation with predictable behaviour, and because the export step already produces the final artifact — no new file I/O is required. The operation is gated on injection success because a partially-injected image is not a valid target for component cleanup, and because a failed injection aborts the pipeline before Step 4. Failure is non-fatal by design: the export produces a valid WIM regardless of whether ResetBase ran, and the recovery image's correctness does not depend on the size reduction.

- **The single-instance guarantee uses a file handle, not a named mutex.** The design choice is deliberate and was made during v44 patch 4. A named mutex would also work, but its cross-privilege behavior depends on the DACL applied at creation, and a misconfigured mutex fails in ways that are difficult to diagnose (a second process could spuriously acquire the mutex, or a first process could fail to release it). A `FileShare.None` handle has none of those failure modes: the OS enforces the exclusion, the handle is released on process termination regardless of how the process terminated, and the file's presence on disk is not the lock — the open handle is. The file is left in place after release, which is harmless; a future operator inspecting the log directory sees the file and does not need to interpret it. The alternative "delete the lock file on release" design was rejected because deleting the file introduces a race between the release and the next acquisition. This is the reasoning behind the v44 patch 4 choice and is recorded here so a future contributor does not "simplify" the lock by adding a deletion step.

- **The offline fallback trusts the state file rather than recomputing the DSI.** The design choice is deliberate and was made during v44 patch 5. Recomputing the DSI from cached inputs would require the OEM pack version, which is resolved from the OEM map — a different gist, on the same unavailable network. The first implementation of patch 5 attempted this and was wrong: on a fully offline machine, the OEM map fetch also fails, so the recomputed DSI contained `OEMPACK=NONE` versus the state file's `OEMPACK=A10`, and the fast path did not fire. The corrected implementation treats the state file's stored `DesiredStateId` as ground truth and relies on the local safety checks to verify the machine is healthy. The residual risk (hardware drift while offline) is named, and a `LocalInputsId` field would close it; that field is planned as its own version boundary. The trade is: accept a small window where a hardware-changed machine takes the fast path with a stale DSI, in exchange for making an offline run useful on every healthy machine. The alternative — refuse to run offline at all — leaves a machine that cannot reach the network in a permanent deferral, which is worse for a fleet whose network is intermittently unavailable.

- **VMD hardware presence detection is fail-closed.** The design choice is deliberate and was made during v44 patch 6. The alternative — treat an enumeration error as "no VMD hardware" — was the pre-patch-6 behavior. It is a wrong-question problem of exactly the shape described in the closing section below: the check was answering "did the enumeration return any matching devices?", but the downstream decision needed the answer to "does this machine have VMD hardware?" An empty device list from an errored enumeration is not evidence of absence. The fail-closed check moves the answer to the question that actually matters, and accepts a deferral when the answer cannot be determined. This is the same corrective pattern as the v44 patch 1 `DesiredStateId` change, applied to the driver-set determination.

- **The type code is the recovery partition's identity; the volume label is only a hint.** The design choice was made during v44 patch 7. Before patch 7, the classifier and the fast-path count accepted either the type code or the volume label as evidence that a partition was a recovery partition. That was a wrong-question problem: the destructive path's delete authorization had always required the type code (because a label alone must never authorize deletion), but the count and the classifier used the label OR the type code. The downstream decision those two consumers actually needed was "is this a partition I am authorized to reuse and count as the authoritative recovery partition?" — and the answer to that question is "yes if and only if it carries the recovery type code." A Basic Data partition labelled "Recovery" is not a recovery partition; it is a data partition that happens to have a misleading label. Treating the label as sufficient authority created a non-convergence loop: the fast path counted the label-only partition (so the "exactly one recovery partition" condition could never be satisfied), the destructive path correctly refused to delete it, and the machine rebuilt on every run. The corrective pattern is the same one that appears in every other entry in this document: move the check from the convenient signal to the authoritative signal. The v44 patch 7 change applies that pattern to the classifier and the count, so all consumers of "is this a recovery partition?" now use the same rule.

## A note on the field failures

The v43 patch 5 change was driven by two field failures on the same day, both on Windows 11 build 26200 with Device Encryption mid-encryption:

- **Dell Latitude 3550** (Intel Core Ultra 5 125U) — `VolumeStatus=EncryptionInProgress` at 73.6% when the script ran.
- **HP ProBook 450 15.6 inch G10** (Intel Core i7-1355U) — same state, same failure sequence.

Both machines lost their dedicated recovery partition and had WinRE disabled. The recovery procedure is documented in [troubleshooting.md](troubleshooting.md).

After the further revision landed, two more Dell machines ran against a mid-encryption state:

- **Dell Pro Slim QCS1250** (Intel Core Ultra 5 235) — startup gate fired, machine unchanged, exit code 2.
- **Dell Vostro 16 5640** (Intel Core i7-150U) — same.

Those two runs confirmed the startup gate of the earlier further revision behaved as designed for the OS-volume policy it was built on.

The further revision 5 change to target-volume-based preparation was driven by a different field observation, made on the same day:

- **Same-machine test on 2026-09-29** — with C: in the `FullyEncrypted`/no-protectors state, `reagentc /enable` against a dedicated recovery partition succeeded while `reagentc /enable` against the OS volume failed on the same machine in the same session. This is the observation that inverted the policy. The earlier startup gate had been deferring on a state that does not actually block the enable-only or dedicated-partition paths.

The further revision's Audit Mode guard was motivated by a separate field case:

- **Dell Latitude 5530** (12th Gen Intel i7-1265U, Windows 11 build 26200). Machine was in Audit Mode when the script first ran. The deployment completed successfully through Step 5, `reagentc /enable` failed with `0x4c7` on two consecutive runs, and the state file recorded the deployment as complete. After the user completed OOBE and ran `reagentc /enable` manually it succeeded on the first attempt with the same WIM. This is the case that motivated the Audit Mode guard and the enable-failure counter.

The v44 patch 4 field observation was separate again:

- **Dell Latitude 3550, 2026-09-30 12:29–12:40.** Two `WinRE.ps1` processes ran simultaneously on the same machine, one exiting on `Cannot rename because item at 'C:\Temp\WinREWork\winre.wim' does not exist.` The scheduled task's `MultipleInstancesPolicy = IgnoreNew` prevents scheduled-vs-scheduled overlap but does nothing about manual invocations. The file lock closed the gap.

The v44 patch 5 field observation:

- **ASUS desktop, 2026-09-30 13:22.** A healthy machine exited `FATAL ERROR: The remote name could not be resolved: 'gist.github.com'` on a transient DNS failure. The manifest fetch runs before the fast-path decision, so a network failure that should have been harmless brought the run down hard. The offline fallback addressed this.

The v44 patch 6 changes were driven by review rather than a single field failure. Two of the four production changes were wrong-question corrections of the same shape as the ones below — the VMD fail-closed check and the Lenovo five-state resolution both move a decision from a convenient-but-insufficient signal to the signal that actually determines the outcome. The C: guard removal was a review finding in the opposite direction: a check that had been added preemptively turned out to be over-broad, and the safety property it was protecting is now preserved by the OS-fallback gate alone in the two ordinary cases; the residual corner is documented in the Step 5 discussion. The Step 2 stale-file cleanup was motivated by the v44 patch 3 field failure on the injection-failure abort branch, which had already demonstrated the wedge on that path; patch 6 closes the same wedge on the normal path.

The v44 patch 7 changes were also driven by review, not by a fresh field failure. The classifier non-convergence loop was identified from the code by ChatGPT; the pre-patch-7 code had the count and the classifier accepting label-OR-type while the destructive path accepted type-only, and the asymmetry was diagnosed as a genuine non-convergence defect rather than a hypothetical one. The three field runs that exercised the fix — Dell Vostro 16 5640, Lenovo V15 G5 IRL, and ASUS PRIME H510M-D — all converged on the second run. None of them happened to trigger the label-only case (the label-only partition would have to be created by something other than the script, on a machine whose other parameters made a rebuild otherwise unnecessary); the fix is validated by the classifier's behaviour on ordinary type-coded partitions and by the code inspection, not by a live reproduction of the loop.

The v45 patch 1 changes were driven by the v44 patch 7 residual and by the user's field insight, not by an AI review. The field insight was shrink-first: the risky shrink operation should run in the reversible window, before any partition is destroyed. The v44 pipeline did the destructive operations in the wrong order; the v45 pipeline runs them in the right order. The four refinements (fail-closed C: volume-read check, delete-active-last ordering with route restoration, single-boundary geometry with whole-layout assertion, post-delete extension with safe fallback) were folded in during the v45 patch 1 cycle.

The v45 patch 1 field runs were:

- **ASUS PRIME H510M-D, 2026-10-01 23:48–23:51.** The first run took the reuse path — the existing 1000 MiB recovery partition was reused with 1082.2 MiB effective free against 1007 MiB required. Workspace selected a non-OS internal volume with 134.53 GiB free. WIM serviced, ResetBase ran (~28s), optimized WIM 756.72 MiB. `WIM_READY` checkpointed; `base.wim` removed after verified export. State file written with `UsedOSFallback = $false`; `Operating mode: DEDICATED`. Second run three minutes later took the fast path; a further pair of fast-path runs followed on 2026-10-02 08:50.

- **Hyper-V VM, Windows 11 Pro 26300, GPT, 2026-10-02 08:56–08:58.** The first end-to-end exercise of the v45 destructive path. The machine was provisioned with an undersized recovery-typed partition to force a rebuild. Plan, pre-shrink, disable, delete, `New-Partition` with type-code-at-creation, whole-layout assertion, WIM deploy, and `reagentc /enable` all completed on the first attempt; the second run took the fast path.

- **Hyper-V VM, Windows 10 Pro 19045, MBR, 2026-10-02 09:41–09:43.** First MBR machine and first Win10 field data. The run took the reuse path and applied `set id=27` to the existing MBR recovery partition; `reagentc /enable` succeeded on the first attempt. The MBR destructive path was not exercised.

- **Hyper-V VM, Windows 10 Pro 19045, MBR, 2026-10-02 09:47 — concurrent-instance test.** A second instance was launched while the first was mid-flight. The second logged the program-lock contention message and exited within seconds; the first completed normally. First field exercise of the v44 patch 4 program-lock contention path.

The v45 patch 1 **field gap**: the 2026-10-02 VM runs (Win11 GPT destructive rebuild, Win10 MBR reuse, program-lock contention) exercised the happy path of the destructive sequence end-to-end and the MBR attribute-application path, but the following code paths remain unexercised on any storage — physical or virtual: the fail-closed C: pre-shrink refuse branch, `Invoke-OSPartitionShrink` attempts 2 and 3, `Invoke-OSPartitionExtend` and its safe fallback, the twelve `Deferred` return paths from `Ensure-AdequateRecoveryPartition`, the deferral marker write/skip/clear lifecycle, `Restore-PreviousWinRERoute` and `Test-WinRELocationMatches`, the delete-active-last ordering against a multi-partition deletable set, the MBR destructive path (`New-Partition -MbrType 0x27` at a planned offset), and the program-lock crash-recovery path. These are covered by parser and mocked-geometry tests but not by physical storage. The VM test plan in [testing.md](testing.md) exercises them.

The v46 patch 1 fix was driven by the first v45 destructive-path *failure* on physical hardware, and verified by clean-path runs on two more machines:

- **Lenovo IdeaPad 3 15IAU7** (MT 82RK, Win 11 build 26200, GPT), 2026-10-02. Motivating failure. A factory-provided partition ended exactly 1 MiB past the disk-end reserve. The pre-v46 plan computed `tailEnd` from that partition's offset without clamping to `diskSize − 1 MiB`; `$alignedManagedExtentEnd` landed 1 MiB past the reserve; the post-delete geometry check (`$plannedEnd -gt ($diskSizeNow - 1MB)`) correctly rejected the plan. The machine fell into OS-fallback with a state file that matched the failing `DesiredStateId`, so subsequent scheduled runs accepted the state and did not retry — the machine stayed in OS-fallback until an operator manually deleted the state file. Under v46 patch 1 the clamp makes the plan valid on the same layout; the second full-update run (after the manual state-file reset) reached `DEDICATED`. This is the first v45 destructive-path failure on physical hardware, and the first time the post-delete geometry check fired outside a test harness.
- **Dell Latitude 3540** (Win 11 build 26300, PM9B1 NVMe, GPT), 2026-10-02 14:48–14:53. Clean-path verification. Full update took the destructive path cleanly (`Assert-RecoveryPartitionLayout` passed with the partition end exactly 1 MiB inside the disk end); fast path on the second run. `Add-WindowsDriver`'s return-shape filter returned 0 added drivers while the delta/matched-INF gate correctly judged success (64 delta, 49 of 49 INF matches).
- **HP EliteBook 6 G1i 16"** (MT SBKP, Core Ultra 7 255U, Win 11 26300), 2026-10-02 14:57–15:01. Clean-path verification. Same shape; first field exercise of the Core Ultra seriesMap branch in `Get-IntelProcessorGeneration`; the HP SoftPaq extractor's non-zero exit code 1168 was correctly handled by the INF-count gate (195 INFs produced).

The v46 patch 2 changes were driven by the build-drift observability question, by a machine-specific `Get-Partition` read failure, and by a post-review round that produced four hardenings of `Ensure-AdequateRecoveryPartition`. They were exercised on:

- **HP EliteBook 8 G1i 16"** (MT SBKP, Core Ultra 5 235U, Win 11 26300), 2026-10-02 15:22–15:26. The machine has an SD/MMC card reader that exposes no MSFT_Partition objects; the pre-fix `Get-RecoveryPartitions` threw `CmdletizationQuery_NotFound_DiskNumber` in the harness diagnostic, and the v46 patch 2 guard silences that specific throw. The clean destructive rebuild ran end-to-end; all three build-drift log lines fired on the full-update run and the two upstream lines fired on the fast-path run; the harness returned `Passed 16, failed 0, skipped 0 (of 16)` on both the pre- and post-production diagnostics. The four post-review hardenings (pre-deletion resolver guard, extension-fallback bucket cap, layout-assertion fail-closed branch, deletion-failure partial-rollback reporting) were not exercised on this run; they are code-review hardenings covered by the same gating tests that gate the rest of the post-deletion segment.

The BitLocker failure is instructive because it was invisible to each function in isolation. `Test-BitLockerProtected` was correctly implementing the tri-state contract for the state it observed (`ProtectionStatus=Off`). `Suspend-BitLockerForWinRE` was correctly taking the "already off, no suspension needed" branch. `New-Partition` was correctly creating a partition. `Set-RecoveryPartitionAttributes` was correctly applying the recovery type GUID. Each function did exactly what it was written to do. The bug was in the composition: the two BitLocker functions queried a subset of the protection state that was insufficient evidence for the decision the downstream code made with the answer.

The same class of failure is what motivated the enable-failure counter: the state-write gate and the enable path were each correct in isolation, but the composition allowed a state file that said "complete" while the enable had failed, with no mechanism to break the resulting loop.

And the same class of failure in a third direction is what motivated the target-volume policy: the earlier further revision's startup gate was correct in isolation, but the state it was querying was not the state reagentc actually cares about. The 2026-09-29 test is what made that visible.

And in a fourth direction, the same class of failure is what motivated the v44 patch 1 `DesiredStateId` change: the ID was correct in isolation, but the hardware state it was querying did not include the inputs that determine VMD driver selection. A machine whose VMD presence changed would have taken the fast path with a stale driver set, and the resulting WinRE could not see the OS disk. The VMD-flip gap is the same shape as the BitLocker gap — the check was answering a question, but not the question the downstream code needed answered.

And in a fifth direction, the same class of failure explains the delete-and-recreate retry that existed from v29 through v43 patch 5. That retry suspended BitLocker on C:, deleted the newly created recovery partition, and recreated it. The premise was that suspending C:'s protection would prevent the Device Encryption service from claiming the new partition. The premise was wrong: suspension changes C:'s state, and does nothing to the new partition the encryption service is about to claim. The retry logic was correct — it did exactly what it said — but it answered a question about the wrong volume. The correct answer, discovered in the v43 patch 5 (further revision 5) work, is to detect the claim after the fact and decrypt in place. The retry was removed for the same reason the earlier BitLocker functions were removed: not because the function was buggy, but because it was solving the wrong problem.

And in a sixth direction, the same class of failure explains the v44 patch 7 classifier fix. The pre-patch-7 classifier and the fast-path count asked "does this partition look like a recovery partition?" — the answer was yes if the type code matched *or* the label matched. The destructive path asked a stricter version of the same question: "is this partition authorized to be deleted as a recovery partition?" — the answer was yes only if the type code matched. The two answers disagreed, and the disagreement was invisible because each consumer was correct in isolation. The downstream decision the classifier needed to answer was "is this the authoritative recovery partition?" — and the correct answer to that question, everywhere in the script, is "yes if and only if the type code matches." Patch 7 unifies the question across all consumers.

And in a seventh direction, the same class of failure explains the v45 patch 1 fail-closed C: pre-shrink check. The pre-v45 check asked "did `Get-Volume -DriveLetter C` return a value?" — the answer was treated as evidence that C: was safe to shrink. When the read failed, the answer was "no", and the code proceeded anyway on the reasoning that the partition supported-size preflight was sufficient. But the question the downstream decision needed answered was "is C: safe to shrink?" — and "the volume query failed" is not evidence of safety, it is evidence of indeterminate state. The fail-closed check moves the answer to the question that matters: an indeterminate read defers, with a distinct reason and `RetrySuppressible = $false` because the read may clear on its own. The same corrective pattern — move the check from the convenient signal to the authoritative signal — appears again.

And in an eighth direction, the same class of failure explains the pre-v46 plan clamp. The v45 planner asked "where does the last relevant partition end?" — the answer was the partition's offset, or `diskSize` if no blocking partition existed. The question the downstream alignment step needed answered was "where does the last relevant partition end, bounded by the disk-end reserve?" The reserve is a fixed Windows convention (the last 1 MiB of the disk is not addressable), not a configurable margin, so the answer the planner gave could exceed the boundary the post-delete check would accept by exactly 1 MiB. On a machine whose last partition ended at `diskSize`, the plan landed on the wrong side of that difference. The v46 patch 1 clamp moves the answer to the question that matters: `tailEnd` is `diskSize − 1 MiB`, or the blocking partition's offset if that is lower.

And in a ninth direction, the same class of failure explains the v46 patch 2 pre-deletion resolver guard and layout-assertion fail-closed branch. The pre-v46 destructive sequence did not ask "which partition is the active WinRE route?" before it began deleting, and did not ask "can I resolve the OS partition?" before it accepted the layout. In both cases, the missing answer meant the downstream code assumed the state it needed was available. If the active route is unresolvable, no partition is protected by the delete-last ordering and route restoration cannot target anything; if the OS partition is unresolvable, the C: adjacency check cannot be performed and the assertion's success would not mean what it appears to mean. Both guards refuse to proceed when the state cannot be established, rather than proceeding on the assumption that the missing state is benign. Same pattern, two more applications.

**The shared shape.** All of those failures have one property in common: each function or check was individually correct, and each was answering a question that was not the question the downstream code needed answered.

- `Test-BitLockerProtected` asked "is C: protected?" when reagentc was asking "is the target volume unencrypted?".
- The state-write gate asked "did the pipeline complete?" when the loop-breaker needed to know "did the enable step succeed?".
- The startup gate asked "is C: in a state that blocks enable-only work?" when the answer to that question was irrelevant to enable-only work.
- The `DesiredStateId` asked "has the hardware identity changed?" when the driver set could change without the identity changing.
- The delete-and-recreate retry asked "how do I stop C: from blocking this operation?" when C: was never blocking anything in the first place.
- The VMD presence check asked "did the enumeration return any devices?" when the downstream decision needed the answer to "does this machine have VMD hardware?".
- The pre-v44-patch-7 classifier and fast-path count asked "does this partition look like a recovery partition?" when the downstream decision needed the answer to "is this partition authorized to be treated as the authoritative recovery partition?".
- The pre-v45-patch-1 C: free-space check asked "did the volume query succeed?" when the downstream decision needed the answer to "is C: safe to shrink?".
- The pre-v46 plan asked "where does the last relevant partition end?" when the downstream alignment step needed the answer to "where does the last relevant partition end, bounded by the disk-end reserve?".
- The pre-v46-patch-2 destructive sequence asked "does the layout assertion pass?" and "does the plan look valid?" when the downstream deletion loop needed the answers to "which partition is the active WinRE route?" and "can the OS partition be resolved?".

The corrective pattern is the same in every case: move the check from the state that is easy to query to the state that actually matters, and record enough about the deployment's inputs that a divergence from the last known good state will be detected rather than assumed absent. That pattern is what the invariants in this document exist to enforce, and it is why each invariant is stated in terms of the question the downstream code needs answered rather than the question that is convenient to ask.

The v44 patch 3 destructive-path guard was an attempt to apply that pattern preemptively. It asked "is C: in a state where the OS-fallback route could complete?" before the destructive sequence began. That question was answerable and the answer was useful in some cases, but as v44 patch 6 review showed, it was over-broad: the dedicated-partition path's success or failure depends on the partition geometry, not on C:'s encryption state, and the OS-fallback gate already asks the same question at the point where the answer actually matters — after the destructive attempt has failed and the run is genuinely about to fall through to OS-fallback. The guard was not wrong to ask the question; it was wrong to ask it there. Patch 6 removes it, and the safety property is preserved by the gate that asks the right question at the right point, in the ordinary cases. The narrower corner where the property is not preserved is the residual that the eventual post-failure check will close.

The v44 patch 4 program lock is a different class of problem — a mutual-exclusion problem, not a wrong-question problem — and is included in the invariants because the pre-patch-4 code lacked any mechanism to enforce the exclusivity the WorkDir design assumed. The corrective pattern for that class is to move the coordination from an implicit assumption ("the scheduled task won't overlap") to an explicit, kernel-enforced primitive, and to accept that the primitive is defensive rather than authoritative (a broken lock logs and proceeds).

The v45 patch 1 reorder is a sequencing problem, not a wrong-question problem. The pre-v45 code asked the right questions (is the shrink needed? is the plan valid? is the geometry correct?) but answered them in the wrong order: it ran the risky operation after the destructive operations instead of before. The corrective pattern for that class is to move the risky step into the window where failure is still reversible. This is a distinct corrective pattern from the wrong-question pattern, and it appears in this document as a separate class because the v45 reorder is the first instance of it in the project.

## Related documents

- [state-and-idempotency.md](state-and-idempotency.md) — details on the state file, checkpoint file, deferral marker, and how they interact, plus the offline fallback's residual risk and the planned `LocalInputsId` field.
- [recovery-partition.md](recovery-partition.md) — the partition lifecycle in depth.
- [driver-injection.md](driver-injection.md) — injection and the success gate.
- [exit-codes.md](exit-codes.md) — every exit path.
