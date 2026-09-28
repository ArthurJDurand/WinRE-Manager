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
```

### Field meanings

- **`version`** — the manifest version string. Goes into `DesiredStateId`. Bump it whenever a `driverUrl` changes.
- **`drivers[].name`** — display name, used in logs.
- **`drivers[].os`** — array of OS identifiers the driver supports. Valid values: `"Win10"`, `"Win11"`.
- **`drivers[].match.cpuGenMin`** — minimum Intel CPU generation.
- **`drivers[].match.cpuGenMax`** — maximum Intel CPU generation.
- **`drivers[].match.requiredDevices`** — array of device hardware IDs. If set, the driver is only downloaded if a matching PnP device is present on the machine. If absent or empty, the driver is downloaded regardless of hardware.
- **`drivers[].driverUrl`** — URL to a `.7z` archive containing one or more driver INFs.

### VMD hardware presence

The script reads all `requiredDevices` values from all manifest entries into a single regex, then matches against `Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match $pattern }`. If at least one device matches, VMD hardware is considered present.

If a manifest entry has `requiredDevices` but the machine has no matching device, that driver is skipped. The log records `Skipping <name>: no matching VMD hardware detected`.

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

## Download

All three downloads go through `Invoke-OemPackDownload`, which:

- Removes any existing file at the destination.
- Retries up to 3 times on exception.
- Verifies SHA256 and/or MD5 if the map provides them.
- Accepts a hashless download only if `Invoke-WebRequest` completed cleanly on the same attempt.

The last rule is important. `Invoke-WebRequest` can throw an exception **after** writing the file (connection reset while waiting for a final ACK). Without the rule, a partial file left by a throwing request would be treated as a successful download. The script removes the file and retries.

## Extraction

Extraction is per-vendor.

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
7z.exe x <cab> -o"<path>" -y
```

The INF count is checked. If zero, the extraction is treated as failure even on a clean 7-Zip exit.

### Common check

For all three vendors, `Get-InfFileCount -Directory <extractDir>` is called after extraction. Zero INFs is a failure.

This is the "Lenovo SCCM Package issue": some Lenovo packages extract successfully but contain no INFs because they are WinPE boot-image bundles rather than driver-only packs. The INF count catches this.

## Injection

`Add-WindowsDriver -Path <MountDir> -Driver <extractDir> -Recurse`.

`Add-WindowsDriver` is called with `-ErrorAction SilentlyContinue -ErrorVariable dismErrors` so the errors can be logged. The function is silent on the shell but the errors are captured.

## The success gate

This is the part of the design that is least obvious and most important.

### Why the naive gate does not work

The obvious approach is: `$added = @($result | Where-Object { $_.Operation -in @("Add","Installed") })` and check `$added.Count -gt 0`. This **does not work**.

`Add-WindowsDriver`'s returned objects do not reliably expose an `Operation` property with values `"Add"` or `"Installed"` across DISM builds. On Windows 11 build 26100 the filter returns zero items even when injection succeeded. Confirmed on Lenovo 21L1: extraction produced 14 INFs, pre-injection third-party count was 0, post-injection was 14, but the return-shape filter reported 0.

### The INF-basename cross-reference

The script computes:

- `$extractedInfNames` — the basenames (lowercased) of every INF in the extracted package.
- `$preInjectThirdParty` — the count of third-party drivers in the mounted image before injection. Third-party is defined as `ProviderName -ne 'Microsoft Corporation'`.
- `$postInjectThirdParty` — the same count after injection.
- `$imageInfNames` — the basenames (lowercased) of the `OriginalFileName` property of every third-party driver in the mounted image after injection.

The success gate is:

```
success if  (($postInjectThirdParty - $preInjectThirdParty) > 0)
         OR (@($extractedInfNames | Where-Object { $_ -in $imageInfNames }).Count > 0)
```

In words: the injection succeeded if either new drivers were added (delta > 0) **or** the package's INFs are present in the image (already there before this run).

Failure (both conditions false) means the package's INFs cannot be demonstrated in the image. The script logs this as `injection failed` and sets `$Script:ImageInjectionComplete = $false` and `$Script:nonFatalWarning = $true`.

### Why both conditions are needed

The `delta > 0` branch handles the common case: fresh injection into an image with no prior third-party drivers.

The `INF basenames match` branch handles the re-run case: the image already has the package's drivers, so injection is a no-op and the delta is 0. This happens when a machine re-runs the same `DesiredStateId` and the base WIM is the previously-deployed one.

The two conditions together avoid both false negatives ("the injection worked but the return-shape filter is unreliable") and false positives ("the image happens to have unrelated third-party drivers from the base WIM").

### Why this matters

A base image carrying unrelated third-party drivers would pass a count-based gate even if the OEM package failed entirely. The cross-reference catches that: if the OEM package's INFs are absent and no new drivers were added, the injection failed, regardless of how many drivers the base image already contains.

## The VMD injection path

VMD injection uses the same success gate but runs after OEM injection, so `$preVmdThirdParty` is captured after the OEM injection result. This is deliberate: the VMD gate's job is to verify that the VMD package contributed drivers, not that the image has any third-party drivers at all.

For each manifest driver that matches (OS, Intel CPU, CPU generation, VMD hardware present):

- Download `driverUrl` to `$WorkDir\driver_<name>.7z`.
- Extract with 7-Zip to `$WorkDir\drv_extract_<name>`.
- Collect INF basenames.

Then `Add-WindowsDriver -Driver $allDirs -Recurse` in one call.

The same INF cross-reference gate applies. A failure sets `$Script:ImageInjectionComplete = $false`.

## When injection fails

A failed injection does not stop the pipeline. The script continues to Step 4 and the full-update path. What changes is:

- `$Script:ImageInjectionComplete = $false`.
- `$Script:nonFatalWarning = $true`.
- Step 3 and Step 4 checkpoints are **not** advanced (v43 patch 4).
- The final state-write gate is skipped, so no state file is written.
- The exit code is `EXIT_WARNING` (2).

The next run will attempt injection again. The migration guard resets `$step` to 2 to force Step 3 to re-run even if the checkpoint was orphaned at a higher step.

## Related documents

- [architecture.md](architecture.md) — where Step 3 fits in the pipeline.
- [state-and-idempotency.md](state-and-idempotency.md) — how `ImageInjectionComplete` gates the state write.
- [troubleshooting.md](troubleshooting.md) — diagnosing injection failures.
