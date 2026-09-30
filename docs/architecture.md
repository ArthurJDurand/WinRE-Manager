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

- **Correct end state**: a single dedicated recovery partition, on the OS disk, correctly typed, containing the right WIM, with `reagentc` registered to it.
- **Do not disturb a healthy machine.** Running the script on a machine already in the correct end state must be a no-op.

Everything below is designed around those two requirements.

## The pipeline

The production script runs one of four control-flow paths. Three of them are short-circuits; the full-update path is the long one.

Before any of those paths is chosen, three things happen in order: the program lock is acquired, one startup guard runs, and one normalisation step runs. The lock is a mutual-exclusion primitive; the guard is read-only and can terminate the run early; the normalisation step is not a gate and does not defer.

The **program lock** is acquired first, immediately after the startup banner, before the Audit Mode guard and before any state-modifying action. `WinRE.ps1` opens `C:\ProgramData\OEM\Logs\WinREManager.lock` with an exclusive handle via `[System.IO.File]::Open($path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)`. The Windows kernel enforces the exclusive handle, so cross-session and cross-privilege exclusion are guaranteed by the OS. The handle is released automatically when the process exits, cleanly or after a crash — there is no stale-lock recovery logic. The lock is **not** acquired under `-DryRun`, because a dry run is read-only and safe to run concurrently with a live deployment. A second instance that cannot acquire the lock logs `Another WinRE Manager instance is already running (program lock file is exclusively held)` and exits `EXIT_WARNING` (code 2) without touching anything. If the lock cannot be acquired for a non-contention reason — a permission error, a missing `Logs` directory, or a transient filesystem issue — the script logs a WARN and proceeds without protection; the lock is defensive, and a broken lock must not prevent a legitimate deployment. See the "Control-flow invariants" section for the full discussion.

The **Audit Mode / OOBE / sysprep guard** runs second, before the hardware check. It reads `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` → `ImageState` and defers with `EXIT_WARNING` when the value is present and is not `IMAGE_STATE_COMPLETE`. During Audit Mode, OOBE, sysprep generalize, and sysprep specialize, `reagentc /enable` is blocked by the OS regardless of what the script has done; running the destructive partition path in these states accomplishes nothing and leaves a state file that would loop on every subsequent run. The guard is deliberately conservative: any value other than `IMAGE_STATE_COMPLETE` defers, and absence of the key is treated as safe (some SKUs omit it). Under `-DryRun` the guard logs `Would defer …` and continues.

The **drive-letter cleanup** then runs: any volume labelled `Recovery` or `WINRE` whose partition is not the boot or system partition and whose root does not contain a `Windows` directory has its drive letter removed. This is a defensive normalisation — those letters should never be persistent — and it is a no-op on a healthy machine.

BitLocker state is not consulted at startup. The v43 patch 5 (further revision 5) policy is target-volume-based, and the target volume is not known until the classifier has resolved the reagentc-registered location. The BitLocker decision is therefore made where the action is taken, not at startup. This is a deliberate departure from the v43 patch 5 (further revision) design, which had a startup BitLocker gate; that gate deferred on the OS volume state, and the OS volume state is irrelevant to the enable-only and dedicated-partition paths. The only place C:'s state is consulted is the OS-fallback route, because on that route the target volume *is* the OS volume. As of v44 patch 6, the destructive partition path does not consult C:'s state at all: the dedicated-partition path's objective is to create a dedicated partition, and it succeeds or fails on the partition geometry, not on C:'s encryption state. If the destructive attempt fails at the shrink step, the run falls through to OS-fallback, and the OS-fallback gate then checks C: and defers as designed.

### Fast path (idempotent)

Entered when: WinRE is enabled, the state file matches, the currently-registered recovery partition is on the OS disk, exactly one recovery partition exists on the OS disk, and the deployed WIM hash matches the stored hash.

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

Entered when: anything has changed — new Windows build, new driver manifest version, new OEM pack version, current WIM hash differs from stored, no state, a change in CPU generation or VMD presence that has moved the `DesiredStateId`, or a classifier-detected problem such as a recovery partition on a secondary disk.

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
   - Its total size is at least `WIM + 250 MiB`.
   - Its effective free space (current free + existing WIM size) is at least `WIM + 250 MiB`.

   Encryption state is **not** a rejection criterion. The target-volume policy means an existing encrypted recovery partition is usable — `Set-RecoveryPartitionReadyForWinRE` will decrypt it in place before reagentc is called.

2. If no candidate passes, `Ensure-AdequateRecoveryPartition` performs the destructive path. It disables WinRE, deletes every recovery partition on the OS disk, extends the OS partition to its `SizeMax`, shrinks it by `(bucketSizeMiB + 1) MiB`, creates a new partition at the aligned offset with the recovery type GUID or type code already applied, formats as NTFS with label `Recovery`, verifies no auto-encryption occurred, decrypts in place if the Device Encryption service claimed the partition anyway, and returns.

   C:'s encryption state is **not** consulted. The dedicated-partition path's objective is to create a dedicated partition; it succeeds or fails on the partition geometry, not on C:'s BitLocker state. If the destructive attempt fails at the shrink step, the run falls through to OS-fallback, and there the OS-fallback gate checks C: and defers as designed. The safety property — never leave a machine with no working recovery route — is preserved end-to-end without a pre-emptive C: check on this path.

   If the shrink fails after three attempts (immediate, after 10s sleep, after `defrag C: /x`), the OS partition size is restored via `Restore-OSPartitionSize`, the destructive attempt is abandoned, and the script falls through to OS-fallback — WinRE deployed to `C:\Recovery\WindowsRE` instead of a dedicated partition, with exit code 2.

**Step 6 — Deploy the WIM.**
First, prepare the target: `Set-RecoveryPartitionReadyForWinRE` on the recovery partition, or — for the OS-fallback route — a check on C:'s `VolumeStatus` that defers unless it is `FullyDecrypted`. The OS-fallback check exists because reagentc refuses to enable WinRE on an encrypted OS volume, always. The script never modifies C:'s BitLocker state.

Then: copy the source WIM to the target directory. Verify SHA256. Set the file hidden + system. Call `reagentc /setreimage /path \\?\GLOBALROOT\device\harddiskX\partitionY\Recovery\WindowsRE`, then `reagentc /enable`. Write the state file with the deployed WIM hash **and** the enable outcome (`LastEnableResult`, `EnableFailureAttempts`). Clear the checkpoint.

**Step 7 — Enforce the single-recovery-partition invariant.**
`Remove-StrayRecoveryPartitions` deletes any type-coded recovery partition (GPT GUID `{de94bba4-...}` or MBR type `0x27`) on any non-OS disk. A partition on a non-OS disk that carries only a `Recovery` *label* but no type code is logged and skipped — label-only matches are not sufficient authority to delete on a secondary disk.

**Step 8 — Final verification.**
Re-read WinRE state. Classify the registered location: `DEDICATED` (recovery partition on OS disk), `OS-FALLBACK` (on the OS partition), or `UNEXPECTED` (neither). If dedicated, remove any temporary drive letter that the script assigned during the pipeline. If OS-fallback, warn that the run is degraded but functional.

## The five state-carrying artifacts

| Artifact | Path | Purpose | Lifetime |
|---|---|---|---|
| **State file** | `C:\Recovery\OEM\winre_state.json` | Records the deployed WIM hash, `DesiredStateId`, and the enable outcome (`LastEnableResult`, `EnableFailureAttempts`). | Persists across runs. |
| **Checkpoint file** | `C:\ProgramData\OEM\Logs\winre_checkpoint.txt` | Records the highest completed step of the current pipeline. | Deleted at end of run. |
| **Log file** | `C:\ProgramData\OEM\Logs\WinRE-Manager.log` | Append-only event log. | Rotated by the operator, not by the script. |
| **Program lock file** | `C:\ProgramData\OEM\Logs\WinREManager.lock` | Exclusive-handle target for the single-instance guarantee (v44 patch 4). | Persists across runs; the file's existence is not the lock, the open handle is. |
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

The offline fallback (v44 patch 5) does **not** recompute the DSI from cached inputs; it trusts the state file's stored value. This is documented in [state-and-idempotency.md](state-and-idempotency.md) as the residual risk that the planned `LocalInputsId` field would close.

## Control-flow invariants

These are the invariants the script maintains. Each one has a real field failure behind it, except where explicitly noted; the `.NOTES` block in `scripts/WinRE.ps1` names them as "CRITICAL LESSONS LEARNED."

1. **Exactly one recovery partition exists, on the OS disk, correctly type-coded.** Enforced on the fast path, the enable-only path, both pending-reboot exits, and Step 7 of the full-update path. A type-coded recovery partition on any non-OS disk is deleted unconditionally. The invariant is absolute.

2. **No failure path leaves C: permanently shrunken.** Every post-shrink failure calls either `Remove-OrphanPartition` (which absorbs freed space back) or `Restore-OSPartitionSize`. Every failure of `Restore-OSPartitionSize` sets `$Script:GeometryRestoreFailed` so the state file is deleted and the next run retries from clean.

3. **The state-write gate is never relaxed.** `Write-WinREState` is only called when `$Script:ImageInjectionComplete` is `$true` and a WIM hash was computed. A failed injection never leaves a state file behind. The one exception is the pending-reboot path, which re-writes the existing state file with an updated `PendingReboot` flag but does not update the hash.

4. **The pipeline stops before deployment when injection fails.** If `$Script:ImageInjectionComplete = $false` after Step 3, the script exits with `EXIT_WARNING` before Step 4 (`dism /Export-Image`), before Step 5 (partition work), before Step 6 (deployment), and before any `reagentc` call. The state-write gate alone would prevent the state file from recording the run, but it would not prevent the deployment of a WIM with no OEM or VMD drivers. The explicit pipeline gate closes that gap. This is the v44 patch 1 gate. The abort branch also removes `base.wim` and `winre_optimized.wim` from `WorkDir` so the next run's Step 2 can rename cleanly; this is the v44 patch 3 fix.

5. **Component cleanup runs on the mounted image before export, and is non-fatal.** `dism /cleanup-image /StartComponentCleanup /ResetBase` runs inside Step 3 after successful injection and before the dismount, gated on `$Script:ImageInjectionComplete`. The size benefit is not realised until Step 4's `dism /Export-Image` writes a fresh `.wim`. ResetBase failure is logged and the pipeline continues; the export writes whatever size the image currently is, and the Step 5 partition acceptance check decides whether the result fits. ResetBase makes the image unserviceable for rollback (updates present when it ran can no longer be uninstalled), which is acceptable for a recovery image that is rebuilt from source whenever the `DesiredStateId` changes. This is the v44 patch 2 addition.

6. **BitLocker is never assumed Off, and the target volume is prepared before reagentc is called.** This is the v43 patch 5 (further revision 5) policy. It replaces the OS-volume-gate policy of the earlier further revision, which the 2026-09-29 field test disproved: reagentc's BitLocker check is on the **target** volume, not on C:. The invariant is now:

   - **The target recovery partition must be unencrypted by the time `reagentc /enable` runs.** `Set-RecoveryPartitionReadyForWinRE` enforces this. It queries the target's BitLocker state with `Test-VolumeEncrypted` (the tri-state classifier). If the target is confirmed unencrypted, it returns immediately. If it is encrypted or actively encrypting, it runs `manage-bde -off` against the target and polls at 5-second intervals up to a 300-second timeout, until the volume reports confirmed-unencrypted. It is called at every point where reagentc will be invoked: the enable-only path, the full-update path with an existing recovery partition, the full-update path with a newly created partition, and the pending-reboot repair path.

   - **The OS-fallback path is the only path that depends on C:'s BitLocker state.** In the OS-fallback case the target volume *is* the OS volume, and reagentc will refuse to enable WinRE on an encrypted OS volume. The OS-fallback gate therefore checks C:'s `VolumeStatus` before deploying the WIM and defers with `EXIT_WARNING` unless it is `FullyDecrypted`. It never modifies C:'s state — decrypting the OS volume is hours of I/O, changes the recovery key relationship, and the OS volume is the user's data. The gate uses `Test-VolumeEncrypted` (not `Get-BitLockerVolume` directly) and requires the result to be exactly `$false`, so a machine whose BitLocker module is unavailable is still classified correctly.

   - **Suspension is not used.** The v43 patch 5 function `Suspend-BitLockerForWinRE` was deleted. Suspension does not prevent Device Encryption from claiming a newly created partition — proven by the Dell Latitude 3550 pre-patch-5 log and by the 2026-09-29 test — and it is useless for OS-fallback, where reagentc refuses regardless. Decrypting the target in place is the mechanism the policy uses; the 2026-09-29 test confirmed that a partition claimed by Device Encryption does not re-encrypt after `manage-bde -off` completes.

   - **The target may be an existing encrypted recovery partition.** `Find-SuitableRecoveryPartition` no longer rejects encrypted candidates, because the helper will decrypt them. This preserves partitions that would previously have been destroyed and recreated.

   **Why the policy was inverted.** The earlier further revision gated on C:'s state because the pre-patch-5 failure had the shape "C: was mid-encryption, the script created a new partition, the encryption service claimed it, and reagentc refused." But the 2026-09-29 test showed the same C: state that failed on the OS volume succeeded on a dedicated recovery partition. The failure was not about C: at all. It was about the target volume being encrypted — and the target volume gets encrypted by two paths: the OS-fallback path (where the target *is* C:) and the new-partition path (where the Device Encryption service claims the new partition before the recovery type GUID can take effect). The new policy addresses both directly: it prepares whatever target the deploy step intends to use, and it defers the new-partition path only when the Device Encryption service is actually active on the OS volume at the moment of creation.

7. **New recovery partitions are created with the recovery type code already applied.** `New-Partition` passes `-GptType {de94bba4-06d1-4d40-a16a-bfd50179d6ac}` (GPT) or `-MbrType 0x27` (MBR) at creation time (v43 patch 5). This closes the window between `New-Partition` and `Set-RecoveryPartitionAttributes` during which the partition is a plain Basic Data partition. `Set-RecoveryPartitionAttributes` still runs after format to apply the GPT attributes (`0x8000000000000001` — PLATFORM_REQUIRED + NO_DRIVE_LETTER); it is idempotent on the type code. The attribute step still runs before any drive letter is assigned.

8. **Self-referential file operations are guarded.** Any block that deletes a file and then writes to the same path (or copies another file onto it) checks first that the source and destination are not the same file (by `[System.IO.Path]::GetFullPath`). This guards against the v42 "fallback copy ate its own source" bug.

9. **Checkpoint advancement requires injection success.** A checkpoint that says "step 3 completed" is only written when image injection actually completed. This is v43 patch 4's fix.

10. **The Audit Mode / OOBE / sysprep guard runs before any state-modifying action.** The guard reads `ImageState` at startup and defers unless the value is absent or `IMAGE_STATE_COMPLETE`. This is the highest-priority guard in the script after the program lock, and it runs before the drive-letter cleanup, the pending-reboot block, the classifier, and any partition work. It exists because on a machine that has not yet reached a normal desktop, `reagentc /enable` is blocked by the OS and the destructive partition work would be wasted while producing a state file that loops.

11. **A `reagentc /enable` failure on the enable-only path does not fall through to full update, and does not loop forever.** When the deployment is current and only the enable step fails — whether with a generic `"failed"` outcome or a `"bitlocker"` outcome after the target was prepared — the enable-only path increments the state-file counter and exits `EXIT_WARNING` without attempting a rebuild. After three consecutive failures the loop-breaker fires and exits `EXIT_FATAL`, requiring manual intervention. This invariant closes the loop that was introduced by the state-file-records-complete behaviour before v43 patch 5's further revision.

12. **The state file never records `DeployedDiskNumber` or `DeployedPartitionNumber` as `0` for OS-fallback states.** An OS-fallback state file does not have those fields, because the fallback target is `C:\Recovery\WindowsRE`, not a partition by number. The `Write-WinREState` parameters are `[object]` typed and the conditional that populates the state file checks `$null -ne` before the integer comparison, so a `$null` argument does not coerce to `0` and write a misleading `"DeployedDiskNumber": 0` into the state file. This is the v44 patch 1 fix.

13. **The script holds an exclusive program lock for its entire duration, from just after the startup banner to the last cleanup step in the `finally` block.** The lock is a `FileShare.None` handle on `C:\ProgramData\OEM\Logs\WinREManager.lock`, enforced by the Windows kernel. Cross-session and cross-privilege exclusion are guaranteed by the OS, not by a security descriptor the script would have to configure. The handle is released automatically when the process exits, cleanly or after a crash — there is no stale-lock recovery logic to get wrong, and no state on disk that a subsequent run has to interpret. **The lock is deliberately not acquired under `-DryRun`**: a dry run is read-only and safe to run concurrently with a live deployment, so an operator can inspect a machine with `WinRE.ps1 -DryRun` or `scripts\Test-WinRE.ps1` while a scheduled run is in progress. **Failure to acquire the lock for any reason other than contention is non-fatal**: a permission error, a missing `Logs` directory, or a transient filesystem issue causes the script to log a WARN and proceed without protection. The lock is defensive: a broken lock must not prevent a legitimate deployment. **The lock is released last in the `finally` block**, after the WIM-mount discard and after every temporary drive letter has been cleaned up, so a waiting second instance cannot begin work while the first is still releasing resources. The pre-patch-4 collision (two instances racing on `C:\Temp\WinREWork`) is closed by this invariant; the primary concurrent-instance failure shape is now a clean `EXIT_WARNING` from the second instance, not a fatal rename error at Step 2. This is the v44 patch 4 addition.

14. **The offline fallback trusts the state file's stored `DesiredStateId` directly, without recomputing it from cached inputs.** When the manifest fetch fails after its retry budget, the script sets `$Script:offlineFallback = $true`, reads the state file's stored `DesiredStateId`, and skips the OEM pack resolution, VMD detection, and required-driver resolution — all three depend on the manifest. The local safety checks (WinRE `Enabled`, exactly one recovery partition on the OS disk, deployed WIM hash matches the stored hash) remain fully enforced and do not depend on the manifest. If the fast path fires, the run exits `EXIT_WARNING`. If the fast path does not fire, the run exits `EXIT_WARNING` before the full-update pipeline. If there is no state file at all, the run throws and exits `EXIT_FATAL`. **The residual risk is that a machine whose hardware changed while offline could take the fast path with a stale DSI**; the next successful manifest fetch detects the drift and forces a rebuild. A `LocalInputsId` field in the state file would close this; it is planned as its own version boundary and is documented in [state-and-idempotency.md](state-and-idempotency.md). This is the v44 patch 5 addition.

15. **VMD hardware presence detection is fail-closed.** When the manifest is available, the script determines VMD hardware presence by enumerating present PnP devices that match the union of the manifest's `requiredDevices` patterns. If `Get-PnpDevice` reports an error during the query, the run treats VMD presence as **indeterminate** rather than as absent, and defers with `EXIT_WARNING` before committing any state. The reasoning: VMD presence determines which driver set the script selects, and a wrong guess on a machine that genuinely has VMD hardware would deploy a WinRE that cannot see the OS disk. The cost of a deferral is one pipeline run; the cost of guessing wrong is a machine with a non-functional recovery environment. This is the v44 patch 6 addition.

## Where the design choices bite

The ten most consequential decisions in the whole script are:

- **Dedicated recovery partition is the primary objective; OS-fallback is the failure outcome.** The script will attempt the destructive repartitioning path even when the pre-check suggests the OS cannot shrink enough. If the attempt fails, the OS is restored and OS-fallback is used with exit code 2. This is a deliberate trade: try hard for the good outcome, fall back honestly when the attempt fails. The alternative — never try if the arithmetic is pessimistic — was tried in v37 and rejected because `SizeMin` is a hint, not a floor.

- **The `DesiredStateId`-scoped retry policy.** A machine in OS-fallback with a matching state file stays in OS-fallback indefinitely, without re-attempting the destructive path. A state change (script version bump, manifest update, hardware change, Windows build update, CPU generation change, or VMD presence change) naturally re-arms the retry. This avoids re-shrinking the OS on every run of a machine that cannot shrink.

- **The BitLocker policy targets the volume reagentc will enable, not the OS volume.** The v43 patch 5 (further revision 5) policy replaces the earlier OS-volume gate. Under the new policy, the enable-only and dedicated-partition paths proceed regardless of C:'s BitLocker state, because reagentc does not care about C: — it cares about the volume it is being asked to enable WinRE on. `Set-RecoveryPartitionReadyForWinRE` prepares that volume: it decrypts it in place with `manage-bde -off` if needed and polls for completion. The only path that gates on C:'s state is the OS-fallback path, and it does so for a specific reason: there the target volume is C:. The gate never modifies C:'s state — the operator resolves the state by completing decryption of C: with `manage-bde -off C:` or waiting for an in-progress decryption to finish. As of v44 patch 6, the destructive partition path no longer consults C:'s state at all; the safety property is preserved end-to-end by the OS-fallback gate alone.

- **The Audit Mode guard takes priority over everything except the program lock, including the BitLocker decision.** When `ImageState` is not `IMAGE_STATE_COMPLETE`, the script defers before it has fetched the manifest, resolved the OEM pack, computed the `DesiredStateId`, or read the state file. The reasoning is that a machine in Audit Mode is not a machine the script should be modifying at all, and the earlier the guard fires, the less work is wasted and the smaller the surface for accidental state change.

- **The enable-failure counter introduces a bounded retry for the enable failure.** Before v43 patch 5 (further revision), a generic `/enable` failure on the enable-only path fell through to full update and eventually exited `EXIT_FATAL` at the final-verification block, having rewritten the state file at the end of the pipeline as if the deployment had succeeded. The next run took the same path. That is a silent loop. The counter turns it into a bounded retry: three attempts, then a hard stop with an actionable message. The trade-off is that a genuinely transient enable failure now costs one extra pipeline run before it succeeds (the state-file rewrite), but it can no longer fail silently forever. This is the right trade for a fleet deployment where a silent loop is worse than a noisy failure.

- **The `DesiredStateId` is a deployment-input fingerprint, not a hardware fingerprint.** The v44 patch 1 revision takes the position that the ID should change whenever the inputs that determine the deployed WinRE artifact change, and should not change merely because unrelated machine state changes. Adding CPU vendor/generation and VMD presence is the minimal correction that closes the concrete gap — a VMD-flip or CPU swap that would otherwise leave a machine with a stale driver set. The revision deliberately does not hash the resolved driver list, on the reasoning that the manifest `version` field already serves that role under the project's manifest discipline; hashing the resolved inputs would be the cleaner long-term design but deserves its own version boundary and its own field evidence. This is documented in [state-and-idempotency.md](state-and-idempotency.md).

- **Component cleanup is applied to the mounted image, not to the export output.** ResetBase reduces the WinSxS component store inside the mounted image; the existing export is what materialises the savings on disk. Adding ResetBase to the pipeline was preferred over a hypothetical "shrink the exported WIM" step because ResetBase is a standard DISM operation with predictable behaviour, and because the export step already produces the final artifact — no new file I/O is required. The operation is gated on injection success because a partially-injected image is not a valid target for component cleanup, and because a failed injection aborts the pipeline before Step 4. Failure is non-fatal by design: the export produces a valid WIM regardless of whether ResetBase ran, and the recovery image's correctness does not depend on the size reduction.

- **The single-instance guarantee uses a file handle, not a named mutex.** The design choice is deliberate and was made during v44 patch 4. A named mutex would also work, but its cross-privilege behavior depends on the DACL applied at creation, and a misconfigured mutex fails in ways that are difficult to diagnose (a second process could spuriously acquire the mutex, or a first process could fail to release it). A `FileShare.None` handle has none of those failure modes: the OS enforces the exclusion, the handle is released on process termination regardless of how the process terminated, and the file's presence on disk is not the lock — the open handle is. The file is left in place after release, which is harmless; a future operator inspecting the log directory sees the file and does not need to interpret it. The alternative "delete the lock file on release" design was rejected because deleting the file introduces a race between the release and the next acquisition. This is the reasoning behind the v44 patch 4 choice and is recorded here so a future contributor does not "simplify" the lock by adding a deletion step.

- **The offline fallback trusts the state file rather than recomputing the DSI.** The design choice is deliberate and was made during v44 patch 5. Recomputing the DSI from cached inputs would require the OEM pack version, which is resolved from the OEM map — a different gist, on the same unavailable network. The first implementation of patch 5 attempted this and was wrong: on a fully offline machine, the OEM map fetch also fails, so the recomputed DSI contained `OEMPACK=NONE` versus the state file's `OEMPACK=A10`, and the fast path did not fire. The corrected implementation treats the state file's stored `DesiredStateId` as ground truth and relies on the local safety checks to verify the machine is healthy. The residual risk (hardware drift while offline) is named, and a `LocalInputsId` field would close it; that field is planned as its own version boundary. The trade is: accept a small window where a hardware-changed machine takes the fast path with a stale DSI, in exchange for making an offline run useful on every healthy machine. The alternative — refuse to run offline at all — leaves a machine that cannot reach the network in a permanent deferral, which is worse for a fleet whose network is intermittently unavailable.

- **VMD hardware presence detection is fail-closed.** The design choice is deliberate and was made during v44 patch 6. The alternative — treat an enumeration error as "no VMD hardware" — was the pre-patch-6 behavior. It is a wrong-question problem of exactly the shape described in the closing section below: the check was answering "did the enumeration return any matching devices?", but the downstream decision needed the answer to "does this machine have VMD hardware?" An empty device list from an errored enumeration is not evidence of absence. The fail-closed check moves the answer to the question that actually matters, and accepts a deferral when the answer cannot be determined. This is the same corrective pattern as the v44 patch 1 `DesiredStateId` change, applied to the driver-set determination.

## A note on the v43 patch 5 field failures

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

The v44 patch 6 changes were driven by review rather than a single field failure. Two of the four production changes were wrong-question corrections of the same shape as the ones below — the VMD fail-closed check and the Lenovo five-state resolution both move a decision from a convenient-but-insufficient signal to the signal that actually determines the outcome. The C: guard removal was a review finding in the opposite direction: a check that had been added preemptively turned out to be over-broad, and the safety property it was protecting is now preserved by the OS-fallback gate alone. The Step 2 stale-file cleanup was motivated by the v44 patch 3 field failure on the injection-failure abort branch, which had already demonstrated the wedge on that path; patch 6 closes the same wedge on the normal path.

The BitLocker failure is instructive because it was invisible to each function in isolation. `Test-BitLockerProtected` was correctly implementing the tri-state contract for the state it observed (`ProtectionStatus=Off`). `Suspend-BitLockerForWinRE` was correctly taking the "already off, no suspension needed" branch. `New-Partition` was correctly creating a partition. `Set-RecoveryPartitionAttributes` was correctly applying the recovery type GUID. Each function did exactly what it was written to do. The bug was in the composition: the two BitLocker functions queried a subset of the protection state that was insufficient evidence for the decision the downstream code made with the answer.

The same class of failure is what motivated the enable-failure counter: the state-write gate and the enable path were each correct in isolation, but the composition allowed a state file that said "complete" while the enable had failed, with no mechanism to break the resulting loop.

And the same class of failure in a third direction is what motivated the target-volume policy: the earlier further revision's startup gate was correct in isolation, but the state it was querying was not the state reagentc actually cares about. The 2026-09-29 test is what made that visible.

And in a fourth direction, the same class of failure is what motivated the v44 patch 1 `DesiredStateId` change: the ID was correct in isolation, but the hardware state it was querying did not include the inputs that determine VMD driver selection. A machine whose VMD presence changed would have taken the fast path with a stale driver set, and the resulting WinRE could not see the OS disk. The VMD-flip gap is the same shape as the BitLocker gap — the check was answering a question, but not the question the downstream code needed answered.

And in a fifth direction, the same class of failure explains the delete-and-recreate retry that existed from v29 through v43 patch 5. That retry suspended BitLocker on C:, deleted the newly created recovery partition, and recreated it. The premise was that suspending C:'s protection would prevent the Device Encryption service from claiming the new partition. The premise was wrong: suspension changes C:'s state, and does nothing to the new partition the encryption service is about to claim. The retry logic was correct — it did exactly what it said — but it answered a question about the wrong volume. The correct answer, discovered in the v43 patch 5 (further revision 5) work, is to detect the claim after the fact and decrypt in place. The retry was removed for the same reason the earlier BitLocker functions were removed: not because the function was buggy, but because it was solving the wrong problem.

**The shared shape.** All of those failures have one property in common: each function or check was individually correct, and each was answering a question that was not the question the downstream code needed answered.

- `Test-BitLockerProtected` asked "is C: protected?" when reagentc was asking "is the target volume unencrypted?".
- The state-write gate asked "did the pipeline complete?" when the loop-breaker needed to know "did the enable step succeed?".
- The startup gate asked "is C: in a state that blocks enable-only work?" when the answer to that question was irrelevant to enable-only work.
- The `DesiredStateId` asked "has the hardware identity changed?" when the driver set could change without the identity changing.
- The delete-and-recreate retry asked "how do I stop C: from blocking this operation?" when C: was never blocking anything in the first place.
- The VMD presence check asked "did the enumeration return any devices?" when the downstream decision needed the answer to "does this machine have VMD hardware?".

The corrective pattern is the same in every case: move the check from the state that is easy to query to the state that actually matters, and record enough about the deployment's inputs that a divergence from the last known good state will be detected rather than assumed absent. That pattern is what the invariants in this document exist to enforce, and it is why each invariant is stated in terms of the question the downstream code needs answered rather than the question that is convenient to ask.

The v44 patch 3 destructive-path guard was an attempt to apply that pattern preemptively. It asked "is C: in a state where the OS-fallback route could complete?" before the destructive sequence began. That question was answerable and the answer was useful in some cases, but as v44 patch 6 review showed, it was over-broad: the dedicated-partition path's success or failure depends on the partition geometry, not on C:'s encryption state, and the OS-fallback gate already asks the same question at the point where the answer actually matters — after the destructive attempt has failed and the run is genuinely about to fall through to OS-fallback. The guard was not wrong to ask the question; it was wrong to ask it there. Patch 6 removes it, and the safety property is preserved by the gate that asks the right question at the right point.

The v44 patch 4 program lock is a different class of problem — a mutual-exclusion problem, not a wrong-question problem — and is included in the invariants because the pre-patch-4 code lacked any mechanism to enforce the exclusivity the WorkDir design assumed. The corrective pattern for that class is to move the coordination from an implicit assumption ("the scheduled task won't overlap") to an explicit, kernel-enforced primitive, and to accept that the primitive is defensive rather than authoritative (a broken lock logs and proceeds).

## Related documents

- [state-and-idempotency.md](state-and-idempotency.md) — details on the state file, checkpoint file, and how they interact, plus the offline fallback's residual risk and the planned `LocalInputsId` field.
- [recovery-partition.md](recovery-partition.md) — the partition lifecycle in depth.
- [driver-injection.md](driver-injection.md) — injection and the success gate.
- [exit-codes.md](exit-codes.md) — every exit path.
