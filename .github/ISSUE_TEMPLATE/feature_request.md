---
name: Feature request
about: Suggest a new capability or improvement.
labels: ['enhancement', 'needs-triage']
---

## Use case

<!-- What problem does this solve? Give a concrete field scenario. -->

## Proposed behaviour

<!-- What would you like to see happen? -->

## Alternatives considered

<!-- Anything else you have tried or thought about. -->

## Impact on existing deployments

- Would this change the `ScriptVersion`? If so, which of the three triggers applies — the deployed WIM bytes, the partition layout that gets created, or a `DesiredStateId` input?
- Would this change the `DesiredStateId` inputs? Adding a new hardware property or deployment input to the ID forces every managed machine to rebuild once on the next run. If so, describe the `Migration Note` the change would need.
- Would this force a rebuild on healthy machines?
- Would this alter any exit-code semantics?
- Does it touch the partition lifecycle, BitLocker state, the state file, the checkpoint file (`C:\ProgramData\OEM\Logs\winre_checkpoint.txt`), or the deferral marker (`C:\Recovery\OEM\winre_partition_deferred.json`)? The checkpoint file carries the source-content binding (v47) and the marker governs retry suppression (v45); both are part of the deployment's persistence surface.

For relocation or persistence changes, describe the effect on ownership, protected recovery material, journal phases, retry/fallback conditions and cleanup using the [current pending-operation requirements](https://github.com/ArthurJDurand/WinRE-Manager/blob/main/CONTRIBUTING.md#patch-5-pending-operation-review). Trust or privileged-installation changes must also account for the [three-copy trust-check invariant](https://github.com/ArthurJDurand/WinRE-Manager/blob/main/CONTRIBUTING.md#the-three-copy-trust-check-invariant).

### If this feature would touch one of the v49 gates or persistence features

v49 introduced a set of pre-deployment gates and post-run persistence features. If your feature would interact with any of them, say so explicitly:

- The **source-ownership classification** and the rule that a `Foreign-With-Drivers` WIM is preserved as-is (does your feature need a fifth class, or a change to the classification rule?).
- The **never-downgrade storage-driver check** (does your feature inject a driver that the check would refuse?).
- The **pre-deployment storage-applicability gate** (does your feature deploy a candidate that the gate would refuse?).
- The **native-boot VHDX fail-closed gate** (does your feature change the refusal, or make some destructive operation safe on VHDX?).
- The **backup and restore actions** and the `backup.json` sidecar format (does your feature change the format, or read the backup outside restore?).
- The **temporary crash-recovery scheduled task** (`WinRE Manager - Resume`; its registration, its two independent persist signals — the `$Script:ResumeTaskShouldPersist` flag and the `[WinRECancelKeyProbe]::ShouldPersist` static field, OR-merged by the `finally` block — plus its two finally-never-runs interruption classes, its clean-completion removal, or its `$PSCommandPath` guard — does your feature change when it is registered, or what it invokes?).
- The **stable install location** at `C:\ProgramData\OEM\WinRE-Manager\WinRE.ps1` and the SHA256-verify-before-register step (does your feature change where the maintenance task is registered, or what is installed?).

### If this feature would touch one of the v50 patch 2 additions

v50 patch 2 added a hypervisor-aware suppression boundary to the non-OS-disk recovery-partition sweep, a protection for mounted VHD/VHDX disks inside that sweep, a `SCSI` entry in the workspace bus allowlist, a per-driver diagnostic loop in the source-ownership classifier, and a URL-builder fix for the restructured `Win10/x64` folder. If your feature would interact with any of them, say so explicitly:

- The **non-OS sweep suppression boundary** in `Remove-StrayRecoveryPartitions` and the `Test-RunningInVirtualMachine` helper it depends on (the ten hypervisor signatures, the `$null` fail-closed return, and the empty-metadata guard — does your feature need a change to the signature list, the detection logic, or the suppression rule?).
- The **`File Backed Virtual` disk protection** inside the same sweep (does your feature change which non-OS disks the sweep preserves?).
- The **`SCSI` entry in the workspace bus allowlist** (`Get-WorkDirCandidates`; the OS-volume-only admission rule — does your feature change the workspace selection policy?).
- The **GitHub Windows 10 URL builder** in `Get-GitHubBaseWinRE` (the `Win10/x64` folder path — does your feature change where the base WIM repository resolves from?).

### If this feature would touch one of the v50 patch 3 additions

v50 patch 3 extended the manager config and resume-task trust checks, added a shared `Test-PathTrustedForSystem` helper, and closed seven correctness gaps across production and the wrapper. If your feature would interact with any of them, say so explicitly:

- The **shared `Test-PathTrustedForSystem` helper** and its split modify-capable mask (does your feature need a different mask, a different trusted-principal set, or a check on a new path?).
- The **extended manager config trust check** on the config file, its containing directory, and its parent.
- The **resume-script staging design** (the SYSTEM resume task executes a staged copy of the running script at `C:\Recovery\OEM\Resume\WinRE.ps1` under an explicit DACL, rather than the script's original path).
- The **Restore resume-task persist condition** on the WIM-deployment-failure path (does your feature change when the resume task is preserved?).
- The **post-deletion verification** in `Remove-StrayRecoveryPartitions` (does your feature change what constitutes a confirmed deletion?).
- The **empty archive-parts guard** in `Get-GitHubBaseWinRE` (does your feature change how base WIM parts are discovered?).
- The **recovery-volume drive-letter normalization scope** (does your feature change which volumes are subject to letter removal?).
- The **volume-root preservation** in `Add-ManagerBackupRoot` (does your feature change how backup roots are stored?).
- The **wrapper Restore catalogue enumeration** and WIM-only backup acceptance.
- The **wrapper argument quoting** for `Start-Process` paths.
- The **reparse-point rejection** in `Cleanup-Backups.ps1` and its exit-code / explicit-path-scope behaviour.
- The **fail-closed drive-letter normalization** in the recovery-volume drive-letter normalization block (does your feature change how a provider error on the `\Windows` presence check is handled?).
- The **fail-closed workspace volume enumeration** in `Get-WorkDirCandidates` (does your feature change how an enumeration error is handled?).
- The **ACE-catch fail-closed correction** in `Test-PathTrustedForSystem` (does your feature need a different behaviour on an unresolvable ACE SID, or a different modify-capable mask?).
- The **two mirror syncs of the ACE-catch fix** in `Cleanup-Backups.ps1` and the compressed inline copy in `WinRE-Manager.cmd`'s Restore `TARGET_COMMAND` (does your feature change how either duplicated trust check evaluates an ACE?).
- The **Restore-failure state invalidation** in `Invoke-RestoreAction` (does your feature change when the state file, checkpoint, or deferral marker is preserved or invalidated after a failed WIM replacement?).
- The **numeric-selection fix** in `Cleanup-Backups.ps1` (does your feature change how backup numbers are parsed, deduplicated, or mapped to backup objects?).

---

**On the design invariants.** WinRE Manager's design is organized around four rules, in this order — see [`docs/architecture.md`](https://github.com/ArthurJDurand/WinRE-Manager/blob/main/docs/architecture.md) for the full hierarchy:

1. **Never break Windows RE.**
2. **Never leave a machine without a working recovery route** — to the extent the machine, its OS, and its storage stack allow.
3. **Minimize the `reagentc /disable` → `reagentc /enable` window.**
4. **Do no work unless needed. When work is needed, prepare everything before touching anything.**

If your feature would serve one of these rules, say so — it helps the maintainer weigh it against the rest of the backlog. If your feature would **weaken** any of rules 1–3, say so explicitly; it will need a field case to justify it.

**If the feature would touch the destructive sequence** (`Get-PartitionPlan`, `Ensure-AdequateRecoveryPartition`, `Invoke-OSPartitionShrink`, `Invoke-OSPartitionExtend`, the `New-Partition` / `Format-Volume` / `Set-RecoveryPartitionAttributes` calls and their failure paths, `Remove-OrphanPartition`, `Restore-OSPartitionSize`, `Restore-PreviousWinRERoute`, `Assert-RecoveryPartitionLayout`, `Remove-StrayRecoveryPartitions`, and any caller of those functions), be aware that any eventual PR will be gated. The gate is on the deliberate post-deletion failure test documented in [`docs/testing.md`](https://github.com/ArthurJDurand/WinRE-Manager/blob/main/docs/testing.md); see [`CONTRIBUTING.md`](https://github.com/ArthurJDurand/WinRE-Manager/blob/main/CONTRIBUTING.md) for the scope. A feature that would change the post-deletion segment cannot ship until that test has run and its result is recorded.
