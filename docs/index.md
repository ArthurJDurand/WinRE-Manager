# WinRE Manager — Documentation

> Idempotent, self-healing Windows Recovery Environment management for managed Windows 10/11 fleets.

Welcome. This is the documentation index. The [README](../README.md) is the entry point; this page links the detailed design, deployment, and troubleshooting material.

## Start here

If you have never deployed WinRE Manager before:

1. Read [architecture.md](architecture.md) — the pipeline in ten steps and the five control-flow paths.
2. Read [recovery-partition.md](recovery-partition.md) — the partition lifecycle and sizing policy, which is where the design's decisions bite.
3. Read [deployment.md](deployment.md) — how to schedule it, how to interpret its exit codes, and the Audit Mode precondition.
4. Read [state-and-idempotency.md](state-and-idempotency.md) — the `DesiredStateId` composition and the fast-path gates, which the v44 patch 1 revision extended.
5. Run `scripts/Test-WinRE.ps1` on a representative machine. It is read-only. Option 1 is the system diagnostic; Option S is the state-file parity check; Option A is "all relevant for this machine".

If you are troubleshooting a failure, start with [troubleshooting.md](troubleshooting.md). The first section is a full recovery procedure for the most severe failure mode the project has seen (dedicated recovery partition lost and WinRE disabled by pre-v43-patch-5 code on a machine mid-Device-Encryption). The second section covers the Audit Mode / OOBE deferral that no longer loops as of the same further revision.

## Reference

| Document | What it covers |
|---|---|
| [architecture.md](architecture.md) | Overall design, control-flow, state model, invariants. |
| [state-and-idempotency.md](state-and-idempotency.md) | `DesiredStateId`, state file, checkpoint file, crash consistency, the loop-breaker. |
| [recovery-partition.md](recovery-partition.md) | Sizing policy, geometry, GPT/MBR attributes, Step 7. |
| [driver-injection.md](driver-injection.md) | OEM pack + VMD injection, the INF-basename success gate. |
| [exit-codes.md](exit-codes.md) | Every exit path and its semantics. |
| [deployment.md](deployment.md) | Scheduled task, MDM, CI/CD integration, log collection, Audit Mode precondition. |
| [testing.md](testing.md) | The harness, the parser self-test, what it does not test. |
| [troubleshooting.md](troubleshooting.md) | Known failure modes, per-symptom playbook, and recovery procedures. |

## The two scripts

- **`scripts/WinRE.ps1`** — production. Runs as SYSTEM on managed machines. Modifies partition tables, the BitLocker state of the target recovery partition, and the WinRE registration. Never modifies the OS volume's BitLocker state.
- **`scripts/Test-WinRE.ps1`** — read-only harness. Exercises the download and extraction paths against live sources; runs a parser self-test against the local Windows tooling; reports the machine's `ImageState`, the BitLocker state of C:, the BitLocker state of the target recovery partition, and — as of v15 — the `DesiredStateId` production would compute right now compared to the on-disk state file. Requires no elevation and modifies nothing.

## The three map builders

- **`scripts/Build-DellWinPEMap.ps1`** — rebuilds the Dell map from `DriverPackCatalog.cab`.
- **`scripts/Build-HPWinPEMap.ps1`** — rebuilds the HP map by scraping `ftp.ext.hp.com`.
- **`scripts/Build-LenovoWinPEMap.ps1`** — rebuilds the Lenovo map from `recipecard.json` plus per-DS-ID support-page scrapes.

These are maintenance scripts. You only run them if you are hosting your own maps (see [deployment.md §Hosting your own maps](deployment.md#hosting-your-own-maps)).

## Versioning

- Production script: **v44 patch 1** (`ScriptVersion = 44`).
- Harness: **v15**.

`ScriptVersion` is deliberately decoupled from deployed-WIM changes: fixes that do not modify the deployed WIM and do not change the `DesiredStateId` inputs ship under the same `ScriptVersion`, so healthy machines do not rebuild. See [state-and-idempotency.md](state-and-idempotency.md) for the reasoning.

The v43 generation shipped five sequential patch generations under `ScriptVersion = 43` (v43 patch, patch 2, patch 3, patch 4, patch 5), plus further revisions to patch 5 that added the Audit Mode guard, the enable-failure counter, and the target-volume BitLocker policy inversion. In parallel with the last of these, the read-only harness moved to v14 to keep its BitLocker diagnostic aligned with the production policy.

The v44 patch 1 revision is the deliberate exception to the decoupling rule: it changes the `DesiredStateId` inputs — adding CPU vendor/generation and VMD presence — and therefore bumps `ScriptVersion` to 44. Every managed machine performs one full-update pass on the next scheduled run to rebuild the WIM against the new ID, then returns to the fast path permanently. The harness moved to v15 in the same window, adding the `DesiredStateId` mirror and the state-file parity check (Option S).

Full engineering changelog is in the `.NOTES` block at the top of `scripts/WinRE.ps1`; a user-facing summary is in [CHANGELOG.md](../CHANGELOG.md).

## Sponsor

If this project saves you time: **https://github.com/sponsors/ArthurJDurand**
