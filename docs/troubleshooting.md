# Troubleshooting

Per-symptom playbook for WinRE Manager. Each section names the symptom, the log lines to look for, the likely causes, and the resolution.

This document is for anyone who has run `WinRE.ps1` and gotten something other than a clean exit — a warning code, a fatal code, a deferral, or a machine that is still broken. It is written for both audiences: a single machine owner repairing their own laptop, and an IT admin diagnosing a fleet. The same symptoms, the same log signatures, and the same resolutions apply in both cases.

Log location: `C:\ProgramData\OEM\Logs\WinRE-Manager.log`.

## How to use this document

1. **Find the symptom.** The section headings name the observable problem — "The machine has no recovery partition and WinRE is disabled", "The machine is in Audit Mode / OOBE / sysprep", "OEM or VMD injection failed", and so on. Skim the headings for the closest match.
2. **Check the log signature.** Each section names the exact log lines that distinguish one failure from another. If your log does not contain those lines, you are probably looking at a different section.
3. **Follow the resolution.** Each section ends with a concrete set of steps. Most are safe to run without stopping anything first.
4. **If nothing matches**, see [Reporting a bug](#reporting-a-bug) at the bottom — the template tells you exactly what to include.

Three common entry points, if you already know which one you are:

- **"The script exited with code 2 or 3 and I don't know why."** → Read the [exit-codes.md](exit-codes.md) reference first, then come back here with the specific case in hand.
- **"The machine still has the same problem after running the script."** → Find the section whose log signature matches your log. If no section matches, the machine is probably in a state this document does not cover and should be reported.
- **"I have not run the script yet and want to know what it will see."** → Run `scripts\Test-WinRE.ps1` first. Option 1 shows the diagnostic; Option S shows whether production would take the fast path. Come back here only if the harness reports something unexpected.

## How to read the log

Every line is `yyyy-MM-dd HH:mm:ss [LEVEL] message`. Levels are `INFO`, `WARN`, `ERROR`, `FATAL`. In `-DryRun` mode, every line is prefixed with `[DRYRUN-<LEVEL>]` instead so a dry-run audit can be distinguished from a live run.

The first line is `========== WinRE Manager Started (v<version> patch <level>) ==========`. Most runs end with a `Released program lock` line; the reboot-required path additionally logs `========== WinRE Manager completed - reboot still required ==========` before exiting. The exit code, not a final log line, is the authoritative outcome signal.

As of v46 patch 2, every run logs three build numbers: the registered WinRE version (`WinRE status: ..., Location: ..., Version: <x>`), the source WIM build (`Source WIM build: <build> (path: <path>)` during force-upgrade detection), and the post-deploy WIM build (`Post-deploy WIM build: <build> (source: <path>)` immediately before the state write). None of the three affects control flow; they are logged for evidence. A run whose `Source WIM build` or `Post-deploy WIM build` is older than the registered `Version` is a candidate signal for base-image drift, not a fault.

As of v47 patch 1, a full-update run additionally logs:

- **The registered-source fingerprint captured before source acquisition**: `Captured registered-source fingerprint: location=..., version=..., hash=...`. This is the value the pre-`/disable` race detector compares against later.
- **The base WIM source-selection decision**: `Base WIM source selection: <reason> -> <path>`. The reason names the branch — `no hash-validated LKG present; using registered`, `registered at least as new as LKG`, `registered older than LKG`, `metadata comparison indeterminate; using hash-validated LKG`, `registered not usable; using hash-validated LKG`, or `neither registered nor hash-validated LKG usable; GitHub cold-start`.
- **The strip stage's inventory and progress**: `Strip: pre-strip third-party inventory: N package(s)`, followed by one line per package (`Strip:   <OEM#.inf> | <provider> | <version> | <original filename>`), then `Strip: removed <OEM#.inf>` per removal and a terminator (`Strip: verified zero third-party drivers remaining after removing N package(s)` or `Strip: image already has zero third-party drivers`).
- **The pre-injection third-party driver count**: `Pre-injection third-party driver count: N`. Under v47 this should be 0 unless the filterless and filtered DISM queries disagree (see the note in the strip-failure section below).
- **The race-detector recheck at whichever `/disable` site the execution reached**: `Registered-source recheck at <site> : unchanged (...)`, where `<site>` is `Ensure-AdequateRecoveryPartition` or `Step 5 deployment`. On drift, the same line reads `CHANGED (location=<bool> version=<bool> hash=<bool>)`.
- **The registered-versus-deployed metadata comparison** at the drift detector: `Registered WinRE metadata: <ver>|<sp>; last deployed: <ver>|<sp>` (or `(none)` on the first v47 run).
- **The deployed metadata anchor written at state-write time**: `Deployed WinRE metadata: <ver>|<sp>`.

The program lock is acquired first, immediately after the banner. The log records `Acquired program lock at C:\ProgramData\OEM\Logs\WinREManager.lock` on success, `Another WinRE Manager instance is already running (program lock file is exclusively held). …` if a second instance is running, and `Could not set up program lock at <path> : <error> - proceeding without single-instance protection; concurrent runs may collide` if the lock could not be acquired for a non-contention reason. Under `-DryRun` the lock is skipped and the log records `[DRY RUN] Skipping program lock - DryRun is read-only and safe to run concurrently with other instances`. See "The script exited with a rename error (concurrent instance)" below for the full discussion.

One startup guard then runs before any state-modifying action: the Audit Mode guard. It logs a distinct deferral message when it fires. Under the v43 patch 5 (further revision 5) policy, BitLocker state is not consulted at startup — the target volume is not known until the classifier has resolved the reagentc-registered location, and the BitLocker decision is made where the action is taken. Two places consult BitLocker state as part of a decision: the enable-only path and the full-update deploy step prepare the **target recovery partition** through `Set-RecoveryPartitionReadyForWinRE`; and the OS-fallback route checks C: through the OS-fallback gate. Each logs a distinct message; see the corresponding sections below. As of v44 patch 6, the destructive path no longer consults C:'s BitLocker state at all — only the OS-fallback route does, because on that route the target volume *is* C:.

One further check that runs early and can defer the run is the VMD hardware presence detection. As of v44 patch 6 it is fail-closed: a PnP enumeration error is treated as indeterminate rather than as VMD hardware absent. See "VMD hardware detection was indeterminate" below.

One classifier message that fires early, without stopping the run, is the label-only classifier WARN (v44 patch 7). When the active WinRE location resolves to a partition whose GPT type is not the recovery GUID and whose MBR type is not `0x27`, but whose volume label is `Recovery` or `WINRE`, the classifier logs a WARN and does **not** treat the partition as a recovery partition. See "The machine keeps rebuilding and never takes the fast path (label-only recovery partition)" below.

One further class of deferrals was introduced in v45 patch 1: the pre-shrink deferrals from `Ensure-AdequateRecoveryPartition`. The function returns a `Deferred` result with a specific `Reason`, and when `RetrySuppressible = $true` the main flow writes the deferral sidecar at `C:\Recovery\OEM\winre_partition_deferred.json`. v46 patch 2 and v47 patch 1 added further reasons to this set. See "The destructive replacement was deferred before partition deletion" below for the full list of reasons and their resolutions.

Three v47 patch 1-specific failures have their own sections: the strip stage failing (see "The strip stage failed"), the pre-`/disable` race detector firing (see "The pre-`/disable` race detector fired"), and a metadata-triggered rebuild (see "The rebuild ran because the registered WinRE metadata changed"). These are the newest addition to the playbook and have not been exercised in the field; a machine that reaches them warrants a bug report.

## The machine has no recovery partition and WinRE is disabled

**This is the most severe failure mode the project has seen, and it was caused by a bug in pre-v43-patch-5 code. If you are running v43 patch 5 or later, this failure mode no longer occurs on the dedicated-partition route.** The pre-patch-5 code deleted the recovery partition on a machine mid-Device-Encryption and could not recreate it. The current code prevents that by applying the recovery type GUID at partition creation and by decrypting in place if the Device Encryption service claims the partition anyway.

**Symptom.** After a run that exited with code 3 (`EXIT_FATAL`), the machine has:

- No recovery partition on the OS disk (`Get-Partition` shows only the EFI, MSR, and Windows partitions).
- WinRE reported as disabled (`reagentc /info` shows `Windows RE status: Disabled`).
- The fallback WIM still present at `C:\Recovery\WindowsRE\winre.wim`.

**Log signature.** Two log entries together:

```
[WARN] Newly created recovery partition is BitLocker-encrypted - attempting delete and recreate after suspend
[ERROR] Recovery partition is STILL BitLocker-encrypted after recreate - aborting
```

followed by:

```
[ERROR] reagentc /enable failed because the target volume is BitLocker-protected
```

and finally:

```
[ERROR] FATAL: WinRE is not enabled at exit
```

**No current build emits these log lines.** The delete-and-recreate retry was removed in v43 patch 5 (further revision 5), along with the `Suspend-BitLockerForWinRE` function. v43 patch 5 (further revision 5) and later log a different sequence for the same underlying condition -- the OS-fallback BitLocker deferral (see "The OS-fallback route deferred because C: is encrypted" above) or the enable-only target-preparation failure (see "Target recovery partition could not be made unencrypted" below). The lines above are retained for interpreting historical logs, and match the failure that motivated the v43 patch 5 fix.

**Cause.** The machine was mid-Device-Encryption when the script ran. `ProtectionStatus` read `Off` while `VolumeStatus` read `EncryptionInProgress`. The pre-patch-5 code treated `ProtectionStatus=Off` as sufficient evidence that BitLocker was not a factor, deleted the existing recovery partition, and created a new one. The Device Encryption service claimed the new partition and started encrypting it before the recovery type GUID could be applied. The delete-and-recreate retry hit the same problem. The script fell back to OS-fallback and then `reagentc /enable` refused because C: was actively encrypting.

Two field failures, both on Windows 11 build 26200:

- **Dell Latitude 3550** (Intel Core Ultra 5 125U) — 2026-09-28, `VolumeStatus=EncryptionInProgress` at 73.6%.
- **HP ProBook 450 15.6 inch G10** (Intel Core i7-1355U) — 2026-09-28, same state.

**A related but distinct failure mode.** The post-deletion create/format corner described under ["The OS-fallback route deferred because C: is encrypted"](#the-os-fallback-route-deferred-because-c-is-encrypted) also produces a machine with no dedicated recovery partition and no working WinRE registration. It is a different root cause — a post-delete failure on an encrypted-C: machine, not the pre-patch-5 Device Encryption race — but the end state looks similar. If the machine's log shows `Pre-deletion inventory:` followed later in the same run by `OS-fallback deferred:`, see that section instead of this one. If the machine's log shows `Newly created recovery partition is BitLocker-encrypted - attempting delete and recreate after suspend`, this section applies.

**Recovery procedure.** Wait for the encryption to finish or abort it, then re-run with patch 5 or later.

**Step 1 — resolve the encryption state.** Open an elevated PowerShell:

```powershell
manage-bde -status C:
```

Read the `Conversion Status:` line.

- If it says `Fully Decrypted` — encryption was never active or was already aborted. Continue to step 2.
- If it says `Fully Encrypted` with `Protection On` — encryption completed and the key was escrowed. Continue to step 2.
- If it says `Fully Encrypted` with `Protection Off` — the machine is in the ambiguous suspended/Waiting-for-Activation state. On the OS-fallback route, production will defer this state; on the dedicated-partition route it does not matter, because the target is the recovery partition, not C:. If the dedicated-partition route is what you want, continue to step 2. If you specifically want the OS-fallback route, wait for the state to resolve to either `Protection On` (activation completed and key escrowed) or `Fully Decrypted`.
- If it says `Encryption In Progress` or `Encryption Paused` — the encryption service is still active. Wait for it to complete (typically 30 minutes to a few hours on a 256 GB SSD, longer on HDD), or abort it:

  ```powershell
  manage-bde -off C:
  ```

  This starts decryption. On a machine mid-encryption, decryption is usually faster than encryption. Wait until `Conversion Status:` reads `Fully Decrypted` before continuing.

**Step 2 — update `WinRE.ps1` to v45 patch 1 or later.** Check the `.NOTES` block at the top of the file for its `Version` line. If the version is below 45, deploy the v45 release (or the current release) before proceeding.

**Step 3 — re-run `WinRE.ps1`.** With the current policy, the script will:

1. Acquire the program lock.
2. Pass the Audit Mode guard.
3. Choose the enable-only or full-update path.
4. Prepare the target recovery partition via `Set-RecoveryPartitionReadyForWinRE`. If the target is encrypted, the helper decrypts it in place with `manage-bde -off` and polls for completion, up to 300 seconds.
5. Call `reagentc /setreimage` and `reagentc /enable` on the prepared target.

The machine returns to a `DEDICATED` end state.

**Immediate interim fix.** If the machine must be returned to service before you can update the script, `reagentc /enable` will succeed against the OS-fallback location once C: is `FullyDecrypted`:

```powershell
reagentc /setreimage /path C:\Recovery\WindowsRE
reagentc /enable
```

This gives you OS-fallback WinRE — functional but not the design goal. The dedicated recovery partition can be recreated later by a run of the current script.

**Do NOT re-run the pre-patch-5 script on this machine.** It will fail the same way and delete the recovery partition again.

## The machine is in Audit Mode / OOBE / sysprep

**Symptom.** The script runs, exits with code 2 (`EXIT_WARNING`), and the machine is completely unchanged — no partition was touched, no WIM was deployed, WinRE is still in whatever state it was before the run, and no state file was written. The script has done nothing wrong; it has deferred.

**Log signature.** Two lines at the very top of the run, immediately after the `========== WinRE Manager Started (v47 patch 2) ==========`, the `Acquired program lock at …` line, and the `*** DRY RUN MODE ***` line if `-DryRun` was passed:

```
[WARN] Deferring WinRE Manager: Windows is not in a normal-running state (Setup\State\ImageState=<value>). reagentc /enable is blocked with 0x4c7 during Audit Mode, OOBE, and the sysprep generalize/specialize phases regardless of WIM correctness. No WinRE or partition changes will be made.
[WARN] Complete OOBE, sign in to a normal desktop session, and re-run this script.
```

Under `-DryRun` the first line reads `Would defer` instead of `Deferring`, and the run continues.

**Cause.** Windows is in a transitional state that is not yet a normal-running installation. During Audit Mode, OOBE, the sysprep generalize phase, and the sysprep specialize phase, `reagentc /enable` fails with `ERROR_CANCELLED` (`0x4c7`, 1223) regardless of the correctness of the deployed WIM or the state of the recovery partition. There is no workaround; the OS blocks `/enable` on purpose until the machine reaches a normal desktop.

The startup guard reads `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` → `ImageState`. It proceeds only when the value is absent (some SKUs omit the key) or exactly `IMAGE_STATE_COMPLETE`. Any other value defers. The predicate is deliberately conservative — it does not depend on knowing the exact value that Audit Mode writes.

Field case: **Dell Latitude 5530** (12th Gen Intel i7-1265U, Windows 11 build 26200). The machine was in Audit Mode when the script first ran. The previous code (which had no Audit Mode guard) deployed the WIM successfully through Step 5 and then failed at `reagentc /enable` with `0x4c7` on two consecutive runs. It also wrote a state file recording the deployment as complete, so every subsequent run took the enable-only path and failed the same way — a permanent loop. After the user completed OOBE, signed in, and ran `reagentc /enable` manually, it succeeded on the first attempt with the same WIM. That confirms Audit Mode was the only blocker. This is the case that motivated the Audit Mode guard.

**Resolution.**

1. Complete OOBE on the machine. Sign in to a normal desktop session.
2. Confirm the state has resolved:

   ```powershell
   (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State" -Name ImageState -ErrorAction SilentlyContinue).ImageState
   ```

   It must read `IMAGE_STATE_COMPLETE`, or the key must be absent.
3. Re-run `WinRE.ps1`. The startup guard will pass, and the script will proceed normally.

Do **not** attempt to defeat the guard by editing the registry or by manually calling `reagentc /enable` while still in Audit Mode. The OS will reject it, and the script's state file may or may not record the attempt depending on which code path you used to invoke reagentc. Wait for OOBE to complete.

**What if `ImageState` is a value other than `IMAGE_STATE_COMPLETE` but the machine is clearly in a normal desktop?** File a bug. The guard's whitelist is currently `IMAGE_STATE_COMPLETE` or the key being absent. If a legitimate running state reports a different value, add it to the whitelist in the startup guard and re-run. The log line names the exact value that triggered the deferral.

## VMD hardware detection was indeterminate (v44 patch 6)

**Symptom.** The run exits with code 2 (`EXIT_WARNING`) and the machine is untouched: no partition work, no WIM deployment, no `reagentc` calls, and the state file is unchanged (or absent). The run got as far as the VMD hardware presence check and could not complete it.

**Log signature.** The last lines of the run before exit:

```
[WARN] VMD hardware detection reported N error(s) during PnP enumeration: <error> - treating VMD presence as indeterminate.
[WARN] VMD hardware detection was indeterminate; deferring because the driver set cannot be safely determined. Re-run when PnP enumeration is healthy.
```

Followed by `Released program lock` and exit code 2.

**Cause.** As of v44 patch 6, the VMD hardware presence check is fail-closed. It enumerates present PnP devices matching the manifest's VMD device IDs; if the enumeration itself reports an error, the script treats VMD presence as **indeterminate** rather than as "VMD hardware absent". This is deliberate: on a machine that genuinely has VMD hardware, guessing "absent" would select a driver set that omits the VMD package, and the deployed WinRE would not be able to see the OS disk.

Common causes of the enumeration error:

- The Plug and Play service or the Windows Device Management service is in a bad state.
- An antivirus or EDR product is blocking device enumeration (some products do this under specific policy configurations).
- A pending driver installation or a device in an error state is preventing the PnP manager from completing the query.
- A Windows component store issue affecting the `Get-PnpDevice` cmdlet.

**Why the run stops.** The VMD driver set is a function of VMD hardware presence. If VMD presence cannot be determined, the correct driver set cannot be selected. Proceeding on a guess would risk deploying a WinRE that cannot see the OS disk on a VMD-based machine — the exact failure mode that the v44 patch 1 `DesiredStateId` change was designed to prevent, and one that is worse than deferring. The deferral is a protective stop, not a degraded-success.

**Resolution.**

1. **Confirm the PnP services are healthy.**

   ```powershell
   Get-Service -Name "PlugPlay", "DeviceAssociationService", "DeviceInstall" | Select-Object Name, Status, StartType
   ```

   All three should be `Running`. If any is stopped, start it:

   ```powershell
   Start-Service -Name <name>
   ```

2. **Check for a pending driver installation or a device in an error state.** Open Device Manager and look for any device with a yellow warning icon. A device with a failed driver load can prevent `Get-PnpDevice -PresentOnly` from returning a clean result.

3. **If an antivirus or EDR product is in use, check whether it has a policy blocking device enumeration.** Some products have a documented setting for this. Consult the vendor's documentation.

4. **Re-run the harness Option 1 diagnostic.** It exercises the same `Get-PnpDevice` query and reports either the matching device count or the same enumeration error production saw. If the harness succeeds where production failed, the error was transient.

5. **Re-run `WinRE.ps1`.** Once the PnP enumeration is healthy, the run proceeds normally.

**Do not disable the fail-closed check.** The check exists because guessing wrong on VMD presence produces a recovery image that cannot see the OS disk. The cost of a deferral is one pipeline run; the cost of bypassing the check is a machine with a non-functional recovery environment. If the check is firing repeatedly, the underlying PnP service issue is the problem to solve.

## The log shows `CmdletizationQuery_NotFound_DiskNumber` (v46 patch 2)

**Symptom.** The production log or the harness Option 1 diagnostic shows one or more lines reading:

```
Get-Partition : No MSFT_Partition objects found with property 'DiskNumber' equal to 'N'.  Verify the value of the property and retry.
At C:\Users\...\Downloads\Test-WinRE.ps1:NNN char:NN
+                      Get-Partition -DiskNumber $diskNum | Where-Objec ...
+                      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

The error is non-terminating, so the run continues and completes normally; the summary and every subsequent section of the diagnostic are unaffected.

**Cause.** A disk that exposes no MSFT_Partition objects — typically an empty SD/MMC card reader, an empty USB enclosure, or a disk with no recognized partition table — causes `Get-Partition -DiskNumber N` to throw `CmdletizationQuery_NotFound_DiskNumber`. The disk is reported by `Get-Disk` (so it enters the loop in `Get-RecoveryPartitions`), but it has no partitions (so the `Get-Partition -DiskNumber` call finds nothing and throws). The error surfaces on every `Get-RecoveryPartitions` invocation — three times in the reference diagnostic.

Field case: **HP EliteBook 8 G1i 16 inch Notebook AI PC** with an SD/MMC card reader (disk 1, no partitions), 2026-10-02 15:20. The error appeared three times in the pre-fix harness diagnostic on that machine.

**Resolution.** Upgrade to v46 patch 2 (production) or harness v22 or later. Both add `-ErrorAction SilentlyContinue` to the two `Get-Partition -DiskNumber $diskNum` calls inside `Get-RecoveryPartitions`. The behaviour on disks that do expose partitions is unchanged; the guard only silences the throw on disks that expose none.

**Is this a problem on a pre-v46-patch-2 build?** No. The error is cosmetic — the diagnostic continues after each occurrence, the machine state is not affected, and no decision the script makes depends on the missing partitions. The correct response, if you see it, is to note the disk number the error names (it is a disk with no partitions) and confirm the rest of the diagnostic is complete.

## The strip stage failed (v47 patch 1)

**Symptom.** The run exits with code 2 (`EXIT_WARNING`) and the machine is untouched: no WIM was deployed, no partition was deleted, WinRE was not disabled, and no `reagentc` call was made. The state file is unchanged (or absent). The run got as far as mounting the base WIM, and the strip stage could not prove the mounted image was free of third-party drivers.

**Log signature.** One of the following before the abort line:

```
[ERROR] Strip: initial Get-WindowsDriver enumeration failed: <error> - candidate rejected
```

or

```
[ERROR] Strip: re-enumeration failed at iteration <n> : <error> - candidate rejected
```

or

```
[ERROR] Strip: enumeration entry has no Driver field (published INF name) - candidate rejected
```

or

```
[ERROR] Strip: Remove-WindowsDriver failed for <OEM#.inf> : <error> - candidate rejected
```

or

```
[ERROR] Strip: exhausted iteration budget (<n>) without reaching zero - candidate rejected
```

Followed by:

```
[ERROR] Strip stage failed - candidate rejected. Dismounting with -Discard and deferring before injection, export, partition work, or WinRE disable.
```

Followed by the dismount, checkpoint rollback to Step 2, and removal of `base.wim` and any stale `winre_optimized.wim`, then exit code 2.

**Cause.** The v47 strip stage is a hard gate. It uses `Get-WindowsDriver -Path $MountDir` **without `-All` and without a provider filter** to enumerate the third-party inventory of the mounted image, removes each published `OEM#.inf` one at a time, and re-enumerates after each removal. It succeeds only when a fresh enumeration returns zero entries. Every failure mode is treated as a candidate rejection:

- **Initial enumeration failed.** `Get-WindowsDriver` itself threw on the mounted image. Common causes: the image is corrupt or partially written, DISM cannot read the image's driver store, or a DISM servicing stack issue is preventing the query.
- **Re-enumeration failed at iteration N.** The initial enumeration succeeded but a subsequent one threw. This is unusual and often indicates a DISM state that degraded during the removals.
- **Enumeration entry has no `Driver` field.** A returned driver entry is missing the published INF name the removal call needs. This is a DISM return-shape anomaly.
- **`Remove-WindowsDriver` failed.** The removal call for a specific published INF returned an error. Common causes: the driver package is marked non-removable in the image, the image is locked, or a DISM servicing stack error.
- **Iteration budget exhausted.** The loop ran more iterations than the budget allowed without reaching zero. This usually means removals are succeeding but new third-party entries keep appearing — an unusual state that the hard gate refuses to interpret.

**Why the run stops.** Microsoft documents `Get-WindowsDriver` / `Remove-WindowsDriver` and offline WinRE servicing with DISM, but the "strip-everything-then-inject-the-recipe" pattern is the project's own engineering choice. Its safety property is that the deployed image is a deterministic function of Microsoft's WinRE base plus the current recipe — with no memory of prior rebuilds. That property only holds if the strip is provably complete. If the strip cannot prove zero third-party drivers remain, the candidate WIM's provenance is not deterministic, and deploying it would reintroduce the driver-accumulation problem the v47 design exists to eliminate. The abort is a protective failure, not a degraded-success: the run stops before anything is committed.

**Enumeration failure is never interpreted as zero.** A DISM query that throws is not evidence that the image has zero third-party drivers — it is evidence that the query could not be answered. The gate is deliberately fail-closed on this point.

**Resolution.**

1. **Re-run the harness Option 1 diagnostic** to confirm the underlying Windows tooling is healthy. In particular, confirm the DISM cmdlet check (Check 11) passes — `Mount-WindowsImage`, `Dismount-WindowsImage`, `Get-WindowsImage`, `Add-WindowsDriver`, and `Get-WindowsDriver` must all be present.

2. **Check the log line above the failure** for the specific error. The candidate rejection reason names the exact failure: an enumeration error, a removal error, a missing `Driver` field, or a budget exhaustion.

3. **If the failure is on the initial enumeration**, the mounted image may be corrupt or partially written. Check the workspace's `base.wim` size against the source from which it was copied; a partially-written base image can cause a DISM read failure. The next run re-acquires the base WIM from source and retries.

4. **If the failure is `Remove-WindowsDriver failed` for a specific INF**, the driver package may be marked non-removable in the image. This is uncommon for the OEM WinPE driver packs that the recipe typically adds, and it usually indicates an image whose driver store has been modified outside the project's own pipeline. On a machine whose registered WinRE is the source, this may be a Windows Update-delivered image with a package the removal API cannot touch. Investigate the driver store state on the mounted image if you have a way to reproduce the mount outside the script.

5. **If the failure is `exhausted iteration budget`**, the removals are not converging. This is unusual and warrants a bug report; include the full log (the per-iteration removal lines are logged).

6. **After identifying the cause, resolve it and re-run `WinRE.ps1`.** The checkpoint is at Step 2 and the workspace was cleaned by the gate; the next run re-acquires the base WIM and re-runs the strip.

**Not to be confused with the OEM or VMD injection failure.** Both are protective stops in Step 3, but they fire at different points: the strip failure fires between mount and injection; the injection failure fires after the strip succeeded, during the recipe-injection step. The log signatures are distinct — the strip failure's abort line reads `Strip stage failed - candidate rejected`; the injection failure's abort line reads `Image injection did not complete. Stopping before Step 4 and before any deployment.`

**Field status.** The strip stage with a non-zero third-party driver set has not been exercised in a v47 production run. The ASUS PRIME H510M-D v47 field run took the strip as a no-op (the registered image was already clean). If you see this section's log signature on a machine — especially the initial-enumeration or removal-failure variants — please capture the full log and file a bug per the [Reporting a bug](#reporting-a-bug) section.

## The pre-`/disable` race detector fired (v47 patch 1)

**Symptom.** The run exits with code 2 (`EXIT_WARNING`) and the machine is unchanged: no partition was deleted, no WIM was deployed. The abort happened before a `reagentc /disable` call. If the abort fired at the `Ensure-AdequateRecoveryPartition` site, C: is restored to its captured size — the pre-shrink ran before the abort, so a size restoration is required. If the abort fired at the Step 5 deployment site, no rollback is needed because no partition changes were made.

**Log signature.** The captured fingerprint appears near the start of the full-update path:

```
[INFO] Captured registered-source fingerprint: location=<location>, version=<version>, hash=<hash>
```

The abort appears at whichever `/disable` site the execution reached:

```
[WARN] Registered-source recheck at Step 5 deployment : CHANGED (location=<bool> version=<bool> hash=<bool>); captured loc=<captured> ver=<captured>; now loc=<now> ver=<now>
```

or

```
[WARN] Registered-source recheck at Ensure-AdequateRecoveryPartition : CHANGED (location=<bool> version=<bool> hash=<bool>); captured loc=<captured> ver=<captured>; now loc=<now> ver=<now>
```

Followed (at the `Ensure-AdequateRecoveryPartition` site) by:

```
[WARN] Registered WinRE source changed during candidate preparation - aborting before /disable. Restoring C: to its captured size; no partitions have been deleted.
```

Followed (at the Step 5 deployment site) by:

```
[WARN] Registered WinRE source changed during candidate preparation - aborting before /disable. The old WinRE route remains intact; no partition changes have been made at this site.
```

Then the checkpoint is reset to Step 2, `base.wim` and any stale `winre_optimized.wim` are removed, and the run exits with code 2.

**Cause.** The v47 patch 1 pre-`/disable` race detector caught the registered WinRE image changing between the start of the rebuild and the moment before the `/disable` call. The detector captures the registered WinRE's `Location`, `Version` (from `reagentc /info`), and WIM SHA256 at the start of the rebuild, and re-reads all three immediately before the first `/disable` of the execution. Any change — location, version, or hash — aborts the disable.

The race the detector closes is real: Windows Update can service or replace the registered WinRE while the script is preparing its candidate WIM. The candidate WIM was built from the registered image (or the LKG, or GitHub), the registered image changes under the script's feet, and the `/disable` + `/enable` cycle deploys a WIM that no longer corresponds to what the detector could have verified. The abort is protective.

**Named as a race detector, not a lock.** Microsoft does not document `reagentc /disable` as atomic with respect to Windows Update. The microseconds between the re-read and the `/disable` call returning cannot be eliminated without moving work into the disable→enable window, which would violate invariant 3 (minimize the disable→enable window). The detector narrows the window from minutes to those residual microseconds.

**Resolution.**

1. **Do nothing if a Windows Update is currently servicing WinRE on the machine.** The abort is the correct protective response; the WU is going to finish on its own. Wait for the WU to settle, then re-run `WinRE.ps1` on the next scheduled trigger.

2. **If no Windows Update is plausibly servicing WinRE on the machine,** investigate why the registered `Location`, `Version`, or WIM SHA256 changed during candidate preparation. Possible causes:
   - An antivirus or endpoint-protection product replaced `winre.wim` at the registered location.
   - An administrator or another tool manually re-registered WinRE to a different location.
   - A concurrent instance of `WinRE.ps1` (or another WinRE-servicing tool) ran the disable/enable cycle and replaced the registered image.

3. **Check `C:\ProgramData\OEM\Logs\WinREManager.log` for the corresponding entry** on the surrounding lines. The recheck line's `location=<bool> version=<bool> hash=<bool>` triple tells you which field changed.

4. **Re-run `WinRE.ps1`.** The next run captures a fresh fingerprint and proceeds normally. The checkpoint was reset to Step 2 and the staged artifacts were removed, so the run restarts source acquisition cleanly.

**Field status.** The race detector has not fired in the field. The ASUS PRIME H510M-D v47 field run logged `Registered-source recheck at Step 5 deployment : unchanged`. If you see this section's log signature, please capture the full log and file a bug per the [Reporting a bug](#reporting-a-bug) section — the exact change pattern (location vs. version vs. hash) is useful field data.

## The rebuild ran because the registered WinRE metadata changed (v47 patch 1)

**Symptom.** The run takes the full-update path on a machine that would otherwise have taken the fast path. The state file's `DesiredStateId` matches the current one, but the rebuild runs anyway. This is the v47 drift detector's behavior, and it is a correct response to any of several conditions.

**Log signatures.** Any of the following appears before the full-update path begins:

```
[INFO] Registered WinRE metadata: <ver>|<sp>; last deployed: <ver>|<sp>
```

followed by one of:

```
[INFO] State has no DeployedWinREMetadata anchor (previous deployment could not record it) - rebuilding
```

or

```
[INFO] Registered WinRE metadata changed from <old> to <new> - rebuilding
```

or

```
[INFO] Registered WinRE metadata could not be read - forcing rebuild so the repair path can replace the image
```

In the first two cases the rebuild is triggered by a metadata comparison; in the third, by an unreadable registered image.

**Cause.** The v47 patch 1 drift detector compares the currently-registered WinRE's DISM servicing metadata (`Version` + `SPBuild`) against the state file's `DeployedWinREMetadata` anchor. Three conditions force a rebuild:

1. **The state file has no anchor.** This is the case for every v46-or-earlier state file. The absence forces a rebuild on the first v47 run so that the anchor is written. After the first successful v47 run, the state file carries the anchor and subsequent runs evaluate against it. The rebuild is a one-time cost of the v46 → v47 migration.
2. **The anchor exists but does not match the current registered metadata.** This is the drift case: Windows Update serviced the registered WinRE, changing its `Version` or `SPBuild`. The detector forces a rebuild to bring the deployed WIM back into agreement with the current registered image. This is the intended behavior — Microsoft documents that an LCU bumps `SPBuild` while the base `Version` may remain unchanged, so both are compared.
3. **The registered metadata is unreadable.** `Get-WimServicingMetadata` failed on the registered WIM. This is a defensive force-rebuild: a valid-looking state file could otherwise let the script take the fast path over an unreadable registered image, which the repair path would then be unable to replace. The rebuild runs so the repair path can replace the image.

**What this replaces.** The v46 WIM-hash-as-rebuild-trigger is retired. Under v46, the fast path compared the deployed WIM's hash at the registered location against the state file's `CurrentImageHash`. A WIM recompression by an external tool changed the hash without changing the semantic desired state, producing a spurious rebuild. The v47 metadata comparison is semantically tighter: it compares the properties that actually indicate a servicing change, not the bytes.

**The tradeoff.** Microsoft documents that a Dynamic Update may change the contents of a serviced WinRE image without changing either `Version` or `SPBuild`. A DU delivered in that manner will not trigger a rebuild on its own. The `WIM_READY` checkpoint layer catches it via source-content-hash binding — an in-flight rebuild is protected because its staged WIM is bound to the source bytes at preparation time — but a completed prior deployment with no in-flight checkpoint will not be flagged. This is the metadata-neutral DU residual; see [CHANGELOG.md](../CHANGELOG.md) under the v47 patch 1 entry.

**Resolution.**

1. **If the log shows `State has no DeployedWinREMetadata anchor`,** nothing needs to be done. This is the expected first-v47-run behavior. The rebuild writes the anchor, and subsequent runs take the fast path unless the metadata changes.

2. **If the log shows `Registered WinRE metadata changed from <old> to <new>`,** the registered WinRE was serviced by Windows Update between the last v47 run and this one. The rebuild is the correct response; no operator action is needed. If the metadata comparison fires on every run — the rebuild happens, the anchor is updated, and the next run's comparison fires again with a new pair of values — investigate whether something on the machine is repeatedly re-servicing the registered WinRE. This is unusual and warrants a bug report.

3. **If the log shows `Registered WinRE metadata could not be read`,** the registered image is unreadable. The rebuild runs to replace it. If the same message fires on the next run, the registered image is persistently unreadable and the machine is not converging — investigate the registered recovery partition's storage state. `Test-WinRE.ps1` Option 1's Build numbers block reports what the harness can see of the registered image; a `(none present at C:\Recovery\WindowsRE\winre.wim)` there plus the production log's persistent unreadable message indicates a real storage problem.

**Field status.** The rebuild-because-of-a-changed-anchor branch and the rebuild-because-of-an-unreadable-registered-image branch have not been exercised in the field. The ASUS PRIME H510M-D v47 field run took the rebuild via the DSI-mismatch branch (state file was stale from v46, so the metadata comparison was subsumed by the DSI mismatch and did not fire). If you see either branch on a machine, please capture the full log and file a bug per the [Reporting a bug](#reporting-a-bug) section.

## The base-WIM copy-integrity check rejected the candidate (v47 patch 2)

**Symptom.** The run exits with code 2 (`EXIT_WARNING`) after Step 2, before mount. No WIM was mounted, no partition was touched, WinRE was not disabled. The state file is unchanged (or absent).

**Log signature.** One of:

```
[ERROR] Base WIM copy hash mismatch: source=<source-hash>, copied=<copied-hash> - rejecting candidate
```

or

```
[ERROR] Base WIM copy is unreadable after Copy-Item - rejecting candidate
```

Followed by removal of `base.wim`, a checkpoint reset to Step 2, and exit code 2.

**Cause.** The copy-integrity check added in v47 patch 2 verifies that the bytes copied to `WorkDir\base.wim` match the selected source's SHA256. A mismatch means the copy failed partway, or the source was replaced by the OS between the hash and the copy. The check exists because the Step 3 and Step 4 checkpoints bind to the source hash; without it, a checkpoint could record a hash that does not describe the bytes that actually entered servicing.

**Resolution.**

1. Re-run `WinRE.ps1`. The checkpoint is at Step 2 and `base.wim` was removed, so the next run re-acquires the source from the selection chain.
2. If the mismatch recurs, investigate the source. A registered-WIM source that changes during acquisition is the same class of race as the pre-`/disable` race detector catches later; see "The pre-`/disable` race detector fired" above.
3. If the source was the LKG, verify its SHA256 manually against `state.CurrentImageHash`.

**Field status.** This check has not been exercised in the field.

## The checkpoint validator invalidated a legacy or drifted checkpoint (v47 patch 2)

**Symptom.** A checkpoint file was present at the start of the run, but the run took the full-update path from Step 1 or Step 2 anyway. The state file is unchanged.

**Log signature.** One of:

```
[WARN] Checkpoint step N has no recorded source identity (legacy or GitHub-sourced checkpoint); invalidating to rebuild from a known source
```

```
[WARN] Checkpoint step N source identity <hash> does not match the currently-selected source <hash> (<reason>); invalidating to rebuild
```

```
[WARN] Checkpoint step N source identity <hash> cannot be re-validated against the current selection (no selected source, or GitHub cold-start has no on-disk hash); invalidating to rebuild
```

Followed by removal of the checkpoint file and a re-read returning Step 0.

**Cause.** The v47 patch 2 checkpoint validator calls `Select-BaseWinRESource` on the live inputs and requires the currently-selected source hash to equal the checkpoint's recorded source hash. Any of three conditions triggers invalidation: the checkpoint is a v47 patch 1 Step 3 checkpoint carrying no source hash; the checkpoint was prepared from a GitHub cold-start (no on-disk source to bind); or the source the current selection rules would choose now has a different hash than the checkpoint recorded.

**Resolution.** Automatic. The run restarts from Step 1 against the current source. No operator action is required unless the invalidation fires repeatedly, which indicates the source is changing during preparation; in that case see "The pre-`/disable` race detector fired" above.

**Field status.** This path has not been exercised in the field.

## The source-selection helper could not use a source (v47 patch 2)

**Symptom.** Two distinct diagnostics, both emitted by `Select-BaseWinRESource` during Step 2 or during the checkpoint validator. Neither is an abort on its own; the run continues with the next source in the preference order.

**Log signature A -- registered WIM present but unreadable:**

```
[WARN] Registered WinRE candidate is present at <path> but its servicing metadata could not be read; treating as not usable
```

**Log signature B -- WIM found at a location that is not the registered location:**

```
[WARN] A WIM was discovered at <path> but not at the registered location; not treating it as a registered source
```

**Cause.** Signature A: `Get-WimServicingMetadata` failed on the registered WIM even though `Test-Path` returned true. The registered image may be corrupt, partially written, or held open by another process. Signature B: a WIM was discovered by the loose fallback-discovery path at a location that is not the reagentc-registered one. Under v47 such a WIM is deliberately excluded from source selection.

**Resolution.**

1. Run `Test-WinRE.ps1` Option 1 and check the "Build numbers" block. If the Active WIM build reads `unknown (active WIM not locatable)`, the registered image is corrupt or unreadable.
2. If signature A recurs on a machine whose registered WIM is expected to be valid, investigate the registered recovery partition's storage state; the same investigation applies as for the `Registered WinRE metadata could not be read - forcing rebuild` production message.
3. If signature B appears, the source selection is working as designed; the loose WIM is not a source-selection candidate under v47. A machine that later needs a rebuild will source from the LKG or the GitHub cold-start.

**Field status.** Neither path has been exercised in the field.

## The OS-fallback missing-WIM guard forced a rebuild (v47 patch 2)

**Symptom.** The run takes the full-update path instead of the enable-only path (or instead of the fast path) on a machine whose WinRE is registered via OS-fallback. This is the guard firing correctly.

**Log signature.**

```
[WARN] WinRE is registered via OS-fallback (location: <location>) but its winre.wim could not be read at that location (status=<status>) - forcing rebuild
```

**Cause.** Under v47 patch 2, the OS-fallback missing-WIM guard no longer requires WinRE to be `Enabled`. When the active route resolves to the OS partition but no readable WIM exists at the registered location, the machine must rebuild. Without the guard, a machine with WinRE `Disabled` and a matching state file could take the full-update path with `$needInject = $false`, and `$imageToCheck` could fall back to a loose WIM at `C:\Windows\System32\Recovery\winre.wim`, bypassing the strip and injection pipeline entirely.

**Resolution.**

1. If the run subsequently completes successfully (`Operating mode: DEDICATED` or OS-FALLBACK, exit 0), nothing needs to be done. The guard fired, the rebuild ran, the machine is healthy.
2. If the run exits with code 2 because the rebuild deferred, follow the corresponding deferral section above.
3. If the registered WIM is consistently unreadable at the OS-fallback location, investigate `C:\Recovery\WindowsRE\winre.wim` directly: the file may be corrupt, ACL-denied, or missing. The harness Option 1 "Target recovery partition state" block reports what the harness can see.

**Field status.** This guard is a v47 patch 2 code-review hardening. It has not been exercised in the field.

## The destructive replacement was deferred before partition deletion (v45 patch 1; v46 patch 2 and v47 patch 1 added reasons)

**Symptom.** The run exits with code 2 (`EXIT_WARNING`) and the machine is unchanged: the old recovery partition is still present, no partition was deleted, and the run did not attempt OS-fallback. The deferral is protective: the destructive sequence was about to run, the read-only plan or the pre-shrink check determined that it could not safely complete, and the script stepped back before destroying anything. In one v46 patch 2 sub-case — the pre-deletion resolver guard — WinRE is left `Disabled` because `reagentc /disable` has already run; see "The active WinRE route could not be resolved to a partition" below. In one v47 patch 1 sub-case — the pre-`/disable` race-detector abort — C: may have been pre-shrunk and is restored before the return; see "The pre-`/disable` race detector fired" above. In every other reason, WinRE stays `Enabled` and registered to the old recovery partition.

**Log signature.** The last lines of the run before exit are:

```
[WARN] Dedicated replacement deferred before partition deletion (<Reason>). The existing WinRE route was preserved; not attempting OS-fallback.
[WARN] Recorded retry-suppressing deferral for DesiredStateId <id>; next run will verify the existing route before skipping identical retries. Delete C:\Recovery\OEM\winre_state.json and C:\Recovery\OEM\winre_partition_deferred.json to force a retry.
```

The second line appears only when the deferral is retry-suppressible; the first appears for every reason.

The most common `<Reason>` values are the following. Each has a distinct resolution. [exit-codes.md](exit-codes.md) carries the full list, including the internal failure reasons (`partition geometry unavailable`, `WinRE disable failed before deletion`, `WinRE disable verification failed before deletion`, `active WinRE location could not be resolved`, the two `recovery partition deletion failed` variants, and `registered source changed before disable`); those indicate storage-level, OS-level, or Windows-Update-driven conditions rather than operator-actionable constraints, and are diagnosable from the surrounding log lines.

- **`Dedicated recovery partition plan rejected: <specific reason>. No partition or WinRE changes were made.`** — The read-only geometry plan rejected the layout. The `RetrySuppressible` flag is not set; the marker is not written. The nested `<specific reason>` is one of thirteen: the partition inventory contains entries from another disk; another partition overlaps the OS partition geometry; the OS partition's supported-size bounds are unavailable; the requested recovery bucket size is invalid; the requested recovery bucket size exceeds the 2 GiB safety ceiling; the OS partition's geometry is inconsistent with the disk size; a recovery-typed partition exceeds the 2 GiB safety ceiling; a recovery-typed partition overlaps the OS partition geometry; a recovery-typed partition precedes the OS partition; partition extents overlap or are not ordered consistently; a recovery-typed partition is separated from C: by a non-recovery partition; the planned OS partition size would be zero or negative; or the aligned managed extent end precedes the OS partition start.
- **`Pre-shrink free-space check could not read the C: volume (Get-Volume -DriveLetter C returned nothing). Refusing to shrink C: without verifying the 3 GiB reserve is preserved. No partition or WinRE changes were made. The read failure may be transient, so this deferral is not retry-suppressed.`** — Fail-closed C: volume-read check. `RetrySuppressible = $false`; the marker is not written; the next run retries naturally.
- **`Pre-shrink free-space check failed: shrinking C: by <n> MiB would leave only <m> GiB free, below the 3 GiB minimum. …`** — The measured projected free space on C: after the planned shrink would fall below 3 GiB. `RetrySuppressible = $true`; the marker is written.
- **`Pre-destructive shrink failed after all retries. Existing WinRE registration and recovery partitions remain intact; deferring without OS-fallback.`** — All three shrink attempts (immediate, sleep-10s, defrag) failed. `RetrySuppressible = $true`; the marker is written.
- **`OS partition did not land at the planned size; preserving the old recovery route and deferring`** — The shrink returned success but the post-resize verification failed. `RetrySuppressible = $true`; the marker is written.
- **`Resize rounding leaves only <n> MiB for a <m> MiB bucket; preserving the old route and deferring`** — The actual post-resize geometry leaves less space than the plan's bucket needs. `RetrySuppressible = $true`; the marker is written.
- **`WinRE is Enabled but its registered location (<location>) could not be resolved to a partition. The delete-last ordering cannot protect the active partition, and route restoration cannot be attempted if a later deletion fails. Refusing to begin the destructive sequence. No partition or WinRE changes were made.`** (v46 patch 2) — The active WinRE route could not be resolved to a partition. `Reason = "active WinRE location could not be resolved"`. Delete-last ordering and route restoration both depend on knowing which partition is active; without it, no partition is protected and a mid-loop failure could leave the machine with no working recovery route. The guard fires **after** `reagentc /disable` has already run, so the machine is left with WinRE `Disabled` and the old recovery partition intact. `RetrySuppressible = $false`; the marker is not written. See "The active WinRE route could not be resolved to a partition" below.
- **`Registered WinRE source changed during candidate preparation - aborting before /disable. Restoring C: to its captured size; no partitions have been deleted.`** (v47 patch 1) — The pre-`/disable` race detector fired at the `Ensure-AdequateRecoveryPartition` site. `Reason = "registered source changed before disable"`. The abort happens after the pre-shrink but before any partition is deleted, so C: is restored to its captured size and the old WinRE route is intact. `RetrySuppressible = $false`; the marker is not written. See "The pre-`/disable` race detector fired" above.

**Cause.** The v45 patch 1 pipeline runs the risky operation — the shrink — in the reversible window, before `reagentc /disable` and before any partition deletion. The read-only geometry plan checks the layout before any change. Any of the conditions above stops the run before the destructive sequence begins. Except for the v46 patch 2 resolver deferral and the v47 patch 1 race-detector abort, the old recovery route is left intact.

The most common causes:

- **Insufficient free space on C:.** The shrink would take C: below the 3 GiB reserve. Free space on C: and re-run.
- **Transient volume-read failure.** `Get-Volume -DriveLetter C` returned nothing. This is rare and usually transient; re-run.
- **Blocking layout.** A non-recovery partition after C:, a non-contiguous recovery partition, or a recovery-typed partition preceding C:. The disk layout requires manual review.
- **Oversized recovery partition.** A recovery-typed partition over 2 GiB is present, and the plan refuses to reuse or delete it. Preserve it or use the harness Option 1 to inspect it.
- **Shrink failure.** C: cannot be shrunk by the required amount even after the sleep-and-defrag retries. Free space on C:, defragment the drive, or reduce the required bucket (which depends on the WIM size).
- **Unresolvable active route (v46 patch 2).** WinRE is `Enabled` but `reagentc /info` reports a Location that cannot be resolved to a partition on the machine. This is rare; it usually means the registration is stale or the reported location format is not one the resolver understands. See "The active WinRE route could not be resolved to a partition" below.
- **Registered WinRE source changed (v47 patch 1).** The registered WinRE's location, version, or WIM hash changed during candidate preparation — typically because Windows Update serviced it. See "The pre-`/disable` race detector fired" above.

**The retry-suppressing marker.** When the deferral is retry-suppressible, the main flow writes a sidecar at `C:\Recovery\OEM\winre_partition_deferred.json` containing the current `DesiredStateId` and a `Since` timestamp. On subsequent runs, the marker is honored only if:

- The old route is still verified functional (WinRE `Enabled`, registered WIM readable, and the active location is either a type-coded recovery partition on the OS disk or OS-fallback on a `FullyDecrypted` C:).
- The fast path would not fire — that is, the machine has not converged on its own.

If both hold, the run exits `EXIT_WARNING` without repeating the same pre-shrink retries. If the fast path would fire (the machine has converged, no rebuild required), the marker is cleared and the run falls through to the fast path, exiting `EXIT_SUCCESS`. If the old route is not functional, the marker is cleared and normal repair evaluation continues. A `DesiredStateId` mismatch also clears the marker on read.

**Resolution.**

1. **Read the `<Reason>` in the log.** Each reason maps to a distinct resolution.
2. **For insufficient free space:** free at least the deficit on C: (the log line records the current free, the planned shrink, and the projected post-shrink free). Delete unnecessary files, empty the Recycle Bin, or move data to another drive. The bucket size depends on the WIM size + 280 MiB, rounded up to the next 100 MiB boundary, minimum 1000 MiB.
3. **For blocking layout:** run `scripts\Test-WinRE.ps1` Option 1 to inspect the disk layout. A non-recovery partition between C: and the disk end, or a non-contiguous recovery partition, requires manual review before the script can proceed.
4. **For an oversized recovery-typed partition:** the partition is being preserved for operator review because it may be an OEM factory recovery volume. Run the harness Option 1 to identify it, and either move it, label it away from `Recovery`/`WINRE`, or leave it as clutter — the script will not delete a recovery-typed partition over 2 GiB.
5. **For a transient volume-read failure:** re-run. The deferral is not retry-suppressed, so the next run attempts the pre-shrink again.
6. **For a genuine shrink failure:** free space on C:, run `defrag C: /x` manually from an elevated shell, and re-run.
7. **For an unresolvable active route (v46 patch 2):** see "The active WinRE route could not be resolved to a partition" below.
8. **For a registered-source-changed abort (v47 patch 1):** wait for any pending Windows Update to settle, then re-run. See "The pre-`/disable` race detector fired" above.
9. **After resolving the underlying cause, delete both files to force a retry:**

   ```powershell
   Remove-Item "$env:SystemDrive\Recovery\OEM\winre_partition_deferred.json" -Force
   Remove-Item "$env:SystemDrive\Recovery\OEM\winre_state.json" -Force
   ```

   The marker deletion clears the suppression record; the state-file deletion clears the recorded deployment identity. Both are safe: the next run treats the state as absent and re-runs the full-update path. Deleting only the state file is not sufficient to clear the marker cleanly — the marker is keyed by `DesiredStateId` and the next run would compute the same DSI, so the marker would still suppress the retry unless the state file's absence forces a rebuild that ultimately converges.

   If you want to force a retry *without* losing the recorded state, delete only the marker file. The next run will re-attempt the pre-shrink; if it succeeds, the run proceeds; if it fails again, the marker is re-written with a fresh `Since` timestamp.

10. **If the marker is present on a later run and you want to know whether it will be honored,** check the log for the line `Dedicated recovery creation was deferred for this DesiredStateId on <Since>. Existing WinRE route is Enabled and its registered WIM is readable; not repeating the same pre-shrink retries (<staged note>).` — that line confirms the marker was honored.

### The active WinRE route could not be resolved to a partition (v46 patch 2)

**Symptom.** The run exits with code 2 (`EXIT_WARNING`) and the log shows the v46 patch 2 pre-deletion resolver guard firing. The old recovery partition is intact — no partition was deleted — but the machine is left with WinRE `Disabled`, because `reagentc /disable` has already run by the time this guard fires.

**Log signature.**

```
[INFO] Disabling WinRE before partition recreation
[INFO] reagentc /disable: exit=0, output=REAGENTC.EXE: Operation Successful.
[INFO] WinRE disable verified
[INFO] Pre-deletion inventory:
[ERROR] WinRE is Enabled but its registered location (<location>) could not be resolved to a partition. The delete-last ordering cannot protect the active partition, and route restoration cannot be attempted if a later deletion fails. Refusing to begin the destructive sequence. No partition or WinRE changes were made.
[WARN] Dedicated replacement deferred before partition deletion (active WinRE location could not be resolved). The existing WinRE route was preserved; not attempting OS-fallback.
```

Note the ordering: the guard fires **after** the `/disable` block, not before it. The machine is left with WinRE `Disabled` and the old recovery partition intact and unregistered.

**Cause.** `Get-WinREState` returned `Status = Enabled` but `Resolve-WinRELocationToPartition` could not map the registered location to a partition. Delete-last ordering depends on identifying the active partition so the previous route's target survives a mid-loop failure; route restoration depends on knowing which partition to re-enable. Without either, the script refuses to begin a destructive sequence that could leave the machine with no working recovery route. The guard fires after `/disable` because the resolver is only needed once the script is about to touch partitions.

Causes of an unresolvable location:

- **The Location string format is not one the resolver understands.** `Resolve-WinRELocationToPartition` handles `\\?\GLOBALROOT\device\harddisk<X>\partition<Y>\...` and `\\?\Volume{<GUID>}\...`. A Location that matches neither form returns `$null`.
- **The referenced partition no longer exists.** The registration is stale — the partition it names was deleted by some other tool, or a Windows Update changed the disk layout.
- **The referenced disk or volume is offline or unreadable.** Rare; usually transient.
- **`Get-Partition`/`Get-Volume` failed on the referenced object.** Also rare.

**Field status.** This guard is a v46 patch 2 code-review hardening. It has not been exercised in the field — no logged run has reached it. If you see this signature, please capture the full log and file a bug per the [Reporting a bug](#reporting-a-bug) section: the project wants field data on which of the four causes above actually fires.

**Resolution.**

1. **Inspect the current registration.**

   ```powershell
   reagentc /info
   ```

   Note the `Windows RE location:` line. If it is empty or absent, the registration is already broken.

2. **Re-enable WinRE against the existing recovery partition** (the partition was not deleted). From an elevated PowerShell:

   ```powershell
   # Identify the type-coded recovery partition on the OS disk.
   Get-Partition | Where-Object {
       $_.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' -or $_.MbrType -eq 0x27
   } | Select-Object DiskNumber, PartitionNumber, Size, DriveLetter

   # Re-register and enable against the correct disk/partition.
   reagentc /setreimage /path \\?\GLOBALROOT\device\harddisk<X>\partition<Y>\Recovery\WindowsRE
   reagentc /enable
   ```

   Replace `<X>` and `<Y>` with the disk and partition from the first command. If the partition carries a `Recovery`-typed partition but a `winre.wim` no longer exists at `\Recovery\WindowsRE\winre.wim`, the copy at `C:\Recovery\WindowsRE\winre.wim` (if present) is a source the script would use on the next full-update pass.

3. **If `/enable` succeeds**, delete the state file to reset the loop so the next run does not see a stale DSI:

   ```powershell
   Remove-Item "$env:SystemDrive\Recovery\OEM\winre_state.json" -Force -ErrorAction SilentlyContinue
   Remove-Item "$env:SystemDrive\Recovery\OEM\winre_partition_deferred.json" -Force -ErrorAction SilentlyContinue
   ```

   Then re-run `WinRE.ps1`. The next run re-registers the correct route, then — depending on the plan — either converges on the existing partition or retries the destructive sequence.

4. **If the location string format is the cause**, run `scripts\Test-WinRE.ps1` Option 1. The parser self-test checks the reagentc location regex; a `[FAIL]` there confirms the format changed and `Resolve-WinRELocationToPartition` needs to be extended. File a bug with the raw `reagentc /info` output.

5. **If no type-coded recovery partition exists on the OS disk**, the machine is in the state described in ["The machine has no recovery partition and WinRE is disabled"](#the-machine-has-no-recovery-partition-and-winre-is-disabled). Follow that recovery procedure.

**Do not re-run the script without re-registering WinRE first.** The next run will see WinRE `Disabled` and may take the enable-only or full-update path; the enable-only path cannot succeed without a partition to register against, and the full-update path may attempt the destructive sequence again and hit the same guard.

## The script exited with a rename error (concurrent instance)

**This failure mode was substantially reduced by v44 patch 4.** Before patch 4, the script had no startup lock: two concurrent `WinRE.ps1` processes could collide at Step 2 and the second one would exit with `EXIT_FATAL` (code 3) on a rename error. Patch 4 adds an exclusive file lock at `C:\ProgramData\OEM\Logs\WinREManager.lock`. As of patch 4, the primary concurrent-instance failure shape is a fast exit with `EXIT_WARNING` (code 2), not a fatal rename error. The rename error is now reachable only in the narrow non-contention lock-failure case described below.

**Symptom (v44 patch 4 and later — the common case).** A second `WinRE.ps1` process is launched while another instance is already running. The second process exits within seconds with code 2 (`EXIT_WARNING`). No partition was touched, no WIM was deployed, no state file was read or written, no checkpoint was left behind.

**Log signature (v44 patch 4 and later — the common case).**

```
[WARN] Another WinRE Manager instance is already running (program lock file is exclusively held). Exiting without making any changes. This is not a deployment failure - the other instance is doing the work and will complete on its own. If you need to run manually, wait for the other instance to finish, or run scripts\Test-WinRE.ps1 for a read-only diagnostic that is safe to run concurrently.
```

The second process exits before the Audit Mode guard, before the hardware check, and before any state-modifying action.

**Cause.** The program lock at `C:\ProgramData\OEM\Logs\WinREManager.lock` is held exclusively by the first instance via `[System.IO.File]::Open` with `FileShare.None`. The Windows kernel refuses the second open. This is the intended behavior.

The most common trigger is a **manual invocation** of `WinRE.ps1` (from an interactive PowerShell prompt, an RMM tool's "run now" button, or an Intune remediation script) overlapping with a scheduled run. The scheduled task's `MultipleInstancesPolicy = IgnoreNew` prevents two *scheduled* runs from overlapping, but has no effect on processes launched any other way — the file lock closes that gap.

**Resolution (v44 patch 4 and later — the common case).**

1. **Do nothing.** This is not a failure. The other instance is doing the work and will complete on its own. The log on the second instance is informational, not diagnostic.
2. If your orchestration treats exit code 2 as a soft failure and re-queues the remediation, be aware that the re-queue will also exit 2 until the first instance completes. Wait, or disable the scheduled task before re-running manually:

   ```powershell
   schtasks /Change /TN "WinRE Manager" /DISABLE
   schtasks /Change /TN "WinRE Manager Weekly" /DISABLE
   # … wait for the first instance to complete, then run manually …
   schtasks /Change /TN "WinRE Manager" /ENABLE
   schtasks /Change /TN "WinRE Manager Weekly" /ENABLE
   ```

3. If you need a read-only diagnostic that is safe to run concurrently with any number of other processes, use `scripts\Test-WinRE.ps1`. The harness does not acquire the lock.

**The lock file persists on disk.** `C:\ProgramData\OEM\Logs\WinREManager.lock` remains between runs and is empty by design — nothing is ever written to it. **Its existence does not indicate a running instance.** Only an active exclusive handle on the file blocks a second instance. Do not delete the lock file to "free" a stuck process; deletion has no effect on the handle and the file will simply be recreated. If you need to know whether an instance is currently running, check Task Scheduler for the scheduled task's "Last Run Result" column and look for a live `powershell.exe` process, not the lock file.

**Symptom (v44 patch 4 and later — the narrow non-contention case).** The script exits with code 3 (`EXIT_FATAL`) on the rename error, because the lock could not be acquired for a reason other than contention. On the same run, an earlier line in the log records the lock failure.

**Log signature (v44 patch 4 and later — the narrow non-contention case).**

```
[WARN] Could not set up program lock at C:\ProgramData\OEM\Logs\WinREManager.lock : <error> - proceeding without single-instance protection; concurrent runs may collide
```

followed later in the same run by:

```
[ERROR] FATAL ERROR: Cannot rename because item at '<workspace>\winre.wim' does not exist.
[ERROR] Stack: at <ScriptBlock>, ...
```

**Cause (the narrow non-contention case).** The lock acquisition failed for a non-contention reason — a permission error on `C:\ProgramData\OEM\Logs\`, a missing `Logs` directory that could not be created, or a transient filesystem issue — and the script proceeded unprotected by design. While it was running unprotected, a second `WinRE.ps1` instance also started and reached Step 2 first, renaming `winre.wim` to `base.wim` before the first instance could do the same. The first instance's rename call then failed because the source file no longer existed.

**Resolution (the narrow non-contention case).**

1. **Investigate the lock failure first.** Check permissions on `C:\ProgramData\OEM\Logs\`. Confirm the directory exists. Confirm `SYSTEM` (or the account that ran the script) has write permission. A common cause is an antivirus product or a GPO locking the directory.
2. **Confirm no other instance is currently running.** Open Task Scheduler, find `WinRE Manager` (and `WinRE Manager Weekly`), and check the "Last Run Result" column. If either task shows "Running", wait for it to complete. From the command line:

   ```powershell
   Get-ScheduledTask -TaskName "WinRE Manager","WinRE Manager Weekly" | Get-ScheduledTaskInfo | Select-Object TaskName, LastRunTime, LastTaskResult, NextRunTime
   ```

   A `LastTaskResult` of `267009` (0x41301) means the task is currently running.
3. **Wait for the other instance to complete.** A healthy fast-path run finishes in a few seconds of CIM/PnP enumeration; a full-update run can take 3–5 minutes, and a run that has to download a fresh base WIM can take longer.
4. **Re-run `WinRE.ps1` if the machine still needs attention.** There is no cleanup required — the failed process left nothing behind.
5. **Fix the lock-acquisition condition** so the next run is protected. If the condition cannot be fixed (e.g. the log directory is on a filesystem that does not support `FileShare.None`), consider temporarily disabling the scheduled task while manual invocations run, and rely on the harness (`scripts\Test-WinRE.ps1`) for read-only diagnostics.

**Not to be confused with a base WIM download failure.** The ["Base WIM download fails"](#base-wim-download-fails) section covers a different failure at the same step: the download itself could not complete. The rename error above is specific to concurrent access — the file was present, and was renamed by another process — and its resolution is to serialize runs (or fix the lock), not to check the network.

## The manifest fetch failed and the machine is offline

**Symptom.** The machine is offline (no network, DNS failure, proxy blocking `gist.github.com`, or a total loss of connectivity), and the run completes with one of three outcomes:

- Exit code 2 (`EXIT_WARNING`) with the fast path having fired successfully. The machine is unchanged and healthy.
- Exit code 2 (`EXIT_WARNING`) with the state file indicating a full update is needed and the offline fallback deferring.
- Exit code 3 (`EXIT_FATAL`) with no state file at all.

This section covers all three. The first is a **degraded-success** — do not treat it as a failure. The second is a **deferral** — no operator action needed; the next scheduled run with network completes the work. The third is a **fatal** — the machine has no state file and needs network for its first deployment.

**Log signature (Case 1 — fast path fired).** The manifest fetch attempt lines, then the offline fallback engage line, then the four "skipping" lines, then the fast-path markers:

```
[WARN] Driver manifest fetch attempt 1 failed: <error>
[WARN] Driver manifest fetch attempt 2 failed: <error>
[WARN] Driver manifest unavailable - taking the offline fallback path using the state file's stored DesiredStateId (state file LastUpdated=yyyy-MM-dd HH:mm:ss). The run will exit EXIT_WARNING. …
[INFO] Offline fallback: skipping OEM pack resolution (network unavailable)
[INFO] Offline fallback: skipping VMD detection (manifest unavailable)
[INFO] Offline fallback: skipping required-driver resolution
[INFO] Offline fallback: using state file's stored DesiredStateId <id>
[INFO] Checkpoint step: 0
[INFO] WinRE status: Enabled, Location: <location>
[INFO] State file accepted (DesiredStateId match)
[INFO] Assigned temporary drive letter Z: (disk 4, part 4)
[INFO] Removing temporary drive letter Z: (assigned for inspection)
[INFO] Operating mode: DEDICATED (WinRE on dedicated recovery partition)
[INFO] Released program lock
```

Exit code 2. Total runtime under 90 seconds. The machine is unchanged.

**Log signature (Case 2 — offline, state file indicates full update needed).**

```
[WARN] Driver manifest fetch attempt 1 failed: <error>
[WARN] Driver manifest fetch attempt 2 failed: <error>
[WARN] Driver manifest unavailable - taking the offline fallback path using the state file's stored DesiredStateId (state file LastUpdated=yyyy-MM-dd HH:mm:ss). …
[INFO] Offline fallback: skipping OEM pack resolution (network unavailable)
[INFO] Offline fallback: skipping VMD detection (manifest unavailable)
[INFO] Offline fallback: skipping required-driver resolution
[INFO] Offline fallback: using state file's stored DesiredStateId <id>
… classifier runs, needInject determination fires …
[WARN] Offline fallback: the machine requires a full update (state file is stale or unhealthy), but the driver manifest is unavailable. Cannot proceed without a live manifest. Will retry on the next scheduled run when the network is available.
[INFO] Released program lock
```

Exit code 2. The machine is unchanged. No WIM deployed, no partition touched, WinRE not disabled, no state file written or modified.

**Log signature (Case 3 — offline, no state file).**

```
[WARN] Driver manifest fetch attempt 1 failed: <error>
[WARN] Driver manifest fetch attempt 2 failed: <error>
[ERROR] Driver manifest unavailable and no state file exists - a live manifest is required for the first deployment on this machine.
[ERROR] FATAL ERROR: Driver manifest unavailable and no state file exists. First deployment requires a live manifest.
[ERROR] Stack: at <ScriptBlock>, ...
```

Exit code 3. The machine is unchanged. No WIM deployed, no partition touched.

**Cause.** All three cases share the same root cause: the driver manifest fetch failed after its retry budget, and there was no network to fall back to. What distinguishes them is the state file's contents:

- **Case 1** — the state file exists, its `DesiredStateId` is available, and the local safety checks pass under v47: WinRE is `Enabled`, exactly one **type-coded** recovery partition is on the OS disk (or `UsedOSFallback = $true` with the active location on the OS partition), and the registered image's DISM servicing metadata matches the state file's `DeployedWinREMetadata` anchor with no force-upgrade or driver-version change. The script trusts the stored `DesiredStateId` and takes the fast path.
- **Case 2** — the state file exists and its `DesiredStateId` is available, but the local safety checks do not pass: the registered metadata no longer matches the anchor, or a force-upgrade was detected, or the stored driver set version differs from the expected one, or the state file is missing the v47 `DeployedWinREMetadata` anchor (a v46-or-earlier state file), or the state file indicates a full update is needed for some other locally-detectable reason. A full update requires the live manifest to resolve the driver set, which is not available. The script defers.
- **Case 3** — there is no state file at all, so the script cannot compute a `DesiredStateId` to work with. The live manifest is required for the first deployment on a machine.

**The v46 → v47 transition on offline machines.** Under v47, a v46-or-earlier state file lacks the `DeployedWinREMetadata` anchor. Its absence forces `$needInject = $true` regardless of network state, so Case 2 is what fires on the first v47 run if that run is offline. From the second v47 run onward — after one successful online run has written the anchor — the offline fast path can fire normally. The one-time cost of the v47 migration on offline machines is therefore: the first scheduled v47 run must happen while the machine can reach the driver manifest.

**Resolution (Case 1 — nothing to do).** The machine is healthy. The exit code 2 is a degraded-success signal from the fact that the fast path was taken without a live manifest fetch. The next scheduled run with network performs a full manifest fetch and confirms there has been no hardware drift while offline.

**Resolution (Case 2 — nothing to do if the machine will regain network; investigate if it will not).** The machine is stale but not damaged. The next scheduled run with network will complete the work. If the machine is expected to be offline for a prolonged period and the deployment is stale, resolve the network issue (restore DNS, unblock the gist host, or point `$DriverManifestUrl` at an internal mirror per [deployment.md](deployment.md#hosting-your-own-maps)) and re-run.

**Resolution (Case 3 — restore network before the next run).** A first deployment requires the live manifest. On the next scheduled run with network, the script fetches the manifest, computes the initial `DesiredStateId`, and performs a full-update pass. If the machine is expected to be offline indefinitely, the deployment cannot complete; consider pre-staging the state file from a machine that has network by copying `C:\Recovery\OEM\winre_state.json` from a working machine of the same model — but note that the DSI is machine-specific and a copied state file may not match.

**Residual risk while offline.** The offline fallback trusts the state file's stored `DesiredStateId` without verifying that the machine's local hardware still matches the inputs that produced it. On a machine whose hardware changed while offline — a CPU swap, a BIOS update that flipped VMD, or a motherboard replacement that changed `Manufacturer` / `Model` / `MachineType` — the offline run could take the fast path with a stale DSI. The next successful manifest fetch detects the drift and forces a rebuild. A `LocalInputsId` field in the state file would close this; it is planned as its own version boundary. See [state-and-idempotency.md](state-and-idempotency.md) for the full discussion.

**Not to be confused with the Audit Mode or OS-fallback BitLocker deferrals.** All three exit with code 2 and leave the state file unchanged, but the log signature is distinct. The Audit Mode deferral logs `Deferring WinRE Manager: Windows is not in a normal-running state (Setup\State\ImageState=…)` and fires before the hardware check. The OS-fallback BitLocker deferral logs `OS-fallback deferred: C: could not be confirmed fully decrypted (Test-VolumeEncrypted=…)` and fires after the classifier runs. The offline deferral logs `Offline fallback: the machine requires a full update …` and fires before the full-update pipeline. A field engineer reading the log will see the difference immediately.

## OEM or VMD injection failed (Step 3 → Step 4 pipeline gate)

**Symptom.** The script exits with code 2 (`EXIT_WARNING`) and the machine is untouched: no partition work, no WIM deployment, no `reagentc` calls, and the state file is unchanged (or absent). The difference from the Audit Mode deferral is that the run got much further — the WIM was downloaded or copied to `WorkDir`, mounted, stripped (v47 patch 1), and an OEM or VMD injection attempt was made against it.

**Log signature.** The last lines of the run before exit:

```
[WARN] OEM extraction FAILED for <vendor>
```

or

```
[WARN] OEM injection failed - package INFs not found in image after injection
```

or

```
[WARN] VMD driver injection failed - VMD package INFs not found in image after injection
```

or (in the failure-branch form when the OEM or VMD download itself failed):

```
[WARN] OEM download failed
```

or

```
[WARN] VMD download failed for <name>: <message>
```

Followed by:

```
[WARN] Checkpoint NOT advanced to step 3 - image injection did not complete; next run will retry step 3
[WARN] Image injection did not complete. Stopping before Step 4 and before any deployment. The recovery partition and WinRE registration are unchanged. Next run will retry from step 2.
```

The pipeline then exits without running `dism /Export-Image`, without touching any partition, without disabling WinRE, and without writing a state file.

**Cause.** One of the driver-injection steps in Step 3 could not demonstrate success. The strip stage that precedes injection (v47 patch 1) has its own failure modes, documented under "The strip stage failed" above; once the strip succeeds, the recipe-injection step has these failure modes:

- The OEM pack download failed (network error, 404, hash mismatch on a manifest that carries a hash, or a zero-byte download that the length check rejected).
- The OEM pack extracted but produced zero INF files (the known Lenovo SCCM Package case, or a packaging error for Dell/HP).
- The OEM pack extracted and contained INF files, but `Add-WindowsDriver` produced no delta and no INF-basename match — the package's INFs are not present in the image after injection.
- A VMD driver download failed (same failure modes as the OEM download).
- A VMD driver archive extracted to a directory with zero INF files.
- A VMD `Add-WindowsDriver` produced no delta and no INF-basename match.

In every case, `$Script:ImageInjectionComplete` was set to `$false` and the pipeline gate stopped the run before Step 4.

As of v44 patch 7, the VMD extraction directory is cleared before each `7z x` invocation, so a stale INF from an earlier run can no longer satisfy the INF-basename cross-reference or the third-party-driver-count delta and mask a failed extraction. If the failure is a VMD injection failure and the log shows the fresh extraction happened (no stale-INF contamination warning), the extraction itself genuinely failed.

**Why the run stops.** A WIM with no OEM or VMD drivers is broken on hardware whose storage controller requires those drivers. On a VMD-based system the resulting WinRE cannot see the OS disk at all, and the deployed recovery environment is worse than useless — it is actively misleading. The v44 patch 1 gate prevents this class of broken deployment, where the earlier pipeline would have exported, deployed, and registered a non-functional WIM. The gate is a protective failure, not a degraded-success: the run stops before anything is committed.

**Resolution.**

1. **Read the log line above the failure.** The specific vendor, package name, or download URL is named. The most common causes are vendor-side (a moved download URL, a changed packaging format), network-side (a proxy blocking the vendor CDN), or manifest-side (a stale `driverUrl`).
2. **For an OEM pack failure**, re-run `scripts\Test-WinRE.ps1` and select Option 6 (HP), 7 (Dell), or 8 (Lenovo) depending on the vendor. The harness downloads and extracts the same pack the production script uses, against live sources, and reports the INF count. If the harness succeeds where production failed, the difference is likely transient (a network hiccup during the production run). If the harness also fails, the pack is genuinely broken or the map is stale.
3. **For a VMD driver failure**, select Option 9 in the harness. This exercises every VMD package the manifest resolves for the machine's CPU generation. A failure here means the manifest's `driverUrl` is stale or the archive format changed.
4. **If the failure is `Add-WindowsDriver produced no error output (silent rejection or no applicable drivers)`**, the package's INFs do not match any device on the image. This is the least common case and usually means the manifest is resolving a package intended for different hardware. Check the manifest entry's `match.cpuGenMin` / `cpuGenMax` against the machine's actual CPU generation. The harness's Option 1 diagnostic reports the generation and the VMD hardware presence.
5. **Fix the underlying cause** — update the manifest or map gist, correct the download URL, install a missing dependency (7-Zip, `curl-impersonate` for the Lenovo builder), or resolve the network/proxy problem.
6. **Re-run `WinRE.ps1`.** The checkpoint is already at step 2 and the `WorkDir` was cleaned by the gate (including the v44 patch 3 `base.wim` cleanup); the next run re-acquires the base WIM and re-runs injection from a clean image.

**What NOT to do.** Do not attempt to force the pipeline past the gate by editing the script. The gate is the mechanism that prevents a broken WIM from reaching the recovery partition. A machine in this state has a functional existing WinRE or a functional existing state file — whatever it had before the run is still in place. The cost of waiting is one pipeline run after the injection failure is resolved; the cost of bypassing the gate is a recovery environment that cannot see the OS disk.

**Not to be confused with the strip-failure abort (v47 patch 1) or the Audit Mode or OS-fallback BitLocker deferrals.** All exit with code 2 and leave the state file unchanged, but the log signature is distinct. The strip-failure abort reads `Strip stage failed - candidate rejected.` The injection-failure gate reads `Image injection did not complete. Stopping before Step 4 and before any deployment.` The Audit Mode deferral reads `Deferring WinRE Manager: Windows is not in a normal-running state`. The OS-fallback BitLocker deferral reads `OS-fallback deferred: C: could not be confirmed fully decrypted`. The strip stage runs between mount and injection; the injection gate runs after the strip succeeded. A field engineer reading the log will see the difference immediately.

## The OS-fallback route deferred because C: is encrypted

**Symptom.** The script chose the OS-fallback route — dedicated-partition creation failed and the script fell back to `C:\Recovery\WindowsRE` — and then exited with code 2 (`EXIT_WARNING`) without deploying the WIM. The machine is unchanged: no new WIM at `C:\Recovery\WindowsRE`, no `reagentc` call made, and the state file is unchanged (or absent).

**Log signature (simple form).**

```
[WARN] OS-fallback deferred: C: could not be confirmed fully decrypted (Test-VolumeEncrypted=<state>). reagentc will refuse to enable WinRE on an encrypted OS volume. The OS-fallback route requires C: to be FullyDecrypted. Actions that complete encryption, add a recovery-password protector, or enable protection do NOT satisfy this requirement. To resolve: complete decryption of C: (e.g. manage-bde -off C:) or wait for an in-progress decryption to finish, then re-run. The dedicated recovery-partition path has its own separate BitLocker policy and is not gated on C:. The script will not modify C:'s BitLocker state.
```

**The compound signature — post-deletion failure (v45 patch 1).** When the OS-fallback deferral is reached via a post-deletion destructive failure — the existing type-coded recovery partition was deleted, and a later step failed — the log shows the deletion first, then the failure, then the OS-fallback deferral in the same run. The most common post-deletion failure points under v45 patch 1 are `New-Partition` failure and `Format-Volume` failure. The corner is also reachable when the whole-layout assertion (`Assert-RecoveryPartitionLayout`), drive-letter availability, drive-letter assignment, in-place decryption of the new partition, the post-delete extension fallback, the post-delete geometry verification, the planned-extent-available re-check, or the delete loop itself fails and the previous route could not be restored. (The v45 reorder moved the shrink into the reversible window, so a shrink failure no longer deletes the old partition and no longer reaches this corner; see the ["The destructive replacement was deferred before partition deletion"](#the-destructive-replacement-was-deferred-before-partition-deletion-v45-patch-1-v46-patch-2-and-v47-patch-1-added-reasons) section above.) The full sequence for the post-deletion case is:

```
[INFO] Pre-deletion inventory:
[INFO]   Disk 0 Part 4: size 1000 MiB, label='Recovery', used=735.9 MiB, isWinRELocation=YES
…
[INFO] Confirmed deletion of partition 4 on disk 0
…
[WARN] New-Partition attempt 1 failed: …
[WARN] New-Partition attempt 2 failed: …
[WARN] New-Partition attempt 3 failed: …
[ERROR] New-Partition failed after 3 attempts
…
[WARN] ================================================================================
[WARN] Dedicated recovery partition creation failed after all attempts.
[WARN] Falling back to C:\Recovery\WindowsRE (OS-partition recovery location).
[WARN] This is NOT equivalent to a dedicated recovery partition.
[WARN] WinRE will function but with reduced resilience. Exit code will be 2.
[WARN] ================================================================================
…
[WARN] OS-fallback deferred: C: could not be confirmed fully decrypted (Test-VolumeEncrypted=True). …
```

or the analogous sequence for `Format-Volume`:

```
[ERROR] Format-Volume failed: …
[INFO] Removing orphan partition <disk>/<part> after Format-Volume failure (main path)
…
[WARN] ================================================================================
[WARN] Dedicated recovery partition creation failed after all attempts.
[WARN] Falling back to C:\Recovery\WindowsRE (OS-partition recovery location).
[WARN] This is NOT equivalent to a dedicated recovery partition.
[WARN] WinRE will function but with reduced resilience. Exit code will be 2.
[WARN] ================================================================================
```

followed by the OS-fallback deferral.

This compound signature means the machine is now in the **post-deletion residual corner**: the existing type-coded recovery partition has been deleted, and the OS-fallback route has refused because C: is encrypted. The machine ends this run with neither a dedicated recovery partition nor a working OS-fallback registration — the residual failure mode that the `[v44 patch 7]` and `[v45 patch 1]` CHANGELOG entries document. The v45 reorder narrowed the corner: only post-deletion failures now reach it, whereas v44 also reached it via shrink failures after deletion.

**This corner has not been exercised in the field.** No logged run has yet shown a destructive attempt that failed *after* deletion with C: encrypted. [testing.md](testing.md) documents the deliberate post-deletion failure test that will gate any future change to the destructive path. **If you see this signature on a machine, please capture the full log and file a bug per the [Reporting a bug](#reporting-a-bug) section — it is a case the project wants field data on.** Include the machine's end state (partition count, WinRE status, whether any working recovery route exists) and C:'s encryption state at the moment of the run.

**Why the script does not reinstate the pre-destructive C: guard.** The v44 patch 3 guard deferred every destructive replacement on every encrypted-C: machine, including the machines where the destructive attempt would have succeeded. The correct fix is a **post-failure** check in the post-deletion failure branches that handles the corner *after* the destructive attempt fails, not a pre-destructive veto. The guard's predicate — "is C: encrypted?" — cannot distinguish a destructive attempt that will succeed from one that will fail. See the `[v44 patch 7]` and `[v45 patch 1]` CHANGELOG entries for the full reasoning and the field evidence.

**Cause.** On the OS-fallback route the target volume *is* the OS volume. reagentc refuses to enable WinRE on an encrypted OS volume, always — this is a hard OS check, not something the script can work around. The gate exists to prevent the script from deploying a WIM it cannot register.

The `<state>` in the log line is the value returned by `Test-VolumeEncrypted -MountPoint "C:"` at the moment the gate fired. Because the gate only fires when the classifier did not return exactly `$false`, the value is either `True` (the classifier is confident C: is encrypted or not fully decrypted) or empty (`$null` — the classifier could not determine the state). Either way, the script treats the machine as not-ready for OS-fallback deployment and defers. The script never modifies C:'s BitLocker state.

**Why the script does not decrypt C:.** Decrypting the OS volume is hours of I/O, changes the recovery key relationship, and the OS volume is the user's data. Removing encryption from the OS volume as a side effect of a WinRE repair is not a change the script is authorised to make. The operator resolves the state.

**Resolution.** From an elevated PowerShell:

```powershell
manage-bde -status C:
```

Read the `Conversion Status:` line and act accordingly:

- **`Fully Encrypted` with `Protection On`** — the volume is fully encrypted and protection is armed. To use the OS-fallback route you must **decrypt C:**, because reagentc refuses to enable WinRE on an encrypted OS volume regardless of the protector state:

  ```powershell
  manage-bde -off C:
  ```

  Wait for `Conversion Status:` to read `Fully Decrypted`, then re-run `WinRE.ps1`. On a 256 GB SSD this typically takes 30–90 minutes.

  Note that **adding a key protector or arming protection does not resolve this state** — those actions make C: *more* protected, not less. The OS-fallback route requires `FullyDecrypted`.

  If decrypting C: is not an option, the alternative is the **dedicated-partition route**, which does not depend on C:'s BitLocker state. The script already attempted the dedicated-partition route and failed, which is why it fell back to OS-fallback. The way to use the dedicated-partition route is to resolve whatever caused the destructive failure (insufficient space on C:, a layout problem, etc.) and free the constraint so a retry can succeed. See the ["The destructive replacement was deferred before partition deletion"](#the-destructive-replacement-was-deferred-before-partition-deletion-v45-patch-1-v46-patch-2-and-v47-patch-1-added-reasons) section above for the constraint-specific resolutions.

- **`Fully Encrypted` with `Protection Off`** — the machine is in a suspended or Waiting-for-Activation state. To use the OS-fallback route you must still decrypt C: (`manage-bde -off C:`), because reagentc refuses on a `FullyEncrypted` volume regardless of protection state.

- **`Encryption In Progress` or `Encryption Paused`** — the Device Encryption service is still working. Wait for it to finish, or abort it:

  ```powershell
  manage-bde -off C:
  ```

  Then wait for `Conversion Status:` to read `Fully Decrypted`.

- **`Decryption In Progress` or `Decryption Paused`** — the encryption service is already stopping. Wait for it to finish.

- **`Fully Decrypted`** — this state should not have triggered the deferral. If it did, re-run `WinRE.ps1`; the previous classification may have hit a transient state.

Once `manage-bde -status C:` reads `Fully Decrypted`, re-run `WinRE.ps1`.

**Do not** attempt to defeat the gate by editing the state file. The gate is the mechanism that prevents the script from deploying a WIM to a target it cannot register. The cost of waiting is one pipeline run; the cost of bypassing the gate is a machine with an unreachable WinRE registration.

**Note.** This gate is only reached on the OS-fallback route. The enable-only and dedicated-partition routes never depend on C:'s BitLocker state, because their target volume is the recovery partition. If you are seeing a related deferral on the enable-only or dedicated-partition route, see the "Target recovery partition could not be made unencrypted" section below.

## Target recovery partition could not be made unencrypted

**Symptom.** The script prepared the target recovery partition via `Set-RecoveryPartitionReadyForWinRE` and the helper reported that the partition could not be made unencrypted. On the **enable-only** path the run exits with code 2 (`EXIT_WARNING`) and the state file is updated with `LastEnableResult = "failed"`. On the **full-update** path the run exits with code 3 (`EXIT_FATAL`) and no state file is written.

**Log signature (enable-only path).**

```
[ERROR] Enable-only path: target recovery partition could not be made unencrypted - deferring without further changes
[WARN] Re-run after the target volume is decrypted, or after the Device Encryption service has stabilised.
```

**Log signature (full-update path).**

```
[ERROR] FATAL: Could not make target recovery partition unencrypted
```

**Cause.** `Set-RecoveryPartitionReadyForWinRE` runs `manage-bde -off` against the target partition and polls `Test-VolumeEncrypted` at 5-second intervals up to a 300-second timeout. The failure means one of:

- The `manage-bde -off` call itself failed. The log line above the failure records the exact `manage-bde` output.
- The partition did not report confirmed-unencrypted within the 300-second timeout.
- A drive letter could not be assigned to the target partition, so the helper could not query it.
- `Get-Partition` could not find the target partition (rare; usually a transient `Storage` module issue).

**Resolution.** Investigate the target partition directly. From an elevated PowerShell, determine the target partition (the log line above the failure records the disk number and partition number), then:

```powershell
manage-bde -status <X>:
```

where `<X>` is the drive letter assigned to the target partition. Read the `Conversion Status:` line.

- **`Fully Decrypted`** — the partition is already clean. The helper's query may have hit a transient state; re-run `WinRE.ps1`.
- **`Fully Encrypted`, `Used Space Only Encrypted`, `Encryption In Progress`, `Encryption Paused`** — the partition is BitLocker-managed. Manually decrypt it:

  ```powershell
  manage-bde -off <X>:
  ```

  Wait for the status to report `Fully Decrypted`. Then re-run `WinRE.ps1`.
- **`The volume could not be opened by BitLocker`** — the partition is not managed by BitLocker. This is the expected state for a recovery partition. The helper's query may have hit a transient state; re-run `WinRE.ps1`.
- **`Decryption In Progress`, `Decryption Paused`** — wait for the decryption to finish, then re-run.

If the drive letter cannot be assigned (the helper logs `Set-RecoveryPartitionReadyForWinRE: could not assign a drive letter to X/Y`), free a drive letter: check `Get-PSDrive -PSProvider FileSystem` and `net use` for mapped drives that can be removed.

If a `manage-bde` call is being blocked (unusual, but antivirus and endpoint protection have been observed to do this), the log will show the `manage-bde` output. Resolve the block with the AV vendor's tooling, or add the recovery partition to the exclusion list, then re-run.

**When the counter reaches 3.** The enable-only path's failure increments `EnableFailureAttempts` in the state file. After three consecutive failures, the next run's loop-breaker fires (see "`reagentc /enable` keeps failing on the enable-only path" below).

## `reagentc /enable` fails with "cannot be enabled on a volume with BitLocker Drive Encryption enabled"

**Symptom.** `reagentc /enable` returns non-zero, output contains the phrase above.

**Log lines.**

```
reagentc /enable (exit 2): ...
reagentc /enable failed because the target volume is BitLocker-protected
```

**Cause.** reagentc's BitLocker check is on the **target** volume — the volume reagentc is being asked to enable WinRE on — not on C:. Under the v43 patch 5 (further revision 5) policy, the script prepares the target volume with `Set-RecoveryPartitionReadyForWinRE` before calling `reagentc /enable`. If this error still appears after preparation, one of the following is true.

**Case 1 — the Device Encryption service re-claimed the target.** Between the helper's successful preparation and the `reagentc /enable` call, the Device Encryption service started encrypting the target partition again. This is rare on a recovery partition, because recovery-typed partitions carry the recovery type GUID and `0x8000000000000001` attributes that tell BitLocker to refuse them. It is more likely on a machine with an unusual BitLocker policy that auto-encrypts new partitions regardless of type. The log line preceding the failure records the partition's state at the time of preparation; check whether the state changed between preparation and `/enable` by comparing timestamps.

**Case 2 — the target reagentc checks is not the partition the helper prepared.** On the OS-fallback route, the target *is* C:, and C: is not prepared by the helper (the script never decrypts C:). The OS-fallback gate should have deferred the run before reaching this point, but a race is possible if C:'s state changed between the gate check and the `reagentc /enable` call. The log line immediately before the `reagentc /enable` call records C:'s `VolumeStatus`; if it is not `FullyDecrypted`, this is what happened.

**Resolution.** The script records the failure and the counter increments. There is no automatic recovery under the current policy; the failure is treated the same as a generic enable failure.

1. Determine which case applies. Grep the log for the last `Target partition` line before the failure and the last `OS-fallback deferred` line, if any.
2. **Case 1:** re-run the script. The next run will re-prepare the target partition and retry. If the Device Encryption service is actively re-claiming the partition every time, the failure will repeat, and the loop-breaker will fire after three attempts — see "`reagentc /enable` keeps failing on the enable-only path" below for the next steps.
3. **Case 2:** check C:'s state:

   ```powershell
   manage-bde -status C:
   ```

   If `Conversion Status:` is not `Fully Decrypted`, wait for the state to resolve, then re-run the script.

**Do NOT attempt to force `reagentc /enable` manually against an encrypted target.** The OS check will refuse the call regardless of how the target was reached. The only fix is to make the target unencrypted.

## `reagentc /enable` keeps failing on the enable-only path

**Symptom.** Two related cases share this section.

The first case — the enable-failure counter is building. The script deployed successfully on a prior run, the state file records the deployment as complete, and the enable-only path fires on every subsequent run because WinRE is still `Disabled`. Each run increments the counter, exits with `EXIT_WARNING`, and does not attempt a rebuild. The counter is visible in the log as `(attempt N of 3)`.

The second case — the loop-breaker has fired. The counter reached 3, and the next run exited with `EXIT_FATAL` without attempting anything.

### Case 1 — enable-only failure with the counter below the threshold

**Log signature.**

```
[INFO] Enable-only path: image current, WinRE disabled, on recovery partition
[INFO] reagentc /setreimage: exit=0, output=REAGENTC.EXE: Operation Successful.
[INFO] reagentc /enable (exit <n>): <output>
[WARN] reagentc /enable: exit=<n> -> hard failure
[WARN] Enable-only /enable failed (attempt 1 of 3). Not falling through to full update - the deployment is current and only the enable step failed, so a rebuild would not change the outcome. Will retry on next run.
```

Or, for the BitLocker-refusal variant:

```
[ERROR] reagentc /enable failed because the target volume is BitLocker-protected
[WARN] Enable-only /enable refused with the BitLocker error after the target partition was confirmed unencrypted (attempt 1 of 3). The Device Encryption service may have re-claimed the volume. Not falling through to full update.
```

Subsequent runs show `(attempt 2 of 3)` and `(attempt 3 of 3)`. Both variants increment the same counter.

**Cause.** `reagentc /enable` returned a terminal failure. The most likely causes:

- `ReAgent.xml` is corrupt or inconsistent. The registration path exists but the XML describes a location that no longer matches reality.
- The WIM at the reagentc-registered location is unusable. The `setreimage` call succeeded but the enable refused because the WIM could not be validated.
- A `Windows\System32\Recovery\` file is locked or ACL-denied.
- A `Windows\System32\Recovery\WinreAgent` component is in a bad state.
- Antivirus or endpoint protection is holding the recovery partition or the deployed `winre.wim` open.
- For the BitLocker variant: the target partition's recovery type GUID and attributes were not applied correctly, so the Device Encryption service re-claimed it before `/enable`. This is a configuration problem on the partition, not on the deployment.

**Resolution.** This is an "investigate the enable failure itself" case, not a "re-run the script" case. The deployment is already correct; nothing the script can do will change the outcome of the enable step.

1. Inspect the WIM at the reagentc-registered location:

   ```powershell
   reagentc /info
   ```

   Note the Location. Then verify a `winre.wim` exists there:

   ```powershell
   Get-Item "<location>\Recovery\WindowsRE\winre.wim"
   ```

2. Check `ReAgent.xml` for obvious corruption:

   ```powershell
   Get-Content "$env:windir\System32\Recovery\ReAgent.xml" -Raw
   ```

   A well-formed file has a `<WinreLocation>` element pointing at the registered location. A malformed or truncated file should be deleted (after `attrib -h -s -r`) and rebuilt. The production script's own `Invoke-ReAgentRegistrationRepair` function performs this recovery, but it only runs during the pipeline after a successful `reagentc /enable` returns `exit 0` with a mismatched status. If `reagentc /enable` is failing outright, the repair function is not reached.

3. Manually repair the registration from an elevated PowerShell:

   ```powershell
   attrib -h -s -r "$env:windir\System32\Recovery\ReAgent.xml"
   Remove-Item "$env:windir\System32\Recovery\ReAgent.xml" -Force
   reagentc /setreimage /path \\?\GLOBALROOT\device\harddisk<X>\partition<Y>\Recovery\WindowsRE
   reagentc /enable
   ```

   Replace `<X>` and `<Y>` with the disk and partition from the `reagentc /info` Location. If `/enable` succeeds, the underlying problem is resolved.

4. If `/enable` still fails, run `Get-WinEvent -LogName "Microsoft-Windows-WinRE-Agent/Operational"` for the corresponding entries. The WinRE-Agent operational log is the authoritative source for the specific reason `/enable` refused.

5. For the BitLocker variant: verify the target partition's type and attributes:

   ```powershell
   Get-Partition -DiskNumber <X> -PartitionNumber <Y> | Select-Object GptType, MbrType
   ```

   For GPT, the `GptType` should be `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}`. For MBR, `MbrType` should be `0x27`. If the type is wrong, use `Set-RecoveryPartitionAttributes` (or `diskpart set id=...`) to fix it, then re-run the script.

6. If the enable now succeeds, delete the state file so the counter resets on the next run:

   ```powershell
   Remove-Item "$env:SystemDrive\Recovery\OEM\winre_state.json" -Force
   ```

   Then re-run `WinRE.ps1`. It will rebuild the WIM once (because the state file is absent) and complete normally.

If the enable never succeeds after the manual investigation above, the machine has an OS-level problem with WinRE that is outside this project's scope. File a bug with the operational log entries.

### Case 2 — the loop-breaker has fired

**Log signature.**

```
[ERROR] Refusing to retry reagentc /enable: it has failed on the last 3 consecutive runs and WinRE is still Disabled. Manual intervention is required.
[ERROR] Verify the machine has completed OOBE and is not in Audit Mode. To reset the failure counter, delete C:\Recovery\OEM\winre_state.json and re-run.
```

The run exits with code 3 (`EXIT_FATAL`).

**Cause.** The enable-failure counter reached 3 and the state file still records a non-`"ok"` `LastEnableResult` with WinRE `Disabled`. The loop-breaker fires to prevent the machine from silently cycling through the same failing path indefinitely.

The Audit Mode guard runs first, so on v43 patch 5 (further revision) this case cannot be caused by Audit Mode. The most likely causes are the same as Case 1, plus:

- The recovery partition is being held open by another process.
- The recovery partition itself has filesystem corruption.
- The WIM at the registered location is not a valid WinRE image (e.g. it was replaced by something else).
- For the BitLocker variant: the partition cannot hold the recovery type GUID (e.g. disk corruption in the partition table), so every recreation ends up auto-encrypted.

**Resolution.**

1. Follow the Case 1 investigation steps. Resolve the underlying cause.
2. Once `reagentc /enable` succeeds manually, delete the state file:

   ```powershell
   Remove-Item "$env:SystemDrive\Recovery\OEM\winre_state.json" -Force
   ```

3. Re-run `WinRE.ps1`. The counter is gone with the state file, the script rebuilds the WIM once, and completes normally.

Do **not** retry the script without first resolving the underlying cause. The loop-breaker will fire again on the next run because the state file still records the counter value.

**Under `-DryRun`** the loop-breaker logs `Would refuse to retry reagentc /enable: …` and continues, matching the pattern used by the Audit Mode guard. A dry run does not modify the state file or reset the counter.

## `reagentc /disable` fails at Step 5

**Symptom.** The script has already created a new recovery partition, deployed the WIM, and now cannot disable the existing WinRE registration.

**Log lines.**

```
reagentc /disable: exit=<n>, output=<output>
reagentc /disable failed (exit <n>): <output>
FATAL: cannot deploy a new WinRE image while WinRE is still Enabled - aborting
```

**Cause.** `reagentc /disable` returned non-zero. Common causes: a pending WinRE operation from a previous run, corruption in `ReAgent.xml`, or a locked recovery partition.

**Resolution.** Manual. The script exits with `EXIT_FATAL` and does not write state. Investigate:

1. Check `C:\Windows\System32\Recovery\ReAgent.xml` for corruption. If the file exists but is malformed, delete it (after `attrib -h -s -r`) and retry.
2. Check `C:\Recovery\WindowsRE\winre.wim` for a lock. `handle.exe` or `Process Explorer` will show the holder.
3. Check `reagentc /info` for the current state. If it reports a state that does not match reality (e.g. `Enabled` when WinRE is disabled), the registration is stale. `reagentc /setreimage /path C:\Recovery\WindowsRE` followed by `reagentc /enable` may repair it.

## `dism /Export-Image` fails

**Symptom.** Step 4 of the full-update path.

**Log lines.**

```
dism /Export-Image failed with exit code <n>
```

or

```
dism /Export-Image reported success but <path> does not exist
```

**Cause.** DISM failure. Common causes: the source WIM is corrupt or incomplete, the destination volume is full, or the WIM has already been mounted by an interrupted run.

**Resolution.** Manual. The script exits with `EXIT_FATAL`.

1. Find the `Workspace selected:` line in the log and inspect that `<drive>:\Temp\WinREWork` for WIM size and integrity.
2. Check free space on the selected workspace volume. The script requires 3 GiB at admission, but a larger-than-expected source, OEM pack, or scratch peak can still exhaust it during servicing.
3. Check `Get-WindowsImage -Mounted` for stale mounts. If any mount's path is under the selected workspace, dismount it with `-Discard`.
4. Delete the selected workspace and its checkpoint file, then let the next run select a volume and start fresh.

## Base WIM download fails

**Symptom.** Step 2 of the full-update path, only reached when the source-selection chain falls through to the GitHub cold-start branch.

**Log lines.**

```
No active or fallback WinRE image found - forcing rebuild
Step 2: Obtaining base WIM
Base WIM source selection: neither registered nor hash-validated LKG usable; GitHub cold-start
7-Zip required
```

followed by a download error or a `FATAL` exit.

Under v47 the GitHub cold-start branch is the third tier of the source-selection chain. Reaching it means the registered image was not usable and the hash-validated LKG was either absent or failed its SHA256 validation. The source-selection line above the download tells you which branch was taken.

**Cause.** The GitHub repository hosting the base WIM is unreachable, the parts are missing, or 7-Zip is not installed and could not be installed via `winget`.

**Resolution.** Manual. The script exits with `EXIT_FATAL`.

1. Verify network access to `api.github.com` and the configured `$BaseWinRERepoApi` URL.
2. Verify 7-Zip is present at `C:\Program Files\7-Zip\7z.exe`. If not, install it via `winget install 7zip.7zip --scope machine` from an elevated shell.
3. Check the GitHub repository for the expected `winre.7z.NNN` parts. If the parts are missing, point the script at a mirror or restore the parts.
4. **Consider whether the source-selection chain is what you want.** A machine whose registered image was unusable but whose LKG is valid should not reach GitHub. If the log shows the GitHub cold-start branch but a copy of `C:\Recovery\WindowsRE\winre.wim` exists, check whether its SHA256 matches `state.CurrentImageHash`. If it does, the source-selection chain should have preferred it; a mismatch indicates the LKG was written under a different `DesiredStateId` — the LKG is deliberately not trusted in that case.

**Note (v44 patch 6).** Step 2 now removes any stale `winre.wim` before extraction and any stale `base.wim` before the rename. If a previous run was interrupted between extraction and rename, this cleanup closes the wedge on the next run. If you see a `Removing stale extracted WIM before extraction` or `Removing stale base.wim before rename` line in the log, the cleanup fired as designed.

## `New-Partition` fails after 3 attempts

**Symptom.** The OS partition has been shrunk and the eligible recovery partitions have been deleted, but the script cannot create the new partition.

**Log lines.**

```
New-Partition attempt 1 failed: ...
New-Partition attempt 2 failed: ...
New-Partition attempt 3 failed: ...
New-Partition failed after 3 attempts
```

**Cause.** The disk geometry changed between the read-only plan and creation, or a disk error prevented creation at the planned extent.

**Resolution.** The script calls `Restore-OSPartitionSize` to restore C: to its recorded original size and returns a creation failure. The main flow may use OS-fallback if C: is confirmed fully decrypted. The run exits with `EXIT_WARNING` when fallback succeeds.

If C: is encrypted, the OS-fallback gate defers and the machine ends with **neither** a dedicated recovery partition **nor** a working OS-fallback registration — the post-deletion residual corner documented in the ["The OS-fallback route deferred because C: is encrypted"](#the-os-fallback-route-deferred-because-c-is-encrypted) section above. The log shows the compound signature: `Pre-deletion inventory:` followed in the same run by `OS-fallback deferred: C: could not be confirmed fully decrypted`. Capture the full log and file a bug.

If `Restore-OSPartitionSize` also fails, `$Script:GeometryRestoreFailed` is set and the state file is deleted. The next run will re-attempt the destructive path from scratch.

## The post-delete extension failed (v45 patch 1; bucket cap in v46 patch 2; ceiling-fill in v47 patch 2)

**Symptom.** The plan called for C: to grow into the space the old recovery partitions occupied (the surplus case). The extension ran after the deletions and failed after all retries. The script used its safe fallback and continued with a slightly different recovery partition layout than the plan intended — the recovery partition starts at the current (un-extended) C: end instead of the planned offset, and is sized to the plan's bucket rather than to the full remaining extent.

**Log signature.** The run continues past the extension failure:

```
[WARN] Post-delete extend attempt 1 failed: ...
[WARN] Post-delete extend attempt 2 failed: ...
[WARN] Post-delete extend attempt 3 failed: ...
[WARN] Post-delete C: extension failed after all retries; attempting the safe fallback (recovery partition at the current C: end) so WinRE remains deployable.
[INFO] Extension-failure fallback: creating recovery partition at <offset> MiB with size <size> MiB (fills the available extent up to the 2048 MiB managed-recovery ceiling; <trailing> MiB trailing unallocated extent will remain; the C: extension was not performed)
```

The run then proceeds to create, format, and deploy into the fallback partition. The exit code is 2 (`EXIT_WARNING`) because `$Script:nonFatalWarning` is set.

If the fallback also fails — the remaining extent after the current C: end is smaller than the plan's bucket size — the script restores C: to its original size and returns `$null`; the main flow falls through to the OS-fallback decision, and the log shows:

```
[ERROR] Extension-failure fallback unavailable: only <n> MiB free after the current C: end, less than the <m> MiB bucket. Falling through to the caller's OS-fallback decision.
```

**Cause.** `Invoke-OSPartitionExtend` runs three times with 5-second spacing between attempts. It fails when the storage stack refuses to grow C: into the freed space — typically because a file on the volume is unmovable, because a temporary lock is held by a system service, or because the disk has a physical constraint. The extension is a real operation on physical storage, and its failure is a storage-stack condition, not a script bug.

**Why the safe fallback exists.** Exact geometry — C: ending exactly at the planned boundary, recovery partition of exactly the planned size — is a goal, not a reason to leave WinRE disabled. When the extension fails, the script computes the largest recovery partition that fits between the current C: end and `AlignedManagedExtentEnd`. If that is at least the plan's bucket size, it creates the partition there, sized to `min(AvailableSize, 2 GiB)` — the full available extent, capped at the managed-recovery ceiling. This fills the extent in the common case, eliminating the trailing unallocated space; only when the surplus exceeds 2 GiB does a trailing extent remain. The alternative — restore C:, return `$null`, fall through to OS-fallback on an encrypted C: — leaves the machine degraded when a working dedicated recovery partition was one step away.

**Evolution of the fallback sizing rule.** Before v46 patch 2 the fallback assigned the entire remaining extent to the replacement partition, which on a layout with a large surplus could exceed the 2 GiB managed-recovery ceiling. v46 patch 2 introduced the ceiling but sized the partition to the plan's bucket — the smallest legal size — leaving the surplus as a trailing unallocated extent on every fallback. v47 patch 2 keeps the ceiling but fills up to it: the partition is sized to `min(AvailableSize, 2 GiB)`, which eliminates the trailing extent whenever the surplus fits under the ceiling.

**Resolution.**

1. **If the run continued past the extension failure** (the log shows `Extension-failure fallback: creating recovery partition`), nothing needs to be done. The machine is in a functional dedicated-recovery state; the trailing unallocated extent is intentional. The next full-update pass — triggered by a DSI change — will re-plan the layout from the plan's perspective.
2. **If the run did not continue** (the log shows `Extension-failure fallback unavailable`), the machine is on the OS-fallback route or has no working recovery route. Check the machine's end state with the harness Option 1. If a recovery route exists, no action needed. If neither route exists, follow the ["The machine has no recovery partition and WinRE is disabled"](#the-machine-has-no-recovery-partition-and-winre-is-disabled) section.
3. **If extension failures are recurring** on the same machine, the freed space after the old recovery partitions may be partially occupied by unmovable files or by a stale temporary allocation. Run `defrag C: /x` from an elevated shell and re-run.

## Drive letters exhausted

**Symptom.** The script cannot assign a drive letter to the newly created recovery partition.

**Log signatures.** One or more of:

```
No drive letter available
```

```
Exhausted all candidate letters for disk <n> part <m>
```

```
Invoke-DriveLetterAssignment: target partition <n>/<m> no longer exists - aborting letter search
```

```
Invoke-DriveLetterAssignment: target disk <n> is <offline|status> - aborting letter search (bring the disk online and re-run)
```

```
All three methods failed for <letter>: - <diagnostic>
```

The last form is the per-letter diagnostic — the error from the last of the three assignment methods (`Set-Partition`, `Add-PartitionAccessPath`, `diskpart assign`). It names the specific reason each letter is being rejected, for example `diskpart: The specified drive letter is not free to be assigned` for a letter reserved by a mapped network drive.

**Cause.** Different root causes for different signatures:

- **`No drive letter available`** 
—
 `Get-AvailableDriveLetter` returned nothing because every letter from D: to Z: is already reserved. Reservations are checked against `Get-Volume`, the Mount Manager's DOS Devices registry key (which is where mapped network drives and `subst` reservations live), and a `Test-Path` fallback. A letter reserved by `net use` or `subst` is now correctly seen as in-use and skipped.
- **`Exhausted all candidate letters`** 
—
 the letter loop tried every candidate and none of the three assignment methods took. The `All three methods failed for <letter>: - <diagnostic>` line immediately above names the specific reason.
- **`target partition <n>/<m> no longer exists`** 
—
 the target partition was deleted mid-search. Rare; usually indicates a concurrent process removed it.
- **`target disk <n> is <offline|status>`** 
—
 the disk the target partition lives on has gone offline or is in a non-Online state. The function refuses to burn through 26 letters against a target that cannot accept one.

**Resolution.** Manual. The script calls `Remove-OrphanPartition` on the new partition and returns `$null`. The main flow falls through to OS-fallback.

Before retrying:

1. **Free a drive letter.** Check `Get-PSDrive -PSProvider FileSystem` and `net use` for mapped drives that can be removed. A mapped `Z:` (or any mapped letter) is a common cause and is now correctly detected by the availability check.
2. **If the signature is the offline-disk bail-out**, bring the disk online and re-run: `Get-Disk -Number <n> | Set-Disk -IsOffline $false`.
3. **If the signature is `All three methods failed` with an unusual diagnostic**, investigate the target partition and its disk with `Get-Disk -Number <n> | Format-List` and `Get-Partition -DiskNumber <n>` before re-running. The diagnostic string names the specific failure.

## `Get-BitLockerVolume` returns null

**Symptom.** `Test-VolumeEncrypted` or `Set-RecoveryPartitionReadyForWinRE` falls back to parsing `manage-bde -status`.

**Log lines.** The fallback path is silent by default in production; the harness (`Test-WinRE.ps1`) logs it. Under production, if the target volume is queried and the fallback fires, the behaviour is transparent — the helper proceeds with `manage-bde` text parsing.

**Cause.** The BitLocker module is not loaded, the cmdlet failed, or the machine lacks the BitLocker feature. This is common on client SKUs where BitLocker is not enabled or on Windows Home.

**Resolution.** Automatic. The fallback path parses `manage-bde -status` output. The fallback is tightened: `Protection Off` alone is not sufficient evidence of safety. Only a confirmed `Conversion Status: Fully Decrypted` (or the `could not be opened by BitLocker` classification) makes the fallback return confirmed-unprotected; anything else returns unknown, and the helper's caller treats unknown as "not safe to proceed."

The refusal is deliberate: the script will not assume BitLocker is safe when it cannot confirm. The target partition is then deferred to the next run.

## `manage-bde -status` output cannot be parsed

**Symptom.** `Test-VolumeEncrypted` returns `$null` on a machine where BitLocker is clearly in one state or the other.

**Log lines.** The failure surfaces as an indeterminate result from `Test-VolumeEncrypted`. The first caller to observe it, `Set-RecoveryPartitionReadyForWinRE`, logs:

```
[WARN] Target partition X/Y (Z:) encryption state indeterminate - sleeping 5s and re-checking
```

and sleeps 5 seconds to give the BitLocker service a chance to report a clean state. If the re-check is still indeterminate, the helper proceeds to run `manage-bde -off` against the target anyway — a partition that might be encrypted is treated as if it is. The `manage-bde -off` output recorded in the log is where you diagnose the format change: on a clean partition it reports `ERROR: An error occurred (code 0x80070057): The parameter is incorrect`, and on an encrypted one it reports `Decryption is now in progress`.

**Cause.** A Windows build changed `manage-bde -status` output format. The regexes for `Protection On` / `Protection Off` / `Conversion Status:` no longer match.

**Resolution.** Manual.

1. Run `manage-bde -status C:` from an elevated shell and capture the output.
2. Run `scripts\Test-WinRE.ps1`, Option 1. The parser self-test checks 3 and 4 will FAIL, and the raw `manage-bde -status` output is dumped to the diagnostic. Compare the format to the regex in `Test-VolumeEncrypted`.
3. Update the regex in `scripts/WinRE.ps1` and mirror it in `scripts/Test-WinRE.ps1`.
4. File an issue with the raw output and the Windows build number.

## `reagentc /info` location regex fails

**Symptom.** The parser self-test check 2 fails, or the script cannot resolve the WinRE location.

**Log lines.**

```
Parser: reagentc location  [FAIL] ...did not match any line
```

**Cause.** `reagentc /info` output format changed. The expected pattern is `\\?\GLOBALROOT\device\harddiskX\partitionY\` or `\\?\Volume{GUID}\`.

**Resolution.** Manual. Run `reagentc /info` and inspect the Location line. Update the regex in `Get-WinREState` in both `scripts/WinRE.ps1` and `scripts/Test-WinRE.ps1`.

## The state file is missing or empty

**Symptom.** The log shows `No valid state (missing or stale) - rebuilding` when you expected the fast path.

**Cause.** The state file at `C:\Recovery\OEM\winre_state.json` is absent, unparseable, or has a `DesiredStateId` that does not match the current one.

**Resolution.** Automatic. The script falls through to the full-update path. A rebuild on a healthy machine is a no-op for the partition layout; it copies the current WIM, verifies it, and rewrites the state file.

**Expected during the v44 patch 1, v45 patch 1, v46 patch 1, v47 patch 1, and v47 patch 2 rollouts.** Each revision changed an input the `DesiredStateId` depends on: v44 added CPU vendor/generation and VMD presence; v45, v46 patch 1, and v47 patch 1 each changed the `SCRIPT` component; v47 patch 2 changes the DSI value on one narrow machine class by normalising the `Win32_ComputerSystemProduct.Version` field (machines whose padded value is at least four characters long while its trimmed value is shorter than four). Every managed machine's stored state file, written under the previous version, no longer matches the ID computed under the new version. The `No valid state (missing or stale) - rebuilding` line will appear on every machine on its first run after each update. This is the intended behaviour and is not a defect. Subsequent runs take the fast path once the state file is rewritten under the new ID.

Under v47 the first run also writes the `DeployedWinREMetadata` anchor. From the second v47 run onward the drift detector compares against it.

If the state file is repeatedly disappearing on a machine that has already taken one full-update pass under the current version, check:

1. Whether `Restore-OSPartitionSize` is failing. If it is, `$Script:GeometryRestoreFailed` is set and `Write-WinREState` deletes the state file on purpose. The log will show `Write-WinREState: OS partition geometry could not be verified after a failed destructive attempt - deleting state file`. Investigate why the geometry restore is failing.
2. Whether the file is being deleted by something else (antivirus, cleanup task, GPO). `C:\Recovery\OEM\` is not a location that should be cleaned by any standard tooling.
3. Whether the loop-breaker is firing because the enable-failure counter reached 3. The state file is deliberately left in place in that case (the operator deletes it manually to reset the counter), but if a cleanup tool is configured to remove anything in `C:\Recovery\OEM\` on a schedule, it will also remove the state file for this reason.

**Not to be confused with the Audit Mode, VMD-query-indeterminate, OS-fallback BitLocker, pre-shrink deferral, race-detector abort, or injection-failure deferrals.** If the run exits with `EXIT_WARNING` because a deferral fired, the state file will also be unchanged — but that is not a problem with the state file. The deferrals leave the prior state file intact (or leave it absent if it was absent before); they do not delete it. If a state file existed before the run and still exists after, the deferral is the explanation. If a state file existed before and is gone after, `Restore-OSPartitionSize` or an external cleanup task is the explanation. The pre-shrink deferral additionally writes the sidecar marker at `C:\Recovery\OEM\winre_partition_deferred.json` — see the ["The destructive replacement was deferred before partition deletion"](#the-destructive-replacement-was-deferred-before-partition-deletion-v45-patch-1-v46-patch-2-and-v47-patch-1-added-reasons) section.

**Not to be confused with the enable-only failure path either.** The enable-only failure path **writes** the state file with a non-`"ok"` `LastEnableResult` and an incremented counter. The state file's `LastUpdated` timestamp will be newer than the run start, and its `EnableFailureAttempts` will be non-zero. If you were expecting the state file to be absent, this is what happened.

**Not to be confused with the offline-fallback deferral.** The offline-fallback deferral leaves the state file untouched, but its log signature is unique: `Offline fallback: the machine requires a full update …`. The state file's `LastUpdated` timestamp is unchanged.

## The machine is in OS-fallback and stays there

**Symptom.** The state file records `UsedOSFallback: true` and the script keeps exiting with code 2 without re-attempting the dedicated partition.

**Cause.** This is deliberate. The `DesiredStateId`-scoped retry policy (v41) preserves the OS-fallback outcome for the current state so that a machine that cannot complete the destructive path does not re-run it on every run. Under v45 patch 1 the trigger set for reaching OS-fallback has narrowed: the shrink runs in the reversible window and a failed pre-shrink now returns a retry-suppressed `Deferred` with the old route preserved, so it no longer reaches OS-fallback. The v45 causes for OS-fallback are post-delete failures where the previous route could not be restored, or where the post-delete extension fallback was unavailable.

**Resolution.** If you want the machine to retry:

1. The most common reason to re-arm the retry is a `ScriptVersion` bump, a manifest `version` change, a change in CPU generation, or a change in VMD presence — any of which changes the `DesiredStateId`. Ship one of those, or wait for the next one.
2. Alternatively, delete `C:\Recovery\OEM\winre_state.json` manually. The next run will treat the state as absent and re-run the full-update path.
3. Or change the hardware in a way that changes `Manufacturer` / `Model` / `MachineType`. Not recommended.

Do not edit the state file's `UsedOSFallback` field and leave the rest in place; that will not change the `DesiredStateId` and the fast path will continue to fire.

**Special case.** A machine that reached OS-fallback because of the pre-patch-5 Device Encryption failure (Section 1) has this exact state. Do not try to force the retry by editing the state file. Follow the Section 1 recovery procedure.

**Not to be confused with a deferral.** A machine on which an Audit Mode, VMD-query-indeterminate, OS-fallback BitLocker, pre-shrink, race-detector abort, injection-failure, or offline-fallback deferral fired will also exit with code 2 and will also leave the state file as-is, but `UsedOSFallback` is not set — the state file is simply unchanged.

### OS-fallback, retrying the dedicated path

In v44 the path into OS-fallback was a failed OS shrink. In v45 patch 1 the shrink runs in the reversible window: a failed pre-shrink now returns a retry-suppressed `Deferred` with the old route preserved and no longer reaches OS-fallback. A machine that reaches OS-fallback under v45 has done so because a post-delete step failed and the run could not recover the previous dedicated-partition route. Freeing C: space may still help — a plan-time rejection is one possible cause of a post-delete failure — but the primary diagnostic is the log line naming the specific post-delete failure.

To make an OS-fallback machine attempt the dedicated path again:

1. Read the log for the specific post-delete failure that produced the OS-fallback outcome. The compound-signature section above and the `New-Partition` and `Format-Volume` sections name the common causes and their resolutions.
2. Free up space on C: if the machine has less than the required bucket size plus a margin. The bucket size is `WIM size + 250 MiB + 30 MiB`, rounded up to the next 100 MiB boundary, minimum 1000 MiB.
3. Delete both the state file and the deferral marker (if present) to force the next run to re-attempt:

   ```powershell
   Remove-Item "$env:SystemDrive\Recovery\OEM\winre_state.json" -Force -ErrorAction SilentlyContinue
   Remove-Item "$env:SystemDrive\Recovery\OEM\winre_partition_deferred.json" -Force -ErrorAction SilentlyContinue
   ```

4. Re-run `WinRE.ps1`. The next run will compute a new `DesiredStateId` and take the full-update path. If the underlying cause is resolved, the destructive replacement succeeds and the machine ends in a `DEDICATED` state. If a pre-shrink deferral fires instead, the machine stays in OS-fallback — the pre-shrink deferral preserves whatever route is currently registered, which in this case is the OS-fallback route. Address the pre-shrink constraint named in the log, then delete the marker file to retry.

### The v45 plan-rejection corner (fixed in v46 patch 1)

**Symptom.** Under v45 patch 1, the machine falls into OS-fallback on the full-update path and stays there. The state file records a matching `DesiredStateId`; subsequent scheduled runs accept the state and do not retry. The machine is stable but degraded — WinRE is registered on the OS partition rather than on a dedicated recovery partition.

**Log signature.** The v45 run that produced the OS-fallback state contains:

```
[INFO] Partition plan: recovery reclaim N MiB, contiguous free M MiB, shrink S MiB, extend E MiB, bucket B MiB, planned offset O MiB, alignment reserve 344 KiB
...
[INFO] Confirmed deletion of partition 4 on disk 0
...
[ERROR] Planned recovery extent is no longer free after deletion (offset=... size=... overlapCount=0); restoring original C: size
```

Two features distinguish this from other post-delete failures: the `alignment reserve 344 KiB` value in the plan summary line, and `overlapCount=0` in the post-delete check. Other post-delete failures produce different messages (`New-Partition` failure, `Format-Volume` failure, and so on) and are documented under their own sections above.

If C: is encrypted, the failure is followed by the compound OS-fallback deferral:

```
[WARN] OS-fallback deferred: C: could not be confirmed fully decrypted (Test-VolumeEncrypted=True). ...
```

If C: is fully decrypted, the run reaches OS-fallback successfully and logs `Operating mode: OS-FALLBACK (WinRE on OS partition...) - degraded but functional`.

**Cause.** This is the v45 plan-clamp bug fixed by v46 patch 1. On a machine whose factory layout places the last partition exactly 1 MiB past the disk-end reserve, `Get-PartitionPlan` computes `tailEnd` from that partition's offset without clamping to `diskSize − 1 MiB`. The aligned managed extent end (`floor(tailEnd / 1 MiB) × 1 MiB`) therefore lands 1 MiB past the reserve. The post-delete geometry check (`$plannedEnd -gt ($diskSizeNow - 1MB)`) correctly rejects the plan, but the plan it rejected is wrong in the first place.

The machine fell into OS-fallback with a state file that matched the failing `DesiredStateId`, so subsequent scheduled runs accepted the state and did not retry. The machine stayed in OS-fallback until an operator manually deleted the state file.

Field case: **Lenovo IdeaPad 3 15IAU7** (MT 82RK, Win 11 build 26200, GPT, Samsung SSD 980 500GB), 2026-10-02. This is the first v45 destructive-path failure on physical hardware, and the first time the post-delete geometry check fired outside a test harness.

**Resolution.** Update to v46 patch 1 or later. The clamp is applied before aligning `tailEnd`, on both the blocking-partition branch and the no-blocking-partition branch. The same factory layout now produces a valid plan; the post-delete geometry check passes with the partition end exactly 1 MiB inside the disk end.

`ScriptVersion` moves from 45 to 46, so the `DesiredStateId` changes and the machine performs one full-update pass on its next scheduled run. The OS-fallback state is cleared by the DSI mismatch automatically. On v46 patch 1 the machine reaches `DEDICATED` on the first full-update pass after the state file is invalidated.

**If you cannot update immediately,** manually delete the state file to force a retry on the next run with whichever version is currently deployed:

```powershell
Remove-Item "$env:SystemDrive\Recovery\OEM\winre_state.json" -Force
```

Under v45 the retry will hit the same plan rejection and fall back to OS-fallback again. Under v46 the retry will succeed. The Lenovo field case reached `DEDICATED` on the second full-update run under v46 patch 1, after the state file was manually deleted.

**If you see this on a v46 patch 1 or later build,** the plan-clamp fix is not the explanation. Check the log for the specific post-delete failure that produced the OS-fallback outcome — the plan-clamp symptom specifically shows `alignment reserve 344 KiB` in the plan summary and `overlapCount=0` in the post-delete check. Any other combination points at a different cause; see the compound-signature discussion in [The OS-fallback route deferred because C: is encrypted](#the-os-fallback-route-deferred-because-c-is-encrypted) or [The machine has no recovery partition and WinRE is disabled](#the-machine-has-no-recovery-partition-and-winre-is-disabled).

## The machine keeps rebuilding and never takes the fast path (label-only recovery partition)

**Symptom.** The machine runs the full-update path on every scheduled run. The state file is written successfully, the machine reports `DEDICATED` (or falls through to OS-fallback), and the fast path never fires. If you inspect the machine's partitions, there is a partition on the OS disk whose volume label is `Recovery` (or `WINRE`) but whose GPT type is not `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}` (or whose MBR type is not `0x27`).

**Log signature.** The classifier WARN appears early in the run:

```
[WARN] Active WinRE location is label-matched but not type-coded on the OS disk (disk <n>, partition <m>) - it will not qualify as a dedicated recovery partition; scheduling migration to a type-coded target.
```

Followed later in the same run by one of:

```
[INFO] No recovery partition on boot disk - scheduling dedicated partition creation
```

or, if the OS-shrink could not fit:

```
[INFO] No suitable existing recovery partition - attempting to create one
…
[ERROR] Returning null - main flow will attempt OS-partition fallback (C:\Recovery\WindowsRE).
```

**Cause.** The active WinRE location resolves to a partition that has the right volume label but not the right type code. Under v44 patch 7, this partition is:

- Not counted by the fast path's "exactly one recovery partition on the OS disk" condition.
- Not reused by `Find-SuitableRecoveryPartition`.
- Not deleted by any code path — a label alone is never sufficient authority for deletion, on any disk.

The consequence is that the machine's fast-path condition "exactly one type-coded recovery partition on the OS disk" cannot be satisfied by the label-only partition. Every run takes the full-update path. If the OS-shrink succeeds, the run creates a proper type-coded partition and the next run's fast path fires — convergence, one run later. If the OS-shrink fails, the v45 pre-shrink deferral preserves the old route and the machine retries when the constraint is resolved.

Before v44 patch 7, this was a permanent non-convergence loop. The fast-path count and the classifier accepted the label-only match as a recovery partition, so the "exactly one recovery partition" condition could never be satisfied (the label-only match counted as one) while the destructive path correctly refused to delete it. The machine rebuilt on every run without ever reaching the fast path. Patch 7 fixed that by treating the label-only match as not-a-recovery-partition everywhere.

**Why the label-only partition is not deleted.** The type-code gate on deletion has been in the script since v42 and is deliberate: a volume label is user-settable and is not authoritative evidence of what a partition is for. Deleting a partition based on its label alone would risk deleting a data partition whose owner happened to name it "Recovery". The v44 patch 7 change applies the same authority rule to the fast-path count and the classifier that the destructive path has always applied to deletion: type code, not label.

**Resolution.** The machine converges automatically if the OS-shrink can fit the new partition. Confirm convergence by running `WinRE.ps1` twice in succession and observing whether the second run takes the fast path:

1. **If the second run takes the fast path** — the machine is converged. The v44 patch 7 behavior did its job: the full-update pass created a proper type-coded recovery partition and the fast path now fires.
2. **If the second run still takes the full-update path** — read the log to see which fast-path condition failed. The log records the reason: `No recovery partition on boot disk`, `Multiple recovery partitions on boot disk`, or the presence of a non-DEDICATED classifier verdict.
3. **If the machine is in OS-fallback after the run** — the OS-shrink could not fit and the machine is now stable in OS-fallback. Follow the "OS-fallback, retrying the dedicated path" section above: free space on C: to allow the shrink to succeed on the next full-update pass.

**To identify the label-only partition.** Run `Test-WinRE.ps1` Option 1. The "Recovery partitions" section reports `isTyped`, `isLabel`, and `onOsDisk` for every candidate. A row with `isTyped=False` and `isLabel=True` is a label-only match. The v20 harness reports the classifier verdict as `LABEL-ONLY` when the active WinRE location is on such a partition; earlier harness versions would have reported `DEDICATED` in that situation (the false-positive that v20 closed).

**Optional cleanup.** The script will never delete a label-only partition on its own. If you want the OS disk to have a single clearly-typed recovery partition and no misleading labels, remove the label manually:

```powershell
# Identify the partition first via Test-WinRE.ps1 Option 1.
$part = Get-Partition -DiskNumber <n> -PartitionNumber <m>
Get-Volume -Partition $part | Set-Volume -FileSystemLabel ""
```

If the label-only partition is genuinely a stale recovery partition from a prior Windows install and you want it gone entirely, delete it manually with `diskpart delete partition override` after confirming it does not hold data you need. The script will not do this for you — a label alone is never sufficient authority.

## VMD hardware present but no driver matches

**Symptom.** A machine with a VMD controller (Intel 12th gen and later typically) does not get VMD drivers injected.

**Log lines.**

```
VMD hardware present: True
Required drivers (VMD): 0
```

or

```
Skipping <name>: CPU gen <n> outside <min>-<max>
```

**Cause.** The manifest's `cpuGenMin` / `cpuGenMax` does not cover the machine's Intel generation, or the machine's CPU generation could not be parsed.

**Resolution.** Investigate the CPU generation.

1. Check `(Get-CimInstance Win32_Processor).Name` for the raw CPU string.
2. Check `Get-IntelProcessorGeneration -CPUName $cpu` in a PowerShell session. If it returns `$null`, the CPU-generation regex does not match this CPU's name.
3. If the regex is at fault, update `Get-IntelProcessorGeneration` in both `scripts/WinRE.ps1` and `scripts/Test-WinRE.ps1`. The two are mirrored on purpose; update both.
4. If the CPU generation is correct but the manifest does not cover it, update the manifest.

The harness (Option 9, VMD drivers) also logs a warning with the raw CPU string when an Intel CPU is detected but its generation cannot be parsed, which makes this failure mode visible. As of v18, the harness also records a `SKIP` result (not a PASS) in that case, because driver applicability was not evaluated.

## The script is running but nothing is happening

**Symptom.** The script runs, exits 0, and does nothing.

**Cause.** This is the fast path. The machine is already in the correct end state.

**Resolution.** None needed. If you want to see what the fast path observed, run `scripts\Test-WinRE.ps1` Option 1. It reports the machine's state from the same vantage point the production script uses. Option S reports whether the state file's `DesiredStateId` matches the ID production would compute right now, and (as of v23) displays the `DeployedWinREMetadata` anchor that production's v47 drift detector compares against.

## The script runs on every boot

**Symptom.** Slow boot, log entries at every boot.

**Cause.** The scheduled task is triggered at boot and the machine is healthy. The fast path runs, exits 0, and does not touch anything. This is by design.

**Resolution.** If the boot delay is unacceptable, change the scheduled task's trigger from `BootTrigger` to a calendar-only trigger. The project's recommendation is boot + weekly because a boot-time run catches machines that were offline during the weekly window.

## Reading a dry run

`WinRE.ps1 -DryRun` walks the entire control flow and logs every decision it would make, but modifies nothing. Every log line is prefixed `[DRYRUN-<LEVEL>]` so a dry-run audit can be distinguished from a live run.

Use it to:

- Verify the machine will take the expected control-flow path (fast path, enable-only, full-update, or pending-reboot).
- Verify the `DesiredStateId` computation.
- Verify that the resolved OEM pack and VMD drivers are what you expect.
- Verify that the classifier verdict matches what you believe the machine's state to be.
- Verify that the Audit Mode guard would not defer a live run.
- Verify that the v45 pre-shrink deferral would not fire on the next live run, by checking whether `Ensure-AdequateRecoveryPartition`'s dry-run plan line appears and what plan it reports.
- Verify the v47 source-selection chain: the dry-run Step 2 block reports which source the run would prefer and names the LKG fallback.

The dry run does not write to the state file, the checkpoint file, or the deferral marker. It does not modify partitions, BitLocker, drive letters, or WinRE registration. The guarantee is structural, not per-step:

- **The program lock is skipped.** The lock is a state-modifying action (it opens the lock file with an exclusive handle), and DryRun's contract is to modify nothing. A dry run is safe to run concurrently with a live deployment, and the harness (`scripts\Test-WinRE.ps1`) is safe to run concurrently with either.
- The Audit Mode guard is read-only and logs `Would defer …` when the live run would defer.
- The drive-letter assignment is skipped under DryRun; the caller works with the original `\\?\GLOBALROOT` path.
- The **full-update pipeline** terminates at a single choke point at the top of the full-update path. It logs a plan for Steps 1 through 7 and exits cleanly without running `dism`, 7-Zip, or any file I/O in WorkDir.
- The **destructive partition path** in `Ensure-AdequateRecoveryPartition` terminates at a single choke point immediately after the read-only pre-checks and pre-deletion inventory. It logs a plan for the delete, extend, shrink, create, format, and attribute steps. Under v45 patch 1 the plan summary is preceded by a `[DRY RUN] Plan is valid:` line that names the shrink, extend, and no-resize decision and the planned partition offset.
- Every state-modifying helper handles DryRun internally: `Set-RecoveryPartitionReadyForWinRE`, `Invoke-ReagentcEnable`, `Write-WinREState`, `Write-PartitionDeferral`, `Clear-PartitionDeferral`, `Remove-StrayRecoveryPartitions`, `Remove-ItemIfExist`, `Restore-OSPartitionSize`, `Remove-OrphanPartition`, `Set-RecoveryPartitionAttributes`, `Invoke-OSPartitionShrink`, `Invoke-OSPartitionExtend`, `Invoke-DriveLetterAssignment`, `Invoke-DriveLetterRemoval`, `Invoke-VendorExtraction`, `Invoke-CabExtraction`, `Invoke-OemPackDownload`, `Invoke-DismMount`, `Set-Checkpoint`, `New-DirectoryIfNotExists`.

Two checks run under `-DryRun` in read-only form and log a `Would defer …` or `Would refuse …` line when the live run would not proceed:

- **Audit Mode guard.** Reads `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` → `ImageState`. Logs `Would defer WinRE Manager: Windows is not in a normal-running state (Setup\State\ImageState=…)` when the value is present and is not `IMAGE_STATE_COMPLETE`. Continues.
- **Enable-failure loop-breaker.** Logs `Would refuse to retry reagentc /enable: …` when the live run would fire the loop-breaker. Continues.

A dry run that reports either of these is telling you the machine would be deferred on the next live run. Address the underlying condition before running the script for real.

Under DryRun the OS-fallback BitLocker gate is not reached. The full-update pipeline's DryRun choke point sits above the Step 5 target-preparation block, so a dry run exits before the OS-fallback route is chosen and before the gate is evaluated. If the gate were reachable under DryRun, there is no `-DryRun` check on that exit and it would exit `EXIT_WARNING` unconditionally.

The DryRun contract for the VMD-query-indeterminate deferral (v44 patch 6) is the same: the enumeration error is logged, and the run continues rather than exiting.

The DryRun contract for the v45 pre-shrink deferrals is that the plan is logged and the run continues. The plan line is preceded by `[DRY RUN] Plan is valid:` when the read-only checks passed; the reasons evaluated before the DryRun choke point are surfaced exactly as in a live run, while the reasons only reachable after the choke point or gated on `-not $Script:DryRun` are not. The surfaced group is the plan-rejection reasons (all thirteen), `partition geometry unavailable`, `C: volume could not be read for free-space check`, `post-shrink free space below minimum`, and `active WinRE location could not be resolved` (seventeen of the twenty-five distinct reason strings). The unsurfaced group is the pre-shrink execution paths (`pre-shrink failed`, `pre-shrink verification failed`, `resize rounding reduced planned extent`), the two disable-failure paths, the deletion-failure path, and the registered-source-changed abort. To see what the plan would contain on a live run, read the `[DRY RUN] Plan is valid:` line and the subsequent `[DRY RUN]   - Disk …` lines.

Under DryRun, the exact outcome of a live run is not predicted: `Invoke-ReagentcEnable` logs `[DRY RUN] Would call reagentc /enable …` and returns `"ok"`, and the caller's `"ok"` branch runs normally. The operator reads the plan from the log rather than the exit code. A live run on the same machine may succeed, may require a reboot, or may take the registration-repair path, depending on what `reagentc /enable` actually reports.

The v47 patch 1 race detector is **not** exercised under DryRun. A dry run does not capture a registered-source fingerprint (no `/disable` site is reached, so the SHA256 cost is not justified), and it does not log a recheck. The dry-run's value is in confirming the source-selection chain and the strip-stage plan; the race detector's value is only realized in a live run.

## Reporting a bug

See [CONTRIBUTING.md](../CONTRIBUTING.md). Include:

- `WinRE.ps1` version.
- Windows build.
- Vendor, model, Lenovo machine type.
- Partition style (GPT or MBR).
- BitLocker state — **both** `Protection Status:` and `Conversion Status:` from `manage-bde -status C:`. The `Conversion Status` value matters: on the OS-fallback route, `Fully Encrypted` with `Protection Off` is one of the states that the script defers on, and on the dedicated-partition route, the target partition's conversion status is what determines whether `Set-RecoveryPartitionReadyForWinRE` will need to run `manage-bde -off`. Omitting the conversion status makes the report impossible to diagnose.
- The target recovery partition's BitLocker state — the `manage-bde -status` output for the partition reagentc is registered to. The harness's `Test-WinRE.ps1` Option 1 reports this automatically.
- `ImageState` from `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` if the machine may be in Audit Mode or OOBE.
- Free space on C: and the total size of C: if the run exited with a pre-shrink deferral. The v45 patch 1 free-space check refuses to shrink C: below a 3 GiB reserve, and the deferral reason names the projected post-shrink free space.
- Whether a deferral marker file exists at `C:\Recovery\OEM\winre_partition_deferred.json`. If it does, its contents (the `DesiredStateId` and `Since` fields) tell you the exact DSI under which the destructive sequence deferred.
- Exit code.
- If the run exited with code 2 and the log shows `Another WinRE Manager instance is already running (program lock file is exclusively held)`, note whether any other `WinRE.ps1` process (scheduled task, manual invocation, RMM tool, Intune remediation) was running at the same time. As of v44 patch 4, this is not a failure — the other instance is doing the work — but the reporter should confirm they are not looking at a machine with a scheduled task stuck in a running state. Check the scheduled task's "Last Run Result" via `Get-ScheduledTaskInfo`.
- If the run exited with code 2 and the log shows `VMD hardware detection was indeterminate; deferring because the driver set cannot be safely determined`, include the raw PnP enumeration error from the line above it (`VMD hardware detection reported N error(s) during PnP enumeration: …`). The specific error text is what distinguishes a service issue from an antivirus/EDR block from a device in an error state.
- If the run exited with code 2 and the log shows `Offline fallback: the machine requires a full update (state file is stale or unhealthy), but the driver manifest is unavailable` or `Offline fallback: using state file's stored DesiredStateId`, note whether the machine was actually offline (no network, DNS failure, proxy) and what the state file's `LastUpdated` timestamp is. This discriminates the offline-fallback deferral (machine unchanged, next scheduled run with network completes the work) from the fast-path-under-offline case (degraded-success, exit 2). Under v47, also include the state file's `DeployedWinREMetadata` value if present — a missing anchor forces `$needInject = $true` and produces Case 2 rather than Case 1.
- If the run exited with code 2 and the log shows `Dedicated replacement deferred before partition deletion`, this is a v45 pre-shrink deferral (v46 patch 2 and v47 patch 1 added further reasons). Include the `<Reason>` string from that log line, the current free space on C:, and the total size of C:. If the reason is `active WinRE location could not be resolved`, include the raw `reagentc /info` output — the Location line is what `Resolve-WinRELocationToPartition` could not map. If the reason is `registered source changed before disable`, see the next bullet. See "The destructive replacement was deferred before partition deletion" above for the full list of reasons and their resolutions.
- **If the run exited with code 2 and the log shows the v47 patch 1 race detector firing** (`Registered-source recheck at <site> : CHANGED` followed by `Registered WinRE source changed during candidate preparation`), include the captured fingerprint line (`Captured registered-source fingerprint: location=…, version=…, hash=…`), the recheck line, and the change triple (`location=<bool> version=<bool> hash=<bool>`). Also note whether any Windows Update activity was in flight at the time. The exact change pattern is useful field data: the race detector has not fired in the field yet.
- **If the run exited with code 2 and the log shows the v47 patch 1 strip stage failing** (`Strip: initial Get-WindowsDriver enumeration failed`, `Strip: re-enumeration failed`, `Strip: enumeration entry has no Driver field`, `Strip: Remove-WindowsDriver failed`, or `Strip: exhausted iteration budget`), include the exact failure line, the pre-strip inventory log lines (`Strip:   <OEM#.inf> | <provider> | <version> | <orig>`), and the number of packages in the pre-strip inventory. Also include the source-selection line that named the branch the run took, since a machine whose registered image carries non-Microsoft drivers is the case the strip stage exists for. This path has not been exercised in the field.
- **If the run took the full-update path on a machine that should have been on the fast path, and the log shows `State has no DeployedWinREMetadata anchor`, `Registered WinRE metadata changed from … to …`, or `Registered WinRE metadata could not be read`**, include the state file's `DeployedWinREMetadata` value, the currently-registered WinRE's `Version` and `SPBuild` (from `reagentc /info` and `Get-WindowsImage` on the registered WIM), and the log lines named in "The rebuild ran because the registered WinRE metadata changed" above. The rebuild-because-of-a-changed-anchor and rebuild-because-of-an-unreadable-image branches have not been exercised in the field.
- **If the log shows `Pre-injection third-party driver count: N` with N > 0 after the strip stage**, include the pre-strip inventory lines from the strip stage and the exact pre-injection count. The strip stage uses the filterless form of `Get-WindowsDriver`, which Microsoft documents as the third-party inventory of a mounted image; the pre-injection count uses the legacy filtered form retained for injection-delta accounting. A disagreement between the two is a real signal about how DISM reports the image, and the project wants field data on when it fires.
- If the run exited with code 2 and the log shows `Extension-failure fallback: creating recovery partition` or `Extension-failure fallback unavailable`, this is a v45 patch 1 / v46 patch 2 post-delete extension failure. Include the machine's disk layout from `Test-WinRE.ps1` Option 1, the plan's bucket size, the trailing unallocated extent size (if the fallback fired), and the current C: end and disk end.
- If the run exited with code 2 and the log shows the compound signature `Pre-deletion inventory:` followed in the same run by `OS-fallback deferred: C: could not be confirmed fully decrypted`, this is the post-deletion residual that the `[v45 patch 1]` CHANGELOG entry documents. Include the machine's end state (partition count, WinRE status, whether any working recovery route exists) and C:'s encryption state at the moment of the run. The project wants field data on this corner — see the "The OS-fallback route deferred because C: is encrypted" section above.
- If the run exited with code 3 and the log ends with `Cannot rename because item at '<workspace>\winre.wim' does not exist`, check whether the log also contains `Could not set up program lock at …` earlier in the run. If it does, the lock could not be acquired for a non-contention reason (permissions, missing `Logs` directory, transient filesystem issue) and the run proceeded unprotected. The reporter should include the exact lock-failure message and any relevant permissions on `C:\ProgramData\OEM\Logs\`.
- If the log contains `CmdletizationQuery_NotFound_DiskNumber` or `No MSFT_Partition objects found with property 'DiskNumber'`, note the disk number the error names and whether the machine has a card reader or an empty USB enclosure attached. As of v46 patch 2 (production) and v22 (harness), the guard silences the error; include the exact text and the version banner so the reporter can confirm the fix applies.
- If the log shows `Planned recovery extent is no longer free after deletion (offset=... size=... overlapCount=0)` following the deletion of the old recovery partition, and the plan summary line shows an `alignment reserve` value, this is the v45 plan-rejection corner fixed by v46 patch 1. Include the version banner from the top of the log (v45 patch 1 or later), the `alignment reserve` value, and the state file's `DesiredStateId` at the time of the failure. See [The v45 plan-rejection corner](#the-v45-plan-rejection-corner-fixed-in-v46-patch-1).
- The relevant slice of the log — not the whole file unless asked.
- The output of `Test-WinRE.ps1` Option 1, which reports what the production script would see on this machine and includes the BitLocker, Windows Setup state, target-partition state, and classifier verdicts. If the report is about the fast path or the state file, also include the output of Option S.

## Related documents

- [exit-codes.md](exit-codes.md) — what each exit code means.
- [architecture.md](architecture.md) — where each failure mode fits in the pipeline.
- [testing.md](testing.md) — how to use the harness to diagnose, including the v45 destructive-path regression test plan and the v47 patch 1 destructive-adjacent coverage gaps.
- [deployment.md](deployment.md) — the "One instance per machine" precondition for manual invocations and the offline behavior of the scheduled task.
- [state-and-idempotency.md](state-and-idempotency.md) — the deferral marker's relationship to the deployment identity and the operator reset procedure.
- [recovery-partition.md](recovery-partition.md) — the full partition lifecycle, including the v45 patch 1 and v46 patch 2 pre-shrink deferral reasons, and the v47 patch 1 race detector.
