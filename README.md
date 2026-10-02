# WinRE Manager

> Rebuild broken Windows recovery environments — on one machine, or ten thousand.

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207.x-blue.svg)](https://github.com/ArthurJDurand/WinRE-Manager)
[![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-blue.svg)](https://github.com/ArthurJDurand/WinRE-Manager)
[![Version](https://img.shields.io/badge/version-v46%20patch%202-blue.svg)](CHANGELOG.md)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa.svg)](https://github.com/sponsors/ArthurJDurand)

📖 **[Full documentation →](https://ArthurJDurand.github.io/WinRE-Manager/)**

WinRE Manager is a self-healing Windows Recovery Environment manager for Windows 10 and 11. It repairs and maintains the Windows Recovery Environment (WinRE / Windows RE): it services `winre.wim`, injects OEM and Intel VMD storage drivers, verifies the registered recovery route, and maintains a correctly sized recovery partition. It runs on one machine, or as a scheduled SYSTEM task across a managed fleet. Safe to re-run — healthy machines take an idempotent fast path and exit in under a second.

If you landed here searching for **"fix Windows RE"**, **"fix Windows Recovery Environment"**, **"WinRE is not enabled"**, **"Windows RE is disabled"**, **"Unable to reset, no recovery image"**, **"recovery image not found"**, or **"`reagentc /enable` failed with `0x4c7`"**, jump to [What it handles](#what-it-handles).

## Who it's for

Two audiences. Both drive the same control flow.

```mermaid
flowchart TD
    Start["Windows 10 / 11 machine<br/>with a broken or missing<br/>recovery environment"]

    Start --> Who{"Who is running<br/>WinRE Manager?"}

    Who -->|"Single-machine user"| Single["One-off repair<br/>on your own laptop"]
    Who -->|"IT admin / sysadmin"| Fleet["Scheduled deployment<br/>across a fleet"]

    Single --> RunOne["Run WinRE.ps1 elevated, once"]
    Fleet --> RunFleet["Deploy as a SYSTEM<br/>scheduled task<br/>(or via Intune / RMM)"]

    RunOne --> Flow["Same control flow<br/>on every machine"]
    RunFleet --> Flow

    Flow --> Fast{"What does the<br/>script find?"}
    Fast -->|"Nothing to fix"| FP["Fast path<br/>exits in seconds"]
    Fast -->|"WinRE registered, disabled"| EO["Enable-only repair"]
    Fast -->|"WinRE missing or broken"| FU["Full update<br/>plan · shrink · rebuild · deploy"]

    FP --> End["DEDICATED WinRE<br/>on a dedicated recovery partition"]
    EO --> End
    FU --> End

    Fleet -.->|"optional"| SH["Self-hosting"]
    SH --> SH1["Own driver manifest"]
    SH --> SH2["Own OEM driver maps"]
    SH --> SH3["Own base WIM repository"]

    style Start fill:#1f6feb,stroke:#1f6feb,color:#fff
    style End fill:#238636,stroke:#238636,color:#fff
    style SH fill:#8957e5,stroke:#8957e5,color:#fff
```

| You are | Start here |
|---|---|
| **A single-machine user**, repairing your own laptop | [Start safely](#start-safely) below |
| **An IT admin or sysadmin**, deploying to a managed fleet | [`docs/deployment.md`](docs/deployment.md) |
| **An MSP or sysadmin hosting your own inputs** | [`docs/self-hosting.md`](docs/self-hosting.md) |

## Start safely

Read-only diagnostic first — no elevation required, changes nothing:

```powershell
.\scripts\Test-WinRE.ps1
```

Single-machine repair, from an elevated PowerShell window:

```powershell
.\scripts\WinRE.ps1 -DryRun    # walk the flow, log every decision, change nothing
.\scripts\WinRE.ps1            # actually deploy
```

Fleet deployment: run `WinRE.ps1` as `NT AUTHORITY\SYSTEM` on a scheduled task triggered at boot and weekly. Ready-to-paste task XML and MDM guidance are in [`docs/deployment.md`](docs/deployment.md).

> **Elevated** means an administrator PowerShell prompt — the current user with the Administrator token. **As SYSTEM** means running under the built-in `NT AUTHORITY\SYSTEM` account, which is how a scheduled task is configured. Production needs one or the other. The harness needs neither.

## What it handles

| You are seeing | What WinRE Manager does |
|---|---|
| **"Could not find the recovery environment"** on Startup Repair, or `reagentc` registered to the wrong location | Classifies the current route, services a fresh image, restores registration |
| **"Unable to reset, no recovery image" / "Recovery image not found"** | Rebuilds the WIM from a known-good base, injects OEM and VMD drivers, re-deploys the image |
| **Recovery partition too small** after a Windows Update | Sizes the replacement from the actual serviced WIM plus the Microsoft 250 MiB servicing margin |
| **A missing or undersized recovery partition** | Plans the geometry, shrinks C: minimally, replaces the partition with a correctly sized one |
| **`reagentc /enable` fails** with *"cannot be enabled on a volume with BitLocker Drive Encryption"* | Decrypts the target volume in place if Device Encryption claimed it; never modifies C:'s state |
| **`reagentc /enable` fails with `0x4c7`** (`ERROR_CANCELLED`) | Defers; retries after OOBE completes. Audit Mode, OOBE, and sysprep block `/enable` regardless of WIM correctness |
| **WinRE cannot see the storage controller** (missing OEM WinPE pack or Intel VMD driver) | Injects applicable drivers, verified by INF-basename cross-reference and third-party driver delta |
| **Hardware or deployment inputs changed** (CPU swap, BIOS VMD flip, Windows build change) | Recomputes `DesiredStateId` and rebuilds the WIM against the new inputs |
| **A stray recovery partition exists on a secondary disk** | Removes type-coded recovery partitions from non-OS disks, enforcing one recovery partition per machine |
| **An OEM factory-restore volume carrying the recovery type code** | Recovery-typed partitions over 2 GiB are preserved for operator review — never deleted, never reused |

## See it in action

The harness shows what production would see, without changing anything:

```
  ╔══════════════════════════════════════════════════════════════════╗
  ║ WinRE Manager Test Harness (v22)                                 ║
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
  Version               10.0.26100.9545
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

That machine is in a healthy `DEDICATED` end state. Production takes the fast path and exits in under a second.

## How a full update runs

1. Classify WinRE state and deployment inputs. Healthy routes exit before workspace setup.
2. Select an internal workspace with enough free space; preserve its location in the checkpoint.
3. Obtain a base WIM, inject applicable drivers, run component cleanup, export the optimized WIM.
4. Record `WIM_READY`, then remove `base.wim` to reclaim space before partition work.
5. Reuse a suitable type-coded recovery partition, or make a read-only single-boundary plan for a replacement.
6. Pre-shrink C: inside the reversible window — **before** WinRE is disabled and **before** any partition is deleted. Verify geometry. Then disable WinRE and delete eligible recovery partitions (the currently-active one last).
7. Extend C: into the reclaimed space, create the new recovery partition on the planned boundary, deploy and hash-verify the WIM, prepare the target volume, register and enable WinRE, write deployment state.

## Disk-space and partition safety

- **Workspace selection is restricted to fixed NTFS volumes on internal/virtual buses.** USB, SD/MMC, network, FireWire, Fibre Channel, unknown-bus disks, and reparse-point workspace paths are excluded.
- **Servicing requires 3 GiB free.** Resuming a verified optimized WIM requires 200 MiB.
- **Stale workspace cleanup is scoped to the script's own `X:\Temp\WinREWork` directories** on eligible internal volumes. User files elsewhere are not touched.
- **Partition geometry is planned read-only before any change.** Non-contiguous or uncertain layouts defer rather than being guessed at. The plan clamps to the disk-end reserve and enforces a 2 GiB ceiling on managed recovery partitions.
- **The pre-shrink runs before WinRE is disabled and before any recovery partition is deleted.** Its immediate, sleep, and defrag retries all happen in the reversible window. If the shrink fails, the old route is preserved and the run defers.
- **C: is never expanded to `SizeMax` to stage a replacement.** Failed-shrink recovery targets the exact pre-attempt size.
- **Recovery-typed partitions larger than 2 GiB are preserved** for operator review; they are neither reused nor deleted.
- **A deferral marker suppresses identical retries** while the old route is verified healthy and no fast-path exit is available. If the machine converges on its own, the marker is cleared automatically.
- **Fail-closed on the destructive sequence.** If the active WinRE route cannot be resolved to a partition, or the OS partition cannot be resolved for the layout assertion, the sequence stops before touching the disk.
- **C:'s BitLocker state is never changed by the script.** WinRE is prepared on its *target* volume; the OS volume is only ever read.

**Known limitation — destructive failure after deletion on encrypted C:.** In v45 the pre-shrink is outside the destructive window, so a shrink failure no longer reaches this corner. A failure of `New-Partition` or `Format-Volume` **after** the old recovery partition has already been deleted, on a machine whose C: is encrypted, can still leave the machine with neither a dedicated recovery partition nor OS-fallback — the OS-fallback gate refuses on encrypted C:. The correct fix is a post-failure check in the post-deletion segment, tracked for a future patch. The corner has not been exercised in the field. See [`docs/troubleshooting.md`](docs/troubleshooting.md).

After freeing space or correcting a blocked layout, clear both deferral records to force a retry:

```powershell
Remove-Item "$env:SystemDrive\Recovery\OEM\winre_state.json" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:SystemDrive\Recovery\OEM\winre_partition_deferred.json" -Force -ErrorAction SilentlyContinue
```

Do not force destructive failure tests on production machines. Use a disposable VM.

## Requirements

- **Windows 10** (build 19041+) or **Windows 11** (build 22000+).
- **PowerShell 5.1** (Windows PowerShell) or **PowerShell 7.x**.
- **Elevation or SYSTEM** for production. The harness runs unelevated.
- **7-Zip** at `C:\Program Files\7-Zip\7z.exe`. The script attempts installation via `winget` if missing.
- **Internet access** to `gist.github.com`, `api.github.com`, `downloads.dell.com`, `ftp.ext.hp.com`, `download.lenovo.com`, and `support.lenovo.com` for the first deployment on a fresh machine. The `support.lenovo.com` endpoint is used only by the map-building helper `Build-LenovoWinPEMap.ps1`, not by production. On a machine whose state file is present and whose local safety checks pass, an outage does not prevent the run — the v44 patch 5 offline fallback trusts the stored `DesiredStateId` and takes the fast path. A first deployment with no state file still requires network. All five external artifacts can be self-hosted; see [`docs/self-hosting.md`](docs/self-hosting.md).
- **Windows is in a normal-running state.** The script defers on OOBE and Audit Mode.

There is **no BitLocker precondition on the OS volume**. The policy is target-volume-based: the enable-only and dedicated-partition paths do not depend on C:'s BitLocker state. Only the OS-fallback route does, because there the target volume *is* C:.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Healthy, or successfully repaired |
| `1` | Reboot required to complete registration |
| `2` | Warning, safe deferral, OS-fallback, or a non-fatal cleanup issue |
| `3` | Fatal failure — investigate the log |

Full matrix and orchestration policy in [`docs/exit-codes.md`](docs/exit-codes.md).

## Version

**Production:** `WinRE.ps1` v46 patch 2. **Harness:** `Test-WinRE.ps1` v22.

The v46 patch 1 `ScriptVersion` bump (45 → 46) changes the `DesiredStateId`, so every managed machine performs one full update on its next scheduled run, then returns to the fast path. v46 patch 2 is patch-level only and does not change the `DesiredStateId`; a machine already on v46 patch 1 stays on the fast path. The v46 patch 1 bump clears the OS-fallback state on machines that the v45 plan bug left in the failing branch. See the migration notes in [`CHANGELOG.md`](CHANGELOG.md).

**Field-test status.** The v46 plan-clamp fix is verified on physical hardware — a Lenovo IdeaPad 3 15IAU7 whose factory layout placed a partition 1 MiB past the disk-end reserve was the motivating v45 failure, and the same machine reached `DEDICATED` under v46 patch 1 after the state file was reset. Clean-path verification of the destructive pipeline under v46 patch 1 is on record for the Dell Latitude 3540 and the HP EliteBook 6 G1i 16". The v46 patch 2 build-drift log lines and the guarded `Get-RecoveryPartitions` read are verified on the HP EliteBook 8 G1i 16". The v46-specific *failure* paths — post-delete extension fallback, the pre-shrink deferrals, the fail-closed C: volume-read refuse branch, the shrink retry branches, and the post-deletion failure corner — are covered by parser and mocked-geometry tests but have not been exercised on physical hardware. Canary and use a disposable VM for destructive end-to-end testing before broad rollout.

## Field-tested hardware

| Vendor | Model | OS | Result |
|---|---|---|---|
| Lenovo | IdeaPad 3 15IAU7 (MT 82RK) | Win11 26200 | **v46 patch 1** — motivating failure of the plan-clamp fix (factory partition 1 MiB past reserve, plan rejected post-delete, OS-fallback); after state-file reset, second full-update reached DEDICATED |
| Dell | Latitude 3540 | Win11 26300 | **v46 patch 1** — clean destructive rebuild; `Assert-RecoveryPartitionLayout` PASS; fast path next run |
| HP | EliteBook 6 G1i 16" (MT SBKP, Core Ultra 7 255U) | Win11 26300 | **v46 patch 1** — clean destructive rebuild; first field exercise of the Core Ultra seriesMap branch; fast path next run |
| HP | EliteBook 8 G1i 16" (MT SBKP, Core Ultra 5 235U) | Win11 26300 | **v46 patch 2** — clean destructive rebuild on a machine with an SD/MMC card reader; first field exercise of the build-drift log lines and the guarded `Get-RecoveryPartitions` read; fast path next run |
| ASUS | PRIME H510M-D (i5-11400) | Win11 26300 | **v45 patch 1** — reuse path 2026-10-01 23:48 (internal workspace on E:, WIM serviced and optimized, existing 1000 MiB type-coded partition reused, DEDICATED); fast path 2026-10-02 08:50 |
| (VM) | Hyper-V Windows 11 (i5-11400) | Win11 26300 | **v45 patch 1** — destructive rebuild 2026-10-02 08:56 (plan → pre-shrink → delete → `New-Partition` with recovery GUID at creation → whole-layout assertion PASS → WIM deployed → `reagentc /enable` exit 0 → DEDICATED); fast path 08:58 |
| (VM) | Hyper-V Windows 10 MBR (i5-11400) | Win10 19045 | **v45 patch 1** — first MBR field data 2026-10-02 09:41 (MBR-type recovery partition reused, `set id=27` applied, `reagentc /enable` exit 0, DEDICATED); fast path 09:43; program-lock contention correctly deferred a second concurrent instance at 09:47 |
| Dell | Vostro 16 5640 (Core 7 150U) | Win11 26300 | v44 patch 7 — clean destructive rebuild on encrypted C: |
| Dell | Latitude 5530 (i5-1245U) | Win11 26300 | v44 patch 7 — clean destructive rebuild on encrypted C: |
| Dell | Pro 16 PC16250 (Core Ultra 7 255U) | Win11 26300 | v44 patch 7 — first Intel 15th-gen field data |
| Lenovo | ThinkPad P16s Gen 2 (i7-1370P, MT 21HL) | Win11 26300 | v44 patch 7 — first `resolved` Lenovo OEM state |
| Lenovo | V15 G5 IRL (i5-13420H, MT 83GW) | Win11 26200 | v44 patch 6 — first `no-entry` Lenovo OEM state |
| HP | ProBook 450 G9 (i5-1235U) | Win11 26300 | v44 patch 7 — first 1200 MiB bucket in the field |
| HP | Laptop 15-fc0xxx (Ryzen 5 7520U) | Win11 26300 | v44 patch 7 — first AMD CPU in the field |

The v44 patch 7 guard-free destructive path is field-verified on encrypted C: across eight distinct physical machines (Intel 12th–15th gen and AMD, Dell/HP/Lenovo/ASUS chassis). The v45 VM runs additionally confirmed the single-boundary destructive path end-to-end, and the MBR VM run confirmed the MBR partition-attribute path and the program lock. The v46 patch 1 plan-clamp fix is field-verified on the Lenovo IdeaPad 3 15IAU7 that motivated it, and clean-path verification of v46 patch 1 and v46 patch 2 is on record for the Dell Latitude 3540 and two HP EliteBook G1i models. Full history and per-machine evidence are in the [changelog](CHANGELOG.md).

## Documentation

| Guide | Use it for |
|---|---|
| [Architecture](docs/architecture.md) | Control flow, invariants, design reasoning |
| [Deployment](docs/deployment.md) | Scheduled tasks, MDM, fleet rollout |
| [Self-hosting](docs/self-hosting.md) | Replacing the manifest, OEM maps, and base WIM repo with your own hosting |
| [Recovery partition](docs/recovery-partition.md) | Sizing, geometry planning, replacement behavior |
| [Driver injection](docs/driver-injection.md) | OEM/VMD selection, downloads, validation |
| [State and idempotency](docs/state-and-idempotency.md) | `DesiredStateId`, checkpoints, deployment state, deferral sidecar |
| [Testing](docs/testing.md) | Read-only harness and recommended regression checks |
| [Troubleshooting](docs/troubleshooting.md) | Log signatures and operator recovery steps |
| [Exit codes](docs/exit-codes.md) | Full exit-code matrix and orchestration policy |
| [Changelog](CHANGELOG.md) | Release history and per-machine field evidence |

## Contributing

Bug reports and PRs welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Security

For security issues, see [`SECURITY.md`](SECURITY.md). Do not file public issues for vulnerabilities.

## Sponsor

If WinRE Manager saves you time: **https://github.com/sponsors/ArthurJDurand**

## License

MIT — see [`LICENSE`](LICENSE).
