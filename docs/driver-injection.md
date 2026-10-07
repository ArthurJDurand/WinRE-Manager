---
title: "Driver injection — WinRE Manager"
description: "How WinRE Manager injects OEM WinPE driver packs and Intel VMD storage drivers into the recovery image, and the strip stage that normalizes the base."
---

# Driver injection

WinRE Manager injects two kinds of drivers into the base WIM:

1. **OEM WinPE driver pack** — one per vendor (Dell, HP, Lenovo).
2. **Intel VMD storage drivers** — one or more per manifest entry, if the machine's CPU generation is in range and VMD hardware is present.

Both injections run inside Step 3 (mount, strip, inject, dismount). As of v47 a strip stage runs between the mount and the injection: it normalizes the mounted image to zero third-party drivers before the current recipe is applied. This document covers the manifest schema, the source URLs, the extraction per vendor, the strip stage, and the success gate.

The injection step is the deepest embodiment of two of the project's four design invariants, which [`architecture.md`](architecture.md) states in this order. **Rule 4 — do no work unless needed; prepare everything before touching anything** — is the reason every driver artifact must be resolved, downloaded, extracted, and verified *before* the destructive sequence begins; a rebuild that would have failed at the injection step never touches a partition. **Rule 1 — never break Windows RE** — is the reason injection failure is fatal-on-progression rather than a degraded-success: a WIM that cannot see the OS disk is actively misleading, and the pipeline gate exists to make sure such a WIM never reaches a recovery partition. The v47 strip stage is the mechanism by which Rule 4's "drivers go into a clean base" corollary is enforced; see [`architecture.md`](architecture.md) — "The v47 rebuild pipeline" — for the full design.

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

### VMD hardware presence (fail-closed as of v44 patch 6)

The script reads all `requiredDevices` values from all manifest entries into a single regex, then matches against `Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match $pattern }`. If at least one device matches, VMD hardware is considered present.

VMD hardware presence is determined once, from the union of all `requiredDevices` values across all manifest entries, matched against present PnP devices. If that machine-wide determination reports VMD absent, every manifest entry that declares `requiredDevices` is skipped. The log records `Skipping <name>: no matching VMD hardware detected` for each skipped entry.

**As of v44 patch 6, the enumeration is fail-closed.** If `Get-PnpDevice` reports an error during the query — for example, the Plug and Play service is in a bad state, an antivirus or EDR product is blocking device enumeration, or a device in an error state is preventing the PnP manager from completing the query — the script treats VMD presence as **indeterminate** rather than as absent. It does not assume the machine has no VMD hardware.

An indeterminate result means the correct driver set cannot be determined. The run logs the enumeration error, sets `$Script:nonFatalWarning = $true`, removes the checkpoint file, and exits `EXIT_WARNING` **before** committing any state. No WIM is deployed, no partition is touched, no `reagentc` call is made.

Why fail-closed and not "assume absent": on a machine that genuinely has VMD hardware, guessing "absent" would select a driver set that omits the VMD package. The deployed WinRE would not be able to see the OS disk. That is the exact failure mode the v44 patch 1 `DesiredStateId` change was designed to prevent, and an empty device list from an errored enumeration is not evidence of absence. The cost of a deferral is one pipeline run; the cost of guessing wrong is a machine with a non-functional recovery environment. See [troubleshooting.md](troubleshooting.md) for the resolution.

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

## The strip stage (v47)

As of v47, Step 3 runs a strip stage between the mount and the injection. It is the mechanism by which the pre-v47 lineage problem is solved: without it, every rebuild seeds from the previously-registered WinRE image, so rebuild N depends on rebuild N−1 and third-party drivers injected by prior runs accumulate silently inside the registered image. The strip breaks the lineage by normalizing the mounted image to **zero third-party drivers** before the current recipe is applied.

### What it does

`Remove-AllThirdPartyDrivers` takes the mounted image and removes every third-party driver from it:

- Enumerate with `Get-WindowsDriver -Path $MountDir`. **No `-All`. No provider filter.** This is the form Microsoft documents as the third-party inventory of a mounted image.
- For each published `OEM#.inf` name from the enumeration, call `Remove-WindowsDriver -Path $MountDir -Driver <published name>`.
- Re-enumerate after every removal. The published numbering can change as packages are removed — removing `oem5.inf` may renumber `oem7.inf` to `oem5.inf`, and so on. The loop terminates only when a fresh enumeration returns zero entries.

### Pre-strip inventory

Before any removal, the initial enumeration is logged as one line per package, with the published INF name, provider, version, and original filename. This is diagnostic:

- It records what the source image contained before the strip. Under v47 the source is chosen by the source-selection logic in Step 2 (see [`architecture.md`](architecture.md) — "The v47 rebuild pipeline" — "Source selection"), so the inventory is a record of what that source contained.
- Over time, the fleet logs answer whether Microsoft's WU servicing ever delivers a WinRE image with third-party driver packages already present. This is the empirical evidence that closed the original design's WU-migration concern; the strip is predicated on the observation that such packages are not currently delivered, and the inventory is how that observation would be falsified if it ever stopped being true.

### The hard gate

The strip is a hard gate, not a best-effort operation. Every failure mode rejects the candidate:

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

The strip runs **before** injection, in the same Step 3 block. The order within Step 3 is:

1. Mount `base.wim`.
2. Strip to zero third-party drivers. Prove zero.
3. Capture the pre-injection third-party driver count (expected to be zero after a successful strip).
4. Download, extract, and inject the OEM pack.
5. Download, extract, and inject the VMD packages (if VMD hardware is present).
6. Verify the injection success gate.
7. ResetBase (only if injection succeeded).
8. Dismount with `-Save`.

If step 2 fails, steps 3–8 never run. The candidate is discarded; the machine is unchanged. If step 2 succeeds but step 6 fails, the injection failure gate fires — same exit code, same checkpoint rollback, same disk-state outcome, but the failure is attributed to the injection rather than to the strip.

The strip is thus the enforcement of Rule 4's "drivers go into a clean base" corollary. See [`architecture.md`](architecture.md) — "Rule 4" and "The v47 rebuild pipeline" — "Why the strip is Rule 4's enforcement, not a separate rule" — for the design reasoning.

## Injection

`Add-WindowsDriver -Path <MountDir> -Driver <extractDir> -Recurse`.

`Add-WindowsDriver` is called with `-ErrorAction SilentlyContinue -ErrorVariable dismErrors` so the errors can be logged. The function is silent on the shell but the errors are captured.

## The success gate

This is the part of the design that is least obvious and most important. It did not change under v47, but its input semantics did: the strip stage means `$preInjectThirdParty` is now expected to be zero, which narrows the role of one of the two success conditions.

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

The `delta > 0` branch is the ordinary v47 case. After the strip, the image has zero third-party drivers. A successful injection adds the package's drivers, so the post-injection count is greater than zero and the delta is positive.

The `INF basenames match` branch was originally written for the pre-v47 re-run case: the image already had the package's drivers (from a prior deployment), so injection was a no-op and the delta was zero. **Under v47 that case is largely eliminated by the strip.** A pre-v47 base WIM that carried the package's drivers would have those drivers stripped out, and the injection would add them back — producing a positive delta, not a zero one.

The INF-basename branch is retained under v47 for two reasons:

1. **Defensive coverage against a strip that missed something.** The strip is a hard gate, but if a driver package is present in the image in a form that the strip did not recognise as third-party, the image would still carry that driver after the strip and the injection of the same driver would produce a zero delta. The INF-basename check catches that case: the package's INFs are present, so the injection is credited as succeeded even though the delta was zero.
2. **Defensive coverage against a differing-in-content-same-name driver.** If the mounted image carried a driver whose original filename matches the package's, but the package's INFs are functionally identical, the injection could be a no-op even after the strip (if the strip's removal failed silently for that specific driver in a way that passed the zero-gate). The INF-basename check catches that too.

In both cases, the INF-basename branch is a fallback, not the primary path. The primary path under v47 is the delta check.

### Why this matters

The pre-v47 motivation for the cross-reference was that a base image carrying unrelated third-party drivers would pass a count-based gate even if the OEM package failed entirely. Under v47 the strip eliminates that risk at the source: the image begins injection with a proven zero third-party driver set, so any driver present after injection came from the current injection. The cross-reference is now primarily a defence-in-depth check rather than the primary success signal.

The cross-reference also depends on the extraction directory being **fresh**. A stale INF left in the extraction directory by an interrupted earlier run would show up in `$extractedInfNames` and could satisfy the basename match even if the current extraction failed. Both extraction paths (OEM and VMD) clear their destination before each extraction — the OEM path since v44 patch 3, the VMD path since v44 patch 7.

### The v47 pre-injection discrepancy check

As of v47, immediately after capturing `$preInjectThirdParty`, the script checks whether it is greater than zero. It is expected to be zero after a successful strip. If it is not zero:

- The script logs a WARN: `Strip claimed zero third-party drivers but the filtered pre-injection count is $preInjectThirdParty - the filterless and filtered DISM queries disagree on this image. Filterless is authoritative; injection delta accounting may underreport.`
- It sets `$Script:nonFatalWarning = $true`.

This is **diagnostic only, not a gate**. The filterless `Get-WindowsDriver` form used by the strip is authoritative for the zero-driver guarantee; the filtered form used by the injection-delta accounting is the older v46 heuristic. If the two disagree, the filterless form wins. The warning surfaces the disagreement so an operator investigating a driver problem has a signal, but the run continues. The existing injection success gate (delta > 0 OR INF-basename match) handles the outcome conservatively regardless of the disagreement.

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

**Related to ResetBase (v44 patch 2).** Component cleanup and ResetBase run inside Step 3, after injection, but only when `$Script:ImageInjectionComplete` is `$true`. When injection fails, ResetBase is skipped — the pipeline aborts before that point, so running the reset would only waste CPU on an image whose driver state is already invalid.

**Related to the offline fallback (v44 patch 5).** When the manifest fetch fails and the offline fallback engages, the entire driver-resolution pipeline is skipped: no OEM pack resolution, no VMD detection, no required-driver resolution, no download, no strip (because no source is acquired), no injection. The full-update path is not reachable offline. A machine on the offline fallback either takes the fast path (state file valid, all local safety checks pass) or exits `EXIT_WARNING` before the full-update pipeline. It never reaches Step 3. This is by design: the driver set is a function of the manifest, and without the manifest there is no safe way to determine which drivers to inject. A machine in this state does not lose its existing WinRE; it simply defers the injection work to a future run with network. See the "Offline behavior" section in [deployment.md](deployment.md) for the operator-facing description of the three cases.

**Related to the VMD fail-closed guard (v44 patch 6).** When the VMD hardware presence check is indeterminate, the run defers with `EXIT_WARNING` **before** reaching Step 3. The full-update path is not reached. The machine is unchanged and the next run retries the enumeration. This is a **Rule 4** protection: the driver set is not guessed on indeterminate input.

**Related to the VMD extraction cleanup (v44 patch 7).** The VMD injection path clears each extraction directory before extracting into it. Before patch 7, an interrupted previous run could leave INFs in `$WorkDir\drv_extract_<name>`, and those stale INFs could satisfy the INF-basename cross-reference or contribute to the third-party-driver-count delta, making a failed VMD extraction look like a success. The OEM path uses a single fixed extraction directory (`$WorkDir\oem_extract`) that was already cleared before each use; the VMD path did not, until patch 7. The Lenovo "non-zero exit but INFs present" branch on the OEM path was the sharpest case for this class of hazard: it treats an INF-count greater than zero as success regardless of the extractor's exit code, so a stale INF could hide a genuine extraction failure.

**Related to the v47 pre-injection discrepancy check.** Immediately after capturing `$preInjectThirdParty` (expected to be zero after a successful strip), the script checks whether it is greater than zero. A non-zero value is a signal that the filterless and filtered DISM queries disagree on this image. The warning is diagnostic only; the strip's filterless form remains authoritative, and the injection success gate handles the outcome conservatively regardless. See "The v47 pre-injection discrepancy check" above.

**Before v44 patch 1** the pipeline continued to Step 4 and beyond even when injection failed, and relied on the state-write gate to prevent the state file from recording the run. That was not sufficient for the reasons above. The v44 patch 1 gate is the correction. The `base.wim` cleanup on the abort branch is the v44 patch 3 follow-up, and the Step 2 stale-file cleanup on the normal path is the v44 patch 6 follow-up. The v47 strip stage adds a parallel abort path that fires before injection is attempted.

## Related documents

- [architecture.md](architecture.md) — the four design invariants, the pipeline and where Step 3 fits in it, the "v47 rebuild pipeline" section describing source selection, the strip stage, the race detector, and the metadata-based drift detector, and the control-flow invariants that the injection gate and the VMD fail-closed guard enforce. The injection step is the deepest embodiment of Rule 4 and the sharpest instance of Rule 1; the strip stage is the mechanism by which Rule 4's "drivers go into a clean base" corollary is enforced.
- [state-and-idempotency.md](state-and-idempotency.md) — how `ImageInjectionComplete` gates the state write and the checkpoint writes, the `DeployedWinREMetadata` field (v47), the offline fallback's residual risk, and how the Lenovo five-state resolution feeds the `OEMPACK` field of the `DesiredStateId`.
- [self-hosting.md](self-hosting.md) — how to host your own manifest and OEM maps if you do not want to rely on the maintainer's gists.
- [troubleshooting.md](troubleshooting.md) — diagnosing injection failures, strip failures, and the VMD-query-indeterminate deferral.
- [deployment.md](deployment.md) — the operator-facing description of offline behavior, including why an offline machine never reaches Step 3.
