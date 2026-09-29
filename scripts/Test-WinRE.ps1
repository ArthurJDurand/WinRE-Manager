<#
.SYNOPSIS
    WinRE Manager test harness - download and extraction validation.

.DESCRIPTION
    Interactive, read-only harness that exercises the download and extraction
    paths of the WinRE Manager against live sources:
      - Driver manifest (gist)
      - OEM maps (Dell, HP, Lenovo gists)
      - OEM pack downloads + extraction
      - VMD driver downloads per manifest
      - GitHub base WIM repo (split 7-Zip archives) + extraction

    The download, extraction, and OEM-provider helpers, along with the
    Intel CPU-generation parser, are based on the corresponding
    WinRE.ps1 v43 functions. The harness substitutes Say for Write-Log
    and omits the production-only DryRun short-circuits in its
    download, extraction and directory helpers, because its purpose is
    to exercise the live paths. Get-ThisMachineProfile is a harness-
    specific read-only helper, not a verbatim copy of production's
    Get-HardwareObject: the two use different OS-detection logic
    (build-number vs caption) and the Lenovo machine-type fallback
    chain is not identical. The harness does not execute any production
    main-flow logic (partition recreation, BitLocker recovery,
    state-file handling, checkpoint writes), so the v43 patch 4 changes
    do not require a functional harness change. The harness exercises
    the same download, extraction, and CPU-generation code paths as
    production within the scope of those shared helpers.

    Validated against v43. The v42 additions (Get-OSDisk and the OS-disk-anchored
    boot-disk lookup), the v43 additions (the fallback-source guard and
    the force-rebuild-when-no-WIM check in the main flow), the v43
    patch 2 changes (the classifier OS-disk gate, the WIM-hash gate on
    ActiveLocationWimPresent, the geometry-restore flag, the count=0
    exemption gate, and the state-file deletion), the v43 patch 3
    changes (the orphan-deletion-failure geometry flag, and the three
    additional enforcement sites for the "no type-coded recovery
    partition on any non-OS disk" invariant: the enable-only path, the
    pending-reboot success exit, and the pending-reboot reboot-required
    exit), the v43 patch 4 changes (the three checkpoint writes
    gated on $Script:ImageInjectionComplete, and the migration guard
    that resets $step when a checkpoint at step 4 or later coincides
    with a required rebuild), and the v43 patch 5 changes (BitLocker
    protection-state checks now consider VolumeStatus as well as
    ProtectionStatus, and New-Partition sets the recovery type GUID at
    creation time to close the Device Encryption auto-encryption
    window) do not change any of the functions the harness exercises,
    so the harness remains valid against the current production file
    without modification. The harness does NOT exercise the
    partition-recreation, BitLocker-recovery, or state-write code paths
    touched by v42/v43; those are covered by field testing.

    Does NOT modify WinRE, partitions, BitLocker, drive letters, or the
    state file. No admin required. All work is confined to $TestDir.

.PARAMETER TestDir
    Working directory. Default C:\Temp\WinRETest.

.PARAMETER Keep
    Do not offer to delete $TestDir on exit.

.PARAMETER NonInteractive
    Run "all relevant for this machine" once and exit.

.NOTES
    Version : 13

    v13 changes vs v12:
    1. Show-SystemDiagnostic now reads
       HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State
       -> ImageState and warns when the value is present and not
       IMAGE_STATE_COMPLETE. Production v43 patch 5 (further
       revision) refuses to run in that state, because reagentc
       /enable is blocked with 0x4c7 during Audit Mode, OOBE, and
       the sysprep generalize/specialize phases. Without this
       check the diagnostic would report every other subsystem
       healthy while production would defer, which is misleading
       on a machine whose only problem is that it has not finished
       OOBE.
    2. Menu and entry banners updated to "v13".

    v12 changes vs v11:
    1. Show-SystemDiagnostic now flags the Device Encryption in-progress
       hazard in the BitLocker (C:) section. When ProtectionStatus reads
       Off but VolumeStatus is one of the hazardous mid-operation states
       (EncryptionInProgress, DecryptionInProgress, EncryptionPaused,
       DecryptionPaused), Device Encryption is actively encrypting or
       decrypting the volume. In that state, new partitions created on
       the same disk are auto-encrypted by the Device Encryption service
       before their recovery type GUID can be applied, and reagentc
       /enable refuses with "Windows RE cannot be enabled on a volume
       with BitLocker Drive Encryption enabled." Production v43 patch 5
       now refuses to run the destructive partition paths in this state;
       the warning here makes the hazard visible to a field engineer
       before they run WinRE.ps1. Triggered by two field failures in the
       same 24-hour window (Dell Latitude 3550 with Core Ultra 5 125U,
       HP ProBook 450 G10 with i7-1355U), both on Windows 11 build 26200
       mid-Device-Encryption.

    1a. (v12, same release) The hazard predicate is now aligned with
        production v43 patch 5 (revised) semantics. A volume with
        ProtectionStatus=Off and VolumeStatus=FullyEncrypted is the
        standard suspended-BitLocker state (e.g. after
        Suspend-BitLocker or a Windows Update suspension that has not
        yet been lifted) and is NOT hazardous. The initial v12 predicate
        treated it as hazardous, which produced a false-positive warning
        on every machine with suspended BitLocker and told the operator
        to wait for a state a suspended machine will never reach on its
        own. Only the four mid-operation states are hazardous. The
        warning message was also corrected: it no longer claims the
        BitLocker key must be escrowed, because Get-BitLockerVolume's
        local output cannot verify escrow.
    2. Menu and entry banners updated to "v12".

    v11 changes vs v10:
    1. Test-GitHubBaseWim now records FAIL when Get-WindowsImage cannot
       read the extracted WIM's build. Previously the catch block left
       $buildOk at $true, so an unreadable WIM was reported as a pass
       even though the build validation - the entire purpose of that
       check - had not run. Identified by independent review; not a
       field failure.
    2. The top-level docstring no longer claims the download,
       extraction, OEM-provider, and hardware-detection functions are
       "copied verbatim" from WinRE.ps1 with "only the logging function"
       differing. The claim was inaccurate: the download, extraction
       and directory helpers omit production's DryRun short-circuits,
       and Get-ThisMachineProfile is a harness-specific helper with
       different OS-detection logic than production's Get-HardwareObject
       (build-number vs caption) and a different Lenovo machine-type
       fallback chain. The wording now describes the actual relationship
       and explicitly states the scope of what is and is not mirrored.
    3. The v2 changelog item 4 for Test-VmdDrivers no longer says it
       "mirrors" the production VMD download block. The harness
       intentionally does not apply production's requiredDevices / PnP
       hardware-presence filter - it validates every OS/CPU-eligible
       package even when no matching VMD controller is present, which is
       deliberate. The wording now describes that behaviour and the
       reason for it.
    4. The docstring's production-compatibility paragraph now names the
       v43 patch 4 changes (the three checkpoint gates and the migration
       guard) alongside the earlier patch generations. Purely
       documentary; patch 4 touched only production main-flow code, not
       any function the harness exercises.
    5. `-NonInteractive` still exits 0 unconditionally. Left unchanged
       deliberately: no consumer is currently known to need failure-
       based exit codes, and adding an exit-code contract would be an
       extension rather than a correction. If a pipeline consumer is
       added later, the minimal change is to count FAIL records in
       $Script:Results and exit non-zero when any exist.
    6. Menu and entry banners updated to "v11".
    7. Section header comments no longer carry the "(verbatim from
       WinRE.ps1)" qualifier. The docstring (v11 item 2) now accurately
       describes the helpers as "based on" the corresponding production
       functions; the section headers retained the older "verbatim"
       claim, which was inconsistent with the docstring and inaccurate
       for the DOWNLOAD and EXTRACTION helpers that omit production's
       DryRun short-circuits. No functional change.
    8. The docstring's production-compatibility paragraph no longer
       opens with "Copied from v43". v11 item 2 changed the primary
       claim to "based on", and "Copied from v43" was a residual
       statement of the older relationship. Replaced with "Validated
       against v43", which matches the actual relationship the file
       already described in v6 item 1 ("the harness is now explicitly
       validated against v43 production"). No functional change.

    v10 changes vs v9:
    1. Top-level docstring updated to name the v43 patch 3 changes
       alongside the v42, v43, and v43 patch 2 changes already listed.
       v43 patch 3 touched only production-only code paths
       (Remove-OrphanPartition's orphan-survival branch, and three new
       calls to Remove-StrayRecoveryPartitions from the enable-only and
       pending-reboot exits). None of the verbatim-copied functions were
       modified. The docstring is updated only so a reader picking up
       this file does not have to independently verify that claim
       against the current production file.

    v9 changes vs v8:
    1. Show-Summary no longer contains dead defensive code. The
       foreach loop and the three count aggregations all guarded
       against records that lacked a State field with
       $r.PSObject.Properties['State'] -and ... The guard dates from
       v5, before v6 introduced the three-state Record contract. Every
       record is now produced by Record, which always sets a State
       field, so the guard is unreachable and the -and clause is
       redundant: Where-Object { $null -eq "PASS" } already evaluates
       to $false. The loop now reads $r.State directly and the three
       aggregations filter on $_.State alone. Behaviorally inert;
       output and counts are identical for every input the harness can
       produce.
    2. Menu and entry banners updated to "v9".

    v8 changes vs v7:
    1. Fixed two parser self-test records whose State field did not
       match the [SKIP] label printed alongside them:
       - Get-PartitionSupportedSize now records SKIP when there is no
         OS partition to query, instead of FAIL. The Say line already
         said [SKIP]; only the record disagreed, and the summary
         counted the check as a failure on machines where the check
         simply could not run.
       - WinRE location resolution now records SKIP when the reagentc
         location field is empty, instead of PASS. The Say line already
         said [SKIP]; only the record disagreed, and the summary
         counted the check as a pass on machines where it did not
         actually run.
       Both were inconsistent with the SKIP convention established in
       v6. They do not affect any downstream test logic; they only
       correct the summary totals on machines in those two edge states.

    v7 changes vs v6:
    1. Show-SystemDiagnostic now mirrors the v43 patch 2 production
       classifier. Previously the diagnostic printed "Classification:
       DEDICATED" whenever the reagentc-registered partition was a
       recovery partition, regardless of which disk it sat on. Under
       v43 patch 2, a recovery partition on a non-OS disk does not take
       the idempotent fast path - the production script forces a full
       update to redeploy the WIM to the OS disk. The diagnostic now
       reports DEDICATED only when the recovery partition is on the OS
       disk, and reports a distinct RECOVERY-ON-SECONDARY verdict
       otherwise, so a field tech is not misled into thinking the
       machine is in the healthy end state.
    2. Parser self-test banner and leading comment updated from "v42
       dependency verification" to "v43 dependency verification". No
       check was added, removed, or reordered - none of the checks
       depend on the code paths v43 patch 2 touched.
    3. Menu and entry banners updated to "v7".

    v6 changes vs v5:
    1. Documentation now says the harness functions are copied from v43
       (the previous text said v41 and only claimed compatibility with
       v42). The v42 and v43 fixes do not touch any function the harness
       exercises, but the harness is now explicitly validated against
       v43 production.
    2. New Test-IsElevated helper. Elevation-dependent parser self-test
       checks now record SKIP rather than FAIL when the harness is run
       without elevation, so a non-admin run no longer reports false
       failures. Show-Summary distinguishes PASS / FAIL / SKIP and prints
       totals for each.
    3. Show-SystemDiagnostic reports elevation state at the top of the
       diagnostic output so it is clear when BitLocker and partition
       queries may return incomplete data.
    4. Test-VmdDrivers now logs a warning with the raw CPU string when
       an Intel CPU is detected but its generation cannot be parsed.
       Previously the VMD test silently skipped all manifest drivers in
       this case, which could hide a stale CPU-generation regex.

    v5 changes vs v4:
    1. Option 1 (system diagnostic) now performs a parser self-test that
       verifies every extractor and API dependency v42 relies on still
       produces the shape we expect. Each check records a PASS or FAIL
       in $Script:Results, so the results summary shows whether this
       machine's Windows tooling still matches v42's assumptions.
       Checks:
       - reagentc /info status regex matches Enabled or Disabled
       - reagentc /info location regex matches GLOBALROOT or Volume GUID
       - manage-bde -status parses 'Protection On' / 'Protection Off'
       - manage-bde -status parses a Conversion Status value OR the
         unmanaged-volume classification 'could not be opened by
         BitLocker'
       - Get-BitLockerVolume returns an object with ProtectionStatus and
         VolumeStatus
       - Get-OSPartition and Get-OSDisk both resolve
       - Get-Partition exposes all expected properties (DiskNumber,
         PartitionNumber, Size, GptType, MbrType, IsBoot, IsSystem,
         IsActive)
       - WinRE location resolves to a partition
       - Get-RecoveryPartitions returns at least one partition
       - Get-PartitionSupportedSize returns SizeMin and SizeMax
       A FAIL on any of these means the production script may silently
       misclassify state on this machine and must be adapted.
    2. manage-bde -status C: is now dumped raw into the diagnostic
       output, so a format change is visible even if the regexes are
       updated later.

    v4 changes vs v3:
    1. New first menu option: "System diagnostic (read-only info
       gathering)". Dumps hardware, raw reagentc /info output, parsed
       WinRE state, WinRE location classification, OS partition and OS
       disk resolution, all disks, all partitions, all volumes, all
       recovery partitions with type-vs-label classification, OS
       partition SizeMin/SizeMax/shrinkable/extendable, the v42 bucket
       sizing preview based on the active WIM size at the reagentc-
       registered location, BitLocker status on C:, and VMD hardware
       presence per manifest. Purely read-only - does not assign drive
       letters, mount WIMs, or modify any state.
    2. Existing menu options shifted down. Driver manifest moved from
       1 to 2, OEM maps from 2 to 3, WIM Win10 from 3 to 4, WIM Win11
       from 4 to 5, HP from 5 to 6, Dell from 6 to 7, Lenovo from 7 to
       8, VMD drivers from 8 to 9. "All relevant for this machine"
       moved from 9 to A, "All of the above" moved from A to B. R and
       Q unchanged.

    v3 changes vs v2:
    1. Version number consistency. The startup banner printed "v2"
       while the file header, .NOTES block, and menu header had
       already been updated to v3. Fixed.
    2. Section header comments no longer carry the "v41" version
       qualifier. The top-level docstring already records that the
       functions were copied from v41, so the qualifier on each
       section header was redundant and made the file appear to have
       three separate version numbers.

    v2 changes vs v1:
    1. Fixed parse-time bug in Invoke-AllRelevant: `if` was used as an
       expression inside a command argument, which is not valid PowerShell
       syntax and prevented the script from running at all. The Dell key is
       now selected via a temporary variable before the call.
    2. Download, extraction, OEM-provider, and hardware-detection functions
       are now copied verbatim from WinRE.ps1 v41 (renamed Say in place of
       Write-Log). Previously the harness re-implemented a slightly different
       version of each, which meant the harness could pass on inputs the
       production script would reject, and vice versa. The harness now
       exercises the same code paths as production.
    3. Invoke-CabExtraction now requires INF files to be present, matching
       the production criterion. Previously it returned true on any clean
       7-Zip exit, even with zero INFs extracted.
    4. Added Test-VmdDrivers. Downloads and extracts each manifest driver
       whose OS and Intel CPU-generation criteria match this machine, and
       reports INF counts. The harness intentionally does not apply the
       production script's requiredDevices / PnP hardware-presence filter:
       it validates every OS/CPU-eligible package, even when the
       corresponding VMD controller is not present. This is deliberately
       broader than production's VMD download block and lets the harness
       validate all package URLs and extraction paths from a single
       machine.
    5. Added Win10/Win11 build validation to Test-GitHubBaseWim. The WIM's
       ImageBuild is compared against the folder it was pulled from; a
       mismatch (e.g. a Win10 build inside the Win11 folder) is reported as
       a failure.
    6. Added CPU generation detection (copied verbatim from production) so
       VMD driver matching uses the same logic as the main script.
#>

[CmdletBinding()]
param(
    [string]$TestDir = "C:\Temp\WinRETest",
    [switch]$Keep,
    [switch]$NonInteractive
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

# =========================== CONFIG (mirror of main script) ===========================
$DriverManifestUrl = "https://gist.github.com/52250179/4d98029c7b39240cdb860ee3c78c3ca9/raw"
$BaseWinRERepoApi  = "https://api.github.com/repos/52250179/OriginalWindowsREImages/contents"
$7Zip              = "C:\Program Files\7-Zip\7z.exe"
$LenovoWinPEMapUrl = "https://gist.github.com/52250179/8211b75a38444caa68b8cebd7529376c/raw"
$HPWinPEMapUrl     = "https://gist.github.com/52250179/07f9c3db08e5ef27daca1e7ff700af35/raw"
$DellWinPEMapUrl   = "https://gist.github.com/52250179/52058dde0701c749be627c9601c5c925/raw"

$GitHubHeaders = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36' }

# =========================== HARNESS STATE ===========================
$Script:Results       = [System.Collections.Generic.List[object]]::new()
$Script:DellWinPEMap  = $null
$Script:HPWinPEMap    = $null
$Script:LenovoWinPEMap = $null

# =========================== HARNESS LOGGING / UI ===========================
function Say {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "$Timestamp [$Level] $Message"
}

function Rule {
    param([string]$Title)
    Write-Host ""
    Write-Host ("--- $Title " + ("-" * [Math]::Max(0, 68 - $Title.Length)))
}

function New-TestDir {
    param([string]$Sub)
    $p = Join-Path $TestDir $Sub
    if (-not (Test-Path $p)) { New-Item -Path $p -ItemType Directory -Force | Out-Null }
    return $p
}

function Test-IsElevated {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Record {
    # Three-state result. -State is one of "PASS", "FAIL", "SKIP".
    # The legacy -Ok boolean remains supported for existing call sites;
    # when -State is not supplied it is derived from -Ok. When -State is
    # supplied it is authoritative, and OK is set to $true only for PASS
    # so a SKIP is never counted as a pass by a consumer reading OK.
    param(
        [string]$Test,
        [bool]$Ok,
        [string]$Detail = "",
        [ValidateSet("PASS","FAIL","SKIP")][string]$State = ""
    )
    if (-not $State) {
        $State = if ($Ok) { "PASS" } else { "FAIL" }
    }
    $Script:Results.Add([PSCustomObject]@{
        Test   = $Test
        State  = $State
        OK     = ($State -eq "PASS")
        Detail = $Detail
    })
}

# =========================== DOWNLOAD HELPERS (based on WinRE.ps1) ===========================
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

function Invoke-OemPackDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$ExpectedSHA256,
        [string]$ExpectedMD5,
        [int]$MaxRetries = 3
    )

    if (Test-Path $DestinationPath) {
        Say "Removing existing file before download: $DestinationPath"
        Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue
    }

    $lastException = $null
    for ($retry = 1; $retry -le $MaxRetries; $retry++) {
        Say "Download attempt $retry of ${MaxRetries}: $Url"
        $requestSucceeded = $false
        try {
            Invoke-WebRequest -Uri $Url -OutFile $DestinationPath -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop
            $requestSucceeded = $true
            Say "Invoke-WebRequest completed without exception (attempt $retry)"
        } catch {
            $lastException = $_
            Say "Invoke-WebRequest threw exception on attempt ${retry}: $($_.Exception.Message)" -Level WARN
        }

        if (-not (Test-Path $DestinationPath)) {
            Say "File not present after attempt $retry" -Level WARN
            if ($retry -lt $MaxRetries) { Start-Sleep 5 }
            continue
        }

        $fileSize = -1
        try { $fileSize = (Get-Item $DestinationPath -Force).Length } catch { }
        Say "File present after attempt $retry, size: $([math]::Round($fileSize/1MB,2)) MiB"

        $hasHash = [bool]$ExpectedSHA256 -or [bool]$ExpectedMD5
        if (-not $hasHash) {
            if ($requestSucceeded) {
                Say "Download successful (no integrity hash supplied) on attempt $retry"
                return $true
            }
            Say "Download not accepted: no integrity hash supplied and request did not complete cleanly - retrying" -Level WARN
            Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue
            if ($retry -lt $MaxRetries) { Start-Sleep 5 }
            continue
        }

        $hashOk = $true
        if ($ExpectedSHA256) {
            $actualSHA256 = (Get-FileHash -Path $DestinationPath -Algorithm SHA256).Hash
            Say "SHA256 actual: $actualSHA256"
            Say "SHA256 expected: $ExpectedSHA256"
            if ($actualSHA256.ToUpperInvariant() -ne $ExpectedSHA256.ToUpperInvariant()) {
                Say "SHA256 mismatch" -Level WARN
                $hashOk = $false
            } else {
                Say "SHA256 verified"
            }
        }
        if ($hashOk -and $ExpectedMD5) {
            $actualMD5 = (Get-FileHash -Path $DestinationPath -Algorithm MD5).Hash
            Say "MD5 actual: $actualMD5"
            Say "MD5 expected: $ExpectedMD5"
            if ($actualMD5.ToUpperInvariant() -ne $ExpectedMD5.ToUpperInvariant()) {
                Say "MD5 mismatch" -Level WARN
                $hashOk = $false
            } else {
                Say "MD5 verified"
            }
        }

        if ($hashOk) {
            Say "Download successful (hash verified) on attempt $retry"
            return $true
        }

        Say "Hash verification failed on attempt $retry - removing file and retrying" -Level WARN
        Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue
        if ($retry -lt $MaxRetries) { Start-Sleep 5 }
    }

    if ($lastException) {
        Say "Download failed after $MaxRetries attempts. Last exception: $($lastException.Exception.Message)" -Level ERROR
    } else {
        Say "Download failed after $MaxRetries attempts (hash verification never passed)" -Level ERROR
    }
    return $false
}

# =========================== EXTRACTION HELPERS (based on WinRE.ps1) ===========================
function Invoke-VendorExtraction {
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$DestinationDir,
        [Parameter(Mandatory)][ValidateSet("LENOVO","HP")][string]$Vendor
    )

    if (-not (Test-Path $ExePath)) {
        Say "Invoke-VendorExtraction: executable not found: $ExePath" -Level ERROR
        return $false
    }

    New-DirectoryIfNotExists $DestinationDir | Out-Null

    $arguments = switch ($Vendor) {
        "LENOVO" { @("/VERYSILENT", "/DIR=`"$DestinationDir`"", "/SILENT", "/SUPPRESSMSGBOXES") }
        "HP"     { @("/s", "/e", "/f", "`"$DestinationDir`"") }
    }

    $argString = $arguments -join ' '
    Say "Extracting $Vendor package: `"$ExePath`" $argString"

    try {
        $proc = Start-Process -FilePath $ExePath -ArgumentList $arguments -Wait -PassThru -NoNewWindow -ErrorAction Stop
        Say "$Vendor extractor exit code: $($proc.ExitCode)"

        if ($proc.ExitCode -ne 0) {
            Say "$Vendor extractor returned non-zero exit code $($proc.ExitCode)" -Level WARN
            $infCount = Get-InfFileCount -Directory $DestinationDir
            Say "$Vendor extractor returned $($proc.ExitCode); INF files found: $infCount"
            if ($infCount -gt 0) {
                Say "$Vendor extractor returned non-zero but produced $infCount INF file(s) - treating as success" -Level WARN
                return $true
            }
            return $false
        }

        $infCount = Get-InfFileCount -Directory $DestinationDir
        Say "$Vendor extractor completed. INF files found in `"$DestinationDir`": $infCount"
        return ($infCount -gt 0)
    } catch {
        Say "$Vendor extractor failed: $_" -Level ERROR
        return $false
    }
}

function Invoke-CabExtraction {
    param(
        [Parameter(Mandatory)][string]$CabPath,
        [Parameter(Mandatory)][string]$DestinationDir
    )

    if (-not (Test-Path $CabPath)) {
        Say "Invoke-CabExtraction: file not found: $CabPath" -Level ERROR
        return $false
    }

    New-DirectoryIfNotExists $DestinationDir | Out-Null

    if (-not (Test-Path $7Zip)) {
        Say "Invoke-CabExtraction: 7-Zip not found at $7Zip" -Level ERROR
        return $false
    }

    try {
        $proc = Start-Process -FilePath $7Zip -ArgumentList @("x", "`"$CabPath`"", "-o`"$DestinationDir`"", "-y") -Wait -PassThru -NoNewWindow -ErrorAction Stop
        Say "7-Zip CAB extraction exit code: $($proc.ExitCode)"
        if ($proc.ExitCode -ne 0) {
            Say "7-Zip CAB extraction failed with exit code $($proc.ExitCode)" -Level WARN
            return $false
        }
        $infCount = Get-InfFileCount -Directory $DestinationDir
        Say "CAB extraction completed. INF files found: $infCount"
        return ($infCount -gt 0)
    } catch {
        Say "7-Zip CAB extraction failed: $_" -Level ERROR
        return $false
    }
}

function New-DirectoryIfNotExists {
    param([string]$Path)
    if ($Path -and -not (Test-Path $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
}

# =========================== HARDWARE (based on WinRE.ps1) ===========================
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

function Get-ThisMachineProfile {
    $build = (Get-CimInstance Win32_OperatingSystem).BuildNumber
    $os = if ([int]$build -ge 22000) { "Win11" } else { "Win10" }
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor
    $mfg = $cs.Manufacturer.Trim()
    $vendor = switch -Regex ($mfg) {
        'Dell'            { 'Dell' }
        'HP'              { 'HP' }
        'Hewlett-Packard' { 'HP' }
        'Lenovo'          { 'Lenovo' }
        default           { $null }
    }
    $mt = $null
    if ($vendor -eq 'Lenovo') {
        if ($cs.Model -match '^([A-Z0-9]{4})') { $mt = $Matches[1] }
        elseif ((Get-CimInstance Win32_ComputerSystemProduct).Name -match '^([A-Z0-9]{4})') { $mt = $Matches[1] }
    }
    $cpuVendor = if ($cpu.Manufacturer -like "*Intel*") { "Intel" } else { "AMD" }
    $gen = Get-IntelProcessorGeneration -CPUName $cpu.Name
    return [PSCustomObject]@{
        OS          = $os
        Vendor      = $vendor
        MachineType = $mt
        Build       = $build
        CPUVendor   = $cpuVendor
        CPUGeneration = $gen
    }
}

# =========================== SYSTEM INFO HELPERS (based on WinRE.ps1) ===========================
# Read-only clones of the production script's WinRE/disk detection
# functions. Used by Show-SystemDiagnostic to report what the production
# script would see on this machine. None of these modify state.

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
    return @{ Status = $status; Location = $location; RawInfo = $info }
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

function Get-OSDisk {
    $osPart = Get-OSPartition
    if (-not $osPart) { return $null }
    return Get-Disk -Number $osPart.DiskNumber -ErrorAction SilentlyContinue
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

# =========================== DIAGNOSTIC ===========================
function Show-SystemDiagnostic {
    Rule "System diagnostic - read-only information gathering"
    $elevated = Test-IsElevated
    Say "  Elevation: $(if ($elevated) { 'YES' } else { 'NO - BitLocker and partition queries may return incomplete data' })"

    # ---- Hardware ----
    Say "--- Hardware ---"
    $cs      = Get-CimInstance Win32_ComputerSystem
    $cpu     = Get-CimInstance Win32_Processor
    $product = Get-CimInstance Win32_ComputerSystemProduct
    $board   = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue
    $osInfo  = Get-CimInstance Win32_OperatingSystem
    $profile = Get-ThisMachineProfile

    Say "  Manufacturer:     $($cs.Manufacturer)"
    Say "  Model:            $($cs.Model.Trim())"
    Say "  Product Name:     $($product.Name)"
    Say "  Product Version:  $($product.Version)"
    if ($board) { Say "  BaseBoard:        $($board.Manufacturer) $($board.Product)" }
    Say "  OS Caption:       $($osInfo.Caption)"
    Say "  OS Build:         $($osInfo.BuildNumber)"
    Say "  Raw CPU:          $($cpu.Name)"
    Say "  CPU Vendor:       $($profile.CPUVendor)"
    Say "  Intel Generation: $($profile.CPUGeneration)"
    Say "  Detected OS:      $($profile.OS)"
    Say "  Detected Vendor:  $($profile.Vendor)"
    Say "  Detected MT:      $($profile.MachineType)"

    # ---- reagentc /info (raw) ----
    Say ""
    Say "--- reagentc /info (raw output) ---"
    $wreState = Get-WinREState
    foreach ($line in $wreState.RawInfo) { Say "  $line" }

    # ---- WinRE parsed state ----
    Say ""
    Say "--- WinRE state (parsed) ---"
    Say "  Status:   $($wreState.Status)"
    Say "  Location: $($wreState.Location)"

    $activePart = $null
    if ($wreState.Location) {
        $activePart = Resolve-WinRELocationToPartition -Location $wreState.Location
    }
    $osPart = Get-OSPartition
    $osDisk = Get-OSDisk

    if ($activePart) {
        Say "  Resolved to: Disk $($activePart.DiskNumber) Part $($activePart.PartitionNumber)"
        $isActiveOSPart = ($osPart -and
                           $activePart.DiskNumber -eq $osPart.DiskNumber -and
                           $activePart.PartitionNumber -eq $osPart.PartitionNumber)
        $isRec = ($activePart.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}') -or ($activePart.MbrType -eq 0x27)
        if (-not $isRec) {
            try {
                $v = Get-Volume -Partition $activePart -ErrorAction SilentlyContinue
                if ($v -and ($v.FileSystemLabel -eq 'Recovery' -or $v.FileSystemLabel -eq 'WINRE')) { $isRec = $true }
            } catch { }
        }
        # v7: mirror the v43 patch 2 production classifier. DEDICATED is
        # only the healthy end state when the reagentc-registered
        # recovery partition is on the OS disk. A recovery partition on
        # a non-OS disk (historically produced by Windows updates, disk
        # migrations, or manual reagentc operations) does not take the
        # idempotent fast path under v43 patch 2 - the production script
        # runs the full-update path, redeploys the WIM to the OS disk,
        # re-registers reagentc there, and only then lets Step 7 remove
        # the stray secondary-disk partition. Reporting DEDICATED for
        # that state would mislead a field tech into thinking no work is
        # needed.
        $isActiveOSDisk = ($osPart -and $activePart.DiskNumber -eq $osPart.DiskNumber)
        if ($isActiveOSPart) {
            Say "  Classification: OS-fallback (WinRE is on the OS partition)"
        } elseif ($isRec -and $isActiveOSDisk) {
            Say "  Classification: DEDICATED (WinRE on dedicated recovery partition on the OS disk)"
        } elseif ($isRec) {
            Say "  Classification: RECOVERY-ON-SECONDARY (WinRE is on a recovery partition not on the OS disk - v43 patch 2 classifier forces a full rebuild)"
        } else {
            Say "  Classification: UNEXPECTED (WinRE is on neither the OS partition nor a recovery partition)"
        }
    } else {
        Say "  Resolved to: (could not resolve location to a partition)"
    }

    # ---- OS partition / OS disk ----
    Say ""
    Say "--- OS partition / OS disk ---"
    if ($osPart) {
        Say "  OS partition: Disk $($osPart.DiskNumber) Part $($osPart.PartitionNumber), $([math]::Round($osPart.Size/1MB,1)) MiB, letter=$($osPart.DriveLetter)"
    } else {
        Say "  OS partition: (could not resolve)"
    }
    if ($osDisk) {
        Say "  OS disk: Disk $($osDisk.Number) '$($osDisk.FriendlyName)' style=$($osDisk.PartitionStyle)"
    } else {
        Say "  OS disk: (could not resolve)"
    }

    # ---- All disks ----
    Say ""
    Say "--- All disks ---"
    foreach ($d in Get-Disk | Sort-Object Number) {
        Say ("  Disk {0}: {1,-30} | {2,-5} | {3,8:N2} GiB | BootFromDisk={4} | IsSystem={5} | IsBoot={6}" -f `
            $d.Number, $d.FriendlyName, $d.PartitionStyle, ($d.Size/1GB), $d.BootFromDisk, $d.IsSystem, $d.IsBoot)
    }

    # ---- All partitions ----
    Say ""
    Say "--- All partitions ---"
    foreach ($p in Get-Partition | Sort-Object DiskNumber, PartitionNumber) {
        $letter = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { "(none)" }
        $label = ""
        try {
            $v = Get-Volume -Partition $p -ErrorAction SilentlyContinue
            if ($v) { $label = $v.FileSystemLabel }
        } catch { }
        Say ("  Disk {0} Part {1}: {2,8:N1} MiB | {3,-5} | label='{4}' | GptType={5} | MbrType={6} | IsBoot={7} | IsSystem={8} | IsActive={9}" -f `
            $p.DiskNumber, $p.PartitionNumber, ($p.Size/1MB), $letter, $label, $p.GptType, $p.MbrType, $p.IsBoot, $p.IsSystem, $p.IsActive)
    }

    # ---- All volumes ----
    Say ""
    Say "--- All volumes ---"
    foreach ($v in Get-Volume | Sort-Object DriveLetter) {
        $dl = if ($v.DriveLetter) { "$($v.DriveLetter):" } else { "(none)" }
        Say ("  {0,-5} | {1,-8} | {2,8:N1} MiB free / {3,8:N1} MiB total | '{4}' | {5} | Health={6}" -f `
            $dl, $v.FileSystem, ($v.SizeRemaining/1MB), ($v.Size/1MB), $v.FileSystemLabel, $v.DriveType, $v.HealthStatus)
    }

    # ---- Recovery partitions with type-vs-label breakdown ----
    Say ""
    Say "--- Recovery partitions (per Get-RecoveryPartitions) ---"
    $recParts = @(Get-RecoveryPartitions)
    if ($recParts.Count -eq 0) {
        Say "  (none found)"
    } else {
        foreach ($rp in $recParts) {
            $isTyped = ($rp.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}') -or ($rp.MbrType -eq 0x27)
            $isLabel = $false
            try {
                $v = Get-Volume -Partition $rp -ErrorAction SilentlyContinue
                if ($v -and ($v.FileSystemLabel -eq 'Recovery' -or $v.FileSystemLabel -eq 'WINRE')) { $isLabel = $true }
            } catch { }
            $onOsDisk = ($osDisk -and $rp.DiskNumber -eq $osDisk.Number)
            Say ("  Disk {0} Part {1}: {2,8:N1} MiB | isTyped={3} | isLabel={4} | onOsDisk={5}" -f `
                $rp.DiskNumber, $rp.PartitionNumber, ($rp.Size/1MB), $isTyped, $isLabel, $onOsDisk)
        }
    }

    # ---- OS partition supported sizes ----
    Say ""
    Say "--- OS partition supported sizes (Get-PartitionSupportedSize) ---"
    if ($osPart) {
        try {
            $supported = Get-PartitionSupportedSize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber
            $size = [int64]$osPart.Size
            $min  = [int64]$supported.SizeMin
            $max  = [int64]$supported.SizeMax
            Say ("  Current:    {0,10:N1} MiB" -f ($size/1MB))
            Say ("  SizeMin:    {0,10:N1} MiB" -f ($min/1MB))
            Say ("  SizeMax:    {0,10:N1} MiB" -f ($max/1MB))
            Say ("  Shrinkable: {0,10:N1} MiB" -f (($size - $min)/1MB))
            Say ("  Extendable: {0,10:N1} MiB" -f (($max - $size)/1MB))
            Say ("  S == M (at min): {0}" -f ($size -eq $min))
        } catch {
            Say "  (could not query: $_)"
        }
    } else {
        Say "  (no OS partition)"
    }

    # ---- v42 bucket sizing preview ----
    Say ""
    Say "--- Bucket sizing preview (WIM + 250 + 30, round up to 100, min 1000) ---"
    $activeWimPath = $null
    $activeWimSize = 0
    if ($wreState.Location) {
        $locationBase = $wreState.Location.TrimEnd('\')
        $cand = "$locationBase\Recovery\WindowsRE\winre.wim"
        if (Test-Path -LiteralPath $cand) {
            try {
                $activeWimPath = $cand
                $activeWimSize = (Get-Item -LiteralPath $cand -Force).Length
            } catch { }
        }
    }
    if ($activeWimPath) {
        $wimMiB = [math]::Round($activeWimSize / 1MB, 1)
        $needed = $wimMiB + 250 + 30
        $bucket = [int]([Math]::Ceiling($needed / 100) * 100)
        if ($bucket -lt 1000) { $bucket = 1000 }
        Say "  Active WIM:   $activeWimPath"
        Say "  WIM size:     $wimMiB MiB"
        Say "  Required:     $needed MiB"
        Say "  Bucket size:  $bucket MiB"
    } else {
        Say "  (could not read active WIM at the reagentc-registered location)"
    }

    # ---- Windows Setup state (Audit Mode / OOBE guard) ----
    # v13: mirrors the production v43 patch 5 (further revision)
    # startup guard. During Audit Mode, OOBE, and the sysprep
    # generalize/specialize phases, Windows blocks reagentc /enable
    # with ERROR_CANCELLED (0x4c7, 1223) regardless of WIM
    # correctness. Production refuses to run destructive partition
    # work in those states. A diagnostic that reported every other
    # subsystem as healthy while production would defer would be
    # misleading on a machine whose only problem is that it has not
    # finished OOBE.
    Say ""
    Say "--- Windows Setup state ---"
    $setupStatePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State"
    $imageState = $null
    try {
        $imageState = (Get-ItemProperty -Path $setupStatePath -Name ImageState -ErrorAction SilentlyContinue).ImageState
    } catch { }
    if ($imageState) {
        Say "  ImageState: $imageState"
        if ($imageState -ne "IMAGE_STATE_COMPLETE") {
            Say ""
            Say "  WARNING: ImageState=$imageState." -Level WARN
            Say "           Windows is not in a normal-running state. Production v43 patch 5" -Level WARN
            Say "           (further revision) refuses to run destructive partition work in" -Level WARN
            Say "           this state, because reagentc /enable is blocked with 0x4c7 during" -Level WARN
            Say "           Audit Mode, OOBE, and the sysprep generalize/specialize phases." -Level WARN
            Say "           Complete OOBE, sign in to a normal desktop session, then re-run." -Level WARN
        }
    } else {
        Say "  ImageState: (not present)"
        Say "  Some SKUs omit the Setup\State key. Production treats this as safe."
    }

    # ---- BitLocker on C: ----
    Say ""
    Say "--- BitLocker (C:) ---"
    try {
        $blv = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
        if ($blv) {
            Say "  ProtectionStatus: $($blv.ProtectionStatus)"
            Say "  VolumeStatus:     $($blv.VolumeStatus)"
            Say "  EncryptionMethod: $($blv.EncryptionMethod)"
            Say "  EncryptionPct:    $($blv.EncryptionPercentage)"

            # v12: flag the Device Encryption in-progress hazard. The
            # hazard check must match production's
            # post-patch-5 semantics. The confirmed-safe VolumeStatus
            # values, when ProtectionStatus is Off, are FullyDecrypted
            # (never encrypted, or decryption finished) and FullyEncrypted
            # (volume is fully encrypted but protection is Off - the normal
            # suspended state after Suspend-BitLocker or a Windows Update
            # suspension that has not yet been lifted). Only the
            # mid-operation states - EncryptionInProgress,
            # DecryptionInProgress, EncryptionPaused, DecryptionPaused -
            # are hazardous. The previous check treated FullyEncrypted as
            # a hazard, which produced a false positive on every machine
            # with suspended BitLocker and told the operator to wait for a
            # state that a suspended machine will never reach on its own.
            $vs = [string]$blv.VolumeStatus
            $hazardous = $false
            $ambiguous = $false
            if ($blv.ProtectionStatus -ne 'On' -and $vs) {
                switch ($vs) {
                    'FullyDecrypted'       { $hazardous = $false }
                    'FullyEncrypted'       { $ambiguous = $true }   # v43 patch 5 (further revision)
                    'EncryptionInProgress' { $hazardous = $true }
                    'DecryptionInProgress' { $hazardous = $true }
                    'EncryptionPaused'     { $hazardous = $true }
                    'DecryptionPaused'     { $hazardous = $true }
                    default                { $hazardous = $false }
                }
            }
            if ($hazardous) {
                Say ""
                Say "  WARNING: ProtectionStatus=$($blv.ProtectionStatus) but VolumeStatus=$vs." -Level WARN
                Say "           Device Encryption is actively encrypting or decrypting the OS volume." -Level WARN
                Say "           Production v43 patch 5 will refuse destructive partition work in this state." -Level WARN
                Say "           Wait until VolumeStatus=FullyDecrypted, or VolumeStatus=FullyEncrypted with ProtectionStatus=On." -Level WARN
            }
            if ($ambiguous) {
                Say ""
                Say "  WARNING: ProtectionStatus=$($blv.ProtectionStatus) with VolumeStatus=$vs." -Level WARN
                Say "           This state is ambiguous: legitimate suspension, OR Device Encryption" -Level WARN
                Say "           Waiting-for-Activation. Production v43 patch 5 refuses destructive" -Level WARN
                Say "           partition work in this state. Resolve by waiting for either" -Level WARN
                Say "           ProtectionStatus=On (protection re-armed) or VolumeStatus=FullyDecrypted." -Level WARN
            }
        } else {
            Say "  Get-BitLockerVolume returned null (module not loaded, cmdlet failed, or requires elevation)"
        }
    } catch {
        Say "  Get-BitLockerVolume failed: $_"
    }

    # ---- VMD hardware presence ----
    Say ""
    Say "--- VMD hardware presence (per driver manifest) ---"
    try {
        $man = Invoke-RestMethod -Uri $DriverManifestUrl -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop
        $vmdIds = @($man.drivers | Where-Object { $_.match.requiredDevices } | ForEach-Object { $_.match.requiredDevices })
        if ($vmdIds.Count -gt 0) {
            $pattern = ($vmdIds | ForEach-Object { [regex]::Escape($_) }) -join '|'
            $vmdMatches = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match $pattern })
            Say "  Manifest VMD device IDs: $($vmdIds -join ', ')"
            Say "  Matching PnP devices:    $($vmdMatches.Count)"
            foreach ($m in $vmdMatches) { Say "    $($m.InstanceId)" }
        } else {
            Say "  (manifest has no VMD device IDs)"
        }
    } catch {
        Say "  (manifest fetch failed: $_)"
    }

    # ---- Parser self-test ----
    # v5: verify that every extractor and API dependency v43 relies on
    # still produces the shape we expect. Each check records PASS, FAIL,
    # or SKIP in $Script:Results, so the results summary shows whether
    # this machine's Windows tooling still matches v43's assumptions. A
    # FAIL here means the production script may silently misclassify
    # state on this machine and must be adapted. A SKIP means the check
    # could not run in the current context (typically: not elevated, or
    # the state it inspects is absent) and does not indicate a defect.
    #
    # v7: none of the checks were affected by v43 patch 2 (classifier
    # OS-disk gate, WIM hash gate, geometry-restore flag, count=0
    # exemption gate, state-file deletion). Those patches are
    # production-only logic; the harness does not exercise them. The
    # banner is updated only so the diagnostic's version claim matches
    # the harness's own docstring.
    Say ""
    Say "--- Parser self-test (v43 dependency verification) ---"

    # Check 1: reagentc /info status regex
    $statusPattern = '(Enabled|Disabled)'
    $statusHits = @($wreState.RawInfo | Select-String -Pattern $statusPattern)
    if ($statusHits.Count -gt 0) {
        $matched = ($statusHits | Select-Object -First 1).Matches.Value
        Say "  [OK]   reagentc status regex '$statusPattern' matched '$matched'"
        Record "Parser: reagentc status" $true "matched '$matched'"
    } else {
        Say "  [FAIL] reagentc status regex '$statusPattern' did not match any line"
        Record "Parser: reagentc status" $false "no match"
    }

    # Check 2: reagentc /info location regex
    $locPattern = '(\\\\\?\\GLOBALROOT\\device\\harddisk\d+\\partition\d+\\|\\\\\?\\Volume\{[a-fA-F0-9\-]+\}\\?)'
    $locHits = @($wreState.RawInfo | Select-String -Pattern $locPattern)
    if ($locHits.Count -gt 0) {
        $matched = ($locHits | Select-Object -First 1).Matches.Value.Trim()
        Say "  [OK]   reagentc location regex matched '$matched'"
        Record "Parser: reagentc location" $true "matched '$matched'"
    } else {
        Say "  [FAIL] reagentc location regex did not match any line"
        Record "Parser: reagentc location" $false "no match"
    }

    # Checks 3 & 4: manage-bde -status C: raw dump and regex verification
    Say ""
    Say "  --- manage-bde -status C: raw output ---"
    try {
        $mboRaw = & manage-bde.exe -status "C:" 2>&1
        $mboText = ($mboRaw | Out-String)
        foreach ($line in $mboRaw) { Say "  $line" }

        # Protection On / Off
        $protOn  = $mboText -match 'Protection On'
        $protOff = $mboText -match 'Protection Off'
        if ($protOn -or $protOff) {
            $state = if ($protOn) { "On" } else { "Off" }
            Say "  [OK]   manage-bde protection regex matched 'Protection $state'"
            Record "Parser: manage-bde protection" $true "matched 'Protection $state'"
        } else {
            Say "  [FAIL] manage-bde protection regex: neither 'Protection On' nor 'Protection Off' present"
            Record "Parser: manage-bde protection" $false "no match"
        }

        # Conversion Status OR unmanaged-volume classification
        $convMatch = $mboText -match 'Conversion Status:\s*(Fully Decrypted|Fully Encrypted|Used Space Only Encrypted|Encryption In Progress|Decryption In Progress|Encryption Paused|Decryption Paused)'
        $unmanaged = $mboText -match 'could not be opened by BitLocker'
        if ($convMatch) {
            Say "  [OK]   manage-bde conversion status regex matched"
            Record "Parser: manage-bde conversion" $true "matched"
        } elseif ($unmanaged) {
            Say "  [OK]   manage-bde unmanaged-volume classification matched ('could not be opened by BitLocker')"
            Record "Parser: manage-bde conversion" $true "unmanaged-volume classification"
        } else {
            Say "  [FAIL] manage-bde conversion status regex: no match and no unmanaged-volume classification"
            Record "Parser: manage-bde conversion" $false "no match"
        }
    } catch {
        Say "  [FAIL] manage-bde invocation failed: $_"
        Record "Parser: manage-bde" $false "invocation failed: $_"
    }

    # Check 5: Get-BitLockerVolume shape
    if (-not $elevated) {
        Say "  [SKIP] Get-BitLockerVolume: requires elevation"
        Record "Parser: Get-BitLockerVolume shape" $false -State "SKIP" -Detail "not elevated"
    } else {
        try {
            $blvCheck = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
            if ($blvCheck -and $null -ne $blvCheck.ProtectionStatus -and $null -ne $blvCheck.VolumeStatus) {
                Say "  [OK]   Get-BitLockerVolume: ProtectionStatus and VolumeStatus present"
                Record "Parser: Get-BitLockerVolume shape" $true "ProtectionStatus=$($blvCheck.ProtectionStatus)"
            } else {
                Say "  [FAIL] Get-BitLockerVolume: missing ProtectionStatus or VolumeStatus"
                Record "Parser: Get-BitLockerVolume shape" $false "missing property"
            }
        } catch {
            Say "  [FAIL] Get-BitLockerVolume threw: $_"
            Record "Parser: Get-BitLockerVolume shape" $false "$_"
        }
    }

    # Check 6: OS partition and OS disk resolution
    if ($osPart -and $osDisk) {
        Say "  [OK]   OS resolution: Disk $($osDisk.Number), partition $($osPart.PartitionNumber)"
        Record "Parser: OS resolution" $true "Disk $($osDisk.Number)/Part $($osPart.PartitionNumber)"
    } else {
        Say "  [FAIL] OS resolution: Get-OSPartition or Get-OSDisk could not resolve"
        Record "Parser: OS resolution" $false "no resolution"
    }

    # Check 7: Get-Partition shape
    try {
        $samplePart = Get-Partition -ErrorAction Stop | Select-Object -First 1
        if ($samplePart) {
            $requiredProps = @("DiskNumber", "PartitionNumber", "Size", "GptType", "MbrType", "IsBoot", "IsSystem", "IsActive")
            $missing = @()
            foreach ($prop in $requiredProps) {
                if ($null -eq $samplePart.PSObject.Properties[$prop]) { $missing += $prop }
            }
            if ($missing.Count -eq 0) {
                Say "  [OK]   Get-Partition exposes all expected properties"
                Record "Parser: Get-Partition shape" $true "all properties present"
            } else {
                Say "  [FAIL] Get-Partition missing properties: $($missing -join ', ')"
                Record "Parser: Get-Partition shape" $false "missing: $($missing -join ', ')"
            }
        } else {
            Say "  [FAIL] Get-Partition returned no partitions"
            Record "Parser: Get-Partition shape" $false "no partitions"
        }
    } catch {
        Say "  [FAIL] Get-Partition threw: $_"
        Record "Parser: Get-Partition shape" $false "$_"
    }

    # Check 8: WinRE location resolution
    if ($wreState.Location) {
        $resolved = Resolve-WinRELocationToPartition -Location $wreState.Location
        if ($resolved) {
            Say "  [OK]   WinRE location resolves to Disk $($resolved.DiskNumber) Part $($resolved.PartitionNumber)"
            Record "Parser: WinRE location resolution" $true "Disk $($resolved.DiskNumber)/Part $($resolved.PartitionNumber)"
        } else {
            Say "  [FAIL] WinRE location '$($wreState.Location)' could not be resolved to a partition"
            Record "Parser: WinRE location resolution" $false "no resolution"
        }
    } else {
        Say "  [SKIP] WinRE location is empty"
        Record "Parser: WinRE location resolution" $false -State "SKIP" -Detail "empty location (expected on some machines)"
    }

    # Check 9: Get-RecoveryPartitions returns at least one partition
    $recPartsCheck = @(Get-RecoveryPartitions)
    if ($recPartsCheck.Count -ge 1) {
        Say "  [OK]   Get-RecoveryPartitions: found $($recPartsCheck.Count) partition(s)"
        Record "Parser: Get-RecoveryPartitions" $true "$($recPartsCheck.Count) found"
    } else {
        Say "  [FAIL] Get-RecoveryPartitions: found 0 partitions"
        Record "Parser: Get-RecoveryPartitions" $false "0 found"
    }

    # Check 10: Get-PartitionSupportedSize
    if ($osPart) {
        try {
            $supportedCheck = Get-PartitionSupportedSize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber -ErrorAction Stop
            if ($null -ne $supportedCheck.SizeMin -and $null -ne $supportedCheck.SizeMax) {
                $minMiB = [math]::Round($supportedCheck.SizeMin / 1MB, 0)
                $maxMiB = [math]::Round($supportedCheck.SizeMax / 1MB, 0)
                Say "  [OK]   Get-PartitionSupportedSize: SizeMin=${minMiB}M SizeMax=${maxMiB}M"
                Record "Parser: Get-PartitionSupportedSize" $true "min=${minMiB}M max=${maxMiB}M"
            } else {
                Say "  [FAIL] Get-PartitionSupportedSize: SizeMin or SizeMax missing"
                Record "Parser: Get-PartitionSupportedSize" $false "missing property"
            }
        } catch {
            Say "  [FAIL] Get-PartitionSupportedSize threw: $_"
            Record "Parser: Get-PartitionSupportedSize" $false "$_"
        }
    } else {
        Say "  [SKIP] Get-PartitionSupportedSize: no OS partition"
        Record "Parser: Get-PartitionSupportedSize" $false -State "SKIP" -Detail "no OS partition"
    }

    Say ""
    Say "Diagnostic complete. Parser self-test results are in the summary."
}

# =========================== OEM PROVIDERS (based on WinRE.ps1) ===========================
function Get-DellWinPEPack {
    param($Hardware)
    if (-not $Script:DellWinPEMap) {
        Say "Downloading Dell WinPE map from gist"
        for ($retry = 1; $retry -le 3; $retry++) {
            try { $Script:DellWinPEMap = Invoke-RestMethod -Uri $DellWinPEMapUrl -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop; break }
            catch { Say "Dell map download attempt $retry failed: $_" -Level WARN; if ($retry -lt 3) { Start-Sleep 5 } }
        }
        if (-not $Script:DellWinPEMap) {
            Say "Could not download Dell WinPE map" -Level WARN
            return $null
        }
        Say "Dell WinPE map loaded ($(@($Script:DellWinPEMap.Packs.PSObject.Properties).Count) pack entries)"
    }
    $key = if ($Hardware.IsWin11) { "WinPE11" } else { "WinPE10" }
    $entry = $Script:DellWinPEMap.Packs.$key
    if (-not $entry) {
        Say "Dell map has no entry for $key" -Level WARN
        return $null
    }
    Say "Dell map resolved $key -> $($entry.dellVersion)"
    [PSCustomObject]@{ Manufacturer = "Dell"; Name = "Dell $($entry.dellVersion)"; Version = $entry.dellVersion; DownloadUrl = $entry.url; ArchiveType = "CAB"; IsUrl = $true; ExpectedMD5 = $entry.md5; ExpectedSHA256 = $entry.sha256 }
}

function Get-HPWinPEPack {
    param($Hardware)
    if (-not $Script:HPWinPEMap) {
        Say "Downloading HP WinPE map from gist"
        for ($retry = 1; $retry -le 3; $retry++) {
            try { $Script:HPWinPEMap = Invoke-RestMethod -Uri $HPWinPEMapUrl -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop; break }
            catch { Say "HP map download attempt $retry failed: $_" -Level WARN; if ($retry -lt 3) { Start-Sleep 5 } }
        }
        if (-not $Script:HPWinPEMap) {
            Say "Could not download HP WinPE map" -Level WARN
            return $null
        }
        Say "HP WinPE map loaded ($(@($Script:HPWinPEMap.Packs.PSObject.Properties).Count) pack entries)"
    }
    $entry = $Script:HPWinPEMap.Packs.WinPE1011
    if (-not $entry) {
        Say "HP map has no WinPE1011 entry" -Level WARN
        return $null
    }
    Say "HP map resolved WinPE1011 -> $($entry.softPaqId) v$($entry.version)"
    [PSCustomObject]@{ Manufacturer = "HP"; Name = "HP $($entry.softPaqId)"; Version = $entry.version; DownloadUrl = $entry.url; ArchiveType = "SoftPaq"; IsUrl = $true; ExpectedMD5 = $null; ExpectedSHA256 = $null }
}

function Get-LenovoWinPEPack {
    param($Hardware)
    $mt = $Hardware.MachineType
    if (-not $mt -or $mt -eq 'UNKN') {
        Say "Lenovo WinPE map: cannot resolve - machine type unknown" -Level WARN
        return $null
    }
    if (-not $Script:LenovoWinPEMap) {
        Say "Downloading Lenovo WinPE map from gist"
        for ($retry = 1; $retry -le 3; $retry++) {
            try { $Script:LenovoWinPEMap = Invoke-RestMethod -Uri $LenovoWinPEMapUrl -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop; break }
            catch { Say "Lenovo map download attempt $retry failed: $_" -Level WARN; if ($retry -lt 3) { Start-Sleep 5 } }
        }
        if (-not $Script:LenovoWinPEMap) {
            Say "Could not download Lenovo WinPE map" -Level WARN
            return $null
        }
        Say "Lenovo WinPE map loaded ($(@($Script:LenovoWinPEMap.Models.PSObject.Properties).Count) model entries)"
    }
    $entry = $Script:LenovoWinPEMap.Models.$mt
    if (-not $entry) {
        Say "No WinPE pack in Lenovo map for machine type $mt" -Level WARN
        return $null
    }
    $winpe = $entry.winpe
    if (-not $winpe -or -not $winpe.url) {
        Say "Lenovo map entry for $mt has no WinPE URL" -Level WARN
        return $null
    }
    Say "Lenovo map resolved $mt -> $($winpe.name) (SHA256: $($winpe.sha256))"
    [PSCustomObject]@{ Manufacturer = "LENOVO"; Name = $winpe.name; Version = $winpe.dsId; DownloadUrl = $winpe.url; ArchiveType = "EXE"; IsUrl = $true; ExpectedMD5 = $null; ExpectedSHA256 = $winpe.sha256 }
}

# =========================== TESTS ===========================
function Test-DriverManifest {
    Rule "Driver manifest fetch"
    try {
        $m = Invoke-RestMethod -Uri $DriverManifestUrl -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop
        if (-not $m -or -not $m.version) { throw "Manifest missing version field" }
        Say "Manifest fetched. version=$($m.version)"
        $driverCount = 0
        if ($m.drivers) {
            $driverCount = @($m.drivers).Count
            Say "Manifest lists $driverCount driver entries"
            foreach ($d in $m.drivers) {
                $reqDev = if ($d.match.requiredDevices) { ($d.match.requiredDevices -join ',') } else { '(none)' }
                Say "  $($d.name)  os=[$($d.os -join ',')]  cpuGen=$($d.match.cpuGenMin)-$($d.match.cpuGenMax)  vmdDevices=$reqDev  url=$($d.driverUrl)"
            }
        }
        Record "Driver manifest" $true "version=$($m.version) drivers=$driverCount"
        return $true
    } catch {
        Say "Failed: $_" -Level ERROR
        Record "Driver manifest" $false "$_"
        return $false
    }
}

function Test-OemMaps {
    Rule "OEM maps fetch"
    $profile = Get-ThisMachineProfile
    $fakeHardware = [PSCustomObject]@{
        IsWin11     = ($profile.OS -eq 'Win11')
        MachineType = $profile.MachineType
    }
    $ok = $true

    $d = Get-DellWinPEPack -Hardware $fakeHardware
    if ($d) {
        Say "Dell: Name=$($d.Name) Version=$($d.Version) ArchiveType=$($d.ArchiveType)"
        Say "Dell: URL=$($d.DownloadUrl)"
        Say "Dell: SHA256=$($d.ExpectedSHA256) MD5=$($d.ExpectedMD5)"
    } else { $ok = $false }

    $h = Get-HPWinPEPack -Hardware $fakeHardware
    if ($h) {
        Say "HP: Name=$($h.Name) Version=$($h.Version) ArchiveType=$($h.ArchiveType)"
        Say "HP: URL=$($h.DownloadUrl)"
        Say "HP: SHA256=$($h.ExpectedSHA256) MD5=$($h.ExpectedMD5)"
    } else { $ok = $false }

    $l = Get-LenovoWinPEPack -Hardware $fakeHardware
    if ($l) {
        Say "Lenovo: Name=$($l.Name) Version=$($l.Version) ArchiveType=$($l.ArchiveType)"
        Say "Lenovo: URL=$($l.DownloadUrl)"
        Say "Lenovo: SHA256=$($l.ExpectedSHA256)"
    } elseif ($profile.Vendor -eq 'Lenovo') {
        $ok = $false
    } else {
        Say "Lenovo map skipped (machine type not applicable)" -Level WARN
    }

    Record "OEM maps" $ok
    return $ok
}

function Test-GitHubBaseWim {
    param([ValidateSet("Win10","Win11")][string]$OS)
    Rule "GitHub base WIM - $OS"
    $dir = New-TestDir "github_$OS"
    $apiUrl = "$BaseWinRERepoApi/$OS"
    try {
        $files = Invoke-RestMethod -Uri $apiUrl -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop
    } catch {
        Say "Failed to list $OS folder: $_" -Level ERROR
        Record "GitHub base WIM ($OS)" $false "listing failed"
        return $false
    }
    $parts = @($files | Where-Object { $_.name -match '^[Ww]inre\.7z\.\d+$' } | Sort-Object name)
    if ($parts.Count -eq 0) {
        Say "No winre.7z.NNN parts found in $OS folder" -Level ERROR
        Record "GitHub base WIM ($OS)" $false "no parts"
        return $false
    }
    Say "Found $($parts.Count) part file(s): $($parts.name -join ', ')"

    $downloaded = @()
    foreach ($p in $parts) {
        $dest = Join-Path $dir $p.name
        Say "Downloading $($p.name) ($([math]::Round($p.size/1MB,2)) MiB)"
        try {
            Invoke-WebRequest -Uri $p.download_url -OutFile $dest -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop
            $downloaded += $dest
        } catch {
            Say "Failed to download $($p.name): $_" -Level ERROR
            Record "GitHub base WIM ($OS)" $false "download failed on $($p.name)"
            return $false
        }
    }

    Say "All parts downloaded. Extracting $($parts[0].name) (7-Zip auto-detects sibling parts)..."
    try {
        $proc = Start-Process -FilePath $7Zip -ArgumentList @("x", "`"$($downloaded[0])`"", "-o`"$dir`"", "-y") -Wait -PassThru -NoNewWindow -ErrorAction Stop
        Say "7-Zip exit code: $($proc.ExitCode)"
        if ($proc.ExitCode -ne 0) {
            Record "GitHub base WIM ($OS)" $false "7-Zip exit $($proc.ExitCode)"
            return $false
        }
    } catch {
        Say "7-Zip failed: $_" -Level ERROR
        Record "GitHub base WIM ($OS)" $false "7-Zip extraction failed"
        return $false
    }

    $wim = Join-Path $dir "winre.wim"
    if (-not (Test-Path $wim)) {
        Say "winre.wim not produced" -Level ERROR
        Record "GitHub base WIM ($OS)" $false "no wim produced"
        return $false
    }
    $sz = (Get-Item $wim -Force).Length
    Say ("winre.wim present: {0:N2} MiB" -f ($sz / 1MB))

    $buildOk = $true
    $detail = "size=$([math]::Round($sz/1MB,2))MiB"
    try {
        $b = (Get-WindowsImage -ImagePath $wim -Index 1 -ErrorAction Stop).Build
        Say "WIM ImageBuild: $b"
        if ($OS -eq "Win11" -and [int]$b -lt 22000) {
            Say "MISMATCH: folder is Win11 but WIM build is $b (< 22000)" -Level ERROR
            $buildOk = $false
        } elseif ($OS -eq "Win10" -and [int]$b -ge 22000) {
            Say "MISMATCH: folder is Win10 but WIM build is $b (>= 22000)" -Level ERROR
            $buildOk = $false
        }
        $detail = "$detail build=$b"
    } catch {
        # v11: inability to read the WIM build must not be reported as
        # a pass. The whole point of this check is to validate the
        # build against the folder it was pulled from. If Get-WindowsImage
        # fails, the validation never happened. Recording FAIL matches
        # the harness's semantics for checks that could not produce
        # their evidence.
        Say "Could not read WIM build: $_" -Level ERROR
        $buildOk = $false
        $detail = "$detail (build read failed)"
    }

    Record "GitHub base WIM ($OS)" $buildOk $detail
    return $buildOk
}

function Test-HPPack {
    Rule "HP WinPE pack"
    $profile = Get-ThisMachineProfile
    $pack = Get-HPWinPEPack -Hardware $profile
    if (-not $pack) { Record "HP pack" $false "map resolution failed"; return $false }

    $dir = New-TestDir "hp_$($pack.Version)"
    $exe = Join-Path $dir (Get-DownloadFileName -Url $pack.DownloadUrl)
    Say "URL: $($pack.DownloadUrl)"
    if (-not (Invoke-OemPackDownload -Url $pack.DownloadUrl -DestinationPath $exe -ExpectedSHA256 $pack.ExpectedSHA256 -ExpectedMD5 $pack.ExpectedMD5)) {
        Record "HP pack" $false "download failed"; return $false
    }
    $extract = Join-Path $dir "extract"
    $ok = Invoke-VendorExtraction -ExePath $exe -DestinationDir $extract -Vendor "HP"
    $inf = Get-InfFileCount -Directory $extract
    Record "HP pack" $ok "inf=$inf"
    return $ok
}

function Test-DellPack {
    param([ValidateSet("WinPE10","WinPE11")][string]$Key)
    Rule "Dell WinPE pack - $Key"
    if (-not $Script:DellWinPEMap) { [void](Get-DellWinPEPack -Hardware ([PSCustomObject]@{ IsWin11 = ($Key -eq 'WinPE11'); MachineType = $null })) }
    if (-not $Script:DellWinPEMap) { Record "Dell $Key" $false "map unavailable"; return $false }

    $entry = $Script:DellWinPEMap.Packs.$Key
    if (-not $entry) { Say "No $Key key" -Level ERROR; Record "Dell $Key" $false "no key"; return $false }

    $pack = [PSCustomObject]@{
        Manufacturer   = "Dell"
        Name           = "Dell $($entry.dellVersion)"
        Version        = $entry.dellVersion
        DownloadUrl    = $entry.url
        ArchiveType    = "CAB"
        ExpectedMD5    = $entry.md5
        ExpectedSHA256 = $entry.sha256
    }
    $dir = New-TestDir "dell_$Key"
    $cab = Join-Path $dir (Get-DownloadFileName -Url $pack.DownloadUrl)
    Say "URL: $($pack.DownloadUrl)"
    if (-not (Invoke-OemPackDownload -Url $pack.DownloadUrl -DestinationPath $cab -ExpectedSHA256 $pack.ExpectedSHA256 -ExpectedMD5 $pack.ExpectedMD5)) {
        Record "Dell $Key" $false "download failed"; return $false
    }
    $extract = Join-Path $dir "extract"
    $ok = Invoke-CabExtraction -CabPath $cab -DestinationDir $extract
    $inf = Get-InfFileCount -Directory $extract
    Record "Dell $Key" $ok "inf=$inf"
    return $ok
}

function Test-LenovoPack {
    param([string]$MachineType)
    Rule "Lenovo WinPE pack - MT=$MachineType"
    if (-not $Script:LenovoWinPEMap) {
        [void](Get-LenovoWinPEPack -Hardware ([PSCustomObject]@{ IsWin11 = $true; MachineType = $MachineType }))
    }
    if (-not $Script:LenovoWinPEMap) { Record "Lenovo $MachineType" $false "map unavailable"; return $false }

    $entry = $null
    if ($Script:LenovoWinPEMap.Models.PSObject.Properties.Name -contains $MachineType) { $entry = $Script:LenovoWinPEMap.Models.$MachineType }
    else {
        $cand = $Script:LenovoWinPEMap.Models.PSObject.Properties | Where-Object { $_.Name -ieq $MachineType } | Select-Object -First 1
        if ($cand) { $entry = $cand.Value }
    }
    if (-not $entry) {
        Say "No entry for MT $MachineType in Lenovo map" -Level ERROR
        Record "Lenovo $MachineType" $false "MT not in map"
        return $false
    }
    $winpe = $entry.winpe
    if (-not $winpe -or -not $winpe.url) {
        Say "Map entry has no winpe.url" -Level ERROR
        Record "Lenovo $MachineType" $false "no winpe.url"
        return $false
    }
    Say "Resolved: $($winpe.name)  URL: $($winpe.url)"

    $dir = New-TestDir "lenovo_$MachineType"
    $exe = Join-Path $dir (Get-DownloadFileName -Url $winpe.url)
    if (-not (Invoke-OemPackDownload -Url $winpe.url -DestinationPath $exe -ExpectedSHA256 $winpe.sha256 -ExpectedMD5 $null)) {
        Record "Lenovo $MachineType" $false "download failed"; return $false
    }
    $extract = Join-Path $dir "extract"
    $ok = Invoke-VendorExtraction -ExePath $exe -DestinationDir $extract -Vendor "LENOVO"
    $inf = Get-InfFileCount -Directory $extract
    Record "Lenovo $MachineType" $ok "inf=$inf"
    return $ok
}

function Test-VmdDrivers {
    Rule "VMD drivers (per manifest, filtered for this machine)"
    try {
        $m = Invoke-RestMethod -Uri $DriverManifestUrl -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop
    } catch {
        Say "Manifest fetch failed: $_" -Level ERROR
        Record "VMD drivers" $false "manifest fetch failed"
        return $false
    }
    if (-not $m -or -not $m.drivers) {
        Record "VMD drivers" $false "no drivers in manifest"
        return $false
    }

    $profile = Get-ThisMachineProfile
    Say "Machine: OS=$($profile.OS) CPUVendor=$($profile.CPUVendor) CPUGen=$($profile.CPUGeneration)"
    if ($profile.CPUVendor -eq 'Intel' -and $null -eq $profile.CPUGeneration) {
        Say "WARNING: Intel CPU detected but generation could not be parsed. VMD driver matching will skip all manifest entries." -Level WARN
        Say "  Raw CPU string: $((Get-CimInstance Win32_Processor).Name)" -Level WARN
    }

    $relevant = @()
    foreach ($drv in $m.drivers) {
        $osMatch = ($profile.OS -eq 'Win10' -and $drv.os -contains 'Win10') -or ($profile.OS -eq 'Win11' -and $drv.os -contains 'Win11')
        if (-not $osMatch) { Say "Skipping $($drv.name): OS mismatch"; continue }
        if ($profile.CPUVendor -ne 'Intel') { Say "Skipping $($drv.name): not Intel hardware"; continue }
        if ($null -eq $profile.CPUGeneration) { Say "Skipping $($drv.name): CPU generation unknown"; continue }
        if ($profile.CPUGeneration -lt $drv.match.cpuGenMin -or $profile.CPUGeneration -gt $drv.match.cpuGenMax) {
            Say "Skipping $($drv.name): CPU gen $($profile.CPUGeneration) outside $($drv.match.cpuGenMin)-$($drv.match.cpuGenMax)"
            continue
        }
        $relevant += $drv
    }

    if ($relevant.Count -eq 0) {
        Say "No VMD drivers in manifest apply to this machine" -Level WARN
        Record "VMD drivers" $true "0 relevant"
        return $true
    }

    $allOk = $true
    foreach ($drv in $relevant) {
        Say "Testing VMD pack: $($drv.name)"
        $dir = New-TestDir "vmd_$($drv.name -replace '[^A-Za-z0-9_-]','_')"
        $archive = Join-Path $dir "driver.7z"
        try {
            Invoke-WebRequest -Uri $drv.driverUrl -OutFile $archive -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop
            Say "Downloaded $([math]::Round((Get-Item $archive).Length/1MB,2)) MiB"
        } catch {
            Say "Download failed: $_" -Level ERROR
            Record "VMD $($drv.name)" $false "download failed"
            $allOk = $false
            continue
        }
        $extract = Join-Path $dir "extract"
        New-DirectoryIfNotExists $extract
        try {
            $proc = Start-Process -FilePath $7Zip -ArgumentList @("x", "`"$archive`"", "-o`"$extract`"", "-y") -Wait -PassThru -NoNewWindow -ErrorAction Stop
            Say "7-Zip exit code: $($proc.ExitCode)"
        } catch {
            Say "7-Zip failed: $_" -Level ERROR
            Record "VMD $($drv.name)" $false "7-Zip failed"
            $allOk = $false
            continue
        }
        $infCount = Get-InfFileCount -Directory $extract
        Say "INF count: $infCount"
        $ok = ($proc.ExitCode -eq 0 -and $infCount -gt 0)
        Record "VMD $($drv.name)" $ok "inf=$infCount"
        if (-not $ok) { $allOk = $false }
    }
    return $allOk
}

# =========================== AGGREGATE RUNS ===========================
function Invoke-AllRelevant {
    $p = Get-ThisMachineProfile
    Rule "All relevant for this machine (OS=$($p.OS), Vendor=$($p.Vendor), CPUGen=$($p.CPUGeneration))"
    [void](Test-DriverManifest)
    [void](Test-OemMaps)
    [void](Test-GitHubBaseWim -OS $p.OS)
    switch ($p.Vendor) {
        'HP'     { [void](Test-HPPack) }
        'Dell'   {
            $dellKey = if ($p.OS -eq 'Win11') { 'WinPE11' } else { 'WinPE10' }
            [void](Test-DellPack -Key $dellKey)
        }
        'Lenovo' {
            if ($p.MachineType) { [void](Test-LenovoPack -MachineType $p.MachineType) }
            else { Say "Lenovo but no MT detected" -Level WARN }
        }
        default  { Say "No OEM vendor detected - skipping OEM pack tests" -Level WARN }
    }
    [void](Test-VmdDrivers)
}

function Invoke-All {
    [void](Test-DriverManifest)
    [void](Test-OemMaps)
    [void](Test-GitHubBaseWim -OS "Win10")
    [void](Test-GitHubBaseWim -OS "Win11")
    [void](Test-HPPack)
    [void](Test-DellPack -Key "WinPE10")
    [void](Test-DellPack -Key "WinPE11")
    $mt = Read-Host "Lenovo machine type to test (blank to skip)"
    if ($mt) { [void](Test-LenovoPack -MachineType $mt.Trim().ToUpper()) }
    [void](Test-VmdDrivers)
}

function Show-Summary {
    Rule "Results summary"
    if ($Script:Results.Count -eq 0) { Say "No tests run yet."; return }
    # Every record is produced by Record, which always sets a State
    # field. The three possible values are PASS, FAIL, and SKIP. No
    # fallback path is needed.
    foreach ($r in $Script:Results) {
        Say ("  [{0}] {1}  {2}" -f $r.State, $r.Test, $r.Detail)
    }
    $passed  = @($Script:Results | Where-Object { $_.State -eq "PASS" }).Count
    $failed  = @($Script:Results | Where-Object { $_.State -eq "FAIL" }).Count
    $skipped = @($Script:Results | Where-Object { $_.State -eq "SKIP" }).Count
    Say ""
    Say "Passed $passed, failed $failed, skipped $skipped (of $($Script:Results.Count))"
}

# =========================== MENU ===========================
function Show-Menu {
    Clear-Host
    Write-Host "WinRE Manager Test Harness (v13)"
    Write-Host ("Working directory: {0}" -f $TestDir)
    $p = Get-ThisMachineProfile
    Write-Host ("Detected: OS={0}  Vendor={1}  MT={2}  CPUVendor={3}  CPUGen={4}" -f $p.OS, $p.Vendor, $p.MachineType, $p.CPUVendor, $p.CPUGeneration)
    Write-Host ""
    Write-Host "  1. System diagnostic (read-only info gathering)"
    Write-Host "  2. Driver manifest fetch"
    Write-Host "  3. OEM maps fetch + resolve (Dell, HP, Lenovo)"
    Write-Host "  4. GitHub base WIM - Win10 (download + extract + build check)"
    Write-Host "  5. GitHub base WIM - Win11 (download + extract + build check)"
    Write-Host "  6. HP WinPE pack (download + extract)"
    Write-Host "  7. Dell WinPE pack (prompts for OS)"
    Write-Host "  8. Lenovo WinPE pack (prompts for MT)"
    Write-Host "  9. VMD drivers (per manifest, filtered for this machine)"
    Write-Host "  A. All relevant for this machine"
    Write-Host "  B. All of the above"
    Write-Host "  R. Print results summary"
    Write-Host "  Q. Quit"
    Write-Host ""
}

# =========================== ENTRY ===========================
New-Item -Path $TestDir -ItemType Directory -Force | Out-Null
Rule "WinRE Manager test harness v13"
Say "Working dir: $TestDir"
if (-not (Test-Path $7Zip)) { Say "7-Zip not found at $7Zip - extraction tests will fail" -Level WARN }

if ($NonInteractive) {
    Invoke-AllRelevant
    Show-Summary
    exit 0
}

# NOTE: PowerShell's `break` inside a switch terminates the switch, not the
# enclosing loop. To exit the while loop from a switch case we use a flag
# checked by the loop condition. This is why the previous version could not
# be quit with Q.
$quit = $false
while (-not $quit) {
    Show-Menu
    $choice = Read-Host "Select"
    $upper = $choice.Trim().ToUpper()
    switch ($upper) {
        "1" { Show-SystemDiagnostic }
        "2" { [void](Test-DriverManifest) }
        "3" { [void](Test-OemMaps) }
        "4" { [void](Test-GitHubBaseWim -OS "Win10") }
        "5" { [void](Test-GitHubBaseWim -OS "Win11") }
        "6" { [void](Test-HPPack) }
        "7" {
            $os = Read-Host "Dell OS (WinPE10 / WinPE11 / Both)"
            switch ($os.Trim().ToUpper()) {
                "WINPE10" { [void](Test-DellPack -Key "WinPE10") }
                "WINPE11" { [void](Test-DellPack -Key "WinPE11") }
                "BOTH"    { [void](Test-DellPack -Key "WinPE10"); [void](Test-DellPack -Key "WinPE11") }
                default   { Say "Unknown choice" -Level WARN }
            }
        }
        "8" {
            $mt = Read-Host "Lenovo machine type (e.g. 21L1)"
            if ($mt) { [void](Test-LenovoPack -MachineType $mt.Trim().ToUpper()) }
        }
        "9" { [void](Test-VmdDrivers) }
        "A" { Invoke-AllRelevant }
        "B" { Invoke-All }
        "R" { Show-Summary }
        "Q" { $quit = $true }
        default { Say "Unknown choice" -Level WARN }
    }
    if (-not $quit) {
        Write-Host ""
        [void](Read-Host "Press Enter to return to menu")
    }
}

Show-Summary
Write-Host ""

if (-not $Keep) {
    # NOTE: do not reuse $Keep (the switch parameter) as a local variable.
    # Assigning a string to a variable that holds [switch] throws a type
    # conversion error, and [switch] has no Trim method. Use a distinct name.
    $keepAnswer = Read-Host "Keep test artifacts in $TestDir ? (y/N)"
    if ($keepAnswer.Trim().ToLower() -ne "y") {
        Say "Removing $TestDir"
        try { Remove-Item $TestDir -Force -Recurse -ErrorAction SilentlyContinue } catch { }
    } else {
        Say "Kept: $TestDir"
    }
}
Say "Done."
