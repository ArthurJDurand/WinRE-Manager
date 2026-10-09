# Contributing to WinRE Manager

Thanks for considering a contribution. This project is a self-healing production script that runs with administrative privilege and modifies partition tables, so the bar for changes is intentionally high.

## Before you open an issue

1. Search existing issues.
2. Run `scripts/Test-WinRE.ps1` on the affected machine and capture its output.
3. Capture the log at `C:\ProgramData\OEM\Logs\WinRE-Manager.log`.
4. Check [docs/troubleshooting.md](docs/troubleshooting.md).

Before posting diagnostic output publicly, review it for sensitive information and redact personal identifiers, serial numbers, usernames, sensitive local paths, credentials, and any other data that should not be public. Never include a BitLocker recovery key, password, access token, or other secret in an issue or discussion.

## Questions and general discussion

For deployment help, "does this work on X", design discussions, and other content that isn't a bug report or a feature request, use [GitHub Discussions](https://github.com/ArthurJDurand/WinRE-Manager/discussions). Bug reports and feature requests go to Issues, using the templates. Do not post security issues publicly - see [SECURITY.md](SECURITY.md).

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

1. **Read the invariants.** [`docs/architecture.md`](docs/architecture.md) states the four design invariants — the hierarchy that every decision in the script is subordinate to. Below them, its "Control-flow invariants" section lists the detailed enforcement, one entry per guarantee. The `.NOTES` block at the top of `scripts/WinRE.ps1` carries the abbreviated "Critical lessons (do not regress)" list. Every one of those exists because a real machine failed. Do not weaken any of them without a field case.
2. **Check the exit-code semantics.** [docs/exit-codes.md](docs/exit-codes.md) documents priority and precedence. Changes that alter exit paths almost always need a changelog entry.
3. **`ScriptVersion` discipline.** The version bumps when a change modifies the deployed WIM bytes, the partition layout that gets created, or the `DesiredStateId` inputs. A `DesiredStateId` input change (the v44 patch 1 pattern) does not change the WIM bytes on a machine whose driver set is already correct, but it forces every managed machine to rebuild once because the state file's stored ID no longer matches — that counts, and such a change must ship with a `Migration note` section in `CHANGELOG.md` describing the expected fleet behaviour and the rollback procedure. The v45 patch 1 revision is a second instance of the same rule: it changed the `SCRIPT` component of the `DesiredStateId` and shipped with its own migration note. The v46 patch 1 revision is a third: it changed the `SCRIPT` component again (45 → 46) to close a plan-rejection corner that had left affected machines stuck in OS-fallback, and shipped with its own migration note. The v47 patch 1 revision is a fourth, and the first to combine two of the three triggers at once: it changes the image production recipe (the strip stage normalizes the mounted WIM to zero third-party drivers before injection, so a rebuild produces different bytes than v46 would have on the same inputs) **and** bumps `SCRIPT` from 46 to 47, so every managed machine performs one full update on its next scheduled run. It shipped with its own migration note. The v48 patch 1 revision is a fifth: it bundles five distinct changes (intervening-partition handling, the architecture gate, the `LocalInputsId` state-file field, LKG-by-hash at any discovered recovery location, and transactional WIM replacement) and bumps `SCRIPT` from 47 to 48. It shipped with its own migration note. The v48 patch 2 revision did not bump `ScriptVersion` and did not change the `DesiredStateId`; a machine that ran v48 patch 1 continues on the fast path. The v49 revision is a sixth, and the second to combine two of the three triggers at once: it changes the image production recipe (the source-ownership classification preserves a `Foreign-With-Drivers` source as-is rather than strip-and-reinjecting it, the never-downgrade check discards the entire candidate when it would inject a storage driver that is a version downgrade against one already present in the mounted image, and the pre-deployment storage-applicability gate refuses a candidate whose INFs do not match the machine's storage controllers — so a rebuild produces different bytes or a different deployment decision than v48 would have on the same inputs) **and** bumps `SCRIPT` from 48 to 49. It shipped with its own migration note. Cosmetic fixes ship under the same version and the same `DesiredStateId`. If your PR would force a rebuild on healthy machines by any of those three mechanisms, say so explicitly in the PR and explain why.
4. **Changelog.** Every functional change gets an entry in `CHANGELOG.md` with the real field case that motivated it, in the style of the existing entries. The `.NOTES` block records the current design invariants and the CRITICAL LESSONS LEARNED list; update it only when your change modifies an invariant or adds a new lesson. The two files serve different readers and both are part of the complete record.
5. **No silent catch blocks.** Every new `try/catch` must either log, set a state flag, or both. This is the standard for new code. It is also the standing target for the existing code, but the shipping script does not uniformly satisfy it — at least one `catch` block swallows an exception without logging or setting a flag, and a code audit to bring the existing catches into compliance has been deferred. Until that audit runs, treat the rule as aspirational for the current file: do not add new silent catch blocks, and if your PR touches an existing one, bring it into compliance rather than leaving it silent.
6. **No unverified destructive operations.** Any code path that deletes, resizes, or formats a partition must either verify its preconditions and restore geometry on failure, or set `$Script:GeometryRestoreFailed`.

### The four design invariants

`docs/architecture.md` states the hierarchy that every decision in `scripts/WinRE.ps1` is subordinate to. The summary for reviewers:

1. **Never break Windows RE.**
2. **Never leave a machine without a working recovery route** — to the extent the machine, its OS, and its storage stack allow.
3. **Minimize the `reagentc /disable` → `reagentc /enable` window.**
4. **Do no work unless needed. When work is needed, prepare everything before touching anything.**

Rules 1–3 are **invariants**: no PR may weaken them. Rule 4 is the **working rule** by which 1–3 are enforced on the fast path, the enable-only path, and the destructive path.

**What a PR that touches the destructive sequence must state.** The destructive sequence covers `Get-PartitionPlan`, `Ensure-AdequateRecoveryPartition`, `Invoke-OSPartitionShrink`, `Invoke-OSPartitionExtend`, `New-Partition` / `Format-Volume` / `Set-RecoveryPartitionAttributes` calls, `Remove-OrphanPartition`, `Restore-OSPartitionSize`, `Restore-PreviousWinRERoute`, `Assert-RecoveryPartitionLayout`, `Remove-StrayRecoveryPartitions`, and any caller of those functions. Any PR that touches this surface must, in the PR description:

- **Name which of the four rules it preserves.**
- **Name which of the four rules it strengthens.**
- **Confirm it does not weaken any of rules 1–3.**
- **Include the test result that demonstrates the change behaves as claimed** — or, if the required test is the gated one described below, say so explicitly and note that the PR is blocked until the test runs and its result is recorded.

A PR that cannot satisfy those four bullets is not ready to merge. This is the mechanism by which the invariants stay true over time; a code change that quietly erodes an invariant is worse than no code change at all.

### Partition-path validation

The v45 patch 1 revision reordered `Ensure-AdequateRecoveryPartition` so the read-only geometry plan and the C: shrink run before WinRE is disabled or any recovery partition is deleted. A failed pre-shrink now returns `Deferred` with the old route intact, which closes the v44 patch 7 residual for the shrink trigger specifically. A shrink-failure VM exercise is therefore a regression test for the reorder, not a release gate for changes that do not touch the post-deletion segment.

Use mocked geometry tests and a disposable Windows VM for partition-path changes. Never force a shrink failure on a production client.

### The remaining gated scope

The residual corner is narrower than the v44 patch 7 residual: any failure in the post-deletion segment of `Ensure-AdequateRecoveryPartition` — after the old recovery partition has been deleted, on an encrypted C:, with no successful retry — can leave the machine with neither a dedicated recovery partition nor OS-fallback. The most common manifestations are `New-Partition` and `Format-Volume` failures; the whole-layout assertion, drive-letter availability, drive-letter assignment, in-place decryption of the new partition, the post-delete extension fallback, the post-delete geometry verification, the planned-extent-available re-check, and the deletion itself when the previous route cannot be restored all reach the same corner. Until the deliberate post-deletion failure test documented in [`docs/testing.md`](docs/testing.md) runs and its result is recorded, no further changes to the **post-deletion segment** of `Ensure-AdequateRecoveryPartition` — the `New-Partition`, `Format-Volume`, `Set-RecoveryPartitionAttributes`, and drive-letter-assignment steps and their failure paths — should ship.

**The four v46 patch 2 hardenings are treated as inside the gate.** The four post-review hardenings — the pre-deletion resolver guard, the extension-fallback bucket cap, the layout-assertion fail-closed branch, and the deletion-failure partial-rollback reporting — modify the failure behaviour of the destructive sequence. Two of them (`New-Partition` sizing in the fallback branch, the entry condition to `Format-Volume`) unambiguously touch the post-deletion segment; the other two modify failure behaviour elsewhere in the sequence. All four are treated as gated. When the post-deletion failure test runs, its recorded result must list which of the four hardenings it exercised and which it did not; that is the right moment to revisit the scope, not before.

The gate also covers the eventual post-deletion-failure check, future refinements to the 2 GiB sanity ceiling that would touch the post-deletion segment (the ceiling itself is implemented and gates `Find-SuitableRecoveryPartition`, `Remove-StrayRecoveryPartitions`, and `Get-PartitionPlan`), and any other change that alters the destructive sequence after deletion.

**The v48-specific intervening-anchor logic is concentrated in the planning and pre-shrink stages.** The resize-target abstraction moves the pre-shrink target from C: to the anchor in the intervening case. The post-deletion sequence (`New-Partition`, `Format-Volume`, `Set-RecoveryPartitionAttributes`, drive-letter assignment) remains the shared recovery-partition path, with the relevant assertions (`Assert-RecoveryPartitionLayout`) and cleanup (`Remove-OrphanPartition`) operating against the validated resize target and boundary. The v48 development accepted the risk that the post-deletion segment has not been exercised under a deliberate failure on the intervening path, on the reasoning that the segment is the same code with different parameters; the 2026-10-06 field validation confirmed the happy path on the exact motivating layout. The deliberate post-deletion failure test remains the gate for future changes to the segment.

Changes to the **pre-shrink segment** (plan, pre-shrink, verification, deferral) are **not** gated by this residual — but they are still subject to the four-bullet requirement above.

If your PR would alter the post-deletion segment, say so explicitly and include the test result that unblocks it.

## Style

- PowerShell 5.1-compatible syntax. Do not use operators or cmdlets introduced in 7.x without a fallback.
- 4-space indentation (see `.editorconfig`).
- CRLF line endings and UTF-8 with BOM for `.ps1`, `.psm1`, and `.psd1`.
- Functions are verb-first (`Get-`, `Set-`, `Test-`, `Invoke-`, `Remove-`, `Resolve-`).
- `[CmdletBinding()]` on any function with parameters that benefit from pipeline input.
- Parameter blocks in `[Parameter(Mandatory)]` form for required parameters.
- `Write-Log` is the only logging call in production. The harness uses `Say`.
- No `Write-Host` in production code paths. The one exception is `Write-Log` itself, which uses `Write-Host` internally to echo to the console alongside the file append.
- `Test-WinRE.ps1` is a separate console UI and is not subject to this rule; it uses `Say`, `Write-Diag`, and `Write-KV`, which call `Write-Host` directly.
- For a pure syntax check of a `.ps1` file, prefer `[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path <path>).Path, [ref]$null, [ref]$null)` over `Get-Command`. Both throw on a syntax error; the Parser form is explicit about its purpose.

## Testing

Before you submit:

```powershell
# 1. Parser check — throws on any syntax error
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\scripts\WinRE.ps1).Path, [ref]$null, [ref]$null)

# 2. Dry run on a real machine (VM preferred) — must run elevated;
#    -DryRun is not exempt from the elevation guard
powershell -ExecutionPolicy Bypass -File .\scripts\WinRE.ps1 -DryRun

# 3. Harness
powershell -ExecutionPolicy Bypass -File .\scripts\Test-WinRE.ps1

# 4. Interactive end-to-end smoke test (optional but recommended)
.\scripts\WinRE-Manager.cmd
```

Use mocked geometry tests and a disposable Windows VM for partition-path changes. Physical GPT/MBR canary runs are recommended before broad fleet rollout; for changes to the post-deletion segment of the destructive path they are required — see the gating note above. Never force a shrink failure on a production client.

## Security

See [SECURITY.md](SECURITY.md). Do not file public issues for vulnerabilities.

## License

By contributing, you agree your contributions are licensed under the MIT License.
