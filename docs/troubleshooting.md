# Troubleshooting

Per-symptom playbook. Each section names the symptom, the log lines to look for, the likely causes, and the resolution.

Log location: `C:\ProgramData\OEM\Logs\WinRE-Manager.log`.

## How to read the log

Every line is `yyyy-MM-dd HH:mm:ss [LEVEL] message`. Levels are `INFO`, `WARN`, `ERROR`, `FATAL`. In `-DryRun` mode, every line is prefixed with `[DRYRUN-<LEVEL>]` instead so a dry-run audit can be distinguished from a live run.

The first line is `========== WinRE Manager Started (v<version>) ==========`. The last line names the outcome and, if applicable, the exit code.

## `reagentc /enable` fails with "cannot be enabled on a volume with BitLocker Drive Encryption enabled"

**Symptom.** `reagentc /enable` returns non-zero, output contains the phrase above.

**Log lines.**

```
reagentc /enable (exit 2): ...
reagentc /enable failed because the target volume is BitLocker-protected
```

**Cause.** The target recovery partition is BitLocker-encrypted. This happens on Windows 11 24H2+ with TPM 2.0 and Secure Boot, where Device Encryption auto-encrypts newly created partitions.

**Resolution.** Automatic. The production script detects this specific error, returns `"bitlocker"` from `Invoke-ReagentcEnable`, and the caller:

1. Suspends BitLocker on C:.
2. Deletes the encrypted recovery partition.
3. Recreates it (with attributes set before drive-letter assignment, per v35).
4. Redeploys the WIM.
5. Retries `reagentc /enable`.

If the retry also fails, the script logs `reagentc /enable still failed after partition recreation` and continues with the remaining pipeline. The run exits with `EXIT_WARNING`.

If the script cannot suspend BitLocker (see below), it aborts the recovery attempt and continues with the WIM already deployed, which may or may not be usable.

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

**Symptom.** `Suspend-BitLockerForWinRE` falls back to parsing `manage-bde -status`.

**Log lines.**

```
BitLocker Get-BitLockerVolume on C: returned null - falling back to manage-bde -status text parsing
```

**Cause.** The BitLocker module is not loaded, the cmdlet failed, or the machine lacks the BitLocker feature. This is common on client SKUs where BitLocker is not enabled or on Windows Home.

**Resolution.** Automatic. The fallback path parses `manage-bde -status` output for `Protection On` or `Protection Off`. If the parse succeeds, the script proceeds normally. If the parse fails (neither string present), `$protectionState` remains `$null` and `Suspend-BitLockerForWinRE` refuses to proceed.

The refusal is deliberate: the script will not assume BitLocker is off when it cannot confirm. The destructive paths abort and the main flow falls back to OS-fallback.

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

## `manage-bde -status` output cannot be parsed

**Symptom.** `Test-BitLockerProtected`, `Test-BitLockerSuspended`, or `Test-VolumeEncrypted` returns `$null` on a machine where BitLocker is clearly in one state or the other.

**Log lines.**

```
BitLocker protection state on C: could not be determined - refusing to treat as unprotected
```

**Cause.** A Windows build changed `manage-bde -status` output format. The regexes for `Protection On` / `Protection Off` / `Conversion Status:` no longer match.

**Resolution.** Manual.

1. Run `manage-bde -status C:` from an elevated shell and capture the output.
2. Run `scripts\Test-WinRE.ps1`, Option 1. The parser self-test checks 3 and 4 will FAIL, and the raw `manage-bde -status` output is dumped to the diagnostic. Compare the format to the regexes in `Test-BitLockerProtected`, `Test-BitLockerSuspended`, and `Test-VolumeEncrypted`.
3. Update the regexes in `scripts/WinRE.ps1` and mirror them in `scripts/Test-WinRE.ps1`.
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

If the state file is repeatedly disappearing, check:

1. Whether `Restore-OSPartitionSize` is failing. If it is, `$Script:GeometryRestoreFailed` is set and `Write-WinREState` deletes the state file on purpose. The log will show `Write-WinREState: OS partition geometry could not be verified after a failed destructive attempt - deleting state file`. Investigate why the geometry restore is failing.
2. Whether the file is being deleted by something else (antivirus, cleanup task, GPO). `C:\Recovery\OEM\` is not a location that should be cleaned by any standard tooling.

## The machine is in OS-fallback and stays there

**Symptom.** The state file records `UsedOSFallback: true` and the script keeps exiting with code 2 without re-attempting the dedicated partition.

**Cause.** This is deliberate. The `DesiredStateId`-scoped retry policy (v41) preserves the OS-fallback outcome for the current state so that a machine that cannot shrink the OS does not re-run the destructive path on every run.

**Resolution.** If you want the machine to retry:

1. The most common reason to re-arm the retry is a `ScriptVersion` bump or a manifest `version` change, either of which changes the `DesiredStateId`. Ship one of those.
2. Alternatively, delete `C:\Recovery\OEM\winre_state.json` manually. The next run will treat the state as absent and re-run the full-update path.
3. Or change the hardware in a way that changes `Manufacturer` / `Model` / `MachineType`. Not recommended.

Do not edit the state file's `UsedOSFallback` field and leave the rest in place; that will not change the `DesiredStateId` and the fast path will continue to fire.

## The script is running but nothing is happening

**Symptom.** The script runs, exits 0, and does nothing.

**Cause.** This is the fast path. The machine is already in the correct end state.

**Resolution.** None needed. If you want to see what the fast path observed, run `scripts\Test-WinRE.ps1` Option 1. It reports the machine's state from the same vantage point the production script uses.

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

The dry run does not write to the state file or the checkpoint file. It does not modify partitions, BitLocker, or WinRE registration.

## Reporting a bug

See [CONTRIBUTING.md](../CONTRIBUTING.md). Include:

- `WinRE.ps1` version.
- Windows build.
- Vendor, model, Lenovo machine type.
- Partition style (GPT or MBR).
- BitLocker state.
- Exit code.
- The relevant slice of the log — not the whole file unless asked.
- The output of `Test-WinRE.ps1` Option 1, which reports what the production script would see on this machine.

## Related documents

- [exit-codes.md](exit-codes.md) — what each exit code means.
- [architecture.md](architecture.md) — where each failure mode fits in the pipeline.
- [testing.md](testing.md) — how to use the harness to diagnose.
