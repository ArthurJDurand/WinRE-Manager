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
    WinRE.ps1 functions. The harness substitutes Say for Write-Log
    and omits the production-only DryRun short-circuits in its
    download, extraction and directory helpers, because its purpose is
    to exercise the live paths. Get-ThisMachineProfile is a harness-
    specific read-only helper, not a verbatim copy of production's
    Get-HardwareObject. The harness does not execute any production
    main-flow logic (partition recreation, BitLocker preparation,
    state-file handling, checkpoint writes). The harness exercises the
    same download, extraction, and CPU-generation code paths as
    production within the scope of those shared helpers.

    Validated against v44 patch 2. The v44 DesiredStateId change (CPU
    vendor/generation and VMD presence added to the ID inputs) is
    exercised by menu option S, which recomputes the ID from the same
    inputs production uses and compares it to the on-disk state file.

    Does NOT modify WinRE, partitions, BitLocker, drive letters, or the
    state file. No admin required. All work is confined to $TestDir.

.PARAMETER TestDir
    Working directory. Default C:\Temp\WinRETest.

.PARAMETER Keep
    Do not offer to delete $TestDir on exit.

.PARAMETER NonInteractive
    Run "all relevant for this machine" once and exit.

.NOTES
    Version : 16

    v16 changes vs v15:
    1. Console output beautification. Say now colour-codes by level
       (INFO=Gray, WARN=Yellow, ERROR=Red, PASS=Green, FAIL=Red,
       SKIP=DarkGray). Rule prints a cyan title with a dimmed rule.
       New formatting helpers: Write-Diag for timestamp-free
       diagnostic output, Write-KV for aligned key/value pairs,
       Format-Size for auto-scaling byte sizes, Get-FreeSpaceColor
       for volume colour coding, and Get-PartitionTypeName for
       friendly GPT/MBR type labels.
    2. The System diagnostic (Option 1) now presents disks,
       partitions, and volumes as aligned tables instead of
       free-form lines. Volume rows are colour-coded by free space:
       Red below 5% or 3 GB, Yellow below 15% or 20 GB, Green
       otherwise. The OS partition and the reagentc-registered
       recovery partition stand out from the other rows.
    3. A prominent banner warns when free space on the OS volume is
       critical or low, with the exact figures and a short
       recommendation. Production may not be able to shrink C: to
       make room for a dedicated recovery partition when free space
       is very low.
    4. The WinRE classification verdict is colour-coded: DEDICATED
       and OS-fallback in Green, RECOVERY-ON-SECONDARY and
       UNEXPECTED in Yellow and Red respectively.
    5. The parser self-test result tags ([OK], [FAIL], [SKIP]) are
       colour-coded, and the results summary uses the same colour
       scheme for its state tags and totals.
    6. The state file parity check (Option S) colour-codes its
       verdict: DSI MATCH in Green, DSI MISMATCH in Yellow.
    7. The menu highlights the shortcut letter in Cyan so the
       available options stand out from their descriptions.
    8. Colour palette chosen for high contrast on the default
       Windows Terminal dark theme. Only Gray, DarkGray, Cyan,
       Green, Yellow, Red, Magenta, and White are used. No DarkBlue,
       DarkGreen, DarkRed, or Blue - those have poor contrast on
       dark backgrounds.

    v15 changes vs v14:
    1. Get-ThisMachineProfile aligned with production v44's
       Get-HardwareObject. Manufacturer normalization now matches
       production exactly (LENOVO uppercase, HP canonicalization,
       raw fallback for unrecognised manufacturers). Model is
       returned because the HW component of the DesiredStateId
       includes it, and OS detection now uses the Caption string
       rather than the build number.
    2. New Get-DesiredStateId: a mirror of production v44's
       function. Accepts an optional ProductionScriptVersion
       parameter so the harness can compute the ID under either
       the v43 or v44 input set for comparison.
    3. New Show-StateFileParity (menu option S).
    4. Test-OemMaps' Lenovo null-return handling now mirrors
       production v44's caller.
    5. Docstring's production-compatibility paragraph notes that
       the v44 DesiredStateId change is exercised by the new S
       menu option.
    6. Menu and entry banners updated to "v15".

    [Full historical change log for v1 through v14 elided in this
    excerpt; retained in the file on disk.]
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
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [string]$Color = ""
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    if (-not $Color) {
        $Color = switch ($Level) {
            "ERROR"  { "Red" }
            "FATAL"  { "Red" }
            "WARN"   { "Yellow" }
            "OK"     { "Green" }
            "PASS"   { "Green" }
            "FAIL"   { "Red" }
            "SKIP"   { "DarkGray" }
            "HEAD"   { "Cyan" }
            default  { "Gray" }
        }
    }
    Write-Host "$Timestamp [$Level] $Message" -ForegroundColor $Color
}

function Rule {
    param([string]$Title, [string]$Color = "Cyan")
    Write-Host ""
    $dashes = "-" * [Math]::Max(0, 74 - $Title.Length)
    Write-Host "--- " -NoNewline -ForegroundColor DarkGray
    Write-Host $Title -NoNewline -ForegroundColor $Color
    Write-Host " $dashes" -ForegroundColor DarkGray
}

# Timestamp-free, colour-driven output for diagnostic sections.
# Use this for anything that is read by a human rather than consumed
# programmatically: the timestamp prefix is noise inside tables and
# aligned key/value blocks.
function Write-Diag {
    param([string]$Message = "", [string]$Color = "Gray")
    if ($Message) {
        Write-Host $Message -ForegroundColor $Color
    } else {
        Write-Host ""
    }
}

# Aligned key/value pair. Key column is dimmed, value is colour-coded.
function Write-KV {
    param(
        [string]$Key,
        [string]$Value,
        [string]$ValueColor = "White",
        [int]$KeyWidth = 22
    )
    Write-Host "  " -NoNewline
    Write-Host $Key.PadRight($KeyWidth) -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor $ValueColor
}

# Auto-scaling byte size formatter. Chooses the largest unit that
# keeps the number above 1.
function Format-Size {
    param([int64]$Bytes)
    if ($Bytes -ge 1TB) { return ("{0:N2} TiB" -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ("{0:N2} GiB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N1} MiB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N1} KiB" -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

# Free-space colour coding.
#   Red    : below 5% OR below 3 GB
#   Yellow : below 15% OR below 20 GB
#   Green  : otherwise
# Returns $null for unknown totals so the caller can fall back to Gray.
function Get-FreeSpaceColor {
    param([int64]$Free, [int64]$Total)
    if ($Total -le 0) { return $null }
    $pct    = ($Free / $Total) * 100
    $freeGB = $Free / 1GB
    if ($pct -lt 5  -or $freeGB -lt 3)  { return "Red" }
    if ($pct -lt 15 -or $freeGB -lt 20) { return "Yellow" }
    return "Green"
}

function Get-FreeSpacePercent {
    param([int64]$Free, [int64]$Total)
    if ($Total -le 0) { return 0 }
    return [math]::Round(($Free / $Total) * 100, 1)
}

# Friendly partition-type labels so tables are readable without the
# reader having to memorise GPT GUIDs.
function Get-PartitionTypeName {
    param($Partition)
    $gpt = $Partition.GptType
    $mbr = $Partition.MbrType
    if ($gpt) {
        switch ($gpt) {
            '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' { return 'EFI' }
            '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' { return 'MSR' }
            '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' { return 'Basic Data' }
            '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' { return 'Recovery' }
            '{21686148-6449-6e6f-744e-656564454649}' { return 'BIOS Boot' }
            '{5808c8aa-7e8f-42e0-85d2-e1e90434cfb3}' { return 'LDM Meta' }
            '{af9b60a0-1431-4f62-bc68-3311714a69ad}' { return 'LDM Data' }
            default { return $gpt.Trim('{','}').Substring(0,8) + '…' }
        }
    }
    if ($null -ne $mbr) {
        switch ($mbr) {
            0x27 { return 'Recovery' }
            0x07 { return 'NTFS' }
            0x0b { return 'FAT32' }
            0x0c { return 'FAT32' }
            0xef { return 'EFI' }
            0xee { return 'GPT Prot' }
            default { return ('0x{0:X2}' -f $mbr) }
        }
    }
    return '-'
}

# Boxed warning banner. Used for the low-disk-space warning on the OS
# volume. ASCII-only so it renders everywhere.
function Write-WarningBanner {
    param(
        [string]$Headline,
        [string[]]$BodyLines,
        [string]$Color = "Red"
    )
    $innerWidth = 74
    $top    = "+" + ("-" * $innerWidth) + "+"
    $bottom = $top
    Write-Host "  $top" -ForegroundColor $Color
    $hLine = "| " + $Headline.PadRight($innerWidth - 2) + " |"
    Write-Host "  $hLine" -ForegroundColor $Color
    foreach ($line in $BodyLines) {
        $l = "| " + $line.PadRight($innerWidth - 2) + " |"
        Write-Host "  $l" -ForegroundColor $Color
    }
    Write-Host "  $bottom" -ForegroundColor $Color
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

function Get-DesiredStateId {
    # Mirror of production v44's Get-DesiredStateId. Requires the same
    # inputs production resolves at startup: the hardware profile, the
    # OEM package (or $null for NONE), the manifest version, and VMD
    # presence. Defaults to production v44's ScriptVersion.
    param(
        [Parameter(Mandatory)]$Hardware,
        $OEMPackage,
        [Parameter(Mandatory)][string]$ExpectedDriverSetVersion,
        [bool]$VMDPresent = $false,
        [int]$ProductionScriptVersion = 44
    )
    $oemVersion = if ($OEMPackage -and $OEMPackage.Version) { $OEMPackage.Version } else { "NONE" }
    $cpuGen = if ($Hardware.CPUGeneration) { $Hardware.CPUGeneration } else { "N" }
    $parts = @(
        "HW=$($Hardware.Manufacturer)|$($Hardware.Model)|$($Hardware.MachineType)",
        "OS=$($Hardware.Build)",
        "CPU=$($Hardware.CPUVendor)|$cpuGen",
        "VMD=$VMDPresent",
        "MANIFEST=$ExpectedDriverSetVersion",
        "OEMPACK=$oemVersion",
        "SCRIPT=$ProductionScriptVersion"
    )
    $joined = $parts -join ';;'
    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($joined)
    $sha    = [System.Security.Cryptography.SHA256]::Create()
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')
}

function Get-ThisMachineProfile {
    # v15: aligned with production v44's Get-HardwareObject.
    $os      = Get-CimInstance Win32_OperatingSystem
    $cs      = Get-CimInstance Win32_ComputerSystem
    $cpu     = Get-CimInstance Win32_Processor
    $product = Get-CimInstance Win32_ComputerSystemProduct
    $board   = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue

    $isWin11 = $os.Caption -like "*Windows 11*"
    $osLabel = if ($isWin11) { "Win11" } else { "Win10" }

    $manufacturerRaw = if ($cs.Manufacturer) { $cs.Manufacturer.Trim() } else { "" }
    $manufacturer = switch -Regex ($manufacturerRaw) {
        "Dell"              { "Dell" }
        "HP"                { "HP" }
        "Hewlett-Packard"   { "HP" }
        "Lenovo"            { "LENOVO" }
        default             { $manufacturerRaw }
    }

    $model   = if ($cs.Model) { $cs.Model.Trim() } else { "" }
    $version = $product.Version
    $machineType = "UNKN"
    if ($manufacturer -eq "LENOVO") {
        if ($model -match '^([A-Z0-9]{4})')                          { $machineType = $Matches[1] }
        elseif ($product.Name -match '^([A-Z0-9]{4})')               { $machineType = $Matches[1] }
        elseif ($board -and $board.Product -match '^([A-Z0-9]{4})')  { $machineType = $Matches[1] }
        elseif ($version -and $version.Length -ge 4)                 { $machineType = $version.Substring(0,4) }
    } else {
        if ($version -and $version.Length -ge 4) { $machineType = $version.Substring(0,4) }
    }

    $cpuVendor = if ($cpu.Manufacturer -like "*Intel*") { "Intel" } else { "AMD" }
    $gen = Get-IntelProcessorGeneration -CPUName $cpu.Name

    return [PSCustomObject]@{
        OS            = $osLabel
        IsWin11       = $isWin11
        Vendor        = $manufacturer
        Manufacturer  = $manufacturer
        Model         = $model
        MachineType   = $machineType
        Build         = $os.BuildNumber
        CPUVendor     = $cpuVendor
        CPUGeneration = $gen
    }
}

# =========================== SYSTEM INFO HELPERS (based on WinRE.ps1) ===========================

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
    $elevColor = if ($elevated) { "Green" } else { "Yellow" }
    $elevText  = if ($elevated) { "YES" } else { "NO - BitLocker and partition queries may return incomplete data" }
    Write-KV "Elevation:" $elevText $elevColor

    # ---- Hardware ----
    Write-Diag ""
    Write-Diag "  Hardware" "Cyan"
    Write-Diag "  ────────" "DarkGray"
    $cs      = Get-CimInstance Win32_ComputerSystem
    $cpu     = Get-CimInstance Win32_Processor
    $product = Get-CimInstance Win32_ComputerSystemProduct
    $board   = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue
    $osInfo  = Get-CimInstance Win32_OperatingSystem
    $profile = Get-ThisMachineProfile

    Write-KV "Manufacturer"     "$($cs.Manufacturer)" "White"
    Write-KV "Model"            "$($cs.Model.Trim())" "White"
    Write-KV "Product Name"     "$($product.Name)" "Gray"
    Write-KV "Product Version"  "$($product.Version)" "Gray"
    if ($board) { Write-KV "BaseBoard" "$($board.Manufacturer) $($board.Product)" "Gray" }
    Write-KV "OS Caption"       "$($osInfo.Caption)" "White"
    Write-KV "OS Build"         "$($osInfo.BuildNumber)" "White"
    Write-KV "Raw CPU"          "$($cpu.Name)" "Gray"
    $vendorColor = if ($profile.CPUVendor -eq 'Intel') { "Cyan" } else { "Magenta" }
    Write-KV "CPU Vendor"       "$($profile.CPUVendor)" $vendorColor
    $genColor = if ($profile.CPUGeneration) { "Cyan" } else { "Yellow" }
    Write-KV "Intel Generation" "$(if ($profile.CPUGeneration) { $profile.CPUGeneration } else { 'N/A (not Intel or unparsed)' })" $genColor
    Write-KV "Detected OS"      "$($profile.OS)" "White"
    Write-KV "Detected Vendor"  "$($profile.Vendor)" "White"
    Write-KV "Detected MT"      "$($profile.MachineType)" "Gray"

    # ---- reagentc /info (raw) ----
    Write-Diag ""
    Write-Diag "  reagentc /info (raw output)" "Cyan"
    Write-Diag "  ─────────────────────────────" "DarkGray"
    $wreState = Get-WinREState
    foreach ($line in $wreState.RawInfo) { Write-Diag "  $line" "DarkGray" }

    # ---- WinRE parsed state ----
    Write-Diag ""
    Write-Diag "  WinRE state (parsed)" "Cyan"
    Write-Diag "  ────────────────────" "DarkGray"
    $statusColor = if ($wreState.Status -eq 'Enabled') { "Green" } elseif ($wreState.Status -eq 'Disabled') { "Yellow" } else { "Red" }
    Write-KV "Status"   "$($wreState.Status)" $statusColor
    Write-KV "Location" "$($wreState.Location)" "White"

    $activePart = $null
    if ($wreState.Location) {
        $activePart = Resolve-WinRELocationToPartition -Location $wreState.Location
    }
    $osPart = Get-OSPartition
    $osDisk = Get-OSDisk

    if ($activePart) {
        Write-KV "Resolved to" "Disk $($activePart.DiskNumber) Part $($activePart.PartitionNumber)" "White"

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
        $isActiveOSDisk = ($osPart -and $activePart.DiskNumber -eq $osPart.DiskNumber)

        if ($isActiveOSPart) {
            Write-KV "Classification" "OS-FALLBACK (WinRE is on the OS partition)" "Yellow"
        } elseif ($isRec -and $isActiveOSDisk) {
            Write-KV "Classification" "DEDICATED (WinRE on dedicated recovery partition on the OS disk)" "Green"
        } elseif ($isRec) {
            Write-KV "Classification" "RECOVERY-ON-SECONDARY (recovery partition on a non-OS disk - production forces a full rebuild)" "Yellow"
        } else {
            Write-KV "Classification" "UNEXPECTED (WinRE is on neither the OS partition nor a recovery partition)" "Red"
        }
    } else {
        Write-KV "Resolved to" "(could not resolve location to a partition)" "Yellow"
    }

    # ---- OS partition / OS disk ----
    Write-Diag ""
    Write-Diag "  OS partition / OS disk" "Cyan"
    Write-Diag "  ──────────────────────" "DarkGray"
    if ($osPart) {
        $osSizeStr = Format-Size ([int64]$osPart.Size)
        Write-KV "OS partition" "Disk $($osPart.DiskNumber) Part $($osPart.PartitionNumber), $osSizeStr, letter=$($osPart.DriveLetter)" "White"
    } else {
        Write-KV "OS partition" "(could not resolve)" "Red"
    }
    if ($osDisk) {
        Write-KV "OS disk" "Disk $($osDisk.Number) '$($osDisk.FriendlyName)' style=$($osDisk.PartitionStyle)" "White"
    } else {
        Write-KV "OS disk" "(could not resolve)" "Red"
    }

    # ---- OS partition free space warning ----
    if ($osPart) {
        $osVol = Get-Volume -Partition $osPart -ErrorAction SilentlyContinue
        if ($osVol -and $osVol.Size -gt 0) {
            $freePct  = Get-FreeSpacePercent -Free $osVol.SizeRemaining -Total $osVol.Size
            $freeStr  = Format-Size ([int64]$osVol.SizeRemaining)
            $totalStr = Format-Size ([int64]$osVol.Size)
            $freeGB   = $osVol.SizeRemaining / 1GB
            $freeColor = Get-FreeSpaceColor -Free $osVol.SizeRemaining -Total $osVol.Size

            if ($freeColor -eq 'Red') {
                Write-Diag ""
                Write-WarningBanner -Headline "LOW DISK SPACE ON OS VOLUME ($($osPart.DriveLetter):)" -BodyLines @(
                    "",
                    "  Free:  $freeStr  of  $totalStr  ($freePct% free)"
                    "",
                    "  Production may not be able to shrink C: enough to make",
                    "  room for a dedicated recovery partition. If the shrink",
                    "  fails, production falls back to OS-fallback and exits",
                    "  with code 2 (EXIT_WARNING).",
                    "",
                    "  Recommend freeing at least 20 GiB of space on C: before",
                    "  running production."
                ) -Color "Red"
            } elseif ($freeColor -eq 'Yellow') {
                Write-Diag ""
                Write-WarningBanner -Headline "OS VOLUME FREE SPACE IS LOW ($($osPart.DriveLetter):)" -BodyLines @(
                    "",
                    "  Free:  $freeStr  of  $totalStr  ($freePct% free)",
                    "",
                    "  Production should still succeed, but the margin is thin.",
                    "  Consider freeing some space on C: first."
                ) -Color "Yellow"
            } else {
                Write-Diag ""
                Write-KV "OS volume free space" "$freeStr of $totalStr ($freePct% free)" "Green"
            }
        }
    }

    # ---- All disks table ----
    Write-Diag ""
    Write-Diag "  All disks" "Cyan"
    Write-Diag "  ─────────" "DarkGray"
    $diskRows = @()
    foreach ($d in Get-Disk | Sort-Object Number) {
        $diskRows += ,@(
            $d.Number,
            $d.FriendlyName,
            $d.PartitionStyle,
            (Format-Size ([int64]$d.Size)),
            $(if ($d.BootFromDisk) { 'Yes' } else { '-' }),
            $(if ($d.IsSystem)     { 'Yes' } else { '-' }),
            $(if ($d.IsBoot)       { 'Yes' } else { '-' })
        )
    }
    Write-Diag ("  {0}  {1}  {2}  {3}  {4}  {5}  {6}" -f `
        "##".PadRight(3), "Name".PadRight(34), "Style".PadRight(5), "Size".PadRight(11), "Boot".PadRight(5), "Sys".PadRight(4), "IsBoot".PadRight(6)) "Cyan"
    Write-Diag ("  {0}  {1}  {2}  {3}  {4}  {5}  {6}" -f `
        ("─" * 3), ("─" * 34), ("─" * 5), ("─" * 11), ("─" * 5), ("─" * 4), ("─" * 6)) "DarkGray"
    foreach ($row in $diskRows) {
        $color = if ($osDisk -and [int]$row[0] -eq $osDisk.Number) { "White" } else { "Gray" }
        Write-Diag ("  {0}  {1}  {2}  {3}  {4}  {5}  {6}" -f `
            ([string]$row[0]).PadRight(3),
            ([string]$row[1]).PadRight(34),
            ([string]$row[2]).PadRight(5),
            ([string]$row[3]).PadRight(11),
            ([string]$row[4]).PadRight(5),
            ([string]$row[5]).PadRight(4),
            ([string]$row[6]).PadRight(6)) $color
    }

    # ---- All partitions table ----
    Write-Diag ""
    Write-Diag "  All partitions" "Cyan"
    Write-Diag "  ──────────────" "DarkGray"
    Write-Diag ("  {0}  {1}  {2}  {3}  {4}  {5}  {6}" -f `
        "Disk".PadRight(4), "Part".PadRight(4), "Size".PadRight(13), "Letter".PadRight(6),
        "Label".PadRight(12), "Type".PadRight(13), "Flags".PadRight(8)) "Cyan"
    Write-Diag ("  {0}  {1}  {2}  {3}  {4}  {5}  {6}" -f `
        ("─" * 4), ("─" * 4), ("─" * 13), ("─" * 6), ("─" * 12), ("─" * 13), ("─" * 8)) "DarkGray"

    $recPartsForColor = @(Get-RecoveryPartitions)
    foreach ($p in Get-Partition | Sort-Object DiskNumber, PartitionNumber) {
        $letter = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { "-" }
        $label  = "-"
        try {
            $v = Get-Volume -Partition $p -ErrorAction SilentlyContinue
            if ($v -and $v.FileSystemLabel) { $label = $v.FileSystemLabel }
        } catch { }
        $typeName = Get-PartitionTypeName -Partition $p
        $flags = @()
        if ($p.IsBoot)   { $flags += "Boot" }
        if ($p.IsSystem) { $flags += "Sys" }
        if ($p.IsActive) { $flags += "Act" }
        $flagStr = if ($flags.Count -gt 0) { $flags -join ' ' } else { "-" }

        # Colour priority: OS partition > recovery partition > other
        $color = "Gray"
        if ($osPart -and $p.DiskNumber -eq $osPart.DiskNumber -and $p.PartitionNumber -eq $osPart.PartitionNumber) {
            $color = "White"
        } else {
            foreach ($rp in $recPartsForColor) {
                if ($rp.DiskNumber -eq $p.DiskNumber -and $rp.PartitionNumber -eq $p.PartitionNumber) {
                    $color = "Cyan"
                    break
                }
            }
        }

        Write-Diag ("  {0}  {1}  {2}  {3}  {4}  {5}  {6}" -f `
            ([string]$p.DiskNumber).PadRight(4),
            ([string]$p.PartitionNumber).PadRight(4),
            (Format-Size ([int64]$p.Size)).PadRight(13),
            $letter.PadRight(6),
            $label.PadRight(12),
            $typeName.PadRight(13),
            $flagStr.PadRight(8)) $color
    }

    # ---- All volumes table ----
    Write-Diag ""
    Write-Diag "  All volumes" "Cyan"
    Write-Diag "  ───────────" "DarkGray"
    Write-Diag ("  {0}  {1}  {2}  {3}  {4}  {5}  {6}  {7}" -f `
        "Letter".PadRight(6), "FS".PadRight(5), "Free".PadRight(13), "Total".PadRight(13),
        "Used".PadRight(5), "Label".PadRight(12), "Type".PadRight(8), "Health".PadRight(8)) "Cyan"
    Write-Diag ("  {0}  {1}  {2}  {3}  {4}  {5}  {6}  {7}" -f `
        ("─" * 6), ("─" * 5), ("─" * 13), ("─" * 13), ("─" * 5), ("─" * 12), ("─" * 8), ("─" * 8)) "DarkGray"

    foreach ($v in Get-Volume | Sort-Object DriveLetter) {
        $dl = if ($v.DriveLetter) { "$($v.DriveLetter):" } else { "-" }
        $usedPct = if ($v.Size -gt 0) { [math]::Round((($v.Size - $v.SizeRemaining) / $v.Size) * 100, 0) } else { 0 }

        # Colour rules:
        #   Fixed volumes        -> by free space (Red / Yellow / Green)
        #   CD-ROM / Removable   -> DarkGray / Cyan
        #   OS volume always     -> by free space
        $color = "Gray"
        if ($v.DriveType -eq 'CD-ROM') {
            $color = "DarkGray"
        } elseif ($v.DriveType -eq 'Removable') {
            $color = "Cyan"
        } elseif ($v.DriveType -eq 'Fixed') {
            $fc = Get-FreeSpaceColor -Free $v.SizeRemaining -Total $v.Size
            if ($fc) { $color = $fc }
        }

        Write-Diag ("  {0}  {1}  {2}  {3}  {4}  {5}  {6}  {7}" -f `
            $dl.PadRight(6),
            ([string]$v.FileSystem).PadRight(5),
            (Format-Size ([int64]$v.SizeRemaining)).PadRight(13),
            (Format-Size ([int64]$v.Size)).PadRight(13),
            ("$usedPct%").PadRight(5),
            ($(if ($v.FileSystemLabel) { $v.FileSystemLabel } else { "-" })).PadRight(12),
            ([string]$v.DriveType).PadRight(8),
            ([string]$v.HealthStatus).PadRight(8)) $color
    }

    # ---- Recovery partitions ----
    Write-Diag ""
    Write-Diag "  Recovery partitions (per Get-RecoveryPartitions)" "Cyan"
    Write-Diag "  ────────────────────────────────────────────────" "DarkGray"
    $recParts = @(Get-RecoveryPartitions)
    if ($recParts.Count -eq 0) {
        Write-Diag "  (none found)" "Yellow"
    } else {
        Write-Diag ("  {0}  {1}  {2}  {3}  {4}  {5}" -f `
            "Disk".PadRight(4), "Part".PadRight(4), "Size".PadRight(13),
            "isTyped".PadRight(8), "isLabel".PadRight(8), "onOsDisk".PadRight(9)) "Cyan"
        Write-Diag ("  {0}  {1}  {2}  {3}  {4}  {5}" -f `
            ("─" * 4), ("─" * 4), ("─" * 13), ("─" * 8), ("─" * 8), ("─" * 9)) "DarkGray"
        foreach ($rp in $recParts) {
            $isTyped = ($rp.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}') -or ($rp.MbrType -eq 0x27)
            $isLabel = $false
            try {
                $v = Get-Volume -Partition $rp -ErrorAction SilentlyContinue
                if ($v -and ($v.FileSystemLabel -eq 'Recovery' -or $v.FileSystemLabel -eq 'WINRE')) { $isLabel = $true }
            } catch { }
            $onOsDisk = ($osDisk -and $rp.DiskNumber -eq $osDisk.Number)

            # isTyped = True and onOsDisk = True is the healthy case
            $color = if ($isTyped -and $onOsDisk) { "Green" } elseif ($isTyped) { "Yellow" } else { "Red" }

            Write-Diag ("  {0}  {1}  {2}  {3}  {4}  {5}" -f `
                ([string]$rp.DiskNumber).PadRight(4),
                ([string]$rp.PartitionNumber).PadRight(4),
                (Format-Size ([int64]$rp.Size)).PadRight(13),
                ([string]$isTyped).PadRight(8),
                ([string]$isLabel).PadRight(8),
                ([string]$onOsDisk).PadRight(9)) $color
        }
    }

    # ---- OS partition supported sizes ----
    Write-Diag ""
    Write-Diag "  OS partition supported sizes" "Cyan"
    Write-Diag "  ────────────────────────────" "DarkGray"
    if ($osPart) {
        try {
            $supported = Get-PartitionSupportedSize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber
            $size = [int64]$osPart.Size
            $min  = [int64]$supported.SizeMin
            $max  = [int64]$supported.SizeMax
            Write-KV "Current"    (Format-Size $size) "White"
            Write-KV "SizeMin"    (Format-Size $min)  "Gray"
            Write-KV "SizeMax"    (Format-Size $max)  "Gray"
            Write-KV "Shrinkable" (Format-Size ($size - $min)) $(if (($size - $min) -lt 1000MB) { "Yellow" } else { "Green" })
            Write-KV "Extendable" (Format-Size ($max - $size)) "Gray"
            $atMin = ($size -eq $min)
            Write-KV "At SizeMin" "$atMin" $(if ($atMin) { "Yellow" } else { "Green" })
        } catch {
            Write-Diag "  (could not query: $_)" "Yellow"
        }
    } else {
        Write-Diag "  (no OS partition)" "Yellow"
    }

    # ---- Bucket sizing preview ----
    Write-Diag ""
    Write-Diag "  Bucket sizing preview (WIM + 250 + 30, round up to 100, min 1000)" "Cyan"
    Write-Diag "  ─────────────────────────────────────────────────────────────────" "DarkGray"
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
        Write-KV "Active WIM"  "$activeWimPath" "DarkGray"
        Write-KV "WIM size"    "$wimMiB MiB" "White"
        Write-KV "Required"    "$needed MiB" "White"
        Write-KV "Bucket size" "$bucket MiB" "Green"
    } else {
        Write-Diag "  (could not read active WIM at the reagentc-registered location)" "Yellow"
    }

    # ---- Windows Setup state ----
    Write-Diag ""
    Write-Diag "  Windows Setup state" "Cyan"
    Write-Diag "  ───────────────────" "DarkGray"
    $setupStatePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State"
    $imageState = $null
    try {
        $imageState = (Get-ItemProperty -Path $setupStatePath -Name ImageState -ErrorAction SilentlyContinue).ImageState
    } catch { }
    if ($imageState) {
        $stateColor = if ($imageState -eq 'IMAGE_STATE_COMPLETE') { "Green" } else { "Yellow" }
        Write-KV "ImageState" "$imageState" $stateColor
        if ($imageState -ne "IMAGE_STATE_COMPLETE") {
            Write-Diag ""
            Write-Diag "  WARNING: Windows is not in a normal-running state." "Yellow"
            Write-Diag "           Production v43 patch 5 (further revision) refuses to run" "Yellow"
            Write-Diag "           destructive partition work when ImageState is not" "Yellow"
            Write-Diag "           IMAGE_STATE_COMPLETE (Audit Mode, OOBE, sysprep)." "Yellow"
            Write-Diag "           Complete OOBE, sign in to a normal desktop, then re-run." "Yellow"
        }
    } else {
        Write-KV "ImageState" "(not present - some SKUs omit the key)" "Gray"
    }

    # ---- BitLocker on C: ----
    Write-Diag ""
    Write-Diag "  BitLocker on C:" "Cyan"
    Write-Diag "  ───────────────" "DarkGray"
    try {
        $blv = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
        if ($blv) {
            Write-KV "ProtectionStatus" "$($blv.ProtectionStatus)" $(if ($blv.ProtectionStatus -eq 'On') { "Green" } else { "Gray" })
            Write-KV "VolumeStatus"     "$($blv.VolumeStatus)"     $(if ($blv.VolumeStatus     -eq 'FullyDecrypted') { "Green" } else { "Yellow" })
            Write-KV "EncryptionMethod" "$($blv.EncryptionMethod)" "Gray"
            Write-KV "EncryptionPct"    "$($blv.EncryptionPercentage)%" "Gray"

            $vs = [string]$blv.VolumeStatus
            $hazardous = $false
            $ambiguous = $false
            if ($blv.ProtectionStatus -ne 'On' -and $vs) {
                switch ($vs) {
                    'FullyDecrypted'       { $hazardous = $false }
                    'FullyEncrypted'       { $ambiguous = $true }
                    'EncryptionInProgress' { $hazardous = $true }
                    'DecryptionInProgress' { $hazardous = $true }
                    'EncryptionPaused'     { $hazardous = $true }
                    'DecryptionPaused'     { $hazardous = $true }
                    default                { $hazardous = $false }
                }
            }
            if ($hazardous) {
                Write-Diag ""
                Write-Diag "  WARNING: ProtectionStatus=$($blv.ProtectionStatus), VolumeStatus=$vs" "Yellow"
                Write-Diag "           Device Encryption is actively encrypting or decrypting C:." "Yellow"
                Write-Diag "           Production refuses the OS-fallback path in this state." "Yellow"
                Write-Diag "           The enable-only and dedicated-partition paths are still" "Yellow"
                Write-Diag "           available because they target the recovery partition." "Yellow"
            }
            if ($ambiguous) {
                Write-Diag ""
                Write-Diag "  WARNING: ProtectionStatus=$($blv.ProtectionStatus), VolumeStatus=$vs" "Yellow"
                Write-Diag "           This state is ambiguous: legitimate suspension, OR" "Yellow"
                Write-Diag "           Device Encryption Waiting-for-Activation." "Yellow"
                Write-Diag "           Production refuses the OS-fallback path in this state." "Yellow"
            }
        } else {
            Write-Diag "  Get-BitLockerVolume returned null (module not loaded, cmdlet" "Yellow"
            Write-Diag "  failed, or requires elevation)" "Yellow"
        }
    } catch {
        Write-Diag "  Get-BitLockerVolume failed: $_" "Red"
    }

    # ---- Target recovery partition state ----
    Write-Diag ""
    Write-Diag "  Target recovery partition state" "Cyan"
    Write-Diag "  ────────────────────────────────" "DarkGray"
    if ($activePart) {
        Write-KV "Registered partition" "Disk $($activePart.DiskNumber) Part $($activePart.PartitionNumber)" "White"
        $targetVol = Get-Volume -Partition $activePart -ErrorAction SilentlyContinue
        if ($targetVol) {
            $mountPoint = if ($targetVol.DriveLetter) { "$($targetVol.DriveLetter):" } else { $targetVol.UniqueId }
            Write-KV "Querying" "manage-bde -status $mountPoint" "DarkGray"
            try {
                $targetBde = & manage-bde.exe -status $mountPoint 2>&1
                $targetBdeText = ($targetBde | Out-String)
                if ($targetBdeText -match 'could not be opened by BitLocker') {
                    Write-KV "Classification" "unmanaged by BitLocker (reagentc /enable will accept this)" "Green"
                } elseif ($targetBdeText -match 'Conversion Status:\s*Fully Decrypted') {
                    Write-KV "Classification" "fully decrypted (reagentc /enable will accept this)" "Green"
                } elseif ($targetBdeText -match 'Conversion Status:\s*(Fully Encrypted|Used Space Only Encrypted|Encryption In Progress|Decryption In Progress|Encryption Paused|Decryption Paused)') {
                    $convMatch = $targetBdeText | Select-String -Pattern 'Conversion Status:\s*(.+)' | Select-Object -First 1
                    $conv = if ($convMatch) { $convMatch.Matches.Groups[1].Value.Trim() } else { "unknown" }
                    Write-KV "Conversion Status" "$conv" "Yellow"
                    Write-KV "Classification" "BitLocker-managed - production will decrypt in place" "Yellow"
                    Write-Diag "                  Expect up to 300s of additional runtime on the next run." "Yellow"
                } else {
                    Write-KV "Classification" "could not parse manage-bde output" "Yellow"
                }
            } catch {
                Write-Diag "  manage-bde -status failed: $_" "Red"
            }
        } else {
            Write-KV "Classification" "could not resolve target partition to a volume" "Yellow"
        }
    } else {
        Write-Diag "  WinRE is not registered to a partition (Disabled, or unresolved)." "Yellow"
        Write-Diag "  If the plan is OS-fallback, production checks C: directly." "Yellow"
    }

    # ---- VMD hardware presence ----
    Write-Diag ""
    Write-Diag "  VMD hardware presence (per driver manifest)" "Cyan"
    Write-Diag "  ─────────────────────────────────────────────" "DarkGray"
    try {
        $man = Invoke-RestMethod -Uri $DriverManifestUrl -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop
        $vmdIds = @($man.drivers | Where-Object { $_.match.requiredDevices } | ForEach-Object { $_.match.requiredDevices })
        if ($vmdIds.Count -gt 0) {
            $pattern = ($vmdIds | ForEach-Object { [regex]::Escape($_) }) -join '|'
            $vmdMatches = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match $pattern })
            Write-KV "Manifest VMD device IDs" ($vmdIds -join ', ') "DarkGray"
            Write-KV "Matching PnP devices" "$($vmdMatches.Count)" $(if ($vmdMatches.Count -gt 0) { "Green" } else { "Gray" })
            foreach ($m in $vmdMatches) { Write-Diag "    $($m.InstanceId)" "Gray" }
        } else {
            Write-Diag "  (manifest has no VMD device IDs)" "Yellow"
        }
    } catch {
        Write-Diag "  (manifest fetch failed: $_)" "Red"
    }

    # ---- Parser self-test ----
    Write-Diag ""
    Write-Diag "  Parser self-test (production dependency verification)" "Cyan"
    Write-Diag "  ──────────────────────────────────────────────────────" "DarkGray"

    # Check 1: reagentc /info status regex
    $statusPattern = '(Enabled|Disabled)'
    $statusHits = @($wreState.RawInfo | Select-String -Pattern $statusPattern)
    if ($statusHits.Count -gt 0) {
        $matched = ($statusHits | Select-Object -First 1).Matches.Value
        Write-Diag "  [OK]   " -Color "DarkGray" -Message "" 2>$null
        Write-Host "  " -NoNewline
        Write-Host "[OK]  " -NoNewline -ForegroundColor Green
        Write-Host "reagentc status regex '$statusPattern' matched '$matched'" -ForegroundColor Gray
        Record "Parser: reagentc status" $true "matched '$matched'"
    } else {
        Write-Host "  " -NoNewline
        Write-Host "[FAIL]" -NoNewline -ForegroundColor Red
        Write-Host " reagentc status regex '$statusPattern' did not match any line" -ForegroundColor Gray
        Record "Parser: reagentc status" $false "no match"
    }

    # Check 2: reagentc /info location regex
    $locPattern = '(\\\\\?\\GLOBALROOT\\device\\harddisk\d+\\partition\d+\\|\\\\\?\\Volume\{[a-fA-F0-9\-]+\}\\?)'
    $locHits = @($wreState.RawInfo | Select-String -Pattern $locPattern)
    if ($locHits.Count -gt 0) {
        $matched = ($locHits | Select-Object -First 1).Matches.Value.Trim()
        Write-Host "  " -NoNewline
        Write-Host "[OK]  " -NoNewline -ForegroundColor Green
        Write-Host "reagentc location regex matched '$matched'" -ForegroundColor Gray
        Record "Parser: reagentc location" $true "matched '$matched'"
    } else {
        Write-Host "  " -NoNewline
        Write-Host "[FAIL]" -NoNewline -ForegroundColor Red
        Write-Host " reagentc location regex did not match any line" -ForegroundColor Gray
        Record "Parser: reagentc location" $false "no match"
    }

    # Checks 3 & 4: manage-bde -status C: raw dump and regex verification
    Write-Diag ""
    Write-Diag "    manage-bde -status C: raw output" "DarkGray"
    Write-Diag "    ─────────────────────────────────" "DarkGray"
    try {
        $mboRaw = & manage-bde.exe -status "C:" 2>&1
        $mboText = ($mboRaw | Out-String)
        foreach ($line in $mboRaw) { Write-Diag "    $line" "DarkGray" }

        $protOn  = $mboText -match 'Protection On'
        $protOff = $mboText -match 'Protection Off'
        if ($protOn -or $protOff) {
            $state = if ($protOn) { "On" } else { "Off" }
            Write-Host "  " -NoNewline
            Write-Host "[OK]  " -NoNewline -ForegroundColor Green
            Write-Host "manage-bde protection regex matched 'Protection $state'" -ForegroundColor Gray
            Record "Parser: manage-bde protection" $true "matched 'Protection $state'"
        } else {
            Write-Host "  " -NoNewline
            Write-Host "[FAIL]" -NoNewline -ForegroundColor Red
            Write-Host " manage-bde protection regex: no match" -ForegroundColor Gray
            Record "Parser: manage-bde protection" $false "no match"
        }

        $convMatch = $mboText -match 'Conversion Status:\s*(Fully Decrypted|Fully Encrypted|Used Space Only Encrypted|Encryption In Progress|Decryption In Progress|Encryption Paused|Decryption Paused)'
        $unmanaged = $mboText -match 'could not be opened by BitLocker'
        if ($convMatch) {
            Write-Host "  " -NoNewline
            Write-Host "[OK]  " -NoNewline -ForegroundColor Green
            Write-Host "manage-bde conversion status regex matched" -ForegroundColor Gray
            Record "Parser: manage-bde conversion" $true "matched"
        } elseif ($unmanaged) {
            Write-Host "  " -NoNewline
            Write-Host "[OK]  " -NoNewline -ForegroundColor Green
            Write-Host "manage-bde unmanaged-volume classification matched" -ForegroundColor Gray
            Record "Parser: manage-bde conversion" $true "unmanaged-volume classification"
        } else {
            Write-Host "  " -NoNewline
            Write-Host "[FAIL]" -NoNewline -ForegroundColor Red
            Write-Host " manage-bde conversion status regex: no match" -ForegroundColor Gray
            Record "Parser: manage-bde conversion" $false "no match"
        }
    } catch {
        Write-Host "  " -NoNewline
        Write-Host "[FAIL]" -NoNewline -ForegroundColor Red
        Write-Host " manage-bde invocation failed: $_" -ForegroundColor Gray
        Record "Parser: manage-bde" $false "invocation failed: $_"
    }

    # Check 5: Get-BitLockerVolume shape
    if (-not $elevated) {
        Write-Host "  " -NoNewline
        Write-Host "[SKIP]" -NoNewline -ForegroundColor DarkGray
        Write-Host " Get-BitLockerVolume: requires elevation" -ForegroundColor Gray
        Record "Parser: Get-BitLockerVolume shape" $false -State "SKIP" -Detail "not elevated"
    } else {
        try {
            $blvCheck = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
            if ($blvCheck -and $null -ne $blvCheck.ProtectionStatus -and $null -ne $blvCheck.VolumeStatus) {
                Write-Host "  " -NoNewline
                Write-Host "[OK]  " -NoNewline -ForegroundColor Green
                Write-Host "Get-BitLockerVolume: ProtectionStatus and VolumeStatus present" -ForegroundColor Gray
                Record "Parser: Get-BitLockerVolume shape" $true "ProtectionStatus=$($blvCheck.ProtectionStatus)"
            } else {
                Write-Host "  " -NoNewline
                Write-Host "[FAIL]" -NoNewline -ForegroundColor Red
                Write-Host " Get-BitLockerVolume: missing ProtectionStatus or VolumeStatus" -ForegroundColor Gray
                Record "Parser: Get-BitLockerVolume shape" $false "missing property"
            }
        } catch {
            Write-Host "  " -NoNewline
            Write-Host "[FAIL]" -NoNewline -ForegroundColor Red
            Write-Host " Get-BitLockerVolume threw: $_" -ForegroundColor Gray
            Record "Parser: Get-BitLockerVolume shape" $false "$_"
        }
    }

    # Check 6: OS partition and OS disk resolution
    if ($osPart -and $osDisk) {
        Write-Host "  " -NoNewline
        Write-Host "[OK]  " -NoNewline -ForegroundColor Green
        Write-Host "OS resolution: Disk $($osDisk.Number), partition $($osPart.PartitionNumber)" -ForegroundColor Gray
        Record "Parser: OS resolution" $true "Disk $($osDisk.Number)/Part $($osPart.PartitionNumber)"
    } else {
        Write-Host "  " -NoNewline
        Write-Host "[FAIL]" -NoNewline -ForegroundColor Red
        Write-Host " OS resolution: could not resolve" -ForegroundColor Gray
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
                Write-Host "  " -NoNewline
                Write-Host "[OK]  " -NoNewline -ForegroundColor Green
                Write-Host "Get-Partition exposes all expected properties" -ForegroundColor Gray
                Record "Parser: Get-Partition shape" $true "all properties present"
            } else {
                Write-Host "  " -NoNewline
                Write-Host "[FAIL]" -NoNewline -ForegroundColor Red
                Write-Host " Get-Partition missing properties: $($missing -join ', ')" -ForegroundColor Gray
                Record "Parser: Get-Partition shape" $false "missing: $($missing -join ', ')"
            }
        } else {
            Write-Host "  " -NoNewline
            Write-Host "[FAIL]" -NoNewline -ForegroundColor Red
            Write-Host " Get-Partition returned no partitions" -ForegroundColor Gray
            Record "Parser: Get-Partition shape" $false "no partitions"
        }
    } catch {
        Write-Host "  " -NoNewline
        Write-Host "[FAIL]" -NoNewline -ForegroundColor Red
        Write-Host " Get-Partition threw: $_" -ForegroundColor Gray
        Record "Parser: Get-Partition shape" $false "$_"
    }

    # Check 8: WinRE location resolution
    if ($wreState.Location) {
        $resolved = Resolve-WinRELocationToPartition -Location $wreState.Location
        if ($resolved) {
            Write-Host "  " -NoNewline
            Write-Host "[OK]  " -NoNewline -ForegroundColor Green
            Write-Host "WinRE location resolves to Disk $($resolved.DiskNumber) Part $($resolved.PartitionNumber)" -ForegroundColor Gray
            Record "Parser: WinRE location resolution" $true "Disk $($resolved.DiskNumber)/Part $($resolved.PartitionNumber)"
        } else {
            Write-Host "  " -NoNewline
            Write-Host "[FAIL]" -NoNewline -ForegroundColor Red
            Write-Host " WinRE location '$($wreState.Location)' could not be resolved" -ForegroundColor Gray
            Record "Parser: WinRE location resolution" $false "no resolution"
        }
    } else {
        Write-Host "  " -NoNewline
        Write-Host "[SKIP]" -NoNewline -ForegroundColor DarkGray
        Write-Host " WinRE location is empty" -ForegroundColor Gray
        Record "Parser: WinRE location resolution" $false -State "SKIP" -Detail "empty location (expected on some machines)"
    }

    # Check 9: Get-RecoveryPartitions returns at least one partition
    $recPartsCheck = @(Get-RecoveryPartitions)
    if ($recPartsCheck.Count -ge 1) {
        Write-Host "  " -NoNewline
        Write-Host "[OK]  " -NoNewline -ForegroundColor Green
        Write-Host "Get-RecoveryPartitions: found $($recPartsCheck.Count) partition(s)" -ForegroundColor Gray
        Record "Parser: Get-RecoveryPartitions" $true "$($recPartsCheck.Count) found"
    } else {
        Write-Host "  " -NoNewline
        Write-Host "[FAIL]" -NoNewline -ForegroundColor Red
        Write-Host " Get-RecoveryPartitions: found 0 partitions" -ForegroundColor Gray
        Record "Parser: Get-RecoveryPartitions" $false "0 found"
    }

    # Check 10: Get-PartitionSupportedSize
    if ($osPart) {
        try {
            $supportedCheck = Get-PartitionSupportedSize -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber -ErrorAction Stop
            if ($null -ne $supportedCheck.SizeMin -and $null -ne $supportedCheck.SizeMax) {
                $minMiB = [math]::Round($supportedCheck.SizeMin / 1MB, 0)
                $maxMiB = [math]::Round($supportedCheck.SizeMax / 1MB, 0)
                Write-Host "  " -NoNewline
                Write-Host "[OK]  " -NoNewline -ForegroundColor Green
                Write-Host "Get-PartitionSupportedSize: SizeMin=${minMiB}M SizeMax=${maxMiB}M" -ForegroundColor Gray
                Record "Parser: Get-PartitionSupportedSize" $true "min=${minMiB}M max=${maxMiB}M"
            } else {
                Write-Host "  " -NoNewline
                Write-Host "[FAIL]" -NoNewline -ForegroundColor Red
                Write-Host " Get-PartitionSupportedSize: SizeMin or SizeMax missing" -ForegroundColor Gray
                Record "Parser: Get-PartitionSupportedSize" $false "missing property"
            }
        } catch {
            Write-Host "  " -NoNewline
            Write-Host "[FAIL]" -NoNewline -ForegroundColor Red
            Write-Host " Get-PartitionSupportedSize threw: $_" -ForegroundColor Gray
            Record "Parser: Get-PartitionSupportedSize" $false "$_"
        }
    } else {
        Write-Host "  " -NoNewline
        Write-Host "[SKIP]" -NoNewline -ForegroundColor DarkGray
        Write-Host " Get-PartitionSupportedSize: no OS partition" -ForegroundColor Gray
        Record "Parser: Get-PartitionSupportedSize" $false -State "SKIP" -Detail "no OS partition"
    }

    Write-Diag ""
    Write-Diag "  Diagnostic complete. Parser self-test results are in the summary." "Green"
}

function Show-StateFileParity {
    Rule "State file parity check"
    Write-Diag "  Answers: would production v44 take the fast path on this machine now?" "Gray"

    # ---- Resolve the manifest ----
    Write-Diag ""
    Write-Diag "  Fetching driver manifest..." "DarkGray"
    $manifest = $null
    try {
        $manifest = Invoke-RestMethod -Uri $DriverManifestUrl -Headers $GitHubHeaders -UseBasicParsing -ErrorAction Stop
    } catch {
        Say "Manifest fetch failed: $_" -Level ERROR
        Record "State file parity" $false "manifest fetch failed"
        return
    }
    if (-not $manifest -or -not $manifest.version) {
        Say "Manifest missing version field" -Level ERROR
        Record "State file parity" $false "manifest invalid"
        return
    }
    Write-KV "Manifest version" "$($manifest.version)" "White"

    # ---- Hardware profile ----
    $profile = Get-ThisMachineProfile
    Write-Diag ""
    Write-Diag "  Hardware" "Cyan"
    Write-Diag "  ────────" "DarkGray"
    Write-KV "Hardware" "$($profile.Manufacturer) | $($profile.Model) | MT=$($profile.MachineType)" "White"
    Write-KV "OS"       "$($profile.OS) (build $($profile.Build))" "White"
    Write-KV "CPU"      "$($profile.CPUVendor) | gen $(if ($profile.CPUGeneration) { $profile.CPUGeneration } else { 'N' })" "White"

    # ---- OEM package (mirrors production's resolution) ----
    $oemPackage = $null
    switch ($profile.Manufacturer) {
        "Dell"   { $oemPackage = Get-DellWinPEPack   -Hardware $profile }
        "HP"     { $oemPackage = Get-HPWinPEPack     -Hardware $profile }
        "LENOVO" { $oemPackage = Get-LenovoWinPEPack -Hardware $profile }
    }
    $oemVersion = if ($oemPackage -and $oemPackage.Version) { $oemPackage.Version } else { "NONE" }
    Write-KV "OEM package" "$oemVersion" $(if ($oemVersion -eq 'NONE') { "Gray" } else { "White" })

    # ---- VMD presence ----
    $vmdIds = @($manifest.drivers | Where-Object { $_.match.requiredDevices } | ForEach-Object { $_.match.requiredDevices })
    $vmdPresent = $false
    if ($vmdIds.Count -gt 0) {
        $pattern = ($vmdIds | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $vmdPresent = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
                        Where-Object { $_.InstanceId -match $pattern }).Count -gt 0
    }
    Write-KV "VMD present" "$vmdPresent" $(if ($vmdPresent) { "Cyan" } else { "Gray" })

    # ---- Compute the DSI production would compute right now ----
    $computedDsi = Get-DesiredStateId -Hardware $profile -OEMPackage $oemPackage `
                                       -ExpectedDriverSetVersion $manifest.version `
                                       -VMDPresent $vmdPresent
    Write-Diag ""
    Write-KV "Computed DesiredStateId" "$computedDsi" "Magenta"

    # ---- Read the state file ----
    $statePath = "$env:SystemDrive\Recovery\OEM\winre_state.json"
    Write-Diag ""
    Write-KV "State file" "$statePath" "DarkGray"
    if (-not (Test-Path $statePath)) {
        Write-Diag ""
        Write-Diag "  (does not exist - production will take the full-update path)" "Yellow"
        Record "State file parity" $true "no state file (rebuild expected)"
        return
    }
    try {
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
    } catch {
        Say "  (could not be parsed: $_)" -Level ERROR
        Record "State file parity" $false "parse failed"
        return
    }

    Write-KV "Stored DesiredStateId" "$($state.DesiredStateId)" "Magenta"
    Write-KV "CurrentImageHash"      "$($state.CurrentImageHash)" "DarkGray"
    Write-KV "DriverSetVersion"      "$($state.InjectedDriverSetVersion)" "Gray"
    Write-KV "LastUpdated"           "$($state.LastUpdated)" "Gray"
    Write-KV "PendingReboot"         "$($state.PendingReboot)" $(if ($state.PendingReboot) { "Yellow" } else { "Gray" })
    Write-KV "UsedOSFallback"        "$($state.UsedOSFallback)" $(if ($state.UsedOSFallback) { "Yellow" } else { "Gray" })
    Write-KV "LastEnableResult"      "$($state.LastEnableResult)" $(if ($state.LastEnableResult -eq 'ok') { "Green" } else { "Yellow" })
    Write-KV "EnableFailureAttempts" "$($state.EnableFailureAttempts)" $(if ([int]$state.EnableFailureAttempts -gt 0) { "Yellow" } else { "Gray" })

    Write-Diag ""
    if ($state.DesiredStateId -eq $computedDsi) {
        Write-Diag "  Verdict: " -Color "DarkGray" -Message "" 2>$null
        Write-Host "  Verdict: " -NoNewline -ForegroundColor DarkGray
        Write-Host "DSI MATCH" -NoNewline -ForegroundColor Green
        Write-Host " - production will accept the state file." -ForegroundColor Gray
        Write-Diag "           Subject to the other fast-path gates: WinRE Enabled," "DarkGray"
        Write-Diag "           exactly one recovery partition on the OS disk, and the" "DarkGray"
        Write-Diag "           active WIM hash matching the stored CurrentImageHash." "DarkGray"
        Record "State file parity" $true "DSI matches"
    } else {
        Write-Host "  Verdict: " -NoNewline -ForegroundColor DarkGray
        Write-Host "DSI MISMATCH" -NoNewline -ForegroundColor Yellow
        Write-Host " - production will treat the state file as stale" -ForegroundColor Gray
        Write-Diag "           and run the full-update path (rebuild + redeploy)." "DarkGray"
        Write-Diag "           Expected on the first run after a DesiredStateId input" "DarkGray"
        Write-Diag "           change: ScriptVersion, MANIFEST, OEMPACK, CPU vendor/" "DarkGray"
        Write-Diag "           generation, or VMD presence. Subsequent runs take the" "DarkGray"
        Write-Diag "           fast path once the state file is rewritten." "DarkGray"
        Record "State file parity" $true "DSI mismatch (rebuild will run)"
    }
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
                Write-Diag "    $($d.name)  os=[$($d.os -join ',')]  cpuGen=$($d.match.cpuGenMin)-$($d.match.cpuGenMax)  vmdDevices=$reqDev" "Gray"
                Write-Diag "      url=$($d.driverUrl)" "DarkGray"
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
        Write-KV "Dell" "Name=$($d.Name)  Version=$($d.Version)  ArchiveType=$($d.ArchiveType)" "Green"
        Write-Diag "    URL=$($d.DownloadUrl)" "DarkGray"
        Write-Diag "    SHA256=$($d.ExpectedSHA256)  MD5=$($d.ExpectedMD5)" "DarkGray"
    } else { $ok = $false; Write-KV "Dell" "(unresolved)" "Red" }

    $h = Get-HPWinPEPack -Hardware $fakeHardware
    if ($h) {
        Write-KV "HP" "Name=$($h.Name)  Version=$($h.Version)  ArchiveType=$($h.ArchiveType)" "Green"
        Write-Diag "    URL=$($h.DownloadUrl)" "DarkGray"
        Write-Diag "    SHA256=$($h.ExpectedSHA256)  MD5=$($h.ExpectedMD5)" "DarkGray"
    } else { $ok = $false; Write-KV "HP" "(unresolved)" "Red" }

    $l = Get-LenovoWinPEPack -Hardware $fakeHardware
    if ($l) {
        Write-KV "Lenovo" "Name=$($l.Name)  Version=$($l.Version)  ArchiveType=$($l.ArchiveType)" "Green"
        Write-Diag "    URL=$($l.DownloadUrl)" "DarkGray"
        Write-Diag "    SHA256=$($l.ExpectedSHA256)" "DarkGray"
    } elseif ($profile.Vendor -eq 'LENOVO') {
        $mtKnown = ($profile.MachineType -and $profile.MachineType -ne 'UNKN')
        if (-not $mtKnown) {
            Write-KV "Lenovo" "machine type could not be resolved (MT=UNKN) - production treats as complete with OEMPACK=NONE" "Gray"
        } elseif (-not $Script:LenovoWinPEMap) {
            Write-KV "Lenovo" "map could not be loaded - production would treat as transient failure and defer" "Yellow"
            $ok = $false
        } else {
            Write-KV "Lenovo" "map loaded, no entry for MT $($profile.MachineType) - production treats as complete with OEMPACK=NONE" "Gray"
        }
    } else {
        Write-KV "Lenovo" "map skipped (machine type not applicable)" "DarkGray"
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
    Write-KV "winre.wim" "$(Format-Size ([int64]$sz))" "White"

    $buildOk = $true
    $detail = "size=$([math]::Round($sz/1MB,2))MiB"
    try {
        $b = (Get-WindowsImage -ImagePath $wim -Index 1 -ErrorAction Stop).Build
        Write-KV "ImageBuild" "$b" "White"
        if ($OS -eq "Win11" -and [int]$b -lt 22000) {
            Say "MISMATCH: folder is Win11 but WIM build is $b (< 22000)" -Level ERROR
            $buildOk = $false
        } elseif ($OS -eq "Win10" -and [int]$b -ge 22000) {
            Say "MISMATCH: folder is Win10 but WIM build is $b (>= 22000)" -Level ERROR
            $buildOk = $false
        }
        $detail = "$detail build=$b"
    } catch {
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
        if (-not $osMatch) { Write-Diag "  Skipping $($drv.name): OS mismatch" "DarkGray"; continue }
        if ($profile.CPUVendor -ne 'Intel') { Write-Diag "  Skipping $($drv.name): not Intel hardware" "DarkGray"; continue }
        if ($null -eq $profile.CPUGeneration) { Write-Diag "  Skipping $($drv.name): CPU generation unknown" "DarkGray"; continue }
        if ($profile.CPUGeneration -lt $drv.match.cpuGenMin -or $profile.CPUGeneration -gt $drv.match.cpuGenMax) {
            Write-Diag "  Skipping $($drv.name): CPU gen $($profile.CPUGeneration) outside $($drv.match.cpuGenMin)-$($drv.match.cpuGenMax)" "DarkGray"
            continue
        }
        $relevant += $drv
    }

    if ($relevant.Count -eq 0) {
        Write-Diag "  No VMD drivers in manifest apply to this machine" "Yellow"
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
            Write-KV "  Downloaded" "$(Format-Size ([int64](Get-Item $archive).Length))" "White"
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
            Write-KV "  7-Zip exit" "$($proc.ExitCode)" $(if ($proc.ExitCode -eq 0) { "Green" } else { "Red" })
        } catch {
            Say "7-Zip failed: $_" -Level ERROR
            Record "VMD $($drv.name)" $false "7-Zip failed"
            $allOk = $false
            continue
        }
        $infCount = Get-InfFileCount -Directory $extract
        Write-KV "  INF count" "$infCount" $(if ($infCount -gt 0) { "Green" } else { "Red" })
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
        'LENOVO' {
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
    foreach ($r in $Script:Results) {
        $stateColor = switch ($r.State) {
            "PASS" { "Green" }
            "FAIL" { "Red" }
            "SKIP" { "DarkGray" }
            default { "Gray" }
        }
        Write-Host "  [" -NoNewline -ForegroundColor DarkGray
        Write-Host $r.State -NoNewline -ForegroundColor $stateColor
        Write-Host "] " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($r.Test)  " -NoNewline -ForegroundColor White
        Write-Host $r.Detail -ForegroundColor DarkGray
    }
    $passed  = @($Script:Results | Where-Object { $_.State -eq "PASS" }).Count
    $failed  = @($Script:Results | Where-Object { $_.State -eq "FAIL" }).Count
    $skipped = @($Script:Results | Where-Object { $_.State -eq "SKIP" }).Count

    $passColor  = if ($passed  -gt 0) { "Green" } else { "DarkGray" }
    $failColor  = if ($failed  -gt 0) { "Red" }   else { "Green" }
    $skipColor  = if ($skipped -gt 0) { "Yellow" } else { "DarkGray" }

    Write-Host ""
    Write-Host "  Passed " -NoNewline -ForegroundColor Gray
    Write-Host "$passed" -NoNewline -ForegroundColor $passColor
    Write-Host ", failed " -NoNewline -ForegroundColor Gray
    Write-Host "$failed" -NoNewline -ForegroundColor $failColor
    Write-Host ", skipped " -NoNewline -ForegroundColor Gray
    Write-Host "$skipped" -NoNewline -ForegroundColor $skipColor
    Write-Host " (of $($Script:Results.Count))" -ForegroundColor Gray
}

# =========================== MENU ===========================
function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔" -NoNewline -ForegroundColor DarkGray
    Write-Host ("═" * 66) -NoNewline -ForegroundColor DarkGray
    Write-Host "╗" -ForegroundColor DarkGray
    Write-Host "  ║ " -NoNewline -ForegroundColor DarkGray
    Write-Host "WinRE Manager Test Harness (v16)" -NoNewline -ForegroundColor Cyan
    Write-Host (" " * 33) -NoNewline
    Write-Host "║" -ForegroundColor DarkGray
    Write-Host "  ║ " -NoNewline -ForegroundColor DarkGray
    Write-Host "Working directory: $TestDir" -NoNewline -ForegroundColor Gray
    Write-Host (" " * [Math]::Max(0, 48 - $TestDir.Length)) -NoNewline
    Write-Host "║" -ForegroundColor DarkGray
    $p = Get-ThisMachineProfile
    $detected = "Detected: OS=$($p.OS)  Vendor=$($p.Vendor)  MT=$($p.MachineType)  CPU=$($p.CPUVendor)"
    $detectedTrim = if ($detected.Length -gt 64) { $detected.Substring(0, 61) + "..." } else { $detected }
    Write-Host "  ║ " -NoNewline -ForegroundColor DarkGray
    Write-Host $detectedTrim -NoNewline -ForegroundColor Gray
    Write-Host (" " * [Math]::Max(0, 64 - $detectedTrim.Length)) -NoNewline
    Write-Host "║" -ForegroundColor DarkGray
    Write-Host "  ╚" -NoNewline -ForegroundColor DarkGray
    Write-Host ("═" * 66) -NoNewline -ForegroundColor DarkGray
    Write-Host "╝" -ForegroundColor DarkGray
    Write-Host ""

    function MenuItem {
        param([string]$Key, [string]$Text, [string]$KeyColor = "Cyan")
        Write-Host "  " -NoNewline
        Write-Host ("{0,-3}" -f $Key) -NoNewline -ForegroundColor $KeyColor
        Write-Host $Text -ForegroundColor White
    }

    MenuItem "1" "System diagnostic (read-only info gathering)"
    MenuItem "2" "Driver manifest fetch"
    MenuItem "3" "OEM maps fetch + resolve (Dell, HP, Lenovo)"
    MenuItem "4" "GitHub base WIM - Win10 (download + extract + build check)"
    MenuItem "5" "GitHub base WIM - Win11 (download + extract + build check)"
    MenuItem "6" "HP WinPE pack (download + extract)"
    MenuItem "7" "Dell WinPE pack (prompts for OS)"
    MenuItem "8" "Lenovo WinPE pack (prompts for MT)"
    MenuItem "9" "VMD drivers (per manifest, filtered for this machine)"
    MenuItem "S" "State file parity check (production DSI vs on-disk state file)" "Magenta"
    MenuItem "A" "All relevant for this machine" "Green"
    MenuItem "B" "All of the above" "Green"
    MenuItem "R" "Print results summary" "Yellow"
    MenuItem "Q" "Quit" "Red"
    Write-Host ""
}

# =========================== ENTRY ===========================
New-Item -Path $TestDir -ItemType Directory -Force | Out-Null
Rule "WinRE Manager test harness v16"
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
    $choice = Read-Host "  Select"
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
        "S" { Show-StateFileParity }
        "A" { Invoke-AllRelevant }
        "B" { Invoke-All }
        "R" { Show-Summary }
        "Q" { $quit = $true }
        default { Say "Unknown choice" -Level WARN }
    }
    if (-not $quit) {
        Write-Host ""
        [void](Read-Host "  Press Enter to return to menu")
    }
}

Show-Summary
Write-Host ""

if (-not $Keep) {
    # NOTE: do not reuse $Keep (the switch parameter) as a local variable.
    # Assigning a string to a variable that holds [switch] throws a type
    # conversion error, and [switch] has no Trim method. Use a distinct name.
    $keepAnswer = Read-Host "  Keep test artifacts in $TestDir ? (y/N)"
    if ($keepAnswer.Trim().ToLower() -ne "y") {
        Say "Removing $TestDir"
        try { Remove-Item $TestDir -Force -Recurse -ErrorAction SilentlyContinue } catch { }
    } else {
        Say "Kept: $TestDir"
    }
}
Say "Done."
