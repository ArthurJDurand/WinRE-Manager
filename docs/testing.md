# Testing

This document covers `Test-WinRE.ps1`, the read-only harness that ships with WinRE Manager.

## What the harness is

An interactive PowerShell script that:

- Exercises the download and extraction paths of the production script against live sources.
- Runs a parser self-test against the local Windows tooling to verify that every regex and API dependency the production script relies on still produces the expected shape.
- Reports the state of the machine from the same vantage point the production script uses, including the BitLocker state of C:, the BitLocker state of the target recovery partition, and the Windows Setup `ImageState`.
- Recomputes the `DesiredStateId` production would compute right now and compares it to the on-disk state file, so a field engineer can see whether production would take the fast path or rebuild (Option S).
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
  S. State file parity check (production DSI vs on-disk state file)
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
- The Windows Setup state (`ImageState`), with a warning when the value is present and is not `IMAGE_STATE_COMPLETE`.
- BitLocker on C: (`ProtectionStatus`, `VolumeStatus`, `EncryptionMethod`, `EncryptionPercentage`), **plus a hazard warning for the four mid-operation states and a separate ambiguity warning for `Fully Encrypted + Protection Off`** (v12, warning text updated in v14).
- **The target recovery partition state** (v14): the BitLocker status of the partition reagentc is registered to. This is the state that determines whether the production script will need to run `manage-bde -off` before calling `reagentc /enable`.
- VMD hardware presence per manifest.

Then it runs the parser self-test (below).

#### BitLocker (C:) warnings (v12, updated in v14)

The BitLocker section of the diagnostic distinguishes two categories of state on C: that are relevant to the OS-fallback route. Both produce a warning block.

**Hazardous states.** When the section reports `ProtectionStatus: Off` together with a `VolumeStatus` of `EncryptionInProgress`, `DecryptionInProgress`, `EncryptionPaused`, or `DecryptionPaused`, the harness prints:

```
  WARNING: ProtectionStatus=Off but VolumeStatus=EncryptionInProgress.
           Device Encryption is actively encrypting or decrypting the OS volume.
           Production v43 patch 5 (further revision 5) refuses the OS-fallback
           path in this state, because reagentc will not enable WinRE on an
           encrypted OS volume. The enable-only and dedicated-partition paths
           are still available: production prepares the target recovery
           partition directly and does not depend on C:'s state.
           To restore the OS-fallback path, wait until manage-bde -status C:
           reads Conversion Status: Fully Decrypted (or Protection On).
```

**Ambiguous state.** When the section reports `ProtectionStatus: Off` together with `VolumeStatus=FullyEncrypted`, the harness prints a distinct block:

```
  WARNING: ProtectionStatus=Off with VolumeStatus=FullyEncrypted.
           This state is ambiguous: legitimate suspension, OR Device Encryption
           Waiting-for-Activation (recovery key not yet escrowed). The local
           two-field view cannot distinguish the two.
           Production v43 patch 5 (further revision 5) refuses the OS-fallback
           path in this state, because reagentc will not enable WinRE on an
           encrypted OS volume. The enable-only and dedicated-partition paths
           are still available if the target recovery partition is unencrypted.
           To restore the OS-fallback path, wait for either ProtectionStatus=On
           (activation completed) or VolumeStatus=FullyDecrypted.
```

The wording of these warnings was updated in harness v14. The v12/v13 wording said production "will refuse destructive partition work" in these states, which described the removed OS-volume-gate policy and would have told a field engineer to defer a run that production would actually succeed on. Under the v43 patch 5 (further revision 5) policy, only the OS-fallback route depends on C:'s BitLocker state; the enable-only and dedicated-partition routes target the recovery partition directly and are not affected.

**Confirmed-safe states.** `VolumeStatus=FullyDecrypted` (or empty) with `ProtectionStatus=Off`, and `ProtectionStatus=On` at any conversion status, are safe for the OS-fallback route. They do not trigger either warning.

The classification predicate matches production's `Test-VolumeEncrypted`: the four mid-operation states are hazardous, `FullyEncrypted+Off` is ambiguous, and everything else is safe. The harness does not call into production's `Test-VolumeEncrypted` — it queries `Get-BitLockerVolume` directly and applies the same predicate — but a diagnostic that disagreed with production about which states are hazardous, ambiguous, or safe would be worse than no diagnostic at all.

#### Target recovery partition state (v14)

The v43 patch 5 (further revision 5) policy is target-volume-based. reagentc's BitLocker check is on the partition it is being asked to enable WinRE on, not on C:. The harness reports the BitLocker state of the partition reagentc is registered to. This is the state that determines whether the production script will need to run `manage-bde -off` on the target partition before calling `reagentc /enable`, and whether `Set-RecoveryPartitionReadyForWinRE` will find the partition already clean or need to prepare it.

The diagnostic prints one of:

```
--- Target recovery partition state ---
  Registered partition: Disk <n> Part <m>
  Querying manage-bde -status for: <letter or volume GUID>
  Classification: unmanaged by BitLocker
                  reagentc /enable will accept this partition as-is.
```

```
  Classification: fully decrypted
                  reagentc /enable will accept this partition as-is.
```

```
  Conversion Status: <value>
  Classification: BitLocker-managed
                  Production will run manage-bde -off against this partition and poll
                  until it reports confirmed-unencrypted before calling reagentc /enable.
                  Expect up to 300s of additional runtime on the next production run.
```

```
  Classification: could not parse manage-bde output
                  Production's Set-RecoveryPartitionReadyForWinRE will retry the query.
```

The harness remains read-only: it does not assign a drive letter. If the target partition already carries a drive letter, that letter is used for the `manage-bde -status` query. If it does not, `manage-bde` is invoked against the volume's `UniqueId` (the `\\?\Volume{...}\` form), which `manage-bde` accepts as a `<volume>` argument.

The block is informational, not a PASS/FAIL/SKIP record. It does not appear in the summary.

#### Windows Setup state (v13)

The diagnostic reads `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` → `ImageState` and warns when the value is present and not `IMAGE_STATE_COMPLETE`. Production's Audit Mode guard defers in that state before any state-modifying action. The diagnostic's check mirrors the guard so that a field engineer pre-flighting a freshly imaged machine sees the deferral condition before running production.

### Option S — State file parity check (v15)

Read-only. Recomputes the `DesiredStateId` production would compute right now — reading the live driver manifest, resolving the OEM package for this machine's vendor, and detecting VMD hardware presence — then reads the on-disk state file at `C:\Recovery\OEM\winre_state.json` and reports whether production would accept it or treat it as stale.

The output names the computed ID and the stored ID side by side, then prints one of two verdicts:

- **DSI MATCH.** Production will accept the state file. The other fast-path gates still apply: WinRE must be Enabled, exactly one recovery partition must exist on the OS disk, and the deployed WIM hash must match `CurrentImageHash`. The harness does not check those three conditions — Option 1 reports them.
- **DSI MISMATCH.** Production will treat the state file as stale and run the full-update path on the next scheduled run. This is expected on the first run after a `DesiredStateId` input change: `ScriptVersion`, `MANIFEST`, `OEMPACK`, CPU vendor/generation, or VMD presence. Subsequent runs take the fast path once the state file is rewritten.

If the state file does not exist, the harness reports that production will take the full-update path (which is correct: `needInject = $true` when there is no state).

Option S is the field engineer's tool for answering "is this machine about to rebuild?" without running the production script.

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

- **Check 3 or 4 (manage-bde regex).** Windows changed `manage-bde -status` output format on this build. Production's `Test-VolumeEncrypted` will return `$null`; `Set-RecoveryPartitionReadyForWinRE` will treat the target partition as indeterminate and either retry the query once or proceed to run `manage-bde -off` against it. The machine is safe but the target preparation may take longer than expected.
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

The BitLocker, target-partition, `ImageState`, and Option S outputs are informational. They do not produce PASS/FAIL/SKIP records and do not appear in `Show-Summary`.

## Non-interactive mode

```powershell
.\scripts\Test-WinRE.ps1 -NonInteractive
```

Runs `Invoke-AllRelevant`, prints the summary, exits.

`-NonInteractive` runs the download and extraction tests. It does not run the System Diagnostic (Option 1) or the State file parity check (Option S), so the BitLocker warnings, the target-partition state block, the `ImageState` check, and the DSI comparison are not printed in this mode. If you need any of those, run the harness interactively and choose Option 1 or Option S.

The exit code is always 0, regardless of results. The summary is the source of truth. If a pipeline consumer is added later, the minimal change to make the exit code reflect pass/fail is to count FAIL records in `$Script:Results` and exit non-zero when any exist. This is documented in the v11 changelog but not implemented, on the grounds that no consumer currently needs it.

## What the harness does not test

The harness is deliberately narrow. It does not and cannot test:

- **Partition creation, deletion, or resize.** No destructive operations.
- **BitLocker preparation or decryption.** No state changes. The BitLocker sections of the diagnostic query `Get-BitLockerVolume` and `manage-bde -status` directly and do not call into production's `Set-RecoveryPartitionReadyForWinRE` or `Test-VolumeEncrypted`.
- **`reagentc /setreimage` or `reagentc /enable`.** No WinRE registration changes.
- **State file or checkpoint file writes.** Those files are production-only artifacts. Option S reads the state file but does not modify it.
- **The full-update pipeline.** The harness exercises the download and extraction steps in isolation, not the pipeline.

Those paths are covered by field testing on representative hardware. See the "Field-tested hardware" table in the [README](../README.md).

## Differences from production

The harness shares code paths with production in the download, extraction, and CPU-generation helpers. It is documented in the file's own docstring which functions are "based on" the production versions and which are harness-specific.

Three known differences:

- **`Test-VmdDrivers` does not filter on VMD hardware presence.** Production skips manifest entries whose `requiredDevices` do not match anything on the machine. The harness intentionally does not — it validates every OS/CPU-eligible URL and extraction path from a single machine, regardless of installed hardware. This makes the harness a package validator, not a machine-specific compatibility test. The state-file parity check (Option S) *does* apply the hardware filter, because it is replicating production's DSI computation and production's DSI includes VMD presence.
- **The harness does not run production's BitLocker helper functions.** The BitLocker sections in the diagnostic query `Get-BitLockerVolume` and `manage-bde -status` directly and apply the same classification the production guard uses — hazardous, ambiguous, or safe — but they do not call `Set-RecoveryPartitionReadyForWinRE` or `Test-VolumeEncrypted`. This is intentional: the harness does not exercise production's BitLocker control flow, and a change to that control flow does not require a harness update to remain correct. The v14 update changed the warning text and added the target-partition state block, but did not change the classifier itself.
- **`Get-ThisMachineProfile` normalises manufacturer names identically to production, but is otherwise harness-specific.** Since v15 the manufacturer normalisation, the OS-detection method (Caption-based, not build-number-based), and the returned fields (including `Model`) all match production's `Get-HardwareObject` exactly, so the DSI computed by Option S is byte-identical to what production computes for the same inputs. The two helpers differ in that `Get-ThisMachineProfile` reads additional CIM data for the diagnostic and does not cache its result the way production's does.

## Adding a test

The harness is a single file. To add a test:

1. Write a function that follows the existing pattern: log via `Say`, record the result via `Record`.
2. Add a menu entry in `Show-Menu`.
3. Add a case to the `switch` in the main loop.
4. If the test should run as part of "all relevant for this machine," add it to `Invoke-AllRelevant`.

Do not add tests that modify the machine's state. The harness's contract with the operator is that it is read-only.

## Related documents

- [troubleshooting.md](troubleshooting.md) — how to use the diagnostic output to diagnose a failure, including the BitLocker hazard and target-partition recovery procedures.
- [driver-injection.md](driver-injection.md) — what the injection tests are actually testing.
- [deployment.md](deployment.md) — the Audit Mode precondition for production deployment.
- [state-and-idempotency.md](state-and-idempotency.md) — the `DesiredStateId` composition that Option S recomputes.
