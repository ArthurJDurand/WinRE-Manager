# WinRE Manager

> Idempotent, self-healing Windows Recovery Environment management for managed Windows 10/11 fleets.

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207.x-blue.svg)](https://github.com/ArthurJDurand/WinRE-Manager)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-lightgrey.svg)]()
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa.svg)](https://github.com/sponsors/ArthurJDurand)

📖 **[Full documentation](https://arthujdurand.github.io/WinRE-Manager/)**

WinRE Manager deploys the correct WinRE (Windows Recovery Environment) image to a dedicated recovery partition on the OS disk of every machine in a managed fleet. It fetches the current base WIM from a versioned repository, injects OEM WinPE driver packs (Dell / HP / Lenovo) and Intel VMD storage drivers from live manifests, and maintains a `DesiredStateId`-scoped state file so re-runs are no-ops when nothing has changed.

It is designed to run unattended as `NT AUTHORITY\SYSTEM` via scheduled task or MDM, on Dell, HP, Lenovo and ASUS hardware, GPT or MBR, with or without BitLocker.

---

## Why this exists

Windows ships a working recovery environment out of the box. It stops working when any of the following happen:

- A Windows Update replaces the recovery partition's `winre.wim` with a newer one, but the partition is too small to hold it or the OS-side fallback copy drifts out of sync.
- BitLocker auto-encrypts a freshly created recovery partition, and `reagentc /enable` refuses to activate it.
- **Device Encryption is mid-encryption** on a Windows 11 24H2+ machine (`VolumeStatus=EncryptionInProgress` while `ProtectionStatus` reads `Off`). In that state the encryption service claims any new partition the script creates, before the recovery type GUID can be applied, and `reagentc /enable` refuses. This is the failure mode fixed in v43 patch 5 — see [troubleshooting.md](docs/troubleshooting.md) for the full explanation and recovery procedure.
- The OEM's WinPE driver pack is missing or stale, so the recovery environment cannot see the storage controller (especially Intel VMD).
- A disk migration or clone leaves the reagentc registration pointing at a partition that no longer exists.
- A recovery partition ends up on a **secondary** disk, where it can confuse the boot loader and cause Startup Repair to fail.

WinRE Manager addresses all of these idempotently. Running it twice in a row on a healthy machine is a no-op. Running it on a broken machine repairs what it can and reports a warning exit code when full remediation is not possible — never a silent success.

## What it does, in order

1. Detects hardware: vendor, model, Lenovo machine type, Intel CPU generation, Windows build.
2. Resolves the current base WIM: reads the live recovery image at the reagentc-registered location, or falls back to `C:\Recovery\WindowsRE\winre.wim`, or downloads a fresh one from GitHub.
3. Mounts and injects drivers: OEM WinPE pack for the vendor, then Intel VMD pack if VMD hardware is present.
4. Optimizes and exports the WIM (`dism /Export-Image /Compress:max`).
5. Ensures a correctly sized recovery partition exists on the **OS disk**: it either accepts an existing one that meets the 250 MiB free-space policy, or deletes stray recovery partitions, extends the OS partition, shrinks it by the required bucket + 1 MiB, and creates a new partition with the recovery type GUID applied at creation.
6. Deploys the WIM to the recovery partition, sets the recovery type GUID and GPT attributes, registers it with `reagentc /setreimage`, and enables WinRE.
7. Enforces the invariant "exactly one recovery partition, on the OS disk" by removing any stray type-coded recovery partition on non-OS disks.
8. Writes a state file containing the deployed WIM hash and the `DesiredStateId` so the next run can short-circuit.

See [`docs/architecture.md`](docs/architecture.md) for the full design and [`docs/recovery-partition.md`](docs/recovery-partition.md) for the partition-lifecycle model.

## Quick start

```powershell
# Read-only diagnostic. Reports what the production script would see.
.\scripts\Test-WinRE.ps1

# Interactive harness. Downloads and extracts every OEM pack, every VMD pack,
# and the GitHub base WIM, without touching WinRE or any partition.
.\scripts\Test-WinRE.ps1

# Production deploy. Requires elevation.
.\scripts\WinRE.ps1 -DryRun   # walk the flow, log every decision, change nothing
.\scripts\WinRE.ps1           # deploy
```

Recommended deployment method is a scheduled task running as `SYSTEM`, triggered at boot and weekly. See [`docs/deployment.md`](docs/deployment.md).

## Exit codes

| Code | Name | Meaning |
|------|------|---------|
| `0` | `EXIT_SUCCESS` | WinRE enabled, dedicated recovery partition healthy, state file written. |
| `1` | `EXIT_REBOOT_REQUIRED` | Deployment succeeded; a reboot is required to complete registration. |
| `2` | `EXIT_WARNING` | WinRE functional but degraded (OS-fallback, incomplete injection, geometry restore, cleanup failure, or v43 patch 5 Device Encryption guard deferral) — or nothing to do but a warning was raised. |
| `3` | `EXIT_FATAL` | Deployment aborted. No state written. Investigate the log. |

`EXIT_REBOOT_REQUIRED` has priority over `EXIT_WARNING`. `EXIT_FATAL` always wins.

See [`docs/exit-codes.md`](docs/exit-codes.md) for the full matrix.

## Requirements

- **Windows 10** (build 19041+) or **Windows 11** (build 22000+).
- **PowerShell 5.1** (Windows PowerShell) or **PowerShell 7.x**.
- **Elevation** for production. `Test-WinRE.ps1` runs unelevated.
- **7-Zip** at `C:\Program Files\7-Zip\7z.exe`. `WinRE.ps1` will attempt to install it via `winget` if missing.
- **Internet access** to: `gist.github.com`, `api.github.com`, `downloads.dell.com`, `ftp.ext.hp.com`, `download.lenovo.com`, `support.lenovo.com`.
- **`reagentc.exe`** in `PATH` (present on all supported SKUs).
- **Stable BitLocker state.** `manage-bde -status C:` must read `Fully Decrypted` or `Fully Encrypted`. The script defers destructive partition work if the state is `Encryption In Progress` or `Encryption Paused` (v43 patch 5). See [`docs/deployment.md`](docs/deployment.md) for the Device Encryption precondition.

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

## Documentation

| Document | What it covers |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Overall design, why each decision was made, invariants. |
| [`docs/deployment.md`](docs/deployment.md) | Scheduled task, MDM, CI/CD integration, Device Encryption precondition. |
| [`docs/exit-codes.md`](docs/exit-codes.md) | Every exit path and its semantics. |
| [`docs/state-and-idempotency.md`](docs/state-and-idempotency.md) | `DesiredStateId`, state file, checkpoint resume. |
| [`docs/recovery-partition.md`](docs/recovery-partition.md) | Sizing policy, geometry, GPT/MBR attributes. |
| [`docs/driver-injection.md`](docs/driver-injection.md) | OEM pack + VMD injection, INF cross-reference success gate. |
| [`docs/testing.md`](docs/testing.md) | Using the harness, writing new tests. |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | Known failure modes, per-symptom playbook, and the recovery procedure for machines damaged by pre-v43-patch-5 code. |

## Version

**Production:** `WinRE.ps1` v43 patch 5.
**Harness:** `Test-WinRE.ps1` v12.

The production script has been through 43 versions and 5 patches within v43. Full changelog is in the `.NOTES` block at the top of `scripts/WinRE.ps1`. A user-facing changelog is in [`CHANGELOG.md`](CHANGELOG.md).

`ScriptVersion` is deliberately decoupled from deployed-WIM changes: fixes that do not modify the deployed WIM ship under the same `ScriptVersion` and the same `DesiredStateId`, so healthy machines do not rebuild unnecessarily. v43 patches 2, 3, 4, and 5 all shipped under `ScriptVersion = 43`.

## Field-tested hardware

| Vendor | Model | OS | Result |
|---|---|---|---|
| ASUS | 11th-gen desktop (i5-11400) | Win11 26100/26200 | DEDICATED |
| HP | ProBook 445 14 inch G10 (Ryzen 5 7530U) | Win11 26200 | DEDICATED after v28 fix |
| HP | ProBook 450 15.6 inch G10 (i7-1355U) | Win11 26200 | Hit the Device Encryption race pre-patch-5; fixed in v43 patch 5 |
| Lenovo | 21L1 (ThinkPad) | Win11 | DEDICATED |
| Dell | Latitude 3550 (Core Ultra 5 125U) | Win11 26200 | Hit the Device Encryption race pre-patch-5; fixed in v43 patch 5 |
| (VM) | Hyper-V Windows 10 MBR | Win10 | DEDICATED |

The two Device Encryption failures are documented in [`docs/troubleshooting.md`](docs/troubleshooting.md) with the recovery procedure. v43 patch 5 prevents them from recurring.

## Contributing

Bug reports and PRs welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Security

For security issues, see [`SECURITY.md`](SECURITY.md). Do not file public issues for vulnerabilities.

## Sponsor

If WinRE Manager saves you time, please consider sponsoring: **https://github.com/sponsors/ArthurJDurand**

## License

MIT — see [`LICENSE`](LICENSE).
