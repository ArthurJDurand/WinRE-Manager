---
name: Bug report
about: Something is broken. Something is behaving unexpectedly.
labels: ['bug', 'needs-triage']
---

## Summary

<!-- One or two sentences. What happened? What did you expect? -->

## Environment

- **WinRE.ps1 version:** <!-- e.g. v46 patch 2, from the .NOTES block or from the first line of the log (`========== WinRE Manager Started (v46 patch 2) ==========`) -->
- **Windows build:** <!-- output of: [Environment]::OSVersion.Version -->
- **Vendor / model / Lenovo MT:** <!-- e.g. Lenovo 21L1 -->
- **Partition style:** <!-- GPT or MBR -->
- **Windows Setup state:** <!-- output of: (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State" -Name ImageState -ErrorAction SilentlyContinue).ImageState -->
  <!-- IMAGE_STATE_COMPLETE, another value, or blank. Another value means the machine is in Audit Mode, OOBE, or a sysprep phase. -->
- **BitLocker state on C:** <!-- paste both fields from: manage-bde -status C: -->
  - **Protection Status:** <!-- Protection On / Protection Off -->
  - **Conversion Status:** <!-- Fully Decrypted / Fully Encrypted / Encryption In Progress / Decryption In Progress / Encryption Paused / Decryption Paused -->
  <!-- C:'s state matters only on the OS-fallback route. On the enable-only and dedicated-partition routes, production targets the recovery partition directly and does not depend on C:'s state. -->
- **Free space on C:** <!-- current free, in GiB, and total size of C: in GiB -->
  <!-- Required if the run exited with a pre-shrink deferral (log line contains "Dedicated replacement deferred before partition deletion"). The free-space check refuses to shrink C: below a 3 GiB reserve, and the deferral reason names the projected post-shrink free space. -->
- **Target recovery partition state:** <!-- run: .\scripts\Test-WinRE.ps1 and choose Option 1. Copy the "Target recovery partition state" block. -->
  <!-- This is the partition reagentc is registered to. It is what production prepares via Set-RecoveryPartitionReadyForWinRE. If the block says "BitLocker-managed", production will run manage-bde -off against it before calling reagentc /enable. -->
- **VMD hardware present:** <!-- output of the harness Option 1 "VMD hardware presence" block, or "yes/no" from BIOS if the harness cannot be run. VMD presence is one of the DesiredStateId inputs. -->
  <!-- If the harness reports "INDETERMINATE", copy the enumeration error line above it (VMD hardware detection reported N error(s) during PnP enumeration: …). The specific error text distinguishes a service issue from an antivirus/EDR block from a device in an error state. -->
- **State file fields:** <!-- if C:\Recovery\OEM\winre_state.json exists, paste: DesiredStateId, LastUpdated, LastEnableResult, and EnableFailureAttempts -->
  <!-- LastEnableResult and EnableFailureAttempts are optional in the JSON and default to "ok" / 0 if absent. LastUpdated distinguishes a run that reached the state-write point (timestamp newer than run start) from a deferral (timestamp unchanged). DesiredStateId is required for the maintainer to check whether the state file would be accepted on this machine. -->
  <!-- If you can run the harness, Option S "State file parity check" reports whether the on-disk state file matches the ID production would compute right now. -->
- **Partition deferral marker:** <!-- if C:\Recovery\OEM\winre_partition_deferred.json exists, paste its contents (the DesiredStateId and Since fields). If it does not exist, say so. -->
  <!-- The marker is written when a pre-shrink deferral suppresses identical retries across runs. Its presence explains why a subsequent run exited EXIT_WARNING without re-attempting the pre-shrink. -->
- **Elevation:** <!-- Running as SYSTEM, as admin, unelevated -->
- **7-Zip present:** <!-- yes/no -->
- **Concurrent invocation:** <!-- was any other WinRE.ps1 process running at the same time? Scheduled task, manual invocation, RMM tool "run now", Intune remediation. -->
  <!-- If the run exited with code 2 and the log contains "Another WinRE Manager instance is already running (program lock file is exclusively held)", this is expected behavior, not a bug. The other instance is doing the work. -->
  <!-- If the run exited with code 3 and the log contains "Cannot rename because item at '<workspace>\winre.wim' does not exist" and an earlier line contains "Could not set up program lock at …", the lock could not be acquired for a non-contention reason and the run proceeded unprotected. Include the exact lock-failure message and the permissions on C:\ProgramData\OEM\Logs\. -->

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
- `Dedicated replacement deferred before partition deletion (<Reason>)` — pre-shrink deferral. Include the exact `<Reason>` string, C:'s free space, and the total size of C:.
- `Image injection did not complete. Stopping before Step 4` — Step 3 → Step 4 pipeline gate. Include the injection failure reason (OEM download, extraction, INF validation, or VMD driver download).
- `Enable-only /enable failed (attempt N of 3)` or `Enable-only /enable refused with the BitLocker error` — enable-failure counter. Include the state file's `LastEnableResult` and `EnableFailureAttempts`.
- `Offline fallback: the machine requires a full update` or `Offline fallback: using state file's stored DesiredStateId` — offline fallback. Include whether the machine was actually offline and the state file's `LastUpdated`.
- `Extension-failure fallback: creating recovery partition` or `Extension-failure fallback unavailable` — post-delete extension failure. Include the plan's bucket size, the trailing unallocated extent size, and the current C: end and disk end.
- `Pre-deletion inventory:` followed in the same run by `OS-fallback deferred: C: could not be confirmed fully decrypted` — the post-deletion residual corner. **Capture the full log and the machine's end state.** The project wants field data on this corner.
- `Refusing to retry reagentc /enable` — enable-failure loop-breaker. The state file still records the counter; the operator resolves the cause, deletes the state file, re-runs.
- `Planned recovery extent is no longer free after deletion (offset=... size=... overlapCount=0)` with an `alignment reserve` value in the plan summary — the v45 plan-rejection corner fixed by v46 patch 1. Include the top-of-log version banner and the `alignment reserve` value.
- `CmdletizationQuery_NotFound_DiskNumber` or `No MSFT_Partition objects found with property 'DiskNumber'` — the SD/MMC read. Note the disk number and whether the machine has a card reader or an empty USB enclosure attached.

<details>
<summary>C:\ProgramData\OEM\Logs\WinRE-Manager.log (relevant slice)</summary>

```
paste here
```

</details>

<details>
<summary>Test-WinRE.ps1 output</summary>

```
paste here
```

</details>

## Additional context

<!-- Screenshots, hardware quirks, anything unusual. -->

---

**Why we ask for all this.** The script's design is organized around four invariants — *never break Windows RE*, *never leave a machine without a working recovery route*, *minimize the `reagentc /disable` → `reagentc /enable` window*, and *do no work unless needed; prepare everything before touching anything*. See [`docs/architecture.md`](../docs/architecture.md) for the full hierarchy. The fields above are the ones that let the maintainer determine which invariant was involved in your failure and reproduce it. `docs/deployment.md` translates the invariants into deployment-time guidance, `docs/troubleshooting.md` maps log signatures to symptoms, and `CONTRIBUTING.md` documents the report requirements.
