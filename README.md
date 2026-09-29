# WinRE Manager

> Idempotent, self-healing Windows Recovery Environment management for managed Windows 10/11 fleets.

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207.x-blue.svg)](https://github.com/ArthurJDurand/WinRE-Manager)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-lightgrey.svg)]()
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa.svg)](https://github.com/sponsors/ArthurJDurand)

📖 **[Full documentation](https://arthujdurand.github.io/WinRE-Manager/)**

WinRE Manager deploys the correct WinRE (Windows Recovery Environment) image to a dedicated recovery partition on the OS disk of every machine in a managed fleet. It fetches the current base WIM from a versioned repository, injects OEM WinPE driver packs (Dell / HP / Lenovo) and Intel VMD storage drivers from live manifests, and maintains a `DesiredStateId`-scoped state file so re-runs are no-ops when nothing has changed.

It is designed to run unattended as `NT AUTHORITY\SYSTEM` via scheduled task or MDM, on Dell, HP, Lenovo and ASUS hardware, GPT or MBR, with or without BitLocker. OEM driver injection is available for Dell, HP, and Lenovo; ASUS machines run with the base WIM plus Intel VMD.

---

## Why this exists

Windows ships a working recovery environment out of the box. It stops working when any of the following happen:

- A Windows Update replaces the recovery partition's `winre.wim` with a newer one, but the partition is too small to hold it or the OS-side fallback copy drifts out of sync.
- BitLocker auto-encrypts a freshly created recovery partition, and `reagentc /enable` refuses to activate it.
- **Device Encryption is mid-encryption** on a Windows 11 24H2+ machine (`VolumeStatus=EncryptionInProgress` while `ProtectionStatus` reads `Off`). The encryption service claims any new partition the script creates, before the recovery type GUID can be applied. The v43 patch 5 series closes this from both sides: `New-Partition` applies the recovery type GUID at creation so the partition is never a plain Basic Data partition, and if the encryption service claims it anyway, `Set-RecoveryPartitionReadyForWinRE` decrypts it in place with `manage-bde -off` before reagentc is called. No partition is destroyed, no OS volume is touched. See [docs/architecture.md](docs/architecture.md) for the full policy and [docs/troubleshooting.md](docs/troubleshooting.md) for the pre-patch-5 recovery procedure if a machine was damaged by older code.
- **A BIOS or firmware update flips VMD on or off, or the CPU or motherboard is replaced on the same chassis.** The deployed WinRE was built with a different driver set than the hardware now requires. On a VMD-based system the resulting recovery environment cannot see the OS disk at all. The v44 patch 1 revision adds CPU vendor/generation and VMD presence to the `DesiredStateId` inputs, so a machine whose deployment inputs have changed since the state file was written rebuilds automatically on the next run rather than taking the fast path with a stale driver set.
- The OEM's WinPE driver pack is missing or stale, so the recovery environment cannot see the storage controller (especially Intel VMD).
- A disk migration or clone leaves the reagentc registration pointing at a partition that no longer exists.
- A recovery partition ends up on a **secondary** disk, where it can confuse the boot loader and cause Startup Repair to fail.
- A freshly imaged machine has not yet completed OOBE. `reagentc /enable` is blocked by the OS in Audit Mode, OOBE, and the sysprep phases regardless of WIM correctness; the script now detects this and defers — see [troubleshooting.md](docs/troubleshooting.md#the-machine-is-in-audit-mode--oobe--sysprep).

WinRE Manager addresses all of these idempotently. Running it twice in a row on a healthy machine is a no-op. Running it on a broken machine repairs what it can and reports a warning exit code when full remediation is not possible — never a silent success.

## What it does, in order

1. Detects hardware: vendor, model, Lenovo machine type, Intel CPU generation, Windows build.
2. Detects VMD hardware presence and resolves the manifest-derived required driver set.
3. Computes the `DesiredStateId` from the current deployment inputs and reads the on-disk state file. A matching ID and a healthy machine take the fast path and exit without modifying anything.
4. Resolves the current base WIM: reads the live recovery image at the reagentc-registered location, or falls back to `C:\Recovery\WindowsRE\winre.wim`, or downloads a fresh one from GitHub.
5. Mounts and injects drivers: OEM WinPE pack for the vendor, then Intel VMD pack if VMD hardware is present.
6. Optimizes and exports the WIM (`dism /Export-Image /Compress:max`).
7. Ensures a correctly sized recovery partition exists on the **OS disk**: it either accepts an existing one that meets the 250 MiB free-space policy, or deletes stray recovery partitions, extends the OS partition, shrinks it by the required bucket + 1 MiB, and creates a new partition with the recovery type GUID applied at creation.
8. Deploys the WIM: prepares the **target recovery partition** with `Set-RecoveryPartitionReadyForWinRE` — which decrypts it in place if the Device Encryption service claimed it, polling for completion up to 300 seconds — copies the WIM, verifies SHA256, sets the recovery type GUID and GPT attributes, registers it with `reagentc /setreimage`, and enables WinRE. On the OS-fallback route, where the target *is* the OS volume, the script instead checks C:'s BitLocker state and defers unless it is `FullyDecrypted`; it never modifies C:'s state.
9. Enforces the invariant "exactly one recovery partition, on the OS disk" by removing any stray type-coded recovery partition on non-OS disks.
10. Writes a state file containing the deployed WIM hash and the `DesiredStateId` so the next run can short-circuit.

See [`docs/architecture.md`](docs/architecture.md) for the full design, [`docs/recovery-partition.md`](docs/recovery-partition.md) for the partition-lifecycle model, and [`docs/state-and-idempotency.md`](docs/state-and-idempotency.md) for the `DesiredStateId` composition and the fast-path gates.

## Quick start

```powershell
# Read-only harness. No elevation needed. Run it and choose a menu option:
#   Option 1 = System diagnostic (what the production script would see)
#   Option S = State file parity check (would production take the fast path?)
#   Option A = All relevant for this machine (download + extraction validation)
#   Option B = All of the above
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
| `2` | `EXIT_WARNING` | WinRE functional but degraded (OS-fallback, incomplete injection, geometry restore, cleanup failure), **or** the run made no changes to the machine and deferred work (Audit Mode / OOBE guard, OS-fallback BitLocker deferral), **or** the enable step failed and the failure counter incremented. |
| `3` | `EXIT_FATAL` | Deployment aborted. No state written, or the enable-failure loop-breaker fired. Investigate the log. |

`EXIT_REBOOT_REQUIRED` has priority over `EXIT_WARNING`. `EXIT_FATAL` always wins.

See [`docs/exit-codes.md`](docs/exit-codes.md) for the full matrix, including the four distinct cases of exit code 2 and how the state file's timestamp distinguishes them.

## Requirements

- **Windows 10** (build 19041+) or **Windows 11** (build 22000+).
- **PowerShell 5.1** (Windows PowerShell) or **PowerShell 7.x**.
- **Elevation** for production. `Test-WinRE.ps1` runs unelevated.
- **7-Zip** at `C:\Program Files\7-Zip\7z.exe`. `WinRE.ps1` will attempt to install it via `winget` if missing.
- **Internet access** to: `gist.github.com`, `api.github.com`, `downloads.dell.com`, `ftp.ext.hp.com`, `download.lenovo.com`, `support.lenovo.com`. The `support.lenovo.com` endpoint is only used by `Build-LenovoWinPEMap.ps1`, not by the production script.
- **`reagentc.exe`** in `PATH` (present on all supported SKUs).
- **Windows is in a normal-running state.** The script refuses to run before any state-modifying action on a machine that has not yet completed OOBE. This is the v43 patch 5 (further revision) Audit Mode guard, and it reads `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` → `ImageState`. It affects freshly imaged machines only. See [`docs/deployment.md`](docs/deployment.md#audit-mode-and-oobe) for the precondition and the fleet timing notes.

There is **no BitLocker precondition on the OS volume**. The v43 patch 5 (further revision 5) policy is target-volume-based: the enable-only and dedicated-partition paths do not depend on C:'s BitLocker state at all. If the target recovery partition is encrypted, the script decrypts it in place before calling reagentc. The only path that checks C:'s state is the OS-fallback route, and only because in that case the target volume *is* C:. See [`docs/deployment.md`](docs/deployment.md#device-encryption-v43-patch-5-further-revision-5) for the full explanation.

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
| [`docs/deployment.md`](docs/deployment.md) | Scheduled task, MDM, CI/CD integration, Audit Mode precondition, target-volume BitLocker policy. |
| [`docs/exit-codes.md`](docs/exit-codes.md) | Every exit path and its semantics. |
| [`docs/state-and-idempotency.md`](docs/state-and-idempotency.md) | `DesiredStateId`, state file, checkpoint resume, the loop-breaker. |
| [`docs/recovery-partition.md`](docs/recovery-partition.md) | Sizing policy, geometry, GPT/MBR attributes. |
| [`docs/driver-injection.md`](docs/driver-injection.md) | OEM pack + VMD injection, INF cross-reference success gate. |
| [`docs/testing.md`](docs/testing.md) | Using the harness, writing new tests. |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | Known failure modes, per-symptom playbook, and recovery procedures. |

## Version

**Production:** `WinRE.ps1` v44 patch 1.
**Harness:** `Test-WinRE.ps1` v15.

The production script has been through 44 versions and one patch within v44, with several further revisions to v43 patch 5 that added the Audit Mode / OOBE guard, the enable-failure counter, and the target-volume BitLocker policy before v44 arrived. Full changelog is in `CHANGELOG.md`; the `.NOTES` block at the top of `scripts/WinRE.ps1` records the current design invariants and the CRITICAL LESSONS LEARNED list.

`ScriptVersion` is deliberately decoupled from deployed-WIM changes: fixes that do not modify the deployed WIM and do not change the `DesiredStateId` ship under the same `ScriptVersion`, so healthy machines do not rebuild unnecessarily. v43 patches 2, 3, 4, and 5 — and the further revisions to patch 5, including further revision 5 — all shipped under `ScriptVersion = 43`.

The v44 patch 1 revision is the deliberate exception. It changes the `DesiredStateId` inputs — adding CPU vendor/generation and VMD presence — and therefore bumps `ScriptVersion` to 44. Every managed machine performs one full-update pass on the next scheduled run to rebuild the WIM against the new ID, then returns to the fast path permanently. The migration note in `CHANGELOG.md` describes the expected fleet behaviour and the rollback procedure.

## Field-tested hardware

| Vendor | Model | OS | Result |
|---|---|---|---|
| ASUS | 11th-gen desktop (i5-11400) | Win11 26100/26200 | DEDICATED |
| ASUS | 11th-gen desktop (i5-11400), PRIME H510M-D | Win11 26200 | v44 patch 1 — full-update pass 2026-09-30 00:29 (DSI mismatch on the v43 state file, 756.4 MiB WIM rebuilt and deployed, 1100 MiB partition accepted on size), fast path 00:32 |
| HP | ProBook 445 14 inch G10 (Ryzen 5 7530U) | Win11 26200 | DEDICATED after v28 fix |
| HP | ProBook 450 15.6 inch G10 (i7-1355U) | Win11 26200 | Hit the Device Encryption race pre-patch-5; fixed in v43 patch 5 |
| HP | ProBook 455 15.6 inch G10 (Ryzen 5 7530U) | Win11 26200 | DEDICATED — full update 2026-09-29 (190 drivers injected, dedicated partition created at 1200 MiB); second run fast path |
| Lenovo | 21L1 (ThinkPad) | Win11 | DEDICATED |
| Dell | Latitude 3550 (Core Ultra 5 125U) | Win11 26200 | Hit the Device Encryption race pre-patch-5; fixed in v43 patch 5 |
| Dell | Pro Slim QCS1250 (Core Ultra 5 235) | Win11 26200 | v43 patch 5 (revised) — startup gate fired correctly, machine left unchanged |
| Dell | Vostro 16 5640 (Intel Core 7 150U) | Win11 26200 | v43 patch 5 (revised) — startup gate fired correctly, machine left unchanged |
| Dell | Latitude 5530 (i7-1265U) | Win11 26200 | Motivated the v43 patch 5 (further revision) Audit Mode guard. The pre-guard code deployed through Step 5, failed at `reagentc /enable` with `0x4c7` on two consecutive runs, and wrote a state file recording the deployment as complete. After OOBE, manual `reagentc /enable` succeeded on the first attempt with the same WIM. |
| (VM) | Hyper-V Windows 10 MBR | Win10 | DEDICATED |
| (VM) | Hyper-V Windows 11 (i5-11400) | Win11 26200 | v44 patch 1 — full-update pass 2026-09-30 00:29 (DSI mismatch on the v43 state file, 713.3 MiB WIM rebuilt and deployed), fast path 00:32 |

The two Device Encryption failures pre-patch-5 are documented in [`docs/troubleshooting.md`](docs/troubleshooting.md) with the recovery procedure. The v43 patch 5 series prevents them from recurring: on the dedicated-partition route, the recovery type GUID is applied at creation and any partition claimed by the Device Encryption service is decrypted in place; on the OS-fallback route, the script defers if C: is not `FullyDecrypted` rather than attempting a registration reagentc will refuse.

The Dell Latitude 5530 is the Audit Mode case. The script's predecessor had no Audit Mode guard; it deployed successfully through Step 5, failed at `reagentc /enable` with `0x4c7` on two consecutive runs, and wrote a state file recording the deployment as complete. After the user completed OOBE, `reagentc /enable` succeeded on the first attempt with the same WIM. The Audit Mode guard added in the further revision prevents this failure mode by deferring before any state-modifying action.

The VM and ASUS entries on 2026-09-30 are the field verification for the v44 patch 1 `DesiredStateId` change. Both machines took the full-update path on the first run after the patch (the state files written under `ScriptVersion = 43` no longer matched), rebuilt the WIM with the new ID, wrote a state file under the new ID, and returned to the fast path on the second run. No drive-letter leaks, no checkpoint residue, no state-write anomalies.

## Contributing

Bug reports and PRs welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Security

For security issues, see [`SECURITY.md`](SECURITY.md). Do not file public issues for vulnerabilities.

## Sponsor

If WinRE Manager saves you time, please consider sponsoring: **https://github.com/sponsors/ArthurJDurand**

## License

MIT — see [`LICENSE`](LICENSE).
