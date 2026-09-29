## What this changes

<!-- Short summary. -->

## Why

<!-- The field case, review finding, or design reason. -->

## Versioning

- [ ] `ScriptVersion` unchanged (cosmetic, logging-only, or a logic change that does not modify the deployed WIM, the partition layout, or the `DesiredStateId` inputs)
- [ ] `ScriptVersion` bumped because the deployed WIM or partition layout changed
- [ ] `ScriptVersion` bumped because a `DesiredStateId` input changed (a new hardware property or a new deployment input is now part of the ID)
- [ ] If bumped, `DesiredStateId` will change and healthy machines rebuild once
- [ ] If bumped because a `DesiredStateId` input changed, the new `CHANGELOG.md` entry includes a `Migration note` section describing the expected fleet behaviour and the rollback procedure

## Changelog

- [ ] Added an entry to `CHANGELOG.md` describing the change in user-facing terms, with the real field case or review finding that motivated it
- [ ] If the change modifies a design invariant or adds a new lesson, updated the relevant section of the `.NOTES` block in `scripts/WinRE.ps1`

`CHANGELOG.md` is the historical record of what changed and when. The `.NOTES` block records the current design invariants and the CRITICAL LESSONS LEARNED list. The two files serve different readers and both are part of the complete record.

## Testing

- [ ] Parser check passes: `Get-Command .\scripts\WinRE.ps1 -ErrorAction Stop | Out-Null`
- [ ] `.\scripts\WinRE.ps1 -DryRun` completes
- [ ] `.\scripts\Test-WinRE.ps1 -NonInteractive` completes
- [ ] `.\scripts\Test-WinRE.ps1` completes interactively (menu path exercised)
- [ ] Field-tested on a GPT machine
- [ ] Field-tested on an MBR machine
- [ ] If the shrink path is touched: tested on hardware with OS partition at `SizeMin`
- [ ] If the BitLocker handling is touched: verified that the harness's Option 1 "Target recovery partition state" block reflects the state production would prepare, and that the code path for both an unencrypted target and an encrypted target is reachable
- [ ] If the `DesiredStateId` inputs are touched: verified that the harness's Option S "State file parity check" recomputes the same ID production computes on this machine, and that a machine whose previous state file is stale is correctly predicted to rebuild

## Invariants

- [ ] I have read the "CRITICAL LESSONS LEARNED" section in `scripts/WinRE.ps1`
- [ ] This change does not weaken any invariant listed there without a new field case
- [ ] Any destructive operation either verifies preconditions and restores geometry on failure, or sets `$Script:GeometryRestoreFailed`
- [ ] Any `try/catch` either logs, sets a state flag, or both

## Related issues

Closes #
