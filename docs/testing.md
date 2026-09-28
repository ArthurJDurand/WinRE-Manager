# Testing

This document covers `Test-WinRE.ps1`, the read-only harness that ships with WinRE Manager.

## What the harness is

An interactive PowerShell script that:

- Exercises the download and extraction paths of the production script against live sources.
- Runs a parser self-test against the local Windows tooling to verify that every regex and API dependency the production script relies on still produces the expected shape.
- Reports the state of the machine from the same vantage point the production script uses, including a BitLocker hazard and ambiguity check.
- Reports results as PASS / FAIL / SKIP.
- Modifies nothing. Does not touch partitions, BitLocker, WinRE registration, drive letters, or the state file. Does not require elevation.

It is the primary tool for pre-flight validation on an unfamiliar machine.

## Running it

```powershell
# Interactive
.\scripts\Test-WinRE.ps1

# Non-interactive: runs "all relevant for this machine" and exits
.\scripts\Test-WinRE.ps1 -NonInteractive

# Do not offer to delete the working directory on exit
.\scripts\Test-WinRE.ps1 -Keep

# Custom working directory
.\scripts\Test-WinRE.ps1 -TestDir D:\WinRETest
```

The default working directory is `C:\Temp\WinRETest`. All downloads and extractions go there.

## The menu

```
  1. System diagnostic (read-only info gathering)
  2. Driver manifest fetch
  3. OEM maps fetch + resolve (Dell, HP, Lenovo)
  4. GitHub base WIM - Win10 (download + extract + build check)
  5. GitHub base WIM - Win11 (download + extract + build check)
  6. HP WinPE pack (download + extract)
  7. Dell WinPE pack (prompts for OS)
  8. Lenovo WinPE pack (prompts for MT)
  9. VMD drivers (per manifest, filtered for this machine)
  A. All relevant for this machine
  B. All of the above
  R. Print results summary
  Q. Quit
```

### Option 1 — System diagnostic

Read-only information gathering. Dumps:

- Hardware: manufacturer, model, product name/version, baseboard, CPU, OS build, Intel generation.
- Raw `reagentc /info` output and the parsed status/location.
- The WinRE classifier verdict: `DEDICATED`, `OS-fallback`, `RECOVERY-ON-SECONDARY`, or `UNEXPECTED`. Matches the v43 patch 2 production classifier.
- OS partition and OS disk.
- All disks with `BootFromDisk`, `IsSystem`, `IsBoot`.
- All partitions with size, drive letter, label, GPT type, MBR type, and boot/system/active flags.
- All volumes with file system, free space, label, and health.
- Recovery partitions per `Get-RecoveryPartitions`, with `isTyped`, `isLabel`, and `onOsDisk` annotations.
- The OS partition's `SizeMin`, `SizeMax`, shrinkable bytes, extendable bytes, and `S == M` status.
- The bucket sizing preview: for the active WIM's size, what bucket the production script would compute.
- BitLocker on C: (`ProtectionStatus`, `VolumeStatus`, `EncryptionMethod`, `EncryptionPercentage`), **plus a hazard warning for the four mid-operation states and a separate ambiguity warning for `Fully Encrypted + Protection Off`** (v12).
- VMD hardware presence per manifest.

Then it runs the parser self-test (below).

#### BitLocker hazard and ambiguity warnings (v12)

The BitLocker section of the diagnostic distinguishes two categories of state that production defers on. Both produce a warning block; they are different blocks, with different text, because they require different operator actions.

**Hazardous states.** When the section reports `ProtectionStatus: Off` together with a `VolumeStatus` of `EncryptionInProgress`, `DecryptionInProgress`, `EncryptionPaused`, or `DecryptionPaused`, the harness prints:

```
  WARNING: ProtectionStatus=Off but VolumeStatus=EncryptionInProgress.
           Device Encryption is actively encrypting or decrypting the OS volume.
           Production v43 patch 5 will refuse destructive partition work in this state.
           Wait until VolumeStatus=FullyDecrypted, or VolumeStatus=FullyEncrypted with ProtectionStatus=On.
```

The four hazardous states are the ones the pre-v43-patch-5 code treated as safe. The failure mode they cause — the encryption service claiming a newly created recovery partition before the recovery type GUID can be applied — is documented in [troubleshooting.md](troubleshooting.md). Two machines were damaged by it on the same day before patch 5 shipped.

**Ambiguous state.** When the section reports `ProtectionStatus: Off` together with `VolumeStatus=FullyEncrypted`, the harness prints a distinct block:

```
  WARNING: ProtectionStatus=Off with VolumeStatus=FullyEncrypted.
           This state is ambiguous: legitimate suspension, OR Device Encryption
           Waiting-for-Activation. Production v43 patch 5 refuses destructive
           partition work in this state. Resolve by waiting for either
           ProtectionStatus=On (protection re-armed) or VolumeStatus=FullyDecrypted.
```

The `Fully Encrypted + Protection Off` combination is what every machine enters after a legitimate `Suspend-BitLocker` or a Windows Update suspension that has not yet been lifted. It is also indistinguishable — from the local two-field view — from a Device Encryption volume in the *Waiting for Activation* state, where the volume has been encrypted with a clear key but protection has not yet been armed because the recovery key has not been escrowed. Production's further revision (v43 patch 5, further revision) treats this combination as ambiguous and defers it. The harness reports the same classification.

**Confirmed-safe states.** `VolumeStatus=FullyDecrypted` (or empty) with `ProtectionStatus=Off`, and `ProtectionStatus=On` at any conversion status, are safe. They do not trigger either warning.

The predicate is deliberately aligned with the production v43 patch 5 (further revision) `Suspend-BitLockerForWinRE` guard. The harness does not call into that guard — it queries `Get-BitLockerVolume` directly and applies the same classification — but a diagnostic that disagreed with production about which states are safe would be worse than no diagnostic at all.

The warnings exist because two machines were damaged by the pre-v43-patch-5 code on the same day, both on Windows 11 build 26200 mid-Device-Encryption. The production script now refuses to run destructive partition work in either the hazardous or the ambiguous state; the harness makes both visible before the field engineer runs the production script. See [troubleshooting.md](troubleshooting.md) for the full failure mode and recovery procedure.

Both warnings are diagnostics, not test results. They do not produce PASS/FAIL/SKIP records. They appear in the diagnostic output above the parser self-test.

### Options 2 through 9 and A/B

Exercise the download and extraction paths. Each option:

- Downloads the source.
- Extracts with the appropriate tool.
- Counts INF files for driver packs.
- For WIM downloads, extracts the WIM and reads its build with `Get-WindowsImage`.

Option A runs the subset relevant to the current machine (its OS, its vendor, its CPU). Option B runs everything.

## The parser self-test

Ten checks. Each records PASS, FAIL, or SKIP in `$Script:Results` and prints a matching `[OK]`/`[FAIL]`/`[SKIP]` line.

| # | Check | What it verifies |
|---|---|---|
| 1 | reagentc status regex | `(Enabled\|Disabled)` matches at least one line of `reagentc /info` output. |
| 2 | reagentc location regex | `(GLOBALROOT\|Volume GUID)` matches at least one line. |
| 3 | manage-bde protection regex | `Protection On` or `Protection Off` appears. |
| 4 | manage-bde conversion status regex | A `Conversion Status:` value matches, **or** the string `could not be opened by BitLocker` appears. |
| 5 | Get-BitLockerVolume shape | `ProtectionStatus` and `VolumeStatus` are non-null. SKIP if not elevated. |
| 6 | OS resolution | `Get-OSPartition` and `Get-OSDisk` both resolve. |
| 7 | Get-Partition shape | A sample partition exposes `DiskNumber`, `PartitionNumber`, `Size`, `GptType`, `MbrType`, `IsBoot`, `IsSystem`, `IsActive`. |
| 8 | WinRE location resolution | The reagentc location resolves to a partition. SKIP if location is empty. |
| 9 | Get-RecoveryPartitions | Returns at least one partition. |
| 10 | Get-PartitionSupportedSize | Returns `SizeMin` and `SizeMax`. SKIP if no OS partition. |

### What a FAIL means

A FAIL means the machine's Windows tooling no longer matches an assumption the production script relies on. The production script **may** silently misclassify state on this machine and must be adapted before deploying to it.

The three most likely FAILs and their implications:

- **Check 3 or 4 (manage-bde regex).** Windows changed `manage-bde -status` output format on this build. Production's BitLocker detection will fail; the script's `Test-BitLockerProtected` will return `$null` (unknown) and the destructive paths will refuse to run. The machine is safe but unreachable by the deployment.
- **Check 7 (Get-Partition shape).** The `Storage` module is missing or reduced. Production's partition classification will fail.
- **Check 10 (Get-PartitionSupportedSize).** The shrink path will fail. The script will fall back to OS-fallback after the OS-shrink attempt, but this is a machine-specific failure that should be investigated.

### What a SKIP means

A SKIP means the check could not run in the current context. The two reasons:

- **Not elevated.** `Get-BitLockerVolume` requires elevation on some machines. The check SKIPs rather than FAILing.
- **The state it inspects is absent.** WinRE location is empty, no OS partition, or similar. The check has nothing to inspect.

A SKIP does not indicate a defect.

## Result states

Every test records a result via `Record`:

```powershell
Record -Test "<name>" -Ok $true   -Detail "<description>"                        # PASS
Record -Test "<name>" -Ok $false  -Detail "<description>"                        # FAIL
Record -Test "<name>" -Ok $false  -State "SKIP" -Detail "<reason>"               # SKIP
```

The legacy `-Ok` boolean is still supported: when `-State` is not supplied, the state is derived from `-Ok`. When `-State` is supplied it is authoritative, and `OK` is `$true` only for PASS.

`Show-Summary` prints each result, then the totals:

```
Passed 8, failed 1, skipped 1 (of 10)
```

The BitLocker hazard and ambiguity warnings are diagnostics, not test records. They do not appear in `Show-Summary`.

## Non-interactive mode

```powershell
.\scripts\Test-WinRE.ps1 -NonInteractive
```

Runs `Invoke-AllRelevant`, prints the summary, exits.

`-NonInteractive` runs the download and extraction tests. It does not run the System Diagnostic (Option 1), so neither the hazardous nor the ambiguous BitLocker warning is printed in this mode. If you need either check, run the harness interactively and choose Option 1.

The exit code is always 0, regardless of results. The summary is the source of truth. If a pipeline consumer is added later, the minimal change to make the exit code reflect pass/fail is to count FAIL records in `$Script:Results` and exit non-zero when any exist. This is documented in the v11 changelog but not implemented, on the grounds that no consumer currently needs it.

## What the harness does not test

The harness is deliberately narrow. It does not and cannot test:

- **Partition creation, deletion, or resize.** No destructive operations.
- **BitLocker suspension or resume.** No state changes. The BitLocker section of the diagnostic queries `Get-BitLockerVolume` directly and does not call into production's `Suspend-BitLockerForWinRE` or `Test-BitLockerProtected`.
- **`reagentc /setreimage` or `reagentc /enable`.** No WinRE registration changes.
- **State file or checkpoint file writes.** Those files are production-only artifacts.
- **The full-update pipeline.** The harness exercises the download and extraction steps in isolation, not the pipeline.

Those paths are covered by field testing on representative hardware. See the "Field-tested hardware" table in the [README](../README.md).

## Differences from production

The harness shares code paths with production in the download, extraction, and CPU-generation helpers. It is documented in the file's own docstring which functions are "based on" the production versions and which are harness-specific.

Three known differences:

- **`Get-ThisMachineProfile` is harness-specific.** It uses `BuildNumber -ge 22000` to detect Windows 11; production uses `$os.Caption -like "*Windows 11*"`. The two agree on every Windows 11 client SKU but diverge on Server SKUs with build ≥ 22000. Neither the harness nor production is expected to run on Server.
- **`Test-VmdDrivers` does not filter on VMD hardware presence.** Production skips manifest entries whose `requiredDevices` do not match anything on the machine. The harness intentionally does not — it validates every OS/CPU-eligible URL and extraction path from a single machine, regardless of installed hardware. This makes the harness a package validator, not a machine-specific compatibility test.
- **The harness does not run `Test-BitLockerProtected`, `Suspend-BitLockerForWinRE`, or any production function that would block destructive work.** The BitLocker section in the diagnostic is a direct query of `Get-BitLockerVolume` and a comparison of the returned `ProtectionStatus` and `VolumeStatus` against the same classification the production guard uses — hazardous, ambiguous, or safe — but it does not call into the production guard. This is intentional: the harness does not exercise production's BitLocker control flow, and a change to that control flow does not require a harness update. The v43 patch 5 change to `Test-BitLockerProtected` and `Suspend-BitLockerForWinRE` (including the further-revision addition of the ambiguous `FullyEncrypted+Off` classification) therefore does not affect the harness directly — but the v12 hazard predicate was aligned with it manually so the two agree on which states are hazardous, ambiguous, and safe.

## Adding a test

The harness is a single file. To add a test:

1. Write a function that follows the existing pattern: log via `Say`, record the result via `Record`.
2. Add a menu entry in `Show-Menu`.
3. Add a case to the `switch` in the main loop.
4. If the test should run as part of "all relevant for this machine," add it to `Invoke-AllRelevant`.

Do not add tests that modify the machine's state. The harness's contract with the operator is that it is read-only.

## Related documents

- [troubleshooting.md](troubleshooting.md) — how to use the diagnostic output to diagnose a failure, including the BitLocker hazard and ambiguity recovery procedures.
- [driver-injection.md](driver-injection.md) — what the injection tests are actually testing.
- [deployment.md](deployment.md) — the BitLocker precondition for production deployment.
