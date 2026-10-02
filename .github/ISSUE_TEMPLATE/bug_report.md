---
name: Bug report
about: Something is broken. Something is behaving unexpectedly.
labels: ['bug', 'needs-triage']
---

## Summary

<!-- One or two sentences. What happened? What did you expect? -->

## Environment

- **WinRE.ps1 version:** <!-- e.g. v45 patch 1, from the .NOTES block -->
- **Windows build:** <!-- output of: [Environment]::OSVersion.Version -->
- **Vendor / model / Lenovo MT:** <!-- e.g. Lenovo 21L1 -->
- **Partition style:** <!-- GPT or MBR -->
- **Windows Setup state:** <!-- output of: (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State" -Name ImageState -ErrorAction SilentlyContinue).ImageState -->
  <!-- IMAGE_STATE_COMPLETE, another value, or blank. Another value means the machine is in Audit Mode, OOBE, or a sysprep phase. -->
- **BitLocker state on C:** <!-- paste both fields from: manage-bde -status C: -->
  - **Protection Status:** <!-- Protection On / Protection Off -->
  - **Conversion Status:** <!-- Fully Decrypted / Fully Encrypted / Encryption In Progress / Decryption In Progress / Encryption Paused / Decryption Paused -->
  <!-- C:'s state matters only on the OS-fallback route. On the enable-only and dedicated-partition routes, production targets the recovery partition directly and does not depend on C:'s state. -->
- **Target recovery partition state:** <!-- run: .\scripts\Test-WinRE.ps1 and choose Option 1. Copy the "Target recovery partition state" block. -->
  <!-- This is the partition reagentc is registered to. It is what production prepares via Set-RecoveryPartitionReadyForWinRE. If the block says "BitLocker-managed", production will run manage-bde -off against it before calling reagentc /enable. -->
- **VMD hardware present:** <!-- output of the harness Option 1 "VMD hardware presence" block, or "yes/no" from BIOS if the harness cannot be run. VMD presence is one of the DesiredStateId inputs. -->
  <!-- If the harness reports "INDETERMINATE", copy the enumeration error line above it (VMD hardware detection reported N error(s) during PnP enumeration: …). The specific error text distinguishes a service issue from an antivirus/EDR block from a device in an error state. -->
- **State file fields:** <!-- if C:\Recovery\OEM\winre_state.json exists, paste: DesiredStateId, LastEnableResult, and EnableFailureAttempts -->
  <!-- LastEnableResult and EnableFailureAttempts are optional in the JSON and default to "ok" / 0 if absent. DesiredStateId is required for the maintainer to check whether the state file would be accepted on this machine. -->
  <!-- If you can run the harness, Option S "State file parity check" reports whether the on-disk state file matches the ID production would compute right now. -->
- **Partition deferral marker:** <!-- if C:\Recovery\OEM\winre_partition_deferred.json exists, paste its contents (the DesiredStateId and Since fields). If it does not exist, say so. -->
  <!-- The marker is written when a pre-shrink deferral suppresses identical retries across runs. Its presence explains why a subsequent run exited EXIT_WARNING without re-attempting the pre-shrink. -->
- **Elevation:** <!-- Running as SYSTEM, as admin, unelevated -->
- **7-Zip present:** <!-- yes/no -->

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
