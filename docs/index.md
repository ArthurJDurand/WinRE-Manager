# WinRE Manager Documentation

WinRE Manager repairs and maintains Windows Recovery Environment on Windows 10 and 11. This index routes you to the operational guide you need; historical release detail is kept in the [changelog](../CHANGELOG.md).

## Choose a Path

| You need to… | Start here |
|---|---|
| Understand the tool or run a one-off repair | [README](../README.md) |
| Inspect a machine without changing it | Run `scripts/Test-WinRE.ps1`; see [testing](testing.md) |
| Deploy to a managed fleet | [Deployment](deployment.md) |
| Understand what the production script will do | [Architecture](architecture.md) |
| Review disk sizing, workspace selection, or partition replacement | [Recovery partition](recovery-partition.md) |
| Investigate driver selection or failed injection | [Driver injection](driver-injection.md) |
| Interpret state, checkpoints, or retry markers | [State and idempotency](state-and-idempotency.md) |
| Diagnose a warning or failure | [Troubleshooting](troubleshooting.md), then [exit codes](exit-codes.md) |

## Safety Model

- A healthy machine should take the idempotent fast path.
- WinRE is prepared on its target volume; C: encryption is never changed by the script.
- Image scratch uses internal fixed NTFS storage only. USB, SD/MMC, network, FireWire, Fibre Channel, unknown-bus disks, and reparse-point workspace paths are excluded.
- A read-only geometry plan and minimal C: shrink happen before disabling WinRE or deleting recovery partitions.
- Failed pre-shrink preserves the current route. A sidecar marker suppresses identical retries while the existing route remains verified functional. A staged optimized WIM, if present, lets the eventual successful retry skip re-servicing; its absence does not affect whether the marker is honored.
- Recovery-typed partitions over 2 GiB and layouts the planner cannot prove contiguous are preserved/deferred for review.

## Current Release

Production is **v45 patch 1**; the read-only harness is **v20**. The v45 `ScriptVersion` change updates the DSI and triggers one full update per managed machine on its next run. Returning to v44 also triggers one full update under the older behavior. See the [v45 migration note](../CHANGELOG.md).

The v45 partition lifecycle has parser and mocked-geometry coverage, but no physical GPT/MBR canary results yet. Use disposable VMs for destructive end-to-end exercises before broad deployment.

## Repository Tools

- `scripts/WinRE.ps1` — elevated production repair and servicing.
- `scripts/Test-WinRE.ps1` — read-only diagnostics and package checks.
- `scripts/Build-DellWinPEMap.ps1`, `scripts/Build-HPWinPEMap.ps1`, `scripts/Build-LenovoWinPEMap.ps1` — optional map-maintenance utilities for teams hosting their own driver maps.
