# Testing

`Test-WinRE.ps1` is WinRE Manager's read-only test harness. It shows you what the production script would see on a machine, without changing anything, so you can confirm the machine is in a state production can work with before you deploy. This document explains how to run it, what each menu option does, and what the results mean.

## When to run the harness

Run `Test-WinRE.ps1` in any of the following situations:

- **Before deploying to a machine you have not touched before.** A single read-only scan tells you whether the machine is healthy, what state WinRE is in, and whether production would take the fast path or rebuild. Takes a few seconds.
- **Before deploying to a fleet.** Run it on one representative machine per vendor/model combination to confirm it agrees with your expectations, then push the scheduled task out. If a machine reports something unexpected, this is where you catch it.
- **After a Windows Update that might change tooling output.** A new build can change `manage-bde`, `reagentc`, or `Get-Partition` output format, or the shape of a `Get-Disk` / `Get-Volume` object. The parser self-test catches the drift before production runs against it, with a specific PASS/FAIL per dependency.
- **When production has exited with an unfamiliar error.** The diagnostic reproduces production's vantage point and reports each dependency check independently, so you can see exactly which step failed.
- **When you are evaluating the project.** A read-only run gives you a complete picture of what the tool does and what it looks at, without touching anything.

The harness requires no elevation and modifies nothing. It is safe to run on any machine, at any time, including on a machine you are about to hand to a user.

## What the harness is

An interactive PowerShell script that:

- Exercises the download and extraction paths of the production script against live sources.
- Runs a parser self-test against the local Windows tooling to verify that every regex and API dependency the production script relies on still produces the expected shape.
- Reports the state of the machine from the same vantage point the production script uses, including the BitLocker state of C:, the BitLocker state of the target recovery partition, and the Windows Setup `ImageState`.
- Recomputes the `DesiredStateId` production would compute right now and compares it to the on-disk state file, so a field engineer can see whether production would take the fast path or rebuild (Option S).
- Reports results as PASS / FAIL / SKIP.
- Modifies nothing. Does not touch partitions, BitLocker, WinRE registration, drive letters, or the state file. Does not require elevation.

It is the primary tool for pre-flight validation on an unfamiliar machine.

**Current version: v21.** The version history is:

- **v15** added the `DesiredStateId` mirror and the Option S state-file parity check, aligned with production v44 patch 1's DSI change.
- **v16** reworked the output: colour-coded values, aligned tables, free-space thresholds, and the `Write-Diag` / `Write-KV` diagnostic helpers.
- **v17** aligned the harness's network behavior with production v44 patch 5: `$NetworkTimeoutSeconds = 15` on every network call, the zero-byte download check restored to match production's ordering, and a note added to `Test-VmdDrivers` explaining why the harness exercises drivers production would skip. The output format is unchanged from v16.
- **v18** mirrors production v44 patch 6 and closes several harness-specific issues. See "v18 changes" below.
- **v19** corrects two Option S issues: the state-file-absent case now reports `SKIP` (not `PASS`) when the VMD query is indeterminate, and the header and DSI MATCH verdict wording no longer imply that DSI equality alone proves production will take the fast path. See "v19 changes" below.
- **v20** mirrors the v44 patch 7 cycle's type-coded active-location classifier (patch 3 of that cycle) and fixes the menu box alignment. See "v20 changes" below.
- **v21** corrects a DSI-mirror drift and adds `RepairAttempts` to the Option S display. See "v21 changes" below.

See the `.NOTES` block at the top of `scripts\Test-WinRE.ps1` for the complete per-version change list.

The harness has no mirror of v45 patch 1's shrink-first pipeline. It reads the machine's state and reports what production would do, but it does not simulate the destructive path or the plan. The shrink-first code paths are exercised on disposable VMs (see "v45 destructive-path regression" below), not through the harness.

### v21 changes

Two changes. This was a standalone harness correction not tied to a production release.

**1. DSI-mirror drift corrected.** The harness's `Get-DesiredStateId` mirror carried `[int]$ProductionScriptVersion = 44`, while production v45 patch 1 ships `$ScriptVersion = 45`. Because the harness computes the same seven-field recipe production does, its default was one version behind, and every comparison against a v45-written state file returned `DSI MISMATCH — production will treat the state file as stale` for a state file that production would actually accept. The default is now `45`, and the parameter-header comment names the version boundary explicitly: this default must be bumped whenever production's `$ScriptVersion` is bumped. The harness's own parser self-test (Check 15) still deliberately passes 44 and 43 to prove version-sensitivity; those values are unchanged.

**2. `Show-StateFileParity` displays the state file's `RepairAttempts` field.** The v44 patch 6 state file carries `RepairAttempts` alongside `PendingReboot`, `LastEnableResult`, and `EnableFailureAttempts`; the harness's parity display previously listed the other three but not this one. Purely additive; no existing display line changed.

### v20 changes

Two changes.

**1. The active-location classifier requires a type-coded partition on the OS disk for the DEDICATED verdict.** Mirrors production's active-location classifier change (patch 3 of the v44 patch 7 cycle). The previous harness logic computed a single `$isRec` flag from `GptType`-or-`MbrType`, and if that was `$false` it fell back to a `Get-Volume -Partition` label check that promoted a label-only match to `$isRec = $true`. The classifier now computes `$isTypedRecovery` and `$isLabelRecovery` separately, and the branches report:

- **`DEDICATED`** — the location resolves to a **type-coded** recovery partition on the OS disk (GPT recovery GUID `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}` or MBR type `0x27`). The verdict text now reads `DEDICATED (WinRE on type-coded recovery partition on the OS disk)`.
- **`OS-FALLBACK`** — the location resolves to the OS partition.
- **`RECOVERY-ON-SECONDARY`** — type-coded but on a non-OS disk (production forces a full rebuild).
- **`LABEL-ONLY`** — on the OS disk with a `Recovery`/`WINRE` label but no matching type code. Production does **not** treat this as DEDICATED; the fast path's count also excludes it, so production converges on the full-update path instead of the fast path.
- **`UNEXPECTED`** — neither of the above.

The `LABEL-ONLY` verdict is new in v20. Before v20, a machine whose reagentc-registered WinRE location was a Basic Data partition labelled "Recovery" would have been reported as `DEDICATED` by the harness, while production would have taken the full-update path. This was a false positive that could have misled a field engineer. Production's final-verification classifier (patch 4 of the v44 patch 7 cycle) has no direct harness equivalent and is not claimed; the harness classifies the reagentc-registered location, which is the active-location decision point.

**2. Menu box alignment fixed.** The menu box's border is 66 columns wide interior (plus the two border characters and two leading spaces). The three content rows — title, working directory, and detected — were each padded to values that did not equal `interior width minus the leading space`, so the closing border character was misaligned on two of the three rows. All three rows now pad their content to exactly 65 columns, truncating with an ellipsis if content overflows. Purely cosmetic; no functional change.

The output format for every other section is unchanged from v16.

### v19 changes

Two Option S corrections.

1. **Option S reports `SKIP` (not `PASS`) when the state file is absent and the VMD query is indeterminate.** Before v19, `Show-StateFileParity` checked for the state file's existence before consulting the VMD query result, and returned `PASS` with detail `no state file (rebuild expected)` whenever the file was missing. That was correct when VMD presence was determinable, but wrong when the VMD query had failed: production defers the entire run with `EXIT_WARNING` in that case rather than taking the full-update path, and the harness's `PASS` disagreed with what a live run would do. The missing-state-file branch now checks `$vmdQueryOk` and records `SKIP` with detail `No state file; VMD query indeterminate`. The existing `INDETERMINATE` / `SKIP` handling for the state-file-present case is unchanged.
2. **Option S wording clarified.** The header now reads "does the stored DesiredStateId match current inputs? This is not a full-flow simulation." The DSI MATCH verdict reads "the stored deployment ID matches current inputs" followed by a note that production separately evaluates WinRE state/location, recovery-partition count, active WIM hash, pending-reboot/repair state, BitLocker, and other startup/flow gates before deciding what to do. The prior wording — "production will accept the state file" — implied that DSI equality alone was sufficient.

### v18 changes

v18 is a combined mirror of production v44 patch 6 and a set of harness-specific fixes. The mirror changes keep the harness's outputs in lockstep with production's actual behavior; the harness-specific fixes close issues that the harness's own review surfaced.

Mirror of production v44 patch 6:

1. **VMD query-failure handling.** Options 1 and S now treat a PnP enumeration error as an indeterminate result rather than absence. Option 1's VMD hardware presence section reports `INDETERMINATE` with the enumeration error message. Option S records `SKIP` in the results with reason `VMD query indeterminate` and prints an `INDETERMINATE` verdict instead of a DSI MATCH or DSI MISMATCH. Before v18, the harness could produce a "definitive" DSI that disagreed with what a live production run would compute, which is the opposite of what Option S is for.
2. **Lenovo map resolution status machine.** `Get-LenovoWinPEPack` in the harness now sets `$Script:LenovoPackResolution` to the same five states as production. `Test-OemMaps` distinguishes `malformed-entry` (red, marks the test failed) from `no-entry` (gray, informational), and treats `map-unavailable` (yellow, marks the test failed) separately from both.

Harness-specific fixes:

3. **`Get-DriverManifest` extracted as a shared helper.** Options 2, 9, and S now all use the same two-attempt / 2-second-sleep / WARN-log retry policy that production uses. Previously each option had its own fetch code, and they had drifted from each other and from production.
4. **Cleanup footgun closed.** The harness refuses to delete `$TestDir` on exit when the directory pre-existed the run and already contained entries. The pre-existing state is captured before any directory work. This prevents `Remove-Item $TestDir -Recurse -Force` from wiping a user-supplied path like `C:\Users\Me\Desktop`.
5. **Stale extraction destinations are cleared before each extraction.** Applies to `Invoke-VendorExtraction`, `Invoke-CabExtraction`, and the GitHub base-WIM test's working directory. Before v18, a stale INF file left by an earlier run could satisfy a failed extraction's INF-count success check. The Lenovo "non-zero exit but INFs present" branch was the sharpest case: it treats an INF-count greater than zero as success regardless of the extractor's exit code, so a stale INF could mask a genuine extraction failure.
6. **`Test-VmdDrivers` records SKIP (not PASS) when the Intel CPU generation cannot be parsed.** Driver applicability was not evaluated in that case, so a PASS would misrepresent what the harness actually checked. The raw CPU string is logged so the parser can be extended. The result detail reads `Intel CPU generation could not be parsed`.

Five new parser self-test checks (see "The parser self-test" below):

7. **DISM cmdlet availability.** Verifies `Mount-WindowsImage`, `Dismount-WindowsImage`, `Get-WindowsImage`, `Add-WindowsDriver`, and `Get-WindowsDriver` are all present. Production hard-depends on all five; a missing cmdlet would only be discovered at injection time.
8. **`Get-Disk` shape.** Verifies `Number`, `FriendlyName`, `PartitionStyle`, `Size`, `BootFromDisk`, `IsSystem`, and `IsBoot` are present.
9. **`Get-Volume` shape.** Verifies `DriveLetter`, `FileSystemLabel`, `FileSystem`, `Size`, `SizeRemaining`, `DriveType`, `HealthStatus`, and `UniqueId` are present.
10. **CPU-generation parser regression table.** Fourteen cases spanning 11th, 12th, 13th Gen, Core, Core Ultra, AMD, Celeron, Pentium, Xeon, and Atom CPU strings. Catches a Windows update or firmware rename that changes `Win32_Processor.Name` in a way that would silently desynchronise `DesiredStateId`.
11. **`DesiredStateId` determinism and input sensitivity.** Same inputs must hash identically; flipping VMD presence must change the hash; flipping `ProductionScriptVersion` must change the hash; the output must be 64 hex characters. A silent change to the DSI recipe would be caught before it desynchronised every deployed state file.

Cosmetic fixes:

12. **`Write-KV` overflow handling.** A key at or past `$KeyWidth` now gets a separating space before its value. Previously, `Manifest VMD device IDs` (23 chars, one over the 22-char key column) rendered flush against the value.
13. **Changelog "Four" → "Five"** for the count of future-proofing checks (the v18 changelog miscounted).
14. **Changelog "in the detail" → "in the log line"** for the `Test-VmdDrivers` SKIP path (the raw CPU string is logged via `Say`, not recorded in `Record -Detail`).

The output format is unchanged from v16 in every respect except the new colour tagging for the v18 checks and the new `INDETERMINATE` verdict colouring in Option S.

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

**Cleanup guard (v18).** The harness refuses to delete `$TestDir` on exit when the directory pre-existed the run and already contained entries. This closes a footgun: before v18, passing `-TestDir C:\Users\Me\Desktop` and then choosing "no" at the cleanup prompt would have deleted the entire desktop directory. The pre-existing state is captured before any harness directory work; a directory that did not exist, or that existed but was empty, is deleted on exit as before. To override the guard, delete the directory manually or pass `-Keep`.

## Output style (v16; format unchanged in v17 through v21 except for the v20 menu box alignment)

As of v16 the harness's output is colour-coded and, in several sections, tabular. The changes are presentation-only: the checks, the menu structure, the arguments, and the read-only contract are unchanged. v17, v18, v19, and v21 do not modify the output format. v20 changes only the menu box's interior alignment; every other section's output format is unchanged.

### Colour-coded values

Diagnostic values are rendered with a colour that reflects their state:

- **Free space on Fixed volumes.** Red when the free space is below 5% **or** below 3 GB. Yellow when it is below 15% **or** below 20 GB. Green otherwise. The rules apply to Fixed volumes only; CD-ROM volumes render DarkGray and Removable volumes render Cyan, because their free space is not a deployment constraint.
- **PASS / FAIL / SKIP results.** Rendered in green, red, and dark gray respectively — in `Say` (via the `-Level` mapping), in the parser self-test's `[OK]` / `[FAIL]` / `[SKIP]` tags, and in `Show-Summary`'s per-result lines and totals.
- **BitLocker state on C:.** The `VolumeStatus` value is green when it reads `FullyDecrypted` and yellow for every other reported value; the `ProtectionStatus` value is green when it reads `On` and gray otherwise. When the state is hazardous (the four mid-operation `VolumeStatus` values with `ProtectionStatus` not `On`) or ambiguous (`FullyEncrypted` with `ProtectionStatus` not `On`), the diagnostic prints an additional warning block below the values, in yellow. The warning blocks are the field engineer's cue that production's OS-fallback route will defer on this machine.
- **OS volume free-space banner.** When the OS volume's free space falls into the Red or Yellow band, the harness draws a boxed warning banner above the disk tables. The Red banner's headline is `LOW DISK SPACE ON OS VOLUME`; the Yellow banner's headline is `OS VOLUME FREE SPACE IS LOW`. The banner body names the exact free/total figures and a short recommendation. The banner is yellow for the Yellow band and red for the Red band.
- **VMD hardware presence (v18).** The line reads `VMD hardware present  True` or `VMD hardware present  False` on a successful enumeration, and `VMD presence  INDETERMINATE` with the enumeration error below it on a failed one. The indeterminate state renders in yellow.
- **Option S verdict (v18).** DSI MATCH is green, DSI MISMATCH is yellow, and INDETERMINATE is yellow with a paragraph explaining that a live production run would defer rather than commit state.
- **Classifier verdict (v20).** `DEDICATED` is green, `OS-FALLBACK` is yellow, `RECOVERY-ON-SECONDARY` is yellow, `LABEL-ONLY` is yellow, and `UNEXPECTED` is red. The `LABEL-ONLY` colouring matches `OS-FALLBACK` and `RECOVERY-ON-SECONDARY` because the machine is not in a fatal state — production will simply take the full-update path on the next run rather than the fast path — but it is not the healthy DEDICATED state either.

### Tables

The **All disks**, **All partitions**, **All volumes**, and **Recovery partitions** sections of Option 1 render as aligned tables with fixed column headers. Each row is colour-coded by relevance: the OS partition and OS disk stand out in White, the reagentc-registered recovery partition stands out in Cyan, and other rows render Gray. Recovery-partition rows are further colour-coded green when the partition is both type-coded and on the OS disk, yellow when type-coded but on a secondary disk, and red when it is not type-coded at all.

The remaining sections — hardware, reagentc raw output, WinRE parsed state, OS partition / OS disk, OS partition supported sizes, bucket sizing preview, Windows Setup state, BitLocker on C:, target recovery partition state, VMD hardware presence, and the parser self-test — render as aligned key/value pairs or as free-form diagnostic lines. The parser self-test in particular is line-per-check: one `[OK]` / `[FAIL]` / `[SKIP]` line per check, with the state tag colour-coded.

### `Write-Diag` and `Write-KV`

Diagnostic output in Option 1 and its sub-sections uses two helpers:

- **`Write-Diag`** — writes a single line, with an optional `-Color` parameter. The caller chooses the colour; the function does not infer a colour from a severity level. Used for free-form diagnostic text and section headers.
- **`Write-KV`** — writes an aligned key/value pair, with a `-KeyWidth` (default 22) and a `-ValueColor`. The key column renders DarkGray, the value column takes the caller's colour. As of v18, a key at or past `$KeyWidth` gets a separating space before its value rather than being rendered flush against it.

These replace direct `Say` calls in the diagnostic output. Download and extraction tests, the menu, and top-level banners continue to use `Say` and `Rule`.

`Say` colour-codes by `-Level`: `INFO` Gray, `WARN` Yellow, `ERROR` / `FATAL` Red, `PASS` / `OK` Green, `FAIL` Red, `SKIP` DarkGray, `HEAD` Cyan.

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

The menu renders the shortcut letter in colour, defaulting to Cyan. The state-file parity check (`S`) renders in Magenta, the aggregate runs (`A`, `B`) in Green, the summary (`R`) in Yellow, and quit (`Q`) in Red. The colour choice is a visual hint, not a semantic change to the option.

### Option 1 — System diagnostic

Read-only information gathering. Dumps:

- Hardware: manufacturer, model, product name/version, baseboard, CPU, OS build, Intel generation.
- Raw `reagentc /info` output and the parsed status/location.
- The WinRE classifier verdict: `DEDICATED`, `OS-FALLBACK`, `RECOVERY-ON-SECONDARY`, `LABEL-ONLY`, or `UNEXPECTED`. As of v20 this mirrors the v44 patch 7 cycle's rule: only a **type-coded** recovery partition on the OS disk reaches `DEDICATED`. A label-only match on the OS disk gets its own `LABEL-ONLY` verdict.
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
- VMD hardware presence per manifest (fail-closed as of v18: an enumeration error reports `INDETERMINATE`).

Then it runs the parser self-test (below).

#### BitLocker (C:) warnings (v12, updated in v14)

The BitLocker section of the diagnostic distinguishes two categories of state on C: that are relevant to the OS-fallback route. Both produce a warning block, in yellow.

**Hazardous states.** When the section reports `ProtectionStatus` not `On` together with a `VolumeStatus` of `EncryptionInProgress`, `DecryptionInProgress`, `EncryptionPaused`, or `DecryptionPaused`, the harness prints:

```
  WARNING: ProtectionStatus=Off, VolumeStatus=EncryptionInProgress
           Device Encryption is actively encrypting or decrypting C:.
           Production refuses the OS-fallback path in this state.
           The enable-only and dedicated-partition paths are still
           available because they target the recovery partition.
```

**Ambiguous state.** When the section reports `ProtectionStatus` not `On` together with `VolumeStatus=FullyEncrypted`, the harness prints a distinct block:

```
  WARNING: ProtectionStatus=Off, VolumeStatus=FullyEncrypted
           This state is ambiguous: legitimate suspension, OR
           Device Encryption Waiting-for-Activation.
           Production refuses the OS-fallback path in this state.
```

The wording of these warnings was updated in harness v14. The v12/v13 wording said production "will refuse destructive partition work" in these states, which described the removed OS-volume-gate policy and would have told a field engineer to defer a run that production would actually succeed on. Under the v43 patch 5 (further revision 5) policy, only the OS-fallback route depends on C:'s BitLocker state; the enable-only and dedicated-partition routes target the recovery partition directly and are not affected. As of v44 patch 6, the destructive partition path does not consult C:'s state either — only the OS-fallback route does.

**Confirmed-safe states.** `VolumeStatus=FullyDecrypted` (or empty) with `ProtectionStatus=Off`, and `ProtectionStatus=On` at any conversion status, are safe for the OS-fallback route. They do not trigger either warning.

The classification predicate matches production's `Test-VolumeEncrypted`: the four mid-operation states are hazardous, `FullyEncrypted+Off` is ambiguous, and everything else is safe. The harness does not call into production's `Test-VolumeEncrypted` — it queries `Get-BitLockerVolume` directly and applies the same predicate — but a diagnostic that disagreed with production about which states are hazardous, ambiguous, or safe would be worse than no diagnostic at all.

#### Target recovery partition state (v14)

The v43 patch 5 (further revision 5) policy is target-volume-based. reagentc's BitLocker check is on the partition it is being asked to enable WinRE on, not on C:. The harness reports the BitLocker state of the partition reagentc is registered to. This is the state that determines whether the production script will need to run `manage-bde -off` on the target partition before calling `reagentc /enable`, and whether `Set-RecoveryPartitionReadyForWinRE` will find the partition already clean or need to prepare it.

The section header is drawn with a divider, then the details are printed as aligned key/value pairs. The diagnostic prints one of the following four classifications, depending on what `manage-bde -status` reports for the target partition.

**Unmanaged by BitLocker.** The partition is not managed by BitLocker — this is the expected state for a properly-typed recovery partition. The block reads:

```
  Target recovery partition state
  ────────────────────────────────
  Registered partition  Disk <n> Part <m>
  Querying              manage-bde -status <letter or volume GUID>
  Classification        unmanaged by BitLocker (reagentc /enable will accept this)
```

**Fully decrypted.** BitLocker manages the partition, but it is currently unencrypted. Also acceptable.

```
  Target recovery partition state
  ────────────────────────────────
  Registered partition  Disk <n> Part <m>
  Querying              manage-bde -status <letter or volume GUID>
  Classification        fully decrypted (reagentc /enable will accept this)
```

**BitLocker-managed.** The partition is encrypted or actively encrypting. Production will decrypt it in place before calling `reagentc /enable`; the harness prints the conversion status and a note about the expected additional runtime.

```
  Target recovery partition state
  ────────────────────────────────
  Registered partition  Disk <n> Part <m>
  Querying              manage-bde -status <letter or volume GUID>
  Conversion Status     <value>
  Classification        BitLocker-managed - production will decrypt in place
                  Expect up to 300s of additional runtime on the next run.
```

Note: the final `Expect up to 300s` line uses a shallower indent than the value column above it. That is a known cosmetic quirk in harness v16 and does not indicate a problem with the diagnostic. A future harness version may tidy the alignment.

**Could not parse.** `manage-bde -status` produced output the harness did not recognise. Production's helper retries the query at runtime.

```
  Target recovery partition state
  ────────────────────────────────
  Registered partition  Disk <n> Part <m>
  Querying              manage-bde -status <letter or volume GUID>
  Classification        could not parse manage-bde output
```

When WinRE is not registered to a partition at all — the common case on a machine where WinRE is Disabled and no registered location exists — the section prints:

```
  Target recovery partition state
  ────────────────────────────────
  WinRE is not registered to a partition (Disabled, or unresolved).
  If the plan is OS-fallback, production checks C: directly.
```

The harness remains read-only: it does not assign a drive letter. If the target partition already carries a drive letter, that letter is used for the `manage-bde -status` query. If it does not, `manage-bde` is invoked against the volume's `UniqueId` (the `\\?\Volume{...}\` form), which `manage-bde` accepts as a `<volume>` argument.

The block is informational, not a PASS/FAIL/SKIP record. It does not appear in the summary.

#### VMD hardware presence (v18)

The VMD section runs the same `Get-PnpDevice` query that production uses, with the same fail-closed semantics. Three outcomes:

- **Manifest has no `requiredDevices` patterns.** The section prints `(manifest has no requiredDevices patterns - VMD not applicable)`. This is informational.
- **Enumeration succeeded.** The section prints the matching device count and a `VMD hardware present  True/False` line, colour-coded.
- **Enumeration failed (indeterminate).** The section prints `VMD presence  INDETERMINATE` with the enumeration error message, and a note that production would defer rather than assume absence. Colour-coded yellow.

The `INDETERMINATE` outcome is new in v18 and mirrors production v44 patch 6.

#### Windows Setup state (v13)

The diagnostic reads `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` → `ImageState` and warns when the value is present and not `IMAGE_STATE_COMPLETE`. Production's Audit Mode guard defers in that state before any state-modifying action. The diagnostic's check mirrors the guard so that a field engineer pre-flighting a freshly imaged machine sees the deferral condition before running production.

### Option S — State file parity check (v15; VMD handling and wording refined in v18, v19, and v21)

Read-only. Recomputes the `DesiredStateId` production would compute right now — reading the live driver manifest, resolving the OEM package for this machine's vendor, and detecting VMD hardware presence — then reads the on-disk state file at `C:\Recovery\OEM\winre_state.json` and reports whether production would accept it or treat it as stale.

The output names the computed ID and the stored ID side by side, then prints one of three verdicts:

- **DSI MATCH** (green). The stored deployment ID matches current inputs. The other fast-path gates still apply: WinRE must be Enabled, exactly one **type-coded** recovery partition must exist on the OS disk, and the deployed WIM hash must match `CurrentImageHash`. The harness does not check those three conditions — Option 1 reports them.
- **DSI MISMATCH** (yellow). Production will treat the state file as stale and run the full-update path on the next scheduled run. This is expected on the first run after a `DesiredStateId` input change: `ScriptVersion`, `MANIFEST`, `OEMPACK`, CPU vendor/generation, or VMD presence. Subsequent runs take the fast path once the state file is rewritten.
- **INDETERMINATE** (yellow, v18). The VMD hardware presence check could not complete because of a PnP enumeration error, so the correct driver set cannot be determined and the DSI cannot be computed with confidence. A live production run would defer with `EXIT_WARNING` before committing any state rather than take either the fast path or the full-update path. The harness records `SKIP` in the results with reason `VMD query indeterminate` and prints a paragraph explaining the situation. Resolve the PnP service issue and re-run.

If the state file does not exist, the harness reports that production will take the full-update path (which is correct: `needInject = $true` when there is no state) — except when the VMD query is also indeterminate, in which case the harness records `SKIP` and explains that a live production run would defer rather than start the update (v19).

As of v21 the parity display also includes the state file's `RepairAttempts` field alongside `PendingReboot`, `LastEnableResult`, and `EnableFailureAttempts`. Before v21 the display omitted this field even though the state file carries it; a field engineer diagnosing a pending-reboot loop had to read the JSON directly.

Option S is the field engineer's tool for answering "is this machine about to rebuild?" without running the production script. It does not exercise the offline fallback (v44 patch 5): Option S always performs a live manifest fetch and a live VMD detection, so on an offline machine the harness reports the fetch failure rather than a DSI verdict.

### Options 2 through 9 and A/B

Exercise the download and extraction paths. Each option:

- Downloads the source.
- Extracts with the appropriate tool.
- Counts INF files for driver packs.
- For WIM downloads, extracts the WIM and reads its build with `Get-WindowsImage`.

Option A runs the subset relevant to the current machine (its OS, its vendor, its CPU). Option B runs everything.

## The parser self-test

Fifteen checks as of v18 (ten before v18). Each records PASS, FAIL, or SKIP in `$Script:Results` and prints one `[OK]` / `[FAIL]` / `[SKIP]` line. The state tags are colour-coded (green `[OK]`, red `[FAIL]`, dark gray `[SKIP]`); the line format itself is unchanged from earlier versions. v19, v20, and v21 did not change the check count or the check contents.

| # | Check | What it verifies | Since |
|---|---|---|---|
| 1 | reagentc status regex | `(Enabled\|Disabled)` matches at least one line of `reagentc /info` output. | v1 |
| 2 | reagentc location regex | `(GLOBALROOT\|Volume GUID)` matches at least one line. | v1 |
| 3 | manage-bde protection regex | `Protection On` or `Protection Off` appears. | v1 |
| 4 | manage-bde conversion status regex | A `Conversion Status:` value matches, **or** the string `could not be opened by BitLocker` appears. | v1 |
| 5 | Get-BitLockerVolume shape | `ProtectionStatus` and `VolumeStatus` are non-null. SKIP if not elevated. | v1 |
| 6 | OS resolution | `Get-OSPartition` and `Get-OSDisk` both resolve. | v1 |
| 7 | Get-Partition shape | A sample partition exposes `DiskNumber`, `PartitionNumber`, `Size`, `GptType`, `MbrType`, `IsBoot`, `IsSystem`, `IsActive`. | v1 |
| 8 | WinRE location resolution | The reagentc location resolves to a partition. SKIP if location is empty. | v1 |
| 9 | Get-RecoveryPartitions | Returns at least one partition. | v1 |
| 10 | Get-PartitionSupportedSize | Returns `SizeMin` and `SizeMax`. SKIP if no OS partition. | v1 |
| 11 | DISM cmdlets | `Mount-WindowsImage`, `Dismount-WindowsImage`, `Get-WindowsImage`, `Add-WindowsDriver`, `Get-WindowsDriver` are all present. | v18 |
| 12 | Get-Disk shape | `Number`, `FriendlyName`, `PartitionStyle`, `Size`, `BootFromDisk`, `IsSystem`, `IsBoot` are present. | v18 |
| 13 | Get-Volume shape | `DriveLetter`, `FileSystemLabel`, `FileSystem`, `Size`, `SizeRemaining`, `DriveType`, `HealthStatus`, `UniqueId` are present. SKIP if no lettered volume to sample. | v18 |
| 14 | CPU generation parser | Fourteen regression cases: 11th/12th/13th Gen, Core, Core Ultra, and negative cases for AMD/Celeron/Pentium/Xeon/Atom return the expected values. | v18 |
| 15 | DesiredStateId | 64-hex, deterministic across repeat calls, VMD-sensitive, ScriptVersion-sensitive. | v18 |

### What a FAIL means

A FAIL means the machine's Windows tooling no longer matches an assumption the production script relies on. The production script **may** silently misclassify state on this machine and must be adapted before deploying to it.

The most likely FAILs and their implications:

- **Check 3 or 4 (manage-bde regex).** Windows changed `manage-bde -status` output format on this build. Production's `Test-VolumeEncrypted` will return `$null`; `Set-RecoveryPartitionReadyForWinRE` will treat the target partition as indeterminate and either retry the query once or proceed to run `manage-bde -off` against it. The machine is safe but the target preparation may take longer than expected.
- **Check 7 (Get-Partition shape).** The `Storage` module is missing or reduced. Production's partition classification will fail.
- **Check 10 (Get-PartitionSupportedSize).** The shrink path will fail. The script will fall back to OS-fallback after the OS-shrink attempt, but this is a machine-specific failure that should be investigated.
- **Check 11 (DISM cmdlets).** A DISM cmdlet is missing. Production's driver-injection path cannot run on this machine at all; the pipeline gate will fire on every full-update pass and the machine will never take the fast path unless it is already in the fast-path state.
- **Check 12 or 13 (Get-Disk / Get-Volume shape).** A property production reads has been removed or renamed. Production may misclassify a disk or a volume.
- **Check 14 (CPU generation parser).** A CPU string no longer parses to the expected generation. `DesiredStateId` will contain a different `CPU=` value than intended, which will force a rebuild on machines whose state file was written under the previous parse. Investigate the raw CPU string (the diagnostic's Hardware section reports it) and extend the parser.
- **Check 15 (DesiredStateId).** The DSI recipe has changed silently — a field dropped from the hash, or the output is no longer deterministic. This is a production correctness bug; do not deploy production to a fleet until the recipe is fixed.

### What a SKIP means

A SKIP means the check could not run in the current context. The reasons:

- **Not elevated.** `Get-BitLockerVolume` requires elevation on some machines. The check SKIPs rather than FAILing.
- **The state it inspects is absent.** WinRE location is empty, no OS partition, no lettered volume to sample, or similar. The check has nothing to inspect.
- **A precondition was not met.** `Test-VmdDrivers` (not a parser check) records SKIP when the Intel CPU generation cannot be parsed, because driver applicability was not evaluated. Option S records SKIP when the VMD query is indeterminate, because the DSI parity verdict cannot be computed from an indeterminate driver-set determination.

A SKIP does not indicate a defect.

## Result states

Every test records a result via `Record`:

```powershell
Record -Test "<name>" -Ok $true   -Detail "<description>"                        # PASS
Record -Test "<name>" -Ok $false  -Detail "<description>"                        # FAIL
Record -Test "<name>" -Ok $false  -State "SKIP" -Detail "<reason>"               # SKIP
```

The legacy `-Ok` boolean is still supported: when `-State` is not supplied, the state is derived from `-Ok`. When `-State` is supplied it is authoritative, and `OK` is `$true` only for PASS.

`Show-Summary` prints each result, then the totals. The per-result state tags are colour-coded: green for `[PASS]`, red for `[FAIL]`, dark gray for `[SKIP]`. The totals on the last line are colour-coded: the pass count green when non-zero, the fail count red when non-zero else green, the skip count yellow when non-zero else dark gray.

```
Passed 8, failed 1, skipped 1 (of 10)
```

The BitLocker, target-partition, `ImageState`, and Option S outputs are informational — Option S records a result for the parity check itself but its intermediate verdict output is a separate thing. The BitLocker, target-partition, and `ImageState` blocks do not produce PASS/FAIL/SKIP records and do not appear in `Show-Summary`.

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
- **The program lock.** The harness does not acquire `C:\ProgramData\OEM\Logs\WinREManager.lock`. It is read-only and safe to run concurrently with a live production run, with another harness run, or with any number of other processes. Production's lock is a mutual-exclusion primitive for `WinRE.ps1` only; the harness deliberately does not participate in it.
- **The offline fallback.** The harness always performs a live manifest fetch. On an offline machine it will fail the manifest fetch and report the failure rather than exercising production's offline fast-path behavior. This is intentional: the harness is a download-and-extraction validator first, and the offline path is only reachable in production by design.
- **State file, checkpoint file, or deferral-marker writes.** Those files are production-only artifacts. Option S reads the state file but does not modify it.
- **The full-update pipeline.** The harness exercises the download and extraction steps in isolation, not the pipeline.
- **The v45 shrink-first pipeline.** The plan, the pre-shrink, the extension path, and the whole-layout assertion are all production-only code paths. See the "v45 destructive-path regression" section below for how they are tested.

Those paths are covered by field testing on representative hardware. See the "Field-tested hardware" table in the [README](../README.md).

## Differences from production

The harness shares code paths with production in the download, extraction, and CPU-generation helpers. It is documented in the file's own docstring which functions are "based on" the production versions and which are harness-specific.

Seven known differences:

- **`Test-VmdDrivers` does not filter on VMD hardware presence.** Production skips manifest entries whose `requiredDevices` do not match anything on the machine. The harness intentionally does not — it validates every OS/CPU-eligible URL and extraction path from a single machine, regardless of installed hardware. This makes the harness a package validator, not a machine-specific compatibility test. As of v17, the harness prints an explicit three-line note before the driver loop explaining this. The state-file parity check (Option S) *does* apply the hardware filter, because it is replicating production's DSI computation and production's DSI includes VMD presence.
- **The harness does not run production's BitLocker helper functions.** The BitLocker sections in the diagnostic query `Get-BitLockerVolume` and `manage-bde -status` directly and apply the same classification the production guard uses — hazardous, ambiguous, or safe — but they do not call `Set-RecoveryPartitionReadyForWinRE` or `Test-VolumeEncrypted`. This is intentional: the harness does not exercise production's BitLocker control flow, and a change to that control flow does not require a harness update to remain correct. The v14 update changed the warning text and added the target-partition state block, but did not change the classifier itself.
- **`Get-ThisMachineProfile` normalises manufacturer names identically to production, but is otherwise harness-specific.** Since v15 the manufacturer normalisation, the OS-detection method (Caption-based, not build-number-based), and the returned fields (including `Model`) all match production's `Get-HardwareObject` exactly, so the DSI computed by Option S is byte-identical to what production computes for the same inputs. The two helpers differ in that `Get-ThisMachineProfile` reads additional CIM data for the diagnostic and does not cache its result the way production's does.
- **Network behavior is aligned with production as of v17.** Every `Invoke-RestMethod` and `Invoke-WebRequest` call in the harness carries `-TimeoutSec $NetworkTimeoutSeconds` where `$NetworkTimeoutSeconds = 15`. Before v17, the harness used PowerShell's default ~100-second timeout on each call, so a fully offline machine would take over 10 minutes to fail. The v17 alignment means the harness fails as fast as production does on a bad network. The `Invoke-OemPackDownload` helper's zero-byte check was also restored to match production's ordering: the length check now runs before the hash comparison, so a zero-byte download with an expected hash logs "file is empty" rather than "SHA256 mismatch". Both changes are correctness improvements that make the harness a more faithful replica of production's download path.
- **VMD query-failure handling, Lenovo resolution, and Option S wording are aligned with production as of v18 and v19.** The harness's VMD presence check now treats a PnP enumeration error as indeterminate (matching production v44 patch 6), and the harness's `Get-LenovoWinPEPack` now sets `$Script:LenovoPackResolution` to the same five states as production. Before v18, an enumeration error in the harness produced a definitive answer, and a malformed Lenovo map entry looked identical to a legitimate no-pack case. Both were drift risks: the harness could disagree with production about what a live run would do. v19 corrected two further Option S wording issues (the state-file-absent-and-VMD-indeterminate case now records `SKIP`; the header and DSI MATCH verdict no longer overstate what DSI equality proves).
- **The active-location classifier is aligned with production as of v20.** The harness's WinRE classifier now requires a type-coded recovery partition on the OS disk to reach the `DEDICATED` verdict, mirroring patch 3 of the v44 patch 7 cycle. Before v20, the classifier promoted a label-only match to `DEDICATED`, which could have reported `DEDICATED` for a machine whose registered location was a Basic Data partition labelled "Recovery" while production would have taken the full-update path. The harness's `LABEL-ONLY` verdict is informational and has no direct production equivalent; production's active-location classifier logs a WARN in the same situation without stopping.
- **The `DesiredStateId` mirror is aligned with production as of v21.** The harness's `Get-DesiredStateId` carries a `$ProductionScriptVersion` default that must track production's `$ScriptVersion`. It was pinned at 44 while production advanced to 45, which made every Option-S comparison against a v45-written state file report `DSI MISMATCH` incorrectly. The default is now 45, and the parameter-header comment states the tracking rule. Before v21, a field engineer running Option S against a machine that had been updated to v45 patch 1 would have seen a false "production will treat this state file as stale" verdict on a machine whose state file production would actually accept.

The harness has no mirror of the v45 shrink-first pipeline. Option 1 and Option S report the machine's current state and the DSI comparison, but they do not simulate the plan, the pre-shrink, the extension path, or the whole-layout assertion. That is by design: those paths are destructive and cannot be simulated read-only.

## v45 destructive-path regression (recommended)

The v45 patch 1 changes to `Ensure-AdequateRecoveryPartition` are the largest rework of the destructive path since v43. The reorder moves the shrink into the reversible window; the geometry model changes from deficit-plus-slack to single-boundary; the plan gains several validity checks; the deletion loop reorders the active partition last; a post-delete extension path with a safe fallback replaces the pre-delete extend; and a whole-layout assertion verifies the created partition's geometry. The happy path through these code paths has been exercised end-to-end on a disposable Hyper-V VM (2026-10-02 08:56).

The tests below split into two groups. The seven listed under "Paths that need coverage" are **recommended regression tests** — the shrink-first reorder closed the v44 residual for the shrink trigger, so these test behavior that is now expected to be safe, not a gate on shipping. The eighth test — "The post-deletion failure test" — exercises the one residual corner the project has not closed. It is a **gating test**: no future change to the post-deletion segment of `Ensure-AdequateRecoveryPartition` should ship until it has been run and its result recorded. See [CONTRIBUTING.md](../CONTRIBUTING.md) for the gate's scope.

See the `[v44 patch 7]` and `[v45 patch 1]` CHANGELOG entries and [architecture.md](architecture.md).

### Paths that need coverage

- **Pre-shrink failure.** All three shrink attempts fail; the script restores C: to its recorded original size, returns `Deferred` with `RetrySuppressible = $true`, preserves the existing route, and writes the deferral marker.
- **Post-delete extension failure.** The plan calls for extension into the freed space; the extension fails after three tries; the safe fallback places the recovery partition at the current C: end, sets `$Script:nonFatalWarning`, and continues with WinRE deployable. If the fallback size is too small, C: is restored and the function returns `$null`.
- **Whole-layout assertion.** `New-Partition` returns success but the actual geometry does not match the plan (wrong offset, wrong size, overlap, or a trailing extent that exceeds one alignment block); `Assert-RecoveryPartitionLayout` fires, `Remove-OrphanPartition` deletes the newly created partition, and the function returns `$null`.
- **Deletion-failure route restoration.** A deletion fails mid-loop while WinRE is disabled; the script restores C: to its original size, calls `Restore-PreviousWinRERoute`, and either returns `Deferred` (route restored) or `$null` (route not restorable). `Test-WinRELocationMatches` handles the GLOBALROOT-vs-Volume-GUID form difference.
- **Plan validation edge cases.** Each rejected layout (blocking non-recovery partition after C:, non-contiguous recovery partition, recovery-typed partition over 2 GiB, cross-disk inventory, insufficient aligned space) returns `Deferred` without touching WinRE or any partition.
- **Deferral marker lifecycle.** The marker is written on a retry-suppressible deferral; a subsequent run honors it while the route is functional and does not repeat the pre-shrink retries; a run where the fast path would fire clears the marker and exits `EXIT_SUCCESS`; a `DesiredStateId` change clears the marker on read.
- **MBR support.** The destructive path on an MBR disk uses `-MbrType 0x27` at creation and `set id=27` in `Set-RecoveryPartitionAttributes`. The MBR attribute-application branch was exercised on a Win10 MBR VM (2026-10-02 09:41, reuse path); the MBR destructive path has not been exercised on any storage.

### The post-deletion failure test (gating)

This test exercises the one residual corner the project has not closed: a failure of `New-Partition` or `Format-Volume` **after** the existing recovery partition has been deleted, on a machine whose C: is encrypted, with no successful retry. In that corner, `Remove-OrphanPartition` cleans up the newly created partition, `Restore-OSPartitionSize` restores C:'s geometry, the run falls through to OS-fallback, and the OS-fallback gate defers because C: is encrypted. The machine ends with neither a dedicated recovery partition nor OS-fallback.

The corner is documented in the `[v45 patch 1]` CHANGELOG entry, in [troubleshooting.md](troubleshooting.md) under "The OS-fallback route deferred because C: is encrypted", and in [architecture.md](architecture.md) as the residual failure mode the eventual post-failure check will close. **No future change to the post-deletion segment of `Ensure-AdequateRecoveryPartition` should ship until this test has been run and its result recorded.** See [CONTRIBUTING.md](../CONTRIBUTING.md) for the scope of the gate.

**Setup.**

- A disposable VM with Windows 11 24H2 or later and C: encrypted. The corner requires C: to be encrypted so the OS-fallback gate defers; the specific state can be `FullyEncrypted + Protection Off` (Waiting-for-Activation) or `EncryptionInProgress`. The state must not be `FullyDecrypted`.
- A type-coded recovery partition on the OS disk that the plan will delete. The partition must be smaller than the required bucket (so `Find-SuitableRecoveryPartition` rejects it and the destructive path is entered), or the state file must be absent or stale (so a rebuild is forced).
- A deterministic way to fail `New-Partition` or `Format-Volume` after the deletion loop. Mocking the cmdlet is the deterministic option; a storage-level failure, ACL denial, or filesystem-level write failure is the realistic option.
- Snapshot-restorable VM. The corner's end state is a machine with no working recovery route, so the VM must be discardable.

**Procedure.**

1. Snapshot the VM.
2. Apply the failure injection (mock `New-Partition`, mock `Format-Volume`, or arrange the storage-level condition that will cause the failure).
3. Run `WinRE.ps1`.
4. Capture the full log.

**Expected sequence.**

For a `New-Partition` failure:

```
[INFO] Pre-deletion inventory:
[INFO]   Disk 0 Part 4: size 1000 MiB, label='Recovery', used=... MiB, isWinRELocation=YES
…
[INFO] Confirmed deletion of partition 4 on disk 0
…
[WARN] New-Partition attempt 1 failed: …
[WARN] New-Partition attempt 2 failed: …
[WARN] New-Partition attempt 3 failed: …
[ERROR] New-Partition failed after 3 attempts
…
[ERROR] Returning null - main flow will attempt OS-partition fallback (C:\Recovery\WindowsRE).
…
[WARN] OS-fallback deferred: C: could not be confirmed fully decrypted (Test-VolumeEncrypted=True). …
```

For a `Format-Volume` failure, the analogous sequence: the deletion block, then `[ERROR] Format-Volume failed: …`, then `[INFO] Removing orphan partition …`, then the OS-fallback deferral.

In both cases, `Restore-OSPartitionSize` runs after the failure and restores C: to its recorded original size. The log should show the restore.

**Expected end state.**

- Exit code **2** (`EXIT_WARNING`).
- No recovery partition on the OS disk. `Get-Partition` shows only the EFI, MSR, and Windows partitions.
- WinRE reports `Disabled` (`reagentc /info`). The `reagentc /disable` call completed earlier in the sequence and there is no subsequent `/enable`.
- The fallback WIM at `C:\Recovery\WindowsRE\winre.wim` is present if a prior run had written it, absent otherwise. It is not re-deployed on this run.
- The state file at `C:\Recovery\OEM\winre_state.json` is unchanged from before the run (the fast-path rewrite is not reached because the pipeline aborted).
- No deferral marker at `C:\Recovery\OEM\winre_partition_deferred.json` — this corner is reached via the OS-fallback path, not via a pre-shrink deferral, so the marker is not written.

**What to record.**

- The machine setup (vendor/model if using a physical machine, but a Hyper-V VM is expected; Windows build; C: encryption state via `manage-bde -status C:`).
- Which cmdlet was forced to fail (`New-Partition` or `Format-Volume`) and the injection method.
- Whether the deletion loop completed before the failure.
- Whether `Restore-OSPartitionSize` ran and succeeded.
- Whether the OS-fallback gate deferred (identify the log line).
- The exact end state (the five points above).
- Whether the exit code is 2.
- Any divergence from the expected sequence above.

**Interpretation.**

**If the test confirms the corner fires as documented** — the log matches the expected sequence and the end state is as described — record the result. From that point the design of the fix (a post-failure check in the post-deletion segment, as the CHANGELOG entries describe) can proceed with real field data on the corner's exact signature and end state.

**If the test reveals behavior different from the documented corner** — different log sequence, different end state, or the corner does not fire at all — investigate before designing the fix. The documented behavior may need revision, and the CHANGELOG entry, this section, and [troubleshooting.md](troubleshooting.md) would need to be corrected to match observed behavior.

**If the failure injection does not reach the corner** — the run succeeds despite the injection, or fails earlier in the pipeline — the injection was not effective at the intended failure point. Adjust the injection and re-run.

### How to run these tests

Each test needs a different starting state. Use a snapshot-restorable VM; the destructive path is only safe in a disposable context.

- **Pre-shrink failure.** Delete the state file to force the full-update path, then force the planned `Resize-Partition` to fail while keeping the geometry plan valid. Mocking `Resize-Partition` is the deterministic option; a storage-level resize failure is the realistic one.
- **Post-delete extension failure.** Requires the plan to call for extension (the surplus case). Mock or force `Invoke-OSPartitionExtend`'s retries to fail and verify both branches: the fallback succeeds when the remaining extent is at least the bucket size, and returns `$null` when it is not.
- **Whole-layout assertion.** Mock `New-Partition` to return a partition at the wrong offset or size, or use a VM whose storage layout causes the resize to land off-boundary.
- **Deletion-failure route restoration.** Mock `Remove-Partition` to fail on a non-active partition while the active partition remains in the deletion list. Verify the active partition was deleted last and that `Restore-PreviousWinRERoute` was attempted.
- **Plan validation edge cases.** Construct each rejected layout on a VM's virtual disk and verify the plan returns `Deferred` with no partition or WinRE change.
- **Deferral marker lifecycle.** Run the pre-shrink failure test, re-run without fixing the constraint (the marker is honored), then mock the fast-path conditions to be met or fix the constraint so the machine converges (the marker is cleared and the run exits `EXIT_SUCCESS`).
- **MBR.** Set up an MBR VM with a type-coded recovery partition; run the full-update path and verify the created partition carries MBR type `0x27`.
- **Post-deletion failure.** See "The post-deletion failure test" above — the setup, procedure, expected sequence, end state, and recording requirements are all documented there.

### What to record when a test is run

For each test, record:

- The test name and the path being exercised.
- The machine setup (vendor, model, OS build, disk partition style, C:'s encryption state).
- Whether the intended branch fired (identify the log line).
- The end state: C: size, partition count, WinRE status, registered location.
- The exit code.
- Whether the deferral marker was written, honored, or cleared.
- Any divergence from the expected behavior.

If a divergence is found, report it as a bug with the test setup and the full log. The fix ships as its own patch, gated on the test that found it. For the post-deletion failure test, the fix is the gate the CHANGELOG entry describes.

## Adding a test

The harness is a single file. To add a test:

1. Write a function that follows the existing pattern: log via `Say`, record the result via `Record`.
2. Add a menu entry in `Show-Menu` using the `MenuItem` helper and pick a shortcut-letter colour from the palette already in use.
3. Add a case to the `switch` in the main loop.
4. If the test should run as part of "all relevant for this machine," add it to `Invoke-AllRelevant`.
5. If the test downloads anything, apply `-TimeoutSec $NetworkTimeoutSeconds` to every network call. The harness's `$NetworkTimeoutSeconds` is declared at the top of the file and matches production's value.

For diagnostic output added to Option 1 or its sub-sections, use `Write-Diag` for free-form lines and `Write-KV` for aligned key/value pairs. The caller chooses the colour in both cases; there is no automatic severity mapping. For values inside tables, follow the pattern of the surrounding table and pick a colour from the restricted palette (Gray, DarkGray, Cyan, Green, Yellow, Red, Magenta, White).

Do not add tests that modify the machine's state. The harness's contract with the operator is that it is read-only.

## Related documents

- [troubleshooting.md](troubleshooting.md) — how to use the diagnostic output to diagnose a failure, including the BitLocker hazard, VMD-query-indeterminate, and target-partition recovery procedures, plus the compound signature of the post-deletion corner.
- [driver-injection.md](driver-injection.md) — what the injection tests are actually testing.
- [deployment.md](deployment.md) — the Audit Mode precondition for production deployment and the one-instance-per-machine program lock.
- [state-and-idempotency.md](state-and-idempotency.md) — the `DesiredStateId` composition that Option S recomputes, the deferral marker's relationship to the deployment identity, and the offline fallback's residual risk.
- [recovery-partition.md](recovery-partition.md) — the full partition lifecycle that the v45 destructive-path regression tests exercise.
- [architecture.md](architecture.md) — the invariant list, the wrong-question narrative, and the sequencing-pattern note that the v45 reorder is the first instance of.
