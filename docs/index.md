# WinRE Manager — Documentation

> Idempotent, self-healing Windows Recovery Environment management for managed Windows 10/11 fleets.

Welcome. This is the documentation index. The [README](../README.md) is the entry point; this page links the detailed design, deployment, and troubleshooting material.

## Start here

If you have never deployed WinRE Manager before:

1. Read [architecture.md](architecture.md) — the pipeline in eight steps and the four control-flow paths.
2. Read [recovery-partition.md](recovery-partition.md) — the partition lifecycle and sizing policy, which is where the design's decisions bite.
3. Read [deployment.md](deployment.md) — how to schedule it, how to interpret its exit codes, and the BitLocker precondition.
4. Run `scripts/Test-WinRE.ps1` on a representative machine. It is read-only.

If you are troubleshooting a failure, start with [troubleshooting.md](troubleshooting.md). The first section is a full recovery procedure for the most severe failure mode the project has seen (dedicated recovery partition lost and WinRE disabled by pre-v43-patch-5 code on a machine mid-Device-Encryption).

## Reference

| Document | What it covers |
|---|---|
| [architecture.md](architecture.md) | Overall design, control-flow, state model, invariants. |
| [state-and-idempotency.md](state-and-idempotency.md) | `DesiredStateId`, state file, checkpoint file, crash consistency. |
| [recovery-partition.md](recovery-partition.md) | Sizing policy, geometry, GPT/MBR attributes, Step 7. |
| [driver-injection.md](driver-injection.md) | OEM pack + VMD injection, the INF-basename success gate. |
| [exit-codes.md](exit-codes.md) | Every exit path and its semantics. |
| [deployment.md](deployment.md) | Scheduled task, MDM, CI/CD integration, log collection, BitLocker precondition. |
| [testing.md](testing.md) | The harness, the parser self-test, what it does not test. |
| [troubleshooting.md](troubleshooting.md) | Known failure modes, per-symptom playbook, and recovery procedures. |

## The two scripts

- **`scripts/WinRE.ps1`** — production. Runs as SYSTEM on managed machines. Modifies partition tables, BitLocker state, and the WinRE registration.
- **`scripts/Test-WinRE.ps1`** — read-only harness. Exercises the download and extraction paths against live sources; runs a parser self-test against the local Windows tooling. Requires no elevation and modifies nothing.

## The three map builders

- **`scripts/Build-DellWinPEMap.ps1`** — rebuilds the Dell map from `DriverPackCatalog.cab`.
- **`scripts/Build-HPWinPEMap.ps1`** — rebuilds the HP map by scraping `ftp.ext.hp.com`.
- **`scripts/Build-LenovoWinPEMap.ps1`** — rebuilds the Lenovo map from `recipecard.json` plus per-DS-ID support-page scrapes.

These are maintenance scripts. You only run them if you are hosting your own maps (see [deployment.md §Hosting your own maps](deployment.md#hosting-your-own-maps)).

## Versioning

- Production script: **v43 patch 5**.
- Harness: **v12**.

`ScriptVersion` is deliberately decoupled from deployed-WIM changes. Fixes that do not modify the deployed WIM or the partition layout ship under the same `ScriptVersion` and the same `DesiredStateId`, so healthy machines do not rebuild. See [state-and-idempotency.md](state-and-idempotency.md) for the reasoning.

The current generation is `ScriptVersion = 43` with five sequential patch generations (v43 patch, patch 2, patch 3, patch 4, patch 5) shipped under it. Full engineering changelog is in the `.NOTES` block at the top of `scripts/WinRE.ps1`; a user-facing summary is in [CHANGELOG.md](../CHANGELOG.md).

## Sponsor

If this project saves you time: **https://github.com/sponsors/ArthurJDurand**
