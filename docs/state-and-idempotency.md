---
title: "State and idempotency — WinRE Manager"
description: "Understand WinRE Manager state files, deployment identity, protected pending operations, checkpoints, retry delays and recovery-task lifecycles."
---

# State and idempotency

`DesiredStateId` identifies the deployment inputs. Idempotency also checks the actual recovery route and partition capacity; the identity does not encode current geometry, free space or BitLocker state. A separate durable pending-deployment record protects unfinished work across interruption and identity changes.

## `DesiredStateId`

A SHA256 computed deterministically from seven fields:

```
HW=<Manufacturer>|<Model>|<MachineType>
OS=<Build>
CPU=<vendor>|<generation or N>
VMD=<True|False>
MANIFEST=<manifest.version>
OEMPACK=<OEM pack version, or NONE>
SCRIPT=<ScriptVersion>
```

The seven fields are joined with `;;`, encoded as UTF-8, and hashed. The result is a 64-character hex string.

### What each field means

- **`HW`** — vendor, model, and machine type. On Lenovo the machine type is derived from the model or product name; on other vendors it is the first four characters of `Win32_ComputerSystemProduct.Version` when that field is at least four characters long, and `UNKN` otherwise. A Lenovo ThinkPad 21L1 and a Lenovo 21L2 have different IDs. Two machines of the same model have the same ID.
- **`OS`** — the Windows build number. A machine that upgrades from 26100 to 26200 gets a new ID and rebuilds.
- **`CPU`** — CPU vendor (`Intel` or `AMD`) and Intel generation. The generation is the value returned by `Get-IntelProcessorGeneration`, or the literal string `N` when the generation cannot be parsed (AMD CPUs, Intel Celeron / Pentium / Atom / Xeon, and N/J-series CPUs). The `N` is deterministic and stable: it does not flip between runs on the same hardware. **The vendor label is not a general vendor classifier.** Non-Intel processors are labelled `AMD` — the label is a bucket for "not Intel", not an assertion about the actual silicon vendor. A future non-Intel, non-AMD CPU (ARM, Qualcomm, RISC-V, etc.) would also be labelled `AMD` unless `Get-HardwareObject` is changed. The purpose of the field is to determine whether the manifest's Intel-generation-gated VMD driver packages apply, not to record the machine's CPU vendor for its own sake. Do not treat `CPU=AMD` as a claim about the silicon.
- **`VMD`** — `True` or `False` (the .NET Boolean string form of the machine-wide presence check). Computed from the union of the `requiredDevices` field across all manifest entries, matched against the machine's present PnP devices. VMD presence is a deployment input because it determines whether the VMD driver package is selected for injection. As of v44 patch 6, the VMD presence query is fail-closed: an enumeration error during the query produces an indeterminate result rather than `absent`, and the run defers with `EXIT_WARNING` before committing any state. A deferral does not write a state file, so the `VMD` field is never populated on the basis of a guess.
- **`MANIFEST`** — the version field of the driver manifest JSON. The manifest author bumps it when driver URLs change.
- **`OEMPACK`** — the resolved OEM pack version for this machine's vendor. For Dell it is the `dellVersion`; for HP the SoftPaq `version`; for Lenovo the `dsId`. If the vendor is unsupported or the map failed to resolve, this is `NONE`. As of v44 patch 6, the Lenovo resolution distinguishes five states. Only `unknown-mt` (machine type could not be determined) and `no-entry` (map loaded, no entry for this machine type) produce `OEMPACK=NONE` and let the run proceed to completion. `map-unavailable` and `malformed-entry` mark the run as incomplete and the state file is not written; the next run retries.
- **`SCRIPT`** — the production script's `ScriptVersion` constant.

### Why CPU and VMD were added in v44

The v43 `DesiredStateId` was a hardware fingerprint for the base WIM and the OEM pack, but it did not capture the inputs that determine **VMD driver selection**. A machine whose VMD presence flipped from `absent` to `present` — because of a BIOS or firmware update that changed the default, or a deliberate configuration change applied post-deployment — would take the fast path with a driver set that no longer matched its hardware. On a VMD-based system the resulting WinRE cannot see the OS disk at all, and Startup Repair fails. The same class of problem applies to a CPU or motherboard swap on the same chassis with the same `Manufacturer` / `Model` / `MachineType` string.

Adding these two inputs to the ID makes it a **deployment-input fingerprint** rather than a hardware fingerprint. The principle is: the ID should change whenever the inputs that determine the desired WinRE artifact change. It should not change merely because unrelated machine state changes.

The `CPU` field's job within this scheme is narrow: it distinguishes Intel CPUs whose generation selects a VMD driver package from every other CPU, for which the same generation-gated selection is skipped. The `AMD` label is a marker for "not an Intel generation to match against", not a general-purpose vendor classification. See the `CPU` bullet under "What each field means" for the full scope note.

The v44 patch 1 revision deliberately does **not** go further than this. It does not hash the actual resolved driver list (which would be cleaner in principle — the ID would change exactly when the artifact would change, not when hardware that happens to correlate with the artifact changes) because the manifest `version` field already plays that role when the manifest author maintains it correctly. If a future revision needs to hash the resolved driver set, it should do so together with another `ScriptVersion` bump.

**The `DesiredStateId` does not encode the production recipe.** The v47 strip stage is part of the production recipe — what the script *does* to a base image during rebuild — not a deployment input. The v47 patch 1 DSI bump exists because the strip changes the deployed WIM bytes, and the bump is the mechanism by which v47 converges the fleet on the strip-normalized driver set. The v49 pre-deployment gates (source-ownership classification, never-downgrade storage-driver check, storage-applicability gate) are likewise recipe refinements that narrow what the pipeline will deploy. They ship under the v49 `SCRIPT` value; future recipe refinements that do not bump `ScriptVersion` would not change the DSI, and a machine whose inputs do not otherwise change would keep its earlier-recipe WIM until a natural DSI change triggered its next rebuild. The `ScriptVersion` discipline is what closes the gap: a recipe change that materially alters the deployed artifact on healthy machines is expected to ship with a `ScriptVersion` bump and a corresponding migration note.

### When the ID changes

Any of the following cause the ID to change, which forces a full rebuild on the next run:

- A new `ScriptVersion`.
- A new Windows build.
- A new manifest `version`.
- A new OEM pack version for the machine's vendor.
- A hardware change (motherboard swap that changes `Manufacturer` / `Model` / `MachineType`).
- A change in CPU vendor or Intel CPU generation.
- A change in VMD presence on the machine (typically a BIOS or firmware update that flips the VMD default).

### When it does not change

- Any cosmetic or logging fix shipped without bumping `ScriptVersion`.
- Any patch generation shipped under the same `ScriptVersion` that does not change the DSI inputs — cosmetic fixes, logging-only changes, and bug fixes to the main flow all ship this way, and the ID is unchanged so healthy machines do not rebuild.
- **v47 patch 2 is a narrow exception to the above.** It changes the DSI value on a machine whose padded `Win32_ComputerSystemProduct.Version` field is at least four characters long while its trimmed value is shorter than four (observed: ASUS machines that set the field to "1.0 "). The DSI inputs are unchanged; the value that enters the `HW` component has been normalised. Those machines rebuild once on their next scheduled run; all other machines continue on the fast path. See the v47 patch 2 Migration Note in `CHANGELOG.md` for the exact trigger class.
- **v49 is not an exception — it bumps `ScriptVersion`.** The bump is the version boundary that converges the fleet on the v49 pipeline. It is documented as a `ScriptVersion` change because the release narrows what the pipeline will deploy: a `Foreign-With-Drivers` source is preserved as-is rather than stripped and re-injected, a storage driver that would be a version downgrade against one already present is not injected, and a candidate in which any one present SCSIAdapter-class device has no matching INF is refused by the pre-deployment storage-applicability gate. Each of these is a change to the recipe that materially alters the deployed artifact or the pipeline's deployment decision on at least some machines; the bump ensures every managed machine exercises the new pipeline once and every subsequent rebuild produces an image that is a function of the current recipe only. See the v49 Migration Note in `CHANGELOG.md` for the fleet behaviour and the rollback procedure.
- A new WIM hash at the registered location. That is a separate check (see below), not part of the ID.
- A Windows Update that changes the WIM inside the recovery partition without changing the OS build. The DSI is unchanged. Under v46 the fast-path WIM-hash comparison would have detected this; under v47 the metadata comparison will not, unless the update also bumped `Version` or `SPBuild`. This is the metadata-neutral DU residual, named in [CHANGELOG.md](../CHANGELOG.md) under the v47 patch 1 entry.
- A change to the BitLocker policy or the target-preparation logic. The state file does not record BitLocker state; it records the deployment's identity and outcome.
- A change to the recovery-partition classifier (the v44 patch 7 type-code-authority rule). The classifier affects the fast path's control-flow decision but not the identity of the deployment; a label-only partition on the OS disk changes whether the fast path fires, not what the state file records.
- A change to the shrink-first ordering or the single-boundary geometry model (v45 patch 1). These change *how* the destructive path produces the target state, not *what* the target state is. The state file does not record partition-layout details.
- A change to the pre-deletion resolver guard, the extension-failure fallback bucket cap, the deletion-failure rollback reporting, or the layout assertion's fail-closed branch (all v46 patch 2). These change *how* the destructive path fails and recovers, not *what* the target state is. The state file's schema and the fast path's conditions are unchanged.
- The backup and restore actions introduced in v49 (`-Action Backup`, `-Action Restore`). They are standalone actions, not part of the repair pipeline. They read and write a backup directory and its `backup.json` sidecar. A backup does not touch the state file and does not change the deployment's identity. A restore replaces the WIM on the currently registered route; on successful completion it deletes the state file, the checkpoint file, and the partition deferral marker so the next repair run re-evaluates the machine from a clean slate. The seven DSI inputs themselves are unchanged — the deployment identity is a function of the inputs above, and none of them changes because a WIM was restored — but the recorded state file is deliberately removed to force a full re-evaluation.
- The temporary crash-recovery scheduled task introduced in v49 (`WinRE Manager - Resume`). It is registered by a Repair or Restore run and deleted on clean completion. It is a per-run safety net, not a machine-state artifact, and it is not recorded in the state file. Its presence or absence does not affect the fast path. See "The temporary resume task" below for the lifecycle, the persist-signal list, and the v50 patch 4 staging flags.
- The stable install location introduced in v49 (`C:\ProgramData\OEM\WinRE-Manager\WinRE.ps1`). The installed copy is a persistent artifact on disk — a wrapper-managed file, not a state-file field. Its presence does not change the DSI; a machine that never installs the maintenance task and a machine that does will compute the same `DesiredStateId` for the same inputs.
- The native-boot VHDX fail-closed gate introduced in v49. This default-Repair startup check is not a DSI input. It refuses a `File Backed Virtual` OS disk with another nonvirtual disk, or an indeterminate topology, before Repair partition/WinRE changes. Logging and staging can precede it; Backup and Restore dispatch before it. Guest disk-file format alone does not trigger refusal.
- A change to the driver manifest's contents without a `version` bump. This is a manifest-authoring bug; production assumes the version field is maintained.

`ScriptVersion` changes can cause fleet-wide re-evaluation. Correctness and recoverability determine whether a bump is appropriate; avoiding fleet work is not a reason to keep an insufficient identity scheme. The project documents changes to deployed WIM bytes, placement policy or DSI inputs in a migration note. Bug fixes to the main flow ship under the same version without a DSI change, and correct the affected machines on their next run without disturbing the rest. The [CHANGELOG.md](../CHANGELOG.md) carries the per-release record.

The v44 patch 1, v45 patch 1, v46 patch 1, v47 patch 1, v48 patch 1, v49, and v50 patch 1 revisions are the deliberate exceptions. Each changes an input the `DesiredStateId` recipe depends on: v44 added `CPU` and `VMD` to the field list; v45, v46 patch 1, v47 patch 1, v48 patch 1, v49, and v50 patch 1 each changed the value of the `SCRIPT` field. Because the ID includes those inputs, the ID changes on every managed machine, and every managed machine performs one full-update pass on its next run before returning to the fast path. See the migration notes in `CHANGELOG.md`; rolling back any of these seven revisions to the preceding one likewise causes a one-time DSI mismatch and rebuild under the older behavior.

The v47 patch 1 bump has an additional purpose beyond the field-value change: it is the version boundary that converges the fleet on the strip-normalized driver set introduced in that release. A machine that would have kept its v46-injected OEM/VMD drivers under the v46 lineage model now rebuilds against the strip-normalized base, and every subsequent rebuild produces an image that is a function of the current recipe only. The same bump makes every machine's first v47 run write a `DeployedWinREMetadata` anchor so the v47 drift detector has a baseline.

The v49 bump has a similar character: it is the version boundary that converges the fleet on the v49 pipeline, whose source-ownership classification, never-downgrade storage-driver check, and pre-deployment storage-applicability gate together narrow what the pipeline will deploy. A machine that would have kept a foreign-vendor-populated source or an older storage driver under the v47/v48 lineage model now rebuilds against the current pipeline's decisions, and every subsequent rebuild produces an image that is a function of the current recipe only.

## The state file

Path: `C:\Recovery\OEM\winre_state.json`.

The legacy state readers and writer do not authenticate the file's ACL or ancestor chain. Protect this file and its parents from untrusted modification: current and historical hashes and lineage values can authorize ownership decisions. The protected pending-deployment store is a separate boundary and does not establish the authenticity of legacy state. See [Security](../SECURITY.md#known-limitations-and-accepted-risks) for the accepted parent-directory policy and its consequences.

### Schema

```json
{
    "DesiredStateId":           "<64-char hex>",
    "CurrentImageHash":         "<last positively manager-owned image SHA256, or null>",
    "InjectedDriverSetVersion": "<manifest.version at deploy time>",
    "LastUpdated":              "yyyy-MM-dd HH:mm:ss",
    "PendingReboot":            false,
    "UsedOSFallback":           false,
    "RepairAttempts":           0,
    "DeployedDiskNumber":       4,
    "DeployedPartitionNumber":  4,
    "LastEnableResult":         "ok",
    "EnableFailureAttempts":    0,
    "DeployedWinREMetadata":    "10.0.26100.9545|9545",
    "LocalInputsId":            "<64-char hex>",
    "ForeignSourceAcceptedHash":"<SHA256 hex>",
    "LineageId":                "<identifier>"
}
```

`ForeignSourceAcceptedHash` and `LineageId` are the v49 additions. Both are optional. `ForeignSourceAcceptedHash` is written when the manager preserves a source rather than normalizing it. In v49 there are two such paths: the source-ownership classification preserving a `Foreign-With-Drivers` source, and the never-downgrade storage-driver check discarding the whole candidate on a detected downgrade. On both paths the field records the preserved source's hash so a later run recognizes the accepted bytes. Patch 5 still checks the actual dedicated layout and capacity before fast-path acceptance. The accepted foreign hash is never promoted into `CurrentImageHash` merely because its bytes were copied. `LineageId` is a persistent identifier generated on the first v49 deploy and embedded in the provenance marker written into the deployed image; it is carried forward across runs on every subsequent state write. Both fields default to `$null` when absent, so a state file written by v48 or earlier is accepted without triggering a rebuild.

`DeployedDiskNumber` and `DeployedPartitionNumber` are present only when the deployment reached a dedicated recovery partition. They are used by the pending-reboot path to re-point `reagentc /setreimage` at the correct location after a reboot. They are absent from an OS-fallback state file, because the fallback target is `C:\Recovery\WindowsRE` — a path, not a partition by number.

`LastEnableResult` records the outcome of the last `reagentc /enable` attempt that reached a state-write point. Its values are `"ok"` (exit 0 and status confirmed `Enabled`), `"reboot"` (registration succeeded but a reboot is required), `"failed"` (generic hard failure), and `"bitlocker"` (the target recovery partition was BitLocker-protected, even after `Set-RecoveryPartitionReadyForWinRE` prepared it). `EnableFailureAttempts` counts *consecutive* terminal outcomes — both `"failed"` and `"bitlocker"` increment the counter. Both fields default to `"ok"` / `0` when absent, so a state file written by an earlier version of the script is accepted without triggering a rebuild.

`DeployedWinREMetadata` (v47 patch 1) records the DISM servicing metadata of the WIM that was actually deployed, in the form `<Version>|<SPBuild>` — for example, `10.0.26100.9545|9545`. It is written at the end of every successful deployment and carried forward on non-deployment state writes via a script-scoped value, so a run that does not rebuild preserves the anchor. The v47 drift detector compares the currently-registered WinRE's DISM servicing metadata against this anchor; equality means no rebuild, inequality forces one. Microsoft documents that an LCU bumps `SPBuild` while the base `Version` may remain unchanged, so both are compared.

The field is absent on v46-and-earlier state files. Its absence forces a rebuild on the first v47 run because the drift detector has no anchor to compare against. The tradeoff of comparing metadata rather than the WIM hash is that a Dynamic Update may change a serviced image's contents without changing either field — the metadata-neutral DU residual, named in [CHANGELOG.md](../CHANGELOG.md) under the v47 patch 1 entry. The WIM hash remains in the state file as `CurrentImageHash`; it is used for LKG validation, copy verification, deployment verification, and the pre-`/disable` race detector, but it is no longer a rebuild trigger.

`LocalInputsId` (v48 patch 1) records a hash over the three deployment inputs observable on the local machine without a network fetch: hardware identity (`Manufacturer|Model|MachineType`), OS build, and CPU vendor/generation. VMD presence is deliberately excluded because its detection depends on the manifest's `requiredDevices` patterns, which the offline fallback does not have. The field is written by every `Write-WinREState` call and read only on the offline fallback path. On that path, the run recomputes the hash from the current machine and compares it against the stored value; a mismatch defers with `EXIT_WARNING` rather than taking the fast path with a `DesiredStateId` that describes a machine whose hardware or OS has since changed. The field defaults to `$null` when absent, so a state file written by a v47 or earlier script is accepted without forcing a rebuild — the next successful online run populates it.

The v46 patch 2 hardenings do not change the schema. The v47 patch 1 release adds two new fields: the state file's `DeployedWinREMetadata` field (described above) and the checkpoint file's optional fifth `SourceHash` field (described under "The v47 source-hash binding"). The v48 patch 1 release adds a third: the state file's `LocalInputsId` field (described above). The v49 release adds two more optional state-file fields: `ForeignSourceAcceptedHash` (written when a source is preserved rather than normalized — on the `Foreign-With-Drivers` preservation path and on the never-downgrade detection path) and `LineageId` (the persistent lineage identifier embedded in the provenance marker). None of the new deferral reasons introduced by these patches writes a new field; the reasons flow through the existing `Deferred` return path and, where applicable, through the existing `GeometryRestoreFailed` flag and state-file-invalidation mechanism.

### Read semantics

`Read-WinREState` is called once, near the top of the main flow, with the current `DesiredStateId`.

- If the file does not exist → return all-`$null` / all-`$false` defaults, treated as "no state."
- If the file exists and `DesiredStateId` matches → return the parsed state. Log "State file accepted."
- If the file exists and `DesiredStateId` does not match → return defaults, log "State file DesiredStateId mismatch - stale." The file is not deleted; the next write overwrites it.
- If the file exists but cannot be parsed → return defaults, log "Failed to parse state file."

Note: the stale file is left in place. If the next run also fails to reach a state-write point, the stale file stays. The next successful run overwrites it.

`LastEnableResult` and `EnableFailureAttempts` are read with defaults of `"ok"` and `0`. A state file written by an earlier version of the script that does not contain these fields is accepted without triggering a rebuild.

`DeployedWinREMetadata` is read as `$null` when absent. A v46-or-earlier state file lacks the field, and the null value forces a rebuild on the first v47 run — the drift detector has no anchor to compare against, so the run cannot take the fast path. This is the intended v46 → v47 transition; after one full update, the state file carries the anchor and subsequent runs evaluate against it.

`LocalInputsId` is read as `$null` when absent. On the offline fallback path, a `$null` stored value means the state file predates v48 patch 1 and the drift check is skipped — the run proceeds as v47 did, with a WARN noting that the field is missing. On any online path the field is written but not read. A state file whose stored `LocalInputsId` does not match the current locally-computable inputs causes the offline fallback to defer rather than trust the stored `DesiredStateId`.

### Partition deferral sidecar

`C:\Recovery\OEM\winre_partition_deferred.json` records a partition refusal separately from deployment ownership. Patch 5 re-evaluates the relevant present conditions before suppressing another attempt. A matching `DesiredStateId` alone does not prove that the same refusal still applies: free space, geometry, target accessibility and encryption state can change without a DSI change.

The version 2 marker contains `SchemaVersion`, `DesiredStateId`, `Since`, `Category`, `Reason` and `RetryAfterUtc`. `Category` distinguishes `Capacity` from `Execution`; execution retries have a one-hour `RetryAfterUtc`, while capacity is freshly assessed. Legacy markers without category/backoff do not suppress a fresh assessment.

The existing reason classes include both capacity refusals and execution/verification failures. `post-shrink free space below minimum` is a capacity constraint. `pre-shrink failed`, `pre-shrink verification failed` and `resize rounding reduced planned extent` are observed operation/geometry failures; they must not be treated as permanent capacity refusals. Patch 5 uses the recorded reason and current preconditions to decide whether a retry is due.

Capacity is checked against the actual required shrink and free-space reserve. Rounding the observed free space into a coarse bucket could hide the moment a machine becomes eligible; no such bucket is proof that another attempt must remain suppressed. Potentially transient execution failures use a bounded one-hour retry delay. This can delay another execution attempt even if an external condition changes during that hour; an already adequate dedicated route is verified/committed before backoff. Removing only the deferral marker requests immediate reassessment without deleting the pending operation. Indeterminate capacity or geometry reads do not authorize partition changes and remain eligible for later reassessment.

The old route still has to satisfy the existing readable/observed-registration checks before suppression can be used. An adequate dedicated route makes an obsolete marker unnecessary. OS-fallback and an inadequate dedicated partition remain remediation conditions rather than healthy fast-path outcomes. An encrypted OS-fallback route is not accepted as functional.

A deferral marker is not the pending-deployment record below. The marker can expire or be cleared as its conditions change; an unresolved pending record and its verified source must survive DSI changes and normal workspace cleanup. Do not delete either recovery artifact merely to reset the retry history.

### Pending deployment record (v50 patch 5)

The trusted record is `%ProgramData%\OEM\WinRE-Manager\pending-deployment.json`. Its independently verified candidate is `%ProgramData%\OEM\WinRE-Manager\PendingDeployment\pending.wim`, under a protected SYSTEM/Administrators directory. A read handle held during deployment denies writers and deletion. The journal binds that fixed candidate path to its expected SHA256. Ordinary servicing-workspace cleanup cannot remove it. Staging requires the WIM size plus 32 MiB free on the OS volume; the subsequent shrink assessment measures free space after that copy. This is durable operation state, separate from `winre_state.json`, the ordinary servicing checkpoint and the backup catalogue.

The disposition is `Managed` or `Preserved`; it is not a new source ownership class. A managed candidate may be a newly serviced WIM or a positively owned current WIM copied unchanged for layout repair. A preserved candidate keeps its accepted bytes and foreign acceptance distinct from `CurrentImageHash`.

The schema version is `1`. Its recorded fields are:

| Group | Fields |
|---|---|
| Operation and disposition | `SchemaVersion`, `OperationId`, `Phase`, `Mode`, `ImageHandling`, `UpdatedUtc` |
| Accepted bytes | `CandidatePath`, `ExpectedSourceHash`, `DeployedWinREMetadata` |
| Completed-servicing cleanup context | `ServicingWorkDir` (canonical ordinary workspace; cleanup follows dedicated commit) |
| Deployment inputs and prior ownership | `DesiredStateId`, `DriverVersion`, `LocalInputsId`, `PriorManagedHash`, `LineageId` |
| OS identity | `OSDiskId`, `OSVolumeId`, `OSPartitionOffset` |
| Previous route evidence | `PreviousStatus`, `PreviousLocation`, `PreviousHash` |
| Observed target | `TargetPartitionGuid`, `TargetOffset`, `TargetSize` |
| Planned target | `PlannedTargetOffset`, `PlannedTargetSize` |
| Resize and deletion evidence | `ResizeTargetGuid`, `ResizeTargetOffset`, `ResizeTargetInitialSize`, `ResizeTargetPlannedSize`, `RecoveryInventoryJson` |

The previous-route hash belongs to that previous image; it is not assumed to equal the deployment candidate. `PreviousLocation` retains the registered folder as well as its volume spelling. Equivalent drive-letter, GLOBALROOT and volume-GUID spellings must identify both the same partition and the same normalized folder; sharing a partition alone does not establish the same route. The target observations are revalidated against current topology before use.

The recorded phases are:

| Phase | Meaning |
|---|---|
| `Prepared` | Independent source bytes and expected SHA256 are durably bound before mutation. |
| `MutationStarted` | The operation may have changed partition or recovery state; ordinary cleanup must retain its source. |
| `Copied` | The selected target WIM has been copied and checked against the expected hash. |
| `Registered` | The target registration has been recorded; observed state must still be checked. A verified last-resort OS-fallback retains this phase and the pending owner. |
| `Verified` | The final route/image checks have passed; state persistence and record retirement still control source release. |

An existing unreadable, untrusted, malformed or unsupported record is a refusal condition. It is not treated as a first run with no pending operation. A valid record is loaded before action dispatch or ordinary cleanup and resumed after hardware/topology gates, before normal network/DSI preparation. Resume re-reads current topology and hashes; recorded partition numbers are observations, not an authority to replay stale mutations.

The source hash remains bound throughout preparation, partition work and deployment. Any previous-route proof uses the previous image's own expected hash, which can differ from the candidate hash. Registration and byte integrity must be distinguished from an acceptable encrypted-OS-fallback recovery route. Restoring partition size alone cannot restore a deleted partition or its image.

Only a verified dedicated final route followed by durable state persistence/read-back permits the pending record to be retired and its candidate released. Last-resort OS-fallback is allowed only after actual dedicated creation failure, on fully decrypted C: with verified geometry and no acceptable route to retain. Its observed OS location, expected hash and saved fallback state are checked; it reports warning and retains the `Registered` journal, candidate and task for later dedicated repair. State persistence failure retains recovery material even if the new route is already correct; it does not cause a healthy route to be undone. Unresolved failures retain the temporary resume task. See the [validation matrix](testing.md#v50-patch-5-validation); real interruption and post-deletion failures remain VM release gates.

### Offline fallback trust (v44 patch 5)

When the manifest fetch fails after its retry budget (typically a DNS failure, a proxy block, or a total network outage), the script engages the offline fallback. Its read of the state file differs from the online case in one important way: **it trusts the state file's stored `DesiredStateId` directly, without recomputing it from cached inputs.**

Recomputing the DSI offline would require the OEM pack version, which is resolved from the OEM map — a different gist, on the same unavailable network. The first implementation of the offline fallback attempted this and was wrong: on a fully offline machine, the OEM map fetch also fails, so the recomputed DSI contained `OEMPACK=NONE` versus the state file's `OEMPACK=A10`, and the fast path did not fire. The corrected implementation treats the state file's stored `DesiredStateId` as ground truth.

The local safety checks are still fully enforced and do not depend on the manifest. Under v47, the fast-path conditions the offline path validates are the same as the online path: `$needInject` must be false, which requires the currently-registered WinRE's DISM servicing metadata (`Version` + `SPBuild`) to match the state file's `DeployedWinREMetadata` anchor, with no force-upgrade, no driver-version change, and no missing-anchor condition firing. The v46-and-earlier deployed-WIM-hash-vs-`CurrentImageHash` comparison no longer gates the fast path; the WIM hash remains in use for LKG validation, copy verification, deployment verification, and the pre-`/disable` race detector.

The full set of offline fast-path conditions under v48 patch 1:

- WinRE is `Enabled`.
- The state file's `DesiredStateId` matches the stored value (used directly; the DSI is not recomputed offline).
- The drift detector reports no change: the registered WinRE's servicing metadata matches the `DeployedWinREMetadata` anchor, and no force-upgrade, driver-version change, or missing-anchor condition applies.
- The state file's stored `LocalInputsId` matches the current locally-computable inputs, or the stored value is `$null` because the state file predates v48 patch 1 (in which case the check is skipped and a WARN is logged).
- Exactly one **type-coded**, adequately sized recovery partition on the OS disk holds the active image; OS-fallback is a remediation condition.

The v49 pipeline narrowing does not add a new offline-path condition. The source-ownership classification, the never-downgrade storage-driver check, and the pre-deployment storage-applicability gate all run inside the full-update path, which the offline fallback does not reach; the native-boot VHDX gate precedes offline fallback on the default Repair path. Backup and Restore dispatch earlier. A VHDX-backed guest is not refused merely because its storage is a virtual-disk file.

If all offline conditions pass, the fast path fires and the run exits `EXIT_WARNING` (code 2) because `$Script:offlineFallback = $true` is set. The state file may be rewritten by the fast path to clear stale counters, exactly as it would online; that rewrite preserves the stored `DesiredStateId` and the `DeployedWinREMetadata` anchor. If any condition does not hold, the run exits `EXIT_WARNING` before the full-update pipeline, having done nothing. If the state file does not exist at all, the run throws and exits `EXIT_FATAL` — a first deployment requires the live manifest to compute the initial `DesiredStateId`.

**The v46 → v47 transition on offline machines.** A v46-or-earlier state file lacks `DeployedWinREMetadata`. Its absence forces `$needInject = $true` regardless of network state — the drift detector has no anchor to compare against. On a machine whose first v47 run is offline, the offline guard then fires: the machine needs a full update, but the live manifest is required for that, so the run exits `EXIT_WARNING` without further work. **From the second v47 run onward**, the state file has the anchor written by the first successful online run, and the offline fast path can fire normally. The one-time cost of the v47 migration on offline machines is therefore: the first scheduled v47 run must happen while the machine can reach the driver manifest.

The analogous transition for v49 is different, because the offline fallback uses the state file's stored `DesiredStateId` directly rather than recomputing it. A state file written under v48 has `SCRIPT=48` and a stored `DesiredStateId` that records that value; the offline path compares that stored value against itself, so the DSI-match condition holds and the fast path can fire. The run exits `EXIT_WARNING` because `$Script:offlineFallback` is set, not because a full update was forced. The v49 pipeline gates (source-ownership classification, never-downgrade check, storage-applicability gate) are not exercised on that first offline run; they are exercised on the next run with network, which recomputes the DSI and forces the v49 full-update pass.

**The residual risk is substantially closed by `LocalInputsId` as of v48 patch 1.** A machine whose local hardware changed while offline — a CPU swap, or a motherboard replacement that changed `Manufacturer` / `Model` / `MachineType` — could under v44-v47 take the fast path with a stale `DesiredStateId`. The v48 patch 1 `LocalInputsId` field closes that: the offline path recomputes a hash over the three locally-observable deployment inputs (hardware identity, OS build, CPU vendor/generation) and defers with `EXIT_WARNING` when the stored and current values disagree. VMD presence is deliberately excluded because its detection depends on the manifest's `requiredDevices` patterns, which is precisely the input the offline fallback does not have; a VMD flip that occurs while the machine is offline therefore remains a documented residual of the offline fallback, not a case this field catches. See [CHANGELOG.md](../CHANGELOG.md) under v48 patch 1 for the shipped field, and [architecture.md](architecture.md) "LocalInputsId (v48 patch 1)" for the full mechanism.

### VMD-query-indeterminate deferral does not write state (v44 patch 6)

The VMD hardware presence check runs before the fast-path decision in the online path, and before any state-write point. When the check is indeterminate — a PnP enumeration error during the query — the run defers with `EXIT_WARNING` **before** any state is committed. No state file is written, no state file is deleted, and the existing state file's `LastUpdated` timestamp is not advanced.

The consequence is that a machine with a valid state file that takes the VMD-query-indeterminate deferral leaves that state file exactly as it was. The next run with a healthy PnP enumeration either accepts the state file (if its `DesiredStateId` matches) or treats it as stale (if the DSI inputs have changed while the machine was deferring). The deferral does not consume the enable-failure counter, does not advance `PendingReboot`, and does not affect `UsedOSFallback`.

### Write semantics

`Write-WinREState` is called from:

- The fast path when `PendingReboot`, `RepairAttempts`, `EnableFailureAttempts`, or a non-`"ok"` `LastEnableResult` was carried in from a previous run and needs clearing.
- The enable-only path, to record the registration result. On a terminal outcome — `"failed"` from a generic enable failure, `"failed"` from a target-preparation failure, or `"bitlocker"` — the counter is incremented and the state file is written with the corresponding `LastEnableResult`. On `"reboot"` the state file is written with `PendingReboot = $true` and the counter reset to 0. On `"ok"` the enable-only path exits `EXIT_SUCCESS` (or `EXIT_WARNING` if a non-fatal warning flag was set) **without writing the state file**; the counter is not reset by the enable-only path on this outcome. The next run's fast path clears a stale non-zero counter, so the counter is reset one run later.
- The pending-reboot path, to update the `PendingReboot` and `RepairAttempts` flags. A successful pending-reboot repair resets the enable-failure counter to 0; a reboot-required outcome keeps `RepairAttempts` and resets the enable-failure counter. **A target-preparation failure on the pending-reboot path does not increment `EnableFailureAttempts`** — the exclusion is deliberate, because immediately after a reboot the target partition's encryption state may be transiently indeterminate, and a preparation failure that would resolve on its own within one poll cycle must not be counted against the enable-failure threshold. The pending-reboot path is tracked exclusively by `RepairAttempts`.
- The full-update path, after Step 6 succeeds. If the run's `$enableResult` is `"failed"` or `"bitlocker"`, the counter is incremented; on any other outcome it resets to 0. The loop-breaker checks the incremented value on the next run.
- Source-preservation outcomes (`Foreign-With-Drivers` or never-downgrade) record `ForeignSourceAcceptedHash` separately from ownership. In patch 5, preserving the bytes also evaluates the recovery layout and can enter unchanged-image deployment; it no longer implies an immediate exit before partition remediation.

The enable-failure counter is incremented on both terminal outcomes. The distinction between `"failed"` and `"bitlocker"` is preserved in the state file so the operator can see *why* the enable step is failing, but the counter treats them the same way — a machine that keeps failing on the BitLocker error is in the same kind of loop as a machine failing generically, and both need the same manual intervention.

The restore action (v49) does not call `Write-WinREState`. On successful completion it deletes the state file, the checkpoint file, and the partition deferral marker: the WIM on the active route has changed, and the recorded deployment identity is invalidated so the next repair run re-evaluates the machine from a clean slate. The state file's `DesiredStateId` value would be unchanged if it were left in place (the seven DSI inputs are unchanged), but the restore deliberately removes the state file so the next run does not trust a state that describes the pre-restore WIM. The backup action (v49) does not touch the state file; it writes a `backup.json` sidecar alongside its WIM copy, in the operator-supplied backup directory. The state file (`winre_state.json`) and the backup's sidecar (`backup.json`) are distinct files in distinct locations and serve different purposes: the state file records the deployment identity, and the backup's sidecar records the captured WIM's provenance for a future restore.

A separate branch on the restore action (v50 patch 3) takes a different path from the success case. When `Deploy-WimTransactional` returns `$false`, the branch captures the target WIM SHA256 from before the deploy attempt and again after the failure. When the two hashes are equal - the target is untouched, or the transactional rollback restored it and hash-verified it - the branch preserves the state file, checkpoint, and deferral marker, because those files still describe the target content. When the two hashes differ, or either hash is unavailable (`Get-LiveWimHash` returns `$null` for both absent and unreadable), the content of the target cannot be proven unchanged, and the branch invalidates the three markers so the next run does not trust stale state. The resume-task persist flag is set unconditionally in the invalidate branch, because `reagentc /enable` returning `ok` establishes only that reagentc reports Enabled, not that the target WIM bytes are intact.

Before writing, the function checks `$Script:GeometryRestoreFailed`. If that flag is set — meaning a post-shrink or post-delete failure left C: at a geometry the restore helper could not verify — the function **deletes** the state file (if it exists) and returns without writing.

The deletion is deliberate: a state file must not record successful convergence while geometry restoration is unverified. An existing matching deployment identity is not evidence that the resize target returned to its original size. Patch 5 also retains the independent candidate and pending record and reports this condition as fatal; the next Repair must reassess actual topology rather than assume that rerunning will restore the geometry.

The v46 patch 2 deletion-failure branch makes the flag's meaning more precise: the branch captures the `Restore-OSPartitionSize` result and the `Restore-PreviousWinRERoute` result separately and returns the distinct reason `recovery partition deletion failed; previous route restored but <resize-target label> geometry restore unverified` when only the route restored (the label is `OS partition (C:)` on the non-intervening path and `anchor partition (disk X part Y)` on the intervening-anchor path; v48 patch 1). The flag is set in that sub-case (by `Restore-OSPartitionSize`), the state file is deleted on write, and the operator sees an accurate reason string rather than a flattened "previous route restored".

If the deletion itself fails, the failure is logged as an error. Manual intervention is then required to force a retry.

### Idempotency via the state file

A matching deployment identity is necessary but not sufficient for the fast path. WinRE must report enabled, the applicable image currency/acceptance checks must pass, and exactly one type-coded OS-disk recovery partition must hold the active image and meet the existing reuse size and effective-free-space requirements. A label-only match is insufficient. An unresolved pending deployment takes precedence over ordinary idempotency.

`UsedOSFallback = true` records a constrained prior outcome; it does not exempt the next run from dedicated-layout reassessment. An accepted foreign hash authorizes preserving that image, not keeping an undersized partition or assigning manager ownership. Adequate preserved installations can report `PRESERVED-DEDICATED` without unnecessary partition work.

When only layout is wrong, the current verified image can take the copy-only repair path. A failed fast-path predicate therefore does not always require a WIM rebuild. Normal servicing still runs when image currency or deployment inputs require it.

The v47 metadata comparison remains the normal image-currency check; hashes still verify ownership, LKG, copying and deployment, and bind interrupted operations. A metadata-neutral Dynamic Update remains a named residual. During offline fallback, live layout and local-input checks still apply and a completed offline check reports warning because the manifest was unavailable.

### The loop-breaker

The enable-failure counter is checked near the top of the main flow, after the pending-reboot block and before the classifier runs:

```powershell
if ($state.EnableFailureAttempts -ge 3 -and $state.LastEnableResult -in @("failed","bitlocker") -and $WinREState.Status -ne "Enabled") {
    # log "manual intervention required", remove the checkpoint file, exit EXIT_FATAL
}
```

This fires when `reagentc /enable` has failed terminally on 3 or more consecutive runs and WinRE is still `Disabled`. The purpose is to prevent a machine from silently retrying `/enable` forever when no amount of retrying will resolve the underlying cause — Audit Mode (before the Audit Mode guard was added), a broken ReAgent registration, a Windows component problem, or a recovery partition that the Device Encryption service keeps re-claiming. The `LastEnableResult -in @("failed","bitlocker")` condition means the loop-breaker fires for both terminal outcomes; the counter is the same for both, and the recovery is the same: resolve the underlying cause, delete the state file, re-run.

The state file is left in place when the loop-breaker fires. The log message names the state file path and instructs the operator to delete it to reset the counter, once the underlying cause has been resolved.

Under `-DryRun` the loop-breaker logs `Would refuse to retry …` and continues, matching the pattern used by the Audit Mode guard.

## The checkpoint file

Path: `C:\ProgramData\OEM\Logs\winre_checkpoint.txt`.

Format: `Step|DesiredStateId|WorkDir|Flag|SourceHash`, one line, e.g. `4|a1b2c3...|D:\Temp\WinREWork|WIM_READY|17843AD7F91D14445CDF35CFBDF254CA895149B123E96CD2870C6EFCAD3FED8E`. The fifth field (`SourceHash`) was added in v47 patch 1 and is present only when the staged WIM was prepared from an on-disk source (the registered image or the hash-validated LKG). A checkpoint prepared from a GitHub cold-start has no on-disk source to bind and omits the field. Existing two-, three-, and four-field checkpoints remain readable; legacy four-field `WIM_READY` checkpoints are invalidated on first resume under v47 because they have no source identity to bind against. A legacy step-4 checkpoint without `WIM_READY` is treated conservatively and reruns injection.

### Purpose

The checkpoint file exists to make a partially-completed full-update run resumable. If a run completes step 2 and then the machine is rebooted or the task is killed, the next run can resume from step 3 instead of redoing step 2. This saves time on slow machines and on slow networks. The checkpoint records the selected workspace so a reboot does not send the next stage to a different volume. If that volume is absent or below the 3 GiB reserve, the script discards the incomplete workspace and restarts at step 1 on another eligible volume. A valid workspace with insufficient space and no alternative causes a deferral; it is not deleted.

Workspace selection runs only after the healthy fast path, enable-only path, and offline deferral. It considers fixed NTFS volumes on allowlisted internal or virtual buses, excludes USB, SD/MMC, network, FireWire, Fibre Channel, unknown buses, recovery-typed and system partitions, and existing Temp/workspace reparse points, prefers a valid checkpoint workspace, and otherwise chooses the eligible non-OS volume with the most free space. With no valid checkpoint, it clears only canonical `X:\Temp\WinREWork` folders on eligible volumes before measuring space. On a fresh run, C: is used only when no eligible secondary fixed volume is available; a valid resume stays with its recorded volume while eligible. DISM, 7-Zip, and child-process temporary files are directed to the selected workspace. Servicing stages require a 3 GiB reserve. A verified `WIM_READY` resume requires 200 MiB because it no longer needs mount, download, injection, or export scratch. Both are admission thresholds, not hard upper bounds on workload size.

### Steps

| Step | Meaning |
|---|---|
| 0 | No checkpoint. Start at step 1. |
| 1 | Step 1 (WorkDir wipe) complete. Resume at step 2. |
| 2 | Step 2 (base WIM) complete. Resume at step 3. |
| 3 | Step 3 (mount/inject) complete. Resume at step 4. |
| 4 | Step 4 (optimize) complete and `WIM_READY` recorded. Resume at step 5. |
| 6 | Full-update path complete. The checkpoint is about to be deleted. |

The ordinary servicing checkpoint does not replay partial partition-and-deployment work. Patch 5 uses the separate pending-operation journal and protected candidate for that recovery. Resume validates the source and current topology and makes a fresh assessment; it does not replay a stored partition number or promise to restore deleted partitions. Interrupted replacement remains a machine-test requirement.

### Guards on resume

After `Get-Checkpoint`, the main flow applies two guards:

```powershell
if ($step -ge 4 -and -not (Test-Path "$WorkDir\winre_optimized.wim")) {
    $step = if (Test-Path "$WorkDir\base.wim") { 3 } else { 1 }
} elseif ($step -ge 2 -and $step -lt 4 -and -not (Test-Path "$WorkDir\base.wim")) {
    $step = 1
}
```

If `base.wim` is missing before Step 4, reset to step 1. A Step 4 checkpoint with `WIM_READY` may omit `base.wim`, because it is deleted after a verified optimized export. If the optimized WIM is missing, resume from Step 3 when a base image remains, otherwise restart at Step 1.

`WIM_READY` distinguishes a newly verified export from legacy step-4 checkpoints that may have been advanced by older failed-injection behavior. A valid `WIM_READY` checkpoint with an existing optimized WIM skips re-injection and re-export. The flag is crash-resume evidence, not part of the deployment identity.

### The v47 source-hash binding

The v47 checkpoint binds to the source-content hash that produced the staged WIM. Both Step 3 and Step 4 checkpoints record this binding: a Step 3 checkpoint carries the source hash of the base WIM that entered servicing, and a Step 4 checkpoint carries the same hash for the exported `winre_optimized.wim`. The validator calls `Select-BaseWinRESource` (the same helper Step 2 uses) and requires `$selectionNow.SourceHash -eq $cp.SourceHash`. This makes the two call sites share decision rules by construction, so drift between Step 2 and the validator is structurally impossible.

The binding exists because the v47 drift detector cannot detect a metadata-neutral source change: Microsoft documents that a Dynamic Update may change a serviced WinRE image's contents without changing its `Version` or `SPBuild`. Without the binding, a staged WIM prepared from a source that had since been silently replaced could be deployed as though nothing had changed. The binding is the checkpoint layer's independent check against that specific residual.

The fifth field is written at both Step 3 and Step 4:

- **Normal Step 2 to Step 3 execution.** `$Script:StagedWimSourceHash` is set by source selection (either the registered WIM's hash or the LKG's hash) after the copy-integrity check on `base.wim`, and flows through to the Step 3 checkpoint write. A crash between Step 3 and Step 4 previously left a checkpoint with no source identity, and the resume validator (which gated on `$cp.Step -ge 4 -and $cp.WimReady`) did not fire at Step 3; the Step 3 write now binds it.
- **Resumed Step 3 to Step 4 execution.** Step 2 was skipped, so `$Script:StagedWimSourceHash` is `$null` at entry. When the validator validates the checkpoint, it restores `$Script:StagedWimSourceHash` from the checkpoint's recorded value, so a resumed Step 3 to Step 4 execution writes the correct Step 4 checkpoint. If the validator did not run (a checkpoint written by an older build whose recorded value was not restored), the script recovers the hash from `base.wim` at Step 4 by matching its live SHA256 against the registered WIM hash and the hash-validated LKG. If `base.wim` matches neither, the source identity is intentionally left `$null` (a GitHub cold-start or an unknown on-disk source) and the checkpoint's fifth field is omitted. The next resume will invalidate such a checkpoint conservatively.

The validation runs once, after `Get-Checkpoint`, before the step guards. The gate is `$cp.Valid -and $cp.Step -ge 3`. When the gate passes and `$cp.SourceHash` is absent, the checkpoint is a legacy v47 patch 1 Step 3 checkpoint or a GitHub cold-start, and it is invalidated. When the gate passes and `$cp.SourceHash` is present, the validator calls `Select-BaseWinRESource` with the live inputs; if no local source is available, or its hash differs from `$cp.SourceHash`, the checkpoint is invalidated. On match, `$Script:StagedWimSourceHash` is restored from `$cp.SourceHash`.

`$ActiveLocationHash` does not participate directly in the comparison. `Select-BaseWinRESource` requires `$ActiveLocationWimPresent` before treating a WIM as the registered source, so a loose fallback-discovery file cannot validate a checkpoint against a source the selection rules would not choose. This closes the same class of gap that the prior `$candidateHashes` array left open, where a staged candidate whose source was no longer what the current selection would prefer could still be accepted.

An invalidated checkpoint is removed and `$cp` is re-read (returning a fresh `Step = 0`). The subsequent step guards then run against the invalidated state, and the run restarts from Step 1 as if there were no checkpoint.

**Legacy Step 3 checkpoints.** A Step 3 checkpoint written by a v47 patch 1 build carries no source hash. The validator's `$cp.Valid -and $cp.Step -ge 3` gate fires on it, sees `$cp.SourceHash` is absent, and invalidates it, forcing a clean rebuild from Step 2 against the current source. This is the correct convergence for a machine whose checkpoint lineage cannot be proven under the patch 2 rules.

**v49 does not change the checkpoint format or the source-hash binding.** The v49 source-ownership classification is a downstream decision that runs after source selection; it does not change what the checkpoint binds to. A checkpoint staged under a v49 run records the same source hash it would have recorded under v48 — the hash of the WIM the source-selection chain chose — and a resume under v49 evaluates the same `Select-BaseWinRESource` result.

### The v43 patch 4 migration guard

A separate guard runs after `$needInject` has been fully determined:

```powershell
if ($step -ge 4 -and $needInject) {
    if ($cp.WimReady -and (Test-Path "$WorkDir\winre_optimized.wim")) {
        Write-Log "Checkpoint step $step confirms a completed image export; resuming with the optimized WIM"
    } else {
        Write-Log "Checkpoint step $step lacks the current WIM_READY marker while a rebuild is required - resetting to step 2 to retry injection" -Level WARN
        $step = 2
    }
}
```

This handles the case where a **prior** run failed injection and left a checkpoint at step ≥ 4 with a valid (but stale) state file. Without the guard, the new run would skip step 3 (`$step -le 3` is false for `$step >= 4`), initialize a fresh `$Script:ImageInjectionComplete = $true`, deploy the un-injected WIM, and commit state for it.

The placement matters: the guard runs after `$needInject` is decided, so it catches both the "no state file" case and the "valid-but-stale state file" case. An earlier placement (immediately after the state read) would only catch the former.

The `WIM_READY` carve-out is deliberate. A step ≥ 4 checkpoint **with** the `WIM_READY` flag and an existing `winre_optimized.wim` is a valid, resumable checkpoint even when `$needInject` is true: the rebuild that `$needInject` implies has already been completed at the image level, and the remaining work is the same partition-and-deploy sequence the checkpoint was protecting. Resetting to step 2 in that case would discard a valid optimized WIM and re-serialize the whole image for no reason. Only a step ≥ 4 checkpoint **without** the `WIM_READY` flag — a legacy checkpoint from a pre-v45 run, or a run whose export did not verify — is treated as untrustworthy and reset.

**Ordering with the v47 source-hash binding.** The source-hash binding check described in "The v47 source-hash binding" runs before this migration guard. When it invalidates a checkpoint, the checkpoint file has already been removed and the fresh `Get-Checkpoint` call returns `Step = 0`; the migration guard's `$step -ge 4` condition is then false, and the guard is not reached. The two guards address different failure shapes and do not overlap.

### Checkpoint advance gating (v43 patch 4)

The three checkpoint writes at steps 3, 4, and 6 are now conditional on `$Script:ImageInjectionComplete`:

```powershell
if ($Script:ImageInjectionComplete) {
    Set-Checkpoint -CheckpointFile $CheckpointFile -Step N -DesiredStateId $DesiredStateId
} else {
    Write-Log "Checkpoint NOT advanced to step N - image injection did not complete; next run will retry step 3" -Level WARN
}
```

On a healthy run the gate is a pass-through. When injection failed, the checkpoint stays at 2 and the next run re-enters step 3 and retries.

This closes an interaction that was invisible to either mechanism in isolation: the checkpoint's job is "resume an interrupted attempt at the same target"; the state file's job is "record whether that target was actually reached." An unconditional checkpoint advance let a run's checkpoint say "past step 3" while its state file correctly said "not done," with no code path checking both at once. The gate aligns the two.

### Checkpoint cleanup

The checkpoint file is deleted:

- After the fast path completes.
- After the enable-only path completes (any outcome).
- After the pending-reboot path completes.
- After the full-update path reaches step 6.

The checkpoint file is **preserved** when:

- A deferral marker is honored and the deferred route is functional — the staged workspace and checkpoint are preserved alongside each other, because the deferred route is still functional and the staged image remains available for the eventual successful run.

If a run is interrupted between `Set-Checkpoint -Step 6` and `Remove-ItemIfExist $CheckpointFile`, the checkpoint file persists. The migration guard handles this on the next run.

### VMD-query-indeterminate deferral removes the checkpoint (v44 patch 6)

When the VMD hardware presence check is indeterminate, the run removes the checkpoint file before exiting `EXIT_WARNING`. This is deliberate: the deferral is a stop before any work is committed, and a stale checkpoint from an interrupted previous run would otherwise cause the next run to resume from a step that no longer reflects reality. Removing the checkpoint forces the next run to start from step 0, re-evaluate the VMD presence check, and proceed cleanly if the enumeration is now healthy.

**The v47 pre-`/disable` race-detector abort rewrites the checkpoint to Step 2 rather than removing it, and removes `base.wim` and any stale `winre_optimized.wim`**, for the same reason: the staged work is tied to a source that has drifted, and resuming from a checkpoint bound to that source would defeat the abort's purpose. Two deferrals remove the checkpoint file entirely: the VMD-query-indeterminate deferral and the offline-fallback deferral (which fires when the manifest fetch fails and the state file indicates a full update is needed). Every other deferral path either preserves the checkpoint (the pre-shrink deferral marker path preserves it alongside the staged workspace) or leaves it intact by never having written one. The `active WinRE location is empty` (v48 patch 1) and `active WinRE location could not be resolved` (v46 patch 2; placement moved by v48 patch 1) deferrals are the notable non-removing cases: the checkpoint is left on disk, and the next run honors it — resuming from Step 4 via the migration guard's `WIM_READY` carve-out — but re-enters the resolver guard, which fires again and defers again until the registration is repaired. Because v48 patch 1 moved the guard before `reagentc /disable`, WinRE is still `Enabled` at the deferral; the old recovery partition and its registration are preserved intact.

## The temporary resume task

Path: Windows Task Scheduler, task name `WinRE Manager - Resume`, root `\`, principal SYSTEM at the highest run level. The task is a scheduled task, not a file.

Live Repair and Restore attempt resume-task registration after the Audit Mode guard and before recovery mutation, when the invocation has a script path and staging can be verified. A registered task fires at boot+1m and as a one-shot at T+1h. It invokes the production script's default `-Action Repair`, which re-evaluates the machine state and either completes the interrupted run or takes the fast path. The task is removed in the `finally` block on any clean terminal exit (SUCCESS, WARNING, REBOOT_REQUIRED, or a FATAL exit taken inside `Main`) unless a persist signal fired. The staged copy at `C:\Recovery\OEM\Resume\WinRE.ps1` is removed at the same point, under the same persist guard, so their cleanup follows the same persist decision. Staging or cleanup can fail; inspect the task and staged-file verification rather than assuming either exists or was removed.

The task exists to cover the window that Rule 2 cannot fully guarantee: an interrupted run that has disabled WinRE, deleted the old recovery partition, or otherwise changed recovery state, before completing the deploy-and-enable sequence. Without the resume task, the machine would sit in that intermediate state until the next scheduled run or an operator intervention.

### Persist signals

The `finally` block reads the persist decision from the OR-merge of two independent signals:

- `$Script:ResumeTaskShouldPersist` — armed while inspecting an existing pending deployment and on deployment entry, so unresolved work retains its recovery hook. It is also set by the outer `catch`, the initial indeterminate-status guard, covered Restore failures, failed previous-route restoration and owned-mount cleanup failures. Restore retains the task when re-enable is not confirmed or the original bytes cannot be proven unchanged, and after registration or terminal enable failure following replacement. Verified deployment completion retires the journal and clears the signal. Historical assignment counts belong to their release entries; they are not the maintenance invariant.
- `[WinRECancelKeyProbe]::ShouldPersist` — set by a compiled `ConsoleCancelKeyPress` delegate. PowerShell runs `finally` blocks on Ctrl+C but bypasses `catch` blocks. The compiled delegate records this interruption for the cleanup decision. The `Add-Type` registration is best-effort: a registration failure logs a WARN and continues; the Ctrl+C signal is unavailable. Ctrl+C alone cannot retain the task in that case; other persist conditions still apply.

The invariant: **when the full-update operation has changed recovery state and the script cannot positively verify an acceptable final recovery route, the resume task must not be unregistered.** The task is a crash-recovery hook, not a retry-until-success mechanism; a clean exit that leaves the machine in a healthy state deletes the task and lets the state file govern the next scheduled run.

Two interruption classes leave the task registered without setting either signal, because the `finally` block never runs: a hard kill (e.g. `taskkill /F`) and a reboot mid-run (the OS terminates PowerShell).

### Staging lifecycle flags (v50 patch 4)

Two script-scope flags track staging safety during the resume-task setup:

- `$Script:ResumeStagingTaskInvalid` — set at entry to the staging touch-region, so any subsequent failure leaves an existing task pointing at a missing, partial, or untrusted script. Cleared only on a verified success return from `Initialize-ResumeScriptStaging`.
- `$Script:ResumeTaskCompromiseUnresolved` — set only when `$Script:ResumeStagingTaskInvalid` is set **and** removal of the existing task cannot be positively confirmed via a `Get-ScheduledTask` enumeration.

When `$Script:ResumeStagingTaskInvalid` is set after a staging failure, `Register-ResumeTask` attempts to remove any existing task and positively verify its absence. If the removal cannot be confirmed, `$Script:ResumeTaskCompromiseUnresolved` is set. `Main` exits `$EXIT_FATAL` when the compromise flag is set, **before** any destructive repair work — the reasoning is that continuing into destructive repair with an unverified SYSTEM task potentially registered against untrusted content is worse than refusing.

Registration failure on an otherwise-safe staging path preserves the verified staged copy so a prior task is not orphaned; the next run's safe cleanup handles any leftover staging directory that is not in use.

### What the task does not do

The task does not participate in the program lock directly. When the task fires, it invokes `WinRE.ps1 -Action Repair`, which acquires the program lock through the normal path and is serialized against any concurrent scheduled run.

The task is a per-run safety net, not machine state. It is not recorded in the state file, does not affect the fast-path decision, and does not change the `DesiredStateId`. Its presence after an exit can mean an interrupted run or an explicitly retained pending deployment. A completed healthy run normally removes it.

Under `$PSCommandPath`-less invocation — gist bootstrap via `Invoke-RestMethod | Invoke-Expression`, or paste-into-console — the guard in `Register-ResumeTask` logs at INFO and does not register the task. Those invocation modes have no `$PSCommandPath`, and a run initiated from such an invocation cannot be resumed by the task.

## Crash consistency

The state, checkpoint and deferral marker have independent lifecycles. Patch 5's pending record takes precedence over the ordinary combinations below: if it exists, validate/resume its protected candidate before interpreting these files as authority to clean scratch space or start another deployment.

| State file | Checkpoint file | Deferral marker | Meaning | Next run behaviour |
|---|---|---|---|---|
| Absent | Absent | Absent | Fresh machine, never run. | Full update from step 1. |
| Absent | Present, step < 3 | Absent | Interrupted run before injection. | Full update from step 1 or 2. |
| Absent | Present, step ≥ 4 | Absent | Interrupted failed-injection run, or `GeometryRestoreFailed` deleted the state file. | Migration guard resets `$step` to 2. Full update from step 2. |
| Present, matching | Absent | Absent | Inputs match a prior run; current route still needs assessment. | Fast path only for an Enabled, adequate dedicated layout; otherwise repair or reclassification. |
| Present, matching | Absent | Present, matching | Historical deferral without a pending owner. | Reassess layout/capacity; an adequate dedicated fast path clears the obsolete marker. |
| Present, matching | Present, step 3 (no WIM_READY) | Present, matching | Servicing checkpoint and historical deferral without a pending owner. | Validate the checkpoint; capacity is reassessed and execution backoff is checked when entering the pending deployment. |
| Present, matching | Present, step < 3 | Absent | Interrupted run that matched the state file. Unusual. | Full update from step 1 or 2. |
| Present, matching | Present, step ≥ 4 | Absent | Interrupted failed-injection run with a stale-but-valid state file. | Migration guard resets `$step` to 2 (because `$needInject` will be true). Full update from step 2. |
| Present, matching | Present, `WIM_READY` | Present, matching | Staged optimized WIM and historical deferral without a pending owner. | Validate source/checkpoint binding before reuse; a marker alone does not authorize skipping layout assessment. |
| Present, stale | Any | Any | The machine's `DesiredStateId` has changed. | Full update from step 1. The deferral marker is cleared on read. |

The existing writer uses a temporary file and replacement with retries. Patch 5 adds `-Durable` for state and journal writes: the temporary file is flushed with `FileStream.Flush(true)` before replacement. The independent candidate is also flushed before the journal can authorize mutation. Journal and final-state read-back check the expected values. This reduces partial-write exposure but does not establish a power-loss transaction across image, partition, registration and state changes. Existing unreadable or malformed pending records fail closed; real interruption and power-loss recovery require separate testing.

Under v47, a step-≥4 `WIM_READY` checkpoint whose fifth field is absent, or does not match any currently-available source (registered WIM or hash-validated LKG), is invalidated at resume before the step guards run. The checkpoint is removed and the run restarts from step 0 as if no checkpoint existed. This applies to legacy four-field checkpoints and to GitHub-cold-start checkpoints, both of which have no source identity to bind against. See "The v47 source-hash binding" in the checkpoint section.

## Why not a database?

The state file could in principle be a SQLite database, a binary blob, a Windows registry key, or a full configuration management system. The design uses a small JSON file on disk, written atomically, for four reasons:

1. **Atomic writes are easy to get right with a temp file and a rename.** `Write-FileAtomically` writes to a temp file and calls `Move-Item`. The helper centralizes replacement and retries; it does not provide one atomic transaction spanning the disk layout, WIM, reagentc registration and all state files. A database would bring its own atomicity guarantees, but also its own machinery: a database engine to load, a schema migration path, and a file-format compatibility contract to maintain. The current design's atomicity is one helper function.

2. **The state is small.** It is a few hundred bytes on disk. A database is overkill for this size of data, and the schema has not grown significantly since the v43 generation.

3. **The state file is human-readable on purpose.** When a field engineer opens `C:\Recovery\OEM\winre_state.json`, they should see something they understand: a `DesiredStateId`, a WIM hash, an enable result, a failure counter. A SQLite database or a binary blob would not serve that requirement, and a field engineer diagnosing a stuck machine is exactly the scenario the state file is designed to support. The [troubleshooting.md](troubleshooting.md) playbook depends on it.

4. **The ordinary state file has an operator reset path.** The loop-breaker recovery procedure tells the operator to delete the state file to reset the enable-failure counter. That reset applies to the ordinary state file after the cause is resolved; it does not authorize deleting an unresolved pending-deployment record or its candidate. A database would add ceremony to that reset without adding safety.

The trade-off is that the script does not defend against an operator manually editing the state file. That is not a scenario the design needs to support; if you edit the state file, you own the consequences.

**A separate durable-settings artifact (v50 patch 1; extended v50 patch 3).** The manager also maintains a machine-wide settings file at `C:\ProgramData\OEM\WinRE-Manager\manager.json`. It is not part of the deployment identity, is not read by `Read-WinREState` or written by `Write-WinREState`, and does not participate in the fast-path decision. It holds the backup-root catalogue read by `Cleanup-Backups.ps1`. The v50 patch 1 form owner-gated both read and write on the containing directory and its immediate parent (SYSTEM or Administrators, fail-closed on ambiguity). The v50 patch 3 form extends this to a full DACL check via `Test-PathTrustedForSystem`: the ACL owner is SYSTEM or Administrators, no Allow ACE grants a modify-capable right to a principal outside SYSTEM, Administrators, or TrustedInstaller, and the config file itself is checked in addition to its containing directory and that directory's parent. The modify-capable mask differs by object class: on a directory it is `Delete | DeleteSubdirectoriesAndFiles | TakeOwnership | ChangePermissions`; on a file it adds `WriteData | AppendData`. The file-level check closes a pre-creation attack that a directory-level check alone would not: a non-admin who pre-created `manager.json` inside a SYSTEM-owned directory would pass a directory-only check, but the file-level check refuses it because the planted file is owned by the attacker, not SYSTEM. See [architecture.md](architecture.md) under "The eight state-carrying artifacts" for the full description, [SECURITY.md](../SECURITY.md) under "Manager config trust gate" for the security posture, and [deployment.md](deployment.md) for the fleet-operator view.

### What the program lock does not replace

The v44 patch 4 program lock at `C:\ProgramData\OEM\Logs\WinREManager.lock` is sometimes confused with persistence. It is not. The lock and the state file serve different purposes:

- **The program lock** enforces single-instance exclusion. It has no content. It is a `FileShare.None` handle that the Windows kernel refuses to grant twice; the handle is released on process exit and the file is left in place. It carries no information between runs.
- **The state file** records the deployment's identity and outcome. It persists across runs, it is read at startup, and it is what the fast path validates against.

The lock does not replace the state file, and the state file does not replace the lock. A machine that runs the script twice in a row has the same state file and the same lock file throughout; the lock is acquired, the fast path runs, the lock is released. The lock's only job is to prevent two concurrent instances from racing on the selected image workspace, the log directory, and the partition operations the script performs.

**Deleting the lock file has no effect.** The lock is the open handle, not the file's existence. A second instance that opens the same path with `FileShare.None` will be refused by the kernel regardless of whether the file was present before. The file's presence on disk between runs is inert.

**Deleting the state file is a legitimate reset operation.** The loop-breaker recovery procedure explicitly says to do it. Do not confuse the two.

For the design reasoning behind the file lock (kernel enforcement, DACL avoidance, automatic release on process termination, why a file handle rather than a named mutex), see [architecture.md](architecture.md).

## Related documents

- [architecture.md](architecture.md) — the pipeline and how the state fits into it, plus the program lock's design reasoning and the v49 pre-deployment gates that the recipe refinement narrows.
- [recovery-partition.md](recovery-partition.md) — what the `GeometryRestoreFailed` flag protects against and how the deferral marker participates in the shrink-first pipeline.
- [driver-injection.md](driver-injection.md) — the v49 source-ownership classification, never-downgrade storage-driver check, and pre-deployment storage-applicability gate; the recipe refinements that the v49 `ScriptVersion` bump converges the fleet onto.
- [exit-codes.md](exit-codes.md) — the exit code each state leads to.
- [troubleshooting.md](troubleshooting.md) — the operator-facing playbook for each failure mode, including the v49 gate refusals and the resume-task states.
- [testing.md](testing.md) — the harness's read-only mirror of the state file (Option S), including the v28 storage-controller enumeration that surfaces the applicability gate's inputs.
