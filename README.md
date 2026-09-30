# WinRE Manager

> **Rebuild broken Windows recovery environments — on one machine, or ten thousand.** WinRE Manager finds out why Windows Recovery (WinRE) has stopped working, fixes it, and keeps it fixed. Run it once for a one-off repair, or on a schedule across a managed fleet.

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207.x-blue.svg)](https://github.com/ArthurJDurand/WinRE-Manager)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-lightgrey.svg)]()
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa.svg)](https://github.com/sponsors/ArthurJDurand)

📖 **[Full documentation](https://ArthurJDurand.github.io/WinRE-Manager/)**

---

## What it is, and who it's for

WinRE Manager is a PowerShell tool that repairs the Windows Recovery Environment on Windows 10 and Windows 11 machines. If your computer shows *"Could not find the recovery environment"* during Startup Repair, or `reagentc /enable` refuses to run, or the recovery partition is missing, too small, or on the wrong disk — this tool rebuilds it. It is safe to run on a healthy machine: re-runs are no-ops.

It is designed for two audiences:

- **An IT professional or power user with a single broken machine.** Run the production script once, elevated. It inspects, repairs, and exits. No installer, no service, no configuration file.
- **An IT team managing a fleet of Windows machines.** Deploy the script as a scheduled task running as `SYSTEM`, triggered at boot and weekly. Every machine keeps its recovery environment healthy on its own, and healthy machines exit in under a second.

The read-only harness (`Test-WinRE.ps1`) is available in both cases to inspect a machine before you change anything.

## What this fixes

Windows recovery breaks in ways that are hard to diagnose and tedious to repair by hand. This is the map from "the error message you saw" to "what WinRE Manager does about it."

| You are seeing | What it usually means | What WinRE Manager does |
|---|---|---|
| **"Could not find the recovery environment"** on Startup Repair | The recovery partition is missing, empty, too small, or `reagentc` is not pointing at it | Rebuilds the partition if needed, copies a freshly-prepared `winre.wim` into it, and re-registers `reagentc` |
| **`reagentc /enable` fails** with *"Windows RE cannot be enabled on a volume with BitLocker Drive Encryption enabled"* | The target volume was encrypted by Device Encryption before `reagentc` could claim it | Decrypts the target partition in place with `manage-bde -off` (polling to completion), then enables |
| **Recovery partition is too small** after a Windows Update | The updated `winre.wim` no longer fits, and the update could not stage it | Shrinks the OS partition by the exact bucket size required, creates a correctly-sized recovery partition, and deploys |
| **`reagentc /enable` fails with `0x4c7` (`ERROR_CANCELLED`)** | The machine is in Audit Mode, OOBE, or a sysprep phase | Defers without touching the machine, and retries on the next scheduled run after OOBE completes |
| **WinRE is disabled** after enabling BitLocker or Device Encryption | The recovery partition was auto-encrypted by the encryption service before its recovery type GUID could be applied | Re-applies the recovery GUID at partition creation and decrypts in place if it was claimed anyway |
| **Startup Repair picks the wrong WinRE image** | A stray recovery partition exists on a secondary or USB-attached disk | Removes type-coded recovery partitions from non-OS disks, enforcing one-recovery-partition-per-machine |
| **Recovery fails after a BIOS update or CPU/motherboard swap** | The deployed WinRE was built for different storage hardware and cannot see the OS disk | Detects the hardware change via `DesiredStateId` and rebuilds the WIM with the correct driver set |
| **Intel VMD system cannot see the OS disk in recovery** | The VMD storage driver is missing from the deployed WinRE | Injects the correct Intel VMD driver package from a live manifest, keyed to the CPU generation |

If your fleet has any of these problems, this tool is for you. If it does not, running it once and letting it take the fast path is harmless.

---

## Running it

There are three ways to run WinRE Manager, depending on what you need.

### One-time fix on a single machine

For a single broken machine, run the production script once from an elevated PowerShell prompt. It inspects, repairs, and exits.

```powershell
# Elevated PowerShell (Run as Administrator)
.\scripts\WinRE.ps1 -DryRun   # walk the flow, log every decision, change nothing
.\scripts\WinRE.ps1           # actually deploy
```

That is the entire workflow. There is no installer, no service, no configuration file to edit.

### Fleet deployment as a scheduled task

For a managed fleet, deploy `WinRE.ps1` as a scheduled task running as `NT AUTHORITY\SYSTEM`, triggered at boot and weekly. Each run takes the fast path on a healthy machine (a few seconds of read-only scanning) and performs a full repair only when something has changed.

See [`docs/deployment.md`](docs/deployment.md) for the ready-to-paste task XML and MDM/Intune integration.

### Verify first with the read-only harness

Before running the production script on an unfamiliar machine, run `Test-WinRE.ps1`. It is read-only, needs no elevation, and shows you exactly what production would see.

```powershell
.\scripts\Test-WinRE.ps1

#   Option 1 = System diagnostic (what the production script would see)
#   Option S = State file parity check (would production take the fast path?)
#   Option A = All relevant for this machine (download + extraction validation)
```

### A note on "elevated" vs "as SYSTEM"

"Elevated" means running from an administrator PowerShell prompt — the current user, with the Administrator token. "As SYSTEM" means running under the built-in `NT AUTHORITY\SYSTEM` account, which is how a scheduled task is configured. The production script needs one or the other because it modifies partition tables and the WinRE registration; those operations require that privilege level. The harness needs neither. In practice, you use "elevated" for a one-off fix and "as SYSTEM" for a fleet deployment. You never need both at once.

---

## See it in action

`scripts\Test-WinRE.ps1` is the read-only harness. It shows you exactly what production would see on a machine, without changing anything.

```
  ╔══════════════════════════════════════════════════════════════════╗
  ║ WinRE Manager Test Harness (v18)                                 ║
  ║ Working directory: C:\Temp\WinRETest                             ║
  ║ Detected: OS=Win11  Vendor=ASUS  MT=Syst  CPU=Intel              ║
  ╚══════════════════════════════════════════════════════════════════╝
```

Running Option 1 (System diagnostic) on a healthy ASUS desktop:

```
  WinRE state (parsed)
  ────────────────────
  Status                Enabled
  Location              \\?\GLOBALROOT\device\harddisk4\partition4\
  Classification        DEDICATED (WinRE on dedicated recovery partition on the OS disk)

  OS partition / OS disk
  ──────────────────────
  OS partition          Disk 4 Part 3, 952.41 GiB, letter=C
  OS disk               Disk 4 'PM951 NVMe SAMSUNG 1024GB' style=GPT

  OS volume free space  173.14 GiB of 952.41 GiB (18.2% free)

  Recovery partitions (per Get-RecoveryPartitions)
  ────────────────────────────────────────────────
  Disk  Part  Size           isTyped   isLabel   onOsDisk
  ────  ────  ─────────────  ────────  ────────  ─────────
  4     4     1.07 GiB       True      True      True

  BitLocker on C:
  ───────────────
  ProtectionStatus      Off
  VolumeStatus          FullyDecrypted

  Target recovery partition state
  ────────────────────────────────
  Registered partition  Disk 4 Part 4
  Classification        unmanaged by BitLocker (reagentc /enable will accept this)
```

That machine is in a healthy `DEDICATED` end state. A production run would take the fast path and exit in under a second.

---

## Why this exists

Windows ships a working recovery environment out of the box. It stops working when any of the following happen:

- **A Windows Update replaces `winre.wim` with a newer, larger one.** The recovery partition no longer has room for it plus the Microsoft-documented servicing margin.
- **BitLocker or Device Encryption auto-encrypts a freshly created recovery partition.** `reagentc /enable` then refuses with *"Windows RE cannot be enabled on a volume with BitLocker Drive Encryption enabled."*
- **Device Encryption is mid-encryption** on Windows 11 24H2+ (`VolumeStatus=EncryptionInProgress` while `ProtectionStatus` reads `Off`). The encryption service claims any new partition the script creates before the recovery type GUID can be applied.
- **A BIOS or firmware update flips VMD on or off, or the CPU or motherboard is replaced on the same chassis.** The deployed WinRE was built with a driver set that no longer matches the hardware. On VMD-based systems the resulting recovery environment cannot see the OS disk at all.
- **The OEM's WinPE driver pack is missing or stale.** The recovery environment cannot see the storage controller.
- **A disk migration or clone leaves the `reagentc` registration pointing at a partition that no longer exists.** Windows silently falls back to `C:\Recovery\WindowsRE`.
- **A recovery partition ends up on a secondary disk,** where it confuses the boot loader and causes Startup Repair to fail.
- **A freshly-imaged machine has not yet completed OOBE.** `reagentc /enable` is blocked by the OS in Audit Mode, OOBE, and the sysprep phases regardless of WIM correctness.

WinRE Manager addresses all of these idempotently. Running it twice in a row on a healthy machine is a no-op. Running it on a broken machine repairs what it can and reports a warning exit code when full remediation is not possible — never a silent success.

---

## What it does, in order

The program acquires an exclusive file lock before doing anything else, so a second instance launched concurrently fails fast with a clear message instead of racing on `C:\Temp\WinREWork`. The manifest fetch that runs early in the pipeline has an offline fallback: if the network is unreachable and the on-disk state file is valid, the machine takes the fast path from local state rather than failing. The VMD hardware presence check is fail-closed: if the enumeration cannot be completed, the run defers rather than guessing that VMD is absent. The remaining steps are:

1. Detects hardware: vendor, model, Lenovo machine type, Intel CPU generation, Windows build.
2. Detects VMD hardware presence (fail-closed) and resolves the manifest-derived required driver set.
3. Computes the `DesiredStateId` from current deployment inputs and reads the on-disk state file. A matching ID and a healthy machine take the fast path and exit without modifying anything.
4. Resolves the current base WIM: reads the live recovery image at the `reagentc`-registered location, or falls back to `C:\Recovery\WindowsRE\winre.wim`, or downloads a fresh one from GitHub.
5. Mounts and injects drivers: OEM WinPE pack for the vendor (Lenovo resolution distinguishes five states — a legitimate "no pack" answer is treated differently from a broken map), then Intel VMD pack if VMD hardware is present.
6. Runs component cleanup and ResetBase (`dism /cleanup-image /StartComponentCleanup /ResetBase`) on the mounted image. ResetBase failure is non-fatal.
7. Optimizes and exports the WIM (`dism /Export-Image /Compress:max`).
8. Ensures a correctly-sized recovery partition exists on the **OS disk**: accepts an existing one that meets the 250 MiB free-space policy, or deletes strays, extends, shrinks by the required bucket + 1 MiB, and creates a new partition with the recovery type GUID applied at creation.
9. Deploys the WIM: prepares the target with `Set-RecoveryPartitionReadyForWinRE` (decrypting in place if needed), copies the WIM, verifies SHA256, sets the recovery type GUID and GPT attributes, registers it with `reagentc /setreimage`, and enables WinRE.
10. Enforces the invariant "exactly one recovery partition, on the OS disk" by removing any stray type-coded recovery partition on non-OS disks.
11. Writes a state file containing the deployed WIM hash and the `DesiredStateId` so the next run can short-circuit.

See [`docs/architecture.md`](docs/architecture.md) for the full design, [`docs/recovery-partition.md`](docs/recovery-partition.md) for the partition-lifecycle model, and [`docs/state-and-idempotency.md`](docs/state-and-idempotency.md) for the `DesiredStateId` composition and fast-path gates.

---

## ⚠️ Before you run this

> **Known limitation — verify your recovery partitions first.**
>
> WinRE Manager identifies recovery partitions by their GPT recovery type GUID (`{de94bba4-06d1-4d40-a16a-bfd50179d6ac}`) or MBR type code (`0x27`). Three code paths act on those partitions:
>
> - The **destructive path** (`Ensure-AdequateRecoveryPartition`) deletes every partition on the OS disk that carries that type code, without checking its size or contents.
> - The **reuse path** (`Find-SuitableRecoveryPartition`) accepts an existing recovery-typed partition that meets the free-space policy, without checking its size against an upper bound.
> - The **stray-cleanup path** (`Remove-StrayRecoveryPartitions`) deletes any type-coded recovery partition on a non-OS disk, without checking size.
>
> Windows Setup and Windows in-place upgrade create recovery partitions under 1.5 GiB. **OEM factory recovery volumes** — the Dell / HP / Lenovo image-restore volumes that hold the OEM's factory Windows image and utilities — can be 7–20 GiB and may carry the same recovery type code. On a machine where an OEM factory recovery volume carries the recovery type code, this script may delete it or re-use it as if it were a Windows recovery partition.
>
> **Before running this script on a machine you did not image yourself**, run `scripts\Test-WinRE.ps1` and inspect the "Recovery partitions" section of the Option 1 diagnostic. It lists every recovery-typed partition on the machine with its size. A recovery-typed partition larger than 2 GiB is a red flag — investigate before proceeding.
>
> A 2 GiB sanity ceiling is planned but not yet implemented. When implemented, it must gate **all three** functions above — not only the destructive one. Tracked in the "Known gaps" section of the `.NOTES` block in `scripts/WinRE.ps1`.

---

## Exit codes

| Code | Name | Meaning |
|------|------|---------|
| `0` | `EXIT_SUCCESS` | WinRE enabled, dedicated recovery partition healthy, state file written or already current. |
| `1` | `EXIT_REBOOT_REQUIRED` | Deployment succeeded; a reboot is required to complete registration. |
| `2` | `EXIT_WARNING` | WinRE functional but degraded (OS-fallback, incomplete injection, geometry restore, cleanup failure), **or** the run deferred work (Audit Mode / OOBE guard, VMD-query-indeterminate deferral, OS-fallback BitLocker deferral, injection failure, concurrent-instance deferral, offline-fallback deferral), **or** the enable step failed and the failure counter incremented. |
| `3` | `EXIT_FATAL` | Deployment aborted. No state written, or the enable-failure loop-breaker fired. Investigate the log. |

`EXIT_REBOOT_REQUIRED` has priority over `EXIT_WARNING`. `EXIT_FATAL` always wins.

See [`docs/exit-codes.md`](docs/exit-codes.md) for the full matrix, including the eight distinct cases of exit code 2 and how the state file's timestamp distinguishes them.

---

## Requirements

- **Windows 10** (build 19041+) or **Windows 11** (build 22000+).
- **PowerShell 5.1** (Windows PowerShell) or **PowerShell 7.x**.
- **Elevation or SYSTEM** for production. `Test-WinRE.ps1` runs unelevated.
- **7-Zip** at `C:\Program Files\7-Zip\7z.exe`. `WinRE.ps1` will attempt to install it via `winget` if missing.
- **Internet access** to: `gist.github.com`, `api.github.com`, `downloads.dell.com`, `ftp.ext.hp.com`, `download.lenovo.com`, `support.lenovo.com`. The `support.lenovo.com` endpoint is only used by `Build-LenovoWinPEMap.ps1`, not by the production script. On a machine whose state file is present and whose local safety checks pass, a network outage does not prevent the run — the v44 patch 5 offline fallback trusts the state file's stored `DesiredStateId` and takes the fast path. A first deployment on a machine with no state file still requires network.
- **`reagentc.exe`** in `PATH` (present on all supported SKUs).
- **Windows is in a normal-running state.** The script refuses to run before any state-modifying action on a machine that has not yet completed OOBE. See [`docs/deployment.md`](docs/deployment.md#audit-mode-and-oobe).

There is **no BitLocker precondition on the OS volume**. The v43 patch 5 (further revision 5) policy is target-volume-based: the enable-only and dedicated-partition paths do not depend on C:'s BitLocker state at all. If the target recovery partition is encrypted, the script decrypts it in place before calling `reagentc`. The only path that depends on C:'s BitLocker state is the OS-fallback route, because on that route the target volume *is* C:. As of v44 patch 6, the destructive partition path does not consult C:'s state either — the dedicated-partition path's success or failure depends on the partition geometry, not on C:'s encryption state.

---

## Repository layout

```
.
├── docs/                Design, deployment, and troubleshooting documentation
├── scripts/             The PowerShell scripts
│   ├── WinRE.ps1                    Production deploy / repair
│   ├── Test-WinRE.ps1               Read-only harness + diagnostic
│   ├── Build-DellWinPEMap.ps1       Rebuild the Dell map gist
│   ├── Build-HPWinPEMap.ps1         Rebuild the HP map gist
│   └── Build-LenovoWinPEMap.ps1     Rebuild the Lenovo map gist
└── README.md
```

---

## Documentation

| Document | What it covers |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Overall design, why each decision was made, invariants. |
| [`docs/deployment.md`](docs/deployment.md) | Scheduled task, MDM, CI/CD integration, Audit Mode precondition, target-volume BitLocker policy, one-instance-per-machine policy, offline behavior. |
| [`docs/exit-codes.md`](docs/exit-codes.md) | Every exit path and its semantics. |
| [`docs/state-and-idempotency.md`](docs/state-and-idempotency.md) | `DesiredStateId`, state file, checkpoint resume, the loop-breaker, the offline fallback's residual risk. |
| [`docs/recovery-partition.md`](docs/recovery-partition.md) | Sizing policy, geometry, GPT/MBR attributes. |
| [`docs/driver-injection.md`](docs/driver-injection.md) | OEM pack + VMD injection, INF cross-reference success gate, Lenovo five-state resolution. |
| [`docs/testing.md`](docs/testing.md) | Using the harness, writing new tests. |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | Known failure modes, per-symptom playbook, and recovery procedures. |

---

## Version

**Production:** `WinRE.ps1` v44 patch 6.
**Harness:** `Test-WinRE.ps1` v18.

`ScriptVersion` is deliberately decoupled from deployed-WIM changes: fixes that do not modify the deployed WIM and do not change the `DesiredStateId` ship under the same `ScriptVersion`, so healthy machines do not rebuild unnecessarily. v43 patches 2, 3, 4, and 5 — and the further revisions to patch 5 — all shipped under `ScriptVersion = 43`. v44 patches 2, 3, 4, 5, and 6 all ship under `ScriptVersion = 44` for the same reason: v44 patch 2 added component cleanup and ResetBase; v44 patch 3 added the destructive-path C: encryption guard (removed in v44 patch 6) and the `base.wim` cleanup on injection failure; v44 patch 4 added the program lock at `C:\ProgramData\OEM\Logs\WinREManager.lock`; v44 patch 5 added the offline fallback for the driver manifest fetch and a 15-second network timeout on every call; v44 patch 6 removed the v44 patch 3 C: guard, made Lenovo OEM-pack resolution distinguish five states, made VMD hardware detection fail-closed, added the Step 2 stale-file cleanup on the normal path, and corrected the OS-fallback remediation wording. None of those five changes affects the deployed WIM bytes, the partition layout, or the `DesiredStateId` inputs.

The v44 patch 1 revision is the deliberate exception. It changed the `DesiredStateId` inputs — adding CPU vendor/generation and VMD presence — and therefore bumped `ScriptVersion` to 44. Every managed machine performed one full-update pass on the next scheduled run to rebuild the WIM against the new ID, then returned to the fast path permanently. See the migration note in [`CHANGELOG.md`](CHANGELOG.md).

Already-completed machines will not rerun automatically on v44 patches 2 through 6 because `ScriptVersion` and the `DesiredStateId` are unchanged. To exercise the fixes on an already-healthy machine, the deployment mechanism must invoke the script explicitly (for example, by deleting the state file or forcing a full-update pass); the next natural rebuild picks them up regardless.

---

## Field-tested hardware

| Vendor | Model | OS | Result |
|---|---|---|---|
| ASUS | PRIME H510M-D (i5-11400) | Win11 26200 | v44 patch 5 — fast path 2026-09-30 15:08:36 and 15:08:57 (two consecutive runs, `Acquired program lock` / `Released program lock` logged, DSI `62DE5C7D…` matched, `Operating mode: DEDICATED`, exit 0, no drive-letter leaks, no contention) |
| ASUS | PRIME H510M-D (i5-11400) | Win11 26200 | v44 patch 3 — fast path 2026-09-30 12:02 (state file accepted, DSI match, DEDICATED, no machine changes) |
| ASUS | PRIME H510M-D (i5-11400) | Win11 26200 | v44 patch 2 — full-update pass 2026-09-30 02:06 (ResetBase ran, exported WIM 756.1 MiB vs. 756.36 MiB pre-ResetBase, DEDICATED), fast path 02:08 |
| ASUS | PRIME H510M-D (i5-11400) | Win11 26200 | v44 patch 1 — full-update pass 2026-09-30 00:29 (DSI mismatch on the v43 state file, 756.4 MiB WIM rebuilt and deployed, 1100 MiB partition accepted on size), fast path 00:32 |
| ASUS | PRIME H510M-D (i5-11400) | Win11 26200 | v18 harness — Option 1 diagnostic 2026-09-30 (all fifteen parser self-test checks PASS: 15 passed, 0 failed, 0 skipped) |
| Dell | Latitude 3550 (Core Ultra 5 125U) | Win11 26200 | v44 patch 3 — full-update pass 2026-09-30 12:29–12:47 (clean partition recreate, `Pre-deletion inventory:` followed by deletion and recreation, `Target partition 0/4 (Z:) is already unencrypted - reagentc /enable can proceed`, `reagentc /enable (exit 0)` Operation Successful, DEDICATED). The machine that motivated the v43 patch 5 investigation now runs cleanly under v44. |
| Dell | Latitude 3550 (Core Ultra 5 125U) | Win11 26200 | Hit the Device Encryption race pre-patch-5; fixed in v43 patch 5 |
| Dell | Pro Slim QCS1250 (Core Ultra 5 235) | Win11 26200 | v43 patch 5 (revised) — startup gate fired correctly, machine left unchanged |
| Dell | Vostro 16 5640 (Intel Core 7 150U) | Win11 26200 | v43 patch 5 (revised) — startup gate fired correctly, machine left unchanged |
| Dell | Latitude 5530 (i7-1265U) | Win11 26200 | Motivated the v43 patch 5 (further revision) Audit Mode guard. After OOBE, manual `reagentc /enable` succeeded on the first attempt with the same WIM. |
| HP | ProBook 445 14 inch G10 (Ryzen 5 7530U) | Win11 26200 | DEDICATED after v28 fix |
| HP | ProBook 450 15.6 inch G10 (i7-1355U) | Win11 26200 | Hit the Device Encryption race pre-patch-5; fixed in v43 patch 5 |
| HP | ProBook 455 15.6 inch G10 (Ryzen 5 7530U) | Win11 26200 | DEDICATED — full update 2026-09-29 (190 drivers injected, dedicated partition created at 1200 MiB); second run fast path |
| Lenovo | 21L1 (ThinkPad) | Win11 | DEDICATED |
| (VM) | Hyper-V Windows 10 MBR | Win10 | DEDICATED |
| (VM) | Hyper-V Windows 11 (i5-11400) | Win11 26200 | v44 patch 1 — full-update pass 2026-09-30 00:29 (DSI mismatch, 713.3 MiB WIM rebuilt and deployed), fast path 00:32 |

The two Device Encryption failures pre-patch-5 are documented in [`docs/troubleshooting.md`](docs/troubleshooting.md) with the recovery procedure. The v43 patch 5 series prevents them from recurring.

---

## Contributing

Bug reports and PRs welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Security

For security issues, see [`SECURITY.md`](SECURITY.md). Do not file public issues for vulnerabilities.

## Sponsor

If WinRE Manager saves you time, please consider sponsoring: **https://github.com/sponsors/ArthurJDurand**

## License

MIT — see [`LICENSE`](LICENSE).
