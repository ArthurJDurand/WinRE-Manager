# Contributing to WinRE Manager

Thanks for considering a contribution. This project is a self-healing production script that runs with administrative privilege and modifies partition tables, so the bar for changes is intentionally high.

## Before you open an issue

1. Search existing issues.
2. Run `scripts/Test-WinRE.ps1` on the affected machine and capture its output.
3. Capture the log at `C:\ProgramData\OEM\Logs\WinRE-Manager.log`.
4. Check [docs/troubleshooting.md](docs/troubleshooting.md).

## Bug reports

Use the issue template. Include:

- `WinRE.ps1` version (from the top of the `.NOTES` block).
- Windows build (`[Environment]::OSVersion.Version`).
- Vendor, model, Lenovo machine type if applicable.
- The BitLocker state of C: — both fields, not just one: `ProtectionStatus` and `VolumeStatus` from `Get-BitLockerVolume -MountPoint "C:"`, or the raw `manage-bde -status C:` output. Under the target-volume policy the field that matters for the OS-fallback path is `VolumeStatus`, because a machine can be actively encrypting (`EncryptionInProgress`) while `ProtectionStatus` reads `Off`. If the machine's WinRE is registered to a dedicated recovery partition, also include the same two fields for that partition (query `manage-bde -status` against its drive letter if it has one, or its `UniqueId` if it does not).
- The `ImageState` value from `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` if the machine may be in Audit Mode or OOBE.
- The exit code.
- Whether a deferral marker exists at `C:\Recovery\OEM\winre_partition_deferred.json`. If it does, include its contents (the `DesiredStateId` and `Since` fields) — they identify the exact deployment under which the destructive sequence deferred.
- The relevant slice of the log — not the whole file unless requested.

## Pull requests

Before you write code:

1. **Read the invariants.** The `.NOTES` block at the top of `scripts/WinRE.ps1` contains a "Critical lessons (do not regress)" section. Every one of those exists because a real machine failed. Do not weaken them without a field case.
2. **Check the exit-code semantics.** [docs/exit-codes.md](docs/exit-codes.md) documents priority and precedence. Changes that alter exit paths almost always need a changelog entry.
3. **`ScriptVersion` discipline.** The version bumps when a change modifies the deployed WIM bytes, the partition layout that gets created, or the `DesiredStateId` inputs. A `DesiredStateId` input change (the v44 patch 1 pattern) does not change the WIM bytes on a machine whose driver set is already correct, but it forces every managed machine to rebuild once because the state file's stored ID no longer matches — that counts, and such a change must ship with a `Migration note` section in `CHANGELOG.md` describing the expected fleet behaviour and the rollback procedure. The v45 patch 1 revision is a second instance of the same rule: it changed the `SCRIPT` component of the `DesiredStateId` and shipped with its own migration note. Cosmetic fixes ship under the same version and the same `DesiredStateId`. If your PR would force a rebuild on healthy machines by any of those three mechanisms, say so explicitly in the PR and explain why.
4. **Changelog.** Every functional change gets an entry in `CHANGELOG.md` with the real field case that motivated it, in the style of the existing entries. The `.NOTES` block records the current design invariants and the CRITICAL LESSONS LEARNED list; update it only when your change modifies an invariant or adds a new lesson. The two files serve different readers and both are part of the complete record.
5. **No silent catch blocks.** Every `try/catch` either logs, sets a state flag, or both.
6. **No unverified destructive operations.** Any code path that deletes, resizes, or formats a partition must either verify its preconditions and restore geometry on failure, or set `$Script:GeometryRestoreFailed`.

**Partition-path validation.** The v45 patch 1 revision reordered `Ensure-AdequateRecoveryPartition` so the read-only geometry plan and the C: shrink run before WinRE is disabled or any recovery partition is deleted. A failed pre-shrink now returns `Deferred` with the old route intact, which closes the v44 patch 7 residual for the shrink trigger specifically. A shrink-failure VM exercise is therefore a regression test for the reorder, not a release gate for changes that do not touch the post-deletion segment. Use mocked geometry tests and a disposable Windows VM for partition-path changes; never force a shrink failure on a production client.

**The remaining gated scope.** The residual corner is narrower than the v44 patch 7 residual: a `New-Partition` or `Format-Volume` failure **after** the old recovery partition has been deleted, on an encrypted C:, with no successful retry. Until the deliberate post-deletion failure test documented in [`docs/testing.md`](docs/testing.md) runs and its result is recorded, no further changes to the post-deletion segment of `Ensure-AdequateRecoveryPartition` — the `New-Partition`, `Format-Volume`, `Set-RecoveryPartitionAttributes`, and drive-letter-assignment steps and their failure paths — should ship. This covers the eventual post-deletion-failure check, the planned 2 GiB sanity ceiling, and any other change that alters the destructive sequence after deletion. Changes to the pre-shrink segment (plan, pre-shrink, verification, deferral) are not gated by this residual. If your PR would alter the post-deletion segment, say so explicitly and include the test result that unblocks it.

## Style

- PowerShell 5.1-compatible syntax. Do not use operators or cmdlets introduced in 7.x without a fallback.
- 4-space indentation (see `.editorconfig`).
- CRLF line endings and UTF-8 with BOM for `.ps1`, `.psm1`, and `.psd1`.
- Functions are verb-first (`Get-`, `Set-`, `Test-`, `Invoke-`, `Remove-`, `Resolve-`).
- `[CmdletBinding()]` on any function with parameters that benefit from pipeline input.
- Parameter blocks in `[Parameter(Mandatory)]` form for required parameters.
- `Write-Log` is the only logging call in production. The harness uses `Say`.
- No `Write-Host` in production code paths.

## Testing

Before you submit:

```powershell
# 1. Parser check — throws on any syntax error
Get-Command .\scripts\WinRE.ps1 -ErrorAction Stop | Out-Null

# 2. Dry run on a real machine (VM preferred)
.\scripts\WinRE.ps1 -DryRun

# 3. Harness
.\scripts\Test-WinRE.ps1
```

Use mocked geometry tests and a disposable Windows VM for partition-path changes. Physical GPT/MBR canary runs are recommended before broad fleet rollout; for changes to the post-deletion segment of the destructive path they are required — see the gating note above. Never force a shrink failure on a production client.

## Security

See [SECURITY.md](SECURITY.md). Do not file public issues for vulnerabilities.

## License

By contributing, you agree your contributions are licensed under the MIT License.
