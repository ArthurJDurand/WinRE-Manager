# Self-hosting the external dependencies

WinRE Manager depends on five external artifacts that are hosted on GitHub by the project maintainer. All five can be replaced with self-hosted equivalents. This document explains the trust model, walks through each artifact, and gives the exact edit needed to point the scripts at your own hosting.

Self-hosting matters to the project's design for a specific reason. [`docs/architecture.md`](architecture.md) opens with four design invariants — *never break Windows RE*, *never leave a machine without a working recovery route*, *minimize the `reagentc /disable` → `reagentc /enable` window*, and *do no work unless needed; prepare everything before touching anything*. The **third** invariant is enforced by the script's own ordering, not by anything external. The **fourth** invariant is where self-hosting enters the picture: "prepare everything before touching anything" means the driver manifest, the OEM maps, and the base WIM must all be reachable and trustworthy **before** the destructive sequence begins. If your fleet's network cannot reach the maintainer's gists, or your security policy does not extend trust to third-party content hosted outside your perimeter, the fourth invariant is not satisfied by the shipped default. Self-hosting is the fix. See [`docs/deployment.md`](deployment.md#design-invariants-at-deployment-time) for how the four rules translate into operational guidance for a fleet operator.

## Do you need to self-host?

| Situation | Recommendation |
|---|---|
| Single machine, occasional repair | Use the defaults. The gists and the base WIM repo are maintained, versioned, and reachable. You gain nothing by self-hosting. |
| Managed fleet, standard IT | Mirror the artifacts to your own HTTPS endpoint and point production at the mirror. This removes your fleet's dependency on a gist or GitHub availability. It is a cache, not a fork — you replicate the upstream content and refresh it on your own cadence. |
| Regulated environment, or you do not want to trust third-party content | Self-host all five. Fork the manifest, rebuild the OEM maps on your own cadence, and mirror the base WIM repository. |
| Air-gapped fleet | Self-host all five on an internal HTTPS endpoint. You will also need a local copy of the base WIM and a reachable mirror of the OEM pack download endpoints (Dell, HP, Lenovo CDNs). See "Air-gapped deployments" below. |

The default configuration is fine for the majority of installations. The rest of this document is for the cases where it is not.

## What the scripts depend on

| Artifact | Default location | Consumed by | Format |
|---|---|---|---|
| Driver manifest | `https://gist.github.com/52250179/4d98029c7b39240cdb860ee3c78c3ca9/raw` | `WinRE.ps1`, `Test-WinRE.ps1` | JSON, single file |
| Dell WinPE map | `https://gist.github.com/52250179/52058dde0701c749be627c9601c5c925/raw` | `WinRE.ps1`, `Test-WinRE.ps1` | JSON, single file |
| HP WinPE map | `https://gist.github.com/52250179/07f9c3db08e5ef27daca1e7ff700af35/raw` | `WinRE.ps1`, `Test-WinRE.ps1` | JSON, single file |
| Lenovo WinPE map | `https://gist.github.com/52250179/8211b75a38444caa68b8cebd7529376c/raw` | `WinRE.ps1`, `Test-WinRE.ps1` | JSON, single file |
| Base WIM repository | `https://api.github.com/repos/52250179/OriginalWindowsREImages/contents` | `WinRE.ps1` | GitHub contents-API listing; split 7-Zip archives per OS folder |
| OEM pack CDNs | Dell, HP, Lenovo (see the maps) | `WinRE.ps1` | Vendor-hosted; referenced by URL from the maps |

Every URL is a variable at the top of `WinRE.ps1` and `Test-WinRE.ps1`. The scripts fetch with `Invoke-RestMethod` / `Invoke-WebRequest` over HTTPS, so a self-hosted replacement must also serve over HTTPS. A UNC path or file share will not work without editing the fetch code itself.

## The default trust model

By default, `WinRE.ps1` and `Test-WinRE.ps1` trust five URLs. What that means, in plain terms:

- **The driver manifest** decides which VMD driver packages are downloaded and injected. A compromised manifest could substitute an arbitrary `.7z` archive for the expected VMD package. The scripts verify the archive's SHA256 if the manifest entry carries one, and the manifest is under version control in the project's GitHub account, but the substitution risk is real for anyone who does not fork it.
- **The three OEM maps** decide which vendor WinPE driver pack is downloaded and injected, and provide the SHA256 that the script verifies against the download. A compromised map could substitute an arbitrary URL for the vendor CDN, and supply a matching SHA256 for the substituted file. The map's SHA256 is a check against CDN corruption, not against a compromised map.
- **The base WIM repository** provides the fallback `winre.wim` for machines whose own recovery image is missing or unusable. The scripts extract it with 7-Zip and use it as the base for servicing. No signature is verified on the WIM itself. Under v47 the repository is the third tier of a three-source chain: the currently-registered WinRE image is preferred, the manager's last-known-good copy at `C:\Recovery\WindowsRE\winre.wim` is preferred if the registered image is unusable or older, and the GitHub repository is reached only when neither local source is usable. The last-known-good copy is a file the manager itself writes to the OS volume on every successful deploy; it is not a self-hosted dependency.

If any of those five are compromised, the deployed recovery image is compromised. For a single machine owned by the person running the script, this is a reasonable default. For a managed fleet, or any environment where "the maintainer's gist is unreachable" or "the maintainer's gist is untrusted" is a concern, self-hosting is the fix.

## Forking the OEM maps

The three OEM maps are JSON files generated by the map-building scripts in `scripts/`. Each builder scrapes the vendor's public catalog and emits a schema that the production script's `Get-*-WinPEPack` function consumes.

### What the builders are

| Script | Input | Output |
|---|---|---|
| `Build-DellWinPEMap.ps1` | Dell's `DriverPackCatalog.cab` (`downloads.dell.com`) | `DellWinPEMap.json` |
| `Build-HPWinPEMap.ps1` | HP's WinPE driver page (`ftp.ext.hp.com`) | `HPWinPEMap.json` |
| `Build-LenovoWinPEMap.ps1` | Lenovo's RecipeCard JSON (`download.lenovo.com`) + per-DS-ID support pages (`support.lenovo.com`) | `LenovoWinPEMap.json` |

They are **maintenance tools, not runtime dependencies**. Nothing in the production script invokes them. They are run by the maintainer (or by a self-hoster) on a cadence to refresh the maps when the vendor publishes a new driver pack.

The Lenovo builder is the slow one. It makes one HTTPS request per unique DS ID with a two-second delay between requests, so a full rebuild against ~200 DS IDs takes ~7 minutes. The Dell and HP builders are each under a minute.

### Running a builder

```powershell
.\scripts\Build-DellWinPEMap.ps1
.\scripts\Build-HPWinPEMap.ps1
.\scripts\Build-LenovoWinPEMap.ps1
```

Each builder writes its output to `scripts\Maps\<Name>WinPEMap.json` if the `scripts\` directory is writable, or to `C:\Temp\Maps\<Name>WinPEMap.json` otherwise. The path is printed at the end of the run. The builders also cache their scratch inputs under `C:\Temp\` (Dell: the downloaded CAB and the extracted XML; Lenovo: the curl-impersonate binary and the RecipeCard JSON) so repeat runs do not re-download the expensive pieces. The cached inputs are left in place between runs by design.

### Hosting the maps

The output is a single JSON file per vendor. Hosting options, in roughly increasing complexity:

- **GitHub Gist.** Copy the file into your own gist. The raw URL of the gist file is what the production script will fetch.
- **Internal HTTPS endpoint.** Any web server that serves static files over HTTPS. Copy the generated JSON file to a stable path the server exposes; the URL of that path is what the production script fetches. The path should be stable because it goes into the production script's configuration. The URL must be reachable by every machine in the fleet and must serve the file directly, without an authentication prompt or an HTML wrapper.
- **Azure Blob Storage static website, S3 static hosting, an internal CDN.** Same idea: a stable HTTPS URL that returns the JSON.

The URL must end in a form that `Invoke-RestMethod` treats as a raw JSON response. If your hosting returns an HTML wrapper (a "file preview" page, for example), the script will fail to parse the response and log the parse error.

### Pointing production at your maps

Edit four lines in `scripts/WinRE.ps1` and the same four in `scripts/Test-WinRE.ps1`. Both scripts carry identical CONFIG blocks near the top of the file.

```powershell
$DriverManifestUrl = "https://your-host.example/drivermanifest.json"
$DellWinPEMapUrl   = "https://your-host.example/DellWinPEMap.json"
$HPWinPEMapUrl     = "https://your-host.example/HPWinPEMap.json"
$LenovoWinPEMapUrl = "https://your-host.example/LenovoWinPEMap.json"
```

The harness (`Test-WinRE.ps1`) mirrors production deliberately, so its OEM-map test options (menu options 3, 6, 7, 8) will download and extract against whatever URLs you set. Update both, or the harness and production will disagree about which pack a given machine should get.

**Important:** the manifest is a `DesiredStateId` input via its `version` field. If your self-hosted manifest has a different `version` than the default (because you forked it at a different time, or edited it), every managed machine will rebuild once on its next run. That is the intended behavior — the `version` field is the mechanism by which manifest changes propagate to machines — but it is worth knowing before you switch a fleet over.

The three maps are **not** `DesiredStateId` inputs. Changing the map URL alone does not trigger a rebuild. Changing the *contents* of a map (a new `dellVersion` value, for example) changes the `OEMPACK` field and therefore the DSI, and does trigger a rebuild. The map's `Generated` timestamp is informational and does not enter the DSI.

## Forking the driver manifest

### What it contains

The manifest is a single JSON file with two top-level fields:

- `version` — the manifest version string. This is a `DesiredStateId` input. Bump it whenever a `driverUrl` or the driver set changes.
- `drivers` — an array of VMD driver packages, each with `name`, `os` (array of `Win10` / `Win11`), `match` (CPU generation range and required device IDs), and `driverUrl`.

The schema is documented in detail in [driver-injection.md](driver-injection.md).

### Editing it

The manifest is hand-maintained. There is no builder. To fork it:

1. Download the current manifest.
2. Change `driverUrl` values to point at your own hosting for the `.7z` archives, or mirror the archives and keep the URLs unchanged if your network can reach the project's GitHub raw endpoint.
3. Bump `version` to a value that reflects your fork (e.g. `2026-10-02-yourorg-a`).
4. Host the JSON at a stable HTTPS URL.

### Pointing production at your manifest

Same edit as the maps — the `$DriverManifestUrl` line in `WinRE.ps1` and `Test-WinRE.ps1`. Because the manifest version is a `DesiredStateId` input, changing this URL to a manifest with a different `version` forces a rebuild on the next run.

## Mirroring the base WIM repository

### What's in it

The `$BaseWinRERepoApi` URL points at a GitHub repository that holds the project's curated `winre.wim` images, split into 7-Zip archives. The repository has two folders:

- `Win10/` — `winre.7z.001`, `winre.7z.002`, ... — a split archive whose extraction produces `winre.wim` for Windows 10.
- `Win11/` — the same, for Windows 11.

The production script reads the folder listing via the GitHub contents API, downloads every file whose name matches `^[Ww]inre\.7z\.\d+$`, sorts them by name, and extracts with 7-Zip. 7-Zip auto-detects sibling parts when extracting from the first part.

**When this is used.** Under v47 the base WIM is sourced from one of three places, in preference order: (1) the currently-registered WinRE image, (2) the manager's last-known-good copy at `C:\Recovery\WindowsRE\winre.wim`, and (3) the GitHub repository described here. Tiers 1 and 2 are local files on the machine being serviced; tier 3 is the only one that reaches the network. The GitHub repository is therefore reached only when the registered image is unusable — its servicing metadata cannot be read — and the LKG is either absent or fails its SHA256-vs-`state.CurrentImageHash` validation. On a machine whose own recovery image is present and usable, the base WIM is copied from the machine, not downloaded. If the registered image is unusable but the LKG is valid, the base WIM is copied from `C:\Recovery\WindowsRE\winre.wim`, still without reaching the network. The last-known-good copy is written by the manager itself on every successful deploy; it is not a self-hosted dependency, and no self-hosting work is needed to maintain it. The v47 patch 1 LKG migration bridge reads the pre-v47 state file's `CurrentImageHash` in isolation for LKG validation across the v46 to v47 version boundary; it does not affect the self-hosted endpoints. Under v47 patch 1 and v47 patch 2 the checkpoint file records the source-content hash of the WIM that produced the staged candidate; on resume the checkpoint validator re-validates that hash against the currently-available sources. This applies equally to registered, LKG, and GitHub sources and does not affect self-hosting, but it does mean that a machine whose source changed between the interrupted run and the resume will invalidate the checkpoint and rebuild from Step 2.

### Mirroring it

The repository can be forked or mirrored with any standard mechanism:

- **Fork on GitHub.** The fork's contents API is at `https://api.github.com/repos/<youruser>/OriginalWindowsREImages/contents`.
- **Mirror to internal object storage.** Copy the split archives to your endpoint and expose a listing endpoint that returns the same JSON shape as the GitHub contents API (an array of objects with `name`, `download_url`, and `size`).
- **Mirror to a static file server.** If your server returns a directory listing in the GitHub contents-API shape, the script will consume it unchanged. Most static servers do not, so this usually means a small wrapper.

**No signature is verified on the WIM itself.** The script extracts and uses whatever the repository provides. If you mirror the base WIM, you should mirror the same content — not rebuild it — or verify it out of band against the upstream archive before serving it.

### Pointing production at your mirror

One line in `scripts/WinRE.ps1`:

```powershell
$BaseWinRERepoApi = "https://api.github.com/repos/youruser/OriginalWindowsREImages/contents"
```

The harness does not use the base WIM repository as a production source — its GitHub base-WIM test options (4 and 5) point at the same API but for a different purpose (validating that the archives are downloadable and extractable). If you mirror the repo, update `$BaseWinRERepoApi` in `Test-WinRE.ps1` too, so the harness validates the same content your fleet will use.

## Air-gapped deployments

An air-gapped fleet cannot reach any of the external HTTPS endpoints. To run WinRE Manager in that environment:

1. **Fork or mirror the driver manifest** and the three OEM maps to an internal HTTPS endpoint.
2. **Mirror the OEM pack CDNs.** The Dell, HP, and Lenovo driver packs are downloaded from vendor CDNs, not from the project's gists. You will need to download each pack once, host it internally, and point the manifest's `driverUrl` (for VMD) and each map's `url` (for the OEM pack) at your internal hosting. The SHA256 that the scripts verify must be recalculated against your internal copy. This applies to Dell and Lenovo, whose maps carry SHA256; HP packs carry no SHA256 in the HP map, so only the HP URL needs to be pointed at the mirror -- there is no hash to recalculate for HP.
3. **Mirror the base WIM repository.** Copy the split archives from the project's repo to your internal endpoint. Same content, different URL.
4. **Edit the four URL variables in both scripts** as described above.
5. **Bump the manifest's `version` field** so the first run against the internal endpoint treats the manifest as a new deployment input. Every managed machine rebuilds once. That rebuild uses only internal URLs.

Note that the scripts' offline fallback (v44 patch 5) does not help in an air-gapped deployment in the way it does for a transient network outage. The offline fallback trusts the state file when the manifest fetch fails, but it does not fall through to a full-update pass without a live manifest. A machine that needs a rebuild in an air-gapped environment must reach the internal manifest endpoint.

## Signing and verification

**Not currently implemented.** The scripts fetch each JSON and each archive, verify hashes where the schema provides them, and use the result. There is no signature check, no pinned hash of the manifest or of the maps themselves.

If you want signature verification on top of what the scripts do today:

- **For the maps and the manifest.** Add a verification step at the top of `WinRE.ps1` that checks the raw JSON against a pinned SHA256 or against a signature you produce out of band. The script's fetch is `Invoke-RestMethod` returning a parsed object; you would need to change that to fetch the raw body, verify, then parse.
- **For the base WIM archives.** Same idea, applied to each split archive before extraction.
- **For the OEM pack downloads.** The SHA256 in the map already covers CDN corruption. To cover a compromised map, you would need to verify the map itself, per the point above.

None of these are part of the shipped design. Adding them is a fork-level change, not a supported configuration.

## Related documents

- [architecture.md](architecture.md) — the four design invariants, the enforcement tables, and the reasoning behind each. The fourth invariant is the one this document serves.
- [deployment.md](deployment.md) — the operator-facing deployment story, including the deployment-time translation of the four invariants and the exit-code matrix for a fleet.
- [driver-injection.md](driver-injection.md) — the manifest and map schemas that a self-hosted deployment must conform to.
- [state-and-idempotency.md](state-and-idempotency.md) — the `DesiredStateId` inputs, including which of the artifacts above are DSI inputs and which are not.
- [testing.md](testing.md) — how to validate a self-hosted configuration with the read-only harness before pushing it to a fleet.
