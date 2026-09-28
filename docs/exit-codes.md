# Exit codes

WinRE Manager returns one of four exit codes. Orchestration should treat them as distinct outcomes, not as success/failure booleans.

## The four codes

| Code | Name | Meaning |
|---|---|---|
| `0` | `EXIT_SUCCESS` | WinRE enabled, dedicated recovery partition healthy, state file written or already current. |
| `1` | `EXIT_REBOOT_REQUIRED` | Deployment succeeded; a reboot is required to complete WinRE registration. |
| `2` | `EXIT_WARNING` | WinRE functional but degraded. Details in the log. |
| `3` | `EXIT_FATAL` | Deployment aborted. No state written or state file deleted. Investigate the log. |

## Priority

When a run's outcome satisfies more than one condition, the priority order is:

```
EXIT_FATAL  >  EXIT_REBOOT_REQUIRED  >  EXIT_WARNING  >  EXIT_SUCCESS
```

`EXIT_FATAL` always wins. Between `EXIT_REBOOT_REQUIRED` and `EXIT_WARNING`, reboot-required wins — the machine needs to reboot either way.

In practice only two combinations are reachable:

- **Reboot-required + warning.** A reboot is needed and a cleanup step failed. Returns `1`.
- **Warning + success.** A non-fatal warning was raised (BitLocker resume failed, fallback copy denied, Device Encryption guard deferral) but the run did not fully fail. Returns `2`.

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
- **Device Encryption guard deferral (v43 patch 5, revised).** The machine was mid-Device-Encryption (`ProtectionStatus=Off` with `VolumeStatus` one of `EncryptionInProgress`, `DecryptionInProgress`, `EncryptionPaused`, `DecryptionPaused`) and the script refused to run the destructive partition path. The guard fires in `Ensure-AdequateRecoveryPartition` before `reagentc /disable`; when that gate refuses, the main flow exits with `EXIT_WARNING` immediately — it logs a single deferral message, does not log a partition-creation failure, does not set `UsedOSFallback`, does not disable WinRE, and does not fall through to OS-fallback. A second gate in Step 5 covers the routes that do not reach `Ensure-AdequateRecoveryPartition` directly (a machine whose existing recovery partition was already insufficient on this pass, or an enable-only escalation); that gate exits the same way. In both cases the machine's WinRE state and recovery partition are left intact, and no new state file is written. The next run, once `VolumeStatus` reads `FullyDecrypted` or `FullyEncrypted`, can complete the dedicated-partition work. See [troubleshooting.md](troubleshooting.md) for the recovery procedure and [deployment.md](deployment.md) for the precondition.
- **`$Script:nonFatalWarning = $true`.** Set by: BitLocker suspension failure, BitLocker resume failure, cleanup failure in `Remove-StrayRecoveryPartitions`, fallback copy denial (ACL), recovery-attribute application failure, and OEM map resolution failure for a supported vendor.
- **`$Script:UsedOSFallback = $true`.** Distinct from `nonFatalWarning`; can be true without any warning-level event, and is the deliberate outcome of the shrink-fails path.

The warning code is returned on the fast path, the enable-only path, the pending-reboot success path, and the full-update path — anywhere a warning flag can be set. In every case the state file is still written (or left in place) if the run reached a state-write point.

**Important for orchestration:** on a machine in the Device Encryption hazard state, exit code 2 can mean either "the machine ended up in OS-fallback" or "the script deferred the work to the next run". The two cases are distinguished by the state-file timestamp:

- If the state file's `LastUpdated` field is newer than the run's start time, the run reached the state-write step and the machine ended up in OS-fallback. `UsedOSFallback = true` will be recorded.
- If the state file's `LastUpdated` field is unchanged (or no state file exists), the run deferred the work before the state-write step. No new state was committed and the machine's WinRE state is unchanged. Re-check on the next scheduled run once the encryption state has stabilised.

The distinguishing log entry for the deferral case is the guard message (`ProtectionStatus=Off but VolumeStatus=... Refusing to treat as unprotected`) followed by a single deferral line. A partition-creation failure — with its `Dedicated recovery partition creation failed after all attempts.` banner — is only logged when the destructive attempt actually ran and failed; a deferral is not that.

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
- **Whether the Device Encryption guard fired.** The log records the guard message (`ProtectionStatus=Off but VolumeStatus=... Refusing to treat as unprotected`) followed by a single deferral line. The state file's `LastUpdated` timestamp distinguishes deferral (unchanged, or absent) from OS-fallback (newer than the run start).
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

Note that `PendingReboot` and `RepairAttempts` are recorded in the state file before the exit, so a machine that exits with code 3 due to too many repair attempts still has a state file reflecting the current repair count.

## Exit codes and orchestration

Recommended orchestration policy:

| Code | Action |
|---|---|
| 0 | Record success. No further action. |
| 1 | Schedule a reboot at the next maintenance window. The next run will finish the registration. |
| 2 | Investigate the log. Check the state file's `LastUpdated` timestamp. If the log shows the guard message (`ProtectionStatus=Off but VolumeStatus=... Refusing to treat as unprotected`) followed by a single deferral line, and the state file was not updated during this run, the script deferred the work; defer the retry to the next scheduled run once `manage-bde -status C:` reads `Fully Decrypted` or `Fully Encrypted`. If instead the log shows the `Dedicated recovery partition creation failed after all attempts.` banner and the state file was updated, the machine ended up in OS-fallback. Do not reboot or intervene while encryption is in progress. |
| 3 | Do not retry automatically. Investigate the log immediately. If the log shows `FATAL: WinRE is not enabled at exit` on a machine that no longer has a recovery partition, follow the [troubleshooting.md](troubleshooting.md) recovery procedure before retrying. |

Do **not** use exit code 0 as the sole health signal. A machine that reached OS-fallback exits with 2, which is a legitimate "the machine is functional but the design goal was not achieved" signal. If your deployment policy requires dedicated recovery partitions, treat 2 as a soft failure and route it to a queue.

Do **not** configure retry loops that ignore the exit code and re-run unconditionally. The Device Encryption hazard state on a machine that is mid-encryption is not made better by retrying — the same guard will fire on the next run. Wait until `manage-bde -status C:` reads `Fully Decrypted` or `Fully Encrypted` and re-run then.

## Related documents

- [architecture.md](architecture.md) — the pipeline and the four control-flow paths.
- [troubleshooting.md](troubleshooting.md) — how to investigate each code, plus the recovery procedure for the pre-patch-5 failure mode.
- [deployment.md](deployment.md) — the Device Encryption precondition and exit-code handling for orchestration.
