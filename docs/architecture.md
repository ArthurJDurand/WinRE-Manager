# Architecture

WinRE Manager is a single-file production script plus a read-only harness and three map builders. This document explains the design.

## What problem it solves

Windows' recovery environment is fragile. The six common failure modes are:

1. **Partition too small.** A Windows Update replaces `winre.wim` with a newer, larger one; the recovery partition no longer has room for it plus the Microsoft-documented servicing margin.
2. **BitLocker auto-encryption.** On Windows 11 24H2+ with TPM 2.0 and Secure Boot, `Device Encryption` auto-encrypts newly created partitions, including recovery partitions. `reagentc /enable` then refuses with *"Windows RE cannot be enabled on a volume with BitLocker Drive Encryption enabled."*
3. **Device Encryption in progress, or in an ambiguous pre-activation state.** A volume can be actively encrypting (`VolumeStatus=EncryptionInProgress`) while `ProtectionStatus` reads `Off`. In that state the encryption service is running and will claim any new partition created on the disk, before the recovery type GUID can be applied. Separately, a volume can be `FullyEncrypted` with `ProtectionStatus=Off` — which is either a legitimate suspension (safe) or a Device Encryption volume in the *Waiting for Activation* state, where the recovery key has not yet been escrowed (unsafe). The two-field local view cannot tell those two apart. Both cases are the failure mode fixed in v43 patch 5; they defeated the earlier reactive BitLocker handling because `ProtectionStatus=Off` was treated as sufficient evidence that BitLocker was not a factor.
4. **Missing storage drivers.** OEM WinPE driver packs and Intel VMD storage drivers are required for the recovery image to see the storage controller. Without them, recovery cannot find the OS.
5. **Stale registration.** A disk migration, clone, or manual `reagentc` operation leaves the registration pointing at a partition that no longer exists. Windows might silently fall back to `C:\Recovery\WindowsRE` (OS-fallback) — a functional but degraded state.
6. **Audit Mode / OOBE / sysprep.** A freshly imaged machine that has not yet reached a normal desktop is in a transitional state where `reagentc /enable` is blocked with `ERROR_CANCELLED` (`0x4c7`, 1223) regardless of the correctness of the deployed WIM. The v43 patch 5 (further revision) startup guard detects this and defers — the script does not repair Audit Mode, it steps back from it. Without the guard, the deployment ran successfully, failed at `/enable`, wrote a state file recording the deployment as complete, and looped on every subsequent run.

WinRE Manager addresses all six idempotently. The two hard requirements are:

- **Correct end state**: a single dedicated recovery partition, on the OS disk, correctly typed, containing the right WIM, with `reagentc` registered to it.
- **Do not disturb a healthy machine.** Running the script on a machine already in the correct end state must be a no-op.

Everything below is designed around those two requirements.

## The pipeline

The production script runs one of four control-flow paths. Three of them are short-circuits; the full-update path is the long one.

Before any of those paths is chosen, two startup checks run, plus one normalisation step. The checks are read-only and each can terminate the run early; the normalisation step is not a gate and does not defer.

The **Audit Mode / OOBE / sysprep guard** runs first, immediately after the log directory is ensured and before the hardware check. It reads `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` → `ImageState` and defers with `EXIT_WARNING` when the value is present and is not `IMAGE_STATE_COMPLETE`. During Audit Mode, OOBE, sysprep generalize, and sysprep specialize, `reagentc /enable` is blocked by the OS regardless of what the script has done; running the destructive partition path in these states accomplishes nothing and leaves a state file that would loop on every subsequent run. The guard is deliberately conservative: any value other than `IMAGE_STATE_COMPLETE` defers, and absence of the key is treated as safe (some SKUs omit it). Under `-DryRun` the guard logs `Would defer …` and continues.

The **drive-letter cleanup** then runs: any volume labelled `Recovery` or `WINRE` whose partition is not the boot or system partition and whose root does not contain a `Windows` directory has its drive letter removed. This is a defensive normalisation — those letters should never be persistent — and it is a no-op on a healthy machine.

The **BitLocker gate** runs immediately after `Get-WinREState`, before the pending-reboot block and before any state-modifying action. If the OS volume is `ProtectionStatus=Off` with a `VolumeStatus` other than `FullyDecrypted` (including `FullyEncrypted`), or if `ProtectionStatus` is neither `On` nor `Off`, or if `Get-BitLockerVolume` returns null and the `Test-BitLockerProtected` fallback cannot confirm a safe state, the run defers with `EXIT_WARNING` before touching any partition or the WinRE registration. Under `-DryRun` the gate performs the same read-only classification and logs `Would defer WinRE Manager: …` without exiting, so a preflight of an unsafe machine reports the state a live run would defer on.

Together, the Audit Mode guard and the BitLocker gate mean that most mid-encryption, ambiguous-state, and pre-OOBE machines never reach any of the four control-flow paths.

### Fast path (idempotent)

Entered when: WinRE is enabled, the state file matches, the currently-registered recovery partition is on the OS disk, exactly one recovery partition exists on the OS disk, and the deployed WIM hash matches the stored hash.

Effect: `Remove-StrayRecoveryPartitions` enforces the "no recovery partition on non-OS disks" invariant, any stale `PendingReboot`/`RepairAttempts`/`EnableFailureAttempts` counters and a stale `LastEnableResult` are cleared by a single state-file rewrite, and the script exits. This is a read-only scan plus, if needed, one small state-file write on a healthy machine.

### Enable-only path

Entered when: WinRE is disabled but the current WIM is already correct (the state file matches and the WIM is present at the registered location).

Effect: `reagentc /setreimage` to re-point at the WIM, then `reagentc /enable`. Four possible outcomes:

- **`"ok"`** — enable succeeded, no reboot required. Exit `EXIT_SUCCESS` (or `EXIT_WARNING` if a non-fatal warning was set).
- **`"reboot"`** — enable succeeded but requires a reboot. Write the state file with `PendingReboot = true` and exit `EXIT_REBOOT_REQUIRED` (code 1).
- **`"failed"`** — generic hard failure. Increment the state file's `EnableFailureAttempts` counter, write `LastEnableResult = "failed"`, remove the checkpoint file, and exit `EXIT_WARNING` (code 2). **The enable-only path deliberately does not fall through to full update on this outcome.** The deployment is already current; a rebuild would not change the outcome of the enable step. The next run will retry enable-only. After three consecutive failures the loop-breaker fires (see below).
- **`"bitlocker"`** — the recovery partition is BitLocker-protected. Log explicitly, set `nonFatalWarning`, and fall through to full update for the suspend + delete + recreate recovery path.
- **`"blunsafe"`** — BitLocker on C: is not confirmed safe. Exit `EXIT_WARNING` immediately without touching the state file.

### Full-update path

Entered when: anything has changed — new Windows build, new driver manifest version, new OEM pack version, current WIM hash differs from stored, no state, or a classifier-detected problem such as a recovery partition on a secondary disk.

Effect: the eight-step pipeline. This is the long path. At the end of Step 6 the state file is written with a `LastEnableResult` and `EnableFailureAttempts` that reflect the run's `$enableResult`; on a `"failed"` outcome the counter is incremented, on any other outcome it resets to 0.

### Pending-reboot path

Entered at the top of the run when the state file says `PendingReboot = true` and the state file's `DesiredStateId` matches the current one.

Effect: re-run `reagentc /enable` against the WIM path recorded in the state file. If it succeeds, clear the flag and exit. If it fails, increment `RepairAttempts` and either retry (up to 3 attempts) or exit fatally. The pending-reboot path resets the enable-failure counter to 0 on every write, because it represents a different failure mode tracked by a separate counter. The two counters are independent.

### Loop-breaker

A separate check runs after the pending-reboot block and before the classifier. When the state file records `EnableFailureAttempts >= 3` **and** `LastEnableResult == "failed"` **and** WinRE is still `Disabled`, the script logs a "manual intervention required" message, removes the checkpoint file, and exits `EXIT_FATAL` (code 3). The state file is left in place; the log message names it and instructs the operator to delete it to reset the counter, once the underlying cause is resolved.

The condition is deliberately narrow. `"blunsafe"` and `"bitlocker"` are excluded — they are distinct failure modes with their own recovery paths, and neither represents a "retry enable against a working deployment" scenario. The counter exists specifically to break the generic `/enable` loop that would otherwise repeat indefinitely because the deployment is current and nothing changes between runs.

Under `-DryRun` the loop-breaker logs `Would refuse to retry …` and continues, matching the pattern used by the Audit Mode guard and the BitLocker gate.

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

2. If no candidate passes, `Ensure-AdequateRecoveryPartition` performs the destructive path: suspend BitLocker (refusing to proceed if the state cannot be confirmed safe — see the v43 patch 5 note below), disable WinRE, delete every recovery partition on the OS disk, extend the OS partition to its `SizeMax`, shrink it by `(bucketSizeMiB + 1) MiB`, create a new partition at the aligned offset with the recovery type GUID or type code already applied, format as NTFS with label `Recovery`, verify no auto-encryption occurred, and return.

   If the shrink fails after three attempts (immediate, after 10s sleep, after `defrag C: /x`), the OS partition size is restored via `Restore-OSPartitionSize`, the destructive attempt is abandoned, and the script falls through to OS-fallback — WinRE deployed to `C:\Recovery\WindowsRE` instead of a dedicated partition, with exit code 2.

**Step 6 — Deploy the WIM.**
Before disabling WinRE, `Suspend-BitLockerForWinRE` runs again as a second safety gate on the deployment path (v43 patch 5, revised). That call is normally a no-op because of the ownership guard: if the same run already suspended BitLocker, `$Script:BitLockerSuspended` is `$true` and the function returns `$true` immediately without re-querying. The gate is only meaningful on paths that did not go through the first suspend — primarily the OS-fallback route and the enable-only escalation. Then: copy the source WIM to the target directory. Verify SHA256. Set the file hidden + system. Call `reagentc /setreimage /path \\?\GLOBALROOT\device\harddiskX\partitionY\Recovery\WindowsRE`, then `reagentc /enable`. Write the state file with the deployed WIM hash **and** the enable outcome (`LastEnableResult`, `EnableFailureAttempts`). Clear the checkpoint.

**Step 7 — Enforce the single-recovery-partition invariant.**
`Remove-StrayRecoveryPartitions` deletes any type-coded recovery partition (GPT GUID `{de94bba4-...}` or MBR type `0x27`) on any non-OS disk. A partition on a non-OS disk that carries only a `Recovery` *label* but no type code is logged and skipped — label-only matches are not sufficient authority to delete on a secondary disk.

**Step 8 — Final verification.**
Re-read WinRE state. Classify the registered location: `DEDICATED` (recovery partition on OS disk), `OS-FALLBACK` (on the OS partition), or `UNEXPECTED` (neither). If dedicated, remove any temporary drive letter that the script assigned during the pipeline. If OS-fallback, warn that the run is degraded but functional.

## The four state-carrying artifacts

| Artifact | Path | Purpose | Lifetime |
|---|---|---|---|
| **State file** | `C:\Recovery\OEM\winre_state.json` | Records the deployed WIM hash, `DesiredStateId`, and the enable outcome (`LastEnableResult`, `EnableFailureAttempts`). | Persists across runs. |
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

`LastEnableResult` and `EnableFailureAttempts` are *not* part of the `DesiredStateId` — they are runtime counters that affect the control-flow decision, not the identity of the deployment. A machine with a non-zero counter is still "the current deployment" as far as the state-file comparison is concerned; the counter tracks the *enable* step's history, not the *deploy* step's identity.

## Control-flow invariants

These are the invariants the script maintains. Each one has a real field failure behind it; the `.NOTES` block in `scripts/WinRE.ps1` names them as "CRITICAL LESSONS LEARNED."

1. **Exactly one recovery partition exists, on the OS disk, correctly type-coded.** Enforced on the fast path, the enable-only path, both pending-reboot exits, and Step 7 of the full-update path. A type-coded recovery partition on any non-OS disk is deleted unconditionally. The invariant is absolute.

2. **No failure path leaves C: permanently shrunken.** Every post-shrink failure calls either `Remove-OrphanPartition` (which absorbs freed space back) or `Restore-OSPartitionSize`. Every failure of `Restore-OSPartitionSize` sets `$Script:GeometryRestoreFailed` so the state file is deleted and the next run retries from clean.

3. **The state-write gate is never relaxed.** `Write-WinREState` is only called when `$Script:ImageInjectionComplete` is `$true` and a WIM hash was computed. A failed injection never leaves a state file behind. The one exception is the pending-reboot path, which re-writes the existing state file with an updated `PendingReboot` flag but does not update the hash.

4. **BitLocker is never assumed Off, and never assumed safe on partial evidence.** All protection-state checks are tri-state (`$true` protected, `$false` unprotected, `$null` unknown). The confirmed-safe states when `ProtectionStatus=Off` are exactly two: `VolumeStatus=FullyDecrypted` (never encrypted, or decryption finished) and empty `VolumeStatus` (some builds report empty for volumes BitLocker has never touched). `FullyEncrypted` with `ProtectionStatus=Off` is **ambiguous**, not safe — it is the state every machine enters after a legitimate `Suspend-BitLocker` or a Windows Update suspension, but it is also indistinguishable from a Device Encryption volume in the *Waiting for Activation* state, where the recovery key has not yet been escrowed. The two-field local view cannot tell them apart, so the script refuses to proceed on that state. The four mid-operation states — `EncryptionInProgress`, `DecryptionInProgress`, `EncryptionPaused`, `DecryptionPaused` — are hazardous. `Test-BitLockerProtected` returns `$null` (unknown) for both the ambiguous state and the hazardous states, and `Suspend-BitLockerForWinRE` returns `$false` immediately without falling through to the generic `manage-bde` fallback. Any code path that would delete, resize, or format a partition refuses to proceed when the state is not confirmed-safe.

   **Ownership guard.** The ambiguous classification above would otherwise break the healthy path. After the script itself suspends BitLocker (`ProtectionStatus=On` → `Suspend-BitLocker` → `ProtectionStatus=Off, VolumeStatus=FullyEncrypted`), a later call to `Suspend-BitLockerForWinRE` in the same run sees the state the script just created. Without a guard, it classifies that state as ambiguous and refuses, which causes Step 5's pre-deploy gate to skip deployment on a machine the script is already committed to modifying — worse than the behaviour the ambiguous classification was introduced to replace. `Suspend-BitLockerForWinRE` short-circuits with `return $true` when `$Script:BitLockerSuspended` is set. That flag means "this run suspended BitLocker and owns the resume"; it is set immediately after a successful `Suspend-BitLocker` call, before the verification polling loop, and read by `Resume-BitLockerIfNeeded` in the `finally` block. The ambiguous-state classification therefore applies only to states observed at the start of the run, not to states the script itself produced.

   **Startup gate.** Most of the work of enforcing this invariant is done by a gate that runs before any control-flow path is chosen. Immediately after `Get-WinREState` and before the pending-reboot block, the script queries `Get-BitLockerVolume` on C:. If the cmdlet returns null, the gate falls back to `Test-BitLockerProtected` — which itself falls back to `manage-bde -status` text parsing — and treats an unknown result as a reason to defer. To avoid a false positive on machines where BitLocker is genuinely absent (Windows Home SKU, or the feature not installed), the gate checks for `manage-bde.exe` before treating a null return as unknown. When the cmdlet returns a value, the gate defers if the volume is `ProtectionStatus=Off` with a `VolumeStatus` other than `FullyDecrypted` (including `FullyEncrypted`), or if `ProtectionStatus` is neither `On` nor `Off`. On deferral the run logs the reason and exits with `EXIT_WARNING`; no partition is touched, no state file is written, `reagentc` state is unchanged, and the checkpoint file is left in place. Under `-DryRun` the gate performs the same read-only classification and logs "Would defer WinRE Manager: …" without exiting, so a preflight of an unsafe machine reports the state a live run would defer on. With the startup gate in place, mid-encryption and ambiguous-state machines never reach the destructive paths at all — the two mid-run guards in `Ensure-AdequateRecoveryPartition` and Step 5 become backstops for the narrow window where BitLocker's state transitions between the startup query and the destructive work.

   **Fail-closed on `reagentc /enable`.** `Invoke-ReagentcEnable` returns a distinct result string `"blunsafe"` when BitLocker on C: is not confirmed unprotected, instead of warning and continuing into `reagentc /enable`. All three callers — the enable-only path, the pending-reboot path, and the full-update post-deploy path — abort with `EXIT_WARNING`, remove the checkpoint file, and leave any state file untouched. Every path that would call `reagentc /enable` therefore requires the BitLocker state to be confirmed safe first, even after a successful `Suspend-BitLockerForWinRE` call elsewhere in the run.

   **Stronger `manage-bde` fallback.** When `Get-BitLockerVolume` is unavailable and the fallback parses `manage-bde -status` text, `Protection Off` alone is not sufficient evidence of safety. Only a confirmed `Conversion Status: Fully Decrypted` makes the fallback return confirmed-unprotected; anything else returns unknown. The fail-closed policy therefore holds even when the primary API is unavailable.

   The reason for all of this is subtle and was learned from field failure. On Windows 11 24H2+ with Device Encryption, a volume can be actively encrypting while `ProtectionStatus` reads `Off`, and in that state the encryption service claims any new partition before its recovery type GUID can be applied. The original v43 patch 5 implementation of `Suspend-BitLockerForWinRE` set an internal "unknown" sentinel in this branch and let the generic fallback run, which then read `Protection Off` from `manage-bde -status` and returned `$true` — reopening the exact fail-open path the patch was written to close. The branch now returns `$false` before the fallback can run. The guard is evaluated at three points in the pipeline — at the startup gate, in `Ensure-AdequateRecoveryPartition` before `reagentc /disable`, and in Step 5 before the deployment-path disable — and it is also evaluated under `-DryRun`. **When a mid-run gate refuses, the main flow exits with `EXIT_WARNING` immediately** — it logs a single deferral message, does not log a partition-creation failure, does not set `UsedOSFallback`, does not disable WinRE, and does not fall through to OS-fallback. With the startup gate in place, the mid-run gates are only reached on the narrow case where the machine's BitLocker state changes after startup.

5. **New recovery partitions are created with the recovery type code already applied.** `New-Partition` passes `-GptType {de94bba4-06d1-4d40-a16a-bfd50179d6ac}` (GPT) or `-MbrType 0x27` (MBR) at creation time (v43 patch 5). This closes the window between `New-Partition` and `Set-RecoveryPartitionAttributes` during which the partition is a plain Basic Data partition. `Set-RecoveryPartitionAttributes` still runs after format to apply the GPT attributes (`0x8000000000000001` — PLATFORM_REQUIRED + NO_DRIVE_LETTER); it is idempotent on the type code. The attribute step still runs before any drive letter is assigned.

6. **Self-referential file operations are guarded.** Any block that deletes a file and then writes to the same path (or copies another file onto it) checks first that the source and destination are not the same file (by `[System.IO.Path]::GetFullPath`). This guards against the v42 "fallback copy ate its own source" bug.

7. **Checkpoint advancement requires injection success.** A checkpoint that says "step 3 completed" is only written when image injection actually completed. This is v43 patch 4's fix.

8. **The Audit Mode / OOBE / sysprep guard runs before any state-modifying action.** The guard reads `ImageState` at startup and defers unless the value is absent or `IMAGE_STATE_COMPLETE`. This is the highest-priority guard in the script and runs before the BitLocker gate, the pending-reboot block, the classifier, and any partition work. It exists because on a machine that has not yet reached a normal desktop, `reagentc /enable` is blocked by the OS and the destructive partition work would be wasted while producing a state file that loops.

9. **A generic `reagentc /enable` failure on the enable-only path does not fall through to full update, and does not loop forever.** When the deployment is current and only the enable step fails with a generic `"failed"` outcome, the enable-only path increments the state-file counter and exits `EXIT_WARNING` without attempting a rebuild. After three consecutive failures the loop-breaker fires and exits `EXIT_FATAL`, requiring manual intervention. This invariant closes the loop that was introduced by the state-file-records-complete behaviour before v43 patch 5's further revision.

## Where the design choices bite

The five most consequential decisions in the whole script are:

- **Dedicated recovery partition is the primary objective; OS-fallback is the failure outcome.** The script will attempt the destructive repartitioning path even when the pre-check suggests the OS cannot shrink enough. If the attempt fails, the OS is restored and OS-fallback is used with exit code 2. This is a deliberate trade: try hard for the good outcome, fall back honestly when the attempt fails. The alternative — never try if the arithmetic is pessimistic — was tried in v37 and rejected because `SizeMin` is a hint, not a floor.

- **The `DesiredStateId`-scoped retry policy.** A machine in OS-fallback with a matching state file stays in OS-fallback indefinitely, without re-attempting the destructive path. A state change (script version bump, manifest update, hardware change, or a Windows build update changing the OS value) naturally re-arms the retry. This avoids re-shrinking the OS on every run of a machine that cannot shrink.

- **The BitLocker safety guard takes priority over the dedicated-partition objective.** When the machine is mid-Device-Encryption, or in the ambiguous `FullyEncrypted+Off` state that could be Waiting-for-Activation, the script refuses to run the destructive partition path even though the dedicated-partition path is the primary objective. This is a deliberate inversion of the primary-objective rule for a specific set of states: damaging the machine is worse than deferring the dedicated-partition work to the next run. The guard is evaluated at three points — at startup, before `reagentc /disable` in `Ensure-AdequateRecoveryPartition`, and before the deployment-path `reagentc /disable` in Step 5 — and it refuses on the hazardous `VolumeStatus` values and on the ambiguous `FullyEncrypted+Off` combination, leaving the machine's WinRE state and recovery partition intact. The main flow exits with `EXIT_WARNING`; no state file is written. The next run, once `VolumeStatus` is `FullyDecrypted` or the machine has completed activation, will attempt the dedicated partition. This is the correct trade: an extra pipeline run later is cheaper than an unusable machine now.

- **The Audit Mode guard takes priority over everything, including the BitLocker guard.** When `ImageState` is not `IMAGE_STATE_COMPLETE`, the script defers before it has fetched the manifest, resolved the OEM pack, computed the `DesiredStateId`, or read the state file. This is even more aggressive than the BitLocker guard, which runs after those steps. The reasoning is the same in spirit but stronger: a machine in Audit Mode is not a machine the script should be modifying at all, and the earlier the guard fires, the less work is wasted and the smaller the surface for accidental state change.

- **The enable-failure counter introduces a bounded retry for the generic enable failure.** Before v43 patch 5 (further revision), a generic `/enable` failure on the enable-only path fell through to full update and eventually exited `EXIT_FATAL` at the final-verification block, having rewritten the state file at the end of the pipeline as if the deployment had succeeded. The next run took the same path. That is a silent loop. The counter turns it into a bounded retry: three attempts, then a hard stop with an actionable message. The trade-off is that a genuinely transient enable failure now costs one extra pipeline run before it succeeds (the state-file rewrite), but it can no longer fail silently forever. This is the right trade for a fleet deployment where a silent loop is worse than a noisy failure.

## A note on the v43 patch 5 field failures

The v43 patch 5 change was driven by two field failures on the same day, both on Windows 11 build 26200 with Device Encryption mid-encryption:

- **Dell Latitude 3550** (Intel Core Ultra 5 125U) — `VolumeStatus=EncryptionInProgress` at 73.6% when the script ran.
- **HP ProBook 450 15.6 inch G10** (Intel Core i7-1355U) — same state, same failure sequence.

Both machines lost their dedicated recovery partition and had WinRE disabled. The recovery procedure is documented in [troubleshooting.md](troubleshooting.md).

After the further revision landed, two more Dell machines ran against a mid-encryption state:

- **Dell Pro Slim QCS1250** (Intel Core Ultra 5 235) — startup gate fired, machine unchanged, exit code 2.
- **Dell Vostro 16 5640** (Intel Core i7-150U) — same.

Those two runs confirmed the startup gate behaves as designed: no partition was touched, no state file was written, and the machine is left ready to complete the deployment on the next run after encryption stabilises.

The further revision's Audit Mode guard was motivated by a separate field case:

- **Dell Latitude 5530** (12th Gen Intel i7-1265U, Windows 11 build 26200). Machine was in Audit Mode when the script first ran. The deployment completed successfully through Step 5, `reagentc /enable` failed with `0x4c7` on two consecutive runs, and the state file recorded the deployment as complete. After the user completed OOBE and ran `reagentc /enable` manually it succeeded on the first attempt with the same WIM. This is the case that motivated the Audit Mode guard and the enable-failure counter.

The BitLocker failure is instructive because it was invisible to each function in isolation. `Test-BitLockerProtected` was correctly implementing the tri-state contract for the state it observed (`ProtectionStatus=Off`). `Suspend-BitLockerForWinRE` was correctly taking the "already off, no suspension needed" branch. `New-Partition` was correctly creating a partition. `Set-RecoveryPartitionAttributes` was correctly applying the recovery type GUID. Each function did exactly what it was written to do. The bug was in the composition: the two BitLocker functions queried a subset of the protection state that was insufficient evidence for the decision the downstream code made with the answer.

The same class of failure is what motivated the enable-failure counter: the state-write gate and the enable path were each correct in isolation, but the composition allowed a state file that said "complete" while the enable had failed, with no mechanism to break the resulting loop.

The further-revision ownership guard is the same class of problem in reverse: the ambiguous classification was correct in isolation, but would have broken the healthy path without a mechanism to distinguish "observed at startup" from "produced by this run." The guard is that mechanism.

## Related documents

- [state-and-idempotency.md](state-and-idempotency.md) — details on the state file, checkpoint file, and how they interact.
- [recovery-partition.md](recovery-partition.md) — the partition lifecycle in depth.
- [driver-injection.md](driver-injection.md) — injection and the success gate.
- [exit-codes.md](exit-codes.md) — every exit path.
