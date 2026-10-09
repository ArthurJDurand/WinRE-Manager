---
name: Bug report
about: Something is broken. Something is behaving unexpectedly.
labels: ['bug', 'needs-triage']
---

## Summary

<!-- One or two sentences. What happened? What did you expect? -->

## Environment

- **WinRE.ps1 version:** <!-- e.g. v49, from the .NOTES block or from the first line of the log (`========== WinRE Manager Started (v49) ==========`) -->
- **Windows build:** <!-- output of: [Environment]::OSVersion.Version -->
- **Vendor / model / Lenovo MT:** <!-- e.g. Lenovo 21L1 -->
- **Partition style:** <!-- GPT or MBR -->
- **Intervening partition (v48+):** <!-- If the OS disk has a non-recovery partition between C: and the type-coded recovery partition, describe it: drive letter, size, filesystem, type code, BitLocker state. v48 handles exactly one intervening partition when it validates as an anchor; a `C: | D: | E: | Recovery` layout still defers. Skip if C: and the recovery partition are adjacent. -->
- **Windows Setup state:** <!-- output of: (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State" -Name ImageState -ErrorAction SilentlyContinue).ImageState -->
  <!-- IMAGE_STATE_COMPLETE, another value, or blank. Another value means the machine is in Audit Mode, OOBE, or a sysprep phase. -->
- **BitLocker state on C:** <!-- paste both fields from: manage-bde -status C: -->
  - **Protection Status:** <!-- Protection On / Protection Off -->
  - **Conversion Status:** <!-- Fully Decrypted / Fully Encrypted / Encryption In Progress / Decryption In Progress / Encryption Paused / Decryption Paused -->
  <!-- C:'s state matters only on the OS-fallback route. On the enable-only and dedicated-partition routes, production targets the recovery partition directly and does not depend on C:'s state. -->
- **Free space on the resize target:** <!-- current free, in GiB, and total size of the resize target in GiB -->
  <!-- Required if the run exited with a pre-shrink deferral (log line contains "Dedicated replacement deferred before partition deletion"). The free-space check refuses to shrink the resize target below a 3 GiB reserve, and the deferral reason names the projected post-shrink free space. The resize target is C: on the ordinary path, or the intervening anchor partition (typically D:) on the v48 `C: | D: | Recovery` path. The deferral reason in the log names which: "OS partition (C:)" or "anchor partition (disk X part Y)". Report the free space and total size of the target the deferral reason names. -->
- **Target recovery partition state:** <!-- run: .\scripts\Test-WinRE.ps1 and choose Option 1. Copy the "Target recovery partition state" block. -->
  <!-- This is the partition reagentc is registered to. It is what production prepares via Set-RecoveryPartitionReadyForWinRE. If the block says "BitLocker-managed", production will run manage-bde -off against it before calling reagentc /enable. -->
- **VMD hardware present:** <!-- output of the harness Option 1 "VMD hardware presence" block, or "yes/no" from BIOS if the harness cannot be run. VMD presence is one of the DesiredStateId inputs. -->
  <!-- If the harness reports "INDETERMINATE", copy the enumeration error line printed under it (the harness emits `PnP enumeration error: …` in the line below the INDETERMINATE verdict). The specific error text distinguishes a service issue from an antivirus/EDR block from a device in an error state. -->
- **Storage controllers present (v28 harness):** <!-- output of the harness Option 1 "Storage controllers" block, if shown. The v49 pre-deployment storage-applicability gate compares the candidate image's INFs against these controllers. If the run deferred at the applicability gate, this block is what the maintainer needs. -->
- **State file fields:** <!-- if C:\Recovery\OEM\winre_state.json exists, paste: DesiredStateId, LastUpdated, LastEnableResult, and EnableFailureAttempts -->
  <!-- LastEnableResult and EnableFailureAttempts are optional in the JSON and default to "ok" / 0 if absent. LastUpdated distinguishes a run that reached the state-write point (timestamp newer than run start) from a deferral (timestamp unchanged). DesiredStateId is required for the maintainer to check whether the state file would be accepted on this machine. -->
  <!-- If you can run the harness, Option S "State file parity check" reports whether the on-disk state file matches the ID production would compute right now. As of v48 it also reports the stored and computed `LocalInputsId` so an offline-fallback mismatch can be diagnosed without running production. -->
- **Checkpoint file (if present):** <!-- copy `C:\ProgramData\OEM\Logs\winre_checkpoint.txt` verbatim. It carries the staged step, the recorded `DesiredStateId`, the workspace path, the `WIM_READY` flag, and the recorded source-content hash. The fifth field (source hash) was introduced on `WIM_READY` checkpoints in v47 patch 1 and extended to Step 3 checkpoints in v47 patch 2. Relevant for v47 checkpoint-invalidation bugs (`Checkpoint step N source identity ... does not match the currently-selected source`) and stale-workspace resume issues. -->
- **Partition deferral marker:** <!-- if C:\Recovery\OEM\winre_partition_deferred.json exists, paste its contents (the DesiredStateId and Since fields). If it does not exist, say so. -->
  <!-- The marker is written when a pre-shrink deferral suppresses identical retries across runs. Its presence explains why a subsequent run exited EXIT_WARNING without re-attempting the pre-shrink. -->
- **Resume task present (v49):** <!-- query: Get-ScheduledTask -TaskName 'WinRE Manager - Resume' -ErrorAction SilentlyContinue. If it exists, paste its State, LastRunTime, NextRunTime, and the action's Arguments (the "Task To Run" field from `schtasks /query /tn "WinRE Manager - Resume" /v /fo list`). If it does not exist, say so. -->
  <!-- The resume task is registered by every Repair or Restore run and is deleted on clean completion. If it is still present, either a prior run was interrupted (Ctrl+C, hard kill, reboot, or an unhandled exception) or a Repair/Restore run is currently in flight. Its five persist triggers are the outer catch, the CancelKeyPress handler, Invoke-RestoreAction's two mid-transformation failure paths, a hard kill, and a reboot. If the log mentions `$PSCommandPath` and this task was not registered, that is expected under gist-bootstrap or paste-into-console invocation — not a bug. -->
- **Elevation:** <!-- Running as SYSTEM, as admin, unelevated -->
- **7-Zip present:** <!-- yes/no -->
- **Concurrent invocation:** <!-- was any other WinRE.ps1 process running at the same time? Scheduled task, manual invocation, RMM tool "run now", Intune remediation. -->
  <!-- If the run exited with code 2 and the log contains "Another WinRE Manager instance is already running (program lock file is exclusively held)", this is expected behavior, not a bug. The other instance is doing the work. -->
  <!-- If the run exited with code 3 and the log contains "Cannot rename because item at '<workspace>\winre.wim' does not exist" and an earlier line contains "Could not set up program lock at …", the lock could not be acquired for a non-contention reason and the run proceeded unprotected. Include the exact lock-failure message and the permissions on C:\ProgramData\OEM\Logs\. -->
  <!-- If the run exited with code 3 and the log contains "FATAL: WinRE Manager requires an elevated (Administrator) PowerShell session", this is expected behavior as of v48 patch 2, not a bug. The guard refuses unelevated launches in milliseconds rather than failing several minutes later at Mount-WindowsImage. The fix is to relaunch from an elevated prompt or via `scripts\WinRE-Manager.cmd`. -->

## Reproduction

1. <!-- exact command line -->
2. <!-- what happened -->

## Expected

<!-- what should have happened -->

## Actual

<!-- what happened instead -->

## Exit code

<!-- 0 / 1 / 2 / 3 -->

## Log

**If your log contains any of the following lines, please copy the surrounding context** (10–20 lines before and after). These are the exact signatures the maintainer wants to see for the corresponding failure mode:

- `Another WinRE Manager instance is already running` — concurrent-instance deferral. Not a failure; the other instance is doing the work.
- `Deferring WinRE Manager: Windows is not in a normal-running state` — Audit Mode / OOBE / sysprep deferral.
- `VMD hardware detection was indeterminate; deferring` — fail-closed VMD check. Include the enumeration error from the line above.
- `OS-fallback deferred: C: could not be confirmed fully decrypted` — OS-fallback route refused. Include C:'s `Test-VolumeEncrypted` value.
- `Dedicated replacement deferred before partition deletion (<Reason>)` — pre-shrink deferral. Include the exact `<Reason>` string, the free space on the resize target named in that reason, and the total size of that target.
- `Image injection did not complete. Stopping before Step 4` — Step 3 → Step 4 pipeline gate. Include the injection failure reason (OEM download, extraction, INF validation, or VMD driver download).
- `Enable-only /enable failed (attempt N of 3)` or `Enable-only /enable refused with the BitLocker error` — enable-failure counter. Include the state file's `LastEnableResult` and `EnableFailureAttempts`.
- `Offline fallback: the machine requires a full update` or `Offline fallback: using state file's stored DesiredStateId` — offline fallback. Include whether the machine was actually offline and the state file's `LastUpdated`.
- `Extension-failure fallback: creating recovery partition` or `Extension-failure fallback unavailable` — post-delete extension failure. Include the plan's bucket size, the trailing unallocated extent size, and the current C: end and disk end.
- `Pre-deletion inventory:` followed in the same run by `OS-fallback deferred: C: could not be confirmed fully decrypted` — the post-deletion residual corner. **Capture the full log and the machine's end state.** The project wants field data on this corner.
- `Refusing to retry reagentc /enable` — enable-failure loop-breaker. The state file still records the counter; the operator resolves the cause, deletes the state file, re-runs.
- `Planned recovery extent is no longer free after deletion (offset=... size=... overlapCount=0)` with an `alignment reserve` value in the plan summary — the v45 plan-rejection corner fixed by v46 patch 1. Include the top-of-log version banner and the `alignment reserve` value.
- `Strip stage failed - candidate rejected` — the v47 strip stage rejected the candidate. Include the specific strip failure reason from the preceding line (enumeration, removal, missing INF field, or budget exhaustion) and the pre-strip inventory lines.
- `Registered-source recheck at <site> : CHANGED` followed by `Registered WinRE source changed during candidate preparation` — the v47 race detector fired. Include the captured fingerprint line, the recheck line, the change triple (`location=<bool> version=<bool> hash=<bool>`), and whether a Windows Update was in flight.
- `State has no DeployedWinREMetadata anchor`, `Registered WinRE metadata changed from … to …`, or `Registered WinRE metadata could not be read` — the v47 metadata-based rebuild trigger fired. Include the state file's `DeployedWinREMetadata` value and the currently-registered WinRE's `Version` / `SPBuild`.
- `CmdletizationQuery_NotFound_DiskNumber` or `No MSFT_Partition objects found with property 'DiskNumber'` — the SD/MMC read. Note the disk number and whether the machine has a card reader or an empty USB enclosure attached.
- `Base WIM copy hash mismatch: source=..., copied=...` — the v47 patch 2 copy-integrity check rejected the candidate. Include the source path, the source hash, the copied hash, and the currently-registered WinRE metadata (in case the source changed during acquisition).
- `Base WIM copy is unreadable after Copy-Item` — the copy-integrity check could not read the destination. Include the source path and the source hash.
- `Could not confirm removal: <path>` — the v47 patch 3 `Remove-ItemIfExist` verification fired. Include the path, its parent directory contents, and whether a lock or ACL was suspected.
- `Checkpoint step N has no recorded source identity` — a legacy (v47 patch 1 Step 3) or GitHub-sourced checkpoint was invalidated on first resume. Include the checkpoint's recorded Step value.
- `Checkpoint step N source identity ... does not match the currently-selected source ...` — the recorded source identity no longer matches the current selection rules. Include the recorded hash, the currently-selected hash, and the source-selection `Reason` string.
- `Checkpoint step N source identity ... cannot be re-validated` — no source was available to validate the checkpoint against. Include the recorded hash.
- `Registered WinRE candidate is present at ... but its servicing metadata could not be read` — the source-selection helper could not read the registered WIM's DISM servicing metadata. Include the path.
- `A WIM was discovered at ... but not at the registered location` — the loose fallback-discovery path found a WIM outside the registered location. Include the path and whether the registered location yielded a readable WIM.
- `WinRE is registered via OS-fallback (location: ...) but its winre.wim could not be read at that location (status=...) - forcing rebuild` — the v47 patch 2 OS-fallback missing-WIM guard fired. Include the registered location, the `reagentc /info` status, and whether `C:\Recovery\WindowsRE\winre.wim` exists.
- `All three methods failed for <letter>: - <diagnostic>` — drive-letter assignment exhausted one of the 26 candidate letters. The `<diagnostic>` names the reason (for example `diskpart: The specified drive letter is not free to be assigned` for a letter reserved by a mapped network drive). Include the diagnostic string, the full `All three methods failed for ...` lines from the log, and the current drive letters reported by `Get-PSDrive -PSProvider FileSystem` and `net use`.
- `Invoke-DriveLetterAssignment: target partition <n>/<m> no longer exists` — the target partition was removed mid-search. Include what deleted it (a concurrent tool, an operator action, or a failed prior step) and the current partition inventory from `Get-Partition`.
- `Invoke-DriveLetterAssignment: target disk <n> is <offline|status>` — the disk holding the target partition went offline or is not Online. Include the disk state from `Get-Disk -Number <n> | Format-List` and whether the disk came back online after the run.
- `WinRE is Enabled but its registered location ... could not be resolved to a partition` or `WinRE is Enabled but reagentc reports no registered location` — the v48 patch 1 fail-closed pre-shrink guard. Include the `reagentc /info` output verbatim, the partition inventory from `Get-Partition`, and whether the registered location is a `GLOBALROOT\...` or `Volume{...}` path.
- `Intervening-anchor plan: anchor is disk <n> part <m>; anchor shrink <N> MiB` — the v48 intervening-anchor path entered. Include the anchor partition's current size, filesystem, type code, BitLocker state, and drive letter, plus the full partition inventory from `Get-Partition -DiskNumber <n>`.
- `anchor is ... ; refusing to shrink` or `anchor is BitLocker-locked` or `anchor encryption state is indeterminate` or `anchor has no drive letter` — the v48 anchor validation rejected. Include the specific rejection reason from the log and the anchor partition's properties.
- `intervening anchor is <N> MiB smaller than the plan requires` — the v48 surplus rejection. Include the anchor's current size, the required bucket size, and the size of the recovery partition being reclaimed.
- `recovery-typed partitions exist beyond the intervening anchor's recovery cluster` — the v48 multi-intervening rejection. Include the full partition layout from `Get-Partition -DiskNumber <n>`.
- `Unsupported OS architecture '<arch>'` — the v48 architecture gate refusal. Include `[Environment]::Is64BitOperatingSystem`, `$env:PROCESSOR_ARCHITECTURE`, `$env:PROCESSOR_ARCHITEW6432`, and the output of `Get-CimInstance Win32_OperatingSystem | Select-Object OSArchitecture, Caption, BuildNumber`.
- `Offline fallback: stored LocalInputsId <hash> does not match the current locally-computable inputs <hash>` — the v48 offline hardware-drift guard. Include both hashes and the state file's `LastUpdated`.
- `Preserving existing target ... as rollback copy` or `Deploy-WimTransactional ... copy failed - restoring rollback copy` or `Deploy-WimTransactional ... rollback restore hash verification failed` or `Rollback copy restored to <path>` — the v48 transactional WIM replacement. Include the source path, target path, source hash, target hash (if any), and whether the rollback restore hash-verified.
- `FATAL: WinRE Manager requires an elevated (Administrator) PowerShell session` — the v48 patch 2 fail-fast elevation guard. This is expected behavior, not a bug. The fix is to relaunch from an elevated prompt or via `scripts\WinRE-Manager.cmd`. The script exits with code 3 in this case.

**v49 log signatures are not listed here yet.** The v49 features that add new log output — source-ownership classification, the never-downgrade storage-driver check, the pre-deployment storage-applicability gate, the native-boot VHDX fail-closed gate, the backup and restore actions, the temporary resume task, and the stable install location — are new in this release and their exact log strings have not been catalogued. If your run failed in a way that mentions one of those features, paste the lines verbatim and the maintainer will add them to this list.

<details>
<summary>C:\ProgramData\OEM\Logs\WinRE-Manager.log (relevant slice)</summary>

```
paste here
```

</details>

<details>
<summary>Test-WinRE.ps1 output</summary>

```
paste the interactive output here. Options 1 (System diagnostic) and S (State file parity check) are the most useful. On the v28 harness the Option 1 output includes the "Storage controllers" block and the VMD diagnostic advisory when VMD is not detected but SCSIAdapter-class devices are present.
```

</details>

## Additional context

<!-- Screenshots, hardware quirks, anything unusual. -->

---

**Why we ask for all this.** The script's design is organized around four invariants — *never break Windows RE*, *never leave a machine without a working recovery route*, *minimize the `reagentc /disable` → `reagentc /enable` window*, and *do no work unless needed; prepare everything before touching anything*. See [`docs/architecture.md`](docs/architecture.md) for the full hierarchy. The fields above are the ones that let the maintainer determine which invariant was involved in your failure and reproduce it. [`docs/deployment.md`](docs/deployment.md) translates the invariants into deployment-time guidance, [`docs/troubleshooting.md`](docs/troubleshooting.md) maps log signatures to symptoms, and [`CONTRIBUTING.md`](CONTRIBUTING.md) documents the report requirements.
