<#
.SYNOPSIS
    Self-Healing Windows Recovery Environment (WinRE) Manager - Production

.NOTES
    Version : 47 (v47 patch 1)

    Full history, design, and troubleshooting:
      CHANGELOG.md, docs/architecture.md, docs/deployment.md,
      docs/exit-codes.md, docs/troubleshooting.md

    Design invariants:
            - Dedicated WinRE is primary. OS-fallback requires C: FullyDecrypted.
                Prepare the target before reagentc; never change C:'s BitLocker state.
            - Only type-coded recovery partitions qualify for reuse/deletion.
                Partitions over 2 GiB are preserved for operator review. The
                post-delete extension-failure fallback preserves this ceiling:
                it sizes the replacement partition to the planned bucket, not
                to the full remaining extent, and logs any trailing
                unallocated extent explicitly.
            - Read-only geometry planning precedes partition changes. C: is resized
                to end where the recovery partition begins; the recovery partition
                fills the aligned extent up to that boundary. The plan clamps the
                usable extent end to diskSize - 1 MiB before aligning, so no
                partition (blocking or reclaimable) can push the aligned boundary
                past the disk-end reserve. Shrink runs before route destruction;
                extend runs after the old recovery partitions are gone. Rollback
                targets the original C: size, never SizeMax.
            - Pre-shrink deferral preserves the old route. Its sidecar marker only
                suppresses retries while that route and its registered WIM are valid.
            - The destructive sequence fails closed before deletion if the active
                WinRE route is Enabled but its registered location cannot be
                resolved to a partition. Delete-last ordering and route
                restoration both depend on identifying the active target;
                without it, no partition is protected and a mid-loop failure
                could leave the machine with no working recovery route.
            - The whole-layout assertion fails closed when the OS partition cannot
                be resolved, rather than skipping the C: adjacency check. A layout
                that cannot be verified against C: is not accepted; the assertion
                is the last check before Format-Volume.
            - Checkpoint advancement requires successful injection. Step 4 records
                WIM_READY before base.wim cleanup; partition/deploy work is not resumed.
            - Scratch uses fixed NTFS volumes on allowlisted internal/virtual buses.
                USB, SD/MMC, network, FireWire, Fibre Channel, and unknown buses are out.
            - Indeterminate VMD detection defers. Network requests use the timeout.
            - Build-drift observability: every run logs the registered WinRE
                version (pre-touch, from reagentc), the source WIM build, and
                the post-deploy WIM build. v47 additionally logs the
                currently-registered WinRE's SHA256, the last successfully
                deployed WIM's SHA256, and whether the two differ (byte-drift
                evidence for a metadata-neutral source change), plus the
                final deployed WIM's SHA256. Logged for evidence only; no
                gate reads any of these values and none enters
                DesiredStateId.

            - LKG migration bridge: on the first v47 run on a machine whose
                state file was written by v46 or earlier, the DSI mismatch
                correctly causes the state reader to return empty, which
                would make the manager's own last-known-good copy at
                C:\Recovery\WindowsRE\winre.wim unrecognizable as LKG. A
                separate narrow read of the stale state file's
                CurrentImageHash restores LKG validation for exactly this
                migration window. It does NOT make the stale state
                operationally authoritative and is used only at
                LKG-validation call sites.

        Known gap:
            - Offline fallback trusts stored DesiredStateId; LocalInputsId would
                close the residual hardware-drift risk.

    Critical lessons (do not regress):
      - No 7-Zip for Lenovo/HP EXE extraction; use the vendor's EXE with
        its own switches. Do not rename downloads before extraction.
      - Invoke-WebRequest can throw even on a successful download; always
        verify the file after the attempt.
      - In double-quoted strings, "$word:" parses as a scope qualifier.
        Use "${word}:" for a literal colon.
      - Add-WindowsDriver's return shape is unreliable across DISM builds.
        Judge by third-party driver count delta plus INF-basename
        cross-reference.
      - manage-bde -status "could not be opened by BitLocker" means
        unmanaged (unencrypted), not unknown.
            - Self-referential file ops guard with GetFullPath.
            - Recovery offsets round UP to 1 MiB. The plan computes the aligned
                managed extent end and places the recovery partition as the last
                bucketSize bytes up to it; C: is resized to end at that boundary.
                Clamp the usable extent to diskSize - 1 MiB before aligning: a
                factory partition that ends 1 MiB past the reserve would otherwise
                push the aligned boundary past the reserve and the post-delete
                geometry check would reject the plan. Plan before destroying the
                old route; never roll back to SizeMax.
      - Audit Mode guard runs before any state-modifying action.
      - A partition claimed by Device Encryption does not re-encrypt
        after manage-bde -off. Decrypt in place.
      - Failed-injection abort removes base.wim too, else step 2 fails
        on the next run at Rename-Item.
#>

[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"
$NetworkTimeoutSeconds = 15

$EXIT_SUCCESS          = 0
$EXIT_REBOOT_REQUIRED  = 1
$EXIT_WARNING          = 2
$EXIT_FATAL            = 3

$ScriptVersion    = 47
$ScriptPatchLevel = "1"

# =========================== CONFIG ===========================
$DriverManifestUrl         = "https://gist.github.com/52250179/4d98029c7b39240cdb860ee3c78c3ca9/raw"
$BaseWinRERepoApi          = "https://api.github.com/repos/52250179/OriginalWindowsREImages/contents"
$7Zip                      = "C:\Program Files\7-Zip\7z.exe"
$DefaultWorkDir            = "C:\Temp\WinREWork"
$WorkDir                   = $DefaultWorkDir
# Minimum free space for both the workspace volume (before servicing)
# and C: (after the planned pre-shrink). Applied to two checks:
#   - workspace selection: the servicing volume must have this much free
#   - pre-shrink: C: must retain this much free after the planned shrink
# 3 GB covers a ~2.5 GB peak workspace during WIM servicing plus headroom.
$MinFreeSpaceGB            = 3
$WorkDirResumeMinFreeMB    = 200
# DriveType=Fixed also includes USB hard drives; require a known internal bus.
$InternalWorkspaceBusTypes = @('ATA', 'SATA', 'NVMe', 'RAID', 'SAS', 'Spaces', 'Virtual', 'File Backed Virtual', 'SCM')
$LogDir                    = "C:\ProgramData\OEM\Logs"
$StateFileName             = "winre_state.json"
$PartitionDeferralFileName = "winre_partition_deferred.json"
$CheckpointFile            = "$LogDir\winre_checkpoint.txt"
$WinREFreeSpaceMiB         = 250
$NewPartitionFilesystemMiB = 30
$NewPartitionIncrementMiB  = 100
$NewPartitionMinimumMiB    = 1000
$MaxManagedRecoveryPartitionMiB = 2048
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
$Script:LenovoPackResolution   = "unknown"
$Script:ProgramLockStream      = $null
$Script:offlineFallback        = $false
$Script:OriginalTempPath       = $null
$Script:OriginalTmpPath        = $null
$Script:TempEnvironmentChanged = $false
$Script:RegisteredSourceFingerprint = $null
$Script:DeployedWinREMetadata = $null
$Script:StagedWimSourceHash = $null

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
        return @{ Step = 0; DesiredStateId = $null; WorkDir = $null; WimReady = $false; SourceHash = $null; Valid = $true }
    }
    try {
        $raw   = (Get-Content $CheckpointFile -Raw).Trim()
        # v47: 5th field is the optional source-content hash that identifies
        # the WIM from which the WIM_READY candidate was prepared. Legacy
        # 4-field checkpoints have no source identity and are invalidated
        # by the resume-time validator.
        $parts = $raw -split '\|', 5
        $step  = [int]$parts[0]
        $storedId = if ($parts.Count -gt 1) { $parts[1] } else { $null }
        $storedWorkDir = if ($parts.Count -gt 2) { $parts[2] } else { $null }
        $storedWimReady = ($parts.Count -gt 3 -and $parts[3] -eq 'WIM_READY')
        $storedSourceHash = if ($parts.Count -gt 4 -and $parts[4]) { [string]$parts[4] } else { $null }
        if (-not $storedId) { return @{ Step = 0; DesiredStateId = $null; WorkDir = $storedWorkDir; WimReady = $storedWimReady; SourceHash = $storedSourceHash; Valid = $false } }
        if ($storedId -ne $CurrentDesiredStateId) {
            return @{ Step = 0; DesiredStateId = $storedId; WorkDir = $storedWorkDir; WimReady = $storedWimReady; SourceHash = $storedSourceHash; Valid = $false }
        }
        return @{ Step = $step; DesiredStateId = $storedId; WorkDir = $storedWorkDir; WimReady = $storedWimReady; SourceHash = $storedSourceHash; Valid = $true }
    } catch {
        return @{ Step = 0; DesiredStateId = $null; WorkDir = $null; WimReady = $false; SourceHash = $null; Valid = $false }
    }
}

function Set-Checkpoint {
    param(
        [Parameter(Mandatory)][string]$CheckpointFile,
        [Parameter(Mandatory)][int]$Step,
        [Parameter(Mandatory)][AllowEmptyString()][string]$DesiredStateId,
        [switch]$WimReady,
        [AllowNull()][string]$SourceHash = $null
    )
    if ($Script:DryRun) { Write-Log "[DRY RUN] Would set checkpoint $Step"; return }
    $checkpointFlag = if ($WimReady) { 'WIM_READY' } else { '-' }
    $content = "$Step|$DesiredStateId|$WorkDir|$checkpointFlag"
    if ($SourceHash) { $content = "$content|$SourceHash" }
    Write-FileAtomically -Path $CheckpointFile -Content $content
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
    # v46 patch 2: extract Windows RE Version so the caller can log which
    # build is currently registered before any destructive work happens.
    # Absent when WinRE is Disabled or reagentc suppresses the line.
    # Informational only - not part of DesiredStateId and not used in any
    # gate.
    $versionLine = $info | Select-String -Pattern 'Windows RE Version:\s*([\d\.]+)' | Select-Object -First 1
    $version = if ($versionLine) { $versionLine.Matches.Groups[1].Value } else { $null }
    return @{ Status = $status; Location = $location; Version = $version }
}

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

# The disk where Windows lives, not necessarily MSFT_Disk.BootFromDisk.
# Anchoring on the OS partition's DiskNumber removes the ambiguity for
# multi-boot or cloned systems.
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

function Get-WorkDirCandidates {
    $osDriveLetter = $env:SystemDrive.TrimEnd(':').ToUpperInvariant()
    $volumes = @(Get-Volume -ErrorAction Stop)
    $candidates = @()

    foreach ($volume in $volumes) {
        if ($volume.DriveType -ne 'Fixed' -or $volume.FileSystem -ne 'NTFS' -or -not $volume.DriveLetter) { continue }
        if ($volume.FileSystemLabel -in @('Recovery', 'WINRE')) { continue }

        $driveLetter = ([string]$volume.DriveLetter).ToUpperInvariant()
        $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $partition -or $partition.IsSystem) { continue }

        $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction SilentlyContinue
        if (-not $disk -or $disk.IsOffline -or $disk.BusType.ToString() -notin $InternalWorkspaceBusTypes) { continue }

        $workspacePath = "${driveLetter}:\Temp\WinREWork"
        $hasReparsePath = $false
        foreach ($path in @("${driveLetter}:\Temp", $workspacePath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
            try {
                $pathItem = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                if (($pathItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    Write-Log "Ignoring workspace candidate $path because it is a reparse point" -Level WARN
                    $hasReparsePath = $true
                    break
                }
            } catch {
                Write-Log "Ignoring workspace candidate $path because its path could not be verified: $_" -Level WARN
                $hasReparsePath = $true
                break
            }
        }
        if ($hasReparsePath) { continue }

        $isTypedRecovery = ($partition.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}') -or ($partition.MbrType -eq 0x27)
        if ($isTypedRecovery) { continue }

        $candidates += [PSCustomObject]@{
            Path          = $workspacePath
            DriveLetter   = $driveLetter
            FreeBytes     = [int64]$volume.SizeRemaining
            IsOSVolume    = ($driveLetter -eq $osDriveLetter)
            DiskNumber    = [int]$partition.DiskNumber
            BusType       = $disk.BusType.ToString()
        }
    }

    return @($candidates)
}

function Get-WorkDirPlan {
    param(
        [string]$PreferredPath,
        [Parameter(Mandatory)][int64]$MinimumFreeBytes
    )

    $candidates = @(Get-WorkDirCandidates)
    $eligible = @($candidates | Where-Object { $_.FreeBytes -ge $MinimumFreeBytes })
    $selected = $null

    if ($PreferredPath) {
        $preferredFullPath = $null
        try { $preferredFullPath = [System.IO.Path]::GetFullPath($PreferredPath).TrimEnd('\') } catch { }
        if ($preferredFullPath) {
            $selected = $eligible | Where-Object {
                [System.StringComparer]::OrdinalIgnoreCase.Equals($_.Path.TrimEnd('\'), $preferredFullPath)
            } | Select-Object -First 1
        }
    }

    if (-not $selected) {
        $selected = $eligible | Where-Object { -not $_.IsOSVolume } | Sort-Object FreeBytes -Descending | Select-Object -First 1
    }
    if (-not $selected) {
        $selected = $eligible | Where-Object { $_.IsOSVolume } | Select-Object -First 1
    }

    return @{
        Path = if ($selected) { $selected.Path } else { $null }
        Candidate = $selected
        Candidates = $candidates
        MinimumFreeBytes = $MinimumFreeBytes
    }
}

# =========================== DRIVE LETTER HANDLING ===========================
# Three-method fallback per candidate letter (Set-Partition,
# Add-PartitionAccessPath, diskpart). DryRun returns the preferred
# letter without assigning it.
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

# =========================== RECOVERY PARTITION ACCESS ===========================
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
# Three-state classifier:
#   $true  = encrypted or partially encrypted
#   $false = confirmed fully decrypted
#   $null  = could not determine
#
# FullyEncrypted, EncryptionInProgress, DecryptionInProgress,
# EncryptionPaused, and DecryptionPaused all represent a volume that
# is not fully decrypted.
#
# "could not be opened by BitLocker" from manage-bde on a properly-typed
# recovery partition is definitive proof the volume is not encrypted.
#
# Text parsing is preferred over -protectionaserrorlevel, which
# misbehaves on some Windows 11 builds.
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

function Test-DeferredWinRERouteFunctional {
    param(
        [Parameter(Mandatory)][hashtable]$WinREState,
        [Parameter(Mandatory)][bool]$ActiveLocationWimPresent,
        [Parameter(Mandatory)][bool]$ActiveOnRecovery,
        [Parameter(Mandatory)][bool]$ActiveOnOSFallback
    )

    if ($WinREState.Status -ne 'Enabled' -or -not $ActiveLocationWimPresent) { return $false }
    if ($ActiveOnRecovery) { return $true }
    if ($ActiveOnOSFallback) { return ((Test-VolumeEncrypted -MountPoint 'C:') -eq $false) }
    return $false
}

# Prepare a target recovery partition for reagentc /enable.
#
# reagentc's BitLocker check is on the TARGET volume, not on C:. This
# function decrypts the target in place with manage-bde -off and polls
# until confirmed-unencrypted or timeout. A partition claimed by Device
# Encryption does not re-encrypt after -off completes (2026-09-29 field
# evidence), so decrypt-in-place is safe and replaces delete-and-recreate.
#
# Poll policy: 5-second interval, 300-second timeout.
# The caller is responsible for removing any drive letter this function
# assigns; letters are added to $Script:tempDriveLetters for cleanup.
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
# Broad detector: matches by Recovery/WINRE label, GPT recovery type
# GUID, or MBR type 0x27. Used on the OS disk. The type-code gate for
# authoritative deletion/reuse is applied by the callers.
function Get-RecoveryPartitions {
    param([int]$DiskNumber = -1)

    $disks = if ($DiskNumber -ge 0) { @(Get-Disk -Number $DiskNumber) } else { Get-Disk }
    $allParts = @()
    foreach ($disk in $disks) {
        $diskNum = $disk.Number
        $byLabel = Get-Volume | Where-Object { $_.FileSystemLabel -eq "Recovery" -or $_.FileSystemLabel -eq "WINRE" } |
                   Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DiskNumber -eq $diskNum }
        # -ErrorAction SilentlyContinue: a disk with no partitions (e.g.
        # an empty SD/MMC card reader) makes Get-Partition -DiskNumber
        # throw CmdletizationQuery_NotFound_DiskNumber. That is absence,
        # not failure.
        $byGpt = if ($disk.PartitionStyle -eq 'GPT') {
                     Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue | Where-Object { $_.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' }
                 } else { @() }
        $byMbr = if ($disk.PartitionStyle -eq 'MBR') {
                     Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue | Where-Object { $_.MbrType -eq 0x27 }
                 } else { @() }
        $allParts += @($byLabel) + @($byGpt) + @($byMbr) |
                     Where-Object { $_.PartitionNumber -gt 0 } |
                     Group-Object -Property PartitionNumber |
                     ForEach-Object { $_.Group | Select-Object -First 1 }
    }
    return @($allParts)
}

# Delete every type-coded recovery partition on a non-OS disk. Label-only
# matches on non-OS disks are logged and skipped — a label alone is never
# sufficient authority to delete. Called from the fast path, the
# enable-only path, both pending-reboot exits, and Step 7.
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
            if ([int64]$rp.Size -gt [int64]($MaxManagedRecoveryPartitionMiB * 1MB)) {
                Write-Log "Step 7: preserving oversized recovery-typed partition $($disk.Number)/$($rp.PartitionNumber) ($([math]::Round($rp.Size/1MB,1)) MiB > $MaxManagedRecoveryPartitionMiB MiB safety ceiling) for operator review" -Level WARN
                $Script:nonFatalWarning = $true
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

# Post-creation geometry assertion. Confirms that a newly-created
# recovery partition landed at the planned offset (exact) and size
# (within one alignment block), that it does not overlap the OS
# partition, that the C:-to-recovery gap does not exceed one alignment
# block, and that its end matches the planned aligned managed-extent
# end within one alignment block. A trailing offset within tolerance
# is logged; anything larger is a fatal geometry mismatch that
# triggers orphan removal and a deferred return.
function Assert-RecoveryPartitionLayout {
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][int]$PartitionNumber,
        [Parameter(Mandatory)][int64]$ExpectedOffsetBytes,
        [Parameter(Mandatory)][int64]$ExpectedSizeBytes,
        [int64]$ExpectedEndBytes = -1,
        [int64]$AlignmentToleranceBytes = 1MB
    )
    try {
        $part = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction Stop
        if (-not $part) {
            Write-Log "Assert-RecoveryPartitionLayout: partition $DiskNumber/$PartitionNumber not found" -Level ERROR
            return $false
        }
        if ($part.DiskNumber -ne $DiskNumber -or $part.PartitionNumber -ne $PartitionNumber) {
            Write-Log "Assert-RecoveryPartitionLayout: identity mismatch, got $($part.DiskNumber)/$($part.PartitionNumber)" -Level ERROR
            return $false
        }
        if ([int64]$part.Offset -ne $ExpectedOffsetBytes) {
            Write-Log "Assert-RecoveryPartitionLayout: recovery offset is $([math]::Round($part.Offset/1MB,3)) MiB, expected $([math]::Round($ExpectedOffsetBytes/1MB,3)) MiB" -Level ERROR
            return $false
        }
        $sizeDelta = [Math]::Abs([int64]$part.Size - $ExpectedSizeBytes)
        if ($sizeDelta -gt $AlignmentToleranceBytes) {
            Write-Log "Assert-RecoveryPartitionLayout: recovery size $([math]::Round($part.Size/1MB,2)) MiB, expected $([math]::Round($ExpectedSizeBytes/1MB,2)) MiB, delta $([math]::Round($sizeDelta/1MB,2)) MiB exceeds $([math]::Round($AlignmentToleranceBytes/1MB,2)) MiB tolerance" -Level ERROR
            return $false
        }
        $osPart = Get-OSPartition
        if (-not $osPart) {
            # The OS partition could not be resolved. Fail closed rather
            # than skip the C: adjacency check: a layout that cannot be
            # verified against C: must not be accepted.
            Write-Log "Assert-RecoveryPartitionLayout: could not resolve the OS partition; refusing to accept the layout without the C: adjacency check" -Level ERROR
            return $false
        }
        if ($osPart.DiskNumber -eq $DiskNumber) {
            $osEnd = [int64]$osPart.Offset + [int64]$osPart.Size
            if ($osEnd -gt [int64]$part.Offset) {
                Write-Log "Assert-RecoveryPartitionLayout: OS partition end $([math]::Round($osEnd/1MB,2)) MiB overlaps recovery start $([math]::Round($part.Offset/1MB,2)) MiB" -Level ERROR
                return $false
            }
            $gapBytes = [int64]$part.Offset - $osEnd
            if ($gapBytes -gt $AlignmentToleranceBytes) {
                Write-Log "Assert-RecoveryPartitionLayout: gap between OS end $([math]::Round($osEnd/1MB,2)) MiB and recovery start $([math]::Round($part.Offset/1MB,2)) MiB is $([math]::Round($gapBytes/1MB,2)) MiB, exceeds $([math]::Round($AlignmentToleranceBytes/1MB,2)) MiB alignment tolerance" -Level ERROR
                return $false
            }
            if ($gapBytes -gt 0) {
                Write-Log "Assert-RecoveryPartitionLayout: C:-to-recovery alignment gap $([math]::Round($gapBytes/1KB,1)) KiB (within tolerance)"
            }
        }
        if ($ExpectedEndBytes -gt 0) {
            $actualEnd = [int64]$part.Offset + [int64]$part.Size
            $endDelta = [Math]::Abs($actualEnd - $ExpectedEndBytes)
            if ($endDelta -gt $AlignmentToleranceBytes) {
                Write-Log "Assert-RecoveryPartitionLayout: recovery partition ends at $([math]::Round($actualEnd/1MB,3)) MiB, expected $([math]::Round($ExpectedEndBytes/1MB,3)) MiB, delta $([math]::Round($endDelta/1MB,2)) MiB exceeds $([math]::Round($AlignmentToleranceBytes/1MB,2)) MiB tolerance" -Level ERROR
                return $false
            }
            if ($endDelta -gt 0) {
                Write-Log "Assert-RecoveryPartitionLayout: recovery partition trailing alignment gap $([math]::Round($endDelta/1KB,1)) KiB (within tolerance)"
            }
        }
        Write-Log "Verified recovery partition layout: disk $DiskNumber partition $PartitionNumber, offset $([math]::Round($part.Offset/1MB,3)) MiB, size $([math]::Round($part.Size/1MB,2)) MiB"
        return $true
    } catch {
        Write-Log "Assert-RecoveryPartitionLayout: query failed for $DiskNumber/$PartitionNumber - $_" -Level ERROR
        return $false
    }
}

# =========================== RECOVERY PARTITION CREATION ===========================
# Restore C: to a requested target size (typically the pre-attempt size
# captured before a shrink). When -TargetSizeBytes is omitted, falls
# back to the partition's supported maximum. Any failure sets
# nonFatalWarning and GeometryRestoreFailed, which causes
# Write-WinREState to delete the state file and forces a clean retry.
function Restore-OSPartitionSize {
    param(
        [Parameter(Mandatory)][string]$Reason,
        [object]$TargetSizeBytes = $null
    )

    if ($Script:DryRun) {
        if ($null -ne $TargetSizeBytes) { Write-Log "[DRY RUN] Would restore OS partition to $([math]::Round([int64]$TargetSizeBytes/1MB,1)) MiB ($Reason)" }
        else { Write-Log "[DRY RUN] Would re-extend OS partition to SizeMax ($Reason)" }
        return $true
    }

    $osPart = Get-OSPartition
    if (-not $osPart) {
        Write-Log "Restore-OSPartitionSize: OS partition not found ($Reason)" -Level WARN
        $Script:nonFatalWarning = $true
        $Script:GeometryRestoreFailed = $true
        return $false
    }
    try {
        $targetSize = if ($null -ne $TargetSizeBytes) {
            [int64]$TargetSizeBytes
        } else {
            [int64](Get-PartitionSupportedSize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber -ErrorAction Stop).SizeMax
        }
        if ($targetSize -eq $osPart.Size) {
            Write-Log "OS partition already at requested size $([math]::Round($targetSize/1MB,1)) MiB ($Reason)"
            return $true
        }
        Write-Log "Restoring OS partition from $([math]::Round($osPart.Size/1MB,1)) MiB to $([math]::Round($targetSize/1MB,1)) MiB ($Reason)"
        $osPart | Resize-Partition -Size $targetSize -ErrorAction Stop
        Start-Sleep 3
        if (-not (Assert-PartitionSizeAfterResize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber -ExpectedSizeBytes $targetSize)) {
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

# Delete a partition we created but could not complete. Uses delete-first
# / diskpart-override-second. On survival, sets the geometry-failure
# flags so the state file is invalidated.
function Remove-OrphanPartition {
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][int]$PartitionNumber,
        [Parameter(Mandatory)][string]$Reason,
        [object]$TargetOSPartitionSizeBytes = $null
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
        $Script:nonFatalWarning = $true
        $Script:GeometryRestoreFailed = $true
        return $false
    }
    Write-Log "Removed orphan partition $DiskNumber/$PartitionNumber after $Reason"

    Restore-OSPartitionSize -Reason "after orphan removal" -TargetSizeBytes $TargetOSPartitionSizeBytes | Out-Null
    return $true
}

function Get-PartitionPlan {
    param(
        [Parameter(Mandatory)][object]$OSDisk,
        [Parameter(Mandatory)][object]$OSPartition,
        [Parameter(Mandatory)][object[]]$Partitions,
        [Parameter(Mandatory)][int64]$SizeMinBytes,
        [Parameter(Mandatory)][int64]$BucketSizeBytes,
        [int64]$MaxRecoveryPartitionBytes = 2GB
    )

    $recoveryType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
    $osStart = [int64]$OSPartition.Offset
    $osSize = [int64]$OSPartition.Size
    $osEnd = $osStart + $osSize
    $diskSize = [int64]$OSDisk.Size
    $allPartitions = @($Partitions | Sort-Object -Property Offset)
    $invalidReason = $null
    if (@($allPartitions | Where-Object { $_.DiskNumber -ne $OSDisk.Number }).Count -gt 0) {
        $invalidReason = 'partition inventory contains entries from another disk'
    } elseif (@($allPartitions | Where-Object {
        $_.PartitionNumber -ne $OSPartition.PartitionNumber -and
        [int64]$_.Offset -lt $osEnd -and ([int64]$_.Offset + [int64]$_.Size) -gt $osStart
    }).Count -gt 0) {
        $invalidReason = 'another partition overlaps the OS partition geometry'
    }
    $typedRecovery = @($allPartitions | Where-Object {
        ($_.GptType -eq $recoveryType) -or ($_.MbrType -eq 0x27)
    })

    if (-not $invalidReason -and $SizeMinBytes -le 0) {
        $invalidReason = 'OS partition supported-size bounds are unavailable'
    } elseif (-not $invalidReason -and $BucketSizeBytes -le 0) {
        $invalidReason = 'requested recovery bucket size is invalid'
    } elseif (-not $invalidReason -and $BucketSizeBytes -gt $MaxRecoveryPartitionBytes) {
        $invalidReason = "required recovery bucket exceeds the $([math]::Round($MaxRecoveryPartitionBytes/1MB)) MiB safety ceiling"
    } elseif (-not $invalidReason -and ($osStart -lt 0 -or $osSize -le 0 -or $osEnd -gt $diskSize)) {
        $invalidReason = 'OS partition geometry is inconsistent with disk size'
    } elseif (-not $invalidReason -and @($typedRecovery | Where-Object { [int64]$_.Size -gt $MaxRecoveryPartitionBytes }).Count -gt 0) {
        $invalidReason = "recovery-typed partition exceeds the $([math]::Round($MaxRecoveryPartitionBytes/1MB)) MiB safety ceiling"
    } elseif (-not $invalidReason -and @($typedRecovery | Where-Object { [int64]$_.Offset -lt $osEnd -and ([int64]$_.Offset + [int64]$_.Size) -gt $osStart }).Count -gt 0) {
        $invalidReason = 'recovery-typed partition overlaps the OS partition geometry'
    } elseif (-not $invalidReason -and @($typedRecovery | Where-Object { ([int64]$_.Offset + [int64]$_.Size) -le $osStart }).Count -gt 0) {
        $invalidReason = 'recovery-typed partition precedes the OS partition; layout requires review'
    }

    $reclaimable = [System.Collections.Generic.List[object]]::new()
    $recoveryBytes = [int64]0
    $unallocatedBytes = [int64]0
    $cursor = $osEnd
    $blockingPartition = $null

    if (-not $invalidReason) {
        foreach ($partition in $allPartitions) {
            if ($partition.PartitionNumber -eq $OSPartition.PartitionNumber -and $partition.DiskNumber -eq $OSPartition.DiskNumber) { continue }
            $partitionStart = [int64]$partition.Offset
            $partitionEnd = $partitionStart + [int64]$partition.Size
            if ($partitionEnd -le $osEnd) { continue }
            if ($partitionStart -lt $cursor) {
                $invalidReason = 'partition extents overlap or are not ordered consistently'
                break
            }

            $unallocatedBytes += ($partitionStart - $cursor)
            $isTypedRecovery = ($partition.GptType -eq $recoveryType) -or ($partition.MbrType -eq 0x27)
            if (-not $isTypedRecovery) {
                $blockingPartition = $partition
                break
            }

            $reclaimable.Add($partition)
            $recoveryBytes += [int64]$partition.Size
            $cursor = $partitionEnd
        }
    }

    if (-not $invalidReason) {
        $nonContiguousRecovery = @($typedRecovery | Where-Object {
            $_.PartitionNumber -notin @($reclaimable | ForEach-Object { $_.PartitionNumber }) -and
            [int64]$_.Offset -ge $cursor
        })
        if ($nonContiguousRecovery.Count -gt 0) {
            $invalidReason = 'recovery-typed partitions are separated from C: by a non-recovery partition'
        }
    }

    # Usable extent end = diskSize - 1 MiB. Clamp both branches before
    # aligning so no partition (blocking or last reclaimable) can push
    # tailEnd past the disk-end reserve. A factory partition that ends
    # exactly 1 MiB past the reserve would otherwise produce a plan the
    # post-delete geometry check always rejects.
    $usableEnd = [int64]($diskSize - 1MB)
    $tailEnd = if ($blockingPartition) { [Math]::Min([int64]$blockingPartition.Offset, $usableEnd) } else { $usableEnd }
    if (-not $blockingPartition -and $cursor -lt $tailEnd) {
        $unallocatedBytes += ($tailEnd - $cursor)
    }

    # Single-boundary geometry model. The recovery partition occupies
    # the last BucketSizeBytes of the usable extent, ending at the
    # 1 MiB-aligned usable end; C: ends exactly where the recovery
    # partition begins. Bytes between the raw extent end and the
    # aligned end are the explicit disk-end / alignment reserve and are
    # logged, not treated as a defect. This replaces the earlier
    # "shrink deficit plus alignment slack" model, which could leave an
    # unaccounted trailing gap.
    $alignedManagedExtentEnd = [int64]([Math]::Floor($tailEnd / 1MB) * 1MB)
    $plannedPartitionStart   = [int64]($alignedManagedExtentEnd - $BucketSizeBytes)
    $plannedOSSize           = [int64]($plannedPartitionStart - $osStart)
    $plannedOSEnd            = [int64]$plannedPartitionStart
    $shrinkBytes             = [int64][Math]::Max(0, ($osSize - $plannedOSSize))
    $extendBytes             = [int64][Math]::Max(0, ($plannedOSSize - $osSize))
    $plannedAvailableBytes   = [int64]$BucketSizeBytes
    $alignmentReserveBytes   = [int64]($tailEnd - $alignedManagedExtentEnd)
    $requiresConsolidation   = ($plannedOSSize -lt $SizeMinBytes)
    if (-not $invalidReason -and $plannedOSSize -le 0) {
        $invalidReason = 'planned OS partition size would be zero or negative'
    } elseif (-not $invalidReason -and $alignedManagedExtentEnd -le $osStart) {
        $invalidReason = 'aligned managed extent end precedes the OS partition start'
    }

    return @{
        Valid                       = [string]::IsNullOrEmpty($invalidReason)
        Reason                      = $invalidReason
        RequiresConsolidation       = $requiresConsolidation
        SizeMinBytes                = $SizeMinBytes
        RecoveryBytes               = $recoveryBytes
        UnallocatedBytes            = $unallocatedBytes
        ShrinkBytes                 = $shrinkBytes
        ExtendBytes                 = $extendBytes
        PlannedOSPartitionSize      = $plannedOSSize
        PlannedOSPartitionEnd       = $plannedOSEnd
        PlannedPartitionStart       = $plannedPartitionStart
        PlannedPartitionSize        = $BucketSizeBytes
        PlannedAvailableBytes       = $plannedAvailableBytes
        ContiguousExtentEnd         = $tailEnd
        AlignedManagedExtentEnd     = $alignedManagedExtentEnd
        AlignmentReserveBytes       = $alignmentReserveBytes
        DeletableRecoveryPartitions = @($reclaimable.ToArray())
        BlockingPartition           = $blockingPartition
    }
}

function Invoke-OSPartitionShrink {
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][int]$PartitionNumber,
        [Parameter(Mandatory)][int64]$InitialSizeBytes,
        [Parameter(Mandatory)][int64]$TargetSizeBytes
    )

    if ($Script:DryRun) {
        Write-Log "[DRY RUN] Would shrink OS partition $DiskNumber/$PartitionNumber from $([math]::Round($InitialSizeBytes/1MB,1)) MiB to $([math]::Round($TargetSizeBytes/1MB,1)) MiB before disabling WinRE or deleting partitions"
        return @{ Success = $true; Changed = $false; CurrentSizeBytes = $InitialSizeBytes }
    }

    $sizeMinBefore = [int64](Get-PartitionSupportedSize -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction Stop).SizeMin
    $cVolForLog = Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction SilentlyContinue
    $cFreeForLog = if ($cVolForLog) { [math]::Round([int64]$cVolForLog.SizeRemaining/1GB, 2) } else { "unknown" }
    Write-Log "Pre-destructive shrink target $([math]::Round($TargetSizeBytes/1MB,1)) MiB; SizeMin $([math]::Round($sizeMinBefore/1MB,1)) MiB; C: free at start of shrink $cFreeForLog GiB"
    $success = $false

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if ($attempt -eq 2) {
            Write-Log "Pre-destructive shrink attempt 1 failed. Sleeping 10s and retrying (attempt 2)." -Level WARN
            Start-Sleep -Seconds 10
            $sizeMinAfterSleep = [int64](Get-PartitionSupportedSize -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction Stop).SizeMin
            Write-Log "After 10s sleep: SizeMin $([math]::Round($sizeMinAfterSleep/1MB,1)) MiB (delta $([math]::Round(($sizeMinBefore-$sizeMinAfterSleep)/1MB,1)) MiB)"
        } elseif ($attempt -eq 3) {
            Write-Log "Consolidating free space with defrag.exe C: /x before pre-destructive shrink attempt 3" -Level WARN
            try {
                $defragOutput = & defrag.exe $env:SystemDrive /x 2>&1
                Write-Log "defrag $env:SystemDrive /x exit $LASTEXITCODE"
                if ($defragOutput) { $defragOutput | Select-Object -First 10 | ForEach-Object { Write-Log "  defrag: $_" } }
            } catch {
                Write-Log "defrag invocation failed: $_" -Level WARN
            }
            Start-Sleep 5
            $sizeMinAfterDefrag = [int64](Get-PartitionSupportedSize -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction Stop).SizeMin
            Write-Log "After defrag: SizeMin $([math]::Round($sizeMinAfterDefrag/1MB,1)) MiB (delta $([math]::Round(($sizeMinAfterSleep-$sizeMinAfterDefrag)/1MB,1)) MiB vs post-sleep)"
        }

        try {
            $osPart = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction Stop
            Write-Log "Pre-destructive shrink attempt ${attempt}: $([math]::Round($osPart.Size/1MB,1)) MiB -> $([math]::Round($TargetSizeBytes/1MB,1)) MiB"
            $osPart | Resize-Partition -Size $TargetSizeBytes -ErrorAction Stop
            Start-Sleep 5
            if (Assert-PartitionSizeAfterResize -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ExpectedSizeBytes $TargetSizeBytes) {
                $success = $true
                break
            }
            Write-Log "Pre-destructive shrink attempt $attempt verification failed" -Level WARN
        } catch {
            Write-Log "Pre-destructive shrink attempt $attempt failed: $_" -Level WARN
        }
    }

    $currentPart = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction SilentlyContinue
    $currentSize = if ($currentPart) { [int64]$currentPart.Size } else { [int64]-1 }
    return @{
        Success = $success
        Changed = ($currentSize -ge 0 -and $currentSize -ne $InitialSizeBytes)
        CurrentSizeBytes = $currentSize
    }
}

# Extend the OS partition into space freed by deleting the old recovery
# partitions. Extension is the only way to consume surplus space in the
# single-boundary geometry model; the pre-shrink path handles the shrink
# case. Uses 3 attempts with 5-second spacing between them; on failure
# the caller decides between the safe fallback and OS-fallback.
function Invoke-OSPartitionExtend {
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][int]$PartitionNumber,
        [Parameter(Mandatory)][int64]$InitialSizeBytes,
        [Parameter(Mandatory)][int64]$TargetSizeBytes
    )

    if ($Script:DryRun) {
        Write-Log "[DRY RUN] Would extend OS partition $DiskNumber/$PartitionNumber from $([math]::Round($InitialSizeBytes/1MB,1)) MiB to $([math]::Round($TargetSizeBytes/1MB,1)) MiB after deleting the old recovery partitions"
        return @{ Success = $true; Changed = $false; CurrentSizeBytes = $InitialSizeBytes }
    }

    if ($TargetSizeBytes -le $InitialSizeBytes) {
        return @{ Success = $true; Changed = $false; CurrentSizeBytes = $InitialSizeBytes }
    }

    $success = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $osPart = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction Stop
            Write-Log "Post-delete extend attempt ${attempt}: $([math]::Round($osPart.Size/1MB,1)) MiB -> $([math]::Round($TargetSizeBytes/1MB,1)) MiB"
            $osPart | Resize-Partition -Size $TargetSizeBytes -ErrorAction Stop
            Start-Sleep 3
            if (Assert-PartitionSizeAfterResize -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ExpectedSizeBytes $TargetSizeBytes) {
                $success = $true
                break
            }
            Write-Log "Post-delete extend attempt $attempt verification failed" -Level WARN
        } catch {
            Write-Log "Post-delete extend attempt $attempt failed: $_" -Level WARN
        }
        if ($attempt -lt 3) { Start-Sleep 5 }
    }

    $currentPart = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction SilentlyContinue
    $currentSize = if ($currentPart) { [int64]$currentPart.Size } else { [int64]-1 }
    return @{
        Success = $success
        Changed = ($currentSize -ge 0 -and $currentSize -ne $InitialSizeBytes)
        CurrentSizeBytes = $currentSize
    }
}

function Ensure-AdequateRecoveryPartition {
    param([int]$RequiredWimSizeMB)

    # Dynamic sizing: WIM + 250 MiB free-space + 30 MiB filesystem, rounded
    # UP to the next 100 MiB boundary, minimum 1000 MiB.
    $neededMiB = $RequiredWimSizeMB + $WinREFreeSpaceMiB + $NewPartitionFilesystemMiB
    $bucketSizeMiB = [int]([Math]::Ceiling($neededMiB / $NewPartitionIncrementMiB) * $NewPartitionIncrementMiB)
    if ($bucketSizeMiB -lt $NewPartitionMinimumMiB) { $bucketSizeMiB = $NewPartitionMinimumMiB }
    Write-Log "Creating recovery partition: required $neededMiB MiB -> dynamic size $bucketSizeMiB MiB"

    $osDisk = Get-OSDisk
    if (-not $osDisk) { Write-Log "No OS disk found" -Level ERROR; return $null }
    $osPart = Get-OSPartition
    if (-not $osPart) { Write-Log "No OS partition found" -Level ERROR; return $null }

    $B = [int64]($bucketSizeMiB * 1MB)
    $initialOSSize = [int64]$osPart.Size
    try {
        $supportedSize = Get-PartitionSupportedSize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber -ErrorAction Stop
        $allPartitions = @(Get-Partition -DiskNumber $osDisk.Number -ErrorAction Stop)
    } catch {
        Write-Log "Partition preflight could not read supported size or complete disk layout: $_" -Level WARN
        return @{ Status = "Deferred"; Reason = "partition geometry unavailable" }
    }

    $plan = Get-PartitionPlan -OSDisk $osDisk -OSPartition $osPart -Partitions $allPartitions `
                             -SizeMinBytes ([int64]$supportedSize.SizeMin) -BucketSizeBytes $B `
                             -MaxRecoveryPartitionBytes ([int64]($MaxManagedRecoveryPartitionMiB * 1MB))
    if (-not $plan.Valid) {
        Write-Log "Dedicated recovery partition plan rejected: $($plan.Reason). No partition or WinRE changes were made." -Level WARN
        return @{ Status = "Deferred"; Reason = $plan.Reason }
    }

    $deletableParts = @($plan.DeletableRecoveryPartitions)
    Write-Log "Partition plan: recovery reclaim $([math]::Round($plan.RecoveryBytes/1MB,1)) MiB, contiguous free $([math]::Round($plan.UnallocatedBytes/1MB,1)) MiB, shrink $([math]::Round($plan.ShrinkBytes/1MB,1)) MiB, extend $([math]::Round($plan.ExtendBytes/1MB,1)) MiB, bucket $bucketSizeMiB MiB, planned offset $([math]::Round($plan.PlannedPartitionStart/1MB,1)) MiB, alignment reserve $([math]::Round($plan.AlignmentReserveBytes/1KB,1)) KiB"
    if ($plan.RequiresConsolidation) {
        Write-Log "Current SizeMin $([math]::Round($plan.SizeMinBytes/1MB,1)) MiB exceeds planned C: target $([math]::Round($plan.PlannedOSPartitionSize/1MB,1)) MiB; running the existing pre-destructive sleep and defrag retries before deciding whether to defer" -Level WARN
    }

    $stateBefore = Get-WinREState

    # v44 patch 6: C: encryption is diagnostic, not a veto, for the
    # dedicated-target path. reagentc's BitLocker check is on the target,
    # and the 2026-09-29 test established that C: encryption does not
    # block dedicated-partition work. The OS-fallback route retains its
    # own separate C: gate.
    $willDestroyCurrentRoute = ($stateBefore.Status -eq "Enabled") -or ($deletableParts.Count -gt 0)
    if ($willDestroyCurrentRoute) {
        $cEnc = Test-VolumeEncrypted -MountPoint "C:"

        if ($cEnc -eq $false) {
            Write-Log "Dedicated recovery-partition replacement will remove the current WinRE route (status=$($stateBefore.Status), deletableParts=$($deletableParts.Count)). C: is confirmed fully decrypted; proceeding." -Level INFO
        } else {
            $cEncText = if ($null -eq $cEnc) { "unknown" } else { "$cEnc" }
            Write-Log "Dedicated recovery-partition replacement will remove the current WinRE route (status=$($stateBefore.Status), deletableParts=$($deletableParts.Count)). C: encryption state=$cEncText; proceeding because C: encryption is not a veto for the dedicated-target path. The OS-fallback path retains its separate C: BitLocker gate." -Level WARN
        }
    }

    if ($plan.ShrinkBytes -gt 0) {
        # Pre-shrink free-space verification (v45 patch 1). The shrink
        # reduces C:'s capacity. We refuse to shrink when the projected
        # post-shrink free space on C: would fall below $MinFreeSpaceGB,
        # because a machine at that threshold may not be able to complete
        # the deployment or function normally afterwards. This check runs
        # before any partition or WinRE change.
        $cVolumeLetter = $env:SystemDrive.TrimEnd(':')
        $cVolumeForCheck = Get-Volume -DriveLetter $cVolumeLetter -ErrorAction SilentlyContinue
        if (-not $cVolumeForCheck) {
            Write-Log "Pre-shrink free-space check could not read the C: volume (Get-Volume -DriveLetter $cVolumeLetter returned nothing). Refusing to shrink C: without verifying the $MinFreeSpaceGB GiB reserve is preserved. No partition or WinRE changes were made. The read failure may be transient, so this deferral is not retry-suppressed." -Level WARN
            return @{ Status = "Deferred"; Reason = "C: volume could not be read for free-space check"; RetrySuppressible = $false }
        }
        $currentFreeBytes = [int64]$cVolumeForCheck.SizeRemaining
        $projectedFreeBytes = $currentFreeBytes - [int64]$plan.ShrinkBytes
        $minFreeBytes = [int64]($MinFreeSpaceGB * 1GB)
        Write-Log "Pre-shrink free-space check: C: currently has $([math]::Round($currentFreeBytes/1GB,2)) GiB free; planned shrink is $([math]::Round($plan.ShrinkBytes/1MB,1)) MiB; projected free after shrink is $([math]::Round($projectedFreeBytes/1GB,2)) GiB; minimum required is $MinFreeSpaceGB GiB"
        if ($projectedFreeBytes -lt $minFreeBytes) {
            Write-Log "Pre-shrink free-space check failed: shrinking C: by $([math]::Round($plan.ShrinkBytes/1MB,1)) MiB would leave only $([math]::Round($projectedFreeBytes/1GB,2)) GiB free, below the $MinFreeSpaceGB GiB minimum. Free space on C: and re-run. No partition or WinRE changes were made." -Level WARN
            return @{ Status = "Deferred"; Reason = "post-shrink free space below minimum"; RetrySuppressible = $true }
        }

        $shrinkResult = $null
        try {
            $shrinkResult = Invoke-OSPartitionShrink -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber `
                                                      -InitialSizeBytes $initialOSSize -TargetSizeBytes $plan.PlannedOSPartitionSize
        } catch {
            Write-Log "Pre-destructive OS shrink could not be completed: $_" -Level WARN
        }

        if (-not $shrinkResult -or -not $shrinkResult.Success) {
            $currentOSPart = Get-OSPartition
            if (-not $currentOSPart -or [int64]$currentOSPart.Size -ne $initialOSSize) {
                $restoreOk = Restore-OSPartitionSize -Reason "pre-destructive shrink failure" -TargetSizeBytes $initialOSSize
                if (-not $restoreOk) {
                    Write-Log "C: could not be verified at its original size after pre-destructive shrink failure" -Level ERROR
                }
            }
            Write-Log "Pre-destructive shrink failed after all retries. Existing WinRE registration and recovery partitions remain intact; deferring without OS-fallback." -Level WARN
            return @{ Status = "Deferred"; Reason = "pre-shrink failed"; RetrySuppressible = $true }
        }

        if (-not $Script:DryRun) {
            $osPart = Get-OSPartition
            if (-not $osPart -or -not (Assert-PartitionSizeAfterResize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber -ExpectedSizeBytes $plan.PlannedOSPartitionSize)) {
                Restore-OSPartitionSize -Reason "pre-destructive shrink verification failure" -TargetSizeBytes $initialOSSize | Out-Null
                Write-Log "OS partition did not land at the planned size; preserving the old recovery route and deferring" -Level ERROR
                return @{ Status = "Deferred"; Reason = "pre-shrink verification failed"; RetrySuppressible = $true }
            }
            # Single-boundary model: align the post-resize C: end up to
            # the next 1 MiB, and let the recovery partition fill the
            # remaining space to the aligned managed-extent end. If the
            # resize landed exactly, actualPartitionStart equals the
            # planned start and the recovery partition is exactly
            # PlannedPartitionSize bytes with no trailing gap. If the
            # resize rounded, the recovery size is adjusted to fill the
            # remaining space exactly, so no trailing gap remains.
            $actualOSStart = [int64]$osPart.Offset
            $actualOSEnd = $actualOSStart + [int64]$osPart.Size
            $actualPartitionStart = [int64]([Math]::Ceiling($actualOSEnd / 1MB) * 1MB)
            $actualPartitionEnd = [int64]$plan.AlignedManagedExtentEnd
            $actualPartitionSize = [int64]($actualPartitionEnd - $actualPartitionStart)
            if ($actualPartitionSize -lt $plan.PlannedPartitionSize) {
                Restore-OSPartitionSize -Reason "resize rounding left insufficient planned extent" -TargetSizeBytes $initialOSSize | Out-Null
                Write-Log "Resize rounding leaves only $([math]::Round($actualPartitionSize/1MB,1)) MiB for a $([math]::Round($plan.PlannedPartitionSize/1MB,1)) MiB bucket; preserving the old route and deferring" -Level WARN
                return @{ Status = "Deferred"; Reason = "resize rounding reduced planned extent"; RetrySuppressible = $true }
            }
            if ($actualPartitionStart -ne $plan.PlannedPartitionStart) {
                Write-Log "Resize rounding adjusted the aligned recovery offset from $([math]::Round($plan.PlannedPartitionStart/1MB,3)) MiB to $([math]::Round($actualPartitionStart/1MB,3)) MiB"
            }
            if ($actualPartitionSize -ne $plan.PlannedPartitionSize) {
                Write-Log "Recovery partition size adjusted from $([math]::Round($plan.PlannedPartitionSize/1MB,3)) MiB to $([math]::Round($actualPartitionSize/1MB,3)) MiB to fill the aligned managed extent exactly"
            }
            $plan.PlannedPartitionStart = $actualPartitionStart
            $plan.PlannedPartitionSize = $actualPartitionSize
            $plan.PlannedAvailableBytes = $actualPartitionSize
        } else {
            Write-Log "[DRY RUN] Skipping live geometry verification because no resize was performed"
        }
    } elseif ($plan.ExtendBytes -gt 0) {
        Write-Log "Partition plan requires extending C: by $([math]::Round($plan.ExtendBytes/1MB,1)) MiB to consume surplus space after the old recovery partitions are deleted; no pre-destructive action required"
    } else {
        Write-Log "Partition plan requires no OS resize; existing C: geometry will be preserved"
    }

    if ($stateBefore.Status -eq "Enabled") {
        if ($Script:DryRun) {
            Write-Log "[DRY RUN] Would disable WinRE before partition recreation"
        } else {
            # v47: race-detector recheck immediately before the first
            # possible /disable of this execution. This site runs after
            # the pre-destructive C: shrink, so an abort must restore
            # C: to its captured size before returning Deferred. No
            # partitions have been deleted yet at this point; the old
            # WinRE route is still intact and no route restoration is
            # needed.
            if (-not (Assert-RegisteredWinREUnchanged -Captured $Script:RegisteredSourceFingerprint -CalledFrom 'Ensure-AdequateRecoveryPartition')) {
                Write-Log "Registered WinRE source changed during candidate preparation - aborting before /disable. Restoring C: to its captured size; no partitions have been deleted." -Level WARN
                $restoreOk = Restore-OSPartitionSize -Reason "registered source drifted before /disable" -TargetSizeBytes $initialOSSize
                if (-not $restoreOk) {
                    Write-Log "C: could not be verified at its original size after drift abort; deleting state file so the next run retries from a clean slate" -Level ERROR
                    $statePath = "$env:SystemDrive\Recovery\OEM\$StateFileName"
                    Remove-ItemIfExist $statePath
                }
                # Invalidate staged work: the checkpoint and its WIM are tied
                # to a source that is now known to have drifted.
                Set-Checkpoint -CheckpointFile $CheckpointFile -Step 2 -DesiredStateId $DesiredStateId
                Remove-ItemIfExist "$WorkDir\winre_optimized.wim"
                Remove-ItemIfExist "$WorkDir\base.wim"
                return @{ Status = "Deferred"; Reason = "registered source changed before disable" }
            }
            Write-Log "Disabling WinRE before partition recreation"
            $disableOutput = cmd /c "reagentc /disable 2>&1"
            $disableExit = $LASTEXITCODE
            Write-Log "reagentc /disable: exit=$disableExit, output=$disableOutput"
            if ($disableExit -ne 0) {
                Write-Log "reagentc /disable failed (exit $disableExit): $disableOutput" -Level ERROR
                Restore-OSPartitionSize -Reason "reagentc /disable failure before deletion" -TargetSizeBytes $initialOSSize | Out-Null
                if (Restore-PreviousWinRERoute -PreviousState $stateBefore) {
                    return @{ Status = "Deferred"; Reason = "WinRE disable failed before deletion" }
                }
                return $null
            }
            Start-Sleep 2
            $verifyDisabled = Get-WinREState
            if ($verifyDisabled.Status -ne "Disabled") {
                Write-Log "WinRE is still reported as $($verifyDisabled.Status) after reagentc /disable - aborting before partition deletion" -Level ERROR
                Restore-OSPartitionSize -Reason "WinRE disable verification failure before deletion" -TargetSizeBytes $initialOSSize | Out-Null
                if (Restore-PreviousWinRERoute -PreviousState $stateBefore) {
                    return @{ Status = "Deferred"; Reason = "WinRE disable verification failed before deletion" }
                }
                return $null
            }
            Write-Log "WinRE disable verified"
        }
    }

    Write-Log "Pre-deletion inventory:"
    $activePartForInventory = $null
    if ($stateBefore.Location) {
        $activePartForInventory = Resolve-WinRELocationToPartition -Location $stateBefore.Location
        if (-not $activePartForInventory -and $stateBefore.Status -eq "Enabled") {
            # The active WinRE route is Enabled, but its registered location
            # could not be resolved to a partition. Delete-last ordering
            # depends on knowing which partition is active so the previous
            # route's target survives a mid-loop failure; without it, no
            # partition is protected, and Restore-PreviousWinRERoute has no
            # target to re-enable if a later deletion fails. Defer before
            # any destructive change rather than proceeding without that
            # protection.
            Write-Log "WinRE is Enabled but its registered location ($($stateBefore.Location)) could not be resolved to a partition. The delete-last ordering cannot protect the active partition, and route restoration cannot be attempted if a later deletion fails. Refusing to begin the destructive sequence. No partition or WinRE changes were made." -Level ERROR
            return @{ Status = "Deferred"; Reason = "active WinRE location could not be resolved" }
        }
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

    # Delete the currently-active recovery partition last. If a later
    # deletion fails, the previous WinRE route's target still exists
    # and can be restored by Restore-PreviousWinRERoute. The script
    # only knows the active partition from $stateBefore.Location at
    # this point; anything it cannot identify as active is a candidate
    # for early deletion.
    $orderedDeletable = [System.Collections.Generic.List[object]]::new()
    $activeDeletablePartition = $null
    foreach ($rp in $deletableParts) {
        if ($activePartForInventory -and
            $activePartForInventory.DiskNumber -eq $rp.DiskNumber -and
            $activePartForInventory.PartitionNumber -eq $rp.PartitionNumber) {
            $activeDeletablePartition = $rp
        } else {
            $orderedDeletable.Add($rp)
        }
    }
    if ($activeDeletablePartition) {
        Write-Log "Deferring deletion of the currently-active recovery partition ($($activeDeletablePartition.DiskNumber)/$($activeDeletablePartition.PartitionNumber)) until last so a mid-loop failure leaves it available for route restoration"
        $orderedDeletable.Add($activeDeletablePartition)
    }

    # DryRun stops here: single structural choke point before any
    # state-modifying action.
    if ($Script:DryRun) {
        $resizeSummary = if ($plan.ShrinkBytes -gt 0) {
            "shrink C: by $([math]::Round($plan.ShrinkBytes/1MB,1)) MiB before disabling WinRE"
        } elseif ($plan.ExtendBytes -gt 0) {
            "extend C: by $([math]::Round($plan.ExtendBytes/1MB,1)) MiB after deleting the old recovery partitions"
        } else {
            "leave C: geometry unchanged"
        }
        Write-Log "[DRY RUN] Plan is valid: $resizeSummary, then delete $($deletableParts.Count) adjacent recovery partition(s) and create exactly $bucketSizeMiB MiB at offset $([math]::Round($plan.PlannedPartitionStart/1MB,1)) MiB"
        foreach ($rp in $orderedDeletable) {
            Write-Log "[DRY RUN]   - Disk $($rp.DiskNumber) Part $($rp.PartitionNumber) (size $([math]::Round($rp.Size/1MB,1)) MiB)"
        }
        $letter = Get-AvailableDriveLetter
        Write-Log "[DRY RUN] Would assign drive letter ${letter}: to the new partition, format it NTFS label 'Recovery', apply the recovery GPT attributes, verify no auto-encryption occurred, and remove the drive letter before reagentc /enable"
        return @{ Status = "Created"; DriveLetter = $letter; DiskNumber = $osDisk.Number; PartitionNumber = 999 }
    }

    foreach ($rp in $orderedDeletable) {
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
            $sizeRestoreOk = Restore-OSPartitionSize -Reason "recovery partition deletion failure" -TargetSizeBytes $initialOSSize
            # WinRE was disabled earlier in this routine. The active
            # partition (deleted last) is still present, so the previous
            # route may be restorable. Attempt it before returning.
            $routeRestoreOk = Restore-PreviousWinRERoute -PreviousState $stateBefore
            if ($routeRestoreOk -and $sizeRestoreOk) {
                return @{ Status = "Deferred"; Reason = "recovery partition deletion failed; previous route restored" }
            }
            if ($routeRestoreOk -and -not $sizeRestoreOk) {
                Write-Log "Recovery partition deletion failed and the previous WinRE route was restored, but C: could not be verified at its original size. The geometry-restore flag is set; the state file will be invalidated so the next run retries from clean. Report this as a partial rollback." -Level ERROR
                return @{ Status = "Deferred"; Reason = "recovery partition deletion failed; previous route restored but C: geometry restore unverified" }
            }
            Write-Log "Previous WinRE route could not be restored after deletion failure; WinRE will remain disabled until the next run or manual intervention" -Level ERROR
            return $null
        }
        Write-Log "Confirmed deletion of partition $($rp.PartitionNumber) on disk $($rp.DiskNumber)"
    }

    # Post-delete extension (single-boundary model surplus case). When
    # the plan requires C: to grow into the space the old recovery
    # partitions occupied, perform the extension now that those
    # partitions are gone. On failure, use the safe fallback: start the
    # recovery partition at the current (un-extended) C: end so WinRE
    # remains deployable, and log the residual trailing extent. Exact
    # geometry is a goal, not a reason to leave WinRE disabled.
    if ($plan.ExtendBytes -gt 0) {
        if ($Script:DryRun) {
            Write-Log "[DRY RUN] Would extend C: to $([math]::Round($plan.PlannedOSPartitionSize/1MB,1)) MiB after recovery deletion"
        } else {
            $extendResult = $null
            try {
                $extendResult = Invoke-OSPartitionExtend -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber `
                                                         -InitialSizeBytes $initialOSSize -TargetSizeBytes $plan.PlannedOSPartitionSize
            } catch {
                Write-Log "Post-delete C: extension could not be completed: $_" -Level WARN
            }
            if (-not $extendResult -or -not $extendResult.Success) {
                Write-Log "Post-delete C: extension failed after all retries; attempting the safe fallback (recovery partition at the current C: end) so WinRE remains deployable." -Level WARN
                $fallbackOSPart = Get-OSPartition
                $fallbackUsable = $false
                if ($fallbackOSPart -and $fallbackOSPart.DiskNumber -eq $osDisk.Number) {
                    $fallbackOSEnd = [int64]$fallbackOSPart.Offset + [int64]$fallbackOSPart.Size
                    $fallbackStart = [int64]([Math]::Ceiling($fallbackOSEnd / 1MB) * 1MB)
                    $fallbackEnd = [int64]$plan.AlignedManagedExtentEnd
                    $fallbackSize = [int64]($fallbackEnd - $fallbackStart)
                    if ($fallbackSize -ge $plan.PlannedPartitionSize) {
                        # Create only the planned bucket size; the remainder
                        # between the new partition's end and the aligned
                        # managed extent end is an explicitly logged trailing
                        # unallocated extent. It is not assigned to the
                        # recovery partition, because doing so could exceed
                        # the 2 GiB managed-recovery ceiling when the plan
                        # reclaimed multiple recovery partitions whose
                        # combined size exceeds the bucket. Exact-fit
                        # geometry is preferred when the C: extension
                        # succeeds; when it fails, a correctly sized WinRE
                        # partition takes precedence over consuming the
                        # residual space.
                        $fallbackTrailingExtent = [int64]($fallbackEnd - ($fallbackStart + $plan.PlannedPartitionSize))
                        Write-Log "Extension-failure fallback: creating recovery partition at $([math]::Round($fallbackStart/1MB,3)) MiB with size $([math]::Round($plan.PlannedPartitionSize/1MB,3)) MiB (bucket size, not full extent; $([math]::Round($fallbackTrailingExtent/1MB,3)) MiB trailing unallocated extent will remain between the recovery partition end and the aligned managed extent end; the C: extension was not performed)"
                        $plan.PlannedOSPartitionSize = [int64]$fallbackOSPart.Size
                        $plan.PlannedOSPartitionEnd = $fallbackOSEnd
                        $plan.PlannedPartitionStart = $fallbackStart
                        # PlannedPartitionSize is left at the bucket size.
                        $plan.PlannedAvailableBytes = $plan.PlannedPartitionSize
                        $plan.FallbackTrailingExtentBytes = $fallbackTrailingExtent
                        $Script:nonFatalWarning = $true
                        $fallbackUsable = $true
                    } else {
                        Write-Log "Extension-failure fallback unavailable: only $([math]::Round($fallbackSize/1MB,1)) MiB free after the current C: end, less than the $([math]::Round($plan.PlannedPartitionSize/1MB,1)) MiB bucket. Falling through to the caller's OS-fallback decision." -Level ERROR
                    }
                } else {
                    Write-Log "Extension-failure fallback unavailable: could not re-query the OS partition. Falling through to the caller's OS-fallback decision." -Level ERROR
                }
                if (-not $fallbackUsable) {
                    Restore-OSPartitionSize -Reason "post-delete extension failure" -TargetSizeBytes $initialOSSize | Out-Null
                    return $null
                }
            }
        }
    }

    $osPart = Get-OSPartition
    if (-not $osPart -or -not (Assert-PartitionSizeAfterResize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber -ExpectedSizeBytes $plan.PlannedOSPartitionSize)) {
        Write-Log "OS partition does not match the planned size after recovery deletion" -Level ERROR
        Restore-OSPartitionSize -Reason "post-delete geometry verification failure" -TargetSizeBytes $initialOSSize | Out-Null
        return $null
    }

    $newOffset = [int64]$plan.PlannedPartitionStart
    $newSize = [int64]$plan.PlannedPartitionSize
    $plannedEnd = $newOffset + $newSize
    $currentPartitions = @(Get-Partition -DiskNumber $osDisk.Number -ErrorAction Stop)
    $overlap = @($currentPartitions | Where-Object {
        [int64]$_.Offset -lt $plannedEnd -and ([int64]$_.Offset + [int64]$_.Size) -gt $newOffset
    })
    $diskSizeNow = [int64](Get-Disk -Number $osDisk.Number -ErrorAction Stop).Size
    if ($overlap.Count -gt 0 -or $plannedEnd -gt ($diskSizeNow - 1MB)) {
        Write-Log "Planned recovery extent is no longer free after deletion (offset=$newOffset size=$newSize overlapCount=$($overlap.Count)); restoring original C: size" -Level ERROR
        Restore-OSPartitionSize -Reason "planned recovery extent unavailable" -TargetSizeBytes $initialOSSize | Out-Null
        return $null
    }

    # Apply recovery type GUID at creation (v43 patch 5) to close the
    # Device Encryption window between New-Partition and
    # Set-RecoveryPartitionAttributes.
    $gptRecoveryType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
    $style = ($osDisk.PartitionStyle)
    $newPart = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $currentPartitions = @(Get-Partition -DiskNumber $osDisk.Number -ErrorAction Stop)
            $overlap = @($currentPartitions | Where-Object {
                [int64]$_.Offset -lt $plannedEnd -and ([int64]$_.Offset + [int64]$_.Size) -gt $newOffset
            })
            if ($overlap.Count -gt 0) { throw "planned recovery extent is occupied by partition $($overlap[0].PartitionNumber)" }
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
            }
        }
    }
    if (-not $newPart) {
        Write-Log "New-Partition failed after 3 attempts" -Level ERROR
        Restore-OSPartitionSize -Reason "New-Partition failed after 3 attempts" -TargetSizeBytes $initialOSSize | Out-Null
        return $null
    }

    # Whole-layout assertion (item 5). New-Partition returning success
    # does not by itself prove the partition landed at the planned
    # offset and size, or that the OS partition ends where the plan
    # expected. Re-query and verify; on failure, remove the orphan and
    # return $null so the caller falls back as it does for Format-Volume
    # failure.
    if (-not (Assert-RecoveryPartitionLayout -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -ExpectedOffsetBytes $newOffset -ExpectedSizeBytes $newSize -ExpectedEndBytes $plan.AlignedManagedExtentEnd)) {
        Write-Log "Recovery partition did not land at the planned geometry - removing it and deferring" -Level ERROR
        Remove-OrphanPartition -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Reason "post-creation geometry assertion failed" -TargetOSPartitionSizeBytes $initialOSSize | Out-Null
        return $null
    }

    try {
        Format-Volume -Partition $newPart -FileSystem NTFS -NewFileSystemLabel 'Recovery' -Confirm:$false -Force | Out-Null
    } catch {
        Write-Log "Format-Volume failed: $_" -Level ERROR
        Remove-OrphanPartition -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Reason "Format-Volume failure (main path)" -TargetOSPartitionSizeBytes $initialOSSize | Out-Null
        return $null
    }
    Start-Sleep 3

    # Attributes before drive letter — a freshly-formatted NTFS partition
    # with a letter is a candidate for auto-encryption on Win11 24H2+.
    $attrsOk = Set-RecoveryPartitionAttributes -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Style $style
    if (-not $attrsOk) {
        Write-Log "Could not set recovery attributes on newly created partition - proceeding but BitLocker may encrypt it" -Level WARN
    }

    # Reuse a letter held earlier this run if now free; MountedDevices
    # caches mappings and reuse avoids assign/remove/reassign churn.
    $preferredLetter = $null
    foreach ($prev in $Script:tempDriveLetters) {
        if (-not (Get-Volume -DriveLetter $prev -ErrorAction SilentlyContinue)) {
            $preferredLetter = $prev
            break
        }
    }
    if (-not $preferredLetter) { $preferredLetter = Get-AvailableDriveLetter }
    if (-not $preferredLetter) {
        Write-Log "No drive letter available" -Level ERROR
        Remove-OrphanPartition -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Reason "no drive letter available" -TargetOSPartitionSizeBytes $initialOSSize | Out-Null
        return $null
    }
    $assignedLetter = Invoke-DriveLetterAssignment -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -PreferredLetter $preferredLetter
    if (-not $assignedLetter) {
        Write-Log "Could not assign ANY drive letter to new recovery partition" -Level ERROR
        Remove-OrphanPartition -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Reason "drive-letter assignment failed" -TargetOSPartitionSizeBytes $initialOSSize | Out-Null
        return $null
    }
    $Script:tempDriveLetters.Add($assignedLetter)

    Start-Sleep 5
    $encNewState = Test-VolumeEncrypted -MountPoint "${assignedLetter}:"
    if ($null -eq $encNewState) {
        Write-Log "Newly created recovery partition encryption state unknown - proceeding; Set-RecoveryPartitionReadyForWinRE will retry at the deploy step" -Level WARN
    }
    if ($encNewState -eq $true) {
        # Decrypt in place; a claimed partition does not re-encrypt after
        # manage-bde -off completes (2026-09-29 field evidence).
        Write-Log "Newly created recovery partition is BitLocker-managed - decrypting in place" -Level WARN
        if (-not (Set-RecoveryPartitionReadyForWinRE -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber)) {
            Write-Log "Could not make newly created recovery partition unencrypted - aborting recovery partition creation" -Level ERROR
            Remove-OrphanPartition -DiskNumber $osPart.DiskNumber -PartitionNumber $newPart.PartitionNumber -Reason "in-place decryption failed" -TargetOSPartitionSizeBytes $initialOSSize | Out-Null
            return $null
        }
        Write-Log "Newly created recovery partition decrypted in place"
    } elseif ($encNewState -eq $false) {
        Write-Log "Verified new recovery partition is not encrypted"
    }

    New-DirectoryIfNotExists "${assignedLetter}:\Recovery\WindowsRE"
    Write-Log "Created fresh recovery partition at ${assignedLetter}:"
    return @{ Status = "Created"; DriveLetter = $assignedLetter; DiskNumber = $osDisk.Number; PartitionNumber = $newPart.PartitionNumber }
}

# =========================== PARTITION SELECTION ===========================
function Find-SuitableRecoveryPartition {
    param([Parameter(Mandatory)][int]$RequiredWimSizeMB)

    $osDisk = Get-OSDisk
    if (-not $osDisk) { Write-Log "Find-SuitableRecoveryPartition: no OS disk" -Level WARN; return $null }

    $parts = @(
        Get-RecoveryPartitions -DiskNumber $osDisk.Number |
            Where-Object {
                ($_.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}') -or
                ($_.MbrType -eq 0x27)
            }
    )
    if ($parts.Count -eq 0) { Write-Log "Find-SuitableRecoveryPartition: no recovery partitions on boot disk"; return $null }
    if ($parts.Count -gt 1) { Write-Log "Find-SuitableRecoveryPartition: multiple ($($parts.Count)) recovery partitions - will relocate"; return $null }

    $osPart = Get-OSPartition
    $requiredBytes = [int64](($RequiredWimSizeMB + $WinREFreeSpaceMiB) * 1MB)

    foreach ($candidate in $parts) {
        if ($osPart -and $candidate.DiskNumber -eq $osPart.DiskNumber -and $candidate.PartitionNumber -eq $osPart.PartitionNumber) {
            Write-Log "Find-SuitableRecoveryPartition: candidate $($candidate.PartitionNumber) is the OS partition - skip"
            continue
        }
        if ([int64]$candidate.Size -gt [int64]($MaxManagedRecoveryPartitionMiB * 1MB)) {
            Write-Log "Find-SuitableRecoveryPartition: preserving oversized recovery-typed candidate $($candidate.PartitionNumber) ($([math]::Round($candidate.Size/1MB,1)) MiB > $MaxManagedRecoveryPartitionMiB MiB safety ceiling) for operator review" -Level WARN
            continue
        }
        if ($candidate.Size -lt $requiredBytes) {
            Write-Log "Find-SuitableRecoveryPartition: candidate $($candidate.PartitionNumber) total size $([math]::Round($candidate.Size/1MB,1)) MiB < required $([math]::Round($requiredBytes/1MB,1)) MiB"
            continue
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
# Returns: "ok" | "reboot" | "failed" | "bitlocker".
# reagentc's BitLocker check is on the TARGET volume; callers are
# responsible for preparing the target before calling this function.
function Invoke-ReagentcEnable {
    param(
        [switch]$AllowTempLetter,
        [hashtable]$Partition = $null,
        [string]$ReRegisterPath = $null
    )

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

# Compare two WinRE locations for equivalence. String-compares first;
# falls back to resolving both to a disk/partition identity, because
# reagentc may report the same volume in either the GLOBALROOT or the
# Volume-GUID form after a disable/enable cycle.
function Test-WinRELocationMatches {
    param(
        [AllowEmptyString()][string]$LocationA,
        [AllowEmptyString()][string]$LocationB
    )
    if (-not $LocationA -or -not $LocationB) { return $false }
    $normA = $LocationA.TrimEnd('\')
    $normB = $LocationB.TrimEnd('\')
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($normA, $normB)) { return $true }
    $partA = Resolve-WinRELocationToPartition -Location $LocationA
    $partB = Resolve-WinRELocationToPartition -Location $LocationB
    if ($partA -and $partB -and
        $partA.DiskNumber -eq $partB.DiskNumber -and
        $partA.PartitionNumber -eq $partB.PartitionNumber) { return $true }
    return $false
}

function Restore-PreviousWinRERoute {
    param([Parameter(Mandatory)][hashtable]$PreviousState)

    if ($Script:DryRun) { Write-Log "[DRY RUN] Would verify or restore the previous WinRE registration"; return $true }
    if ($PreviousState.Status -ne 'Enabled') { return $false }

    $currentState = Get-WinREState
    if ($currentState.Status -eq 'Enabled') {
        if (Test-WinRELocationMatches -LocationA $currentState.Location -LocationB $PreviousState.Location) {
            return $true
        }
        Write-Log "WinRE is already Enabled but registered at a location that does not match the previous route (current=$($currentState.Location), previous=$($PreviousState.Location)); proceeding to restore the previous route" -Level WARN
    }
    if (-not $PreviousState.Location) {
        Write-Log "Cannot restore previous WinRE route: prior location is unknown" -Level ERROR
        return $false
    }

    $previousPart = Resolve-WinRELocationToPartition -Location $PreviousState.Location
    if (-not $previousPart) {
        Write-Log "Cannot restore previous WinRE route: prior partition cannot be resolved" -Level ERROR
        return $false
    }

    $osPart = Get-OSPartition
    $isOSFallback = ($osPart -and $previousPart.DiskNumber -eq $osPart.DiskNumber -and $previousPart.PartitionNumber -eq $osPart.PartitionNumber)
    if ($isOSFallback) {
        $cEncrypted = Test-VolumeEncrypted -MountPoint $env:SystemDrive
        if ($cEncrypted -ne $false) {
            Write-Log "Cannot restore previous OS-fallback route: C: is not confirmed fully decrypted (Test-VolumeEncrypted=$cEncrypted)" -Level WARN
            return $false
        }
        $reRegisterPath = "$env:SystemDrive\Recovery\WindowsRE"
        $enableResult = Invoke-ReagentcEnable -ReRegisterPath $reRegisterPath
    } else {
        $isTypedRecovery = ($previousPart.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}') -or ($previousPart.MbrType -eq 0x27)
        if (-not $isTypedRecovery) {
            Write-Log "Cannot restore previous WinRE route: prior target is not a type-coded recovery partition" -Level ERROR
            return $false
        }
        if (-not (Set-RecoveryPartitionReadyForWinRE -DiskNumber $previousPart.DiskNumber -PartitionNumber $previousPart.PartitionNumber)) {
            Write-Log "Cannot restore previous WinRE route: target partition is not ready for reagentc" -Level ERROR
            return $false
        }
        $reRegisterPath = "\\?\GLOBALROOT\device\harddisk$($previousPart.DiskNumber)\partition$($previousPart.PartitionNumber)\Recovery\WindowsRE"
        $enableResult = Invoke-ReagentcEnable -AllowTempLetter -Partition @{ DiskNumber = $previousPart.DiskNumber; PartitionNumber = $previousPart.PartitionNumber } -ReRegisterPath $reRegisterPath
    }

    $restoredState = Get-WinREState
    $locationMatches = Test-WinRELocationMatches -LocationA $restoredState.Location -LocationB $PreviousState.Location
    $restored = ($enableResult -in @('ok','reboot') -and $restoredState.Status -eq 'Enabled' -and $locationMatches)
    if (-not $restored) {
        Write-Log "Previous WinRE route could not be confirmed on the expected location after restore attempt (result=$enableResult, status=$($restoredState.Status), location=$($restoredState.Location), expected=$($PreviousState.Location))" -Level ERROR
    }
    return $restored
}

function Invoke-ReAgentRegistrationRepair {
    param([string]$ReRegisterPath)

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

    # C:\Recovery\ReAgentOld.xml is deliberately NOT touched. It is the
    # downlevel/servicing configuration used by Windows Setup; manual
    # test confirmed its deletion does not resolve the issue.
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

# v47: read DISM servicing metadata from a WIM for source-selection
# comparison. Returns $null if the image cannot be read.
function Get-WimServicingMetadata {
    param([string]$WimPath)
    if (-not $WimPath) { return $null }
    try {
        $info = Get-WindowsImage -ImagePath $WimPath -Index 1 -ErrorAction Stop
        return @{
            Version      = [string]$info.Version
            SPBuild      = [string]$info.SPBuild
            SPLevel      = [string]$info.SPLevel
            Architecture = [string]$info.Architecture
        }
    } catch {
        Write-Log "Get-WimServicingMetadata: could not read $WimPath - $_" -Level WARN
        return $null
    }
}

# v47: compare two DISM servicing-metadata sets.
#   'A-newer-or-equal' when A is at least as new as B
#   'A-older'          when A is older than B
#   $null              when the comparison cannot be made
# Ordering keys: Version (strict parse on both sides), then SPBuild
# (strict parse on both sides), then SPLevel (permissive - used only
# when both sides parse). Architecture must match. Microsoft documents
# that an LCU bumps ServicePackBuild while the base Version can remain
# unchanged, so Version alone is not sufficient. A Dynamic Update may
# not change either field, so equal metadata does not prove
# byte-for-byte equality; that tradeoff is accepted here and is handled
# at the checkpoint layer by source-content-hash binding.
function Compare-WimServicingMetadata {
    param($MetaA, $MetaB)
    if (-not $MetaA -or -not $MetaB) { return $null }
    if ($MetaA.Architecture -and $MetaB.Architecture -and
        $MetaA.Architecture -ne $MetaB.Architecture) { return $null }

    # Primary key: Version (Major.Minor.Build.Revision).
    # Version must parse on both sides to order at all; if it does not,
    # the comparison is indeterminate and the caller falls back to LKG.
    $vA = $null; $vB = $null
    try { $vA = [System.Version]([string]$MetaA.Version) } catch { }
    try { $vB = [System.Version]([string]$MetaB.Version) } catch { }
    if (-not $vA -or -not $vB) { return $null }
    if ($vA -gt $vB) { return 'A-newer-or-equal' }
    if ($vA -lt $vB) { return 'A-older' }

    # Version tied. Microsoft's WinRE documentation states that an LCU
    # bumps the servicing build while the base Version can remain
    # unchanged; SPBuild is the numeric UBR and is the correct
    # discriminator in that case. If Version is tied but either SPBuild
    # cannot be parsed, the comparison is indeterminate; return $null
    # rather than treating it as equality.
    $sA = 0; $sB = 0
    if (-not [int]::TryParse([string]$MetaA.SPBuild, [ref]$sA)) { return $null }
    if (-not [int]::TryParse([string]$MetaB.SPBuild, [ref]$sB)) { return $null }
    if ($sA -gt $sB) { return 'A-newer-or-equal' }
    if ($sA -lt $sB) { return 'A-older' }

    # SPBuild tied. SPLevel is a secondary tiebreak; use it only when
    # both sides parse. If either side is unparseable, the tie stands
    # on the two primary keys alone.
    $lA = 0; $lB = 0
    if ([int]::TryParse([string]$MetaA.SPLevel, [ref]$lA) -and
        [int]::TryParse([string]$MetaB.SPLevel, [ref]$lB)) {
        if ($lA -gt $lB) { return 'A-newer-or-equal' }
        if ($lA -lt $lB) { return 'A-older' }
    }

    # Version and SPBuild both tied; SPLevel either tied or not
    # comparable on both sides. Equal on all comparable keys means the
    # registered WIM is eligible.
    return 'A-newer-or-equal'
}

# v47: validate the manager's last-known-good copy. The LKG is
# C:\Recovery\WindowsRE\winre.wim and is only trusted when its SHA256
# matches state.CurrentImageHash. A failed fallback copy in a prior run
# breaks the equality, so a partial or stale file cannot be silently
# promoted. No new persistence field is needed.
#
# Returns a hashtable @{ Path = <string>; Hash = <string> } when the
# LKG is valid, $null otherwise. Callers that need only the path read
# .Path; callers that need the content hash for source-binding or
# checkpoint validation read .Hash.
function Get-LKGWinREImagePath {
    param([string]$StoredHash)
    if (-not $StoredHash) { return $null }
    $candidate = "$env:SystemDrive\Recovery\WindowsRE\winre.wim"
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $null }
    $hash = Get-LiveWimHash -WimPath $candidate
    if (-not $hash) {
        Write-Log "Get-LKGWinREImagePath: LKG candidate exists but is unreadable: $candidate" -Level WARN
        return $null
    }
    if ($hash -ne $StoredHash) {
        Write-Log "Get-LKGWinREImagePath: LKG candidate hash $hash does not match state.CurrentImageHash $StoredHash - not treated as LKG"
        return $null
    }
    return @{ Path = $candidate; Hash = $hash }
}

# =========================== REGISTERED-SOURCE FINGERPRINT ===========================
# v47: race detector for the interval between source selection and the
# first reagentc /disable of an execution. WU may service or replace
# the registered WinRE while the script is preparing its candidate.
# The detector catches that drift and aborts before disabling.
#
# This is NOT a lock. Microsoft does not document reagentc /disable as
# atomic with respect to Windows Update, so the microseconds between
# the recheck and /disable returning cannot be eliminated without
# moving work into the disable->enable window and violating invariant
# 3. The detector narrows the window from minutes to that residual.
#
# Get-RegisteredWinREFingerprint returns a hashtable with a Status
# field:
#   'none'      - WinRE was not Enabled or had no registered location
#                 at capture time. The recheck verifies no registered
#                 source has appeared since.
#   'unreadable' - WinRE was Enabled with a registered location but no
#                 readable WIM was found there. The recheck verifies
#                 Location and Version remain unchanged and the WIM is
#                 still unreadable before allowing the verified-source
#                 repair path to proceed.
#   'captured'   - fingerprint fully captured (Location, Version, Hash).
#                 The recheck re-reads all three and returns $true only
#                 when nothing changed.

function Get-RegisteredWinREFingerprint {
    param(
        [Parameter(Mandatory)][hashtable]$WinREState,
        [AllowEmptyString()][string]$RegisteredWimPath,
        [AllowNull()][string]$RegisteredWimHash
    )
    if (-not $WinREState -or $WinREState.Status -ne 'Enabled') {
        return @{ Status = 'none' }
    }
    if (-not $WinREState.Location) {
        return @{ Status = 'none' }
    }
    if ($RegisteredWimPath -and $RegisteredWimHash) {
        return @{
            Status   = 'captured'
            Location = $WinREState.Location
            Version  = $WinREState.Version
            Hash     = $RegisteredWimHash
        }
    }
    # WinRE is Enabled with a registered location, but no readable WIM was
    # found there. The source cannot be fingerprinted. The recheck helper
    # defers on this state rather than treating it as "no source."
    return @{
        Status   = 'unreadable'
        Location = $WinREState.Location
        Version  = $WinREState.Version
    }
}

function Assert-RegisteredWinREUnchanged {
    param(
        [AllowNull()][object]$Captured,
        [Parameter(Mandatory)][string]$CalledFrom
    )

    # Helper: read the current registered WIM hash if the registered
    # location yields a readable WIM. Returns $null when not readable.
    $readNowRegisteredHash = {
        param($state)
        if (-not $state -or $state.Status -ne 'Enabled' -or -not $state.Location) { return $null }
        try {
            $tempLoc = @(Ensure-RecoveryPartitionAccess -TargetDir $state.Location)[0]
            if (-not $tempLoc) { return $null }
            # Probe both forms: the resolver returns a drive root when the
            # registered location was a raw partition path, and returns the
            # subpath directly when the registered location already
            # included Recovery\WindowsRE. Only one candidate resolves to a
            # real file on a given machine.
            foreach ($cand in @(Join-Path $tempLoc "Recovery\WindowsRE\winre.wim"; Join-Path $tempLoc "winre.wim")) {
                if (Test-Path -Path $cand -PathType Leaf -ErrorAction SilentlyContinue) {
                    $h = Get-LiveWimHash -WimPath $cand
                    if ($h) { return $h }
                }
            }
        } catch { }
        return $null
    }

    # No registered source existed at capture time. If one has appeared
    # since (WU may have registered WinRE), defer to re-evaluate source
    # selection; otherwise there is nothing to protect.
    if (-not $Captured -or $Captured.Status -eq 'none') {
        $nowForNone = Get-WinREState
        if ($nowForNone.Status -eq 'Enabled') {
            Write-Log "Registered-source recheck at $CalledFrom : no registered source at capture time, but WinRE is now Enabled at $($nowForNone.Location) - deferring to re-evaluate source selection" -Level WARN
            return $false
        }
        Write-Log "Registered-source recheck at $CalledFrom : no registered source present at capture or now; nothing to protect"
        return $true
    }

    # Registered source existed but its WIM was not readable at capture
    # time. Distinguish two cases:
    #   - still unreadable: the situation is unchanged and the repair
    #     path must be allowed to proceed (otherwise a persistently
    #     corrupt registered WIM would block every run)
    #   - now readable: WU may have delivered a new one; defer to
    #     re-evaluate source selection
    if ($Captured.Status -eq 'unreadable') {
        $nowForUnreadable = Get-WinREState
        if ($nowForUnreadable.Status -ne 'Enabled') {
            Write-Log "Registered-source recheck at $CalledFrom : registered WIM was unreadable at capture time; WinRE status is now $($nowForUnreadable.Status) - deferring to re-evaluate" -Level WARN
            return $false
        }
        # Compare Location and Version against the captured values. A
        # redirect to a different location (even one whose WIM is also
        # unreadable) or a servicing bump means the registered source is
        # not the one we captured; defer to re-evaluate.
        $capturedLocU = if ($Captured.Location) { $Captured.Location.TrimEnd('\') } else { '' }
        $nowLocU      = if ($nowForUnreadable.Location) { $nowForUnreadable.Location.TrimEnd('\') } else { '' }
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($capturedLocU, $nowLocU)) {
            Write-Log "Registered-source recheck at $CalledFrom : registered WIM was unreadable at capture time; registered location changed from $($Captured.Location) to $($nowForUnreadable.Location) - deferring to re-evaluate source selection" -Level WARN
            return $false
        }
        if ($nowForUnreadable.Version -ne $Captured.Version) {
            Write-Log "Registered-source recheck at $CalledFrom : registered WIM was unreadable at capture time; registered version changed from $($Captured.Version) to $($nowForUnreadable.Version) - deferring to re-evaluate source selection" -Level WARN
            return $false
        }
        $nowHashUnreadable = & $readNowRegisteredHash $nowForUnreadable
        if ($nowHashUnreadable) {
            Write-Log "Registered-source recheck at $CalledFrom : registered WIM was unreadable at capture time but is now readable - deferring to re-evaluate source selection" -Level WARN
            return $false
        }
        Write-Log "Registered-source recheck at $CalledFrom : registered WIM remains unreadable at the same location and version; allowing repair path to proceed against the separately verified source"
        return $true
    }

    # Captured is 'captured'.
    $now = Get-WinREState
    if ($now.Status -ne 'Enabled') {
        Write-Log "Registered-source recheck at $CalledFrom : WinRE status changed from Enabled to $($now.Status) since capture; cannot verify source unchanged - deferring" -Level WARN
        return $false
    }

    $capturedLoc = if ($Captured.Location) { $Captured.Location.TrimEnd('\') } else { '' }
    $nowLoc      = if ($now.Location)      { $now.Location.TrimEnd('\')      } else { '' }
    $locChanged  = -not [System.StringComparer]::OrdinalIgnoreCase.Equals($capturedLoc, $nowLoc)
    $verChanged  = ($now.Version -ne $Captured.Version)

    $hashChanged = $false
    if ($Captured.Hash) {
        $nowHash = & $readNowRegisteredHash $now
        if (-not $nowHash) {
            Write-Log "Registered-source recheck at $CalledFrom : registered WIM hash could not be re-read; treating as changed (safe side)" -Level WARN
            $hashChanged = $true
        } elseif ($nowHash -ne $Captured.Hash) {
            $hashChanged = $true
        }
    }

    if ($locChanged -or $verChanged -or $hashChanged) {
        Write-Log "Registered-source recheck at $CalledFrom : CHANGED (location=$locChanged version=$verChanged hash=$hashChanged); captured loc=$($Captured.Location) ver=$($Captured.Version); now loc=$($now.Location) ver=$($now.Version)" -Level WARN
        return $false
    }

    Write-Log "Registered-source recheck at $CalledFrom : unchanged (location=$($now.Location), version=$($now.Version))"
    return $true
}

# =========================== OEM PROVIDERS ===========================
function Get-DellWinPEPack {
    param($Hardware)
    if (-not $Script:DellWinPEMap) {
        Write-Log "Downloading Dell WinPE map from gist"
        for ($retry = 1; $retry -le 3; $retry++) {
            try { $Script:DellWinPEMap = Invoke-RestMethod -Uri $DellWinPEMapUrl -Headers $GitHubHeaders -UseBasicParsing -TimeoutSec $NetworkTimeoutSeconds -ErrorAction Stop; break }
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
            try { $Script:HPWinPEMap = Invoke-RestMethod -Uri $HPWinPEMapUrl -Headers $GitHubHeaders -UseBasicParsing -TimeoutSec $NetworkTimeoutSeconds -ErrorAction Stop; break }
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

# Sets $Script:LenovoPackResolution to one of:
#   "unknown-mt"      - machine type could not be determined (permanent)
#   "map-unavailable" - map fetch failed (transient)
#   "no-entry"        - map loaded, no entry for this MT (permanent)
#   "malformed-entry" - key exists but is missing winpe.url (config error)
#   "resolved"        - pack returned successfully
# The caller uses this to distinguish "expected no-pack" from a real
# failure, which previously were conflated by a $null return.
function Get-LenovoWinPEPack {
    param($Hardware)
    $Script:LenovoPackResolution = "unknown"
    $mt = $Hardware.MachineType
    if (-not $mt -or $mt -eq 'UNKN') {
        Write-Log "Lenovo WinPE map: cannot resolve - machine type unknown" -Level WARN
        $Script:LenovoPackResolution = "unknown-mt"
        return $null
    }
    if (-not $Script:LenovoWinPEMap) {
        Write-Log "Downloading Lenovo WinPE map from gist"
        for ($retry = 1; $retry -le 3; $retry++) {
            try { $Script:LenovoWinPEMap = Invoke-RestMethod -Uri $LenovoWinPEMapUrl -Headers $GitHubHeaders -UseBasicParsing -TimeoutSec $NetworkTimeoutSeconds -ErrorAction Stop; break }
            catch { Write-Log "Lenovo map download attempt $retry failed: $_" -Level WARN; if ($retry -lt 3) { Start-Sleep 5 } }
        }
        if (-not $Script:LenovoWinPEMap) {
            Write-Log "Could not download Lenovo WinPE map" -Level WARN
            $Script:LenovoPackResolution = "map-unavailable"
            return $null
        }
        Write-Log "Lenovo WinPE map loaded ($(@($Script:LenovoWinPEMap.Models.PSObject.Properties).Count) model entries)"
    }
    $entry = $Script:LenovoWinPEMap.Models.$mt
    if (-not $entry) {
        # Many Lenovo MTs have no published WinPE pack; this is the
        # expected, permanent answer for those models.
        Write-Log "No WinPE pack in Lenovo map for machine type $mt (expected for some Lenovo models)" -Level INFO
        $Script:LenovoPackResolution = "no-entry"
        return $null
    }
    $winpe = $entry.winpe
    if (-not $winpe -or -not $winpe.url) {
        Write-Log "Lenovo map entry for $mt has no WinPE URL - treating as configuration failure, not a legitimate no-pack result" -Level WARN
        $Script:LenovoPackResolution = "malformed-entry"
        return $null
    }
    Write-Log "Lenovo map resolved $mt -> $($winpe.name) (SHA256: $($winpe.sha256))"
    $Script:LenovoPackResolution = "resolved"
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
    # "N" is the deterministic placeholder for any CPU whose Intel
    # generation cannot be parsed (AMD, Celeron, Pentium, Atom, Xeon,
    # N/J-series). It is stable across re-runs.
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
# v47: narrow read of a stale state file's CurrentImageHash, used only
# for LKG validation during the v46 -> v47 migration.
#
# Read-WinREState correctly refuses to accept a state file whose
# DesiredStateId does not match the current one. On the first v47 run on
# a machine whose state file was written by v46 or earlier, that refusal
# turns $storedHash into $null, which makes Get-LKGWinREImagePath refuse
# to promote C:\Recovery\WindowsRE\winre.wim to LKG status even though the
# file is the manager's own last-known-good copy from the prior
# deployment.
#
# The CurrentImageHash field records a fact about the machine that
# survives a version boundary: the hash of the last successfully deployed
# WIM. Reading it in isolation lets the LKG validation work across the
# boundary without weakening the DSI gate on operational state.
#
# The value returned here is advisory only. It does NOT make the stale
# state file authoritative and it does NOT enter any gate other than LKG
# validation. Callers must not use it as operational state.
function Get-StaleWinREStateImageHash {
    $path = "$env:SystemDrive\Recovery\OEM\$StateFileName"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $stale = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($stale.CurrentImageHash) { return [string]$stale.CurrentImageHash }
        return $null
    } catch {
        Write-Log "Get-StaleWinREStateImageHash: could not read $path - $_" -Level WARN
        return $null
    }
}

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
        DeployedWinREMetadata    = $null
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
                DeployedWinREMetadata    = if ($state.DeployedWinREMetadata) { [string]$state.DeployedWinREMetadata } else { $null }
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
        [int]$EnableFailureAttempts = 0,
        [string]$DeployedWinREMetadata = $null
    )
    # v47: DeployedWinREMetadata defaults to the script-scoped carry-forward
    # value. Only the full-update deployment path overrides it explicitly.
    if (-not $PSBoundParameters.ContainsKey('DeployedWinREMetadata')) {
        $DeployedWinREMetadata = $Script:DeployedWinREMetadata
    }
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
    if ($DeployedWinREMetadata) { $state.DeployedWinREMetadata = [string]$DeployedWinREMetadata }
    $stateJson = $state | ConvertTo-Json -Depth 3
    $path = "$env:SystemDrive\Recovery\OEM\$StateFileName"

    if ($Script:DryRun) { Write-Log "[DRY RUN] Would write state file"; return }

    # GeometryRestoreFailed means C: is still shrunken after a failed
    # destructive attempt. Delete the state file so the next run treats
    # the state as absent and retries from clean.
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

function Read-PartitionDeferral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$CurrentDesiredStateId)

    $path = "$env:SystemDrive\Recovery\OEM\$PartitionDeferralFileName"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $marker = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($marker.DesiredStateId -eq $CurrentDesiredStateId -and $marker.DesiredStateId) {
            return @{ DesiredStateId = [string]$marker.DesiredStateId; Since = [string]$marker.Since }
        }
        Write-Log "Partition deferral marker is stale for the current DesiredStateId; clearing it"
        Remove-ItemIfExist $path
    } catch {
        Write-Log "Partition deferral marker could not be read; clearing corrupt marker: $_" -Level WARN
        Remove-ItemIfExist $path
    }
    return $null
}

function Write-PartitionDeferral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$DesiredStateId)

    $path = "$env:SystemDrive\Recovery\OEM\$PartitionDeferralFileName"
    $marker = @{
        DesiredStateId = $DesiredStateId
        Since          = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
    if ($Script:DryRun) { Write-Log "[DRY RUN] Would write partition deferral marker"; return }
    try {
        Write-FileAtomically -Path $path -Content ($marker | ConvertTo-Json -Depth 2)
        Write-Log "Wrote partition deferral marker: $path"
    } catch {
        Write-Log "Could not persist partition deferral marker at $path; the existing WinRE route remains preserved, but a later scheduled run may retry the pre-shrink: $_" -Level WARN
    }
}

function Clear-PartitionDeferral {
    $path = "$env:SystemDrive\Recovery\OEM\$PartitionDeferralFileName"
    Remove-ItemIfExist $path
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
    New-DirectoryIfNotExists "$WorkDir\scratch"
    for ($i = 1; $i -le 3; $i++) {
        try { Mount-WindowsImage -ImagePath $ImageFile -Index $Index -Path $MountDir -ScratchDirectory "$WorkDir\scratch" -ErrorAction Stop; return }
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

# =========================== THIRD-PARTY DRIVER STRIP ===========================
# v47: Remove every third-party driver from a mounted image. Hard-gated:
# any failure to enumerate, remove, or re-verify returns $false, and the
# caller MUST reject the candidate. Enumeration failure is NEVER
# interpreted as zero drivers.
#
# Uses Get-WindowsDriver -Path $MountDir WITHOUT -All and WITHOUT a
# provider filter. Microsoft documents this form as the third-party
# inventory of a mounted image. Do not add -All or a provider filter.
#
# Re-enumerates after each removal because published OEM#.inf numbering
# can change as packages are removed. The loop terminates only when a
# fresh enumeration returns zero entries. The budget is generous headroom
# over the initial count and is not expected to be hit in practice.
function Remove-AllThirdPartyDrivers {
    param([Parameter(Mandatory)][string]$MountDir)

    $initialDrivers = $null
    try {
        $initialDrivers = @(Get-WindowsDriver -Path $MountDir -ErrorAction Stop)
    } catch {
        Write-Log "Strip: initial Get-WindowsDriver enumeration failed: $_ - candidate rejected" -Level ERROR
        return $false
    }

    Write-Log "Strip: pre-strip third-party inventory: $($initialDrivers.Count) package(s)"
    foreach ($d in $initialDrivers) {
        $inf      = if ($d.Driver)           { $d.Driver }           else { '(unknown)' }
        $provider = if ($d.ProviderName)     { $d.ProviderName }     else { '(unknown)' }
        $version  = if ($d.Version)          { $d.Version }          else { '(unknown)' }
        $orig     = if ($d.OriginalFileName) { $d.OriginalFileName } else { '(unknown)' }
        Write-Log "Strip:   $inf | $provider | $version | $orig"
    }

    if ($initialDrivers.Count -eq 0) {
        Write-Log "Strip: image already has zero third-party drivers"
        return $true
    }

    $removed = 0
    $budget  = [int](($initialDrivers.Count * 4) + 16)
    for ($i = 0; $i -lt $budget; $i++) {
        $currentDrivers = $null
        try {
            $currentDrivers = @(Get-WindowsDriver -Path $MountDir -ErrorAction Stop)
        } catch {
            Write-Log "Strip: re-enumeration failed at iteration $i : $_ - candidate rejected" -Level ERROR
            return $false
        }

        if ($currentDrivers.Count -eq 0) {
            Write-Log "Strip: verified zero third-party drivers remaining after removing $removed package(s)"
            return $true
        }

        $target    = $currentDrivers[0]
        $targetInf = if ($target.Driver) { $target.Driver } else { $null }
        if (-not $targetInf) {
            Write-Log "Strip: enumeration entry has no Driver field (published INF name) - candidate rejected" -Level ERROR
            return $false
        }

        try {
            Remove-WindowsDriver -Path $MountDir -Driver $targetInf -ErrorAction Stop | Out-Null
            Write-Log "Strip: removed $targetInf"
        } catch {
            Write-Log "Strip: Remove-WindowsDriver failed for $targetInf : $_ - candidate rejected" -Level ERROR
            return $false
        }
        $removed++
    }

    Write-Log "Strip: exhausted iteration budget ($budget) without reaching zero - candidate rejected" -Level ERROR
    return $false
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

# Vendor-specific switches.
#   LENOVO: Inno Setup based self-extractor.
#   HP:     Custom SoftPaq self-extractor.
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
            # populate the target. INF count decides.
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
        $proc = Start-Process -FilePath $7Zip -ArgumentList @("x", "`"$CabPath`"", "-o`"$DestinationDir`"", "-w`"$DestinationDir`"", "-y") -Wait -PassThru -NoNewWindow -ErrorAction Stop
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
# Invoke-WebRequest can throw even after writing a complete file
# (connection reset on the final ACK). The no-hash path therefore
# requires the request to have completed cleanly on the same attempt;
# a partial file left behind by a throwing request is never accepted.
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
            Invoke-WebRequest -Uri $Url -OutFile $DestinationPath -Headers $GitHubHeaders -UseBasicParsing -TimeoutSec $NetworkTimeoutSeconds -ErrorAction Stop
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

# =========================== GITHUB BASE WIM ===========================
# v47: extracted from the Step 2 cold-start path so source selection can
# invoke it from either branch. Returns $true on success, $false on
# unrecoverable failure; the caller maps failure to EXIT_FATAL.
function Get-GitHubBaseWinRE {
    param(
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)]$Hardware
    )
    if (-not (Ensure-7Zip)) {
        Write-Log "7-Zip required" -Level FATAL
        return $false
    }
    $folder = if ($Hardware.IsWin10) { "Win10" } else { "Win11" }
    $apiUrl = "$BaseWinRERepoApi/$folder"
    $files = Invoke-RestMethod -Uri $apiUrl -Headers $GitHubHeaders -UseBasicParsing -TimeoutSec $NetworkTimeoutSeconds -ErrorAction Stop
    $parts = $files | Where-Object { $_.name -match '^[Ww]inre\.7z\.\d+$' } | Sort-Object name
    foreach ($part in $parts) {
        Invoke-WebRequest -Uri $part.download_url -OutFile (Join-Path $WorkDir $part.name) -Headers $GitHubHeaders -UseBasicParsing -TimeoutSec $NetworkTimeoutSeconds -ErrorAction Stop
    }
    # v44 patch 6: remove any stale winre.wim from an interrupted
    # previous extraction, verify extraction produced it, then remove
    # any stale destination base.wim before the rename.
    $extractedWim = Join-Path $WorkDir "winre.wim"
    if (Test-Path -LiteralPath $extractedWim) {
        Write-Log "Removing stale extracted WIM before extraction: $extractedWim" -Level WARN
        Remove-Item -LiteralPath $extractedWim -Force -ErrorAction SilentlyContinue
    }
    & $7Zip x (Join-Path $WorkDir $parts[0].name) -o"$WorkDir" -w"$WorkDir\scratch" -y | Out-Null
    if (-not (Test-Path -LiteralPath $extractedWim -PathType Leaf)) {
        throw "GitHub base WIM extraction did not produce winre.wim"
    }
    $staleBase = Join-Path $WorkDir "base.wim"
    if (Test-Path -LiteralPath $staleBase) {
        Write-Log "Removing stale base.wim before rename: $staleBase" -Level WARN
        Remove-Item -LiteralPath $staleBase -Force -ErrorAction SilentlyContinue
    }
    Rename-Item -LiteralPath $extractedWim -NewName "base.wim" -ErrorAction Stop
    Write-Log "Downloaded base WIM from GitHub"
    return $true
}

# =========================== MAIN ===========================
try {
    New-DirectoryIfNotExists $LogDir
    Write-Log "========== WinRE Manager Started (v$ScriptVersion patch $ScriptPatchLevel) =========="
    if ($Script:DryRun) { Write-Log "*** DRY RUN MODE ***" }

    # ---- Program lock (v44 patch 4) ----
    # Exclusive file handle at FileShare.None. Kernel-enforced, no DACL,
    # released on process exit even after a crash. Skipped under DryRun;
    # non-contention failures log a WARN and proceed unprotected.
    if (-not $Script:DryRun) {
        $lockPath = Join-Path $LogDir "WinREManager.lock"
        try {
            $Script:ProgramLockStream = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            Write-Log "Acquired program lock at $lockPath"
        } catch [System.IO.IOException] {
            Write-Log "Another WinRE Manager instance is already running (program lock file is exclusively held). Exiting without making any changes. This is not a deployment failure - the other instance is doing the work and will complete on its own. If you need to run manually, wait for the other instance to finish, or run scripts\Test-WinRE.ps1 for a read-only diagnostic that is safe to run concurrently." -Level WARN
            exit $EXIT_WARNING
        } catch {
            Write-Log "Could not set up program lock at $lockPath : $_ - proceeding without single-instance protection; concurrent runs may collide" -Level WARN
            $Script:nonFatalWarning = $true
        }
    } else {
        Write-Log "[DRY RUN] Skipping program lock - DryRun is read-only and safe to run concurrently with other instances"
    }

    # ---- Audit Mode / OOBE / sysprep guard ----
    # reagentc /enable is blocked with ERROR_CANCELLED (0x4c7) until the
    # machine reaches a normal desktop. Defer before any WinRE, partition,
    # image, checkpoint, or recovery-state modification.
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

    # ---- Hardware ----
    $Hardware = Get-HardwareObject
    Write-Log "System: $($Hardware.Manufacturer) $($Hardware.Model), MT=$($Hardware.MachineType), OS=$($Hardware.WinPE) (build $($Hardware.Build))"

    # ---- Driver manifest fetch (v44 patch 5) ----
    # Offline fallback: on fetch failure, trust the state file's stored
    # DesiredStateId directly (does NOT recompute from cached inputs,
    # which would need the OEM map on the same unavailable network).
    # Local safety checks in the fast path still enforced.
    $manifest = $null
    for ($retry = 1; $retry -le 2; $retry++) {
        try { $manifest = Invoke-RestMethod -Uri $DriverManifestUrl -Headers $GitHubHeaders -UseBasicParsing -TimeoutSec $NetworkTimeoutSeconds -ErrorAction Stop; break }
        catch {
            Write-Log "Driver manifest fetch attempt $retry failed: $($_.Exception.Message)" -Level WARN
        }
        if ($retry -lt 2) { Start-Sleep 2 }
    }

    if ($manifest -and $manifest.version) {
        $ExpectedDriverSetVersion = $manifest.version
    } else {
        if ($manifest) {
            Write-Log "Driver manifest fetched but has no version field - treating as unavailable" -Level WARN
        }
        $manifestStateFilePath = "$env:SystemDrive\Recovery\OEM\$StateFileName"
        if (-not (Test-Path $manifestStateFilePath)) {
            Write-Log "Driver manifest unavailable and no state file exists - a live manifest is required for the first deployment on this machine." -Level ERROR
            throw "Driver manifest unavailable and no state file exists. First deployment requires a live manifest."
        }
        try {
            $cachedManifestState = Get-Content $manifestStateFilePath -Raw | ConvertFrom-Json
        } catch {
            Write-Log "Driver manifest unavailable and the state file could not be parsed: $_" -Level ERROR
            throw "Driver manifest unavailable and state file unparseable."
        }
        if (-not $cachedManifestState.DesiredStateId) {
            Write-Log "Driver manifest unavailable and the state file does not record a DesiredStateId." -Level ERROR
            throw "Driver manifest unavailable and state file lacks the required fields."
        }
        $ExpectedDriverSetVersion = $cachedManifestState.InjectedDriverSetVersion
        $DesiredStateId           = $cachedManifestState.DesiredStateId
        $Script:offlineFallback   = $true
        $Script:nonFatalWarning   = $true
        $stateFileAge = if ($cachedManifestState.LastUpdated) { "state file LastUpdated=$($cachedManifestState.LastUpdated)" } else { "state file LastUpdated=unknown" }
        Write-Log "Driver manifest unavailable - taking the offline fallback path using the state file's stored DesiredStateId ($stateFileAge). The run will exit EXIT_WARNING. The machine will update automatically on the next successful manifest fetch if any deployment input has changed in the meantime." -Level WARN
    }

    $OEMPackage = $null
    if (-not $Script:offlineFallback) {
        $OEMPackage = Get-OEMWinPEPack -Hardware $Hardware
    } else {
        Write-Log "Offline fallback: skipping OEM pack resolution (network unavailable)" -Level INFO
    }

    # ---- OEM pack null-result classification (v44 patch 6) ----
    # For LENOVO, the resolution status distinguishes a legitimate no-pack
    # (unknown-mt / no-entry) from transient or configuration failures.
    # For Dell and HP, a null return is always transient.
    $oemVendorSupported = $Hardware.Manufacturer -in @("Dell", "HP", "LENOVO")
    if (-not $Script:offlineFallback -and $oemVendorSupported -and -not $OEMPackage) {
        if ($Hardware.Manufacturer -eq "LENOVO") {
            switch ($Script:LenovoPackResolution) {
                "unknown-mt" {
                    Write-Log "LENOVO machine type could not be resolved (MT=UNKN) - no pack can ever match. The run is recorded as complete with OEMPACK=NONE." -Level INFO
                }
                "no-entry" {
                    Write-Log "LENOVO machine type $($Hardware.MachineType) has no published WinPE driver pack in the loaded map - OEM driver injection will be skipped. If Lenovo publishes a pack for this model later, the DesiredStateId will change and the machine will rebuild." -Level INFO
                }
                "malformed-entry" {
                    Write-Log "LENOVO map entry for machine type $($Hardware.MachineType) is present but malformed (no winpe.url) - configuration failure, not a legitimate no-pack. OEM driver injection will be skipped and the run will be marked incomplete." -Level WARN
                    $Script:nonFatalWarning = $true
                    $Script:ImageInjectionComplete = $false
                }
                "map-unavailable" {
                    Write-Log "LENOVO WinPE map could not be downloaded - transient failure. OEM driver injection will be skipped and the run will be marked incomplete." -Level WARN
                    $Script:nonFatalWarning = $true
                    $Script:ImageInjectionComplete = $false
                }
                default {
                    Write-Log "LENOVO OEM pack resolution ended unexpectedly (state=$($Script:LenovoPackResolution)) - marking run incomplete." -Level WARN
                    $Script:nonFatalWarning = $true
                    $Script:ImageInjectionComplete = $false
                }
            }
        } else {
            Write-Log "$($Hardware.Manufacturer) is a supported vendor but no OEM WinPE pack could be resolved (map fetch failed or no matching entry) - OEM driver injection will be skipped" -Level WARN
            $Script:nonFatalWarning = $true
            $Script:ImageInjectionComplete = $false
        }
    }

    # ---- VMD detection (v44 patch 6, fail-closed) ----
    # VMD presence is a deployment input. A query failure is not the
    # same as "no VMD hardware": only a successful enumeration that
    # yields no matches proves absence. Any error during enumeration is
    # treated as indeterminate, and the run defers before committing
    # state.
    $vmdPresent   = $false
    $vmdQueryOk   = $true
    if (-not $Script:offlineFallback) {
        $vmdIds = $manifest.drivers | Where-Object { $_.match.requiredDevices } | ForEach-Object { $_.match.requiredDevices }
        if ($vmdIds) {
            $pattern = ($vmdIds | ForEach-Object { [regex]::Escape($_) }) -join '|'
            $vmdErr = $null
            $vmdDevices = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue -ErrorVariable vmdErr |
                            Where-Object { $_.InstanceId -match $pattern })
            if ($vmdErr -and @($vmdErr).Count -gt 0) {
                $vmdQueryOk = $false
                Write-Log "VMD hardware detection reported $(@($vmdErr).Count) error(s) during PnP enumeration: $($vmdErr[0]) - treating VMD presence as indeterminate." -Level WARN
            } else {
                $vmdPresent = $vmdDevices.Count -gt 0
                Write-Log "VMD hardware present: $vmdPresent ($($vmdDevices.Count) matching device(s) out of $(@($vmdIds).Count) pattern(s))"
            }
        } else {
            Write-Log "VMD hardware present: False (manifest has no requiredDevices patterns)"
        }
    } else {
        Write-Log "Offline fallback: skipping VMD detection (manifest unavailable)" -Level INFO
    }

    # Fail-closed guard: a full update or a fast path cannot be trusted
    # when VMD presence is unknown. Defer rather than commit state.
    if (-not $Script:DryRun -and -not $vmdQueryOk) {
        Write-Log "VMD hardware detection was indeterminate; deferring because the driver set cannot be safely determined. Re-run when PnP enumeration is healthy." -Level WARN
        $Script:nonFatalWarning = $true
        Remove-ItemIfExist $CheckpointFile
        exit $EXIT_WARNING
    }

    # ---- Required VMD driver set ----
    # Deterministic for a given (manifest, hardware, vmdPresent) triple.
    # Not separately hashed into DesiredStateId - the manifest version
    # identifies the driver set, and the deployed artifact is tracked
    # via CurrentImageHash.
    $requiredDrivers = @()
    if (-not $Script:offlineFallback) {
        foreach ($drv in $manifest.drivers) {
            $osMatch = ($Hardware.IsWin10 -and $drv.os -contains "Win10") -or ($Hardware.IsWin11 -and $drv.os -contains "Win11")
            $genOk = ($Hardware.CPUGeneration -ge $drv.match.cpuGenMin) -and ($Hardware.CPUGeneration -le $drv.match.cpuGenMax)
            if ($drv.match.requiredDevices -and -not $vmdPresent) { Write-Log "Skipping $($drv.name): no matching VMD hardware detected"; continue }
            if ($osMatch -and $Hardware.CPUVendor -eq "Intel" -and $genOk) { $requiredDrivers += $drv }
        }
        Write-Log "Required drivers (VMD): $($requiredDrivers.Count)"
    } else {
        Write-Log "Offline fallback: skipping required-driver resolution" -Level INFO
    }

    if (-not $Script:offlineFallback) {
        $DesiredStateId = Get-DesiredStateId -Hardware $Hardware -OEMPackage $OEMPackage -ExpectedDriverSetVersion $ExpectedDriverSetVersion -VMDPresent $vmdPresent
        Write-Log "DesiredStateId: $DesiredStateId"
    } else {
        Write-Log "Offline fallback: using state file's stored DesiredStateId $DesiredStateId"
    }

    # ---- Recovery-volume drive-letter normalization ----
    Get-Volume | Where-Object { $_.FileSystemLabel -eq "Recovery" -or $_.FileSystemLabel -eq "WINRE" } | ForEach-Object {
        if ($_.DriveLetter) {
            $part = Get-Partition -Volume $_ -ErrorAction SilentlyContinue
            if ($part -and -not $part.IsBoot -and -not $part.IsSystem -and -not (Test-Path "$($_.DriveLetter):\Windows")) {
                if (-not $Script:DryRun) {
                    if (-not $Script:tempDriveLetters.Contains($_.DriveLetter)) { $Script:tempDriveLetters.Add($_.DriveLetter) }
                    Invoke-DriveLetterRemoval -Letter $_.DriveLetter | Out-Null
                } else {
                    Write-Log "[DRY RUN] Would remove drive letter $($_.DriveLetter): from recovery volume '$($_.FileSystemLabel)'"
                }
            }
        }
    }

    $WinREState = Get-WinREState
    Write-Log "WinRE status: $($WinREState.Status), Location: $($WinREState.Location), Version: $(if ($WinREState.Version) { $WinREState.Version } else { 'unknown' })"

    $state = Read-WinREState -CurrentDesiredStateId $DesiredStateId
    $storedHash = $state.CurrentImageHash
    $storedDriverVersion = $state.InjectedDriverSetVersion
    # v47: carry the last-deployed WinRE metadata in script scope so every
    # Write-WinREState call preserves it by default. Only the full-update
    # deployment path overrides this with the metadata of the WIM it just
    # deployed.
    $Script:DeployedWinREMetadata = $state.DeployedWinREMetadata
    # v47: LKG-validation hash. The operational read above refuses to
    # accept a stale state file, which correctly nulls $storedHash on the
    # first v47 run on a v46 machine. The file's CurrentImageHash is still
    # the hash of the last successfully deployed WIM, so read it in
    # isolation to restore LKG validation across the version boundary. The
    # fallback is used only at LKG-validation call sites and does not make
    # the stale state operationally authoritative.
    $lkgStoredHash = $storedHash
    if (-not $lkgStoredHash) {
        $lkgStoredHash = Get-StaleWinREStateImageHash
        if ($lkgStoredHash) {
            Write-Log "LKG validation: using historical CurrentImageHash from stale state file ($lkgStoredHash) for the v46 -> v47 migration"
        }
    }

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
                    # OS-fallback: target IS C:. Defer unless confirmed
                    # FullyDecrypted. Never modify C:'s state.
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
    $ActiveLocationWimPresent = $false

    if ($WinREState.Location) {
        $tempLocation = @(Ensure-RecoveryPartitionAccess -TargetDir $WinREState.Location)[0]
        if ($tempLocation) {
            # Probe both forms: the resolver returns a drive root when the
            # registered location was a raw partition path, and returns the
            # subpath directly when the registered location already
            # included Recovery\WindowsRE. Only one candidate resolves to a
            # real file on a given machine.
            foreach ($cand in @(Join-Path $tempLocation "Recovery\WindowsRE\winre.wim"; Join-Path $tempLocation "winre.wim")) {
                if (Test-Path -Path $cand -PathType Leaf -ErrorAction SilentlyContinue) {
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
            Write-Log "Source WIM build: $wimBuild (path: $imageToCheck)"
            if ($Hardware.IsWin10 -and $wimBuild -ge 22000) { $forceUpgrade = $true }
            elseif ($Hardware.IsWin11 -and $wimBuild -lt 22000) { $forceUpgrade = $true }
        } else {
            Write-Log "Source WIM build: unknown (path: $imageToCheck)" -Level WARN
        }
    }

    # ---- needInject determination ----
    # v47: drift detection is metadata-based, not WIM-hash-based. A WIM
    # recompression by an external tool changes bytes without changing the
    # semantic desired state, so the WIM hash is not a rebuild trigger.
    # Metadata (DISM Version and SPBuild) is a cheap and useful signal:
    # Microsoft documents that an LCU bumps SPBuild while the base Version
    # may remain unchanged, so both are compared. The tradeoff is that a
    # Dynamic Update package may not change either field, so equal metadata
    # does not prove byte-for-byte equality; that is accepted here. The
    # WIM hash remains in use for copy verification, deployment
    # verification, and the pre-/disable race detector, not as a rebuild
    # trigger.
    $needInject = $false
    $registeredSourceChanged = $false
    $registeredMetaString = $null
    $registeredMetadataUnreadable = $false
    if ($ActiveLocationWimPresent -and $ActiveLocationImage) {
        $regMetaNow = Get-WimServicingMetadata -WimPath $ActiveLocationImage
        if ($regMetaNow) {
            $registeredMetaString = "$($regMetaNow.Version)|$($regMetaNow.SPBuild)"
        } else {
            # v47: registered WIM present but metadata unreadable. This is
            # the same condition Patch 2C treats as "registered not
            # usable" for source selection. Force a rebuild so the repair
            # path replaces it. Without this, a valid-looking state could
            # let the script take the fast path over an unreadable
            # registered image.
            $registeredMetadataUnreadable = $true
        }
    }
    if ($registeredMetaString -and $state.DeployedWinREMetadata) {
        $registeredSourceChanged = ($registeredMetaString -ne $state.DeployedWinREMetadata)
    }
    if ($registeredMetaString) {
        Write-Log "Registered WinRE metadata: $registeredMetaString; last deployed: $(if ($state.DeployedWinREMetadata) { $state.DeployedWinREMetadata } else { '(none)' })"
    }
    # v47: byte-drift evidence. The metadata comparison above is the drift
    # *gate*; this is its observability counterpart. A hash difference
    # between the currently-registered image and the last successfully
    # deployed WIM is field evidence of a source change that the metadata
    # comparison may not have caught -- Microsoft documents that a
    # Dynamic Update may change a serviced WinRE's contents without
    # bumping Version or SPBuild. Logged for evidence only; the
    # byte-drift signal does not enter any gate and does not become a
    # rebuild trigger.
    if ($ActiveLocationWimPresent -and $ActiveLocationHash -and $lkgStoredHash) {
        $byteDrift = ($ActiveLocationHash -ne $lkgStoredHash)
        Write-Log "Registered WinRE SHA256: $ActiveLocationHash"
        Write-Log "Last deployed WinRE SHA256: $lkgStoredHash"
        Write-Log "Byte drift from last deployment: $(if ($byteDrift) { 'YES' } else { 'NO' })"
    }

    if ($forceUpgrade) { $needInject = $true; Write-Log "OS upgrade detected - forcing WIM rebuild" }
    elseif ($registeredMetadataUnreadable) { $needInject = $true; Write-Log "Registered WinRE metadata could not be read - forcing rebuild so the repair path can replace the image" }
    elseif ($registeredSourceChanged) { $needInject = $true; Write-Log "Registered WinRE metadata changed from $($state.DeployedWinREMetadata) to $registeredMetaString - rebuilding" }
    elseif ($storedHash -and $storedDriverVersion -and -not $state.DeployedWinREMetadata) { $needInject = $true; Write-Log "State has no DeployedWinREMetadata anchor (previous deployment could not record it) - rebuilding" }
    elseif ($storedDriverVersion -and $storedDriverVersion -ne $ExpectedDriverSetVersion) { $needInject = $true; Write-Log "Driver version changed - rebuilding" }
    elseif (-not $storedHash -or -not $storedDriverVersion) { $needInject = $true; Write-Log "No valid state (missing or stale) - rebuilding" }

    if (-not $needInject -and -not $ActiveLocationImage -and -not $FallbackImage) {
        Write-Log "No active or fallback WinRE image found - forcing rebuild" -Level WARN
        $needInject = $true
    }

    if ($registeredSourceChanged) {
        Write-Log "Invalidating any staged WIM checkpoint because the currently registered source image metadata changed" -Level WARN
        Remove-ItemIfExist $CheckpointFile
    }

    # ---- Recovery-partition classification ----
    $osDisk = Get-OSDisk
    $existingRecoveryParts = @(
        if ($osDisk) {
            Get-RecoveryPartitions -DiskNumber $osDisk.Number |
                Where-Object {
                    ($_.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}') -or
                    ($_.MbrType -eq 0x27)
                }
        }
    )

    $activePart = $null
    if ($WinREState.Location) {
        $activePart = Resolve-WinRELocationToPartition -Location $WinREState.Location
    }

    $activeOnRecovery = $false
    $activeOnOSFallback = $false

    if ($activePart) {
        $isTypedRecovery = ($activePart.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}') -or
                           ($activePart.MbrType -eq 0x27)
        $isLabelRecovery = $false

        if (-not $isTypedRecovery) {
            $vol = Get-Volume -Partition $activePart -ErrorAction SilentlyContinue
            $isLabelRecovery = ($vol -and
                                ($vol.FileSystemLabel -eq 'Recovery' -or
                                 $vol.FileSystemLabel -eq 'WINRE'))
        }

        $osPartCheck = Get-OSPartition
        $isActiveOSPart = ($osPartCheck -and
                           $activePart.DiskNumber -eq $osPartCheck.DiskNumber -and
                           $activePart.PartitionNumber -eq $osPartCheck.PartitionNumber)
        # Require active partition to be on OS disk: otherwise a machine
        # registered to a secondary-disk recovery partition would take
        # the fast path and then lose it to Remove-StrayRecoveryPartitions.
        $isActiveOSDisk = ($osPartCheck -and
                           $activePart.DiskNumber -eq $osPartCheck.DiskNumber)

        if ($isActiveOSPart) {
            $activeOnOSFallback = $true
        } elseif ($isTypedRecovery -and $isActiveOSDisk) {
            $activeOnRecovery = $true
        } elseif ($isLabelRecovery -and $isActiveOSDisk) {
            Write-Log "Active WinRE location is label-matched but not type-coded on the OS disk (disk $($activePart.DiskNumber), partition $($activePart.PartitionNumber)) - it will not qualify as a dedicated recovery partition; scheduling migration to a type-coded target." -Level WARN
        }
    }

    if ($activeOnRecovery -and -not $ActiveLocationWimPresent -and $WinREState.Status -eq "Enabled") {
        if ($Script:DryRun -and $WinREState.Location -match '^\\\\\?\\GLOBALROOT') {
            Write-Log "[DRY RUN] Cannot verify winre.wim at the reagentc-registered GLOBALROOT location without a drive letter (which DryRun does not assign). A live run would Test-Path the WIM and force a rebuild only if it is missing or unreadable." -Level INFO
        } else {
            Write-Log "WinRE is registered on recovery partition $($activePart.DiskNumber)/$($activePart.PartitionNumber) but its winre.wim could not be read at that location - forcing rebuild" -Level WARN
            $needInject = $true
        }
    }
    # v47: mirror of the guard above for the OS-fallback route. The
    # registered location there is C:\Recovery\WindowsRE, and the fast
    # path's OS-fallback branch accepts the machine on the classifier
    # verdict alone; it does not re-check that the WIM at that location
    # is readable. Without this guard, a machine whose registered
    # OS-fallback winre.wim has gone missing could take the fast path on
    # the strength of a WIM discovered by the loose fallback path
    # ($FallbackImage), which is not the registered source. Force a
    # rebuild so the repair path replaces the registered image.
    elseif ($activeOnOSFallback -and -not $ActiveLocationWimPresent -and $WinREState.Status -eq "Enabled") {
        Write-Log "WinRE is registered via OS-fallback (location: $($WinREState.Location)) but its winre.wim could not be read at that location - forcing rebuild" -Level WARN
        $needInject = $true
    }

    $partitionDeferral = Read-PartitionDeferral -CurrentDesiredStateId $DesiredStateId
    if ($partitionDeferral) {
        $deferredRouteFunctional = Test-DeferredWinRERouteFunctional -WinREState $WinREState `
                                     -ActiveLocationWimPresent $ActiveLocationWimPresent `
                                     -ActiveOnRecovery $activeOnRecovery -ActiveOnOSFallback $activeOnOSFallback
        $stagedCheckpoint = Get-Checkpoint -CheckpointFile $CheckpointFile -CurrentDesiredStateId $DesiredStateId
        $stagedWimReady = $false
        if (-not $registeredSourceChanged -and $stagedCheckpoint.Valid -and $stagedCheckpoint.WimReady -and $stagedCheckpoint.WorkDir) {
            $stagedWorkspace = @(Get-WorkDirCandidates | Where-Object {
                [System.StringComparer]::OrdinalIgnoreCase.Equals($_.Path.TrimEnd('\'), ([string]$stagedCheckpoint.WorkDir).TrimEnd('\'))
            } | Select-Object -First 1)
            $stagedWimReady = ($stagedWorkspace.Count -gt 0 -and
                               (Test-Path -LiteralPath (Join-Path $stagedWorkspace[0].Path 'winre_optimized.wim') -PathType Leaf))
        }
        # The deferral marker's only job is to suppress a rebuild that the
        # read-only geometry plan already knows will fail at the pre-shrink.
        # Compute here whether the run would instead exit cleanly via the
        # idempotent fast path (both stages of $needInject evaluation are
        # reflected: stage 1 already set $needInject above; stage 2 would
        # fire inside the fast path for count != 1 or active-location
        # mismatches). If the fast path would fire, the marker is obsolete:
        # clear it and fall through so the run exits EXIT_SUCCESS rather
        # than being pinned at EXIT_WARNING.
        $fastPathWillFire = (-not $needInject) -and
                            ($WinREState.Status -eq "Enabled") -and
                            (
                                ($existingRecoveryParts.Count -eq 1 -and ($activeOnRecovery -or $activeOnOSFallback)) -or
                                ($existingRecoveryParts.Count -eq 0 -and $state.UsedOSFallback -eq $true -and $activeOnOSFallback)
                            )
        if ($deferredRouteFunctional -and -not $fastPathWillFire) {
            $since = if ($partitionDeferral.Since) { $partitionDeferral.Since } else { "unknown" }
            $stagedNote = if ($stagedWimReady) { 'staged optimized WIM is available for immediate reuse' } else { 'no staged optimized WIM is present; the next successful run will re-service the image' }
            Write-Log "Dedicated recovery creation was deferred for this DesiredStateId on $since. Existing WinRE route is Enabled and its registered WIM is readable; not repeating the same pre-shrink retries ($stagedNote). After resolving space/layout, delete $env:SystemDrive\Recovery\OEM\$StateFileName and $env:SystemDrive\Recovery\OEM\$PartitionDeferralFileName to retry." -Level WARN
            $Script:UsedOSFallback = $activeOnOSFallback
            $Script:nonFatalWarning = $true
            # Intentionally preserve the staged workspace and checkpoint:
            # the deferred route is still functional, the operator has not
            # yet resolved the underlying issue, and the staged WIM stays
            # available for the eventual successful run. The marker alone
            # suppresses identical retries.
            exit $EXIT_WARNING
        }
        if ($fastPathWillFire) {
            # The machine is now in a state the fast path would accept
            # cleanly. The marker's only purpose was to suppress a
            # failing rebuild; with no rebuild required, it is obsolete.
            # Clear it and fall through so the run can exit EXIT_SUCCESS
            # rather than being pinned at EXIT_WARNING.
            Write-Log "Partition deferral marker present for this DesiredStateId, but the machine is already in a healthy end state; clearing the marker and falling through to the fast path" -Level INFO
            Clear-PartitionDeferral
        } else {
            $ignoreReason = 'the existing WinRE route is no longer proven functional'
            Write-Log "Partition deferral marker ignored because $ignoreReason; normal repair evaluation will continue" -Level WARN
            Clear-PartitionDeferral
        }
    }

    # ---- Idempotent fast path ----
    # v44 patch 6: when accepting a stored OS-fallback state on the fast
    # path, re-verify C: is still confirmed FullyDecrypted. The machine
    # remains functional either way, but a state that has drifted is
    # surfaced as EXIT_WARNING so an operator sees it.
    $nothingToDo = $false
    if (-not $needInject -and $WinREState.Status -eq "Enabled") {
        if ($existingRecoveryParts.Count -ne 1) {
            if ($existingRecoveryParts.Count -eq 0 -and $state.UsedOSFallback -eq $true -and $activeOnOSFallback) {
                Write-Log "No recovery partition and state records OS-fallback for this DesiredStateId - preserving idempotent OS-fallback"
                $Script:UsedOSFallback = $true
                $osFbEncCheck = Test-VolumeEncrypted -MountPoint "C:"
                if ($osFbEncCheck -ne $false) {
                    Write-Log "OS-fallback fast path: C: is no longer confirmed fully decrypted (Test-VolumeEncrypted=$osFbEncCheck). The existing WinRE registration on C: remains functional, but the machine cannot be repaired by this script while C: is encrypted. Surfacing EXIT_WARNING." -Level WARN
                    $Script:nonFatalWarning = $true
                }
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
                $driveLetterVerb = if ($Script:DryRun) { "Would remove" } else { "Removing" }
                Write-Log "$driveLetterVerb temporary drive letter $($activePart.DriveLetter): (assigned for inspection)"
                if (-not $Script:tempDriveLetters.Contains($activePart.DriveLetter)) { $Script:tempDriveLetters.Add($activePart.DriveLetter) }
                if (-not $Script:DryRun) { Invoke-DriveLetterRemoval -Letter $activePart.DriveLetter | Out-Null }
                $nothingToDo = $true
            }
        } elseif ($activeOnOSFallback) {
            Write-Log "WinRE is enabled via OS-fallback (location: $($WinREState.Location))"
            $Script:UsedOSFallback = $true
            $osFbEncCheck = Test-VolumeEncrypted -MountPoint "C:"
            if ($osFbEncCheck -ne $false) {
                Write-Log "OS-fallback fast path: C: is no longer confirmed fully decrypted (Test-VolumeEncrypted=$osFbEncCheck). The existing WinRE registration on C: remains functional, but the machine cannot be repaired by this script while C: is encrypted. Surfacing EXIT_WARNING." -Level WARN
                $Script:nonFatalWarning = $true
            }
            $nothingToDo = $true
        }
    }

    if ($nothingToDo) {
        if ($Script:UsedOSFallback) {
            Write-Log "Operating mode: OS-FALLBACK (degraded - WinRE is on the OS partition)"
        } else {
            Write-Log "Operating mode: DEDICATED (WinRE on dedicated recovery partition)"
        }
        Remove-ItemIfExist $CheckpointFile

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
    # Image current, WinRE disabled, reagentc registered on a recovery
    # partition. Prepare the target and enable.
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
                $enableWarningReason = if ($Script:offlineFallback) { "offline fallback was engaged" }
                                       elseif ($Script:UsedOSFallback) { "OS-fallback deployment" }
                                       else { "one or more non-fatal warnings were logged above" }
                Write-Log "Enable succeeded; exiting EXIT_WARNING because $enableWarningReason"
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

    # ============ OFFLINE GUARD ============
    if ($Script:offlineFallback) {
        Write-Log "Offline fallback: the machine requires a full update (state file is stale or unhealthy), but the driver manifest is unavailable. Cannot proceed without a live manifest. Will retry on the next scheduled run when the network is available." -Level WARN
        Remove-ItemIfExist $CheckpointFile
        exit $EXIT_WARNING
    }

    # Initialize scratch only after all no-op and enable-only paths exit.
    $cp = Get-Checkpoint -CheckpointFile $CheckpointFile -CurrentDesiredStateId $DesiredStateId

    # v47: a WIM_READY checkpoint is bound to the source-content hash that
    # produced the staged WIM. The metadata comparison in the drift
    # detector cannot detect a metadata-neutral source change (Microsoft
    # documents that a Dynamic Update may not bump Version or SPBuild).
    # The staged WIM must be invalidated if the source it was prepared
    # from is no longer present with the same bytes. Legacy checkpoints
    # without a source hash are also invalidated.
    if ($cp.Valid -and $cp.Step -ge 4 -and $cp.WimReady) {
        $storedSourceHash = $cp.SourceHash
        if (-not $storedSourceHash) {
            Write-Log "Checkpoint WIM_READY has no recorded source identity (legacy or GitHub-sourced checkpoint); invalidating to rebuild from a known source" -Level WARN
            Remove-ItemIfExist $CheckpointFile
            $cp = Get-Checkpoint -CheckpointFile $CheckpointFile -CurrentDesiredStateId $DesiredStateId
        } else {
            $candidateHashes = @()
            if ($ActiveLocationHash) { $candidateHashes += $ActiveLocationHash }
            $lkgForCheck = Get-LKGWinREImagePath -StoredHash $lkgStoredHash
            if ($lkgForCheck) { $candidateHashes += $lkgForCheck.Hash }
            if ($candidateHashes -notcontains $storedSourceHash) {
                Write-Log "Checkpoint WIM_READY source identity $storedSourceHash no longer matches any available source (registered=$(if ($ActiveLocationHash) { $ActiveLocationHash } else { 'none' }), lkg=$(if ($lkgForCheck) { $lkgForCheck.Hash } else { 'none' })); invalidating to rebuild from the current source" -Level WARN
                Remove-ItemIfExist $CheckpointFile
                $cp = Get-Checkpoint -CheckpointFile $CheckpointFile -CurrentDesiredStateId $DesiredStateId
            } else {
                Write-Log "Checkpoint WIM_READY source identity $storedSourceHash matches an available source"
            }
        }
    }

    $step = $cp.Step
    $workDirCandidates = @(Get-WorkDirCandidates)
    $checkpointPath = if ($cp.WorkDir) { [string]$cp.WorkDir } else { $DefaultWorkDir }
    $checkpointCandidate = $workDirCandidates | Where-Object {
        [System.StringComparer]::OrdinalIgnoreCase.Equals($_.Path.TrimEnd('\'), $checkpointPath.TrimEnd('\'))
    } | Select-Object -First 1

    # With no valid checkpoint, files in every canonical script-owned
    # workspace are disposable; remove stale data before measuring space.
    if (-not $cp.Valid -or $cp.Step -eq 0) {
        foreach ($candidate in $workDirCandidates) {
            if (-not (Test-Path -LiteralPath $candidate.Path -PathType Container)) { continue }
            Write-Log "Removing uncheckpointed or stale workspace before capacity planning: $($candidate.Path)"
            Remove-ItemIfExist $candidate.Path -Recurse
        }
        $workDirCandidates = @(Get-WorkDirCandidates)
        $checkpointCandidate = $workDirCandidates | Where-Object {
            [System.StringComparer]::OrdinalIgnoreCase.Equals($_.Path.TrimEnd('\'), $checkpointPath.TrimEnd('\'))
        } | Select-Object -First 1
    }

    $preferredWorkDir = if ($cp.WorkDir) { [string]$cp.WorkDir } elseif ($cp.Step -gt 0) { $DefaultWorkDir } else { $null }
    $resumeWimReady = ($cp.Valid -and $cp.Step -ge 4 -and $cp.WimReady -and $checkpointCandidate -and
                       (Test-Path -LiteralPath (Join-Path $checkpointCandidate.Path 'winre_optimized.wim') -PathType Leaf))
    $minimumWorkDirBytes = if ($resumeWimReady) {
        [int64]($WorkDirResumeMinFreeMB * 1MB)
    } else {
        [int64]($MinFreeSpaceGB * 1GB)
    }
    $minimumWorkDirDisplay = if ($resumeWimReady) { "$WorkDirResumeMinFreeMB MiB" } else { "$MinFreeSpaceGB GiB" }
    $workDirPlan = Get-WorkDirPlan -PreferredPath $preferredWorkDir -MinimumFreeBytes $minimumWorkDirBytes
    if (-not $workDirPlan.Path) {
        $candidateSummary = if ($workDirPlan.Candidates.Count -gt 0) {
            ($workDirPlan.Candidates | ForEach-Object { "$($_.DriveLetter): $([math]::Round($_.FreeBytes/1GB,2)) GiB free" }) -join '; '
        } else { "no eligible fixed NTFS volumes found" }
        Write-Log "Full update deferred: no eligible fixed NTFS workspace has at least $minimumWorkDirDisplay free. $candidateSummary. Free space on an eligible volume and re-run; no partition changes were made." -Level WARN
        Remove-ItemIfExist $CheckpointFile
        $Script:nonFatalWarning = $true
        exit $EXIT_WARNING
    }

    $WorkDir = $workDirPlan.Path
    $checkpointMatchesSelection = [System.StringComparer]::OrdinalIgnoreCase.Equals($checkpointPath.TrimEnd('\'), $WorkDir.TrimEnd('\'))
    if (-not $cp.Valid -or ($cp.Step -gt 0 -and -not $checkpointMatchesSelection)) {
        if ($cp.Step -gt 0 -and -not $checkpointMatchesSelection) {
            Write-Log "Checkpoint workspace '$checkpointPath' is unavailable or below the free-space requirement; restarting from step 1 in $WorkDir" -Level WARN
            if ($checkpointCandidate -and (Test-Path -LiteralPath $checkpointCandidate.Path -PathType Container)) {
                Remove-ItemIfExist $checkpointCandidate.Path -Recurse
            }
        } elseif (-not $cp.Valid) {
            Write-Log "Checkpoint invalidated - restarting from step 1 in $WorkDir" -Level WARN
        }
        $step = 0
        if (Test-Path -LiteralPath $WorkDir -PathType Container) { Remove-ItemIfExist $WorkDir -Recurse }
    }

    Write-Log "Workspace selected: $WorkDir ($([math]::Round($workDirPlan.Candidate.FreeBytes/1GB,2)) GiB free; minimum $minimumWorkDirDisplay)"
    Write-Log "Checkpoint step: $step"
    New-DirectoryIfNotExists $WorkDir
    New-DirectoryIfNotExists "$WorkDir\scratch"
    $Script:OriginalTempPath = $env:TEMP
    $Script:OriginalTmpPath = $env:TMP
    if (-not $Script:DryRun) {
        $env:TEMP = "$WorkDir\scratch"
        $env:TMP = "$WorkDir\scratch"
        $Script:TempEnvironmentChanged = $true
    }
    if ($step -ge 4 -and -not (Test-Path "$WorkDir\winre_optimized.wim")) {
        $step = if (Test-Path "$WorkDir\base.wim") { 3 } else { 1 }
    } elseif ($step -ge 2 -and $step -lt 4 -and -not (Test-Path "$WorkDir\base.wim")) {
        $step = 1
    }

    # Migration guard: a step>=4 checkpoint alongside a required rebuild
    # cannot be trusted (a prior failed-injection run may have advanced
    # the checkpoint without committing new state).
    if ($step -ge 4 -and $needInject) {
        if ($cp.WimReady -and (Test-Path "$WorkDir\winre_optimized.wim")) {
            Write-Log "Checkpoint step $step confirms a completed image export; resuming with the optimized WIM"
        } else {
            Write-Log "Checkpoint step $step lacks the current WIM_READY marker while a rebuild is required - resetting to step 2 to retry injection" -Level WARN
            $step = 2
        }
    }

    # ============ FULL UPDATE PATH ============
    Write-Log "Starting full update"

    # v47: capture the registered-source fingerprint immediately before
    # source acquisition. The recheck helper compares this against a
    # fresh reading immediately before whichever /disable site this
    # execution reaches first. DryRun does not capture (no /disable
    # site is reached and the SHA256 cost is not justified).
    $Script:RegisteredSourceFingerprint = $null
    if (-not $Script:DryRun) {
        # Only pass the registered WIM path/hash when the registered
        # location actually produced a readable WIM. $ActiveLocationImage
        # can be populated by fallback discovery while
        # $ActiveLocationWimPresent is $false; passing it in that case
        # would fingerprint the fallback as if it were the registered
        # source.
        $regWimPathForFingerprint = if ($ActiveLocationWimPresent) { $ActiveLocationImage } else { $null }
        $regWimHashForFingerprint = if ($ActiveLocationWimPresent) { $ActiveLocationHash } else { $null }
        $Script:RegisteredSourceFingerprint = Get-RegisteredWinREFingerprint `
            -WinREState $WinREState `
            -RegisteredWimPath $regWimPathForFingerprint `
            -RegisteredWimHash $regWimHashForFingerprint
        switch ($Script:RegisteredSourceFingerprint.Status) {
            'captured' {
                Write-Log "Captured registered-source fingerprint: location=$($Script:RegisteredSourceFingerprint.Location), version=$($Script:RegisteredSourceFingerprint.Version), hash=$($Script:RegisteredSourceFingerprint.Hash)"
            }
            'unreadable' {
                Write-Log "Registered-source fingerprint unavailable: WinRE is Enabled at $($Script:RegisteredSourceFingerprint.Location) but its WIM could not be read. The pre-/disable race-detector recheck will defer." -Level WARN
            }
            default {
                Write-Log "No registered source to fingerprint (WinRE status=$($WinREState.Status))"
            }
        }
    }

    if ($Script:DryRun) {
        Write-Log "[DRY RUN] Full update plan (checkpoint step $step):"

        if ($step -le 1) {
            Write-Log "[DRY RUN]   Step 1: Clean WorkDir\mount and WorkDir\base.wim"
        }
        if ($step -le 2 -and $needInject) {
            if ($ActiveLocationImage -or $FallbackImage) {
                Write-Log "[DRY RUN]   Step 2: Select base WIM source (registered vs hash-validated LKG by Version/SPBuild/SPLevel; GitHub cold-start if neither usable) and copy to WorkDir\base.wim"
                Write-Log "[DRY RUN]     Registered candidate: $(if ($ActiveLocationImage) { $ActiveLocationImage } else { '(unavailable)' })"
                Write-Log "[DRY RUN]     LKG candidate: $env:SystemDrive\Recovery\WindowsRE\winre.wim (used only when SHA256 matches state.CurrentImageHash)"
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
        if ($step -lt 4 -and $needInject) {
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
                if (-not (Get-GitHubBaseWinRE -WorkDir $WorkDir -Hardware $Hardware)) {
                    Write-Log "GitHub base WIM retrieval failed" -Level FATAL
                    exit $EXIT_FATAL
                }
            } else {
                # v47: source selection. The registered image is usable
                # only when its servicing metadata can be read. The LKG
                # is usable only when its SHA256 matches
                # state.CurrentImageHash. If neither is usable, fall
                # through to the GitHub cold-start baseline; the loose
                # $FallbackImage discovery is not a designed source and
                # is not used here.
                $lkgResult = Get-LKGWinREImagePath -StoredHash $lkgStoredHash
                $lkgPath   = if ($lkgResult) { $lkgResult.Path } else { $null }
                # v47: only treat the candidate as "registered" when discovery
                # found a readable WIM at the registered location.
                # $ActiveLocationImage can be populated by fallback discovery
                # when the registered location did not produce a WIM; in that
                # case $ActiveLocationWimPresent is $false and the fallback is
                # not a designed source. Source-selection chain is
                # registered -> LKG -> GitHub. Gate accordingly.
                $regMeta   = if ($ActiveLocationWimPresent -and $ActiveLocationImage) { Get-WimServicingMetadata -WimPath $ActiveLocationImage } else { $null }
                $regUsable = [bool]($ActiveLocationWimPresent -and $ActiveLocationImage -and $regMeta)
                $lkgUsable = [bool]$lkgResult

                if (-not $regUsable -and $ActiveLocationWimPresent -and $ActiveLocationImage) {
                    Write-Log "Registered WinRE candidate is present at $ActiveLocationImage but its servicing metadata could not be read; treating as not usable" -Level WARN
                }
                if (-not $ActiveLocationWimPresent -and $ActiveLocationImage) {
                    Write-Log "A WIM was discovered at $ActiveLocationImage but not at the registered location; not treating it as a registered source" -Level WARN
                }

                $selectedSource = $null
                $selectedSourceHash = $null
                $selectedReason = $null
                if ($regUsable -and $lkgUsable) {
                    $lkgMeta = Get-WimServicingMetadata -WimPath $lkgPath
                    $cmp = Compare-WimServicingMetadata -MetaA $regMeta -MetaB $lkgMeta
                    if ($cmp -eq 'A-older') {
                        $selectedSource = $lkgPath
                        $selectedSourceHash = $lkgResult.Hash
                        $selectedReason = "registered older than LKG (reg=$($regMeta.Version)/$($regMeta.SPBuild), lkg=$($lkgMeta.Version)/$($lkgMeta.SPBuild))"
                    } elseif ($cmp -eq 'A-newer-or-equal') {
                        $selectedSource = $ActiveLocationImage
                        $selectedSourceHash = $ActiveLocationHash
                        $selectedReason = "registered at least as new as LKG (reg=$($regMeta.Version)/$($regMeta.SPBuild), lkg=$($lkgMeta.Version)/$($lkgMeta.SPBuild))"
                    } else {
                        # Indeterminate comparison (metadata shape mismatch
                        # or unparseable fields). The registered image is
                        # not proven at least as new as the LKG, so the
                        # hash-validated LKG wins.
                        $selectedSource = $lkgPath
                        $selectedSourceHash = $lkgResult.Hash
                        $selectedReason = "metadata comparison indeterminate; using hash-validated LKG"
                    }
                } elseif ($regUsable) {
                    $selectedSource = $ActiveLocationImage
                    $selectedSourceHash = $ActiveLocationHash
                    $selectedReason = "no hash-validated LKG present; using registered"
                } elseif ($lkgUsable) {
                    $selectedSource = $lkgPath
                    $selectedSourceHash = $lkgResult.Hash
                    $selectedReason = "registered not usable; using hash-validated LKG"
                } else {
                    $selectedReason = "neither registered nor hash-validated LKG usable; GitHub cold-start"
                }

                if ($selectedSource) {
                    Write-Log "Base WIM source selection: $selectedReason -> $selectedSource"
                    Copy-Item $selectedSource "$WorkDir\base.wim" -Force
                    Write-Log "Copied base WIM from $selectedSource"
                    $Script:StagedWimSourceHash = $selectedSourceHash
                } else {
                    Write-Log "Base WIM source selection: $selectedReason"
                    # GitHub cold-start: no on-disk source to fingerprint.
                    # A WIM_READY checkpoint prepared from a GitHub source
                    # will be treated as stale on resume, which is safe.
                    $Script:StagedWimSourceHash = $null
                    if (-not (Get-GitHubBaseWinRE -WorkDir $WorkDir -Hardware $Hardware)) {
                        Write-Log "GitHub base WIM retrieval failed" -Level FATAL
                        exit $EXIT_FATAL
                    }
                }
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

        # v47: normalize the mounted image to zero third-party drivers
        # before injecting the current recipe. Hard gate: any failure to
        # enumerate, remove, or prove zero rejects the candidate. On
        # rejection, dismount with -Discard, clean up, roll the checkpoint
        # back to step 2, and defer. No injection, no export, no partition
        # work, no WinRE disable.
        if (-not (Remove-AllThirdPartyDrivers -MountDir $MountDir)) {
            Write-Log "Strip stage failed - candidate rejected. Dismounting with -Discard and deferring before injection, export, partition work, or WinRE disable." -Level ERROR
            try { Dismount-WindowsImage -Path $MountDir -Discard -ErrorAction SilentlyContinue } catch { }
            Remove-ItemIfExist $MountDir
            Set-Checkpoint -CheckpointFile $CheckpointFile -Step 2 -DesiredStateId $DesiredStateId
            Remove-ItemIfExist "$WorkDir\winre_optimized.wim"
            Remove-ItemIfExist "$WorkDir\base.wim"
            exit $EXIT_WARNING
        }

        $extractDir = "$WorkDir\oem_extract"

        # Add-WindowsDriver's return-shape filter ($_.Operation -in
        # @("Add","Installed")) does not match on Windows 11 build 26100.
        # Judge success by image third-party driver count delta plus
        # INF-basename cross-reference.
        $preInjectThirdParty = 0
        try {
            $preInjectThirdParty = @(
                Get-WindowsDriver -Path $MountDir -ErrorAction SilentlyContinue |
                Where-Object { $_.ProviderName -and $_.ProviderName -ne 'Microsoft Corporation' }
            ).Count
        } catch { }
        Write-Log "Pre-injection third-party driver count: $preInjectThirdParty"
        # v47: the strip stage above proved zero third-party drivers using
        # the filterless form Microsoft documents as the third-party
        # inventory. This pre-injection count uses the legacy filtered
        # form retained for injection-delta accounting. If the two views
        # disagree, log the discrepancy and flag a non-fatal warning. The
        # filterless form remains authoritative for the zero-driver
        # guarantee, so this does not abort the run; the existing
        # injection success gate (delta == 0 AND matchedInfCount == 0)
        # already fails conservatively in the case where a real
        # discrepancy would matter.
        if ($preInjectThirdParty -gt 0) {
            Write-Log "Strip claimed zero third-party drivers but the filtered pre-injection count is $preInjectThirdParty - the filterless and filtered DISM queries disagree on this image. Filterless is authoritative; injection delta accounting may underreport." -Level WARN
            $Script:nonFatalWarning = $true
        }

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

                    # Success gate: fail only when the package's INFs are
                    # absent AND no third-party drivers were added this run.
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
                Invoke-WebRequest -Uri $drv.driverUrl -OutFile $drvArchive -Headers $GitHubHeaders -UseBasicParsing -TimeoutSec $NetworkTimeoutSeconds -ErrorAction Stop
                $drvExtractDir = "$WorkDir\drv_extract_$($drv.name)"
                Remove-ItemIfExist $drvExtractDir -Recurse
                New-DirectoryIfNotExists $drvExtractDir | Out-Null
                & $7Zip x $drvArchive -o"$drvExtractDir" -w"$WorkDir\scratch" -y | Out-Null
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

        # ResetBase removes superseded components from the WinSxS store.
        # The size reduction only materialises on disk in Step 4's export.
        # Failure is non-fatal: the export writes whatever size the image
        # currently is. ResetBase makes the image unserviceable for
        # rollback, which is acceptable for a recovery image that is
        # rebuilt from source whenever the DesiredStateId changes.
        if ($Script:ImageInjectionComplete) {
            Write-Log "Step 3: Running component cleanup and ResetBase on mounted image"
            & dism /image:"$MountDir" /ScratchDir:"$WorkDir\scratch" /cleanup-image /StartComponentCleanup /ResetBase | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Log "dism /cleanup-image /StartComponentCleanup /ResetBase returned exit code $LASTEXITCODE - continuing without ResetBase savings. The export in Step 4 will still run." -Level WARN
            } else {
                Write-Log "Component cleanup and ResetBase completed successfully"
            }
        }

        Dismount-WindowsImage -Path $MountDir -Save; Remove-ItemIfExist $MountDir
        if ($Script:ImageInjectionComplete) {
            Set-Checkpoint -CheckpointFile $CheckpointFile -Step 3 -DesiredStateId $DesiredStateId
        } else {
            Write-Log "Checkpoint NOT advanced to step 3 - image injection did not complete; next run will retry step 3" -Level WARN
        }
    }

    # The pipeline gate: no Step 4, no partition work, no deployment, no
    # reagentc when injection failed. A WIM with no OEM/VMD drivers is
    # broken on hardware whose storage controller requires those drivers.
    if (-not $Script:ImageInjectionComplete) {
        Write-Log "Image injection did not complete. Stopping before Step 4 and before any deployment. The recovery partition and WinRE registration are unchanged. Next run will retry from step 2." -Level WARN
        Set-Checkpoint -CheckpointFile $CheckpointFile -Step 2 -DesiredStateId $DesiredStateId
        Remove-ItemIfExist "$WorkDir\winre_optimized.wim"
        Remove-ItemIfExist "$WorkDir\base.wim"
        exit $EXIT_WARNING
    }

    $OptimizedWim = "$WorkDir\winre_optimized.wim"
    if ($step -lt 4 -and $needInject) {
        Write-Log "Step 4: Optimizing"
        & dism /Export-Image /SourceImageFile:"$WorkDir\base.wim" /SourceIndex:1 /DestinationImageFile:$OptimizedWim /Compress:max /ScratchDir:"$WorkDir\scratch" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "dism /Export-Image failed with exit code $LASTEXITCODE" -Level FATAL
            exit $EXIT_FATAL
        }
        if (-not (Test-Path $OptimizedWim)) {
            Write-Log "dism /Export-Image reported success but $OptimizedWim does not exist" -Level FATAL
            exit $EXIT_FATAL
        }
        if ($Script:ImageInjectionComplete) {
            # v47: if this execution resumed at Step 3, Step 2 was skipped
            # and $Script:StagedWimSourceHash is still $null. Recover it
            # from base.wim by matching against the registered WIM hash
            # and the hash-validated LKG. If base.wim matches neither, it
            # is a GitHub cold-start (or an unknown on-disk source) and
            # the source identity is intentionally left $null, which
            # causes the next resume to invalidate the checkpoint
            # conservatively. base.wim is still present at this point;
            # it is removed immediately after the checkpoint write.
            if (-not $Script:StagedWimSourceHash -and (Test-Path "$WorkDir\base.wim")) {
                $recoveredHash = Get-LiveWimHash -WimPath "$WorkDir\base.wim"
                if ($recoveredHash) {
                    if ($ActiveLocationHash -and $recoveredHash -eq $ActiveLocationHash) {
                        $Script:StagedWimSourceHash = $recoveredHash
                        Write-Log "Recovered staged WIM source identity from base.wim: registered ($recoveredHash)"
                    } else {
                        $lkgForRecovery = Get-LKGWinREImagePath -StoredHash $lkgStoredHash
                        if ($lkgForRecovery -and $recoveredHash -eq $lkgForRecovery.Hash) {
                            $Script:StagedWimSourceHash = $recoveredHash
                            Write-Log "Recovered staged WIM source identity from base.wim: LKG ($recoveredHash)"
                        } else {
                            Write-Log "base.wim hash $recoveredHash does not match registered or LKG; treating as GitHub cold-start (no source identity)"
                        }
                    }
                } else {
                    Write-Log "Could not hash base.wim at Step 4 to recover source identity; checkpoint will have no source binding" -Level WARN
                }
            }
            Set-Checkpoint -CheckpointFile $CheckpointFile -Step 4 -DesiredStateId $DesiredStateId -WimReady -SourceHash $Script:StagedWimSourceHash
            Remove-ItemIfExist "$WorkDir\base.wim"
            Write-Log "Removed base.wim after verified export to free workspace capacity before partition planning"
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
        if ($created -and $created.Status -eq "Deferred") {
            Write-Log "Dedicated replacement deferred before partition deletion ($($created.Reason)). The existing WinRE route was preserved; not attempting OS-fallback." -Level WARN
            if ($created.RetrySuppressible) {
                Write-PartitionDeferral -DesiredStateId $DesiredStateId
                Write-Log "Recorded retry-suppressing deferral for DesiredStateId $DesiredStateId; next run will verify the existing route before skipping identical retries. Delete $env:SystemDrive\Recovery\OEM\$StateFileName and $env:SystemDrive\Recovery\OEM\$PartitionDeferralFileName to force a retry."
            }
            $Script:nonFatalWarning = $true
            exit $EXIT_WARNING
        } elseif ($created -and $created.Status -eq "Created") {
            $recoveryPartition = @{ DriveLetter = $created.DriveLetter; DiskNumber = $created.DiskNumber; PartitionNumber = $created.PartitionNumber; Partition = $null }
            Clear-PartitionDeferral
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

    # Dedicated: prepare the target recovery partition (reagentc's
    # BitLocker check is on the target). OS-fallback: gate on C: being
    # confirmed FullyDecrypted, because there the target IS the OS
    # volume. Never modify C:'s BitLocker state.
    if ($recoveryPartition) {
        if (-not (Set-RecoveryPartitionReadyForWinRE -DiskNumber $recoveryPartition.DiskNumber -PartitionNumber $recoveryPartition.PartitionNumber)) {
            Write-Log "FATAL: Could not make target recovery partition unencrypted" -Level ERROR
            exit $EXIT_FATAL
        }
    } else {
        # v44 patch 6: corrected OS-fallback remediation wording.
        # Actions that complete encryption, add a protector, or enable
        # protection do NOT satisfy the FullyDecrypted requirement.
        $osFallbackEnc = Test-VolumeEncrypted -MountPoint "C:"
        if ($osFallbackEnc -ne $false) {
            Write-Log "OS-fallback deferred: C: could not be confirmed fully decrypted (Test-VolumeEncrypted=$osFallbackEnc). reagentc refuses to enable WinRE on an encrypted OS volume. The OS-fallback route requires C: to be FullyDecrypted. Actions that complete encryption, add a recovery-password protector, or enable protection do NOT satisfy this requirement. To resolve: complete decryption of C: (e.g. manage-bde -off C:) or wait for an in-progress decryption to finish, then re-run. The dedicated recovery-partition path has its own separate BitLocker policy and is not gated on C:. The script will not modify C:'s BitLocker state." -Level WARN
            $Script:nonFatalWarning = $true
            Remove-ItemIfExist $CheckpointFile
            exit $EXIT_WARNING
        }
    }

    $CurrentWinREState = Get-WinREState
    if ($CurrentWinREState.Status -eq "Enabled") {
        # v47: race-detector recheck immediately before the first
        # possible /disable of this execution. This site is reached
        # with the old WinRE route intact and no partition changes
        # made by Ensure-AdequateRecoveryPartition (if that function
        # ran and disabled WinRE, this branch does not execute). A
        # drift-abort here is a clean defer without rollback.
        if (-not (Assert-RegisteredWinREUnchanged -Captured $Script:RegisteredSourceFingerprint -CalledFrom 'Step 5 deployment')) {
            Write-Log "Registered WinRE source changed during candidate preparation - aborting before /disable. The old WinRE route remains intact; no partition changes have been made at this site." -Level WARN
            # Invalidate staged work: the checkpoint and its WIM are tied to
            # a source that is now known to have drifted.
            Set-Checkpoint -CheckpointFile $CheckpointFile -Step 2 -DesiredStateId $DesiredStateId
            Remove-ItemIfExist "$WorkDir\winre_optimized.wim"
            Remove-ItemIfExist "$WorkDir\base.wim"
            $Script:nonFatalWarning = $true
            exit $EXIT_WARNING
        }
        Write-Log "Disabling WinRE before deployment"
        $disOut = cmd /c "reagentc /disable 2>&1"
        $disExit = $LASTEXITCODE
        Write-Log "reagentc /disable: exit=$disExit, output=$disOut"
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

    # Update the OS-fallback WIM at C:\Recovery\WindowsRE\winre.wim.
    # In v47 this file serves two roles: the OS-fallback deployment target
    # when WinRE runs from the OS partition, and the last-known-good (LKG)
    # source that Get-LKGWinREImagePath validates against
    # state.CurrentImageHash. Both roles require it to hold the current
    # image. Skip when the deployment source is already this file: the
    # block would delete the source and then copy it to itself, destroying
    # the only copy.
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
    # v46 patch 2: log the build of the WIM that was actually deployed.
    # Compare against the pre-touch "WinRE ... Version:" startup line to
    # see whether this run replaced a newer registered build with an
    # older one. Informational only.
    $deployedWimBuild = Get-WimBuild -WimPath $SourceWim
    Write-Log "Post-deploy WIM build: $(if ($deployedWimBuild) { $deployedWimBuild } else { 'unknown' }) (source: $SourceWim)"
    # v47: log the final deployed WIM's SHA256. This is the value that
    # will be written to the state file as CurrentImageHash and will be
    # compared against the next run's registered hash for byte-drift
    # evidence. Logged for evidence only; no gate reads it.
    if ($finalHash) {
        Write-Log "Final deployed WinRE SHA256: $finalHash"
    }
    # v47: capture the metadata of the WIM just deployed so the next run's
    # drift detection has an anchor. If the metadata cannot be read, store
    # $null; the next run will then treat the state as missing metadata
    # and force a rebuild.
    $deployedMetaNow = Get-WimServicingMetadata -WimPath $SourceWim
    if ($deployedMetaNow) {
        $Script:DeployedWinREMetadata = "$($deployedMetaNow.Version)|$($deployedMetaNow.SPBuild)"
        Write-Log "Deployed WinRE metadata: $($Script:DeployedWinREMetadata)"
    } else {
        $Script:DeployedWinREMetadata = $null
        Write-Log "Deployed WinRE metadata could not be read from $SourceWim; next run will treat this as missing metadata and rebuild" -Level WARN
    }
    if ($Script:ImageInjectionComplete -and $finalHash) {
        $deployedDisk = if ($recoveryPartition) { $recoveryPartition.DiskNumber } else { -1 }
        $deployedPart = if ($recoveryPartition) { $recoveryPartition.PartitionNumber } else { -1 }
        # Counter increments on terminal enable failures only.
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
    if ($Script:ImageInjectionComplete) {
        Set-Checkpoint -CheckpointFile $CheckpointFile -Step 6 -DesiredStateId $DesiredStateId
    } else {
        Write-Log "Checkpoint NOT advanced to step 6 - image injection did not complete; next run will retry step 3" -Level WARN
    }

    Write-Log "Step 6: Cleanup"
    Remove-ItemIfExist $WorkDir -Recurse; Remove-ItemIfExist $CheckpointFile

    # Step 7: enforce "no type-coded recovery partition on any non-OS disk".
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

            $isRec = ($finalPart.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}') -or
                     ($finalPart.MbrType -eq 0x27)

            if ($isFinalOSPart) {
                if ($Script:UsedOSFallback) {
                    Write-Log "Operating mode: OS-FALLBACK (WinRE on OS partition at $($finalState.Location)) - degraded but functional" -Level WARN
                } else {
                    Write-Log "FATAL: WinRE is on the OS partition but the script did not deploy it via OS-fallback" -Level ERROR
                    exit $EXIT_FATAL
                }
            }
            elseif ($isRec -and $finalOSPartCheck -and
                    $finalPart.DiskNumber -eq $finalOSPartCheck.DiskNumber) {
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

    if ($Script:TempEnvironmentChanged) {
        $env:TEMP = $Script:OriginalTempPath
        $env:TMP = $Script:OriginalTmpPath
    }

    $leaks = @()
    foreach ($letter in $Script:tempDriveLetters) {
        try {
            $part = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
            if (-not $part) { continue }
            if ($part.IsBoot -or $part.IsSystem) { continue }
            if (Test-Path "${letter}:\Windows") { continue }
            $removedOk = Invoke-DriveLetterRemoval -Letter $letter
            if ($removedOk) {
                if ($Script:DryRun) { Write-Log "[DRY RUN] Would remove temp drive letter ${letter}:" }
                else { Write-Log "Removed temp drive letter ${letter}:" }
            } else {
                Write-Log "FAILED to remove drive letter ${letter}:" -Level ERROR; $leaks += $letter
            }
        } catch { $leaks += $letter }
    }
    if ($leaks.Count -gt 0) { Write-Log "Drive letters still assigned: $($leaks -join ', ')" -Level ERROR }

    # Lock released last, after every cleanup step.
    if ($Script:ProgramLockStream) {
        try {
            $Script:ProgramLockStream.Dispose()
            Write-Log "Released program lock"
        } catch {
            Write-Log "Could not release program lock: $_" -Level WARN
        }
    }
}
