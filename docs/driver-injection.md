---
title: "Driver injection — WinRE Manager"
description: "How WinRE Manager injects OEM WinPE driver packs and Intel VMD storage drivers into the recovery image, the v49 source-ownership classification, and the strip stage that normalizes the base."
---

# Driver injection

WinRE Manager injects two kinds of drivers into the base WIM:

1. **OEM WinPE driver pack** — one per vendor (Dell, HP, Lenovo).
2. **Intel VMD storage drivers** — one or more per manifest entry, if the machine's CPU generation is in range and VMD hardware is present.

Both injections run inside Step 3 (mount, classify source, strip, inject, dismount). As of v47 a strip stage runs between the mount and the injection: it normalizes the mounted image to zero third-party drivers before the current recipe is applied. As of v49 the strip runs **conditionally**, gated by a source-ownership classification; a **never-downgrade storage-driver check** runs after injection completes and before ResetBase; and a **pre-deployment storage-applicability gate** runs after the never-downgrade check, still before ResetBase and before the dismount. This document covers the manifest schema, the source URLs, the extraction per vendor, the v49 source-ownership classification, the strip stage, the never-downgrade check, the applicability gate, and the success gate.

The injection step is the deepest embodiment of two of the project's four design invariants, which [`architecture.md`](architecture.md) states in this order. **Rule 4 — do no work unless needed; prepare everything before touching anything** — is the reason every driver artifact must be resolved, downloaded, extracted, and verified *before* the destructive sequence begins; a rebuild that would have failed at the injection step never touches a partition. **Rule 1 — never break Windows RE** — is the reason injection failure is fatal-on-progression rather than a degraded-success: a WIM that cannot see the OS disk is actively misleading, and the pipeline gate exists to make sure such a WIM never reaches a recovery partition. The v47 strip stage is the mechanism by which Rule 4's "drivers go into a clean base" corollary is enforced; the v49 source-ownership classification narrows that corollary to sources the manager itself deployed or in-box images with no third-party drivers, and the v49 pre-deployment applicability gate is the final refusal before deployment. See [`architecture.md`](architecture.md) — "The v47 rebuild pipeline" — for the strip design, and "The v49 pipeline refinements" for the source-ownership classification and the applicability gate.

## The manifest

The manifest is a JSON file hosted on GitHub Gist. `WinRE.ps1` reads it from `$DriverManifestUrl` at the top of the script.

For how to host your own manifest and OEM maps, see [self-hosting.md](self-hosting.md).

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
                "cpuGenMax": 16,
                "requiredDevices": [
                    "PCI\\VEN_8086&DEV_467F",
                    "PCI\\VEN_8086&DEV_9A0B"
                ]
            },
            "driverUrl": "https://github.com/.../vmd-12-14.7z"
        }
    ]
}
```

### Field meanings

- **`version`** — the manifest version string. Goes into `DesiredStateId`. Bump it whenever a `driverUrl` changes.
- **`drivers[].name`** — display name, used in logs.
- **`drivers[].os`** — array of OS identifiers the driver supports. Valid values: `"Win10"`, `"Win11"`.
- **`drivers[].match.cpuGenMin`** — minimum Intel CPU generation.
- **`drivers[].match.cpuGenMax`** — maximum Intel CPU generation.
- **`drivers[].match.requiredDevices`** — array of device hardware IDs. The union of all `requiredDevices` values across all manifest entries is matched against present PnP devices in a single query; if any device matches, VMD hardware is considered present. A driver entry that declares `requiredDevices` is downloaded only when that machine-wide check succeeds. If `requiredDevices` is absent or empty on an entry, the VMD-presence filter is bypassed for that entry; the OS match and the Intel CPU-vendor / generation range still apply.
- **`drivers[].driverUrl`** — URL to a `.7z` archive containing one or more driver INFs.

**v49 note.** The `requiredDevices` patterns are one of the inputs the pre-deployment storage-applicability gate reads. A manifest that omits a controller present on your fleet will cause the gate to refuse the candidate on machines with that controller. Keep the patterns complete for the hardware you deploy to; a trimmed manifest is the most likely way a self-hoster triggers the applicability gate. See "The pre-deployment storage-applicability gate (v49)" below.

### VMD hardware presence (fail-closed as of v44 patch 6)

The script reads all `requiredDevices` values from all manifest entries into a single regex, then matches against `Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match $pattern }`. If at least one device matches, VMD hardware is considered present.

VMD hardware presence is determined once, from the union of all `requiredDevices` values across all manifest entries, matched against present PnP devices. If that machine-wide determination reports VMD absent, every manifest entry that declares `requiredDevices` is skipped. The log records `Skipping <name>: no matching VMD hardware detected` for each skipped entry.

**As of v44 patch 6, the enumeration is fail-closed.** If `Get-PnpDevice` reports an error during the query — for example, the Plug and Play service is in a bad state, an antivirus or EDR product is blocking device enumeration, or a device in an error state is preventing the PnP manager from completing the query — the script treats VMD presence as **indeterminate** rather than as absent. It does not assume the machine has no VMD hardware.

An indeterminate result means the correct driver set cannot be determined. The run logs the enumeration error, sets `$Script:nonFatalWarning = $true`, removes the checkpoint file, and exits `EXIT_WARNING` **before** committing any state. No WIM is deployed, no partition is touched, no `reagentc` call is made.

Why fail-closed and not "assume absent": on a machine that genuinely has VMD hardware, guessing "absent" would select a driver set that omits the VMD package. The deployed WinRE would not be able to see the OS disk. That is the exact failure mode the v44 patch 1 `DesiredStateId` change was designed to prevent, and an empty device list from an errored enumeration is not evidence of absence. The cost of a deferral is one pipeline run; the cost of guessing wrong is a machine with a non-functional recovery environment. See [troubleshooting.md](troubleshooting.md) for the resolution.

The harness's Option 1 diagnostic (v28) surfaces the machine's storage-controller enumeration alongside the manifest's VMD patterns, which is what the v49 applicability gate reads. See [testing.md](testing.md).

## The OEM pack source

Each vendor has its own map hosted on GitHub Gist. The map schema is per-vendor.

### Dell (`$DellWinPEMapUrl`)

```json
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
        "WinPE10": { },
        "Current": { }
    }
}
```

Selection: `$key = if ($Hardware.IsWin11) { "WinPE11" } else { "WinPE10" }`. The pack's `sha256` is verified after download. Format is CAB.

### HP (`$HPWinPEMapUrl`)

```json
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
        "Current": { }
    }
}
```

Selection: always `WinPE1011`. HP does not currently publish per-OS versions. Format is `SoftPaq` (a self-extracting EXE). No hash is present in the HP map; the script requires the download to complete cleanly but cannot verify integrity.

### Lenovo (`$LenovoWinPEMapUrl`)

```json
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
```

Selection: `$entry = $Script:LenovoWinPEMap.Models.$mt` where `$mt` is the machine type. Format is EXE (Inno Setup). The `sha256` is verified after download.

### Lenovo five-state resolution (v44 patch 6)

Lenovo does not publish WinPE driver packs for every model in their catalog. That is a normal, expected fact about the Lenovo lineup, not a failure of the map or of the script. As of v44 patch 6, the Lenovo resolution distinguishes five states so that the caller can tell a legitimate "no pack available" answer apart from a broken map or a transient network failure.

`Get-LenovoWinPEPack` sets `$Script:LenovoPackResolution` to one of:

| State | Meaning | What the run does |
|---|---|---|
| `unknown-mt` | Machine type could not be determined (`MT=UNKN`). | **Normal.** No pack can ever match. Run recorded as complete with `OEMPACK=NONE`. |
| `no-entry` | Map loaded successfully, but has no entry for this machine type. | **Normal.** Lenovo does not publish a pack for every model. Run recorded as complete with `OEMPACK=NONE`. |
| `map-unavailable` | The map gist could not be downloaded. Transient. | **Incomplete.** `$Script:ImageInjectionComplete = $false`, `$Script:nonFatalWarning = $true`. Pipeline gate aborts before Step 4. Next run retries. |
| `malformed-entry` | The map has an entry for this machine type, but it has no `winpe.url`. | **Incomplete.** Configuration failure of the map, not a legitimate "no pack" answer. Same handling as `map-unavailable`. |
| `resolved` | Pack returned successfully. | Normal injection path. |

Before v44 patch 6, the caller could only distinguish "pack resolved" from "pack did not resolve". A malformed map entry looked identical to a legitimate no-pack case, and the machine would silently complete without OEM driver injection even though the map itself was broken. The five-state resolution closes that gap.

The distinction matters because `unknown-mt` and `no-entry` are **expected, permanent answers** for a substantial fraction of Lenovo hardware. Treating them as failures would force the pipeline gate to fire on every Lenovo machine with no published pack, and those machines would never take the fast path. Treating `malformed-entry` as a legitimate no-pack answer would hide a genuine configuration error in the map. The five states keep the two apart.

The state flows into `DesiredStateId` via the `OEMPACK` field. `unknown-mt` and `no-entry` both produce `OEMPACK=NONE`, so the machine takes the fast path on subsequent runs as long as nothing else has changed. `map-unavailable` and `malformed-entry` do not write a state file at all; the next run recomputes from scratch.

## Download

All three downloads go through `Invoke-OemPackDownload`, which:

- Removes any existing file at the destination.
- Retries up to 3 times on exception.
- Verifies SHA256 and/or MD5 if the map provides them.
- Accepts a hashless download only if `Invoke-WebRequest` completed cleanly on the same attempt.

The last rule is important. `Invoke-WebRequest` can throw an exception **after** writing the file (connection reset while waiting for a final ACK). Without the rule, a partial file left by a throwing request would be treated as a successful download. The script removes the file and retries.

Every network call in `Invoke-OemPackDownload` carries `-TimeoutSec $NetworkTimeoutSeconds` where `$NetworkTimeoutSeconds = 15`. A fully offline machine fails a download within ~15 seconds rather than the ~100-second default.

## Extraction

Extraction is per-vendor. The OEM pack's extraction destination (`$WorkDir\oem_extract`) is cleared and recreated before each extraction. As of **v44 patch 7**, the VMD extraction path does the same for each driver's destination (`$WorkDir\drv_extract_<name>`). Before patch 7, an interrupted earlier run could leave INFs in the VMD directory, and those stale INFs could satisfy the INF-basename cross-reference or contribute to the third-party-driver-count delta and mask a failed VMD extraction.

### Lenovo (Inno Setup EXE)

```
<exe> /VERYSILENT /DIR="<path>" /SILENT /SUPPRESSMSGBOXES
```

Runs the self-extractor. Lenovo's Inno Setup packages ignore `-o` flags meant for other extractors; `Start-Process -Wait` blocks until the installer exits.

Some Lenovo packages return a non-zero exit code on **success** and still populate the target. The script counts INF files after extraction; if any are present, the extraction is treated as success regardless of exit code.

### HP (SoftPaq EXE)

```
<exe> /s /e /f "<path>"
```

`/s` silent, `/e` extract without launching setup, `/f` destination folder.

### Dell (CAB)

7-Zip:

```
7z.exe x <cab> -o"<path>" -w"<path>" -y
```

The INF count is checked. If zero, the extraction is treated as failure even on a clean 7-Zip exit.

### Common check

For all three vendors, `Get-InfFileCount -Directory <extractDir>` is called after extraction. Zero INFs is a failure.

This is the "Lenovo SCCM Package issue": some Lenovo packages extract successfully but contain no INFs because they are WinPE boot-image bundles rather than driver-only packs. The INF count catches this.

## Step 3 ordering (v49)

The Step 3 block runs in this order. The v49 additions are **bolded**:

1. Mount `base.wim`.
2. **Source-ownership classification (v49).** Classify the mounted source into one of four ownership classes. The classification decision determines whether the strip stage runs (step 3) and whether the current recipe is injected (steps 5–6). A `Foreign-With-Drivers` source is preserved as-is: the mounted image is dismounted with `-Discard`, no WIM is exported, no WIM is deployed, and the state file records `ForeignSourceAcceptedHash`. The other three classes proceed through the strip and injection.
3. Strip to zero third-party drivers. Prove zero. **Skipped when the source classified as `Foreign-With-Drivers`** (the pipeline exits before this step on such a source).
4. Capture the pre-injection third-party driver count (expected to be zero after a successful strip).
5. Download, extract, and inject the OEM pack.
6. Download, extract, and inject the VMD packages (if VMD hardware is present).
7. **Never-downgrade storage-driver check (v49).** Compare each storage-class driver in the final image against the pre-strip inventory, by INF basename. If any post-injection driver would be older, the candidate is discarded — dismounted with `-Discard`, the source preserved, the state file records `ForeignSourceAcceptedHash`, and the run exits `EXIT_WARNING`.
8. Verify the injection success gate (`$Script:ImageInjectionComplete`).
9. **Pre-deployment storage-applicability gate (v49).** The candidate must contain an INF matching one of the machine's present SCSIAdapter-class devices. A candidate that does not match is refused, dismounted with `-Discard`, and deferred.
10. **Provenance marker write (v49).** If the `LineageId` is not yet set, generate one; write the marker into the mounted image at `Sources\Recovery\WinRE-Manager\provenance.json`. Non-load-bearing in v49: no gate reads it; a write failure is logged and the pipeline continues.
11. ResetBase (only if injection succeeded).
12. Dismount with `-Save`.

If step 2 classifies the source as `Foreign-With-Drivers`, the pipeline exits immediately after the classification: the mounted image is dismounted with `-Discard`, `base.wim` and `winre_optimized.wim` are removed, `ForeignSourceAcceptedHash` is recorded in the state file, and the run exits `EXIT_WARNING`. Steps 3–12 do not run. If step 3 fails, steps 4–12 never run — the candidate is discarded and the machine is unchanged. If step 7 detects a downgrade, the candidate is discarded; steps 8–12 do not run. If step 9 refuses, the candidate is dismounted with `-Discard` and the run defers; steps 10–12 do not run.

## Source-ownership classification (v49)

Every candidate source WIM is classified into one of four ownership classes before the strip stage runs:

- **`Manager-Owned`** — the staged source hash exactly matches the state file's `CurrentImageHash`, so the bytes are identical to what the manager last deployed. The strip stage runs and the current recipe is injected.
- **`Manager-Lineage`** — a valid provenance marker is present in the mounted image (`Sources\Recovery\WinRE-Manager\provenance.json`) and its `LineageId` matches the state file's. The strip stage runs and the current recipe is injected.
- **`Foreign-No-Drivers`** — no positive ownership evidence, but the source contains zero third-party drivers. The strip stage runs (as a no-op on an already-clean image) and the current recipe is injected.
- **`Foreign-With-Drivers`** — no positive ownership evidence and at least one third-party driver present. The strip stage is **skipped**, and the pipeline exits without deploying: the mounted image is dismounted with `-Discard`, the staged artifacts are removed, the state file records `ForeignSourceAcceptedHash`, and the run exits `EXIT_WARNING`.

The classification gate decides whether the strip-and-reinject pipeline runs. **It is not a source-selection input.** Which of the registered WIM, the hash-validated LKG, or the GitHub cold-start source is used as the base is decided by `Select-BaseWinRESource`, which does not consult the ownership class. The classification is evaluated on whichever source that step chose.

### Why the classification exists

The v47 strip-and-reinject policy was: whatever source the pipeline chose, strip it to zero third-party drivers and inject the current recipe. That policy assumed the source was either a manager-deployed image, a manager-lineage image, or an in-box WIM. It held for the shipped source chain — the registered WinRE, the LKG, and the GitHub in-box WIM — but it did not hold for a source that a vendor tool had populated with its own third-party drivers.

The ASUS-incident field case made the risk concrete: a machine whose registered WinRE had been populated by an OEM servicing tool with vendor-specific third-party drivers was treated by the v47 pipeline as a source to strip and normalize. Under v47 the strip would have removed the vendor's drivers and injected the manager's current recipe. On a machine whose hardware depended on the vendor drivers, that would have regressed the recovery environment.

The v49 classification preserves a `Foreign-With-Drivers` source as-is. The manager's job on such a source is not to normalize it, but to leave it alone.

### What "preserved as-is" means

When the source classifies as `Foreign-With-Drivers`:

- The strip stage is not run. The mounted image retains its existing third-party driver set.
- The OEM pack and VMD injections do not run. The current recipe is not applied.
- **No WIM is exported and no WIM is deployed.** The mounted image is dismounted with `-Discard`; `base.wim` and any stale `winre_optimized.wim` are removed. The existing WinRE route is untouched; the manager does not overwrite the currently-registered image.
- The state file records the source's hash as `ForeignSourceAcceptedHash`, so subsequent runs recognize the preserved source and take the fast path rather than re-classifying it.
- The run exits `EXIT_WARNING`.

The result is that the machine keeps whatever recovery image it already had. For a machine whose vendor-populated image is the correct one, this is the right outcome. For a machine whose vendor-populated image is stale, the operator must resolve the staleness through a source that classifies as `Manager-Owned`, `Manager-Lineage`, or `Foreign-No-Drivers` — typically by using the LKG copy (if it is a manager-owned image) or the GitHub cold-start source.

### Interaction with source selection

The classification runs after source selection has chosen a candidate, and before the strip stage runs. A machine whose registered WinRE classifies as `Foreign-With-Drivers` but whose LKG copy classifies as `Manager-Owned` will still have the LKG copy preferred by source selection only if the LKG's DISM servicing metadata is provably newer. If the registered image is at least as new as the LKG, the source-selection chain prefers the registered image, and the pipeline preserves it.

Deleting the state file does not change the classification of the registered image — the classification depends on the source's actual driver set, not on the state file. To force a rebuild against a manager-owned source, the operator must make a manager-owned source available: either the LKG copy (if it matches `state.CurrentImageHash`) or the GitHub cold-start.

## The strip stage (v47; skipped when the source is `Foreign-With-Drivers` under v49)

As of v47, Step 3 runs a strip stage between the mount and the injection, subject to the v49 source-ownership classification above. It is the mechanism by which the pre-v47 lineage problem is solved: without it, every rebuild seeds from the previously-registered WinRE image, so rebuild N depends on rebuild N−1 and third-party drivers injected by prior runs accumulate silently inside the registered image. The strip breaks the lineage by normalizing the mounted image to **zero third-party drivers** before the current recipe is applied.

### What it does

`Remove-AllThirdPartyDrivers` takes the mounted image and removes every third-party driver from it:

- Enumerate with `Get-WindowsDriver -Path $MountDir`. **No `-All`. No provider filter.** This is the form Microsoft documents as the third-party inventory of a mounted image.
- For each published `OEM#.inf` name from the enumeration, call `Remove-WindowsDriver -Path $MountDir -Driver <published name>`.
- Re-enumerate after every removal. The published numbering can change as packages are removed — removing `oem5.inf` may renumber `oem7.inf` to `oem5.inf`, and so on. The loop terminates only when a fresh enumeration returns zero entries.

### Pre-strip inventory

Before any removal, the initial enumeration is logged as one line per package, with the published INF name, provider, version, and original filename. This is diagnostic:

- It records what the source image contained before the strip. Under v47 the source is chosen by the source-selection logic in Step 2 (see [`architecture.md`](architecture.md) — "The v47 rebuild pipeline" — "Source selection"), so the inventory is a record of what that source contained.
- Under v49, when the source classifies as `Foreign-With-Drivers`, the pre-strip inventory is not logged — the strip is skipped and the mounted image is preserved as-is. The classification decision itself is logged instead.
- Over time, the fleet logs answer whether Microsoft's WU servicing ever delivers a WinRE image with third-party driver packages already present. This is the empirical evidence that closed the original design's WU-migration concern; the strip is predicated on the observation that such packages are not currently delivered, and the inventory is how that observation would be falsified if it ever stopped being true.

### The hard gate

When the strip runs — i.e., when the source is not `Foreign-With-Drivers` — it is a hard gate, not a best-effort operation. Every failure mode rejects the candidate:

| Failure | Result |
|---|---|
| Initial enumeration fails | Candidate rejected. |
| Re-enumeration fails at any iteration | Candidate rejected. |
| Enumeration entry is missing its published INF name | Candidate rejected. |
| `Remove-WindowsDriver` fails for any entry | Candidate rejected. |
| Iteration budget exhausted without reaching zero | Candidate rejected. |
| Final enumeration returns a non-zero count | Candidate rejected. |

**Enumeration failure is never interpreted as zero drivers.** There is no `catch {}` that swallows an error and returns success. A candidate that cannot be proven clean is not used.

On rejection the caller dismounts with `-Discard`, rolls the checkpoint back to Step 2, removes `base.wim` and any stale `winre_optimized.wim`, and exits `EXIT_WARNING`. **No injection, no export, no partition work, and no `reagentc` call occurs.** The machine's existing recovery route is untouched. See "When the strip fails" below for the full description of the abort.

### Relationship to injection

The strip runs **before** injection, in the same Step 3 block, when the source-ownership classification permits. The order within Step 3 is:

1. Mount `base.wim`.
2. Classify the source's ownership class.
3. If the source is not `Foreign-With-Drivers`, strip to zero third-party drivers. Prove zero.
4. Capture the pre-injection third-party driver count (expected to be zero after a successful strip; the preserved `Foreign-With-Drivers` case does not reach this step).
5. Download, extract, and inject the OEM pack (only when the strip ran).
6. Download, extract, and inject the VMD packages (only when the strip ran).
7. Run the never-downgrade storage-driver check.
8. Verify the injection success gate.
9. Run the pre-deployment storage-applicability gate.
10. Write the provenance marker.
11. ResetBase (only if injection succeeded).
12. Dismount with `-Save`.

If step 3 fails, steps 4–12 never run. The candidate is discarded; the machine is unchanged. If step 3 succeeds but step 8 fails, the injection failure gate fires — same exit code, same checkpoint rollback, same disk-state outcome, but the failure is attributed to the injection rather than to the strip. If step 7 detects a downgrade, the candidate is discarded before the success gate is evaluated. If step 9 refuses, the candidate is dismounted with `-Discard` and the run defers.

The strip is thus the enforcement of Rule 4's "drivers go into a clean base" corollary, narrowed by the v49 source-ownership classification to sources that are not foreign-with-drivers. See [`architecture.md`](architecture.md) — "Rule 4" and "The v47 rebuild pipeline" — "Why the strip is Rule 4's enforcement, not a separate rule" — for the design reasoning.

## Injection

`Add-WindowsDriver -Path <MountDir> -Driver <extractDir> -Recurse`.

`Add-WindowsDriver` is called with `-ErrorAction SilentlyContinue -ErrorVariable dismErrors` so the errors can be logged. The function is silent on the shell but the errors are captured.

### The never-downgrade storage-driver check (v49)

After injection completes and before ResetBase, the manager compares each storage-class driver in the final image against the pre-strip inventory, matched by INF basename. If any post-injection driver would be older than the source's version of the same basename, the entire candidate is discarded — not just the offending driver — the mounted image is dismounted with `-Discard`, `base.wim` and `winre_optimized.wim` are removed, the checkpoint rolls back to Step 2, the state file records `ForeignSourceAcceptedHash` set to the preserved source's hash, and the run exits `EXIT_WARNING`.

The check runs inside Step 3, after injection is confirmed complete, before ResetBase and before the applicability gate. It applies to every storage-class driver the manifest resolves — OEM pack drivers and VMD package drivers alike.

**Why it exists.** A Windows Update-delivered storage driver can be newer than what the manifest or OEM pack resolves. Without the check, the next scheduled run would replace the newer driver with an older copy, silently regressing the recovery environment's ability to see the OS disk. The check prevents that regression. The response is deliberately conservative: the whole source is preserved rather than a partial fix.

**What it does not apply to.** The check does not apply to a source classified as `Foreign-With-Drivers` — the recipe is not injected on such a source, and the pipeline exits before the check is reached. It also does not apply on the enable-only path, which does not inject anything.

**What the refusal looks like.** The log names each detected downgrade — the driver's INF basename, the source version, and the candidate version. The run then discards the candidate: the mounted image is dismounted with `-Discard`, `base.wim` and `winre_optimized.wim` are removed, the checkpoint rolls back to Step 2, the state file records `ForeignSourceAcceptedHash`, and the run exits `EXIT_WARNING`. No WIM is deployed, no partition is touched, WinRE is not disabled.

**Interaction with the success gate.** The check runs only after the injection success gate has already passed (`$Script:ImageInjectionComplete = $true`). A downgrade detected here is not a "skipped injection" the success gate tolerates; it aborts the pipeline and discards the whole candidate. There is no partial-normalize path in v49.

**Field status.** The never-downgrade check has not been exercised in the field. A field log of a detected downgrade — naming the driver, the two versions, and the source of the candidate package — is high-signal and the project wants the data. See [testing.md](testing.md) for the test plan.

## The success gate

This is the part of the design that is least obvious and most important. It did not change under v47 or v49, but its input semantics did: the strip stage means `$preInjectThirdParty` is now expected to be zero, which narrows the role of one of the two success conditions. On a `Foreign-With-Drivers` source the strip does not run and the injection does not run either, so the success gate is not reached.

### Why the naive gate does not work

The obvious approach is: `$added = @($result | Where-Object { $_.Operation -in @("Add","Installed") })` and check `$added.Count -gt 0`. This **does not work**.

`Add-WindowsDriver`'s returned objects do not reliably expose an `Operation` property with values `"Add"` or `"Installed"` across DISM builds. On Windows 11 build 26100 the filter returns zero items even when injection succeeded. Confirmed on Lenovo 21L1: extraction produced 14 INFs, pre-injection third-party count was 0, post-injection was 14, but the return-shape filter reported 0.

### The INF-basename cross-reference

The script computes:

- `$extractedInfNames` — the basenames (lowercased) of every INF in the extracted package.
- `$preInjectThirdParty` — the count of third-party drivers in the mounted image before injection. Third-party is defined as `ProviderName -ne 'Microsoft Corporation'`. Under v47 this is captured **after** the strip, so it is expected to be zero.
- `$postInjectThirdParty` — the same count after injection.
- `$imageInfNames` — the basenames (lowercased) of the `OriginalFileName` property of every third-party driver in the mounted image after injection.

The success gate is:

```
success if  (($postInjectThirdParty - $preInjectThirdParty) > 0)
         OR (@($extractedInfNames | Where-Object { $_ -in $imageInfNames }).Count > 0)
```

In words: the injection succeeded if either new drivers were added (delta > 0) **or** the package's INFs are present in the image.

Failure (both conditions false) means the package's INFs cannot be demonstrated in the image. The script logs this as `injection failed` and sets `$Script:ImageInjectionComplete = $false` and `$Script:nonFatalWarning = $true`.

### Why both conditions are needed

The `delta > 0` branch is the ordinary case. After the strip, the image has zero third-party drivers. A successful injection adds the package's drivers, so the post-injection count is greater than zero and the delta is positive.

The `INF basenames match` branch is a defensive fallback:

1. **Against a strip that missed something.** The strip is a hard gate, but if a driver package is present in the image in a form that the strip did not recognise as third-party, the image would still carry that driver after the strip and the injection of the same driver would produce a zero delta. The INF-basename check catches that case: the package's INFs are present, so the injection is credited as succeeded even though the delta was zero.
2. **Against a differing-in-content, same-name driver.** If the mounted image carried a driver whose original filename matches the package's, and the pipeline's injection was effectively a no-op for that driver, the delta could be zero even though the driver is present. The INF-basename branch catches that.

In both cases the INF-basename branch is a fallback, not the primary path. The primary path is the delta check.

### Why this matters

The pre-v47 motivation for the cross-reference was that a base image carrying unrelated third-party drivers would pass a count-based gate even if the OEM package failed entirely. Under v47 the strip eliminates that risk at the source: the image begins injection with a proven zero third-party driver set, so any driver present after injection came from the current injection. The cross-reference is now primarily a defence-in-depth check rather than the primary success signal.

The cross-reference also depends on the extraction directory being **fresh**. A stale INF left in the extraction directory by an interrupted earlier run would show up in `$extractedInfNames` and could satisfy the basename match even if the current extraction failed. Both extraction paths (OEM and VMD) clear their destination before each extraction — the OEM path since v44 patch 3, the VMD path since v44 patch 7.

### The v47 pre-injection discrepancy check

As of v47, immediately after capturing `$preInjectThirdParty`, the script checks whether it is greater than zero. It is expected to be zero after a successful strip. If it is not zero:

- The script logs a WARN: `Strip claimed zero third-party drivers but the filtered pre-injection count is $preInjectThirdParty - the filterless and filtered DISM queries disagree on this image. Filterless is authoritative; injection delta accounting may underreport.`
- It sets `$Script:nonFatalWarning = $true`.

This is **diagnostic only, not a gate**. The filterless `Get-WindowsDriver` form used by the strip is authoritative for the zero-driver guarantee; the filtered form used by the injection-delta accounting is the older v46 heuristic. If the two disagree, the filterless form wins. The warning surfaces the disagreement so an operator investigating a driver problem has a signal, but the run continues. The existing injection success gate (delta > 0 OR INF-basename match) handles the outcome conservatively regardless of the disagreement.

**Under v49 the check does not run on a `Foreign-With-Drivers` source**, because the strip does not run and the pre-injection count is not captured.

## The pre-deployment storage-applicability gate (v49)

The gate runs inside Step 3, after injection is confirmed complete and after the never-downgrade check, before ResetBase and before the dismount. The manager verifies that the mounted candidate image contains an INF whose `HardwareID` or `CompatibleID` matches one of the machine's present SCSIAdapter-class devices.

The gate is the last refusal before the candidate is committed by the dismount and the pipeline advances to the deploy stage. A candidate that does not match the machine's controller is refused: the mounted image is dismounted with `-Discard`, `base.wim` and `winre_optimized.wim` are removed, the checkpoint rolls back to Step 2, and the run exits `EXIT_WARNING`. No WIM is deployed, no partition is touched, WinRE is not disabled.

### Why it exists

The gate was added after the ASUS-incident field case. A machine's controller (`PCI\VEN_8086&DEV_7D0B`) was not in the manifest's VMD patterns. Under the v47 pipeline the machine's VMD hardware presence was classified as absent (because the manifest did not recognize the controller), the VMD driver package was not selected for injection, and the machine would have received a candidate with no driver for its actual storage controller — a recovery environment that boots but cannot see the OS disk.

The manifest's VMD patterns are an incomplete signal. The gate closes the gap by verifying the actual outcome: does the candidate's INF set match the machine's actual controllers? A candidate that does not match is refused.

### What the gate reads

- **The candidate image's INFs.** The gate enumerates the driver INFs in the candidate image and extracts each one's `HardwareID` and `CompatibleID` entries.
- **The machine's present SCSIAdapter-class devices.** The gate enumerates the machine's present SCSIAdapter-class devices and extracts each device's `HardwareID` and `CompatibleID` entries.
- **The match.** The gate requires at least one INF-to-device match. A candidate that contains no INF whose `HardwareID` or `CompatibleID` matches any of the machine's present SCSIAdapter-class devices is refused.

Software and virtual controllers (`InstanceId` starting with `{GUID}\` or `SWD\`) are excluded from the device enumeration, mirroring the v28 harness diagnostic. A machine whose only SCSIAdapter-class devices are Windows-component software controllers is treated as having no relevant controller; the gate does not refuse on that basis, because such a machine has no physical storage controller the candidate image needs to match.

### Field status

**The gate has never fired in the field.** It is a v49 addition and no logged run has reached it. A field log of the refusal is high-signal.

If the log shows the gate refusing a candidate, capture:

- The candidate image path.
- The machine's present SCSIAdapter-class devices (from the harness Option 1 "Storage controllers" block, harness v28).
- The manifest version.
- The candidate's injection source (the OEM pack resolution, the VMD package resolution, or both, if the candidate was injected).

See [troubleshooting.md](troubleshooting.md) and [testing.md](testing.md) for the diagnosis and test plan.

### Interaction with a preserved `Foreign-With-Drivers` source

The gate does not run on a `Foreign-With-Drivers` source. A `Foreign-With-Drivers` source is preserved before the gate is reached: the pipeline exits after the classification step without deploying. The gate runs only on sources the pipeline is prepared to deploy — `Manager-Owned`, `Manager-Lineage`, and `Foreign-No-Drivers`.

## The VMD injection path

VMD injection uses the same success gate but runs after OEM injection, so `$preVmdThirdParty` is captured after the OEM injection result. This is deliberate: the VMD gate's job is to verify that the VMD package contributed drivers, not that the image has any third-party drivers at all. Under v47 the sequence is:

1. Strip → zero third-party drivers, proven.
2. OEM injection → some number of third-party drivers present.
3. `$preVmdThirdParty` captured (this is the OEM-injected count, not zero).
4. VMD injection → the OEM count plus the VMD count.

For each manifest driver that matches (OS, Intel CPU, CPU generation, VMD hardware present):

- Download `driverUrl` to `$WorkDir\driver_<name>.7z`.
- Clear `$WorkDir\drv_extract_<name>` and recreate it, then extract with 7-Zip. As of v44 patch 7, the extraction directory is removed and recreated before each extraction, so a stale INF from an earlier run cannot satisfy the INF-basename cross-reference or contribute to the third-party-driver-count delta and mask a failed extraction.
- Collect INF basenames.

Then `Add-WindowsDriver -Driver $allDirs -Recurse` in one call.

The same INF cross-reference gate applies. A failure sets `$Script:ImageInjectionComplete = $false`.

**VMD hardware presence is checked before this path runs.** As of v44 patch 6, the check is fail-closed: an enumeration error produces an indeterminate result rather than treating VMD as absent. The run defers with `EXIT_WARNING` before committing any state, so the VMD injection path is not reached at all when the presence check cannot complete. See "VMD hardware presence (fail-closed as of v44 patch 6)" above.

**The never-downgrade check (v49) runs after all injection is complete.** It compares the final image's storage-class drivers against the pre-strip inventory, matched by INF basename, and discards the whole candidate if any post-injection driver would be older. See "The never-downgrade storage-driver check (v49)" above.

## When the strip fails

As of v47, the strip stage has its own abort path that runs **before** the injection stage. When `Remove-AllThirdPartyDrivers` returns `$false` — any failure mode in the hard-gate table above — the caller:

- Dismounts the mounted image with `Dismount-WindowsImage -Discard`.
- Removes the mount directory.
- Sets the checkpoint back to `Step=2`.
- Removes any stale `winre_optimized.wim`.
- Removes `base.wim` from `WorkDir`.
- Exits with `EXIT_WARNING` (code 2).

The exit code, the checkpoint rollback, the stale-artifact cleanup, and the disk-state outcome are identical to the injection-failure gate below. What distinguishes the two:

- **The strip fails before injection is attempted.** No `Add-WindowsDriver` call runs. The pre-injection count is never captured. The ResetBase step is never reached.
- **The failure is attributed to the strip**, not to the injection. The log names the specific strip failure (enumeration, removal, missing INF field, budget exhaustion) rather than the generic injection gate.
- **The candidate is discarded with `-Discard`, not `-Save`.** The mounted image is not written back to `base.wim`, because the source is not the problem — the strip could not normalise it. The next run re-acquires the source from Step 2, which may be a different source if the source-selection logic chooses differently, or the same source if nothing else has changed.

What the strip failure does not do:

- It does not disable WinRE.
- It does not touch any partition.
- It does not write or delete the state file.
- It does not change the currently-registered WinRE image.

The machine is left exactly as it was before the run. This is the same shape as the injection-failure abort below.

**Under v49 this abort is only reached when the source-ownership classification is not `Foreign-With-Drivers`.** A `Foreign-With-Drivers` source skips the strip, so the strip-failure abort is not reachable on such a source.

## When injection fails

When `$Script:ImageInjectionComplete` is `$false` after Step 3, the pipeline **exits with `EXIT_WARNING` immediately**. It does not proceed to Step 4 (`dism /Export-Image`), Step 5 (partition work), Step 6 (deployment), or any `reagentc` call. This is the v44 patch 1 pipeline gate.

The gate exists because a WIM with no OEM or VMD drivers is broken on hardware whose storage controller requires those drivers. On a VMD-based system the resulting WinRE cannot see the OS disk at all, and the deployed recovery environment is worse than useless — it is actively misleading. The state-write gate alone would not have prevented this: it stops the state file from recording the run, but does not prevent the deployment of the broken WIM. The explicit pipeline gate closes that gap. This is a **Rule 1** protection in the terms of [`architecture.md`](architecture.md): the pipeline refuses to deploy a recovery environment that cannot see the OS disk, rather than deploying it and reporting a warning afterwards.

**What the gate does:**

- Sets the checkpoint back to `Step=2`, so the next run re-acquires the base WIM from source and re-runs injection against a clean image rather than mounting a `base.wim` that was partially modified by the failed injection attempt.
- Removes any stale `winre_optimized.wim` left from a previous run.
- Removes `base.wim` from `WorkDir`. Without this, the next run's Step 2 would fail at `Rename-Item "$WorkDir\winre.wim" "base.wim"` because the destination file still existed, and the machine would not progress past Step 2 until an operator deleted `WorkDir` by hand. This is the v44 patch 3 cleanup.
- Exits with `EXIT_WARNING` (code 2).

**What the gate does not do:**

- It does not disable WinRE.
- It does not touch any partition.
- It does not write or delete the state file.
- It does not change the currently-registered WinRE image.

The machine is left exactly as it was before the run — WinRE is still in whatever state it started, the recovery partition is untouched, and the next scheduled run retries from Step 2 with a clean `WorkDir`.

**Related to the strip stage (v47).** A strip failure aborts before injection is attempted; a successful strip proceeds to injection and the injection gate governs. Both paths exit `EXIT_WARNING` with the same checkpoint rollback and the same disk-state outcome. See "When the strip fails" above.

**Related to Rule 4 (prepare everything before touching anything).** The pipeline gate is the operational enforcement of Rule 4 at the injection boundary. Every driver artifact is prepared, verified, and injected into the mounted image **before** the destructive sequence begins. A failure at any point in the preparation phase stops the run in a state where the machine's existing recovery route is untouched. Rule 4's guarantee — "the destructive sequence is only reachable through a chain of successful preparations" — is what makes the pipeline gate a clean stop rather than an emergency rollback.

**Related to the v47 strip.** The strip is the first gate in Step 3, and it is a hard gate. Under v47, a candidate that cannot be proven free of third-party drivers never reaches injection, export, partition work, or `reagentc`. See "The strip stage (v47)" above.

**Related to the v49 pre-deployment storage-applicability gate.** The applicability gate is the last refusal before the WIM is committed by the dismount and the pipeline advances to the deploy stage. It is downstream of injection and the never-downgrade check, upstream of ResetBase and the dismount. A candidate that passes injection but is refused by the applicability gate is discarded rather than deployed. The two gates have different jobs: injection failure means the WIM was not prepared successfully; applicability refusal means the prepared WIM does not match the machine's controllers. Both exit `EXIT_WARNING`, both leave the machine's existing recovery route untouched, both are the design's intended response to a candidate that cannot safely be deployed.

**Related to ResetBase (v44 patch 2).** Component cleanup and ResetBase run inside Step 3, after the applicability gate, but only when `$Script:ImageInjectionComplete` is `$true`. When injection fails, ResetBase is skipped — the pipeline aborts before that point, so running the reset would only waste CPU on an image whose driver state is already invalid.

**Related to the offline fallback (v44 patch 5).** When the manifest fetch fails and the offline fallback engages, the entire driver-resolution pipeline is skipped: no OEM pack resolution, no VMD detection, no required-driver resolution, no download, no strip (because no source is acquired), no injection, no applicability gate. The full-update path is not reachable offline. A machine on the offline fallback either takes the fast path (state file valid, all local safety checks pass) or exits `EXIT_WARNING` before the full-update pipeline. It never reaches Step 3. This is by design: the driver set is a function of the manifest, and without the manifest there is no safe way to determine which drivers to inject. A machine in this state does not lose its existing WinRE; it simply defers the injection work to a future run with network. See the "Offline behavior" section in [deployment.md](deployment.md) for the operator-facing description of the three cases.

**Related to the VMD fail-closed guard (v44 patch 6).** When the VMD hardware presence check is indeterminate, the run defers with `EXIT_WARNING` **before** reaching Step 3. The full-update path is not reached. The machine is unchanged and the next run retries the enumeration. This is a **Rule 4** protection: the driver set is not guessed on indeterminate input.

**Related to the VMD extraction cleanup (v44 patch 7).** The VMD injection path clears each extraction directory before extracting into it. Before patch 7, an interrupted previous run could leave INFs in `$WorkDir\drv_extract_<name>`, and those stale INFs could satisfy the INF-basename cross-reference or contribute to the third-party-driver-count delta, making a failed VMD extraction look like a success. The OEM path uses a single fixed extraction directory (`$WorkDir\oem_extract`) that was already cleared before each use; the VMD path did not have equivalent cleanup until v44 patch 7. The Lenovo "non-zero exit but INFs present" branch on the OEM path was the sharpest case for this class of hazard: it treats an INF-count greater than zero as success regardless of the extractor's exit code, so a stale INF could hide a genuine extraction failure.

**Related to the v47 pre-injection discrepancy check.** Immediately after capturing `$preInjectThirdParty` (expected to be zero after a successful strip), the script checks whether it is greater than zero. A non-zero value is a signal that the filterless and filtered DISM queries disagree on this image. The warning is diagnostic only; the strip's filterless form remains authoritative, and the injection success gate handles the outcome conservatively regardless. See "The v47 pre-injection discrepancy check" above.

**Related to the v49 source-ownership classification.** A `Foreign-With-Drivers` source skips the strip and the injection entirely. The pipeline does not reach the injection gate on such a source; it exits after the classification step, preserving the source and recording `ForeignSourceAcceptedHash`. The classification is the v49 narrowing of the strip-and-reinject policy; see "Source-ownership classification (v49)" above.

**Related to the v49 never-downgrade check.** The never-downgrade check runs after injection is confirmed complete. When it detects a downgrade, the whole candidate is discarded — dismounted with `-Discard`, `base.wim` and `winre_optimized.wim` removed, checkpoint rolled back to Step 2, `ForeignSourceAcceptedHash` recorded. The pipeline does not continue with a retained driver; there is no partial-normalize path in v49. See "The never-downgrade storage-driver check (v49)" above.

**Related to the v49 pre-deployment storage-applicability gate.** The gate runs on every candidate the pipeline is prepared to deploy. A candidate that does not contain an INF matching one of the machine's present SCSIAdapter-class devices is refused and discarded. The gate has never fired in the field; a field log of the refusal is high-signal. See "The pre-deployment storage-applicability gate (v49)" above.

**Related to the v49 provenance marker write.** After the applicability gate passes and after ResetBase, the pipeline writes the provenance marker (if the `LineageId` is not yet set, it generates one) into the mounted image at `Sources\Recovery\WinRE-Manager\provenance.json`. The marker is not load-bearing in v49 — no gate reads it, and a write failure is logged and the pipeline continues. Its only current consumer is `Read-ProvenanceMarker`, which is called by the source-ownership classifier on a subsequent run.

**Before v44 patch 1** the pipeline continued to Step 4 and beyond even when injection failed, and relied on the state-write gate to prevent the state file from recording the run. That was not sufficient for the reasons above. The v44 patch 1 gate is the correction. The `base.wim` cleanup on the abort branch is the v44 patch 3 follow-up, and the Step 2 stale-file cleanup on the normal path is the v44 patch 6 follow-up. The v47 strip stage adds a parallel abort path that fires before injection is attempted. The v49 source-ownership classification narrows the strip to sources that are not foreign-with-drivers; the v49 never-downgrade check runs after injection and discards the whole candidate on a downgrade; the v49 applicability gate is the last refusal before the dismount commits the candidate.

## Related documents

- [architecture.md](architecture.md) — the four design invariants, the pipeline and where Step 3 fits in it, the "v47 rebuild pipeline" section describing source selection, the strip stage, the race detector, and the metadata-based drift detector, and the "v49 pipeline refinements" section describing the source-ownership classification, the never-downgrade check, and the pre-deployment applicability gate. The injection step is the deepest embodiment of Rule 4 and the sharpest instance of Rule 1; the strip stage is the mechanism by which Rule 4's "drivers go into a clean base" corollary is enforced, narrowed by v49 to sources that are not foreign-with-drivers.
- [state-and-idempotency.md](state-and-idempotency.md) — how `ImageInjectionComplete` gates the state write and the checkpoint writes, the `DeployedWinREMetadata` field (v47), the offline fallback's residual risk, the `LocalInputsId` field (v48 patch 1), the `ForeignSourceAcceptedHash` and `LineageId` fields (v49), and how the Lenovo five-state resolution feeds the `OEMPACK` field of the `DesiredStateId`.
- [self-hosting.md](self-hosting.md) — how to host your own manifest and OEM maps, including the v49 pre-deployment gates' implications for a self-hosted configuration.
- [troubleshooting.md](troubleshooting.md) — diagnosing injection failures, strip failures, the VMD-query-indeterminate deferral, the v49 applicability gate's refusal, and the v49 never-downgrade check's discards.
- [testing.md](testing.md) — the v28 harness's storage-controller enumeration, which surfaces the applicability gate's inputs, and the v49 test plan for the source-ownership classification, the never-downgrade check, and the applicability gate.
- [deployment.md](deployment.md) — the operator-facing description of offline behavior, including why an offline machine never reaches Step 3.
