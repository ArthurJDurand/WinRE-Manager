<#
.SYNOPSIS
    Self-Healing Windows Recovery Environment (WinRE) Manager - Production

.NOTES
    Version : 43

    v43 patch 5 (same ScriptVersion, no DesiredStateId change):
    1. BitLocker state checks now consider VolumeStatus, not just
       ProtectionStatus. On Windows 11 24H2+ with Device Encryption, a
       volume can be actively encrypting (VolumeStatus=EncryptionInProgress)
       while ProtectionStatus reads Off. In that state, Suspend-BitLockerForWinRE
       previously logged "already Off - no suspension needed" and returned
       $true, and Test-BitLockerProtected previously returned $false
       (confirmed unprotected). Both were wrong: Device Encryption's
       auto-encryption service is active, new partitions created on the
       same disk get auto-encrypted before their recovery type GUID can be
       applied, and reagentc /enable refuses with "Windows RE cannot be
       enabled on a volume with BitLocker Drive Encryption enabled." The
       two functions now treat a ProtectionStatus=Off volume as
       confirmed-safe only when VolumeStatus is one of:
         - FullyDecrypted (never encrypted, or decryption finished);
         - FullyEncrypted (volume encrypted but protection Off - the
           normal suspended state, e.g. after Suspend-BitLocker or a
           Windows Update suspension that has not yet been lifted);
         - empty (some builds report empty for volumes BitLocker has
           never touched).
       When ProtectionStatus is Off, any other VolumeStatus -
       EncryptionInProgress, DecryptionInProgress, EncryptionPaused,
       DecryptionPaused - is the hazardous Device Encryption in-progress
       state, and the destructive partition paths refuse to run. When
       ProtectionStatus is On, the state is treated as protected and the
       function proceeds to suspend regardless of VolumeStatus, which is
       correct: protection being On is the factor that matters, and
       suspension moves the volume into the ProtectionStatus=Off branch
       where the hazardous-VolumeStatus rule then applies. Real case: Dell Latitude 3550, Intel Core Ultra 5
       125U, Windows 11 build 26200, Device Encryption mid-encryption at
       73.6%. The original recovery partition was deleted and could not
       be replaced across three consecutive runs, leaving the machine
       with no dedicated recovery partition and WinRE disabled.

       Follow-up (same patch, same day): the unsafe-VolumeStatus branch
       in Suspend-BitLockerForWinRE originally set $protectionState =
       $null and allowed the generic manage-bde -status fallback to run.
       That fallback parses "Protection Off" from the output - which is
       present on a mid-encryption volume, because ProtectionStatus
       really is Off; the encryption is in progress, not the protection -
       reclassified the state as $false (confirmed unprotected), and let
       the function return $true. That re-opened the exact fail-open path
       the patch was written to close. The branch now returns $false
       immediately, before the fallback can run. Test-BitLockerProtected
       was already correct: it returns $null (not $false) for the same
       condition. Identified by independent review of the patch; the
       fallback path is only reachable when Get-BitLockerVolume returns
       an object with ProtectionStatus=Off and an unsafe VolumeStatus,
       which is exactly the state this patch detects, so the fallback
       correction is required for the patch's stated guarantee to hold.

       Follow-up (same patch, further revision): three additional changes
       were required to close the failure completely.

       First, the confirmed-safe VolumeStatus whitelist in both
       Test-BitLockerProtected and Suspend-BitLockerForWinRE now also
       includes FullyEncrypted. The initial patch only whitelisted
       FullyDecrypted (plus empty). That rejected the standard post-
       Suspend-BitLocker state - ProtectionStatus=Off, VolumeStatus=
       FullyEncrypted - as if it were hazardous, which would refuse to
       run the destructive partition path on any machine whose BitLocker
       was already suspended. FullyEncrypted with protection Off is a
       safe, common state and must be treated as unprotected.

       Second, the BitLocker safety check in
       Ensure-AdequateRecoveryPartition now runs BEFORE reagentc
       /disable, not after. The original patch placed the check after
       the WinRE disable, so on a machine mid-Device-Encryption the
       function would disable WinRE, then refuse the destructive work,
       leaving the machine with WinRE disabled and no way to re-enable
       it until encryption completed - the exact damaged state the
       patch was written to prevent. Reordering means the guard fires
       while WinRE is still registered and functional, so a refusal
       leaves the machine unchanged rather than damaged.

       Third, the deployment step (Step 5) now performs the same
       BitLocker safety check before disabling WinRE. Even with the
       first two fixes, the main flow could reach Step 5 (via the
       OS-fallback path or an enable-only escalation) and disable WinRE
       before trying to enable it against a mid-encryption volume.
       reagentc /enable then refused, leaving the machine with WinRE
       disabled. Step 5 now refuses to disable WinRE unless BitLocker
       is confirmed safe, exits with EXIT_WARNING, and leaves the
       machine's WinRE state untouched for the next run after
       encryption stabilises.

       Fourth, Suspend-BitLockerForWinRE now evaluates the BitLocker
       safety check even under -DryRun. Previously the DryRun branch
       short-circuited before any BitLocker query, so a dry run of a
       mid-Device-Encryption machine returned $true from the guard,
       bypassed the refusal check in Ensure-AdequateRecoveryPartition,
       and logged "Would delete recovery partition N" lines while the
       real destructive path is exactly what must not run in that
       state. A field engineer pre-flighting with -DryRun would see a
       clean dry run and conclude the machine was safe. The DryRun
       branch now queries Get-BitLockerVolume and returns $false on the
       hazardous VolumeStatus values before proceeding to the
       "[DRY RUN] Would check and suspend BitLocker" log line. The
       check is read-only; no state-modifying call is made in DryRun.

       Fifth (v43 patch 5, further revision): FullyEncrypted with
       ProtectionStatus=Off is now treated as AMBIGUOUS, not safe.
       That state can be a legitimate suspension (by us, by Windows
       Update, or by an operator) OR a Device Encryption volume in
       the "Waiting for Activation" state - Device Encryption has
       fully encrypted the volume with a clear protector, but
       protection has not been armed because the recovery key has
       not been escrowed. Microsoft documents Waiting for Activation
       as a distinct state; the local two-field view (ProtectionStatus
       and VolumeStatus) cannot distinguish it from a suspension.
       Test-BitLockerProtected and Suspend-BitLockerForWinRE now
       return $null / $false (ambiguous) for FullyEncrypted+Off, so
       the destructive paths refuse and defer. Deferring rather than
       proceeding is the correct trade: an extra pipeline run later
       is cheaper than an unrepairable recovery partition.

       Ownership guard. The above change created a regression that
       would break the healthy path: after the script itself suspended
       BitLocker (ProtectionStatus=On -> Suspend-BitLocker ->
       ProtectionStatus=Off, VolumeStatus=FullyEncrypted), a later
       call to Suspend-BitLockerForWinRE in the same run would see
       the state it just created, classify it as ambiguous, and
       refuse - causing Step 5's pre-deploy gate to skip deployment
       on a machine we had already committed to modify. The function
       now short-circuits when $Script:BitLockerSuspended is $true:
       if THIS run suspended BitLocker, subsequent calls trust that
       ownership. The ambiguous-state classification applies only to
       states observed at the START of the run, not to states the
       script itself produced.

       Startup gate. A startup BitLocker gate runs immediately after
       Get-WinREState, before the pending-reboot block and before any
       state-modifying action. If the OS volume at startup is
       ProtectionStatus=Off with a VolumeStatus other than
       FullyDecrypted (including FullyEncrypted), the run defers with
       EXIT_WARNING before touching any partition or the WinRE
       registration.

       Further revision 2 (same patch, same ScriptVersion). Three
       changes to the startup gate.

       First, the gate now handles a null Get-BitLockerVolume return.
       Previously the entire gate block was skipped when the cmdlet
       returned null, so a machine whose BitLocker state could not be
       queried passed the gate silently. The gate now falls back to
       Test-BitLockerProtected, which itself falls back to manage-bde
       -status text parsing. A null result from that fallback causes
       the gate to defer. To avoid a false positive on machines where
       BitLocker is genuinely not present (Windows Home SKU, or the
       feature not installed), the gate checks for manage-bde.exe
       before treating a null return as unknown; when the tooling is
       absent the gate is a no-op.

       Second, the gate runs under -DryRun. Previously it was wrapped
       in if (-not $Script:DryRun), so a preflight of an
       idempotent-but-unsafe machine reported nothing. Under -DryRun
       the gate now performs the same read-only classification and
       logs "Would defer WinRE Manager: ..." when the state is unsafe.
       It does not exit; the DryRun continues. This makes a preflight
       report the state a live run would defer on, without modifying
       BitLocker, WinRE, partitions, or drive letters.

       Third, the gate no longer removes the checkpoint file on
       deferral. Deferring on BitLocker state does not invalidate any
       resumable step - steps 1-4 do not depend on BitLocker and the
       existing step guards handle resumption once the state is safe.
       Preserving the checkpoint lets the next run resume rather than
       re-download and re-inject from scratch.

       Further revision 3 (same patch, same ScriptVersion). The DryRun
       contract is now structural rather than per-step: no code path
       reachable under -DryRun modifies BitLocker, WinRE registration,
       partitions, drive letters, or the state file.

       Two leaks existed. First, Ensure-AdequateRecoveryPartition's
       reagentc /disable call was not guarded. A DryRun on a machine
       with no suitable recovery partition - the exact case in which
       the function is invoked - actually disabled WinRE. The
       per-step DryRun guards elsewhere in the function (the deletion
       loop's continue, the OS extend's -and -not $Script:DryRun, the
       final early return) were correct individually but did not cover
       the disable call.

       Second, Invoke-ReagentcEnable ran reagentc /enable
       unconditionally. The enable-only caller was guarded at the call
       site; the full-update post-deploy and final-verification callers
       sit after the Step 5 DryRun early-return, so they were never
       reached under DryRun; but the pending-reboot path called the
       function unguarded, so a DryRun on a machine whose state file
       recorded PendingReboot=true actually enabled WinRE.

       Fixes. In Ensure-AdequateRecoveryPartition, the DryRun early
       return is moved to just after the read-only pre-deletion
       inventory and before the first state-modifying action. It logs
       a comprehensive plan of what a real run would do (which
       partitions would be deleted, the extend, the shrink, the
       create, the format, the attributes, the drive-letter
       assignment). The reagentc /disable block now has an explicit
       DryRun branch that logs and skips. All previously scattered
       per-step DryRun guards are removed because the consolidated
       early return makes them unreachable - the choke point is now
       the only place that has to be maintained. In
       Invoke-ReagentcEnable, a DryRun branch is added after the
       BitLocker fail-closed check: an unsafe BitLocker state still
       returns "blunsafe" under DryRun, and a safe state logs the
       intent and returns "ok" without calling reagentc. The
       pending-reboot path's "ok" log line and the enable-only
       path's clean-exit log line are both conditioned on
       $Script:DryRun so neither claims success on a pass that
       attempted nothing.

       The result: the "dry runs modify nothing" guarantee is now
       enforced at a single structural choke point per state-modifying
       function, rather than at every call site. Adding new
       state-modifying code below the Ensure-AdequateRecoveryPartition
       choke point cannot violate the guarantee without first
       overriding the DryRun early return; adding new callers of
       Invoke-ReagentcEnable cannot violate it at all, because the
       guard is inside the function.

       Further revision 4 (same patch, same ScriptVersion). The v42
       OEM-pack resolution failure rule treated every supported-vendor
       run with no resolved pack as incomplete and refused to write a
       state file. That was correct for Dell and HP (single-pack maps
       resolved by OS family or a fixed key; a $null return can only
       mean the map failed to load - transient) and for a Lenovo map
       that failed to download. It was wrong for the common Lenovo case
       where the map loaded successfully and simply has no entry for
       this machine type: many Lenovo models have no published WinPE
       driver pack, and the absence is permanent, not transient.
       Marking such a run incomplete prevented the state file from
       ever being written, forcing the full-update path on every
       scheduled run forever, with EXIT_WARNING on every run.

       The fix distinguishes the two cases using information already
       present: $Script:LenovoWinPEMap is non-null when the map loaded
       successfully and $null when the map failed to download or when
       the machine-type resolution short-circuited before the fetch.
       For a Lenovo machine with a loaded map and no entry for its MT,
       the run is treated as legitimately complete with OEMPACK=NONE
       in the DesiredStateId; the state file is written and the fast
       path fires on subsequent runs. If Lenovo publishes a pack for
       that MT later, the DesiredStateId changes and the machine
       rebuilds automatically. Dell, HP, and Lenovo-map-download-
       failure runs keep the v42 behaviour: marked incomplete, retried.
       The "no entry" log line in Get-LenovoWinPEPack is demoted from
       WARN to INFO because the caller now decides the completion
       state; the operator sees a single INFO line explaining the
       situation, not a WARN that suggests action is needed.

       Fail-closed on suspension failure. Invoke-ReagentcEnable now
       returns "blunsafe" (a distinct result) when BitLocker on C:
       cannot be confirmed unprotected, instead of warning and
       continuing into reagentc /enable. The enable-only path aborts
       with EXIT_WARNING on "blunsafe" rather than falling through
       to the full-update path. The full-update post-deploy path and
       the pending-reboot path handle "blunsafe" the same way. Every
       path that would call reagentc /enable now requires that the
       BitLocker state be confirmed safe first.

       Stronger manage-bde fallback. When Get-BitLockerVolume is
       unavailable and the fallback parses manage-bde -status text,
       "Protection Off" alone is no longer sufficient. Only a
       confirmed "Conversion Status: Fully Decrypted" makes the
       fallback return confirmed-unprotected; anything else returns
       unknown, so the fail-closed policy holds even when the primary
       API is unavailable.

    2. New-Partition now sets the recovery type GUID (GPT) or type code
       (MBR) at partition creation, closing the window between New-Partition
       and Set-RecoveryPartitionAttributes during which the partition looked
       like a Basic Data partition and could be claimed by the Device
       Encryption service. Combined with change 1, this makes the destructive
       partition path safe to run on machines where BitLocker has ever been
       active. Machines where VolumeStatus is FullyDecrypted see no
       behaviour change.

    3. ScriptVersion is deliberately left at 43: this change does not
       modify the deployed WIM or force a DesiredStateId rebuild.

    v43 patch 4 (same ScriptVersion, no DesiredStateId change):
    1. The step 3, step 4, and step 6 checkpoint writes are now gated
       on $Script:ImageInjectionComplete. Previously all three wrote
       unconditionally, including on runs whose OEM or VMD injection
       had failed. On such a run the state-file write at the end was
       correctly skipped (ImageInjectionComplete was false), but the
       checkpoint file on disk still advanced. Because the cleanup
       that removes the checkpoint file runs at the very end of the
       pipeline and is not atomic with the checkpoint write, an
       interruption between the write and the cleanup leaves a
       checkpoint on disk. The next run accepts the checkpoint (same
       DesiredStateId, unchanged), the step guards skip step 3
       ($step -le 3 is false for $step >= 4), ImageInjectionComplete
       is $true again (fresh script state), and the run reaches the
       state-write gate with a valid hash - committing state for the
       un-injected WIM. The machine then takes the idempotent fast
       path on every subsequent run and the injection is never
       retried. Identified by independent review of the checkpoint /
       state-file interaction; not a field failure. The three
       checkpoint writes now read:

           if ($Script:ImageInjectionComplete) {
               Set-Checkpoint -CheckpointFile $CheckpointFile -Step N -DesiredStateId $DesiredStateId
           } else {
               Write-Log "Checkpoint NOT advanced to step N - image injection did not complete; next run will retry step 3" -Level WARN
           }

       On a successful run ImageInjectionComplete is $true and the
       checkpoint advances as before - the gate is behaviour-preserving
       on the healthy path. When injection fails, the checkpoint stays
       at 2 and the next run re-enters step 3 and retries. This aligns
       the checkpoint's "stage N completed" semantics with the
       state-write gate's "the deployment as specified succeeded"
       semantics across the interruption boundary, which the previous
       code did not.

    2. A migration guard resets $step to 2 when the checkpoint claims
       $step >= 4 and $needInject has been determined to be true. That
       combination means the checkpoint cannot be trusted: a high
       checkpoint is present while a rebuild is still required. Two
       situations produce it. First, an interrupted failed-injection
       run under v43 patch 3 or earlier - a run that advanced the
       checkpoint but did not commit new state - and it can occur even
       when a valid (pre-existing) state file with an old hash remains
       on disk, because the failed-injection branch skips the state
       write without deleting the prior state. Second, an interruption
       after a successful step-4 checkpoint but before the new state
       was committed - the injection succeeded, the optimized WIM
       exists, and the run was killed before the state write. The guard
       cannot distinguish these two cases using the checkpoint data
       alone, and the conservative response is the same for both: reset
       to step 2 and re-run the injection. In the second case this is a
       safe replay of work that had already succeeded, not a recovery
       from a defect; it costs one extra pipeline run of step 3 on the
       narrow interruption. That is preferable to trusting a checkpoint
       that might be bypassing required injection. Without the guard the
       machine would not self-heal: the step guards skip step 3 for
       $step >= 4, so the new run initializes a fresh
       $Script:ImageInjectionComplete = $true, deploys the un-injected
       WIM, and commits state for it, after which the fast path
       preserves the state indefinitely. Placement matters: the guard
       runs after $needInject has been fully determined (including the
       forced-rebuild paths driven by active-WIM hash mismatch, driver
       version change, forced OS upgrade, and no-valid-state), because
       an earlier placement that considered only the no-valid-state
       case would miss an interrupted failed-injection run whose prior
       state hash is still valid. The guard uses $step >= 4 rather
       than $step >= 3 because a checkpoint at 3 already runs step 3
       ($step -le 3 is true). As with the checkpoint gate, the guard
       is a one-time correction: once a machine has run through once
       with the guard in place, its checkpoint no longer carries the
       condition that triggers it.

    3. ScriptVersion is deliberately left at 43: this change does not
       modify the deployed WIM or force a DesiredStateId rebuild, and
       a version bump would force a full pipeline run on every healthy
       machine. The checkpoint gate takes effect on the next non-
       resumed invocation; the migration guard corrects already-
       affected machines on their next run.

    v43 patch 3 (same ScriptVersion, no DesiredStateId change):
    1. Orphan-partition deletion failure now sets GeometryRestoreFailed.
       Remove-OrphanPartition is called from seven post-shrink failure
       paths in Ensure-AdequateRecoveryPartition, all after C: has been
       shrunk by (bucketSizeMiB + 1) MiB. When the newly created
       partition cannot be removed (Remove-Partition fails and the
       diskpart override also fails), the function logged a warning and
       returned $false, but the caller discards the return value and the
       main flow proceeds to OS-fallback with C: still shrunken. The
       state file was then written with UsedOSFallback=$true, and on the
       next run the count=0 exemption (or the count=1 fast path when the
       orphan carries a recovery type code) accepted the state and the
       geometry was preserved indefinitely. Fix: the orphan-survives
       branch now sets both $Script:nonFatalWarning and
       $Script:GeometryRestoreFailed. Write-WinREState's existing gate
       on the second flag then refuses to persist the state file,
       forcing the next run to re-run the full-update path. This is the
       same class of problem the v43 patch 2 changes were designed to
       eliminate; this was the one remaining geometry-restore failure
       path that did not set the flag.

    2. The enable-only path now enforces the "no type-coded recovery
       partition on any non-OS disk" invariant. The enable-only path
       exits before Step 7, so a stray secondary-disk recovery partition
       that appeared between the last full run and this run survived
       indefinitely on a machine whose WinRE was simply re-enabled. The
       fast path already enforces the invariant via
       Remove-StrayRecoveryPartitions; the enable-only path now calls it
       before its success or reboot-required exit.

    3. The pending-reboot repair block now enforces the same invariant.
       Two exits in that block (repair succeeded; repair failed and a
       reboot is still required) also bypass Step 7. Both now call
       Remove-StrayRecoveryPartitions before their Write-WinREState /
       exit sequence. The repair-succeeded exit additionally checks
       $Script:nonFatalWarning before its EXIT_SUCCESS so a stray-cleanup
       failure or a BitLocker-suspension warning is not silently
       overridden by a success exit code. This matches the exit-code
       convention already used by the fast path and the enable-only
       path. The reboot-required exit does not need the same check:
       EXIT_REBOOT_REQUIRED has priority over EXIT_WARNING in this
       script's exit semantics, and the failed cleanup is recorded in
       the log and state file regardless.

    4. The v43 patch 2 changelog item 5 wording is corrected. The
       original text said the classifier and idempotency checks run
       "before the state comparison"; the state file is in fact read
       first, and the classifier logic then operates on the accepted
       state. The fixes still take effect without a DesiredStateId
       change - the state file comparison has nothing to do with whether
       the classifier fires - but the sentence now describes the actual
       ordering.

    ScriptVersion is deliberately left at 43: these changes do not
    modify the deployed WIM or force a DesiredStateId rebuild, so a
    version bump would force an unnecessary WIM rebuild on every healthy
    machine.

    v43 patch 2 (same ScriptVersion, no DesiredStateId change):
    1. Fast-path cleanup could delete the partition reagentc is
       registered to. The v43 patch added a call to
       Remove-StrayRecoveryPartitions on the idempotent fast path.
       That function deletes any type-coded recovery partition on a
       non-OS disk. If reagentc is registered to a recovery partition
       on a secondary disk AND the OS disk also carries exactly one
       recovery partition AND the state file matches, the classifier
       set $activeOnRecovery = $true (it only required the active
       partition to be a recovery partition, not to be on the OS
       disk), the fast path set $nothingToDo = $true, and the cleanup
       then deleted the very partition reagentc was pointing at. The
       run exited success with WinRE effectively broken. Fix:
       $activeOnRecovery now also requires the active partition to be
       on the OS disk. In the affected state the classifier returns
       $false for both branches, the fast path does not fire, and the
       full-update path deploys the WIM to the OS disk, re-registers
       reagentc, and only then lets Step 7 delete the stray
       secondary-disk partition. Identified by independent code
       review; the preconditions are producible by Windows updates,
       manual reagentc operations, or disk migrations that move the
       WinRE registration before moving the partition.

    2. ActiveLocationWimPresent could be set for an unreadable WIM.
       The v42 idempotency fix relies on this flag to force a rebuild
       when the reagentc-registered location has no usable image. The
       flag was set on Test-Path success alone. If the file existed
       but its hash could not be computed (corruption, ACL, lock), the
       flag was $true while $ActiveLocationHash remained $null and the
       fallback WIM was substituted. The v42 forced-rebuild check then
       did not fire and the fast path reported DEDICATED with an
       unusable WIM at the registered location. Fix: the flag is now
       set only after Get-LiveWimHash returns a non-null hash.

    3. Post-shrink rollback gap. The v42 Restore-OSPartitionSize
       helper was called on most post-shrink failure paths, but not on
       the final "-not $shrinkOK" branch after all three shrink
       attempts fail. Since Resize-Partition and
       Assert-PartitionSizeAfterResize are not atomic, a partial
       success (Resize succeeded, verification failed) could leave C:
       shrunken while the run proceeded to OS-fallback and persisted a
       state file that the v41 zero-partitions + UsedOSFallback
       exemption then preserves indefinitely. Fix: the final branch now
       calls Restore-OSPartitionSize before returning $null.
       Restore-OSPartitionSize itself now sets
       $Script:nonFatalWarning on any failure so the run's exit code
       reflects the geometry-restore problem, and also sets
       $Script:GeometryRestoreFailed. Write-WinREState checks that
       second flag and, when set, deletes the state file instead of
       writing it. The deletion is what actually closes the
       state-preservation problem described above: skipping the write
       would not be enough, because if the previous state file's
       DesiredStateId matched the current one, the next run's
       Read-WinREState would still accept it and the v41 exemption
       would still fire. Deleting the file forces the next run to
       treat the state as absent, set needInject = $true, and re-run
       the full-update path - which re-extends C: as part of the
       destructive attempt and repairs the geometry if the failure
       was transient.

    4. The count=0 OS-fallback idempotency exemption additionally
       requires $activeOnOSFallback. Without this, a machine whose
       state file records UsedOSFallback but whose reagentc
       registration actually points at a secondary-disk recovery
       partition would take the fast path, then have the fast-path
       cleanup delete that secondary partition. The state is
       inconsistent and rare but producible by Windows updates or
       manual reagentc operations. The new condition forces the
       full-update path in that case.

    5. ScriptVersion is deliberately left at 43. These fixes take
       effect without a DesiredStateId change because the classifier
       and idempotency checks run after the state file is read and can
       force the appropriate repair path for the specific broken
       condition, and each fix fires on the state it addresses
       (secondary-disk registration, unreadable registered WIM,
       geometry-restore failure) rather than requiring a rebuild on
       every machine. A version bump would force the full-update path
       on healthy machines - a full pipeline run that does not change
       partition layout - which is exactly the kind of unnecessary
       disturbance the deployment policy avoids. The v43 script
       version therefore remains the marker for this patch generation,
       and the changelog above documents the fixes.

    v43 patch (same ScriptVersion, no DesiredStateId change):
    1. Step 7's stray-partition cleanup is extracted into a function
       (Remove-StrayRecoveryPartitions) and is now also called from the
       idempotent fast path. Previously Step 7 ran only on the
       full-update path, so a type-coded recovery partition that
       appeared on a non-OS disk after the last full run (e.g. a
       USB-attached device carrying an old recovery partition) would
       survive indefinitely as long as the machine's WinRE state
       stayed idempotent. The invariant the script maintains is "no
       type-coded recovery partition on any non-OS disk"; the fast
       path now enforces it. The scan is read-only when no strays
       exist (the common case).
    2. The idempotent fast path now honours $Script:nonFatalWarning in
       its exit code, matching the exit-code logic at the end of the
       full-update path. Previously a cleanup failure on the fast path
       could be masked by a subsequent EXIT_SUCCESS.
    3. DryRun log messages preserve the original log level
       ("[DRYRUN-ERROR]" instead of "[DRYRUN]") so a dry-run audit can
       see which operations were expected to fail.
    ScriptVersion is deliberately left at 43: these changes do not
    modify the deployed WIM or force a DesiredStateId rebuild, and a
    version bump would force an unnecessary WIM rebuild on every
    healthy machine. The new behaviour takes effect on the next
    invocation. Note that the fast-path Step 7 cleanup CAN change the
    partition layout on a machine with a stray type-coded recovery
    partition on a non-OS disk; it does not touch the deployed WIM or
    the OS disk's own recovery partition.

    v43 changes vs v42:
    1. Fallback copy no longer deletes its own source. When WinRE was
       disabled and the deployment source was already the fallback file
       at C:\Recovery\WindowsRE\winre.wim, the fallback-update block
       would delete that file and then attempt to copy it to itself,
       failing and leaving no fallback WIM behind. The block is now
       skipped when SourceWim and the fallback target resolve to the
       same path. Real case: Windows 10 MBR VM, recovery partition
       deleted, WinRE disabled, WinRE.ps1 v42 was run and the source
       WIM was the OS-fallback image. The script deployed the WIM to
       the new recovery partition successfully but then destroyed the
       fallback image during the fallback-update block, and the run
       ended with "State file NOT updated - could not compute final
       WIM hash".
    2. Full update now forces a rebuild when no WIM can be found
       anywhere. If the state file matches (so $needInject would
       normally be $false) but neither the reagentc-registered
       location nor the fallback search produced a WIM, the script
       entered the full-update path with a $null source and died at
       "Could not determine WIM size". The check now forces
       $needInject = $true so step 2 obtains a fresh WIM from GitHub.
       Real case: the Windows 10 MBR VM after v42 hit v43 bug #1 - the
       state file existed, matched its DesiredStateId, and both WIM
       locations were empty. v43 forces the rebuild and the script
       recovers from GitHub instead of exiting fatal.
    3. Both fixes confirmed by re-running the MBR test sequence with
       v43. The fallback-source guard fired as intended on the run
       where the deployment source was C:\Recovery\WindowsRE\winre.wim
       (no fallback-copy block executed, no "Fallback copy failed"
       warning, state file written successfully). Idempotent follow-up
       runs returned DEDICATED on both the just-created partition and
       the OS-fallback path. The Windows 10 MBR VM now sits in a
       steady DEDICATED state with state file matching.
    4. $ScriptVersion bumped to 43. DesiredStateId changes, so v42
       machines rebuild once. The rebuild is a no-op on machines with
       a healthy dedicated recovery partition whose winre.wim is
       present at the reagentc-registered location.

    v42 changes vs v41:
    1. Post-shrink failure cleanup. Ensure-AdequateRecoveryPartition
       shrinks the OS partition before creating a new recovery partition,
       but several failure paths after the shrink (New-Partition failed,
       insufficient space at the calculated offset, no drive letter
       available, drive-letter assignment failed, BitLocker suspension
       failed during the encrypted-partition retry, recreated partition
       still encrypted) returned $null without restoring the OS
       partition. The OS stayed shrunk until the next full-update run,
       which - under the v41 zero-partitions + OS-fallback exemption -
       could be indefinitely deferred with the same DesiredStateId. A new
       helper Restore-OSPartitionSize re-queries SizeMax and re-extends
       the OS partition to it, using the same verification convention as
       the rest of the script (Assert-PartitionSizeAfterResize). Every
       post-shrink failure exit now either calls Remove-OrphanPartition
       (when a partition was created) or Restore-OSPartitionSize (when it
       was not), so no failure path leaves C: permanently shrunken.
       Remove-OrphanPartition now delegates its own re-extend step to
       Restore-OSPartitionSize and gains the same post-resize
       verification it previously lacked.
    2. Idempotency no longer accepts a fallback WIM as evidence that a
       dedicated WinRE location is healthy. Previously, if reagentc
       pointed at a recovery partition whose winre.wim was missing or
       unreadable, the fallback search found C:\Recovery\WindowsRE\winre.wim,
       substituted it as $ActiveLocationImage, and the idempotency check
       then compared the fallback hash against $storedHash and concluded
       the machine was healthy - logging "Operating mode: DEDICATED" and
       exiting success while the registered location had no usable image.
       A new $ActiveLocationWimPresent flag records whether the WIM was
       actually found at the reagentc-registered location, independent of
       the fallback search. If WinRE is registered on a recovery partition
       but the flag is false, $needInject is forced to $true so the
       full-update path repairs the registered location. The fallback WIM
       remains useful as a source for rebuild; it just no longer counts
       as evidence that the current state is healthy.
    3. Boot-disk lookups replaced with Get-OSDisk. Five call sites used
       Get-Disk | Where-Object { $_.BootFromDisk -eq $true } to identify
       the disk on which recovery-partition work happens. MSFT_Disk's
       BootFromDisk reports the disk the firmware booted from, which is
       the same disk as the OS disk on virtually all configurations but
       can differ on multi-boot or cloned systems whose boot files live
       on a different physical disk. Every one of the five call sites
       actually means "the disk where Windows is installed and where the
       recovery partition belongs," which is precisely what
       Get-OSPartition().DiskNumber identifies. A new Get-OSDisk helper
       returns Get-Disk -Number (Get-OSPartition).DiskNumber and replaces
       all five lookups. Variable names changed from $bootDisk to $osDisk
       at the same sites where the semantic meaning is now explicit.
    4. Step 7 secondary-disk deletion now requires a recovery partition
       type code. The non-OS-disk cleanup loop previously deleted any
       partition returned by Get-RecoveryPartitions, which classifies by
       label OR GPT recovery GUID OR MBR 0x27. On the OS disk, the label
       fallback is intentional and safe (it exists for OEM images with
       mistyped partitions, and the deployment environment guarantees
       that "Recovery"/"WINRE" labels are applied only by our own tooling).
       On a secondary disk, a data partition labelled "Recovery" - for
       example on an attached external drive during a manual run - would
       have been deleted. Step 7 now requires the partition's GptType or
       MbrType to match one of the documented recovery type codes before
       deletion; a label-only match on a secondary disk is logged and
       skipped. Get-RecoveryPartitions itself is unchanged: it remains
       the broad detector used on the OS disk, and the narrower trust
       policy is applied only at the Step 7 deletion site.
    5. dism /Export-Image exit code is now checked before checkpointing
       step 4. Previously the export was invoked with its output
       discarded and the checkpoint was written unconditionally. A
       native executable returning nonzero does not raise a PowerShell
       exception under $ErrorActionPreference = "Stop", so a failed
       export could leave a corrupt or missing winre_optimized.wim
       checkpointed as step 4 complete; a subsequent run with the same
       DesiredStateId would then skip the export and deploy the bad WIM.
       The export exit code is now checked, the output file's existence
       is confirmed, and the script exits fatal on either failure.
    6. reagentc /disable failure at Step 5 now aborts deployment. The
       deployment step previously logged a warning if /disable returned
       nonzero and continued into suspend-BitLocker, WIM deployment,
       setreimage, and enable. That was inconsistent with
       Ensure-AdequateRecoveryPartition, which treats a failed /disable
       as a hard stop. Step 5 now does the same: check exit code, sleep,
       re-query Get-WinREState, and abort fatal if WinRE is still
       Enabled. There is no good reason to deploy a new WIM while the
       old registration is still active.
    7. OEM map resolution failure now marks the run as incomplete for a
       supported vendor. Previously, if Get-OEMWinPEPack returned $null -
       which happens both for unsupported vendors and for supported
       vendors whose map fetch failed - the script carried on and could
       write a state file marking the run complete, with OEMPACK=NONE
       in the DesiredStateId. The next successful map lookup changes the
       DesiredStateId and triggers a rebuild, so the situation
       self-corrects on the next run, but the current run was still
       being recorded as complete despite an unavailable driver source.
       The main flow now checks whether the hardware's vendor is in the
       supported set and, if so, whether $OEMPackage resolved; failure
       sets $Script:ImageInjectionComplete = $false and
       $Script:nonFatalWarning = $true so state is not written as
       complete.
    8. Cleanup failures now affect the run's warning status. Step 7
       wrapped its Remove-Partition calls in a silently-discarding
       try/catch, so a stray recovery partition that could not be
       deleted was logged nowhere and had no effect on the exit code.
       Each deletion is now logged on success and sets
       $Script:nonFatalWarning = $true on failure, so the run reports
       EXIT_WARNING rather than EXIT_SUCCESS when cleanup was
       incomplete. Resume-BitLockerIfNeeded similarly sets
       $Script:nonFatalWarning = $true on failure; note that because it
       runs in the finally block after the exit code has been
       determined by the try block, this flag currently only documents
       intent - a Resume failure does not change the exit code. That is
       acceptable given the -RebootCount 1 suspension semantics: if
       Resume fails, BitLocker protection re-enables automatically on
       the next reboot, so the failure is cosmetic within the current
       session. The comment in Resume-BitLockerIfNeeded records this.
    9. $ScriptVersion bumped to 42. DesiredStateId changes, so v41
       machines rebuild once. The rebuild is a no-op on machines with
       a single adequately-sized dedicated recovery partition whose
       winre.wim is present and readable at the reagentc-registered
       location: Find-SuitableRecoveryPartition accepts the existing
       partition and the script exits DEDICATED without touching the
       disk.

    v41 changes vs v40:
    1. Remove-OrphanPartition now re-extends the OS partition to
       SizeMax after successfully deleting an orphan. The OS was
       extended to SizeMax before the orphan was created and then
       shrunk by (bucketSizeMiB + 1) MiB to make room; without this
       re-extend the OS stays shrunk for the remainder of the current
       run, and the freed space is only reclaimed on the next
       full-update run, which may be months away under the
       DesiredStateId-scoped retry policy. The re-extend leaves the
       disk in the same state the caller started with.
    2. The idempotent-run check now examines the count of recovery
       partitions on the boot disk. Previously a machine with two (or
       zero) recovery partitions passed the idempotent check as long as
       WinRE was enabled on one of them, which allowed stray partitions
       to accumulate indefinitely and could not recover from a state
       where no recovery partition existed at all. Now, if the count is
       anything other than exactly one, the script forces $needInject
       to $true so the full-update path runs; Find-SuitableRecoveryPartition
       returns $null on multiple partitions, and
       Ensure-AdequateRecoveryPartition then deletes all of them and
       creates one correctly sized replacement. Setting $needInject
       also ensures the current WIM is copied into WorkDir during step
       2 before any partition is deleted, keeping $SourceWim valid
       after the source partition disappears.
       The "count != 1" rule is exempted in exactly one case: when
       the count is 0 AND the state file records UsedOSFallback = $true
       for this DesiredStateId. That combination means a previous run
       already attempted dedicated recovery for this exact state, the
       shrink failed, and the script deliberately ended in OS-fallback.
       Without the exemption, the zero-count branch would force a full
       rebuild on every subsequent run with the same state, defeating
       the DesiredStateId-scoped retry policy and re-running the full
       destructive attempt (WIM rebuild, delete, extend, shrink, defrag,
       fail) on every run. The exemption preserves the idempotent
       OS-fallback outcome; a state change (script version bump,
       manifest update, hardware change) naturally re-arms the retry.
       The zero-count-with-UsedOSFallback = $false case (inconsistent
       state) still forces a rebuild, as does the multiple-partition
       case, as intended.
    3. Investigated and rejected two candidate additions from prior
       discussion:
       - A guard that would skip the destructive attempt when the OS
         partition is at SizeMin (S == M) and the reclaimable recovery
         space (R) is smaller than the required bucket (B). The v38
         ASUS field log disproves the premise: S == M and R < B were
         both true, and the shrink nevertheless succeeded after
         defrag, because SizeMin is not a hard floor. Any proof based
         on SizeMin can be wrong. Dropped.
       - A "free space on C:" pre-check. Rejected because free space
         does not predict shrinkability; SizeMin does, and the script
         already computes both SizeMin and Size for the safe/fatal
         determination. A separate free-space threshold would be
         redundant and potentially misleading.
       The existing DesiredStateId-scoped retry policy (retry on state
       change, do not retry with the same state) already provides the
       "try hard once, do not repeat pointlessly" behaviour that these
       two rejected candidates were trying to achieve. The count-check
       exemption added in change #2 above is what makes that policy
       actually hold in the zero-recovery-partition + OS-fallback
       case; without it, the count rule would have defeated the retry
       policy for that specific state combination.
    4. $ScriptVersion bumped to 41. DesiredStateId changes, so v40
       machines rebuild once. The rebuild is a no-op on machines with
       a single adequately-sized dedicated recovery partition:
       Find-SuitableRecoveryPartition accepts the existing partition
       and the script exits DEDICATED without touching the disk.

    v40 changes vs v39:
    1. Removed the dead Test-ImageContainsThirdPartyDrivers function. It
       was defined once and never called. Its logic is reimplemented
       inline in the driver-injection step, where the count (rather than
       a boolean) is used to compute the pre/post delta that drives the
       injection success gate. There is no call site where the boolean
       form would be more useful than the count, so wiring it up would
       replace a more informative value with a less informative one.
       Deleted.
    2. Removed the dead $Script:BitLockerVolume variable. It was
       initialized to $null and assigned inside
       Suspend-BitLockerForWinRE, but never read. The obvious intent was
       for Resume-BitLockerIfNeeded to use the tracked volume object,
       but every call to Suspend-BitLockerForWinRE passes either the
       default "C:" or an explicit "C:", so no resume path could ever
       need a different mount point. Wiring it up would add state
       tracking for a case that does not exist. Deleted the
       initialization and the assignment. The hardcoded "C:" in
       Resume-BitLockerIfNeeded is correct.
    3. New helper Remove-OrphanPartition, called from both Format-Volume
       failure paths (main creation and the BitLocker-encrypted retry).
       Rationale: if Format-Volume throws, the function previously
       returned $null with the freshly created partition still present.
       That partition has the default Basic Data GPT type, no filesystem
       label, and no filesystem, so Get-RecoveryPartitions cannot match
       it on the next run (its predicates are label, recovery type GUID,
       and MBR type 0x27). The orphan would therefore survive every
       subsequent run, silently bounding the OS partition's SizeMax at
       its start and making it impossible for the script to create a
       correctly sized replacement. The helper uses the same
       Remove-Partition-with-diskpart-override pattern as the main
       deletion loop, so behavior is consistent, and it logs a distinct
       warning if the cleanup itself fails (disk unavailable, partition
       locked, etc.). No order change to the format-then-attributes
       sequence; that sequence is v35-tested and reordering it would
       introduce untested risk for a rare failure case.
    4. $ScriptVersion bumped to 40. DesiredStateId changes, so v39
       machines rebuild once. The rebuild is a no-op on machines that
       already have a correctly-sized dedicated recovery partition
       (Find-SuitableRecoveryPartition accepts it and the script exits
       DEDICATED without touching the disk).

    v39 changes vs v38:
    1. OS-partition shrink now makes three attempts instead of two:
       attempt 1 immediate, attempt 2 after a 10-second sleep with a
       re-queried SizeMin, attempt 3 after defrag /x. The v38 field log
       showed attempt 1 failing with "Size Not Supported" and attempt 2
       with the same target succeeding after a 29-minute defrag, but did
       not establish whether the defrag caused the change or whether
       something time-based lowered SizeMin. The new attempt 2 settles
       that question on every run where attempt 1 fails: if the retry
       after a short sleep succeeds, the defrag is not needed and the
       30-minute cost is avoided. If the retry never succeeds in the
       field, the defrag is confirmed necessary and the sleep step can
       be removed. SizeMin is now logged before attempt 1, after the
       sleep, and after the defrag so the deltas are visible in the log.
    2. No timeout on defrag /x. It runs to completion on both SSD and
       HDD. Rationale: 30 minutes of free-space consolidation on a
       nearly-full volume is a one-time cost for a specific purpose
       (creating a dedicated recovery partition), not routine
       maintenance. A bounded timeout can be introduced in a future
       version once field data shows how long the operation actually
       takes on representative hardware. The v39 SizeMin logging is
       the instrumentation that will inform that decision.
    3. $ScriptVersion bumped to 39. DesiredStateId changes, so v38
       machines rebuild once. On a machine that already has a
       correctly-sized dedicated recovery partition, the rebuild is a
       no-op: Find-SuitableRecoveryPartition accepts the existing
       partition and the script exits DEDICATED without touching the
       disk.

    v38 changes vs v37:
    1. Ensure-AdequateRecoveryPartition no longer bails out before
       touching the disk when the capacity pre-check reports that the
       OS partition cannot shrink enough to leave room for a new
       dedicated recovery partition. The pre-check is now advisory:
       the function proceeds with delete-all-recovery-partitions,
       extend-OS, shrink-OS, create-new-partition. If the actual OS
       shrink fails, the main flow still falls back to OS-fallback.
       Rationale: dedicated recovery partition is the primary
       objective; the SizeMin returned by Get-PartitionSupportedSize
       is a conservative hint and may be pessimistic on volumes with
       movable files. Real case: ASUS 11th-gen, S=975374 MiB,
       M=975374 MiB, R=999 MiB, B=1100 MiB. v37 refused before any
       state change and fell straight to OS-fallback. v38 attempts
       the repartitioning first. If the shrink genuinely cannot
       succeed, the outcome is unchanged (OS-fallback, exit 2); if
       defrag /x frees enough space, the outcome is a dedicated
       recovery partition.

    v37 changes vs v36:
    1. Recovery partition free-space policy simplified. Removed
       MinWinREFreeSpaceMB (200), FreeSpaceToleranceMB (5), and the fixed
       PartitionSizesMiB bucket list (1000/1500/2000/2500). Replaced with:
       - Existing-partition acceptance: WIM + WinREFreeSpaceMiB (250).
       - New-partition sizing: WIM + 250 + NewPartitionFilesystemMiB (30),
         rounded UP to the next NewPartitionIncrementMiB (100), clamped
         to NewPartitionMinimumMiB (1000).
       The 250 MiB target matches Microsoft's current WinRE servicing
       guidance (KB5028997) and the OS's own pre-update WinRE check. The
       30 MiB is OUR implementation allowance for filesystem overhead on a
       freshly-formatted volume - it is a sizing prediction, not a
       Microsoft-required figure and not an acceptance tolerance.
       Microsoft's documentation confirms NTFS itself consumes space but
       does not specify an exact number. Rounding is always UP to avoid
       ever picking a size smaller than required.
       Real consequence: ASUS 11th-gen desktop with a 757 MiB WIM and an
       existing 999 MiB recovery partition has ~197 MiB free after WIM
       replacement, below the 250 MiB target. That machine will no longer
       satisfy the dedicated-partition path and will fall back to
       OS-fallback with exit 2. This is the honest outcome; the previous
       195 MiB exception (200 - 5 tolerance) was rejected as undocumented
       and inconsistent with servicing requirements.

    2. VMD driver injection gate now uses package-specific INF name
       cross-reference, matching the OEM injection gate introduced in
       v36. Previously the VMD gate used $postVmdThirdParty -eq 0 as the
       failure condition, but $preVmdThirdParty was captured after OEM
       injection, so on any machine where the OEM package added drivers
       the VMD gate could never fail even if the VMD package contributed
       nothing. Real impact: Intel 12th-15th gen machines with VMD
       hardware present and an OEM package that also injects drivers.
       New gate: success when VMD delta > 0 (new drivers added) OR VMD
       package INF basenames match image INF basenames (already present);
       failure only when neither.

    3. Removed dead $oemInjectionOk variable (set in three branches, never
       read). The OEM injection gate is driven by
       $Script:ImageInjectionComplete and $Script:nonFatalWarning, both
       unchanged.

    4. Corrected stale comment in Find-SuitableRecoveryPartition that
       still referenced the v36-era 195 MiB acceptance floor.

    v36 changes vs v35:
    1. Recovery partition free-space floor raised from 30 MiB to
       MinWinREFreeSpaceMB (200) minus FreeSpaceToleranceMB (5), i.e.
       195 MiB. Microsoft's general WinRE troubleshooting guidance calls
       for 200 MB free space; the previous 30 MiB was only a hard floor
       for NTFS metadata, not a real servicing threshold. The 5 MiB
       tolerance prevents the check from demanding a larger bucket for
       negligible shortfalls (e.g. 197 MiB computed free against a
       200 MiB nominal target). Both Find-SuitableRecoveryPartition and
       Ensure-AdequateRecoveryPartition now use the same 195 MiB floor.
       Real case: ASUS 11th-gen desktop, WIM 757 MiB, existing 999 MiB
       recovery partition -> ~197 MiB effective free after deploy.
       Passes at 195, fails at 200, and neither value warrants upsizing
       to the next 1500 MiB bucket.

    2. Bucket selection for new recovery partitions is now driven by the
       same 195 MiB target instead of the previous fixed 250 MiB buffer.
       For a 757 MiB WIM, the old logic required WIM + 250 = 1007 MiB
       and picked the 1500 MiB bucket. The new logic requires
       WIM + 195 = 952 MiB and picks the 1000 MiB bucket, saving 500 MiB
       of OS volume space with no servicing downside.

    3. Test-VolumeEncrypted now recognizes the manage-bde error
       "could not be opened by BitLocker" as confirmation that the
       volume is not BitLocker-managed, and returns $false (confirmed
       not encrypted) rather than $null (unknown). Real case: recovery
       partitions carrying the correct type GUID and GPT attributes
       (de94bba4... + 0x8000000000000001) are refused by BitLocker by
       design, and neither Get-BitLockerVolume nor manage-bde -status
       can produce a Conversion Status for them. Previously this meant
       every candidate logged "encryption state unknown - proceeding"
       on every run. Classification is now definitive and the warning
       line goes away.

    4. OEM injection success gate cross-references the extracted
       package's INF filenames against the mounted image's third-party
       driver OriginalFileName values and fails only when zero package
       INFs are present AND no third-party drivers were added this run.
       The previous gate (post-injection third-party count) could not
       distinguish "our package's drivers are present" from "unrelated
       third-party drivers happen to already be in the image". Real
       case: a base WIM carrying unrelated drivers would pass the
       previous gate even if the OEM package's INFs failed to inject.

    5. New constants MinWinREFreeSpaceMB (200) and FreeSpaceToleranceMB
       (5). $FreeSpaceBufferMB removed - both call sites now use the
       new floor expression.

    v35 changes vs v34:
    1. Recovery partition attributes are now set immediately after
       Format-Volume and BEFORE assigning a drive letter, in both the
       initial creation path and the delete-and-recreate retry path of
       Ensure-AdequateRecoveryPartition. Previously the recovery type GUID
       and 0x8000000000000001 GPT attributes were applied only after
       WinRE was enabled. Between New-Partition and attribute-setting the
       volume was a plain NTFS data partition with a drive letter - a
       candidate for Device Encryption / BitLocker auto-encryption on
       Windows 11 24H2+ hardware. Diagnostic confirmed a recovery-typed
       partition reports "The volume could not be opened by BitLocker"
       with no Win32_EncryptableVolume entry, while still accepting a
       temporary drive letter. Setting attributes first closes the window.
       The reactive fallback (Test-VolumeEncrypted after letter assignment,
       and reagentc /enable BitLocker error -> suspend + delete + recreate)
       still handles the case where encryption occurs despite the earlier
       attribute-setting.

    2. OEM injection logging now reports the truthful driver delta.
       Add-WindowsDriver's returned objects do not reliably expose an
       Operation property with values "Add" or "Installed" across DISM
       builds. On Windows 11 build 26100 the filter returns zero items
       even when injection succeeded, so the script logged
       "Add-WindowsDriver returned 0 added driver(s)" followed by
       "Drivers already present in image - OK" on every successful
       Lenovo run. Confirmed via standalone test: extraction produced
       14 INFs, base image had 0 third-party drivers before injection,
       14 after. The success gate was never affected (it uses the image
       inventory), so state was written correctly all along - only the
       log line was wrong. v35 now reports pre-injection count,
       post-injection count, and delta. No functional change, no
       DesiredStateId change - logging-only fix, deliberately shipped
       without a version bump to avoid forcing a rebuild on v35
       machines.

    v34 changes vs v33:
    1. Reverted the BitLocker fallback to manage-bde -status text parsing
       in Test-BitLockerProtected, Test-BitLockerSuspended, and
       Suspend-BitLockerForWinRE. v32 introduced -protectionaserrorlevel
       on the assumption the exit-code convention was cleaner and more
       portable than parsing output. It is not portable: on Windows 11
       build 26100 the flag either errors or returns an unexpected exit
       code depending on invocation, so the "unknown" branch was hit on
       every fallback. v29's text parsing was reliable and build-agnostic.
       Reverted to that, keeping the v32 tri-state return values.

    v33 changes vs v32:
    1. Find-SuitableRecoveryPartition no longer rejects candidates whose
       encryption state could not be determined. Only a confirmed $true
       (BitLocker-encrypted) causes the candidate to be skipped. Unknown
       state now proceeds with a warning. Real failure: ASUS desktop with
       11th Gen i5-11400, Win11 26200, existing 999 MiB recovery partition
       on disk 4 part 4. Both Get-BitLockerVolume and manage-bde returned
       no usable protection state for that partition, so v32 screened it
       as unknown and rejected it. The OS partition cannot be shrunk
       (S == M), so creation of a replacement was refused and the machine
       fell to OS-fallback. The pre-existing backstop (reagentc /enable
       BitLocker error -> suspend + delete + recreate) covers the case
       where the partition really is encrypted, making the fail-closed
       screening unnecessary. Fix: skip on confirmed encryption, proceed
       on unknown.

    v32 changes vs v31:
    1. BitLocker protection state is now genuinely three-valued across
       every helper. Test-BitLockerProtected, Test-BitLockerSuspended,
       Test-VolumeEncrypted, and Suspend-BitLockerForWinRE all return
       $true = protected/encrypted, $false = confirmed unprotected/
       decrypted, $null = unknown. Previously a null Get-BitLockerVolume
       return, or manage-bde output that matched neither On nor Off,
       collapsed to $false and let destructive operations proceed on an
       unverified protection state.

    2. Suspend-BitLockerForWinRE no longer falls through to "already Off,
       no suspension needed" when the manage-bde output is unparseable.
       It now uses manage-bde -status -protectionaserrorlevel (documented
       for script use: exit 0 = protected, 1 = unprotected, anything else
       = unknown) and refuses to proceed on an unknown state.

    3. Suspend-BitLockerForWinRE marks $Script:BitLockerSuspended = $true
       immediately after a successful Suspend-BitLocker call, before the
       verification polling loop. If verification times out, the finally
       block now attempts Resume-BitLocker even though confirmation was
       never obtained.

    4. Test-VolumeEncrypted recognizes all non-fully-decrypted conversion
       states as encrypted per the Win32_EncryptableVolume contract:
       FullyEncrypted, EncryptionInProgress, DecryptionInProgress,
       EncryptionPaused, DecryptionPaused. Previously only the first two
       were treated as encrypted.

    5. Test-RecoveryPartitionEncrypted now uses the same tri-state helper
       (Test-VolumeEncrypted) that the C: checks use. Previously it had no
       manage-bde fallback, so a null Get-BitLockerVolume caused candidate
       recovery partitions to be screened as "not encrypted."

    6. Callers of Test-BitLockerProtected (Ensure-AdequateRecoveryPartition,
       Invoke-ReagentcEnable, the final-verification block in main) now
       test "-eq $false" for confirmed-unprotected and treat $true or $null
       as "do not proceed with destructive work." The old "-not $X" test
       would have treated $null (unknown) as unprotected after the tri-state
       change.

    7. Invoke-OemPackDownload no longer treats the mere existence of a file
       as success when no integrity hash is supplied. HP packages carry
       neither SHA256 nor MD5 in the map. When no hash is available, the
       function now requires Invoke-WebRequest itself to have completed
       cleanly on that attempt. A partial file left by a throwing request
       is rejected. The log line is now "Download successful (no integrity
       hash supplied)" for the no-hash path; "hash verified" is only logged
       when a hash was actually verified.

    8. Removed dead $neededMiB and $bucketSizeMiB locals from
       Find-SuitableRecoveryPartition. Both were computed but never read.

    v31 changes vs v30:
    1. Relaxed the total-size pre-filter in Find-SuitableRecoveryPartition.
       v30 rejected any existing recovery partition whose total size was
       less than (WIM + FreeSpaceBuffer) MiB - 5 MiB, but the actual
       acceptance test (Test-RecoveryPartitionHasRoom) only requires
       (WIM + 30) MiB. Real failure: ASUS desktop with 11th Gen i5-11400,
       Win11 26200, OS partition at minimum size (S == M), existing
       999 MiB recovery partition containing a 757 MiB WIM. The pre-filter
       rejected the 999 MiB partition against a 1002 MiB threshold,
       triggered creation of a new partition, and the capacity pre-check
       correctly refused because the OS cannot shrink (S == M). Result:
       unnecessary OS-fallback on a machine with a working recovery
       partition. Fix: pre-filter now uses $requiredBytes, matching the
       real acceptance test.

    v30 changes vs v29:
    1. Removed duplicate BitLocker function definitions. v29 contained
       two copies of Test-BitLockerProtected and Test-VolumeEncrypted -
       the first (old, no manage-bde fallback) and the second (new with
       fallback). PowerShell executed the last definition so there was
       no runtime regression, but the dead first definitions were a
       maintenance hazard. The dangerous first definition returned
       $false silently when Get-BitLockerVolume returned null, which
       is the exact bug that caused the v28 HP failure.

    2. Enable-only path now handles "bitlocker" return from
       Invoke-ReagentcEnable. Previously the enable-only path handled
       "ok", "reboot", and "failed" - a "bitlocker" return fell
       through silently with no logging. Now it logs the escalation
       explicitly and sets nonFatalWarning before falling through to
       the full update path.

    3. Narrowed BitLocker error detection in Invoke-ReagentcEnable.
       Previously any reagentc output containing the substring
       "BitLocker" returned "bitlocker". Now the match is the specific
       documented error text "cannot be enabled on a volume with
       BitLocker" so benign log lines that merely mention BitLocker
       cannot trigger the recovery path.

    4. Offset recalculation after delete-and-recreate in
       Ensure-AdequateRecoveryPartition. When the newly created
       recovery partition was found to be BitLocker-encrypted and the
       function deleted it for a retry, the previous code reused the
       stale $newOffset computed before deletion. Disk geometry may
       have changed. The retry now recomputes $newOffset from the
       current OS partition end, matching the main path behavior.

    5. Fixed false-positive in Test-VolumeEncrypted fallback. The
       manage-bde -status fallback matched the substring "Percentage
       Encrypted", which appears as a field label even on freshly
       formatted, never-encrypted NTFS volumes (with value 0.0%). Now
       it matches Conversion Status values that specifically indicate
       an encrypted volume.

    v29 changes vs v28:
    1. BitLocker suspension logging and fallback. Suspend-BitLockerForWinRE
       now logs every branch it takes. If Get-BitLockerVolume returns null
       (which happens when the BitLocker module is not loaded or the
       cmdlet fails silently), the function falls back to manage-bde
       -status to determine protection state. Previously a null return
       from Get-BitLockerVolume caused the function to return $true
       silently, and the script proceeded to delete/recreate the recovery
       partition without suspending BitLocker. HP ProBook 445 G10
       confirmed: reagentc /enable then failed with "Windows RE cannot
       be enabled on a volume with BitLocker Drive Encryption enabled"
       because the newly created recovery partition was auto-encrypted
       by BitLocker. Fix: never return success without evidence.

    2. reagentc /enable BitLocker error now triggers partition recreation.
       When Invoke-ReagentcEnable receives a BitLocker-specific failure
       ("cannot be enabled on a volume with BitLocker Drive Encryption
       enabled"), the caller now suspends BitLocker, deletes the
       encrypted recovery partition, recreates it, and retries. This
       replaces the previous behavior of falling through to OS-fallback,
       which also failed because the OS volume is BitLocker-protected.

    3. Newly created recovery partition auto-encryption now triggers
       delete-and-retry instead of abort. Ensure-AdequateRecoveryPartition
       previously aborted when the newly created partition was found to
       be BitLocker-encrypted. It now deletes the encrypted partition,
       verifies BitLocker is suspended, recreates the partition, and
       verifies again. The old abort behavior guaranteed OS-fallback on
       any machine where BitLocker auto-encrypts new partitions.

    4. New helper Test-BitLockerSuspended uses manage-bde -status as a
       fallback when Get-BitLockerVolume is unavailable. Used by the
       suspend and verification paths.

    v28 changes vs v27:
    1. Alignment slack fix in Ensure-AdequateRecoveryPartition. The new
       partition offset is rounded UP to the next 1 MiB boundary
       ($newOffset = [Math]::Ceiling($osEnd / 1MB) * 1MB). Without slack,
       that rounding could consume part of the requested bucket and leave
       the tail slightly too short. Real failure: HP ProBook 445 14 inch
       G10 (AMD Ryzen 5 7530U, Win11 26200), where after shrinking the OS
       by 1500 MiB the tail had only 1499.34 MiB available for a 1500 MiB
       bucket. The script aborted with "Not enough space at offset
       510538022912 for 1572864000 bytes (available 1572167680)" and fell
       back to OS-fallback, where reagentc then refused to enable WinRE
       because the OS volume is BitLocker-protected. Fix: shrink by
       (bucketSizeMiB + 1) MiB instead of bucketSizeMiB. The extra 1 MiB
       covers the worst-case MiB alignment rounding and guarantees the
       aligned offset leaves at least bucketSizeMiB available at the tail.
       Machines that already have a suitable recovery partition never
       reach this code path.

    v27 changes vs v26:
    1. Download logic completely rewritten to handle the Invoke-WebRequest
       exception-on-success behavior. In v26, a download that completed
       successfully and passed SHA256 verification could still be marked as
       failed if Invoke-WebRequest threw an exception (connection reset,
       timeout, etc.) after the file was written. The new logic checks the
       file's existence and hash AFTER the download attempt, and only
       declares failure if the file is missing or corrupt. This was the
       root cause of the Lenovo "OEM download failed" logs.

    2. Extraction logic for Lenovo and HP corrected. v26 still used 7-Zip
       for Lenovo EXE packages, which is unreliable for self-extracting
       installers. v27 uses the vendor's own EXE with the correct switches:
       - Lenovo: <exe> /VERYSILENT /DIR="<path>" /SILENT /SUPPRESSMSGBOXES
       - HP:     <exe> /s /e /f "<path>"
       - Dell:   CAB, still extracted via 7-Zip (correct as before)

    3. Comprehensive download and extraction logging added:
       - Downloaded file size
       - Exact Invoke-WebRequest exception (if any)
       - Exact vendor extraction command line
       - Vendor extraction exit code and output
       - INF file count in the extraction directory
       - Add-WindowsDriver error output (first 5 lines)

    4. Header comments updated with all critical lessons learned.

    5. Version bumped to 27. The DesiredStateId must change because the
       OEM injection behavior changed functionally. A machine that ran v26
       and got "state not updated" will rebuild once under v27.

    v26 carried forward:
    - OEM pack extraction rewritten to use vendor-native extractors.
    - INF-file count logging.
    - Add-WindowsDriver result logging with -ErrorVariable.
    - Download filename preservation.
    - Logging noise fix for map entry counts.

    v25 carried forward:
    - Volume GUID classification bug fix.
    - Enable-only path uses Resolve-WinRELocationToPartition.
    - Pre-deletion inventory logging uses Resolve-WinRELocationToPartition.
    - Dead code removed.
    - ReAgent.xml + ReAgent_merged.xml deletion on stale registration.
    - RepairAttempts > 3 message no longer claims a reboot happened.
    - reagentc output logging with exit code + raw output + action line.
    - .old backup cleanup in fallback-copy rename path.
    - BitLocker suspension inside Invoke-ReagentcEnable.
    - Cosmetic drive-letter log message fixes.
    - RepairAttempts tracking.

    CRITICAL LESSONS LEARNED (do not regress):
    - Do NOT use 7-Zip as the primary extractor for Lenovo or HP EXEs.
    - Do NOT rename vendor downloads to a generic name before extraction.
    - Do NOT swallow Add-WindowsDriver errors.
    - Always count .inf files after extraction.
    - The state-write gate must not be relaxed.
    - Invoke-WebRequest can throw an exception even when the download
      completed successfully. Always verify the file after the download
      attempt, not only inside the try block.
    - The Lenovo SCCM Package for Windows PE 11 provides device drivers
      in .inf form. Some packages may extract successfully but contain
      no INF files. The INF count diagnostic is essential.
    - [PSCustomObject]@{} objects may not accept new properties via
      dot-assignment ($obj.NewProp = value). Assigning a property that
      was not declared in the initial @{} literal throws "cannot be
      found on this object". Use
      $obj | Add-Member -NotePropertyName X -NotePropertyValue Y -Force
      or declare the property up-front in the @{} literal. This exact
      bug broke v27's second release at the DownloadFileName assignment
      immediately after a successful download.
    - In double-quoted PowerShell strings, "$word:" is parsed as a scope
      or drive qualifier (like $env:PATH), not as a variable followed by
      a literal colon. Use "${word}:" or "$($expr):" whenever a literal
      colon must follow a variable reference. This exact bug broke v27's
      first release at the "Download attempt $retry of $MaxRetries: $Url"
      line and is silent in the log because the parser dies before any
      code runs.

    - BitLocker can and will auto-encrypt newly created recovery partitions
      on modern hardware with TPM + Secure Boot. reagentc /enable then
      fails with "Windows RE cannot be enabled on a volume with BitLocker
      Drive Encryption enabled." The script must suspend BitLocker BEFORE
      partition creation, and must detect the BitLocker-specific reagentc
      error and react by suspending, deleting, and recreating the
      partition. Never silently return $true from Suspend-BitLockerForWinRE
      when Get-BitLockerVolume returns null - that is the exact bug that
      broke v28 on HP ProBook 445 G10.
    - Windows 11 24H2+ enables Device Encryption by default on hardware
      meeting TPM 2.0 + Secure Boot requirements. This auto-encrypts
      newly created partitions, including recovery partitions. Suspending
      BitLocker on C: does NOT prevent this. reagentc /enable then fails
      with "Windows RE cannot be enabled on a volume with BitLocker Drive
      Encryption enabled." The delete-and-recreate retry in v29 works
      around this but does not address the root cause. A future fix may
      require calling manage-bde -off <letter>: on the new partition
      before formatting it.
    - Prefer build-agnostic manage-bde parsing to exit-code flags. The
      -protectionaserrorlevel sub-parameter of manage-bde -status has
      inconsistent behavior across Windows 11 builds (tested: errors on
      26100 with correct syntax, returns -1 in other invocation forms).
      Text-parsing "Protection On" / "Protection Off" from
      manage-bde -status works on every build that has manage-bde and is
      what v29 used. v32 replaced it with the flag and broke the fallback.
    - Add-WindowsDriver's returned objects do not reliably expose an
      Operation property with values "Add" or "Installed" across DISM
      builds. On Windows 11 build 26100 the filter
      `$result | Where-Object { $_.Operation -in @("Add","Installed") }`
      returns zero items even when injection succeeded. Do not use that
      count to determine success or to log the result. Instead, capture
      the third-party driver count in the mounted image before and after
      injection via Get-WindowsDriver, and report the delta. This is the
      same inventory the state-write gate already uses. Confirmed on
      Lenovo 21L1 (tp_mtl_pe11_202403.exe): extraction produced 14 INFs,
      pre-injection third-party count 0, post-injection 14, but the
      return-shape filter reported 0. Image was correctly injected;
      state was correctly written; only the log line was wrong.
    - Set recovery partition type GUID and GPT attributes BEFORE assigning
      a drive letter. A freshly-formatted NTFS partition with a normal
      data type and a drive letter is a candidate for Device Encryption /
      BitLocker auto-encryption on Windows 11 24H2+. The recovery type
      GUID (de94bba4-06d1-4d40-a16a-bfd50179d6ac) plus 0x8000000000000001
      (PLATFORM_REQUIRED + NO_DRIVE_LETTER) makes BitLocker refuse the
      volume ("could not be opened by BitLocker"). Applying those before
      the letter closes the auto-encryption window. Verified by diagnostic
      on ASUS 11th-gen hardware: recovery-typed partition accepted a
      temporary drive letter and reported no Win32_EncryptableVolume entry.
    - Recovery partition free-space policy: after replacing the WinRE WIM,
      the partition must have at least 250 MiB free. Same threshold
      Microsoft uses in its WinRE servicing guidance (KB5028997) and the
      OS's own pre-update WinRE check. Existing-partition acceptance uses
      WIM + WinREFreeSpaceMiB (250), measured as (SizeRemaining +
      existingWimSize) >= (WIM + 250) MiB. New-partition sizing uses
      WIM + 250 + NewPartitionFilesystemMiB (30), rounded UP to the next
      NewPartitionIncrementMiB (100), clamped to NewPartitionMinimumMiB
      (1000). The 30 MiB allowance covers NTFS metadata overhead on a
      freshly-formatted volume - it is a sizing prediction, not an
      acceptance tolerance. Do NOT re-introduce a tolerance (e.g. 195
      MiB) to accommodate hardware whose existing recovery partition
      cannot meet 250. A machine whose existing recovery partition is
      too small must instead be given a correctly sized NEW partition;
      OS-fallback with exit 2 is the outcome only when the new partition
      genuinely cannot be created (the OS shrink fails after the defrag
      retry in Ensure-AdequateRecoveryPartition). Real case: ASUS
      11th-gen with a 757 MiB WIM and a 999 MiB existing recovery
      partition has ~197 MiB free post-deployment and fails the 250 MiB
      acceptance; v38 deletes it and attempts to create a properly
      sized replacement before falling back.
    - manage-bde -status on a BitLocker-unmanaged volume emits
      "could not be opened by BitLocker". For a properly-typed recovery
      partition (GUID de94bba4-06d1-4d40-a16a-bfd50179d6ac, attributes
      0x8000000000000001) this is the expected output and is definitive
      proof the volume is not encrypted. Test-VolumeEncrypted recognizes
      it and returns $false (confirmed not encrypted), not $null
      (unknown). Do not reclassify it as unknown; doing so reintroduces
      the "encryption state unknown" warning that appears on every run
      on hardware where this is simply the normal state.
    - OEM and VMD injection success cannot be judged by provider count
      alone. A base image carrying unrelated third-party drivers would
      pass a count-based gate even if the package failed entirely. The
      reliable test is to cross-reference the extracted package's INF
      basenames against the mounted image's third-party driver
      OriginalFileName basenames: success when either new drivers were
      added (delta > 0) or package INFs match image INFs (already
      present); failure only when neither. Applies equally to the OEM
      package and to each VMD archive. The pre/post delta remains useful
      as secondary evidence. Historical note: v36 fixed this for the OEM
      package but left the VMD gate as $postVmdThirdParty -eq 0, which
      could never fail after an OEM injection that added unrelated
      drivers. v37 applies the same pattern to VMD.
    - The new recovery partition offset is rounded UP to the next 1 MiB
      boundary. When shrinking the OS to make room, add at least 1 MiB
      of slack beyond the bucket size or the rounding can leave the tail
      too short for the new partition. See v28 change #1 and the HP
      ProBook 445 G10 failure.
    - Self-referential file operations must be guarded. Any block that
      deletes a file and then writes to the same path (or copies
      another file onto it) must first check whether the source and
      destination resolve to the same file. The v42 fallback-update
      block in the main flow deleted C:\Recovery\WindowsRE\winre.wim
      and then tried to copy the deployment source onto that same
      path, destroying the source and leaving the fallback missing
      whenever the source was already the fallback image. v43 guards
      the block by comparing [System.IO.Path]::GetFullPath($SourceWim)
      with [System.IO.Path]::GetFullPath($fallbackTarget) and skipping
      when they match. Apply the same guard anywhere two code paths
      could converge on one file.

    All prior decisions preserved: BitLocker suspend-only; encrypted recovery
    partitions deleted and recreated; single state file at
    C:\Recovery\OEM\winre_state.json; letters removed before reagentc /enable;
    GPT recovery type GUID and 0x8000000000000001 attributes applied
    immediately after Format-Volume and BEFORE assigning a drive letter
    (v35, both creation and recreate paths); letters always removed at exit;
    DesiredStateId idempotency; dismount scoped to WorkDir; add-only letter
    tracking; fallback copy non-fatal on ACL denial; post-resize verification
    via Assert-PartitionSizeAfterResize.
#>

[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$EXIT_SUCCESS          = 0
$EXIT_REBOOT_REQUIRED  = 1
$EXIT_WARNING          = 2
$EXIT_FATAL            = 3

$ScriptVersion = 43

# =========================== CONFIG ===========================
$DriverManifestUrl = "https://gist.github.com/52250179/4d98029c7b39240cdb860ee3c78c3ca9/raw"
$BaseWinRERepoApi  = "https://api.github.com/repos/52250179/OriginalWindowsREImages/contents"
$7Zip              = "C:\Program Files\7-Zip\7z.exe"
$WorkDir           = "C:\Temp\WinREWork"
$LogDir            = "C:\ProgramData\OEM\Logs"
$StateFileName     = "winre_state.json"
$CheckpointFile    = "$LogDir\winre_checkpoint.txt"
$WinREFreeSpaceMiB         = 250
$NewPartitionFilesystemMiB = 30
$NewPartitionIncrementMiB  = 100
$NewPartitionMinimumMiB    = 1000
$LenovoWinPEMapUrl = "https://gist.github.com/52250179/8211b75a38444caa68b8cebd7529376c/raw"
$HPWinPEMapUrl     = "https://gist.github.com/52250179/07f9c3db08e5ef27daca1e7ff700af35/raw"
$DellWinPEMapUrl   = "https://gist.github.com/52250179/52058dde0701c749be627c9601c5c925/raw"

$GitHubHeaders = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36' }

# =========================== SCRIPT STATE ===========================
$Script:tempDriveLetters = [System.Collections.Generic.List[string]]::new()
$Script:DryRun = $DryRun
$Script:BitLockerSuspended = $false
$Script:rebootRequired = $false
$Script:nonFatalWarning = $false
$Script:ImageInjectionComplete = $true
$Script:UsedOSFallback = $false
$Script:GeometryRestoreFailed = $false
$Script:BitLockerGuardDeferred = $false
$Script:CachedHardware = $null
$Script:LenovoWinPEMap = $null
$Script:HPWinPEMap     = $null
$Script:DellWinPEMap   = $null

# =========================== LOGGING ===========================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Msg = "$Timestamp [$Level] $Message"
    if ($Script:DryRun) { $Msg = "$Timestamp [DRYRUN-$Level] $Message" }
    try { Add-Content -Path "$LogDir\WinRE-Manager.log" -Value $Msg -ErrorAction SilentlyContinue } catch { }
    Write-Host $Msg
}

function New-DirectoryIfNotExists {
    param([string]$Path)
    if ($Script:DryRun) { Write-Log "[DRY RUN] Would create: $Path"; return }
    if ($Path -and -not (Test-Path $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
}

function Remove-ItemIfExist {
    param([string]$Path, [switch]$Recurse)
    if ($Script:DryRun) { Write-Log "[DRY RUN] Would remove: $Path"; return }
    if ($Path -and (Test-Path $Path)) {
        if (Test-Path $Path -PathType Container) { Remove-Item $Path -Force -Recurse -ErrorAction SilentlyContinue }
        else { Remove-Item $Path -Force -ErrorAction SilentlyContinue }
        Write-Log "Removed: $Path"
    }
}

function Write-FileAtomically {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content, [int]$MaxRetries = 3)
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $tempFile = Join-Path $dir ("{0}.tmp_{1}" -f (Split-Path $Path -Leaf), [guid]::NewGuid().ToString('N').Substring(0,8))
    try { [System.IO.File]::WriteAllText($tempFile, $Content, [System.Text.UTF8Encoding]::new($false)) }
    catch { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue; throw "Atomic write temp failed: $_" }
    for ($retry = 0; $retry -lt $MaxRetries; $retry++) {
        try { Move-Item -Path $tempFile -Destination $Path -Force -ErrorAction Stop; return }
        catch {
            if ($retry -eq ($MaxRetries - 1)) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue; throw "Atomic write move failed: $_" }
            Start-Sleep -Seconds ([math]::Pow(2, $retry))
        }
    }
}

# =========================== CHECKPOINT ===========================
function Get-Checkpoint {
    param([Parameter(Mandatory)][string]$CheckpointFile, [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentDesiredStateId)
    if (-not (Test-Path $CheckpointFile)) { return @{ Step = 0; DesiredStateId = $null; Valid = $true } }
    try {
        $raw = (Get-Content $CheckpointFile -Raw).Trim()
        $parts = $raw -split '\|', 2
        $step = [int]$parts[0]
        $storedId = if ($parts.Count -gt 1) { $parts[1] } else { $null }
        if (-not $storedId) { return @{ Step = 0; DesiredStateId = $null; Valid = $false } }
        if ($storedId -ne $CurrentDesiredStateId) { return @{ Step = 0; DesiredStateId = $storedId; Valid = $false } }
        return @{ Step = $step; DesiredStateId = $storedId; Valid = $true }
    } catch { return @{ Step = 0; DesiredStateId = $null; Valid = $false } }
}

function Set-Checkpoint {
    param([Parameter(Mandatory)][string]$CheckpointFile, [Parameter(Mandatory)][int]$Step, [Parameter(Mandatory)][AllowEmptyString()][string]$DesiredStateId)
    if ($Script:DryRun) { Write-Log "[DRY RUN] Would set checkpoint $Step"; return }
    Write-FileAtomically -Path $CheckpointFile -Content "$Step|$DesiredStateId"
}

# =========================== WINRE STATE ===========================
function Get-WinREState {
    $info = & cmd /c "reagentc /info 2>&1"
    $statusLine = $info | Select-String -Pattern '(Enabled|Disabled)' | Select-Object -First 1
    $status = if ($statusLine) { $statusLine.Matches.Value } else { "Unknown" }
    $locationLine = $info | Select-String -Pattern '(\\\\\?\\GLOBALROOT\\device\\harddisk\d+\\partition\d+\\|\\\\\?\\Volume\{[a-fA-F0-9\-]+\}\\?)' | Select-Object -First 1
    $location = if ($locationLine) { $locationLine.Matches.Value.Trim() } else { $null }
    if (-not $location) {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinRE"
        $location = (Get-ItemProperty -Path $regPath -Name "WinRELocation" -ErrorAction SilentlyContinue).WinRELocation
    }
    return @{ Status = $status; Location = $location }
}

# Resolve a WinRE location string (GLOBALROOT or Volume GUID form) to a
# partition object. Returns $null if resolution fails.
function Resolve-WinRELocationToPartition {
    param([string]$Location)
    if (-not $Location) { return $null }
    if ($Location -match 'harddisk(\d+)\\partition(\d+)') {
        return Get-Partition -DiskNumber ([int]$Matches[1]) -PartitionNumber ([int]$Matches[2]) -ErrorAction SilentlyContinue
    }
    if ($Location -match 'Volume\{([a-fA-F0-9-]+)\}') {
        $vol = Get-Volume -UniqueId "\\?\Volume{$($Matches[1])}\" -ErrorAction SilentlyContinue
        if ($vol) { return Get-Partition -Volume $vol -ErrorAction SilentlyContinue }
    }
    return $null
}

function Get-OSPartition {
    $systemDrive = $env:SystemDrive
    if (-not $systemDrive) { return $null }
    $part = Get-Partition -DriveLetter $systemDrive.TrimEnd(':') -ErrorAction SilentlyContinue
    if ($part) { return $part }
    $vol = Get-Volume -DriveLetter $systemDrive.TrimEnd(':') -ErrorAction SilentlyContinue
    if ($vol) { $part = Get-Partition -Volume $vol -ErrorAction SilentlyContinue }
    return $part
}

# v42: return the disk that contains the running Windows installation.
# Every use of "the boot disk" in this script means "the disk where
# Windows lives and where the recovery partition belongs". That is the
# disk of the OS partition, not necessarily the disk the firmware booted
# from (MSFT_Disk.BootFromDisk). On virtually all configurations the two
# are identical, but on multi-boot or cloned systems whose boot files
# live on a different physical disk they can differ. Anchoring on the OS
# partition's DiskNumber removes the ambiguity.
function Get-OSDisk {
    $osPart = Get-OSPartition
    if (-not $osPart) { return $null }
    return Get-Disk -Number $osPart.DiskNumber -ErrorAction SilentlyContinue
}

function Get-AvailableDriveLetter {
    $letters = 90..68 | ForEach-Object { [char]$_ }
    $used = (Get-Volume).DriveLetter
    foreach ($l in $letters) { if ($l -notin $used) { return $l } }
    return $null
}

# =========================== DRIVE LETTER HANDLING ===========================
function Invoke-DriveLetterAssignment {
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][int]$PartitionNumber,
        [Parameter(Mandatory)][string]$PreferredLetter
    )
    $preferred = $PreferredLetter.TrimEnd(':').ToUpper()
    if ($Script:DryRun) { return $preferred }

    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add($preferred)
    foreach ($l in (90..68 | ForEach-Object { [char]$_ })) {
        $lc = $l.ToString().ToUpper()
        if ($lc -ne $preferred) { $candidates.Add($lc) }
    }

    foreach ($letterChar in $candidates) {
        $existing = Get-Volume -DriveLetter $letterChar -ErrorAction SilentlyContinue
        if ($existing) {
            $existingPart = Get-Partition -Volume $existing -ErrorAction SilentlyContinue
            if ($existingPart -and -not ($existingPart.DiskNumber -eq $DiskNumber -and $existingPart.PartitionNumber -eq $PartitionNumber)) {
                continue
            }
        }

        try {
            $part = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction Stop
            $part | Set-Partition -NewDriveLetter $letterChar -ErrorAction Stop
            for ($i = 0; $i -lt 5; $i++) { if (Test-Path "${letterChar}:\") { break }; Start-Sleep 1 }
            if (Test-Path "${letterChar}:\") {
                if ($letterChar -ne $preferred) { Write-Log "Assigned ${letterChar}: (preferred ${preferred}: was unavailable)" -Level WARN }
                return $letterChar
            }
        } catch { }

        try {
            $part = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction Stop
            $part | Add-PartitionAccessPath -AccessPath "${letterChar}:" -ErrorAction Stop
            for ($i = 0; $i -lt 5; $i++) { if (Test-Path "${letterChar}:\") { break }; Start-Sleep 1 }
            if (Test-Path "${letterChar}:\") {
                if ($letterChar -ne $preferred) { Write-Log "Assigned ${letterChar}: (preferred ${preferred}: was unavailable)" -Level WARN }
                return $letterChar
            }
        } catch { }

        try {
            $script = "select disk $DiskNumber`nselect partition $PartitionNumber`nassign letter=$letterChar"
            $script | diskpart | Out-Null
            for ($i = 0; $i -lt 5; $i++) { if (Test-Path "${letterChar}:\") { break }; Start-Sleep 1 }
            if (Test-Path "${letterChar}:\") {
                if ($letterChar -ne $preferred) { Write-Log "Assigned ${letterChar}: (preferred ${preferred}: was unavailable)" -Level WARN }
                return $letterChar
            }
        } catch { }

        Write-Log "All methods failed for ${letterChar}: - trying another letter" -Level WARN
        try { & cmd /c "mountvol ${letterChar}: /d 2>&1" | Out-Null } catch { }
    }

    Write-Log "Exhausted all candidate letters for disk $DiskNumber part $PartitionNumber" -Level ERROR
    return $null
}

function Invoke-DriveLetterRemoval {
    param([Parameter(Mandatory)][string]$Letter)
    $letterChar = $Letter.TrimEnd(':')
    if ($Script:DryRun) { return $true }
    try {
        & cmd /c "mountvol ${letterChar}: /d 2>&1" | Out-Null
        if (-not (Test-Path "${letterChar}:\")) { return $true }
    } catch { Write-Log "mountvol /d failed for ${letterChar}: - $_" -Level WARN }
    try {
        $part = Get-Partition -DriveLetter $letterChar -ErrorAction Stop
        $part | Remove-PartitionAccessPath -AccessPath "${letterChar}:\" -ErrorAction Stop
        if (-not (Test-Path "${letterChar}:\")) { return $true }
    } catch { Write-Log "Remove-PartitionAccessPath failed for ${letterChar}: - $_" -Level WARN }
    try {
        $script = "select volume $letterChar`nremove letter=$letterChar"
        $script | diskpart | Out-Null
        if (-not (Test-Path "${letterChar}:\")) { return $true }
    } catch { Write-Log "diskpart remove failed for ${letterChar}: - $_" -Level WARN }
    return $false
}

# =========================== ENSURE RECOVERY PARTITION ACCESS ===========================
function Ensure-RecoveryPartitionAccess {
    param([string]$TargetDir)
    if (-not $TargetDir) { return $null }

    if ($TargetDir -match '^\\\\\?\\GLOBALROOT\\device\\harddisk(\d+)\\partition(\d+)(\\(.*))?$') {
        $diskNum = [int]$Matches[1]; $partNum = [int]$Matches[2]
        $subPath = if ($Matches[4]) { $Matches[4] } else { '' }
        $part = Get-Partition -DiskNumber $diskNum -PartitionNumber $partNum -ErrorAction SilentlyContinue
        if (-not $part) { return $TargetDir }
        if ($part.DriveLetter) {
            $path = "$($part.DriveLetter):\"; if ($subPath) { $path = Join-Path $path $subPath }
            return $path
        }
        if ($part.IsBoot -or $part.IsSystem) { return $TargetDir }
        $letter = Get-AvailableDriveLetter
        if ($letter) {
            $assignedLetter = Invoke-DriveLetterAssignment -DiskNumber $diskNum -PartitionNumber $partNum -PreferredLetter $letter
            if ($assignedLetter) {
                Write-Log "Assigned temporary drive letter ${assignedLetter}: (disk $diskNum, part $partNum)"
                $Script:tempDriveLetters.Add($assignedLetter)
                $path = "${assignedLetter}:\"; if ($subPath) { $path = Join-Path $path $subPath }
                return $path
            }
        }
        return $TargetDir
    }

    if ($TargetDir -match '^\\\\\?\\Volume\{([a-fA-F0-9-]+)\}\\?(.*)') {
        $guid = $Matches[1]; $subPath = $Matches[2]
        $vol = Get-Volume -UniqueId "\\?\Volume{$guid}\" -ErrorAction SilentlyContinue
        if (-not $vol) { return $TargetDir }
        if ($vol.DriveLetter) {
            $path = "$($vol.DriveLetter):\"; if ($subPath) { $path = Join-Path $path $subPath }
            return $path
        }
        $part = Get-Partition -Volume $vol -ErrorAction SilentlyContinue
        if ($part -and ($part.IsBoot -or $part.IsSystem)) { return $TargetDir }
        $letter = Get-AvailableDriveLetter
        if ($letter) {
            $assignedLetter = Invoke-DriveLetterAssignment -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -PreferredLetter $letter
            if ($assignedLetter) {
                Write-Log "Assigned temporary drive letter ${assignedLetter}: (volume {$guid})"
                $Script:tempDriveLetters.Add($assignedLetter)
                $path = "${assignedLetter}:\"; if ($subPath) { $path = Join-Path $path $subPath }
                return $path
            }
        }
        return $TargetDir
    }
    return $TargetDir
}

# =========================== BITLOCKER ===========================
function Test-BitLockerProtected {
    param([string]$MountPoint = "C:")
    # v32: three-state contract.
    #   $true  = confirmed protected
    #   $false = confirmed unprotected
    #   $null  = could not determine
    # The Win32_EncryptableVolume.ProtectionStatus contract defines
    # 0=Off, 1=On, 2=Unknown. Get-BitLockerVolume does not surface
    # Unknown, so we treat any non-On/non-Off value as unknown and fall
    # back to manage-bde -status -protectionaserrorlevel, which is
    # documented for script use (exit 0 = protected, 1 = unprotected,
    # anything else = unknown).
    $blv = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction SilentlyContinue
    if ($blv) {
        $status = $blv.ProtectionStatus
        $vs     = [string]$blv.VolumeStatus
        if ($status -eq 'On' -or $status -eq 'ProtectionOn' -or $status -eq 1) { return $true }
        if ($status -eq 'Off' -or $status -eq 'ProtectionOff' -or $status -eq 0) {
            # v43 patch 5 (revised): ProtectionStatus=Off is not sufficient
            # evidence that the volume is safe to perform destructive
            # partition operations on. On Windows 11 24H2+ with Device
            # Encryption, a volume can be actively encrypting
            # (VolumeStatus=EncryptionInProgress) while ProtectionStatus
            # reads Off. In that state, new partitions created on the same
            # disk are auto-encrypted by the Device Encryption service
            # before the recovery type GUID can be applied, and
            # reagentc /enable refuses with "Windows RE cannot be enabled
            # on a volume with BitLocker Drive Encryption enabled."
            #
            # The confirmed-safe VolumeStatus values are:
            #   - FullyDecrypted: never encrypted, or decryption finished.
            #   - FullyEncrypted: volume is fully encrypted but protection
            #     is Off (a normal suspended state, e.g. after
            #     Suspend-BitLocker or a Windows Update suspension that has
            #     not yet been lifted). Destructive partition work is safe.
            #   - empty VolumeStatus: some builds report empty for volumes
            #     BitLocker has never touched.
            # Any other VolumeStatus (EncryptionInProgress,
            # DecryptionInProgress, EncryptionPaused, DecryptionPaused) is
            # the hazardous Device Encryption in-progress state.
            # v43 patch 5 (further revision): FullyEncrypted with
            # ProtectionStatus=Off is now treated as AMBIGUOUS, not safe.
            # It can be a legitimate suspension (by us, by Windows Update,
            # or by an operator) OR a Device Encryption volume in the
            # "Waiting for Activation" state. We cannot distinguish the
            # two from these two properties alone. Only FullyDecrypted
            # (or an empty VolumeStatus) is confirmed-safe.
            if ($vs -eq 'FullyDecrypted' -or -not $vs) { return $false }
            return $null
        }
        return $null
    }
    # v34: text parsing fallback. The -protectionaserrorlevel flag is a
    # sub-parameter of -status but has been observed to misbehave or be
    # unavailable on some Windows 11 builds. Text parsing is build-
    # agnostic and reliable.
    #
    # v43 patch 5 (further revision): "Protection Off" alone is not
    # sufficient evidence of safety. Only return $false when the
    # Conversion Status is explicitly "Fully Decrypted"; otherwise
    # return $null (unknown) so callers refuse destructive work.
    try {
        $mbo = & manage-bde.exe -status $MountPoint 2>&1
        $mboJoined = ($mbo | Out-String)
        if ($mboJoined -match 'Protection On')  { return $true }
        if ($mboJoined -match 'Protection Off') {
            if ($mboJoined -match 'Conversion Status:\s*Fully Decrypted') { return $false }
            return $null
        }
        return $null
    } catch {
        return $null
    }
}

function Test-BitLockerSuspended {
    param([string]$MountPoint = "C:")
    # v32: three-state contract.
    #   $true  = confirmed suspended (protection Off)
    #   $false = confirmed not suspended (protection On)
    #   $null  = could not determine
    $blv = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction SilentlyContinue
    if ($blv) {
        $status = $blv.ProtectionStatus
        if ($status -eq 'Off' -or $status -eq 'ProtectionOff' -or $status -eq 0) { return $true }
        if ($status -eq 'On' -or $status -eq 'ProtectionOn' -or $status -eq 1) { return $false }
        return $null
    }
    # v34: text parsing fallback (see note above).
    try {
        $mbo = & manage-bde.exe -status $MountPoint 2>&1
        $mboJoined = ($mbo | Out-String)
        if ($mboJoined -match 'Protection Off') { return $true }
        if ($mboJoined -match 'Protection On')  { return $false }
        return $null
    } catch {
        return $null
    }
}

function Test-VolumeEncrypted {
    param([string]$MountPoint)
    # v32: three-state contract.
    #   $true  = encrypted or partially encrypted
    #   $false = confirmed fully decrypted
    #   $null  = could not determine
    # Per Win32_EncryptableVolume.GetConversionStatus, all of
    # FullyEncrypted, EncryptionInProgress, DecryptionInProgress,
    # EncryptionPaused, and DecryptionPaused represent a volume that is
    # not fully decrypted and must not be treated as clean.
    $blv = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction SilentlyContinue
    if ($blv) {
        $prot = $blv.ProtectionStatus
        if ($prot -eq 'On' -or $prot -eq 'ProtectionOn' -or $prot -eq 1) { return $true }
        $vs = [string]$blv.VolumeStatus
        switch ($vs) {
            'FullyDecrypted'       { return $false }
            'FullyEncrypted'       { return $true }
            'EncryptionInProgress' { return $true }
            'DecryptionInProgress' { return $true }
            'EncryptionPaused'     { return $true }
            'DecryptionPaused'     { return $true }
            default                { return $null }
        }
    }
    # Fallback: manage-bde -status text parsing.
    # NOTE: "Percentage Encrypted" appears as a field label even on a
    # freshly-formatted, never-encrypted NTFS volume (value 0.0%). Match
    # Conversion Status values specifically.
    try {
        $mbo = & manage-bde.exe -status $MountPoint 2>&1
        $mboJoined = ($mbo | Out-String)
        # v36: BitLocker refusal means the volume is not BitLocker-managed -
        # typical of a properly-typed recovery partition carrying
        # de94bba4-06d1-4d40-a16a-bfd50179d6ac and 0x8000000000000001.
        # This is a definitive classification, not an unknown state.
        if ($mboJoined -match 'could not be opened by BitLocker') {
            Write-Log "BitLocker does not manage volume ${MountPoint} (manage-bde: could not be opened by BitLocker) - treating as not encrypted"
            return $false
        }
        if ($mboJoined -match 'Conversion Status:\s*Fully Decrypted') { return $false }
        if ($mboJoined -match 'Conversion Status:\s*(Fully Encrypted|Used Space Only Encrypted|Encryption In Progress|Decryption In Progress|Encryption Paused|Decryption Paused)') { return $true }
        return $null
    } catch {
        return $null
    }
}

function Suspend-BitLockerForWinRE {
    param([string]$MountPoint = "C:")

    # v43 patch 5 (revised): the BitLocker state query runs even in DryRun
    # mode. Its purpose is to detect the Device Encryption in-progress
    # state, which is a property of the machine, not of the operation. A
    # dry run on a mid-encryption machine must report the hazard so the
    # field engineer does not run the real script and damage the machine.
    # The state queries are read-only; the DryRun branch below returns
    # before any state-modifying operation.
    if ($Script:DryRun) {
        $blvDry = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction SilentlyContinue
        if ($blvDry) {
            $dryProt = $blvDry.ProtectionStatus
            $dryVs   = [string]$blvDry.VolumeStatus
            if (($dryProt -eq 'Off' -or $dryProt -eq 'ProtectionOff' -or $dryProt -eq 0) -and
                $dryVs -and
                $dryVs -ne 'FullyDecrypted') {
                # v43 patch 5 (further revision): includes FullyEncrypted.
                # See the non-DryRun branch below for rationale.
                Write-Log "BitLocker on ${MountPoint}: ProtectionStatus=Off but VolumeStatus=$dryVs - the volume is encrypted, actively encrypting, or in an ambiguous state. Device Encryption will auto-encrypt new partitions on this disk and reagentc /enable will fail. Refusing to treat as unprotected." -Level ERROR
                return $false
            }
        }
        Write-Log "[DRY RUN] Would check and suspend BitLocker on $MountPoint"
        # v43 patch 5 (revised): do NOT set $Script:BitLockerSuspended here.
        # The flag means "this run suspended BitLocker and therefore owns
        # the resume". In DryRun the script never called Suspend-BitLocker,
        # so setting the flag would cause the finally block's
        # Resume-BitLockerIfNeeded to call Resume-BitLocker on a machine
        # the script never suspended - a real state modification on a
        # supposed-to-be read-only dry run, and on a machine whose BitLocker
        # was already suspended (ProtectionStatus=Off, VolumeStatus=
        # FullyEncrypted) it would silently turn protection back on.
        # The finally block will therefore skip the resume, which is
        # correct: the script did not suspend anything.
        return $true
    }

    # v43 patch 5 (further revision): if THIS run already suspended
    # BitLocker, subsequent calls trust that ownership. The state we
    # observe on a later call (ProtectionStatus=Off, VolumeStatus=
    # FullyEncrypted) is the one WE produced via Suspend-BitLocker, not
    # an ambiguous Waiting-for-Activation state. Without this guard,
    # Step 5's pre-deploy call would see the state we just created and
    # refuse to proceed, breaking the healthy path.
    if ($Script:BitLockerSuspended) {
        Write-Log "BitLocker on ${MountPoint} is already suspended by this run - no additional suspension needed"
        return $true
    }

    # Step 1: determine protection state. Prefer Get-BitLockerVolume for
    # the common case; fall back to manage-bde -status text parsing. The
    # -protectionaserrorlevel flag was tried in v32 and reverted in v34:
    # its behaviour is not consistent across Windows 11 builds (errors on
    # 26100 with correct syntax, returns unexpected values in other
    # invocation forms). Text parsing "Protection On" / "Protection Off"
    # works on every build that has manage-bde.
    $protectionState  = $null   # $true/$false/$null
    $protectionStatus = $null
    $volumeStatus     = $null

    $blv = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction SilentlyContinue
    if ($blv) {
        $protectionStatus = $blv.ProtectionStatus
        $volumeStatus     = [string]$blv.VolumeStatus
        if ($protectionStatus -eq 'On' -or $protectionStatus -eq 'ProtectionOn' -or $protectionStatus -eq 1) {
            $protectionState = $true
        } elseif ($protectionStatus -eq 'Off' -or $protectionStatus -eq 'ProtectionOff' -or $protectionStatus -eq 0) {
            # v43 patch 5 (revised): ProtectionStatus=Off alone is not
            # sufficient. On Windows 11 24H2+ Device Encryption, a volume can
            # be actively encrypting (VolumeStatus=EncryptionInProgress) with
            # protection Off. During that window new partitions created on the
            # same disk are auto-encrypted by the Device Encryption service
            # before their recovery type GUID can be applied, and reagentc
            # /enable will refuse. The confirmed-safe VolumeStatus values are
            # FullyDecrypted (never encrypted or decryption finished),
            # FullyEncrypted (volume encrypted but protection Off - a normal
            # suspended state), and empty.
            # v43 patch 5 (further revision): FullyEncrypted+Off is treated
            # as AMBIGUOUS, not safe. Rationale: that state can be a
            # legitimate suspension OR a Device Encryption volume in the
            # "Waiting for Activation" state, and we cannot distinguish the
            # two. Only FullyDecrypted (or empty) is confirmed-safe.
            if ($volumeStatus -eq 'FullyDecrypted' -or -not $volumeStatus) {
                $protectionState = $false
            } else {
                # Refuse before the manage-bde fallback can run. On both a
                # mid-encryption volume and a Waiting-for-Activation
                # volume, manage-bde -status reports "Protection Off"
                # (because ProtectionStatus really is Off) and would
                # reclassify the state as $false, letting this function
                # return $true - the exact fail-open path the patch closed.
                if ($volumeStatus -eq 'FullyEncrypted') {
                    Write-Log "BitLocker on ${MountPoint}: ProtectionStatus=Off with VolumeStatus=FullyEncrypted - this state is ambiguous (could be a legitimate suspension, or Device Encryption in Waiting-for-Activation). Refusing to proceed with destructive partition work until the state is resolved to FullyDecrypted or ProtectionStatus=On." -Level ERROR
                } else {
                    Write-Log "BitLocker on ${MountPoint}: ProtectionStatus=Off but VolumeStatus=$volumeStatus - the volume is encrypted or actively encrypting. Device Encryption will auto-encrypt new partitions on this disk and reagentc /enable will fail. Refusing to treat as unprotected." -Level ERROR
                }
                return $false
            }
        }
        Write-Log "BitLocker Get-BitLockerVolume on ${MountPoint}: ProtectionStatus=$protectionStatus, VolumeStatus=$volumeStatus"
    } else {
        Write-Log "BitLocker Get-BitLockerVolume on ${MountPoint} returned null - falling back to manage-bde -status text parsing" -Level WARN
    }

    if ($null -eq $protectionState) {
        # v34: text parsing fallback. See Test-BitLockerProtected for why
        # -protectionaserrorlevel is not used.
        try {
            $mbo = & manage-bde.exe -status $MountPoint 2>&1
            $mboJoined = ($mbo | Out-String)
            if ($mboJoined -match 'Protection On')  { $protectionState = $true }
            elseif ($mboJoined -match 'Protection Off') {
                # v43 patch 5 (further revision): only confirmed-safe when
                # Conversion Status is explicitly Fully Decrypted.
                if ($mboJoined -match 'Conversion Status:\s*Fully Decrypted') {
                    $protectionState = $false
                } else {
                    $protectionState = $null
                }
            }
            else { $protectionState = $null }
            Write-Log "BitLocker manage-bde -status on ${MountPoint}: parsed state=$protectionState"
        } catch {
            Write-Log "BitLocker manage-bde -status failed on ${MountPoint}: $_" -Level WARN
            $protectionState = $null
        }
    }

    # Step 2: unknown state must not silently proceed as "already off".
    if ($null -eq $protectionState) {
        Write-Log "BitLocker protection state on ${MountPoint} could not be determined - refusing to treat as unprotected" -Level ERROR
        return $false
    }

    # Step 3: already off -> done.
    if ($protectionState -eq $false) {
        Write-Log "BitLocker protection on ${MountPoint} is already Off - no suspension needed"
        return $true
    }

    # Step 4: suspend.
    Write-Log "Suspending BitLocker on ${MountPoint}"
    try {
        Suspend-BitLocker -MountPoint $MountPoint -RebootCount 1 -ErrorAction Stop
    } catch {
        Write-Log "Suspend-BitLocker failed on ${MountPoint}: $_" -Level WARN
        return $false
    }

    # v32: mark ownership immediately after the machine's protection
    # state has changed, before verification. If verification times out,
    # the finally block must still attempt Resume-BitLocker.
    $Script:BitLockerSuspended = $true

    # Step 5: verify suspension with a polling loop.
    $suspended = $false
    for ($i = 0; $i -lt 60; $i++) {
        if ((Test-BitLockerSuspended -MountPoint $MountPoint) -eq $true) {
            $suspended = $true
            break
        }
        Start-Sleep 1
    }

    if (-not $suspended) {
        Write-Log "BitLocker did not suspend within 60s on ${MountPoint} - ownership flag left set so finally attempts resume" -Level WARN
        return $false
    }

    Write-Log "BitLocker suspension confirmed on ${MountPoint}"
    Start-Sleep -Seconds 5
    return $true
}

function Resume-BitLockerIfNeeded {
    if ($Script:BitLockerSuspended) {
        try {
            Write-Log "Resuming BitLocker on C:"
            Resume-BitLocker -MountPoint "C:" -ErrorAction Stop
        } catch {
            Write-Log "Failed to resume BitLocker: $_" -Level WARN
            # v42: flag the failure so it is visible to any consumer of
            # this run's state. Note that this function is called from the
            # finally block, which runs after the exit code has already
            # been determined by the try block, so setting the flag here
            # does not change the current run's exit code. It is set
            # anyway so the intent is correct if that ordering is ever
            # changed. BitLocker's -RebootCount 1 suspension means
            # protection re-enables automatically on the next reboot, so
            # a failed Resume is cosmetic within the current session.
            $Script:nonFatalWarning = $true
        }
    }
}

# =========================== RECOVERY PARTITION DETECTION ===========================
function Test-RecoveryPartitionEncrypted {
    param([Parameter(Mandatory)] $Partition)
    # v32: three-state contract, delegated to Test-VolumeEncrypted so
    # this screening step shares the same protection model as the C:
    # checks.
    #   $true  = encrypted or partially encrypted
    #   $false = confirmed fully decrypted
    #   $null  = could not determine
    if ($Script:DryRun) { return $false }
    try {
        $vol = Get-Volume -Partition $Partition -ErrorAction SilentlyContinue
        if (-not $vol) { return $null }
        $letter = $vol.DriveLetter
        $assignedTemp = $false
        if (-not $letter) {
            $avail = Get-AvailableDriveLetter
            if (-not $avail) { return $null }
            $assignedLetter = Invoke-DriveLetterAssignment -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -PreferredLetter $avail
            if (-not $assignedLetter) { return $null }
            $letter = $assignedLetter
            $assignedTemp = $true
            $Script:tempDriveLetters.Add($assignedLetter)
        }
        try {
            return (Test-VolumeEncrypted -MountPoint "${letter}:")
        } finally {
            if ($assignedTemp) { Invoke-DriveLetterRemoval -Letter $letter | Out-Null }
        }
    } catch {
        Write-Log "Error checking encryption on partition $($Partition.PartitionNumber): $_" -Level WARN
        return $null
    }
}

function Get-RecoveryPartitions {
    param([int]$DiskNumber = -1)
    $disks = if ($DiskNumber -ge 0) { @(Get-Disk -Number $DiskNumber) } else { Get-Disk }
    $allParts = @()
    foreach ($disk in $disks) {
        $diskNum = $disk.Number
        $byLabel = Get-Volume | Where-Object { $_.FileSystemLabel -eq "Recovery" -or $_.FileSystemLabel -eq "WINRE" } |
                   Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DiskNumber -eq $diskNum }
        $byGpt = if ($disk.PartitionStyle -eq 'GPT') {
                     Get-Partition -DiskNumber $diskNum | Where-Object { $_.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' }
                 } else { @() }
        $byMbr = if ($disk.PartitionStyle -eq 'MBR') {
                     Get-Partition -DiskNumber $diskNum | Where-Object { $_.MbrType -eq 0x27 }
                 } else { @() }
        $allParts += @($byLabel) + @($byGpt) + @($byMbr) |
                     Where-Object { $_.PartitionNumber -gt 0 } |
                     Group-Object -Property PartitionNumber |
                     ForEach-Object { $_.Group | Select-Object -First 1 }
    }
    return @($allParts)
}

# Remove any type-coded recovery partition that is not on the OS disk.
# Extracted from the inline Step 7 block so the same cleanup runs on both
# the full-update path and the idempotent fast path. The idempotent path
# previously exited before Step 7, so a stray partition that appeared
# after the last full run (e.g. a USB-attached device carrying an old
# recovery partition) would survive indefinitely as long as the machine's
# state stayed idempotent. The invariant this function enforces is: no
# type-coded recovery partition exists on any non-OS disk.
#
# The type-code gate (GPT DE94... or MBR 0x27) distinguishes "recovery
# partition that could confuse the boot loader" from "data partition that
# happens to carry the Recovery/WINRE label". The former is deleted, the
# latter is logged and skipped. On non-OS disks, a label-only match is
# never sufficient authority to delete a partition (v42 change #4).
#
# Returns $true if every type-coded stray partition was removed (or none
# was present), $false if any deletion failed. A failure also sets
# $Script:nonFatalWarning so the caller's exit code reflects the
# incomplete cleanup.
function Remove-StrayRecoveryPartitions {
    param([Parameter(Mandatory)][int]$OSDiskNumber)
    $anyFailed = $false
    foreach ($disk in Get-Disk) {
        if ($disk.Number -eq $OSDiskNumber) { continue }
        foreach ($rp in @(Get-RecoveryPartitions -DiskNumber $disk.Number)) {
            $isTyped = ($rp.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}') -or ($rp.MbrType -eq 0x27)
            if (-not $isTyped) {
                Write-Log "Step 7: skipping non-OS-disk partition $($disk.Number)/$($rp.PartitionNumber) - label matches recovery but type code does not" -Level WARN
                continue
            }
            if ($Script:DryRun) {
                Write-Log "[DRY RUN] Would delete stray recovery partition $($disk.Number)/$($rp.PartitionNumber)"
                continue
            }
            try {
                $rp | Remove-Partition -Confirm:$false -ErrorAction Stop
                Write-Log "Step 7: deleted stray recovery partition $($disk.Number)/$($rp.PartitionNumber)"
            } catch {
                Write-Log "Step 7: failed to delete stray recovery partition $($disk.Number)/$($rp.PartitionNumber): $_" -Level WARN
                $Script:nonFatalWarning = $true
                $anyFailed = $true
            }
        }
    }
    return (-not $anyFailed)
}

# =========================== FREE SPACE CHECK ===========================
function Test-RecoveryPartitionHasRoom {
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][int]$PartitionNumber,
        [Parameter(Mandatory)][string]$Letter,
        [Parameter(Mandatory)][int64]$RequiredBytes
    )
    try {
        $vol = Get-Volume -DriveLetter $Letter.TrimEnd(':') -ErrorAction SilentlyContinue
        if (-not $vol) {
            $p = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction SilentlyContinue
            if ($p) { $vol = Get-Volume -Partition $p -ErrorAction SilentlyContinue }
        }
        if (-not $vol) { Write-Log "Test-RecoveryPartitionHasRoom: no volume for ${Letter}:" -Level WARN; return $false }
        $existingWimPath = "$($Letter.TrimEnd(':')):\Recovery\WindowsRE\winre.wim"
        $existingWimSize = 0
        if (Test-Path $existingWimPath) {
            try { $existingWimSize = (Get-Item $existingWimPath -Force).Length } catch { }
        }
        $effectiveFree = [int64]$vol.SizeRemaining + [int64]$existingWimSize
        Write-Log "Partition $PartitionNumber ($Letter): effective free $([math]::Round($effectiveFree/1MB,1)) MiB (current $([math]::Round($vol.SizeRemaining/1MB,1)) + existing WIM $([math]::Round($existingWimSize/1MB,1))), need $([math]::Round($RequiredBytes/1MB,1)) MiB"
        return ($effectiveFree -ge $RequiredBytes)
    } catch {
        Write-Log "Test-RecoveryPartitionHasRoom failed: $_" -Level WARN
        return $false
    }
}

# =========================== RECOVERY PARTITION ATTRIBUTES ===========================
function Set-RecoveryPartitionAttributes {
    param([Parameter(Mandatory)][int]$DiskNumber, [Parameter(Mandatory)][int]$PartitionNumber, [Parameter(Mandatory)][string]$Style)
    if ($Script:DryRun) { Write-Log "[DRY RUN] Would set recovery attrs on disk $DiskNumber part $PartitionNumber"; return $true }
    try {
        if ($Style -eq 'GPT') {
            $dp = @"
select disk $DiskNumber
select partition $PartitionNumber
set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac
gpt attributes=0x8000000000000001
"@
        } else {
            $dp = @"
select disk $DiskNumber
select partition $PartitionNumber
set id=27
"@
        }
        $output = $dp | diskpart 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Log "diskpart set attributes returned non-zero: $output" -Level WARN; return $false }
        Write-Log "Set recovery attributes on disk $DiskNumber part $PartitionNumber ($Style)"
        return $true
    } catch { Write-Log "Failed to set recovery attributes: $_" -Level WARN; return $false }
}

# =========================== POST-RESIZE VERIFICATION ===========================
function Assert-PartitionSizeAfterResize {
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][int]$PartitionNumber,
        [Parameter(Mandatory)][int64]$ExpectedSizeBytes,
        [int64]$ToleranceBytes = 1MB
    )
    try {
        $re = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction Stop
        if (-not $re) {
            Write-Log "Assert-PartitionSizeAfterResize: partition $DiskNumber/$PartitionNumber not found" -Level ERROR
            return $false
        }
        if ($re.DiskNumber -ne $DiskNumber -or $re.PartitionNumber -ne $PartitionNumber) {
            Write-Log "Assert-PartitionSizeAfterResize: identity mismatch, got $($re.DiskNumber)/$($re.PartitionNumber)" -Level ERROR
            return $false
        }
        $delta = [Math]::Abs([int64]$re.Size - $ExpectedSizeBytes)
        if ($delta -gt $ToleranceBytes) {
            Write-Log "Assert-PartitionSizeAfterResize: partition $DiskNumber/$PartitionNumber size $([math]::Round($re.Size/1MB,2)) MiB, expected $([math]::Round($ExpectedSizeBytes/1MB,2)) MiB, delta $([math]::Round($delta/1MB,2)) MiB > tolerance $([math]::Round($ToleranceBytes/1MB,2)) MiB" -Level ERROR
            return $false
        }
        Write-Log "Verified partition $DiskNumber/$PartitionNumber size $([math]::Round($re.Size/1MB,2)) MiB (expected $([math]::Round($ExpectedSizeBytes/1MB,2)) MiB)"
        return $true
    } catch {
        Write-Log "Assert-PartitionSizeAfterResize: query failed for $DiskNumber/$PartitionNumber - $_" -Level ERROR
        return $false
    }
}

# =========================== RECOVERY PARTITION CREATION ===========================
# v42: re-extend the OS partition to its current SizeMax. Called from
# every post-shrink failure path in Ensure-AdequateRecoveryPartition so
# that no failure leaves C: permanently shrunken. The OS was extended to
# SizeMax before the shrink and then reduced by (bucketSizeMiB + 1) MiB
# to make room for a new recovery partition; if the new partition cannot
# be created for any reason, that space must be returned to C:. Returns
# $true if the OS partition is at SizeMax on return (or was already),
# $false if the resize failed or verification failed. Failures are
# non-fatal - the space remains unallocated and will be reclaimed on the
# next full-update run - but they are logged so the operator can see them.
function Restore-OSPartitionSize {
    param([Parameter(Mandatory)][string]$Reason)
    if ($Script:DryRun) { Write-Log "[DRY RUN] Would re-extend OS partition ($Reason)"; return $true }
    $osPart = Get-OSPartition
    if (-not $osPart) {
        Write-Log "Restore-OSPartitionSize: OS partition not found ($Reason)" -Level WARN
        # v43 patch 2 change #3: same contract as the verification-failed
        # and exception branches below - every failed attempt to restore
        # the OS partition geometry must set GeometryRestoreFailed so
        # Write-WinREState's gate fires. The "OS partition not found"
        # state is extremely unlikely on a running system (it implies
        # the C: drive letter has been lost while the script is still
        # executing), but leaving it as the one failure path that does
        # not set the flag makes the flag's contract inconsistent and
        # creates a narrow window where a bad state file could be
        # written. The fix is free and closes that window.
        $Script:nonFatalWarning = $true
        $Script:GeometryRestoreFailed = $true
        return $false
    }
    try {
        $newMax = [int64](Get-PartitionSupportedSize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber).SizeMax
        if ($newMax -le $osPart.Size) {
            Write-Log "OS partition already at SizeMax ($Reason) - no re-extend needed"
            return $true
        }
        Write-Log "Re-extending OS partition from $([math]::Round($osPart.Size/1MB,1)) MiB to $([math]::Round($newMax/1MB,1)) MiB ($Reason)"
        $osPart | Resize-Partition -Size $newMax -ErrorAction Stop
        Start-Sleep 3
        if (-not (Assert-PartitionSizeAfterResize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber -ExpectedSizeBytes $newMax)) {
            Write-Log "Restore-OSPartitionSize: verification failed ($Reason)" -Level WARN
            # v43 patch 2 change #3: surface the failure via two channels.
            # nonFatalWarning changes the exit code so the caller
            # reports EXIT_WARNING instead of EXIT_SUCCESS.
            # GeometryRestoreFailed additionally invalidates the state
            # file (see Write-WinREState) so the machine does not leave
            # behind a state file that a subsequent run could accept as
            # the current deployment while C: is still shrunken. Without
            # this, the v41 zero-partitions + UsedOSFallback exemption
            # could preserve the shrunken geometry indefinitely and the
            # script would report success on every subsequent run. With
            # the invalidation, the next run treats the state as absent,
            # sets needInject = $true, and re-runs the full-update path
            # - which re-extends C: as part of the destructive attempt
            # and repairs the geometry if the failure was transient.
            $Script:nonFatalWarning = $true
            $Script:GeometryRestoreFailed = $true
            return $false
        }
        return $true
    } catch {
        Write-Log "Restore-OSPartitionSize failed ($Reason): $_" -Level WARN
        # v43 patch 2 change #3: same rationale as the verification-failed
        # branch above.
        $Script:nonFatalWarning = $true
        $Script:GeometryRestoreFailed = $true
        return $false
    }
}

# v40: helper to clean up a partition we created but could not complete.
# Used when Format-Volume fails, so the freshly created partition does not
# survive as an orphan with a default GPT type, no label, and no
# filesystem - a combination Get-RecoveryPartitions cannot match, which
# would leave the orphan permanently invisible to the script. Uses the
# same delete-first / diskpart-override-second pattern as the main
# deletion loop in Ensure-AdequateRecoveryPartition. Returns $true when
# the partition is confirmed gone, $false when it survived.
function Remove-OrphanPartition {
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][int]$PartitionNumber,
        [Parameter(Mandatory)][string]$Reason
    )
    if ($Script:DryRun) { Write-Log "[DRY RUN] Would remove orphan partition $DiskNumber/$PartitionNumber ($Reason)"; return $true }
    try {
        $p = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction Stop
        $p | Remove-Partition -Confirm:$false -ErrorAction Stop
    } catch {
        try {
            $dp = "select disk $DiskNumber`nselect partition $PartitionNumber`ndelete partition override"
            $dp | diskpart | Out-Null
        } catch { }
    }
    Start-Sleep 2
    $stillThere = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction SilentlyContinue
    if ($stillThere) {
        Write-Log "Orphan partition $DiskNumber/$PartitionNumber could not be removed after $Reason - manual cleanup may be required" -Level WARN
        # v43 patch 3: if the orphan survives, C: is still shrunken and
        # the space it consumed cannot be re-extended into it (the orphan
        # sits between the OS partition and the disk end). Set the
        # geometry-failure flag so Write-WinREState refuses to record the
        # resulting layout as a valid state. Without this, the caller
        # discards Remove-OrphanPartition's return value, the flow
        # proceeds to OS-fallback, and the state file is written with
        # UsedOSFallback=$true. On the next run the count=0 exemption
        # (when the orphan is a Basic Data partition) or the count=1 fast
        # path via $activeOnOSFallback (when the orphan was retyped as
        # recovery before the drive-letter check failed) preserves the
        # shrunken geometry indefinitely. This is the same class of
        # problem the v43 patch 2 changes were designed to eliminate;
        # this was the one remaining geometry-restore failure path that
        # did not set the flag.
        $Script:nonFatalWarning = $true
        $Script:GeometryRestoreFailed = $true
        return $false
    }
    Write-Log "Removed orphan partition $DiskNumber/$PartitionNumber after $Reason"

    # v42: absorb the freed space back into the OS partition. Delegates
    # to Restore-OSPartitionSize so the same logic and the same
    # post-resize verification are used by every post-shrink failure
    # path, not just this one.
    Restore-OSPartitionSize -Reason "after orphan removal" | Out-Null
    return $true
}

function Ensure-AdequateRecoveryPartition {
    param([int]$RequiredWimSizeMB)

    # v37: dynamic new-partition sizing. Required total = WIM + 250 MiB
    # free-space target + 30 MiB filesystem allowance, rounded UP to the
    # next 100 MiB boundary and clamped to a 1000 MiB minimum. The 250 MiB
    # target matches Microsoft's current WinRE servicing guidance. The 30
    # MiB covers NTFS metadata and cluster overhead on a freshly-formatted
    # volume so the 250 MiB target is actually achieved after deployment.
    # Rounding is always UP - never nearest - so the result can only be
    # larger than required, never smaller.
    $neededMiB = $RequiredWimSizeMB + $WinREFreeSpaceMiB + $NewPartitionFilesystemMiB
    $bucketSizeMiB = [int]([Math]::Ceiling($neededMiB / $NewPartitionIncrementMiB) * $NewPartitionIncrementMiB)
    if ($bucketSizeMiB -lt $NewPartitionMinimumMiB) { $bucketSizeMiB = $NewPartitionMinimumMiB }
    Write-Log "Creating recovery partition: required $neededMiB MiB -> dynamic size $bucketSizeMiB MiB"

    $osDisk = Get-OSDisk
    if (-not $osDisk) { Write-Log "No OS disk found" -Level ERROR; return $null }
    $osPart = Get-OSPartition
    if (-not $osPart) { Write-Log "No OS partition found" -Level ERROR; return $null }

    $S = [int64]$osPart.Size
    $B = [int64]($bucketSizeMiB * 1MB)
    $M = [int64](Get-PartitionSupportedSize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber).SizeMin

    $parts = @(Get-RecoveryPartitions -DiskNumber $osDisk.Number)
    $deletableParts = @()
    $R = [int64]0
    foreach ($rp in $parts) {
        if ($osPart -and $rp.DiskNumber -eq $osPart.DiskNumber -and $rp.PartitionNumber -eq $osPart.PartitionNumber) { continue }
        $deletableParts += $rp
        $R += [int64]$rp.Size
    }

    Write-Log "Capacity pre-check: S=$([math]::Round($S/1MB,1)) MiB, B=$([math]::Round($B/1MB,1)) MiB, M=$([math]::Round($M/1MB,1)) MiB, R=$([math]::Round($R/1MB,1)) MiB"

    $case1Safe = (($S - $B) -ge $M)
    $case3Fatal = (($S + $R - $B) -lt $M)

    if ($case1Safe) {
        Write-Log "Pre-check: current OS partition can shrink by bucket size without reclaiming recovery space (safe path)"
    } else {
        Write-Log "WARNING: Pre-check indicates current OS partition cannot shrink by bucket size alone." -Level WARN
        Write-Log "WARNING: Destructive path required: delete recovery partitions, extend OS, then shrink OS." -Level WARN
        Write-Log "WARNING: If the final shrink fails, recovery partitions will have been destroyed. No rollback." -Level WARN
    }

    # v38: dedicated recovery partition is the primary objective. The
    # capacity pre-check is now advisory only - we proceed with the
    # destructive repartitioning attempt even when the arithmetic
    # suggests the OS may not shrink enough. SizeMin from
    # Get-PartitionSupportedSize is a conservative hint and can be
    # pessimistic when the volume has movable files; defrag /x retry
    # in the shrink path may still succeed. If the real shrink fails,
    # the existing recovery partitions have already been deleted and
    # the main flow falls back to OS-fallback. That is the deliberate
    # trade: try for a dedicated partition first, fall back only when
    # the attempt actually fails.
    if ($case3Fatal) {
        Write-Log "WARNING: Capacity pre-check: S=$([math]::Round($S/1MB,1)) MiB, R=$([math]::Round($R/1MB,1)) MiB, B=$([math]::Round($B/1MB,1)) MiB, M=$([math]::Round($M/1MB,1)) MiB. S+R-B=$([math]::Round(($S+$R-$B)/1MB,1)) MiB < M - the OS partition may not shrink enough for a dedicated recovery partition." -Level WARN
        Write-Log "WARNING: Proceeding with destructive repartitioning attempt anyway (dedicated recovery partition is the primary objective)." -Level WARN
        Write-Log "WARNING: If the OS shrink fails, recovery partitions will have been deleted and cannot be restored. No rollback." -Level WARN
    }

    # v43 patch 5 (revised): the BitLocker safety check runs BEFORE the
    # WinRE disable. If the BitLocker check refuses (Device Encryption
    # in-progress), the function returns without having disabled WinRE,
    # so the machine retains its current recovery environment while the
    # encryption state stabilises. The original patch 5 implementation
    # disabled WinRE first and then refused, which left the machine with
    # WinRE disabled and no way to re-enable it until encryption
    # finished - the exact damaged state that patch 5 was written to
    # prevent.
    $suspendResult = Suspend-BitLockerForWinRE
    if (-not $suspendResult) {
        $blState = Test-BitLockerProtected -MountPoint "C:"
        if ($blState -ne $false) {
            $blStateText = if ($null -eq $blState) { 'unknown' } else { "$blState" }
            Write-Log "Cannot confirm BitLocker is unprotected on C: (state=$blStateText) - refusing destructive partition operations" -Level ERROR
            $Script:BitLockerGuardDeferred = $true
            return $null
        }
        Write-Log "Suspend returned false but BitLocker is confirmed Off - proceeding" -Level WARN
    }

    $stateBefore = Get-WinREState
    if ($stateBefore.Status -eq "Enabled") {
        if ($Script:DryRun) {
            Write-Log "[DRY RUN] Would disable WinRE before partition recreation"
        } else {
            Write-Log "Disabling WinRE before partition recreation"
            $disableOutput = cmd /c "reagentc /disable 2>&1"
            $disableExit = $LASTEXITCODE
            Write-Log "reagentc /disable: exit=$disableExit, output=$disableOutput"
            if ($disableExit -ne 0) {
                Write-Log "reagentc /disable failed (exit $disableExit): $disableOutput" -Level ERROR
                return $null
            }
            Start-Sleep 2
            $verifyDisabled = Get-WinREState
            if ($verifyDisabled.Status -ne "Disabled") {
                Write-Log "WinRE is still reported as $($verifyDisabled.Status) after reagentc /disable - aborting before partition deletion" -Level ERROR
                return $null
            }
            Write-Log "WinRE disable verified"
        }
    }

    Write-Log "Pre-deletion inventory:"
    $activePartForInventory = $null
    if ($stateBefore.Location) {
        $activePartForInventory = Resolve-WinRELocationToPartition -Location $stateBefore.Location
    }
    foreach ($rp in $deletableParts) {
        $rpLabel = "(no label)"
        $rpUsedMiB = -1
        try {
            $rpVol = Get-Volume -Partition $rp -ErrorAction SilentlyContinue
            if ($rpVol) {
                if ($rpVol.FileSystemLabel) { $rpLabel = $rpVol.FileSystemLabel }
                $rpUsedMiB = [math]::Round(($rpVol.Size - $rpVol.SizeRemaining) / 1MB, 1)
            }
        } catch { }
        $isWinRELocation = "no"
        if ($activePartForInventory -and
            $activePartForInventory.DiskNumber -eq $rp.DiskNumber -and
            $activePartForInventory.PartitionNumber -eq $rp.PartitionNumber) {
            $isWinRELocation = "YES"
        }
        Write-Log "  Disk $($rp.DiskNumber) Part $($rp.PartitionNumber): size $([math]::Round($rp.Size/1MB,1)) MiB, label='$rpLabel', used=$rpUsedMiB MiB, isWinRELocation=$isWinRELocation"
    }

    # v43 patch 5 (further revision 3): DryRun terminates here, after the
    # read-only pre-checks and pre-deletion inventory and before any
    # state-modifying action. Everything below this point modifies the
    # machine: partition deletion, OS partition resize, partition
    # creation, format, attribute application, drive-letter assignment,
    # and directory creation. Under DryRun the plan is logged and the
    # function returns without performing any of them.
    #
    # This replaces the previous per-step DryRun guards (a `continue`
    # inside the deletion loop, `-and -not $Script:DryRun` on the OS
    # extend, and a final early return before the shrink). Those guards
    # worked except for one: the reagantc /disable call above was not
    # guarded, so a DryRun pass on a machine with no suitable recovery
    # partition - the exact case this function exists to handle -
    # actually disabled WinRE. Consolidating the terminator here makes
    # the DryRun guarantee structural rather than per-step: no future
    # code inserted into this function can accidentally modify the
    # machine under DryRun without first passing through this choke
    # point.
    if ($Script:DryRun) {
        Write-Log "[DRY RUN] Would delete $($deletableParts.Count) recovery partition(s) on the OS disk:"
        foreach ($rp in $deletableParts) {
            Write-Log "[DRY RUN]   - Disk $($rp.DiskNumber) Part $($rp.PartitionNumber) (size $([math]::Round($rp.Size/1MB,1)) MiB)"
        }
        if ($deletableParts.Count -gt 0) {
            Write-Log "[DRY RUN] Would extend the OS partition to absorb the space freed by the deletion(s)"
        } else {
            Write-Log "[DRY RUN] No recovery partitions on the OS disk - the OS partition extend step would be a no-op"
        }
        Write-Log "[DRY RUN] Would shrink the OS partition by $($bucketSizeMiB + 1) MiB (bucket + 1 MiB alignment slack)"
        Write-Log "[DRY RUN] Would create a new recovery partition of $bucketSizeMiB MiB with the recovery type GUID applied at creation"
        $letter = Get-AvailableDriveLetter
        Write-Log "[DRY RUN] Would assign drive letter ${letter}: to the new partition, format it NTFS label 'Recovery', apply the recovery GPT attributes, verify no auto-encryption occurred, and remove the drive letter before reagentc /enable"
        return @{ DriveLetter = $letter; DiskNumber = $osDisk.Number; PartitionNumber = 999 }
    }

    foreach ($rp in $deletableParts) {
        try {
            $rp | Remove-Partition -Confirm:$false -ErrorAction Stop
        } catch {
            $dp = "select disk $($rp.DiskNumber)`nselect partition $($rp.PartitionNumber)`ndelete partition override"
            $dp | diskpart | Out-Null
        }
        Start-Sleep 2
        $stillThere = Get-Partition -DiskNumber $rp.DiskNumber -PartitionNumber $rp.PartitionNumber -ErrorAction SilentlyContinue
        if ($stillThere) {
            Write-Log "FATAL: recovery partition $($rp.DiskNumber)/$($rp.PartitionNumber) could not be deleted" -Level ERROR
            return $null
        }
        Write-Log "Confirmed deletion of partition $($rp.PartitionNumber) on disk $($rp.DiskNumber)"
    }

    $osPart = Get-OSPartition
    if (-not $osPart) { Write-Log "OS partition lost after deletion - FATAL" -Level ERROR; return $null }

    $maxSize = [int64](Get-PartitionSupportedSize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber).SizeMax
    if ($maxSize -gt $osPart.Size) {
        Write-Log "Extending OS partition from $([math]::Round($osPart.Size/1MB,1)) MiB to $([math]::Round($maxSize/1MB,1)) MiB"
        try {
            $osPart | Resize-Partition -Size $maxSize -ErrorAction Stop
        } catch {
            Write-Log "OS partition extend failed: $_" -Level ERROR
            return $null
        }
        Start-Sleep 3
        if (-not (Assert-PartitionSizeAfterResize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber -ExpectedSizeBytes $maxSize)) {
            Write-Log "OS partition extend verification failed - aborting before shrink" -Level ERROR
            return $null
        }
    }

    # v28: add 1 MiB of alignment slack. $newOffset below rounds the OS
    # end UP to the next MiB boundary. Without slack that rounding can
    # consume part of the requested bucket and leave the tail slightly
    # too short for the new partition. The 1 MiB covers the worst case
    # (rounding add < 1 MiB) and guarantees the aligned offset leaves at
    # least bucketSizeMiB at the tail. HP ProBook 445 G10 (AMD Ryzen 5
    # 7530U, Win11 26200) confirmed the failure: after shrink the tail
    # had 1499.34 MiB for a 1500 MiB bucket.
    $shrinkBytes = [int64](($bucketSizeMiB + 1) * 1MB)
    $osPart = Get-OSPartition
    if (-not $osPart) { Write-Log "OS partition lost before shrink - FATAL" -Level ERROR; return $null }
    $initialOSSize = [int64]$osPart.Size
    $expectedAfterShrink = $initialOSSize - $shrinkBytes

    # v39: log SizeMin at each stage so we can determine empirically
    # whether the sleep/settle step or the defrag step is what actually
    # lowers SizeMin enough to permit the shrink. See the v39 changelog
    # entry for the measurement rationale.
    $sizeMinBefore = [int64](Get-PartitionSupportedSize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber).SizeMin
    Write-Log "Shrink target $([math]::Round($expectedAfterShrink/1MB,1)) MiB; current SizeMin $([math]::Round($sizeMinBefore/1MB,1)) MiB"

    # --- Attempt 1: immediate shrink ---
    Write-Log "Shrinking OS partition from $([math]::Round($initialOSSize/1MB,1)) MiB to $([math]::Round($expectedAfterShrink/1MB,1)) MiB (attempt 1, immediate)"
    $shrinkOK = $false
    try {
        $osPart | Resize-Partition -Size $expectedAfterShrink -ErrorAction Stop
        Start-Sleep 5
        if (Assert-PartitionSizeAfterResize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber -ExpectedSizeBytes $expectedAfterShrink) {
            $shrinkOK = $true
        } else {
            Write-Log "Shrink attempt 1 verification failed" -Level WARN
        }
    } catch {
        Write-Log "Shrink attempt 1 failed: $_" -Level WARN
    }

    # --- Attempt 2: sleep and retry (v39) ---
    # Rationale: attempt 1 in the v38 ASUS field log failed with "Size Not
    # Supported" while attempt 2 with the same target succeeded after a
    # 29-minute defrag. We do not know whether the defrag was the cause or
    # whether something time-based lowered SizeMin. Attempt 2 settles that
    # question on every run where attempt 1 fails: sleep, re-query SizeMin,
    # log the delta, then retry. If the retry succeeds often, the defrag
    # step becomes rare. If it never succeeds, the defrag is confirmed
    # necessary and we remove this step.
    $sizeMinAfterSleep = $sizeMinBefore
    if (-not $shrinkOK) {
        $sleepSec = 10
        Write-Log "Shrink attempt 1 failed. Sleeping ${sleepSec}s then re-querying SizeMin and retrying (attempt 2)." -Level WARN
        Start-Sleep -Seconds $sleepSec

        $osPart = Get-OSPartition
        if (-not $osPart) { Write-Log "OS partition lost before retry - FATAL" -Level ERROR; return $null }
        $sizeMinAfterSleep = [int64](Get-PartitionSupportedSize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber).SizeMin
        $deltaSleepMiB = [math]::Round(($sizeMinBefore - $sizeMinAfterSleep) / 1MB, 1)
        Write-Log "After ${sleepSec}s sleep: SizeMin $([math]::Round($sizeMinAfterSleep/1MB,1)) MiB (delta $deltaSleepMiB MiB vs before attempt 1); target $([math]::Round($expectedAfterShrink/1MB,1)) MiB"

        Write-Log "Retrying shrink to $([math]::Round($expectedAfterShrink/1MB,1)) MiB (attempt 2, after sleep)"
        try {
            $osPart | Resize-Partition -Size $expectedAfterShrink -ErrorAction Stop
            Start-Sleep 5
            if (Assert-PartitionSizeAfterResize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber -ExpectedSizeBytes $expectedAfterShrink) {
                $shrinkOK = $true
                Write-Log "Shrink attempt 2 succeeded after sleep - defrag was not required on this run"
            } else {
                Write-Log "Shrink attempt 2 verification failed" -Level WARN
            }
        } catch {
            Write-Log "Shrink attempt 2 (after sleep) failed: $_" -Level WARN
        }
    }

    # --- Attempt 3: defrag /x, then retry ---
    if (-not $shrinkOK) {
        Write-Log "Attempting free-space consolidation via defrag.exe C: /x before retrying shrink (attempt 3)" -Level WARN
        try {
            $defragOutput = & defrag.exe C: /x 2>&1
            $defragExit = $LASTEXITCODE
            Write-Log "defrag C: /x exit $defragExit"
            if ($defragOutput) {
                $defragOutput | Select-Object -First 10 | ForEach-Object { Write-Log "  defrag: $_" }
            }
        } catch {
            Write-Log "defrag invocation failed: $_" -Level WARN
        }
        Start-Sleep 5

        $osPart = Get-OSPartition
        if (-not $osPart) { Write-Log "OS partition lost before retry - FATAL" -Level ERROR; return $null }
        $sizeMinAfterDefrag = [int64](Get-PartitionSupportedSize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber).SizeMin
        $deltaDefragMiB = [math]::Round(($sizeMinAfterSleep - $sizeMinAfterDefrag) / 1MB, 1)
        Write-Log "After defrag: SizeMin $([math]::Round($sizeMinAfterDefrag/1MB,1)) MiB (delta $deltaDefragMiB MiB vs post-sleep); target $([math]::Round($expectedAfterShrink/1MB,1)) MiB"

        Write-Log "Retrying shrink to $([math]::Round($expectedAfterShrink/1MB,1)) MiB (attempt 3, after defrag)" -Level WARN
        try {
            $osPart | Resize-Partition -Size $expectedAfterShrink -ErrorAction Stop
            Start-Sleep 5
            if (Assert-PartitionSizeAfterResize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber -ExpectedSizeBytes $expectedAfterShrink) {
                $shrinkOK = $true
            } else {
                Write-Log "Shrink attempt 3 verification failed" -Level ERROR
            }
        } catch {
            Write-Log "Shrink attempt 3 (post-defrag) failed: $_" -Level ERROR
        }
    }

    if (-not $shrinkOK) {
        Write-Log "OS partition shrink failed after all three attempts. Recovery partitions have already been deleted." -Level ERROR
        # v43 patch 2 change #3: Resize-Partition and
        # Assert-PartitionSizeAfterResize are not atomic. If a
        # Resize-Partition succeeded but its verification failed, the OS
        # partition may already be shrunken even though shrinkOK is
        # false. Restore before returning so no failure path leaves C:
        # permanently shrunken. Without this, the OS-fallback state is
        # persisted with C: reduced by (bucketSizeMiB + 1) MiB, and the
        # v41 zero-partitions + UsedOSFallback exemption preserves that
        # state indefinitely.
        Write-Log "Restoring OS partition size before falling back to OS-fallback." -Level WARN
        Restore-OSPartitionSize -Reason "shrink failed after all three attempts" | Out-Null
        Write-Log "Returning null - main flow will attempt OS-partition fallback (C:\Recovery\WindowsRE)." -Level ERROR
        return $null
    }

    $osPart = Get-OSPartition
    $osEnd = $osPart.Offset + $osPart.Size
    $newOffset = [Math]::Ceiling($osEnd / 1MB) * 1MB
    $newSize = [int64]($bucketSizeMiB * 1MB)
    $availableSpace = [int64](Get-Disk -Number $osPart.DiskNumber).Size - $newOffset
    if ($availableSpace -lt $newSize) {
        Write-Log "Not enough space at offset $newOffset for $newSize bytes (available $availableSpace)" -Level ERROR
        Restore-OSPartitionSize -Reason "insufficient space at new-partition offset" | Out-Null
        return $null
    }

    # v43 patch 5: create the partition with the recovery type GUID/type code
    # already applied. This closes the window between New-Partition and
    # Set-RecoveryPartitionAttributes during which the partition looks like a
    # Basic Data partition. On Windows 11 24H2+ with Device Encryption
    # actively encrypting, the encryption service can grab a plain partition
    # in that window and start encrypting it; reagentc /enable then refuses.
    $gptRecoveryType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
    $style = ($osDisk.PartitionStyle)
    $newPart = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            if ($style -eq 'GPT') {
                $newPart = New-Partition -DiskNumber $osPart.DiskNumber -Offset $newOffset -Size $newSize -GptType $gptRecoveryType -ErrorAction Stop
            } else {
                $newPart = New-Partition -DiskNumber $osPart.DiskNumber -Offset $newOffset -Size $newSize -MbrType 0x27 -ErrorAction Stop
            }
            Write-Log "New-Partition succeeded (PartitionNumber=$($newPart.PartitionNumber), type set at creation)"
            break
        } catch {
            Write-Log "New-Partition attempt $attempt failed: $_" -Level WARN
            if ($attempt -lt 3) {
                Start-Sleep 5
                $osPart = Get-OSPartition
                $newOffset = [Math]::Ceiling(($osPart.Offset + $osPart.Size) / 1MB) * 1MB
            }
        }
    }
    if (-not $newPart) {
        Write-Log "New-Partition failed after 3 attempts" -Level ERROR
        Restore-OSPartitionSize -Reason "New-Partition failed after 3 attempts" | Out-Null
        return $null
    }

    try { Format-Volume -Partition $newPart -FileSystem NTFS -NewFileSystemLabel 'Recovery' -Confirm:$false -Force | Out-Null }
    catch {
        Write-Log "Format-Volume failed: $_" -Level ERROR
        # v40: clean up the partition we just created. Without this, an
        # unformatted partition with the default Basic Data GPT type and
        # no filesystem label is invisible to Get-RecoveryPartitions, so
        # the next run would neither delete nor reuse it, and the OS
        # partition's SizeMax would be silently bounded by the orphan.
        Remove-OrphanPartition -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Reason "Format-Volume failure (main path)" | Out-Null
        return $null
    }
    Start-Sleep 3

    # v35: set recovery type and GPT attributes BEFORE assigning a drive
    # letter. A freshly-formatted NTFS partition with a normal data type
    # GUID and a drive letter is a candidate for Device Encryption / BitLocker
    # auto-encryption on Windows 11 24H2+ hardware. Applying the recovery
    # type GUID and 0x8000000000000001 (PLATFORM_REQUIRED + NO_DRIVE_LETTER)
    # first tells BitLocker this is not a data volume. Confirmed by diagnostic:
    # a recovery-typed partition with these attributes reports "The volume
    # could not be opened by BitLocker" and has no Win32_EncryptableVolume
    # entry, while still accepting a temporary drive letter for deployment.
    $style = ($osDisk.PartitionStyle)
    $attrsOk = Set-RecoveryPartitionAttributes -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Style $style
    if (-not $attrsOk) {
        Write-Log "Could not set recovery attributes on newly created partition - proceeding but BitLocker may encrypt it" -Level WARN
    }

    $letter = Get-AvailableDriveLetter
    if (-not $letter) {
        Write-Log "No drive letter available" -Level ERROR
        Remove-OrphanPartition -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Reason "no drive letter available" | Out-Null
        return $null
    }
    $assignedLetter = Invoke-DriveLetterAssignment -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -PreferredLetter $letter
    if (-not $assignedLetter) {
        Write-Log "Could not assign ANY drive letter to new recovery partition" -Level ERROR
        Remove-OrphanPartition -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Reason "drive-letter assignment failed" | Out-Null
        return $null
    }
    $Script:tempDriveLetters.Add($assignedLetter)

    Start-Sleep 5
    $encNewState = Test-VolumeEncrypted -MountPoint "${assignedLetter}:"
    if ($null -eq $encNewState) {
        Write-Log "Newly created recovery partition encryption state unknown - proceeding; reagentc will surface any issue at enable time" -Level WARN
    }
    if ($encNewState -eq $true) {
        Write-Log "Newly created recovery partition is BitLocker-encrypted - attempting delete and recreate after suspend" -Level WARN

        # Ensure BitLocker is suspended before retrying.
        $suspendOk = Suspend-BitLockerForWinRE -MountPoint "C:"
        if (-not $suspendOk) {
            Write-Log "Cannot suspend BitLocker - aborting recovery partition creation" -Level ERROR
            Remove-OrphanPartition -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Reason "BitLocker suspension failed for encrypted new partition" | Out-Null
            return $null
        }

        # Delete the encrypted partition.
        try {
            $p = Get-Partition -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -ErrorAction Stop
            $p | Remove-Partition -Confirm:$false -ErrorAction Stop
        } catch {
            $dp = "select disk $($osPart.DiskNumber)`nselect partition $($newPart.PartitionNumber)`ndelete partition override"
            $dp | diskpart | Out-Null
        }
        Start-Sleep 3

        # Recreate. Recalculate offset because disk geometry may have changed.
        $osPart = Get-OSPartition
        if (-not $osPart) {
            Write-Log "OS partition lost before recreate - aborting" -Level ERROR
            return $null
        }
        $newOffset = [Math]::Ceiling(($osPart.Offset + $osPart.Size) / 1MB) * 1MB
        $newPart = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                # v43 patch 5: same recovery-type-at-creation guard as the main path.
                if ($style -eq 'GPT') {
                    $newPart = New-Partition -DiskNumber $osPart.DiskNumber -Offset $newOffset -Size $newSize -GptType $gptRecoveryType -ErrorAction Stop
                } else {
                    $newPart = New-Partition -DiskNumber $osPart.DiskNumber -Offset $newOffset -Size $newSize -MbrType 0x27 -ErrorAction Stop
                }
                Write-Log "New-Partition retry succeeded (PartitionNumber=$($newPart.PartitionNumber), type set at creation)"
                break
            } catch {
                Write-Log "New-Partition retry attempt $attempt failed: $_" -Level WARN
                if ($attempt -lt 3) { Start-Sleep 5 }
            }
        }
        if (-not $newPart) {
            Write-Log "New-Partition retry failed after 3 attempts" -Level ERROR
            Restore-OSPartitionSize -Reason "New-Partition retry failed after 3 attempts" | Out-Null
            return $null
        }

        try { Format-Volume -Partition $newPart -FileSystem NTFS -NewFileSystemLabel 'Recovery' -Confirm:$false -Force | Out-Null }
        catch {
            Write-Log "Format-Volume (retry) failed: $_" -Level ERROR
            # v40: same orphan-cleanup as the main path.
            Remove-OrphanPartition -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Reason "Format-Volume failure (retry path)" | Out-Null
            return $null
        }
        Start-Sleep 3

        # v35: set attributes before letter on the retry path too.
        $styleRetry = ($osDisk.PartitionStyle)
        $attrsRetryOk = Set-RecoveryPartitionAttributes -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Style $styleRetry
        if (-not $attrsRetryOk) {
            Write-Log "Could not set recovery attributes on recreated partition - proceeding but BitLocker may encrypt it" -Level WARN
        }

        $assignedLetter = Invoke-DriveLetterAssignment -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -PreferredLetter $letter
        if (-not $assignedLetter) {
            Write-Log "Could not assign drive letter after recreate" -Level ERROR
            Remove-OrphanPartition -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Reason "drive-letter assignment failed after recreate" | Out-Null
            return $null
        }
        $Script:tempDriveLetters.Add($assignedLetter)
        Start-Sleep 5

        $encRetryState = Test-VolumeEncrypted -MountPoint "${assignedLetter}:"
        if ($encRetryState -eq $true) {
            Write-Log "Recovery partition is STILL BitLocker-encrypted after recreate - aborting" -Level ERROR
            Remove-OrphanPartition -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Reason "recreated partition still BitLocker-encrypted" | Out-Null
            return $null
        }
        if ($null -eq $encRetryState) {
            Write-Log "Recreated recovery partition encryption state unknown - proceeding" -Level WARN
        } else {
            Write-Log "Verified recreated recovery partition is not encrypted"
        }
    } elseif ($encNewState -eq $false) {
        Write-Log "Verified new recovery partition is not encrypted"
    }

    New-DirectoryIfNotExists "${assignedLetter}:\Recovery\WindowsRE"
    Write-Log "Created fresh recovery partition at ${assignedLetter}:"
    return @{ DriveLetter = $assignedLetter; DiskNumber = $osDisk.Number; PartitionNumber = $newPart.PartitionNumber }
}

# =========================== HARDWARE ===========================
function Get-IntelProcessorGeneration {
    [CmdletBinding()]
    param ( [Parameter(Mandatory, ValueFromPipeline)] [string]$CPUName )
    begin { $Script:seriesMap = @{ '1' = 14; '2' = 15; '3' = 16 } }
    process {
        $name = ($CPUName -replace '\s+', ' ').Trim()
        $name = $name -replace '\(R\)|\(TM\)|\(C\)|\bProcessor\b|\bCPU\b', ''
        $name = ($name -replace '\s+', ' ').Trim()
        if ($name -match '(?i)\bAMD\b')                   { return $null }
        if ($name -match '(?i)\b(?:N|J)\d{2,4}\b')        { return $null }
        if ($name -match '(?i)\bPentium\b|\bCeleron\b|\bAtom\b|\bXeon\b') { return $null }
        if ($name -match '(?i)\b(?<gen>1[1-9])(?:st|nd|rd|th)?\s+Gen\b') { $gen = [int]$Matches['gen']; if ($gen -ge 11) { return $gen } }
        if ($name -match '(?i)\bCore\s+Ultra\s+[3579]\s+(?<sku>\d{3})[A-Z]*\b') { return $Script:seriesMap[$Matches['sku'].Substring(0,1)] }
        if ($name -match '(?i)\bCore\s+[3579]\s+(?<sku>\d{3})[A-Z]*\b') { return $Script:seriesMap[$Matches['sku'].Substring(0,1)] }
        if ($name -match '(?i)\bi[3579][- ](?<model>\d{4,5})[A-Z0-9]*\b') {
            $model = $Matches['model']; $len = $model.Length
            if ($len -eq 5) { $gen = [int]$model.Substring(0,2); if ($gen -ge 11) { return $gen } }
            elseif ($len -eq 4) { $gen = [int]$model.Substring(0,2); if ($gen -ge 11 -and $gen -le 13) { return $gen } }
        }
        return $null
    }
}

function Get-HardwareObject {
    if ($Script:CachedHardware) { return $Script:CachedHardware }
    $cs      = Get-CimInstance Win32_ComputerSystem
    $product = Get-CimInstance Win32_ComputerSystemProduct
    $os      = Get-CimInstance Win32_OperatingSystem
    $cpu     = Get-CimInstance Win32_Processor
    $board   = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue
    $manufacturerRaw = $cs.Manufacturer.Trim()
    $Manufacturer = switch -Regex ($manufacturerRaw) {
        "Dell"              { "Dell" }
        "HP"                { "HP" }
        "Hewlett-Packard"   { "HP" }
        "Lenovo"            { "LENOVO" }
        default             { $manufacturerRaw }
    }
    Write-Log "Raw CPU string: $($cpu.Name)"
    $gen = Get-IntelProcessorGeneration -CPUName $cpu.Name
    Write-Log "Intel generation: $(if ($gen) { $gen } else { 'N/A' })"
    $version = $product.Version
    $machineType = "UNKN"
    if ($Manufacturer -eq "LENOVO") {
        if ($cs.Model -match '^([A-Z0-9]{4})') { $machineType = $Matches[1]; Write-Log "Lenovo machine type from ComputerSystem.Model: $machineType" }
        elseif ($product.Name -match '^([A-Z0-9]{4})') { $machineType = $Matches[1]; Write-Log "Lenovo machine type from ComputerSystemProduct.Name: $machineType" }
        elseif ($board -and $board.Product -match '^([A-Z0-9]{4})') { $machineType = $Matches[1]; Write-Log "Lenovo machine type from BaseBoard.Product: $machineType" }
        elseif ($version -and $version.Length -ge 4) { $machineType = $version.Substring(0,4); Write-Log "Lenovo machine type from Version (fallback): $machineType" }
        else { Write-Log "Could not determine Lenovo machine type" -Level WARN }
    } else { if ($version -and $version.Length -ge 4) { $machineType = $version.Substring(0,4) } }
    $Script:CachedHardware = [PSCustomObject]@{
        Manufacturer   = $Manufacturer; Model = $cs.Model.Trim(); MachineType = $machineType
        CPUVendor      = if ($cpu.Manufacturer -like "*Intel*") { "Intel" } else { "AMD" }
        CPUGeneration  = $gen; Architecture = "x64"; OS = $os.Caption
        IsWin10        = $os.Caption -like "*Windows 10*"; IsWin11 = $os.Caption -like "*Windows 11*"
        WinPE          = if ($os.Caption -like "*Windows 11*") { "11" } else { "10" }; Build = $os.BuildNumber
    }
    return $Script:CachedHardware
}

# =========================== WIM HELPERS ===========================
function Get-WimBuild {
    param([string]$WimPath)
    if (-not $WimPath -or -not (Test-Path $WimPath)) { return $null }
    try { return (Get-WindowsImage -ImagePath $WimPath -Index 1 -ErrorAction Stop).Build }
    catch { Write-Log "Get-WimBuild: could not read $WimPath - $_" -Level WARN; return $null }
}

function Get-LiveWimHash {
    param([string]$WimPath)
    if ($WimPath -and (Test-Path -Path $WimPath -PathType Leaf)) {
        try { return (Get-FileHash -Path $WimPath -Algorithm SHA256).Hash }
        catch { return $null }
    }
    return $null
}

function Get-FileSizeMB {
    param([string]$Path)
    if (-not $Path) { return -1 }
    try { return [math]::Round((Get-Item -Path $Path -Force).Length / 1MB, 2) }
    catch { Write-Log "Get-FileSizeMB: could not stat $Path - $_" -Level WARN; return -1 }
}

# =========================== OEM PROVIDERS ===========================
function Get-DellWinPEPack {
    param($Hardware)
    if (-not $Script:DellWinPEMap) {
        Write-Log "Downloading Dell WinPE map from gist"
        for ($retry = 1; $retry -le 3; $retry++) {
            try { $Script:DellWinPEMap = Invoke-RestMethod -Uri $DellWinPEMapUrl -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop; break }
            catch { Write-Log "Dell map download attempt $retry failed: $_" -Level WARN; if ($retry -lt 3) { Start-Sleep 5 } }
        }
        if (-not $Script:DellWinPEMap) {
            Write-Log "Could not download Dell WinPE map" -Level WARN
            return $null
        }
        Write-Log "Dell WinPE map loaded ($(@($Script:DellWinPEMap.Packs.PSObject.Properties).Count) pack entries)"
    }
    $key = if ($Hardware.IsWin11) { "WinPE11" } else { "WinPE10" }
    $entry = $Script:DellWinPEMap.Packs.$key
    if (-not $entry) {
        Write-Log "Dell map has no entry for $key" -Level WARN
        return $null
    }
    Write-Log "Dell map resolved $key -> $($entry.dellVersion)"
    [PSCustomObject]@{ Manufacturer = "Dell"; Name = "Dell $($entry.dellVersion)"; Version = $entry.dellVersion; DownloadUrl = $entry.url; ArchiveType = "CAB"; IsUrl = $true; ExpectedMD5 = $entry.md5; ExpectedSHA256 = $entry.sha256 }
}

function Get-HPWinPEPack {
    param($Hardware)
    if (-not $Script:HPWinPEMap) {
        Write-Log "Downloading HP WinPE map from gist"
        for ($retry = 1; $retry -le 3; $retry++) {
            try { $Script:HPWinPEMap = Invoke-RestMethod -Uri $HPWinPEMapUrl -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop; break }
            catch { Write-Log "HP map download attempt $retry failed: $_" -Level WARN; if ($retry -lt 3) { Start-Sleep 5 } }
        }
        if (-not $Script:HPWinPEMap) {
            Write-Log "Could not download HP WinPE map" -Level WARN
            return $null
        }
        Write-Log "HP WinPE map loaded ($(@($Script:HPWinPEMap.Packs.PSObject.Properties).Count) pack entries)"
    }
    $entry = $Script:HPWinPEMap.Packs.WinPE1011
    if (-not $entry) {
        Write-Log "HP map has no WinPE1011 entry" -Level WARN
        return $null
    }
    Write-Log "HP map resolved WinPE1011 -> $($entry.softPaqId) v$($entry.version)"
    [PSCustomObject]@{ Manufacturer = "HP"; Name = "HP $($entry.softPaqId)"; Version = $entry.version; DownloadUrl = $entry.url; ArchiveType = "SoftPaq"; IsUrl = $true; ExpectedMD5 = $null; ExpectedSHA256 = $null }
}

function Get-LenovoWinPEPack {
    param($Hardware)
    $mt = $Hardware.MachineType
    if (-not $mt -or $mt -eq 'UNKN') {
        Write-Log "Lenovo WinPE map: cannot resolve - machine type unknown" -Level WARN
        return $null
    }
    if (-not $Script:LenovoWinPEMap) {
        Write-Log "Downloading Lenovo WinPE map from gist"
        for ($retry = 1; $retry -le 3; $retry++) {
            try { $Script:LenovoWinPEMap = Invoke-RestMethod -Uri $LenovoWinPEMapUrl -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop; break }
            catch { Write-Log "Lenovo map download attempt $retry failed: $_" -Level WARN; if ($retry -lt 3) { Start-Sleep 5 } }
        }
        if (-not $Script:LenovoWinPEMap) {
            Write-Log "Could not download Lenovo WinPE map" -Level WARN
            return $null
        }
        Write-Log "Lenovo WinPE map loaded ($(@($Script:LenovoWinPEMap.Models.PSObject.Properties).Count) model entries)"
    }
    $entry = $Script:LenovoWinPEMap.Models.$mt
    if (-not $entry) {
        # v43 patch 5 (further revision 4): many Lenovo machine types have
        # no published WinPE driver pack. A map that loaded successfully
        # and simply does not contain this MT is the expected, permanent
        # answer, not a transient failure. Logged at INFO, not WARN, so it
        # does not appear in the operator's "something to look at" filter.
        # The caller decides the run's completion state based on whether
        # the map loaded, not on whether this specific MT was present.
        Write-Log "No WinPE pack in Lenovo map for machine type $mt (expected for some Lenovo models)" -Level INFO
        return $null
    }
    $winpe = $entry.winpe
    if (-not $winpe -or -not $winpe.url) {
        Write-Log "Lenovo map entry for $mt has no WinPE URL" -Level WARN
        return $null
    }
    Write-Log "Lenovo map resolved $mt -> $($winpe.name) (SHA256: $($winpe.sha256))"
    [PSCustomObject]@{ Manufacturer = "LENOVO"; Name = $winpe.name; Version = $winpe.dsId; DownloadUrl = $winpe.url; ArchiveType = "EXE"; IsUrl = $true; ExpectedMD5 = $null; ExpectedSHA256 = $winpe.sha256 }
}

function Get-OEMWinPEPack {
    param($Hardware)
    switch ($Hardware.Manufacturer) {
        "Dell"   { return Get-DellWinPEPack   -Hardware $Hardware }
        "HP"     { return Get-HPWinPEPack     -Hardware $Hardware }
        "LENOVO" { return Get-LenovoWinPEPack -Hardware $Hardware }
        default  { return $null }
    }
}

# =========================== IDEMPOTENCY ===========================
function Get-DesiredStateId {
    param($Hardware, $OEMPackage, $ExpectedDriverSetVersion)
    $oemVersion = if ($OEMPackage -and $OEMPackage.Version) { $OEMPackage.Version } else { "NONE" }
    $parts = @(
        "HW=$($Hardware.Manufacturer)|$($Hardware.Model)|$($Hardware.MachineType)",
        "OS=$($Hardware.Build)",
        "MANIFEST=$ExpectedDriverSetVersion",
        "OEMPACK=$oemVersion",
        "SCRIPT=$ScriptVersion"
    )
    $joined = $parts -join ';;'
    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($joined)
    $sha    = [System.Security.Cryptography.SHA256]::Create()
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')
}

# =========================== STATE FILE ===========================
function Read-WinREState {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$CurrentDesiredStateId)
    $empty = @{
        CurrentImageHash = $null; InjectedDriverSetVersion = $null; DesiredStateId = $null
        PendingReboot = $false; DeployedDiskNumber = $null; DeployedPartitionNumber = $null
        UsedOSFallback = $false; RepairAttempts = 0
        LastEnableResult = "ok"; EnableFailureAttempts = 0
    }
    $path = "$env:SystemDrive\Recovery\OEM\$StateFileName"
    if (-not (Test-Path $path)) { return $empty }
    try {
        $state = Get-Content $path -Raw | ConvertFrom-Json
        if ($state.DesiredStateId -eq $CurrentDesiredStateId) {
            Write-Log "State file accepted (DesiredStateId match)"
            return @{
                CurrentImageHash         = $state.CurrentImageHash
                InjectedDriverSetVersion = $state.InjectedDriverSetVersion
                DesiredStateId           = $state.DesiredStateId
                PendingReboot            = if ($state.PendingReboot) { [bool]$state.PendingReboot } else { $false }
                DeployedDiskNumber       = $state.DeployedDiskNumber
                DeployedPartitionNumber  = $state.DeployedPartitionNumber
                UsedOSFallback           = if ($state.UsedOSFallback) { [bool]$state.UsedOSFallback } else { $false }
                RepairAttempts           = if ($state.RepairAttempts) { [int]$state.RepairAttempts } else { 0 }
                LastEnableResult         = if ($state.LastEnableResult) { [string]$state.LastEnableResult } else { "ok" }
                EnableFailureAttempts    = if ($state.EnableFailureAttempts) { [int]$state.EnableFailureAttempts } else { 0 }
            }
        }
        Write-Log "State file DesiredStateId mismatch - stale" -Level WARN
        return $empty
    } catch {
        Write-Log "Failed to parse state file: $_" -Level WARN
        return $empty
    }
}

function Write-WinREState {
    param(
        [string]$Hash,
        [string]$DriverVersion,
        [Parameter(Mandatory)][AllowEmptyString()][string]$DesiredStateId,
        [bool]$PendingReboot = $false,
        [int]$DeployedDiskNumber = -1,
        [int]$DeployedPartitionNumber = -1,
        [bool]$UsedOSFallback = $false,
        [int]$RepairAttempts = 0,
        [string]$LastEnableResult = "ok",
        [int]$EnableFailureAttempts = 0
    )
    $state = @{
        DesiredStateId           = $DesiredStateId
        CurrentImageHash         = $Hash
        InjectedDriverSetVersion = $DriverVersion
        LastUpdated              = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        PendingReboot            = $PendingReboot
        UsedOSFallback           = $UsedOSFallback
        RepairAttempts           = $RepairAttempts
        LastEnableResult         = $LastEnableResult
        EnableFailureAttempts    = $EnableFailureAttempts
    }
    if ($DeployedDiskNumber -ge 0) { $state.DeployedDiskNumber = $DeployedDiskNumber }
    if ($DeployedPartitionNumber -ge 0) { $state.DeployedPartitionNumber = $DeployedPartitionNumber }

    $stateJson = $state | ConvertTo-Json -Depth 3
    $path = "$env:SystemDrive\Recovery\OEM\$StateFileName"

    # v43 patch 2: if a post-shrink failure left C: shrunken and
    # Restore-OSPartitionSize could not return it to SizeMax, do not
    # leave any state file on disk that could be accepted on a
    # subsequent run. The state file is the machine-readable "last
    # known good deployment" record. If GeometryRestoreFailed, the
    # current deployment is NOT a known-good record - C: is still
    # reduced by (bucketSizeMiB + 1) MiB. Leaving the previous state
    # file in place is not sufficient: if that file's DesiredStateId
    # happens to match the current one (which is possible when a
    # needInject trigger other than a state change fired, e.g. a WIM
    # hash mismatch at the registered location), the next run's
    # Read-WinREState accepts it, the v41 zero-partitions +
    # UsedOSFallback exemption fires, and C: stays shrunken
    # indefinitely. Deleting the state file forces the next run to
    # treat the state as absent, set needInject = $true, and re-run
    # the full-update path - which re-extends C: as part of the
    # destructive attempt and repairs the geometry if the failure
    # was transient.
    if ($Script:GeometryRestoreFailed) {
        Write-Log "Write-WinREState: OS partition geometry could not be verified after a failed destructive attempt - deleting state file so the next run retries from a clean slate" -Level WARN
        if (Test-Path $path) {
            try {
                & cmd /c "attrib -h -s -r `"$path`" 2>&1" | Out-Null
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                Write-Log "Deleted state file: $path"
            } catch {
                Write-Log "Could not delete state file $path : $_ - manual intervention may be required to force a retry" -Level ERROR
            }
        }
        return
    }

    if ($Script:DryRun) { Write-Log "[DRY RUN] Would write state file"; return }
    Write-FileAtomically -Path $path -Content $stateJson
    Write-Log "Wrote state file: $path (PendingReboot=$PendingReboot, UsedOSFallback=$UsedOSFallback, RepairAttempts=$RepairAttempts)"
}

# =========================== 7-ZIP ===========================
function Ensure-7Zip {
    if (Test-Path $7Zip) { return $true }
    Write-Log "7-Zip not found - attempting installation via winget..." -Level WARN
    $wingetPath = (Get-ChildItem -Path "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    if (-not $wingetPath) { Write-Log "Winget not found" -Level ERROR; return $false }
    try {
        $proc = Start-Process -FilePath $wingetPath -ArgumentList @('install', '--id', '7zip.7zip', '--scope', 'machine', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -eq 0 -and (Test-Path $7Zip)) { return $true }
    } catch { Write-Log "Winget error: $_" -Level ERROR }
    return (Test-Path $7Zip)
}

# =========================== DISM MOUNT ===========================
function Invoke-DismMount {
    param([string]$ImageFile, [string]$MountDir, [int]$Index = 1)
    if ($Script:DryRun) { Write-Log "[DRY RUN] Would mount $ImageFile"; return }
    Write-Log "Dismounting any WIM mounts under $WorkDir"
    try {
        Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path -like "$WorkDir\*" } |
            ForEach-Object {
                Write-Log "Discarding mounted image at $($_.Path)"
                Dismount-WindowsImage -Path $_.Path -Discard -ErrorAction SilentlyContinue
            }
    } catch { }
    if (Test-Path $MountDir) { Remove-ItemIfExist $MountDir -Recurse }
    New-DirectoryIfNotExists $MountDir
    for ($i = 1; $i -le 3; $i++) {
        try { Mount-WindowsImage -ImagePath $ImageFile -Index $Index -Path $MountDir -ErrorAction Stop; return }
        catch {
            Write-Log "Mount failed: $_" -Level WARN
            if ($i -lt 3) {
                Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
                    Where-Object { $_.Path -and $_.Path -like "$WorkDir\*" } |
                    ForEach-Object { Dismount-WindowsImage -Path $_.Path -Discard -ErrorAction SilentlyContinue }
                Start-Sleep 5
            }
        }
    }
    throw "DISM mount failed after 3 attempts"
}

# =========================== PARTITION SELECTION ===========================
function Find-SuitableRecoveryPartition {
    param([Parameter(Mandatory)][int]$RequiredWimSizeMB)

    $osDisk = Get-OSDisk
    if (-not $osDisk) { Write-Log "Find-SuitableRecoveryPartition: no OS disk" -Level WARN; return $null }

    $parts = @(Get-RecoveryPartitions -DiskNumber $osDisk.Number)
    if ($parts.Count -eq 0) { Write-Log "Find-SuitableRecoveryPartition: no recovery partitions on boot disk"; return $null }
    if ($parts.Count -gt 1) { Write-Log "Find-SuitableRecoveryPartition: multiple ($($parts.Count)) recovery partitions - will relocate"; return $null }

    $osPart = Get-OSPartition
    # v37: acceptance floor is WIM + WinREFreeSpaceMiB (250). Same standard
    # as the new-partition sizing target and the OS's own pre-update WinRE
    # check. No tolerance.
    $requiredBytes = [int64](($RequiredWimSizeMB + $WinREFreeSpaceMiB) * 1MB)

    foreach ($candidate in $parts) {
        if ($osPart -and $candidate.DiskNumber -eq $osPart.DiskNumber -and $candidate.PartitionNumber -eq $osPart.PartitionNumber) {
            Write-Log "Find-SuitableRecoveryPartition: candidate $($candidate.PartitionNumber) is the OS partition - skip"
            continue
        }
        # v31: relaxed the total-size pre-filter to match the acceptance
        # test in Test-RecoveryPartitionHasRoom. Previously the pre-filter
        # rejected any candidate smaller than (WIM + FreeSpaceBuffer) MiB
        # - 5 MiB, which was stricter than the actual acceptance test and
        # disqualified partitions the acceptance test would have passed.
        # Historical context: the v31 fix unblocked an ASUS 11th-gen
        # desktop whose 999 MiB recovery partition held a 757 MiB WIM.
        # Under v37's stricter 250 MiB free-space floor, that same
        # partition is now rejected on capacity - the pre-filter is not
        # the reason. The two thresholds are deliberately aligned at
        # (WIM + 250) MiB.
        if ($candidate.Size -lt $requiredBytes) {
            Write-Log "Find-SuitableRecoveryPartition: candidate $($candidate.PartitionNumber) total size $([math]::Round($candidate.Size/1MB,1)) MiB < required $([math]::Round($requiredBytes/1MB,1)) MiB"
            continue
        }
        # v33: reject only on confirmed encryption ($true). Unknown ($null)
        # is treated as not-BitLocker-managed, which is the normal state for
        # a recovery partition. Both Get-BitLockerVolume and manage-bde
        # legitimately return nothing useful for these volume types. If the
        # partition actually is encrypted, reagentc /enable will fail with
        # the BitLocker-specific error and the existing suspend + delete +
        # recreate path handles it. Historical context: the v33 fix
        # unblocked an ASUS 11th-gen desktop whose 999 MiB recovery
        # partition reported unknown encryption state. That same partition
        # is now rejected by the 250 MiB free-space floor introduced in
        # v37, which is the correct and deliberate outcome - the encryption
        # logic and the capacity logic are independent concerns.
        $encState = Test-RecoveryPartitionEncrypted -Partition $candidate
        if ($encState -eq $true) {
            Write-Log "Find-SuitableRecoveryPartition: candidate $($candidate.PartitionNumber) is BitLocker-encrypted" -Level WARN
            continue
        }
        if ($null -eq $encState) {
            Write-Log "Find-SuitableRecoveryPartition: candidate $($candidate.PartitionNumber) encryption state unknown - proceeding (reagentc backstop)" -Level WARN
        }

        $letter = $candidate.DriveLetter
        $assignedTemp = $false
        if (-not $letter) {
            $avail = Get-AvailableDriveLetter
            if (-not $avail) { Write-Log "Find-SuitableRecoveryPartition: no letter available" -Level WARN; return $null }
            $assignedLetter = Invoke-DriveLetterAssignment -DiskNumber $candidate.DiskNumber -PartitionNumber $candidate.PartitionNumber -PreferredLetter $avail
            if (-not $assignedLetter) {
                Write-Log "Find-SuitableRecoveryPartition: could not assign ANY letter to candidate $($candidate.PartitionNumber)" -Level ERROR
                continue
            }
            $letter = $assignedLetter
            $assignedTemp = $true
            $Script:tempDriveLetters.Add($assignedLetter)
        }

        $hasRoom = Test-RecoveryPartitionHasRoom -DiskNumber $candidate.DiskNumber -PartitionNumber $candidate.PartitionNumber -Letter $letter -RequiredBytes $requiredBytes

        if ($hasRoom) {
            Write-Log "Find-SuitableRecoveryPartition: candidate $($candidate.PartitionNumber) on disk $($candidate.DiskNumber) is suitable (letter ${letter}:)"
            return @{ DriveLetter = $letter; DiskNumber = $candidate.DiskNumber; PartitionNumber = $candidate.PartitionNumber; Partition = $candidate }
        }

        if ($assignedTemp) { Invoke-DriveLetterRemoval -Letter $letter | Out-Null }
    }
    Write-Log "Find-SuitableRecoveryPartition: no suitable candidate"
    return $null
}

# =========================== DEPLOY WIM TO PARTITION ===========================
function Deploy-WimToPartition {
    param(
        [Parameter(Mandatory)][hashtable]$Partition,
        [Parameter(Mandatory)][string]$SourceWim
    )
    $letter = $Partition.DriveLetter
    if (-not $letter) { Write-Log "Deploy-WimToPartition: partition has no letter" -Level ERROR; return $false }

    $targetDir = "${letter}:\Recovery\WindowsRE"
    $target = Join-Path $targetDir "winre.wim"

    $srcFull = $null
    try { $srcFull = [System.IO.Path]::GetFullPath($SourceWim) } catch { }
    $dstFull = $null
    try { $dstFull = [System.IO.Path]::GetFullPath($target) } catch { }
    if ($srcFull -and $dstFull -and $srcFull -eq $dstFull) {
        Write-Log "Source and target are the same file ($SourceWim) - nothing to copy"
        return $true
    }

    New-DirectoryIfNotExists $targetDir

    try {
        if (Test-Path $target) {
            $existingSize = Get-FileSizeMB -Path $target
            Write-Log "Deleting existing $target ($existingSize MiB) to free space"
            Remove-Item $target -Force -ErrorAction SilentlyContinue
            Start-Sleep 1
        }
        $srcHash = (Get-FileHash $SourceWim -Algorithm SHA256).Hash
        $srcSize = (Get-Item $SourceWim -Force).Length
        Write-Log "Copying $([math]::Round($srcSize/1MB,1)) MiB to $target"
        Copy-Item $SourceWim -Destination $target -Force
        if (-not (Test-Path $target)) { Write-Log "Copy failed: destination missing" -Level ERROR; return $false }
        $dstHash = (Get-FileHash $target -Algorithm SHA256).Hash
        if ($srcHash -ne $dstHash) { Write-Log "Copy hash mismatch" -Level ERROR; return $false }
        Write-Log "Copy verified (SHA256=$dstHash)"
        attrib $target +h +s
        return $true
    } catch {
        Write-Log "Deploy-WimToPartition failed: $_" -Level ERROR
        return $false
    }
}

# =========================== ENABLE WINRE ===========================
function Invoke-ReagentcEnable {
    param(
        [switch]$AllowTempLetter,
        [hashtable]$Partition = $null,
        [string]$ReRegisterPath = $null
    )

    # v23: ensure BitLocker is suspended before any enable attempt.
    # v43 patch 5 (further revision): fail-closed. If BitLocker on C: is
    # not confirmed unprotected, refuse to call reagentc /enable. An
    # enable against an encrypted volume fails with the BitLocker error,
    # and the caller's recovery path (suspend, delete, recreate) is
    # itself a state modification on a volume whose state we cannot
    # confirm. Return a distinct "blunsafe" result so callers can abort
    # rather than treating it as an ordinary "failed" that falls through.
    $suspended = Suspend-BitLockerForWinRE
    if (-not $suspended) {
        $blState = Test-BitLockerProtected -MountPoint "C:"
        if ($blState -ne $false) {
            $blStateText = if ($null -eq $blState) { 'unknown' } else { "$blState" }
            Write-Log "BitLocker state on C: is not confirmed unprotected (state=$blStateText) - refusing to call reagentc /enable" -Level ERROR
            return "blunsafe"
        }
        Write-Log "Suspend returned false but BitLocker is confirmed Off - proceeding with reagentc /enable" -Level WARN
    }

    # v43 patch 5 (further revision 3): DryRun must not call reagentc
    # /enable. This function previously ran it unconditionally; the
    # enable-only caller was guarded at the call site, but the
    # pending-reboot path was not, so a DryRun on a machine whose state
    # file had PendingReboot=true actually enabled WinRE. The DryRun
    # branch is placed after the BitLocker fail-closed check above so
    # an unsafe BitLocker state still returns "blunsafe" under DryRun
    # and the caller reports the deferral correctly. When BitLocker is
    # safe, the function logs the intent and returns "ok" - the closest
    # approximation of a successful live run that can be made without
    # running reagentc. Every caller's "ok" branch is DryRun-safe:
    # Remove-StrayRecoveryPartitions, Write-WinREState, and
    # Remove-ItemIfExist all handle DryRun internally.
    if ($Script:DryRun) {
        Write-Log "[DRY RUN] Would call reagentc /enable and evaluate the result (exit code, WinRE status, and the registration repair path if the status check does not confirm Enabled)"
        return "ok"
    }

    $output = cmd /c "reagentc /enable 2>&1"
    $exitCode = $LASTEXITCODE
    Write-Log "reagentc /enable (exit $exitCode): $output"

    if ($exitCode -eq 0) {
        $stateNow = Get-WinREState
        if ($stateNow.Status -eq "Enabled") {
            Write-Log "reagentc /enable: exit=0, status=Enabled -> success"
            return "ok"
        }

        Write-Log "reagentc /enable: exit=0, status=$($stateNow.Status) -> registration may be stale, attempting repair" -Level WARN

        $repaired = Invoke-ReAgentRegistrationRepair -ReRegisterPath $ReRegisterPath
        if ($repaired) { return "ok" }

        Write-Log "reagentc /enable: repair did not produce Enabled. Returning reboot-required." -Level WARN
        return "reboot"
    }

    Write-Log "reagentc /enable: exit=$exitCode -> hard failure" -Level WARN

    # v29: detect the BitLocker-specific failure. If the recovery partition
    # is BitLocker-encrypted, reagentc refuses with exit 2 and the message
    # "Windows RE cannot be enabled on a volume with BitLocker Drive
    # Encryption enabled." The caller must suspend BitLocker, delete the
    # encrypted recovery partition, and recreate it.
    if ($output -match 'cannot be enabled on a volume with BitLocker') {
        Write-Log "reagentc /enable failed because the target volume is BitLocker-protected" -Level ERROR
        return "bitlocker"
    }

    if ($AllowTempLetter -and $Partition) {
        Write-Log "Retrying with temporary drive letter assigned" -Level WARN
        $retryLetter = Get-AvailableDriveLetter
        if ($retryLetter) {
            $assignedLetter = Invoke-DriveLetterAssignment -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -PreferredLetter $retryLetter
            if ($assignedLetter) {
                $Script:tempDriveLetters.Add($assignedLetter)
                $retryOutput = cmd /c "reagentc /enable 2>&1"
                $retryExit = $LASTEXITCODE
                Write-Log "reagentc /enable retry with temp letter (exit $retryExit): $retryOutput"
                Invoke-DriveLetterRemoval -Letter $assignedLetter | Out-Null

                if ($retryExit -eq 0) {
                    $stateNow = Get-WinREState
                    if ($stateNow.Status -eq "Enabled") {
                        Write-Log "reagentc /enable retry: exit=0, status=Enabled -> success"
                        return "ok"
                    }

                    Write-Log "reagentc /enable retry: exit=0, status=$($stateNow.Status) -> attempting registration repair" -Level WARN
                    $repaired = Invoke-ReAgentRegistrationRepair -ReRegisterPath $ReRegisterPath
                    if ($repaired) { return "ok" }
                    Write-Log "reagentc /enable retry: repair failed. Returning reboot-required." -Level WARN
                    return "reboot"
                }
            }
        }
    }

    return "failed"
}

function Invoke-ReAgentRegistrationRepair {
    param([string]$ReRegisterPath)

    if (-not $ReRegisterPath) {
        Write-Log "Registration repair requested but no ReRegisterPath provided - cannot safely rebuild registration" -Level ERROR
        return $false
    }

    $reagentXml = Join-Path $env:windir "System32\Recovery\ReAgent.xml"
    $mergedXml  = Join-Path $env:windir "System32\Recovery\ReAgent_merged.xml"

    # NOTE: C:\Recovery\ReAgentOld.xml is deliberately NOT touched.
    # That file is the downlevel / servicing configuration used by Windows Setup.
    # Manual test confirmed its deletion does not resolve the issue.

    $anyDeleted = $false
    foreach ($xmlPath in @($reagentXml, $mergedXml)) {
        if (-not (Test-Path $xmlPath)) { continue }
        try {
            & cmd /c "attrib -h -s -r `"$xmlPath`" 2>&1" | Out-Null
            Remove-Item -LiteralPath $xmlPath -Force -ErrorAction Stop
            Write-Log "Deleted stale $xmlPath" -Level WARN
            $anyDeleted = $true
        } catch {
            Write-Log "Could not delete $xmlPath : $_" -Level WARN
        }
    }

    if (-not $anyDeleted) {
        Write-Log "No stale ReAgent XML found to delete - cannot perform registration repair" -Level WARN
        return $false
    }

    $reSetOutput = cmd /c "reagentc /setreimage /path `"$ReRegisterPath`" 2>&1"
    $reSetExit = $LASTEXITCODE
    Write-Log "reagentc /setreimage (repair, exit $reSetExit): $reSetOutput"
    if ($reSetExit -ne 0) {
        Write-Log "Registration repair failed at /setreimage: $reSetOutput" -Level ERROR
        return $false
    }

    $repairOutput = cmd /c "reagentc /enable 2>&1"
    $repairExit = $LASTEXITCODE
    Write-Log "reagentc /enable (repair, exit $repairExit): $repairOutput"

    if ($repairExit -ne 0) {
        Write-Log "reagentc /enable failed during registration repair (exit $repairExit)" -Level ERROR
        return $false
    }

    $stateAfter = Get-WinREState
    if ($stateAfter.Status -eq "Enabled") {
        Write-Log "WinRE registration repair succeeded - WinRE is now Enabled"
        return $true
    }

    Write-Log "WinRE still reports $($stateAfter.Status) after registration repair" -Level WARN
    return $false
}

# =========================== OEM EXTRACTION HELPERS ===========================
function Get-DownloadFileName {
    param([Parameter(Mandatory)][string]$Url, [string]$FallbackName = "oem_pack")
    try {
        $uri = [System.Uri]$Url
        $leaf = [System.IO.Path]::GetFileName($uri.LocalPath)
        if ($leaf) { return $leaf }
    } catch { }
    return $FallbackName
}

function Get-InfFileCount {
    param([Parameter(Mandatory)][string]$Directory)
    if (-not (Test-Path $Directory)) { return 0 }
    try {
        return @(Get-ChildItem -Path $Directory -Recurse -Filter "*.inf" -File -ErrorAction SilentlyContinue).Count
    } catch { return 0 }
}

function Invoke-VendorExtraction {
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$DestinationDir,
        [Parameter(Mandatory)][ValidateSet("LENOVO","HP")][string]$Vendor
    )

    if ($Script:DryRun) {
        Write-Log "[DRY RUN] Would extract $ExePath to $DestinationDir using $Vendor extractor"
        return $true
    }

    if (-not (Test-Path $ExePath)) {
        Write-Log "Invoke-VendorExtraction: executable not found: $ExePath" -Level ERROR
        return $false
    }

    New-DirectoryIfNotExists $DestinationDir | Out-Null

    # Vendor-specific switch sets.
    # Lenovo: Inno Setup based self-extractor. /VERYSILENT suppresses the
    #   "change output location" dialog; /DIR sets the destination;
    #   /SILENT and /SUPPRESSMSGBOXES suppress any remaining UI.
    # HP: Custom HP SoftPaq self-extractor. /s = silent, /e = extract
    #   without launching setup, /f = destination folder.
    $arguments = switch ($Vendor) {
        "LENOVO" { @("/VERYSILENT", "/DIR=`"$DestinationDir`"", "/SILENT", "/SUPPRESSMSGBOXES") }
        "HP"     { @("/s", "/e", "/f", "`"$DestinationDir`"") }
    }

    $argString = $arguments -join ' '
    Write-Log "Extracting $Vendor package: `"$ExePath`" $argString"

    try {
        $proc = Start-Process -FilePath $ExePath -ArgumentList $arguments -Wait -PassThru -NoNewWindow -ErrorAction Stop
        Write-Log "$Vendor extractor exit code: $($proc.ExitCode)"

        if ($proc.ExitCode -ne 0) {
            Write-Log "$Vendor extractor returned non-zero exit code $($proc.ExitCode)" -Level WARN
            # Some Lenovo packages return non-zero on success but still
            # populate the target. Check for INF files before declaring failure.
            $infCount = Get-InfFileCount -Directory $DestinationDir
            Write-Log "$Vendor extractor returned $($proc.ExitCode); INF files found: $infCount"
            if ($infCount -gt 0) {
                Write-Log "$Vendor extractor returned non-zero but produced $infCount INF file(s) - treating as success" -Level WARN
                return $true
            }
            return $false
        }

        $infCount = Get-InfFileCount -Directory $DestinationDir
        Write-Log "$Vendor extractor completed. INF files found in `"$DestinationDir`": $infCount"
        return ($infCount -gt 0)
    } catch {
        Write-Log "$Vendor extractor failed: $_" -Level ERROR
        return $false
    }
}

function Invoke-CabExtraction {
    param(
        [Parameter(Mandatory)][string]$CabPath,
        [Parameter(Mandatory)][string]$DestinationDir
    )

    if ($Script:DryRun) {
        Write-Log "[DRY RUN] Would extract CAB $CabPath to $DestinationDir"
        return $true
    }

    if (-not (Test-Path $CabPath)) {
        Write-Log "Invoke-CabExtraction: file not found: $CabPath" -Level ERROR
        return $false
    }

    New-DirectoryIfNotExists $DestinationDir | Out-Null

    if (-not (Test-Path $7Zip)) {
        Write-Log "Invoke-CabExtraction: 7-Zip not found at $7Zip" -Level ERROR
        return $false
    }

    try {
        $proc = Start-Process -FilePath $7Zip -ArgumentList @("x", "`"$CabPath`"", "-o`"$DestinationDir`"", "-y") -Wait -PassThru -NoNewWindow -ErrorAction Stop
        Write-Log "7-Zip CAB extraction exit code: $($proc.ExitCode)"
        if ($proc.ExitCode -ne 0) {
            Write-Log "7-Zip CAB extraction failed with exit code $($proc.ExitCode)" -Level WARN
            return $false
        }
        $infCount = Get-InfFileCount -Directory $DestinationDir
        Write-Log "CAB extraction completed. INF files found: $infCount"
        return ($infCount -gt 0)
    } catch {
        Write-Log "7-Zip CAB extraction failed: $_" -Level ERROR
        return $false
    }
}

# =========================== DOWNLOAD HELPERS ===========================
function Invoke-OemPackDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$ExpectedSHA256,
        [string]$ExpectedMD5,
        [int]$MaxRetries = 3
    )

    if ($Script:DryRun) {
        Write-Log "[DRY RUN] Would download $Url to $DestinationPath"
        return $true
    }

    if (Test-Path $DestinationPath) {
        Write-Log "Removing existing file before download: $DestinationPath"
        Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue
    }

    $lastException = $null
    for ($retry = 1; $retry -le $MaxRetries; $retry++) {
        Write-Log "Download attempt $retry of ${MaxRetries}: $Url"
        $requestSucceeded = $false
        try {
            Invoke-WebRequest -Uri $Url -OutFile $DestinationPath -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop
            $requestSucceeded = $true
            Write-Log "Invoke-WebRequest completed without exception (attempt $retry)"
        } catch {
            $lastException = $_
            Write-Log "Invoke-WebRequest threw exception on attempt ${retry}: $($_.Exception.Message)" -Level WARN
        }

        if (-not (Test-Path $DestinationPath)) {
            Write-Log "File not present after attempt $retry" -Level WARN
            if ($retry -lt $MaxRetries) { Start-Sleep 5 }
            continue
        }

        $fileSize = -1
        try { $fileSize = (Get-Item $DestinationPath -Force).Length } catch { }
        Write-Log "File present after attempt $retry, size: $([math]::Round($fileSize/1MB,2)) MiB"

        $hasHash = [bool]$ExpectedSHA256 -or [bool]$ExpectedMD5
        if (-not $hasHash) {
            # v32: no integrity hash supplied. Require Invoke-WebRequest
            # itself to have completed cleanly on this attempt. A partial
            # file left behind by a throwing request is not accepted.
            if ($requestSucceeded) {
                Write-Log "Download successful (no integrity hash supplied) on attempt $retry"
                return $true
            }
            Write-Log "Download not accepted: no integrity hash supplied and request did not complete cleanly - retrying" -Level WARN
            Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue
            if ($retry -lt $MaxRetries) { Start-Sleep 5 }
            continue
        }

        $hashOk = $true
        if ($ExpectedSHA256) {
            $actualSHA256 = (Get-FileHash -Path $DestinationPath -Algorithm SHA256).Hash
            Write-Log "SHA256 actual: $actualSHA256"
            Write-Log "SHA256 expected: $ExpectedSHA256"
            if ($actualSHA256.ToUpperInvariant() -ne $ExpectedSHA256.ToUpperInvariant()) {
                Write-Log "SHA256 mismatch" -Level WARN
                $hashOk = $false
            } else {
                Write-Log "SHA256 verified"
            }
        }
        if ($hashOk -and $ExpectedMD5) {
            $actualMD5 = (Get-FileHash -Path $DestinationPath -Algorithm MD5).Hash
            Write-Log "MD5 actual: $actualMD5"
            Write-Log "MD5 expected: $ExpectedMD5"
            if ($actualMD5.ToUpperInvariant() -ne $ExpectedMD5.ToUpperInvariant()) {
                Write-Log "MD5 mismatch" -Level WARN
                $hashOk = $false
            } else {
                Write-Log "MD5 verified"
            }
        }

        if ($hashOk) {
            Write-Log "Download successful (hash verified) on attempt $retry"
            return $true
        }

        Write-Log "Hash verification failed on attempt $retry - removing file and retrying" -Level WARN
        Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue
        if ($retry -lt $MaxRetries) { Start-Sleep 5 }
    }

    if ($lastException) {
        Write-Log "Download failed after $MaxRetries attempts. Last exception: $($lastException.Exception.Message)" -Level ERROR
    } else {
        Write-Log "Download failed after $MaxRetries attempts (hash verification never passed)" -Level ERROR
    }
    return $false
}

# =========================== MAIN ===========================
try {
    New-DirectoryIfNotExists $LogDir
    Write-Log "========== WinRE Manager Started (v$ScriptVersion) =========="
    if ($Script:DryRun) { Write-Log "*** DRY RUN MODE ***" }

    # v43 patch 5 (Audit Mode guard, enable-failure counter): Audit Mode /
    # OOBE / specialize / generalize guard. In these transitional Windows
    # states, reagentc /enable fails with ERROR_CANCELLED (0x4c7, 1223)
    # regardless of the correctness of the deployed WIM or the state of the
    # recovery partition. Confirmed field case: a Dell Latitude 5530 running
    # in Audit Mode. After the user completed OOBE, reagentc /enable
    # succeeded on the first attempt with the same WIM. Without this guard,
    # the script deploys successfully, fails at /enable, writes a state file
    # recording the deployment as complete, and then loops on every
    # subsequent run (the state file matches, no rebuild is triggered, and
    # the enable-only path retries /enable forever).
    #
    # Predicate: read
    #   HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State
    #     -> ImageState (string)
    # Proceed only when ImageState is absent (some SKUs may not have the
    # key) or exactly IMAGE_STATE_COMPLETE. Any other value defers. The
    # predicate is deliberately conservative: it does not depend on knowing
    # the exact value that Audit Mode writes. If a legitimate running state
    # reports a value other than IMAGE_STATE_COMPLETE, add it to the
    # whitelist below.
    #
    # Runs under -DryRun: logs "Would defer" and continues.
    $imageStatePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State"
    $imageState = $null
    try {
        $imageState = (Get-ItemProperty -Path $imageStatePath -Name ImageState -ErrorAction SilentlyContinue).ImageState
    } catch { }
    if ($imageState -and $imageState -ne "IMAGE_STATE_COMPLETE") {
        $auditVerb = if ($Script:DryRun) { "Would defer" } else { "Deferring" }
        Write-Log "$auditVerb WinRE Manager: Windows is not in a normal-running state (Setup\State\ImageState=$imageState). reagentc /enable is blocked with 0x4c7 during Audit Mode, OOBE, and the sysprep generalize/specialize phases regardless of WIM correctness. No WinRE or partition changes will be made." -Level WARN
        Write-Log "Complete OOBE, sign in to a normal desktop session, and re-run this script." -Level WARN
        if (-not $Script:DryRun) {
            exit $EXIT_WARNING
        }
    }

    $Hardware = Get-HardwareObject
    Write-Log "System: $($Hardware.Manufacturer) $($Hardware.Model), MT=$($Hardware.MachineType), OS=$($Hardware.WinPE) (build $($Hardware.Build))"

    $manifest = $null
    for ($retry = 1; $retry -le 3; $retry++) {
        try { $manifest = Invoke-RestMethod -Uri $DriverManifestUrl -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop; break }
        catch { if ($retry -eq 3) { throw } }
        Start-Sleep 5
    }
    if (-not $manifest -or -not $manifest.version) { throw "Driver manifest invalid." }
    $ExpectedDriverSetVersion = $manifest.version

    $OEMPackage = Get-OEMWinPEPack -Hardware $Hardware

    # v42: Get-OEMWinPEPack returns $null both for unsupported vendors
    # and for supported vendors whose pack did not resolve. The v42 fix
    # marked every such run as incomplete so state was not written as if
    # OEM injection had been performed. That was correct for Dell and HP
    # (single-pack maps resolved by OS family or a fixed key; a $null
    # return always means the map failed to load - transient) and for a
    # Lenovo map that failed to download. It was wrong for the common
    # Lenovo case where the map loaded successfully and simply has no
    # entry for this machine type: many Lenovo models have no published
    # WinPE driver pack, and the absence is permanent, not transient.
    # Marking the run incomplete in that case prevented the state file
    # from ever being written, forcing the full-update path (WIM
    # download, mount, inject, export, deploy) on every scheduled run
    # forever, with EXIT_WARNING on every run.
    #
    # v43 patch 5 (further revision 4): distinguish "map loaded, no entry
    # for this model" (expected and permanent for Lenovo) from "map
    # failed to load" (transient). For the expected case, proceed as if
    # the OEM pack were legitimately resolved to NONE: the state file is
    # written with OEMPACK=NONE in the DesiredStateId, and the fast path
    # fires on subsequent runs. If Lenovo later publishes a pack for this
    # MT, the DesiredStateId changes (OEMPACK goes from NONE to the
    # version) and the machine rebuilds automatically.
    #
    # Dell and HP keep the v42 behaviour unconditionally. Their maps are
    # single-pack (Dell resolved by WinPE family, HP by a fixed key), so
    # a $null return can only mean the map failed to load or its entry is
    # malformed. Both are transient; the run is marked incomplete and
    # retried.
    $oemVendorSupported = $Hardware.Manufacturer -in @("Dell", "HP", "LENOVO")
    if ($oemVendorSupported -and -not $OEMPackage) {
        $mapLoadedNoEntry = ($Hardware.Manufacturer -eq "LENOVO" -and $Script:LenovoWinPEMap)
        if ($mapLoadedNoEntry) {
            Write-Log "LENOVO machine type $($Hardware.MachineType) has no published WinPE driver pack in the loaded map - OEM driver injection will be skipped. The run is recorded as complete with OEMPACK=NONE; if Lenovo publishes a pack for this model later, the DesiredStateId will change and the machine will rebuild." -Level INFO
        } else {
            Write-Log "$($Hardware.Manufacturer) is a supported vendor but no OEM WinPE pack could be resolved (map fetch failed or no matching entry) - OEM driver injection will be skipped" -Level WARN
            $Script:nonFatalWarning = $true
            $Script:ImageInjectionComplete = $false
        }
    }

    $DesiredStateId = Get-DesiredStateId -Hardware $Hardware -OEMPackage $OEMPackage -ExpectedDriverSetVersion $ExpectedDriverSetVersion
    Write-Log "DesiredStateId: $DesiredStateId"

    $cp = Get-Checkpoint -CheckpointFile $CheckpointFile -CurrentDesiredStateId $DesiredStateId
    $step = $cp.Step
    if (-not $cp.Valid) { Write-Log "Checkpoint invalidated - wiping WorkDir"; Remove-ItemIfExist $WorkDir -Recurse }
    Write-Log "Checkpoint step: $step"
    New-DirectoryIfNotExists $WorkDir
    if ($step -ge 2 -and -not (Test-Path "$WorkDir\base.wim")) { $step = 1 }
    if ($step -ge 4 -and -not (Test-Path "$WorkDir\winre_optimized.wim")) { $step = 4 }

    Get-Volume | Where-Object { $_.FileSystemLabel -eq "Recovery" -or $_.FileSystemLabel -eq "WINRE" } | ForEach-Object {
        if ($_.DriveLetter) {
            $part = Get-Partition -Volume $_ -ErrorAction SilentlyContinue
            if ($part -and -not $part.IsBoot -and -not $part.IsSystem -and -not (Test-Path "$($_.DriveLetter):\Windows")) {
                if (-not $Script:DryRun) {
                    if (-not $Script:tempDriveLetters.Contains($_.DriveLetter)) { $Script:tempDriveLetters.Add($_.DriveLetter) }
                    Invoke-DriveLetterRemoval -Letter $_.DriveLetter | Out-Null
                }
            }
        }
    }

    $WinREState = Get-WinREState
    Write-Log "WinRE status: $($WinREState.Status), Location: $($WinREState.Location)"

    # v43 patch 5 (further revision 2): startup BitLocker gate. Defer
    # BEFORE any state-modifying action when the OS volume is in a state
    # we cannot confirm safe. Runs after Get-WinREState so the log records
    # the WinRE state first, and before the pending-reboot block and the
    # full-update path so no partition or registration is touched.
    #
    # Changes in this revision:
    #   - If Get-BitLockerVolume returns null, the gate now falls back to
    #     Test-BitLockerProtected, which itself falls back to manage-bde
    #     -status text parsing. An unknown state is deferred rather than
    #     silently allowed through. Previously a null return caused the
    #     entire gate to be skipped, so a healthy-looking fast path could
    #     exit 0 on a machine whose BitLocker state was unknown.
    #     To avoid a false positive on machines where BitLocker is not
    #     present at all (Home SKU, or feature not installed), the gate
    #     checks for the manage-bde tooling before treating a null as
    #     "state unknown". If the tooling is absent, the gate is a no-op
    #     and logs that fact.
    #   - The gate now runs under -DryRun as well. In DryRun it logs the
    #     hazard and continues; it does not exit. This makes a preflight
    #     of an idempotent-but-unsafe machine report the state instead of
    #     exiting 0 without a warning. The DryRun path modifies nothing.
    #   - A valid checkpoint file is preserved on deferral. The gate no
    #     longer removes it. Deferring on BitLocker state does not
    #     invalidate any resumable step; steps 1-4 do not depend on
    #     BitLocker and the existing step guards handle resumption
    #     correctly. Removing the checkpoint would force a full
    #     re-download and re-injection on the next run for no benefit.
    #
    # The gate deliberately does NOT defer on ProtectionStatus=On with a
    # mid-operation VolumeStatus. That is a policy decision documented in
    # docs/architecture.md: protection being On is the factor that
    # matters, the script suspends protection before the destructive
    # work, and New-Partition applies the recovery type GUID at creation
    # so the encryption service has no window to claim the new partition.
    # Only when the classifier cannot confirm protection On does this
    # gate defer.
    $startupDeferReason = $null
    $startupDeferDetail = $null
    $startupBlv = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
    if ($startupBlv) {
        $startupProt    = $startupBlv.ProtectionStatus
        $startupVs      = [string]$startupBlv.VolumeStatus
        $startupProtOn  = ($startupProt -eq 'On' -or $startupProt -eq 'ProtectionOn' -or $startupProt -eq 1)
        $startupProtOff = ($startupProt -eq 'Off' -or $startupProt -eq 'ProtectionOff' -or $startupProt -eq 0)
        $startupVsSafe  = (-not $startupVs -or $startupVs -eq 'FullyDecrypted')
        if (-not $startupProtOn) {
            if ($startupProtOff) {
                if (-not $startupVsSafe) {
                    if ($startupVs -eq 'FullyEncrypted') {
                        $startupDeferReason = "ProtectionStatus=Off with VolumeStatus=FullyEncrypted"
                        $startupDeferDetail = "this state is ambiguous (could be a legitimate suspension, or Device Encryption in Waiting-for-Activation). Only FullyDecrypted or an empty VolumeStatus is confirmed-safe."
                    } else {
                        $startupDeferReason = "ProtectionStatus=Off with VolumeStatus=$startupVs"
                        $startupDeferDetail = "Device Encryption may be actively encrypting or decrypting the OS volume."
                    }
                }
            } else {
                $startupDeferReason = "ProtectionStatus=$startupProt is neither On nor Off"
                $startupDeferDetail = "the protection state cannot be confirmed safe."
            }
        }
    } else {
        # Get-BitLockerVolume returned null. Distinguish "BitLocker is not
        # present on this machine" (nothing to check, proceed) from
        # "BitLocker is present but the cmdlet returned null for C:"
        # (cannot confirm safe, defer). The presence of manage-bde.exe is
        # a reliable indicator of whether the BitLocker feature is
        # installed at all.
        $blPresent = Test-Path "$env:SystemRoot\System32\manage-bde.exe"
        if ($blPresent) {
            $startupClass = Test-BitLockerProtected -MountPoint "C:"
            if ($null -eq $startupClass) {
                $startupDeferReason = "state could not be determined"
                $startupDeferDetail = "BitLocker is present but Get-BitLockerVolume returned null and the manage-bde fallback did not confirm a safe state."
            }
        } else {
            Write-Log "BitLocker tooling is not present on this machine - startup gate not applicable" -Level INFO
        }
    }
    if ($startupDeferReason) {
        $startupVerb = if ($Script:DryRun) { "Would defer" } else { "Deferring" }
        Write-Log "$startupVerb WinRE Manager: BitLocker on C: $startupDeferReason - $startupDeferDetail No WinRE or partition changes will be made." -Level WARN
        Write-Log "Resolve by ensuring manage-bde -status C: shows one of: Protection Status: Protection On (any conversion status), or Protection Status: Protection Off with Conversion Status: Fully Decrypted. Then re-run." -Level WARN
        if (-not $Script:DryRun) {
            exit $EXIT_WARNING
        }
    }

    $state = Read-WinREState -CurrentDesiredStateId $DesiredStateId
    $storedHash = $state.CurrentImageHash
    $storedDriverVersion = $state.InjectedDriverSetVersion

    if ($state.PendingReboot -eq $true -and $state.DesiredStateId -eq $DesiredStateId) {
        if ($WinREState.Status -eq "Enabled") {
            Write-Log "Previous run's pending reboot completed - WinRE is now Enabled"
        } else {
            $repairAttempts = $state.RepairAttempts + 1
            if ($repairAttempts -gt 3) {
                Write-Log "WinRE registration repair has failed $($state.RepairAttempts) times without resolving WinRE state. Manual intervention required." -Level ERROR
                Remove-ItemIfExist $CheckpointFile
                exit $EXIT_FATAL
            }

            Write-Log "Previous run reported reboot required; WinRE still reports $($WinREState.Status). Repair attempt $repairAttempts of 3." -Level WARN

            $pendingPath = $null
            $pendingPartition = $null
            if ($state.UsedOSFallback) {
                $pendingPath = "$env:SystemDrive\Recovery\WindowsRE"
            }
            elseif ($state.DeployedDiskNumber -ne $null -and $state.DeployedPartitionNumber -ne $null) {
                $pendingPath = "\\?\GLOBALROOT\device\harddisk$($state.DeployedDiskNumber)\partition$($state.DeployedPartitionNumber)\Recovery\WindowsRE"
                $pendingPartition = @{
                    DiskNumber      = [int]$state.DeployedDiskNumber
                    PartitionNumber = [int]$state.DeployedPartitionNumber
                }
            }

            if ($pendingPath) {
                $pendingResult = $null
                if ($pendingPartition) {
                    $pendingResult = Invoke-ReagentcEnable -AllowTempLetter -Partition $pendingPartition -ReRegisterPath $pendingPath
                } else {
                    $pendingResult = Invoke-ReagentcEnable -ReRegisterPath $pendingPath
                }

                if ($pendingResult -eq "blunsafe") {
                    Write-Log "Pending-reboot path refused: BitLocker on C: not confirmed safe - exiting with warning" -Level WARN
                    $Script:nonFatalWarning = $true
                    Remove-ItemIfExist $CheckpointFile
                    exit $EXIT_WARNING
                }
                if ($pendingResult -eq "ok") {
                    if ($Script:DryRun) {
                        Write-Log "[DRY RUN] Would report the pending-reboot repair as succeeded and exit with EXIT_SUCCESS"
                    } else {
                        Write-Log "Registration repair succeeded after pending-reboot retry"
                    }
                    # v43 patch 3: enforce the invariant on the pending-reboot
                    # success exit. This path also bypasses Step 7. See the
                    # enable-only block for rationale.
                    $osDiskForStray = Get-OSDisk
                    if ($osDiskForStray) {
                        Remove-StrayRecoveryPartitions -OSDiskNumber $osDiskForStray.Number | Out-Null
                    } else {
                        Write-Log "Pending-reboot repair: could not determine OS disk for stray-recovery cleanup" -Level WARN
                        $Script:nonFatalWarning = $true
                    }
                    $deployedDisk = if ($pendingPartition) { $pendingPartition.DiskNumber } else { -1 }
                    $deployedPart = if ($pendingPartition) { $pendingPartition.PartitionNumber } else { -1 }
                    Write-WinREState -Hash $storedHash -DriverVersion $storedDriverVersion -DesiredStateId $DesiredStateId `
                                     -PendingReboot $false `
                                     -DeployedDiskNumber $deployedDisk `
                                     -DeployedPartitionNumber $deployedPart `
                                     -UsedOSFallback $state.UsedOSFallback `
                                     -RepairAttempts 0
                    Remove-ItemIfExist $CheckpointFile
                    if ($state.UsedOSFallback) { exit $EXIT_WARNING }
                    if ($Script:nonFatalWarning) { exit $EXIT_WARNING }
                    exit $EXIT_SUCCESS
                }
            }

            Write-Log "WinRE remains Disabled after pending-reboot repair attempt $repairAttempts of 3." -Level WARN
            # v43 patch 3: enforce the invariant on the reboot-required exit
            # as well. The machine is about to reboot, and the next run may
            # or may not succeed at the repair; cleanup runs now so the
            # invariant is not deferred indefinitely if the loop continues.
            $osDiskForStray = Get-OSDisk
            if ($osDiskForStray) {
                Remove-StrayRecoveryPartitions -OSDiskNumber $osDiskForStray.Number | Out-Null
            } else {
                Write-Log "Pending-reboot reboot-required: could not determine OS disk for stray-recovery cleanup" -Level WARN
                $Script:nonFatalWarning = $true
            }
            $deployedDisk = if ($pendingPartition) { $pendingPartition.DiskNumber } else { -1 }
            $deployedPart = if ($pendingPartition) { $pendingPartition.PartitionNumber } else { -1 }
            Write-WinREState -Hash $storedHash -DriverVersion $storedDriverVersion -DesiredStateId $DesiredStateId `
                             -PendingReboot $true `
                             -DeployedDiskNumber $deployedDisk `
                             -DeployedPartitionNumber $deployedPart `
                             -UsedOSFallback $state.UsedOSFallback `
                             -RepairAttempts $repairAttempts
            Remove-ItemIfExist $CheckpointFile
            Write-Log "========== WinRE Manager completed - reboot still required =========="
            exit $EXIT_REBOOT_REQUIRED
        }
    }

    # v43 patch 5 (enable-failure counter): loop breaker. When the
    # deployment is current but reagentc /enable has failed on the last 3
    # or more runs and WinRE is still Disabled, do not keep retrying
    # silently. Exit EXIT_FATAL with an actionable message. The state file
    # is left in place so the operator can inspect it; the message tells
    # them how to clear the counter if the underlying cause has been
    # resolved. Classic cause: a machine stuck in Audit Mode, where
    # /enable returns 0x4c7 regardless of WIM correctness. The Audit Mode
    # startup guard above now defers before any work is attempted, but
    # this counter protects against the same failure mode arising from
    # any other source.
    if ($state.EnableFailureAttempts -ge 3 -and $state.LastEnableResult -eq "failed" -and $WinREState.Status -ne "Enabled") {
        $loopVerb = if ($Script:DryRun) { "Would refuse to retry" } else { "Refusing to retry" }
        $loopStatePath = "$env:SystemDrive\Recovery\OEM\$StateFileName"
        Write-Log "$loopVerb reagentc /enable: it has failed on the last $($state.EnableFailureAttempts) consecutive runs and WinRE is still Disabled. Manual intervention is required." -Level ERROR
        Write-Log "Verify the machine has completed OOBE and is not in Audit Mode. To reset the failure counter, delete ${loopStatePath} and re-run." -Level ERROR
        if (-not $Script:DryRun) {
            Remove-ItemIfExist $CheckpointFile
            exit $EXIT_FATAL
        }
    }

    $ActiveLocationImage = $null
    $ActiveLocationHash = $null
    # v42: track separately whether the reagentc-registered location
    # actually contained a WIM. Without this, the fallback search below
    # can substitute C:\Recovery\WindowsRE\winre.wim as the effective
    # active image, and the idempotency check will then compare the
    # fallback hash against the stored hash and conclude the machine is
    # healthy even when the registered location has no usable image.
    # $ActiveLocationWimPresent being false while WinRE is registered on
    # a recovery partition is treated below as a forced rebuild.
    $ActiveLocationWimPresent = $false

    if ($WinREState.Location) {
        $tempLocation = @(Ensure-RecoveryPartitionAccess -TargetDir $WinREState.Location)[0]
        if ($tempLocation) {
            foreach ($cand in @(Join-Path $tempLocation "Recovery\WindowsRE\winre.wim"; Join-Path $tempLocation "winre.wim")) {
                if (Test-Path -Path $cand -PathType Leaf) {
                    # v43 patch 2 change #2: ActiveLocationWimPresent must mean "present AND
                    # readable". Test-Path alone accepts a file whose hash
                    # computation fails (corruption, ACL, lock), which
                    # would defeat the v42 forced-rebuild check below -
                    # the check would see the flag as true, assume the
                    # registered location is healthy, and let the fast
                    # path report DEDICATED with an unusable WIM at the
                    # reagentc-registered path. Only set the flag after
                    # Get-LiveWimHash succeeds; otherwise continue to the
                    # next candidate.
                    $candidateHash = Get-LiveWimHash -WimPath $cand
                    if ($candidateHash) {
                        $ActiveLocationImage = $cand
                        $ActiveLocationHash = $candidateHash
                        $ActiveLocationWimPresent = $true
                        break
                    } else {
                        Write-Log "WinRE location candidate exists but is not readable: $cand - continuing search" -Level WARN
                    }
                }
            }
        }
    }

    $FallbackImage = $null
    if (-not $ActiveLocationImage) {
        foreach ($path in @("C:\Windows\System32\Recovery\Winre.wim", "C:\Recovery\WindowsRE\winre.wim")) {
            if (Test-Path -Path $path -PathType Leaf) { $FallbackImage = $path; break }
        }
        if (-not $FallbackImage) {
            $recoveryVolumes = Get-Volume | Where-Object { $_.FileSystemLabel -eq "Recovery" -or $_.FileSystemLabel -eq "WINRE" }
            foreach ($vol in $recoveryVolumes) {
                if ($vol.DriveLetter) {
                    $p = "$($vol.DriveLetter):\Recovery\WindowsRE\winre.wim"
                    if (Test-Path $p) { $FallbackImage = $p; break }
                } else {
                    $part = Get-Partition -Volume $vol -ErrorAction SilentlyContinue
                    if ($part) {
                        $l = Get-AvailableDriveLetter
                        if ($l) {
                            $assignedLetter = Invoke-DriveLetterAssignment -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -PreferredLetter $l
                            if ($assignedLetter) {
                                $Script:tempDriveLetters.Add($assignedLetter)
                                $p = "${assignedLetter}:\Recovery\WindowsRE\winre.wim"
                                if (Test-Path $p) { $FallbackImage = $p; break }
                            }
                        }
                    }
                }
            }
        }
    }
    if (-not $ActiveLocationHash -and $FallbackImage) {
        $ActiveLocationHash = Get-LiveWimHash -WimPath $FallbackImage
        if ($ActiveLocationHash) { $ActiveLocationImage = $FallbackImage }
    }

    $forceUpgrade = $false
    $imageToCheck = if ($ActiveLocationImage) { $ActiveLocationImage } else { $FallbackImage }
    if ($imageToCheck) {
        $wimBuild = Get-WimBuild -WimPath $imageToCheck
        if ($wimBuild) {
            if ($Hardware.IsWin10 -and $wimBuild -ge 22000) { $forceUpgrade = $true }
            elseif ($Hardware.IsWin11 -and $wimBuild -lt 22000) { $forceUpgrade = $true }
        }
    }

    $vmdIds = $manifest.drivers | Where-Object { $_.match.requiredDevices } | ForEach-Object { $_.match.requiredDevices }
    $vmdPresent = $false
    if ($vmdIds) {
        $pattern = ($vmdIds | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $vmdPresent = (Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match $pattern }).Count -gt 0
    }
    Write-Log "VMD hardware present: $vmdPresent"
    $requiredDrivers = @()
    foreach ($drv in $manifest.drivers) {
        $osMatch = ($Hardware.IsWin10 -and $drv.os -contains "Win10") -or ($Hardware.IsWin11 -and $drv.os -contains "Win11")
        $genOk = ($Hardware.CPUGeneration -ge $drv.match.cpuGenMin) -and ($Hardware.CPUGeneration -le $drv.match.cpuGenMax)
        if ($drv.match.requiredDevices -and -not $vmdPresent) { Write-Log "Skipping $($drv.name): no matching VMD hardware detected"; continue }
        if ($osMatch -and $Hardware.CPUVendor -eq "Intel" -and $genOk) { $requiredDrivers += $drv }
    }
    Write-Log "Required drivers (VMD): $($requiredDrivers.Count)"

    $needInject = $false
    if ($forceUpgrade) { $needInject = $true; Write-Log "OS upgrade detected - forcing WIM rebuild" }
    elseif ($storedHash -and $ActiveLocationHash -and $ActiveLocationHash -ne $storedHash) { $needInject = $true; Write-Log "Active WIM hash differs from stored - rebuilding" }
    elseif ($storedDriverVersion -and $storedDriverVersion -ne $ExpectedDriverSetVersion) { $needInject = $true; Write-Log "Driver version changed - rebuilding" }
    elseif (-not $storedHash -or -not $storedDriverVersion) { $needInject = $true; Write-Log "No valid state (missing or stale) - rebuilding" }

    # v43: if no WIM can be found anywhere (neither at the reagentc-
    # registered location nor as a fallback), there is no source for the
    # deployment step. Force a full rebuild so step 2 obtains a fresh WIM
    # from GitHub. Without this, a machine whose state file matches but
    # whose actual WIM files are missing would enter the full-update path
    # with needInject=false and die at "Could not determine WIM size".
    if (-not $needInject -and -not $ActiveLocationImage -and -not $FallbackImage) {
        Write-Log "No active or fallback WinRE image found - forcing rebuild" -Level WARN
        $needInject = $true
    }

    $osDisk = Get-OSDisk
    $existingRecoveryParts = @( if ($osDisk) { @(Get-RecoveryPartitions -DiskNumber $osDisk.Number) } else { @() } )

    # v25: resolve the WinRE location partition ONCE and use it for both
    # recovery and OS-fallback classification. Handles harddiskX\partitionY
    # and \\?\Volume{GUID} forms uniformly.
    $activePart = $null
    if ($WinREState.Location) {
        $activePart = Resolve-WinRELocationToPartition -Location $WinREState.Location
    }

    $activeOnRecovery = $false
    $activeOnOSFallback = $false

    if ($activePart) {
        $isRec = ($activePart.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}') -or ($activePart.MbrType -eq 0x27)
        if (-not $isRec) {
            $vol = Get-Volume -Partition $activePart -ErrorAction SilentlyContinue
            if ($vol -and ($vol.FileSystemLabel -eq 'Recovery' -or $vol.FileSystemLabel -eq 'WINRE')) { $isRec = $true }
        }

        $osPartCheck = Get-OSPartition
        $isActiveOSPart = ($osPartCheck -and
                           $activePart.DiskNumber -eq $osPartCheck.DiskNumber -and
                           $activePart.PartitionNumber -eq $osPartCheck.PartitionNumber)
        # v43 patch 2 change #1: activeOnRecovery must additionally require the active
        # partition to be on the OS disk. Without this, a machine whose
        # reagentc registration points at a recovery partition on a
        # secondary disk and whose OS disk also has exactly one recovery
        # partition takes the idempotent fast path (nothingToDo=true) and
        # then lets Remove-StrayRecoveryPartitions delete the very
        # partition reagentc is registered to, exiting "success" with
        # WinRE effectively broken. Requiring OS-disk membership means
        # that state falls through to the full-update path, which
        # deploys the WIM to the OS disk, re-registers reagentc, and only
        # then lets Step 7 remove the stray secondary-disk partition.
        $isActiveOSDisk = ($osPartCheck -and
                           $activePart.DiskNumber -eq $osPartCheck.DiskNumber)

        if ($isActiveOSPart) {
            $activeOnOSFallback = $true
        } elseif ($isRec -and $isActiveOSDisk) {
            $activeOnRecovery = $true
        }
    }

    # v42: if WinRE is registered on a recovery partition but no WIM could
    # be read at that location, the fallback WIM substitution above may
    # have made the hash comparison in the $needInject calculation
    # silently succeed. Force a rebuild so the full-update path repairs
    # the registered location rather than reporting DEDICATED based on a
    # fallback image that is not actually where reagentc is pointing.
    if ($activeOnRecovery -and -not $ActiveLocationWimPresent -and $WinREState.Status -eq "Enabled") {
        Write-Log "WinRE is registered on recovery partition $($activePart.DiskNumber)/$($activePart.PartitionNumber) but its winre.wim could not be read at that location - forcing rebuild" -Level WARN
        $needInject = $true
    }

    $nothingToDo = $false
    if (-not $needInject -and $WinREState.Status -eq "Enabled") {
        if ($existingRecoveryParts.Count -ne 1) {
            # v41: exactly one recovery partition is the ideal end state.
            # Anything else (zero, or multiple) is a state the idempotent
            # path used to accept as long as WinRE was enabled somewhere
            # plausible, which meant stray partitions accumulated
            # indefinitely and a machine with no recovery partition at all
            # could never recover. Force $needInject so the full-update
            # path runs; Ensure-AdequateRecoveryPartition will then delete
            # every recovery partition on the boot disk (zero or many) and
            # create exactly one correctly sized replacement.
            #
            # Setting $needInject = $true also ensures that step 2 copies
            # the current WIM into WorkDir before any partition is deleted,
            # which keeps $SourceWim valid after the source partition is
            # gone. Without this, a machine with $needInject = $false would
            # reach the deploy step with $SourceWim pointing into a deleted
            # partition.
            #
            # v41: exempt the "zero recovery partitions AND the state
            # file records OS-fallback for this DesiredStateId" case. That
            # combination means a previous run already attempted dedicated
            # recovery for this exact state, the shrink failed, and the
            # script deliberately ended in OS-fallback. Forcing a rebuild
            # here would defeat the DesiredStateId-scoped retry policy and
            # re-run the full destructive attempt (WIM rebuild, delete,
            # extend, shrink, defrag, fail) on every subsequent run with
            # the same state. Preserve the idempotent OS-fallback outcome
            # instead. A state change (script version bump, manifest
            # update, hardware change) naturally re-arms the retry.
            # v43 patch 2 change #4: additionally require that the currently-active WinRE
            # location is actually on the OS partition. Without this, a
            # machine whose state file records UsedOSFallback but whose
            # reagentc registration actually points at a secondary-disk
            # recovery partition (an inconsistent state that Windows
            # updates or manual reagentc operations can produce) would
            # take the idempotent fast path, then have the fast-path
            # cleanup delete that secondary partition. Requiring
            # $activeOnOSFallback forces the full-update path in that
            # case, which re-registers reagentc to the correct location
            # before any deletion happens.
            if ($existingRecoveryParts.Count -eq 0 -and $state.UsedOSFallback -eq $true -and $activeOnOSFallback) {
                Write-Log "No recovery partition and state records OS-fallback for this DesiredStateId - preserving idempotent OS-fallback"
                $Script:UsedOSFallback = $true
                $nothingToDo = $true
            } else {
                if ($existingRecoveryParts.Count -gt 1) {
                    Write-Log "Multiple ($($existingRecoveryParts.Count)) recovery partitions on boot disk - scheduling cleanup and consolidation"
                } else {
                    Write-Log "No recovery partition on boot disk - scheduling dedicated partition creation"
                }
                $needInject = $true
            }
        } elseif ($activeOnRecovery -and $activePart) {
            if (-not $activePart.DriveLetter) {
                $nothingToDo = $true
            } else {
                Write-Log "Removing temporary drive letter $($activePart.DriveLetter): (assigned for inspection)"
                if (-not $Script:tempDriveLetters.Contains($activePart.DriveLetter)) { $Script:tempDriveLetters.Add($activePart.DriveLetter) }
                if (-not $Script:DryRun) { Invoke-DriveLetterRemoval -Letter $activePart.DriveLetter | Out-Null }
                $nothingToDo = $true
            }
        } elseif ($activeOnOSFallback) {
            Write-Log "WinRE is enabled via OS-fallback (location: $($WinREState.Location))"
            $Script:UsedOSFallback = $true
            $nothingToDo = $true
        }
    }

    # v43 patch 4 migration (revised): the checkpoint may have advanced
    # past step 3 in a prior run that failed injection but left a
    # valid (pre-existing) state file on disk. The guard at the state
    # read cannot catch that case because $storedHash is non-null
    # there. By this point $needInject has been fully determined and
    # captures the actual "must reinject" condition (active WIM
    # mismatch, driver version change, forced upgrade, or no valid
    # state). If a checkpoint at step >= 4 is present while $needInject
    # is true, the step guards skip step 3 ($step -le 3 is false for
    # $step >= 4) and the un-injected WIM is deployed and committed
    # with a fresh $Script:ImageInjectionComplete = $true. Reset to
    # step 2 so step 3 runs and injection is retried. $step of 3 or
    # less already runs step 3, so no reset is needed there.
    if ($step -ge 4 -and $needInject) {
        Write-Log "Checkpoint step $step cannot be trusted while a rebuild is required - resetting to step 2 to retry injection (v43 patch 4 migration)" -Level WARN
        $step = 2
    }

    if ($nothingToDo) {
        if ($Script:UsedOSFallback) {
            Write-Log "Operating mode: OS-FALLBACK (degraded - WinRE is on the OS partition)"
        } else {
            Write-Log "Operating mode: DEDICATED (WinRE on dedicated recovery partition)"
        }
        Remove-ItemIfExist $CheckpointFile

        # Enforce the "no type-coded recovery partition on any non-OS
        # disk" invariant on the idempotent fast path. Step 7 previously
        # ran only on the full-update path, so a stray partition that
        # appeared after the last full run (e.g. a USB-attached device
        # carrying an old recovery partition) would survive indefinitely
        # as long as the machine's WinRE state stayed idempotent. This is
        # a read-only scan when no strays exist (the common case), and it
        # deletes any strays it finds. A deletion failure sets
        # $Script:nonFatalWarning, which the exit-code block below honours.
        if ($osDisk) {
            Remove-StrayRecoveryPartitions -OSDiskNumber $osDisk.Number | Out-Null
        }

        if ($state.PendingReboot -eq $true -or $state.RepairAttempts -gt 0 -or $state.EnableFailureAttempts -gt 0 -or $state.LastEnableResult -ne "ok") {
            Write-Log "Clearing stale PendingReboot / RepairAttempts / enable-failure counters in state file"
            Write-WinREState -Hash $storedHash -DriverVersion $storedDriverVersion -DesiredStateId $DesiredStateId `
                             -PendingReboot $false -UsedOSFallback $Script:UsedOSFallback `
                             -DeployedDiskNumber $state.DeployedDiskNumber -DeployedPartitionNumber $state.DeployedPartitionNumber `
                             -RepairAttempts 0
        }
        if ($Script:UsedOSFallback) { exit $EXIT_WARNING }
        if ($Script:nonFatalWarning) { exit $EXIT_WARNING }
        exit $EXIT_SUCCESS
    }

    # ============ ENABLE-ONLY PATH ============
    $needEnableOnly = (-not $needInject -and $WinREState.Status -ne "Enabled" -and $activeOnRecovery)
    if ($needEnableOnly) {
        Write-Log "Enable-only path: image current, WinRE disabled, on recovery partition"
        $suspended = Suspend-BitLockerForWinRE
        if (-not $suspended) {
            $blStateEnableOnly = Test-BitLockerProtected -MountPoint "C:"
            if ($blStateEnableOnly -ne $false) {
                $blStateEnableOnlyText = if ($null -eq $blStateEnableOnly) { 'unknown' } else { "$blStateEnableOnly" }
                Write-Log "Cannot confirm BitLocker is unprotected on C: (state=$blStateEnableOnlyText) - refusing enable-only path" -Level ERROR
                Write-Log "Re-run after the encryption state stabilises (Conversion Status Fully Decrypted, or Protection Status Protection On)." -Level WARN
                $Script:nonFatalWarning = $true
                Remove-ItemIfExist $CheckpointFile
                exit $EXIT_WARNING
            }
            Write-Log "Suspend returned false but BitLocker is confirmed Off - proceeding with enable-only path" -Level WARN
        }

        $enableResult = "failed"
        $targetPart = $null
        if (-not $Script:DryRun) {
            # v25: use Resolve-WinRELocationToPartition for consistency with
            # the classification logic above.
            if ($WinREState.Location) {
                $targetPart = Resolve-WinRELocationToPartition -Location $WinREState.Location
            }
            if (-not $targetPart -and $existingRecoveryParts.Count -gt 0) {
                $targetPart = $existingRecoveryParts[0]
                Write-Log "Enable-only path: location resolution failed - falling back to first recovery partition (disk $($targetPart.DiskNumber) part $($targetPart.PartitionNumber))" -Level WARN
            }

            if ($targetPart) {
                $permanentPath = "\\?\GLOBALROOT\device\harddisk$($targetPart.DiskNumber)\partition$($targetPart.PartitionNumber)\Recovery\WindowsRE"

                $setImageOutput = cmd /c "reagentc /setreimage /path $permanentPath 2>&1"
                $setImageExit = $LASTEXITCODE
                Write-Log "reagentc /setreimage: exit=$setImageExit, output=$setImageOutput"
                if ($setImageExit -ne 0) {
                    Write-Log "reagentc /setreimage failed in enable-only path: $setImageOutput" -Level ERROR
                    Write-Log "Falling through to full update to rebuild and re-set the path" -Level WARN
                    $Script:nonFatalWarning = $true
                    $needEnableOnly = $false
                } else {
                    $vol = Get-Volume -Partition $targetPart -ErrorAction SilentlyContinue
                    if ($vol -and $vol.DriveLetter) {
                        if (-not $Script:tempDriveLetters.Contains($vol.DriveLetter)) { $Script:tempDriveLetters.Add($vol.DriveLetter) }
                        Invoke-DriveLetterRemoval -Letter $vol.DriveLetter | Out-Null
                    }
                    $enableResult = Invoke-ReagentcEnable -AllowTempLetter -Partition @{ DiskNumber = $targetPart.DiskNumber; PartitionNumber = $targetPart.PartitionNumber } -ReRegisterPath $permanentPath
                }
            } else {
                Write-Log "Enable-only path: no recovery partition found - escalating to full update" -Level WARN
                $needEnableOnly = $false
            }
        } else {
            $enableResult = "ok"
        }

        if ($needEnableOnly -and ($enableResult -eq "ok" -or $enableResult -eq "reboot")) {
            # v43 patch 3: enforce the "no type-coded recovery partition on
            # any non-OS disk" invariant on the enable-only path. This
            # path exits before Step 7, so without this call a stray
            # secondary-disk recovery partition that appeared between the
            # last full run and this run would survive indefinitely on a
            # machine whose WinRE was simply re-enabled. The scan is
            # read-only when no strays exist.
            if ($osDisk) {
                Remove-StrayRecoveryPartitions -OSDiskNumber $osDisk.Number | Out-Null
            } else {
                Write-Log "Enable-only path: could not determine OS disk for stray-recovery cleanup" -Level WARN
                $Script:nonFatalWarning = $true
            }
            if ($enableResult -eq "reboot") {
                Write-Log "Enable succeeded - reboot required"
                if ($targetPart) {
                    Write-WinREState -Hash $storedHash -DriverVersion $storedDriverVersion -DesiredStateId $DesiredStateId `
                                     -PendingReboot $true `
                                     -DeployedDiskNumber $targetPart.DiskNumber `
                                     -DeployedPartitionNumber $targetPart.PartitionNumber `
                                     -UsedOSFallback $false `
                                     -RepairAttempts 0
                } else {
                    Write-WinREState -Hash $storedHash -DriverVersion $storedDriverVersion -DesiredStateId $DesiredStateId `
                                     -PendingReboot $true `
                                     -UsedOSFallback $false `
                                     -RepairAttempts 0
                }
                Remove-ItemIfExist $CheckpointFile
                exit $EXIT_REBOOT_REQUIRED
            }
            if ($Script:nonFatalWarning) {
                Write-Log "Enable succeeded with warnings"
                Remove-ItemIfExist $CheckpointFile
                exit $EXIT_WARNING
            }
            if ($Script:DryRun) {
                Write-Log "[DRY RUN] Would report the enable-only path as succeeded and exit with EXIT_SUCCESS"
            } else {
                Write-Log "Enable succeeded cleanly"
            }
            Remove-ItemIfExist $CheckpointFile
            exit $EXIT_SUCCESS
        }
        if ($needEnableOnly -and $enableResult -eq "failed") {
            $newEnableAttempts = [int]$state.EnableFailureAttempts + 1
            Write-Log "Enable-only /enable failed (attempt $newEnableAttempts of 3). Not falling through to full update - the deployment is current and only the enable step failed, so a rebuild would not change the outcome. Will retry on next run." -Level WARN
            Write-WinREState -Hash $storedHash -DriverVersion $storedDriverVersion -DesiredStateId $DesiredStateId `
                             -PendingReboot $false `
                             -DeployedDiskNumber $state.DeployedDiskNumber `
                             -DeployedPartitionNumber $state.DeployedPartitionNumber `
                             -UsedOSFallback $false `
                             -RepairAttempts 0 `
                             -LastEnableResult "failed" `
                             -EnableFailureAttempts $newEnableAttempts
            Remove-ItemIfExist $CheckpointFile
            exit $EXIT_WARNING
        }
        if ($needEnableOnly -and $enableResult -eq "bitlocker") {
            Write-Log "Enable-only path hit BitLocker-protected recovery partition - falling through to full update for suspend + delete + recreate" -Level WARN
            $Script:nonFatalWarning = $true
        }
        if ($needEnableOnly -and $enableResult -eq "blunsafe") {
            Write-Log "Enable-only path refused: BitLocker on C: not confirmed safe - aborting without changes" -Level WARN
            $Script:nonFatalWarning = $true
            Remove-ItemIfExist $CheckpointFile
            exit $EXIT_WARNING
        }
    }

    # ============ FULL UPDATE PATH ============
    Write-Log "Starting full update"

    if ($step -le 1) {
        Remove-ItemIfExist "$WorkDir\mount" -Recurse; Remove-ItemIfExist "$WorkDir\base.wim"
        Set-Checkpoint -CheckpointFile $CheckpointFile -Step 1 -DesiredStateId $DesiredStateId
    }
    if ($step -le 2) {
        Write-Log "Step 2: Obtaining base WIM"
        if ($needInject) {
            if (-not $ActiveLocationImage -and -not $FallbackImage) {
                if (-not (Ensure-7Zip)) { Write-Log "7-Zip required" -Level FATAL; exit $EXIT_FATAL }
                $folder = if ($Hardware.IsWin10) { "Win10" } else { "Win11" }
                $apiUrl = "$BaseWinRERepoApi/$folder"
                $files = Invoke-RestMethod -Uri $apiUrl -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop
                $parts = $files | Where-Object { $_.name -match '^[Ww]inre\.7z\.\d+$' } | Sort-Object name
                foreach ($part in $parts) {
                    Invoke-WebRequest -Uri $part.download_url -OutFile (Join-Path $WorkDir $part.name) -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop
                }
                & $7Zip x (Join-Path $WorkDir $parts[0].name) -o"$WorkDir" -y | Out-Null
                Rename-Item "$WorkDir\winre.wim" "base.wim"
                Write-Log "Downloaded base WIM from GitHub"
            } else {
                $src = if ($ActiveLocationImage) { $ActiveLocationImage } else { $FallbackImage }
                Copy-Item $src "$WorkDir\base.wim"
                Write-Log "Copied base WIM from $src"
            }
        }
        Set-Checkpoint -CheckpointFile $CheckpointFile -Step 2 -DesiredStateId $DesiredStateId
    }

    if ($needInject -and $OEMPackage -and $OEMPackage.IsUrl) {
        Write-Log "Downloading OEM pack: $($OEMPackage.Name)"
        $downloadFileName = Get-DownloadFileName -Url $OEMPackage.DownloadUrl -FallbackName "oem_pack"
        $tempArchive = Join-Path $WorkDir $downloadFileName

        Write-Log "OEM pack original filename: $downloadFileName"
        Write-Log "OEM pack URL: $($OEMPackage.DownloadUrl)"
        Write-Log "OEM pack archive type: $($OEMPackage.ArchiveType)"

        $downloadOk = Invoke-OemPackDownload -Url $OEMPackage.DownloadUrl -DestinationPath $tempArchive -ExpectedSHA256 $OEMPackage.ExpectedSHA256 -ExpectedMD5 $OEMPackage.ExpectedMD5

        if ($downloadOk) {
            $OEMPackage.DownloadUrl = $tempArchive; $OEMPackage.IsUrl = $false
            $OEMPackage | Add-Member -NotePropertyName DownloadFileName -NotePropertyValue $downloadFileName -Force
        } else {
            Write-Log "OEM download failed" -Level WARN
            $Script:nonFatalWarning = $true
            $Script:ImageInjectionComplete = $false
            $OEMPackage = $null
        }
    }

    if ($step -le 3 -and $needInject) {
        Write-Log "Step 3: Mounting and injecting"
        if ($OEMPackage -or $requiredDrivers.Count -gt 0) { if (-not (Test-Path $7Zip)) { Ensure-7Zip | Out-Null } }
        $MountDir = "$WorkDir\mount"
        Invoke-DismMount -ImageFile "$WorkDir\base.wim" -MountDir $MountDir -Index 1

        $extractDir = "$WorkDir\oem_extract"

        # Capture pre-injection third-party driver count. Add-WindowsDriver's
        # return-shape filter ($_.Operation -in @("Add","Installed")) does not
        # match on Windows 11 build 26100, so we compute success by comparing
        # image inventories before and after injection. See CRITICAL LESSONS
        # LEARNED.
        $preInjectThirdParty = 0
        try {
            $preInjectThirdParty = @(
                Get-WindowsDriver -Path $MountDir -ErrorAction SilentlyContinue |
                Where-Object { $_.ProviderName -and $_.ProviderName -ne 'Microsoft Corporation' }
            ).Count
        } catch { }
        Write-Log "Pre-injection third-party driver count: $preInjectThirdParty"

        if ($OEMPackage) {
            Write-Log "Processing OEM pack: $($OEMPackage.Name)"
            Write-Log "  Manufacturer: $($OEMPackage.Manufacturer)"
            Write-Log "  Archive type: $($OEMPackage.ArchiveType)"
            Write-Log "  Local path: $($OEMPackage.DownloadUrl)"
            Remove-ItemIfExist $extractDir -Recurse
            New-DirectoryIfNotExists $extractDir | Out-Null

            $extractionOk = $false
            switch ($OEMPackage.Manufacturer) {
                "LENOVO" {
                    $extractionOk = Invoke-VendorExtraction -ExePath $OEMPackage.DownloadUrl -DestinationDir $extractDir -Vendor "LENOVO"
                }
                "HP" {
                    $extractionOk = Invoke-VendorExtraction -ExePath $OEMPackage.DownloadUrl -DestinationDir $extractDir -Vendor "HP"
                }
                default {
                    # Dell and any other vendor: CAB via 7-Zip.
                    $extractionOk = Invoke-CabExtraction -CabPath $OEMPackage.DownloadUrl -DestinationDir $extractDir
                }
            }

            if (-not $extractionOk) {
                Write-Log "OEM extraction FAILED for $($OEMPackage.Manufacturer)" -Level WARN
                $Script:nonFatalWarning = $true
                $Script:ImageInjectionComplete = $false
            } else {
                $infCount = Get-InfFileCount -Directory $extractDir
                Write-Log "OEM extraction succeeded. INF files available for injection: $infCount"

                if ($infCount -eq 0) {
                    Write-Log "OEM extraction produced ZERO INF files. This is the known Lenovo SCCM Package issue." -Level WARN
                    Write-Log "The package may be a WinPE boot image bundle rather than a driver-only pack." -Level WARN
                    $Script:nonFatalWarning = $true
                    $Script:ImageInjectionComplete = $false
                } else {
                    Write-Log "Injecting OEM drivers from $extractDir"

                    # v36: collect INF basenames from the extracted package.
                    # We cross-reference these against the mounted image's
                    # third-party driver OriginalFileName values after
                    # injection. Provider count alone cannot distinguish
                    # "our package's drivers are present" from "some other
                    # third-party drivers happen to already be present".
                    $extractedInfNames = @()
                    try {
                        $extractedInfNames = @(
                            Get-ChildItem -Path $extractDir -Recurse -Filter "*.inf" -File -ErrorAction SilentlyContinue |
                            ForEach-Object { $_.Name.ToLowerInvariant() }
                        ) | Select-Object -Unique
                    } catch { }

                    $dismErrors = @()
                    $result = Add-WindowsDriver -Path $MountDir -Driver $extractDir -Recurse -ErrorAction SilentlyContinue -ErrorVariable dismErrors
                    $added = @($result | Where-Object { $_.Operation -in @("Add","Installed") })
                    Write-Log "Add-WindowsDriver returned $($added.Count) added driver(s) (return-shape filter may be unreliable on this DISM build)"

                    # Post-injection count and delta. This is the only reliable
                    # indicator of injection result - do not trust $added.Count
                    # from the Add-WindowsDriver return object.
                    $postInjectThirdParty = 0
                    $imageInfNames = @()
                    try {
                        $drivers = @(
                            Get-WindowsDriver -Path $MountDir -ErrorAction SilentlyContinue |
                            Where-Object { $_.ProviderName -and $_.ProviderName -ne 'Microsoft Corporation' }
                        )
                        $postInjectThirdParty = $drivers.Count
                        $imageInfNames = @(
                            $drivers |
                            Where-Object { $_.OriginalFileName } |
                            ForEach-Object { ($_.OriginalFileName -split '\\')[-1].ToLowerInvariant() }
                        ) | Select-Object -Unique
                    } catch { }

                    $matchedInfCount = 0
                    if ($extractedInfNames.Count -gt 0 -and $imageInfNames.Count -gt 0) {
                        $matchedInfCount = @($extractedInfNames | Where-Object { $_ -in $imageInfNames }).Count
                    }

                    $delta = $postInjectThirdParty - $preInjectThirdParty
                    Write-Log "Post-injection third-party driver count: $postInjectThirdParty (delta $delta); package INF matches: $matchedInfCount of $($extractedInfNames.Count)"

                    # v36: success gate. Fail only when the package's INFs
                    # are absent from the image AND no third-party drivers
                    # were added this run.
                    if ($delta -eq 0 -and $matchedInfCount -eq 0) {
                        Write-Log "OEM injection failed - package INFs not found in image after injection" -Level WARN
                        if ($dismErrors.Count -gt 0) {
                            Write-Log "Add-WindowsDriver error output (first 5):" -Level WARN
                            $dismErrors | Select-Object -First 5 | ForEach-Object { Write-Log "  DISM: $_" -Level WARN }
                        } else {
                            Write-Log "Add-WindowsDriver produced no error output (silent rejection or no applicable drivers)" -Level WARN
                        }
                        $Script:nonFatalWarning = $true
                        $Script:ImageInjectionComplete = $false
                    } elseif ($delta -gt 0) {
                        Write-Log "OEM drivers injected: $delta new third-party driver(s) added to image"
                    } else {
                        Write-Log "OEM injection no-op: $matchedInfCount of $($extractedInfNames.Count) package INF(s) already present in image before this run"
                    }
                }
            }
            Remove-ItemIfExist $extractDir -Recurse
        }

        if ($requiredDrivers.Count -gt 0) {
            $allDirs = @()
            $extractedVmdInfNames = @()
            foreach ($drv in $requiredDrivers) {
                Write-Log "Downloading VMD driver: $($drv.name)"
                $drvArchive = "$WorkDir\driver_$($drv.name).7z"
                Invoke-WebRequest -Uri $drv.driverUrl -OutFile $drvArchive -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop
                $drvExtractDir = "$WorkDir\drv_extract_$($drv.name)"
                & $7Zip x $drvArchive -o"$drvExtractDir" -y | Out-Null
                try {
                    $extractedVmdInfNames += @(
                        Get-ChildItem -Path $drvExtractDir -Recurse -Filter "*.inf" -File -ErrorAction SilentlyContinue |
                        ForEach-Object { $_.Name.ToLowerInvariant() }
                    )
                } catch { }
                $allDirs += $drvExtractDir
            }
            $extractedVmdInfNames = @($extractedVmdInfNames) | Select-Object -Unique
            Write-Log "VMD package INF files found: $($extractedVmdInfNames.Count)"

            $preVmdThirdParty = 0
            try {
                $preVmdThirdParty = @(
                    Get-WindowsDriver -Path $MountDir -ErrorAction SilentlyContinue |
                    Where-Object { $_.ProviderName -and $_.ProviderName -ne 'Microsoft Corporation' }
                ).Count
            } catch { }

            $dismErrors = @()
            $result = Add-WindowsDriver -Path $MountDir -Driver $allDirs -Recurse -ErrorAction SilentlyContinue -ErrorVariable dismErrors
            $added = @($result | Where-Object { $_.Operation -in @("Add","Installed") })
            Write-Log "VMD Add-WindowsDriver returned $($added.Count) added driver(s) (return-shape filter may be unreliable on this DISM build)"

            $postVmdThirdParty = 0
            $imageVmdInfNames = @()
            try {
                $vmdDrivers = @(
                    Get-WindowsDriver -Path $MountDir -ErrorAction SilentlyContinue |
                    Where-Object { $_.ProviderName -and $_.ProviderName -ne 'Microsoft Corporation' }
                )
                $postVmdThirdParty = $vmdDrivers.Count
                $imageVmdInfNames = @(
                    $vmdDrivers |
                    Where-Object { $_.OriginalFileName } |
                    ForEach-Object { ($_.OriginalFileName -split '\\')[-1].ToLowerInvariant() }
                ) | Select-Object -Unique
            } catch { }

            $vmdMatchedInfCount = 0
            if ($extractedVmdInfNames.Count -gt 0 -and $imageVmdInfNames.Count -gt 0) {
                $vmdMatchedInfCount = @($extractedVmdInfNames | Where-Object { $_ -in $imageVmdInfNames }).Count
            }

            $vmdDelta = $postVmdThirdParty - $preVmdThirdParty
            Write-Log "VMD post-injection third-party driver count: $postVmdThirdParty (delta $vmdDelta); package INF matches: $vmdMatchedInfCount of $($extractedVmdInfNames.Count)"

            # v37: success gate. Success when the VMD package contributed
            # either new drivers (delta > 0) or package INFs are already
            # present (matched > 0). Failure only when neither - i.e. the
            # VMD package's INFs cannot be demonstrated in the image.
            if ($vmdDelta -gt 0) {
                Write-Log "VMD drivers injected: $vmdDelta new third-party driver(s) added to image"
            } elseif ($vmdMatchedInfCount -gt 0) {
                Write-Log "VMD injection no-op: $vmdMatchedInfCount of $($extractedVmdInfNames.Count) VMD package INF(s) already present in image before this run"
            } else {
                Write-Log "VMD driver injection failed - VMD package INFs not found in image after injection" -Level WARN
                if ($dismErrors.Count -gt 0) {
                    Write-Log "VMD Add-WindowsDriver error output (first 5):" -Level WARN
                    $dismErrors | Select-Object -First 5 | ForEach-Object { Write-Log "  DISM: $_" -Level WARN }
                }
                $Script:nonFatalWarning = $true
                $Script:ImageInjectionComplete = $false
            }
            $allDirs | ForEach-Object { Remove-ItemIfExist $_ -Recurse }
        }

        Dismount-WindowsImage -Path $MountDir -Save; Remove-ItemIfExist $MountDir
        # v43 patch 4: do not advance the checkpoint past step 2 when
        # image injection did not complete. If the checkpoint advances
        # but the run is interrupted before cleanup, the next run
        # resumes past step 3 with a fresh $Script:ImageInjectionComplete
        # = $true and can commit state for the un-injected WIM. See the
        # migration guard near the state read for the complementary fix
        # on already-affected machines.
        if ($Script:ImageInjectionComplete) {
            Set-Checkpoint -CheckpointFile $CheckpointFile -Step 3 -DesiredStateId $DesiredStateId
        } else {
            Write-Log "Checkpoint NOT advanced to step 3 - image injection did not complete; next run will retry step 3" -Level WARN
        }
    }

    $OptimizedWim = "$WorkDir\winre_optimized.wim"
    if ($step -le 4 -and $needInject) {
        Write-Log "Step 4: Optimizing"
        & dism /Export-Image /SourceImageFile:"$WorkDir\base.wim" /SourceIndex:1 /DestinationImageFile:$OptimizedWim /Compress:max | Out-Null
        # v42: a native executable returning nonzero does not raise a
        # PowerShell exception under $ErrorActionPreference = "Stop".
        # Check the exit code and the output file explicitly before
        # checkpointing step 4, so a failed export cannot be recorded as
        # complete and silently reused on a subsequent run.
        if ($LASTEXITCODE -ne 0) {
            Write-Log "dism /Export-Image failed with exit code $LASTEXITCODE" -Level FATAL
            exit $EXIT_FATAL
        }
        if (-not (Test-Path $OptimizedWim)) {
            Write-Log "dism /Export-Image reported success but $OptimizedWim does not exist" -Level FATAL
            exit $EXIT_FATAL
        }
        # v43 patch 4: same gate as step 3. A step-4 checkpoint on disk
        # after a failed-injection run lets the next run skip step 3
        # ($step >= 4 means the step-3 block does not run) and commit
        # state for the un-injected WIM.
        if ($Script:ImageInjectionComplete) {
            Set-Checkpoint -CheckpointFile $CheckpointFile -Step 4 -DesiredStateId $DesiredStateId
        } else {
            Write-Log "Checkpoint NOT advanced to step 4 - image injection did not complete; next run will retry step 3" -Level WARN
        }
    }

    $SourceWim = if ($needInject) { $OptimizedWim } else { $imageToCheck }
    $finalSizeMB = Get-FileSizeMB -Path $SourceWim
    if ($finalSizeMB -le 0) { Write-Log "Could not determine WIM size" -Level FATAL; exit $EXIT_FATAL }
    Write-Log "Source WIM: $SourceWim ($finalSizeMB MiB)"

    $recoveryPartition = Find-SuitableRecoveryPartition -RequiredWimSizeMB $finalSizeMB

    if (-not $recoveryPartition) {
        Write-Log "No suitable existing recovery partition - attempting to create one"
        $Script:BitLockerGuardDeferred = $false
        $created = Ensure-AdequateRecoveryPartition -RequiredWimSizeMB $finalSizeMB
        if ($created) {
            $recoveryPartition = @{ DriveLetter = $created.DriveLetter; DiskNumber = $created.DiskNumber; PartitionNumber = $created.PartitionNumber; Partition = $null }
        } elseif ($Script:BitLockerGuardDeferred) {
            Write-Log "BitLocker guard deferred destructive partition work. No changes were made to the machine. Re-run once manage-bde -status C: shows Protection Status: Protection On (any conversion status), or Protection Status: Protection Off with Conversion Status: Fully Decrypted. Exit code will be 2." -Level WARN
            Remove-ItemIfExist $CheckpointFile
            exit $EXIT_WARNING
        } else {
            Write-Log "================================================================================" -Level WARN
            Write-Log "Dedicated recovery partition creation failed after all attempts." -Level WARN
            Write-Log "Falling back to C:\Recovery\WindowsRE (OS-partition recovery location)." -Level WARN
            Write-Log "This is NOT equivalent to a dedicated recovery partition." -Level WARN
            Write-Log "WinRE will function but with reduced resilience. Exit code will be 2." -Level WARN
            Write-Log "================================================================================" -Level WARN
            $Script:UsedOSFallback = $true
            $Script:nonFatalWarning = $true
            $recoveryPartition = $null
        }
    }

    if ($recoveryPartition) {
        Write-Log "Target recovery partition: disk $($recoveryPartition.DiskNumber) part $($recoveryPartition.PartitionNumber) (letter $($recoveryPartition.DriveLetter):)"
        $TargetDir = "$($recoveryPartition.DriveLetter):\Recovery\WindowsRE"
        $permanentPath = "\\?\GLOBALROOT\device\harddisk$($recoveryPartition.DiskNumber)\partition$($recoveryPartition.PartitionNumber)\Recovery\WindowsRE"
    } else {
        Write-Log "Target (OS-fallback): C:\Recovery\WindowsRE"
        $TargetDir = "$env:SystemDrive\Recovery\WindowsRE"
        $permanentPath = $TargetDir
    }
    $FinalWim = Join-Path $TargetDir "winre.wim"

    Write-Log "Step 5: Deploying WIM to $TargetDir"
    if ($Script:DryRun) {
        Write-Log "[DRY RUN] Would deploy $SourceWim to $TargetDir and enable WinRE"
        Remove-ItemIfExist $CheckpointFile
        exit $EXIT_SUCCESS
    }

    # v43 patch 5 (revised): check BitLocker safety BEFORE disabling WinRE.
    # If BitLocker is in the hazardous Device Encryption in-progress state,
    # reagentc /enable will refuse regardless of which target we deploy to.
    # Disabling WinRE and then failing to re-enable it leaves the machine
    # worse off than it started: WinRE disabled, no registered recovery
    # location. Bail out now with a warning so the machine keeps whatever
    # WinRE registration it has, and the next run after encryption
    # stabilises can complete the work.
    $preDeploySuspend = Suspend-BitLockerForWinRE
    if (-not $preDeploySuspend) {
        $preDeployBl = Test-BitLockerProtected -MountPoint "C:"
        if ($preDeployBl -ne $false) {
            $preDeployBlText = if ($null -eq $preDeployBl) { 'unknown' } else { "$preDeployBl" }
            Write-Log "Cannot confirm BitLocker is unprotected on C: (state=$preDeployBlText) - skipping deployment to preserve current WinRE state" -Level ERROR
            Write-Log "Re-run after the encryption state stabilises (VolumeStatus=FullyDecrypted or FullyEncrypted)." -Level WARN
            $Script:nonFatalWarning = $true
            Remove-ItemIfExist $CheckpointFile
            exit $EXIT_WARNING
        }
        Write-Log "Suspend returned false but BitLocker is confirmed Off - proceeding" -Level WARN
    }

    $CurrentWinREState = Get-WinREState
    if ($CurrentWinREState.Status -eq "Enabled") {
        Write-Log "Disabling WinRE before deployment"
        $disOut = cmd /c "reagentc /disable 2>&1"
        $disExit = $LASTEXITCODE
        Write-Log "reagentc /disable: exit=$disExit, output=$disOut"
        # v42: treat a failed /disable as a hard stop, matching the
        # conservative pattern already used in Ensure-AdequateRecoveryPartition.
        # Deploying a new WIM while the old registration is still active
        # is not a state we want to be in.
        if ($disExit -ne 0) {
            Write-Log "reagentc /disable failed (exit $disExit): $disOut" -Level ERROR
            Write-Log "FATAL: cannot deploy a new WinRE image while WinRE is still Enabled - aborting" -Level ERROR
            exit $EXIT_FATAL
        }
        Start-Sleep 3
        $verifyDisabled = Get-WinREState
        if ($verifyDisabled.Status -ne "Disabled") {
            Write-Log "WinRE still reports $($verifyDisabled.Status) after reagentc /disable - aborting" -Level ERROR
            exit $EXIT_FATAL
        }
    }

    $deployOk = $false
    if ($recoveryPartition) {
        $deployOk = Deploy-WimToPartition -Partition $recoveryPartition -SourceWim $SourceWim
    } else {
        $srcFull = $null; try { $srcFull = [System.IO.Path]::GetFullPath($SourceWim) } catch { }
        $dstFull = $null; try { $dstFull = [System.IO.Path]::GetFullPath($FinalWim) } catch { }
        if ($srcFull -and $dstFull -and $srcFull -eq $dstFull) {
            Write-Log "OS-fallback: source and target are the same file - nothing to copy"
            $deployOk = $true
        } else {
            try {
                New-DirectoryIfNotExists $TargetDir
                if (Test-Path $FinalWim) {
                    try { & attrib $FinalWim -h -s -r 2>&1 | Out-Null } catch { }
                    try { Remove-Item $FinalWim -Force -ErrorAction SilentlyContinue } catch { }
                }
                $srcHash = (Get-FileHash $SourceWim -Algorithm SHA256).Hash
                Copy-Item $SourceWim -Destination $FinalWim -Force -ErrorAction Stop
                if (-not (Test-Path $FinalWim)) { throw "destination missing" }
                $dstHash = (Get-FileHash $FinalWim -Algorithm SHA256).Hash
                if ($srcHash -ne $dstHash) { throw "copy hash mismatch" }
                attrib $FinalWim +h +s
                Write-Log "OS-fallback copy verified (SHA256=$dstHash)"
                $deployOk = $true
            } catch {
                Write-Log "OS-fallback deployment failed: $_" -Level ERROR
                $deployOk = $false
            }
        }
    }

    if (-not $deployOk) {
        Write-Log "FATAL: WIM deployment failed" -Level ERROR
        exit $EXIT_FATAL
    }

    $setImageOutput = cmd /c "reagentc /setreimage /path $permanentPath 2>&1"
    $setImageExit = $LASTEXITCODE
    Write-Log "reagentc /setreimage: exit=$setImageExit, output=$setImageOutput -> $permanentPath"
    if ($setImageExit -ne 0) {
        Write-Log "FATAL: reagentc /setreimage failed: $setImageOutput" -Level ERROR
        exit $EXIT_FATAL
    }

    if ($recoveryPartition -and $recoveryPartition.DriveLetter) {
        $letterToRemove = $recoveryPartition.DriveLetter
        $removed = Invoke-DriveLetterRemoval -Letter $letterToRemove
        if ($removed) { Write-Log "Removed drive letter ${letterToRemove}: before enable" }
        else { Write-Log "Could not remove drive letter ${letterToRemove}: - enable may still work" -Level WARN }
    }

    if ($recoveryPartition) {
        $enableResult = Invoke-ReagentcEnable -AllowTempLetter -Partition $recoveryPartition -ReRegisterPath $permanentPath
    } else {
        $enableResult = Invoke-ReagentcEnable -ReRegisterPath $permanentPath
    }
    if ($enableResult -eq "reboot") { $Script:rebootRequired = $true }
    elseif ($enableResult -eq "failed") { $Script:nonFatalWarning = $true }
    elseif ($enableResult -eq "blunsafe") {
        Write-Log "BitLocker on C: is not confirmed safe - refusing to attempt reagentc /enable after WIM deployment. WinRE may not be enabled on this machine until the state stabilises." -Level WARN
        Write-Log "Exiting with warning. The deployed WIM will be retried on a future run once the BitLocker state is confirmed safe." -Level WARN
        $Script:nonFatalWarning = $true
        Remove-ItemIfExist $CheckpointFile
        exit $EXIT_WARNING
    }
    elseif ($enableResult -eq "bitlocker") {
        Write-Log "BitLocker protection on the recovery partition prevented enable. Attempting suspend + delete + recreate." -Level WARN
        $Script:nonFatalWarning = $true

        # Step 1: ensure BitLocker is suspended.
        $suspendOk = Suspend-BitLockerForWinRE -MountPoint "C:"
        if (-not $suspendOk) {
            Write-Log "Cannot suspend BitLocker - unable to recover from BitLocker-protected recovery partition" -Level ERROR
        } else {
            # Step 2: delete the encrypted recovery partition.
            $encPart = $null
            if ($recoveryPartition) {
                $encPart = @{ DiskNumber = $recoveryPartition.DiskNumber; PartitionNumber = $recoveryPartition.PartitionNumber }
            }
            if ($encPart) {
                Write-Log "Deleting BitLocker-encrypted recovery partition disk $($encPart.DiskNumber) part $($encPart.PartitionNumber)" -Level WARN
                try {
                    $p = Get-Partition -DiskNumber $encPart.DiskNumber -PartitionNumber $encPart.PartitionNumber -ErrorAction Stop
                    $p | Remove-Partition -Confirm:$false -ErrorAction Stop
                } catch {
                    $dp = "select disk $($encPart.DiskNumber)`nselect partition $($encPart.PartitionNumber)`ndelete partition override"
                    $dp | diskpart | Out-Null
                }
                Start-Sleep 3

                # Step 3: recreate the recovery partition.
                $recreated = Ensure-AdequateRecoveryPartition -RequiredWimSizeMB $finalSizeMB
                if ($recreated) {
                    $recoveryPartition = @{ DriveLetter = $recreated.DriveLetter; DiskNumber = $recreated.DiskNumber; PartitionNumber = $recreated.PartitionNumber; Partition = $null }
                    $TargetDir = "$($recoveryPartition.DriveLetter):\Recovery\WindowsRE"
                    $permanentPath = "\\?\GLOBALROOT\device\harddisk$($recoveryPartition.DiskNumber)\partition$($recoveryPartition.PartitionNumber)\Recovery\WindowsRE"
                    $FinalWim = Join-Path $TargetDir "winre.wim"

                    # Step 4: redeploy the WIM.
                    $redeployOk = Deploy-WimToPartition -Partition $recoveryPartition -SourceWim $SourceWim
                    if ($redeployOk) {
                        $reSetOutput = cmd /c "reagentc /setreimage /path $permanentPath 2>&1"
                        $reSetExit = $LASTEXITCODE
                        Write-Log "reagentc /setreimage (post-recreate): exit=$reSetExit, output=$reSetOutput"
                        if ($reSetExit -eq 0) {
                            if ($recoveryPartition.DriveLetter) { Invoke-DriveLetterRemoval -Letter $recoveryPartition.DriveLetter | Out-Null }
                            $retryEnable = Invoke-ReagentcEnable -AllowTempLetter -Partition $recoveryPartition -ReRegisterPath $permanentPath
                            if ($retryEnable -eq "ok") {
                                Write-Log "reagentc /enable succeeded after BitLocker suspend + partition recreation"
                                $enableResult = "ok"
                            } elseif ($retryEnable -eq "reboot") {
                                $Script:rebootRequired = $true
                                $enableResult = "reboot"
                            } else {
                                Write-Log "reagentc /enable still failed after partition recreation: $retryEnable" -Level ERROR
                            }
                        }
                    } else {
                        Write-Log "WIM redeploy failed after partition recreation" -Level ERROR
                    }
                } else {
                    Write-Log "Could not recreate recovery partition after BitLocker encryption" -Level ERROR
                }
            } else {
                Write-Log "No recovery partition context available for BitLocker recovery" -Level WARN
            }
        }
    }

    if ($recoveryPartition) {
        $osDisk = Get-OSDisk
        $style = if ($osDisk) { $osDisk.PartitionStyle } else { 'GPT' }
        $attrsOk = Set-RecoveryPartitionAttributes -DiskNumber $recoveryPartition.DiskNumber -PartitionNumber $recoveryPartition.PartitionNumber -Style $style
        if (-not $attrsOk) {
            Write-Log "Recovery partition attributes could not be fully applied. WinRE is functional, but the partition may not be correctly marked as a recovery partition." -Level WARN
            $Script:nonFatalWarning = $true
        }
    }

    $fallbackTarget = "$env:SystemDrive\Recovery\WindowsRE\winre.wim"
    # v43: guard against SourceWim being the fallback itself. When WinRE is
    # disabled and the deployment source is the same file we would write
    # as the fallback (C:\Recovery\WindowsRE\winre.wim), the copy below
    # would delete the source and then try to copy it back to itself,
    # failing and leaving no fallback WIM at all. Skip the block when
    # source and target are the same file.
    $srcFullFb = $null; try { $srcFullFb = [System.IO.Path]::GetFullPath($SourceWim) } catch { }
    $dstFullFb = $null; try { $dstFullFb = [System.IO.Path]::GetFullPath($fallbackTarget) } catch { }
    $sourceIsFallback = ($srcFullFb -and $dstFullFb -and $srcFullFb -eq $dstFullFb)
    if ($FinalWim -ne $fallbackTarget -and -not $sourceIsFallback) {
        New-DirectoryIfNotExists (Split-Path $fallbackTarget -Parent)
        $copyOk = $false
        try {
            if (Test-Path $fallbackTarget) {
                try { & attrib $fallbackTarget -h -s -r 2>&1 | Out-Null } catch { }
                try { Remove-Item $fallbackTarget -Force -ErrorAction Stop } catch { }
            }
            Copy-Item $SourceWim -Destination $fallbackTarget -Force -ErrorAction Stop
            Write-Log "Updated fallback WinRE image at $fallbackTarget"
            $copyOk = $true
        } catch {
            Write-Log "Fallback copy attempt 1 failed: $_" -Level WARN
        }
        if (-not $copyOk) {
            try {
                if (Test-Path $fallbackTarget) {
                    $backup = "$fallbackTarget.old"
                    if (Test-Path $backup) { Remove-Item $backup -Force -ErrorAction SilentlyContinue }
                    Rename-Item $fallbackTarget $backup -Force -ErrorAction Stop
                }
                Copy-Item $SourceWim -Destination $fallbackTarget -Force -ErrorAction Stop
                Write-Log "Updated fallback WinRE image at $fallbackTarget (via rename)"
                if (Test-Path $backup) {
                    Remove-Item $backup -Force -ErrorAction SilentlyContinue
                    Write-Log "Removed backup file $backup"
                }
                $copyOk = $true
            } catch { }
        }
        if (-not $copyOk) {
            Write-Log "Fallback copy to $fallbackTarget denied (likely ACL). Non-fatal." -Level WARN
        }
    }

    $finalHash = Get-LiveWimHash $SourceWim
    if ($Script:ImageInjectionComplete -and $finalHash) {
        $deployedDisk = if ($recoveryPartition) { $recoveryPartition.DiskNumber } else { -1 }
        $deployedPart = if ($recoveryPartition) { $recoveryPartition.PartitionNumber } else { -1 }
        $newEnableAttempts = if ($enableResult -eq "failed") { [int]$state.EnableFailureAttempts + 1 } else { 0 }
        Write-WinREState -Hash $finalHash -DriverVersion $ExpectedDriverSetVersion -DesiredStateId $DesiredStateId `
                         -PendingReboot $Script:rebootRequired `
                         -DeployedDiskNumber $deployedDisk `
                         -DeployedPartitionNumber $deployedPart `
                         -UsedOSFallback $Script:UsedOSFallback `
                         -RepairAttempts 0 `
                         -LastEnableResult $enableResult `
                         -EnableFailureAttempts $newEnableAttempts
    } else {
        if (-not $Script:ImageInjectionComplete) {
            Write-Log "State file NOT updated - requested driver injection did not complete successfully" -Level WARN
        }
        if (-not $finalHash) {
            Write-Log "State file NOT updated - could not compute final WIM hash" -Level WARN
        }
        $Script:nonFatalWarning = $true
    }
    # v43 patch 4: same gate as steps 3 and 4. The step 6 checkpoint is
    # written immediately before cleanup removes it; the window between
    # the two operations is not atomic and spans the recursive WorkDir
    # delete, so an interruption in that window leaves a step-6
    # checkpoint on disk. If the run also failed injection (state write
    # skipped above), the next run would resume at step 6, skip step 3,
    # see $Script:ImageInjectionComplete = $true, and commit state for
    # the un-injected WIM.
    if ($Script:ImageInjectionComplete) {
        Set-Checkpoint -CheckpointFile $CheckpointFile -Step 6 -DesiredStateId $DesiredStateId
    } else {
        Write-Log "Checkpoint NOT advanced to step 6 - image injection did not complete; next run will retry step 3" -Level WARN
    }

    Write-Log "Step 6: Cleanup"
    Remove-ItemIfExist $WorkDir -Recurse; Remove-ItemIfExist $CheckpointFile

    # Step 7: remove every type-coded recovery partition that is not on the
    # OS disk. This is not cosmetic cleanup. Windows Setup and Startup
    # Repair scan all attached volumes for WinRE-capable partitions; a
    # recovery partition on a secondary or USB-attached disk can cause
    # the BCD to be pointed at the wrong WinRE image during repair or
    # reset operations, which fails the repair. The invariant the script
    # maintains is: exactly one recovery partition exists on the machine,
    # on the OS disk, correctly type-coded. Any type-coded recovery
    # partition elsewhere is removed unconditionally.
    #
    # The deletion body lives in Remove-StrayRecoveryPartitions so the same
    # cleanup runs on the idempotent fast path. The type-code gate
    # (GPT DE94... or MBR 0x27, distinguishing "recovery partition that
    # could confuse the boot loader" from "data partition that happens to
    # carry the Recovery/WINRE label") is documented at that function.
    Write-Log "Step 7: Removing stray recovery partitions on non-OS disks"
    $osDisk = Get-OSDisk
    if (-not $osDisk) {
        Write-Log "Step 7 skipped: could not determine OS disk" -Level WARN
        $Script:nonFatalWarning = $true
    } else {
        Remove-StrayRecoveryPartitions -OSDiskNumber $osDisk.Number | Out-Null
    }

    # ============ Final verification ============
    $finalState = Get-WinREState

    if ($finalState.Status -eq "Enabled" -and $Script:rebootRequired) {
        Write-Log "WinRE reports Enabled - clearing rebootRequired flag"
        $Script:rebootRequired = $false
    }

    if ($finalState.Status -eq "Enabled") {
        if ($finalState.Location) {
            $finalPart = Resolve-WinRELocationToPartition -Location $finalState.Location
            if (-not $finalPart) {
                Write-Log "FATAL: WinRE location cannot be resolved to a partition: $($finalState.Location)" -Level ERROR
                exit $EXIT_FATAL
            }

            $finalOSPartCheck = Get-OSPartition
            $isFinalOSPart = ($finalOSPartCheck -and
                              $finalPart.DiskNumber -eq $finalOSPartCheck.DiskNumber -and
                              $finalPart.PartitionNumber -eq $finalOSPartCheck.PartitionNumber)

            $isRec = ($finalPart.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}') -or ($finalPart.MbrType -eq 0x27)
            if (-not $isRec) {
                $vol = Get-Volume -Partition $finalPart -ErrorAction SilentlyContinue
                if ($vol -and ($vol.FileSystemLabel -eq 'Recovery' -or $vol.FileSystemLabel -eq 'WINRE')) { $isRec = $true }
            }

            if ($isFinalOSPart) {
                if ($Script:UsedOSFallback) {
                    Write-Log "Operating mode: OS-FALLBACK (WinRE on OS partition at $($finalState.Location)) - degraded but functional" -Level WARN
                } else {
                    Write-Log "FATAL: WinRE is on the OS partition but the script did not deploy it via OS-fallback" -Level ERROR
                    exit $EXIT_FATAL
                }
            }
            elseif ($isRec) {
                if ($finalPart.DriveLetter) {
                    Write-Log "Removing temporary drive letter $($finalPart.DriveLetter): (assigned for verification)" -Level WARN
                    if (-not $Script:tempDriveLetters.Contains($finalPart.DriveLetter)) { $Script:tempDriveLetters.Add($finalPart.DriveLetter) }
                    Invoke-DriveLetterRemoval -Letter $finalPart.DriveLetter | Out-Null
                }
                Write-Log "Operating mode: DEDICATED"
            }
            else {
                Write-Log "FATAL: WinRE is on an unexpected partition (disk $($finalPart.DiskNumber) part $($finalPart.PartitionNumber))" -Level ERROR
                exit $EXIT_FATAL
            }
        }
        elseif ($Script:UsedOSFallback) {
            Write-Log "Operating mode: OS-FALLBACK (WinRE at $($finalState.Location)) - degraded but functional" -Level WARN
        }
        else {
            Write-Log "FATAL: WinRE Enabled but location is empty" -Level ERROR
            exit $EXIT_FATAL
        }
    }
    elseif ($Script:rebootRequired) {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinRE"
        $winreLocation = (Get-ItemProperty -Path $regPath -Name "WinRELocation" -ErrorAction SilentlyContinue).WinRELocation
        Write-Log "WinRE reports $($finalState.Status) but enable succeeded - reboot will complete setup. Registered location: $winreLocation" -Level WARN
    }
    else {
        Write-Log "WinRE not enabled - final attempt" -Level WARN
        $cProtected = Test-BitLockerProtected -MountPoint "C:"
        if ($cProtected -eq $false) {
            Suspend-BitLockerForWinRE | Out-Null
            $finalResult = Invoke-ReagentcEnable -ReRegisterPath $permanentPath
            if ($finalResult -eq "ok") { }
            elseif ($finalResult -eq "reboot") {
                $Script:rebootRequired = $true
                if ($Script:ImageInjectionComplete -and $finalHash) {
                    $deployedDisk = if ($recoveryPartition) { $recoveryPartition.DiskNumber } else { -1 }
                    $deployedPart = if ($recoveryPartition) { $recoveryPartition.PartitionNumber } else { -1 }
                    Write-WinREState -Hash $finalHash -DriverVersion $ExpectedDriverSetVersion -DesiredStateId $DesiredStateId `
                                     -PendingReboot $true `
                                     -DeployedDiskNumber $deployedDisk `
                                     -DeployedPartitionNumber $deployedPart `
                                     -UsedOSFallback $Script:UsedOSFallback `
                                     -RepairAttempts 0
                }
            }
            else {
                Write-Log "FATAL: WinRE is not enabled at exit" -Level ERROR
                exit $EXIT_FATAL
            }
        } elseif ($cProtected -eq $true) {
            Write-Log "FATAL: BitLocker still protected - cannot enable WinRE. BitLocker is the blocker here; enable requires either suspension or disable." -Level ERROR
            exit $EXIT_FATAL
        } else {
            Write-Log "FATAL: BitLocker state on C: could not be determined - cannot enable WinRE safely" -Level ERROR
            exit $EXIT_FATAL
        }
    }

    if ($Script:rebootRequired) { exit $EXIT_REBOOT_REQUIRED }
    elseif ($Script:UsedOSFallback) { exit $EXIT_WARNING }
    elseif ($Script:nonFatalWarning) { exit $EXIT_WARNING }
    else { exit $EXIT_SUCCESS }
}
catch {
    Write-Log "FATAL ERROR: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level ERROR
    exit $EXIT_FATAL
}
finally {
    try {
        Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path -like "$WorkDir\*" } |
            ForEach-Object { try { Dismount-WindowsImage -Path $_.Path -Discard -ErrorAction SilentlyContinue } catch { } }
    } catch { }

    $leaks = @()
    foreach ($letter in $Script:tempDriveLetters) {
        try {
            $part = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
            if (-not $part) { continue }
            if ($part.IsBoot -or $part.IsSystem) { continue }
            if (Test-Path "${letter}:\Windows") { continue }
            if (Invoke-DriveLetterRemoval -Letter $letter) { Write-Log "Removed temp drive letter ${letter}:" }
            else { Write-Log "FAILED to remove drive letter ${letter}:" -Level ERROR; $leaks += $letter }
        } catch { $leaks += $letter }
    }
    if ($leaks.Count -gt 0) { Write-Log "Drive letters still assigned: $($leaks -join ', ')" -Level ERROR }

    Resume-BitLockerIfNeeded
}
