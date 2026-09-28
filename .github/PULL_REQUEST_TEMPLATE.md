## What this changes

<!-- Short summary. -->

## Why

<!-- The field case, review finding, or design reason. -->

## Versioning

- [ ] `ScriptVersion` unchanged (cosmetic or logging-only fix)
- [ ] `ScriptVersion` bumped (deployed WIM or partition layout changed)
- [ ] If bumped, `DesiredStateId` will change and healthy machines rebuild once

## Changelog

- [ ] Added an entry to the `.NOTES` block in `scripts/WinRE.ps1`
- [ ] Added an entry to `CHANGELOG.md` if user-facing

## Testing

- [ ] `Get-Command -Syntax .\scripts\WinRE.ps1` succeeds
- [ ] `.\scripts\WinRE.ps1 -DryRun` completes
- [ ] `.\scripts\Test-WinRE.ps1 -NonInteractive` completes
- [ ] `.\scripts\Test-WinRE.ps1` completes interactively (menu path exercised)
- [ ] Field-tested on a GPT machine
- [ ] Field-tested on an MBR machine
- [ ] If the shrink path is touched: tested on hardware with OS partition at `SizeMin`

## Invariants

- [ ] I have read the "CRITICAL LESSONS LEARNED" section in `scripts/WinRE.ps1`
- [ ] This change does not weaken any invariant listed there without a new field case
- [ ] Any destructive operation either verifies preconditions and restores geometry on failure, or sets `$Script:GeometryRestoreFailed`
- [ ] Any `try/catch` either logs, sets a state flag, or both

## Related issues

Closes #
