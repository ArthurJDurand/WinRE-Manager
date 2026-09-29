# Security Policy

## Scope

WinRE Manager runs as `NT AUTHORITY\SYSTEM` and modifies partition tables, the WinRE registration, and the BitLocker state of the **target recovery partition only** — never the OS volume's. The script downloads code-adjacent artifacts (WIMs, driver packs) from the internet and injects them into the recovery image.

Security-relevant areas:

- **Download integrity.** Every OEM pack download is hash-verified when the map provides a hash. Lenovo SHA256 and Dell SHA256/MD5 are always verified. HP packs do not currently carry a hash in the HP map. On the HP path the script requires that the HTTP request completed cleanly and that the downloaded file is non-empty (an explicit zero-byte check was added in v44 patch 1); a truncated file that nonetheless reports a clean HTTP completion and a non-zero size would not be detected.
- **Base WIM source.** Base WIMs are downloaded from a GitHub repository over HTTPS and extracted with 7-Zip. No signature verification is performed on the WIM itself.
- **Driver injection.** Driver INFs are injected with `dism /Add-WindowsDriver`. DISM enforces driver signing on the target machine's recovery image; unsigned drivers are rejected.
- **BitLocker interaction.** The script decrypts the target recovery partition in place (`manage-bde -off`) if the Device Encryption service has claimed it, polling until `manage-bde` reports the volume is unmanaged or fully decrypted. The script does not modify the OS volume's BitLocker state, does not add or remove key protectors on C:, and defers without change if the OS-fallback route would require C: to be modified.
- **Scheduled task privilege.** The recommended deployment model runs the script as SYSTEM. A compromise of the script or its sources is a compromise of every machine it runs on.

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

## Hardening guidance

If you deploy this at scale:

1. Fork the driver manifest and the three OEM maps to your own repository and point `$DriverManifestUrl`, `$DellWinPEMapUrl`, `$HPWinPEMapUrl`, `$LenovoWinPEMapUrl` at your fork.
2. Mirror the base WIM to your own HTTPS endpoint and point `$BaseWinRERepoApi` at your mirror.
3. Sign the downloaded WIM with your own code-signing certificate and add a verification step.
4. Run the scheduled task under a dedicated service account with a scheduled-task-scoped right to run as SYSTEM, rather than as SYSTEM directly.
