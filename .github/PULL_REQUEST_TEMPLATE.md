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

### If this PR touches the destructive sequence

The destructive sequence covers `Get-PartitionPlan`, `Ensure-AdequateRecoveryPartition`, `Invoke-OSPartitionShrink`, `Invoke-OSPartitionExtend`, the `New-Partition` / `Format-Volume` / `Set-RecoveryPartitionAttributes` calls, `Remove-OrphanPartition`, `Restore-OSPartitionSize`, `Restore-PreviousWinRERoute`, `Assert-RecoveryPartitionLayout`, `Remove-StrayRecoveryPartitions`, and any caller of those functions. **Delete this subsection if it does not apply.**

- [ ] I have named **which of the four design invariants this PR preserves** — see below for the four rules, and [`docs/architecture.md`](docs/architecture.md) for the full hierarchy and the enforcement tables.
- [ ] I have named **which of the four design invariants this PR strengthens**.
- [ ] I confirm this PR **does not weaken any of rules 1–3**.
- [ ] I have included the **test result that demonstrates the change behaves as claimed** — or, if the required test is the post-deletion failure test described in [`docs/testing.md`](docs/testing.md), I have said so explicitly and noted that this PR is **blocked until that test runs and its result is recorded**.
- [ ] If the post-deletion segment of `Ensure-AdequateRecoveryPartition` (the `New-Partition`, `Format-Volume`, `Set-RecoveryPartitionAttributes`, and drive-letter-assignment steps and their failure paths) is touched: the deliberate post-deletion failure test has been run and its result is recorded. Per [`CONTRIBUTING.md`](CONTRIBUTING.md#the-remaining-gated-scope), the four v46 patch 2 hardenings sit inside this gate.

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
