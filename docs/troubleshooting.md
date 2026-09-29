# Troubleshooting

Per-symptom playbook. Each section names the symptom, the log lines to look for, the likely causes, and the resolution.

Log location: `C:\ProgramData\OEM\Logs\WinRE-Manager.log`.

## How to read the log

Every line is `yyyy-MM-dd HH:mm:ss [LEVEL] message`. Levels are `INFO`, `WARN`, `ERROR`, `FATAL`. In `-DryRun` mode, every line is prefixed with `[DRYRUN-<LEVEL>]` instead so a dry-run audit can be distinguished from a live run.

The first line is `========== WinRE Manager Started (v<version>) ==========`. The last line names the outcome and, if applicable, the exit code.

One startup guard runs before any state-modifying action: the Audit Mode guard. It logs a distinct deferral message when it fires. Under the v43 patch 5 (further revision 5) policy, BitLocker state is not consulted at startup — the target volume is not known until the classifier has resolved the reagentc-registered location, and the BitLocker decision is made where the action is taken. The two BitLocker deferrals that remain are on the enable-only path (target preparation) and the OS-fallback path (C: check). Each logs a distinct message; see the corresponding sections below.

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

**Cause.** The machine was mid-Device-Encryption when the script ran. `ProtectionStatus` read `Off` while `VolumeStatus` read `EncryptionInProgress`. The pre-patch-5 code treated `ProtectionStatus=Off` as sufficient evidence that BitLocker was not a factor, deleted the existing recovery partition, and created a new one. The Device Encryption service claimed the new partition and started encrypting it before the recovery type GUID could be applied. The delete-and-recreate retry hit the same problem. The script fell back to OS-fallback and then `reagentc /enable` refused because C: was actively encrypting.

Two field failures, both on Windows 11 build 26200:

- **Dell Latitude 3550** (Intel Core Ultra 5 125U) — 2026-09-28, `VolumeStatus=EncryptionInProgress` at 73.6%.
- **HP ProBook 450 15.6 inch G10** (Intel Core i7-1355U) — 2026-09-28, same state.

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

**Step 2 — update `WinRE.ps1` to v44 patch 1 or later.** Check the `.NOTES` block at the top of the file for a `Version : 44` line. If the file is still v43, apply the v44 update before proceeding.

**Step 3 — re-run `WinRE.ps1`.** With the current policy, the script will:

1. Pass the Audit Mode guard.
2. Choose the enable-only or full-update path.
3. Prepare the target recovery partition via `Set-RecoveryPartitionReadyForWinRE`. If the target is encrypted, the helper decrypts it in place with `manage-bde -off` and polls for completion, up to 300 seconds.
4. Call `reagentc /setreimage` and `reagentc /enable` on the prepared target.

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

**Log signature.** Two lines at the very top of the run, immediately after the `========== WinRE Manager Started (v44) ==========` banner and the `*** DRY RUN MODE ***` line if `-DryRun` was passed:

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

## OEM or VMD injection failed (Step 3 → Step 4 pipeline gate)

**Symptom.** The script exits with code 2 (`EXIT_WARNING`) and the machine is untouched: no partition work, no WIM deployment, no `reagentc` calls, and the state file is unchanged (or absent). The difference from the Audit Mode deferral is that the run got much further — the WIM was downloaded or copied to `WorkDir`, mounted, and an OEM or VMD injection attempt was made against it.

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

**Cause.** One of the driver-injection steps in Step 3 could not demonstrate success:

- The OEM pack download failed (network error, 404, hash mismatch on a manifest that carries a hash, or a zero-byte download that the length check rejected).
- The OEM pack extracted but produced zero INF files (the known Lenovo SCCM Package case, or a packaging error for Dell/HP).
- The OEM pack extracted and contained INF files, but `Add-WindowsDriver` produced no delta and no INF-basename match — the package's INFs are not present in the image after injection.
- A VMD driver download failed (same failure modes as the OEM download).
- A VMD driver archive extracted to a directory with zero INF files.
- A VMD `Add-WindowsDriver` produced no delta and no INF-basename match.

In every case, `$Script:ImageInjectionComplete` was set to `$false` and the pipeline gate stopped the run before Step 4.

**Why the run stops.** A WIM with no OEM or VMD drivers is broken on hardware whose storage controller requires those drivers. On a VMD-based system the resulting WinRE cannot see the OS disk at all, and the deployed recovery environment is worse than useless — it is actively misleading. The v44 patch 1 gate prevents this class of broken deployment, where the earlier pipeline would have exported, deployed, and registered a non-functional WIM. The gate is a protective failure, not a degraded-success: the run stops before anything is committed.

**Resolution.**

1. **Read the log line above the failure.** The specific vendor, package name, or download URL is named. The most common causes are vendor-side (a moved download URL, a changed packaging format), network-side (a proxy blocking the vendor CDN), or manifest-side (a stale `driverUrl`).
2. **For an OEM pack failure**, re-run `scripts\Test-WinRE.ps1` and select Option 6 (HP), 7 (Dell), or 8 (Lenovo) depending on the vendor. The harness downloads and extracts the same pack the production script uses, against live sources, and reports the INF count. If the harness succeeds where production failed, the difference is likely transient (a network hiccup during the production run). If the harness also fails, the pack is genuinely broken or the map is stale.
3. **For a VMD driver failure**, select Option 9 in the harness. This exercises every VMD package the manifest resolves for the machine's CPU generation. A failure here means the manifest's `driverUrl` is stale or the archive format changed.
4. **If the failure is `Add-WindowsDriver produced no error output (silent rejection or no applicable drivers)`**, the package's INFs do not match any device on the image. This is the least common case and usually means the manifest is resolving a package intended for different hardware. Check the manifest entry's `match.cpuGenMin` / `cpuGenMax` against the machine's actual CPU generation. The harness's Option 1 diagnostic reports the generation and the VMD hardware presence.
5. **Fix the underlying cause** — update the manifest or map gist, correct the download URL, install a missing dependency (7-Zip, `curl-impersonate` for the Lenovo builder), or resolve the network/proxy problem.
6. **Re-run `WinRE.ps1`.** The checkpoint is already at step 2 and the `WorkDir` was cleaned by the gate; the next run re-acquires the base WIM and re-runs injection from a clean image.

**What NOT to do.** Do not attempt to force the pipeline past the gate by editing the script. The gate is the mechanism that prevents a broken WIM from reaching the recovery partition. A machine in this state has a functional existing WinRE or a functional existing state file — whatever it had before the run is still in place. The cost of waiting is one pipeline run after the injection failure is resolved; the cost of bypassing the gate is a recovery environment that cannot see the OS disk.

**Not to be confused with the Audit Mode or OS-fallback BitLocker deferrals.** All three exit with code 2 and leave the state file unchanged, but the log signature is distinct: the Audit Mode deferral logs `Deferring WinRE Manager: Windows is not in a normal-running state`, the OS-fallback BitLocker deferral logs `OS-fallback deferred: C: VolumeStatus=…`, and the pipeline gate logs `Image injection did not complete. Stopping before Step 4 and before any deployment.` The first two fire before any download or mount; the pipeline gate fires after both. A field engineer reading the log will see the difference immediately.

## The OS-fallback route deferred because C: is encrypted

**Symptom.** The script chose the OS-fallback route — dedicated-partition creation failed and the script fell back to `C:\Recovery\WindowsRE` — and then exited with code 2 (`EXIT_WARNING`) without deploying the WIM. The machine is unchanged: no new WIM at `C:\Recovery\WindowsRE`, no `reagentc` call made, and the state file is unchanged (or absent).

**Log signature.**

```
[WARN] OS-fallback deferred: C: VolumeStatus=<value>. reagentc will refuse to enable WinRE on the encrypted OS volume. To resolve: sign in with a Microsoft account to complete Device Encryption activation, or add a key protector manually (Add-BitLockerKeyProtector -MountPoint C: -RecoveryPasswordProtector) and enable protection, or wait for decryption to finish. The script will not modify C:'s BitLocker state.
```

**Cause.** On the OS-fallback route the target volume *is* the OS volume. reagentc refuses to enable WinRE on an encrypted OS volume, always — this is a hard OS check, not something the script can work around. The gate exists to prevent the script from deploying a WIM it cannot register.

The `<value>` in the log line is C:'s `VolumeStatus` at the moment the gate fired. It is one of `FullyEncrypted`, `EncryptionInProgress`, `DecryptionInProgress`, `EncryptionPaused`, or `DecryptionPaused`. `FullyEncrypted` is the ambiguous suspended/Waiting-for-Activation state; the four mid-operation states mean the Device Encryption service is actively working.

**Why the script does not decrypt C:.** Decrypting the OS volume is hours of I/O, changes the recovery key relationship, and the OS volume is the user's data. Removing encryption from the OS volume as a side effect of a WinRE repair is not a change the script is authorised to make. The operator resolves the state.

**Resolution.** From an elevated PowerShell:

```powershell
manage-bde -status C:
```

Read the `Conversion Status:` line and act accordingly:

- **`Fully Encrypted` with `Protection Off`** — the machine is in a suspended or Waiting-for-Activation state. Two options: sign in with a Microsoft account on this machine to complete Device Encryption activation (which arms protection and escrows the recovery key), or add a key protector manually and enable protection:

  ```powershell
  Add-BitLockerKeyProtector -MountPoint "C:" -RecoveryPasswordProtector
  ```

  Then wait for `Protection Status:` to read `Protection On`.

- **`Encryption In Progress` or `Encryption Paused`** — the Device Encryption service is still working. Wait for it to finish, or abort it:

  ```powershell
  manage-bde -off C:
  ```

  Then wait for `Conversion Status:` to read `Fully Decrypted`.

- **`Decryption In Progress` or `Decryption Paused`** — the encryption service is already stopping. Wait for it to finish.

Once `manage-bde -status C:` reads either `Protection On` (any conversion status) or `Protection Off` with `Fully Decrypted`, re-run `WinRE.ps1`.

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

**When the counter reaches 3.** The enable-only path's failure increments `EnableFailureAttempts` in the state file. After three consecutive failures, the next run's loop-breaker fires (see "reagentc /enable keeps failing on the enable-only path" below).

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
2. **Case 1:** re-run the script. The next run will re-prepare the target partition and retry. If the Device Encryption service is actively re-claiming the partition every time, the failure will repeat, and the loop-breaker will fire after three attempts — see "reagentc /enable keeps failing on the enable-only path" below for the next steps.
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

1. Check `C:\Temp\WinREWork\base.wim` for size and integrity.
2. Check free space on `C:\Temp` and on the volume where `winre_optimized.wim` is being written.
3. Check `Get-WindowsImage -Mounted` for stale mounts. If any mount's path is under `C:\Temp\WinREWork`, dismount it with `-Discard`.
4. Delete `C:\Temp\WinREWork` and let the next run start fresh.

## Base WIM download fails

**Symptom.** Step 2 of the full-update path, only reached when there is no usable WIM at the reagentc-registered location or via fallback.

**Log lines.**

```
No active or fallback WinRE image found - forcing rebuild
Step 2: Obtaining base WIM
7-Zip required
```

followed by a download error or a `FATAL` exit.

**Cause.** The GitHub repository hosting the base WIM is unreachable, the parts are missing, or 7-Zip is not installed and could not be installed via `winget`.

**Resolution.** Manual. The script exits with `EXIT_FATAL`.

1. Verify network access to `api.github.com` and the configured `$BaseWinRERepoApi` URL.
2. Verify 7-Zip is present at `C:\Program Files\7-Zip\7z.exe`. If not, install it via `winget install 7zip.7zip --scope machine` from an elevated shell.
3. Check the GitHub repository for the expected `winre.7z.NNN` parts. If the parts are missing, point the script at a mirror or restore the parts.

## `New-Partition` fails after 3 attempts

**Symptom.** The OS partition has been shrunk, the recovery partitions have been deleted, and the script cannot create the new partition.

**Log lines.**

```
New-Partition attempt 1 failed: ...
New-Partition attempt 2 failed: ...
New-Partition attempt 3 failed: ...
New-Partition failed after 3 attempts
```

**Cause.** The disk geometry changed between the shrink and the create (uncommon), or there is genuinely not enough unallocated space at the target offset.

**Resolution.** Automatic. The script calls `Restore-OSPartitionSize` to re-extend C: and returns `$null` from `Ensure-AdequateRecoveryPartition`. The main flow falls through to OS-fallback. The run exits with `EXIT_WARNING`.

If `Restore-OSPartitionSize` also fails, `$Script:GeometryRestoreFailed` is set and the state file is deleted. The next run will re-attempt the destructive path from scratch.

## Drive letters exhausted

**Symptom.** The script cannot assign a drive letter to the newly created recovery partition.

**Log lines.**

```
No drive letter available
```

or

```
Exhausted all candidate letters for disk <n> part <m>
```

**Cause.** All 26 drive letters are in use by volumes or mapped drives.

**Resolution.** Manual. The script calls `Remove-OrphanPartition` on the new partition and returns `$null`. The main flow falls through to OS-fallback.

Before retrying, free a drive letter. Check `Get-PSDrive -PSProvider FileSystem` and `net use` for mapped drives that can be removed.

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

**Expected during the v44 patch 1 rollout.** The v44 patch 1 revision added CPU vendor/generation and VMD presence to the `DesiredStateId`. Every managed machine's stored state file, written under v43, no longer matches the ID computed under v44. The `No valid state (missing or stale) - rebuilding` line will appear on every machine on its first run after the update. This is the intended behaviour and is not a defect. Subsequent runs take the fast path once the state file is rewritten under the new ID.

If the state file is repeatedly disappearing on a machine that has already taken one full-update pass under v44, check:

1. Whether `Restore-OSPartitionSize` is failing. If it is, `$Script:GeometryRestoreFailed` is set and `Write-WinREState` deletes the state file on purpose. The log will show `Write-WinREState: OS partition geometry could not be verified after a failed destructive attempt - deleting state file`. Investigate why the geometry restore is failing.
2. Whether the file is being deleted by something else (antivirus, cleanup task, GPO). `C:\Recovery\OEM\` is not a location that should be cleaned by any standard tooling.
3. Whether the loop-breaker is firing because the enable-failure counter reached 3. The state file is deliberately left in place in that case (the operator deletes it manually to reset the counter), but if a cleanup tool is configured to remove anything in `C:\Recovery\OEM\` on a schedule, it will also remove the state file for this reason.

**Not to be confused with the Audit Mode, OS-fallback BitLocker, or injection-failure deferrals.** If the run exits with `EXIT_WARNING` because a deferral fired, the state file will also be unchanged — but that is not a problem with the state file. The three are distinguishable: the deferrals leave the prior state file intact (or leave it absent if it was absent before); they do not delete it. If a state file existed before the run and still exists after, the deferral is the explanation. If a state file existed before and is gone after, `Restore-OSPartitionSize` or an external cleanup task is the explanation.

**Not to be confused with the enable-only failure path either.** The enable-only failure path **writes** the state file with a non-`"ok"` `LastEnableResult` and an incremented counter. The state file's `LastUpdated` timestamp will be newer than the run start, and its `EnableFailureAttempts` will be non-zero. If you were expecting the state file to be absent, this is what happened.

## The machine is in OS-fallback and stays there

**Symptom.** The state file records `UsedOSFallback: true` and the script keeps exiting with code 2 without re-attempting the dedicated partition.

**Cause.** This is deliberate. The `DesiredStateId`-scoped retry policy (v41) preserves the OS-fallback outcome for the current state so that a machine that cannot shrink the OS does not re-run the destructive path on every run.

**Resolution.** If you want the machine to retry:

1. The most common reason to re-arm the retry is a `ScriptVersion` bump, a manifest `version` change, a change in CPU generation, or a change in VMD presence — any of which changes the `DesiredStateId`. Ship one of those, or wait for the next one.
2. Alternatively, delete `C:\Recovery\OEM\winre_state.json` manually. The next run will treat the state as absent and re-run the full-update path.
3. Or change the hardware in a way that changes `Manufacturer` / `Model` / `MachineType`. Not recommended.

Do not edit the state file's `UsedOSFallback` field and leave the rest in place; that will not change the `DesiredStateId` and the fast path will continue to fire.

**Special case.** A machine that reached OS-fallback because of the pre-patch-5 Device Encryption failure (Section 1) has this exact state. Do not try to force the retry by editing the state file. Follow the Section 1 recovery procedure.

**Not to be confused with a deferral.** A machine on which an Audit Mode, OS-fallback BitLocker, or injection-failure deferral fired will also exit with code 2 and will also leave the state file as-is, but `UsedOSFallback` is not set — the state file is simply unchanged.

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

The harness (Option 9, VMD drivers) also logs a warning with the raw CPU string when an Intel CPU is detected but its generation cannot be parsed, which makes this failure mode visible.

## The script is running but nothing is happening

**Symptom.** The script runs, exits 0, and does nothing.

**Cause.** This is the fast path. The machine is already in the correct end state.

**Resolution.** None needed. If you want to see what the fast path observed, run `scripts\Test-WinRE.ps1` Option 1. It reports the machine's state from the same vantage point the production script uses. Option S reports whether the state file's `DesiredStateId` matches the ID production would compute right now.

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

The dry run does not write to the state file or the checkpoint file. It does not modify partitions, BitLocker, drive letters, or WinRE registration. The guarantee is structural, not per-step:

- The Audit Mode guard is read-only and logs `Would defer …` when the live run would defer.
- The drive-letter assignment is skipped under DryRun; the caller works with the original `\\?\GLOBALROOT` path.
- The **full-update pipeline** terminates at a single choke point at the top of the full-update path. It logs a plan for Steps 1 through 7 and exits cleanly without running `dism`, 7-Zip, or any file I/O in WorkDir.
- The **destructive partition path** in `Ensure-AdequateRecoveryPartition` terminates at a single choke point immediately after the read-only pre-checks and pre-deletion inventory. It logs a plan for the delete, extend, shrink, create, format, and attribute steps.
- Every state-modifying helper handles DryRun internally: `Set-RecoveryPartitionReadyForWinRE`, `Invoke-ReagentcEnable`, `Write-WinREState`, `Remove-StrayRecoveryPartitions`, `Remove-ItemIfExist`, `Restore-OSPartitionSize`, `Remove-OrphanPartition`, `Set-RecoveryPartitionAttributes`, `Invoke-DriveLetterAssignment`, `Invoke-DriveLetterRemoval`, `Invoke-VendorExtraction`, `Invoke-CabExtraction`, `Invoke-OemPackDownload`, `Invoke-DismMount`, `Set-Checkpoint`, `New-DirectoryIfNotExists`.

Two checks run under `-DryRun` in read-only form and log a `Would defer …` or `Would refuse …` line when the live run would not proceed:

- **Audit Mode guard.** Reads `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` → `ImageState`. Logs `Would defer WinRE Manager: Windows is not in a normal-running state (Setup\State\ImageState=…)` when the value is present and is not `IMAGE_STATE_COMPLETE`. Continues.
- **Enable-failure loop-breaker.** Logs `Would refuse to retry reagentc /enable: …` when the live run would fire the loop-breaker. Continues.

A dry run that reports either of these is telling you the machine would be deferred on the next live run. Address the underlying condition before running the script for real.

The DryRun contract for the OS-fallback BitLocker gate is that the gate is logged but does not short-circuit. If the OS-fallback route is reached under DryRun, the gate logs `OS-fallback deferred: C: VolumeStatus=…` and continues — but the deployed WIM plan downstream is not evaluated against C:'s state, because no WIM is deployed under DryRun.

Under DryRun, the exact outcome of a live run is not predicted: `Invoke-ReagentcEnable` logs `[DRY RUN] Would call reagentc /enable …` and returns `"ok"`, and the caller's `"ok"` branch runs normally. The operator reads the plan from the log rather than the exit code. A live run on the same machine may succeed, may require a reboot, or may take the registration-repair path, depending on what `reagentc /enable` actually reports.

## Reporting a bug

See [CONTRIBUTING.md](../CONTRIBUTING.md). Include:

- `WinRE.ps1` version.
- Windows build.
- Vendor, model, Lenovo machine type.
- Partition style (GPT or MBR).
- BitLocker state — **both** `Protection Status:` and `Conversion Status:` from `manage-bde -status C:`. The `Conversion Status` value matters: on the OS-fallback route, `Fully Encrypted` with `Protection Off` is the ambiguous state that the script defers on, and on the dedicated-partition route, the target partition's conversion status is what determines whether `Set-RecoveryPartitionReadyForWinRE` will need to run `manage-bde -off`. Omitting the conversion status makes the report impossible to diagnose.
- The target recovery partition's BitLocker state — the `manage-bde -status` output for the partition reagentc is registered to. The harness's `Test-WinRE.ps1` Option 1 reports this automatically.
- `ImageState` from `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State` if the machine may be in Audit Mode or OOBE.
- Exit code.
- The relevant slice of the log — not the whole file unless asked.
- The output of `Test-WinRE.ps1` Option 1, which reports what the production script would see on this machine and includes the BitLocker, Windows Setup state, target-partition state, and classifier verdicts. If the report is about the fast path or the state file, also include the output of Option S.

## Related documents

- [exit-codes.md](exit-codes.md) — what each exit code means.
- [architecture.md](architecture.md) — where each failure mode fits in the pipeline.
- [testing.md](testing.md) — how to use the harness to diagnose.
