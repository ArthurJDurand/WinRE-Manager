# Changelog

All notable user-facing changes to WinRE Manager are documented here.

This file is the authoritative user-facing record of what changed and when. The production script's `.NOTES` block records the current design invariants and the CRITICAL LESSONS LEARNED list; it is not a history. Together the two are the complete record.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to a `ScriptVersion` + patch-generation scheme rather than strict SemVer — see [docs/state-and-idempotency.md](docs/state-and-idempotency.md) for why.

## [v44 patch 7] — 2026-10-01

Six patches closing a non-convergence loop in the recovery-partition classifier, a VMD extraction-directory cleanup, and a diagnostic-only logging change on the destructive path. `ScriptVersion` remains 44; `DesiredStateId` is unchanged; no fleet-wide rebuild is forced.

The change was driven by a review of the v44 patch 6 code in which ChatGPT identified a real non-convergence defect in the classifier and Claude identified a related narrowing of the destructive-path safety envelope. Both reviewers agreed the trade should not be resolved by reinstating the removed v44 patch 3 C: guard, and that the narrowed safety envelope needed to be documented honestly rather than papered over. The six patches reflect that conclusion.

### Fixed

- **Partition-classifier consistency (patches 1–4).** Only a **type-coded** recovery partition on the OS disk is now authoritative for reuse, fast-path counting, active-location classification, and final verification. A partition detected only by its Recovery/WINRE volume label is not promoted to DEDICATED, is not counted by the fast path, and is not reused by `Find-SuitableRecoveryPartition`.

  Closes a non-convergence loop. `Get-RecoveryPartitions` broad-matches by volume label **or** type code. `Ensure-AdequateRecoveryPartition` already filtered to type code before deleting — a label-only match is never authorized for deletion and the code comment said so — but the fast-path count and the reuse classifier still used the broad result. A Basic Data partition labelled "Recovery" was therefore counted by the fast path (`$existingRecoveryParts.Count` included it, so the "exactly one recovery partition on the OS disk" condition could never be satisfied) while being preserved by the destructive path (which correctly refused to delete it, because the label alone is not sufficient authority). The machine cycled through rebuilds indefinitely without converging.

  The four patches:

  1. **`Find-SuitableRecoveryPartition`** — filter candidates to type-coded recovery partitions only (`GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'` or `MbrType -eq 0x27`), before the size and free-space checks.
  2. **Main-flow `$existingRecoveryParts`** — count only type-coded recovery partitions on the OS disk, so the fast-path count agrees with what the destructive path is authorized to remove.
  3. **Active-location classifier** — do not promote a label-only match to DEDICATED. The classifier now distinguishes `$isTypedRecovery` from `$isLabelRecovery`; a label-only match on the OS disk logs a WARN and does not set `$activeOnRecovery`, so the natural rebuild path fires instead of the fast path accepting a route production will not maintain.
  4. **Final-verification classifier** — require type-coded **and** on-OS-disk for the DEDICATED verdict. A label-only match now falls through to the FATAL "unexpected partition" branch instead of being silently accepted as a healthy end state.

- **VMD extraction directory cleanup (patch 5).** Before each `7z x` invocation in the VMD driver injection loop, the extraction directory is now cleared and recreated (`Remove-ItemIfExist` followed by `New-DirectoryIfNotExists`). Closes a class of failure in which a stale INF from an earlier run could satisfy the INF-basename cross-reference or the third-party-driver-count delta and make a failed extraction look like a success. The Lenovo vendor-extractor path had a similar hazard, but the INF-count branch there is only reached after the extractor itself exits non-zero, which does not occur on the VMD `.7z` path.

### Changed

- **Destructive-replacement logging now reports C:'s actual encryption state (patch 6).** When the destructive path is about to run and the current WinRE route will be destroyed (`$stateBefore.Status -eq "Enabled"` or `$deletableParts.Count -gt 0`), the WARN now includes C:'s measured encryption state:

  - `Test-VolumeEncrypted -MountPoint "C:"` returns `$false` → INFO: `C: is confirmed fully decrypted; proceeding.`
  - returns `$true` → WARN: `C: encryption state=True; proceeding because C: encryption is not a veto for the dedicated-target path. The OS-fallback path retains its separate C: BitLocker gate.`
  - returns `$null` → WARN with `C: encryption state=unknown;` and the same rationale text.

  **Diagnostic only.** The decision to proceed is unchanged; no gate was reinstated. The purpose is to make the narrowed safety envelope visible in the log so an operator can recognize the residual failure mode described below.

### Changed (harness)

- **`Test-WinRE.ps1` moved to v20.** Two changes.

  The active-location classifier in `Show-SystemDiagnostic` now requires a **type-coded** recovery partition on the OS disk to reach the DEDICATED verdict, mirroring production's v44 patch 3 change. The previous logic computed a single `$isRec` flag and fell back to a `Get-Volume -Partition` label check that promoted a label-only match to `$isRec = $true`. The classifier now computes `$isTypedRecovery` and `$isLabelRecovery` separately, and the branches report:

  - `OS-FALLBACK` — the WinRE location resolves to the OS partition.
  - `DEDICATED` — the location is both type-coded and on the OS disk.
  - `RECOVERY-ON-SECONDARY` — type-coded but on a non-OS disk (production forces a full rebuild).
  - `LABEL-ONLY` — on the OS disk with a Recovery/WINRE label but not type-coded (production does **not** treat as DEDICATED).
  - `UNEXPECTED` — otherwise.

  This closes a false-positive that could have misled an operator: pre-v20, a machine whose reagentc-registered WinRE location was a Basic Data partition labelled "Recovery" would have been reported as `DEDICATED` by the harness, while production would have taken the full-update path. Production's final-verification classifier (v44 patch 4) has no direct harness equivalent and is not claimed; the harness classifies the reagentc-registered location, which is the active-location decision point, not the post-deploy verification decision point.

  The menu box alignment is also fixed. The menu's top border is 66 columns wide interior (plus the two `╔`/`╗` characters and two leading spaces). The title row was padded to 33 columns, the working-directory row to a length-relative value, and the detected row to 64 — none of which equals the interior width minus the leading space. All three rows now pad their content to exactly 65 columns with the working-directory and detected rows truncating at 65 with an ellipsis if content overflows. Purely cosmetic; no functional change.

### Changed (docs)

- **`docs/architecture.md`** — added Invariant 16 (only a type-coded recovery partition on the OS disk is authoritative). The Step 5 discussion now names the safety property's two ordinary cases (the destructive attempt succeeds, or it fails before deletion) and the one narrow corner where it does not hold, with a cross-reference to this entry and to `docs/testing.md`. The "shared shape" narrative adds the classifier as a sixth instance of the same wrong-question pattern. The fast-path and full-update entry conditions and the Step 5 acceptance criteria are qualified with the type-coded rule.
- **`docs/recovery-partition.md`** — the invariant now says "exactly one **type-coded** recovery partition, on the OS disk" and lists the four places a label-only partition is rejected. The existing-partition acceptance criteria adds "It is type-coded" as a prerequisite. The pre-check `R` computation and the delete loop now count type-coded partitions only. The OS-shrink failure section names the failure-then-fallback corner explicitly, with a cross-reference to `docs/architecture.md` Step 5 and to this entry.
- **`docs/state-and-idempotency.md`** — the fast-path conditions and the offline-fallback local safety check now say "type-coded" for the recovery-partition-count and registered-partition conditions. The "when the ID does not change" list adds v44 patch 7 to the same-version roll call, and the harness-move list extends through v19 and v20.
- **`docs/testing.md`** — added a "v20 changes" subsection and a "v19 changes" subsection above the existing v18 subsection. Option 1's classifier verdict list now includes `LABEL-ONLY`. Added a new top-level section on the encrypted-C: failure-then-fallback test: the four preconditions, how to run it, what to record, and the gating requirement on future destructive-path changes.
- **`docs/troubleshooting.md`** — added a new section on the label-only non-convergence loop, with the classifier WARN as the diagnostic and the two convergence outcomes. The OS-fallback BitLocker section adds the compound log signature (`Pre-deletion inventory:` followed in the same run by `OS-fallback deferred: C: could not be confirmed fully decrypted`) for the failure-then-fallback corner. The bug-report guidance adds that compound signature to the list of data to include.
- **`docs/index.md`** — the "If something is broken" section converted to a bullet list and extended with the label-only non-convergence loop and the compound-signature corner. The reference-table descriptions for `architecture.md` and `recovery-partition.md` name the type-coded authority rule and the residual corner respectively. Versioning updated to production v44 patch 7 and harness v20.
- **`docs/deployment.md`** — the "Later v44 patches" list, the "Rollback for the later v44 patches" list, and the "Canary and ring deployment" guidance are extended to cover patch 7. The canary section describes the convergence change for machines whose only recovery-looking partition was label-only.
- **`docs/driver-injection.md`** — the extraction section documents the v44 patch 7 VMD extraction-directory cleanup alongside the existing OEM cleanup. The "Why this matters" discussion of the INF-basename cross-reference explains why the extraction directory must be fresh. A "Related to the VMD extraction cleanup (v44 patch 7)" paragraph sits in the pipeline-gate discussion.
- **`README.md`** — production marker bumped to v44 patch 7, harness to v20. The "What it does, in order" step 8 and step 10 name the type-coded qualification. A new "Known limitation" block under "Before you run this" documents the failure-then-fallback corner with the combined log signature. Field-tested hardware table adds the ASUS v44 patch 7 run, the Lenovo V15 G5 IRL, and the Dell Vostro 16 5640. Version section extended through patch 7 and the harness move list extended through v20.
- **`.github/ISSUE_TEMPLATE/bug_report.md`** — the example version string updated from v44 patch 6 to v44 patch 7.

`docs/exit-codes.md`, `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, and the remaining `.github/` files (PULL_REQUEST_TEMPLATE, FUNDING, feature_request, config) were reviewed and required no changes for patch 7.

### Known limitation (documented; not fixed in this revision)

Removing the v44 patch 3 pre-destructive C: guard in v44 patch 6 narrows the safety envelope in one specific corner. On a machine where **all four** of the following hold:

1. C: is encrypted (common on Win11 24H2+ with Device Encryption).
2. Destructive replacement of the existing recovery partition is required — natural on any rebuild: a `DesiredStateId` change, a manifest bump, a partition-size shortfall, or a CPU/VMD presence change.
3. The destructive attempt fails **after** the existing recovery partition has already been deleted — e.g. `New-Partition` failing, the shrink not fitting even after the defrag retry, or `Format-Volume` failing.
4. No successful retry occurs before the machine is needed.

...the machine ends up with neither a dedicated recovery partition nor OS-fallback, because the OS-fallback gate also refuses on an encrypted C: (reagentc refuses to enable WinRE on an encrypted OS volume regardless of protector state). Under the pre-v44-patch-6 guard, the same machine deferred **before** touching the current route, leaving the existing route intact.

Preconditions 1 and 2 are common. Preconditions 3 and 4 are the narrow part. On a machine with reasonable free space, the destructive path succeeds and the corner does not fire. The failure mode is real but it is a corner, not the main path.

**The correct response is not to reinstate the guard.** The guard's predicate — "is C: encrypted?" — cannot distinguish a destructive attempt that will succeed from one that will fail, and the field evidence below shows the destructive path succeeding cleanly on multiple encrypted-C: machines. A pre-destructive guard on C: encryption defers every destructive replacement on every encrypted-C: machine, including the ones that would have succeeded. That is the over-deferral the v43 patch 5 (further revision 5) target-volume finding already corrected, in exchange for suppressing a double failure (the destructive attempt fails **and** the OS-fallback gate refuses) that only manifests after the first failure has already occurred.

The correct response is a **post-failure** check in the shrink-failure branch that handles the case *after* the destructive attempt fails, not a pre-destructive veto. Such a check can distinguish "the attempt failed" from "the attempt might fail" — which is exactly what the guard's predicate cannot do. That work is tracked for a future patch and gated on the test documented below.

**Log signature.** An operator can recognize the corner from the log: a `Pre-deletion inventory:` block followed in the same run by `OS-fallback deferred: C: could not be confirmed fully decrypted`. `docs/troubleshooting.md` carries the combined signature and its interpretation.

### Field verification

- **Dell Vostro 16 5640 (Core 7 150U, Win 11 26200), 2026-10-01 12:22–12:30.** v44 patch 6. C: was `ProtectionStatus=Off`, `VolumeStatus=EncryptionInProgress` at 96.6%, no key protectors. The destructive path entered, WinRE was disabled, the existing 1000 MiB recovery partition was deleted, the OS partition was extended, the shrink succeeded on attempt 1 with no defrag retry, `New-Partition` succeeded with the recovery GUID applied at creation, the new partition was verified not encrypted, the WIM was deployed, and `reagentc /enable` returned exit 0 with status Enabled. The second run at 12:30:47 took the fast path — state file accepted, `Operating mode: DEDICATED`, no repeated work. This was the earliest of the four clean destructive runs on encrypted C: now on record; see the four-machine summary at the end of this section.

- **Lenovo V15 G5 IRL (i5-13420H, MT=83GW, Win 11 26200), 2026-10-01 13:11–13:15.** v44 patch 6. C: was `ProtectionStatus=Off`, `VolumeStatus=EncryptionInProgress` at 92.7%, no key protectors. Same clean destructive sequence: delete, extend, shrink attempt 1, `New-Partition` with the recovery GUID at creation, WIM deployed, `reagentc /enable` exit 0. The second run took the fast path. This run also exercised the v44 patch 6 Lenovo five-state resolution: the machine type 83GW has no published WinPE pack, the map resolution correctly produced `no-entry`, and the run was recorded as complete with `OEMPACK=NONE` rather than being marked incomplete.

- **ASUS desktop (PRIME H510M-D, i5-11400, Win 11 26300), 2026-10-01 14:02–14:04.** v44 patch 7. The first run took the **reuse** path: `Find-SuitableRecoveryPartition: candidate 4 on disk 4 is suitable (letter Z:)`. The existing 1100 MiB recovery partition was correctly identified as type-coded and adequate — 1082.2 MiB effective free against 1007 MiB required — and the deploy went into it with no delete, no extend, no shrink, and no recreate. This is the concrete demonstration that patch 1 does what it was designed to do: reuse an adequate recovery partition rather than churn the disk. The second run took the fast path.

- **Dell Vostro 16 5640 (Core 7 150U, Win 11 26300), 2026-10-01 14:28–14:32.** v44 patch 7. Second run on this physical machine, now on build 26300. C: was `ProtectionStatus=Off`, `VolumeStatus=EncryptionInProgress` at 94.9%. The `DesiredStateId` changed (build component), so the machine correctly rebuilt and re-converged rather than taking the fast path: clean destructive sequence — delete, extend, shrink attempt 1, `New-Partition` with the recovery GUID applied at creation, new partition verified not encrypted, WIM deployed, `reagentc /enable` exit 0 with status Enabled, `Operating mode: DEDICATED`. The second run at 14:32:38 took the fast path.

- **Dell Latitude 5530 (i5-1245U, 12th Gen, Win 11 26300), 2026-10-01 15:08–15:13.** v44 patch 7. C: was `ProtectionStatus=Off`, `VolumeStatus=EncryptionInProgress` at 78.5%. Same clean destructive sequence — delete, extend, shrink attempt 1, `New-Partition` with the recovery GUID applied at creation, new partition verified not encrypted, WIM deployed, `reagentc /enable` exit 0 with status Enabled, `Operating mode: DEDICATED`. Fast path at 15:14:39. This unit is **distinct from** the i7-1265U Latitude 5530 that motivated the v43 patch 5 (further revision) Audit Mode guard — the two are different machines and must not be conflated.

- **ASUS Vivobook X1504VA (i3-1315U, 13th Gen, Win 11 26300), 2026-10-01 15:12–15:14.** v44 patch 7. C: was `ProtectionStatus=Off`, `VolumeStatus=EncryptionInProgress` at 90.6%. Clean destructive rebuild — delete, extend, shrink attempt 1, `New-Partition` with the recovery GUID applied at creation, new partition verified not encrypted, WIM deployed, `reagentc /enable` exit 0 with status Enabled, `Operating mode: DEDICATED`. Fast path on the second run at 15:15:08. This run also exercised the v44 patch 7 diagnostic WARN reporting C:'s encryption state before proceeding.

- **Dell Latitude 3550 (Core Ultra 5 125U, Win 11 26200), 2026-09-28, v43.** C: was `ProtectionStatus=Off`, `VolumeStatus=EncryptionInProgress` at 94.2%, no key protectors. Across four logged runs on that date, the destructive path completed delete, OS extend, OS shrink (attempt 1, no defrag), `New-Partition`, and `Set-PartitionAttributes`. The failure was isolated to the newly created partition being auto-encrypted by Device Encryption — the problem v43 patch 5 subsequently addressed by applying the recovery GUID at creation. This is the field evidence that the destructive path reaches and completes every pre-create step on an encrypted-C: machine; the create-step failure was a separate problem, not a consequence of C:'s state.

- **Dell Pro 14 PC14250 (Core 5 120U) and Dell 15 DC15250 (i7-1355U), 2026-09-30, v44 patch 5.** Both machines had encrypted C: (94% and 90% `EncryptionInProgress` at time of diagnostic). Both deferred under the pre-v44-patch-6 guard with the log line `Destructive recovery-partition replacement would remove the current WinRE route, and C: is not confirmed fully decrypted (Test-VolumeEncrypted=True). Deferring to preserve the current recovery environment.` These are the machines the guard removal unblocks: on the next rebuild they will attempt the destructive path instead of deferring.

**Four distinct machines now confirm the guard-free destructive path succeeds on encrypted C:** the Dell Vostro 16 5640 (on both 26200 and 26300), the Dell Latitude 5530 (i5-1245U), the Lenovo V15 G5 IRL, and the ASUS Vivobook X1504VA. All four entered the destructive path with C: mid-encryption (`EncryptionInProgress` at 78.5%–96.6%), completed delete/extend/shrink/`New-Partition`/format/attribute, verified the new partition not encrypted, deployed the WIM, and reached `reagentc /enable` exit 0 with status `Enabled`. The v44 patch 7 diagnostic WARN correctly reported C:'s encryption state in each destructive run. This is the field evidence supporting the v44 patch 6 decision not to reinstate the pre-destructive C: guard. The failure-then-fallback corner remains untested — see the "Known limitation" section above and the pending-test note below.

### Pending test (gating future destructive-path changes)

The failure-then-fallback corner has not been exercised in the field. No logged run has yet shown a destructive attempt that failed **after** deletion with C: encrypted. Until such a test runs — ideally a deliberate shrink failure on an encrypted-C: machine, or a naturally-occurring one on a constrained disk — no further changes to the destructive path should ship. The test is documented in `docs/testing.md`.

### Unchanged

`ScriptVersion` remains 44. `DesiredStateId` is unchanged. No fleet-wide rebuild is forced. Healthy machines continue to take the fast path. A machine that is already healthy will not rerun automatically; the deployment mechanism must invoke the script explicitly to pick up the patch-7 changes. A machine whose next natural rebuild is already due (manifest bump, OEM pack version change, Windows build change, or CPU/VMD presence change) picks up the patch-7 changes on that rebuild.

### Notes

- **Label-only recovery partitions on the OS disk are no longer reused but also not deleted.** A label alone is not sufficient authority for deletion — consistent with the existing policy in `Remove-StrayRecoveryPartitions` and `Ensure-AdequateRecoveryPartition`. Label-only partitions may therefore persist across runs as clutter on the OS disk. This is intentional design, not an oversight: the alternative (deleting them) would require relaxing the type-code gate that every deletion decision in the script depends on.
- **`Test-WinRE.ps1` moves from v19 to v20** in the same window. The classifier mirror is the substantive change; the menu-box alignment is cosmetic.

## [harness v19] — 2026-09-30

Two Option S corrections in the read-only harness. Production `WinRE.ps1` is unaffected; this entry is the harness's own version marker.

### Fixed

- **Option S reports SKIP (not PASS) when the state file is absent and the VMD query is indeterminate.** Before v19, `Show-StateFileParity` checked for the state file's existence before consulting the VMD query result, and returned `PASS` with detail `no state file (rebuild expected)` whenever the file was missing. That was correct when VMD presence was determinable, but wrong when the VMD query had failed: production defers the entire run with `EXIT_WARNING` in that case rather than taking the full-update path, and the harness's `PASS` disagreed with what a live run would do. The missing-state-file branch now checks `$vmdQueryOk` and records `SKIP` with detail `No state file; VMD query indeterminate`, printing a short explanation that production would defer rather than start the update. The existing `INDETERMINATE`/`SKIP` handling for the state-file-present case is unchanged.
- **Option S wording clarified.** The header now reads "does the stored DesiredStateId match current inputs? This is not a full-flow simulation." The DSI MATCH verdict now reads "the stored deployment ID matches current inputs" followed by a note that production separately evaluates WinRE state/location, recovery-partition count, active WIM hash, pending-reboot/repair state, BitLocker, and other startup/flow gates before deciding what to do. The prior wording — "production will accept the state file" — implied that DSI equality alone was sufficient, which overstated what the check proves.

### Changed (docs)

- **`docs/testing.md`** — added a v19 version-history entry and a "v19 changes" subsection describing both Option S corrections; updated the Option S section heading and body to reflect the new no-state-file SKIP verdict and the clarified scope paragraph; updated the "Output style" heading to note that v19 did not change the output format; updated the parser self-test heading to note that v19 did not change the check count; added the Option S VMD-query-indeterminate case to the "What a SKIP means" list; added a clarifying parenthetical to the "Result states" section about Option S recording a result for the parity check itself; extended the fifth "differences from production" bullet to cover the v19 refinement.
- **`docs/index.md`** — updated the harness version to v19 in the Versioning section and in the "two scripts" harness bullet; added the v18→v19 move to the sequence of harness moves; added a note that v19 corrected Option S; corrected the production-script bullet to lead with the operations ("Runs elevated on a single machine, or as `SYSTEM` under a scheduled task on a managed fleet") rather than presenting SYSTEM as definitional.
- **`README.md`** — updated the "See it in action" banner to v19; updated the harness version to v19 in the Version section; added a note that the v19 change is confined to Option S and no managed machine rebuilds; clarified the ASUS field-verification row to note that v19 changes Option S only.
- **`SECURITY.md`** — corrected the opening line and the privilege bullet to describe both execution modes (elevated for single-machine repair, `SYSTEM` for fleet deployment) rather than presenting SYSTEM as definitional.
- **`CONTRIBUTING.md`** — corrected the opening line to say "runs with administrative privilege and modifies partition tables" rather than naming only the SYSTEM deployment mode.

### Unchanged

The harness's extraction cleanup, user-supplied `TestDir` protection, VMD-indeterminate reporting for the state-file-present case, Lenovo five-state resolution mirror, and parser self-test are unchanged. `Test-WinRE.ps1` remains read-only, requires no elevation, and modifies nothing. Production `WinRE.ps1` v44 patch 6 is unaffected.

## [v44 patch 6] — 2026-09-30

> **Note.** The claim in this entry that "the safety property — never leave a machine with no working recovery route — is preserved end-to-end without the guard" was found to be inaccurate on review. Removing the guard narrows the safety envelope in a specific corner: C: encrypted, destructive replacement needed, destructive attempt fails after deletion, no successful retry. The correct response is a post-failure check in the shrink-failure branch, not a reinstatement of the guard. See [v44 patch 7](#v44-patch-7--2026-10-01) for the corrected statement, the field evidence, and the residual failure mode.

Removes the v44 patch 3 destructive-path C: guard, makes Lenovo OEM-pack resolution distinguish five states, makes VMD hardware detection fail-closed, closes a Step 2 wedge left by interrupted runs, corrects the OS-fallback remediation wording, and mirrors the production changes into the harness as v18.

The change was driven by a review of the v44 patch 3 guard in light of the v43 patch 5 (further revision 5) target-volume policy that the guard was built on top of. The guard was correct in spirit — prevent the destructive path from leaving a machine with no working recovery route — but it applied an OS-fallback precondition to the dedicated-partition path. The dedicated-partition path does not depend on C:'s BitLocker state at all; reagentc's check is on the **target** volume, and on the dedicated-partition path the target is the recovery partition. The guard was deferring runs that would have succeeded.

### Changed

- **C:'s encryption state is no longer a veto for the dedicated-recovery-partition path.** The v44 patch 3 destructive-path C: guard inside `Ensure-AdequateRecoveryPartition` has been removed. When the destructive path is about to run and the run will destroy the current recovery route (WinRE `Enabled` or a non-empty deletable-part set), the function still logs the `Destructive recovery-partition replacement will remove the current WinRE route` WARN, but it no longer calls `Test-VolumeEncrypted -MountPoint "C:"`, no longer returns `$null` on a non-`FullyDecrypted` result, and no longer defers via the OS-fallback machinery. The destructive sequence proceeds.

  **Why the guard was removed.** The v44 patch 3 guard was added preemptively on the reasoning that the destructive path could disable WinRE and delete a recovery partition on a machine whose C: was not in a state where the OS-fallback route — the path the destructive attempt falls through to on shrink failure — could itself complete. That reasoning over-applied the OS-fallback precondition to the dedicated-partition path. The dedicated-partition path's objective is to **create** a dedicated partition; it succeeds or fails on the partition geometry, not on C:'s BitLocker state. If the dedicated-partition path succeeds, C:'s state never matters. If it fails at the shrink step, the run falls through to OS-fallback, and *there* the OS-fallback gate checks C: and defers as designed.

  The only place C:'s BitLocker state is now consulted is the OS-fallback route: the fast-path OS-fallback re-verification, the full-update deploy step's OS-fallback branch, and the pending-reboot OS-fallback branch. All three exist because on the OS-fallback route the target volume *is* the OS volume, and reagentc refuses to enable WinRE on an encrypted OS volume. The dedicated-partition path — including the destructive sequence — does not consult C:'s state at any point.

- **Lenovo OEM-pack resolution now distinguishes five states.** `Get-LenovoWinPEPack` sets `$Script:LenovoPackResolution` to one of `unknown-mt`, `map-unavailable`, `no-entry`, `malformed-entry`, or `resolved`. The caller uses the state to distinguish "this Lenovo model has no published WinPE driver pack" (normal, expected, run recorded as complete with `OEMPACK=NONE`) from "the map entry exists but is missing its `winpe.url`" (configuration failure, run marked incomplete). Before patch 6, the caller could distinguish a map-fetch failure from a no-pack answer, but could not distinguish a malformed map entry from a legitimate no-pack case; both produced the same `$null` return and the same handling, and the machine would silently complete without OEM driver injection even though the map itself was broken.

  Lenovo does not publish WinPE driver packs for every model in their catalog. `unknown-mt` and `no-entry` are the two states that represent that fact, and both correctly let the run proceed with `OEMPACK=NONE`. `map-unavailable` (transient network failure fetching the map gist) and `malformed-entry` (map entry present but missing `winpe.url`) both mark the run with `$Script:ImageInjectionComplete = $false` and `$Script:nonFatalWarning = $true`; the pipeline gate then aborts before Step 4 and the next run retries. A malformed map entry is a configuration failure of the map itself, not a legitimate "no pack available" answer.

- **VMD hardware detection is now fail-closed.** The VMD presence query wraps `Get-PnpDevice -PresentOnly` in `-ErrorVariable vmdErr` and treats any enumeration error as an indeterminate result, not as "VMD hardware absent". Previously, an enumeration error would produce an empty device list, `$vmdPresent` would be set to `$false`, and the run would proceed to select a driver set that omits the VMD package on a machine that may well have VMD hardware. On a VMD-based machine whose deployed WinRE lacks the VMD driver, the recovery environment cannot see the OS disk — this is the failure mode the v44 patch 1 `DesiredStateId` change was designed to prevent, and patch 6 closes the remaining path by which it could still occur.

  On an indeterminate VMD query the run logs the enumeration error, sets `$Script:nonFatalWarning = $true`, removes the checkpoint file, and exits with `EXIT_WARNING` **before** committing any state. No WIM is deployed, no partition is touched, no `reagentc` call is made. The next run retries the enumeration; a transient PnP service issue is the most likely cause.

- **Step 2 removes stale `winre.wim` and `base.wim` before extraction and rename.** When the base WIM is obtained from the GitHub repository — the path reached only when no usable WIM exists at the reagentc-registered location or via fallback — Step 2 now:

  1. Removes any stale `winre.wim` at `$WorkDir\winre.wim` before invoking 7-Zip, in case an interrupted previous run left the extraction output partially written.
  2. Verifies that 7-Zip produced `winre.wim` after extraction.
  3. Removes any stale `base.wim` at `$WorkDir\base.wim` before the `Rename-Item "$WorkDir\winre.wim" "base.wim"` call.

  Before patch 6, an interrupted previous run could leave a `base.wim` in place at the moment the next run reached the rename. The rename would fail, and the machine would not progress past Step 2 until an operator deleted `WorkDir` by hand. The v44 patch 3 fix added the same `base.wim` cleanup to the **injection-failure abort branch**; patch 6 adds it to the **normal Step 2 path** so the wedge is closed whether the previous run failed in injection or in the download-and-rename step itself.

- **OS-fallback remediation wording corrected.** The log message the OS-fallback gate emits when it defers has been rewritten. The previous message told the operator that the machine could be made ready for OS-fallback by "completing encryption, adding a protector, or enabling protection." That was wrong: those actions make C: *more* encrypted, not less, and reagentc refuses to enable WinRE on an encrypted OS volume regardless of which protector is present or whether protection is armed.

  The corrected message tells the operator what actually resolves the state — complete decryption of C: (`manage-bde -off C:`) or waiting for an in-progress decryption to finish — and states explicitly that the OS-fallback route requires C: to be `FullyDecrypted`. The corrected message also points at the dedicated-partition path as the alternative when decryption of C: is not an option, because the dedicated-partition path does not depend on C:'s BitLocker state.

- **The 2 GiB sanity ceiling note now names three functions consistently.** The `.NOTES` block in `scripts/WinRE.ps1` names three functions that the future ceiling must gate: `Ensure-AdequateRecoveryPartition`, `Find-SuitableRecoveryPartition`, and `Remove-StrayRecoveryPartitions`. The README, the `[v44 patch 2]` and `[v44 patch 3]` CHANGELOG entries, and `docs/recovery-partition.md` previously named two, omitting `Remove-StrayRecoveryPartitions`. That function deletes any type-coded recovery partition on a non-OS disk without checking size — the same class of hazard the ceiling is designed to guard against, and one that is reached by a different code path than the other two. All four references now name three.

### Changed (harness)

- **`Test-WinRE.ps1` moved to v18.** Six behavior changes, five new future-proofing checks, and three cosmetic fixes.

  Mirror drift from production patch 6:

  1. **VMD query-failure handling.** Options 1 and S now treat a PnP enumeration error as an indeterminate result rather than absence. Option 1's VMD hardware presence section reports `INDETERMINATE` with the enumeration error message. Option S records `SKIP` in the results with reason `VMD query indeterminate` and prints an `INDETERMINATE` verdict instead of a DSI MATCH or DSI MISMATCH. Before v18, the harness could produce a "definitive" DSI that disagreed with what a live production run would compute, which is the opposite of what Option S is for.
  2. **Lenovo map resolution status machine.** `Get-LenovoWinPEPack` in the harness now sets `$Script:LenovoPackResolution` to the same five states as production. `Test-OemMaps` distinguishes `malformed-entry` (red, marks the test failed) from `no-entry` (gray, informational), and treats `map-unavailable` (yellow, marks the test failed) separately from both.

  Harness-specific bugs:

  3. **`Get-DriverManifest` extracted as a shared helper.** Options 2, 9, and S now all use the same two-attempt / 2-second-sleep / WARN-log retry policy that production uses. Previously each option had its own fetch code, and they had drifted from each other and from production.
  4. **Cleanup footgun closed.** The harness refuses to delete `$TestDir` on exit when the directory pre-existed the run and already contained entries. The pre-existing state is captured before any directory work. This prevents `Remove-Item $TestDir -Recurse -Force` from wiping a user-supplied path like `C:\Users\Me\Desktop`.
  5. **Stale extraction destinations are cleared before each extraction.** Applies to `Invoke-VendorExtraction`, `Invoke-CabExtraction`, and the GitHub base-WIM test's working directory. Before v18, a stale INF file left by an earlier run could satisfy a failed extraction's INF-count success check. The Lenovo "non-zero exit but INFs present" branch was the sharpest case: it treats an INF-count greater than zero as success regardless of the extractor's exit code, so a stale INF could mask a genuine extraction failure.
  6. **`Test-VmdDrivers` records SKIP (not PASS) when the Intel CPU generation cannot be parsed.** Driver applicability was not evaluated in that case, so a PASS would misrepresent what the harness actually checked. The raw CPU string is logged so the parser can be extended. The result detail reads `Intel CPU generation could not be parsed`.

  Future-proofing checks added to the parser self-test (production dependency verification):

  7. **DISM cmdlet availability.** Verifies `Mount-WindowsImage`, `Dismount-WindowsImage`, `Get-WindowsImage`, `Add-WindowsDriver`, and `Get-WindowsDriver` are all present. Production hard-depends on all five; a missing cmdlet would only be discovered at injection time.
  8. **`Get-Disk` shape.** Verifies `Number`, `FriendlyName`, `PartitionStyle`, `Size`, `BootFromDisk`, `IsSystem`, and `IsBoot` are present.
  9. **`Get-Volume` shape.** Verifies `DriveLetter`, `FileSystemLabel`, `FileSystem`, `Size`, `SizeRemaining`, `DriveType`, `HealthStatus`, and `UniqueId` are present.
  10. **CPU-generation parser regression table.** Fourteen cases spanning 11th, 12th, 13th Gen, Core, Core Ultra, AMD, Celeron, Pentium, Xeon, and Atom CPU strings. Catches a Windows update or firmware rename that changes `Win32_Processor.Name` in a way that would silently desynchronise `DesiredStateId`.
  11. **`DesiredStateId` determinism and input sensitivity.** Same inputs must hash identically; flipping VMD presence must change the hash; flipping `ProductionScriptVersion` must change the hash; the output must be 64 hex characters. A silent change to the DSI recipe would be caught before it desynchronised every deployed state file.

  Cosmetic fixes:

  12. **`Write-KV` overflow handling.** A key at or past `$KeyWidth` now gets a separating space before its value. Previously, `Manifest VMD device IDs` (23 chars, one over the 22-char key column) rendered flush against the value.
  13. **`Test-WinRE.ps1`'s `.NOTES` block count.** The v18 future-proofing regression check count was corrected from "Four" to "Five" to match the number of bullets listed.
  14. **`Test-WinRE.ps1`'s `.NOTES` block wording.** For the `Test-VmdDrivers` SKIP path, the phrase "in the detail" was corrected to "in the log line" (the raw CPU string is logged via `Say`, not recorded in `Record -Detail`).

### Changed (docs)

- **`docs/troubleshooting.md`** — the "v44 patch 3 — the destructive-path guard" section is removed. The OS-fallback deferral section is unchanged except for the deletion of the sub-variant A/B discriminator, which referred to the removed guard.
- **`docs/exit-codes.md`** — the sub-variant A/B breakdown of the OS-fallback BitLocker deferral is removed. The `Pre-deletion inventory:` discriminator no longer applies; the guard's deferral line is no longer logged.
- **`docs/architecture.md`** — Invariant 13 (destructive-path C: guard) is removed. The "same shape" narrative in the closing section no longer uses the guard as an example of preemptive correctness.
- **`docs/deployment.md`** — the "v44 patch 3" section is reduced to the `base.wim` cleanup only; the C: guard discussion is removed.
- **`docs/recovery-partition.md`** — section 2 is simplified to "disable WinRE" with no C: check.
- **`docs/state-and-idempotency.md`** — the paragraph describing the destructive-path C: guard's effect on the state file is removed.
- **`docs/driver-injection.md`** — a new section documents the Lenovo five-state resolution and why `unknown-mt` and `no-entry` are legitimate "no pack" answers while `map-unavailable` and `malformed-entry` are not.
- **`.github/ISSUE_TEMPLATE/bug_report.md`** — the sub-variant A/B discriminator field is removed; the OS-fallback deferral log-string example is corrected from `C: VolumeStatus=…` to `Test-VolumeEncrypted=…`.
- **`SECURITY.md`** — a new bullet under "Known limitations (not vulnerabilities)" documents the offline-fallback trust model, names the residual hardware-drift risk, and clarifies that the state file's editability is a documented correctness limitation rather than a privilege boundary crossing.

### Removed

- **The v44 patch 3 destructive-path C: guard.** `Ensure-AdequateRecoveryPartition` no longer calls `Test-VolumeEncrypted -MountPoint "C:"`, no longer returns `$null` on a non-`FullyDecrypted` result, and no longer defers via the OS-fallback machinery when C: is encrypted. The `Destructive recovery-partition replacement would remove the current WinRE route, and C: is not confirmed fully decrypted` deferral line is no longer logged. When the destructive path is about to run, the function logs `Destructive recovery-partition replacement will remove the current WinRE route. … C:'s BitLocker state is not a veto for the dedicated-target path. The OS-fallback route retains its separate C: BitLocker gate.` and continues.

### Unchanged

`ScriptVersion` remains 44. `DesiredStateId` is unchanged. No fleet-wide rebuild is forced. Healthy machines continue to take the fast path. A machine that is already healthy will not rerun automatically; the deployment mechanism must invoke the script explicitly to pick up the patch-6 changes. A machine whose next natural rebuild is already due (manifest bump, OEM pack version change, Windows build change, or CPU/VMD presence change) picks up the patch-6 changes on that rebuild.

### Field verification

- **Harness v18 on ASUS desktop (PRIME H510M-D, i5-11400, Win11 26200), 2026-09-30.** Option 1 diagnostic completed. All fifteen parser self-test checks PASS: reagentc status and location regexes, both `manage-bde` regexes, `Get-BitLockerVolume` shape, OS resolution, `Get-Partition` shape, WinRE location resolution, `Get-RecoveryPartitions`, `Get-PartitionSupportedSize`, the five v18 additions (DISM cmdlets, `Get-Disk` shape, `Get-Volume` shape, CPU-generation regression table, `DesiredStateId` determinism). 15 passed, 0 failed, 0 skipped. The `Write-KV` overflow fix was verified visually: `Manifest VMD device IDs PCI\VEN_8086&DEV_9A0B, …` renders with the separating space.
- **Production v44 patch 6.** Pending. The intended coverage is a fast-path run on a machine whose state file matches, followed by a full-update run on a machine whose state file has been deleted. Neither has been exercised on real hardware yet; both are the same code paths as v44 patch 5 with the five patch-6 changes layered on.

## [v44 patch 5] — 2026-09-30

Offline fallback for the driver manifest fetch, network timeouts on every call, and two harness refinements.

The change was driven by a 2026-09-30 field observation on a healthy ASUS desktop: the manifest fetch failed with `FATAL ERROR: The remote name could not be resolved: 'gist.github.com'` on a machine whose state file was still valid. The manifest fetch runs before the fast-path decision, so a DNS failure took a healthy machine down to `EXIT_FATAL` without any local state being wrong. The run had done nothing to warrant a fatal exit; it simply could not reach the network to prove what the state file already recorded.

### Added

- **Offline fallback for the manifest fetch.** When the driver manifest fetch fails after its retry budget, the script now reads the state file at `C:\Recovery\OEM\winre_state.json` and trusts its stored `DesiredStateId` directly. It does **not** attempt to recompute the ID from cached inputs — recomputing would require the OEM pack version, which is resolved from the OEM map, another gist on the same unavailable network. The local safety checks (WinRE `Enabled`, exactly one recovery partition on the OS disk, deployed WIM hash matches the stored hash) remain fully enforced and do not depend on the manifest. If the fast path does not fire under the offline fallback, the run exits `EXIT_WARNING` before the full-update pipeline and the machine retries on its next scheduled run when the network is available. The residual risk is named below.

- **`$NetworkTimeoutSeconds = 15` on every network call.** Previously, `Invoke-RestMethod` and `Invoke-WebRequest` defaulted to roughly 100 seconds each. On a fully offline machine with a stale cache, the aggregate worst-case runtime was over 10 minutes before the offline fallback could engage. All eight network calls in `WinRE.ps1` now carry `-TimeoutSec $NetworkTimeoutSeconds`. The fully offline worst-case runtime dropped to roughly 90 seconds, dominated by the fixed sleeps in the retry loops rather than by the network timeouts. The last of the eight calls — the GitHub API listing reached only in the full-update path when no local WIM is available — was applied in a follow-up edit within the same patch.

### Changed

- **`Test-WinRE.ps1` moved to v17.** Three changes. `$NetworkTimeoutSeconds = 15` was added and applied to every network call, matching production. `Invoke-OemPackDownload`'s zero-byte check was moved back above the `$hasHash` computation so that a zero-byte download with an expected hash logs `file is empty` rather than `SHA256 mismatch`. A note was added to `Test-VmdDrivers` stating that the harness intentionally exercises every OS/CPU-eligible driver to validate the download path, whereas production additionally filters on VMD hardware presence. The harness output format is unchanged from v16.

- **`docs/troubleshooting.md`, `docs/exit-codes.md`, and `docs/deployment.md`** gained an offline-deferral section. See the individual documents.

### Known limitation (introduced by this patch; not fixed)

The offline fallback trusts the state file's stored `DesiredStateId` without verifying that the machine's local hardware still matches the inputs that produced it. On a machine whose hardware changed while offline — a CPU swap, a BIOS update that flipped VMD, or a motherboard replacement that changed `Manufacturer` / `Model` / `MachineType` — the offline run could take the fast path with a stale DSI and exit `EXIT_WARNING` on a machine that would have rebuilt under the live manifest. The next successful manifest fetch detects the drift and forces a rebuild. A `LocalInputsId` field in the state file would close this; it is planned as its own version boundary and is documented in [docs/state-and-idempotency.md](docs/state-and-idempotency.md).

### Field verification

- **ASUS desktop (PRIME H510M-D, i5-11400, Win11 26200), 2026-09-30 13:22.** The motivating observation: the pre-release version of patch 5 exited `FATAL ERROR: The remote name could not be resolved: 'gist.github.com'` on a healthy machine. The initial implementation was wrong in a way that the offline case exposed — it recomputed the DSI from cached inputs, which fails on a fully offline machine because the OEM map fetch (a different gist) also fails, producing `OEMPACK=NONE` in the candidate DSI versus the state file's `OEMPACK=A10`. The corrected implementation trusts the state file directly.

- **ASUS desktop, 2026-09-30 15:08:36 and 15:08:57.** Two consecutive v44 patch 5 fast-path runs. Both runs: banner `(v44 patch 5)`, `Acquired program lock at C:\ProgramData\OEM\Logs\WinREManager.lock`, manifest fetch succeeded, DSI `62DE5C7D…` matched the on-disk state file, `Assigned temporary drive letter Z:` followed by `Removing temporary drive letter Z:`, `Operating mode: DEDICATED`, `Released program lock`. Both runs exited 0. No contention, no warnings, no leaked drive letters. This is the healthy online path.

- **Offline verification.** Pending. The intended coverage is a hosts-file block on the ASUS (`0.0.0.0 gist.github.com` and `0.0.0.0 api.github.com`) followed by a run of `WinRE.ps1`, expecting: two `Driver manifest fetch attempt N failed` lines, the offline-fallback engage line with a `state file LastUpdated=…` suffix, four `Offline fallback: skipping …` lines, `Checkpoint step: 0`, `State file accepted (DesiredStateId match)`, `Operating mode: DEDICATED`, `Released program lock`, exit code 2, total runtime under 90 seconds.

### Unchanged

`ScriptVersion` remains 44. `DesiredStateId` is unchanged. No fleet-wide rebuild is forced. Healthy machines continue to take the fast path.

## [v44 patch 4] — 2026-09-30

Single-instance guarantee via an exclusive file lock, closing the concurrent-instance defect first observed on the Dell Latitude 3550.

The change was driven by a 2026-09-30 field observation on the Dell Latitude 3550 (12:29–12:40). Two `WinRE.ps1` processes ran simultaneously on the same machine, one of them exiting on `Cannot rename because item at 'C:\Temp\WinREWork\winre.wim' does not exist.` The script assumed exclusive access to `C:\Temp\WinREWork` but had no startup lock. The scheduled task's `MultipleInstancesPolicy = IgnoreNew` prevents scheduled-vs-scheduled overlap but does nothing about manual invocations (interactive shells, RMM "run now" buttons, Intune remediation scripts).

### Added

- **Program lock via an exclusive file handle.** Before any state-modifying action, `WinRE.ps1` opens `C:\ProgramData\OEM\Logs\WinREManager.lock` with `FileShare.None` via `[System.IO.File]::Open($path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)`. The Windows kernel enforces the exclusive handle: cross-session, cross-privilege exclusion is guaranteed by the OS, not by a security descriptor the script would have to configure. The handle is released automatically when the process exits, cleanly or after a crash — there is no stale-lock recovery logic to get wrong. The lock file is not deleted on release; its existence is not the lock, the open handle is.

  **The lock is deliberately not acquired under `-DryRun`.** A dry run is read-only and safe to run concurrently with a live deployment, so an operator can inspect a machine with `WinRE.ps1 -DryRun` or `scripts\Test-WinRE.ps1` while a scheduled run is in progress.

  **Failure to open the lock file for any reason other than contention is non-fatal.** A permission error, a missing `Logs` directory, or a transient filesystem issue causes the script to log a WARN and proceed without single-instance protection. The lock is defensive: a broken lock must not prevent a legitimate deployment.

  **The lock is released last.** In the `finally` block, after the WIM-mount discard and after every temporary drive letter has been cleaned up. This ensures the lock is held until all cleanup is complete, so a waiting second instance cannot begin work while the first is still releasing resources.

### Changed

- **`docs/deployment.md` — "One instance per machine" section** rewritten. The section previously stated that the script had no lock and that exclusive operation was the operator's responsibility. It now leads with the file lock and describes the failure mode of a second instance: it fails fast with `Another WinRE Manager instance is already running (program lock file is exclusively held)` and exits `EXIT_WARNING` (code 2), not `EXIT_FATAL` (code 3). The mitigations for manual invocations (wait for the scheduled task, temporarily disable it, use the harness) remain as secondary guidance. A new note clarifies that the lock file persists on disk between runs and that its presence does not indicate a running instance.

- **`docs/troubleshooting.md` — "The script exited with a rename error (concurrent instance)" section** rewritten. The rename error is now reachable only if the lock acquisition fails for a permission reason and the run proceeds unprotected. The primary concurrent-instance failure shape is now a fast exit with `EXIT_WARNING` and the `Another WinRE Manager instance is already running` log line. A new log-string reference for the lock-acquisition failure sub-case (`Could not set up program lock at … : … - proceeding without single-instance protection`) is included.

- **`docs/deployment.md` — Intune/MDM section.** The prediction that a remediation that coincides with a scheduled run would exit `EXIT_FATAL` was corrected to `EXIT_WARNING`.

### Field verification

- **Dell Latitude 3550, 2026-09-30 12:29–12:40.** The concurrent-instance defect that motivated this patch. Two processes running, one exiting on the rename error. Post-patch, this run shape produces one successful run and one fast-fail exit with `EXIT_WARNING`.

- **ASUS desktop, 2026-09-30 14:04:37.** First successful field run of the file lock. Log shows `Acquired program lock at C:\ProgramData\OEM\Logs\WinREManager.lock` early in the run and `Released program lock` at the end. Only one instance was running, so the concurrent-failure path was not exercised; the mechanism itself was confirmed.

- **ASUS desktop, 2026-09-30 15:08:36 and 15:08:57.** Two consecutive v44 patch 5 runs (which inherit patch 4). Both runs show the acquired/released lock pair, confirming the lock release is not blocking subsequent runs even when the runs are seconds apart.

- **Concurrent-instance test (Test C from the hand-off).** Pending. The intended coverage is a second interactive invocation of `WinRE.ps1` while a first is mid-flight, expecting the second to log `Another WinRE Manager instance is already running (program lock file is exclusively held)` and exit code 2 within seconds.

- **Crash-recovery test (Test D from the hand-off).** Pending. The intended coverage is a PowerShell process killed mid-flight followed by a fresh run, expecting the fresh run to acquire the lock immediately with no stale-lock loop. The design guarantees this — the kernel releases the handle on process termination — but it has not been exercised.

### Unchanged

`ScriptVersion` remains 44. `DesiredStateId` is unchanged. No fleet-wide rebuild is forced. The lock acquisition is transparent to all downstream logic; no existing behavior depends on whether the lock is held.

## [v44 patch 3] — 2026-09-30

> **Note.** The destructive-path C: guard described in this entry was removed in [v44 patch 6](#v44-patch-6--2026-09-30). The `base.wim` cleanup on the injection-failure abort branch remains, and its description below is still accurate. See the patch 6 entry for the reasoning behind the reversal.

Two targeted correctness fixes from the v44 patch 2 peer-review round, a harness beautification (v16), and an extension of the documented 2 GiB ceiling known gap to name both affected code paths.

Both fixes are small and scoped. Neither changes `ScriptVersion`, neither changes the `DesiredStateId`, and neither forces a rebuild on any machine. Already-completed machines will not rerun automatically; the deployment mechanism must invoke the script explicitly to pick the fixes up.

### Fixed

- **Destructive-path C: encryption guard in `Ensure-AdequateRecoveryPartition`.** Before the `reagentc /disable` call, if the path is about to destroy the current recovery route — either WinRE is `Enabled` or `$deletableParts.Count -gt 0` — the function now checks C: via `Test-VolumeEncrypted -MountPoint "C:"`. If the result is not exactly `$false` (confirmed fully decrypted), it logs the reason, sets `$nonFatalWarning`, and returns `$null` without touching WinRE registration, partitions, or drive letters. The `$null` return propagates to the OS-fallback machinery, which then defers. This closes the gap ChatGPT identified in the v44 patch 2 round: the destructive path could disable WinRE and delete a recovery partition on a machine whose C: was not in a state where the OS-fallback route could complete, leaving the machine without a working recovery route. The guard is scoped to the destructive path only. It is **not** a reinstatement of the global C: startup gate, which the 2026-09-29 same-machine differential test disproved. The code comment names the reason, per the standing rule that any new C: check must be scoped and justified. **(Removed in [v44 patch 6](#v44-patch-6--2026-09-30).)**
- **`Remove-ItemIfExist "$WorkDir\base.wim"` in the failed-injection abort branch.** The abort branch already removed `winre_optimized.wim`; it did not remove `base.wim`. Without the extra line, the next run's Step 2 failed at `Rename-Item "$WorkDir\winre.wim" "base.wim"` because the destination file existed. The machine never progressed past Step 2 until an operator deleted `WorkDir` by hand. This is a genuine defect on the injection-failure path, not a hypothetical.

### Changed

- **`Test-WinRE.ps1` moved to v16.** The harness is colour-coded. Disks, partitions, volumes, recovery partitions, and the parser self-test are rendered as tables. Free-space values are colour-coded against explicit thresholds: Red below 5% **or** below 3 GB; Yellow below 15% **or** below 20 GB; Green otherwise. The colour rules apply to Fixed volumes only; CD-ROM and Removable volumes keep neutral colours because their free space is not a deployment constraint. A boxed warning banner is drawn when the OS volume's free space is critical. Diagnostic output uses `Write-Diag` and `Write-KV` instead of `Say` so key/value pairs align and values render with the correct colour. The harness remains read-only, and its menu structure, parser self-test, download test, and extraction test are unchanged. See the `.NOTES` block in `scripts/Test-WinRE.ps1` for the full v16 change list.

### Known limitation (extended in this revision; not fixed)

The v44 patch 2 entry documented the destructive path in `Ensure-AdequateRecoveryPartition` as the exposure for the planned 2 GiB sanity ceiling. Claude identified in the v44 patch 2 peer-review round that the reuse path in `Find-SuitableRecoveryPartition` is also exposed: an oversized recovery-typed partition can be **accepted** for reuse by that function and then re-registered against, which is a different failure shape from deletion but draws on the same missing size check. The Known gap is therefore extended to name both functions.

Until the 2 GiB ceiling ships:

- The destructive path (`Ensure-AdequateRecoveryPartition`) deletes every partition on the OS disk carrying the standard recovery GPT type GUID or MBR type code, without checking its size or contents.
- The reuse path (`Find-SuitableRecoveryPartition`) accepts an existing recovery-typed partition that meets the free-space policy without checking its size against an upper bound.
- The 2 GiB ceiling, when it ships, must gate **both** functions, not only the destructive one.

The README carries a "Before you run this" warning at the top of the page. The `.NOTES` block in `scripts/WinRE.ps1` carries the "Known gaps" section. Operators deploying to machines they did not image themselves should run the harness Option 1 diagnostic and inspect the "Recovery partitions" section before proceeding. The ceiling is planned as its own version boundary and will ship with a fresh CHANGELOG entry and a `ScriptVersion` decision.

Note: as of [v44 patch 6](#v44-patch-6--2026-09-30), the known-gap list names a third function — `Remove-StrayRecoveryPartitions`, which deletes type-coded recovery partitions on non-OS disks without checking size. The planned ceiling must gate all three functions. See the patch 6 entry.

### Field verification

- **Dell Latitude 3550 (Intel Core Ultra 5 125U, Win11 26200), 2026-09-30 12:29–12:47.** The machine that motivated the entire v43 patch 5 investigation now runs cleanly under v44. The run produced a clean partition recreate: `Component cleanup and ResetBase completed successfully`, `Pre-deletion inventory:` followed by partition deletion and recreation, `Target partition 0/4 (Z:) is already unencrypted - reagentc /enable can proceed`, `reagentc /enable (exit 0): … Operation Successful.`, `Operating mode: DEDICATED`. The old v43 failure mode (`delete-and-recreate` retry, OS-fallback, `FATAL: WinRE is not enabled at exit`) is gone. This confirms the destructive-path C: guard and the target-volume policy work on the machine that broke the previous design.

- **ASUS desktop (PRIME H510M-D, i5-11400, Win11 26200), 2026-09-30 12:02.** Fast path with the v44 patch 3 code. State file accepted (DSI match), `Operating mode: DEDICATED`, no machine changes. Confirms no regression on the healthy path.

The v44 patch 2 field verification below remains the latest confirmed data for the ResetBase change specifically.

### Unchanged

`ScriptVersion` remains 44. `DesiredStateId` is unchanged. No fleet-wide rebuild is forced. Healthy machines continue to take the fast path. A machine whose next natural rebuild is already due (manifest bump, OEM pack version change, Windows build change, or CPU/VMD presence change) picks up the v44 patch 3 fixes on that rebuild. A machine that is already in a completed state and whose inputs have not changed will not see the fixes until the deployment mechanism invokes the script with intent to rerun, for example by deleting the state file or forcing a full-update pass.

## [v44 patch 2] — 2026-09-30

### Changed

- **`dism /cleanup-image /StartComponentCleanup /ResetBase` now runs on the mounted image after driver injection completes and before the dismount, on the full-update path only.** The size reduction is materialised by the existing Step 4 `dism /Export-Image /Compress:max`, which writes a smaller `winre_optimized.wim`. The technique was adopted from Microsoft's KB5028997 remediation scripts (`WinREPathScriptSamples`), which use the same pair of operations to make `winre.wim` fit an existing recovery partition.

  ResetBase makes the image unserviceable for rollback (updates present when it ran can no longer be uninstalled). This is acceptable for a recovery image, which is rebuilt from source whenever the `DesiredStateId` changes and is never rolled back in place.

  ResetBase failure is non-fatal: the log records a WARN with the DISM exit code, the pipeline continues, and the Step 4 export writes whatever size the image currently is. The Step 5 partition acceptance check decides whether the result fits. ResetBase runs only when `$Script:ImageInjectionComplete` is `$true`; if injection failed, the pipeline aborts before Step 4 and the reset would waste CPU.

  **Field-observed size reduction.** The first v44 patch 2 run on a machine with a base WinRE image that had not accumulated update history produced 0.26 MiB of savings (756.36 MiB → 756.1 MiB). This is expected: the WinRE WinSxS store is only a few hundred MB to begin with, and on a fresh image most of that is the current baseline with nothing to reset. The savings will be material only on a machine whose WinRE image has accumulated multiple cumulative updates. The runtime cost is roughly 2 seconds on a fresh image and longer on one with more superseded state.

  `ScriptVersion` remains 44. `DesiredStateId` is unchanged. No fleet-wide rebuild is forced: healthy machines continue to take the fast path with their current WIM, and only receive the ResetBase'd WIM on their next natural rebuild (manifest bump, OEM pack version change, Windows build change, or CPU/VMD presence change). The behavioural change is a slower full-update pass and a smaller exported WIM.

### Known limitation (documented; not fixed in this revision)

The destructive path in `Ensure-AdequateRecoveryPartition` deletes every partition on the OS disk that carries the standard recovery GPT type GUID or MBR type code, without checking its size or contents. Windows Setup and in-place upgrade recovery partitions are under 1.5 GiB; OEM factory recovery volumes can be 7–20 GiB and may carry the same type code. A 2 GiB sanity ceiling that would WARN and skip oversized candidates is planned but not implemented. Until it ships:

- The `.NOTES` block in `scripts/WinRE.ps1` carries a "Known gaps" section describing the limitation.
- The README carries a "Before you run this" warning at the top of the page.
- Operators deploying to machines they did not image themselves should run the harness Option 1 diagnostic and inspect the "Recovery partitions" section before proceeding.

Note: as of [v44 patch 3](#v44-patch-3--2026-09-30), this limitation is extended to also name the reuse path in `Find-SuitableRecoveryPartition`. As of [v44 patch 6](#v44-patch-6--2026-09-30), it names a third function — `Remove-StrayRecoveryPartitions` — which deletes type-coded recovery partitions on non-OS disks without checking size. The planned ceiling must gate all three functions.

### Field verification

- **ASUS desktop (PRIME H510M-D, i5-11400, Win11 26200), 2026-09-30 02:06.** State file deleted manually to force a full-update pass. ResetBase ran on the mounted image, took ~2 seconds, exited 0, and logged `Component cleanup and ResetBase completed successfully`. The exported WIM was 756.1 MiB, versus 756.36 MiB on the pre-ResetBase run. The run completed normally with `Operating mode: DEDICATED`; the second run at 02:08 took the fast path.

## [v44 patch 1] — 2026-09-30

This revision bumps `ScriptVersion` from 43 to 44 and changes the `DesiredStateId` inputs. Every managed machine performs one full-update pass on its next scheduled run to rebuild the WIM against the new ID, then returns to the fast path. The revision also carries six patches that were applied on disk during the [v43 patch 5 (further revision 5)] session but never documented, and two correctness fixes for edge cases identified during review.

The `DesiredStateId` change closes a gap in which a BIOS or firmware update that flipped VMD on or off — or a CPU or motherboard swap on the same chassis — could leave a machine taking the fast path with a driver set that no longer matched its hardware. In that scenario the deployed WinRE cannot see the OS disk on a VMD-based system, and Startup Repair fails. The ID is now a deployment-input fingerprint rather than a hardware fingerprint.

### Changed

- **`DesiredStateId` inputs now include CPU vendor/generation and VMD presence.** Previous inputs were `HW`, `OS`, `MANIFEST`, `OEMPACK`, `SCRIPT`. New inputs are `HW`, `OS`, `CPU`, `VMD`, `MANIFEST`, `OEMPACK`, `SCRIPT`. The CPU component is `vendor|generation`, with the literal string `N` used when the generation cannot be parsed (AMD, Intel Celeron/Pentium/Atom/Xeon, N/J-series). The VMD component is `present` or `absent`. VMD presence is a deployment input because it determines whether the VMD driver package is selected for injection. Full rationale is in [docs/state-and-idempotency.md](docs/state-and-idempotency.md).
- **`ScriptVersion` = 44.** Changed because the `DesiredStateId` format changed. This is the version boundary that explains the fleet-wide rebuild; `ScriptVersion` is not bumped for changes that do not affect the deployed WIM or the partition layout.
- **The read-only harness `Test-WinRE.ps1` was updated to v15.** The harness's hardware-profile helper is now aligned with production's manufacturer normalization (LENOVO uppercase, HP canonicalization, raw fallback for unrecognised manufacturers), and it returns the same fields production's `Get-HardwareObject` produces — including `Model`, which is part of the `HW` component of the new ID. A new `Get-DesiredStateId` mirror and a new `Show-StateFileParity` diagnostic (menu option `S`) recompute the ID from the same inputs production uses and compare it to the on-disk state file, so a field engineer can check "would production take the fast path on this machine right now?" without running the production script. The `Test-OemMaps` Lenovo null-return handling now mirrors production's caller: the two permanent-skip cases (`MT=UNKN`, and map loaded with no entry for this MT) are logged at `INFO` and counted as a pass, and only a failed map load is counted as a failure. See the `.NOTES` block in `scripts/Test-WinRE.ps1` for the full v15 change list.

### Fixed

Six patches applied during the [v43 patch 5 (further revision 5)] session but never documented. All ship in v44 patch 1.

- **Step 3 → Step 4 pipeline gate.** When OEM or VMD injection failed (`$Script:ImageInjectionComplete = $false`), the pipeline was continuing to Step 4 (`dism /Export-Image`), Step 5 (deploy), and `reagentc`. The state-write gate prevented the state file from recording the run, but did not prevent the deployment. On a VMD-based system the resulting WinRE cannot see the OS disk. The pipeline now exits with `EXIT_WARNING` immediately after Step 3, removes any stale `winre_optimized.wim`, and resets the checkpoint to step 2 so the next run re-acquires the base WIM from source and re-runs injection against a clean image.
- **OS-fallback BitLocker gate, full-update path, fail-closed.** The gate previously called `Get-BitLockerVolume -MountPoint C:` directly and passed silently when the cmdlet returned `$null`: `$osFallbackVs` became `""`, the `-and` short-circuited, and the gate passed. Replaced with `Test-VolumeEncrypted -MountPoint "C:"` requiring exactly `$false` (confirmed fully decrypted) to proceed. `Test-VolumeEncrypted` also brings the `manage-bde` text-parsing fallback for machines whose BitLocker module is unavailable.
- **OS-fallback BitLocker gate, pending-reboot path.** Same fail-open pattern, same fix.
- **Hashless download length check.** In `Invoke-OemPackDownload`, the no-hash path accepted a file on clean HTTP completion without checking its length. HP is the vendor that reaches this path. An explicit `if ($fileSize -le 0)` check now runs before the hashless acceptance branch.
- **Audit Mode comment correction.** The comment claimed the guard "runs before any state-modifying action", which is literally false — `New-DirectoryIfNotExists $LogDir` and `Write-Log` run before the guard. Narrowed to "runs before any WinRE registration, partition, image, checkpoint, or recovery-state modification", with a note that log directory creation is not deployment state.
- **Two `-DryRun` structural cleanups.** `Write-WinREState` moved the `if ($Script:DryRun)` check above the `$Script:GeometryRestoreFailed` branch. `Invoke-ReAgentRegistrationRepair` added an internal `-DryRun` guard at the top of the function. Neither closes an active bug; both make the `-DryRun` contract self-upholding rather than caller-dependent.

Two correctness fixes identified during v44 review:

- **Lenovo machines whose machine type cannot be resolved no longer loop on `EXIT_WARNING`.** When `Get-LenovoWinPEPack` could not determine the machine type, it returned early before loading the Lenovo WinPE map. The caller's "map loaded, no entry for this MT" detection therefore failed (`$Script:LenovoWinPEMap` was null), and the transient-failure branch fired: `ImageInjectionComplete` was set to false, no state file was written, and every subsequent run repeated the same path. The machine never progressed. The caller now treats an unresolvable machine type the same as "map loaded, no entry": the run is recorded as complete with `OEMPACK=NONE`, the state file is written, and the fast path fires on subsequent runs. If the machine type is later resolved — or a pack is published — the `DesiredStateId` changes and the machine rebuilds automatically.
- **`DeployedDiskNumber` and `DeployedPartitionNumber` are no longer written as `0` for OS-fallback states.** The `Write-WinREState` parameters were typed `[int]`, so a `$null` argument (from `$state.DeployedDiskNumber` on an OS-fallback state file that never set the field) was coerced to `0` and written into the state file as `"DeployedDiskNumber": 0`. Latent today because no consumer trusts those fields in the OS-fallback branch, but a correctness bug the moment a future consumer does. The parameters are now `[object]` typed, and the conditional that populates them checks `$null -ne` before the integer comparison.

### Field verification

- **Hyper-V VM, Win11 26200, 2026-09-30 00:29.** First run after the v44 patch: `DesiredStateId` mismatch on the state file written by v43 patch 5 (further revision 5) → full-update path. VMD hardware present = False, so `VMD=False` and `CPU=Intel|11` entered the new ID stably. WIM copied from the reagentc-registered recovery partition, mounted, dismounted, optimized (713.3 MiB), target partition accepted on size (980.1 MiB effective free, 963 MiB required), deployed, `reagentc /enable` succeeded, DEDICATED, state file written. Second run at 00:32: `DesiredStateId` match → fast path, drive letter removed, DEDICATED. No drive-letter leaks, no checkpoint residue.
- **ASUS desktop, Win11 26200, 2026-09-30 00:29.** Same sequence. Target partition accepted on size (1082.2 MiB effective free, 1006 MiB required). DEDICATED, state file written. Second run at 00:32: fast path, drive letter removed, DEDICATED.

### Migration note

Every managed machine performs one full-update pass on its next scheduled run. Healthy NVMe laptops take roughly 3–5 minutes of I/O and CPU. Machines with a suitable existing recovery partition re-use it; no partition work occurs on healthy machines. After the first full-update pass per machine, the state file records the new `DesiredStateId` and the fast path resumes permanently.

Machines whose state file recorded `PendingReboot = true` are treated as stale before the pending-reboot repair block runs, so the ID change triggers the full-update path instead. No machines are lost. Machines stuck in the enable-failure loop-breaker (`EnableFailureAttempts >= 3`) receive one fresh attempt under the new ID before the loop-breaker can fire again.

Rollback: change `$ScriptVersion` back to 43, revert the `Get-DesiredStateId` `$parts` array, and restore the previous `Get-HardwareObject` if the manufacturer normalisation differed. No data is lost; another fleet-wide rebuild occurs on the next run.

The read-only harness `Test-WinRE.ps1` moves from v14 to v15 in the same window. The harness has no `ScriptVersion` and no `DesiredStateId` of its own; its version is its own marker. A v14 harness run still reads the machine's state correctly, but its `Get-ThisMachineProfile` would compute a different `DesiredStateId` than production for a Lenovo or an unrecognised-OEM machine — that is the drift v15 closes.

## [v43 patch 5 (further revision 5)] — 2026-09-29

This revision inverts the BitLocker policy. It is the largest single change in the v43 patch 5 generation, and it supersedes the BitLocker portions of the [v43 patch 5 (further revision)] entry below. Everything else in that entry — the Audit Mode guard and the enable-failure counter — remains accurate.

The change was driven by a same-machine test on 2026-09-29 that disproved the policy the earlier revisions had been built on.

### Changed

- **The BitLocker policy is now target-volume-based, not OS-volume-based.** reagentc's BitLocker check is on the volume it is being asked to enable WinRE on, not on the OS volume. Proven by a same-machine test: with C: in the `FullyEncrypted`/no-protectors state (the *Waiting for Activation* state of Device Encryption), `reagentc /enable` against a dedicated recovery partition succeeded while `reagentc /enable` against the OS volume failed with *"Windows RE cannot be enabled on a volume with BitLocker Drive Encryption enabled."* The policy was therefore inverted: prepare the **target** volume before calling reagentc, and do not gate on C:'s state except for the OS-fallback path, where the target volume *is* the OS volume. Full rationale and the field evidence are in [docs/architecture.md](docs/architecture.md) and [docs/deployment.md](docs/deployment.md).

- **A partition claimed by Device Encryption does not re-encrypt after `manage-bde -off` completes.** Confirmed by the same test: a newly created partition (labelled `R:` in the test) that the Device Encryption service had claimed, then explicitly decrypted with `manage-bde -off`, stayed unmanaged. `reagentc /enable` against it then succeeded. This makes decrypt-in-place safe and replaces the delete-and-recreate retry that had never worked on the Dell Latitude 3550 case.

- **The read-only harness `Test-WinRE.ps1` was updated to v14 in lockstep with the production policy change.** The BitLocker diagnostic's hazard and ambiguity warnings no longer say that production "will refuse destructive partition work" in those states — that language described the removed OS-volume gate and would have told a field engineer to defer a run that production would actually succeed on. The warnings now name which production path is affected by which state: the OS-fallback path is the only one that depends on C:'s `VolumeStatus`, and the enable-only and dedicated-partition paths proceed regardless of C:'s state because they target the recovery partition. A new diagnostic block reports the BitLocker state of the partition reagentc is registered to — the target that `Set-RecoveryPartitionReadyForWinRE` will prepare — and states plainly whether the next production run will need to spend up to 300 seconds decrypting it in place. The harness remains read-only; its scope, menu structure, parser self-test, and download and extraction tests are unchanged. See the `.NOTES` block in `scripts/Test-WinRE.ps1` for the full v14 change list.

### Added

- **`Set-RecoveryPartitionReadyForWinRE`.** A new helper that prepares a target recovery partition for `reagentc /enable`. If the partition is already unencrypted, it returns immediately. If it is encrypted or actively encrypting, it runs `manage-bde -off` against the partition and polls `Test-VolumeEncrypted` at 5-second intervals up to a 300-second timeout, until the volume reports confirmed-unencrypted (`FullyDecrypted`, or the `could not be opened by BitLocker` classification from `manage-bde`). Returns `$true` on success and `$false` on timeout or unrecoverable failure. Under `-DryRun` it logs the intent and returns `$true` without touching the volume. Called at four sites: the enable-only path, the full-update path with an existing recovery partition, the full-update path with a newly created partition, and the pending-reboot repair path.

- **OS-fallback gate.** reagentc refuses to enable WinRE on an encrypted OS volume, always. The OS-fallback path now checks C:'s `VolumeStatus` before deploying the WIM and defers with `EXIT_WARNING` unless it is `FullyDecrypted`. The script never modifies C:'s BitLocker state — decrypting the OS volume is hours of I/O, changes the recovery key relationship, and the OS volume is the user's data. When the OS-fallback gate defers, the operator message tells them what to do: sign in with a Microsoft account to complete Device Encryption activation, or add a key protector manually (`Add-BitLockerKeyProtector -MountPoint C: -RecoveryPasswordProtector`) and enable protection, or wait for decryption to finish.

- **Structural `-DryRun` choke point for the full-update pipeline.** The pipeline (copy or download base WIM, mount, inject drivers, dismount, `dism /Export-Image`) performs file I/O in `WorkDir` and invokes `dism` and 7-Zip. None of that should run under `-DryRun`. A single early return at the top of the full-update path logs the plan for Steps 1 through 7 and exits cleanly. The downstream plan-only functions (`Find-SuitableRecoveryPartition`, `Ensure-AdequateRecoveryPartition`, `Invoke-ReagentcEnable`, `Remove-StrayRecoveryPartitions`) have their own `-DryRun` guards, but are not reached from this path — the guard is single and structural.

### Removed

- **The startup BitLocker gate.** The earlier further revision installed a startup gate that deferred on any `ProtectionStatus=Off` with a non-`FullyDecrypted` `VolumeStatus`. That included the `FullyEncrypted`/no-protectors state, which is the normal state of every fresh Win11 local-account machine before a Microsoft-account sign-in. The gate was deferring on the majority of the fleet. It has been removed entirely. The Audit Mode guard that ran before it is unchanged.

- **`Suspend-BitLockerForWinRE` and `Test-BitLockerSuspended`.** Deleted. Suspension does not prevent Device Encryption from claiming newly created partitions — proven by the Dell Latitude 3550 pre-patch-5 log, where the new partition was auto-encrypted despite protection being `Off`, and by the 2026-09-29 test, where the new partition was auto-encrypted with C: in the state suspension produces. Suspension is also useless for OS-fallback, where reagentc refuses regardless.

- **The internal BitLocker check in `Invoke-ReagentcEnable` and its `"blunsafe"` return value.** Callers are now responsible for making the target unencrypted via `Set-RecoveryPartitionReadyForWinRE` before calling `Invoke-ReagentcEnable`. The four `"blunsafe"` handlers (enable-only, pending-reboot, full-update post-enable, final verification) are gone.

- **The encrypted-partition delete-and-recreate retry in `Ensure-AdequateRecoveryPartition`.** It never worked on the Dell and is redundant given that a claimed partition can be decrypted in place without re-encrypting.

- **The `"bitlocker"` suspend + delete + recreate recovery in the full-update path.** Replaced by a short handler that logs, sets the warning flag, and lets the state-file counter and the loop-breaker do their work.

- **`Test-BitLockerProtected` and `Test-RecoveryPartitionEncrypted`.** Deleted. `Test-VolumeEncrypted` is the sole BitLocker classifier in the script.

- **Dead script state.** `$Script:BitLockerSuspended` and `$Script:BitLockerGuardDeferred` were removed along with the functions that set them.

### Fixed

- **The enable-failure counter now counts terminal `"bitlocker"` results and decryption timeouts alongside `"failed"`.** The loop-breaker predicate was widened to `LastEnableResult -in @("failed","bitlocker")`, and the counter is incremented on `"bitlocker"` in both the enable-only path and the full-update state write, so a machine that keeps failing the enable step on the BitLocker error no longer loops silently.

- **`Find-SuitableRecoveryPartition` no longer rejects encrypted existing partitions.** The target-volume policy means the script will decrypt the target in place before `reagentc /enable` rather than destroy and recreate it. An existing encrypted recovery partition is therefore usable.

- **Preferred drive-letter reuse.** When `Ensure-AdequateRecoveryPartition` creates a new recovery partition after deleting the old one, it now prefers a letter that was already used earlier in this run over a fresh one from `Get-AvailableDriveLetter`. Windows caches letter-to-volume mappings in `MountedDevices`; reusing a letter the script held earlier is more likely to succeed cleanly than picking a fresh one, and it avoids the assign-remove-reassign churn that can leave stale entries. The fallback chain in `Invoke-DriveLetterAssignment` is unchanged.

### Unchanged

`ScriptVersion` remains 43. `DesiredStateId` is unchanged. Healthy machines do not rebuild. (The `DesiredStateId` was subsequently changed in [v44 patch 1](#v44-patch-1--2026-09-30).)

### Field evidence

- **VM test, 2026-09-29.** C: was `ProtectionStatus=Off`, `VolumeStatus=FullyEncrypted`, `KeyProtector: {}`. `reagentc /enable` against partition 4 (a dedicated recovery partition) succeeded. `reagentc /enable` against partition 3 (the OS volume), on the same machine in the same session, failed with *"Windows RE cannot be enabled on a volume with BitLocker Drive Encryption enabled."* This is the test that established the target-volume nature of reagentc's check.

- **VM test, 2026-09-29 (continued).** A newly created recovery partition (`R:`) was claimed by the Device Encryption service (`VolumeStatus=EncryptionInProgress` at 97.6%, no key protectors). `manage-bde -off R:` was run. After the `-off` completed, `manage-bde -status R:` reported `The volume R: could not be opened by BitLocker` — the definitive signal of a clean, BitLocker-unmanaged recovery partition — and R: stayed unmanaged. `reagentc /enable` then succeeded. This is the test that established that decrypt-in-place is safe.

- **Dell Latitude 3550 (Intel Core Ultra 5 125U, Windows 11 build 26200), pre-patch-5 log.** The script created a new partition on a machine mid-Device-Encryption, the Device Encryption service auto-encrypted it before the recovery type GUID could take effect, the delete-and-recreate retry hit the same problem, the script fell back to OS-fallback, and `reagentc /enable` refused on the encrypted OS volume. This is the failure the new policy is designed to prevent, and the log is the basis for the OS-fallback gate.

### Migration note

A machine running [v43 patch 5 (further revision)] will not rebuild on this revision: `ScriptVersion` is unchanged and the `DesiredStateId` is unchanged. A machine whose previous run deferred at the startup BitLocker gate will, on the next run, proceed normally if the target partition can be prepared. A machine whose previous run took the OS-fallback path on an encrypted C: will defer at the OS-fallback gate with a clear operator message.

The read-only harness `Test-WinRE.ps1` moves from v13 to v14 in the same window. The harness has no `ScriptVersion` and no `DesiredStateId`; the version is its own marker. A v13 harness run still reads the machine's BitLocker state correctly — only the warning text and the new target-partition block differ.

## [v43 patch 5 (further revision)] — 2026-09-29

> **Note.** The BitLocker policy described in this entry was superseded on the same day by [v43 patch 5 (further revision 5)](#v43-patch-5-further-revision-5--2026-09-29). The Audit Mode guard and the enable-failure counter introduced in this entry remain current. Read this entry as history for the BitLocker portions; read the newer entry for the current behaviour.

### Fixed

- **Audit Mode / OOBE / sysprep guard.** The script now refuses to run before any state-modifying action when Windows is not in a normal-running state. During Audit Mode, OOBE, and the sysprep generalize/specialize phases, `reagentc /enable` fails with `ERROR_CANCELLED` (`0x4c7`, 1223) regardless of the correctness of the deployed WIM or the state of the recovery partition. The previous code deployed successfully, failed at `/enable`, wrote a state file recording the deployment as complete, and then looped on every subsequent run — the state file matched, no rebuild was triggered, and the enable-only path retried `/enable` forever. The guard reads `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` → `ImageState` at startup, immediately after the log directory is ensured and before the hardware check. It proceeds only when `ImageState` is absent (some SKUs omit the key) or exactly `IMAGE_STATE_COMPLETE`; any other value defers with `EXIT_WARNING`, logs a clear message, and makes no WinRE or partition changes. Runs under `-DryRun` in the same read-only form (logs `Would defer` and continues). Field case: Dell Latitude 5530 (12th Gen Intel i7-1265U, Windows 11 build 26200) — the machine was in Audit Mode when the script first ran, `/enable` failed with `0x4c7` on two consecutive runs, and after the user completed OOBE and ran `reagentc /enable` manually it succeeded on the first attempt with the same WIM.
- **Enable-failure counter and loop-breaker.** The state file now records `LastEnableResult` (string) and `EnableFailureAttempts` (integer). Previously, a failed `reagentc /enable` did not affect the state-write gate: the run continued through Step 6 and Step 7, wrote the state file as if the deployment had completed, and exited `EXIT_FATAL` at the final-verification block. The next run accepted the state file, took the fast or enable-only path, and failed the same way — a permanent loop for any cause of `/enable` failure, not just Audit Mode. Three changes close this:
  - **The enable-only path no longer falls through to full update on `"failed"`.** A failed enable on the enable-only path increments the counter, writes the state file with the new counter value, and exits `EXIT_WARNING`. The deployment is already current; rebuilding it would not change the outcome. (Under the original further revision, `"bitlocker"` still fell through to the suspend + delete + recreate recovery path; that path was removed in further revision 5, and the counter now includes `"bitlocker"`.)
  - **A loop-breaker exits `EXIT_FATAL` after 3 consecutive failed enables.** When the state file records `EnableFailureAttempts >= 3`, a terminal `LastEnableResult`, and WinRE is still `Disabled`, the script logs a clear "manual intervention required" message, names the state file path, and exits without attempting anything else. The operator resolves the underlying cause and deletes the state file to reset the counter.
  - **The fast path clears stale counters.** When the idempotent fast path fires on a machine whose state file carries a non-zero `EnableFailureAttempts` or a `LastEnableResult` other than `"ok"`, the state file is rewritten with the counters reset. A healthy machine's counters are cleared on the first fast-path run after the underlying cause is resolved.

  Both new fields default to `"ok"` / `0` when read from state files written by earlier versions, so no rebuild is triggered by adding them.

### Changed

- **BitLocker state checks now consider `VolumeStatus`, not just `ProtectionStatus`.** On Windows 11 24H2+ with Device Encryption, a volume can be actively encrypting (`VolumeStatus=EncryptionInProgress`) while `ProtectionStatus` reads `Off`. In that state, the previous code logged *"already Off - no suspension needed"* and proceeded with the destructive partition path. The Device Encryption service then auto-encrypted any new partition before its recovery type GUID could be applied, and `reagentc /enable` refused with *"Windows RE cannot be enabled on a volume with BitLocker Drive Encryption enabled."* (Superseded by further revision 5: the check now targets the recovery partition, not C:.)
- **`FullyEncrypted` with `ProtectionStatus=Off` was treated as ambiguous, not safe.** (Superseded by further revision 5. Under the newer policy, this state is no longer relevant to the enable-only or full-update paths, because those now target the recovery partition, not C:. It is still relevant to the OS-fallback gate, where the target *is* C:.)
- **Startup BitLocker gate.** A read-only BitLocker check ran at startup, immediately after `Get-WinREState` and before the pending-reboot block or any state-modifying action. (Removed in further revision 5.)
- **Checkpoint file is preserved on deferral.** The deferral blocks no longer remove the checkpoint file. Deferring on BitLocker state does not invalidate any resumable step; steps 1–4 do not depend on BitLocker and the existing step guards handle resumption once the state is safe.
- **`-DryRun` no longer modifies WinRE registration.** Two code paths could modify state despite the "dry run modifies nothing" contract. First, `Ensure-AdequateRecoveryPartition`'s `reagentc /disable` call was not guarded. Second, `Invoke-ReagentcEnable` ran `reagentc /enable` unconditionally; the enable-only caller was guarded, but the pending-reboot path was not. Both are now closed with structural, not per-step, guards.
- **Lenovo machines with no published WinPE pack no longer re-run the full pipeline forever.** The v42 rule marked every supported-vendor run with no resolved OEM pack as incomplete and refused to write a state file. That was correct for Dell and HP (their maps are single-pack) and for a Lenovo map that failed to download. It was wrong for the common Lenovo case where the map loads successfully and simply has no entry for this machine type. The fix distinguishes "map loaded, no entry for this model" (expected and permanent) from "map failed to load" (transient).
- **New partitions are created with the recovery type GUID already applied.** `New-Partition` now passes `-GptType {de94bba4-06d1-4d40-a16a-bfd50179d6ac}` (GPT) or `-MbrType 0x27` (MBR) at creation. This closes the window between `New-Partition` and `Set-RecoveryPartitionAttributes` during which a plain Basic Data partition could be claimed by the Device Encryption service.

### Field reports

**Dell Latitude 5530** (12th Gen Intel i7-1265U, Windows 11 build 26200). Machine was in Audit Mode when `WinRE.ps1` was first run. The deployment completed successfully through Step 5, `reagentc /enable` failed with `0x4c7` on two consecutive runs, and the state file recorded the deployment as complete. After the user completed OOBE and ran `reagentc /enable` manually it succeeded on the first attempt with the same WIM. This is the case that motivated the Audit Mode guard.

### Unchanged

`ScriptVersion` remains 43. `DesiredStateId` is unchanged. Healthy machines do not rebuild.

## [v43 patch 5] — 2026-09-28

### Fixed

- **BitLocker protection-state checks now consider `VolumeStatus`, not just `ProtectionStatus`.** On Windows 11 24H2+ with Device Encryption, a volume can be actively encrypting (`VolumeStatus=EncryptionInProgress`) while `ProtectionStatus` reads `Off`. In that state, the previous code logged *"already Off - no suspension needed"* and proceeded with the destructive partition path. The Device Encryption service then auto-encrypted any new partition before its recovery type GUID could be applied, and `reagentc /enable` refused with *"Windows RE cannot be enabled on a volume with BitLocker Drive Encryption enabled."* `Test-BitLockerProtected` now returns `$null` (unknown) and `Suspend-BitLockerForWinRE` returns `$false` immediately — without falling through to the generic `manage-bde` fallback — for any hazardous `VolumeStatus`. Both refuse to treat the volume as unprotected, and the destructive partition paths abort.
- **`FullyEncrypted` with `ProtectionStatus=Off` is treated as ambiguous, not safe.** This state is the standard suspended-BitLocker state, but it is also indistinguishable from a Device Encryption volume in the *Waiting for Activation* state, where the volume has been encrypted with a clear key but protection has not been armed because the recovery key has not yet been escrowed. The two-field local view cannot tell the two apart. Both `Test-BitLockerProtected` and `Suspend-BitLockerForWinRE` now return `$null` / `$false` for this combination, and the destructive partition paths defer with `EXIT_WARNING`. (Superseded by further revision 5.)
- **Ownership guard on `Suspend-BitLockerForWinRE`.** The ambiguous-state classification above would otherwise have broken the healthy path. `Suspend-BitLockerForWinRE` short-circuited with `return $true` when `$Script:BitLockerSuspended` was set, so the ambiguous classification applied only to states observed at the start of the run. (Superseded by further revision 5: the function was removed.)
- **Startup BitLocker gate.** A read-only BitLocker check ran at startup, immediately after `Get-WinREState` and before the pending-reboot block or any state-modifying action. (Removed in further revision 5.)
- **Startup gate handles an unknown BitLocker state.** The gate fell back to `Test-BitLockerProtected` when `Get-BitLockerVolume` returned `$null`, and deferred on an unknown result. On machines where `manage-bde.exe` is absent, the gate was a no-op. (Removed with the gate in further revision 5.)
- **Startup gate runs under `-DryRun`.** (Removed with the gate in further revision 5.)
- **Checkpoint file is preserved on BitLocker deferral.** (Retained as a general principle in further revision 5.)
- **`-DryRun` no longer modifies WinRE registration.** Two code paths could modify state despite the "dry run modifies nothing" contract: `Ensure-AdequateRecoveryPartition`'s `reagentc /disable` call, and `Invoke-ReagentcEnable` on the pending-reboot path. Both closed with structural guards. (Retained and extended to the full-update pipeline in further revision 5.)
- **Lenovo machines with no published WinPE pack no longer re-run the full pipeline forever.** The v42 rule marked every supported-vendor run with no resolved OEM pack as incomplete. The fix distinguishes "map loaded, no entry for this model" (expected and permanent) from "map failed to load" (transient).
- **The BitLocker safety check in `Ensure-AdequateRecoveryPartition` runs before `reagentc /disable`.** The initial patch placed the check after the WinRE disable, so a refusal left the machine with WinRE disabled and no way to re-enable it until encryption finished — the exact damaged state the patch was written to prevent.
- **Step 5 performs the same BitLocker safety check before disabling WinRE.**
- **Fail-closed on BitLocker state in `Invoke-ReagentcEnable`.** `Invoke-ReagentcEnable` returned a distinct result `"blunsafe"` when BitLocker on C: was not confirmed unprotected. All three call sites aborted with `EXIT_WARNING`. (Removed in further revision 5.)
- **Stronger `manage-bde` fallback.** When `Get-BitLockerVolume` is unavailable and the fallback parses `manage-bde -status` text, `Protection Off` alone is no longer sufficient evidence of safety. Only a confirmed `Conversion Status: Fully Decrypted` makes the fallback return confirmed-unprotected.
- **`-DryRun` evaluates the BitLocker safety check.** The DryRun branch of `Suspend-BitLockerForWinRE` now queries `Get-BitLockerVolume` and returns `$false` on the hazardous states, so a dry run of a hazardous machine reports the hazard. (Superseded by further revision 5: the function was removed and the equivalent check lives in `Set-RecoveryPartitionReadyForWinRE`.)
- **New partitions are created with the recovery type GUID already applied.** `New-Partition` now passes `-GptType {de94bba4-06d1-4d40-a16a-bfd50179d6ac}` (GPT) or `-MbrType 0x27` (MBR) at creation.

### Field reports

Two machines hit this bug in the same 24-hour window, both on Windows 11 build 26200 mid-Device-Encryption:

- **Dell Latitude 3550** (Intel Core Ultra 5 125U) — `VolumeStatus=EncryptionInProgress` at 73.6% when the script ran.
- **HP ProBook 450 15.6 inch G10** (Intel Core i7-1355U) — same state, same failure sequence.

Both machines lost their dedicated recovery partition and had WinRE disabled by the pre-patch-5 code. Recovery procedure: see [docs/troubleshooting.md](docs/troubleshooting.md).

Two further Dell machines (a Pro Slim QCS1250 and a Vostro 16 5640) ran against a mid-encryption state after the further revision landed. The startup gate fired correctly on both: no partition was touched, no state file was written, and both runs exited with `EXIT_WARNING`. Both machines will complete the dedicated-partition deployment automatically on the next run after their encryption state stabilises.

### Unchanged

`ScriptVersion` remains 43. `DesiredStateId` is unchanged. Healthy machines do not rebuild.

## [v43 patch 4] — 2026-09-27

### Fixed

- **Checkpoint writes are now gated on injection success.** Previously the step 3, 4 and 6 checkpoint files advanced even when OEM or VMD injection failed. If a run was interrupted before its cleanup step, the next run would resume past step 3, deploy the un-injected WIM, and commit state for it — silently marking a broken deployment as healthy and disabling all future retries. The three writes are now conditional on `$Script:ImageInjectionComplete`. On a healthy run the behaviour is unchanged.
- **Migration guard for already-affected machines.** A machine already sitting on an orphaned step-4 or step-6 checkpoint from a pre-patch-4 run will have its `$step` reset to 2 whenever the current run also determines that a rebuild is required, forcing step 3 to re-run and injection to be retried. The guard runs after `$needInject` has been fully evaluated, so it catches both the "no state file at all" case and the "valid-but-stale state file" case.

`ScriptVersion` unchanged at 43. `DesiredStateId` unchanged. Healthy machines do not rebuild.

## [v43 patch 3] — 2026-09-27

### Fixed

- `Remove-OrphanPartition` now sets `GeometryRestoreFailed` when the newly created partition cannot be removed after a failure. The state file is then deleted on the write gate, forcing a full retry on the next run instead of preserving a shrunken OS partition indefinitely.
- The enable-only path and both pending-reboot exits now enforce the "no type-coded recovery partition on any non-OS disk" invariant, matching the fast path and Step 7. Previously a stray secondary-disk recovery partition could survive indefinitely on a machine whose WinRE was simply re-enabled.
- The pending-reboot success exit now honours `$Script:nonFatalWarning` before returning `EXIT_SUCCESS`.

## [v43 patch 2] — 2026-09-27

### Fixed

- The classifier now requires the reagentc-registered recovery partition to be on the **OS disk**. Previously a machine registered to a secondary-disk recovery partition could take the idempotent fast path and then have the fast-path cleanup delete the very partition reagentc was pointing at.
- `ActiveLocationWimPresent` now requires a successful WIM hash, not just a successful `Test-Path`. A file that exists but cannot be read no longer counts as evidence that the registered location is healthy.
- Post-shrink rollback gap closed. If all three shrink attempts fail, `Restore-OSPartitionSize` now runs before the fallback path so C: is not left shrunken.
- `Restore-OSPartitionSize` sets `GeometryRestoreFailed` on every failure path. `Write-WinREState` deletes the state file when that flag is set, forcing a fresh full-update run on the next invocation.
- The count=0 OS-fallback exemption additionally requires that the active WinRE location is on the OS partition.

## [v43 patch] — 2026-09-27

### Fixed

- Step 7's stray-partition cleanup extracted to `Remove-StrayRecoveryPartitions` and called from the idempotent fast path. Previously the fast path exited before Step 7, so a stray recovery partition on a non-OS disk survived indefinitely on machines whose state stayed idempotent.
- Fast-path exit now honours `$Script:nonFatalWarning`.

## [v43] — 2026-09-27

### Fixed

- Fallback copy no longer deletes its own source when `$SourceWim` and the fallback target resolve to the same file.
- Full update now forces a rebuild when no WIM is available at either the reagentc-registered location or the fallback search.

## [v42] — 2026-09-27

### Fixed

- Post-shrink failure cleanup. Every failure path in `Ensure-AdequateRecoveryPartition` after the OS partition has been shrunk now either removes the orphan partition or restores the OS partition size. No failure leaves C: permanently shrunken.
- Idempotency no longer accepts a fallback WIM as evidence that a dedicated WinRE location is healthy.
- `BootFromDisk` lookups replaced with `Get-OSDisk` (OS partition's disk number) throughout.
- Step 7 secondary-disk deletion now requires a recovery partition type code; label-only matches on non-OS disks are logged and skipped.
- `dism /Export-Image` exit code is checked before checkpointing step 4.
- `reagentc /disable` failure at step 5 now aborts instead of continuing.
- OEM map resolution failure for a supported vendor now marks the run incomplete.
- Step 7 cleanup failures now set `$Script:nonFatalWarning`.

## [v41] — 2026-09-27

- `Remove-OrphanPartition` re-extends the OS partition to `SizeMax` after successfully deleting an orphan.
- The idempotent-run check examines the count of recovery partitions on the boot disk. Anything other than exactly one forces a full-update run.
- The "zero recovery partitions + OS-fallback state file" case is exempted from the rebuild policy.

## Earlier versions

v27 through v40 introduced: the download exception-on-success fix, vendor-native extraction (Lenovo Inno Setup, HP SoftPaq), Add-WindowsDriver return-shape workaround, recovery-partition attributes before drive-letter assignment, the 250 MiB free-space policy, `defrag /x` retry on shrink failure, and the tri-state BitLocker contract. Full engineering changelog is in the `.NOTES` block at the top of `scripts/WinRE.ps1`.
