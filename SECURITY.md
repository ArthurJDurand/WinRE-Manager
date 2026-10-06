# Security Policy

## Scope

WinRE Manager modifies partition tables, the WinRE registration, and the BitLocker state of the **target recovery partition only** — never the OS volume's. It downloads code-adjacent artifacts (WIMs, driver packs) from the internet and injects them into the recovery image.

The script requires administrative privilege. The two supported execution modes are:

- **Elevated (single-machine repair).** Run from an administrator PowerShell prompt under the current user's elevated token. This is the mode for one-off repairs.
- **`NT AUTHORITY\SYSTEM` (fleet deployment).** Run from a scheduled task configured to run as SYSTEM, triggered at boot and weekly. This is the recommended mode for a managed fleet.

The security posture described below applies to both modes: the script always requires a privilege level capable of modifying partition tables and the WinRE registration. A compromise of the script or its sources is a compromise of whatever privilege level it is running under.

### Where security sits in the design

[`docs/architecture.md`](docs/architecture.md) opens with four design invariants — *never break Windows RE*, *never leave a machine without a working recovery route*, *minimize the `reagentc /disable` → `reagentc /enable` window*, and *do no work unless needed; prepare everything before touching anything*. Two of those rules are the security posture's foundation.

**Rule 4 — prepare everything before touching anything.** The script resolves, downloads, verifies, and injects every driver artifact *before* the destructive sequence begins. A failure at any point in the preparation phase stops the run in a state where the machine's existing recovery route is untouched. This is what makes a compromised or unreachable driver source a **deferral** rather than a **corruption**: the run exits with `EXIT_WARNING` and leaves WinRE exactly as it found it. The alternative — download first, destroy second, verify never — is what most recovery tools do, and it is the design the project deliberately avoids.

**Rule 1 — never break Windows RE.** The pipeline gate (v44 patch 1) stops the run before deployment when injection fails, because a WIM that cannot see the OS disk is actively misleading. The gate is a safety property, not a security boundary, but it has the same effect: a compromised or partially-downloaded driver package never reaches the recovery partition.

Self-hosting (see [docs/self-hosting.md](docs/self-hosting.md)) is the operator-facing response to the residual trust placed in the maintainer's gists under Rule 4. It exists because "prepare everything" is only as strong as the provenance of the artifacts being prepared.

Security-relevant areas:

- **Download integrity.** Every OEM pack download is hash-verified when the map provides a hash. Lenovo SHA256 and Dell SHA256/MD5 are always verified. HP packs do not currently carry a hash in the HP map. On the HP path the script requires that the HTTP request completed cleanly and that the downloaded file is non-empty (an explicit zero-byte check was added in v44 patch 1); a truncated file that nonetheless reports a clean HTTP completion and a non-zero size would not be detected.
- **Base WIM source.** The base WIM is sourced, in preference order, from (1) the currently-registered WinRE image, (2) the manager's last-known-good copy at `C:\Recovery\WindowsRE\winre.wim`, or (3) a GitHub repository over HTTPS, extracted with 7-Zip. Sources (1) and (2) are local files under the operator's own control; source (3) is a remote download. No signature verification is performed on the WIM itself in any of the three cases. The last-known-good source is trusted only when its SHA256 matches `state.CurrentImageHash` — a partial or stale file is not promoted to LKG, and a failed fallback copy in a prior run cannot silently promote a stale WIM. The registered image is preferred unless the LKG is provably newer by the image's DISM servicing metadata (`Version` + `SPBuild`, with `SPLevel` as a secondary tiebreak and `Architecture` required to match); the GitHub source is used only when neither local source is usable.
- **Driver injection and normalization.** v47 normalizes the mounted image to zero third-party drivers (`Remove-WindowsDriver` against the image's own filterless third-party inventory) before the current recipe is injected (`Add-WindowsDriver`). Driver signing is enforced by the Windows kernel at driver-load time; an unsigned driver is refused by the kernel, not by `Add-WindowsDriver` at injection. The injection stage stages the driver package into the image's driver store; the kernel enforces signing when the driver is loaded at WinRE boot. The strip stage is hard-gated: if enumeration, removal, or the final zero-driver verification fails at any point, the candidate is discarded before any partition work, `reagentc` call, or WIM deployment. The deployed image is therefore a deterministic function of the current recipe, not a lineage of prior injections.
- **BitLocker interaction.** The script decrypts the target recovery partition in place (`manage-bde -off`) if the Device Encryption service has claimed it, polling until `manage-bde` reports the volume is unmanaged or fully decrypted. The script does not modify the OS volume's BitLocker state, does not add or remove key protectors on C:, and defers without change if the OS-fallback route would require C: to be modified. As of v48 patch 1, the intervening-anchor path also reads (but never modifies) the BitLocker state of the anchor partition: it requires the anchor to be fully decrypted, or BitLocker-encrypted and currently unlocked, and defers if the state is locked or indeterminate.
- **Elevated or SYSTEM privilege.** Both execution modes run with enough privilege to modify partition tables, the WinRE registration, and the BitLocker state of the target recovery partition. A compromise of the script or its sources is a compromise of every machine it runs on at that privilege level. The fleet-deployment mode (SYSTEM, scheduled task) is the higher-impact case because it runs automatically and unattended on many machines.
- **Fail-fast elevation guard (v48 patch 2).** An unelevated launch of `WinRE.ps1` is refused in milliseconds with `FATAL: WinRE Manager requires an elevated (Administrator) PowerShell session.` and exit code 3, before the program lock, before hardware probes, and before any network fetch. On refusal the guard creates the log directory itself so its FATAL message has somewhere to be written. The process does not consume network, disk, or CPU resources on the way to the refusal.
- **Architecture gate (v48 patch 1).** The manager refuses to run on any OS architecture other than `x64` — ARM64, x86, and any architecture whose token cannot be resolved exit with `EXIT_WARNING` before any state mutation. The refusal is a stable deferral, not a crash: no partition is touched, no WIM is deployed, and no state file is written. The gate exists because the pipeline has not been validated on non-x64 targets; ARM64 support would be a separate, tested change.

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
- The GitHub-hosted driver manifest and OEM maps are community-maintained. Do not trust them for anything beyond this project's scope. Under the fourth design invariant ("prepare everything before touching anything"), the manifest and maps are prepared *before* the destructive sequence begins; a compromise of either affects the deployed recovery image but cannot affect a machine that the script defers on. If your trust model does not extend to third-party content hosted outside your perimeter, self-hosting is the response — see [docs/self-hosting.md](docs/self-hosting.md) for the trust model and the exact variables to change.
- **The offline fallback trust model — v44 patch 5 through v47, closed by v48 patch 1.** When the driver manifest fetch fails after its retry budget — typically a DNS failure, a proxy block, or a total network outage — the script reads `C:\Recovery\OEM\winre_state.json` and treats its stored `DesiredStateId` as ground truth, then takes the fast path if the local safety checks (WinRE `Enabled`, exactly one **type-coded** recovery partition on the OS disk, deployed WIM hash matches the stored `CurrentImageHash`) also pass. Under v44 patch 5 through v47 patch 3, the residual risk was that a machine whose hardware changed while offline could take the fast path with a stale DSI, because recomputing the DSI would require the OEM pack version from the OEM map — another gist on the same unavailable network.

  **v48 patch 1 closes that residual with the `LocalInputsId` field.** The state file now records a hash over the three deployment inputs observable without a network fetch (hardware identity, OS build, CPU vendor/generation). On the offline fallback path, the run recomputes that hash from the current machine and defers with `EXIT_WARNING` when the stored and current values disagree, rather than trusting a `DesiredStateId` that describes a machine whose hardware or OS has since changed. VMD presence is deliberately excluded because it depends on the manifest's `requiredDevices` patterns, which is the input the offline fallback does not have. See [CHANGELOG.md](CHANGELOG.md#v48-patch-1--2026-10-06) for the v48 patch 1 details.

  This remains a **documented correctness limitation, not a privilege boundary crossing.** Modifying `C:\Recovery\OEM\winre_state.json` requires administrator or SYSTEM privileges — the same privileges the script itself runs under — and an attacker with those privileges already has full control of the machine. The design also deliberately makes the state file human-editable: the loop-breaker recovery procedure instructs the operator to delete it to reset the enable-failure counter. See [`docs/architecture.md`](docs/architecture.md) — Rule 4 — for the four-rule framing of the offline behavior.

## Hardening guidance

If you deploy this at scale, four changes reduce the trust surface:

1. **Fork the driver manifest and the three OEM maps** to your own repository and point `$DriverManifestUrl`, `$DellWinPEMapUrl`, `$HPWinPEMapUrl`, `$LenovoWinPEMapUrl` at your fork. This is the strongest single mitigation and directly answers the "is the maintainer's gist untrusted?" question that the fourth design invariant raises.
2. **Mirror the base WIM** to your own HTTPS endpoint and point `$BaseWinRERepoApi` at your mirror.
3. **Sign the downloaded WIM** with your own code-signing certificate and add a verification step.
4. **Remove SYSTEM membership from any account that does not need it, and disable RMM "run as SYSTEM" paths when a scheduled-task path is available.** The script's partition operations require SYSTEM-level privilege, so the task itself must run as SYSTEM; the hardening is to ensure that the scheduled task is the *only* execution path with that privilege, and that no interactive or RMM "run as SYSTEM" path can bypass the task's `IgnoreNew` protection and the program lock. This is a Windows security configuration and is outside the scope of the self-hosting doc.

Steps 1 through 3 change URLs and add verification to the production script; the full procedure — including the trust model, the exact variables to change in both `WinRE.ps1` and `Test-WinRE.ps1`, the map-builder scripts, and the air-gapped deployment workflow — is documented in [docs/self-hosting.md](docs/self-hosting.md). Step 4 is a Windows security configuration and is outside the scope of the self-hosting doc.

## Related documents

- [docs/architecture.md](docs/architecture.md) — the four design invariants (particularly Rule 1 and Rule 4), the pipeline, and the control-flow invariants that this document's hardening guidance is designed to preserve.
- [docs/self-hosting.md](docs/self-hosting.md) — the trust model for the external artifacts, the map-builder scripts, and the air-gapped deployment workflow.
- [docs/deployment.md](docs/deployment.md) — the operator-facing deployment story, including the four-rule translation into fleet-operator guidance.
- [docs/driver-injection.md](docs/driver-injection.md) — the driver package sources and the injection success gate.
- [CONTRIBUTING.md](CONTRIBUTING.md) — the four-bullet requirement for PRs that touch the destructive sequence.
