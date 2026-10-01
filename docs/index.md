# WinRE Manager — Documentation

> **Rebuild broken Windows recovery environments — on one machine, or ten thousand.** WinRE Manager is a PowerShell tool that repairs the Windows Recovery Environment (WinRE) on Windows 10 and Windows 11. It works on a single machine or a managed fleet, and it is safe to re-run: healthy machines exit in under a second.

The [README](../README.md) is the entry point for a quick overview. This page is the documentation index — detailed design, deployment, and troubleshooting material for readers who want to understand how it works, deploy it to a fleet, or diagnose a failure.

---

## What this is, and who it's for

If you are here for the first time, the short version:

- **What it does.** Detects why Windows Recovery has stopped working on a machine and rebuilds it. The common causes are a missing or too-small recovery partition, a `reagentc` registration pointing at the wrong location, a BitLocker-encrypted recovery partition, missing OEM storage drivers, or a hardware change that invalidated the deployed recovery image. The tool handles all of them and reports a clear exit code when it cannot.
- **Who it's for.** An IT professional or power user with a single broken machine (run it once, elevated, done). Or an IT team managing a fleet (deploy as a scheduled task running as `SYSTEM`, triggered at boot and weekly).
- **What it will not do.** It will not touch the OS volume's BitLocker state. It will not repair a machine that has not yet completed OOBE — it defers instead. It will not act on a recovery-typed partition larger than the design's implicit assumptions without warning you first (see the 2 GiB ceiling note in the README).

The read-only harness (`scripts/Test-WinRE.ps1`) is available in every case to inspect a machine before you change anything. It requires no elevation and modifies nothing.

## Start here

### First time here

1. Read the [README](../README.md) for the overview and the "What this fixes" symptom table.
2. Read [architecture.md](architecture.md) — the full design and the reasoning behind each decision.
3. Read [deployment.md](deployment.md) — how to schedule it, how to interpret its exit codes, the Audit Mode precondition, and the one-instance-per-machine program lock.
4. Run `scripts/Test-WinRE.ps1` on a representative machine. Option 1 is the system diagnostic; Option S is the state-file parity check; Option A is "all relevant for this machine".

### If something is broken

Start with [troubleshooting.md](troubleshooting.md). It is a per-symptom playbook — each section names the symptom, the log lines to look for, the likely causes, and the resolution. Key sections:

- **Dedicated recovery partition lost and WinRE disabled.** The most severe failure mode the project has seen. Caused by a bug in pre-v43-patch-5 code on a machine mid-Device-Encryption; fixed in v43 patch 5.
- **Audit Mode / OOBE / sysprep deferral.** The startup guard that no longer loops on freshly imaged machines.
- **VMD hardware detection indeterminate.** The fail-closed deferral added in v44 patch 6.
- **Concurrent instance.** The file lock added in v44 patch 4 and the narrow non-contention lock-failure case.
- **Offline manifest fetch.** The three outcomes of a manifest fetch failure on a machine with no network (v44 patch 5).
- **The machine keeps rebuilding (label-only recovery partition).** The non-convergence loop that v44 patch 7 closed — a Basic Data partition labelled "Recovery" on the OS disk now converges instead of triggering a rebuild on every run.
- **OS-fallback deferred because C: is encrypted.** Includes the combined log signature (`Pre-deletion inventory:` followed in the same run by `OS-fallback deferred: C: could not be confirmed fully decrypted`) that identifies the residual failure-then-fallback corner. The project is actively collecting field data on this corner.

### If you know what you are looking for

Jump straight to the relevant reference document from the table below.

## Reference

| Document | What it covers |
|---|---|
| [architecture.md](architecture.md) | Overall design, control-flow, state model, invariants (including the type-coded recovery-partition authority rule), and the program lock's design reasoning. |
| [state-and-idempotency.md](state-and-idempotency.md) | `DesiredStateId`, state file, checkpoint file, crash consistency, the loop-breaker, the offline fallback's residual risk, and the VMD-query-indeterminate deferral's effect on state. |
| [recovery-partition.md](recovery-partition.md) | Sizing policy, geometry, GPT/MBR attributes, the type-coded invariant, Step 7, and the residual failure-then-fallback corner. |
| [driver-injection.md](driver-injection.md) | OEM pack + VMD injection, the INF-basename success gate, the Lenovo five-state resolution, and the VMD fail-closed guard. |
| [exit-codes.md](exit-codes.md) | Every exit path and its semantics, including the three new exit-code-2 cases from v44 patches 4, 5, and 6. |
| [deployment.md](deployment.md) | Scheduled task, MDM, CI/CD integration, log collection, Audit Mode precondition, one-instance-per-machine policy, offline behavior. |
| [testing.md](testing.md) | The harness, the parser self-test's fifteen checks, what it does not test, and the v18/v19/v20 changes. |
| [troubleshooting.md](troubleshooting.md) | Known failure modes, per-symptom playbook, and recovery procedures. |

## The two scripts

- **`scripts/WinRE.ps1`** — production. Runs elevated on a single machine, or as `SYSTEM` under a scheduled task on a managed fleet. Modifies partition tables, the BitLocker state of the target recovery partition, and the WinRE registration. Never modifies the OS volume's BitLocker state. As of **v44 patch 4**, it holds an exclusive program lock at `C:\ProgramData\OEM\Logs\WinREManager.lock` for its entire duration, so a second concurrent instance fails fast with `EXIT_WARNING` instead of colliding at Step 2. The lock is skipped under `-DryRun`. As of **v44 patch 6**, it removes the v44 patch 3 destructive-path C: guard (the destructive path no longer consults C:'s BitLocker state); distinguishes five Lenovo OEM-pack resolution states; makes VMD hardware presence detection fail-closed; and adds a Step 2 stale-file cleanup on the normal GitHub-download path. As of **v44 patch 7**, it enforces the type-coded-recovery-partition classifier consistently across the fast-path count, the active-location classifier, the final-verification classifier, and `Find-SuitableRecoveryPartition`; clears the VMD extraction directory before each extraction; and reports C:'s actual encryption state in the destructive-replacement WARN.
- **`scripts/Test-WinRE.ps1`** — read-only harness. Exercises the download and extraction paths against live sources; runs a parser self-test against the local Windows tooling; reports the machine's `ImageState`, the BitLocker state of C:, the BitLocker state of the target recovery partition, and — as of **v15** — the `DesiredStateId` production would compute right now compared to the on-disk state file. **v16** added colour-coded output, aligned tables, free-space thresholds, and the `Write-Diag` / `Write-KV` diagnostic helpers. **v17** added a 15-second timeout on every network call matching production, restored the zero-byte download check ordering, and added a note to `Test-VmdDrivers` explaining why the harness exercises drivers production would skip. **v18** mirrored production v44 patch 6 (VMD fail-closed handling in Options 1 and S, Lenovo five-state resolution) and closed several harness-specific issues (shared `Get-DriverManifest` helper, cleanup guard for a pre-existing `$TestDir`, stale-extraction-directory clearing, `Test-VmdDrivers` SKIP on unparsed Intel gen) and added five new parser self-test checks. **v19** corrected Option S: it now reports `SKIP` (not `PASS`) when the state file is absent and the VMD query is indeterminate, matching what a live production run would do; and it clarified the wording of the header and the DSI-MATCH verdict so a matching `DesiredStateId` is not presented as proof that production will take the fast path. **v20** mirrors production v44 patch 3's active-location classifier — a partition must be type-coded and on the OS disk to reach the `DEDICATED` verdict, and a label-only match on the OS disk gets its own `LABEL-ONLY` verdict — and fixes the menu box alignment. Requires no elevation and modifies nothing.

## The three map builders

- **`scripts/Build-DellWinPEMap.ps1`** — rebuilds the Dell map from `DriverPackCatalog.cab`.
- **`scripts/Build-HPWinPEMap.ps1`** — rebuilds the HP map by scraping `ftp.ext.hp.com`.
- **`scripts/Build-LenovoWinPEMap.ps1`** — rebuilds the Lenovo map from `recipecard.json` plus per-DS-ID support-page scrapes.

These are maintenance scripts. You only run them if you are hosting your own maps (see [deployment.md §Hosting your own maps](deployment.md#hosting-your-own-maps)).

## Versioning

- Production script: **v44 patch 7** (`ScriptVersion = 44`).
- Harness: **v20**.

`ScriptVersion` is deliberately decoupled from deployed-WIM changes: fixes that do not modify the deployed WIM and do not change the `DesiredStateId` inputs ship under the same `ScriptVersion`, so healthy machines do not rebuild. See [state-and-idempotency.md](state-and-idempotency.md) for the reasoning.

The v43 generation shipped five sequential patch generations under `ScriptVersion = 43` (v43 patch, patch 2, patch 3, patch 4, patch 5), plus further revisions to patch 5 that added the Audit Mode guard, the enable-failure counter, and the target-volume BitLocker policy inversion. In parallel with the last of these, the read-only harness moved to v14 to keep its BitLocker diagnostic aligned with the production policy.

The v44 patch 1 revision is the deliberate exception to the decoupling rule: it changes the `DesiredStateId` inputs — adding CPU vendor/generation and VMD presence — and therefore bumps `ScriptVersion` to 44. Every managed machine performs one full-update pass on the next scheduled run to rebuild the WIM against the new ID, then returns to the fast path permanently. The harness moved to v15 in the same window, adding the `DesiredStateId` mirror and the state-file parity check (Option S).

The six subsequent v44 patches ship under `ScriptVersion = 44` without changing the `DesiredStateId` inputs. **v44 patch 2** adds `dism /cleanup-image /StartComponentCleanup /ResetBase` to the full-update pipeline; the size reduction materialises on the next natural rebuild, not immediately. **v44 patch 3** adds the destructive-path C: encryption guard inside `Ensure-AdequateRecoveryPartition` (removed in v44 patch 6) and a `base.wim` cleanup on the injection-failure abort branch (retained). **v44 patch 4** adds the program lock at `C:\ProgramData\OEM\Logs\WinREManager.lock`, so a second concurrent instance fails fast with `EXIT_WARNING` instead of colliding at Step 2. **v44 patch 5** adds the offline fallback for the driver manifest fetch and a 15-second timeout on every network call. **v44 patch 6** removes the v44 patch 3 destructive-path C: guard; makes Lenovo OEM-pack resolution distinguish five states; makes VMD hardware detection fail-closed; adds the Step 2 stale-file cleanup on the normal path; and corrects the OS-fallback remediation wording. **v44 patch 7** closes a non-convergence loop by making the type-coded classifier authoritative across every recovery-partition decision — the fast-path count, the active-location classifier, the final-verification classifier, and `Find-SuitableRecoveryPartition` — so a Basic Data partition labelled "Recovery" no longer counts toward the "exactly one recovery partition on the OS disk" condition while being preserved by the destructive path; it also clears the VMD extraction directory before each extraction, and it adds C:'s actual encryption state to the destructive-replacement WARN (diagnostic only). Because none of these six patches changes `ScriptVersion` or the `DesiredStateId`, an already-completed machine will not rerun automatically; the deployment mechanism must invoke the script explicitly to pick the fixes up. The next natural rebuild (manifest bump, OEM pack version change, Windows build change, or CPU/VMD presence change) picks them up regardless. The harness moved from v15 to v16 (colour-coded output refresh), from v16 to v17 (network timeouts, zero-byte check ordering, VMD-presence note), from v17 to v18 (mirror of production v44 patch 6 plus harness-specific fixes and five new parser checks), from v18 to v19 (Option S corrections), and from v19 to v20 (active-location classifier mirror of production v44 patch 3 and menu box alignment) across these patches. See [testing.md](testing.md) for the harness change detail and [exit-codes.md](exit-codes.md) for the three new exit-code-2 cases that patches 4, 5, and 6 introduce.

Full engineering changelog is in the `.NOTES` block at the top of `scripts/WinRE.ps1`; a user-facing summary is in [CHANGELOG.md](../CHANGELOG.md).

## Sponsor

If this project saves you time: **https://github.com/sponsors/ArthurJDurand**
