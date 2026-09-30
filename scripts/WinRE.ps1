<#
.SYNOPSIS
    Self-Healing Windows Recovery Environment (WinRE) Manager - Production

.NOTES
    Version : 44 (v44 patch 2)

    Manages the Windows Recovery Environment on managed Windows 10/11
    fleets. Downloads a base WinRE image, injects OEM and VMD drivers,
    deploys it to a dedicated recovery partition, and enables WinRE via
    reagentc. Maintains idempotency via a DesiredStateId state file.

    Full version history (v25 through v43 and all v43 patches) lives in
    CHANGELOG.md. This header records only the current design invariants
    and the lessons that must survive refactoring.

    ================================================================
    Current BitLocker policy (v43 patch 5, further revision 5, 2026-09-29)
    ================================================================

    The policy is target-volume-based, driven by field evidence.

    What changed:

    1. reagentc's BitLocker check is on the TARGET volume, not the OS
       volume. Proven by a same-machine test: with C: in the
       FullyEncrypted/no-protectors state, `reagentc /enable` against
       a dedicated recovery partition succeeds while `reagentc /enable`
       against the OS volume fails with "Windows RE cannot be enabled
       on a volume with BitLocker Drive Encryption enabled."

    2. A partition claimed by Device Encryption does not re-encrypt
       after `manage-bde -off` completes. Confirmed by the same test.

    Removed:

    - The startup BitLocker gate (it deferred on the OS volume state
      when the OS volume state is irrelevant to enable-only work).
    - Suspend-BitLockerForWinRE and Test-BitLockerSuspended. Suspension
      does not prevent Device Encryption from claiming new partitions.
    - The internal BitLocker check in Invoke-ReagentcEnable and its
      "blunsafe" return value.
    - The encrypted-partition delete-and-recreate retry in
      Ensure-AdequateRecoveryPartition (it never worked).

    Added:

    - Set-RecoveryPartitionReadyForWinRE: prepares the target partition
      by running `manage-bde -off` if needed and polling
      Test-VolumeEncrypted until the volume is confirmed unencrypted.
      5s poll interval, 300s timeout.
    - Call sites at the point of action: enable-only path, full-update
      existing-partition path, full-update new-partition path, and the
      pending-reboot repair path.
    - OS-fallback gate: reagentc refuses to enable WinRE on an
      encrypted OS volume, so the OS-fallback path checks C:'s
      VolumeStatus before deploying and defers unless it is
      FullyDecrypted. The script never modifies C:'s BitLocker state.

    Audit Mode guard (unchanged):

    In Audit Mode, OOBE, and the sysprep generalize/specialize phases,
    reagentc /enable fails with ERROR_CANCELLED (0x4c7) regardless of
    WIM correctness. The script reads
    HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State\ImageState
    at startup and defers with EXIT_WARNING unless the value is absent
    or IMAGE_STATE_COMPLETE.

    Enable-failure counter and loop-breaker:

    The state file records LastEnableResult and EnableFailureAttempts.
    After 3 consecutive terminal failures (failed / bitlocker /
    decryption timeout), the loop-breaker exits EXIT_FATAL with an
    actionable message. The fast path clears stale counters.

    ================================================================
    Component cleanup and ResetBase (v44 patch 2)
    ================================================================

    On the full-update path, after driver injection completes and
    before the image is dismounted, the script runs:

        dism /image:<MountDir> /cleanup-image /StartComponentCleanup /ResetBase

    ResetBase removes superseded components from the WinSxS store
    inside the mounted image. The size reduction does not materialise
    in the .wim file on disk until the image is re-exported; the
    existing Step 4 dism /Export-Image /Compress:max is what writes a
    smaller file. Without the export, ResetBase is wasted CPU.

    ResetBase makes the image unserviceable for rollback purposes: any
    update that was present when the command ran can no longer be
    uninstalled. This is acceptable for a recovery image, which is
    rebuilt from source whenever the DesiredStateId changes and is
    never rolled back in place.

    ResetBase runs only when $Script:ImageInjectionComplete is $true.
    If injection failed, the pipeline aborts before Step 4, so a
    successful ResetBase on a partially-injected image would waste CPU
    for no benefit. ResetBase failure is non-fatal: the log records a
    WARN with the DISM exit code, the pipeline continues, and the
    Step 4 export writes whatever size the image currently is. The
    Step 5 partition acceptance check decides whether the result fits.

    ScriptVersion remains 44. DesiredStateId is unchanged. No
    fleet-wide rebuild is forced: healthy machines continue to take
    the fast path with their current WIM, and only receive the
    ResetBase'd WIM on their next natural rebuild.

    The technique was adopted from Microsoft's KB5028997 remediation
    scripts (WinREPathScriptSamples), which use the same pair of
    operations to make winre.wim fit an existing recovery partition.

    ================================================================
    Design invariants
    ================================================================

    - Dedicated recovery partition is the target. OS-fallback
      (C:\Recovery\WindowsRE) is the degraded alternative and only
      when C: is FullyDecrypted.
    - Single state file at C:\Recovery\OEM\winre_state.json.
    - DesiredStateId =
      SHA256(HW=mfr|model|mt;;OS=build;;CPU=vendor|gen;;VMD=present|absent;;MANIFEST=version;;OEMPACK=version|NONE;;SCRIPT=44)
    - DesiredStateId includes CPU vendor/generation and VMD presence
      because those determine VMD driver selection. A machine whose VMD
      state changes (BIOS update, firmware re-default, deliberate
      config change) must rebuild even when Manufacturer / Model /
      MachineType, OS build, and manifest version are unchanged.
    - GPT recovery type GUID de94bba4-06d1-4d40-a16a-bfd50179d6ac and
      attributes 0x8000000000000001 applied at partition creation.
    - Drive letters removed before reagentc /enable; temporary letters
      tracked in $Script:tempDriveLetters and cleaned in the finally
      block.
    - Recovery partition free space: existing-partition acceptance
      requires (SizeRemaining + existing WIM) >= WIM + 250 MiB.
      New-partition sizing = WIM + 250 + 30 MiB, rounded up to the
      next 100 MiB, minimum 1000 MiB.
    - Idempotency: DesiredStateId match + healthy state -> fast path,
      no rebuild.
    - Checkpoint gates: step 3/4/6 checkpoint writes gated on
      $Script:ImageInjectionComplete; migration guard resets $step to
      2 when a checkpoint at step >= 4 coincides with $needInject.
    - Post-resize verification via Assert-PartitionSizeAfterResize.
    - $Script:GeometryRestoreFailed is set by any failure to restore
      C: to SizeMax after a post-shrink failure. Write-WinREState
      deletes the state file when it is set, forcing a retry.

    ================================================================
    Known gaps (documented; not yet implemented)
    ================================================================

    - Recovery-typed partition sanity ceiling. Get-RecoveryPartitions
      matches partitions by the recovery GPT type GUID
      (de94bba4-06d1-4d40-a16a-bfd50179d6ac) or MBR type 0x27, and the
      destructive path in Ensure-AdequateRecoveryPartition will delete
      any such partition on the OS disk. Windows Setup and Windows
      in-place upgrade create recovery partitions under 1.5 GiB. OEM
      factory recovery volumes can be 7-20 GiB and may carry the
      standard recovery type code. On a machine where an OEM factory
      recovery volume carries the recovery type code, this script
      treats it as a candidate and deletes it.

      A 2 GiB sanity ceiling is planned but not yet implemented. It
      would WARN and skip (not abort) any recovery-typed candidate
      whose size exceeds 2 GiB, leaving the oversized partition in
      place and creating a new recovery partition alongside it.

      Until the ceiling is implemented, operators deploying this
      script should verify the machine has no oversized recovery-typed
      partition containing data they want to preserve. See the
      "Before you run this" section in README.md for the operator-
      facing warning.

    ================================================================
    CRITICAL LESSONS LEARNED (do not regress)
    ================================================================

    - Do NOT use 7-Zip as the primary extractor for Lenovo or HP EXEs.
      Use the vendor's own EXE with the vendor's switches.
    - Do NOT rename vendor downloads to a generic name before
      extraction. The extractor may rely on the filename.
    - Do NOT swallow Add-WindowsDriver errors; capture with
      -ErrorVariable and log the first 5 lines.
    - Always count .inf files after extraction.
    - The state-write gate must not be relaxed.
    - Invoke-WebRequest can throw an exception even when the download
      completed successfully. Always verify the file after the
      download attempt, not only inside the try block.
    - [PSCustomObject]@{} objects may not accept new properties via
      dot-assignment. Use Add-Member -Force or declare up-front.
    - In double-quoted PowerShell strings, "$word:" is parsed as a
      scope or drive qualifier. Use "${word}:" or "$($expr):" when a
      literal colon must follow a variable reference.
    - Add-WindowsDriver's returned objects do not reliably expose an
      Operation property across DISM builds. Use the third-party
      driver count delta via Get-WindowsDriver instead.
    - manage-bde -status on a BitLocker-unmanaged volume emits "could
      not be opened by BitLocker". That is definitive proof the
      volume is not encrypted, not an unknown state.
    - Prefer build-agnostic manage-bde text parsing to
      -protectionaserrorlevel. The flag misbehaves on some builds.
    - OEM and VMD injection success cannot be judged by provider
      count alone. Cross-reference the package's INF basenames
      against the image's third-party driver OriginalFileName values.
    - Self-referential file operations must be guarded by comparing
      [System.IO.Path]::GetFullPath on both sides.
    - The recovery partition offset is rounded UP to the next 1 MiB
      boundary. Shrink by (bucket + 1) MiB to leave alignment slack.
    - The Audit Mode guard must run before any state-modifying action.
    - reagentc's BitLocker check is on the target volume. Prepare the
      target; do not gate on C:'s state. Only the OS-fallback path
      gates on C:'s state, because there the target IS the OS volume.
    - A recovery partition claimed by Device Encryption does not
      re-encrypt after manage-bde -off. Decrypt in place.
    - Get-RecoveryPartitions matches by type code, not by size or by
      content. OEM factory recovery volumes that carry the standard
      recovery type code are indistinguishable from Windows Setup's
      recovery partition to the matcher. No size ceiling is
      implemented yet; see the Known gaps section above.
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

$ScriptVersion = 44

# =========================== CONFIG ===========================
$DriverManifestUrl         = "https://gist.github.com/52250179/4d98029c7b39240cdb860ee3c78c3ca9/raw"
$BaseWinRERepoApi          = "https://api.github.com/repos/52250179/OriginalWindowsREImages/contents"
$7Zip                      = "C:\Program Files\7-Zip\7z.exe"
$WorkDir                   = "C:\Temp\WinREWork"
$LogDir                    = "C:\ProgramData\OEM\Logs"
$StateFileName             = "winre_state.json"
$CheckpointFile            = "$LogDir\winre_checkpoint.txt"
$WinREFreeSpaceMiB         = 250
$NewPartitionFilesystemMiB = 30
$NewPartitionIncrementMiB  = 100
$NewPartitionMinimumMiB    = 1000
$LenovoWinPEMapUrl         = "https://gist.github.com/52250179/8211b75a38444caa68b8cebd7529376c/raw"
$HPWinPEMapUrl             = "https://gist.github.com/52250179/07f9c3db08e5ef27daca1e7ff700af35/raw"
$DellWinPEMapUrl           = "https://gist.github.com/52250179/52058dde0701c749be627c9601c5c925/raw"

$GitHubHeaders = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36' }

# =========================== SCRIPT STATE ===========================
$Script:tempDriveLetters       = [System.Collections.Generic.List[string]]::new()
$Script:DryRun                 = $DryRun
$Script:rebootRequired         = $false
$Script:nonFatalWarning        = $false
$Script:ImageInjectionComplete = $true
$Script:UsedOSFallback         = $false
$Script:GeometryRestoreFailed  = $false
$Script:CachedHardware         = $null
$Script:LenovoWinPEMap         = $null
$Script:HPWinPEMap             = $null
$Script:DellWinPEMap           = $null

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
    if (-not $Path) { return }
    if (-not (Test-Path $Path)) { return }
    if (Test-Path $Path -PathType Container) {
        if ($Recurse) { Remove-Item $Path -Force -Recurse -ErrorAction SilentlyContinue }
        else          { Remove-Item $Path -Force -ErrorAction SilentlyContinue }
    } else {
        Remove-Item $Path -Force -ErrorAction SilentlyContinue
    }
    Write-Log "Removed: $Path"
}

function Write-FileAtomically {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [int]$MaxRetries = 3
    )
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $tempFile = Join-Path $dir ("{0}.tmp_{1}" -f (Split-Path $Path -Leaf), [guid]::NewGuid().ToString('N').Substring(0,8))
    try {
        [System.IO.File]::WriteAllText($tempFile, $Content, [System.Text.UTF8Encoding]::new($false))
    } catch {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        throw "Atomic write temp failed: $_"
    }
    for ($retry = 0; $retry -lt $MaxRetries; $retry++) {
        try { Move-Item -Path $tempFile -Destination $Path -Force -ErrorAction Stop; return }
        catch {
            if ($retry -eq ($MaxRetries - 1)) {
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                throw "Atomic write move failed: $_"
            }
            Start-Sleep -Seconds ([math]::Pow(2, $retry))
        }
    }
}

# =========================== CHECKPOINT ===========================
function Get-Checkpoint {
    param(
        [Parameter(Mandatory)][string]$CheckpointFile,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentDesiredStateId
    )
    if (-not (Test-Path $CheckpointFile)) {
        return @{ Step = 0; DesiredStateId = $null; Valid = $true }
    }
    try {
        $raw   = (Get-Content $CheckpointFile -Raw).Trim()
        $parts = $raw -split '\|', 2
        $step  = [int]$parts[0]
        $storedId = if ($parts.Count -gt 1) { $parts[1] } else { $null }
        if (-not $storedId) { return @{ Step = 0; DesiredStateId = $null; Valid = $false } }
        if ($storedId -ne $CurrentDesiredStateId) {
            return @{ Step = 0; DesiredStateId = $storedId; Valid = $false }
        }
        return @{ Step = $step; DesiredStateId = $storedId; Valid = $true }
    } catch {
        return @{ Step = 0; DesiredStateId = $null; Valid = $false }
    }
}

function Set-Checkpoint {
    param(
        [Parameter(Mandatory)][string]$CheckpointFile,
        [Parameter(Mandatory)][int]$Step,
        [Parameter(Mandatory)][AllowEmptyString()][string]$DesiredStateId
    )
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
        $regPath  = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinRE"
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

# Return the disk that contains the running Windows installation.
# Every use of "the boot disk" in this script means "the disk where
# Windows lives and where the recovery partition belongs". That is the
# disk of the OS partition, not necessarily the disk the firmware
# booted from (MSFT_Disk.BootFromDisk). On virtually all configurations
# the two are identical, but on multi-boot or cloned systems whose boot
# files live on a different physical disk they can differ. Anchoring on
# the OS partition's DiskNumber removes the ambiguity.
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
    if ($Script:DryRun) {
        # Return the preferred letter without assigning it. Callers that
        # consume the letter for a real operation must check $Script:DryRun
        # first - see Ensure-RecoveryPartitionAccess and
        # Set-RecoveryPartitionReadyForWinRE for the pattern.
        return $preferred
    }

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
        # DryRun must not assign a drive letter. Return the original
        # GLOBALROOT path; the file system provider resolves it directly
        # for Test-Path, Get-Item, and Get-FileHash.
        if ($Script:DryRun) {
            Write-Log "[DRY RUN] Would assign a temporary drive letter to disk $diskNum part $partNum for image discovery"
            return $TargetDir
        }
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
        if ($Script:DryRun) {
            Write-Log "[DRY RUN] Would assign a temporary drive letter to volume {$guid} for image discovery"
            return $TargetDir
        }
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
# Three-state contract used across the recovery-partition paths:
#   $true  = encrypted or partially encrypted
#   $false = confirmed fully decrypted
#   $null  = could not determine
#
# Per Win32_EncryptableVolume.GetConversionStatus, all of
# FullyEncrypted, EncryptionInProgress, DecryptionInProgress,
# EncryptionPaused, and DecryptionPaused represent a volume that is
# not fully decrypted and must not be treated as clean.
#
# manage-bde -status on a BitLocker-unmanaged volume emits "could not
# be opened by BitLocker". For a properly-typed recovery partition
# (GUID de94bba4-06d1-4d40-a16a-bfd50179d6ac, attributes
# 0x8000000000000001) this is the expected output and is definitive
# proof the volume is not encrypted, not an unknown state.
#
# Prefer build-agnostic manage-bde text parsing to the
# -protectionaserrorlevel sub-parameter, which misbehaves on some
# Windows 11 builds.
function Test-VolumeEncrypted {
    param([string]$MountPoint)

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
    try {
        $mbo = & manage-bde.exe -status $MountPoint 2>&1
        $mboJoined = ($mbo | Out-String)
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

# Prepare a target recovery partition for reagentc /enable.
#
# reagentc's BitLocker check is on the TARGET volume, not the OS volume.
# Field evidence (2026-09-29): on a machine whose C: is
# FullyEncrypted/no-protectors, /enable against a dedicated recovery
# partition succeeds while /enable against the OS volume fails with
# "Windows RE cannot be enabled on a volume with BitLocker Drive
# Encryption enabled." The fix is therefore to make the target volume
# unencrypted, not to gate on C:'s state.
#
# If the target is already unencrypted, returns immediately. If it is
# encrypted or actively encrypting, runs manage-bde -off and polls
# Test-VolumeEncrypted until it reports confirmed-unencrypted
# (FullyDecrypted, or "could not be opened by BitLocker"). Returns
# $true on success, $false on timeout or unrecoverable failure.
#
# A recovery partition claimed by Device Encryption does not re-encrypt
# after manage-bde -off completes; confirmed by the same field test
# (R: stayed unmanaged after decryption). This makes decrypt-in-place
# safe and replaces the previous delete-and-recreate retry, which
# never worked on the Dell.
#
# Poll policy: 5-second interval, 300-second timeout (60 polls). A 1 GB
# recovery partition decrypts in well under a minute on NVMe; the
# timeout is generous for HDDs and loaded systems.
#
# The caller is responsible for removing any drive letter this function
# may assign. The letter is added to $Script:tempDriveLetters so the
# script's finally block cleans it up if the caller forgets.
#
# -DryRun: logs the intent and returns $true without touching the volume.
function Set-RecoveryPartitionReadyForWinRE {
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][int]$PartitionNumber,
        [int]$PollIntervalSeconds = 5,
        [int]$PollTimeoutSeconds  = 300
    )

    $part = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction SilentlyContinue
    if (-not $part) {
        Write-Log "Set-RecoveryPartitionReadyForWinRE: partition $DiskNumber/$PartitionNumber not found" -Level ERROR
        return $false
    }

    if ($Script:DryRun) {
        Write-Log "[DRY RUN] Would ensure partition $DiskNumber/$PartitionNumber is unencrypted - decrypt in place with manage-bde -off if needed, poll for Fully Decrypted up to ${PollTimeoutSeconds}s"
        return $true
    }

    $letter = $part.DriveLetter
    if (-not $letter) {
        $avail = Get-AvailableDriveLetter
        if (-not $avail) {
            Write-Log "Set-RecoveryPartitionReadyForWinRE: no drive letter available for target partition" -Level ERROR
            return $false
        }
        $assigned = Invoke-DriveLetterAssignment -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -PreferredLetter $avail
        if (-not $assigned) {
            Write-Log "Set-RecoveryPartitionReadyForWinRE: could not assign a drive letter to $DiskNumber/$PartitionNumber" -Level ERROR
            return $false
        }
        $letter = $assigned
        if (-not $Script:tempDriveLetters.Contains($assigned)) { $Script:tempDriveLetters.Add($assigned) }
    }

    $state = Test-VolumeEncrypted -MountPoint "${letter}:"
    if ($state -eq $false) {
        Write-Log "Target partition $DiskNumber/$PartitionNumber (${letter}:) is already unencrypted - reagentc /enable can proceed"
        return $true
    }

    if ($null -eq $state) {
        # Indeterminate. Give it one retry after a short pause - the
        # BitLocker service can briefly report an unparseable state right
        # after partition creation.
        Write-Log "Target partition $DiskNumber/$PartitionNumber (${letter}:) encryption state indeterminate - sleeping ${PollIntervalSeconds}s and re-checking" -Level WARN
        Start-Sleep -Seconds $PollIntervalSeconds
        $state = Test-VolumeEncrypted -MountPoint "${letter}:"
        if ($state -eq $false) {
            Write-Log "Target partition $DiskNumber/$PartitionNumber (${letter}:) is unencrypted on re-check - reagentc /enable can proceed"
            return $true
        }
    }

    Write-Log "Target partition $DiskNumber/$PartitionNumber (${letter}:) is BitLocker-managed (state=$state) - running manage-bde -off to decrypt"
    try {
        $offOutput = & manage-bde.exe -off "${letter}:" 2>&1
        $offJoined = ($offOutput | Out-String)
        Write-Log "manage-bde -off ${letter}: output: $offJoined"
    } catch {
        Write-Log "manage-bde -off ${letter}: failed: $_" -Level ERROR
        return $false
    }

    # manage-bde -off is asynchronous. Poll Test-VolumeEncrypted until it
    # reports confirmed-unencrypted or the timeout expires.
    $elapsed   = 0
    $lastState = $state
    while ($elapsed -lt $PollTimeoutSeconds) {
        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsed  += $PollIntervalSeconds
        $lastState = Test-VolumeEncrypted -MountPoint "${letter}:"
        if ($lastState -eq $false) {
            Write-Log "Target partition ${letter}: confirmed unencrypted after ${elapsed}s - reagentc /enable can proceed"
            return $true
        }
    }

    Write-Log "Target partition ${letter}: did not decrypt within ${PollTimeoutSeconds}s (last state=$lastState) - refusing to call reagentc /enable against an encrypted volume" -Level ERROR
    return $false
}

# =========================== RECOVERY PARTITION DETECTION ===========================
# Broad detector: matches partitions by Recovery/WINRE label, GPT recovery
# type GUID, or MBR type 0x27. Used on the OS disk. The narrower
# type-code-only trust policy for non-OS-disk deletion is applied at
# Remove-StrayRecoveryPartitions.
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

# Remove every type-coded recovery partition that is not on the OS disk.
# The invariant is: no type-coded recovery partition exists on any
# non-OS disk. Windows Setup and Startup Repair scan all attached
# volumes for WinRE-capable partitions; a stray can point the BCD at
# the wrong image during repair.
#
# The type-code gate (GPT DE94... or MBR 0x27) distinguishes "recovery
# partition that could confuse the boot loader" from "data partition
# that happens to carry the Recovery/WINRE label". On non-OS disks, a
# label-only match is never sufficient authority to delete a partition.
#
# Called from the idempotent fast path, the enable-only path, the
# pending-reboot exits, and Step 7 of the full-update path.
#
# Returns $true if every type-coded stray was removed (or none was
# present), $false if any deletion failed. A failure also sets
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
        # Use the volume's own drive letter when available so we do not
        # build a path from a letter that may not exist on the volume
        # (relevant in DryRun and after a racing letter removal).
        $effectiveLetter = if ($vol.DriveLetter) { $vol.DriveLetter } else { $Letter.TrimEnd(':') }
        $existingWimPath = "${effectiveLetter}:\Recovery\WindowsRE\winre.wim"
        $existingWimSize = 0
        try {
            if (Test-Path -LiteralPath $existingWimPath -ErrorAction Stop) {
                $existingWimSize = (Get-Item -LiteralPath $existingWimPath -Force -ErrorAction Stop).Length
            }
        } catch { }
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
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][int]$PartitionNumber,
        [Parameter(Mandatory)][string]$Style
    )
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
    } catch {
        Write-Log "Failed to set recovery attributes: $_" -Level WARN
        return $false
    }
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
# Re-extend the OS partition to its current SizeMax. Called from every
# post-shrink failure path in Ensure-AdequateRecoveryPartition so no
# failure leaves C: permanently shrunken.
#
# Returns $true if the OS partition is at SizeMax on return (or was
# already), $false if the resize failed or verification failed. Any
# failure sets both $Script:nonFatalWarning and
# $Script:GeometryRestoreFailed; the latter causes Write-WinREState to
# delete the state file so the next run retries from a clean slate
# rather than accepting a state file that describes a shrunken C:.
function Restore-OSPartitionSize {
    param([Parameter(Mandatory)][string]$Reason)

    if ($Script:DryRun) { Write-Log "[DRY RUN] Would re-extend OS partition ($Reason)"; return $true }

    $osPart = Get-OSPartition
    if (-not $osPart) {
        Write-Log "Restore-OSPartitionSize: OS partition not found ($Reason)" -Level WARN
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
            $Script:nonFatalWarning = $true
            $Script:GeometryRestoreFailed = $true
            return $false
        }
        return $true
    } catch {
        Write-Log "Restore-OSPartitionSize failed ($Reason): $_" -Level WARN
        $Script:nonFatalWarning = $true
        $Script:GeometryRestoreFailed = $true
        return $false
    }
}

# Clean up a partition we created but could not complete. Used when
# Format-Volume fails or when the target cannot be made unencrypted,
# so the freshly created partition does not survive as an orphan with
# a default GPT type, no label, and no filesystem - a combination
# Get-RecoveryPartitions cannot match, which would leave the orphan
# permanently invisible and silently bound the OS partition's SizeMax
# at its start.
#
# Uses the same delete-first / diskpart-override-second pattern as the
# main deletion loop. Returns $true when the partition is confirmed
# gone, $false when it survived (in which case the geometry-failure
# flags are set so the state file is invalidated).
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
        # If the orphan survives, C: is still shrunken and the space it
        # consumed cannot be re-extended into it. Set the geometry-failure
        # flags so Write-WinREState refuses to record the resulting
        # layout as a valid state.
        $Script:nonFatalWarning = $true
        $Script:GeometryRestoreFailed = $true
        return $false
    }
    Write-Log "Removed orphan partition $DiskNumber/$PartitionNumber after $Reason"

    # Absorb the freed space back into the OS partition.
    Restore-OSPartitionSize -Reason "after orphan removal" | Out-Null
    return $true
}

function Ensure-AdequateRecoveryPartition {
    param([int]$RequiredWimSizeMB)

    # Dynamic new-partition sizing: WIM + 250 MiB free-space target +
    # 30 MiB filesystem allowance, rounded UP to the next 100 MiB
    # boundary and clamped to a 1000 MiB minimum. The 250 MiB target
    # matches Microsoft's current WinRE servicing guidance.
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

    $case1Safe  = (($S - $B) -ge $M)
    $case3Fatal = (($S + $R - $B) -lt $M)

    if ($case1Safe) {
        Write-Log "Pre-check: current OS partition can shrink by bucket size without reclaiming recovery space (safe path)"
    } else {
        Write-Log "WARNING: Pre-check indicates current OS partition cannot shrink by bucket size alone." -Level WARN
        Write-Log "WARNING: Destructive path required: delete recovery partitions, extend OS, then shrink OS." -Level WARN
        Write-Log "WARNING: If the final shrink fails, recovery partitions will have been destroyed. No rollback." -Level WARN
    }

    # Dedicated recovery partition is the primary objective. The capacity
    # pre-check is advisory only - we proceed with the destructive
    # repartitioning attempt even when the arithmetic suggests the OS may
    # not shrink enough. SizeMin is a conservative hint and can be
    # pessimistic when the volume has movable files; the defrag retry in
    # the shrink path may still succeed.
    if ($case3Fatal) {
        Write-Log "WARNING: Capacity pre-check: S=$([math]::Round($S/1MB,1)) MiB, R=$([math]::Round($R/1MB,1)) MiB, B=$([math]::Round($B/1MB,1)) MiB, M=$([math]::Round($M/1MB,1)) MiB. S+R-B=$([math]::Round(($S+$R-$B)/1MB,1)) MiB < M - the OS partition may not shrink enough for a dedicated recovery partition." -Level WARN
        Write-Log "WARNING: Proceeding with destructive repartitioning attempt anyway (dedicated recovery partition is the primary objective)." -Level WARN
        Write-Log "WARNING: If the OS shrink fails, recovery partitions will have been deleted and cannot be restored. No rollback." -Level WARN
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

    # DryRun terminates here, after the read-only pre-checks and
    # pre-deletion inventory and before any state-modifying action. This
    # is the single structural choke point for the DryRun guarantee in
    # this function: no future code inserted below can accidentally
    # modify the machine under DryRun without first overriding this
    # early return.
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

    # Add 1 MiB of alignment slack: the new partition offset below rounds
    # the OS end UP to the next MiB boundary, and without slack that
    # rounding can consume part of the requested bucket and leave the
    # tail slightly too short for the new partition.
    $shrinkBytes = [int64](($bucketSizeMiB + 1) * 1MB)
    $osPart = Get-OSPartition
    if (-not $osPart) { Write-Log "OS partition lost before shrink - FATAL" -Level ERROR; return $null }
    $initialOSSize = [int64]$osPart.Size
    $expectedAfterShrink = $initialOSSize - $shrinkBytes

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

    # --- Attempt 2: sleep and retry ---
    # The v38 ASUS field log showed attempt 1 failing with "Size Not
    # Supported" and attempt 2 succeeding after a defrag, but did not
    # establish whether the defrag was the cause or whether something
    # time-based lowered SizeMin. Attempt 2 settles that question on
    # every run where attempt 1 fails.
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
        # Resize-Partition and Assert-PartitionSizeAfterResize are not
        # atomic. If Resize succeeded but verification failed, C: may
        # already be shrunken. Restore before returning so no failure
        # path leaves C: permanently shrunken.
        Write-Log "Restoring OS partition size before falling back to OS-fallback." -Level WARN
        Restore-OSPartitionSize -Reason "shrink failed after all three attempts" | Out-Null
        Write-Log "Returning null - main flow will attempt OS-partition fallback (C:\Recovery\WindowsRE)." -Level ERROR
        return $null
    }

    $osPart = Get-OSPartition
    $osEnd  = $osPart.Offset + $osPart.Size
    $newOffset = [Math]::Ceiling($osEnd / 1MB) * 1MB
    $newSize   = [int64]($bucketSizeMiB * 1MB)
    $availableSpace = [int64](Get-Disk -Number $osPart.DiskNumber).Size - $newOffset
    if ($availableSpace -lt $newSize) {
        Write-Log "Not enough space at offset $newOffset for $newSize bytes (available $availableSpace)" -Level ERROR
        Restore-OSPartitionSize -Reason "insufficient space at new-partition offset" | Out-Null
        return $null
    }

    # Create the partition with the recovery type GUID/type code already
    # applied. This closes the window between New-Partition and
    # Set-RecoveryPartitionAttributes during which the partition looks
    # like a Basic Data partition.
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

    try {
        Format-Volume -Partition $newPart -FileSystem NTFS -NewFileSystemLabel 'Recovery' -Confirm:$false -Force | Out-Null
    } catch {
        Write-Log "Format-Volume failed: $_" -Level ERROR
        Remove-OrphanPartition -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Reason "Format-Volume failure (main path)" | Out-Null
        return $null
    }
    Start-Sleep 3

    # Set recovery type and GPT attributes BEFORE assigning a drive
    # letter. A freshly-formatted NTFS partition with a normal data type
    # and a drive letter is a candidate for Device Encryption /
    # BitLocker auto-encryption on Windows 11 24H2+. Applying the
    # recovery type GUID and 0x8000000000000001
    # (PLATFORM_REQUIRED + NO_DRIVE_LETTER) first tells BitLocker this
    # is not a data volume.
    $attrsOk = Set-RecoveryPartitionAttributes -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Style $style
    if (-not $attrsOk) {
        Write-Log "Could not set recovery attributes on newly created partition - proceeding but BitLocker may encrypt it" -Level WARN
    }

    # Prefer a letter we already used in this run for a recovery
    # partition, then any other available letter. Windows caches
    # letter-to-volume mappings in MountedDevices; reusing a letter
    # we held earlier is more likely to succeed cleanly than picking
    # a fresh one, and it avoids the "assigned, removed, reassigned"
    # churn that can leave stale entries.
    $preferredLetter = $null
    foreach ($prev in $Script:tempDriveLetters) {
        # Only reuse if the letter is now free
        if (-not (Get-Volume -DriveLetter $prev -ErrorAction SilentlyContinue)) {
            $preferredLetter = $prev
            break
        }
    }
    if (-not $preferredLetter) { $preferredLetter = Get-AvailableDriveLetter }
    if (-not $preferredLetter) {
        Write-Log "No drive letter available" -Level ERROR
        Remove-OrphanPartition -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Reason "no drive letter available" | Out-Null
        return $null
    }
    $assignedLetter = Invoke-DriveLetterAssignment -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -PreferredLetter $preferredLetter
    if (-not $assignedLetter) {
        Write-Log "Could not assign ANY drive letter to new recovery partition" -Level ERROR
        Remove-OrphanPartition -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Reason "drive-letter assignment failed" | Out-Null
        return $null
    }
    $Script:tempDriveLetters.Add($assignedLetter)

    Start-Sleep 5
    $encNewState = Test-VolumeEncrypted -MountPoint "${assignedLetter}:"
    if ($null -eq $encNewState) {
        Write-Log "Newly created recovery partition encryption state unknown - proceeding; Set-RecoveryPartitionReadyForWinRE will retry at the deploy step" -Level WARN
    }
    if ($encNewState -eq $true) {
        # Decrypt in place rather than delete-and-recreate. A partition
        # claimed by Device Encryption does not re-encrypt after
        # manage-bde -off completes (field evidence 2026-09-29),
        # so decrypting preserves the partition we just created.
        Write-Log "Newly created recovery partition is BitLocker-managed - decrypting in place" -Level WARN
        if (-not (Set-RecoveryPartitionReadyForWinRE -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber)) {
            Write-Log "Could not make newly created recovery partition unencrypted - aborting recovery partition creation" -Level ERROR
            Remove-OrphanPartition -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Reason "in-place decryption failed" | Out-Null
            return $null
        }
        Write-Log "Newly created recovery partition decrypted in place"
    } elseif ($encNewState -eq $false) {
        Write-Log "Verified new recovery partition is not encrypted"
    }

    New-DirectoryIfNotExists "${assignedLetter}:\Recovery\WindowsRE"
    Write-Log "Created fresh recovery partition at ${assignedLetter}:"
    return @{ DriveLetter = $assignedLetter; DiskNumber = $osDisk.Number; PartitionNumber = $newPart.PartitionNumber }
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
    # Acceptance floor is WIM + WinREFreeSpaceMiB (250). Same standard as
    # the new-partition sizing target and the OS's own pre-update WinRE
    # check. No tolerance.
    $requiredBytes = [int64](($RequiredWimSizeMB + $WinREFreeSpaceMiB) * 1MB)

    foreach ($candidate in $parts) {
        if ($osPart -and $candidate.DiskNumber -eq $osPart.DiskNumber -and $candidate.PartitionNumber -eq $osPart.PartitionNumber) {
            Write-Log "Find-SuitableRecoveryPartition: candidate $($candidate.PartitionNumber) is the OS partition - skip"
            continue
        }
        if ($candidate.Size -lt $requiredBytes) {
            Write-Log "Find-SuitableRecoveryPartition: candidate $($candidate.PartitionNumber) total size $([math]::Round($candidate.Size/1MB,1)) MiB < required $([math]::Round($requiredBytes/1MB,1)) MiB"
            continue
        }
        # Encryption state is no longer a rejection criterion. reagentc's
        # BitLocker check is on the TARGET volume, and
        # Set-RecoveryPartitionReadyForWinRE decrypts the target in place
        # before reagentc /enable is called. An existing encrypted
        # recovery partition is therefore usable.

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
# Wraps reagentc /enable. Returns:
#   "ok"        - exit 0 and status Enabled (or repair produced Enabled)
#   "reboot"    - exit 0 or repair path did not produce Enabled
#   "failed"    - non-zero exit that is not the BitLocker error
#   "bitlocker" - reagentc refused because the target volume is
#                 BitLocker-protected. Callers decide whether to retry
#                 after preparing the target or to defer.
#
# The internal BitLocker check and the "blunsafe" return value were
# removed in v43 patch 5 (further revision 5). reagentc's BitLocker
# check is on the TARGET volume, not C:, and the caller is now
# responsible for making the target unencrypted via
# Set-RecoveryPartitionReadyForWinRE before calling this function.
function Invoke-ReagentcEnable {
    param(
        [switch]$AllowTempLetter,
        [hashtable]$Partition = $null,
        [string]$ReRegisterPath = $null
    )

    # DryRun must not call reagentc /enable. Log the intent and return
    # "ok" - the closest approximation of a successful live run that can
    # be made without running reagentc. Callers' "ok" branches are
    # DryRun-safe: Remove-StrayRecoveryPartitions, Write-WinREState, and
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

    # Detect the BitLocker-specific failure. If the target volume is
    # BitLocker-encrypted, reagentc refuses with exit 2 and the message
    # "Windows RE cannot be enabled on a volume with BitLocker Drive
    # Encryption enabled." The caller is responsible for deciding
    # whether to defer or retry after preparing the target.
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

    # DryRun: this function deletes ReAgent.xml and ReAgent_merged.xml and
    # calls reagentc /setreimage followed by reagentc /enable. None of
    # that may run under DryRun. The only current caller
    # (Invoke-ReagentcEnable) already returns "ok" before reaching this
    # function under DryRun, but the guard is placed here so the function
    # upholds the contract on its own rather than relying on its caller.
    if ($Script:DryRun) {
        Write-Log "[DRY RUN] Would rebuild WinRE registration (delete ReAgent.xml / ReAgent_merged.xml, reagentc /setreimage, reagentc /enable) using path: $ReRegisterPath"
        return $true
    }

    if (-not $ReRegisterPath) {
        Write-Log "Registration repair requested but no ReRegisterPath provided - cannot safely rebuild registration" -Level ERROR
        return $false
    }

    $reagentXml = Join-Path $env:windir "System32\Recovery\ReAgent.xml"
    $mergedXml  = Join-Path $env:windir "System32\Recovery\ReAgent_merged.xml"

    # NOTE: C:\Recovery\ReAgentOld.xml is deliberately NOT touched. That
    # file is the downlevel / servicing configuration used by Windows
    # Setup. Manual test confirmed its deletion does not resolve the
    # issue.
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

    $manufacturerRaw = if ($cs.Manufacturer) { $cs.Manufacturer.Trim() } else { "" }
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

    $model = if ($cs.Model) { $cs.Model.Trim() } else { "" }
    $version = $product.Version
    $machineType = "UNKN"
    if ($Manufacturer -eq "LENOVO") {
        if ($model -match '^([A-Z0-9]{4})')             { $machineType = $Matches[1]; Write-Log "Lenovo machine type from ComputerSystem.Model: $machineType" }
        elseif ($product.Name -match '^([A-Z0-9]{4})')  { $machineType = $Matches[1]; Write-Log "Lenovo machine type from ComputerSystemProduct.Name: $machineType" }
        elseif ($board -and $board.Product -match '^([A-Z0-9]{4})') { $machineType = $Matches[1]; Write-Log "Lenovo machine type from BaseBoard.Product: $machineType" }
        elseif ($version -and $version.Length -ge 4)    { $machineType = $version.Substring(0,4); Write-Log "Lenovo machine type from Version (fallback): $machineType" }
        else { Write-Log "Could not determine Lenovo machine type" -Level WARN }
    } else {
        if ($version -and $version.Length -ge 4) { $machineType = $version.Substring(0,4) }
    }

    $Script:CachedHardware = [PSCustomObject]@{
        Manufacturer  = $Manufacturer
        Model         = $model
        MachineType   = $machineType
        CPUVendor     = if ($cpu.Manufacturer -like "*Intel*") { "Intel" } else { "AMD" }
        CPUGeneration = $gen
        Architecture  = "x64"
        OS            = $os.Caption
        IsWin10       = $os.Caption -like "*Windows 10*"
        IsWin11       = $os.Caption -like "*Windows 11*"
        WinPE         = if ($os.Caption -like "*Windows 11*") { "11" } else { "10" }
        Build         = $os.BuildNumber
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
    [PSCustomObject]@{
        Manufacturer   = "Dell"
        Name           = "Dell $($entry.dellVersion)"
        Version        = $entry.dellVersion
        DownloadUrl    = $entry.url
        ArchiveType    = "CAB"
        IsUrl          = $true
        ExpectedMD5    = $entry.md5
        ExpectedSHA256 = $entry.sha256
    }
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
    [PSCustomObject]@{
        Manufacturer   = "HP"
        Name           = "HP $($entry.softPaqId)"
        Version        = $entry.version
        DownloadUrl    = $entry.url
        ArchiveType    = "SoftPaq"
        IsUrl          = $true
        ExpectedMD5    = $null
        ExpectedSHA256 = $null
    }
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
        # Many Lenovo machine types have no published WinPE driver pack.
        # A loaded map with no entry for this MT is the expected,
        # permanent answer, not a transient failure. Logged at INFO so
        # it does not appear in the operator's "something to look at"
        # filter. The caller decides the run's completion state based on
        # whether the map loaded, not on whether this MT was present.
        Write-Log "No WinPE pack in Lenovo map for machine type $mt (expected for some Lenovo models)" -Level INFO
        return $null
    }
    $winpe = $entry.winpe
    if (-not $winpe -or -not $winpe.url) {
        Write-Log "Lenovo map entry for $mt has no WinPE URL" -Level WARN
        return $null
    }
    Write-Log "Lenovo map resolved $mt -> $($winpe.name) (SHA256: $($winpe.sha256))"
    [PSCustomObject]@{
        Manufacturer   = "LENOVO"
        Name           = $winpe.name
        Version        = $winpe.dsId
        DownloadUrl    = $winpe.url
        ArchiveType    = "EXE"
        IsUrl          = $true
        ExpectedMD5    = $null
        ExpectedSHA256 = $winpe.sha256
    }
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
    param($Hardware, $OEMPackage, $ExpectedDriverSetVersion, [bool]$VMDPresent = $false)
    $oemVersion = if ($OEMPackage -and $OEMPackage.Version) { $OEMPackage.Version } else { "NONE" }
    # CPUGeneration is $null for AMD and for Intel CPUs that do not
    # parse to a generation (Celeron, Pentium, Atom, Xeon, N/J-series).
    # Use the literal string "N" so the ID string is deterministic.
    # The "N" is stable: it will not silently flip on a re-run.
    $cpuGen = if ($Hardware.CPUGeneration) { $Hardware.CPUGeneration } else { "N" }
    $parts = @(
        "HW=$($Hardware.Manufacturer)|$($Hardware.Model)|$($Hardware.MachineType)",
        "OS=$($Hardware.Build)",
        "CPU=$($Hardware.CPUVendor)|$cpuGen",
        "VMD=$VMDPresent",
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
        CurrentImageHash         = $null
        InjectedDriverSetVersion = $null
        DesiredStateId           = $null
        PendingReboot            = $false
        DeployedDiskNumber       = $null
        DeployedPartitionNumber  = $null
        UsedOSFallback           = $false
        RepairAttempts           = 0
        LastEnableResult         = "ok"
        EnableFailureAttempts    = 0
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
        [object]$DeployedDiskNumber = $null,
        [object]$DeployedPartitionNumber = $null,
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
    if ($null -ne $DeployedDiskNumber -and [int]$DeployedDiskNumber -ge 0) { $state.DeployedDiskNumber = [int]$DeployedDiskNumber }
    if ($null -ne $DeployedPartitionNumber -and [int]$DeployedPartitionNumber -ge 0) { $state.DeployedPartitionNumber = [int]$DeployedPartitionNumber }

    $stateJson = $state | ConvertTo-Json -Depth 3
    $path = "$env:SystemDrive\Recovery\OEM\$StateFileName"

    # If a post-shrink failure left C: shrunken and Restore-OSPartitionSize
    # could not return it to SizeMax, do not leave any state file on disk
    # that could be accepted on a subsequent run. The state file is the
    # machine-readable "last known good deployment" record. If
    # GeometryRestoreFailed, the current deployment is NOT a known-good
    # record - C: is still reduced by (bucketSizeMiB + 1) MiB. Deleting
    # the file forces the next run to treat the state as absent, set
    # needInject = $true, and re-run the full-update path, which
    # re-extends C: as part of the destructive attempt.
    if ($Script:DryRun) { Write-Log "[DRY RUN] Would write state file"; return }

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

# =========================== OEM EXTRACTION HELPERS ===========================
function Get-DownloadFileName {
    param([Parameter(Mandatory)][string]$Url, [string]$FallbackName = "oem_pack")
    try {
        $uri  = [System.Uri]$Url
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

        if ($fileSize -le 0) {
            Write-Log "Downloaded file is empty - removing and retrying" -Level WARN
            Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue
            if ($retry -lt $MaxRetries) { Start-Sleep 5 }
            continue
        }

        $hasHash = [bool]$ExpectedSHA256 -or [bool]$ExpectedMD5
        if (-not $hasHash) {
            # No integrity hash supplied. Require Invoke-WebRequest itself
            # to have completed cleanly on this attempt. A partial file
            # left behind by a throwing request is not accepted.
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

    # ---- Audit Mode / OOBE / sysprep guard ----
    # In these transitional Windows states, reagentc /enable fails with
    # ERROR_CANCELLED (0x4c7, 1223) regardless of the correctness of the
    # deployed WIM or the state of the recovery partition. Confirmed
    # field case: Dell Latitude 5530. After OOBE, /enable succeeded on
    # the first attempt with the same WIM. The guard runs before any
    # WinRE registration, partition, image, checkpoint, or recovery-state
    # modification. It does not run before the log directory is created
    # or the startup banner is written; those are not deployment state.
    #
    # Proceed only when ImageState is absent (some SKUs omit the key) or
    # exactly IMAGE_STATE_COMPLETE. Any other value defers.
    $imageStatePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State"
    $imageState = $null
    try {
        $imageState = (Get-ItemProperty -Path $imageStatePath -Name ImageState -ErrorAction SilentlyContinue).ImageState
    } catch { }
    if ($imageState -and $imageState -ne "IMAGE_STATE_COMPLETE") {
        $auditVerb = if ($Script:DryRun) { "Would defer" } else { "Deferring" }
        Write-Log "$auditVerb WinRE Manager: Windows is not in a normal-running state (Setup\State\ImageState=$imageState). reagentc /enable is blocked with 0x4c7 during Audit Mode, OOBE, and the sysprep generalize/specialize phases regardless of WIM correctness. No WinRE or partition changes will be made." -Level WARN
        Write-Log "Complete OOBE, sign in to a normal desktop session, and re-run this script." -Level WARN
        if (-not $Script:DryRun) { exit $EXIT_WARNING }
    }

    # ---- Hardware, manifest, OEM pack ----
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

    # Get-OEMWinPEPack returns $null both for unsupported vendors and for
    # supported vendors whose pack did not resolve. For Dell and HP
    # (single-pack maps) a $null return always means the map failed to
    # load or its entry is malformed - both transient. For Lenovo, a
    # loaded map with no entry for this MT is the expected, permanent
    # answer for many models: the run is treated as legitimately
    # complete with OEMPACK=NONE in the DesiredStateId, and the fast
    # path fires on subsequent runs. If Lenovo later publishes a pack
    # for this MT, the DesiredStateId changes and the machine rebuilds
    # automatically.
    $oemVendorSupported = $Hardware.Manufacturer -in @("Dell", "HP", "LENOVO")
    if ($oemVendorSupported -and -not $OEMPackage) {
        # UNKN is also a permanent answer: if the machine type cannot be
        # resolved, no Lenovo pack can ever match, so the run is complete
        # with OEMPACK=NONE. Without this, the transient-failure branch
        # fires every run, no state file is written, and the machine
        # loops on EXIT_WARNING forever.
        $mapLoadedNoEntry = ($Hardware.Manufacturer -eq "LENOVO" -and
                             ($Script:LenovoWinPEMap -or $Hardware.MachineType -eq "UNKN"))
        if ($mapLoadedNoEntry) {
            Write-Log "LENOVO machine type $($Hardware.MachineType) has no published WinPE driver pack in the loaded map - OEM driver injection will be skipped. The run is recorded as complete with OEMPACK=NONE; if Lenovo publishes a pack for this model later, the DesiredStateId will change and the machine will rebuild." -Level INFO
        } else {
            Write-Log "$($Hardware.Manufacturer) is a supported vendor but no OEM WinPE pack could be resolved (map fetch failed or no matching entry) - OEM driver injection will be skipped" -Level WARN
            $Script:nonFatalWarning = $true
            $Script:ImageInjectionComplete = $false
        }
    }

    # ---- VMD detection ----
    # Computed before DesiredStateId so the ID captures whether VMD
    # hardware is present. VMD presence is a deployment input, not
    # incidental machine state: it determines whether the VMD driver
    # package is selected for injection. A BIOS or firmware update
    # that flips VMD on or off changes the deployed WIM and must
    # change the ID.
    $vmdIds = $manifest.drivers | Where-Object { $_.match.requiredDevices } | ForEach-Object { $_.match.requiredDevices }
    $vmdPresent = $false
    if ($vmdIds) {
        $pattern = ($vmdIds | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $vmdPresent = (Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match $pattern }).Count -gt 0
    }
    Write-Log "VMD hardware present: $vmdPresent"

    # ---- Required VMD driver set ----
    # Deterministic for a given (manifest, hardware, vmdPresent) triple.
    # Not separately hashed into DesiredStateId - the manifest version
    # already identifies the driver set, and the deployed artifact is
    # tracked via CurrentImageHash. The resolved-inputs design (hashing
    # the actual selected driver list) is deliberately deferred; the
    # manifest version discipline is what makes this safe.
    $requiredDrivers = @()
    foreach ($drv in $manifest.drivers) {
        $osMatch = ($Hardware.IsWin10 -and $drv.os -contains "Win10") -or ($Hardware.IsWin11 -and $drv.os -contains "Win11")
        $genOk = ($Hardware.CPUGeneration -ge $drv.match.cpuGenMin) -and ($Hardware.CPUGeneration -le $drv.match.cpuGenMax)
        if ($drv.match.requiredDevices -and -not $vmdPresent) { Write-Log "Skipping $($drv.name): no matching VMD hardware detected"; continue }
        if ($osMatch -and $Hardware.CPUVendor -eq "Intel" -and $genOk) { $requiredDrivers += $drv }
    }
    Write-Log "Required drivers (VMD): $($requiredDrivers.Count)"

    $DesiredStateId = Get-DesiredStateId -Hardware $Hardware -OEMPackage $OEMPackage -ExpectedDriverSetVersion $ExpectedDriverSetVersion -VMDPresent $vmdPresent
    Write-Log "DesiredStateId: $DesiredStateId"

    # ---- Checkpoint and WorkDir ----
    $cp = Get-Checkpoint -CheckpointFile $CheckpointFile -CurrentDesiredStateId $DesiredStateId
    $step = $cp.Step
    if (-not $cp.Valid) { Write-Log "Checkpoint invalidated - wiping WorkDir"; Remove-ItemIfExist $WorkDir -Recurse }
    Write-Log "Checkpoint step: $step"
    New-DirectoryIfNotExists $WorkDir
    if ($step -ge 2 -and -not (Test-Path "$WorkDir\base.wim")) { $step = 1 }
    if ($step -ge 4 -and -not (Test-Path "$WorkDir\winre_optimized.wim")) { $step = 4 }

    # ---- Recovery-volume drive-letter normalization ----
    # A recovery volume should not carry a drive letter in steady state.
    # Remove any that are present, tracking them so the finally block
    # cleans up if the removal races a re-assignment.
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

    $state = Read-WinREState -CurrentDesiredStateId $DesiredStateId
    $storedHash = $state.CurrentImageHash
    $storedDriverVersion = $state.InjectedDriverSetVersion

    # ---- Pending-reboot repair ----
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
                if ($pendingPartition) {
                    if (-not (Set-RecoveryPartitionReadyForWinRE -DiskNumber $pendingPartition.DiskNumber -PartitionNumber $pendingPartition.PartitionNumber)) {
                        Write-Log "Pending-reboot repair: target recovery partition could not be made unencrypted - deferring" -Level WARN
                        $Script:nonFatalWarning = $true
                        Remove-ItemIfExist $CheckpointFile
                        exit $EXIT_WARNING
                    }
                } else {
                    # OS-fallback: reagentc's BitLocker check is on the
                    # target volume, which in this branch is the OS
                    # partition. Defer unless C: is confirmed unencrypted.
                    # Never modify C:'s BitLocker state. See the full-
                    # update OS-fallback gate for the fail-closed
                    # rationale; the pending-reboot branch uses the same
                    # Test-VolumeEncrypted classifier and the same
                    # anything-other-than-$false deferral rule.
                    $prEnc = Test-VolumeEncrypted -MountPoint "C:"
                    if ($prEnc -ne $false) {
                        Write-Log "Pending-reboot OS-fallback: C: could not be confirmed fully decrypted (Test-VolumeEncrypted=$prEnc) - deferring without changing C: BitLocker state" -Level WARN
                        $Script:nonFatalWarning = $true
                        Remove-ItemIfExist $CheckpointFile
                        exit $EXIT_WARNING
                    }
                }

                $pendingResult = if ($pendingPartition) {
                    Invoke-ReagentcEnable -AllowTempLetter -Partition $pendingPartition -ReRegisterPath $pendingPath
                } else {
                    Invoke-ReagentcEnable -ReRegisterPath $pendingPath
                }

                if ($pendingResult -eq "ok") {
                    if ($Script:DryRun) {
                        Write-Log "[DRY RUN] Would report the pending-reboot repair as succeeded and exit with EXIT_SUCCESS"
                    } else {
                        Write-Log "Registration repair succeeded after pending-reboot retry"
                    }
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

    # ---- Enable-failure loop-breaker ----
    # When the deployment is current but reagentc /enable has failed on
    # the last 3 or more consecutive runs and WinRE is still Disabled, do
    # not keep retrying silently. The state file is left in place so the
    # operator can inspect it. Terminal failures include "failed" (generic
    # enable failure, including decryption timeouts) and "bitlocker"
    # (reagentc refused because the target volume was still encrypted
    # after preparation).
    if ($state.EnableFailureAttempts -ge 3 -and $state.LastEnableResult -in @("failed","bitlocker") -and $WinREState.Status -ne "Enabled") {
        $loopVerb = if ($Script:DryRun) { "Would refuse to retry" } else { "Refusing to retry" }
        $loopStatePath = "$env:SystemDrive\Recovery\OEM\$StateFileName"
        Write-Log "$loopVerb reagentc /enable: it has failed on the last $($state.EnableFailureAttempts) consecutive runs and WinRE is still Disabled. Manual intervention is required." -Level ERROR
        Write-Log "Verify the machine has completed OOBE and is not in Audit Mode. To reset the failure counter, delete ${loopStatePath} and re-run." -Level ERROR
        if (-not $Script:DryRun) {
            Remove-ItemIfExist $CheckpointFile
            exit $EXIT_FATAL
        }
    }

    # ---- Active-location image discovery ----
    $ActiveLocationImage = $null
    $ActiveLocationHash = $null
    # Track separately whether the reagentc-registered location actually
    # contained a WIM. Without this, the fallback search below can
    # substitute C:\Recovery\WindowsRE\winre.wim as the effective active
    # image, and the idempotency check would then compare the fallback
    # hash against the stored hash and conclude the machine is healthy
    # even when the registered location has no usable image.
    $ActiveLocationWimPresent = $false

    if ($WinREState.Location) {
        $tempLocation = @(Ensure-RecoveryPartitionAccess -TargetDir $WinREState.Location)[0]
        if ($tempLocation) {
            foreach ($cand in @(Join-Path $tempLocation "Recovery\WindowsRE\winre.wim"; Join-Path $tempLocation "winre.wim")) {
                if (Test-Path -Path $cand -PathType Leaf -ErrorAction SilentlyContinue) {
                    # ActiveLocationWimPresent must mean "present AND
                    # readable". Only set the flag after Get-LiveWimHash
                    # succeeds; otherwise continue to the next candidate.
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
                    if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) { $FallbackImage = $p; break }
                } else {
                    $part = Get-Partition -Volume $vol -ErrorAction SilentlyContinue
                    if ($part) {
                        $l = Get-AvailableDriveLetter
                        if ($l) {
                            $assignedLetter = Invoke-DriveLetterAssignment -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -PreferredLetter $l
                            if ($assignedLetter) {
                                $Script:tempDriveLetters.Add($assignedLetter)
                                $p = "${assignedLetter}:\Recovery\WindowsRE\winre.wim"
                                if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) { $FallbackImage = $p; break }
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

    # ---- Force-upgrade detection ----
    $forceUpgrade = $false
    $imageToCheck = if ($ActiveLocationImage) { $ActiveLocationImage } else { $FallbackImage }
    if ($imageToCheck) {
        $wimBuild = Get-WimBuild -WimPath $imageToCheck
        if ($wimBuild) {
            if ($Hardware.IsWin10 -and $wimBuild -ge 22000) { $forceUpgrade = $true }
            elseif ($Hardware.IsWin11 -and $wimBuild -lt 22000) { $forceUpgrade = $true }
        }
    }

    # ---- needInject determination ----
    $needInject = $false
    if ($forceUpgrade) { $needInject = $true; Write-Log "OS upgrade detected - forcing WIM rebuild" }
    elseif ($storedHash -and $ActiveLocationHash -and $ActiveLocationHash -ne $storedHash) { $needInject = $true; Write-Log "Active WIM hash differs from stored - rebuilding" }
    elseif ($storedDriverVersion -and $storedDriverVersion -ne $ExpectedDriverSetVersion) { $needInject = $true; Write-Log "Driver version changed - rebuilding" }
    elseif (-not $storedHash -or -not $storedDriverVersion) { $needInject = $true; Write-Log "No valid state (missing or stale) - rebuilding" }

    # If no WIM can be found anywhere (neither at the reagentc-registered
    # location nor as a fallback), there is no source for the deployment
    # step. Force a full rebuild so step 2 obtains a fresh WIM from
    # GitHub.
    if (-not $needInject -and -not $ActiveLocationImage -and -not $FallbackImage) {
        Write-Log "No active or fallback WinRE image found - forcing rebuild" -Level WARN
        $needInject = $true
    }

    # ---- Recovery-partition classification ----
    $osDisk = Get-OSDisk
    $existingRecoveryParts = @( if ($osDisk) { @(Get-RecoveryPartitions -DiskNumber $osDisk.Number) } else { @() } )

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
        # activeOnRecovery must additionally require the active partition
        # to be on the OS disk. Without this, a machine whose reagentc
        # registration points at a recovery partition on a secondary disk
        # and whose OS disk also has exactly one recovery partition takes
        # the idempotent fast path and then lets Remove-StrayRecoveryPartitions
        # delete the very partition reagentc is registered to.
        $isActiveOSDisk = ($osPartCheck -and
                           $activePart.DiskNumber -eq $osPartCheck.DiskNumber)

        if ($isActiveOSPart) {
            $activeOnOSFallback = $true
        } elseif ($isRec -and $isActiveOSDisk) {
            $activeOnRecovery = $true
        }
    }

    # If WinRE is registered on a recovery partition but no WIM could be
    # read at that location, force a rebuild so the full-update path
    # repairs the registered location rather than reporting DEDICATED
    # based on a fallback image that is not where reagentc is pointing.
    if ($activeOnRecovery -and -not $ActiveLocationWimPresent -and $WinREState.Status -eq "Enabled") {
        # In DryRun we cannot assign a drive letter, so we cannot
        # meaningfully Test-Path a \\?\GLOBALROOT path. Do not force a
        # rebuild on an unverified negative - the live run will do the
        # real check and force the rebuild only if the WIM really is
        # missing or unreadable.
        if ($Script:DryRun -and $WinREState.Location -match '^\\\\\?\\GLOBALROOT') {
            Write-Log "[DRY RUN] Cannot verify winre.wim at the reagentc-registered GLOBALROOT location without a drive letter (which DryRun does not assign). A live run would Test-Path the WIM and force a rebuild only if it is missing or unreadable." -Level INFO
        } else {
            Write-Log "WinRE is registered on recovery partition $($activePart.DiskNumber)/$($activePart.PartitionNumber) but its winre.wim could not be read at that location - forcing rebuild" -Level WARN
            $needInject = $true
        }
    }

    # ---- Idempotent fast path ----
    $nothingToDo = $false
    if (-not $needInject -and $WinREState.Status -eq "Enabled") {
        if ($existingRecoveryParts.Count -ne 1) {
            # Exactly one recovery partition is the ideal end state.
            # Anything else (zero, or multiple) forces the full-update
            # path so the layout is consolidated. One exemption: count=0
            # with UsedOSFallback for this DesiredStateId AND the active
            # location actually being the OS partition - that is a
            # previously-committed OS-fallback state and must not be
            # rebuilt on every run.
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

    # Migration guard: a checkpoint at step >= 4 alongside a required
    # rebuild cannot be trusted. A prior failed-injection run may have
    # advanced the checkpoint without committing new state; the next run
    # would skip step 3 and commit the un-injected WIM. Reset to step 2.
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
        # disk" invariant on the idempotent fast path.
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
    # Image is current, WinRE is disabled, and reagentc is registered on
    # a recovery partition. Prepare the target and enable.
    $needEnableOnly = (-not $needInject -and $WinREState.Status -ne "Enabled" -and $activeOnRecovery)
    if ($needEnableOnly) {
        Write-Log "Enable-only path: image current, WinRE disabled, on recovery partition"

        $enableResult = "failed"
        $targetPart = $null
        if ($WinREState.Location) {
            $targetPart = Resolve-WinRELocationToPartition -Location $WinREState.Location
        }
        if (-not $targetPart -and $existingRecoveryParts.Count -gt 0) {
            $targetPart = $existingRecoveryParts[0]
            Write-Log "Enable-only path: location resolution failed - falling back to first recovery partition (disk $($targetPart.DiskNumber) part $($targetPart.PartitionNumber))" -Level WARN
        }

        if ($targetPart) {
            # Prepare the target BEFORE /setreimage. reagentc's BitLocker
            # check is on the target volume, so the target must be
            # unencrypted by the time /enable runs. Decrypting in place
            # is safe: a partition claimed by Device Encryption does not
            # re-encrypt after manage-bde -off completes (field evidence
            # 2026-09-29).
            if (-not (Set-RecoveryPartitionReadyForWinRE -DiskNumber $targetPart.DiskNumber -PartitionNumber $targetPart.PartitionNumber)) {
                Write-Log "Enable-only path: target recovery partition could not be made unencrypted - deferring without further changes" -Level ERROR
                Write-Log "Re-run after the target volume is decrypted, or after the Device Encryption service has stabilised." -Level WARN
                $decryptAttempts = [int]$state.EnableFailureAttempts + 1
                Write-WinREState -Hash $storedHash -DriverVersion $storedDriverVersion -DesiredStateId $DesiredStateId `
                                 -PendingReboot $false `
                                 -DeployedDiskNumber $state.DeployedDiskNumber `
                                 -DeployedPartitionNumber $state.DeployedPartitionNumber `
                                 -UsedOSFallback $false `
                                 -RepairAttempts 0 `
                                 -LastEnableResult "failed" `
                                 -EnableFailureAttempts $decryptAttempts
                $Script:nonFatalWarning = $true
                Remove-ItemIfExist $CheckpointFile
                exit $EXIT_WARNING
            }

            if (-not $Script:DryRun) {
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
                $enableResult = "ok"
            }
        } else {
            if (-not $Script:DryRun) {
                Write-Log "Enable-only path: no recovery partition found - escalating to full update" -Level WARN
                $needEnableOnly = $false
            } else {
                $enableResult = "ok"
            }
        }

        if ($needEnableOnly -and ($enableResult -eq "ok" -or $enableResult -eq "reboot")) {
            # Enforce the "no type-coded recovery partition on any non-OS
            # disk" invariant on the enable-only path. This path exits
            # before Step 7, so without this a stray secondary-disk
            # recovery partition would survive indefinitely on a machine
            # whose WinRE was simply re-enabled.
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
            # The target was prepared before /setreimage; if reagentc
            # still refuses with the BitLocker error, the Device
            # Encryption service re-claimed the volume or reagentc is
            # checking something else. Record the failure and defer; the
            # loop-breaker handles repetition.
            $newEnableAttempts = [int]$state.EnableFailureAttempts + 1
            Write-Log "Enable-only /enable refused with the BitLocker error after the target partition was confirmed unencrypted (attempt $newEnableAttempts of 3). The Device Encryption service may have re-claimed the volume. Not falling through to full update." -Level WARN
            Write-WinREState -Hash $storedHash -DriverVersion $storedDriverVersion -DesiredStateId $DesiredStateId `
                             -PendingReboot $false `
                             -DeployedDiskNumber $state.DeployedDiskNumber `
                             -DeployedPartitionNumber $state.DeployedPartitionNumber `
                             -UsedOSFallback $false `
                             -RepairAttempts 0 `
                             -LastEnableResult "bitlocker" `
                             -EnableFailureAttempts $newEnableAttempts
            Remove-ItemIfExist $CheckpointFile
            exit $EXIT_WARNING
        }
    }

    # ============ FULL UPDATE PATH ============
    Write-Log "Starting full update"

    # In DryRun the full-update pipeline (copy/download base WIM, mount,
    # inject drivers, dismount, dism /Export-Image) performs file I/O in
    # WorkDir and invokes dism and 7-Zip. None of that should run under
    # -DryRun. Log the plan from the information already gathered and
    # exit. The downstream plan-only functions
    # (Find-SuitableRecoveryPartition, Ensure-AdequateRecoveryPartition,
    # Invoke-ReagentcEnable, Remove-StrayRecoveryPartitions) have their
    # own DryRun guards, but are not reached from here - that keeps the
    # DryRun guarantee for the full-update path single and structural.
    if ($Script:DryRun) {
        Write-Log "[DRY RUN] Full update plan (checkpoint step $step):"

        if ($step -le 1) {
            Write-Log "[DRY RUN]   Step 1: Clean WorkDir\mount and WorkDir\base.wim"
        }
        if ($step -le 2 -and $needInject) {
            if ($ActiveLocationImage) {
                Write-Log "[DRY RUN]   Step 2: Copy base WIM from $ActiveLocationImage to WorkDir\base.wim"
            } elseif ($FallbackImage) {
                Write-Log "[DRY RUN]   Step 2: Copy base WIM from $FallbackImage to WorkDir\base.wim"
            } else {
                Write-Log "[DRY RUN]   Step 2: Download base WIM from GitHub and extract to WorkDir\base.wim"
            }
        }
        if ($step -le 3 -and $needInject) {
            $oemDesc = if ($OEMPackage) {
                "OEM pack ($($OEMPackage.Manufacturer) - $($OEMPackage.Name))"
            } else {
                "no OEM pack"
            }
            $vmdDesc = if ($requiredDrivers.Count -gt 0) {
                "$($requiredDrivers.Count) VMD driver package(s)"
            } else {
                "no VMD drivers"
            }
            Write-Log "[DRY RUN]   Step 3: Mount base WIM, inject $oemDesc and $vmdDesc, dismount with -Save"
        }
        if ($step -le 4 -and $needInject) {
            Write-Log "[DRY RUN]   Step 4: dism /Export-Image /Compress:max to WorkDir\winre_optimized.wim"
        }

        $estMB = if ($imageToCheck) {
            $sz = Get-FileSizeMB -Path $imageToCheck
            if ($sz -gt 0) { $sz } else { 750 }
        } else { 750 }
        Write-Log "[DRY RUN]   Step 5: Find or create dedicated recovery partition, deploy WIM (est. $estMB MiB), reagentc /setreimage, reagentc /enable"
        Write-Log "[DRY RUN]   Step 6: Clean WorkDir and checkpoint file"
        Write-Log "[DRY RUN]   Step 7: Remove stray type-coded recovery partitions on non-OS disks"

        Remove-ItemIfExist $CheckpointFile
        exit $EXIT_SUCCESS
    }

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
            $OEMPackage.DownloadUrl = $tempArchive
            $OEMPackage.IsUrl = $false
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

        # Capture pre-injection third-party driver count.
        # Add-WindowsDriver's return-shape filter
        # ($_.Operation -in @("Add","Installed")) does not match on
        # Windows 11 build 26100, so we compute success by comparing
        # image inventories before and after injection.
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
                "LENOVO" { $extractionOk = Invoke-VendorExtraction -ExePath $OEMPackage.DownloadUrl -DestinationDir $extractDir -Vendor "LENOVO" }
                "HP"     { $extractionOk = Invoke-VendorExtraction -ExePath $OEMPackage.DownloadUrl -DestinationDir $extractDir -Vendor "HP" }
                default  { $extractionOk = Invoke-CabExtraction    -CabPath $OEMPackage.DownloadUrl -DestinationDir $extractDir }
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

                    # Cross-reference the extracted package's INF basenames
                    # against the mounted image's third-party driver
                    # OriginalFileName values after injection. Provider
                    # count alone cannot distinguish "our package's
                    # drivers are present" from "unrelated third-party
                    # drivers happen to already be present".
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

                    # Success gate. Fail only when the package's INFs are
                    # absent from the image AND no third-party drivers
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

            # Success when the VMD package contributed either new drivers
            # (delta > 0) or package INFs are already present (matched >
            # 0). Failure only when neither.
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

        # Run component cleanup and ResetBase on the mounted image before
        # dismount. ResetBase removes superseded components from the WinSxS
        # store inside the image. The size reduction does NOT materialise in
        # the .wim file on disk until the image is re-exported — the export
        # in Step 4 is what writes a smaller file. Without the export,
        # ResetBase is wasted CPU.
        #
        # ResetBase makes the image unserviceable for rollback purposes: any
        # update that was present when the command ran can no longer be
        # uninstalled. This is acceptable for a recovery image, which is
        # rebuilt from source whenever the DesiredStateId changes and is
        # never rolled back in place.
        #
        # Only run when injection succeeded. If injection failed, the
        # pipeline aborts before Step 4 anyway, so a successful ResetBase
        # on a partially-injected image would waste minutes of CPU for no
        # benefit. ResetBase failure is non-fatal: the WIM exports at
        # whatever size it currently is, and the Step 5 partition
        # acceptance check decides whether the result fits.
        if ($Script:ImageInjectionComplete) {
            Write-Log "Step 3: Running component cleanup and ResetBase on mounted image"
            & dism /image:"$MountDir" /cleanup-image /StartComponentCleanup /ResetBase | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Log "dism /cleanup-image /StartComponentCleanup /ResetBase returned exit code $LASTEXITCODE - continuing without ResetBase savings. The export in Step 4 will still run." -Level WARN
            } else {
                Write-Log "Component cleanup and ResetBase completed successfully"
            }
        }

        Dismount-WindowsImage -Path $MountDir -Save; Remove-ItemIfExist $MountDir
        # Do not advance the checkpoint past step 2 when image injection
        # did not complete. If the checkpoint advances but the run is
        # interrupted before cleanup, the next run resumes past step 3
        # with a fresh $Script:ImageInjectionComplete = $true and can
        # commit state for the un-injected WIM.
        if ($Script:ImageInjectionComplete) {
            Set-Checkpoint -CheckpointFile $CheckpointFile -Step 3 -DesiredStateId $DesiredStateId
        } else {
            Write-Log "Checkpoint NOT advanced to step 3 - image injection did not complete; next run will retry step 3" -Level WARN
        }
    }

    # If image injection did not complete, stop here. Continuing to Step 4
    # would export a WIM with no OEM or VMD drivers, and Step 5 would
    # deploy it. On a VMD-based system the resulting recovery environment
    # cannot see the OS disk at all. The state-write gate alone is not
    # sufficient: it prevents the state file from recording the run, not
    # the deployment of the broken WIM.
    #
    # Nothing has been deployed, no partition has been touched, and WinRE
    # has not been disabled at this point. The recovery partition and the
    # WinRE registration are unchanged. The checkpoint is set back to 2
    # so the next run re-acquires the base WIM from source and re-runs
    # injection against a clean WIM, rather than mounting a base.wim that
    # was partially modified by this run's failed injection attempt.
    if (-not $Script:ImageInjectionComplete) {
        Write-Log "Image injection did not complete. Stopping before Step 4 and before any deployment. The recovery partition and WinRE registration are unchanged. Next run will retry from step 2." -Level WARN
        Set-Checkpoint -CheckpointFile $CheckpointFile -Step 2 -DesiredStateId $DesiredStateId
        Remove-ItemIfExist "$WorkDir\winre_optimized.wim"
        $Script:nonFatalWarning = $true
        exit $EXIT_WARNING
    }

    $OptimizedWim = "$WorkDir\winre_optimized.wim"
    if ($step -le 4 -and $needInject) {
        Write-Log "Step 4: Optimizing"
        & dism /Export-Image /SourceImageFile:"$WorkDir\base.wim" /SourceIndex:1 /DestinationImageFile:$OptimizedWim /Compress:max | Out-Null
        # A native executable returning nonzero does not raise a
        # PowerShell exception under $ErrorActionPreference = "Stop".
        # Check the exit code and the output file explicitly before
        # checkpointing step 4.
        if ($LASTEXITCODE -ne 0) {
            Write-Log "dism /Export-Image failed with exit code $LASTEXITCODE" -Level FATAL
            exit $EXIT_FATAL
        }
        if (-not (Test-Path $OptimizedWim)) {
            Write-Log "dism /Export-Image reported success but $OptimizedWim does not exist" -Level FATAL
            exit $EXIT_FATAL
        }
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
        $created = Ensure-AdequateRecoveryPartition -RequiredWimSizeMB $finalSizeMB
        if ($created) {
            $recoveryPartition = @{ DriveLetter = $created.DriveLetter; DiskNumber = $created.DiskNumber; PartitionNumber = $created.PartitionNumber; Partition = $null }
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

    # Prepare the target / gate the OS-fallback before any state
    # modification. In the dedicated case, ensure the target recovery
    # partition is unencrypted before we write the WIM to it (and before
    # reagentc /enable later). In the OS-fallback case, reagentc's
    # BitLocker check is on the target volume, which is C:. reagentc will
    # refuse to enable WinRE on an encrypted OS volume. Defer rather than
    # attempt a call that will be refused. Never modify C:'s BitLocker
    # state - decrypting the OS volume is hours of I/O, changes the
    # recovery key relationship, and the OS volume is the user's data.
    if ($recoveryPartition) {
        if (-not (Set-RecoveryPartitionReadyForWinRE -DiskNumber $recoveryPartition.DiskNumber -PartitionNumber $recoveryPartition.PartitionNumber)) {
            Write-Log "FATAL: Could not make target recovery partition unencrypted" -Level ERROR
            exit $EXIT_FATAL
        }
    } else {
        # OS-fallback: reagentc's BitLocker check is on the target volume,
        # which in this branch is the OS partition. reagentc refuses to
        # enable WinRE on an encrypted OS volume. Defer unless C: is
        # confirmed unencrypted. Never modify C:'s BitLocker state.
        #
        # Test-VolumeEncrypted returns $false only for a confirmed fully
        # decrypted volume; $true for encrypted or partially encrypted;
        # $null for unknown. Anything other than $false defers. This
        # closes a fail-open path: the previous code passed the gate
        # silently when Get-BitLockerVolume returned $null, because the
        # $osFallbackVs -and condition short-circuited on the empty
        # string. Test-VolumeEncrypted also brings the manage-bde text-
        # parsing fallback, so a machine whose BitLocker module is
        # unavailable is still classified correctly.
        $osFallbackEnc = Test-VolumeEncrypted -MountPoint "C:"
        if ($osFallbackEnc -ne $false) {
            Write-Log "OS-fallback deferred: C: could not be confirmed fully decrypted (Test-VolumeEncrypted=$osFallbackEnc). reagentc will refuse to enable WinRE on an encrypted OS volume. To resolve: sign in with a Microsoft account to complete Device Encryption activation, or add a key protector manually (Add-BitLockerKeyProtector -MountPoint C: -RecoveryPasswordProtector) and enable protection, or wait for decryption to finish. The script will not modify C:'s BitLocker state." -Level WARN
            $Script:nonFatalWarning = $true
            Remove-ItemIfExist $CheckpointFile
            exit $EXIT_WARNING
        }
    }

    $CurrentWinREState = Get-WinREState
    if ($CurrentWinREState.Status -eq "Enabled") {
        Write-Log "Disabling WinRE before deployment"
        $disOut = cmd /c "reagentc /disable 2>&1"
        $disExit = $LASTEXITCODE
        Write-Log "reagentc /disable: exit=$disExit, output=$disOut"
        # Treat a failed /disable as a hard stop. Deploying a new WIM
        # while the old registration is still active is not a state we
        # want to be in.
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

    $enableResult = if ($recoveryPartition) {
        Invoke-ReagentcEnable -AllowTempLetter -Partition $recoveryPartition -ReRegisterPath $permanentPath
    } else {
        Invoke-ReagentcEnable -ReRegisterPath $permanentPath
    }

    if ($enableResult -eq "reboot") {
        $Script:rebootRequired = $true
    } elseif ($enableResult -eq "failed") {
        $Script:nonFatalWarning = $true
    } elseif ($enableResult -eq "bitlocker") {
        # The target was prepared before deployment; if reagentc still
        # refuses with the BitLocker error, the Device Encryption service
        # may have re-claimed the volume, or reagentc's check is against
        # a different state than the two-field view exposes. Record the
        # failure and continue - the state write below increments the
        # counter, and the loop-breaker handles repetition.
        Write-Log "reagentc /enable refused with the BitLocker error after the target partition was confirmed unencrypted. Recording the failure so the loop-breaker can fire if this repeats." -Level ERROR
        $Script:nonFatalWarning = $true
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

    # Update the OS-fallback WIM. Skip when the deployment source is
    # already the fallback file itself: the block would delete the source
    # and then copy it to itself, destroying the only copy.
    $fallbackTarget = "$env:SystemDrive\Recovery\WindowsRE\winre.wim"
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

    # ---- State write ----
    $finalHash = Get-LiveWimHash $SourceWim
    if ($Script:ImageInjectionComplete -and $finalHash) {
        $deployedDisk = if ($recoveryPartition) { $recoveryPartition.DiskNumber } else { -1 }
        $deployedPart = if ($recoveryPartition) { $recoveryPartition.PartitionNumber } else { -1 }
        # Increment the enable-failure counter on terminal failures only.
        # "failed" covers generic reagentc failures and decryption
        # timeouts; "bitlocker" covers a BitLocker refusal after the
        # target was prepared. Both feed the loop-breaker.
        $newEnableAttempts = if ($enableResult -in @("failed","bitlocker")) { [int]$state.EnableFailureAttempts + 1 } else { 0 }
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
    # Same gate as steps 3 and 4. The step 6 checkpoint is written
    # immediately before cleanup removes it; the window between the two
    # operations is not atomic and spans the recursive WorkDir delete, so
    # an interruption in that window leaves a step-6 checkpoint on disk.
    if ($Script:ImageInjectionComplete) {
        Set-Checkpoint -CheckpointFile $CheckpointFile -Step 6 -DesiredStateId $DesiredStateId
    } else {
        Write-Log "Checkpoint NOT advanced to step 6 - image injection did not complete; next run will retry step 3" -Level WARN
    }

    Write-Log "Step 6: Cleanup"
    Remove-ItemIfExist $WorkDir -Recurse; Remove-ItemIfExist $CheckpointFile

    # Step 7: remove every type-coded recovery partition that is not on
    # the OS disk. Windows Setup and Startup Repair scan all attached
    # volumes for WinRE-capable partitions; a stray can point the BCD at
    # the wrong image during repair. The invariant is: exactly one
    # recovery partition exists on the machine, on the OS disk, correctly
    # type-coded.
    Write-Log "Step 7: Removing stray recovery partitions on non-OS disks"
    $osDisk = Get-OSDisk
    if (-not $osDisk) {
        Write-Log "Step 7 skipped: could not determine OS disk" -Level WARN
        $Script:nonFatalWarning = $true
    } else {
        Remove-StrayRecoveryPartitions -OSDiskNumber $osDisk.Number | Out-Null
    }

    # ---- Final verification ----
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
        # Last-ditch retry. Skip if the main flow already recorded a
        # terminal failure that a retry cannot resolve ("bitlocker" means
        # the target was encrypted after preparation; the state file
        # records the failure for the loop-breaker).
        if ($enableResult -eq "bitlocker") {
            Write-Log "WinRE is not enabled at exit. Last enable attempt returned: bitlocker. The state file records the failure for the loop-breaker." -Level WARN
            exit $EXIT_WARNING
        }
        Write-Log "WinRE not enabled - final attempt" -Level WARN
        $finalResult = Invoke-ReagentcEnable -ReRegisterPath $permanentPath
        if ($finalResult -eq "ok") {
            Write-Log "Final enable attempt succeeded"
        } elseif ($finalResult -eq "reboot") {
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
}
