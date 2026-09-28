# Driver injection

WinRE Manager injects two kinds of drivers into the base WIM:

1. **OEM WinPE driver pack** — one per vendor (Dell, HP, Lenovo).
2. **Intel VMD storage drivers** — one or more per manifest entry, if the machine's CPU generation is in range and VMD hardware is present.

Both injections run inside Step 3 (mount, inject, dismount). This document covers the manifest schema, the source URLs, the extraction per vendor, and the success gate.

## The manifest

The manifest is a JSON file hosted on GitHub Gist. `WinRE.ps1` reads it from `$DriverManifestUrl` at the top of the script.

### Schema

```json
{
    "version": "2026-09-27-a",
    "drivers": [
        {
            "name": "Intel VMD 12th-14th Gen",
            "os": ["Win10", "Win11"],
            "match": {
                "cpuGenMin": 12,
                "cpuGenMax": 14,
                "requiredDevices": [
                    "PCI\\VEN_8086&DEV_467F",
                    "PCI\\VEN_8086&DEV_9A0B"
                ]
            },
            "driverUrl": "https://github.com/.../vmd-12-14.7z"
        }
    ]
}
Field meanings
version — the manifest version string. Goes into DesiredStateId. Bump it whenever a driverUrl changes.

drivers[].name — display name, used in logs.

drivers[].os — array of OS identifiers the driver supports. Valid values: "Win10", "Win11".

drivers[].match.cpuGenMin — minimum Intel CPU generation.

drivers[].match.cpuGenMax — maximum Intel CPU generation.

drivers[].match.requiredDevices — array of device hardware IDs. If set, the driver is only downloaded if a matching PnP device is present on the machine. If absent or empty, the driver is downloaded regardless of hardware.

drivers[].driverUrl — URL to a .7z archive containing one or more driver INFs.

VMD hardware presence
The script reads all requiredDevices values from all manifest entries into a single regex, then matches against Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match $pattern }. If at least one device matches, VMD hardware is considered present.

If a manifest entry has requiredDevices but the machine has no matching device, that driver is skipped. The log records Skipping <name>: no matching VMD hardware detected.

The OEM pack source
Each vendor has its own map hosted on GitHub Gist. The map schema is per-vendor.

Dell ($DellWinPEMapUrl)
json
{
    "Generated": "2026-09-27 12:00:00",
    "Count": 3,
    "Packs": {
        "WinPE11": {
            "name": "Dell WinPE 11 Driver Pack",
            "dellVersion": "A26",
            "releaseId": "...",
            "date": "2026-09-15",
            "url": "https://downloads.dell.com/.../....cab",
            "md5": "...",
            "sha256": "...",
            "sizeBytes": 123456789
        },
        "WinPE10": { ... },
        "Current": { ... }
    }
}
Selection: $key = if ($Hardware.IsWin11) { "WinPE11" } else { "WinPE10" }. The pack's sha256 is verified after download. Format is CAB.

HP ($HPWinPEMapUrl)
json
{
    "Generated": "...",
    "Count": 1,
    "Packs": {
        "WinPE1011": {
            "winpeVersion": "WinPE 10/11",
            "version": "5.00.11",
            "softPaqId": "sp123456",
            "date": "2026-09-01",
            "url": "https://ftp.ext.hp.com/.../sp123456.exe"
        },
        "Current": { ... }
    }
}
Selection: always WinPE1011. HP does not currently publish per-OS versions. Format is SoftPaq (a self-extracting EXE). No hash is present in the HP map; the script requires the download to complete cleanly but cannot verify integrity.

Lenovo ($LenovoWinPEMapUrl)
json
{
    "Generated": "...",
    "Count": 500,
    "Models": {
        "21L1": {
            "model": "ThinkPad T14 Gen 4",
            "winpe": {
                "dsId": "DS123456",
                "name": "ThinkPad T14 Gen 4 WinPE 11 Driver Pack",
                "url": "https://download.lenovo.com/.../ds123456.exe",
                "sha256": "...",
                "size": 123456789,
                "osId": "11",
                "version": "1.0.0"
            }
        }
    }
}
Selection: $entry = $Script:LenovoWinPEMap.Models.$mt where $mt is the machine type. Format is EXE (Inno Setup). The sha256 is verified after download.

Download
All three downloads go through Invoke-OemPackDownload, which:

Removes any existing file at the destination.

Retries up to 3 times on exception.

Verifies SHA256 and/or MD5 if the map provides them.

Accepts a hashless download only if Invoke-WebRequest completed cleanly on the same attempt.

The last rule is important. Invoke-WebRequest can throw an exception after writing the file (connection reset while waiting for a final ACK). Without the rule, a partial file left by a throwing request would be treated as a successful download. The script removes the file and retries.

Extraction
Extraction is per-vendor.

Lenovo (Inno Setup EXE)
text
<exe> /VERYSILENT /DIR="<path>" /SILENT /SUPPRESSMSGBOXES
Runs the self-extractor. Lenovo's Inno Setup packages ignore -o flags meant for other extractors; Start-Process -Wait blocks until the installer exits.

Some Lenovo packages return a non-zero exit code on success and still populate the target. The script counts INF files after extraction; if any are present, the extraction is treated as success regardless of exit code.

HP (SoftPaq EXE)
text
<exe> /s /e /f "<path>"
/s silent, /e extract without launching setup, /f destination folder.

Dell (CAB)
7-Zip:

text
7z.exe x <cab> -o"<path>" -y
The INF count is checked. If zero, the extraction is treated as failure even on a clean 7-Zip exit.

Common check
For all three vendors, Get-InfFileCount -Directory <extractDir> is called after extraction. Zero INFs is a failure.

This is the "Lenovo SCCM Package issue": some Lenovo packages extract successfully but contain no INFs because they are WinPE boot-image bundles rather than driver-only packs. The INF count catches this.

Injection
Add-WindowsDriver -Path <MountDir> -Driver <extractDir> -Recurse.

Add-WindowsDriver is called with -ErrorAction SilentlyContinue -ErrorVariable dismErrors so the errors can be logged. The function is silent on the shell but the errors are captured.

The success gate
This is the part of the design that is least obvious and most important.

Why the naive gate does not work
The obvious approach is: $added = @($result | Where-Object { $_.Operation -in @("Add","Installed") }) and check $added.Count -gt 0. This does not work.

Add-WindowsDriver's returned objects do not reliably expose an Operation property with values "Add" or "Installed" across DISM builds. On Windows 11 build 26100 the filter returns zero items even when injection succeeded. Confirmed on Lenovo 21L1: extraction produced 14 INFs, pre-injection third-party count was 0, post-injection was 14, but the return-shape filter reported 0.

The INF-basename cross-reference
The script computes:

$extractedInfNames — the basenames (lowercased) of every INF in the extracted package.

$preInjectThirdParty — the count of third-party drivers in the mounted image before injection. Third-party is defined as ProviderName -ne 'Microsoft Corporation'.

$postInjectThirdParty — the same count after injection.

$imageInfNames — the basenames (lowercased) of the OriginalFileName property of every third-party driver in the mounted image after injection.

The success gate is:

text
success if  (($postInjectThirdParty - $preInjectThirdParty) > 0)
         OR (@($extractedInfNames | Where-Object { $_ -in $imageInfNames }).Count > 0)
In words: the injection succeeded if either new drivers were added (delta > 0) or the package's INFs are present in the image (already there before this run).

Failure (both conditions false) means the package's INFs cannot be demonstrated in the image. The script logs this as injection failed and sets $Script:ImageInjectionComplete = $false and $Script:nonFatalWarning = $true.

Why both conditions are needed
The delta > 0 branch handles the common case: fresh injection into an image with no prior third-party drivers.

The INF basenames match branch handles the re-run case: the image already has the package's drivers, so injection is a no-op and the delta is 0. This happens when a machine re-runs the same DesiredStateId and the base WIM is the previously-deployed one.

The two conditions together avoid both false negatives ("the injection worked but the return-shape filter is unreliable") and false positives ("the image happens to have unrelated third-party drivers from the base WIM").

Why this matters
A base image carrying unrelated third-party drivers would pass a count-based gate even if the OEM package failed entirely. The cross-reference catches that: if the OEM package's INFs are absent and no new drivers were added, the injection failed, regardless of how many drivers the base image already contains.

The VMD injection path
VMD injection uses the same success gate but runs after OEM injection, so $preVmdThirdParty is captured after the OEM injection result. This is deliberate: the VMD gate's job is to verify that the VMD package contributed drivers, not that the image has any third-party drivers at all.

For each manifest driver that matches (OS, Intel CPU, CPU generation, VMD hardware present):

Download driverUrl to $WorkDir\driver_<name>.7z.

Extract with 7-Zip to $WorkDir\drv_extract_<name>.

Collect INF basenames.

Then Add-WindowsDriver -Driver $allDirs -Recurse in one call.

The same INF cross-reference gate applies. A failure sets $Script:ImageInjectionComplete = $false.

When injection fails
A failed injection does not stop the pipeline. The script continues to Step 4 and the full-update path. What changes is:

$Script:ImageInjectionComplete = $false.

$Script:nonFatalWarning = $true.

Step 3 and Step 4 checkpoints are not advanced (v43 patch 4).

The final state-write gate is skipped, so no state file is written.

The exit code is EXIT_WARNING (2).

The next run will attempt injection again. The migration guard resets $step to 2 to force Step 3 to re-run even if the checkpoint was orphaned at a higher step.

Related documents
architecture.md — where Step 3 fits in the pipeline.

state-and-idempotency.md — how ImageInjectionComplete gates the state write.

troubleshooting.md — diagnosing injection failures.

text

---

## `docs/testing.md`

```markdown
# Testing

This document covers `Test-WinRE.ps1`, the read-only harness that ships with WinRE Manager.

## What the harness is

An interactive PowerShell script that:

- Exercises the download and extraction paths of the production script against live sources.
- Runs a parser self-test against the local Windows tooling to verify that every regex and API dependency the production script relies on still produces the expected shape.
- Reports results as PASS / FAIL / SKIP.
- Modifies nothing. Does not touch partitions, BitLocker, WinRE registration, drive letters, or the state file. Does not require elevation.

It is the primary tool for pre-flight validation on an unfamiliar machine.

## Running it

```powershell
# Interactive
.\scripts\Test-WinRE.ps1

# Non-interactive: runs "all relevant for this machine" and exits
.\scripts\Test-WinRE.ps1 -NonInteractive

# Do not offer to delete the working directory on exit
.\scripts\Test-WinRE.ps1 -Keep

# Custom working directory
.\scripts\Test-WinRE.ps1 -TestDir D:\WinRETest
The default working directory is C:\Temp\WinRETest. All downloads and extractions go there.

The menu
text
  1. System diagnostic (read-only info gathering)
  2. Driver manifest fetch
  3. OEM maps fetch + resolve (Dell, HP, Lenovo)
  4. GitHub base WIM - Win10 (download + extract + build check)
  5. GitHub base WIM - Win11 (download + extract + build check)
  6. HP WinPE pack (download + extract)
  7. Dell WinPE pack (prompts for OS)
  8. Lenovo WinPE pack (prompts for MT)
  9. VMD drivers (per manifest, filtered for this machine)
  A. All relevant for this machine
  B. All of the above
  R. Print results summary
  Q. Quit
Option 1 — System diagnostic
Read-only information gathering. Dumps:

Hardware: manufacturer, model, product name/version, baseboard, CPU, OS build, Intel generation.

Raw reagentc /info output and the parsed status/location.

The WinRE classifier verdict: DEDICATED, OS-fallback, RECOVERY-ON-SECONDARY, or UNEXPECTED. Matches the v43 patch 2 production classifier.

OS partition and OS disk.

All disks with BootFromDisk, IsSystem, IsBoot.

All partitions with size, drive letter, label, GPT type, MBR type, and boot/system/active flags.

All volumes with file system, free space, label, and health.

Recovery partitions per Get-RecoveryPartitions, with isTyped, isLabel, and onOsDisk annotations.

The OS partition's SizeMin, SizeMax, shrinkable bytes, extendable bytes, and S == M status.

The bucket sizing preview: for the active WIM's size, what bucket the production script would compute.

BitLocker on C: (ProtectionStatus, VolumeStatus, EncryptionMethod, EncryptionPercentage).

VMD hardware presence per manifest.

Then it runs the parser self-test (below).

Options 2 through 9 and A/B
Exercise the download and extraction paths. Each option:

Downloads the source.

Extracts with the appropriate tool.

Counts INF files for driver packs.

For WIM downloads, extracts the WIM and reads its build with Get-WindowsImage.

Option A runs the subset relevant to the current machine (its OS, its vendor, its CPU). Option B runs everything.

The parser self-test
Ten checks. Each records PASS, FAIL, or SKIP in $Script:Results and prints a matching [OK]/[FAIL]/[SKIP] line.

#	Check	What it verifies
1	reagentc status regex	(Enabled|Disabled) matches at least one line of reagentc /info output.
2	reagentc location regex	(GLOBALROOT|Volume GUID) matches at least one line.
3	manage-bde protection regex	Protection On or Protection Off appears.
4	manage-bde conversion status regex	A Conversion Status: value matches, or the string could not be opened by BitLocker appears.
5	Get-BitLockerVolume shape	ProtectionStatus and VolumeStatus are non-null. SKIP if not elevated.
6	OS resolution	Get-OSPartition and Get-OSDisk both resolve.
7	Get-Partition shape	A sample partition exposes DiskNumber, PartitionNumber, Size, GptType, MbrType, IsBoot, IsSystem, IsActive.
8	WinRE location resolution	The reagentc location resolves to a partition. SKIP if location is empty.
9	Get-RecoveryPartitions	Returns at least one partition.
10	Get-PartitionSupportedSize	Returns SizeMin and SizeMax. SKIP if no OS partition.
What a FAIL means
A FAIL means the machine's Windows tooling no longer matches an assumption the production script relies on. The production script may silently misclassify state on this machine and must be adapted before deploying to it.

The three most likely FAILs and their implications:

Check 3 or 4 (manage-bde regex). Windows changed manage-bde -status output format on this build. Production's BitLocker detection will fail; the script's Test-BitLockerProtected will return $null (unknown) and the destructive paths will refuse to run. The machine is safe but unreachable by the deployment.

Check 7 (Get-Partition shape). The Storage module is missing or reduced. Production's partition classification will fail.

Check 10 (Get-PartitionSupportedSize). The shrink path will fail. The script will fall back to OS-fallback after the OS-shrink attempt, but this is a machine-specific failure that should be investigated.

What a SKIP means
A SKIP means the check could not run in the current context. The two reasons:

Not elevated. Get-BitLockerVolume requires elevation on some machines. The check SKIPs rather than FAILing.

The state it inspects is absent. WinRE location is empty, no OS partition, or similar. The check has nothing to inspect.

A SKIP does not indicate a defect.

Result states
Every test records a result via Record:

powershell
Record -Test "<name>" -Ok $true   -Detail "<description>"                        # PASS
Record -Test "<name>" -Ok $false  -Detail "<description>"                        # FAIL
Record -Test "<name>" -Ok $false  -State "SKIP" -Detail "<reason>"               # SKIP
The legacy -Ok boolean is still supported: when -State is not supplied, the state is derived from -Ok. When -State is supplied it is authoritative, and OK is $true only for PASS.

Show-Summary prints each result, then the totals:

text
Passed 8, failed 1, skipped 1 (of 10)
Non-interactive mode
powershell
.\scripts\Test-WinRE.ps1 -NonInteractive
Runs Invoke-AllRelevant, prints the summary, exits.

The exit code is always 0, regardless of results. The summary is the source of truth. If a pipeline consumer is added later, the minimal change to make the exit code reflect pass/fail is to count FAIL records in $Script:Results and exit non-zero when any exist. This is documented in the v11 changelog but not implemented, on the grounds that no consumer currently needs it.

What the harness does not test
The harness is deliberately narrow. It does not and cannot test:

Partition creation, deletion, or resize. No destructive operations.

BitLocker suspension or resume. No state changes.

reagentc /setreimage or reagentc /enable. No WinRE registration changes.

State file or checkpoint file writes. Those files are production-only artifacts.

The full-update pipeline. The harness exercises the download and extraction steps in isolation, not the pipeline.

Those paths are covered by field testing on representative hardware. See the "Field-tested hardware" table in the README.

Differences from production
The harness shares code paths with production in the download, extraction, and CPU-generation helpers. It is documented in the file's own docstring which functions are "based on" the production versions and which are harness-specific.

Two known differences:

Get-ThisMachineProfile is harness-specific. It uses BuildNumber -ge 22000 to detect Windows 11; production uses $os.Caption -like "*Windows 11*". The two agree on every Windows 11 client SKU but diverge on Server SKUs with build ≥ 22000. Neither the harness nor production is expected to run on Server.

Test-VmdDrivers does not filter on VMD hardware presence. Production skips manifest entries whose requiredDevices do not match anything on the machine. The harness intentionally does not — it validates every OS/CPU-eligible URL and extraction path from a single machine, regardless of installed hardware. This makes the harness a package validator, not a machine-specific compatibility test.

Adding a test
The harness is a single file. To add a test:

Write a function that follows the existing pattern: log via Say, record the result via Record.

Add a menu entry in Show-Menu.

Add a case to the switch in the main loop.

If the test should run as part of "all relevant for this machine," add it to Invoke-AllRelevant.

Do not add tests that modify the machine's state. The harness's contract with the operator is that it is read-only.

Related documents
troubleshooting.md — how to use the diagnostic output to diagnose a failure.

driver-injection.md — what the injection tests are actually testing.

text

---

## `docs/troubleshooting.md`

```markdown
# Troubleshooting

Per-symptom playbook. Each section names the symptom, the log lines to look for, the likely causes, and the resolution.

Log location: `C:\ProgramData\OEM\Logs\WinRE-Manager.log`.

## How to read the log

Every line is `yyyy-MM-dd HH:mm:ss [LEVEL] message`. Levels are `INFO`, `WARN`, `ERROR`, `FATAL`. In `-DryRun` mode, every line is prefixed with `[DRYRUN-<LEVEL>]` instead so a dry-run audit can be distinguished from a live run.

The first line is `========== WinRE Manager Started (v<version>) ==========`. The last line names the outcome and, if applicable, the exit code.

## `reagentc /enable` fails with "cannot be enabled on a volume with BitLocker Drive Encryption enabled"

**Symptom.** `reagentc /enable` returns non-zero, output contains the phrase above.

**Log lines.**
reagentc /enable (exit 2): ...
reagentc /enable failed because the target volume is BitLocker-protected

text

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
reagentc /disable: exit=<n>, output=<output>
reagentc /disable failed (exit <n>): <output>
FATAL: cannot deploy a new WinRE image while WinRE is still Enabled - aborting

text

**Cause.** `reagentc /disable` returned non-zero. Common causes: a pending WinRE operation from a previous run, corruption in `ReAgent.xml`, or a locked recovery partition.

**Resolution.** Manual. The script exits with `EXIT_FATAL` and does not write state. Investigate:

1. Check `C:\Windows\System32\Recovery\ReAgent.xml` for corruption. If the file exists but is malformed, delete it (after `attrib -h -s -r`) and retry.
2. Check `C:\Recovery\WindowsRE\winre.wim` for a lock. `handle.exe` or `Process Explorer` will show the holder.
3. Check `reagentc /info` for the current state. If it reports a state that does not match reality (e.g. `Enabled` when WinRE is disabled), the registration is stale. `reagentc /setreimage /path C:\Recovery\WindowsRE` followed by `reagentc /enable` may repair it.

## `dism /Export-Image` fails

**Symptom.** Step 4 of the full-update path.

**Log lines.**
dism /Export-Image failed with exit code <n>

text

or
dism /Export-Image reported success but <path> does not exist

text

**Cause.** DISM failure. Common causes: the source WIM is corrupt or incomplete, the destination volume is full, or the WIM has already been mounted by an interrupted run.

**Resolution.** Manual. The script exits with `EXIT_FATAL`.

1. Check `C:\Temp\WinREWork\base.wim` for size and integrity.
2. Check free space on `C:\Temp` and on the volume where `winre_optimized.wim` is being written.
3. Check `Get-WindowsImage -Mounted` for stale mounts. If any mount's path is under `C:\Temp\WinREWork`, dismount it with `-Discard`.
4. Delete `C:\Temp\WinREWork` and let the next run start fresh.

## Base WIM download fails

**Symptom.** Step 2 of the full-update path, only reached when there is no usable WIM at the reagentc-registered location or via fallback.

**Log lines.**
No active or fallback WinRE image found - forcing rebuild
Step 2: Obtaining base WIM
7-Zip required

text
followed by a download error or a `FATAL` exit.

**Cause.** The GitHub repository hosting the base WIM is unreachable, the parts are missing, or 7-Zip is not installed and could not be installed via `winget`.

**Resolution.** Manual. The script exits with `EXIT_FATAL`.

1. Verify network access to `api.github.com` and the configured `$BaseWinRERepoApi` URL.
2. Verify 7-Zip is present at `C:\Program Files\7-Zip\7z.exe`. If not, install it via `winget install 7zip.7zip --scope machine` from an elevated shell.
3. Check the GitHub repository for the expected `winre.7z.NNN` parts. If the parts are missing, point the script at a mirror or restore the parts.

## `New-Partition` fails after 3 attempts

**Symptom.** The OS partition has been shrunk, the recovery partitions have been deleted, and the script cannot create the new partition.

**Log lines.**
New-Partition attempt 1 failed: ...
New-Partition attempt 2 failed: ...
New-Partition attempt 3 failed: ...
New-Partition failed after 3 attempts

text

**Cause.** The disk geometry changed between the shrink and the create (uncommon), or there is genuinely not enough unallocated space at the target offset.

**Resolution.** Automatic. The script calls `Restore-OSPartitionSize` to re-extend C: and returns `$null` from `Ensure-AdequateRecoveryPartition`. The main flow falls through to OS-fallback. The run exits with `EXIT_WARNING`.

If `Restore-OSPartitionSize` also fails, `$Script:GeometryRestoreFailed` is set and the state file is deleted. The next run will re-attempt the destructive path from scratch.

## Drive letters exhausted

**Symptom.** The script cannot assign a drive letter to the newly created recovery partition.

**Log lines.**
No drive letter available

text
or
Exhausted all candidate letters for disk <n> part <m>

text

**Cause.** All 26 drive letters are in use by volumes or mapped drives.

**Resolution.** Manual. The script calls `Remove-OrphanPartition` on the new partition and returns `$null`. The main flow falls through to OS-fallback.

Before retrying, free a drive letter. Check `Get-PSDrive -PSProvider FileSystem` and `net use` for mapped drives that can be removed.

## `Get-BitLockerVolume` returns null

**Symptom.** `Suspend-BitLockerForWinRE` falls back to parsing `manage-bde -status`.

**Log lines.**
BitLocker Get-BitLockerVolume on C: returned null - falling back to manage-bde -status text parsing

text

**Cause.** The BitLocker module is not loaded, the cmdlet failed, or the machine lacks the BitLocker feature. This is common on client SKUs where BitLocker is not enabled or on Windows Home.

**Resolution.** Automatic. The fallback path parses `manage-bde -status` output for `Protection On` or `Protection Off`. If the parse succeeds, the script proceeds normally. If the parse fails (neither string present), `$protectionState` remains `$null` and `Suspend-BitLockerForWinRE` refuses to proceed.

The refusal is deliberate: the script will not assume BitLocker is off when it cannot confirm. The destructive paths abort and the main flow falls back to OS-fallback.

## VMD hardware present but no driver matches

**Symptom.** A machine with a VMD controller (Intel 12th gen and later typically) does not get VMD drivers injected.

**Log lines.**
VMD hardware present: True
Required drivers (VMD): 0

text
or
Skipping <name>: CPU gen <n> outside <min>-<max>

text

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
BitLocker protection state on C: could not be determined - refusing to treat as unprotected

text

**Cause.** A Windows build changed `manage-bde -status` output format. The regexes for `Protection On` / `Protection Off` / `Conversion Status:` no longer match.

**Resolution.** Manual.

1. Run `manage-bde -status C:` from an elevated shell and capture the output.
2. Run `scripts\Test-WinRE.ps1`, Option 1. The parser self-test checks 3 and 4 will FAIL, and the raw `manage-bde -status` output is dumped to the diagnostic. Compare the format to the regexes in `Test-BitLockerProtected`, `Test-BitLockerSuspended`, and `Test-VolumeEncrypted`.
3. Update the regexes in `scripts/WinRE.ps1` and mirror them in `scripts/Test-WinRE.ps1`.
4. File an issue with the raw output and the Windows build number.

## `reagentc /info` location regex fails

**Symptom.** The parser self-test check 2 fails, or the script cannot resolve the WinRE location.

**Log lines.**
Parser: reagentc location [FAIL] ...did not match any line

text

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
