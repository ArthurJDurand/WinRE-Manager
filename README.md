# WinRE Manager

> Rebuild broken Windows recovery environments — on one machine, or ten thousand.

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207.x-blue.svg)](https://github.com/ArthurJDurand/WinRE-Manager)
[![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-blue.svg)]()
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

WinRE Manager repairs the Windows Recovery Environment (WinRE) on Windows 10 and 11. It services `winre.wim`, injects OEM and Intel VMD storage drivers, verifies the registered recovery route, and maintains a correctly sized recovery partition. Safe to re-run: healthy machines take an idempotent fast path and exit in under a second.

## Start safely

Read-only diagnostic first (no elevation required):

```powershell
.\scripts\Test-WinRE.ps1
```

Single-machine repair, from an elevated PowerShell window:

```powershell
.\scripts\WinRE.ps1 -DryRun
.\scripts\WinRE.ps1
```

`-DryRun` describes the planned actions without changing the machine.

For a managed fleet, deploy the production script as `NT AUTHORITY\SYSTEM`, triggered at boot and weekly. See [`docs/deployment.md`](docs/deployment.md) for the ready-to-paste task XML and MDM guidance.

## What it handles

| Situation | Response |
|---|---|
| **"Could not find the recovery environment"** on Startup Repair, or `reagentc` registered to the wrong location | Classifies the current route, services an image, restores registration |
| **Recovery partition too small** after a Windows Update | Calculates the required size from the actual serviced WIM plus the Microsoft 250 MiB servicing margin |
| **`reagentc /enable` fails** with *"Windows RE cannot be enabled on a volume with BitLocker Drive Encryption enabled"* | Prepares the target volume (decrypts it in place if the Device Encryption service claimed it); never modifies C:'s state |
| **`reagentc /enable` fails with `0x4c7`** (`ERROR_CANCELLED`) | Defers; retries after OOBE completes. Audit Mode, OOBE, and sysprep phases block `/enable` regardless of WIM correctness |
| **WinRE cannot see the storage controller** (missing OEM WinPE pack or Intel VMD driver) | Injects applicable drivers; verifies by INF-basename cross-reference and third-party driver delta |
| **Hardware or deployment inputs changed** (CPU swap, BIOS VMD flip, Windows build change) | Recomputes `DesiredStateId` and rebuilds the WIM against the new inputs |
| **C: is nearly full** | Uses an eligible internal fixed NTFS workspace; defers before any partition change if the required reserve is unavailable |

## See it in action

`scripts\Test-WinRE.ps1` is the read-only harness. It shows you what production would see, without changing anything.

```
  ╔══════════════════════════════════════════════════════════════════╗
  ║ WinRE Manager Test Harness (v20)                                 ║
  ║ Working directory: C:\Temp\WinRETest                             ║
  ║ Detected: OS=Win11  Vendor=ASUS  MT=Syst  CPU=Intel              ║
  ╚══════════════════════════════════════════════════════════════════╝
```

Option 1 (System diagnostic) on a healthy ASUS desktop:

```
  WinRE state (parsed)
  ────────────────────
  Status                Enabled
  Location              \\?\GLOBALROOT\device\harddisk4\partition4\
  Resolved to           Disk 4 Part 4
  Classification        DEDICATED (WinRE on type-coded recovery partition on the OS disk)

  OS partition / OS disk
  ──────────────────────
  OS partition          Disk 4 Part 3, 952.41 GiB, letter=C
  OS disk               Disk 4 'PM951 NVMe SAMSUNG 1024GB' style=GPT

  Recovery partitions (per Get-RecoveryPartitions)
  ────────────────────────────────────────────────
  Disk  Part  Size           isTyped   isLabel   onOsDisk
  ────  ────  ─────────────  ────────  ────────  ─────────
  4     4     1.07 GiB       True      True      True

  Target recovery partition state
  ────────────────────────────────
  Registered partition  Disk 4 Part 4
  Classification        unmanaged by BitLocker (reagentc /enable will accept this)
```

That machine is in a healthy `DEDICATED` end state. A production run takes the fast path and exits in under a second.

## Disk-space and partition safety

The v45 partition redesign makes these guarantees:

- **Workspace selection is restricted to fixed NTFS volumes on internal/virtual buses.** USB, SD/MMC, network, FireWire, Fibre Channel, unknown-bus disks, and reparse-point workspace paths are excluded.
- **Servicing requires 3 GiB free.** Resuming a verified optimized WIM requires 200 MiB. These are admission reserves, not guarantees that arbitrary future packages will fit.
- **Stale workspace cleanup is scoped to the script's own `X:\Temp\WinREWork` directories** on eligible internal volumes. User files elsewhere are not touched.
- **Partition geometry is planned read-only before any change.** The plan computes the exact C: shrink from reclaimable recovery space, contiguous unallocated space, and the WIM bucket; non-contiguous or uncertain layouts defer rather than being guessed at.
- **The pre-shrink runs before WinRE is disabled and before any recovery partition is deleted.** Its immediate, sleep, and defrag retries all happen in the reversible window. If the shrink fails, the old route is preserved and the run defers.
- **C: is never expanded to `SizeMax` to stage a replacement.** Failed shrink recovery targets the exact pre-attempt size.
- **Recovery-typed partitions larger than 2 GiB are preserved** for operator review; they are neither reused nor deleted.
- **A deferral marker suppresses identical retries** while the old route is verified healthy and no fast-path exit is available. If the machine converges on its own, the marker is cleared automatically.

After freeing space or correcting a blocked layout, clear both deferral records to force a retry:

```powershell
Remove-Item "$env:SystemDrive\Recovery\OEM\winre_state.json" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:SystemDrive\Recovery\OEM\winre_partition_deferred.json" -Force -ErrorAction SilentlyContinue
```

**Known limitation — destructive failure after deletion on encrypted C:.** In v45 the pre-shrink is now outside the destructive window, so a *shrink* failure no longer reaches this corner. A failure of `New-Partition` or `Format-Volume` *after* the old recovery partition has already been deleted, on a machine whose C: is encrypted, can still leave the machine with neither a dedicated recovery partition nor OS-fallback — the OS-fallback gate refuses on encrypted C:. The correct fix is a post-failure check in the shrink-failure branch, tracked for a future patch. The corner has not been exercised in the field. See [`docs/troubleshooting.md`](docs/troubleshooting.md).

Do not force destructive failure tests on production machines. Use a disposable VM.

## How a full update runs

1. Classify WinRE state and deployment inputs. Healthy routes exit before workspace setup.
2. Select an internal workspace with enough free space and preserve its location in the checkpoint.
3. Obtain a base WIM, inject applicable drivers, run component cleanup, export the optimized WIM.
4. Record `WIM_READY`, then remove `base.wim` to reclaim space before partition work.
5. Reuse a suitable type-coded recovery partition, or make a read-only contiguous-layout plan for a replacement.
6. Shrink C: by only the planned deficit, verify geometry, then disable WinRE and replace eligible partitions.
7. Deploy and hash-verify the WIM, prepare the target volume, register and enable WinRE, write deployment state.

Drive-letter assignment uses the same three-method fallback as earlier releases: `Set-Partition`, `Add-PartitionAccessPath`, then `diskpart`, trying the remaining free letters when needed.

## Requirements

- **Windows 10** (build 19041+) or **Windows 11** (build 22000+).
- **PowerShell 5.1** (Windows PowerShell) or **PowerShell 7.x**.
- **Elevation or SYSTEM** for production. The harness runs unelevated.
- **7-Zip** at `C:\Program Files\7-Zip\7z.exe`. The script attempts installation via `winget` if missing.
- **Internet access** to the driver manifest gist, the three OEM map gists, and the base WIM repository for the first deployment on a fresh machine. On a machine whose state file is present and whose local safety checks pass, an outage does not prevent the run — the v44 patch 5 offline fallback trusts the stored `DesiredStateId` and takes the fast path.
- **Windows is in a normal-running state.** The script defers on OOBE and Audit Mode.

There is **no BitLocker precondition on the OS volume**. The v43 patch 5 (further revision 5) policy is target-volume-based: the enable-only and dedicated-partition paths do not depend on C:'s BitLocker state. Only the OS-fallback route does, because there the target volume *is* C:.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Healthy or successfully repaired |
| `1` | Reboot required to complete registration |
| `2` | Warning, safe deferral, OS-fallback, or a non-fatal cleanup issue |
| `3` | Fatal failure — investigate the log |

Full matrix and orchestration policy in [`docs/exit-codes.md`](docs/exit-codes.md).

## Documentation

| Guide | Use it for |
|---|---|
| [Architecture](docs/architecture.md) | Control flow, invariants, design reasoning |
| [Deployment](docs/deployment.md) | Scheduled tasks, MDM, fleet rollout |
| [Recovery partition](docs/recovery-partition.md) | Sizing, geometry planning, replacement behavior |
| [Driver injection](docs/driver-injection.md) | OEM/VMD selection, downloads, and validation |
| [State and idempotency](docs/state-and-idempotency.md) | DSI, checkpoints, deployment state, deferral sidecar |
| [Testing](docs/testing.md) | Read-only harness and recommended regression checks |
| [Troubleshooting](docs/troubleshooting.md) | Log signatures and operator recovery steps |
| [Changelog](CHANGELOG.md) | Release history and per-machine field evidence |

## Version

Production is **v45 patch 1**. The `ScriptVersion` bump changes the `DesiredStateId`, so every managed machine performs one full update on its next run, then returns to the fast path. Rolling back to v44 also triggers a one-time rebuild under the older layout behavior. See the [migration note](CHANGELOG.md).

**Field-test status.** The reuse path, workspace selection, and WIM servicing are field-verified on physical GPT hardware. The new partition-planning, pre-shrink, and deferral code paths are covered by parser, mocked-geometry, and workspace-selection tests but have not yet been exercised on physical hardware. Use a disposable VM for destructive end-to-end testing and canary before broad rollout.

## Field-tested hardware

| Vendor | Model | OS | Result |
|---|---|---|---|
| ASUS | PRIME H510M-D (i5-11400) | Win11 26300 | **v45 patch 1** — reuse path 2026-10-01 23:48 (internal workspace on E:, stale C: workspace cleaned, WIM serviced and optimized, 1000 MiB partition reused, DEDICATED); fast path 23:51 |
| Dell | Vostro 16 5640 (Core 7 150U) | Win11 26300 | v44 patch 7 — clean destructive rebuild on encrypted C: |
| Dell | Latitude 5530 (i5-1245U) | Win11 26300 | v44 patch 7 — clean destructive rebuild on encrypted C: |
| Dell | Pro 16 PC16250 (Core Ultra 7 255U) | Win11 26300 | v44 patch 7 — first Intel 15th-gen field data |
| Lenovo | ThinkPad P16s Gen 2 (i7-1370P, MT 21HL) | Win11 26300 | v44 patch 7 — first `resolved` Lenovo OEM state |
| Lenovo | V15 G5 IRL (i5-13420H, MT 83GW) | Win11 26200 | v44 patch 6 — first `no-entry` Lenovo OEM state |
| HP | ProBook 450 G9 (i5-1235U) | Win11 26300 | v44 patch 7 — first 1200 MiB bucket in the field |
| HP | Laptop 15-fc0xxx (Ryzen 5 7520U) | Win11 26300 | v44 patch 7 — first AMD CPU in the field |

Full history and per-machine evidence are in the [changelog](CHANGELOG.md).

## Contributing

Bug reports and PRs welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Security

For security issues, see [`SECURITY.md`](SECURITY.md). Do not file public issues for vulnerabilities.

## Sponsor

If WinRE Manager saves you time: **https://github.com/sponsors/ArthurJDurand**

## License

MIT — see [`LICENSE`](LICENSE).
