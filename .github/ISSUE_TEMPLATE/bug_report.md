---
name: Bug report
about: Something is broken. Something is behaving unexpectedly.
labels: ['bug', 'needs-triage']
---

## Summary

<!-- One or two sentences. What happened? What did you expect? -->

## Environment

- **WinRE.ps1 version:** <!-- e.g. v43 patch 5, from the .NOTES block -->
- **Windows build:** <!-- output of: [Environment]::OSVersion.Version -->
- **Vendor / model / Lenovo MT:** <!-- e.g. Lenovo 21L1 -->
- **Partition style:** <!-- GPT or MBR -->
- **BitLocker state on C::** <!-- paste both fields from: manage-bde -status C: -->
  - **Protection Status:** <!-- Protection On / Protection Off -->
  - **Conversion Status:** <!-- Fully Decrypted / Fully Encrypted / Encryption In Progress / Decryption In Progress / Encryption Paused / Decryption Paused -->
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
