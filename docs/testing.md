---
title: "Testing — WinRE Manager"
description: "Test-WinRE.ps1, the read-only harness for WinRE Manager: menu options, parser self-test, and the destructive-path regression tests."
---

# Testing

`Test-WinRE.ps1` is WinRE Manager's read-only test harness. It shows you what the production script would see on a machine, without changing anything, so you can confirm the machine is in a state production can work with before you deploy. This document explains how to run it, what each menu option does, and what the results mean.

The harness exists to serve the project's four design invariants, which [`architecture.md`](architecture.md) states in this order: **never break Windows RE**, **never leave a machine without a working recovery route**, **minimize the `reagentc /disable` → `reagentc /enable` window**, and **do no work unless needed; prepare everything before touching anything**. Two of those rules bear directly on the harness:

- **Rule 4 — do no work unless needed.** A read-only diagnostic is the lowest-work thing anyone can do to a machine. The harness exists so that a field engineer or a fleet operator can answer "is this machine healthy?" and "what would production do?" without mounting a WIM, touching a partition, or making a `reagentc` call. Rule 4 is the reason the harness is a first-class tool in the project, not a debugger.
- **Rule 1 — never break Windows RE.** The v45 and v46 destructive-path regression tests documented in this file exist to catch a regression before it reaches a fleet. A canary machine, a disposable VM, and a read-only harness are the three layers that make Rule 1 operational. The **post-deletion failure test** (gating) is the mechanism that will eventually close the one residual corner where Rule 2 — never leave a machine without a working recovery route — cannot be guaranteed.

## When to run the harness

Run `Test-WinRE.ps1` in any of the following situations:

- **Before deploying to a machine you have not touched before.** A single read-only scan tells you whether the machine is healthy, what state WinRE is in, and whether production would take the fast path or rebuild. Takes a few seconds.
- **Before deploying to a fleet.** Run it on one representative machine per vendor/model combination to confirm it agrees with your expectations, then push the scheduled task out. If a machine reports something unexpected, this is where you catch it.
- **After a Windows Update that might change tooling output.** A new build can change `manage-bde`, `reagentc`, or `Get-Partition` output format, or the shape of a `Get-Disk` / `Get-Volume` / `Get-PnpDevice` object. The parser self-test catches the drift before production runs against it, with a specific PASS/FAIL per dependency.
- **When production has exited with an unfamiliar error.** The diagnostic reproduces production's vantage point and reports each dependency check independently, so you can see exactly which step failed.
- **When you are evaluating the project.** A read-only run gives you a complete picture of what the tool does and what it looks at, without touching anything.

The harness requires no elevation and modifies nothing. It is safe to run on any machine, at any time, including on a machine you are about to hand to a user.

## What the harness is

An interactive PowerShell script that:

- Exercises the download and extraction paths of the production script against live sources.
- Runs a parser self-test against the local Windows tooling to verify that every regex and API dependency the production script relies on still produces the expected shape.
- Reports the state of the machine from the same vantage point the production script uses, including the BitLocker state of C:, the BitLocker state of the target recovery partition, the Windows Setup `ImageState`, and — as of v28 — the machine's present SCSIAdapter-class storage controllers with their HardwareID and CompatibleID sets.
- Recomputes the `DesiredStateId` production would compute right now and compares it to the on-disk state file, so a field engineer can see whether production would take the fast path or rebuild (Option S).
- Reports results as PASS / FAIL / SKIP.
- Modifies nothing. Does not touch partitions, BitLocker, WinRE registration, drive letters, or the state file. Does not require elevation.

It is the primary tool for pre-flight validation on an unfamiliar machine.

**Current version: v28.** The version history is:

- **v15** added the `DesiredStateId` mirror and the Option S state-file parity check, aligned with production v44 patch 1's DSI change.
- **v16** reworked the output: colour-coded values, aligned tables, free-space thresholds, and the `Write-Diag` / `Write-KV` diagnostic helpers.
- **v17** aligned the harness's network behavior with production v44 patch 5: `$NetworkTimeoutSeconds = 15` on every network call, the zero-byte download check restored to match production's ordering, and a note added to `Test-VmdDrivers` explaining why the harness exercises drivers production would skip. The output format is unchanged from v16.
- **v18** mirrors production v44 patch 6 and closes several harness-specific issues. See "v18 changes" below.
- **v19** corrects two Option S issues: the state-file-absent case now reports `SKIP` (not `PASS`) when the VMD query is indeterminate, and the header and DSI MATCH verdict wording no longer imply that DSI equality alone proves production will take the fast path. See "v19 changes" below.
- **v20** mirrors the v44 patch 7 cycle's type-coded active-location classifier (patch 3 of that cycle) and fixes the menu box alignment. See "v20 changes" below.
- **v21** corrects a DSI-mirror drift and adds `RepairAttempts` to the Option S display. See "v21 changes" below.
- **v22** mirrors production v46 patch 2's `Get-WinREState` version parsing, adds a parser self-test check for the version regex, and bumps the `$ProductionScriptVersion` default. See "v22 changes" below.
- **v23** mirrors production v47 patch 1's harness-side changes: `$ProductionScriptVersion` default bumped 46 → 47 and `Show-StateFileParity` now displays the state file's `DeployedWinREMetadata` field. See "v23 changes" below.
- **v24** mirrors production v47 patch 2 and closes two harness-specific gaps: the active-WIM diagnostic probe now matches production's dual-path resolver, and `Get-ThisMachineProfile` trims `Win32_ComputerSystemProduct.Version` to align with production's DSI computation. See "v24 changes" below.
- **v25** mirrors production v47 patch 3: `Remove-WindowsDriver` added to the DISM cmdlet availability check, `BusType` added to the `Get-Disk` shape check, `-NonInteractive` exits non-zero on any FAIL, `Test-OemMaps` guards the Lenovo call on vendor, `Compare-WimServicingMetadata` mirror and regression self-test added, and the Option S DSI-mismatch detail sentence names all seven components. See "v25 changes" below.
- **v26** adds a Plan adjacency preview to Option 1 - a read-only mirror of the geometric and partition-identity subset of production's `Get-PartitionPlan` rejection checks. See "v26 changes" below.
- **v27** mirrors production v48 patch 1: `$ProductionScriptVersion` default bumped 47 -> 48, `Get-LocalInputsId` mirror added and displayed in `Show-StateFileParity`, `Test-PlanAdjacencyReadOnly` extended to mirror v48's intervening-anchor handling, and `Architecture` added to `Get-ThisMachineProfile` and rendered with a red banner when the value is not `x64`. See "v27 changes" below.
- **v28** mirrors production v49: `$ProductionScriptVersion` default bumped 48 -> 49, `Get-StorageControllerDevices` mirror added, a new VMD storage-controller diagnostic added to Option 1, and a new parser self-test check for the `Get-StorageControllerDevices` shape. See "v28 changes" below.

See the `.NOTES` block at the top of `scripts\Test-WinRE.ps1` for the complete per-version change list.

The harness has no mirror of v45 patch 1's shrink-first pipeline. It reads the machine's state and reports what production would do, but it does not simulate the destructive path or the plan. The shrink-first code paths are exercised on disposable VMs (see "v45 destructive-path regression" below), not through the harness.

### v28 changes

Five changes, all downstream of the v49 cycle.

- **`$ProductionScriptVersion` default bumped 48 -> 49.** The harness's `Get-DesiredStateId` mirror carries this default to track production's `$ScriptVersion`. Left at 48 it would report a false `DSI MISMATCH` for every state file v49 production writes, the same class of drift the earlier bumps corrected. This is the fifth correction in the same family (v21, v22, v23, v27, v28).
- **`Get-StorageControllerDevices` mirror added.** Enumerates present SCSIAdapter-class devices and extracts the union of `HardwareID`, `CompatibleID`, and the `InstanceId` prefix up to the last backslash. Software and virtual controllers (`InstanceId` starting with `{GUID}\` or `SWD\`) are skipped, mirroring production's software-device filter. The mirror is used by the Option 1 VMD diagnostic and verified by the new parser self-test (Check 17).
- **New VMD diagnostic section added to Option 1.** The section enumerates the machine's controllers (friendly name, InstanceId, and the union of IDs), then the manifest's VMD patterns, then the match verdict, then an advisory when VMD presence is false but SCSIAdapter-class devices are present. The advisory names the exact ASUS-incident shape: a controller that exists on the machine and does not match any manifest VMD pattern.
- **New parser self-test check (Check 17) for the `Get-StorageControllerDevices` shape.** The three possible outcomes are handled distinctly: a NULL return (an indeterminate PnP enumeration) records FAIL, an empty array records SKIP (legitimate on some VMs), and a populated array is verified to have objects each carrying `FriendlyName`, `InstanceId`, and `Ids`.

Additionally, stale "v48" references in the architecture warning and the `Get-DesiredStateId` header comment were rewritten version-agnostically (they now say "production" rather than "production v48"); the over-indented `try {` in the `Compare-WimServicingMetadata` self-test was fixed; and the menu title and startup `Rule` were bumped to v28.

The parser self-test count moves from seventeen checks to eighteen with the `Get-StorageControllerDevices` check.

### v27 changes

Four changes, all downstream of the v48 patch 1 cycle.

- **`$ProductionScriptVersion` default bumped 47 -> 48.** The harness's `Get-DesiredStateId` mirror carries this default to track production's `$ScriptVersion`. Left at 47 it would report a false `DSI MISMATCH` for every state file v48 production writes, the same class of drift the earlier bumps corrected.
- **`Get-LocalInputsId` mirror added** and displayed in `Show-StateFileParity` alongside the computed and stored values. Production writes `LocalInputsId` to the state file and consults it on offline fallback; the harness surfaces a mismatch before it surprises an operator.
- **`Test-PlanAdjacencyReadOnly` now mirrors v48's intervening-anchor handling.** The Option 1 Plan adjacency preview detects the anchor, validates it against the same read-only rules production uses, and reports either acceptance (with the anchor identity) or rejection (with the specific anchor failure). Before this change the preview reported the `C: | D: | Recovery` layout as either OK or as an unconditional rejection that v48 production no longer produces when the anchor validates.
- **`Architecture` added to `Get-ThisMachineProfile`** and displayed in the System Diagnostic with a red banner when the value is anything other than `x64`. This surfaces production's v48 architecture-gate refusal on the harness side before an operator runs production on a non-x64 host.

The parser self-test count is unchanged from v25 (seventeen checks).

### v26 changes

One diagnostic addition, downstream of the production v47 patch 3 plan-rejection enrichment.

**Plan adjacency preview.** Option 1 now runs a read-only mirror of the geometric and partition-identity subset of production's `Get-PartitionPlan` rejection checks against the current layout. On a clean layout the section prints two green lines confirming the layout would not be rejected on the checks evaluated; on a separated-recovery or oversized-recovery layout it prints the enriched rejection reason(s) that production would log. The preview does not compute a bucket size or a planned extent, so the rejections related to planned-extent sizing are not evaluated. A clean preview is not a claim that the full plan would succeed, and the section says so explicitly. A new `Get-HarnessPartitionRef` helper renders a partition the same way production's `Format-PartitionRef` does.

The parser self-test count is unchanged. The preview is diagnostic and does not record a PASS/FAIL/SKIP result.

### v25 changes

Six functional changes and one comment set, all downstream of the production v47 patch 3 cycle. See the [v47 patch 3](../CHANGELOG.md) entry for the full context.

- `Remove-WindowsDriver` added to the DISM cmdlet availability check.
- `BusType` added to the `Get-Disk` shape check.
- `-NonInteractive` exits non-zero when any FAIL result is recorded.
- `Test-OemMaps` only calls `Get-LenovoWinPEPack` on Lenovo hardware.
- `Compare-WimServicingMetadata` mirror and eight-case regression self-test added - a new parser self-test check.
- Option S DSI-mismatch detail sentence names all seven `DesiredStateId` components.
- Comment-only clarifications in the classifier, `Get-DesiredStateId`, and `.DESCRIPTION`.

The parser self-test count moved from sixteen to seventeen with the `Compare-WimServicingMetadata` check.

### v24 changes

Two changes, both downstream of the v47 patch 2 cycle.

**1. The active-WIM diagnostic probe now matches production's dual-path resolver.** The prior code constructed `<registered-location>\Recovery\WindowsRE\winre.wim` unconditionally. That path is correct when `reagentc /info` returns a partition root, but doubles the path when it returns `...\Recovery\WindowsRE` (producing `...\Recovery\WindowsRE\Recovery\WindowsRE\winre.wim` and reporting the active WIM as missing when it is present). Production handles both forms via `Ensure-RecoveryPartitionAccess`, which returns a drive root or the subpath depending on which form the registered location was in. The harness now probes both forms in order (`<location>\Recovery\WindowsRE\winre.wim`, then `<location>\winre.wim`) and uses the first that resolves to a readable file.

**2. `Get-ThisMachineProfile` trims `Win32_ComputerSystemProduct.Version`.** Mirrors production's `Get-HardwareObject` change in v47 patch 2. Some vendors pad the field with trailing whitespace (observed: ASUS sets it to `"1.0 "`); without trimming, the harness's DSI mirror could compute a different `HW` component than production on such machines, causing a false Option-S mismatch.

### v23 changes

Three changes, all downstream of the v47 patch 1 cycle.

**1. `$ProductionScriptVersion` default bumped 46 → 47.** The harness's `Get-DesiredStateId` mirror carries this default to track production's `$ScriptVersion`. Left at 46 it would report a false `DSI MISMATCH` for every state file v47 production writes, exactly the drift v21 and v22 corrected for earlier bumps. The parameter-header comment continues to name the tracking rule. The harness's own parser self-test (Check 15) still deliberately passes 44 and 43 to prove version-sensitivity; those values are unchanged.

**2. `Show-StateFileParity` now displays `DeployedWinREMetadata`.** The state file's DISM servicing metadata anchor (v47 patch 1's `DeployedWinREMetadata` field, in `<Version>|<SPBuild>` form) renders in the parity output alongside `PendingReboot`, `LastEnableResult`, `EnableFailureAttempts`, and `RepairAttempts`. When present, it renders green. When absent (a v46-or-earlier state file), it renders yellow with a note that production v47 will force a rebuild on the next run because the drift detector has no anchor to compare against. Purely diagnostic; no production decision depends on the harness reading this field.

**3. Harness version string bumped 22 → 23** in the menu title and the startup Rule.

### v22 changes

Three changes, all downstream of the v46 patch 2 cycle.

**1. Mirrored production v46 patch 2's `Get-WinREState` version parsing.** The harness's `Get-WinREState` now extracts `Windows RE Version` from `reagentc /info` and returns it as `Version`. The parsed-state block in Option 1 reports the value alongside `Status` and `Location`, and a new "Build numbers" section renders the registered WinRE version, the active WIM build, and (when present) the backup WIM build at `C:\Recovery\WindowsRE\winre.wim`. This answers the operator's question "what builds are we about to replace?" before any destructive operation.

**2. New parser self-test check for the version regex.** `Parser: reagentc version` reports `[OK]` when the version line matches, `[FAIL]` when WinRE is Enabled and the line is missing, and `[SKIP]` when WinRE is Disabled or reagentc suppressed the line. The self-test total moves from fifteen checks to sixteen. The check mirrors production v46 patch 2's extraction logic: if the regex fails on a machine where WinRE is Enabled, the production log's `WinRE ... Version:` line will read `unknown`, which is a signal that the reagentc output format has shifted under both the harness and production.

**3. `$ProductionScriptVersion` default bumped 45 → 46.** The harness's `Get-DesiredStateId` mirror carries this default to track production's `$ScriptVersion`. Left at 45 it would report a false `DSI MISMATCH` for every state file v46 production writes, exactly the drift v21 corrected for the 44 → 45 case. The parameter-header comment continues to name the tracking rule. The harness's own parser self-test (Check 15) still deliberately passes 44 and 43 to prove version-sensitivity; those values are unchanged.

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
13. **Harness `.NOTES` block count "Four" → "Five"** for the count of future-proofing checks (the v18 harness `.NOTES` block miscounted).
14. **Harness `.NOTES` block wording "in the detail" → "in the log line"** for the `Test-VmdDrivers` SKIP path (the raw CPU string is logged via `Say`, not recorded in `Record -Detail`).

The output format is unchanged from v16 in every respect except the new colour tagging for the v18 checks, the five new parser self-test lines, and the new `INDETERMINATE` verdict colouring in Option S.

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

## Output style (v16; extended in v17 through v28, with v20's menu box alignment, v22's new Build numbers section, v23's Option S `DeployedWinREMetadata` display, v24's dual-path active-WIM probe and `Version` trim, v25's colour-tagged parser self-test additions and seven-component DSI-mismatch sentence, v26's Plan adjacency preview section, v27's `Architecture` line in the System Diagnostic and `LocalInputsId` in Option S, and v28's VMD storage-controller diagnostic section as the departures)

As of v16 the harness's output is colour-coded and, in several sections, tabular. The changes are presentation-only: the checks, the menu structure, the arguments, and the read-only contract are unchanged. v17, v18, v19, and v21 do not modify the output format. v20 changes only the menu box's interior alignment; every other section's output format is unchanged. v22 adds a `Version` line to the parsed-state block and a new "Build numbers" section. v23 adds a `DeployedWinREMetadata` line to Option S's parity output. v27 adds an `Architecture` line to the Hardware section of the System Diagnostic and a `LocalInputsId` pair to the Option S parity output. v28 adds the VMD storage-controller diagnostic block to the VMD hardware presence section of Option 1. The rest of the output format is unchanged from v16.

### Colour-coded values

Diagnostic values are rendered with a colour that reflects their state:

- **Free space on Fixed volumes.** Red when the free space is below 5% **or** below 3 GB. Yellow when it is below 15% **or** below 20 GB. Green otherwise. The rules apply to Fixed volumes only; CD-ROM volumes render DarkGray and Removable volumes render Cyan, because their free space is not a deployment constraint.
- **PASS / FAIL / SKIP results.** Rendered in green, red, and dark gray respectively — in `Say` (via the `-Level` mapping), in the parser self-test's `[OK]` / `[FAIL]` / `[SKIP]` tags, and in `Show-Summary`'s per-result lines and totals.
- **BitLocker state on C:.** The `VolumeStatus` value is green when it reads `FullyDecrypted` and yellow for every other reported value; the `ProtectionStatus` value is green when it reads `On` and gray otherwise. When the state is hazardous (the four mid-operation `VolumeStatus` values with `ProtectionStatus` not `On`) or ambiguous (`FullyEncrypted` with `ProtectionStatus` not `On`), the diagnostic prints an additional warning block below the values, in yellow. The warning blocks are the field engineer's cue that production's OS-fallback route will defer on this machine.
- **OS volume free-space banner.** When the OS volume's free space falls into the Red or Yellow band, the harness draws a boxed warning banner above the disk tables. The Red banner's headline is `LOW DISK SPACE ON OS VOLUME`; the Yellow banner's headline is `OS VOLUME FREE SPACE IS LOW`. The banner body names the exact free/total figures and a short recommendation. The banner is yellow for the Yellow band and red for the Red band.
- **VMD hardware presence (v18; extended v28).** The line reads `VMD hardware present  True` or `VMD hardware present  False` on a successful enumeration, and `VMD presence  INDETERMINATE` with the enumeration error below it on a failed one. The indeterminate state renders in yellow. As of v28 the section is preceded by the storage-controller enumeration block, whose entries render Cyan for the friendly name, DarkGray for the InstanceId, and Gray for each ID.
- **Storage controllers (v28).** The block names the count of SCSIAdapter-class devices, then one sub-block per device with the friendly name, the InstanceId, and the union of `HardwareID`, `CompatibleID`, and the InstanceId prefix. The block is followed by the manifest's VMD patterns and the match verdict. When VMD is not present but SCSIAdapter-class devices are present, an additional advisory block renders in yellow and names the ASUS-incident shape: the applicability gate production v49 will run immediately before deployment is the last check before the WIM is written to the active route.
- **Option S verdict (v18).** DSI MATCH is green, DSI MISMATCH is yellow, and INDETERMINATE is yellow with a paragraph explaining that a live production run would defer rather than commit state.
- **Classifier verdict (v20).** `DEDICATED` is green, `OS-FALLBACK` is yellow, `RECOVERY-ON-SECONDARY` is yellow, `LABEL-ONLY` is yellow, and `UNEXPECTED` is red. The `LABEL-ONLY` colouring matches `OS-FALLBACK` and `RECOVERY-ON-SECONDARY` because the machine is not in a fatal state — production will simply take the full-update path on the next run rather than the fast path — but it is not the healthy DEDICATED state either.

### Tables

The **All disks**, **All partitions**, **All volumes**, and **Recovery partitions** sections of Option 1 render as aligned tables with fixed column headers. Each row is colour-coded by relevance: the OS partition and OS disk stand out in White, the reagentc-registered recovery partition stands out in Cyan, and other rows render Gray. Recovery-partition rows are further colour-coded green when the partition is both type-coded and on the OS disk, yellow when type-coded but on a secondary disk, and red when it is not type-coded at all.

The remaining sections — hardware, reagentc raw output, WinRE parsed state, OS partition / OS disk, OS partition supported sizes, bucket sizing preview, Build numbers, Windows Setup state, BitLocker on C:, target recovery partition state, VMD hardware presence (with the v28 storage-controller block), and the parser self-test — render as aligned key/value pairs or as free-form diagnostic lines. The parser self-test in particular is line-per-check: one `[OK]` / `[FAIL]` / `[SKIP]` line per check, with the state tag colour-coded.

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

- Hardware: manufacturer, model, product name/version, baseboard, CPU, OS build, Intel generation, architecture token. As of v27, the architecture line renders with a red banner when the value is anything other than `x64`.
- Raw `reagentc /info` output and the parsed status/location.
- The WinRE classifier verdict: `DEDICATED`, `OS-FALLBACK`, `RECOVERY-ON-SECONDARY`, `LABEL-ONLY`, or `UNEXPECTED`. As of v20 this mirrors the v44 patch 7 cycle's rule: only a **type-coded** recovery partition on the OS disk reaches `DEDICATED`. A label-only match on the OS disk gets its own `LABEL-ONLY` verdict.
- OS partition and OS disk.
- All disks with `BootFromDisk`, `IsSystem`, `IsBoot`.
- All partitions with size, drive letter, label, GPT type, MBR type, and boot/system/active flags.
- All volumes with file system, free space, label, and health.
- Recovery partitions per `Get-RecoveryPartitions`, with `isTyped`, `isLabel`, and `onOsDisk` annotations.
- The OS partition's `SizeMin`, `SizeMax`, shrinkable bytes, extendable bytes, and `S == M` status.
- The bucket sizing preview: for the active WIM's size, what bucket the production script would compute.
- **The Plan adjacency preview (v26):** a read-only check that mirrors the geometric and partition-identity subset of production's `Get-PartitionPlan` rejection checks against the current layout. On a clean layout it reports that production would not reject the layout on the checks evaluated; on a separated-recovery or oversized-recovery layout it prints the enriched rejection reason(s). The preview does not compute a bucket size or a planned extent, so the planned-extent rejections are not evaluated. As of v27 the preview also mirrors v48's intervening-anchor handling and reports either acceptance with the anchor identity or rejection with the specific anchor failure.
- **The Build numbers block (v22):** the registered WinRE version (from `reagentc /info`), the active WIM build (from `Get-WindowsImage` on the registered WIM), and the backup WIM build (from `Get-WindowsImage` on `C:\Recovery\WindowsRE\winre.wim`, or `(none present)` when the file is absent).
- The Windows Setup state (`ImageState`), with a warning when the value is present and is not `IMAGE_STATE_COMPLETE`.
- BitLocker on C: (`ProtectionStatus`, `VolumeStatus`, `EncryptionMethod`, `EncryptionPercentage`), **plus a hazard warning for the four mid-operation states and a separate ambiguity warning for `Fully Encrypted + Protection Off`** (v12, warning text updated in v14).
- **The target recovery partition state** (v14): the BitLocker status of the partition reagentc is registered to. This is the state that determines whether the production script will need to run `manage-bde -off` before calling `reagentc /enable`.
- VMD hardware presence per manifest (fail-closed as of v18: an enumeration error reports `INDETERMINATE`). As of v28 the section is preceded by the storage-controller enumeration block described below.

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

#### Build numbers (v22)

The "Build numbers" section renders immediately after the bucket sizing preview and before the Windows Setup state. It reports three values side by side:

```
  Build numbers
  ─────────────
  Registered WinRE      10.0.26100.9545
  Active WIM build      26100
  Backup WIM build      26100  C:\Recovery\WindowsRE\winre.wim
```

- **Registered WinRE** is the value `reagentc /info` reports for `Windows RE Version`, extracted by the same regex the parser self-test verifies. When the line is absent (WinRE Disabled, or reagentc suppressed it), the value renders as `unknown (reagentc emitted no version line)`.
- **Active WIM build** is `Get-WindowsImage -ImagePath <registered WIM> -Index 1` `.Build`, where the registered WIM is resolved from the reagentc location. When the registered WIM cannot be read, the value renders as `unknown (active WIM not locatable)` in Gray.
- **Backup WIM build** is the same query against `C:\Recovery\WindowsRE\winre.wim`. When the file is not present — expected on a machine that has never run production — the value renders as `(none present at C:\Recovery\WindowsRE\winre.wim)` in Gray.

The three values are the harness's read-only mirror of production v46 patch 2's build-drift logging. A field engineer diagnosing whether a run is about to replace a newer registered WinRE with an older WIM reads these three values before running production. If the registered version is newer than the build of the WIM the harness sees at the reagentc location, that is a signal — but not necessarily a fault — and the harness reports the values without flagging.

The block does not produce a PASS/FAIL/SKIP record and does not appear in the summary.

#### VMD hardware presence (v18; extended v28)

The VMD section runs the same `Get-PnpDevice` query that production uses, with the same fail-closed semantics. As of v28 the section is preceded by a storage-controller enumeration block that closes the diagnostic gap the ASUS incident exposed: the machine had a controller (`PCI\VEN_8086&DEV_7D0B`) that the manifest did not recognize as VMD, the VMD detector reported "0 of 3 patterns matched", and nothing in the previous output showed the operator which IDs to compare against.

**Storage-controller enumeration (v28).** The block runs first. It reports one of three outcomes:

- **Enumeration failed (NULL).** Prints `Storage controllers  INDETERMINATE (PnP enumeration failed)` in yellow, with a note that production v49 would similarly refuse to certify the candidate if its own enumeration also failed.
- **Enumeration succeeded, zero devices.** Prints `Storage controllers  none present (SCSIAdapter class)` in gray.
- **Enumeration succeeded, one or more devices.** Prints the device count, then one sub-block per device: the friendly name (Cyan), the InstanceId (DarkGray), and each ID in the union of `HardwareID`, `CompatibleID`, and the InstanceId prefix up to the last backslash (Gray).

Software and virtual controllers (`InstanceId` starting with `{GUID}\` or `SWD\`) are skipped, mirroring production v49's software-device filter.

**Manifest VMD patterns.** Immediately after the controller enumeration, the block prints the manifest's `requiredDevices` patterns, one per line, under a `Manifest VMD patterns  N pattern(s)` header. This is the operator's side-by-side view: the machine's controller IDs above, the manifest's expected IDs below.

**Match verdict.** Then the VMD presence verdict:

- **Manifest has no `requiredDevices` patterns.** The section prints `(manifest has no requiredDevices patterns - VMD not applicable)`. This is informational.
- **Enumeration succeeded.** The section prints the matching device count and a `VMD hardware present  True/False` line, colour-coded.
- **Enumeration failed (indeterminate).** The section prints `VMD presence  INDETERMINATE` with the enumeration error message, and a note that production would defer rather than assume absence. Colour-coded yellow.

**ASUS-shape advisory (v28).** When VMD is not present but SCSIAdapter-class devices are, an additional advisory block renders in yellow. It names the exact ASUS-incident shape and states that production v49's storage-applicability gate — the last check before deployment — is what refuses a candidate that does not match the machine's controller IDs. The advisory is operator-facing only; production does not depend on the operator to make the decision.

The `INDETERMINATE` outcome is v18; the storage-controller enumeration, the manifest-pattern display, and the ASUS-shape advisory are v28.

#### Windows Setup state (v13)

The diagnostic reads `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` → `ImageState` and warns when the value is present and not `IMAGE_STATE_COMPLETE`. Production's Audit Mode guard defers in that state before any state-modifying action. The diagnostic's check mirrors the guard so that a field engineer pre-flighting a freshly imaged machine sees the deferral condition before running production.

### Option S — State file parity check (v15; VMD handling and wording refined in v18, v19, and v21; `DeployedWinREMetadata` display added in v23; `LocalInputsId` display added in v27)

Read-only. Recomputes the `DesiredStateId` production would compute right now — reading the live driver manifest, resolving the OEM package for this machine's vendor, and detecting VMD hardware presence — then reads the on-disk state file at `C:\Recovery\OEM\winre_state.json` and reports whether production would accept it or treat it as stale.

The output names the computed ID and the stored ID side by side, then prints one of three verdicts:

- **DSI MATCH** (green). The stored deployment ID matches current inputs. The other fast-path gates still apply: WinRE must be Enabled, exactly one **type-coded** recovery partition must exist on the OS disk, and the registered image's DISM servicing metadata (`Version` + `SPBuild`) must match the state file's `DeployedWinREMetadata` anchor. The harness does not check those conditions — Option 1 reports the machine state, and the parity display shows `DeployedWinREMetadata` (v23) so a field engineer can see the anchor production's v47 drift detector compares against.
- **DSI MISMATCH** (yellow). Production will treat the state file as stale and run the full-update path on the next scheduled run. This is expected on the first run after a `DesiredStateId` input change: `ScriptVersion`, `MANIFEST`, `OEMPACK`, CPU vendor/generation, or VMD presence. Subsequent runs take the fast path once the state file is rewritten.
- **INDETERMINATE** (yellow, v18). The VMD hardware presence check could not complete because of a PnP enumeration error, so the correct driver set cannot be determined and the DSI cannot be computed with confidence. A live production run would defer with `EXIT_WARNING` before committing any state rather than take either the fast path or the full-update path. The harness records `SKIP` in the results with reason `VMD query indeterminate` and prints a paragraph explaining the situation. Resolve the PnP service issue and re-run.

If the state file does not exist, the harness reports that production will take the full-update path (which is correct: `needInject = $true` when there is no state) — except when the VMD query is also indeterminate, in which case the harness records `SKIP` and explains that a live production run would defer rather than start the update (v19).

As of v21 the parity display also includes the state file's `RepairAttempts` field alongside `PendingReboot`, `LastEnableResult`, and `EnableFailureAttempts`. Before v21 the display omitted this field even though the state file carries it; a field engineer diagnosing a pending-reboot loop had to read the JSON directly.

As of v23 the parity display also includes the state file's `DeployedWinREMetadata` field. When present (a state file written by a v47 production run), it renders green. When absent (a v46-or-earlier state file), it renders yellow with a note that production v47 will force a rebuild on the next run because the drift detector has no anchor to compare against. Before v23 the field was silently absent from the display; a field engineer diagnosing a rebuild-on-first-v47-run had to read the JSON directly.

As of v27 the parity display also includes the state file's `LocalInputsId`, alongside the computed value. Production writes the field (v48 patch 1) and consults it on offline fallback; the harness makes a mismatch visible before the machine goes offline. A stored `LocalInputsId` that differs from the current locally-computable value means a hardware or OS input has changed since the state file was written, and production's offline fallback will defer rather than trust the stale DSI.

Option S is the field engineer's tool for answering "is this machine about to rebuild?" without running the production script. It does not exercise the offline fallback (v44 patch 5): Option S always performs a live manifest fetch and a live VMD detection, so on an offline machine the harness reports the fetch failure rather than a DSI verdict.

### Options 2 through 9 and A/B

Exercise the download and extraction paths. Each option:

- Downloads the source.
- Extracts with the appropriate tool.
- Counts INF files for driver packs.
- For WIM downloads, extracts the WIM and reads its build with `Get-WindowsImage`.

Option A runs the subset relevant to the current machine (its OS, its vendor, its CPU). Option B runs everything.

## The parser self-test

Eighteen checks as of v28 (seventeen as of v25, sixteen as of v22, fifteen as of v18, ten before v18); v23, v24, v26, and v27 did not change the count or the contents. v28 added the `Get-StorageControllerDevices` shape check. Each records PASS, FAIL, or SKIP in `$Script:Results` and prints one `[OK]` / `[FAIL]` / `[SKIP]` line. The state tags are colour-coded (green `[OK]`, red `[FAIL]`, dark gray `[SKIP]`); the line format itself is unchanged from earlier versions.

| # | Check | What it verifies | Since |
|---|---|---|---|
| 1 | reagentc status regex | `(Enabled\|Disabled)` matches at least one line of `reagentc /info` output. | v1 |
| 2 | reagentc location regex | `(GLOBALROOT\|Volume GUID)` matches at least one line. | v1 |
| 2b | reagentc version regex | `Windows RE Version:` matches at least one line. SKIP when the line is absent (WinRE Disabled, or reagentc suppressed it). | v22 |
| 3 | manage-bde protection regex | `Protection On` or `Protection Off` appears. | v1 |
| 4 | manage-bde conversion status regex | A `Conversion Status:` value matches, **or** the string `could not be opened by BitLocker` appears. | v1 |
| 5 | Get-BitLockerVolume shape | `ProtectionStatus` and `VolumeStatus` are non-null. SKIP if not elevated. | v1 |
| 6 | OS resolution | `Get-OSPartition` and `Get-OSDisk` both resolve. | v1 |
| 7 | Get-Partition shape | A sample partition exposes `DiskNumber`, `PartitionNumber`, `Size`, `GptType`, `MbrType`, `IsBoot`, `IsSystem`, `IsActive`. | v1 |
| 8 | WinRE location resolution | The reagentc location resolves to a partition. SKIP if location is empty. | v1 |
| 9 | Get-RecoveryPartitions | Returns at least one partition. | v1 |
| 10 | Get-PartitionSupportedSize | Returns `SizeMin` and `SizeMax`. SKIP if no OS partition. | v1 |
| 11 | DISM cmdlets | `Mount-WindowsImage`, `Dismount-WindowsImage`, `Get-WindowsImage`, `Add-WindowsDriver`, `Get-WindowsDriver`, `Remove-WindowsDriver` are all present. | v18 (extended v25) |
| 12 | Get-Disk shape | `Number`, `FriendlyName`, `PartitionStyle`, `Size`, `BootFromDisk`, `IsSystem`, `IsBoot`, `BusType` are present. | v18 (extended v25) |
| 13 | Get-Volume shape | `DriveLetter`, `FileSystemLabel`, `FileSystem`, `Size`, `SizeRemaining`, `DriveType`, `HealthStatus`, `UniqueId` are present. SKIP if no lettered volume to sample. | v18 |
| 14 | CPU generation parser | Fourteen regression cases: 11th/12th/13th Gen, Core, Core Ultra, and negative cases for AMD/Celeron/Pentium/Xeon/Atom return the expected values. | v18 |
| 15 | DesiredStateId | 64-hex, deterministic across repeat calls, VMD-sensitive, ScriptVersion-sensitive. | v18 |
| 16 | Compare-WimServicingMetadata | Eight regression cases covering the DISM servicing-metadata comparison rules. | v25 |
| 17 | Get-StorageControllerDevices shape | Handles the enumeration's three outcomes: a NULL return (indeterminate PnP enumeration) records FAIL, an empty array records SKIP, and a populated array is verified to have objects each carrying `FriendlyName`, `InstanceId`, and `Ids`. | v28 |

### What a FAIL means

A FAIL means the machine's Windows tooling no longer matches an assumption the production script relies on. The production script **may** silently misclassify state on this machine and must be adapted before deploying to it.

The most likely FAILs and their implications:

- **Check 2b (reagentc version regex).** Windows changed `reagentc /info` output format on this build, or the `Windows RE Version:` line is suppressed while WinRE is Enabled. Production's `Get-WinREState` will return `Version = $null`, and the startup log line will read `WinRE ... Version: unknown`. Production's behavior is unchanged — the value is informational — but the build-drift observability is lost on this machine until the regex is extended.
- **Check 3 or 4 (manage-bde regex).** Windows changed `manage-bde -status` output format on this build. Production's `Test-VolumeEncrypted` will return `$null`; `Set-RecoveryPartitionReadyForWinRE` will treat the target partition as indeterminate and either retry the query once or proceed to run `manage-bde -off` against it. The machine is safe but the target preparation may take longer than expected.
- **Check 7 (Get-Partition shape).** The `Storage` module is missing or reduced. Production's partition classification will fail.
- **Check 10 (Get-PartitionSupportedSize).** The shrink path will fail. The script will fall back to OS-fallback after the OS-shrink attempt, but this is a machine-specific failure that should be investigated.
- **Check 11 (DISM cmdlets).** A DISM cmdlet is missing. Production's driver-injection path cannot run on this machine at all; the pipeline gate will fire on every full-update pass and the machine will never take the fast path unless it is already in the fast-path state.
- **Check 12 or 13 (Get-Disk / Get-Volume shape).** A property production reads has been removed or renamed. Production may misclassify a disk or a volume.
- **Check 14 (CPU generation parser).** A CPU string no longer parses to the expected generation. `DesiredStateId` will contain a different `CPU=` value than intended, which will force a rebuild on machines whose state file was written under the previous parse. Investigate the raw CPU string (the diagnostic's Hardware section reports it) and extend the parser.
- **Check 15 (DesiredStateId).** The DSI recipe has changed silently — a field dropped from the hash, or the output is no longer deterministic. This is a production correctness bug; do not deploy production to a fleet until the recipe is fixed.
- **Check 17 (Get-StorageControllerDevices shape).** One of: the enumeration returned NULL (a transient PnP failure — re-run or investigate PnP service state); the `Get-PnpDevice` result shape has changed; the software-device filter (`{GUID}\` and `SWD\` prefixes) has stopped matching; or an unexpected exception was thrown during the enumeration. Production v49's storage-applicability gate uses this enumeration to decide whether the candidate image contains an INF matching the machine's controller; a shape change that removed or renamed `FriendlyName`, `InstanceId`, or `Ids` would silently degrade the harness's diagnostic output, and a change to the filter would change which devices count as the machine's storage controllers. Investigate the raw `Get-PnpDevice -Class 'SCSIAdapter' -PresentOnly` output.

### What a SKIP means

A SKIP means the check could not run in the current context. The reasons:

- **Not elevated.** `Get-BitLockerVolume` requires elevation on some machines. The check SKIPs rather than FAILing.
- **The state it inspects is absent.** WinRE location is empty, no OS partition, no lettered volume to sample, or similar. The check has nothing to inspect.
- **Zero devices present (Check 17).** The `Get-StorageControllerDevices` enumeration returns an empty array on some VMs (no SCSIAdapter-class devices). A zero-device result is legitimate; the check SKIPs rather than FAILing. The distinction matters: NULL means the enumeration failed (indeterminate), and an empty array means the enumeration succeeded but found nothing (legitimate). The check verifies both cases.
- **A precondition was not met.** `Test-VmdDrivers` (not a parser check) records SKIP when the Intel CPU generation cannot be parsed, because driver applicability was not evaluated. Option S records SKIP when the VMD query is indeterminate, because the DSI parity verdict cannot be computed from an indeterminate driver-set determination. Check 2b records SKIP when WinRE is Disabled or reagentc suppressed the version line.

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

The BitLocker, target-partition, `ImageState`, Build numbers, storage-controller, and Option S outputs are informational — Option S records a result for the parity check itself but its intermediate verdict output is a separate thing. The BitLocker, target-partition, Build numbers, storage-controller, and `ImageState` blocks do not produce PASS/FAIL/SKIP records and do not appear in `Show-Summary`.

## Non-interactive mode

```powershell
.\scripts\Test-WinRE.ps1 -NonInteractive
```

Runs `Invoke-AllRelevant`, prints the summary, exits.

`-NonInteractive` runs the download and extraction tests. It does not run the System Diagnostic (Option 1) or the State file parity check (Option S), so the BitLocker warnings, the target-partition state block, the `ImageState` check, the Build numbers block, the storage-controller block, and the DSI comparison are not printed in this mode. If you need any of those, run the harness interactively and choose Option 1 or Option S.

The exit code is 0 when no FAIL results were recorded, and 1 when at least one FAIL was recorded (v25+). SKIPs do not affect the exit code. The summary remains the authoritative view of what ran. The behavior was introduced in v25 so that CI and cron consumers can treat the harness as a regression gate rather than a reporter.

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
- **The v49 pre-deployment gates.** The source-ownership classification, the never-downgrade storage-driver check, the pre-deployment storage-applicability gate, and the native-boot VHDX fail-closed gate are all production-only. The harness surfaces the *inputs* those gates read — the storage controllers (v28), the source-WIM ownership class is not currently surfaced — but does not exercise the gates themselves. See the "v49 destructive-path coverage" section below.

Those paths are covered by field testing on representative hardware. See the "Field-tested hardware" table in the [README](../README.md).

## Differences from production

The harness shares code paths with production in the download, extraction, and CPU-generation helpers. It is documented in the file's own docstring which functions are "based on" the production versions and which are harness-specific.

Thirteen known differences:

- **`Test-VmdDrivers` does not filter on VMD hardware presence.** Production skips manifest entries whose `requiredDevices` do not match anything on the machine. The harness intentionally does not — it validates every OS/CPU-eligible URL and extraction path from a single machine, regardless of installed hardware. This makes the harness a package validator, not a machine-specific compatibility test. As of v17, the harness prints an explicit three-line note before the driver loop explaining this. The state-file parity check (Option S) *does* apply the hardware filter, because it is replicating production's DSI computation and production's DSI includes VMD presence.
- **The harness does not run production's BitLocker helper functions.** The BitLocker sections in the diagnostic query `Get-BitLockerVolume` and `manage-bde -status` directly and categorize the result for display as hazardous, ambiguous, or safe. Production's `Test-VolumeEncrypted` returns a tri-state ($true / $false / $null); the harness's three-way UI categorization is a display-level view of the same underlying state, not a distinct predicate. The harness does not call `Set-RecoveryPartitionReadyForWinRE` or `Test-VolumeEncrypted`. This is intentional: the harness does not exercise production's BitLocker control flow, and a change to that control flow does not require a harness update to remain correct. The v14 update changed the warning text and added the target-partition state block, but did not change the classifier itself.
- **`Get-ThisMachineProfile` normalises manufacturer names identically to production, but is otherwise harness-specific.** Since v15 the manufacturer normalisation, the OS-detection method (Caption-based, not build-number-based), and the returned fields (including `Model`) all match production's `Get-HardwareObject` exactly, so the DSI computed by Option S is byte-identical to what production computes for the same inputs. The two helpers differ in that `Get-ThisMachineProfile` reads additional CIM data for the diagnostic and does not cache its result the way production's does.
- **Network behavior is aligned with production as of v17.** Every `Invoke-RestMethod` and `Invoke-WebRequest` call in the harness carries `-TimeoutSec $NetworkTimeoutSeconds` where `$NetworkTimeoutSeconds = 15`. Before v17, the harness used PowerShell's default ~100-second timeout on each call, so a fully offline machine would take over 10 minutes to fail. The v17 alignment means the harness fails as fast as production does on a bad network. The `Invoke-OemPackDownload` helper's zero-byte check was also restored to match production's ordering: the length check now runs before the hash comparison, so a zero-byte download with an expected hash logs "file is empty" rather than "SHA256 mismatch". Both changes are correctness improvements that make the harness a more faithful replica of production's download path.
- **VMD query-failure handling, Lenovo resolution, and Option S wording are aligned with production as of v18 and v19.** The harness's VMD presence check now treats a PnP enumeration error as indeterminate (matching production v44 patch 6), and the harness's `Get-LenovoWinPEPack` now sets `$Script:LenovoPackResolution` to the same five states as production. Before v18, an enumeration error in the harness produced a definitive answer, and a malformed Lenovo map entry looked identical to a legitimate no-pack case. Both were drift risks: the harness could disagree with production about what a live run would do. v19 corrected two further Option S wording issues (the state-file-absent-and-VMD-indeterminate case now records `SKIP`; the header and DSI MATCH verdict no longer overstate what DSI equality proves).
- **The active-location classifier is aligned with production as of v20.** The harness's WinRE classifier now requires a type-coded recovery partition on the OS disk to reach the `DEDICATED` verdict, mirroring patch 3 of the v44 patch 7 cycle. Before v20, the classifier promoted a label-only match to `DEDICATED`, which could have reported `DEDICATED` for a machine whose registered location was a Basic Data partition labelled "Recovery" while production would have taken the full-update path. The harness's `LABEL-ONLY` verdict is informational and has no direct production equivalent; production's active-location classifier logs a WARN in the same situation without stopping.
- **The `DesiredStateId` mirror is aligned with production as of v21 (through v28).** The harness's `Get-DesiredStateId` carries a `$ProductionScriptVersion` default that must track production's `$ScriptVersion`. It was pinned at 44 while production advanced to 45, which made every Option-S comparison against a v45-written state file report `DSI MISMATCH` incorrectly. The default became 45 in v21, 46 in v22, 47 in v23, 48 in v27, and 49 in v28; the parameter-header comment states the tracking rule. Before each bump, a field engineer running Option S against a machine updated to the corresponding production version would have seen a false "production will treat this state file as stale" verdict on a machine whose state file production would actually accept. v22, v23, v27, and v28 close the analogous gaps for v46, v47, v48, and v49.
- **The reagentc version parser and the Build numbers block are aligned with production as of v22.** The harness's `Get-WinREState` now extracts `Windows RE Version` from `reagentc /info` and returns it as `Version`, and Option 1 renders the "Build numbers" block described above. Both mirror production v46 patch 2's build-drift logging. The harness shows the values; it does not write them to a production log file, and the values do not enter the harness's DSI computation.
- **`Show-StateFileParity` displays `DeployedWinREMetadata` as of v23.** The state file's DISM servicing metadata anchor (v47 patch 1's `DeployedWinREMetadata` field, in `<Version>|<SPBuild>` form) renders in the parity output alongside the other state-file fields. When present, it renders green; when absent (a v46-or-earlier state file), it renders yellow with a note that production v47 will force a rebuild on the next run because the drift detector has no anchor to compare against. This mirrors production v47 patch 1's `DeployedWinREMetadata` field — the harness shows the value, but no production decision depends on the harness reading it.
- **The Plan adjacency preview is a mirror, not a simulation.** Option 1's preview evaluates the geometric and partition-identity subset of `Get-PartitionPlan`'s rejection checks read-only. It does not compute a bucket size, does not run the pre-shrink, does not choose a target partition, and does not exercise the extension path or the whole-layout assertion. A clean preview confirms the layout would not be rejected on the checks evaluated; it is not a prediction that the full plan would succeed. As of v27 the preview also mirrors v48's intervening-anchor handling and reports either acceptance with the anchor identity or rejection with the specific anchor failure.
- **`Architecture` and `LocalInputsId` are reported as of v27.** The harness's hardware-profile helper now carries the same normalized architecture token production's `Get-HardwareObject` produces, and the System Diagnostic renders it with a red banner when the value is anything other than `x64`. This surfaces production's v48 architecture-gate refusal before an operator runs production on a non-x64 host. Option S shows both the computed and the stored `LocalInputsId`, matching production v48 patch 1's offline-fallback input. Neither the architecture token nor `LocalInputsId` enters the harness's DSI computation — matching production, where they are gate inputs rather than `DesiredStateId` components.
- **The storage-controller enumeration and VMD diagnostic are aligned with production as of v28.** `Get-StorageControllerDevices` mirrors production v49's SCSIAdapter-class enumeration, including the software-device filter (`{GUID}\` and `SWD\` prefixes skipped). The Option 1 diagnostic surfaces the machine's controller IDs, the manifest's VMD patterns, and the ASUS-shape advisory. The harness does not run the pre-deployment storage-applicability gate itself — that is a production-only check immediately before the WIM is written to the active route — but it gives the operator the same inputs production's gate reads, so a mismatch that would cause production to refuse the candidate is visible before the run.
- **The harness does not exercise the v49 pre-deployment gates.** The source-ownership classification, the never-downgrade storage-driver check, the pre-deployment storage-applicability gate, and the native-boot VHDX fail-closed gate are all production-only. The harness surfaces the storage controllers (v28) that the applicability gate reads; it does not classify the source WIM, does not compare driver versions, and does not check the OS volume topology.

The harness has no mirror of the v45 shrink-first pipeline. Option 1 and Option S report the machine's current state and the DSI comparison, but they do not simulate the plan, the pre-shrink, the extension path, or the whole-layout assertion. That is by design: those paths are destructive and cannot be simulated read-only.

## v45 destructive-path regression (recommended)

The v45 patch 1 changes to `Ensure-AdequateRecoveryPartition` are the largest rework of the destructive path since v43. The reorder moves the shrink into the reversible window; the geometry model changes from deficit-plus-slack to single-boundary; the plan gains several validity checks; the deletion loop reorders the active partition last; a post-delete extension path with a safe fallback replaces the pre-delete extend; and a whole-layout assertion verifies the created partition's geometry. The happy path through these code paths has been exercised end-to-end on a disposable Hyper-V VM (2026-10-02 08:56).

The v46 patch 1 cycle added two physical-hardware exercises on top of the VM run.

**`Assert-RecoveryPartitionLayout` has been exercised in the passing case.** The Dell Latitude 3540 and the HP EliteBook 6 G1i 16" both took the v46 patch 1 destructive path on 2026-10-02 and both logged `Verified recovery partition layout: disk 0 partition 4, offset O MiB, size S MiB` before reaching `DEDICATED`. Both runs also confirmed the C:-to-recovery gap and the disk-end trailing reserve were within tolerance, which is what the assertion exists to verify. This is the first physical-hardware exercise of the whole-layout assertion on the v45/v46 pipeline.

**The plan-rejection check has been exercised in the rejecting case.** The Lenovo IdeaPad 3 15IAU7 that motivated v46 patch 1 took the v45 patch 1 pipeline on physical hardware and the post-delete geometry check in `Ensure-AdequateRecoveryPartition` (`$plannedEnd -gt ($diskSizeNow - 1MB)`) correctly rejected the plan: `Get-PartitionPlan` had computed `tailEnd` from a factory-provided partition ending exactly 1 MiB past the disk-end reserve, `AlignedManagedExtentEnd` landed 1 MiB past the reserve, and the post-delete check refused to proceed. The machine fell into OS-fallback with a state file that matched the failing `DesiredStateId`, so subsequent scheduled runs accepted the state and did not retry — the machine stayed in OS-fallback until an operator manually deleted the state file. Under v46 patch 1's clamp the same layout produces a valid plan; the second full-update run (after the state-file reset) reached `DEDICATED`. This is the first physical-hardware failure of the v45 destructive path, and the first time the post-delete check fired outside a test harness.

### v47 patch 1 destructive-path coverage (recommended next step)

The v47 non-destructive paths are field-verified on the ASUS PRIME H510M-D. The v47-specific code paths that remain unexercised on any storage — physical or virtual — are:

- **The strip stage with a non-zero third-party driver set.** The ASUS run's strip was a no-op. The loop that removes published OEM#.inf entries one at a time, re-enumerates, and reaches zero was validated by an earlier real-machine F1/F2/F3 experiment, but has not been exercised inside a v47 production run.
- **The strip-failure abort path.** The candidate-rejection path (dismount `-Discard`, checkpoint rollback to Step 2, stale-artifact cleanup) has not run in the field.
- **The source-selection LKG-comparison and GitHub cold-start branches.** The ASUS run took the "registered" branch through its "no hash-validated LKG present" sub-path. The two remaining branches were not reached.
- **The pre-`/disable` race-detector abort path.** No drift occurred, so the abort branch has not fired.
- **The metadata-triggered rebuild branch.** The registered metadata matched the last-deployed on the first fast-path run.
- **The WIM_READY checkpoint save and resume round trip.** The ASUS run completed its deployment in one execution.
- **The destructive partition paths under v47.** Pre-shrink, partition delete, `New-Partition`, the whole-layout assertion, and the post-delete extension fallback were not reached — the existing recovery partition was reusable.

The v45 destructive-path VM test documented below remains the recommended next step before broad rollout under v47. It should be followed by a canary on a machine with an OEM driver pack so the strip-and-reinject loop runs against a non-empty set. These paths are covered by inspection, by the earlier F1/F2/F3 strip experiment, and by the mocked-geometry test plan documented below.

**v48 patch 1 coverage.** The intervening-anchor happy path is field-verified on the AMD Ryzen 7 5825U machine that motivated it (2026-10-06), on the exact `C: | D: | Recovery` layout. The v48-specific code paths that remain unexercised on any storage are: the intervening-anchor post-deletion failure behaviour (the same class of residual documented for the non-intervening path); the v48 multi-intervening rejection and surplus rejection; the transactional WIM replacement's rollback branch (a copy failure mid-replacement); the architecture gate on ARM64 hardware; and, from v48 patch 2, the source-WIM hash cache fix on the enable-only fallthrough path. The remaining v47 gaps also stand: the strip stage against a non-zero third-party driver set, the OEM pack or VMD injection paths, the metadata-triggered rebuild branch, the pre-`/disable` race-detector abort branch, and the WIM_READY checkpoint save/resume round trip. The deliberate post-deletion failure test remains the gate for future changes to the post-deletion segment. See the "v48 patch 1 destructive-path coverage" section below.

### v48 patch 1 destructive-path coverage

The v48 patch 1 release introduces five changes: intervening-partition handling, the architecture gate, `LocalInputsId`, LKG-by-hash at any discovered recovery location, and transactional WIM replacement. Four are covered below; the fifth (LKG-by-hash) is a source-selection change and is not covered here.

- **Architecture gate.** Unexercised on ARM64 hardware. A live run on any non-x64 host should exit `EXIT_WARNING` before any state mutation; a live run on an x64 host should log `Architecture gate passed: x64` and continue unchanged. The gate has no DryRun carve-out: a dry run on a non-x64 host also exits `EXIT_WARNING` unconditionally.
- **`LocalInputsId` offline-drift guard.** Unexercised on the offline path. The test shape: a machine whose stored `LocalInputsId` was written by a prior run, taken offline, and whose hardware or OS build is changed while offline (VM snapshot manipulation or an in-place build change), then run with the manifest unreachable. The run should exit `EXIT_WARNING` with the `Offline fallback: stored LocalInputsId ... does not match` line rather than take the fast path.
- **Transactional WIM replacement rollback.** Unexercised. The rollback branch fires when a copy fails mid-replacement after the previous WIM has been preserved. The test shape: mock `Copy-Item` to fail on the new-WIM copy, confirm the rollback copy is restored and hash-verified, and confirm the log shows `Rollback copy restored to <path>` before the run returns to the enable attempt.
- **Intervening-anchor post-deletion failure.** Unexercised on the intervening path. This is the same class of residual the deliberate post-deletion failure test exercises for the non-intervening path: the anchor is shrunk, the recovery partition is deleted, and a later step (create, format, drive letter, or extension) fails. Follow the setup and recording requirements in "The post-deletion failure test (gating)" above, on an `C: | D: | Recovery` VM.

### v49 destructive-path coverage

The v49 release introduces several pre-deployment gates, post-run persistence features, and the backup / restore actions. The happy path for the interim features (backup, restore, resume task on clean completion) is exercised by the wrapper's own smoke tests. The gates and the interruption paths below are the v49 coverage that remains.

- **Source-ownership classification.** Unexercised in the field. The classification runs before the strip stage. The test shape: prepare four VMs, one for each ownership class, and confirm the classification decision matches the expected class. In particular, a `Foreign-With-Drivers` source should be preserved as-is (strip stage skipped) rather than stripped and re-injected. The `Manager-Owned` and `Manager-Lineage` classes should be stripped and re-injected. The `Foreign-No-Drivers` class should be stripped (a no-op) and re-injected. Record the class the harness reports and the strip-stage decision.
- **Never-downgrade storage-driver check.** Unexercised in the field. The check runs during the injection stage. The test shape: a VM whose registered WinRE carries a version N storage driver, and a candidate package that resolves to version N-1 of the same driver. Confirm the check skips the injection and retains the existing driver, and that the log names the driver, the two versions, and the skip decision. Confirm the reverse (a candidate with a newer version) is injected normally.
- **Pre-deployment storage-applicability gate.** Unexercised in the field — it has never fired. This gate is the last refusal before the WIM is written to the active route: the candidate must contain an INF matching one of the machine's present SCSIAdapter-class devices. The test shape: a VM whose controller is deliberately absent from the manifest's VMD patterns and from the OEM pack's INFs, and a candidate image prepared from the manifest. Confirm the gate refuses the candidate, the run exits `EXIT_WARNING`, and the log names the candidate image path, the machine's storage controllers, and the fact that no INF matched. This is the highest-signal v49 test because the gate has never fired in the field.
- **Native-boot VHDX fail-closed gate.** Unexercised on VHDX-boot hardware. The test shape: a Windows VM booted from a native VHDX rather than a physical or pass-through volume. Confirm the gate refuses before any destructive operation and the run exits `EXIT_WARNING` with the topology-named refusal. Confirm the log line names the VHDX topology and the specific operations the manager does not support under it.
- **Backup action.** Exercised on the clean path by the wrapper. The failure branches (a source-WIM read error, a destination-write error, a copy hash mismatch, a drive-letter exhaustion) have not been exercised. Test each against a VM: mock the source read to fail, mock the destination write to fail, tamper with the copy to cause a hash mismatch, and exhaust drive letters. Confirm the run exits with a non-zero code, the machine state is unchanged, and the log names the specific failure point.
- **Restore action.** Exercised on the clean path by the wrapper. The two mid-transformation failure paths (`/setreimage` failing after the WIM has been replaced, `/enable` returning failed/bitlocker after the WIM is in place) have not been exercised. Test both against a VM: mock `/setreimage` to return non-zero after the WIM has been written, and mock `/enable` to return a terminal failure after the WIM is in place. Confirm in each case that the resume task's persist flag is set, that the transactional helper leaves the machine's previous WIM in place (either by completing the rollback or by reporting a rollback-restore failure), and that the machine's end state matches one of the two documented outcomes.
- **Temporary resume task persist triggers.** Exercised on the clean-completion path only — the task is registered and then deleted. The five persist triggers (outer catch, Ctrl+C, the two restore failure paths, hard kill, reboot) have not been exercised. The Ctrl+C trigger is the load-bearing one and is high-signal. Test each: force an unhandled exception, send Ctrl+C during a run, invoke the two restore failure paths above, kill the PowerShell process mid-run (`Stop-Process -Force`), and reboot the VM mid-run. Confirm in each case that the resume task is preserved, that it fires on the next boot (or within the hour), and that the resume run completes the interrupted operation.
- **Stable install location and copy-hash verification.** Exercised on the clean path by the wrapper. The copy-hash mismatch refusal branch has not been exercised. Test by mocking the copy to introduce a byte discrepancy (or by racing an AV/EDR product that alters the copy in place). Confirm the install step refuses to register the task, the log names the source and destination hashes, and the installed copy is left in place.

Each of these tests should be recorded with the same data the v45 / v46 tests record: the VM setup, the branch that fired (with the log line), the machine's end state, the exit code, and any divergence from the documented behavior.

### v46 patch 2 hardenings (inside the post-deletion gate)

The v46 patch 2 cycle added four post-review hardenings of `Ensure-AdequateRecoveryPartition`. Per [`CONTRIBUTING.md`](../CONTRIBUTING.md#the-remaining-gated-scope), they are treated as inside the post-deletion gate — no future change to the post-deletion segment of the destructive sequence should ship until the post-deletion failure test below runs and its result is recorded. The four hardenings:

- **Pre-deletion resolver guard.** Refuses the destructive sequence when WinRE was `Enabled` and its registered location cannot be resolved to a partition. As of v48 patch 1, fires ahead of the pre-shrink and ahead of `reagentc /disable`, so the machine is left with WinRE still `Enabled` and the old recovery partition intact.
- **Extension-fallback bucket cap.** Caps the extension-failure fallback at the plan's bucket size, not the full remaining extent, preserving the 2 GiB managed-recovery ceiling.
- **Layout-assertion fail-closed branch.** `Assert-RecoveryPartitionLayout` returns `$false` when `Get-OSPartition` returns nothing, rather than skipping the C: adjacency check.
- **Deletion-failure partial-rollback reporting.** The deletion-failure branch captures the `Restore-OSPartitionSize` and `Restore-PreviousWinRERoute` results separately, and reports a distinct reason when the route is restored but C: geometry is not verified.

**None of the four has been exercised in the field.** They were code-review hardenings in the v46 patch 2 cycle, not field-driven fixes. They are covered by parser and mocked-geometry tests, and by the same post-deletion failure test that gates the rest of the post-deletion segment. When that test runs, its recorded result must list which of the four hardenings it exercised and which it did not; that is the right moment to revisit the gate's scope.

### The post-deletion failure test (gating)

This test exercises the one residual corner the project has not closed: a failure of `New-Partition` or `Format-Volume` **after** the existing recovery partition has been deleted, on a machine whose C: is encrypted, with no successful retry. In that corner, `Remove-OrphanPartition` cleans up the newly created partition, `Restore-OSPartitionSize` restores C:'s geometry, the run falls through to OS-fallback, and the OS-fallback gate defers because C: is encrypted. The machine ends with neither a dedicated recovery partition nor OS-fallback.

The corner is the one place where **Rule 1 (never break Windows RE)** and **Rule 2 (never leave a machine without a working recovery route)** conflict. Rule 2 cannot be *guaranteed* in this case; it holds in the two ordinary cases (the destructive attempt succeeds, or it fails before deletion), but a post-deletion failure on an encrypted-C: machine reaches the corner. The v45 shrink-first reorder narrowed the trigger set — a shrink failure no longer reaches the corner because the shrink runs before deletion — but the corner itself is not closed. Closing it is the eventual post-failure check, gated on this test.

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
[WARN] ================================================================================
[WARN] Dedicated recovery partition creation failed after all attempts.
[WARN] Falling back to C:\Recovery\WindowsRE (OS-partition recovery location).
[WARN] This is NOT equivalent to a dedicated recovery partition.
[WARN] WinRE will function but with reduced resilience. Exit code will be 2.
[WARN] ================================================================================
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

### Paths that need coverage

- **Pre-shrink failure.** All three shrink attempts fail; the script restores C: to its recorded original size, returns `Deferred` with `RetrySuppressible = $true`, preserves the existing route, and writes the deferral marker.
- **Post-delete extension failure.** The plan calls for extension into the freed space; the extension fails after three tries; the safe fallback places the recovery partition at the current C: end, sets `$Script:nonFatalWarning`, and continues with WinRE deployable. If the fallback size is too small, C: is restored and the function returns `$null`.
- **Whole-layout assertion.** `New-Partition` returns success but the actual geometry does not match the plan (wrong offset, wrong size, overlap, or a trailing extent that exceeds one alignment block); `Assert-RecoveryPartitionLayout` fires, `Remove-OrphanPartition` deletes the newly created partition, and the function returns `$null`.
- **Deletion-failure route restoration.** A deletion fails mid-loop while WinRE is disabled; the script restores C: to its original size, calls `Restore-PreviousWinRERoute`, and either returns `Deferred` (route restored) or `$null` (route not restorable). `Test-WinRELocationMatches` handles the GLOBALROOT-vs-Volume-GUID form difference.
- **Plan validation edge cases.** Each rejected layout (blocking non-recovery partition after C:, non-contiguous recovery partition, recovery-typed partition over 2 GiB, cross-disk inventory, insufficient aligned space) returns `Deferred` without touching WinRE or any partition.
- **Deferral marker lifecycle.** The marker is written on a retry-suppressible deferral; a subsequent run honors it while the route is functional and does not repeat the pre-shrink retries; a run where the fast path would fire clears the marker and exits `EXIT_SUCCESS`; a `DesiredStateId` change clears the marker on read.
- **MBR support.** The destructive path on an MBR disk uses `-MbrType 0x27` at creation and `set id=27` in `Set-RecoveryPartitionAttributes`. The MBR attribute-application branch was exercised on a Win10 MBR VM (2026-10-02 09:41, reuse path); the MBR destructive path has not been exercised on any storage.

Each of these tests exists to protect a specific invariant from `architecture.md`. The pre-shrink and deletion-failure tests are direct exercises of **Rule 2** — a failing pre-shrink must leave the old recovery route intact, and a failing deletion must attempt to restore it. The whole-layout assertion and the plan-validation edge cases are **Rule 1** tests — the destructive sequence must refuse to proceed on a layout it cannot prove safe. The deferral marker lifecycle is a **Rule 4** test — the marker is the mechanism by which "do no work unless needed" is enforced across a run that has deferred. The MBR test confirms **Rule 1** on a partition style that has not yet seen a field exercise.

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
- **v49 pre-deployment gates.** See "v49 destructive-path coverage" above — the setup, expected behavior, and high-signal branches are documented there.

### What to record when a test is run

For each test, record:

- The test name and the path being exercised.
- The machine setup (vendor, model, OS build, disk partition style, C:'s encryption state).
- Whether the intended branch fired (identify the log line).
- The end state: C: size, partition count, WinRE status, registered location.
- The exit code.
- Whether the deferral marker was written, honored, or cleared.
- Whether the resume task is present after the run (v49 tests).
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

When adding a check to the parser self-test, use the pattern of the existing checks: enumerate the object's expected properties, compare against the observed shape, record `PASS` when all are present, `FAIL` when one is missing, and `SKIP` when the state the check inspects is legitimately absent. A check that a machine can be in without fault should SKIP rather than FAIL — for example, the `Get-StorageControllerDevices` shape check (v28) SKIPs on zero devices because a VM with no SCSIAdapter-class devices is a valid configuration.

Do not add tests that modify the machine's state. The harness's contract with the operator is that it is read-only.

## Related documents

- [architecture.md](architecture.md) — the four design invariants, the control-flow invariants, the wrong-question narrative, and the sequencing-pattern note that the v45 reorder is the first instance of. The gating post-deletion test exists to close the one corner where Rule 2 cannot be guaranteed.
- [CONTRIBUTING.md](../CONTRIBUTING.md) — the four-bullet requirement for any PR that touches the destructive sequence, and the scope of the post-deletion gate that this document's gating test unblocks.
- [troubleshooting.md](troubleshooting.md) — how to use the diagnostic output to diagnose a failure, including the BitLocker hazard, VMD-query-indeterminate, and target-partition recovery procedures, plus the compound signature of the post-deletion corner.
- [deployment.md](deployment.md) — the deployment-time translation of the four invariants, the Audit Mode precondition for production deployment, and the one-instance-per-machine program lock.
- [driver-injection.md](driver-injection.md) — what the injection tests are actually testing, including the v49 source-ownership classification and never-downgrade check.
- [state-and-idempotency.md](state-and-idempotency.md) — the `DesiredStateId` composition that Option S recomputes, the deferral marker's relationship to the deployment identity, and the offline fallback's residual risk.
- [recovery-partition.md](recovery-partition.md) — the full partition lifecycle that the v45 destructive-path regression tests exercise.
