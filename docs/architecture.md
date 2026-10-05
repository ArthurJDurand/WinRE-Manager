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

Entered when: WinRE is enabled, the state file matches, the currently-registered recovery partition is **type-coded and** on the OS disk, exactly one **type-coded** recovery partition exists on the OS disk, and the currently-registered WinRE image's servicing metadata matches the `DeployedWinREMetadata` anchor recorded in the state file (v47).

Effect: `Remove-StrayRecoveryPartitions` enforces the "no recovery partition on non-OS disks" invariant, any stale `PendingReboot` / `RepairAttempts` / `EnableFailureAttempts` counters and a stale `LastEnableResult` are cleared by a single state-file rewrite, and the script exits. This is a read-only scan plus, if needed, one small state-file write on a healthy machine.

If the manifest fetch failed and the state file's local safety checks pass, the fast path can also fire under the **offline fallback** (v44 patch 5). The script trusts the state file's stored `DesiredStateId` directly, skips the OEM pack resolution and VMD detection (both require the manifest), and exits `EXIT_WARNING` because `$Script:offlineFallback = $true`. Under v47 the offline fast path additionally requires a state file whose `DeployedWinREMetadata` anchor matches the currently-registered image's metadata; a state file written by v46 or earlier has no anchor and forces a rebuild on the first v47 run regardless of network state. From the second v47 run onward the offline check is metadata-based. The machine is unchanged; the exit code signals that the fast path was taken without a live manifest fetch. See the "Control-flow invariants" section and [state-and-idempotency.md](state-and-idempotency.md) for the residual risk.

### Enable-only path

Entered when: WinRE is disabled but the current WIM is already correct (the state file matches and the WIM is present at the registered location).

Effect: **prepare the target recovery partition first** via `Set-RecoveryPartitionReadyForWinRE`. This is the v43 patch 5 (further revision 5) change: reagentc's BitLocker check is on the target volume, not on C:, so the target must be unencrypted by the time `/enable` runs. The helper decrypts the target in place with `manage-bde -off` and polls for completion if needed, up to a 300-second timeout. It does not touch C:'s BitLocker state.

If the target cannot be made unencrypted, the enable-only path records the failure, increments the state file's `EnableFailureAttempts` counter, writes `LastEnableResult = "failed"`, removes the checkpoint file, and exits `EXIT_WARNING`. Otherwise it proceeds to `reagentc /setreimage` followed by `reagentc /enable`. Four possible outcomes from that call:

- **`"ok"`** — enable succeeded, no reboot required. Exit `EXIT_SUCCESS` (or `EXIT_WARNING` if a non-fatal warning was set).
- **`"reboot"`** — enable succeeded but requires a reboot. Write the state file with `PendingReboot = true` and exit `EXIT_REBOOT_REQUIRED` (code 1).
- **`"failed"`** — generic hard failure. Increment the state file's `EnableFailureAttempts` counter, write `LastEnableResult = "failed"`, remove the checkpoint file, and exit `EXIT_WARNING` (code 2). **The enable-only path deliberately does not fall through to full update on this outcome.** The deployment is already current; a rebuild would not change the outcome of the enable step. The next run will retry enable-only. After three consecutive failures the loop-breaker fires (see below).
- **`"bitlocker"`** — reagentc refused because the target volume is BitLocker-protected, even after the helper prepared it. Increment the counter with `LastEnableResult = "bitlocker"`, remove the checkpoint file, and exit `EXIT_WARNING`. This is rare under the new policy: it means either the Device Encryption service re-claimed the volume between preparation and `/enable`, or the target reagentc is checking is not the partition the helper prepared. The loop-breaker counts this alongside `"failed"`.

### Full-update path

Entered when: anything has changed — new Windows build, new driver manifest version, new OEM pack version, no state, a change in CPU generation or VMD presence that has moved the `DesiredStateId`, a registered WinRE image whose servicing metadata has drifted from the `DeployedWinREMetadata` anchor (v47), a classifier-detected problem such as a recovery partition on a secondary disk, or a label-only recovery partition on the OS disk that no longer qualifies as DEDICATED.

Effect: the eight-step pipeline. This is the long path. At the end of Step 6 the state file is written with a `LastEnableResult` and `EnableFailureAttempts` that reflect the run's `$enableResult`; on a `"failed"` or `"bitlocker"` outcome the counter is incremented, on any other outcome it resets to 0. The state file also records `DeployedWinREMetadata` (v47) — the `Version|SPBuild` of the image that was actually deployed.

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

The offline fallback trusts the state file's stored `DesiredStateId` **without verifying that the machine's local hardware still matches the inputs that produced it.** This is the residual risk. On a machine whose hardware changed while offline — a CPU swap, a BIOS update that flipped VMD, or a motherboard replacement that changed `Manufacturer` / `Model` / `MachineType` — the offline run could take the fast path with a stale DSI. The next successful manifest fetch detects the drift and forces a rebuild. A `LocalInputsId` field in the state file would close this; it is planned as its own version boundary. Under v47 the offline fast path additionally requires a `DeployedWinREMetadata` anchor matching the currently-registered image's servicing metadata, so the offline path is metadata-based from the second v47 run onward; this changes the signal that gates the fast path but does not close the underlying hardware-drift residual. See [state-and-idempotency.md](state-and-idempotency.md) for the full discussion.

### VMD fail-closed guard (v44 patch 6)

When the manifest is available, the script determines VMD hardware presence by enumerating present PnP devices that match the union of the manifest's `requiredDevices` patterns. As of v44 patch 6 the enumeration is fail-closed: if `Get-PnpDevice` reports an error during the query, the run treats VMD presence as **indeterminate** rather than as absent.

An indeterminate result means the correct driver set cannot be determined. Proceeding on a guess would risk selecting a driver set that omits the VMD package on a machine that has VMD hardware; the resulting WinRE would not be able to see the OS disk, which is exactly the failure mode the v44 patch 1 `DesiredStateId` change was designed to prevent. The run logs the enumeration error, sets `$Script:nonFatalWarning = $true`, removes the checkpoint file, and exits `EXIT_WARNING` **before** committing any state. No WIM is deployed, no partition is touched, no `reagentc` call is made. The next run retries the enumeration.

Under `-DryRun` the check logs the enumeration error and continues; the exit is not predicted. See [troubleshooting.md](troubleshooting.md) for the resolution.

## The eight steps

The full-update path.

**Step 1 — Wipe WorkDir.**
Delete `<WorkDir>\mount` and `<WorkDir>\base.wim` under the workspace selected in this run. Checkpoint as `Step=1`.

**Step 2 — Obtain base WIM.**
Source selection (v47). The base WIM is sourced from one of three places, in preference order: the currently-registered WinRE image, the manager's last-known-good copy at `C:\Recovery\WindowsRE\winre.wim`, or the GitHub repository. The registered image wins unless the LKG is provably newer by DISM servicing metadata (`Version` + `SPBuild` + `SPLevel`, with `Architecture` required to match); the LKG is trusted only when its SHA256 matches `state.CurrentImageHash`; GitHub is the last resort. A WIM found by the loose fallback-discovery path is no longer a source-selection candidate. Copy the selected source to `WorkDir\base.wim`; record the source's SHA256 for the Step 4 checkpoint. Checkpoint as `Step=2`.

As of v44 patch 6, the GitHub download path removes any stale `winre.wim` at `$WorkDir\winre.wim` before invoking 7-Zip, verifies that 7-Zip produced `winre.wim` after extraction, and removes any stale `base.wim` at `$WorkDir\base.wim` before the `Rename-Item` call. Before patch 6, an interrupted previous run could leave a `base.wim` in place at the moment the next run reached the rename; the rename would fail and the machine would not progress past Step 2 until an operator deleted `WorkDir` by hand.

**Step 3 — Mount, strip, inject, dismount.**
Mount `base.wim` with `Mount-WindowsImage`.

**Strip every third-party driver (v47).** `Remove-AllThirdPartyDrivers` enumerates the mounted image with `Get-WindowsDriver -Path $MountDir` (no `-All`, no provider filter), removes each published `OEM#.inf` one at a time with `Remove-WindowsDriver`, and re-enumerates after every removal because the published numbering can change as packages are removed. The loop terminates only when a fresh enumeration returns zero entries. Every failure mode rejects the candidate: enumeration failure, removal failure, a missing `Driver` field on an enumeration entry, or budget exhaustion. Enumeration failure is never interpreted as zero drivers. On rejection the caller dismounts with `-Discard`, rolls the checkpoint back to Step 2, removes `base.wim` and any stale `winre_optimized.wim`, and exits `EXIT_WARNING` — no injection, no export, no partition work, no `reagentc` call. The pre-strip inventory is logged as one line per package (published INF name, provider, version, original filename) for field evidence.

Then capture the pre-injection third-party driver count via `Get-WindowsDriver` — expected to be zero after the strip. Download the OEM pack (vendor-specific: CAB for Dell, EXE for Lenovo, SoftPaq EXE for HP), extract to a temp dir, `Add-WindowsDriver -Recurse`. Then, if VMD hardware is present and manifest VMD drivers match the CPU generation, download each VMD pack, extract, `Add-WindowsDriver`. Success gate: the package's INF basenames must appear in the mounted image's third-party drivers after injection, OR the pre/post delta must be > 0. See [driver-injection.md](driver-injection.md).

Lenovo OEM pack resolution distinguishes five states as of v44 patch 6: `unknown-mt`, `map-unavailable`, `no-entry`, `malformed-entry`, and `resolved`. `unknown-mt` and `no-entry` are legitimate "no pack available for this machine" answers and let the run proceed with `OEMPACK=NONE`. `map-unavailable` and `malformed-entry` mark the run with `$Script:ImageInjectionComplete = $false`.

Once injection is confirmed complete (`$Script:ImageInjectionComplete = $true`), run `dism /image:<MountDir> /cleanup-image /StartComponentCleanup /ResetBase` on the mounted image. ResetBase removes superseded components from the WinSxS store inside the image; the size reduction it represents does not appear in the `.wim` file on disk until the image is re-exported in Step 4. ResetBase failure is non-fatal.

Dismount with `-Save` to commit the strip (no-op when the source was already clean), the injected drivers, and the ResetBase changes to `base.wim`. Checkpoint as `Step=3` **only if** `$Script:ImageInjectionComplete` is `$true`. After this block, if `$Script:ImageInjectionComplete` is `$false`, the pipeline exits with `EXIT_WARNING` before Step 4 (the v44 patch 1 pipeline gate), and the abort branch removes both `winre_optimized.wim` and `base.wim` from `WorkDir`.

**Step 4 — Optimize.**
`dism /Export-Image /Compress:max` to `winre_optimized.wim`. This is where the ResetBase savings from Step 3 are materialised on disk as a smaller file. The exit code is checked; a non-zero exit is fatal. Checkpoint as `Step=4` **only if** `$Script:ImageInjectionComplete` is `$true`. The v47 checkpoint additionally records the source-content hash that produced this WIM (from Step 2, or recovered from `base.wim` when this execution resumed at Step 3), so a later resume can prove the staged WIM was prepared from a source that is still available with the same bytes.

**Step 5 — Ensure a suitable recovery partition.**
Two-step decision:

1. `Find-SuitableRecoveryPartition` scans the OS disk for existing recovery partitions. It accepts the candidate only if:
   - There is exactly one.
   - It is not the OS partition.
   - **It is type-coded** — GPT recovery GUID `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}` or MBR type `0x27`. A partition detected only by a `Recovery` / `WINRE` volume label is not accepted, is not counted toward the "exactly one" condition, and is not reused.
   - Its total size is at least `WIM + 250 MiB`.
   - Its effective free space (current free + existing WIM size) is at least `WIM + 250 MiB`.

   Encryption state is **not** a rejection criterion. The target-volume policy means an existing encrypted recovery partition is usable — `Set-RecoveryPartitionReadyForWinRE` will decrypt it in place before reagentc is called.

2. If no candidate passes, `Ensure-AdequateRecoveryPartition` performs the destructive path. As of v45 patch 1 the pipeline is shrink-first: a read-only geometry plan runs before any state-modifying action; if the plan calls for a C: shrink, the shrink runs **before** `reagentc /disable` and **before** any partition deletion. A shrink failure at that point returns `Deferred` with the old route intact. If the shrink succeeds, the script disables WinRE, deletes every **type-coded** recovery partition on the OS disk (label-only matches are never deleted), extends C: into the reclaimed space if the plan called for it, creates a new partition at the aligned boundary with the recovery type GUID or type code already applied, formats as NTFS with label `Recovery`, asserts the whole layout, verifies no auto-encryption occurred, decrypts in place if the Device Encryption service claimed the partition anyway, and returns.

   The plan clamps the usable extent end to `diskSize − 1 MiB` before aligning, on both branches (v46 patch 1), so no partition — blocking or reclaimable — can push the aligned boundary past the disk-end reserve. The whole-layout assertion re-queries the newly created partition and confirms identity, exact offset, size within one alignment block, no overlap with C:, C:-to-recovery gap within one alignment block, and end at the current plan's own end (`$plannedEnd`). On the normal path `$plannedEnd` equals `$plan.AlignedManagedExtentEnd`; when the extension-failure fallback ran, `$plannedEnd` reflects the fallback geometry (a partition ending where it was deliberately placed, not at the abandoned pre-fallback extent end). If the assertion fails, `Remove-OrphanPartition` cleans up and the run falls through to OS-fallback.

   C:'s encryption state is **not** consulted. The dedicated-partition path's objective is to create a dedicated partition; it succeeds or fails on the partition geometry, not on C:'s BitLocker state.

   **The safety property** — never leave a machine with no working recovery route — holds in the two ordinary cases:

   - **The destructive attempt succeeds.** The machine ends up with a working dedicated recovery partition; the OS-fallback gate is never reached and C:'s state is irrelevant.
   - **The destructive attempt fails before deletion.** No partition was destroyed; the existing recovery route is intact.

   It does not hold in one narrow corner: **a destructive attempt that fails *after* the existing recovery partition has already been deleted, on a machine whose C: is encrypted.** The v45 shrink-first reorder narrowed the trigger set — a shrink failure no longer reaches this corner because the shrink runs before deletion — but a `New-Partition` failure, a `Format-Volume` failure, a whole-layout assertion failure, a drive-letter assignment failure, or a post-delete extension failure can still reach it. In that corner, `Restore-OSPartitionSize` restores C:'s geometry and `Restore-PreviousWinRERoute` attempts to re-enable the previous route; if the route was restored but C: geometry did not verify, the distinct reason `recovery partition deletion failed; previous route restored but C: geometry restore unverified` is returned and `$Script:GeometryRestoreFailed` is set, so the state file is invalidated and the next run retries from clean (v46 patch 2). If the route could not be restored at all, the run returns `$null` and the main flow falls through to OS-fallback, where the OS-fallback gate checks C:, finds it encrypted, and defers. The machine ends with neither a dedicated recovery partition nor OS-fallback.

   This is a documented residual, not a design intention. The correct fix is a **post-failure** check in the post-deletion failure branches that attempts an immediate `reagentc /enable` against `C:\Recovery\WindowsRE` before exiting — closing the corner and shortening the `disable` → `enable` window in the failure case. That fix is gated on the deliberate post-deletion failure test documented in [testing.md](testing.md).

   As of v46 patch 2, the destructive sequence also fails closed if the active WinRE route cannot be resolved to a partition (pre-deletion resolver guard) or if the OS partition cannot be resolved for the layout assertion (assertion fail-closed branch).

**Step 6 — Deploy the WIM.**
First, prepare the target: `Set-RecoveryPartitionReadyForWinRE` on the recovery partition, or — for the OS-fallback route — a check on C:'s `VolumeStatus` that defers unless it is `FullyDecrypted`. The OS-fallback check exists because reagentc refuses to enable WinRE on an encrypted OS volume, always. The script never modifies C:'s BitLocker state.

Then: copy the source WIM to the target directory. Verify SHA256. Set the file hidden + system. Call `reagentc /setreimage /path \\?\GLOBALROOT\device\harddiskX\partitionY\Recovery\WindowsRE`, then `reagentc /enable`. Write the state file with the deployed WIM hash, the enable outcome (`LastEnableResult`, `EnableFailureAttempts`), and the deployed image's servicing metadata (`DeployedWinREMetadata`, v47). Clear the checkpoint.

**Step 7 — Enforce the single-recovery-partition invariant.**
`Remove-StrayRecoveryPartitions` deletes any type-coded recovery partition (GPT GUID `{de94bba4-...}` or MBR type `0x27`) on any non-OS disk. A partition on a non-OS disk that carries only a `Recovery` *label* but no type code is logged and skipped. As of v46 patch 2, the `Get-Partition -DiskNumber` calls inside `Get-RecoveryPartitions` carry `-ErrorAction SilentlyContinue`, so a disk that exposes no partitions does not throw.

**Step 8 — Final verification.**
Re-read WinRE state. Classify the registered location: `DEDICATED` (recovery partition on OS disk), `OS-FALLBACK` (on the OS partition), or `UNEXPECTED` (neither). A partition detected only by a `Recovery` / `WINRE` volume label — with no matching type code — does not reach `DEDICATED`; it falls through to `UNEXPECTED`. If dedicated, remove any temporary drive letter that the script assigned during the pipeline. If OS-fallback, warn that the run is degraded but functional.

## The six state-carrying artifacts

| Artifact | Path | Purpose | Lifetime |
|---|---|---|---|
| **State file** | `C:\Recovery\OEM\winre_state.json` | Records the deployed WIM hash, `DesiredStateId`, the enable outcome (`LastEnableResult`, `EnableFailureAttempts`), and the last-deployed WinRE servicing metadata (`DeployedWinREMetadata`, v47). | Persists across runs. |
| **Checkpoint file** | `C:\ProgramData\OEM\Logs\winre_checkpoint.txt` | Records the highest completed step of the current pipeline; from Step 3 onward, also records the source-content hash of the WIM that produced the staged candidate (v47 patch 2). | Deleted at end of run. |
| **Log file** | `C:\ProgramData\OEM\Logs\WinRE-Manager.log` | Append-only event log. | Rotated by the operator, not by the script. |
| **Program lock file** | `C:\ProgramData\OEM\Logs\WinREManager.lock` | Exclusive-handle target for the single-instance guarantee (v44 patch 4). | Persists across runs; the file's existence is not the lock, the open handle is. |
| **Partition deferral marker** | `C:\Recovery\OEM\winre_partition_deferred.json` | Suppresses identical retries of the pre-shrink deferral while the old route remains verified functional (v45 patch 1). | Persists across runs until cleared; cleared on DSI mismatch, on the route becoming non-functional, or when the fast path would fire. |
| **WorkDir** | Selected at run time from an eligible fixed NTFS volume on an allowlisted internal/virtual bus; recorded in the checkpoint. | Scratch space for mounts, downloads, and intermediate WIMs. | Deleted at Step 6. |

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

The design deliberately excludes things that change frequently but should not trigger a rebuild: the current date, the current WIM hash at the registered location (that's a separate check), and the machine's serial number. As of v47 the WIM hash is also no longer a rebuild trigger at all — the drift detector compares servicing metadata (`Version` + `SPBuild`) instead. The WIM hash remains in use for copy verification, deployment verification, LKG validation, and the pre-`/disable` race detector, but it does not enter the `DesiredStateId` and does not force a rebuild on its own. The `DeployedWinREMetadata` field plays the drift-detection role.

`LastEnableResult` and `EnableFailureAttempts` are *not* part of the `DesiredStateId` — they are runtime counters that affect the control-flow decision, not the identity of the deployment. A machine with a non-zero counter is still "the current deployment" as far as the state-file comparison is concerned; the counter tracks the *enable* step's history, not the *deploy* step's identity.

`DeployedWinREMetadata` (v47) is also *not* part of the `DesiredStateId`. It records what the last successful deployment actually produced, so the next run's drift detector has a baseline to compare the currently-registered image against. It is an *observed* value, not a *desired* input; the same reasoning that keeps the WIM hash out of `DesiredStateId` applies to it.

The deferral marker (v45 patch 1) is also *not* part of the `DesiredStateId`. Its `DesiredStateId` field records the DSI under which the deferral was written, but the marker's presence does not change the DSI.

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
| The extension-failure fallback never creates a partition larger than the 2 GiB managed-recovery ceiling. | v47 patch 2 ceiling-fill in the fallback branch: `min(AvailableSize, 2 GiB)`. |
| No failure path leaves C: permanently shrunken. | `Restore-OSPartitionSize` on every post-shrink failure path; `$Script:GeometryRestoreFailed` invalidates the state file. |
| A failed injection never reaches deployment. | Step 3 → Step 4 pipeline gate on `$Script:ImageInjectionComplete`. |
| A candidate image never reaches injection without first being normalized to zero third-party drivers. | v47 strip stage as a hard gate. |
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
| A strip failure preserves the machine's existing recovery route. | v47 strip hard gate — candidate rejection happens before any partition work or `reagentc` call. |

**The residual corner, named honestly.** Rule 2 cannot be *guaranteed* in the case where the old recovery partition has already been deleted, a later step fails, and C: is encrypted — the OS-fallback gate refuses on encrypted C:, so the machine ends with neither a dedicated partition nor a working route until the next run. The v45 shrink-first reorder narrowed this corner without closing it: the shrink is no longer the trigger, but a post-deletion create, format, layout-assertion, drive-letter, or extension failure is. The gating post-deletion failure test documented in [testing.md](testing.md) is the mechanism that will close it.**A second residual, narrower in scope.** A layout that places a non-recovery partition between C: and the type-coded recovery partition cannot be reconciled by the current single-boundary geometry model. The plan requires the recovery partition to abut C:, and native tooling cannot shift a partition's start rightward without moving its data. Production defers stably with the enriched rejection reason naming the intervening partition; the machine does not converge to the modern layout automatically. The manual path is to remove the intervening partition or to shrink it from the right and extend the recovery partition leftward by hand. The v48 design candidate (shrink the intervening partition automatically) is the design response; it is not part of v47 patch 3.

### Rule 3 — minimize the `reagentc /disable` → `reagentc /enable` window

For the duration of that window, WinRE is not registered: `reagentc /info` reads `Disabled`, and `reagentc` will refuse to hand off to a recovery image. The script therefore runs **everything that does not strictly require a disabled WinRE before the disable**, and **only the operations that require a disabled WinRE inside the window**.

**Before the window:**

- Manifest fetch, OEM pack resolution and download, VMD package resolution and download, driver extraction and INF validation.
- Base WIM source selection, acquisition (registered copy, hash-validated LKG copy, or GitHub), and content-hash capture.
- Image mount, third-party driver strip, current-recipe injection, ResetBase, export, `WIM_READY` checkpoint, `base.wim` cleanup.
- Registered-source fingerprint capture.
- Read-only geometry plan, free-space check, pre-shrink (with its sleep and defrag retries), post-shrink verification and actual-geometry recomputation.
- Pre-deletion inventory, pre-deletion resolver guard.

**Inside the window:**

- (Nothing before this line runs after the pre-shrink but before the `/disable`; the fingerprint recheck is the first operation inside the window's entry, immediately before the `/disable` call itself.)
- Partition delete.
- Post-delete C: extension.
- `New-Partition`, `Format-Volume`, `Set-RecoveryPartitionAttributes`, drive-letter assignment.
- WIM copy to the new partition, hash verification.
- `reagentc /setreimage` and `reagentc /enable`.

**After the window:**

- Fallback WIM refresh, stray-partition cleanup, final verification, state write.

The longest operation inside the window is the WIM copy — typically 700–1000 MiB onto a freshly created partition. It cannot be moved out: the partition being replaced is the one the WIM is being deployed to. Everything else that can be moved out has been. The v47 source fingerprint recheck is a bounded addition to the window's entry — one SHA256 of a ~750 MiB WIM, roughly 1–3 seconds — and it runs only once per actual rebuild.

**Why this matters operationally.** If the machine loses power, blue-screens, or is forced off inside the window, `reagentc` is left disabled and the recovery partition is in whatever state the interruption left it. The shorter the window, the smaller the exposure. The single-run recovery story is: `Restore-PreviousWinRERoute` on delete failure; `Remove-OrphanPartition` plus `Restore-OSPartitionSize` on create failure; the enable-only path on a clean-but-disabled state. The crash-inside-the-window case is not fully covered today — the same post-deletion failure test that gates the eventual fix for Rule 2's residual also gates the eventual fix for this one.

### Rule 4 — do no work unless needed; prepare everything before touching anything

This is the working rule. It is subordinate to 1–3 in that any conflict resolves in favor of 1–3, but it is the mechanism through which 1–3 are enforced on the fast path and the enable-only path, and through which the destructive path is made to fail safe.

**"Do no work unless needed"** — three tiers:

- **Tier 1 (fast path).** State file matches, image is current, partition is correct. No WIM mounted, no partition touched, no `reagentc` call. Runtime is dominated by Windows' own CIM and PnP enumeration.
- **Tier 2 (enable-only).** Image current, WinRE disabled. Prepare the target partition and call `reagentc /enable`. No partition geometry change, no rebuild, no C: shrink.
- **Tier 3 (full update).** The image is missing, stale, or the partition is wrong-sized. This is the only tier that does destructive work.

**"Prepare everything before touching anything"** — the mandatory ordering inside Tier 3:

1. Resolve the manifest, the OEM pack, the VMD packages. Select the base WIM source.
2. Download and verify every external artifact — hash check against the manifest-declared values; INF-count check after extraction.
3. Only when every artifact is verified: mount the base WIM, strip its third-party driver set to zero (v47), inject the resolved drivers, run ResetBase, export the optimized WIM, checkpoint `WIM_READY`.
4. Only when the image is ready: run the read-only geometry plan.
5. Only when the plan is valid: run the pre-shrink in the reversible window.
6. Only when the pre-shrink has verified: enter the destructive window.

**The failure semantics of Rule 4.** If driver download fails, or OEM pack extraction produces zero INFs, or the VMD package cannot be resolved for the CPU generation, or the base WIM cannot be verified, or the strip stage cannot prove zero third-party drivers remain — the script stops before it touches the recovery partition. The old recovery route stays intact. The run exits `EXIT_WARNING` with a named reason in the log. Nothing is destroyed in the service of a rebuild that could not have succeeded anyway.

This is exactly how Rule 4 reinforces Rules 1 and 2: the destructive sequence is only reachable through a chain of successful preparations, so no partition operation is ever performed as preparation for another partition operation that might fail. Every failure point has been moved into the reversible window or excluded from the pipeline entirely.

**"Drivers go into a clean base"** is a corollary of Rule 4 for the image-servicing step. The recovery image on a machine that has ever run the script carries *our* previously injected OEM and VMD drivers. Before new drivers are injected, the image is normalised so the injection targets a clean baseline rather than a stale one with our own prior layers still present. Without that normalisation, the effective driver set is a function of the image's own prior history, and the deployment identity stops being a reliable fingerprint of the image contents. The **mechanism** is the v47 strip stage: the mounted image is stripped to zero third-party drivers, proven by re-enumeration, before the current recipe is injected. The strip is a hard gate — a candidate that cannot be proven clean is discarded. See "The v47 rebuild pipeline" below for the full description.

## The v47 rebuild pipeline

The v47 release changes the way a rebuild selects and prepares its seed image. It does not change the four design invariants, the four control-flow paths, or the eight-step pipeline shape; it changes what happens inside Step 2 (source selection) and Step 3 (image servicing), and it adds a pre-`/disable` recheck that runs before whichever `reagentc /disable` an execution reaches first.

The change was driven by an architectural problem in the pre-v47 design. Every rebuild seeded from the currently-registered WinRE image, so rebuild N depended on rebuild N−1 and third-party drivers injected by prior runs accumulated silently inside the registered image. The deployment identity (`DesiredStateId`) remained a fingerprint of the *inputs* that produced the image, but the image's *contents* drifted as a function of the machine's rebuild history. Two consequences followed: the fleet could not be externally proven to hold a normalized driver set, and a machine that had been rebuilt many times carried more driver packages than a freshly-provisioned one under the same recipe.

The fix is to strip every third-party driver from the mounted image — proving by re-enumeration that zero remain — and then inject only the current recipe. The resulting image is a deterministic function of the current recipe plus Microsoft's current WinRE base, with no memory of prior rebuilds.

### Source selection

Step 2 now selects the base WIM from one of three sources, in preference order:

1. **The currently-registered WinRE image.** The default source when its servicing metadata (`Version`, `SPBuild`, `SPLevel`, with `Architecture` required to match) is at least as new as the manager's last-known-good copy.
2. **The manager's last-known-good copy** at `C:\Recovery\WindowsRE\winre.wim`. Used when it is provably newer than the registered image, when the registered image's metadata cannot be read, or when the registered image is not usable.
3. **The GitHub base-WIM repository.** Used only when neither local source is usable.

The **regression guard** is the point of the ordering. Without it, a machine whose registered WinRE had been rolled back — by a failed WU servicing operation, a disk-level restore, or an operator action — would seed its next rebuild from the older image, and the manager would have no way to know the source had regressed. The comparison is metadata-based (`Version` first, `SPBuild` as the tiebreak, `SPLevel` as a secondary tiebreak) because Microsoft documents that an LCU bumps `SPBuild` while the base `Version` can remain unchanged; a `Version`-only comparison would tie across an LCU and select the wrong source. An indeterminate comparison (metadata shape mismatch, unparseable field) defers to the LKG: the registered image is not proven at least as new as the LKG, so the hash-validated copy wins.

The LKG is trusted only when its SHA256 matches `state.CurrentImageHash`. The state file's hash is written *after* the fallback copy in Step 6, so a partial copy from a crashed prior run leaves a file whose hash does not match the recorded value, and the file is not promoted. No new persistence field is needed: the state file already carries the hash of the last successfully deployed WIM, and the fallback copy is written with that same content.

A WIM found by the loose fallback-discovery path is no longer a source-selection candidate. The old v46 discovery could populate `$ActiveLocationImage` with a fallback file when the registered location yielded nothing readable; that path is now excluded from source selection. If the registered location yields no readable WIM, the LKG is the next candidate; only if the LKG is also unusable does the GitHub cold-start fire.

### The last-known-good copy

`Get-LKGWinREImagePath` returns a `@{ Path; Hash }` pair when the LKG is valid, `$null` otherwise. The validity test has two parts:

- The file exists at `C:\Recovery\WindowsRE\winre.wim` and is readable.
- Its SHA256 matches `state.CurrentImageHash`.

The second condition is what makes the copy "known good". A stale file, a partially-written file from a crashed prior run, or a file that has been tampered with all fail the equality and are not promoted. The helper logs a WARN on each failure so a fleet-wide hash mismatch is visible in the logs.

### The strip stage

Step 3 inserts a strip between mount and injection. `Remove-AllThirdPartyDrivers` takes the mounted image and removes every third-party driver from it:

- Enumerate with `Get-WindowsDriver -Path $MountDir`. No `-All`. No provider filter. This is the form Microsoft documents as the third-party inventory of a mounted image.
- For each published `OEM#.inf`, call `Remove-WindowsDriver -Path $MountDir -Driver <published name>`.
- Re-enumerate after every removal, because the published numbering can change as packages are removed (removing `oem5.inf` may renumber `oem7.inf` to `oem5.inf`, and so on). The loop terminates only when a fresh enumeration returns zero entries.

The strip is a **hard gate**, not a best-effort operation. Every failure mode rejects the candidate:

| Failure | Result |
|---|---|
| Initial enumeration fails | Candidate rejected. |
| Re-enumeration fails at any iteration | Candidate rejected. |
| Enumeration entry is missing its published INF name | Candidate rejected. |
| `Remove-WindowsDriver` fails for any entry | Candidate rejected. |
| Iteration budget exhausted without reaching zero | Candidate rejected. |
| Final enumeration returns a non-zero count | Candidate rejected. |

Enumeration failure is never interpreted as zero drivers. There is no `catch {}` that swallows an error and returns success. On rejection the caller dismounts with `-Discard`, rolls the checkpoint back to Step 2, removes `base.wim` and any stale `winre_optimized.wim`, and exits `EXIT_WARNING`. No injection, no export, no partition work, and no `reagentc` call occurs.

The pre-strip inventory is logged as one line per third-party package, with the published INF name, provider, version, and original filename. This is diagnostic: it records what the source image contained before the strip, and over time the fleet logs answer whether Microsoft's WU servicing ever delivers a WinRE image with third-party driver packages already present.

### Why the strip is Rule 4's enforcement, not a separate rule

Rule 4 says "prepare everything before touching anything". The strip is a preparation step in the fullest sense: it produces a candidate image that is provably what the current recipe says it should be, before any partition work begins. The order matters:

1. Source selection.
2. Copy source to `base.wim`. Verify the copy.
3. Mount `base.wim`.
4. Strip to zero third-party drivers. Prove zero.
5. Inject the current recipe.
6. Verify the injection.
7. ResetBase.
8. Export. `WIM_READY`.
9. Only then: partition work, disable, deploy, enable.

If step 4 cannot be proven, steps 5–9 never run. The candidate is discarded; the machine's existing recovery route is untouched. That is the "prepare everything" discipline applied to the image itself: no state-modifying operation runs against a candidate that has not first been proven to match the current recipe.

### The pre-`/disable` race detector

Windows Update can service or replace the registered WinRE while the script is preparing a candidate. The preparation takes minutes; a WU servicing pass is smaller but can complete in that window. If the registered image is replaced between source capture and the first `/disable`, the script would deploy a candidate based on a source that no longer exists and would overwrite a newer Microsoft image with one derived from the previous one.

The **race detector** narrows that window from minutes to microseconds:

1. Immediately before source acquisition: capture the registered image's location, version, and WIM SHA256.
2. Immediately before whichever `reagentc /disable` this execution reaches first: re-read all three.
3. If any of the three has changed: abort before `/disable`. Discard the candidate, invalidate the checkpoint, defer.

Both `/disable` sites are wrapped — the `Ensure-AdequateRecoveryPartition` site (which runs after the pre-shrink, so an abort restores C: to its captured size first) and the Step 5 deployment site (which runs with the old route intact, so an abort is a clean defer). Only one fires per execution; whichever fires first performs the recheck. The helper handles three capture states: `'captured'` (full fingerprint, all three fields re-read and compared), `'unreadable'` (WinRE was Enabled with a registered location but the WIM could not be read at capture time — the recheck verifies location and version are unchanged and the WIM is still unreadable before allowing the repair path to proceed), and `'none'` (WinRE was not Enabled or had no registered location — the recheck verifies no registered source has appeared since).

The detector is **named honestly as a race detector, not a lock**. Microsoft does not document `reagentc /disable` as atomic with respect to Windows Update. The microseconds between the final re-read and `/disable` returning cannot be closed without moving the re-read inside the disable→enable window, which would lengthen that window and violate Rule 3. The detector reduces the exposure window from minutes to a residual that is not addressable without violating a higher-priority invariant.

### The WIM_READY checkpoint's source binding

The `WIM_READY` checkpoint is the entry point for a resumed execution that skipped Step 2 (resumed at Step 3, then completed the export at Step 4). Under v47 the checkpoint records a fifth field: the SHA256 of the source WIM from which the staged candidate was prepared. On resume, the checkpoint validator compares the recorded hash against the currently available sources (the registered WIM and the LKG). If the recorded hash no longer matches either available source, the checkpoint is invalidated and the candidate is discarded — the source it was prepared from is no longer present with the same bytes, so the staged WIM's lineage cannot be trusted.

Legacy four-field checkpoints written by a pre-v47 build have no source binding and are invalidated on first resume. Checkpoints prepared from a GitHub cold-start also have no source binding (there is no on-disk source to bind to) and are invalidated on first resume as a conservative rebuild. This is not a problem in practice: GitHub cold-start is rare, and the rebuild cost is the same as any other rebuild.

When the source-selection path is skipped because the execution resumed at Step 3, the source hash is recovered at Step 4 by hashing `base.wim` and matching against the registered WIM hash and the LKG hash. If `base.wim` matches neither, the source identity is left unbound and the checkpoint is written without the fifth field, which is the conservative outcome.

### Rationale for the `ScriptVersion` bump

`ScriptVersion` moves from 46 to 47. The four-rule hierarchy permits this without compromising any invariant: the bump is not a gratuitous rebuild trigger, it is the mechanism that converges the fleet on a rebuild the recipe change has already made necessary. Every managed machine performs one full update on its next scheduled run because the `SCRIPT` component of the `DesiredStateId` changed; that is the intended effect, not a side effect.

The rule is: `ScriptVersion` bumps when a change modifies the deployed WIM bytes, the partition layout that gets created, or the `DesiredStateId` inputs. The strip changes the WIM bytes whenever a rebuild happens. On a machine that is already on the current recipe, the strip is a no-op — the image is already normalized — and the deployed WIM is byte-identical to what v46 would have produced. On a machine that would carry accumulated drivers under v46, the strip produces a different WIM. The two cases cannot be distinguished from the fleet without the version boundary.

Without the bump, the fleet ends heterogeneous: machines rebuilt under v46 (or earlier) retain whatever driver packages the lineage had accumulated, and machines rebuilt under v47 carry a stripped image. The `DesiredStateId` is the same string under both cases, so the state file cannot distinguish them, and the deployment identity stops being a reliable fingerprint of the deployed artifact's contents. The v47 bump is the version boundary that forces every machine onto a common footing: every managed machine performs one full update on its next scheduled run, converges on the strip-normalized driver set, and returns to the fast path.

The bump also serves a second purpose: every machine's first v47 run writes a `DeployedWinREMetadata` anchor, so the metadata-based drift detector has a baseline. Without the bump, machines whose existing inputs happened to produce the same DSI would keep running without an anchor.

### What the empirical observation settled

The original design brief flagged a residual concern: Microsoft documents that WinRE servicing can migrate certain boot-critical or input drivers from the OS into the WIM. If Microsoft's WU servicing ever delivered a WinRE image that already contained third-party driver packages, the strip would remove them, and on the machine's next rebuild the recipe would decide what to reinstall — potentially producing a WinRE that lacks a driver Microsoft had intentionally migrated in.

The design accepts this as a named residual rather than designing around a hypothetical. The observation that closed the concern is empirical, not documentary: across the project's actual collection of WU-serviced WinRE images, no third-party driver packages have been observed in the WIMs. That is evidence, not proof — Microsoft could begin delivering such packages in a future servicing change — and the pre-strip inventory logging is the mechanism by which the project accumulates the field data that would surface a change if it occurred. If future data shows Microsoft-serviced WinRE images containing third-party packages, the strip stage is revisited.

### Residuals named honestly

Four residuals are carried forward under v47:

1. **The WU race remains a race.** The pre-`/disable` recheck narrows the exposure window from minutes to microseconds. It does not close it. Closing it would require holding a lock that Microsoft does not provide; the correct posture is to detect the change and defer, which is what the recheck does.

2. **`DesiredStateId` does not encode the strip.** The strip is part of the WIM production recipe, not an input to the deployment identity. A machine whose current recipe is unchanged will rebuild under v47 (because `SCRIPT` changed from 46 to 47) and produce a strip-normalized image; a machine whose current recipe would change next month will rebuild once under v47 (from the strip change) and once again under the next `DesiredStateId` change (from the recipe change). The two rebuilds are separate. `DesiredStateId` answers "what recipe should the deployed image reflect?"; the strip answers "what should the base image contain before the recipe is applied?" — the second is not a deployment input in the DSI sense.

3. **Metadata-neutral Dynamic Update drift is undetected as a rebuild trigger.** Microsoft documents that a Dynamic Update may change the contents of a serviced WinRE image without changing its `Version` or `SPBuild`. The v47 drift detector compares servicing metadata, so a DU delivered in that manner will not trigger a rebuild. The `WIM_READY` checkpoint's source-content-hash binding catches it for an in-flight rebuild — a staged candidate whose source is no longer available with the same bytes is invalidated on resume — but a **completed** prior deployment with no in-flight checkpoint will not be flagged by a metadata-neutral DU. In practice a machine whose registered WinRE was serviced by a DU-only update will continue on the fast path until some other deployment input (manifest version, OEM pack version, Windows build, CPU vendor/generation, VMD presence) changes. The pre-strip inventory logging is the field-evidence mechanism by which a wider fleet impact would be recognised.

4. **`LocalInputsId` is not shipped.** The offline fallback's residual (a machine whose hardware changed while offline taking the fast path with a stale DSI) remains open and is closed by the same `LocalInputsId` field that was already planned for its own version boundary. The v47 release does not touch it; the offline fast path now additionally requires a `DeployedWinREMetadata` anchor that matches the currently-registered image's metadata, so a v46-or-earlier state file forces a rebuild on the first v47 run regardless of network state. From the second v47 run onward, the offline fast path is metadata-based rather than WIM-hash-based, which is a change to which signal gates the fast path but not to the underlying hardware-drift residual.

## Control-flow invariants

These are the invariants the script maintains, in the order they are enforced. Each one has a real field failure behind it, except where explicitly noted; the `.NOTES` block in `scripts/WinRE.ps1` carries the "Critical lessons (do not regress)" list. They are the detailed enforcement of Rules 1–4 above.

1. **Exactly one type-coded recovery partition exists, on the OS disk.** Enforced on the fast path, the enable-only path, both pending-reboot exits, and Step 7 of the full-update path. A type-coded recovery partition on any non-OS disk is deleted unconditionally. A partition detected only by a Recovery/WINRE volume label is not counted, not reused, and not deleted — a label alone is never sufficient authority for any of those decisions. The invariant is absolute; the type code, not the label, is what identifies a recovery partition for every decision the script makes.

2. **No failure path leaves C: permanently shrunken.** Every post-shrink failure calls either `Remove-OrphanPartition` (which absorbs freed space back) or `Restore-OSPartitionSize`. Every failure of `Restore-OSPartitionSize` sets `$Script:GeometryRestoreFailed` so the state file is deleted and the next run retries from clean.

3. **No new WIM hash is ever written unless injection succeeded.** The full-update path and the final-verification reboot-required path both gate their `Write-WinREState` call on `$Script:ImageInjectionComplete` and a computed WIM hash; a failed injection never advances the state file's recorded hash. Other call sites (the fast path, the enable-only path, the two pending-reboot exits) write the state file for non-deployment reasons and carry the existing `$storedHash` forward unchanged. The invariant is about the recorded WIM hash, not about the presence of a state file.

4. **The pipeline stops before deployment when injection fails.** If `$Script:ImageInjectionComplete = $false` after Step 3, the script exits with `EXIT_WARNING` before Step 4 (`dism /Export-Image`), before Step 5 (partition work), before Step 6 (deployment), and before any `reagentc` call. The abort branch also removes `base.wim` and `winre_optimized.wim` from `WorkDir` so the next run's Step 2 can rename cleanly; this is the v44 patch 3 fix.

5. **Component cleanup runs on the mounted image before export, and is non-fatal.** `dism /cleanup-image /StartComponentCleanup /ResetBase` runs inside Step 3 after successful injection and before the dismount, gated on `$Script:ImageInjectionComplete`. The size benefit is not realised until Step 4's `dism /Export-Image` writes a fresh `.wim`. ResetBase failure is logged and the pipeline continues. ResetBase makes the image unserviceable for rollback, which is acceptable for a recovery image that is rebuilt from source whenever the `DesiredStateId` changes. This is the v44 patch 2 addition.

6. **BitLocker is never assumed Off, and the target volume is prepared before reagentc is called.** This is the v43 patch 5 (further revision 5) policy. It replaces the OS-volume-gate policy of the earlier further revision, which the 2026-09-29 field test disproved: reagentc's BitLocker check is on the **target** volume, not on C:. The invariant is now:

   - **The target recovery partition must be unencrypted by the time `reagentc /enable` runs.** `Set-RecoveryPartitionReadyForWinRE` enforces this. It queries the target's BitLocker state with `Test-VolumeEncrypted` (the tri-state classifier). If the target is confirmed unencrypted, it returns immediately. If it is encrypted or actively encrypting, it runs `manage-bde -off` against the target and polls at 5-second intervals up to a 300-second timeout. It is called at every point where reagentc will be invoked.

   - **The OS-fallback path is the only path that depends on C:'s BitLocker state.** In the OS-fallback case the target volume *is* the OS volume, and reagentc will refuse to enable WinRE on an encrypted OS volume. The OS-fallback gate therefore checks C:'s `VolumeStatus` before deploying the WIM and defers with `EXIT_WARNING` unless it is `FullyDecrypted`. It never modifies C:'s state. The gate uses `Test-VolumeEncrypted` (not `Get-BitLockerVolume` directly) and requires the result to be exactly `$false`.

   - **Suspension is not used.** The v43 patch 5 function `Suspend-BitLockerForWinRE` was deleted. Suspension does not prevent Device Encryption from claiming a newly created partition. Decrypting the target in place is the mechanism the policy uses; the 2026-09-29 test confirmed that a partition claimed by Device Encryption does not re-encrypt after `manage-bde -off` completes.

   - **The target may be an existing encrypted recovery partition.** `Find-SuitableRecoveryPartition` no longer rejects encrypted candidates, because the helper will decrypt them.

7. **New recovery partitions are created with the recovery type code already applied.** `New-Partition` passes `-GptType {de94bba4-06d1-4d40-a16a-bfd50179d6ac}` (GPT) or `-MbrType 0x27` (MBR) at creation time (v43 patch 5). This closes the window between `New-Partition` and `Set-RecoveryPartitionAttributes` during which the partition is a plain Basic Data partition. `Set-RecoveryPartitionAttributes` still runs after format to apply the GPT attributes (`0x8000000000000001` — PLATFORM_REQUIRED + NO_DRIVE_LETTER); it is idempotent on the type code.

8. **Self-referential file operations are guarded.** Any block that deletes a file and then writes to the same path (or copies another file onto it) checks first that the source and destination are not the same file (by `[System.IO.Path]::GetFullPath`). This guards against the v42 "fallback copy ate its own source" bug.

9. **Checkpoint advancement requires injection success.** A checkpoint that says "step 3 completed" is only written when image injection actually completed. This is v43 patch 4's fix.

10. **The Audit Mode / OOBE / sysprep guard runs before any state-modifying action.** The guard reads `ImageState` at startup and defers unless the value is absent or `IMAGE_STATE_COMPLETE`. This is the highest-priority guard in the script after the program lock, and it runs before the drive-letter cleanup, the pending-reboot block, the classifier, and any partition work.

11. **A `reagentc /enable` failure on the enable-only path does not fall through to full update, and does not loop forever.** When the deployment is current and only the enable step fails, the enable-only path increments the state-file counter and exits `EXIT_WARNING` without attempting a rebuild. After three consecutive failures the loop-breaker fires and exits `EXIT_FATAL`, requiring manual intervention.

12. **The state file never records `DeployedDiskNumber` or `DeployedPartitionNumber` as `0` for OS-fallback states.** The `Write-WinREState` parameters are `[object]` typed and the conditional that populates the state file checks `$null -ne` before the integer comparison, so a `$null` argument does not coerce to `0` and write a misleading `"DeployedDiskNumber": 0` into the state file. This is the v44 patch 1 fix.

13. **The script holds an exclusive program lock for its entire duration, from just after the startup banner to the last cleanup step in the `finally` block.** The lock is a `FileShare.None` handle on `C:\ProgramData\OEM\Logs\WinREManager.lock`, enforced by the Windows kernel. The handle is released automatically when the process exits. **The lock is deliberately not acquired under `-DryRun`.** **Failure to acquire the lock for any reason other than contention is non-fatal.** **The lock is released last in the `finally` block.** This is the v44 patch 4 addition.

14. **The offline fallback trusts the state file's stored `DesiredStateId` directly, without recomputing it from cached inputs.** When the manifest fetch fails after its retry budget, the script sets `$Script:offlineFallback = $true`, reads the state file's stored `DesiredStateId`, and skips the OEM pack resolution, VMD detection, and required-driver resolution. The local safety checks remain fully enforced. **The residual risk is that a machine whose hardware changed while offline could take the fast path with a stale DSI**; the next successful manifest fetch detects the drift and forces a rebuild. This is the v44 patch 5 addition.

15. **VMD hardware presence detection is fail-closed.** When the manifest is available, the script determines VMD hardware presence by enumerating present PnP devices that match the union of the manifest's `requiredDevices` patterns. If `Get-PnpDevice` reports an error during the query, the run treats VMD presence as **indeterminate** rather than as absent, and defers with `EXIT_WARNING` before committing any state. This is the v44 patch 6 addition.

16. **Only a type-coded recovery partition on the OS disk is authoritative.** Every decision the script makes about recovery partitions — reuse, fast-path counting, active-location classification, final verification, deletion authorization, stray cleanup — reads from a single rule: the partition must carry the recovery GPT type GUID `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}` or the MBR type code `0x27`. This is the v44 patch 7 addition.

17. **The shrink runs in the reversible window, before route destruction.** The v45 patch 1 reorder moves the pre-shrink (with its sleep and defrag retries) ahead of `reagentc /disable` and ahead of any partition deletion. A shrink failure at this point returns `Deferred` with the old route intact. The pre-shrink free-space check is fail-closed: if C:'s volume cannot be read, the run defers rather than proceeding on the assumption that the partition supported-size preflight is sufficient.

18. **The plan computes a single boundary; the recovery partition fills exactly the space between that boundary and C:'s end.** The usable extent end is `diskSize − 1 MiB`; `tailEnd` is clamped to that value before aligning, on both branches (v46 patch 1). `AlignedManagedExtentEnd = floor(tailEnd / 1 MiB) × 1 MiB`; `TargetRecoveryStart = AlignedManagedExtentEnd − B`. C: is resized so it ends exactly at `TargetRecoveryStart`, and the recovery partition of size exactly `B` fills the space up to `AlignedManagedExtentEnd`. The whole-layout assertion (`Assert-RecoveryPartitionLayout`) re-queries the newly created partition and confirms identity, exact offset, size within one alignment block, no overlap with C:, C:-to-recovery gap within one alignment block, and end at `AlignedManagedExtentEnd`.

19. **Post-delete extension has a safe fallback that prioritizes WinRE deployability over exact geometry.** When the plan calls for extending C: into the space the old recovery partitions occupied, the extension runs after deletion. If extension fails, the script re-queries C:'s current end, computes the largest recovery partition that fits between the current C: end and `AlignedManagedExtentEnd`, and places the recovery partition there with a non-fatal warning. The v47 patch 2 addition sizes that partition to `min(AvailableSize, 2 GiB)`: it fills the available extent in the common case (the surplus after a failed extension is typically a few hundred MiB, well under the ceiling) and only leaves a trailing unallocated extent when the surplus exceeds 2 GiB. The ceiling is what matters, not the plan's bucket size.

20. **The pre-shrink deferral marker suppresses retries only while the old route is verified functional.** When `Ensure-AdequateRecoveryPartition` returns `Deferred` with `RetrySuppressible = $true`, the main flow writes `C:\Recovery\OEM\winre_partition_deferred.json`. On the next run, the marker is honored only if the old route is verified functional and the fast path would not fire.

21. **A deletion failure restores the previous route when possible.** The currently active recovery partition is deleted last, so a mid-loop failure leaves it available. On any deletion failure, the script restores C: to its original size and attempts `Restore-PreviousWinRERoute`. As of v46 patch 2, the two restores are reported separately: when the route restored but C: geometry did not verify, the distinct reason `recovery partition deletion failed; previous route restored but C: geometry restore unverified` is returned and `$Script:GeometryRestoreFailed` is set.

22. **The destructive sequence fails closed if the active WinRE route or the OS partition cannot be resolved.** Two guards, both v46 patch 2. The **pre-deletion resolver guard** refuses the sequence if WinRE was `Enabled` and its registered location cannot be resolved to a partition. The **layout-assertion fail-closed branch** refuses the layout if `Get-OSPartition` returns nothing. Both refuse to proceed when the state cannot be established, rather than proceeding on the assumption that the missing state is benign.

23. **Build numbers are logged for evidence, not gated on.** Every run logs three values: the registered WinRE version, the source WIM's build, and the post-deploy WIM build. None of the three enters the `DesiredStateId`, and no gate reads any of the three. The purpose is empirical: over time the fleet logs answer whether Windows Update is updating the registered WinRE between runs, and whether any rebuild replaces a newer registered image with an older one. This is the v46 patch 2 addition.

24. **The rebuild seed is normalized to zero third-party drivers before the current recipe is injected.** The strip stage runs between mount and injection, and it is a hard gate: any failure to enumerate, remove, or re-verify rejects the candidate before any injection, export, partition work, or `reagentc` call. Enumeration failure is never interpreted as zero drivers. The pre-strip inventory is logged for field evidence. This is the v47 addition, and it is the mechanism by which "drivers go into a clean base" (Rule 4) is enforced. See "The v47 rebuild pipeline" above.

25. **The base WIM is sourced by a regression-guarded preference order.** Registered wins only when its servicing metadata is at least as new as the LKG; the LKG wins when it is provably newer or when the registered image is unusable; GitHub is the last resort. The LKG is trusted only when its SHA256 matches `state.CurrentImageHash`. An indeterminate metadata comparison defers to the LKG. A WIM found by the loose fallback-discovery path is not a source-selection candidate. This is the v47 addition.

26. **The registered-source fingerprint is re-read immediately before whichever `reagentc /disable` this execution reaches first.** A change in location, version, or WIM hash aborts before `/disable`. The detector is a race detector, not a lock. Both `/disable` sites are wrapped. This is the v47 addition.

27. **The WIM_READY checkpoint is bound to the source-content hash that produced the staged WIM.** On resume, the recorded source hash must still match an available source (the registered WIM or the LKG) or the checkpoint is invalidated. Legacy four-field checkpoints, and checkpoints prepared from a GitHub cold-start, are invalidated on first resume. When a resume from Step 3 needs to bind the source at Step 4, the source hash is recovered from `base.wim`. This is the v47 addition.

28. **The `needInject` trigger is metadata-based, not WIM-hash-based.** The currently-registered WinRE's DISM servicing metadata (`Version` + `SPBuild`) is compared against a `DeployedWinREMetadata` field recorded in the state file at the end of every successful deployment. Drift forces a rebuild; stability stays on the fast path. The WIM hash is no longer a rebuild trigger, though it remains in use for LKG validation, copy verification, and the pre-`/disable` race detector. A registered image whose metadata cannot be read forces a rebuild. A state file whose `DeployedWinREMetadata` is absent forces a rebuild. This is the v47 addition.

## Where the design choices bite

The eighteen most consequential decisions in the whole script, in the order the code reaches them rather than in any ranked order, are:

- **Shrink-first replacement (v45 patch 1).** The risky operation — the shrink — runs in the reversible window, before any partition is destroyed. A failed shrink now returns `Deferred` with the old route intact, closing the v44 residual for the shrink trigger. What changed is when each step runs and what happens if it fails.

- **Single-boundary geometry with whole-layout assertion (v45 patch 1).** The planner computes a target boundary rather than a shrink amount, and the post-creation assertion re-queries the partition to confirm it landed exactly where the plan intended.

- **The plan clamps `tailEnd` to the disk-end reserve before aligning (v46 patch 1).** The disk-end reserve is a fixed Windows convention: the last 1 MiB of the disk is not addressable for partition layout. The clamp moves the plan to the boundary the post-delete check would accept on the same layout.

- **Post-delete extension uses a safe fallback (v45 patch 1; ceiling-fill in v47 patch 2).** When the plan calls for extending C: into the space the old recovery partitions occupied, extension runs after deletion. If extension fails, the safe fallback places the recovery partition at the current C: end, sized to `min(AvailableSize, 2 GiB)`, and continues. Exact geometry is a goal, not a reason to leave WinRE disabled.

- **Dedicated recovery partition is the primary objective; OS-fallback is the failure outcome.** The script will attempt the destructive repartitioning path even when the pre-check suggests the OS cannot shrink enough. If the attempt fails, the OS is restored and OS-fallback is used with exit code 2.

- **The `DesiredStateId`-scoped retry policy.** A machine in OS-fallback with a matching state file stays in OS-fallback indefinitely, without re-attempting the destructive path. A state change naturally re-arms the retry.

- **The BitLocker policy targets the volume reagentc will enable, not the OS volume.** The enable-only and dedicated-partition paths proceed regardless of C:'s BitLocker state, because reagentc does not care about C: — it cares about the volume it is being asked to enable WinRE on. The only path that gates on C:'s state is the OS-fallback path, and it does so for a specific reason: there the target volume is C:.

- **The Audit Mode guard takes priority over everything except the program lock, including the BitLocker decision.** When `ImageState` is not `IMAGE_STATE_COMPLETE`, the script defers before it has fetched the manifest, resolved the OEM pack, computed the `DesiredStateId`, or read the state file.

- **The enable-failure counter introduces a bounded retry for the enable failure.** Before the counter, a generic `/enable` failure on the enable-only path fell through to full update and eventually exited `EXIT_FATAL` at the final-verification block. That is a silent loop. The counter turns it into a bounded retry.

- **The `DesiredStateId` is a deployment-input fingerprint, not a hardware fingerprint.** The ID should change whenever the inputs that determine the deployed WinRE artifact change, and should not change merely because unrelated machine state changes.

- **Component cleanup is applied to the mounted image, not to the export output.** ResetBase reduces the WinSxS component store inside the mounted image; the existing export is what materialises the savings on disk.

- **The single-instance guarantee uses a file handle, not a named mutex.** A `FileShare.None` handle has no DACL dependency, is released on process termination regardless of how the process terminated, and the file's presence on disk is not the lock — the open handle is.

- **The offline fallback trusts the state file rather than recomputing the DSI.** Recomputing the DSI from cached inputs would require the OEM pack version, which is resolved from the OEM map — a different gist, on the same unavailable network. The trade is: accept a small window where a hardware-changed machine takes the fast path with a stale DSI, in exchange for making an offline run useful on every healthy machine.

- **VMD hardware presence detection is fail-closed.** The alternative — treat an enumeration error as "no VMD hardware" — was the pre-patch-6 behavior. It is a wrong-question problem: the check was answering "did the enumeration return any matching devices?", but the downstream decision needed the answer to "does this machine have VMD hardware?"

- **The type code is the recovery partition's identity; the volume label is only a hint.** Before v44 patch 7, the classifier and the fast-path count accepted either the type code or the volume label as evidence that a partition was a recovery partition. That was a wrong-question problem: the destructive path's delete authorization had always required the type code, but the count and the classifier used the label OR the type code. Patch 7 unifies the question across all consumers.

- **The strip stage is a hard gate, and the fallback for a strip failure is deferral, not best-effort.** If the strip cannot prove zero third-party drivers remain, the candidate is discarded and the machine's existing recovery route is preserved. The alternative — inject on top of a partial strip, or accept enumeration failure as zero — would produce a WIM whose driver set is a function of the source image's history rather than the current recipe, which is the lineage problem the strip is designed to solve. The candidate is disposable; the recovery route is not.

- **Source selection prefers the registered image; the LKG is the regression guard, not the default.** The registered image is what Windows Update serviced most recently, so in the ordinary case it is the better source. The LKG is preferred only when it is provably newer by servicing metadata, or when the registered image cannot be read. This is the reverse of what a naive "always use the known-good copy" design would do, and it is the correct preference because the registered image is more current by construction; the LKG's role is to catch the case where the registered image has regressed.

- **The pre-`/disable` recheck is a race detector, and it is not called a lock.** Naming matters: a "lock" implies atomicity that the script does not have. The recheck detects a WU servicing event and defers; it does not prevent one. The residual microseconds between the recheck and `/disable` returning are accepted, because closing them would require moving the recheck inside the disable→enable window and lengthening that window, in violation of Rule 3.

## A note on the field failures

The v43 patch 5 change was driven by two field failures on the same day, both on Windows 11 build 26200 with Device Encryption mid-encryption:

- **Dell Latitude 3550** (Intel Core Ultra 5 125U) — `VolumeStatus=EncryptionInProgress` at 73.6% when the script ran.
- **HP ProBook 450 15.6 inch G10** (Intel Core i7-1355U) — same state, same failure sequence.

Both machines lost their dedicated recovery partition and had WinRE disabled. The recovery procedure is documented in [troubleshooting.md](troubleshooting.md).

After the further revision landed, two more Dell machines ran against a mid-encryption state:

- **Dell Pro Slim QCS1250** (Intel Core Ultra 5 235) — startup gate fired, machine unchanged, exit code 2.
- **Dell Vostro 16 5640** (Intel Core 7 150U) — same.

The further revision 5 change to target-volume-based preparation was driven by a different field observation, made on the same day:

- **Same-machine test on 2026-09-29** — with C: in the `FullyEncrypted`/no-protectors state, `reagentc /enable` against a dedicated recovery partition succeeded while `reagentc /enable` against the OS volume failed on the same machine in the same session. This is the observation that inverted the policy.

The further revision's Audit Mode guard was motivated by a separate field case:

- **Dell Latitude 5530** (12th Gen Intel i7-1265U, Windows 11 build 26200). Machine was in Audit Mode when the script first ran. The deployment completed successfully through Step 5, `reagentc /enable` failed with `0x4c7` on two consecutive runs, and the state file recorded the deployment as complete. After the user completed OOBE and ran `reagentc /enable` manually it succeeded on the first attempt with the same WIM.

The v44 patch 4 field observation:

- **Dell Latitude 3550, 2026-09-30 12:29–12:40.** Two `WinRE.ps1` processes ran simultaneously on the same machine, one exiting on `Cannot rename because item at 'C:\Temp\WinREWork\winre.wim' does not exist.`

The v44 patch 5 field observation:

- **ASUS desktop, 2026-09-30 13:22.** A healthy machine exited `FATAL ERROR: The remote name could not be resolved: 'gist.github.com'` on a transient DNS failure.

The v45 patch 1 field runs:

- **ASUS PRIME H510M-D, 2026-10-01 23:48–23:51.** The first run took the reuse path. Second run took the fast path; a further pair of fast-path runs followed on 2026-10-02 08:50.
- **Hyper-V VM, Windows 11 Pro 26300, GPT, 2026-10-02 08:56–08:58.** First end-to-end exercise of the v45 destructive path.
- **Hyper-V VM, Windows 10 Pro 19045, MBR, 2026-10-02 09:41–09:43.** First MBR machine and first Win10 field data.
- **Hyper-V VM, Windows 10 Pro 19045, MBR, 2026-10-02 09:47 — concurrent-instance test.** First field exercise of the v44 patch 4 program-lock contention path.

The v46 patch 1 fix was driven by the first v45 destructive-path *failure* on physical hardware, and verified by clean-path runs on two more machines:

- **Lenovo IdeaPad 3 15IAU7** (MT 82RK, Win 11 build 26200, GPT), 2026-10-02. Motivating failure. A factory-provided partition ended exactly 1 MiB past the disk-end reserve. Under v46 patch 1 the clamp makes the plan valid on the same layout; the second full-update run reached `DEDICATED`.
- **Dell Latitude 3540** (Win 11 build 26300, PM9B1 NVMe, GPT), 2026-10-02 14:48–14:53. Clean-path verification.
- **HP EliteBook 6 G1i 16"** (MT SBKP, Core Ultra 7 255U, Win 11 26300), 2026-10-02 14:57–15:01. Clean-path verification.

The v46 patch 2 changes were exercised on:

- **HP EliteBook 8 G1i 16"** (MT SBKP, Core Ultra 5 235U, Win 11 26300), 2026-10-02 15:22–15:26. Clean destructive rebuild; all three build-drift log lines fired on the full-update run and the two upstream lines fired on the fast-path run.

The v47 non-destructive paths were field-verified on:

- **ASUS PRIME H510M-D** (i5-11400, Win11 26300, GPT), 2026-10-03 02:21–02:24. First v47 run on physical hardware. Three-run sequence: full update triggered by the v46→v47 DSI mismatch; source selection chose the registered image (no hash-validated LKG present); the strip stage found zero third-party drivers and was a no-op; ResetBase ran; the export produced a 756.72 MiB WIM; `Find-SuitableRecoveryPartition` accepted the existing type-coded recovery partition and no partition work occurred; the pre-`/disable` race detector fired at the Step 5 site and confirmed the source was unchanged; `reagentc /disable` exit 0; WIM deployed with SHA256 verified; `reagentc /setreimage` exit 0; `reagentc /enable` exit 0; `DeployedWinREMetadata: 10.0.26100.9545|9545` recorded; `Operating mode: DEDICATED`. Two subsequent fast-path runs on the same machine confirmed the metadata-based drift detector: `Registered WinRE metadata: 10.0.26100.9545|9545; last deployed: 10.0.26100.9545|9545` — the anchor matched, `$registeredSourceChanged` stayed false, `$needInject` stayed false, no partition touched, no WIM mounted, no `reagentc` call. Runtime dominated by the driver-manifest fetch and Windows CIM/PnP enumeration, which together account for the ~13-second span between the `System:` and `VMD hardware present:` log lines. The v23 harness returned `Passed 16, failed 0, skipped 0 (of 16)` on the same machine.

**The v47 field gap.** The v47 non-destructive paths are field-verified on the ASUS run above. The following v47-specific code paths have not been exercised on any storage, physical or virtual: the strip stage with a non-zero third-party driver set, the strip-failure abort path, the source-selection LKG and GitHub cold-start branches, the pre-`/disable` race-detector abort path, the metadata-triggered rebuild branch, the WIM_READY checkpoint save/resume, and the destructive partition paths under v47 (the existing recovery partition was reusable on the ASUS run, so `Ensure-AdequateRecoveryPartition` was never called). These are covered by inspection, by the earlier real-machine F1/F2/F3 strip experiment that established the strip approach, and by the mocked-geometry test plan in [testing.md](testing.md).

The BitLocker failure is instructive because it was invisible to each function in isolation. `Test-BitLockerProtected` was correctly implementing the tri-state contract for the state it observed (`ProtectionStatus=Off`). `Suspend-BitLockerForWinRE` was correctly taking the "already off, no suspension needed" branch. `New-Partition` was correctly creating a partition. `Set-RecoveryPartitionAttributes` was correctly applying the recovery type GUID. Each function did exactly what it was written to do. The bug was in the composition: the two BitLocker functions queried a subset of the protection state that was insufficient evidence for the decision the downstream code made with the answer.

**The shared shape.** All of the documented failures have one property in common: each function or check was individually correct, and each was answering a question that was not the question the downstream code needed answered.

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
- The pre-v47 seed selection asked "which image is currently registered?" when the downstream injection needed the answer to "what is the clean baseline the current recipe should be applied to?".

The corrective pattern is the same in every case: move the check from the state that is easy to query to the state that actually matters, and record enough about the deployment's inputs that a divergence from the last known good state will be detected rather than assumed absent. That pattern is what the invariants in this document exist to enforce.

## Related documents

- [state-and-idempotency.md](state-and-idempotency.md) — details on the state file, checkpoint file, deferral marker, and how they interact, plus the offline fallback's residual risk and the planned `LocalInputsId` field.
- [recovery-partition.md](recovery-partition.md) — the partition lifecycle in depth.
- [driver-injection.md](driver-injection.md) — injection and the success gate.
- [exit-codes.md](exit-codes.md) — every exit path.
