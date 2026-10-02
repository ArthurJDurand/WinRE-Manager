# Security Policy

## Scope

WinRE Manager modifies partition tables, the WinRE registration, and the BitLocker state of the **target recovery partition only** — never the OS volume's. It downloads code-adjacent artifacts (WIMs, driver packs) from the internet and injects them into the recovery image.

The script requires administrative privilege. The two supported execution modes are:

- **Elevated (single-machine repair).** Run from an administrator PowerShell prompt under the current user's elevated token. This is the mode for one-off repairs.
- **`NT AUTHORITY\SYSTEM` (fleet deployment).** Run from a scheduled task configured to run as SYSTEM, triggered at boot and weekly. This is the recommended mode for a managed fleet.

The security posture described below applies to both modes: the script always requires a privilege level capable of modifying partition tables and the WinRE registration. A compromise of the script or its sources is a compromise of whatever privilege level it is running under.

Security-relevant areas:

- **Download integrity.** Every OEM pack download is hash-verified when the map provides a hash. Lenovo SHA256 and Dell SHA256/MD5 are always verified. HP packs do not currently carry a hash in the HP map. On the HP path the script requires that the HTTP request completed cleanly and that the downloaded file is non-empty (an explicit zero-byte check was added in v44 patch 1); a truncated file that nonetheless reports a clean HTTP completion and a non-zero size would not be detected.
- **Base WIM source.** Base WIMs are downloaded from a GitHub repository over HTTPS and extracted with 7-Zip. No signature verification is performed on the WIM itself.
- **Driver injection.** Driver INFs are injected with `dism /Add-WindowsDriver`. DISM enforces driver signing on the target machine's recovery image; unsigned drivers are rejected.
- **BitLocker interaction.** The script decrypts the target recovery partition in place (`manage-bde -off`) if the Device Encryption service has claimed it, polling until `manage-bde` reports the volume is unmanaged or fully decrypted. The script does not modify the OS volume's BitLocker state, does not add or remove key protectors on C:, and defers without change if the OS-fallback route would require C: to be modified.
- **Elevated or SYSTEM privilege.** Both execution modes run with enough privilege to modify partition tables, the WinRE registration, and the BitLocker state of the target recovery partition. A compromise of the script or its sources is a compromise of every machine it runs on at that privilege level. The fleet-deployment mode (SYSTEM, scheduled task) is the higher-impact case because it runs automatically and unattended on many machines.

## Reporting a vulnerability

**Do not open a public issue.**

Report vulnerabilities privately through one of these channels:

1. **GitHub Security Advisories** (preferred) — open a private advisory at <https://github.com/ArthurJDurand/WinRE-Manager/security/advisories/new>.
2. If you cannot use GitHub Security Advisories, open a blank issue at <https://github.com/ArthurJDurand/WinRE-Manager/issues/new> with only the word `security-contact` in the title and no body. A maintainer will reach out to you by reply.

Include:

- Affected version.
- Reproduction steps.
- Impact assessment.
- Whether the vulnerability is reachable without elevation.

You will receive a response within 72 hours. This is a best-effort project; the maintainer is a single individual, and coordinated disclosure timelines will be negotiated in good faith.

## Known limitations (not vulnerabilities)

The following are documented behaviour, not defects:

- `Invoke-WebRequest` in `scripts/WinRE.ps1` uses `-UseBasicParsing` and a static User-Agent. This is intentional — the script does not need a full browser engine, and the User-Agent is used to bypass CDN blocks on some vendor sites.
- The fallback copy to `C:\Recovery\WindowsRE\winre.wim` is attempted even if the primary deployment succeeded. An ACL denial is logged and treated as non-fatal.
- Driver packs are downloaded from the OEM's own CDN. The project does not redistribute them.
- The GitHub-hosted driver manifest and OEM maps are community-maintained. Do not trust them for anything beyond this project's scope.
- **The offline fallback (v44 patch 5) trusts the state file's stored `DesiredStateId` without recomputing it from the machine's current inputs.** When the driver manifest fetch fails after its retry budget — typically a DNS failure, a proxy block, or a total network outage — the script reads `C:\Recovery\OEM\winre_state.json` and treats its stored `DesiredStateId` as ground truth, then takes the fast path if the local safety checks (WinRE `Enabled`, exactly one **type-coded** recovery partition on the OS disk, deployed WIM hash matches the stored `CurrentImageHash`) also pass. It does not verify that the machine's current hardware matches the inputs that produced that ID, because recomputing would require the OEM pack version from the OEM map — another gist on the same unavailable network. The residual risk is that a machine whose hardware changed while offline could take the fast path with a stale DSI; the next successful manifest fetch detects the drift and forces a rebuild. This is a **documented correctness limitation, not a privilege boundary crossing.** Modifying `C:\Recovery\OEM\winre_state.json` requires administrator or SYSTEM privileges — the same privileges the script itself runs under — and an attacker with those privileges already has full control of the machine. The design also deliberately makes the state file human-editable: the loop-breaker recovery procedure instructs the operator to delete it to reset the enable-failure counter. A `LocalInputsId` field would close the residual risk; it is planned as its own version boundary.

## Hardening guidance

If you deploy this at scale, four changes reduce the trust surface:

1. **Fork the driver manifest and the three OEM maps** to your own repository and point `$DriverManifestUrl`, `$DellWinPEMapUrl`, `$HPWinPEMapUrl`, `$LenovoWinPEMapUrl` at your fork.
2. **Mirror the base WIM** to your own HTTPS endpoint and point `$BaseWinRERepoApi` at your mirror.
3. **Sign the downloaded WIM** with your own code-signing certificate and add a verification step.
4. **Run the scheduled task under a dedicated service account** with a scheduled-task-scoped right to run as SYSTEM, rather than as SYSTEM directly.

Steps 1 through 3 change URLs and add verification to the production script; the full procedure — including the trust model, the exact variables to change in both `WinRE.ps1` and `Test-WinRE.ps1`, the map-builder scripts, and the air-gapped deployment workflow — is documented in [docs/self-hosting.md](docs/self-hosting.md). Step 4 is a Windows security configuration and is outside the scope of the self-hosting doc.
