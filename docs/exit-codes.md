# Exit codes

WinRE Manager returns one of four exit codes. Orchestration should treat them as distinct outcomes, not as success/failure booleans.

## The four codes

| Code | Name | Meaning |
|---|---|---|
| `0` | `EXIT_SUCCESS` | WinRE enabled, dedicated recovery partition healthy, state file written or already current. |
| `1` | `EXIT_REBOOT_REQUIRED` | Deployment succeeded; a reboot is required to complete WinRE registration. |
| `2` | `EXIT_WARNING` | WinRE functional but degraded, or the run deferred work (BitLocker safety gate). Details in the log. |
| `3` | `EXIT_FATAL` | Deployment aborted. No state written or state file deleted. Investigate the log. |

## Priority

When a run's outcome satisfies more than one condition, the priority order is:

```
EXIT_FATAL  >  EXIT_REBOOT_REQUIRED  >  EXIT_WARNING  >  EXIT_SUCCESS
```

`EXIT_FATAL` always wins. Between `EXIT_REBOOT_REQUIRED` and `EXIT_WARNING`, reboot-required wins — the machine needs to reboot either way.

In practice only two combinations are reachable:

- **Reboot-required + warning.** A reboot is needed and a cleanup step failed. Returns `1`.
- **Warning + success.** A non-fatal warning was raised (BitLocker resume failed, fallback copy denied, BitLocker safety deferral) but the run did not fully fail. Returns `2`.

## When each code is returned

### `EXIT_SUCCESS` (0)

The fast path found nothing to do and exited cleanly. Or the full-update path completed, WinRE reports `Enabled`, the state file was written, and no warning flags were set.

Also returned by `-DryRun` when the dry run completes without errors. Dry runs do not write a state file; they exit `0` from the deployment step.

### `EXIT_REBOOT_REQUIRED` (1)

`reagentc /enable` returned exit 0 but `reagentc /info` did not immediately report `Enabled`. This is a common result after a fresh registration: Windows schedules the registration to complete on the next reboot.

The script writes the state file with `PendingReboot = true`, records the deployed partition number and disk number so the next run knows where the WIM is, and exits with code 1.

Also returned by the pending-reboot path when the retry `reagentc /enable` still returns reboot-required, and by the enable-only path when `reagentc /enable` returns reboot-required.

### `EXIT_WARNING` (2)

Reached when any of the following is true at exit time:

- **OS-fallback.** The dedicated recovery partition could not be created and WinRE is deployed to `C:\Recovery\WindowsRE`.

- **BitLocker safety deferral (v43 patch 5, further revision).** The BitLocker state on C: could not be confirmed safe and the script refused to proceed before any state-modifying work. The machine is left unchanged: no partition is touched, no WIM is deployed, WinRE is not disabled, no state file is written. Three gate sites, all fail-closed:

  1. **Startup gate (primary).** Runs immediately after `Get-WinREState` and before the pending-reboot block or any state-modifying action. Fires when the OS volume is `ProtectionStatus=Off` with a `VolumeStatus` other than `FullyDecrypted`, or when `ProtectionStatus` is neither `On` nor `Off`. Logs the reason and a "wait until … then re-run" line, removes the checkpoint file, and exits with `EXIT_WARNING`. This is the primary defence: most mid-encryption and ambiguous-state machines never reach the destructive paths at all.
  2. **Mid-run gate in `Ensure-AdequateRecoveryPartition` (backstop).** Fires inside `Suspend-BitLockerForWinRE` for the narrow window where the machine's BitLocker state changes between the startup query and the destructive work. The guard's refusal is recorded via `$Script:BitLockerGuardDeferred = $true`, and the main flow logs a single deferral line and exits with `EXIT_WARNING`.
  3. **Mid-run gate in Step 5 (backstop).** Same function, deployment path. Fires on the routes that do not go through `Ensure-AdequateRecoveryPartition` directly — the OS-fallback route and the enable-only escalation. Exits the same way.

  Two categories of state trigger these gates:

  - **Hazardous.** The OS volume is `ProtectionStatus=Off` with `VolumeStatus` one of `EncryptionInProgress`, `DecryptionInProgress`, `EncryptionPaused`, `DecryptionPaused`. Device Encryption is actively encrypting or decrypting the volume. Servicing WinRE in this state allows the encryption service to claim the new partition before its recovery type GUID can be applied.
  - **Ambiguous.** The OS volume is `ProtectionStatus=Off` with `VolumeStatus=FullyEncrypted`. This is the standard suspended-BitLocker state after a legitimate `Suspend-BitLocker` or a Windows Update suspension that has not yet been lifted, but it is also indistinguishable from a Device Encryption volume in the *Waiting for Activation* state where the recovery key has not yet been escrowed. The two-field local view cannot tell them apart, so the script defers both.

  A fourth fail-closed path is the `blunsafe` result from `Invoke-ReagentcEnable`. When BitLocker on C: is not confirmed unprotected at the point just before `reagentc /enable`, the function returns a distinct result `"blunsafe"` instead of calling through. All three call sites — the enable-only path, the pending-reboot path, and the full-update post-deploy path — abort with `EXIT_WARNING`, remove the checkpoint file, and leave any state file untouched. This is reached only if the startup gate and both mid-run gates have already passed but BitLocker's state changed again before `reagentc /enable` was invoked — a very narrow window. See [troubleshooting.md](troubleshooting.md) for the recovery procedure and [deployment.md](deployment.md) for the precondition.

- **`$Script:nonFatalWarning = $true`.** Set by: BitLocker suspension failure, BitLocker resume failure, cleanup failure in `Remove-StrayRecoveryPartitions`, fallback copy denial (ACL), recovery-attribute application failure, and OEM map resolution failure for a supported vendor.

- **`$Script:UsedOSFallback = $true`.** Distinct from `nonFatalWarning`; can be true without any warning-level event, and is the deliberate outcome of the shrink-fails path.

The warning code is returned on the fast path, the enable-only path, the pending-reboot success path, and the full-update path — anywhere a warning flag can be set. In every case the state file is still written (or left in place) if the run reached a state-write point. The BitLocker safety deferral is the one exception: the run exits before the state-write point, so any existing state file is left unchanged and no new state is committed.

**Important for orchestration:** exit code 2 has three distinct meanings and they require different actions. The state file's `LastUpdated` timestamp and the specific log content distinguish them.

| Case | State file `LastUpdated` | Log signature | Action |
|---|---|---|---|
| **OS-fallback** | Newer than the run start (state file was written this run, with `UsedOSFallback = true`) | `Dedicated recovery partition creation failed after all attempts.` banner | The machine ended in OS-fallback; do not reboot or intervene. Router to a soft-failure queue if your deployment policy requires dedicated partitions. |
| **Hazardous deferral** | Unchanged, or state file absent | Startup gate message: `Deferring WinRE Manager: BitLocker on C: ProtectionStatus=Off with VolumeStatus=EncryptionInProgress …` (or one of the other three hazardous `VolumeStatus` values), **or** mid-run guard message: `ProtectionStatus=Off but VolumeStatus=EncryptionInProgress - the volume is encrypted or actively encrypting …` followed by the single deferral line | The machine was mid-encryption; no partition work was attempted. Wait for `manage-bde -status C:` to show `Protection On` or `Protection Off + Fully Decrypted` before retrying. |
| **Ambiguous deferral** | Unchanged, or state file absent | Startup gate message: `Deferring WinRE Manager: BitLocker on C: ProtectionStatus=Off with VolumeStatus=FullyEncrypted - ambiguous …`, **or** mid-run guard message: `ProtectionStatus=Off with VolumeStatus=FullyEncrypted - this state is ambiguous …` followed by the single deferral line | The machine is in a suspended-BitLocker or Waiting-for-Activation state. Wait for the state to resolve to either `Protection On` (activation completed) or `Fully Decrypted` before retrying. |

The distinguishing factor between OS-fallback and the two deferrals is the state file timestamp: OS-fallback reaches the state-write step and updates `LastUpdated`; both deferrals exit before it and leave the timestamp unchanged. The distinguishing factor between hazardous and ambiguous deferral is the `VolumeStatus` value named in the guard message. Both deferrals are safe outcomes — the machine is unchanged.

A partition-creation failure — with its `Dedicated recovery partition creation failed after all attempts.` banner — is only logged when the destructive attempt actually ran and failed. A deferral is not that.

### `EXIT_FATAL` (3)

Reached when any of the following occurs:

- **Base WIM could not be obtained.** GitHub download failed, or the existing WIM at the reagentc-registered location is unusable and no fallback exists.
- **`dism /Export-Image` failed.** Non-zero exit from DISM or missing output file.
- **`reagentc /disable` failed at Step 5.** WinRE is enabled and the script could not disable it, so the deployment cannot proceed.
- **`reagentc /setreimage` failed at Step 6.** Registration failed; the WIM was copied but the registry is inconsistent.
- **WIM deployment failed.** The copy or hash verification failed.
- **WinRE location cannot be resolved to a partition after enable.** The registration is inconsistent; the script would need manual intervention.
- **WinRE reports `Enabled` but the location is empty.** Same class.
- **WinRE is on an unexpected partition.** Not the OS disk's recovery partition, not the OS partition. This is a state the script cannot reconcile.
- **`FATAL: WinRE is not enabled at exit`.** The final attempt to enable WinRE failed. On a machine where the recovery partition was lost, this is the pre-v43-patch-5 Device Encryption failure mode. See [troubleshooting.md](troubleshooting.md) for the recovery procedure.
- **RepairAttempts > 3.** The pending-reboot path has been retried 4 times without resolving. Manual intervention is required.
- **An unhandled exception was thrown.** The top-level `catch` block logs and exits 3.

Fatal exits do not write a state file. If a state file was written earlier in the run and the fatal exit occurs after that point, the state file is left as-is; on the next run, the fast path may fire if the state is now healthy, or the full-update path may re-run if it is not.

**Special case for orchestration:** exit code 3 with the log line `FATAL: WinRE is not enabled at exit` on a machine that no longer has a recovery partition indicates the pre-patch-5 failure mode. Do not retry automatically. Follow the recovery procedure in [troubleshooting.md](troubleshooting.md).

## What the codes do not tell you

- **Which recovery partition was used.** The log records the disk and partition number.
- **Whether the run was a fast path or a full update.** The log records the control-flow path.
- **Whether BitLocker was suspended and successfully resumed.** The log records both.
- **Which BitLocker gate fired, and whether the deferred state was hazardous or ambiguous.** The three gate sites log distinct messages. The startup gate logs `Deferring WinRE Manager: BitLocker on C: …` with the `VolumeStatus` value and reason. The mid-run gate in `Ensure-AdequateRecoveryPartition` logs the guard message from `Suspend-BitLockerForWinRE` (`ProtectionStatus=Off but VolumeStatus=… Refusing to treat as unprotected` for hazardous, or `ProtectionStatus=Off with VolumeStatus=FullyEncrypted - this state is ambiguous …` for ambiguous) followed by the single deferral line. The Step 5 gate logs its own refusal. The `blunsafe` result from `Invoke-ReagentcEnable` logs `BitLocker state on C: is not confirmed unprotected (state=…) - refusing to call reagentc /enable`. The state file's `LastUpdated` timestamp distinguishes deferral (unchanged, or absent) from OS-fallback (newer than the run start).
- **How long the run took.** The log lines have timestamps; the first and last line bound the duration.

For any of those details, read the log. See [troubleshooting.md](troubleshooting.md).

## Exit codes on the pending-reboot path

The pending-reboot path has its own exit logic. In order:

1. If the retry `reagentc /enable` succeeded and WinRE reports `Enabled`:
   - If `UsedOSFallback` was carried over from the state file → `EXIT_WARNING`.
   - Else if `nonFatalWarning` was set → `EXIT_WARNING`.
   - Else → `EXIT_SUCCESS`.
2. If the retry still reports reboot-required → `EXIT_REBOOT_REQUIRED`.
3. If `RepairAttempts > 3` → `EXIT_FATAL`.

The `blunsafe` result from `Invoke-ReagentcEnable` short-circuits this logic: the pending-reboot path exits with `EXIT_WARNING` immediately on `blunsafe`, before any `EXIT_REBOOT_REQUIRED` or `EXIT_FATAL` determination.

Note that `PendingReboot` and `RepairAttempts` are recorded in the state file before the exit, so a machine that exits with code 3 due to too many repair attempts still has a state file reflecting the current repair count.

## Exit codes and orchestration

Recommended orchestration policy:

| Code | Action |
|---|---|
| 0 | Record success. No further action. |
| 1 | Schedule a reboot at the next maintenance window. The next run will finish the registration. |
| 2 | Investigate the log. Check the state file's `LastUpdated` timestamp. Three cases: **(a)** If the log shows the `Dedicated recovery partition creation failed after all attempts.` banner and the state file was updated this run, the machine ended up in OS-fallback. Do not reboot or intervene while encryption is in progress. **(b)** If the log shows the hazardous-guard message (`ProtectionStatus=Off but VolumeStatus=EncryptionInProgress`, or `DecryptionInProgress`, `EncryptionPaused`, `DecryptionPaused`) and the state file was not updated, the script deferred the work on a mid-encryption machine. Defer the retry to the next scheduled run once `manage-bde -status C:` reads `Protection On` (any conversion status) or `Protection Off + Fully Decrypted`. **(c)** If the log shows the ambiguous-guard message (`ProtectionStatus=Off with VolumeStatus=FullyEncrypted - this state is ambiguous`), the machine is in a suspended or Waiting-for-Activation state. Defer the retry until the state resolves to `Protection On` (activation completed) or `Fully Decrypted`. Both deferral cases leave the machine unchanged. |
| 3 | Do not retry automatically. Investigate the log immediately. If the log shows `FATAL: WinRE is not enabled at exit` on a machine that no longer has a recovery partition, follow the [troubleshooting.md](troubleshooting.md) recovery procedure before retrying. |

Do **not** use exit code 0 as the sole health signal. A machine that reached OS-fallback exits with 2, which is a legitimate "the machine is functional but the design goal was not achieved" signal. If your deployment policy requires dedicated recovery partitions, treat 2 as a soft failure and route it to a queue.

Do **not** configure retry loops that ignore the exit code and re-run unconditionally. Neither the hazardous state nor the ambiguous state is made better by retrying — the same guard will fire on the next run. Wait until `manage-bde -status C:` reads `Protection On` (any conversion status) or `Protection Off + Fully Decrypted`, then re-run. The ambiguous `Fully Encrypted + Protection Off` state will resolve on its own once Device Encryption completes activation and the recovery key is escrowed; the hazardous mid-operation states will resolve when the encryption or decryption operation finishes.

## Related documents

- [architecture.md](architecture.md) — the pipeline and the four control-flow paths.
- [troubleshooting.md](troubleshooting.md) — how to investigate each code, plus the recovery procedure for the pre-patch-5 failure mode.
- [deployment.md](deployment.md) — the BitLocker precondition and exit-code handling for orchestration.
