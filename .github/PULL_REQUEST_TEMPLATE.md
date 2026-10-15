## What this changes

<!-- Short summary. -->

## Why

<!-- The field case, review finding, or design reason. -->

## Versioning

- [ ] `ScriptVersion` unchanged (cosmetic, logging-only, or a logic change that does not modify the deployed WIM, the partition layout, or the `DesiredStateId` inputs). Note: a change that alters a DSI *value* on a narrow machine class without changing the DSI *inputs* -- for example, a value-normalisation fix like the v47 patch 2 `Win32_ComputerSystemProduct.Version` trim -- still belongs in this category, but the CHANGELOG entry must describe the affected machine class and the expected one-time rebuild. See the v47 patch 2 Migration Note in `CHANGELOG.md` for the pattern.
- [ ] `ScriptVersion` bumped because the deployed WIM or partition layout changed
- [ ] `ScriptVersion` bumped because a `DesiredStateId` input changed (a new hardware property or a new deployment input is now part of the ID)
- [ ] If bumped, `DesiredStateId` will change and healthy machines rebuild once
- [ ] If bumped because a `DesiredStateId` input changed, the new `CHANGELOG.md` entry includes a `Migration Note` section describing the expected fleet behaviour and the rollback procedure

## Changelog

- [ ] Added an entry to `CHANGELOG.md` describing the change in user-facing terms, with the real field case or review finding that motivated it
- [ ] If the change modifies a design invariant or adds a new lesson, updated the relevant section of the `.NOTES` block in `scripts/WinRE.ps1`

`CHANGELOG.md` is the historical record of what changed and when. The `.NOTES` block records the current design invariants and the Critical lessons list. The two files serve different readers and both are part of the complete record.

## Testing

- [ ] Parser check passes: `[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\scripts\WinRE.ps1).Path, [ref]$null, [ref]$null)` (throws on any syntax error; preferred form per `CONTRIBUTING.md` style section)
- [ ] `.\scripts\WinRE.ps1 -DryRun` completes
- [ ] `.\scripts\Test-WinRE.ps1 -NonInteractive` completes with exit code 0 (v25+; a non-zero exit means the harness recorded FAILs)
- [ ] `.\scripts\Test-WinRE.ps1` completes interactively (menu path exercised)
- [ ] Field-tested on a GPT machine
- [ ] Field-tested on an MBR machine
- [ ] If the shrink path is touched: tested on hardware with OS partition at `SizeMin`
- [ ] If the BitLocker handling is touched: verified that the harness's Option 1 "Target recovery partition state" block reflects the state production would prepare, and that the code path for both an unencrypted target and an encrypted target is reachable
- [ ] If the `DesiredStateId` inputs are touched: verified that the harness's Option S "State file parity check" recomputes the same ID production computes on this machine, and that a machine whose previous state file is stale is correctly predicted to rebuild

### If this PR touches the preparation or post-deployment surface (v49+)

The v49 release added a family of gates that run **before** the destructive sequence, and a set of post-run persistence features. If your PR touches any of the following, say so explicitly and include the test result that demonstrates the change behaves as claimed:

- The **source-ownership classification** (the four classes `Manager-Owned`, `Manager-Lineage`, `Foreign-No-Drivers`, `Foreign-With-Drivers`; the rule that a `Foreign-With-Drivers` WIM is preserved as-is and not stripped and re-injected over).
- The **never-downgrade storage-driver check** (a driver that would be a version downgrade against one already present in the mounted image is not injected; the existing driver is retained).
- The **pre-deployment storage-applicability gate** (the last refusal before the WIM is written to the active route: every present SCSIAdapter-class device on the machine must have at least one matching INF in the candidate).
- The **native-boot VHDX fail-closed gate** (refuses destructive operations on a VHDX-boot OS volume).
- The **backup and restore actions** (`-Action Backup` and `-Action Restore`; the sidecar `backup.json` format; the transactional restore path).
- The **temporary crash-recovery scheduled task** (`WinRE Manager - Resume`; its two independent persist signals — the `$Script:ResumeTaskShouldPersist` flag, set by the outer catch and by `Invoke-RestoreAction`'s three mid-transformation failure paths (the WIM-deployment failure when the re-enable attempt after the failure does not return `ok`, added in v50 patch 3), and the `[WinRECancelKeyProbe]::ShouldPersist` static field, set by the compiled Ctrl+C delegate — plus its two finally-never-runs interruption classes, its clean-completion removal, and its `$PSCommandPath` guard).
- The **stable install location** for the permanent maintenance task (`C:\ProgramData\OEM\WinRE-Manager\WinRE.ps1`; the SHA256-verify-before-register step).

A change to any of these that is not covered by an existing field case still requires a `CHANGELOG.md` entry per the Changelog section above.

If your PR touches any of the v50 patch 1 additions below, say so explicitly and include the test result that demonstrates the change behaves as claimed:

- The **`manager.json` config file** and its helpers (`Get-ManagerConfig`, `Set-ManagerConfig`, `Add-ManagerBackupRoot`).
- The **manager config ownership gate** (two-level SYSTEM/Administrators ownership check on both read and write, fail-closed on ambiguity).
- The **resume-task protected-path guard** (the check that refuses to register the SYSTEM crash-recovery task when the script directory grants write-capable rights to a non-admin principal). Superseded in v50 patch 3 by the resume-script staging design listed under the v50 patch 3 additions below.
- The **destination-volume free-space preflight on backup** (100 MiB margin, before destination directory creation).
- The **UNC resolution for mapped-drive backup paths** in `Add-ManagerBackupRoot`.
- The **empty-parent cleanup** in `Remove-EmptyWorkspaceParent` and the parallel logic in `Cleanup-Backups.ps1`.
- The **aggregate summary line** emitted by `Remove-StrayRecoveryPartitions`.

A change to any of these that is not covered by an existing field case still requires a `CHANGELOG.md` entry per the Changelog section above.

If your PR touches any of the v50 patch 2 additions below, say so explicitly and include the test result that demonstrates the change behaves as claimed:

- The **GitHub Windows 10 URL builder** in `Get-GitHubBaseWinRE` (the `Win10/x64` folder path for the restructured `OriginalWindowsREImages` repository).
- The **classifier diagnostic loop** in `Main`'s Step 3 (the per-driver pre-strip inventory logging that precedes the source-ownership classification).
- The **non-OS sweep suppression boundary** in `Remove-StrayRecoveryPartitions` and the new `Test-RunningInVirtualMachine` helper it depends on (the ten hypervisor signatures, the `$null` fail-closed return, and the empty-metadata guard that returns `$null` when `Win32_ComputerSystem` succeeds but returns empty or whitespace-only Manufacturer and Model fields).
- The **`File Backed Virtual` disk protection** inside the same sweep (the preservation of mounted VHD/VHDX disks regardless of the hypervisor detection result, and the `preserved virtual:` field in the aggregate summary line).
- The **`SCSI` entry in the workspace bus allowlist** (`Get-WorkDirCandidates`; the OS-volume-only admission rule).

A change to any of these that is not covered by an existing field case still requires a `CHANGELOG.md` entry per the Changelog section above.

If your PR touches any of the v50 patch 3 additions below, say so explicitly and include the test result that demonstrates the change behaves as claimed:

- The **shared `Test-PathTrustedForSystem` helper** and its split modify-capable mask (`Delete | DeleteSubdirectoriesAndFiles | TakeOwnership | ChangePermissions` on a directory; those plus `WriteData | AppendData` on a file).
- The **extended manager config trust check** (config file itself, its containing directory, and that directory's parent, all validated via `Test-PathTrustedForSystem`).
- The **resume-script staging design** (the SYSTEM resume task executes a staged copy of the running script at `C:\Recovery\OEM\Resume\WinRE.ps1` under an explicit DACL, rather than the script's original path; the staging directory is removed on clean terminal exit; the copy is byte-verified against the source).
- The **Restore resume-task persist condition** on the WIM-deployment-failure path (keyed on `-ne 'ok'`, not `-ne 'ok' -and -ne 'reboot'`).
- The **post-deletion verification** in `Remove-StrayRecoveryPartitions` (a terminating re-query and absent-from-results check before recording a deletion as confirmed).
- The **empty archive-parts guard** in `Get-GitHubBaseWinRE`.
- The **OS-disk scope** on the recovery-volume drive-letter normalization block.
- The **volume-root preservation** in `Add-ManagerBackupRoot` (`E:\` is not truncated to `E:`).
- The **wrapper Restore catalogue enumeration** and its WIM-only acceptance.
- The **wrapper argument quoting** for `Start-Process` paths ending in a backslash.
- The **reparse-point rejection** in `Cleanup-Backups.ps1` (discovery and pre-deletion revalidation).
- The **cleanup helper's exit code** and its **explicit-path scope** for the default hierarchy.
- The **fail-closed drive-letter normalization** in the recovery-volume drive-letter normalization block (a provider error on the `\Windows` presence check skips removal for that volume rather than aborting the run).
- The **fail-closed workspace volume enumeration** in `Get-WorkDirCandidates` (a Storage-module error returns an empty candidate list so the caller defers cleanly rather than aborting FATAL).
- The **ACE-catch fail-closed correction** in `Test-PathTrustedForSystem` (the ACE loop now logs and returns `$false` on an unresolvable SID rather than silently skipping it, honouring the header comment contract).
- The **two mirror syncs of the ACE-catch fix** (the duplicated trust helper in `Cleanup-Backups.ps1` and the compressed inline trust check in `WinRE-Manager.cmd`'s Restore `TARGET_COMMAND`).
- The **Restore-failure state invalidation** in `Invoke-RestoreAction` (the target WIM's SHA256 is captured before the deploy attempt and again on failure; the state file, checkpoint, and deferral marker are preserved only when both hashes match, and the resume-task persist flag is set unconditionally in the invalidate branch).
- The **numeric-selection fix** in `Cleanup-Backups.ps1` (`@($backups).Count` and typed `List[int]` handle the single-backup case correctly).

A change to any of these that is not covered by an existing field case still requires a `CHANGELOG.md` entry per the Changelog section above.

### If this PR touches the destructive sequence

The destructive sequence covers `Get-PartitionPlan`, `Ensure-AdequateRecoveryPartition`, `Invoke-OSPartitionShrink`, `Invoke-OSPartitionExtend`, the `New-Partition` / `Format-Volume` / `Set-RecoveryPartitionAttributes` calls, `Remove-OrphanPartition`, `Restore-OSPartitionSize`, `Restore-PreviousWinRERoute`, `Assert-RecoveryPartitionLayout`, `Remove-StrayRecoveryPartitions`, and any caller of those functions. **Delete this subsection if it does not apply.**

- [ ] I have named **which of the four design invariants this PR preserves** — see below for the four rules, and [`docs/architecture.md`](docs/architecture.md) for the full hierarchy and the enforcement tables.
- [ ] I have named **which of the four design invariants this PR strengthens**.
- [ ] I confirm this PR **does not weaken any of rules 1–3**.
- [ ] I have included the **test result that demonstrates the change behaves as claimed** — or, if the required test is the post-deletion failure test described in [`docs/testing.md`](docs/testing.md), I have said so explicitly and noted that this PR is **blocked until that test runs and its result is recorded**.
- [ ] If the post-deletion segment of `Ensure-AdequateRecoveryPartition` (the `New-Partition`, `Format-Volume`, `Set-RecoveryPartitionAttributes`, and drive-letter-assignment steps and their failure paths) is touched: the deliberate post-deletion failure test has been run and its result is recorded. Per [`CONTRIBUTING.md`](CONTRIBUTING.md#the-remaining-gated-scope), the four v46 patch 2 hardenings are treated as inside this gate, and the gate's scope has not changed since v46 patch 2 through v50 patch 3. v50 patch 1 does not touch the destructive sequence and did not modify the gate. v50 patch 2 modifies `Remove-StrayRecoveryPartitions` (the non-OS sweep suppression boundary and the `File Backed Virtual` protection), which is on the broader destructive-sequence list in this template, but not the post-deletion segment that the gate protects; the gate's scope is unchanged. v50 patch 3 modifies `Remove-StrayRecoveryPartitions` (positive post-deletion verification) and the recovery-volume drive-letter normalization block in `Main` (OS-disk scope); the former is on the broader destructive-sequence list. Neither touches the post-deletion segment that the gate protects, and the gate's scope is unchanged.

## Invariants

WinRE Manager's design is organized around four rules, in this order. See [`docs/architecture.md`](docs/architecture.md) for the hierarchy, the enforcement tables, and the reasoning behind each.

1. **Never break Windows RE.**
2. **Never leave a machine without a working recovery route** — to the extent the machine, its OS, and its storage stack allow.
3. **Minimize the `reagentc /disable` → `reagentc /enable` window.**
4. **Do no work unless needed. When work is needed, prepare everything before touching anything.**

Rules 1–3 are invariants: no PR may weaken them. Rule 4 is the working rule by which 1–3 are enforced on the fast path, the enable-only path, and the destructive path.

- [ ] I have read the four design invariants in [`docs/architecture.md`](docs/architecture.md) and the "Critical lessons (do not regress)" section in `scripts/WinRE.ps1`
- [ ] This change does not weaken any invariant without a new field case
- [ ] Any destructive operation either verifies preconditions and restores geometry on failure, or sets `$Script:GeometryRestoreFailed`
- [ ] Any `try/catch` either logs, sets a state flag, or both

## Related issues

Closes #
