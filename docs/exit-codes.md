# Exit codes

WinRE Manager returns one of four exit codes. Orchestration should treat them as distinct outcomes, not as success/failure booleans.

## The four codes

| Code | Name | Meaning |
|---|---|---|
| `0` | `EXIT_SUCCESS` | WinRE enabled, dedicated recovery partition healthy, state file written or already current. |
| `1` | `EXIT_REBOOT_REQUIRED` | Deployment succeeded; a reboot is required to complete WinRE registration. |
| `2` | `EXIT_WARNING` | WinRE functional but degraded, or the run deferred work, or a non-fatal failure is queued for retry. Details in the log. |
| `3` | `EXIT_FATAL` | Deployment aborted. No state written, or state file deleted. Investigate the log. |

## Priority

When a run's outcome satisfies more than one condition, the priority order is:

```
EXIT_FATAL  >  EXIT_REBOOT_REQUIRED  >  EXIT_WARNING  >  EXIT_SUCCESS
```

`EXIT_FATAL` always wins. Between `EXIT_REBOOT_REQUIRED` and `EXIT_WARNING`, reboot-required wins — the machine needs to reboot either way.

In practice only two combinations are reachable through the final exit-code determination:

- **Reboot-required + warning.** A reboot is needed and a warning flag was set. Returns `1`.
- **Warning + success.** A run completed successfully but a non-fatal warning flag was set (fallback copy denied, recovery-attribute application failed, cleanup incomplete). Returns `2`.

Some exit paths bypass the final determination and exit `EXIT_WARNING` or `EXIT_FATAL` directly — the Step 3 → Step 4 pipeline gate, the Audit Mode deferral, the OS-fallback BitLocker deferral, the enable-only target-preparation failure, the enable-failure counter exit, and the loop-breaker. Those cases are described in the sections below.

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

- **Step 3 → Step 4 pipeline gate (v44 patch 1).** OEM or VMD injection failed (`$Script:ImageInjectionComplete = $false`). The script exits with `EXIT_WARNING` immediately after Step 3, before Step 4 (`dism /Export-Image`), before Step 5 (partition work), before Step 6 (deployment), and before any `reagentc` call. The pipeline sets the checkpoint back to 2 so the next run re-acquires the base WIM from source and re-runs injection against a clean WIM. The state-write gate alone would not have prevented the deployment of a WIM with no OEM or VMD drivers; the pipeline gate closes that gap. On a VMD-based system the resulting WinRE cannot see the OS disk at all, so this exit is a protective failure, not a degraded-success. The `winre_optimized.wim` from the run is removed by the gate before exiting.

- **Audit Mode / OOBE / sysprep deferral (v43 patch 5, further revision).** The startup guard reads `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` → `ImageState` before any other action. When the value is present and is not `IMAGE_STATE_COMPLETE`, Windows is in a transitional state (Audit Mode, OOBE, sysprep generalize, or sysprep specialize) where `reagentc /enable` is blocked with `ERROR_CANCELLED` (`0x4c7`, 1223) regardless of WIM correctness or the state of the recovery partition. The run logs a clear message naming the `ImageState` value and defers before the hardware check, the manifest fetch, the OEM pack resolution, the `DesiredStateId` computation, or any state-modifying action. The machine is left unchanged: no partition touched, no WIM deployed, WinRE not disabled, no state file written, checkpoint file preserved. Under `-DryRun` the gate performs the same read-only classification and logs `Would defer …` without exiting. This is the highest-priority deferral — it runs before every other gate.

- **OS-fallback BitLocker deferral (v43 patch 5, further revision 5).** On the OS-fallback route — reached when dedicated-partition creation fails and the script falls back to `C:\Recovery\WindowsRE` — the target volume *is* the OS volume. reagentc refuses to enable WinRE on an encrypted OS volume, always. The OS-fallback gate checks C:'s `VolumeStatus` before deploying the WIM and defers with `EXIT_WARNING` unless it is `FullyDecrypted`. The script **never** modifies C:'s BitLocker state — decrypting the OS volume is hours of I/O, changes the recovery key relationship, and the OS volume is the user's data. The machine is left unchanged: no WIM deployed, no `reagentc` call made, no state file written, checkpoint file preserved. The log message names the C: state and the operator resolutions: sign in with a Microsoft account to complete Device Encryption activation, add a key protector manually (`Add-BitLockerKeyProtector -MountPoint C: -RecoveryPasswordProtector`) and enable protection, or wait for decryption to finish. Under `-DryRun` the gate logs the deferral and continues. Note that this gate is only reached on the OS-fallback route; the enable-only and dedicated-partition routes never depend on C:'s BitLocker state, because their target volume is the recovery partition.

- **Enable-only target-preparation failure (v43 patch 5, further revision 5).** The enable-only path prepares the target recovery partition via `Set-RecoveryPartitionReadyForWinRE` before calling `reagentc /setreimage`. If the helper reports that the target could not be made unencrypted within its 300-second timeout, the enable-only path records the failure, increments the state file's `EnableFailureAttempts` counter, writes `LastEnableResult = "failed"`, removes the checkpoint file, and exits `EXIT_WARNING`. The deployment is already current; the next run will retry enable-only. After three consecutive failures the loop-breaker fires and the next exit is `EXIT_FATAL` (see below).

- **Enable-failure counter (v43 patch 5, further revision).** The enable-only path called `reagentc /enable` on a deployment that was already current. The call returned a terminal failure — either a generic `"failed"` result or a `"bitlocker"` result (reagentc refused because the target volume is BitLocker-protected, even after the helper prepared it). The enable-only path increments the state file's `EnableFailureAttempts` counter, writes `LastEnableResult` to the corresponding value, removes the checkpoint file, and exits with `EXIT_WARNING`. It does **not** fall through to full update: the deployment is current, and rebuilding it would not change the outcome of the enable step. The next run will retry the enable-only path (not the full-update path). After three consecutive terminal failures the loop-breaker fires and the next exit is `EXIT_FATAL` (see below). Both `"failed"` and `"bitlocker"` count toward the same three-failure threshold; they are not distinguished by the counter.

- **`$Script:nonFatalWarning = $true`.** Set by a range of non-fatal conditions the run encountered: `Restore-OSPartitionSize` failure on any post-shrink geometry-restore path, `Remove-OrphanPartition` orphan survival, `Remove-StrayRecoveryPartitions` cleanup failure, `Set-RecoveryPartitionAttributes` failure at the end of Step 6, the full-update post-enable `"failed"` and `"bitlocker"` outcomes, OEM map resolution failure for a supported vendor, `Set-RecoveryPartitionReadyForWinRE` failure on any deferring path, and the OS-fallback BitLocker gate. Fallback copy denial (ACL) is logged but does **not** set the flag — it is genuinely non-fatal and the run continues to completion with the exit code determined by the other flags.

- **`$Script:UsedOSFallback = $true`.** Distinct from `nonFatalWarning`; can be true without any warning-level event, and is the deliberate outcome of the shrink-fails path.

The warning code is returned on the fast path, the enable-only path, the pending-reboot success path, and the full-update path — anywhere a warning flag can be set. In every case the state file is still written (or left in place) if the run reached a state-write point. The Step 3 → Step 4 pipeline gate, the Audit Mode deferral, and the OS-fallback BitLocker deferral all exit before the state-write point, so any existing state file is left unchanged and no new state is committed. The enable-only failure and the enable-failure counter exit **do** reach a state-write point and update the state file.

**Important for orchestration:** exit code 2 has five distinct meanings and they require different actions. The state file's `LastUpdated` timestamp, the presence of the `UsedOSFallback` flag, and the specific log content distinguish them.

| Case | State file `LastUpdated` | Log signature | Action |
|---|---|---|---|
| **OS-fallback** | Newer than the run start (state file written this run, with `UsedOSFallback = true`) | `Dedicated recovery partition creation failed after all attempts.` banner | The machine ended in OS-fallback. Do not reboot or intervene. Route to a soft-failure queue if your deployment policy requires dedicated partitions. |
| **Step 3 → Step 4 pipeline gate** | Unchanged, or state file absent | `Image injection did not complete. Stopping before Step 4 and before any deployment.` | The OEM or VMD injection failed. The WIM was not deployed, the partition was not touched, and WinRE was not disabled. The checkpoint was set back to 2. The next run will retry from step 2. Investigate the injection failure reason (OEM pack download, extraction, INF validation, or VMD driver download). |
| **Audit Mode deferral** | Unchanged, or state file absent | `Deferring WinRE Manager: Windows is not in a normal-running state (Setup\State\ImageState=…)` | The machine has not finished OOBE, or is in Audit Mode or a sysprep phase. No partition work was attempted. Complete OOBE, sign in to a normal desktop session, and re-run. Do not retry immediately. |
| **OS-fallback BitLocker deferral** | Unchanged, or state file absent | `OS-fallback deferred: C: VolumeStatus=…` followed by the operator guidance line | The dedicated partition could not be created and the OS-fallback target (C:) is encrypted. No WIM was deployed, no `reagentc` call was made. Wait for C: to reach `FullyDecrypted`, or complete Device Encryption activation, then re-run. |
| **Enable-only failure (counter < 3)** | Newer than the run start (state file written this run, with `LastEnableResult` set to `"failed"` or `"bitlocker"` and the counter incremented) | `Enable-only /enable failed (attempt N of 3).` or `Enable-only /enable refused with the BitLocker error after the target partition was confirmed unencrypted (attempt N of 3).` | The deployment is current; only the enable step failed. Do not rebuild. Investigate the enable failure itself (ReAgent.xml corruption, missing registration, a Windows component problem, an antivirus product holding the recovery partition open). The next run will retry enable-only. After three consecutive failures the loop-breaker fires and the next run exits with code 3. |

The distinguishing factor between OS-fallback and the three deferrals/gates is the state file timestamp: OS-fallback reaches the state-write step and updates `LastUpdated`; the Step 3 → Step 4 pipeline gate, the Audit Mode deferral, and the OS-fallback BitLocker deferral all exit before it and leave the timestamp unchanged. The enable-only failure also updates the state file, but its log signature is unique and cannot be confused with OS-fallback.

A partition-creation failure — with its `Dedicated recovery partition creation failed after all attempts.` banner — is only logged when the destructive attempt actually ran and failed. A deferral or a pipeline gate is not that.

### `EXIT_FATAL` (3)

Reached when any of the following occurs:

- **Base WIM could not be obtained.** GitHub download failed, or the existing WIM at the reagentc-registered location is unusable and no fallback exists.
- **`dism /Export-Image` failed.** Non-zero exit from DISM or missing output file.
- **`reagentc /disable` failed at Step 5.** WinRE is enabled and the script could not disable it, so the deployment cannot proceed.
- **`reagentc /setreimage` failed at Step 6.** Registration failed; the WIM was copied but the registry is inconsistent.
- **WIM deployment failed.** The copy or hash verification failed.
- **Target partition could not be made unencrypted on the full-update path.** `Set-RecoveryPartitionReadyForWinRE` returned `$false` before the WIM was deployed. Under the v43 patch 5 (further revision 5) policy this is a fatal exit rather than a deferral on the full-update path, because the WIM has already been placed and the recovery partition has already been created; leaving the state mid-flight would produce an inconsistent machine on the next run.
- **WinRE location cannot be resolved to a partition after enable.** The registration is inconsistent; the script would need manual intervention.
- **WinRE reports `Enabled` but the location is empty.** Same class.
- **WinRE is on an unexpected partition.** Not the OS disk's recovery partition, not the OS partition. This is a state the script cannot reconcile.
- **`FATAL: WinRE is not enabled at exit`.** The final attempt to enable WinRE failed. On a machine where the recovery partition was lost, this is the pre-v43-patch-5 Device Encryption failure mode. See [troubleshooting.md](troubleshooting.md) for the recovery procedure.
- **`RepairAttempts > 3`.** The pending-reboot path has been retried 4 times without resolving. Manual intervention is required.
- **Enable-failure loop-breaker (v43 patch 5, further revision 5).** The state file records `EnableFailureAttempts >= 3` with `LastEnableResult` set to `"failed"` or `"bitlocker"`, and WinRE is still `Disabled`. The loop-breaker logs `Refusing to retry reagentc /enable: it has failed on the last N consecutive runs and WinRE is still Disabled. Manual intervention is required.`, names the state file path, and exits `EXIT_FATAL` without attempting anything else. The state file is left in place so the operator can inspect it. The cause may be Audit Mode (though the Audit Mode startup guard would have deferred earlier), a broken ReAgent registration, a Windows component problem, a filesystem problem on the target partition, or an antivirus product holding the recovery partition open. Resolve the underlying cause, then delete `C:\Recovery\OEM\winre_state.json` to reset the counter and re-run. See the "Enable-only failure (counter < 3)" row above for the pre-loop state.
- **An unhandled exception was thrown.** The top-level `catch` block logs and exits 3.

Fatal exits do not write a state file. If a state file was written earlier in the run and the fatal exit occurs after that point, the state file is left as-is; on the next run, the fast path may fire if the state is now healthy, or the full-update path may re-run if it is not.

**Special case for orchestration:** exit code 3 with the log line `FATAL: WinRE is not enabled at exit` on a machine that no longer has a recovery partition indicates the pre-patch-5 failure mode. Do not retry automatically. Follow the recovery procedure in [troubleshooting.md](troubleshooting.md).

**Second special case:** exit code 3 with the log line `Refusing to retry reagentc /enable` indicates the enable-failure loop-breaker. Do not retry automatically — the same guard will fire on the next run because the state file still records the counter value. Resolve the underlying cause, delete the state file, and re-run. See [troubleshooting.md](troubleshooting.md) for the diagnosis procedure.

## What the codes do not tell you

- **Which recovery partition was used.** The log records the disk and partition number.
- **Whether the run was a fast path or a full update.** The log records the control-flow path.
- **Which deferral gate fired.** The Audit Mode gate logs `Deferring WinRE Manager: Windows is not in a normal-running state (Setup\State\ImageState=…)`. The OS-fallback BitLocker gate logs `OS-fallback deferred: C: VolumeStatus=…` followed by the operator guidance line. The two are distinguishable by the log text alone. The state file's `LastUpdated` timestamp distinguishes both deferrals (unchanged, or absent) from OS-fallback and enable-only failure (both newer than the run start).
- **Whether the target recovery partition needed to be decrypted, and how long it took.** The log records `Target partition X/Y (Z:) is BitLocker-managed (state=…) - running manage-bde -off to decrypt` and a confirmation line with the elapsed time when the decryption completes. If `Set-RecoveryPartitionReadyForWinRE` returned without decrypting, the log records `Target partition X/Y (Z:) is already unencrypted - reagentc /enable can proceed`.
- **How many consecutive enable failures the enable-only path has accumulated.** Read `EnableFailureAttempts` from the state file, or look for the `Enable-only /enable failed (attempt N of 3)` or `Enable-only /enable refused with the BitLocker error after the target partition was confirmed unencrypted (attempt N of 3)` log line.
- **How long the run took.** The log lines have timestamps; the first and last line bound the duration.

For any of those details, read the log. See [troubleshooting.md](troubleshooting.md).

## Exit codes on the pending-reboot path

The pending-reboot path has its own exit logic. In order:

1. Resolve the deployed target from the state file (`DeployedDiskNumber` / `DeployedPartitionNumber`, or `C:\Recovery\WindowsRE` for OS-fallback).
2. Prepare the target:
   - **Dedicated partition:** call `Set-RecoveryPartitionReadyForWinRE` on the recorded partition. If it returns `$false` — the target could not be made unencrypted within the timeout — defer with `EXIT_WARNING` immediately.
   - **OS-fallback:** check C:'s `VolumeStatus`. If it is not `FullyDecrypted`, defer with `EXIT_WARNING` immediately.
3. Re-run `reagentc /enable` against the recorded path. If the retry succeeded and WinRE reports `Enabled`:
   - If `UsedOSFallback` was carried over from the state file → `EXIT_WARNING`.
   - Else if `nonFatalWarning` was set → `EXIT_WARNING`.
   - Else → `EXIT_SUCCESS`.
4. If the retry still reports reboot-required → `EXIT_REBOOT_REQUIRED`.
5. If `RepairAttempts > 3` → `EXIT_FATAL`.

Note that `PendingReboot` and `RepairAttempts` are recorded in the state file before the exit, so a machine that exits with code 3 due to too many repair attempts still has a state file reflecting the current repair count.

The pending-reboot path writes the state file with `LastEnableResult = "ok"` and `EnableFailureAttempts = 0`. A machine that reaches the pending-reboot path therefore has its enable-failure counter reset regardless of the outcome — the pending-reboot path represents a different failure mode (registration did not complete after a reboot) and is tracked by the separate `RepairAttempts` counter. The two counters are independent.

## Exit codes and orchestration

Recommended orchestration policy:

| Code | Action |
|---|---|
| 0 | Record success. No further action. |
| 1 | Schedule a reboot at the next maintenance window. The next run will finish the registration. |
| 2 | Investigate the log. Check the state file's `LastUpdated` timestamp and `UsedOSFallback` flag. Five cases: **(a)** If the log shows the `Dedicated recovery partition creation failed after all attempts.` banner and the state file was updated this run with `UsedOSFallback = true`, the machine ended up in OS-fallback. Do not reboot or intervene while encryption is in progress. **(b)** If the log shows `Image injection did not complete. Stopping before Step 4 and before any deployment.` and the state file was not updated, OEM or VMD injection failed. No WIM was deployed, no partition touched, WinRE not disabled. The checkpoint was reset to 2. Investigate the injection failure reason. **(c)** If the log shows `Deferring WinRE Manager: Windows is not in a normal-running state (Setup\State\ImageState=…)` and the state file was not updated, the machine has not finished OOBE or is in Audit Mode. Complete OOBE and re-run. **(d)** If the log shows `OS-fallback deferred: C: VolumeStatus=…` and the state file was not updated, the dedicated partition could not be created and the OS-fallback target is encrypted. Wait for C: to reach `FullyDecrypted` or complete Device Encryption activation, then re-run. **(e)** If the log shows `Enable-only /enable failed (attempt N of 3)` or `Enable-only /enable refused with the BitLocker error after the target partition was confirmed unencrypted (attempt N of 3)` and the state file was updated with a non-`"ok"` `LastEnableResult`, the deployment is current and only the enable step failed. Investigate the enable failure itself; the next run retries enable-only. After three consecutive failures the loop-breaker fires (exit code 3). Cases (b), (c), and (d) leave the machine unchanged. |
| 3 | Do not retry automatically. Investigate the log immediately. If the log shows `FATAL: WinRE is not enabled at exit` on a machine that no longer has a recovery partition, follow the [troubleshooting.md](troubleshooting.md) recovery procedure before retrying. If the log shows `Refusing to retry reagentc /enable`, resolve the enable failure, delete the state file, then re-run. |

Do **not** use exit code 0 as the sole health signal. A machine that reached OS-fallback exits with 2, which is a legitimate "the machine is functional but the design goal was not achieved" signal. If your deployment policy requires dedicated recovery partitions, treat 2 as a soft failure and route it to a queue.

Do **not** configure retry loops that ignore the exit code and re-run unconditionally. None of the deferral states is made better by retrying — the same gate will fire on the next run. Wait until the underlying condition resolves (`manage-bde -status C:` reads a safe state on the OS-fallback route, or the machine has finished OOBE), then re-run. For the enable-failure counter, do not retry blindly: the counter is designed to break a silent loop, and after three consecutive failures the loop-breaker fires and requires manual intervention. Investigate the enable failure itself rather than cycling the script.

## Related documents

- [architecture.md](architecture.md) — the pipeline and the four control-flow paths.
- [troubleshooting.md](troubleshooting.md) — how to investigate each code, plus the recovery procedure for the pre-patch-5 failure mode and the enable-failure counter.
- [deployment.md](deployment.md) — the Audit Mode and BitLocker preconditions and exit-code handling for orchestration.
