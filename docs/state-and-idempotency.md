# State and idempotency

WinRE Manager is idempotent via a single hash called `DesiredStateId`. Everything else — the state file, the checkpoint file, the fast path — exists to make that hash work.

## `DesiredStateId`

A SHA256 computed deterministically from seven fields:

```
HW=<Manufacturer>|<Model>|<MachineType>
OS=<Build>
CPU=<vendor>|<generation or N>
VMD=<present|absent>
MANIFEST=<manifest.version>
OEMPACK=<OEM pack version, or NONE>
SCRIPT=<ScriptVersion>
```

The seven fields are joined with `;;`, encoded as UTF-8, and hashed. The result is a 64-character hex string.

### What each field means

- **`HW`** — vendor, model, and (for Lenovo) machine type. A Lenovo ThinkPad 21L1 and a Lenovo 21L2 have different IDs. Two machines of the same model have the same ID.
- **`OS`** — the Windows build number. A machine that upgrades from 26100 to 26200 gets a new ID and rebuilds.
- **`CPU`** — CPU vendor (`Intel` or `AMD`) and Intel generation. The generation is the value returned by `Get-IntelProcessorGeneration`, or the literal string `N` when the generation cannot be parsed (AMD CPUs, Intel Celeron / Pentium / Atom / Xeon, and N/J-series CPUs). The `N` is deterministic and stable: it does not flip between runs on the same hardware.
- **`VMD`** — `present` or `absent`. Computed from the union of the `requiredDevices` field across all manifest entries, matched against the machine's present PnP devices. VMD presence is a deployment input because it determines whether the VMD driver package is selected for injection.
- **`MANIFEST`** — the version field of the driver manifest JSON. The manifest author bumps it when driver URLs change.
- **`OEMPACK`** — the resolved OEM pack version for this machine's vendor. For Dell it is the `dellVersion`; for HP the SoftPaq `version`; for Lenovo the `dsId`. If the vendor is unsupported or the map failed to resolve, this is `NONE`.
- **`SCRIPT`** — the production script's `ScriptVersion` constant.

### Why CPU and VMD were added in v44

The v43 `DesiredStateId` was a hardware fingerprint for the base WIM and the OEM pack, but it did not capture the inputs that determine **VMD driver selection**. A machine whose VMD presence flipped from `absent` to `present` — because of a BIOS or firmware update that changed the default, or a deliberate configuration change applied post-deployment — would take the fast path with a driver set that no longer matched its hardware. On a VMD-based system the resulting WinRE cannot see the OS disk at all, and Startup Repair fails. The same class of problem applies to a CPU or motherboard swap on the same chassis with the same `Manufacturer` / `Model` / `MachineType` string.

Adding these two inputs to the ID makes it a **deployment-input fingerprint** rather than a hardware fingerprint. The principle is: the ID should change whenever the inputs that determine the desired WinRE artifact change. It should not change merely because unrelated machine state changes.

The v44 patch 1 revision deliberately does **not** go further than this. It does not hash the actual resolved driver list (which would be cleaner in principle — the ID would change exactly when the artifact would change, not when hardware that happens to correlate with the artifact changes) because the manifest `version` field already plays that role when the manifest author maintains it correctly. If a future revision needs to hash the resolved driver set, it should do so together with another `ScriptVersion` bump.

### When the ID changes

Any of the following cause the ID to change, which forces a full rebuild on the next run:

- A new `ScriptVersion`.
- A new Windows build.
- A new manifest `version`.
- A new OEM pack version for the machine's vendor.
- A hardware change (motherboard swap that changes `Manufacturer` / `Model` / `MachineType`).
- A change in CPU vendor or Intel CPU generation.
- A change in VMD presence on the machine (typically a BIOS or firmware update that flips the VMD default).

### When it does not change

- Any cosmetic or logging fix shipped without bumping `ScriptVersion`.
- Any patch generation shipped under the same `ScriptVersion` that does not change the DSI inputs — v43 patches 2, 3, 4, and 5, and the further revisions to patch 5 (including further revision 5), all ship under v43, so the ID is unchanged and healthy machines do not rebuild.
- A new WIM hash at the registered location. That is a separate check (see below), not part of the ID.
- A Windows Update that changes the WIM inside the recovery partition without changing the OS build.
- A change to the BitLocker policy or the target-preparation logic. The state file does not record BitLocker state; it records the deployment's identity and outcome.
- A change to the driver manifest's contents without a `version` bump. This is a manifest-authoring bug; production assumes the version field is maintained.

`ScriptVersion` bumps are expensive: they force every healthy machine to rebuild. The project's policy is to bump only when the deployed WIM, the partition layout, or the DSI inputs change. Bug fixes to the main flow — including the v43 patch 4 checkpoint/state interaction fix, the v43 patch 5 further revision 5 BitLocker policy inversion, and the harness's move to v14 and v15 — ship under the same version or without a DSI change, and correct the affected machines on their next run without disturbing the rest.

The v44 patch 1 revision is the deliberate exception. It changes the DSI inputs and therefore bumps `ScriptVersion` to 44. Every managed machine performs one full-update pass on the next run and returns to the fast path. See the migration note in `CHANGELOG.md`.

## The state file

Path: `C:\Recovery\OEM\winre_state.json`.

### Schema

```json
{
    "DesiredStateId":           "<64-char hex>",
    "CurrentImageHash":         "<SHA256 hex of the deployed winre.wim>",
    "InjectedDriverSetVersion": "<manifest.version at deploy time>",
    "LastUpdated":              "yyyy-MM-dd HH:mm:ss",
    "PendingReboot":            false,
    "UsedOSFallback":           false,
    "RepairAttempts":           0,
    "DeployedDiskNumber":       4,
    "DeployedPartitionNumber":  4,
    "LastEnableResult":         "ok",
    "EnableFailureAttempts":    0
}
```

`DeployedDiskNumber` and `DeployedPartitionNumber` are present only when the deployment reached a dedicated recovery partition. They are used by the pending-reboot path to re-point `reagentc /setreimage` at the correct location after a reboot. They are absent from an OS-fallback state file, because the fallback target is `C:\Recovery\WindowsRE` — a path, not a partition by number.

`LastEnableResult` records the outcome of the last `reagentc /enable` attempt that reached a state-write point. Its values are `"ok"` (exit 0 and status confirmed `Enabled`), `"reboot"` (registration succeeded but a reboot is required), `"failed"` (generic hard failure), and `"bitlocker"` (the target recovery partition was BitLocker-protected, even after `Set-RecoveryPartitionReadyForWinRE` prepared it). `EnableFailureAttempts` counts *consecutive* terminal outcomes — both `"failed"` and `"bitlocker"` increment the counter. Both fields default to `"ok"` / `0` when absent, so a state file written by an earlier version of the script is accepted without triggering a rebuild.

### Read semantics

`Read-WinREState` is called once, near the top of the main flow, with the current `DesiredStateId`.

- If the file does not exist → return all-`$null` / all-`$false` defaults, treated as "no state."
- If the file exists and `DesiredStateId` matches → return the parsed state. Log "State file accepted."
- If the file exists and `DesiredStateId` does not match → return defaults, log "State file DesiredStateId mismatch - stale." The file is not deleted; the next write overwrites it.
- If the file exists but cannot be parsed → return defaults, log "Failed to parse state file."

Note: the stale file is left in place. If the next run also fails to reach a state-write point, the stale file stays. The next successful run overwrites it.

`LastEnableResult` and `EnableFailureAttempts` are read with defaults of `"ok"` and `0`. A state file written by an earlier version of the script that does not contain those fields is accepted without triggering a rebuild; the fast path treats it as a healthy machine on the counters dimension.

### Write semantics

`Write-WinREState` is called from:

- The fast path when `PendingReboot`, `RepairAttempts`, `EnableFailureAttempts`, or a non-`"ok"` `LastEnableResult` was carried in from a previous run and needs clearing.
- The enable-only path, to record the registration result. On a terminal outcome — `"failed"` from a generic enable failure, `"failed"` from a target-preparation failure, or `"bitlocker"` — the counter is incremented and the state file is written with the corresponding `LastEnableResult`. On `"reboot"` the state file is written with `PendingReboot = $true` and the counter reset to 0. On `"ok"` the enable-only path exits `EXIT_SUCCESS` (or `EXIT_WARNING` if a non-fatal warning flag was set) **without writing the state file**; the counter is not reset by the enable-only path on this outcome. The next run's fast path clears a stale non-zero counter, so the counter is reset one run later.
- The pending-reboot path, to update the `PendingReboot` and `RepairAttempts` flags. A successful pending-reboot repair resets the enable-failure counter to 0; a reboot-required outcome keeps `RepairAttempts` and resets the enable-failure counter.
- The full-update path, after Step 6 succeeds. If the run's `$enableResult` is `"failed"` or `"bitlocker"`, the counter is incremented; on any other outcome it resets to 0. The loop-breaker checks the incremented value on the next run.

The enable-failure counter is incremented on both terminal outcomes. The distinction between `"failed"` and `"bitlocker"` is preserved in the state file so the operator can see *why* the enable step is failing, but the counter treats them the same way — a machine that keeps failing on the BitLocker error is in the same kind of loop as a machine failing generically, and both need the same manual intervention.

Before writing, the function checks `$Script:GeometryRestoreFailed`. If that flag is set — meaning a post-shrink failure left C: shrunken and `Restore-OSPartitionSize` could not verify the geometry was restored — the function **deletes** the state file (if it exists) and returns without writing.

The deletion is deliberate. Skipping the write would not be enough: if the previous state file's `DesiredStateId` matched the current one, the next run's `Read-WinREState` would accept it, the count=0 exemption would fire, and C: would stay shrunken indefinitely. Deleting the file forces the next run to treat the state as absent, set `needInject = $true`, and re-run the full-update path, which re-extends C: as part of the destructive attempt.

If the deletion itself fails, the failure is logged as an error. Manual intervention is then required to force a retry.

### Idempotency via the state file

The fast path fires when:

- WinRE is enabled, AND
- The state file's `DesiredStateId` matches the current one, AND
- Exactly one recovery partition exists on the OS disk, AND
- The currently-registered partition is on the OS disk and is a recovery partition, AND
- The deployed WIM hash at the registered location matches `CurrentImageHash`.

If all five conditions hold, the machine is in the correct end state. The fast path runs `Remove-StrayRecoveryPartitions` (a read-only scan when there are no strays), optionally clears stale `PendingReboot` / `RepairAttempts` / `EnableFailureAttempts` flags and a stale `LastEnableResult`, and exits with `EXIT_SUCCESS`.

If any condition fails, the script forces a full rebuild. The conditions above are also the fast-path `elseif` branches — the log records which one failed.

### The loop-breaker

The enable-failure counter is checked near the top of the main flow, after the pending-reboot block and before the classifier runs:

```powershell
if ($state.EnableFailureAttempts -ge 3 -and $state.LastEnableResult -in @("failed","bitlocker") -and $WinREState.Status -ne "Enabled") {
    # log "manual intervention required", remove the checkpoint file, exit EXIT_FATAL
}
```

This fires when `reagentc /enable` has failed terminally on 3 or more consecutive runs and WinRE is still `Disabled`. The purpose is to prevent a machine from silently retrying `/enable` forever when no amount of retrying will resolve the underlying cause — Audit Mode (before the Audit Mode guard was added), a broken ReAgent registration, a Windows component problem, or a recovery partition that the Device Encryption service keeps re-claiming. The `LastEnableResult -in @("failed","bitlocker")` condition means the loop-breaker fires for both terminal outcomes; the counter is the same for both, and the recovery is the same: resolve the underlying cause, delete the state file, re-run.

The state file is left in place when the loop-breaker fires. The log message names the state file path and instructs the operator to delete it to reset the counter, once the underlying cause has been resolved.

Under `-DryRun` the loop-breaker logs `Would refuse to retry …` and continues rather than exiting, matching the pattern used by the Audit Mode guard.

## The checkpoint file

Path: `C:\ProgramData\OEM\Logs\winre_checkpoint.txt`.

Format: `Step|DesiredStateId`, one line, e.g. `3|a1b2c3...`.

### Purpose

The checkpoint file exists to make a partially-completed full-update run resumable. If a run completes step 2 and then the machine is rebooted or the task is killed, the next run can resume from step 3 instead of redoing step 2. This saves time on slow machines and on slow networks.

### Steps

| Step | Meaning |
|---|---|
| 0 | No checkpoint. Start at step 1. |
| 1 | Step 1 (WorkDir wipe) complete. Resume at step 2. |
| 2 | Step 2 (base WIM) complete. Resume at step 3. |
| 3 | Step 3 (mount/inject) complete. Resume at step 4. |
| 4 | Step 4 (optimize) complete. Resume at step 5. |
| 6 | Full-update path complete. The checkpoint is about to be deleted. |

Step 5 is not checkpointed. It is the partition-and-deploy step, and resuming in the middle of it would leave the machine in an unrecoverable state.

### Guards on resume

After `Get-Checkpoint`, the main flow applies two guards:

```powershell
if ($step -ge 2 -and -not (Test-Path "$WorkDir\base.wim")) { $step = 1 }
if ($step -ge 4 -and -not (Test-Path "$WorkDir\winre_optimized.wim")) { $step = 4 }
```

If the checkpoint says step ≥ 2 but `base.wim` is missing (WorkDir was wiped manually, or the machine was rebooted into a clean state), reset to step 1. Same for `winre_optimized.wim` and step 4.

### The v43 patch 4 migration guard

A separate guard runs after `$needInject` has been fully determined:

```powershell
if ($step -ge 4 -and $needInject) {
    $step = 2
}
```

This handles the case where a **prior** run failed injection and left a checkpoint at step ≥ 4 with a valid (but stale) state file. Without the guard, the new run would skip step 3 (`$step -le 3` is false for `$step >= 4`), initialize a fresh `$Script:ImageInjectionComplete = $true`, deploy the un-injected WIM, and commit state for it.

The placement matters: the guard runs after `$needInject` is decided, so it catches both the "no state file" case and the "valid-but-stale state file" case. An earlier placement (immediately after the state read) would only catch the former.

### Checkpoint advance gating (v43 patch 4)

The three checkpoint writes at steps 3, 4, and 6 are now conditional on `$Script:ImageInjectionComplete`:

```powershell
if ($Script:ImageInjectionComplete) {
    Set-Checkpoint -CheckpointFile $CheckpointFile -Step N -DesiredStateId $DesiredStateId
} else {
    Write-Log "Checkpoint NOT advanced to step N - image injection did not complete; next run will retry step 3" -Level WARN
}
```

On a healthy run the gate is a pass-through. When injection failed, the checkpoint stays at 2 and the next run re-enters step 3 and retries.

This closes an interaction that was invisible to either mechanism in isolation: the checkpoint's job is "resume an interrupted attempt at the same target"; the state file's job is "record whether that target was actually reached." An unconditional checkpoint advance let a run's checkpoint say "past step 3" while its state file correctly said "not done," with no code path checking both at once. The gate aligns the two.

### Checkpoint cleanup

The checkpoint file is deleted:

- After the fast path completes.
- After the enable-only path completes (any outcome).
- After the pending-reboot path completes.
- After the full-update path reaches step 6.

If a run is interrupted between `Set-Checkpoint -Step 6` and `Remove-ItemIfExist $CheckpointFile`, the checkpoint file persists. The migration guard handles this on the next run.

## Crash consistency

The two files have independent lifecycles, and their interaction is what the guards above are protecting.

| State file | Checkpoint file | Meaning | Next run behaviour |
|---|---|---|---|
| Absent | Absent | Fresh machine, never run. | Full update from step 1. |
| Absent | Present, step < 3 | Interrupted run before injection. | Full update from step 1 or 2. |
| Absent | Present, step ≥ 4 | Interrupted failed-injection run, or `GeometryRestoreFailed` deleted the state file. | Migration guard resets `$step` to 2. Full update from step 2. |
| Present, matching | Absent | Healthy, complete run. | Fast path. |
| Present, matching | Present, step < 3 | Interrupted run that matched the state file. Unusual. | Full update from step 1 or 2. |
| Present, matching | Present, step ≥ 4 | Interrupted failed-injection run with a stale-but-valid state file. | Migration guard resets `$step` to 2 (because `$needInject` will be true). Full update from step 2. |
| Present, stale | Any | The machine's `DesiredStateId` has changed. | Full update from step 1. |

The two files are written atomically (`Write-FileAtomically` uses a temp file + `Move-Item` with retries), so neither can be partially written even on power loss.

## Why not file locks or a database?

Two constraints made a simpler design the right one:

1. **The script runs as SYSTEM from a scheduled task that uses `IgnoreNew` for overlapping instances.** Two runs cannot overlap by construction; a file lock would be redundant.
2. **The state file is small, JSON, and human-readable on purpose.** When a field engineer opens `C:\Recovery\OEM\winre_state.json`, they should see something they understand. A SQLite database or a binary blob would not serve that requirement.

The trade-off is that the script does not defend against an operator manually editing the state file. That is not a scenario the design needs to support; if you edit the state file, you own the consequences.

## Related documents

- [architecture.md](architecture.md) — the pipeline and how the state fits into it.
- [recovery-partition.md](recovery-partition.md) — what the `GeometryRestoreFailed` flag protects against.
- [exit-codes.md](exit-codes.md) — the exit code each state leads to.
